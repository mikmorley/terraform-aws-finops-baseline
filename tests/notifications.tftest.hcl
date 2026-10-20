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

run "email_only_creates_topic_and_subscriptions" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
    emails      = ["ops@example.com", "dev@example.com"]
    tags        = { Project = "acme" }
  }

  assert {
    condition     = aws_sns_topic.this.name == "finops-alerts"
    error_message = "The topic should be named <prefix>-alerts."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 2
    error_message = "Expected one email subscription per address."
  }

  assert {
    condition     = length(aws_lambda_function.slack_notifier) == 0 && length(aws_sns_topic_subscription.slack_notifier) == 0
    error_message = "Slack resources must not exist without a webhook parameter."
  }

  assert {
    condition     = aws_sns_topic.this.tags["Project"] == "acme" && aws_sns_topic.this.tags["ManagedBy"] == "terraform-aws-finops-baseline"
    error_message = "The topic should carry user tags and the ManagedBy tag."
  }

  assert {
    condition     = aws_sns_topic.this.kms_master_key_id == null
    error_message = "The topic should be unencrypted by default so Budgets and Cost Anomaly Detection can publish."
  }
}

run "topic_policy_allows_budgets_and_anomaly_detection_from_this_account" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
    emails      = ["ops@example.com"]
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_sns_topic_policy.this.policy).Statement : s.Principal.Service
      if try(s.Principal.Service, null) != null
    ]) == toset(["budgets.amazonaws.com", "costalerts.amazonaws.com"])
    error_message = "The topic policy should allow exactly the Budgets and Cost Anomaly Detection service principals."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_sns_topic_policy.this.policy).Statement :
      s.Condition.StringEquals["aws:SourceAccount"] == "123456789012"
      if try(s.Principal.Service, null) != null
    ])
    error_message = "Every service principal must be scoped with aws:SourceAccount."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_sns_topic_policy.this.policy).Statement :
      s.Action == "SNS:Publish" && s.Resource == "arn:aws:sns:us-east-1:123456789012:finops-alerts"
      if try(s.Principal.Service, null) != null
    ])
    error_message = "Service principals may only publish, and only to this topic."
  }
}

run "slack_creates_lambda_with_least_privilege" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix             = "finops"
    slack_webhook_ssm_param = "/finops/slack-webhook"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "No email subscriptions expected."
  }

  assert {
    condition = (
      length(aws_lambda_function.slack_notifier) == 1 &&
      length(aws_cloudwatch_log_group.slack_notifier) == 1 &&
      length(aws_lambda_permission.sns_invoke_slack_notifier) == 1 &&
      aws_sns_topic_subscription.slack_notifier[0].protocol == "lambda"
    )
    error_message = "Slack should add the Lambda, its log group, the SNS invoke permission and a lambda subscription."
  }

  assert {
    condition     = aws_lambda_function.slack_notifier[0].runtime == "python3.13" && aws_lambda_function.slack_notifier[0].timeout > 0 && aws_lambda_function.slack_notifier[0].memory_size > 0
    error_message = "The Lambda should use Python 3.13 with an explicit timeout and memory size."
  }

  assert {
    condition     = aws_cloudwatch_log_group.slack_notifier[0].retention_in_days == 30
    error_message = "Log retention should default to 30 days."
  }

  assert {
    condition = (
      aws_lambda_function.slack_notifier[0].environment[0].variables["SLACK_WEBHOOK_SSM_PARAM"] == "/finops/slack-webhook" &&
      !anytrue([for v in values(aws_lambda_function.slack_notifier[0].environment[0].variables) : can(regex("https?://", v))])
    )
    error_message = "The environment should hold the parameter name and no URL."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.slack_notifier[0].policy).Statement : s.Resource if s.Action == "ssm:GetParameter"] ==
      ["arn:aws:ssm:us-east-1:123456789012:parameter/finops/slack-webhook"]
    )
    error_message = "ssm:GetParameter must be limited to the one webhook parameter."
  }

  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_role_policy.slack_notifier[0].policy).Statement : s.Action == "kms:Decrypt"])
    error_message = "kms:Decrypt must not be granted unless a parameter key is set."
  }
}

run "customer_managed_keys_are_wired_in" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix             = "finops"
    slack_webhook_ssm_param = "/finops/slack-webhook"
    kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    ssm_kms_key_arn         = "arn:aws:kms:us-east-1:123456789012:key/66666666-7777-8888-9999-000000000000"
  }

  assert {
    condition     = aws_sns_topic.this.kms_master_key_id == var.kms_key_arn
    error_message = "The topic should use the supplied CMK."
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.slack_notifier[0].policy).Statement : s.Resource if s.Action == "kms:Decrypt"
    ] == [var.ssm_kms_key_arn]
    error_message = "kms:Decrypt should be limited to the parameter's key."
  }
}

run "log_settings_are_passed_through" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix             = "finops"
    slack_webhook_ssm_param = "/finops/slack-webhook"
    log_level               = "DEBUG"
    log_retention_days      = 7
  }

  assert {
    condition     = aws_lambda_function.slack_notifier[0].environment[0].variables["LOG_LEVEL"] == "DEBUG"
    error_message = "LOG_LEVEL should follow log_level."
  }

  assert {
    condition     = aws_cloudwatch_log_group.slack_notifier[0].retention_in_days == 7
    error_message = "Retention should follow log_retention_days."
  }
}

run "rejects_no_notification_target" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
  }

  expect_failures = [aws_sns_topic.this]
}

run "rejects_invalid_email" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
    emails      = ["not-an-email"]
  }

  expect_failures = [var.emails]
}

run "rejects_webhook_url_in_place_of_parameter_name" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix             = "finops"
    slack_webhook_ssm_param = "https://hooks.slack.com/services/T000/B000/xxxx"
  }

  expect_failures = [var.slack_webhook_ssm_param]
}

run "rejects_parameter_name_without_leading_slash" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix             = "finops"
    slack_webhook_ssm_param = "finops/slack-webhook"
  }

  expect_failures = [var.slack_webhook_ssm_param]
}

run "rejects_bad_name_prefix" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "1 bad prefix"
    emails      = ["ops@example.com"]
  }

  expect_failures = [var.name_prefix]
}

run "rejects_kms_alias_for_topic_key" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
    emails      = ["ops@example.com"]
    kms_key_arn = "alias/aws/sns"
  }

  expect_failures = [var.kms_key_arn]
}

run "rejects_unsupported_log_retention" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix        = "finops"
    emails             = ["ops@example.com"]
    log_retention_days = 31
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_unknown_log_level" {
  command = plan

  module {
    source = "./modules/notifications"
  }

  variables {
    name_prefix = "finops"
    emails      = ["ops@example.com"]
    log_level   = "TRACE"
  }

  expect_failures = [var.log_level]
}
