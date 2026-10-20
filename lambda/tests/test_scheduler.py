import json

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws

from scheduler import handler
from slack_notifier import handler as slack_handler

TOPIC_ARN = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
TAG = ("Schedule", "office-hours")


@pytest.fixture(autouse=True)
def _reset_state(monkeypatch):
    handler._CLIENTS.clear()
    for name in ("TAG_KEY", "TAG_VALUE", "RESOURCE_TYPES", "SNS_TOPIC_ARN", "DRY_RUN"):
        monkeypatch.delenv(name, raising=False)
    yield
    handler._CLIENTS.clear()


def client_error(code="UnauthorizedOperation", message="not allowed"):
    return ClientError({"Error": {"Code": code, "Message": message}}, "Operation")


# --- Fakes ----------------------------------------------------------------------


class FakePaginator:
    def __init__(self, pages):
        self._pages = pages

    def paginate(self, **_kwargs):
        return iter(self._pages)


class FakeEC2:
    """Applies the tag and state filters the function sends, then records changes."""

    def __init__(self, instances, fail_ids=(), list_error=None):
        self.instances = instances
        self.fail_ids = set(fail_ids)
        self.list_error = list_error
        self.calls = []

    def get_paginator(self, name):
        assert name == "describe_instances"
        if self.list_error:
            raise self.list_error

        class _Paginator:
            def paginate(inner, Filters):  # noqa: N803, N805 - mirrors the boto3 signature
                wanted = {f["Name"]: f["Values"] for f in Filters}
                matched = [
                    i
                    for i in self.instances
                    if i["State"]["Name"] in wanted["instance-state-name"]
                    and any(
                        f"tag:{t['Key']}" in wanted and t["Value"] in wanted[f"tag:{t['Key']}"]
                        for t in i.get("Tags", [])
                    )
                ]
                # One reservation per instance checks that the function walks both levels.
                return iter([{"Reservations": [{"Instances": [m]} for m in matched]}])

        return _Paginator()

    def _change(self, verb, InstanceIds):  # noqa: N803
        self.calls.append((verb, InstanceIds))
        if InstanceIds[0] in self.fail_ids:
            raise client_error("IncorrectInstanceState", "cannot change state")

    def stop_instances(self, InstanceIds):  # noqa: N803
        self._change("stop", InstanceIds)

    def start_instances(self, InstanceIds):  # noqa: N803
        self._change("start", InstanceIds)


class FakeRDS:
    def __init__(self, instances=(), clusters=(), fail=(), list_errors=()):
        self.instances = list(instances)
        self.clusters = list(clusters)
        self.fail = set(fail)
        self.list_errors = set(list_errors)
        self.calls = []

    def get_paginator(self, name):
        if name in self.list_errors:
            raise client_error("AccessDenied", f"{name} denied")
        if name == "describe_db_instances":
            return FakePaginator([{"DBInstances": self.instances}])
        if name == "describe_db_clusters":
            return FakePaginator([{"DBClusters": self.clusters}])
        raise AssertionError(name)

    def _change(self, verb, name):
        self.calls.append((verb, name))
        if name in self.fail:
            raise client_error("InvalidDBInstanceState", "cannot change state")

    def stop_db_instance(self, DBInstanceIdentifier):  # noqa: N803
        self._change("stop_instance", DBInstanceIdentifier)

    def start_db_instance(self, DBInstanceIdentifier):  # noqa: N803
        self._change("start_instance", DBInstanceIdentifier)

    def stop_db_cluster(self, DBClusterIdentifier):  # noqa: N803
        self._change("stop_cluster", DBClusterIdentifier)

    def start_db_cluster(self, DBClusterIdentifier):  # noqa: N803
        self._change("start_cluster", DBClusterIdentifier)


def ec2_instance(instance_id, state="running", tagged=True, extra_tags=(), **fields):
    tags = [{"Key": "Name", "Value": instance_id}, *extra_tags]
    if tagged:
        tags.append({"Key": TAG[0], "Value": TAG[1]})
    return {"InstanceId": instance_id, "State": {"Name": state}, "Tags": tags, **fields}


