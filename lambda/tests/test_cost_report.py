import json
from datetime import date

import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

from cost_report import handler
from slack_notifier import handler as slack_handler

TOPIC_ARN = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
MONDAY = date(2026, 10, 19)


@pytest.fixture(autouse=True)
def _reset_state(monkeypatch):
    handler._CLIENTS.clear()
    for name in ("SNS_TOPIC_ARN", "ACCOUNT_ID", "BUDGET_NAME", "PERIOD_DAYS"):
        monkeypatch.delenv(name, raising=False)
    yield
    handler._CLIENTS.clear()


def client_error(code="AccessDeniedException", message="no"):
    return ClientError({"Error": {"Code": code, "Message": message}}, "Operation")


def total_bucket(amount):
    return {"Total": {"UnblendedCost": {"Amount": str(amount), "Unit": "USD"}}}


def group_bucket(**services):
    return {
        "Groups": [
            {"Keys": [name], "Metrics": {"UnblendedCost": {"Amount": str(amount), "Unit": "USD"}}}
            for name, amount in services.items()
        ]
    }


# --- Dates ----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("day", "expected"),
    [
        (date(2026, 10, 19), date(2026, 11, 1)),
        (date(2026, 12, 31), date(2027, 1, 1)),
        (date(2028, 2, 29), date(2028, 3, 1)),
        (date(2026, 1, 1), date(2026, 2, 1)),
    ],
)
def test_next_month_start(day, expected):
    assert handler.next_month_start(day) == expected
    assert handler.month_start(day) == day.replace(day=1)


def test_report_periods_for_a_monday():
    ranges = handler.report_periods(MONDAY, 7)
    assert ranges["period"] == (date(2026, 10, 12), date(2026, 10, 19))
    assert ranges["prior"] == (date(2026, 10, 5), date(2026, 10, 12))
    assert ranges["month"] == (date(2026, 10, 1), date(2026, 10, 19))
    assert ranges["forecast"] == (date(2026, 10, 19), date(2026, 11, 1))


def test_period_label_has_an_inclusive_end():
    assert handler.period_label(date(2026, 10, 12), date(2026, 10, 19)) == (
        "2026-10-12 to 2026-10-18"
    )


# --- Parsing --------------------------------------------------------------------


def test_totals_sum_across_buckets_and_ignore_missing_fields():
    results = [total_bucket("10.50"), total_bucket("4.25"), {}, {"Total": {}}]
    assert handler.total_from_results(results) == pytest.approx(14.75)
    assert handler.total_from_results([]) == 0.0


def test_services_sum_across_buckets():
    results = [group_bucket(EC2=10, S3=1), group_bucket(EC2=5), {"Groups": [{"Keys": []}]}]
    assert handler.services_from_results(results) == {"EC2": 15.0, "S3": 1.0, "Unknown": 0.0}


def test_top_services_orders_limits_and_drops_credits():
    costs = {"A": 5, "B": 50, "C": 5, "D": 1, "E": 2, "F": 3, "Credit": -4, "Zero": 0}
    top = handler.top_services(costs)
    assert [s["service"] for s in top] == ["B", "A", "C", "F", "E"]
    assert top[0] == {"service": "B", "amount_usd": 50.0}
    assert handler.top_services({}) == []


def test_biggest_change_picks_the_largest_move_either_way():
    result = handler.biggest_change({"EC2": 30, "RDS": 10}, {"EC2": 20, "RDS": 25})
    assert result == {"service": "RDS", "change_usd": -15.0, "change_pct": -60.0}
    up = handler.biggest_change({"EC2": 30}, {"EC2": 20})
    assert up == {"service": "EC2", "change_usd": 10.0, "change_pct": 50.0}


def test_biggest_change_for_a_new_service_has_no_percentage():
    result = handler.biggest_change({"Lambda": 12}, {})
    assert result == {"service": "Lambda", "change_usd": 12.0, "change_pct": None}


def test_biggest_change_is_none_when_nothing_moved():
    assert handler.biggest_change({}, {}) is None
    assert handler.biggest_change({"EC2": 10}, {"EC2": 10}) is None


