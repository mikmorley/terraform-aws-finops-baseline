"""Slack notifier for terraform-aws-finops-baseline.

Subscribed to the module's SNS topic. For every SNS record it works out what kind
of message arrived, formats it for Slack and posts it to an incoming webhook.

Recognised messages:

* AWS Budgets notifications (plain text).
* Cost Anomaly Detection notifications (JSON, top level or under ``detail``).
* Cost report payloads published by this module (JSON, ``{"kind": "cost_report"}``).
* Scheduler summaries published by this module (JSON, ``{"kind": "scheduler_summary"}``).

Anything else gets a generic message with the raw text. Formatting never raises, so
an unexpected payload still reaches Slack. Failing to post does raise, so SNS retries.

The webhook URL is a secret. It is read from an SSM SecureString at runtime, cached
per container, and never logged.
"""

import json
import logging
import os
import re
import urllib.request
from typing import Any

import boto3

BUDGET = "budget"
ANOMALY = "anomaly"
COST_REPORT = "cost_report"
SCHEDULER_SUMMARY = "scheduler_summary"
UNKNOWN = "unknown"

HTTP_TIMEOUT_SECONDS = 5
SLACK_HEADER_LIMIT = 150
SLACK_SECTION_LIMIT = 2800
MAX_DETAIL_LINES = 20

_BUDGET_FIELD = re.compile(
    r"^\s*(Budget Name|Budget Type|Budgeted Amount|Alert Type|Alert Threshold"
    r"|ACTUAL Amount|FORECASTED Amount):\s*(.+?)\s*$",
    re.MULTILINE,
)

_CLIENTS: dict[str, Any] = {}
_WEBHOOK_CACHE: dict[str, str] = {}


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        extra = getattr(record, "fields", None)
        if extra:
            entry.update(extra)
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def _configure_logging() -> logging.Logger:
    logger = logging.getLogger("slack_notifier")
    logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
    logger.propagate = False
    return logger


LOGGER = _configure_logging()


# --- Classification -------------------------------------------------------------


def classify(message: str, subject: str | None = None) -> tuple[str, Any]:
    """Return ``(kind, parsed)`` for an SNS message body."""
    stripped = message.strip()
    if stripped.startswith("{"):
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError:
            payload = None
        if isinstance(payload, dict):
            kind = payload.get("kind")
            if kind == COST_REPORT:
                return COST_REPORT, payload
            if kind == SCHEDULER_SUMMARY:
                return SCHEDULER_SUMMARY, payload
            anomaly = _unwrap_anomaly(payload)
            if anomaly is not None:
                return ANOMALY, anomaly
        return UNKNOWN, payload

    budget = parse_budget_message(message)
    if budget.get("budget_name") or (subject or "").startswith("AWS Budgets"):
        return BUDGET, budget
    return UNKNOWN, None


def _unwrap_anomaly(payload: dict[str, Any]) -> dict[str, Any] | None:
    if "anomalyId" in payload:
        return payload
    detail = payload.get("detail")
    if isinstance(detail, dict) and "anomalyId" in detail:
        return detail
    return None


def parse_budget_message(message: str) -> dict[str, str]:
    """Pull the labelled fields out of an AWS Budgets notification."""
    fields = dict(_BUDGET_FIELD.findall(message))
    result = {
        "budget_name": fields.get("Budget Name", ""),
        "budget_type": fields.get("Budget Type", ""),
        "budgeted_amount": fields.get("Budgeted Amount", ""),
        "alert_type": fields.get("Alert Type", ""),
        "alert_threshold": fields.get("Alert Threshold", ""),
        "amount": fields.get("ACTUAL Amount") or fields.get("FORECASTED Amount", ""),
    }
    account = re.search(r"AWS Account\s+(\d{12})", message)
    result["account_id"] = account.group(1) if account else ""
    return result


# --- Formatting -----------------------------------------------------------------


def _escape(text: Any) -> str:
    """Escape the three characters Slack treats as control characters."""
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _money(value: Any) -> str:
    try:
        return f"${float(value):,.2f}"
    except (TypeError, ValueError):
        return "n/a"