def rds_instance(name, status="available", tagged=True, **fields):
    tag_list = [{"Key": TAG[0], "Value": TAG[1]}] if tagged else []
    return {"DBInstanceIdentifier": name, "DBInstanceStatus": status, "TagList": tag_list, **fields}


def aurora_cluster(name, status="available", tagged=True, **fields):
    tag_list = [{"Key": TAG[0], "Value": TAG[1]}] if tagged else []
    return {"DBClusterIdentifier": name, "Status": status, "TagList": tag_list, **fields}


def outcomes(results):
    return {r["resource"]: r["outcome"] for r in results}


# --- Event parsing --------------------------------------------------------------


def test_parse_event_from_schedule():
    assert handler.parse_event({"action": "stop", "dry_run": False}) == ("stop", False, "schedule")
    assert handler.parse_event({"action": "start", "dry_run": True}) == ("start", True, "schedule")


def test_parse_event_uses_default_dry_run_when_event_has_none():
    assert handler.parse_event({"action": "stop"}, default_dry_run=True) == (
        "stop",
        True,
        "schedule",
    )


def test_event_dry_run_wins_over_default():
    assert (
        handler.parse_event({"action": "stop", "dry_run": False}, default_dry_run=True)[1] is False
    )


def test_parse_event_treats_an_sns_record_as_stop():
    event = {"Records": [{"Sns": {"Subject": "AWS Budgets", "Message": "anything"}}]}
    assert handler.parse_event(event) == ("stop", False, "budget")
    assert handler.parse_event(event, default_dry_run=True) == ("stop", True, "budget")


@pytest.mark.parametrize("event", [{}, {"action": "delete"}, None, "stop", {"Records": []}])
def test_parse_event_rejects_anything_else(event):
    with pytest.raises(ValueError, match="unsupported event"):
        handler.parse_event(event)


def test_has_tag_needs_matching_key_and_value():
    tags = [{"Key": "Schedule", "Value": "office-hours"}]
    assert handler.has_tag(tags, "Schedule", "office-hours")
    assert not handler.has_tag(tags, "Schedule", "nights")
    assert not handler.has_tag(tags, "schedule", "office-hours")
    assert not handler.has_tag(None, "Schedule", "office-hours")


# --- Skip rules -----------------------------------------------------------------


def test_ec2_skip_reasons():
    asg = ec2_instance("i-1", extra_tags=[{"Key": "aws:autoscaling:groupName", "Value": "web"}])
    assert "Auto Scaling group web" in handler.ec2_skip_reason(asg)
    assert handler.ec2_skip_reason(ec2_instance("i-2", InstanceLifecycle="spot")) == "spot instance"
    assert "instance store" in handler.ec2_skip_reason(
        ec2_instance("i-3", RootDeviceType="instance-store")
    )
    assert handler.ec2_skip_reason(ec2_instance("i-4", RootDeviceType="ebs")) is None


def test_rds_instance_skip_reasons():
    assert "cluster aurora-1" in handler.rds_instance_skip_reason(
        rds_instance("db", DBClusterIdentifier="aurora-1")
    )
    assert "read replica" in handler.rds_instance_skip_reason(
        rds_instance("db", ReadReplicaSourceDBInstanceIdentifier="primary")
    )
    assert "has read replicas" in handler.rds_instance_skip_reason(
        rds_instance("db", ReadReplicaDBInstanceIdentifiers=["replica"])
    )
    assert (
        handler.rds_instance_skip_reason(rds_instance("db", ReadReplicaDBInstanceIdentifiers=[]))
        is None
    )


def test_aurora_skip_reasons():
    assert "Serverless v1" in handler.aurora_cluster_skip_reason(
        aurora_cluster("c", EngineMode="serverless")
    )
    assert "replica cluster" in handler.aurora_cluster_skip_reason(
        aurora_cluster(
            "c", ReplicationSourceIdentifier="arn:aws:rds:us-east-1:123456789012:cluster:p"
        )
    )
    assert handler.aurora_cluster_skip_reason(aurora_cluster("c", EngineMode="provisioned")) is None


