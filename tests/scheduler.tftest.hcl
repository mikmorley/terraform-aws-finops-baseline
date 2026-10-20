mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

mock_provider "archive" {}

variables {
  name_prefix   = "finops"
  sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
}

run "defaults_create_lambda_and_two_schedules" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    tags = { Project = "acme" }
  }

  assert {
    condition     = aws_lambda_function.scheduler.function_name == "finops-scheduler" && aws_lambda_function.scheduler.runtime == "python3.13" && aws_lambda_function.scheduler.timeout > 0 && aws_lambda_function.scheduler.memory_size > 0
    error_message = "The Lambda should be named <prefix>-scheduler on Python 3.13 with an explicit timeout and memory size."
  }

  assert {
    condition     = aws_lambda_function.scheduler.reserved_concurrent_executions == -1
    error_message = "No concurrency should be reserved by default, because a reservation fails in new accounts."
  }

  assert {
    condition     = aws_lambda_function.scheduler.environment[0].variables["TAG_KEY"] == "Schedule" && aws_lambda_function.scheduler.environment[0].variables["TAG_VALUE"] == "office-hours" && aws_lambda_function.scheduler.environment[0].variables["RESOURCE_TYPES"] == "ec2,rds" && aws_lambda_function.scheduler.environment[0].variables["DRY_RUN"] == "false" && aws_lambda_function.scheduler.environment[0].variables["SNS_TOPIC_ARN"] == var.sns_topic_arn
    error_message = "The environment should carry the tag, the resource types, the dry-run default and the topic."
  }

  assert {
    condition     = length(aws_scheduler_schedule.this) == 2 && aws_scheduler_schedule.this["stop"].name == "finops-scheduler-stop" && aws_scheduler_schedule.this["start"].name == "finops-scheduler-start"
    error_message = "Expected a stop and a start schedule named <prefix>-scheduler-<action>."
  }

  assert {
    condition     = aws_scheduler_schedule.this["stop"].schedule_expression == "cron(0 19 ? * MON-FRI *)" && aws_scheduler_schedule.this["start"].schedule_expression == "cron(0 7 ? * MON-FRI *)"
    error_message = "The schedules should default to 19:00 stop and 07:00 start on weekdays."
  }

  assert {
    condition     = aws_scheduler_schedule.this["stop"].schedule_expression_timezone == "UTC" && aws_scheduler_schedule.this["stop"].flexible_time_window[0].mode == "OFF"
    error_message = "The schedules should use the timezone and no flexible window."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.this["stop"].target[0].input).action == "stop" && jsondecode(aws_scheduler_schedule.this["start"].target[0].input).action == "start" && jsondecode(aws_scheduler_schedule.this["stop"].target[0].input).dry_run == false
    error_message = "Each schedule should send its action and the dry-run flag to the Lambda."
  }

  assert {
    condition     = aws_cloudwatch_log_group.scheduler.retention_in_days == 30 && aws_lambda_function.scheduler.environment[0].variables["LOG_LEVEL"] == "INFO"
    error_message = "Logs should default to 30 days and INFO."
  }

  assert {
    condition     = aws_lambda_function.scheduler.tags["Project"] == "acme" && aws_lambda_function.scheduler.tags["ManagedBy"] == "terraform-aws-finops-baseline"
    error_message = "The Lambda should carry user tags and the ManagedBy tag."
  }

  assert {
    condition     = length(aws_lambda_permission.budget_stop) == 0 && length(aws_sns_topic_subscription.budget_stop) == 0
    error_message = "The budget stop path should be off by default."
  }
}

run "policy_limits_stop_and_start_to_tagged_resources" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Sid]) == "WriteLogs,PublishSummary,DescribeEc2,StopStartTaggedEc2,DescribeRds,StopStartTaggedRdsInstances,StopStartTaggedAuroraClusters"
    error_message = "With ec2 and rds the policy should hold logs, publish and the six scheduler statements."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Resource == "*" if startswith(s.Sid, "Describe")]) && alltrue([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Resource != "*" && s.Condition.StringEquals["aws:ResourceTag/Schedule"] == "office-hours" if startswith(s.Sid, "StopStart")])
    error_message = "Only the describe calls may use *. Every stop and start must be limited by the schedule tag."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Resource if s.Sid == "PublishSummary"]) == var.sns_topic_arn
    error_message = "Publishing should be limited to the topic."
  }

  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : startswith(s.Sid, "UseTopicKey")])
    error_message = "No KMS permission should be granted without a key."
  }
}

run "ec2_only_drops_rds_permissions" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    resource_types = ["ec2"]
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Sid]) == "WriteLogs,PublishSummary,DescribeEc2,StopStartTaggedEc2"
    error_message = "With ec2 only there should be no RDS statements."
  }

  assert {
    condition     = aws_lambda_function.scheduler.environment[0].variables["RESOURCE_TYPES"] == "ec2"
    error_message = "RESOURCE_TYPES should follow resource_types."
  }
}

run "rds_only_drops_ec2_permissions" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    resource_types = ["rds"]
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Sid]) == "WriteLogs,PublishSummary,DescribeRds,StopStartTaggedRdsInstances,StopStartTaggedAuroraClusters"
    error_message = "With rds only there should be no EC2 statements."
  }
}