def test_open_anomalies_skip_reviewed_ones_and_sort_by_impact():
    anomalies = [
        {"Impact": {"TotalImpact": 5}, "RootCauses": [{"Service": "S3"}]},
        {"Impact": {"TotalImpact": 50}, "RootCauses": [{"Service": "EC2"}], "Feedback": "YES"},
        {"Impact": {"TotalImpact": 99}, "RootCauses": [{"Service": "RDS"}], "Feedback": "NO"},
        {"Impact": {"TotalImpact": 80}, "DimensionValue": "Lambda", "Feedback": "PLANNED_ACTIVITY"},
        {"Impact": {"TotalImpact": 7}, "DimensionValue": "Athena"},
        {"Impact": {}, "RootCauses": []},
    ]
    result = handler.open_anomalies(anomalies)
    assert [(a["service"], a["impact_usd"]) for a in result] == [
        ("EC2", 50.0),
        ("Athena", 7.0),
        ("S3", 5.0),
        ("Unknown", 0.0),
    ]


# --- Report ---------------------------------------------------------------------


def make_report(**overrides):
    args = {
        "period": "2026-10-12 to 2026-10-18",
        "month_to_date": 42.1,
        "budget_limit": 100,
        "remaining_forecast": 55.3,
        "current": {"EC2": 20, "S3": 2},
        "prior": {"EC2": 10, "S3": 2},
        "anomalies": [{"Impact": {"TotalImpact": 15}, "RootCauses": [{"Service": "EC2"}]}],
        "notes": [],
    }
    args.update(overrides)
    return handler.build_report(**args)


def test_report_adds_spend_so_far_to_the_remaining_forecast():
    report = make_report()
    assert report["kind"] == "cost_report"
    assert report["month_to_date_usd"] == 42.1
    assert report["forecast_usd"] == 97.4
    assert report["budget_limit_usd"] == 100.0
    assert report["biggest_change"] == {"service": "EC2", "change_usd": 10.0, "change_pct": 100.0}
    assert report["anomalies"] == [{"service": "EC2", "impact_usd": 15.0}]


def test_report_without_forecast_or_budget_uses_none():
    report = make_report(remaining_forecast=None, budget_limit=None)
    assert report["forecast_usd"] is None
    assert report["budget_limit_usd"] is None
    assert make_report(budget_limit=0)["budget_limit_usd"] is None


def test_report_for_an_account_with_no_data():
    report = make_report(
        month_to_date=0,
        budget_limit=100,
        remaining_forecast=None,
        current={},
        prior={},
        anomalies=[],
    )
    assert report["month_to_date_usd"] == 0.0
    assert report["top_services"] == []
    assert report["biggest_change"] is None
    text = handler.report_text(report, 7)
    assert "Month to date: $0.00 of $100.00 budget (0.0%)" in text
    assert "not available yet" in text
    assert "- no spend" in text
    assert "Open anomalies (last 7 days): 0" in text


def test_report_text_has_every_section():
    text = handler.report_text(make_report(notes=["something to know"]), 7)
    assert "Cost report (2026-10-12 to 2026-10-18)" in text
    assert "Month to date: $42.10 of $100.00 budget (42.1%)" in text
    assert "Forecast for month end: $97.40" in text
    assert "- EC2: $20.00" in text
    assert "Biggest change against the previous 7 days: EC2 +$10.00 (+100.0%)" in text
    assert "- EC2: $15.00" in text
    assert "- something to know" in text


def test_report_text_handles_a_decrease_with_no_percentage():
    report = make_report(current={}, prior={"RDS": 8})
    text = handler.report_text(report, 7)
    assert "RDS -$8.00 (-100.0%)" in text
    new = handler.report_text(make_report(current={"Lambda": 3}, prior={}), 7)
    assert "Lambda +$3.00 (n/a)" in new


def test_slack_notifier_formats_the_report_not_the_fallback():
    payload = slack_handler.build_slack_payload(None, json.dumps(make_report()))
    text = json.dumps(payload)
    assert "Cost report (2026-10-12 to 2026-10-18)" in text
    assert "Month to date" in text
    assert "42.10" in text
    assert "Top services" in text
    assert "Open anomalies" in text


