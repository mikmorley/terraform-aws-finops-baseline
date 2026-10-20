"""Weekly cost report for terraform-aws-finops-baseline.

Reads Cost Explorer (and optionally the account budget), builds a summary and
publishes it to the module's SNS topic. The Slack notifier formats the JSON body
and email subscribers get plain text.

The report covers:

* Month-to-date spend, against the account budget limit when one is configured.
* A forecast of month-end spend.
* The top five services in the report period.
* The biggest change by service against the equal period before it.
* Anomalies from the last seven days that nobody has marked as a false alarm or planned.

Every Cost Explorer request costs US$0.01, so a run makes five: three
``GetCostAndUsage``, one ``GetCostForecast`` and one ``GetAnomalies``. Nothing is
cached between runs.

New accounts and the first days of a month have little or no data. Missing data
gives zeros, ``None`` or empty lists, never a division by zero or a crash.
"""

import json
import logging
import os
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

CE_REGION = "us-east-1"  # Cost Explorer and Budgets only answer here.
METRIC = "UnblendedCost"
TOP_SERVICES = 5
MAX_ANOMALIES = 10
MAX_PAGES = 3
ANOMALY_WINDOW_DAYS = 7
SNS_SUBJECT_LIMIT = 100
IGNORED_FEEDBACK = ("NO", "PLANNED_ACTIVITY")

_CLIENTS: dict[str, Any] = {}


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
    logger = logging.getLogger("cost_report")
    logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
    logger.propagate = False
    return logger


LOGGER = _configure_logging()


# --- Dates and numbers (pure) ---------------------------------------------------


def month_start(day: date) -> date:
    return day.replace(day=1)


def next_month_start(day: date) -> date:
    return (day.replace(day=28) + timedelta(days=4)).replace(day=1)


def report_periods(today: date, period_days: int) -> dict[str, tuple[date, date]]:
    """Date ranges as ``(start, end)`` with an exclusive end, the way Cost Explorer reads them.

    ``period`` is the ``period_days`` before today and ``prior`` the same length before that.
    Today is left out because its cost is still arriving.
    """
    period_start = today - timedelta(days=period_days)
    return {
        "period": (period_start, today),
        "prior": (period_start - timedelta(days=period_days), period_start),
        "month": (month_start(today), today),
        "forecast": (today, next_month_start(today)),
    }


def period_label(start: date, end: date) -> str:
    """Human label with an inclusive end date."""
    return f"{start.isoformat()} to {(end - timedelta(days=1)).isoformat()}"


def to_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def money(value: float) -> float:
    return round(value, 2)


# --- Cost Explorer parsing (pure) -----------------------------------------------


def total_from_results(results: list[dict[str, Any]]) -> float:
    """Sum the ungrouped totals of every time bucket."""
    return sum(to_float(r.get("Total", {}).get(METRIC, {}).get("Amount")) for r in results)


def services_from_results(results: list[dict[str, Any]]) -> dict[str, float]:
    """Sum the cost of each service across every time bucket."""
    totals: dict[str, float] = defaultdict(float)
    for bucket in results:
        for group in bucket.get("Groups", []):
            keys = group.get("Keys") or []
            name = keys[0] if keys else "Unknown"
            totals[name] += to_float(group.get("Metrics", {}).get(METRIC, {}).get("Amount"))
    return dict(totals)


def top_services(costs: dict[str, float], limit: int = TOP_SERVICES) -> list[dict[str, Any]]:
    """The biggest services by cost. Services with no cost or a credit are left out."""
    ranked = sorted(((n, c) for n, c in costs.items() if c > 0), key=lambda i: (-i[1], i[0]))
    return [{"service": name, "amount_usd": money(cost)} for name, cost in ranked[:limit]]


def biggest_change(current: dict[str, float], prior: dict[str, float]) -> dict[str, Any] | None:
    """The service whose cost moved most between two periods, or None if nothing moved."""
    best: tuple[str, float] | None = None
    for name in sorted(set(current) | set(prior)):
        change = current.get(name, 0.0) - prior.get(name, 0.0)
        if best is None or abs(change) > abs(best[1]):
            best = (name, change)
    if best is None or abs(best[1]) < 0.005:
        return None
    name, change = best
    before = prior.get(name, 0.0)
    pct = money(change / before * 100) if before > 0 else None
    return {"service": name, "change_usd": money(change), "change_pct": pct}


def open_anomalies(
    anomalies: list[dict[str, Any]], limit: int = MAX_ANOMALIES
) -> list[dict[str, Any]]:
    """Anomalies not marked as a false alarm or planned, biggest impact first."""
    kept = []
    for item in anomalies:
        if item.get("Feedback") in IGNORED_FEEDBACK:
            continue
        causes = item.get("RootCauses") or []
        service = (causes[0].get("Service") if causes else None) or item.get("DimensionValue")
        impact = to_float((item.get("Impact") or {}).get("TotalImpact"))
        kept.append({"service": service or "Unknown", "impact_usd": money(impact)})
    kept.sort(key=lambda i: (-i["impact_usd"], i["service"]))
    return kept[:limit]


