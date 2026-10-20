mock_provider "aws" {}

variables {
  name_prefix   = "finops"
  sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
}

run "default_creates_service_monitor_and_subscription" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    tags = { Project = "acme" }
  }

  assert {
    condition     = length(aws_ce_anomaly_monitor.service) == 1 && length(aws_ce_anomaly_monitor.tag) == 0
    error_message = "Only the service monitor should exist by default."
  }

  assert {
    condition     = aws_ce_anomaly_monitor.service[0].name == "finops-service" && aws_ce_anomaly_monitor.service[0].monitor_type == "DIMENSIONAL" && aws_ce_anomaly_monitor.service[0].monitor_dimension == "SERVICE"
    error_message = "The service monitor should be a dimensional monitor on SERVICE."
  }

  assert {
    condition     = aws_ce_anomaly_subscription.this.name == "finops-anomaly-alerts" && aws_ce_anomaly_subscription.this.frequency == "IMMEDIATE"
    error_message = "The subscription should be named <prefix>-anomaly-alerts and use IMMEDIATE, which SNS subscribers need."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this.monitor_arn_list) == 1
    error_message = "The subscription should cover the service monitor."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this.subscriber) == 1 && one([for s in aws_ce_anomaly_subscription.this.subscriber : s.type]) == "SNS" && one([for s in aws_ce_anomaly_subscription.this.subscriber : s.address]) == var.sns_topic_arn
    error_message = "The only subscriber should be the SNS topic."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this.threshold_expression[0].and) == 2
    error_message = "The threshold should combine two conditions with AND."
  }

  assert {
    condition     = { for a in aws_ce_anomaly_subscription.this.threshold_expression[0].and : a.dimension[0].key => one(a.dimension[0].values) }["ANOMALY_TOTAL_IMPACT_ABSOLUTE"] == "10" && { for a in aws_ce_anomaly_subscription.this.threshold_expression[0].and : a.dimension[0].key => one(a.dimension[0].values) }["ANOMALY_TOTAL_IMPACT_PERCENTAGE"] == "20"
    error_message = "The defaults should be 10 dollars and 20 percent."
  }

  assert {
    condition     = alltrue([for a in aws_ce_anomaly_subscription.this.threshold_expression[0].and : one(a.dimension[0].match_options) == "GREATER_THAN_OR_EQUAL"])
    error_message = "Both conditions should use GREATER_THAN_OR_EQUAL."
  }

  assert {
    condition     = aws_ce_anomaly_monitor.service[0].tags["Project"] == "acme" && aws_ce_anomaly_subscription.this.tags["ManagedBy"] == "terraform-aws-finops-baseline"
    error_message = "Resources should carry user tags and the ManagedBy tag."
  }
}

run "custom_thresholds_are_passed_through" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    min_impact_usd = 25.5
    min_impact_pct = 40
  }

  assert {
    condition     = { for a in aws_ce_anomaly_subscription.this.threshold_expression[0].and : a.dimension[0].key => one(a.dimension[0].values) }["ANOMALY_TOTAL_IMPACT_ABSOLUTE"] == "25.5" && { for a in aws_ce_anomaly_subscription.this.threshold_expression[0].and : a.dimension[0].key => one(a.dimension[0].values) }["ANOMALY_TOTAL_IMPACT_PERCENTAGE"] == "40"
    error_message = "Custom thresholds should replace the defaults."
  }
}

run "existing_monitor_replaces_service_monitor" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    create_service_monitor = false
    existing_monitor_arns  = ["arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555"]
  }

  assert {
    condition     = length(aws_ce_anomaly_monitor.service) == 0
    error_message = "No service monitor should be created when create_service_monitor is false."
  }

  assert {
    condition     = join(",", aws_ce_anomaly_subscription.this.monitor_arn_list) == "arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555"
    error_message = "The subscription should cover only the existing monitor."
  }
}

run "existing_monitor_is_added_to_service_monitor" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    existing_monitor_arns = ["arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555"]
  }

  assert {
    condition     = length(aws_ce_anomaly_monitor.service) == 1 && length(aws_ce_anomaly_subscription.this.monitor_arn_list) == 2
    error_message = "The subscription should cover the new service monitor and the existing one."
  }
}

run "tag_monitors_are_custom_monitors_on_tags" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    create_service_monitor = false
    tag_monitors = {
      project = { tag_key = "Project", tag_values = ["acme", "beta"] }
      env     = { tag_key = "Environment", tag_values = ["dev"] }
    }
  }

  assert {
    condition     = length(aws_ce_anomaly_monitor.tag) == 2 && aws_ce_anomaly_monitor.tag["project"].name == "finops-tag-project" && aws_ce_anomaly_monitor.tag["project"].monitor_type == "CUSTOM"
    error_message = "Each tag monitor should be a CUSTOM monitor named <prefix>-tag-<key>."
  }

  assert {
    condition     = jsondecode(aws_ce_anomaly_monitor.tag["project"].monitor_specification).Tags.Key == "Project" && join(",", jsondecode(aws_ce_anomaly_monitor.tag["project"].monitor_specification).Tags.Values) == "acme,beta"
    error_message = "The monitor specification should match the tag key and values."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this.monitor_arn_list) == 2
    error_message = "The subscription should cover both tag monitors."
  }
}

run "rejects_nothing_to_monitor" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    create_service_monitor = false
  }

  expect_failures = [aws_ce_anomaly_subscription.this]
}

run "rejects_zero_dollar_threshold" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    min_impact_usd = 0
  }

  expect_failures = [var.min_impact_usd]
}

run "rejects_zero_percent_threshold" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    min_impact_pct = 0
  }

  expect_failures = [var.min_impact_pct]
}

run "rejects_bad_topic_arn" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    sns_topic_arn = "finops-alerts"
  }

  expect_failures = [var.sns_topic_arn]
}

run "rejects_bad_existing_monitor_arn" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    existing_monitor_arns = ["not-an-arn"]
  }

  expect_failures = [var.existing_monitor_arns]
}

run "rejects_repeated_existing_monitor_arn" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    existing_monitor_arns = [
      "arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555",
      "arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555",
    ]
  }

  expect_failures = [var.existing_monitor_arns]
}

run "rejects_tag_monitor_without_values" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    tag_monitors = { project = { tag_key = "Project", tag_values = [] } }
  }

  expect_failures = [var.tag_monitors]
}

run "rejects_tag_monitor_with_empty_key" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    tag_monitors = { project = { tag_key = " ", tag_values = ["acme"] } }
  }

  expect_failures = [var.tag_monitors]
}

run "rejects_tag_monitor_key_with_spaces" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    tag_monitors = { "my project" = { tag_key = "Project", tag_values = ["acme"] } }
  }

  expect_failures = [var.tag_monitors]
}

run "rejects_bad_name_prefix" {
  command = plan

  module {
    source = "./modules/anomaly-detection"
  }

  variables {
    name_prefix = "1 bad prefix"
  }

  expect_failures = [var.name_prefix]
}