run "custom_tag_and_condition_follow_the_variables" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    tag_key   = "Env"
    tag_value = "dev"
  }

  assert {
    condition     = aws_lambda_function.scheduler.environment[0].variables["TAG_KEY"] == "Env" && one([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Condition.StringEquals["aws:ResourceTag/Env"] if s.Sid == "StopStartTaggedEc2"]) == "dev"
    error_message = "The tag in the environment and in the IAM conditions should follow tag_key and tag_value."
  }
}

run "schedule_settings_are_passed_through" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    timezone             = "Australia/Brisbane"
    stop_cron            = "cron(30 18 ? * MON-FRI *)"
    start_cron           = "cron(0 8 ? * MON-FRI *)"
    dry_run              = true
    reserved_concurrency = 1
    log_level            = "DEBUG"
    log_retention_days   = 7
  }

  assert {
    condition     = aws_scheduler_schedule.this["stop"].schedule_expression_timezone == "Australia/Brisbane" && aws_scheduler_schedule.this["stop"].schedule_expression == "cron(30 18 ? * MON-FRI *)" && aws_scheduler_schedule.this["start"].schedule_expression == "cron(0 8 ? * MON-FRI *)"
    error_message = "Timezone and cron expressions should follow the variables."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.this["stop"].target[0].input).dry_run == true && aws_lambda_function.scheduler.environment[0].variables["DRY_RUN"] == "true"
    error_message = "dry_run should reach both the schedule input and the environment."
  }

  assert {
    condition     = aws_lambda_function.scheduler.reserved_concurrent_executions == 1
    error_message = "reserved_concurrency should be passed to the Lambda."
  }

  assert {
    condition     = aws_lambda_function.scheduler.environment[0].variables["LOG_LEVEL"] == "DEBUG" && aws_cloudwatch_log_group.scheduler.retention_in_days == 7
    error_message = "Log settings should follow the variables."
  }
}

run "topic_key_adds_kms_permission" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    sns_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : s.Resource if s.Sid == "UseTopicKey"]) == var.sns_kms_key_arn
    error_message = "The Lambda should get KMS access to the topic key."
  }
}

run "budget_stop_topic_subscribes_the_lambda" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    budget_stop_enabled   = true
    budget_stop_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-budget-stop"
  }

  assert {
    condition     = length(aws_lambda_permission.budget_stop) == 1 && aws_lambda_permission.budget_stop[0].principal == "sns.amazonaws.com" && aws_lambda_permission.budget_stop[0].source_arn == var.budget_stop_topic_arn
    error_message = "SNS should be allowed to invoke the Lambda, from that topic only."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.budget_stop) == 1 && aws_sns_topic_subscription.budget_stop[0].protocol == "lambda" && aws_sns_topic_subscription.budget_stop[0].topic_arn == var.budget_stop_topic_arn
    error_message = "The Lambda should be subscribed to the budget stop topic."
  }
}

run "rejects_unknown_resource_type" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    resource_types = ["ec2", "lambda"]
  }

  expect_failures = [var.resource_types]
}

run "rejects_empty_resource_types" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    resource_types = []
  }

  expect_failures = [var.resource_types]
}

run "rejects_repeated_resource_type" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    resource_types = ["ec2", "ec2"]
  }

  expect_failures = [var.resource_types]
}

run "rejects_stop_cron_without_cron_wrapper" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    stop_cron = "0 19 * * *"
  }

  expect_failures = [var.stop_cron]
}

run "rejects_start_cron_that_is_a_rate" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    start_cron = "rate(1 day)"
  }

  expect_failures = [var.start_cron]
}

run "rejects_timezone_with_spaces" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    timezone = "Brisbane time"
  }

  expect_failures = [var.timezone]
}

run "rejects_bad_topic_arn" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    sns_topic_arn = "finops-alerts"
  }

  expect_failures = [var.sns_topic_arn]
}

run "rejects_budget_stop_without_a_topic" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    budget_stop_enabled = true
  }

  expect_failures = [aws_lambda_permission.budget_stop]
}

run "ignores_budget_stop_topic_when_not_enabled" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    budget_stop_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-budget-stop"
  }

  assert {
    condition     = length(aws_lambda_permission.budget_stop) == 0 && length(aws_sns_topic_subscription.budget_stop) == 0
    error_message = "A topic ARN alone should not create the budget stop path."
  }
}

run "rejects_bad_budget_stop_topic_arn" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    budget_stop_topic_arn = "finops-budget-stop"
  }

  expect_failures = [var.budget_stop_topic_arn]
}

run "rejects_bad_kms_key_arn" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    sns_kms_key_arn = "alias/aws/sns"
  }

  expect_failures = [var.sns_kms_key_arn]
}

run "rejects_reserved_concurrency_below_minus_one" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    reserved_concurrency = -2
  }

  expect_failures = [var.reserved_concurrency]
}

run "rejects_fractional_reserved_concurrency" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    reserved_concurrency = 1.5
  }

  expect_failures = [var.reserved_concurrency]
}

run "rejects_tag_key_with_dollar_sign" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    tag_key = "Sched$ule"
  }

  expect_failures = [var.tag_key]
}

run "rejects_empty_tag_value" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    tag_value = ""
  }

  expect_failures = [var.tag_value]
}

run "rejects_unknown_log_level" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    log_level = "TRACE"
  }

  expect_failures = [var.log_level]
}

run "rejects_unsupported_log_retention" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    log_retention_days = 31
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_bad_name_prefix" {
  command = plan

  module {
    source = "./modules/scheduler"
  }

  variables {
    name_prefix = "1 bad prefix"
  }

  expect_failures = [var.name_prefix]
}