# --- Report (pure) --------------------------------------------------------------


def build_report(
    *,
    period: str,
    month_to_date: float,
    budget_limit: float | None,
    remaining_forecast: float | None,
    current: dict[str, float],
    prior: dict[str, float],
    anomalies: list[dict[str, Any]],
    notes: list[str],
) -> dict[str, Any]:
    """The payload the Slack notifier formats (``kind`` is ``cost_report``)."""
    return {
        "kind": "cost_report",
        "period": period,
        "month_to_date_usd": money(month_to_date),
        "budget_limit_usd": money(budget_limit) if budget_limit else None,
        # Month-end forecast = spend so far + forecast for the rest of the month.
        "forecast_usd": None
        if remaining_forecast is None
        else money(month_to_date + remaining_forecast),
        "top_services": top_services(current),
        "biggest_change": biggest_change(current, prior),
        "anomalies": open_anomalies(anomalies),
        "notes": notes,
    }


def report_subject(report: dict[str, Any]) -> str:
    return f"Cost report ({report['period']})"[:SNS_SUBJECT_LIMIT]


def _usd(value: Any) -> str:
    return f"${to_float(value):,.2f}"


def report_text(report: dict[str, Any], period_days: int) -> str:
    """Plain text body for email subscribers."""
    spend = report["month_to_date_usd"]
    limit = report["budget_limit_usd"]
    line = f"Month to date: {_usd(spend)}"
    if limit:
        line += f" of {_usd(limit)} budget ({spend / limit * 100:.1f}%)"
    forecast = report["forecast_usd"]
    forecast_line = (
        f"Forecast for month end: {_usd(forecast)}"
        if forecast is not None
        else "Forecast for month end: not available yet"
    )
    lines = [report_subject(report), "", line, forecast_line, ""]

    lines.append(f"Top services ({period_days} days):")
    if report["top_services"]:
        lines += [f"- {s['service']}: {_usd(s['amount_usd'])}" for s in report["top_services"]]
    else:
        lines.append("- no spend")

    change = report["biggest_change"]
    if change:
        pct = "n/a" if change["change_pct"] is None else f"{change['change_pct']:+.1f}%"
        sign = "+" if change["change_usd"] >= 0 else "-"
        lines += [
            "",
            f"Biggest change against the previous {period_days} days: {change['service']} "
            f"{sign}{_usd(abs(change['change_usd']))} ({pct})",
        ]

    anomalies = report["anomalies"]
    lines += ["", f"Open anomalies (last {ANOMALY_WINDOW_DAYS} days): {len(anomalies)}"]
    lines += [f"- {a['service']}: {_usd(a['impact_usd'])}" for a in anomalies]

    if report["notes"]:
        lines += ["", "Notes:"] + [f"- {n}" for n in report["notes"]]
    return "\n".join(lines)


# --- AWS ------------------------------------------------------------------------


def _client(service: str) -> Any:
    """Cost Explorer and Budgets live in us-east-1. SNS is in the region the function runs in."""
    if service not in _CLIENTS:
        region = CE_REGION if service in ("ce", "budgets") else None
        _CLIENTS[service] = boto3.client(service, region_name=region)
    return _CLIENTS[service]


def _error_code(exc: Exception) -> str:
    if isinstance(exc, ClientError):
        return exc.response.get("Error", {}).get("Code", "Error")
    return type(exc).__name__


def _pages(call: Any, **kwargs: Any) -> list[dict[str, Any]]:
    """Call a Cost Explorer API and follow ``NextPageToken``, capped to bound the cost."""
    pages = []
    token = None
    for _ in range(MAX_PAGES):
        response = call(**kwargs, **({"NextPageToken": token} if token else {}))
        pages.append(response)
        token = response.get("NextPageToken")
        if not token:
            break
    return pages


def _time_period(start: date, end: date) -> dict[str, str]:
    return {"Start": start.isoformat(), "End": end.isoformat()}


def _no_data(exc: ClientError) -> bool:
    return _error_code(exc) == "DataUnavailableException"


def fetch_total(ce: Any, start: date, end: date) -> float:
    """Total spend for a range. An empty range (the first of the month) costs nothing."""
    if start >= end:
        return 0.0
    try:
        pages = _pages(
            ce.get_cost_and_usage,
            TimePeriod=_time_period(start, end),
            Granularity="MONTHLY",
            Metrics=[METRIC],
        )
    except ClientError as exc:
        if _no_data(exc):
            return 0.0
        raise
    return sum(total_from_results(p.get("ResultsByTime", [])) for p in pages)