def _percent(value: Any) -> str:
    try:
        return f"{float(value):.1f}%"
    except (TypeError, ValueError):
        return "n/a"


def _slack_payload(title: str, lines: list[str]) -> dict[str, Any]:
    body = "\n".join(lines)[:SLACK_SECTION_LIMIT]
    blocks: list[dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": title[:SLACK_HEADER_LIMIT]}}
    ]
    if body:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": body}})
    return {"text": title, "blocks": blocks}


def format_budget(budget: dict[str, str]) -> dict[str, Any]:
    name = budget.get("budget_name") or "unknown budget"
    lines = []
    if budget.get("alert_type"):
        lines.append(f"*Alert type:* {_escape(budget['alert_type'])}")
    if budget.get("alert_threshold"):
        lines.append(f"*Threshold:* {_escape(budget['alert_threshold'])}")
    if budget.get("amount"):
        lines.append(f"*Amount:* {_escape(budget['amount'])}")
    if budget.get("budgeted_amount"):
        lines.append(f"*Budgeted:* {_escape(budget['budgeted_amount'])}")
    if budget.get("account_id"):
        lines.append(f"*Account:* {_escape(budget['account_id'])}")
    return _slack_payload(f"Budget alert: {name}", lines)


def format_anomaly(anomaly: dict[str, Any]) -> dict[str, Any]:
    impact = anomaly.get("impact") or {}
    service = anomaly.get("dimensionValue") or "unknown service"
    lines = [
        f"*Total impact:* {_money(impact.get('totalImpact'))} "
        f"({_percent(impact.get('totalImpactPercentage'))})",
        f"*Actual vs expected:* {_money(impact.get('totalActualSpend'))} "
        f"vs {_money(impact.get('totalExpectedSpend'))}",
    ]
    if anomaly.get("anomalyStartDate"):
        lines.append(f"*Started:* {_escape(anomaly['anomalyStartDate'])}")
    for cause in (anomaly.get("rootCauses") or [])[:5]:
        parts = [cause.get(key) for key in ("service", "region", "usageType") if cause.get(key)]
        if parts:
            lines.append("• " + _escape(" / ".join(parts)))
    link = anomaly.get("anomalyDetailsLink")
    if isinstance(link, str) and link.startswith("https://"):
        lines.append(f"<{link}|View in the AWS console>")
    return _slack_payload(f"Cost anomaly: {service}", lines)


def format_cost_report(report: dict[str, Any]) -> dict[str, Any]:
    spend = report.get("month_to_date_usd")
    limit = report.get("budget_limit_usd")
    spend_line = f"*Month to date:* {_money(spend)}"
    try:
        if float(limit) > 0:
            share = float(spend) / float(limit) * 100
            spend_line += f" of {_money(limit)} budget ({_percent(share)})"
    except (TypeError, ValueError):
        pass
    forecast = report.get("forecast_usd")
    forecast_line = (
        f"*Forecast for month end:* {_money(forecast)}"
        if forecast is not None
        else "*Forecast for month end:* not available yet"
    )
    lines = [spend_line, forecast_line]

    services = report.get("top_services") or []
    if services:
        lines.append("*Top services*")
        for item in services[:5]:
            lines.append(
                f"• {_escape(item.get('service', 'unknown'))}: {_money(item.get('amount_usd'))}"
            )

    change = report.get("biggest_change")
    if isinstance(change, dict) and change.get("service"):
        lines.append(
            f"*Biggest change:* {_escape(change['service'])} "
            f"{_signed_money(change.get('change_usd'))} "
            f"({_signed_percent(change.get('change_pct'))})"
        )

    anomalies = report.get("anomalies") or []
    lines.append(f"*Open anomalies (last 7 days):* {len(anomalies)}")
    for item in anomalies[:5]:
        lines.append(
            f"• {_escape(item.get('service', 'unknown'))}: {_money(item.get('impact_usd'))}"
        )
    period = report.get("period") or "weekly"
    return _slack_payload(f"Cost report ({_escape(period)})", lines)


def _signed_money(value: Any) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "n/a"
    sign = "+" if number >= 0 else "-"
    return f"{sign}${abs(number):,.2f}"


