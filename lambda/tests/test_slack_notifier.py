import json
import logging
from contextlib import contextmanager

import boto3
import pytest
from botocore.stub import Stubber

from slack_notifier import handler

WEBHOOK_URL = "https://hooks.slack.com/services/T000/B000/not-a-real-secret"
PARAM_NAME = "/finops/slack-webhook"

BUDGET_MESSAGE = """AWS Budget Notification March 10, 2026
AWS Account 123456789012

Dear AWS Customer,

You requested that we alert you when the ACTUAL Cost associated with your Monthly account \
budget is greater than $80.00 for the current month. The ACTUAL Cost associated with this \
budget is $85.20.

Budget Name: finops-account
Budget Type: Cost
Budgeted Amount: $100.00
Alert Type: ACTUAL
Alert Threshold: > $80.00
ACTUAL Amount: $85.20
"""

ANOMALY = {
    "accountId": "123456789012",
    "anomalyId": "abc-123",
    "anomalyStartDate": "2026-03-09T00:00:00Z",
    "dimensionValue": "Amazon Elastic Compute Cloud - Compute",
    "impact": {
        "maxImpact": 55.0,
        "totalActualSpend": 120.0,
        "totalExpectedSpend": 60.0,
        "totalImpact": 60.0,
        "totalImpactPercentage": 100.0,
    },
    "rootCauses": [{"service": "Amazon EC2", "region": "us-east-1", "usageType": "BoxUsage"}],
    "anomalyDetailsLink": "https://console.aws.amazon.com/cost-management/home#/anomaly/abc-123",
}

COST_REPORT = {
    "kind": "cost_report",
    "period": "weekly",
    "month_to_date_usd": 42.5,
    "budget_limit_usd": 100,
    "forecast_usd": 91.2,
    "top_services": [
        {"service": "Amazon EC2", "amount_usd": 30.0},
        {"service": "Amazon RDS", "amount_usd": 8.5},
    ],
    "biggest_change": {"service": "Amazon EC2", "change_usd": 12.0, "change_pct": 66.7},
    "anomalies": [{"service": "Amazon EC2", "impact_usd": 60.0}],
}

SCHEDULER_SUMMARY = {
    "kind": "scheduler_summary",
    "action": "stop",
    "dry_run": False,
    "counts": {"stopped": 2, "started": 0, "skipped": 1, "failed": 1},
    "details": [
        {"resource": "i-0abc", "type": "ec2", "outcome": "stopped"},
        {"resource": "i-0def", "type": "ec2", "outcome": "skipped", "reason": "in an ASG"},
        {
            "resource": "db-1",
            "type": "rds",
            "outcome": "failed",
            "reason": "InvalidDBInstanceState",
        },
    ],
}


def text_of(payload):
    """All the text in a Slack payload, for simple substring assertions."""
    return json.dumps(payload, ensure_ascii=False)


@pytest.fixture(autouse=True)
def _reset_state(monkeypatch):
    handler._CLIENTS.clear()
    handler._WEBHOOK_CACHE.clear()
    monkeypatch.setenv("SLACK_WEBHOOK_SSM_PARAM", PARAM_NAME)


# --- classification -------------------------------------------------------------


def test_classify_budget_text():
    kind, parsed = handler.classify(BUDGET_MESSAGE, "AWS Budgets: finops-account has exceeded")
    assert kind == handler.BUDGET
    assert parsed["budget_name"] == "finops-account"
    assert parsed["amount"] == "$85.20"
    assert parsed["account_id"] == "123456789012"


def test_classify_budget_forecast_amount():
    message = "Budget Name: x\nAlert Type: FORECASTED\nFORECASTED Amount: $120.00\n"
    _, parsed = handler.classify(message)
    assert parsed["amount"] == "$120.00"


def test_classify_anomaly_top_level_and_nested():
    assert handler.classify(json.dumps(ANOMALY))[0] == handler.ANOMALY
    nested = json.dumps({"detail": ANOMALY})
    kind, parsed = handler.classify(nested)
    assert kind == handler.ANOMALY
    assert parsed["anomalyId"] == "abc-123"


def test_classify_module_payloads():
    assert handler.classify(json.dumps(COST_REPORT))[0] == handler.COST_REPORT
    assert handler.classify(json.dumps(SCHEDULER_SUMMARY))[0] == handler.SCHEDULER_SUMMARY


