mock_provider "aws" {}

variables {
  name_prefix   = "finops"
  sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
}

run "account_budget_uses_default_thresholds" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    tags           = { Project = "acme" }
  }

  assert {
    condition     = length(aws_budgets_budget.this) == 1 && aws_budgets_budget.this["account"].name == "finops-account"
    error_message = "Only the account budget should exist, named <prefix>-account."
  }

  assert {
    condition = (
      aws_budgets_budget.this["account"].budget_type == "COST" &&
      aws_budgets_budget.this["account"].time_unit == "MONTHLY" &&
      aws_budgets_budget.this["account"].limit_unit == "USD" &&
      aws_budgets_budget.this["account"].limit_amount == "100"
    )
    error_message = "The account budget should be a monthly USD cost budget with the given limit."
  }

  assert {
    condition = toset([
      for n in aws_budgets_budget.this["account"].notification : n.threshold if n.notification_type == "ACTUAL"
    ]) == toset([50, 80, 100])
    error_message = "Actual alerts should default to 50, 80 and 100 percent."
  }

  assert {
    condition = toset([
      for n in aws_budgets_budget.this["account"].notification : n.threshold if n.notification_type == "FORECASTED"
    ]) == toset([100])
    error_message = "Forecast alerts should default to 100 percent."
  }

  assert {
    condition = alltrue([
      for n in aws_budgets_budget.this["account"].notification :
      n.threshold_type == "PERCENTAGE" && n.comparison_operator == "GREATER_THAN" && n.subscriber_sns_topic_arns == toset(["arn:aws:sns:us-east-1:123456789012:finops-alerts"])
    ])
    error_message = "Every alert should be a percentage threshold that publishes only to the SNS topic."
  }

  assert {
    condition     = length(aws_budgets_budget.this["account"].cost_filter) == 0
    error_message = "The account budget must not filter costs."
  }

  assert {
    condition     = aws_budgets_budget.this["account"].tags["Project"] == "acme" && aws_budgets_budget.this["account"].tags["ManagedBy"] == "terraform-aws-finops-baseline"
    error_message = "The budget should carry user tags and the ManagedBy tag."
  }
}

run "custom_thresholds_replace_defaults" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd           = 250.5
      alert_thresholds    = [90]
      forecast_thresholds = [80, 120]
    }
  }

  assert {
    condition     = aws_budgets_budget.this["account"].limit_amount == "250.5"
    error_message = "A fractional limit should be passed through."
  }

  assert {
    condition = (
      toset([for n in aws_budgets_budget.this["account"].notification : n.threshold if n.notification_type == "ACTUAL"]) == toset([90]) &&
      toset([for n in aws_budgets_budget.this["account"].notification : n.threshold if n.notification_type == "FORECASTED"]) == toset([80, 120])
    )
    error_message = "Custom thresholds should replace the defaults."
  }
}

run "forecast_alerts_can_be_turned_off" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100, forecast_thresholds = [] }
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.this["account"].notification : n.notification_type == "ACTUAL"]) && length(aws_budgets_budget.this["account"].notification) == 3
    error_message = "With no forecast thresholds only the three actual alerts should remain."
  }
}

run "tag_and_service_budgets_filter_costs" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      env-dev = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
    }
    service_budgets = {
      ec2 = { service = "Amazon Elastic Compute Cloud - Compute", limit_usd = 40, alert_thresholds = [100], forecast_thresholds = [] }
    }
  }

  assert {
    condition     = length(aws_budgets_budget.this) == 3
    error_message = "Expected the account budget plus one tag budget and one service budget."
  }

  assert {
    condition     = aws_budgets_budget.this["tag-env-dev"].name == "finops-tag-env-dev" && aws_budgets_budget.this["service-ec2"].name == "finops-service-ec2"
    error_message = "Names should be <prefix>-tag-<key> and <prefix>-service-<key>."
  }

  assert {
    condition = (
      length(aws_budgets_budget.this["tag-env-dev"].cost_filter) == 1 &&
      one([for f in aws_budgets_budget.this["tag-env-dev"].cost_filter : f.name]) == "TagKeyValue" &&
      one(flatten([for f in aws_budgets_budget.this["tag-env-dev"].cost_filter : tolist(f.values)])) == "user:Environment$dev"
    )
    error_message = "The tag budget should filter on TagKeyValue in user:<key>$<value> form."
  }

  assert {
    condition = (
      length(aws_budgets_budget.this["service-ec2"].cost_filter) == 1 &&
      one([for f in aws_budgets_budget.this["service-ec2"].cost_filter : f.name]) == "Service" &&
      one(flatten([for f in aws_budgets_budget.this["service-ec2"].cost_filter : tolist(f.values)])) == "Amazon Elastic Compute Cloud - Compute"
    )
    error_message = "The service budget should filter on Service."
  }

  assert {
    condition = (
      aws_budgets_budget.this["tag-env-dev"].limit_amount == "30" &&
      length(aws_budgets_budget.this["tag-env-dev"].notification) == 4 &&
      length(aws_budgets_budget.this["service-ec2"].notification) == 1
    )
    error_message = "Each budget should use its own limit and thresholds."
  }

  assert {
    condition     = output.tag_budget_names == { env-dev = "finops-tag-env-dev" } && output.service_budget_names == { ec2 = "finops-service-ec2" }
    error_message = "Outputs should list tag and service budget names by key."
  }
}

run "rejects_zero_limit" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 0 }
  }

  expect_failures = [var.account_budget]
}

run "rejects_threshold_out_of_range" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100, alert_thresholds = [0] }
  }

  expect_failures = [var.account_budget]
}

run "rejects_threshold_above_1000" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100, forecast_thresholds = [1001] }
  }

  expect_failures = [var.account_budget]
}

run "rejects_repeated_threshold" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100, alert_thresholds = [80, 80] }
  }

  expect_failures = [var.account_budget]
}

run "rejects_budget_without_alerts" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100, alert_thresholds = [], forecast_thresholds = [] }
  }

  expect_failures = [var.account_budget]
}

run "rejects_more_than_ten_alerts" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd           = 100
      alert_thresholds    = [10, 20, 30, 40, 50, 60]
      forecast_thresholds = [70, 80, 90, 100, 110]
    }
  }

  expect_failures = [var.account_budget]
}

run "rejects_bad_topic_arn" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    sns_topic_arn  = "finops-alerts"
  }

  expect_failures = [var.sns_topic_arn]
}

run "rejects_tag_value_with_dollar_sign" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      bad = { tag_key = "Environment", tag_value = "de$v", limit_usd = 30 }
    }
  }

  expect_failures = [var.tag_budgets]
}

run "rejects_tag_key_with_user_prefix" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      bad = { tag_key = "user:Environment", tag_value = "dev", limit_usd = 30 }
    }
  }

  expect_failures = [var.tag_budgets]
}

run "rejects_tag_budget_key_with_spaces" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    tag_budgets = {
      "env dev" = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
    }
  }

  expect_failures = [var.tag_budgets]
}

run "rejects_empty_service_name" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    service_budgets = {
      ec2 = { service = " ", limit_usd = 40 }
    }
  }

  expect_failures = [var.service_budgets]
}

run "rejects_service_budget_threshold_out_of_range" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    service_budgets = {
      ec2 = { service = "Amazon Elastic Compute Cloud - Compute", limit_usd = 40, alert_thresholds = [5000] }
    }
  }

  expect_failures = [var.service_budgets]
}

run "rejects_bad_name_prefix" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
    name_prefix    = "1 bad prefix"
  }

  expect_failures = [var.name_prefix]
}