def _signed_percent(value: Any) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "n/a"
    return f"{number:+.1f}%"


def format_scheduler_summary(summary: dict[str, Any]) -> dict[str, Any]:
    action = summary.get("action", "run")
    dry_run = bool(summary.get("dry_run"))
    counts = summary.get("counts") or {}
    title = f"Scheduler {action}" + (" (dry run)" if dry_run else "")
    totals = {
        key: int(counts.get(key, 0) or 0) for key in ("stopped", "started", "skipped", "failed")
    }
    lines = [" ".join(f"*{key.capitalize()}:* {value}" for key, value in totals.items())]
    details = [d for d in summary.get("details") or [] if d.get("outcome") in ("skipped", "failed")]
    for item in details[:MAX_DETAIL_LINES]:
        reason = f": {_escape(item['reason'])}" if item.get("reason") else ""
        lines.append(
            f"• {_escape(item.get('outcome', ''))} {_escape(item.get('type', ''))} "
            f"{_escape(item.get('resource', 'unknown'))}{reason}"
        )
    if len(details) > MAX_DETAIL_LINES:
        lines.append(f"…and {len(details) - MAX_DETAIL_LINES} more")
    return _slack_payload(title, lines)


def format_unknown(message: str, subject: str | None) -> dict[str, Any]:
    title = subject or "AWS finops notification"
    body = _escape(message.strip())[: SLACK_SECTION_LIMIT - 10]
    return _slack_payload(title, [f"```{body}```"] if body else [])


def build_slack_payload(subject: str | None, message: str) -> dict[str, Any]:
    """Format one SNS message. Never raises: any failure falls back to the raw text."""
    try:
        kind, parsed = classify(message, subject)
        if kind == BUDGET:
            return format_budget(parsed)
        if kind == ANOMALY:
            return format_anomaly(parsed)
        if kind == COST_REPORT:
            return format_cost_report(parsed)
        if kind == SCHEDULER_SUMMARY:
            return format_scheduler_summary(parsed)
    except Exception:  # noqa: BLE001 - a bad payload must still reach Slack
        LOGGER.exception("formatting failed, sending generic message")
    return format_unknown(message, subject)


def extract_messages(event: Any) -> list[tuple[str | None, str]]:
    """Return ``(subject, message)`` pairs from an SNS event, or the raw event."""
    records = event.get("Records") if isinstance(event, dict) else None
    messages = []
    for record in records or []:
        sns = record.get("Sns") if isinstance(record, dict) else None
        if isinstance(sns, dict):
            messages.append((sns.get("Subject"), str(sns.get("Message", ""))))
    if messages:
        return messages
    return [(None, json.dumps(event, default=str))]


# --- AWS and HTTP ---------------------------------------------------------------


def _ssm_client() -> Any:
    if "ssm" not in _CLIENTS:
        _CLIENTS["ssm"] = boto3.client("ssm")
    return _CLIENTS["ssm"]


def get_webhook_url() -> str:
    """Read the webhook from SSM once per container."""
    name = os.environ["SLACK_WEBHOOK_SSM_PARAM"]
    if name not in _WEBHOOK_CACHE:
        response = _ssm_client().get_parameter(Name=name, WithDecryption=True)
        _WEBHOOK_CACHE[name] = response["Parameter"]["Value"]
    return _WEBHOOK_CACHE[name]


def post_to_slack(url: str, payload: dict[str, Any]) -> int:
    """POST the payload and return the HTTP status. Never logs the URL."""
    if not url.startswith("https://"):
        raise ValueError("the Slack webhook URL must start with https://")
    request = urllib.request.Request(  # noqa: S310 - scheme checked above
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:  # noqa: S310
        return response.status


def lambda_handler(event: Any, context: Any) -> dict[str, int]:
    posted = 0
    webhook = None
    for subject, message in extract_messages(event):
        payload = build_slack_payload(subject, message)
        if webhook is None:
            webhook = get_webhook_url()
        status = post_to_slack(webhook, payload)
        posted += 1
        LOGGER.info("posted to Slack", extra={"fields": {"status": status}})
    return {"posted": posted}