# --- EC2 ------------------------------------------------------------------------


def test_ec2_stop_changes_only_running_tagged_instances():
    ec2 = FakeEC2(
        [
            ec2_instance("i-run"),
            ec2_instance("i-untagged", tagged=False),
            ec2_instance("i-already", state="stopped"),
        ]
    )
    results = handler.run_ec2(ec2, "stop", *TAG, dry_run=False)
    assert outcomes(results) == {"i-run": "stopped"}
    assert ec2.calls == [("stop", ["i-run"])]


def test_ec2_start_changes_only_stopped_tagged_instances():
    ec2 = FakeEC2([ec2_instance("i-off", state="stopped"), ec2_instance("i-on")])
    results = handler.run_ec2(ec2, "start", *TAG, dry_run=False)
    assert outcomes(results) == {"i-off": "started"}
    assert ec2.calls == [("start", ["i-off"])]


def test_ec2_skips_auto_scaling_members_and_reports_why():
    asg = ec2_instance("i-asg", extra_tags=[{"Key": "aws:autoscaling:groupName", "Value": "web"}])
    ec2 = FakeEC2([asg, ec2_instance("i-plain")])
    results = handler.run_ec2(ec2, "stop", *TAG, dry_run=False)
    assert outcomes(results) == {"i-asg": "skipped", "i-plain": "stopped"}
    assert "web" in next(r for r in results if r["resource"] == "i-asg")["reason"]
    assert ec2.calls == [("stop", ["i-plain"])]


def test_ec2_dry_run_reports_without_calling_aws():
    ec2 = FakeEC2([ec2_instance("i-run")])
    results = handler.run_ec2(ec2, "stop", *TAG, dry_run=True)
    assert outcomes(results) == {"i-run": "stopped"}
    assert "dry run" in results[0]["reason"]
    assert ec2.calls == []


def test_ec2_one_failure_does_not_stop_the_rest():
    ec2 = FakeEC2([ec2_instance("i-bad"), ec2_instance("i-good")], fail_ids={"i-bad"})
    results = handler.run_ec2(ec2, "stop", *TAG, dry_run=False)
    assert outcomes(results) == {"i-bad": "failed", "i-good": "stopped"}
    assert (
        "IncorrectInstanceState" in next(r for r in results if r["resource"] == "i-bad")["reason"]
    )
    assert [c[1][0] for c in ec2.calls] == ["i-bad", "i-good"]


# --- RDS and Aurora -------------------------------------------------------------


def test_rds_stop_and_skip_rules():
    rds = FakeRDS(
        instances=[
            rds_instance("db-ok"),
            rds_instance("db-member", DBClusterIdentifier="aurora-1"),
            rds_instance("db-replica", ReadReplicaSourceDBInstanceIdentifier="db-ok"),
            rds_instance("db-primary", ReadReplicaDBInstanceIdentifiers=["db-replica"]),
            rds_instance("db-untagged", tagged=False),
            rds_instance("db-off", status="stopped"),
        ]
    )
    results = handler.run_rds_instances(rds, "stop", *TAG, dry_run=False)
    assert outcomes(results) == {
        "db-ok": "stopped",
        "db-member": "skipped",
        "db-replica": "skipped",
        "db-primary": "skipped",
    }
    assert rds.calls == [("stop_instance", "db-ok")]


def test_rds_start_only_touches_stopped_instances():
    rds = FakeRDS(instances=[rds_instance("db-off", status="stopped"), rds_instance("db-on")])
    results = handler.run_rds_instances(rds, "start", *TAG, dry_run=False)
    assert outcomes(results) == {"db-off": "started"}
    assert rds.calls == [("start_instance", "db-off")]


