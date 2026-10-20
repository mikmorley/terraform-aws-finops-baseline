locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  monitor_arns = concat(
    aws_ce_anomaly_monitor.service[*].arn,
    var.existing_monitor_arns,
    [for k in sort(keys(var.tag_monitors)) : aws_ce_anomaly_monitor.tag[k].arn],
  )
}

resource "aws_ce_anomaly_monitor" "service" {
  count = var.create_service_monitor ? 1 : 0

  name              = "${var.name_prefix}-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = local.tags
}

resource "aws_ce_anomaly_monitor" "tag" {
  for_each = var.tag_monitors

  name         = "${var.name_prefix}-tag-${each.key}"
  monitor_type = "CUSTOM"
  tags         = local.tags

  monitor_specification = jsonencode({
    Tags = {
      Key    = each.value.tag_key
      Values = each.value.tag_values
    }
  })
}

resource "aws_ce_anomaly_subscription" "this" {
  name = "${var.name_prefix}-anomaly-alerts"
  # SNS subscribers need IMMEDIATE. DAILY and WEEKLY only work for email.
  frequency        = "IMMEDIATE"
  monitor_arn_list = local.monitor_arns
  tags             = local.tags

  subscriber {
    type    = "SNS"
    address = var.sns_topic_arn
  }

  # Alert only when the anomaly clears both the dollar and the percent bar.
  threshold_expression {
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [tostring(var.min_impact_usd)]
      }
    }
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [tostring(var.min_impact_pct)]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.create_service_monitor || length(var.existing_monitor_arns) > 0 || length(var.tag_monitors) > 0
      error_message = "Nothing to monitor. Set create_service_monitor, existing_monitor_arns or tag_monitors."
    }
  }
}
