"""Dev resource scheduler for terraform-aws-finops-baseline.

Stops and starts EC2 instances, RDS instances and Aurora clusters that carry a
tag, then publishes a summary to the module's SNS topic.

Two kinds of event start it:

* EventBridge Scheduler sends ``{"action": "stop" | "start", "dry_run": bool}``.
* An SNS record (a budget notification) means ``stop``. The message body is not read.

Resources that AWS cannot stop, or that stopping would break, are skipped and
reported with a reason: instances in an Auto Scaling group, spot instances,
instance store instances, RDS members of a cluster, read replicas, instances
with replicas, Aurora replica clusters and Aurora Serverless v1 clusters.
One resource failing never stops the run. With ``dry_run`` the function reads and
reports but changes nothing.
"""

import json
import logging
import os
from collections.abc import Callable
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

STOP = "stop"
START = "start"
ACTIONS = (STOP, START)

STOPPED = "stopped"
STARTED = "started"
SKIPPED = "skipped"
FAILED = "failed"
OUTCOMES = (STOPPED, STARTED, SKIPPED, FAILED)

EC2 = "ec2"
RDS = "rds"
AURORA = "aurora"

MAX_DETAILS = 100
SNS_SUBJECT_LIMIT = 100

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
    logger = logging.getLogger("scheduler")
    logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
    logger.propagate = False
    return logger


LOGGER = _configure_logging()


# --- Event and configuration ----------------------------------------------------


def _truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes")
    return bool(value)


def parse_event(event: Any, default_dry_run: bool = False) -> tuple[str, bool, str]:
    """Return ``(action, dry_run, trigger)``. Raise ``ValueError`` for an unusable event."""
    if isinstance(event, dict) and isinstance(event.get("Records"), list):
        has_sns = any(isinstance(r, dict) and "Sns" in r for r in event["Records"])
        if has_sns:
            return STOP, default_dry_run, "budget"
    if isinstance(event, dict) and event.get("action") in ACTIONS:
        dry_run = _truthy(event["dry_run"]) if "dry_run" in event else default_dry_run
        return event["action"], dry_run, "schedule"
    raise ValueError(f"unsupported event, expected an action of stop or start: {event!r}")


def has_tag(tags: list[dict[str, str]] | None, key: str, value: str) -> bool:
    """True if ``tags`` (a list of Key/Value dicts, as AWS returns them) holds key=value."""
    return any(t.get("Key") == key and t.get("Value") == value for t in tags or [])


def _error_reason(exc: Exception) -> str:
    if isinstance(exc, ClientError):
        error = exc.response.get("Error", {})
        return f"{error.get('Code', 'Error')}: {error.get('Message', str(exc))}"
    return f"{type(exc).__name__}: {exc}"


def _result(resource: str, kind: str, outcome: str, reason: str | None = None) -> dict[str, Any]:
    return {"resource": resource, "type": kind, "outcome": outcome, "reason": reason}


# --- Skip rules (pure) ----------------------------------------------------------


def ec2_skip_reason(instance: dict[str, Any]) -> str | None:
    tags = {t.get("Key"): t.get("Value") for t in instance.get("Tags", [])}
    group = tags.get("aws:autoscaling:groupName")
    if group:
        return f"member of Auto Scaling group {group}, stopping it would make the group replace it"
    if instance.get("InstanceLifecycle") == "spot":
        return "spot instance"
    if instance.get("RootDeviceType") == "instance-store":
        return "instance store root volume, AWS cannot stop it"
    return None


def rds_instance_skip_reason(db: dict[str, Any]) -> str | None:
    if db.get("DBClusterIdentifier"):
        return f"member of cluster {db['DBClusterIdentifier']}, tag the cluster instead"
    if db.get("ReadReplicaSourceDBInstanceIdentifier") or db.get(
        "ReadReplicaSourceDBClusterIdentifier"
    ):
        return "read replica, AWS cannot stop it"
    if db.get("ReadReplicaDBInstanceIdentifiers"):
        return "has read replicas, AWS cannot stop it"
    return None


def aurora_cluster_skip_reason(cluster: dict[str, Any]) -> str | None:
    if cluster.get("EngineMode") == "serverless":
        return "Aurora Serverless v1 pauses on its own, AWS cannot stop it"
    if cluster.get("ReplicationSourceIdentifier"):
        return "replica cluster, AWS cannot stop it"
    return None


