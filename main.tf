locals {
  # Actions from every budget, to check them against the other features.
  all_budget_actions = concat(
    values(var.account_budget.actions),
    flatten([for _, b in var.tag_budgets : values(b.actions)]),
    flatten([for _, b in var.service_budgets : values(b.actions)]),
  )
  uses_stop_tagged = anytrue([for a in local.all_budget_actions : a.type == "stop_tagged"])

  # Tag keys that budgets and monitors depend on.
  tag_keys_in_use = distinct(concat(
    [for _, b in var.tag_budgets : b.tag_key],
    var.anomaly_detection.enabled ? [for _, m in var.anomaly_detection.tag_monitors : m.tag_key] : [],
  ))
  tag_keys_not_activated = [for k in local.tag_keys_in_use : k if !contains(var.cost_allocation_tag_keys, k)]
}

# Rules that span features. A variable validation can only see its own variable.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = !local.uses_stop_tagged || var.scheduler.enabled
      error_message = "A stop_tagged budget action stops resources through the scheduler. Set scheduler.enabled = true, or use another action type."
    }
  }
}

# Tag budgets and tag monitors see nothing until their tag key is an active cost
# allocation tag. It may be active already, so this warns and does not block.
check "tag_keys_activated" {
  assert {
    condition     = length(local.tag_keys_not_activated) == 0
    error_message = "These tag keys are used by tag budgets or tag monitors but are not in cost_allocation_tag_keys: ${join(", ", local.tag_keys_not_activated)}. They show no spend until they are active cost allocation tags."
  }
}

module "notifications" {
  source = "./modules/notifications"

  name_prefix             = var.name_prefix
  tags                    = var.tags
  emails                  = var.notifications.emails
  slack_webhook_ssm_param = var.notifications.slack_webhook_ssm_param
  ssm_kms_key_arn         = var.notifications.ssm_kms_key_arn
  kms_key_arn             = var.notifications.kms_key_arn
  log_level               = var.notifications.log_level
  log_retention_days      = var.notifications.log_retention_days
}

module "budgets" {
  source = "./modules/budgets"

  name_prefix         = var.name_prefix
  tags                = var.tags
  sns_topic_arn       = module.notifications.topic_arn
  account_budget      = var.account_budget
  tag_budgets         = var.tag_budgets
  service_budgets     = var.service_budgets
  deny_policy_actions = var.deny_policy_actions
}

module "anomaly_detection" {
  source = "./modules/anomaly-detection"
  count  = var.anomaly_detection.enabled ? 1 : 0

  name_prefix            = var.name_prefix
  tags                   = var.tags
  sns_topic_arn          = module.notifications.topic_arn
  min_impact_usd         = var.anomaly_detection.min_impact_usd
  min_impact_pct         = var.anomaly_detection.min_impact_pct
  create_service_monitor = var.anomaly_detection.create_service_monitor
  existing_monitor_arns  = var.anomaly_detection.existing_monitor_arns
  tag_monitors           = var.anomaly_detection.tag_monitors
}

module "cost_allocation_tags" {
  source = "./modules/cost-allocation-tags"
  count  = length(var.cost_allocation_tag_keys) > 0 ? 1 : 0

  tag_keys = var.cost_allocation_tag_keys
}

module "scheduler" {
  source = "./modules/scheduler"
  count  = var.scheduler.enabled ? 1 : 0

  name_prefix          = var.name_prefix
  tags                 = var.tags
  sns_topic_arn        = module.notifications.topic_arn
  sns_kms_key_arn      = var.notifications.kms_key_arn
  timezone             = var.scheduler.timezone
  tag_key              = var.scheduler.tag_key
  tag_value            = var.scheduler.tag_value
  stop_cron            = var.scheduler.stop_cron
  start_cron           = var.scheduler.start_cron
  resource_types       = var.scheduler.resource_types
  dry_run              = var.scheduler.dry_run
  reserved_concurrency = var.scheduler.reserved_concurrency
  log_level            = var.scheduler.log_level
  log_retention_days   = var.scheduler.log_retention_days

  # Budget actions of type stop_tagged publish to this topic.
  budget_stop_enabled   = local.uses_stop_tagged
  budget_stop_topic_arn = module.budgets.stop_topic_arn
}

module "cost_report" {
  source = "./modules/cost-report"
  count  = var.cost_report.enabled ? 1 : 0

  name_prefix        = var.name_prefix
  tags               = var.tags
  sns_topic_arn      = module.notifications.topic_arn
  sns_kms_key_arn    = var.notifications.kms_key_arn
  budget_name        = module.budgets.account_budget_name
  schedule           = var.cost_report.schedule
  timezone           = var.cost_report.timezone
  period_days        = var.cost_report.period_days
  log_level          = var.cost_report.log_level
  log_retention_days = var.cost_report.log_retention_days
}