def test_rds_failure_is_reported_and_the_run_continues():
    rds = FakeRDS(instances=[rds_instance("db-bad"), rds_instance("db-good")], fail={"db-bad"})
    results = handler.run_rds_instances(rds, "stop", *TAG, dry_run=False)
    assert outcomes(results) == {"db-bad": "failed", "db-good": "stopped"}


def test_aurora_stop_start_and_skips():
    rds = FakeRDS(
        clusters=[
            aurora_cluster("c-ok"),
            aurora_cluster("c-serverless", EngineMode="serverless"),
            aurora_cluster("c-off", status="stopped"),
            aurora_cluster("c-untagged", tagged=False),
        ]
    )
    stop = handler.run_aurora_clusters(rds, "stop", *TAG, dry_run=False)
    assert outcomes(stop) == {"c-ok": "stopped", "c-serverless": "skipped"}
    start = handler.run_aurora_clusters(rds, "start", *TAG, dry_run=False)
    assert outcomes(start) == {"c-off": "started"}
    assert rds.calls == [("stop_cluster", "c-ok"), ("start_cluster", "c-off")]


def test_rds_and_aurora_dry_run_make_no_calls():
    rds = FakeRDS(instances=[rds_instance("db")], clusters=[aurora_cluster("c")])
    results = handler.run_rds_instances(rds, "stop", *TAG, dry_run=True)
    results += handler.run_aurora_clusters(rds, "stop", *TAG, dry_run=True)
    assert outcomes(results) == {"db": "stopped", "c": "stopped"}
    assert rds.calls == []


# --- run_all --------------------------------------------------------------------


def test_run_all_reports_a_listing_failure_and_keeps_going(monkeypatch):
    ec2 = FakeEC2([], list_error=client_error("UnauthorizedOperation", "no describe"))
    rds = FakeRDS(instances=[rds_instance("db")], list_errors={"describe_db_clusters"})
    monkeypatch.setitem(handler._CLIENTS, "ec2", ec2)
    monkeypatch.setitem(handler._CLIENTS, "rds", rds)
    results = handler.run_all("stop", False, *TAG, ["ec2", "rds"])
    by_type = {(r["type"], r["outcome"]) for r in results}
    assert ("ec2", "failed") in by_type
    assert ("aurora", "failed") in by_type
    assert ("rds", "stopped") in by_type


def test_run_all_only_touches_the_enabled_resource_types(monkeypatch):
    ec2 = FakeEC2([ec2_instance("i-1")])
    rds = FakeRDS(instances=[rds_instance("db")])
    monkeypatch.setitem(handler._CLIENTS, "ec2", ec2)
    monkeypatch.setitem(handler._CLIENTS, "rds", rds)
    results = handler.run_all("stop", False, *TAG, ["ec2"])
    assert outcomes(results) == {"i-1": "stopped"}
    assert rds.calls == []


# --- Summary --------------------------------------------------------------------


def make_results():
    return [
        {"resource": "i-1", "type": "ec2", "outcome": "stopped", "reason": None},
        {"resource": "db-1", "type": "rds", "outcome": "skipped", "reason": "read replica"},
        {"resource": "c-1", "type": "aurora", "outcome": "failed", "reason": "boom"},
    ]


def test_build_summary_counts_every_outcome():
    summary = handler.build_summary("stop", False, "schedule", make_results())
    assert summary["kind"] == "scheduler_summary"
    assert summary["counts"] == {"stopped": 1, "started": 0, "skipped": 1, "failed": 1}
    assert summary["trigger"] == "schedule"
    assert "details_omitted" not in summary


def test_build_summary_caps_details():
    results = [
        {"resource": f"i-{n}", "type": "ec2", "outcome": "stopped", "reason": None}
        for n in range(handler.MAX_DETAILS + 5)
    ]
    summary = handler.build_summary("stop", False, "schedule", results)
    assert len(summary["details"]) == handler.MAX_DETAILS
    assert summary["details_omitted"] == 5
    assert summary["counts"]["stopped"] == handler.MAX_DETAILS + 5