# --- Collecting -----------------------------------------------------------------


class FakeCE:
    """Answers by call type. Records every request so cost can be counted."""

    def __init__(self, usage=None, forecast=None, anomalies=None, usage_error=None):
        self.usage = usage or {}
        self.forecast = forecast
        self.anomalies = anomalies if anomalies is not None else [{"Anomalies": []}]
        self.usage_error = usage_error
        self.calls = []

    def get_cost_and_usage(self, **kwargs):
        self.calls.append(("usage", kwargs))
        if self.usage_error:
            raise self.usage_error
        key = (kwargs["TimePeriod"]["Start"], "GroupBy" in kwargs)
        return self.usage.get(key, {"ResultsByTime": []})

    def get_cost_forecast(self, **kwargs):
        self.calls.append(("forecast", kwargs))
        if isinstance(self.forecast, Exception):
            raise self.forecast
        return self.forecast or {"Total": {"Amount": "0"}}

    def get_anomalies(self, **kwargs):
        self.calls.append(("anomalies", kwargs))
        if isinstance(self.anomalies, Exception):
            raise self.anomalies
        index = sum(1 for c in self.calls if c[0] == "anomalies") - 1
        return self.anomalies[min(index, len(self.anomalies) - 1)]


class FakeBudgets:
    def __init__(self, amount="100.0", error=None):
        self.amount = amount
        self.error = error
        self.calls = []

    def describe_budget(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        return {"Budget": {"BudgetLimit": {"Amount": self.amount, "Unit": "USD"}}}


def normal_usage():
    return {
        ("2026-10-01", False): {"ResultsByTime": [total_bucket("42.10")]},
        ("2026-10-12", True): {"ResultsByTime": [group_bucket(EC2=20, S3=2)]},
        ("2026-10-05", True): {"ResultsByTime": [group_bucket(EC2=10, S3=2)]},
    }


def test_collect_makes_five_cost_explorer_requests():
    ce = FakeCE(usage=normal_usage(), forecast={"Total": {"Amount": "55.30"}})
    report = handler.collect(ce, FakeBudgets(), MONDAY, 7, "123456789012", "finops-account")
    assert [c[0] for c in ce.calls] == ["usage", "usage", "usage", "forecast", "anomalies"]
    assert report["month_to_date_usd"] == 42.1
    assert report["forecast_usd"] == 97.4
    assert report["budget_limit_usd"] == 100.0
    assert report["notes"] == []
    forecast_call = ce.calls[3][1]
    assert forecast_call["TimePeriod"] == {"Start": "2026-10-19", "End": "2026-11-01"}


def test_collect_on_the_first_of_the_month_skips_the_empty_range():
    first = date(2026, 11, 2)  # month to date covers only the 1st, so it is not empty
    ce = FakeCE()
    handler.collect(ce, FakeBudgets(), first, 7, None, None)
    assert len([c for c in ce.calls if c[0] == "usage"]) == 3
    day_one = date(2026, 11, 1)  # month to date is empty, so no request is made for it
    ce = FakeCE()
    report = handler.collect(ce, FakeBudgets(), day_one, 7, None, None)
    assert len([c for c in ce.calls if c[0] == "usage"]) == 2
    assert report["month_to_date_usd"] == 0.0


def test_collect_for_a_new_account_gives_an_empty_report():
    ce = FakeCE(
        usage_error=client_error("DataUnavailableException", "no data"),
        forecast=client_error("DataUnavailableException", "not enough data"),
    )
    report = handler.collect(ce, FakeBudgets(), MONDAY, 7, None, None)
    assert report["month_to_date_usd"] == 0.0
    assert report["forecast_usd"] is None
    assert report["top_services"] == []
    assert report["biggest_change"] is None
    assert report["anomalies"] == []
    assert any("forecast" in n for n in report["notes"])


def test_collect_lets_other_usage_errors_through():
    ce = FakeCE(usage_error=client_error("AccessDeniedException", "no permission"))
    with pytest.raises(ClientError):
        handler.collect(ce, FakeBudgets(), MONDAY, 7, None, None)


def test_collect_notes_an_anomaly_failure_and_a_budget_failure():
    ce = FakeCE(usage=normal_usage(), anomalies=client_error("AccessDeniedException"))
    budgets = FakeBudgets(error=client_error("NotFoundException"))
    report = handler.collect(ce, budgets, MONDAY, 7, "123456789012", "finops-account")
    assert report["anomalies"] == []
    assert report["budget_limit_usd"] is None
    assert any("Anomalies could not be read (AccessDeniedException)" in n for n in report["notes"])
    assert any("budget limit could not be read (NotFoundException)" in n for n in report["notes"])


def test_collect_skips_the_budget_call_without_a_name():
    budgets = FakeBudgets()
    handler.collect(FakeCE(), budgets, MONDAY, 7, None, None)
    handler.collect(FakeCE(), budgets, MONDAY, 7, "123456789012", None)
    assert budgets.calls == []


def test_pages_follow_next_token_and_stop_at_the_cap():
    calls = []

    def call(**kwargs):
        calls.append(kwargs.get("NextPageToken"))
        return {"NextPageToken": f"t{len(calls)}", "Items": len(calls)}

    pages = handler._pages(call, A=1)
    assert len(pages) == handler.MAX_PAGES
    assert calls == [None, "t1", "t2"]


def test_anomalies_use_all_pages():
    ce = FakeCE(
        anomalies=[
            {"Anomalies": [{"Impact": {"TotalImpact": 1}}], "NextPageToken": "next"},
            {"Anomalies": [{"Impact": {"TotalImpact": 2}}]},
        ]
    )
    assert len(handler.fetch_anomalies(ce, MONDAY)) == 2


# --- Request and response shapes, checked against the real service model --------


def test_requests_and_responses_match_the_boto3_model():
    ce = boto3.client("ce", region_name="us-east-1")
    budgets = boto3.client("budgets", region_name="us-east-1")
    period = {"Start": "2026-10-12", "End": "2026-10-19"}
    prior = {"Start": "2026-10-05", "End": "2026-10-12"}
    month_period = {"Start": "2026-10-01", "End": "2026-10-19"}
    group_by = [{"Type": "DIMENSION", "Key": "SERVICE"}]
    with Stubber(ce) as ce_stub, Stubber(budgets) as budget_stub:
        ce_stub.add_response(
            "get_cost_and_usage",
            {
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2026-10-01", "End": "2026-10-19"},
                        **total_bucket(42.1),
                    }
                ]
            },
            {
                "TimePeriod": month_period,
                "Granularity": "MONTHLY",
                "Metrics": ["UnblendedCost"],
            },
        )
        for time_period, services in ((period, {"EC2": 20}), (prior, {"EC2": 10})):
            ce_stub.add_response(
                "get_cost_and_usage",
                {"ResultsByTime": [{"TimePeriod": time_period, **group_bucket(**services)}]},
                {
                    "TimePeriod": time_period,
                    "Granularity": "MONTHLY",
                    "Metrics": ["UnblendedCost"],
                    "GroupBy": group_by,
                },
            )
        ce_stub.add_response(
            "get_cost_forecast",
            {"Total": {"Amount": "55.3", "Unit": "USD"}},
            {
                "TimePeriod": {"Start": "2026-10-19", "End": "2026-11-01"},
                "Metric": "UNBLENDED_COST",
                "Granularity": "MONTHLY",
            },
        )
        ce_stub.add_response(
            "get_anomalies",
            {
                "Anomalies": [
                    {
                        "AnomalyId": "a-1",
                        "AnomalyScore": {"MaxScore": 1.0, "CurrentScore": 1.0},
                        "Impact": {"MaxImpact": 15.0, "TotalImpact": 15.0},
                        "MonitorArn": "arn:aws:ce::123456789012:anomalymonitor/abc",
                        "RootCauses": [{"Service": "Amazon EC2"}],
                    }
                ]
            },
            {"DateInterval": {"StartDate": "2026-10-12", "EndDate": "2026-10-19"}},
        )
        budget_stub.add_response(
            "describe_budget",
            {
                "Budget": {
                    "BudgetName": "finops-account",
                    "TimeUnit": "MONTHLY",
                    "BudgetType": "COST",
                    "BudgetLimit": {"Amount": "100.0", "Unit": "USD"},
                }
            },
            {"AccountId": "123456789012", "BudgetName": "finops-account"},
        )
        report = handler.collect(ce, budgets, MONDAY, 7, "123456789012", "finops-account")
        ce_stub.assert_no_pending_responses()
        budget_stub.assert_no_pending_responses()
    assert report["forecast_usd"] == 97.4
    assert report["budget_limit_usd"] == 100.0
    assert report["anomalies"] == [{"service": "Amazon EC2", "impact_usd": 15.0}]
    assert report["biggest_change"]["service"] == "EC2"