@pytest.mark.parametrize(
    "message",
    ["hello world", "", "{not json", "[1, 2, 3]", json.dumps({"something": "else"})],
)
def test_classify_unknown(message):
    assert handler.classify(message)[0] == handler.UNKNOWN


# --- formatting -----------------------------------------------------------------


def test_budget_format():
    payload = handler.build_slack_payload("AWS Budgets: x", BUDGET_MESSAGE)
    body = text_of(payload)
    assert payload["text"] == "Budget alert: finops-account"
    assert "$85.20" in body and "$100.00" in body and "ACTUAL" in body


def test_anomaly_format():
    payload = handler.build_slack_payload(None, json.dumps(ANOMALY))
    body = text_of(payload)
    assert payload["text"] == "Cost anomaly: Amazon Elastic Compute Cloud - Compute"
    assert "$60.00" in body and "100.0%" in body
    assert "Amazon EC2 / us-east-1 / BoxUsage" in body
    assert "View in the AWS console" in body


def test_anomaly_ignores_non_https_link():
    anomaly = dict(ANOMALY, anomalyDetailsLink="javascript:alert(1)")
    body = text_of(handler.build_slack_payload(None, json.dumps(anomaly)))
    assert "javascript" not in body


def test_cost_report_format():
    body = text_of(handler.build_slack_payload(None, json.dumps(COST_REPORT)))
    assert "$42.50 of $100.00 budget (42.5%)" in body
    assert "$91.20" in body
    assert "Amazon RDS: $8.50" in body
    assert "+$12.00" in body and "+66.7%" in body
    assert "last 7 days):* 1" in body


def test_cost_report_for_new_account_with_no_data():
    empty = {"kind": "cost_report", "month_to_date_usd": 0, "budget_limit_usd": 0}
    payload = handler.build_slack_payload(None, json.dumps(empty))
    body = text_of(payload)
    assert "$0.00" in body
    assert "not available yet" in body
    assert "budget (" not in body  # no division by a zero limit
    assert "last 7 days):* 0" in body


def test_cost_report_with_missing_fields_still_formats():
    payload = handler.build_slack_payload(None, json.dumps({"kind": "cost_report"}))
    assert payload["text"].startswith("Cost report")
    assert "n/a" in text_of(payload)


def test_scheduler_summary_format():
    body = text_of(handler.build_slack_payload(None, json.dumps(SCHEDULER_SUMMARY)))
    assert "*Stopped:* 2" in body and "*Failed:* 1" in body
    assert "in an ASG" in body and "InvalidDBInstanceState" in body
    assert "i-0abc" not in body  # successes are counted, not listed


def test_scheduler_summary_dry_run_title_and_detail_cap():
    details = [{"resource": f"i-{n}", "type": "ec2", "outcome": "skipped"} for n in range(30)]
    summary = dict(SCHEDULER_SUMMARY, dry_run=True, details=details)
    payload = handler.build_slack_payload(None, json.dumps(summary))
    assert payload["text"] == "Scheduler stop (dry run)"
    assert "…and 10 more" in text_of(payload)


def test_slack_control_characters_are_escaped():
    summary = dict(SCHEDULER_SUMMARY, details=[{"resource": "<!channel>", "outcome": "failed"}])
    body = text_of(handler.build_slack_payload(None, json.dumps(summary)))
    assert "<!channel>" not in body
    assert "&lt;!channel&gt;" in body


def test_unknown_payload_gets_generic_message():
    payload = handler.build_slack_payload("Some subject", "plain text from somewhere")
    assert payload["text"] == "Some subject"
    assert "plain text from somewhere" in text_of(payload)


def test_unknown_payload_without_subject_or_body():
    payload = handler.build_slack_payload(None, "")
    assert payload["text"] == "AWS finops notification"
    assert len(payload["blocks"]) == 1


def test_formatter_failure_falls_back_instead_of_raising():
    broken = json.dumps({"kind": "scheduler_summary", "counts": {"stopped": "many"}})
    payload = handler.build_slack_payload("subject", broken)
    assert payload["text"] == "subject"
    assert "scheduler_summary" in text_of(payload)