def test_summary_text_lists_skips_and_failures():
    text = handler.summary_text(handler.build_summary("stop", True, "schedule", make_results()))
    assert "Scheduler stop (dry run)" in text
    assert "Stopped: 1" in text and "Failed: 1" in text
    assert "- skipped rds db-1: read replica" in text
    assert "- failed aurora c-1: boom" in text
    assert "i-1" not in text
    assert "Dry run: nothing was changed." in text


def test_summary_is_formatted_by_the_slack_notifier_not_the_fallback():
    summary = handler.build_summary("stop", False, "schedule", make_results())
    payload = slack_handler.build_slack_payload("Scheduler stop", json.dumps(summary))
    text = json.dumps(payload)
    assert "Scheduler stop" in text
    assert "read replica" in text
    assert "boom" in text


# --- Publishing -----------------------------------------------------------------


def test_publish_message_body(monkeypatch):
    sent = {}

    class Recorder:
        def publish(self, **kwargs):
            sent.update(kwargs)

    monkeypatch.setitem(handler._CLIENTS, "sns", Recorder())
    summary = handler.build_summary("stop", False, "budget", make_results())
    assert handler.publish_summary(summary, TOPIC_ARN) is True
    assert sent["TopicArn"] == TOPIC_ARN
    assert sent["MessageStructure"] == "json"
    assert sent["Subject"] == "Scheduler stop"
    body = json.loads(sent["Message"])
    assert json.loads(body["default"])["kind"] == "scheduler_summary"
    assert "Skipped: 1" in body["email"]


def test_publish_skips_when_nothing_happened_or_no_topic(monkeypatch):
    monkeypatch.setitem(handler._CLIENTS, "sns", object())  # any call would raise
    empty = handler.build_summary("stop", False, "schedule", [])
    assert handler.publish_summary(empty, TOPIC_ARN) is False
    full = handler.build_summary("stop", False, "schedule", make_results())
    assert handler.publish_summary(full, None) is False
    assert handler.publish_summary(full, "") is False


def test_publish_failure_is_logged_not_raised(monkeypatch):
    class Broken:
        def publish(self, **_kwargs):
            raise client_error("AuthorizationError", "no publish")

    monkeypatch.setitem(handler._CLIENTS, "sns", Broken())
    summary = handler.build_summary("stop", False, "schedule", make_results())
    assert handler.publish_summary(summary, TOPIC_ARN) is False


# --- End to end with moto -------------------------------------------------------


def configure(monkeypatch, **env):
    monkeypatch.setenv("TAG_KEY", TAG[0])
    monkeypatch.setenv("TAG_VALUE", TAG[1])
    for key, value in env.items():
        monkeypatch.setenv(key, value)


def launch(ec2, tagged=True, extra_tags=()):
    tags = [{"Key": TAG[0], "Value": TAG[1]}] if tagged else []
    tags += list(extra_tags)
    response = ec2.run_instances(
        ImageId="ami-12345678",
        MinCount=1,
        MaxCount=1,
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags}] if tags else [],
    )
    return response["Instances"][0]["InstanceId"]


def state_of(ec2, instance_id):
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    return reservations[0]["Instances"][0]["State"]["Name"]


@mock_aws
def test_handler_stops_then_starts_tagged_ec2_instances(monkeypatch):
    configure(monkeypatch, RESOURCE_TYPES="ec2")
    ec2 = boto3.client("ec2", region_name="us-east-1")
    tagged = launch(ec2)
    untagged = launch(ec2, tagged=False)

    stopped = handler.lambda_handler({"action": "stop", "dry_run": False}, None)
    assert stopped["counts"]["stopped"] == 1
    assert state_of(ec2, tagged) == "stopped"
    assert state_of(ec2, untagged) == "running"

    started = handler.lambda_handler({"action": "start", "dry_run": False}, None)
    assert started["counts"]["started"] == 1
    assert state_of(ec2, tagged) == "running"