# --- Publishing and entry point -------------------------------------------------


class Recorder:
    def __init__(self, error=None):
        self.sent = []
        self.error = error

    def publish(self, **kwargs):
        if self.error:
            raise self.error
        self.sent.append(kwargs)


def test_publish_sends_json_for_lambda_and_text_for_email(monkeypatch):
    sns = Recorder()
    monkeypatch.setitem(handler._CLIENTS, "sns", sns)
    report = make_report()
    assert handler.publish_report(report, 7, TOPIC_ARN) is True
    sent = sns.sent[0]
    assert sent["TopicArn"] == TOPIC_ARN
    assert sent["MessageStructure"] == "json"
    assert sent["Subject"] == "Cost report (2026-10-12 to 2026-10-18)"
    body = json.loads(sent["Message"])
    assert json.loads(body["default"])["kind"] == "cost_report"
    assert "Forecast for month end: $97.40" in body["email"]


def test_publish_without_a_topic_does_nothing():
    assert handler.publish_report(make_report(), 7, None) is False
    assert handler.publish_report(make_report(), 7, "") is False


def test_a_failed_publish_raises_so_the_run_is_retried(monkeypatch):
    monkeypatch.setitem(handler._CLIENTS, "sns", Recorder(error=client_error("AuthorizationError")))
    with pytest.raises(ClientError):
        handler.publish_report(make_report(), 7, TOPIC_ARN)