def fetch_services(ce: Any, start: date, end: date) -> dict[str, float]:
    if start >= end:
        return {}
    try:
        pages = _pages(
            ce.get_cost_and_usage,
            TimePeriod=_time_period(start, end),
            Granularity="MONTHLY",
            Metrics=[METRIC],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as exc:
        if _no_data(exc):
            return {}
        raise
    merged: dict[str, float] = defaultdict(float)
    for page in pages:
        for name, cost in services_from_results(page.get("ResultsByTime", [])).items():
            merged[name] += cost
    return dict(merged)


def fetch_forecast(ce: Any, start: date, end: date) -> float:
    """Forecast for the rest of the month. Raises ``ClientError`` when AWS has too little data."""
    response = ce.get_cost_forecast(
        TimePeriod=_time_period(start, end),
        Metric="UNBLENDED_COST",
        Granularity="MONTHLY",
    )
    return to_float((response.get("Total") or {}).get("Amount"))


def fetch_anomalies(ce: Any, today: date) -> list[dict[str, Any]]:
    window_start = today - timedelta(days=ANOMALY_WINDOW_DAYS)
    pages = _pages(
        ce.get_anomalies,
        DateInterval={"StartDate": window_start.isoformat(), "EndDate": today.isoformat()},
    )
    return [a for p in pages for a in p.get("Anomalies", [])]


def fetch_budget_limit(budgets: Any, account_id: str, name: str) -> float:
    response = budgets.describe_budget(AccountId=account_id, BudgetName=name)
    return to_float(response["Budget"]["BudgetLimit"]["Amount"])


def collect(
    ce: Any,
    budgets: Any,
    today: date,
    period_days: int,
    account_id: str | None,
    budget_name: str | None,
) -> dict[str, Any]:
    """Run every query. Usage queries must succeed. Forecast, anomalies and budget may not."""
    ranges = report_periods(today, period_days)
    notes: list[str] = []

    month_to_date = fetch_total(ce, *ranges["month"])
    current = fetch_services(ce, *ranges["period"])
    prior = fetch_services(ce, *ranges["prior"])

    remaining_forecast = None
    try:
        remaining_forecast = fetch_forecast(ce, *ranges["forecast"])
    except (ClientError, BotoCoreError) as exc:
        LOGGER.info("no forecast", extra={"fields": {"reason": _error_code(exc)}})
        notes.append("The forecast is not available yet. AWS needs more spend history.")

    anomalies: list[dict[str, Any]] = []
    try:
        anomalies = fetch_anomalies(ce, today)
    except (ClientError, BotoCoreError) as exc:
        LOGGER.warning("anomalies failed", extra={"fields": {"reason": _error_code(exc)}})
        notes.append(f"Anomalies could not be read ({_error_code(exc)}).")

    budget_limit = None
    if account_id and budget_name:
        try:
            budget_limit = fetch_budget_limit(budgets, account_id, budget_name)
        except (ClientError, BotoCoreError, KeyError) as exc:
            LOGGER.warning("budget failed", extra={"fields": {"reason": _error_code(exc)}})
            notes.append(f"The budget limit could not be read ({_error_code(exc)}).")

    return build_report(
        period=period_label(*ranges["period"]),
        month_to_date=month_to_date,
        budget_limit=budget_limit,
        remaining_forecast=remaining_forecast,
        current=current,
        prior=prior,
        anomalies=anomalies,
        notes=notes,
    )


def publish_report(report: dict[str, Any], period_days: int, topic_arn: str | None) -> bool:
    """Publish JSON for the Slack notifier and text for email. A failed publish raises."""
    if not topic_arn:
        return False
    message = {"default": json.dumps(report), "email": report_text(report, period_days)}
    _client("sns").publish(
        TopicArn=topic_arn,
        Subject=report_subject(report),
        Message=json.dumps(message),
        MessageStructure="json",
    )
    return True


# --- Entry point ----------------------------------------------------------------


def _today() -> date:
    return datetime.now(UTC).date()


def lambda_handler(event: Any, context: Any) -> dict[str, Any]:
    today = _today()
    period_days = int(os.environ.get("PERIOD_DAYS", "7"))
    report = collect(
        _client("ce"),
        _client("budgets"),
        today,
        period_days,
        os.environ.get("ACCOUNT_ID"),
        os.environ.get("BUDGET_NAME"),
    )
    published = publish_report(report, period_days, os.environ.get("SNS_TOPIC_ARN"))
    LOGGER.info(
        "report finished",
        extra={"fields": {"period": report["period"], "published": published}},
    )
    return {**report, "published": published}