# --- Per-service runs -----------------------------------------------------------


def _client(service: str) -> Any:
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _change(
    resource: str,
    kind: str,
    action: str,
    dry_run: bool,
    call: Callable[[], Any],
) -> dict[str, Any]:
    """Run one stop or start call. Failure becomes a result, never an exception."""
    outcome = STOPPED if action == STOP else STARTED
    if dry_run:
        LOGGER.info("dry run, would %s", action, extra={"fields": {"resource": resource}})
        return _result(resource, kind, outcome, "dry run, no change made")
    try:
        call()
    except (ClientError, BotoCoreError) as exc:
        LOGGER.warning("%s failed", action, extra={"fields": {"resource": resource}})
        return _result(resource, kind, FAILED, _error_reason(exc))
    LOGGER.info("%s requested", action, extra={"fields": {"resource": resource}})
    return _result(resource, kind, outcome)


def _skip(resource: str, kind: str, reason: str) -> dict[str, Any]:
    LOGGER.info("skipped", extra={"fields": {"resource": resource, "reason": reason}})
    return _result(resource, kind, SKIPPED, reason)


def run_ec2(
    ec2: Any, action: str, tag_key: str, tag_value: str, dry_run: bool
) -> list[dict[str, Any]]:
    state = "running" if action == STOP else "stopped"
    filters = [
        {"Name": f"tag:{tag_key}", "Values": [tag_value]},
        {"Name": "instance-state-name", "Values": [state]},
    ]
    results = []
    for page in ec2.get_paginator("describe_instances").paginate(Filters=filters):
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                instance_id = instance["InstanceId"]
                reason = ec2_skip_reason(instance)
                if reason:
                    results.append(_skip(instance_id, EC2, reason))
                    continue
                method = ec2.stop_instances if action == STOP else ec2.start_instances
                results.append(
                    _change(
                        instance_id,
                        EC2,
                        action,
                        dry_run,
                        lambda method=method, instance_id=instance_id: method(
                            InstanceIds=[instance_id]
                        ),
                    )
                )
    return results


def run_rds_instances(
    rds: Any, action: str, tag_key: str, tag_value: str, dry_run: bool
) -> list[dict[str, Any]]:
    status = "available" if action == STOP else "stopped"
    results = []
    for page in rds.get_paginator("describe_db_instances").paginate():
        for db in page.get("DBInstances", []):
            if db.get("DBInstanceStatus") != status or not has_tag(
                db.get("TagList"), tag_key, tag_value
            ):
                continue
            name = db["DBInstanceIdentifier"]
            reason = rds_instance_skip_reason(db)
            if reason:
                results.append(_skip(name, RDS, reason))
                continue
            method = rds.stop_db_instance if action == STOP else rds.start_db_instance
            results.append(
                _change(
                    name,
                    RDS,
                    action,
                    dry_run,
                    lambda method=method, name=name: method(DBInstanceIdentifier=name),
                )
            )
    return results


def run_aurora_clusters(
    rds: Any, action: str, tag_key: str, tag_value: str, dry_run: bool
) -> list[dict[str, Any]]:
    status = "available" if action == STOP else "stopped"
    results = []
    for page in rds.get_paginator("describe_db_clusters").paginate():
        for cluster in page.get("DBClusters", []):
            if cluster.get("Status") != status or not has_tag(
                cluster.get("TagList"), tag_key, tag_value
            ):
                continue
            name = cluster["DBClusterIdentifier"]
            reason = aurora_cluster_skip_reason(cluster)
            if reason:
                results.append(_skip(name, AURORA, reason))
                continue
            method = rds.stop_db_cluster if action == STOP else rds.start_db_cluster
            results.append(
                _change(
                    name,
                    AURORA,
                    action,
                    dry_run,
                    lambda method=method, name=name: method(DBClusterIdentifier=name),
                )
            )
    return results