def test_sns_uses_the_function_region_and_cost_explorer_stays_in_us_east_1(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-southeast-2")
    assert handler._client("sns").meta.endpoint_url == "https://sns.ap-southeast-2.amazonaws.com"
    assert handler._client("ce").meta.endpoint_url == "https://ce.us-east-1.amazonaws.com"
    assert handler._client("budgets").meta.endpoint_url == "https://budgets.amazonaws.com"


def test_lambda_handler_runs_end_to_end(monkeypatch):
    monkeypatch.setenv("SNS_TOPIC_ARN", TOPIC_ARN)
    monkeypatch.setenv("ACCOUNT_ID", "123456789012")
    monkeypatch.setenv("BUDGET_NAME", "finops-account")
    monkeypatch.setattr(handler, "_today", lambda: MONDAY)
    sns = Recorder()
    monkeypatch.setitem(handler._CLIENTS, "sns", sns)
    monkeypatch.setitem(handler._CLIENTS, "budgets", FakeBudgets())
    monkeypatch.setitem(
        handler._CLIENTS,
        "ce",
        FakeCE(usage=normal_usage(), forecast={"Total": {"Amount": "55.30"}}),
    )
    result = handler.lambda_handler({}, None)
    assert result["published"] is True
    assert result["period"] == "2026-10-12 to 2026-10-18"
    assert len(sns.sent) == 1


def test_period_days_comes_from_the_environment(monkeypatch):
    monkeypatch.setenv("PERIOD_DAYS", "14")
    monkeypatch.setattr(handler, "_today", lambda: MONDAY)
    monkeypatch.setitem(handler._CLIENTS, "budgets", FakeBudgets())
    monkeypatch.setitem(handler._CLIENTS, "ce", FakeCE())
    result = handler.lambda_handler({}, None)
    assert result["period"] == "2026-10-05 to 2026-10-18"