@mock_aws
def test_handler_dry_run_leaves_instances_running(monkeypatch):
    configure(monkeypatch, RESOURCE_TYPES="ec2")
    ec2 = boto3.client("ec2", region_name="us-east-1")
    instance_id = launch(ec2)
    summary = handler.lambda_handler({"action": "stop", "dry_run": True}, None)
    assert summary["dry_run"] is True
    assert summary["counts"]["stopped"] == 1
    assert state_of(ec2, instance_id) == "running"


@mock_aws
def test_handler_skips_auto_scaling_group_members(monkeypatch):
    configure(monkeypatch, RESOURCE_TYPES="ec2")
    ec2 = boto3.client("ec2", region_name="us-east-1")
    instance_id = launch(ec2, extra_tags=[{"Key": "aws:autoscaling:groupName", "Value": "web"}])
    summary = handler.lambda_handler({"action": "stop", "dry_run": False}, None)
    assert summary["counts"] == {"stopped": 0, "started": 0, "skipped": 1, "failed": 0}
    assert state_of(ec2, instance_id) == "running"


@mock_aws
def test_handler_budget_notification_stops_and_publishes(monkeypatch):
    sns = boto3.client("sns", region_name="us-east-1")
    topic_arn = sns.create_topic(Name="finops-alerts")["TopicArn"]
    queue = boto3.client("sqs", region_name="us-east-1")
    queue_url = queue.create_queue(QueueName="inbox")["QueueUrl"]
    queue_arn = queue.get_queue_attributes(QueueUrl=queue_url, AttributeNames=["QueueArn"])[
        "Attributes"
    ]["QueueArn"]
    sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn)

    configure(monkeypatch, RESOURCE_TYPES="ec2", SNS_TOPIC_ARN=topic_arn)
    ec2 = boto3.client("ec2", region_name="us-east-1")
    instance_id = launch(ec2)

    event = {"Records": [{"Sns": {"Subject": "AWS Budgets", "Message": "budget text"}}]}
    summary = handler.lambda_handler(event, None)

    assert summary["trigger"] == "budget"
    assert summary["published"] is True
    assert state_of(ec2, instance_id) == "stopped"
    received = queue.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)["Messages"]
    delivered = json.loads(json.loads(received[0]["Body"])["Message"])
    assert delivered["kind"] == "scheduler_summary"
    assert delivered["counts"]["stopped"] == 1


@mock_aws
def test_handler_stops_a_tagged_rds_instance(monkeypatch):
    configure(monkeypatch, RESOURCE_TYPES="rds")
    rds = boto3.client("rds", region_name="us-east-1")
    rds.create_db_instance(
        DBInstanceIdentifier="dev-db",
        DBInstanceClass="db.t3.micro",
        Engine="postgres",
        MasterUsername="admin",
        MasterUserPassword="not-a-real-password",
        AllocatedStorage=20,
        Tags=[{"Key": TAG[0], "Value": TAG[1]}],
    )
    summary = handler.lambda_handler({"action": "stop", "dry_run": False}, None)
    assert summary["counts"]["stopped"] == 1
    status = rds.describe_db_instances(DBInstanceIdentifier="dev-db")["DBInstances"][0]
    assert status["DBInstanceStatus"] == "stopped"


def test_handler_rejects_an_unknown_event(monkeypatch):
    configure(monkeypatch)
    with pytest.raises(ValueError, match="unsupported event"):
        handler.lambda_handler({"hello": "world"}, None)


def test_handler_reads_dry_run_default_from_the_environment(monkeypatch):
    configure(monkeypatch, RESOURCE_TYPES="ec2", DRY_RUN="true")
    ec2 = FakeEC2([ec2_instance("i-1")])
    monkeypatch.setitem(handler._CLIENTS, "ec2", ec2)
    event = {"Records": [{"Sns": {"Message": "budget"}}]}
    summary = handler.lambda_handler(event, None)
    assert summary["dry_run"] is True
    assert ec2.calls == []