def test_long_messages_are_truncated_to_slack_limits():
    payload = handler.build_slack_payload("s" * 400, "x" * 10_000)
    assert len(payload["blocks"][0]["text"]["text"]) <= handler.SLACK_HEADER_LIMIT
    assert len(payload["blocks"][1]["text"]["text"]) <= handler.SLACK_SECTION_LIMIT


# --- event handling -------------------------------------------------------------


def sns_event(*messages):
    return {
        "Records": [{"Sns": {"Subject": subject, "Message": body}} for subject, body in messages]
    }


def test_extract_messages_from_sns_event():
    event = sns_event(("a", "one"), (None, "two"))
    assert handler.extract_messages(event) == [("a", "one"), (None, "two")]


def test_extract_messages_from_non_sns_event():
    [(subject, message)] = handler.extract_messages({"hello": "world"})
    assert subject is None
    assert json.loads(message) == {"hello": "world"}


# --- AWS and HTTP ---------------------------------------------------------------


@contextmanager
def stubbed_ssm(monkeypatch, *, calls=1):
    client = boto3.client("ssm", region_name="us-east-1")
    stubber = Stubber(client)
    for _ in range(calls):
        stubber.add_response(
            "get_parameter",
            {"Parameter": {"Name": PARAM_NAME, "Value": WEBHOOK_URL}},
            {"Name": PARAM_NAME, "WithDecryption": True},
        )
    monkeypatch.setitem(handler._CLIENTS, "ssm", client)
    with stubber:
        yield stubber
    stubber.assert_no_pending_responses()


def test_webhook_is_read_with_decryption_and_cached(monkeypatch):
    with stubbed_ssm(monkeypatch, calls=1):
        assert handler.get_webhook_url() == WEBHOOK_URL
        # A second SSM call would raise, because only one response is stubbed.
        assert handler.get_webhook_url() == WEBHOOK_URL


def test_post_rejects_non_https_urls():
    with pytest.raises(ValueError, match="https"):
        handler.post_to_slack("http://example.com/hook", {})


def test_post_sends_json(monkeypatch):
    seen = {}

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fake_urlopen(request, timeout):
        seen["url"] = request.full_url
        seen["body"] = json.loads(request.data)
        seen["content_type"] = request.get_header("Content-type")
        seen["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr(handler.urllib.request, "urlopen", fake_urlopen)
    assert handler.post_to_slack(WEBHOOK_URL, {"text": "hi"}) == 200
    assert seen == {
        "url": WEBHOOK_URL,
        "body": {"text": "hi"},
        "content_type": "application/json",
        "timeout": handler.HTTP_TIMEOUT_SECONDS,
    }


def test_handler_posts_each_record_and_reads_ssm_once(monkeypatch):
    posts = []
    monkeypatch.setattr(
        handler, "post_to_slack", lambda url, payload: posts.append((url, payload)) or 200
    )
    event = sns_event(("AWS Budgets: x", BUDGET_MESSAGE), (None, json.dumps(COST_REPORT)))
    with stubbed_ssm(monkeypatch, calls=1):
        assert handler.lambda_handler(event, None) == {"posted": 2}
    assert [url for url, _ in posts] == [WEBHOOK_URL, WEBHOOK_URL]
    assert posts[0][1]["text"].startswith("Budget alert")
    assert posts[1][1]["text"].startswith("Cost report")


def test_handler_raises_when_slack_post_fails(monkeypatch):
    def fail(url, payload):
        raise OSError("connection reset")

    monkeypatch.setattr(handler, "post_to_slack", fail)
    with stubbed_ssm(monkeypatch), pytest.raises(OSError):
        handler.lambda_handler(sns_event((None, "hello")), None)


def test_webhook_url_never_appears_in_logs(monkeypatch):
    lines = []

    class Capture(logging.Handler):
        def emit(self, record):
            lines.append(handler._JsonFormatter().format(record))

    capture = Capture(level=logging.DEBUG)
    handler.LOGGER.addHandler(capture)
    try:
        monkeypatch.setattr(handler, "post_to_slack", lambda url, payload: 200)
        with stubbed_ssm(monkeypatch):
            handler.lambda_handler(sns_event((None, "hello")), None)
    finally:
        handler.LOGGER.removeHandler(capture)
    assert lines
    assert all("hooks.slack.com" not in line and "not-a-real-secret" not in line for line in lines)
