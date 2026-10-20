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

run "minimal_input_wires_the_defaults" {
  command = plan

  variables {
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
  }

  assert {
    condition     = module.notifications.topic_name == "finops-alerts" && module.budgets.account_budget_name == "finops-account"
    error_message = "The topic and the account budget should use the default prefix."
  }

  assert {
    condition     = length(module.anomaly_detection) == 1 && length(module.cost_report) == 1
    error_message = "Anomaly detection and the cost report should be on by default."
  }

  assert {
    condition     = length(module.scheduler) == 0 && length(module.cost_allocation_tags) == 0
    error_message = "The scheduler and tag activation should be off by default."
  }

  assert {
    condition     = output.scheduler_function_name == null && output.scheduler_schedule_names == {} && length(output.active_cost_allocation_tag_keys) == 0
    error_message = "Outputs for disabled features should be null or empty."
  }

  assert {
    condition     = output.cost_report_function_name == "finops-cost-report" && output.cost_report_schedule_name == "finops-cost-report"
    error_message = "The cost report outputs should name its Lambda and schedule."
  }

  assert {
    condition     = output.native_action_budget_count == 0 && length(output.budget_action_ids) == 0
    error_message = "No budget action should exist by default."
  }
}

run "every_feature_on" {
  command = plan

  variables {
    name_prefix = "acme"
    tags        = { Project = "example" }

    notifications = {
      emails                  = ["ops@example.com"]
      slack_webhook_ssm_param = "/finops/slack-webhook"
    }

    account_budget = {
      limit_usd = 100
      actions = {
        deny-new-spend = { type = "deny_policy", threshold_percent = 100, roles = ["dev-deployer"], approval_model = "MANUAL" }
        stop-dev       = { type = "stop_tagged", threshold_percent = 120 }
      }
    }

    tag_budgets = {
      env-dev = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
    }

    service_budgets = {
      ec2 = { service = "Amazon Elastic Compute Cloud - Compute", limit_usd = 40 }
    }

    anomaly_detection = {
      tag_monitors = { project = { tag_key = "Project", tag_values = ["example"] } }
    }

    cost_allocation_tag_keys = ["Environment", "Project"]

    scheduler = {
      enabled  = true
      timezone = "Australia/Brisbane"
      dry_run  = true
    }

    cost_report = {
      timezone = "Australia/Brisbane"
    }
  }

  assert {
    condition     = length(module.anomaly_detection) == 1 && length(module.cost_allocation_tags) == 1 && length(module.scheduler) == 1 && length(module.cost_report) == 1
    error_message = "Every optional feature should be on."
  }

  assert {
    condition     = module.notifications.topic_name == "acme-alerts" && module.notifications.slack_notifier_function_name == "acme-slack-notifier"
    error_message = "The name prefix and Slack should reach the notifications module."
  }

  assert {
    condition     = module.budgets.tag_budget_names == { env-dev = "acme-tag-env-dev" } && module.budgets.service_budget_names == { ec2 = "acme-service-ec2" }
    error_message = "Tag and service budgets should reach the budgets module."
  }

  assert {
    condition     = output.native_action_budget_count == 1
    error_message = "Only the account budget has a native action. stop_tagged is not native."
  }

  assert {
    condition     = output.scheduler_schedule_names == { stop = "acme-scheduler-stop", start = "acme-scheduler-start" } && output.scheduler_function_name == "acme-scheduler"
    error_message = "The scheduler outputs should carry the prefix."
  }

  assert {
    condition     = join(",", output.active_cost_allocation_tag_keys) == "Environment,Project"
    error_message = "Both tag keys should be activated."
  }
}

run "slack_only_is_a_valid_target" {
  command = plan

  variables {
    notifications  = { slack_webhook_ssm_param = "/finops/slack-webhook" }
    account_budget = { limit_usd = 100 }
  }

  assert {
    condition     = output.slack_notifier_function_name == "finops-slack-notifier"
    error_message = "Slack alone should be enough."
  }
}

run "features_can_be_switched_off" {
  command = plan

  variables {
    notifications     = { emails = ["ops@example.com"] }
    account_budget    = { limit_usd = 100 }
    anomaly_detection = { enabled = false }
    cost_report       = { enabled = false }
  }

  assert {
    condition     = length(module.anomaly_detection) == 0 && length(module.cost_report) == 0
    error_message = "Disabled features should create no module."
  }

  assert {
    condition     = output.anomaly_subscription_arn == null && length(output.anomaly_monitor_arns) == 0 && output.cost_report_function_name == null
    error_message = "Outputs for disabled features should be null or empty."
  }
}

run "stop_by_instance_id_needs_no_scheduler" {
  command = plan

  variables {
    notifications = { emails = ["ops@example.com"] }
    account_budget = {
      limit_usd = 100
      actions = {
        stop-db = { type = "stop_rds", threshold_percent = 100, instance_ids = ["dev-db"] }
      }
    }
  }

  assert {
    condition     = length(module.scheduler) == 0 && output.native_action_budget_count == 1
    error_message = "A native stop action should work without the scheduler."
  }
}

run "rejects_stop_tagged_without_the_scheduler" {
  command = plan

  variables {
    notifications = { emails = ["ops@example.com"] }
    account_budget = {
      limit_usd = 100
      actions = {
        stop-dev = { type = "stop_tagged", threshold_percent = 120 }
      }
    }
  }

  expect_failures = [terraform_data.checks]
}

run "rejects_stop_tagged_on_a_tag_budget_without_the_scheduler" {
  command = plan

  variables {
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      env-dev = {
        tag_key   = "Environment"
        tag_value = "dev"
        limit_usd = 30
        actions = {
          stop = { type = "stop_tagged", threshold_percent = 100 }
        }
      }
    }
    cost_allocation_tag_keys = ["Environment"]
  }

  expect_failures = [terraform_data.checks]
}

run "warns_when_a_tag_budget_key_is_not_activated" {
  command = plan

  variables {
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      env-dev = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
    }
  }

  expect_failures = [check.tag_keys_activated]
}

run "warns_when_a_tag_monitor_key_is_not_activated" {
  command = plan

  variables {
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
    anomaly_detection = {
      tag_monitors = { project = { tag_key = "Project", tag_values = ["example"] } }
    }
  }

  expect_failures = [check.tag_keys_activated]
}

run "does_not_warn_for_a_disabled_tag_monitor" {
  command = plan

  variables {
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
    anomaly_detection = {
      enabled      = false
      tag_monitors = { project = { tag_key = "Project", tag_values = ["example"] } }
    }
  }

  assert {
    condition     = length(module.anomaly_detection) == 0
    error_message = "A disabled anomaly detection should not need its tag keys activated."
  }
}

run "rejects_no_notification_target" {
  command = plan

  variables {
    notifications  = {}
    account_budget = { limit_usd = 100 }
  }

  expect_failures = [var.notifications]
}

run "rejects_bad_name_prefix" {
  command = plan

  variables {
    name_prefix    = "1 bad prefix"
    notifications  = { emails = ["ops@example.com"] }
    account_budget = { limit_usd = 100 }
  }

  expect_failures = [var.name_prefix]
}