def _guarded(kind: str, run: Callable[[], list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """Run one discovery step. If listing fails, report that and let the others run."""
    try:
        return run()
    except (ClientError, BotoCoreError) as exc:
        LOGGER.warning("listing %s failed", kind, extra={"fields": {"reason": str(exc)}})
        return [_result(f"list {kind}", kind, FAILED, _error_reason(exc))]


def run_all(
    action: str,
    dry_run: bool,
    tag_key: str,
    tag_value: str,
    resource_types: list[str],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    if EC2 in resource_types:
        ec2 = _client("ec2")
        results += _guarded(EC2, lambda: run_ec2(ec2, action, tag_key, tag_value, dry_run))
    if RDS in resource_types:
        rds = _client("rds")
        results += _guarded(
            RDS, lambda: run_rds_instances(rds, action, tag_key, tag_value, dry_run)
        )
        results += _guarded(
            AURORA, lambda: run_aurora_clusters(rds, action, tag_key, tag_value, dry_run)
        )
    return results


# --- Summary --------------------------------------------------------------------


def build_summary(
    action: str, dry_run: bool, trigger: str, results: list[dict[str, Any]]
) -> dict[str, Any]:
    """The payload the Slack notifier formats (``kind`` is ``scheduler_summary``)."""
    counts = dict.fromkeys(OUTCOMES, 0)
    for item in results:
        counts[item["outcome"]] += 1
    summary: dict[str, Any] = {
        "kind": "scheduler_summary",
        "action": action,
        "dry_run": dry_run,
        "trigger": trigger,
        "counts": counts,
        "details": results[:MAX_DETAILS],
    }
    if len(results) > MAX_DETAILS:
        summary["details_omitted"] = len(results) - MAX_DETAILS
    return summary


def summary_subject(summary: dict[str, Any]) -> str:
    suffix = " (dry run)" if summary["dry_run"] else ""
    return f"Scheduler {summary['action']}{suffix}"[:SNS_SUBJECT_LIMIT]


def summary_text(summary: dict[str, Any]) -> str:
    """Plain text body for email subscribers."""
    counts = summary["counts"]
    lines = [
        summary_subject(summary),
        "",
        "  ".join(f"{key.capitalize()}: {counts[key]}" for key in OUTCOMES),
    ]
    notable = [d for d in summary["details"] if d["outcome"] in (SKIPPED, FAILED)]
    if notable:
        lines.append("")
        for item in notable:
            reason = f": {item['reason']}" if item.get("reason") else ""
            lines.append(f"- {item['outcome']} {item['type']} {item['resource']}{reason}")
    if summary.get("details_omitted"):
        lines.append(f"...and {summary['details_omitted']} more not listed")
    if summary["dry_run"]:
        lines += ["", "Dry run: nothing was changed."]
    return "\n".join(lines)


def publish_summary(summary: dict[str, Any], topic_arn: str | None) -> bool:
    """Publish to SNS. The default body is JSON for the Slack notifier, email gets text.

    Returns False when there is nothing to send or publishing failed. A failed
    publish is logged but does not fail the run, because the changes already happened.
    """
    if not topic_arn or not any(summary["counts"].values()):
        return False
    message = {"default": json.dumps(summary), "email": summary_text(summary)}
    try:
        _client("sns").publish(
            TopicArn=topic_arn,
            Subject=summary_subject(summary),
            Message=json.dumps(message),
            MessageStructure="json",
        )
    except (ClientError, BotoCoreError):
        LOGGER.exception("publishing the summary failed")
        return False
    return True


# --- Entry point ----------------------------------------------------------------


def lambda_handler(event: Any, context: Any) -> dict[str, Any]:
    action, dry_run, trigger = parse_event(
        event, default_dry_run=_truthy(os.environ.get("DRY_RUN", "false"))
    )
    resource_types = [t.strip() for t in os.environ.get("RESOURCE_TYPES", "ec2,rds").split(",")]
    results = run_all(
        action,
        dry_run,
        os.environ["TAG_KEY"],
        os.environ["TAG_VALUE"],
        [t for t in resource_types if t],
    )
    summary = build_summary(action, dry_run, trigger, results)
    published = publish_summary(summary, os.environ.get("SNS_TOPIC_ARN"))
    LOGGER.info(
        "run finished",
        extra={"fields": {"action": action, "dry_run": dry_run, **summary["counts"]}},
    )
    return {**summary, "published": published}
