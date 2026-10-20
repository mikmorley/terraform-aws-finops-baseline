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

run "defaults_create_lambda_and_weekly_schedule" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    tags = { Project = "acme" }
  }

  assert {
    condition     = aws_lambda_function.cost_report.function_name == "finops-cost-report" && aws_lambda_function.cost_report.runtime == "python3.13" && aws_lambda_function.cost_report.timeout > 0 && aws_lambda_function.cost_report.memory_size > 0
    error_message = "The Lambda should be named <prefix>-cost-report on Python 3.13 with an explicit timeout and memory size."
  }

  assert {
    condition     = aws_lambda_function.cost_report.environment[0].variables["SNS_TOPIC_ARN"] == var.sns_topic_arn && aws_lambda_function.cost_report.environment[0].variables["PERIOD_DAYS"] == "7" && aws_lambda_function.cost_report.environment[0].variables["LOG_LEVEL"] == "INFO"
    error_message = "The environment should carry the topic, the period and the log level."
  }

  assert {
    condition     = !contains(keys(aws_lambda_function.cost_report.environment[0].variables), "BUDGET_NAME") && !contains(keys(aws_lambda_function.cost_report.environment[0].variables), "ACCOUNT_ID")
    error_message = "Without a budget name the environment should not mention a budget."
  }

  assert {
    condition     = aws_scheduler_schedule.this.name == "finops-cost-report" && aws_scheduler_schedule.this.schedule_expression == "cron(0 9 ? * MON *)" && aws_scheduler_schedule.this.schedule_expression_timezone == "UTC"
    error_message = "The schedule should default to 09:00 on Mondays in UTC."
  }

  assert {
    condition     = aws_scheduler_schedule.this.flexible_time_window[0].mode == "OFF" && aws_scheduler_schedule.this.target[0].role_arn == aws_iam_role.schedule.arn
    error_message = "The schedule should have no flexible window and use the schedule role."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cost_report.retention_in_days == 30
    error_message = "Logs should default to 30 days."
  }

  assert {
    condition     = aws_lambda_function.cost_report.tags["Project"] == "acme" && aws_lambda_function.cost_report.tags["ManagedBy"] == "terraform-aws-finops-baseline"
    error_message = "The Lambda should carry user tags and the ManagedBy tag."
  }
}

run "policy_reads_cost_explorer_and_publishes_to_the_topic" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Sid]) == "WriteLogs,PublishReport,ReadCostExplorer"
    error_message = "The default policy should hold logs, publish and Cost Explorer reads only."
  }

  assert {
    condition     = join(",", one([for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Action if s.Sid == "ReadCostExplorer"])) == "ce:GetCostAndUsage,ce:GetCostForecast,ce:GetAnomalies"
    error_message = "Cost Explorer access should be read-only and limited to the three calls the report makes."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Resource if s.Sid == "PublishReport"]) == var.sns_topic_arn
    error_message = "Publishing should be limited to the topic."
  }
}

run "budget_name_adds_the_budget_read" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    budget_name = "finops-account"
  }

  assert {
    condition     = aws_lambda_function.cost_report.environment[0].variables["BUDGET_NAME"] == "finops-account" && aws_lambda_function.cost_report.environment[0].variables["ACCOUNT_ID"] == "123456789012"
    error_message = "The environment should carry the budget name and the account ID."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Resource if s.Sid == "ReadAccountBudget"]) == "arn:aws:budgets::123456789012:budget/finops-account" && one([for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Action if s.Sid == "ReadAccountBudget"]) == "budgets:ViewBudget"
    error_message = "The role should be able to view that one budget."
  }
}

run "topic_key_adds_kms_permission" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    sns_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.cost_report.policy).Statement : s.Resource if s.Sid == "UseTopicKey"]) == var.sns_kms_key_arn
    error_message = "The Lambda should get KMS access to the topic key."
  }
}

run "settings_are_passed_through" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    schedule           = "cron(30 8 ? * FRI *)"
    timezone           = "Australia/Brisbane"
    period_days        = 14
    log_level          = "DEBUG"
    log_retention_days = 7
  }

  assert {
    condition     = aws_scheduler_schedule.this.schedule_expression == "cron(30 8 ? * FRI *)" && aws_scheduler_schedule.this.schedule_expression_timezone == "Australia/Brisbane"
    error_message = "Schedule and timezone should follow the variables."
  }

  assert {
    condition     = aws_lambda_function.cost_report.environment[0].variables["PERIOD_DAYS"] == "14" && aws_lambda_function.cost_report.environment[0].variables["LOG_LEVEL"] == "DEBUG" && aws_cloudwatch_log_group.cost_report.retention_in_days == 7
    error_message = "Period and log settings should follow the variables."
  }
}

run "rejects_schedule_without_cron_wrapper" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    schedule = "0 9 * * MON"
  }

  expect_failures = [var.schedule]
}

run "rejects_rate_schedule" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    schedule = "rate(7 days)"
  }

  expect_failures = [var.schedule]
}

run "rejects_timezone_with_spaces" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    timezone = "Brisbane time"
  }

  expect_failures = [var.timezone]
}

run "rejects_zero_period_days" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    period_days = 0
  }

  expect_failures = [var.period_days]
}

run "rejects_period_days_above_31" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    period_days = 32
  }

  expect_failures = [var.period_days]
}

run "rejects_fractional_period_days" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    period_days = 1.5
  }

  expect_failures = [var.period_days]
}

run "rejects_budget_name_with_colon" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    budget_name = "finops:account"
  }

  expect_failures = [var.budget_name]
}

run "rejects_empty_budget_name" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    budget_name = ""
  }

  expect_failures = [var.budget_name]
}

run "rejects_bad_topic_arn" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    sns_topic_arn = "finops-alerts"
  }

  expect_failures = [var.sns_topic_arn]
}

run "rejects_bad_kms_key_arn" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    sns_kms_key_arn = "alias/aws/sns"
  }

  expect_failures = [var.sns_kms_key_arn]
}

run "rejects_unknown_log_level" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    log_level = "TRACE"
  }

  expect_failures = [var.log_level]
}

run "rejects_unsupported_log_retention" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    log_retention_days = 31
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_bad_name_prefix" {
  command = plan

  module {
    source = "./modules/cost-report"
  }

  variables {
    name_prefix = "1 bad prefix"
  }

  expect_failures = [var.name_prefix]
}
