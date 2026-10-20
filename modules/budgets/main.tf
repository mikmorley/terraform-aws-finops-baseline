locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  # Every budget goes through one resource. The key is stable, so adding or
  # removing a budget never moves the others.
  budgets = merge(
    {
      account = {
        limit_usd           = var.account_budget.limit_usd
        alert_thresholds    = var.account_budget.alert_thresholds
        forecast_thresholds = var.account_budget.forecast_thresholds
        filter              = null
      }
    },
    {
      for k, b in var.tag_budgets : "tag-${k}" => {
        limit_usd           = b.limit_usd
        alert_thresholds    = b.alert_thresholds
        forecast_thresholds = b.forecast_thresholds
        # format() because "$${" in a template is an escape for a literal "${".
        filter = { name = "TagKeyValue", value = format("user:%s$%s", b.tag_key, b.tag_value) }
      }
    },
    {
      for k, b in var.service_budgets : "service-${k}" => {
        limit_usd           = b.limit_usd
        alert_thresholds    = b.alert_thresholds
        forecast_thresholds = b.forecast_thresholds
        filter              = { name = "Service", value = b.service }
      }
    },
  )

  # One entry per alert. The provider stores notifications as a set, so list
  # order does not matter.
  notifications = {
    for k, b in local.budgets : k => concat(
      [for t in b.alert_thresholds : { type = "ACTUAL", threshold = t }],
      [for t in b.forecast_thresholds : { type = "FORECASTED", threshold = t }],
    )
  }
}

resource "aws_budgets_budget" "this" {
  for_each = local.budgets

  name         = "${var.name_prefix}-${each.key}"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(each.value.limit_usd)
  limit_unit   = "USD"
  tags         = local.tags

  dynamic "cost_filter" {
    for_each = each.value.filter == null ? [] : [each.value.filter]

    content {
      name   = cost_filter.value.name
      values = [cost_filter.value.value]
    }
  }

  dynamic "notification" {
    for_each = local.notifications[each.key]

    content {
      notification_type         = notification.value.type
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      comparison_operator       = "GREATER_THAN"
      subscriber_sns_topic_arns = [var.sns_topic_arn]
    }
  }
}
