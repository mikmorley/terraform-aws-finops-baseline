data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Every budget goes through one resource. The key is stable, so adding or
  # removing a budget never moves the others.
  budgets = merge(
    {
      account = {
        limit_usd           = var.account_budget.limit_usd
        alert_thresholds    = var.account_budget.alert_thresholds
        forecast_thresholds = var.account_budget.forecast_thresholds
        actions             = var.account_budget.actions
        filter              = null
      }
    },
    {
      for k, b in var.tag_budgets : "tag-${k}" => {
        limit_usd           = b.limit_usd
        alert_thresholds    = b.alert_thresholds
        forecast_thresholds = b.forecast_thresholds
        actions             = b.actions
        # format() because "$${" in a template is an escape for a literal "${".
        filter = { name = "TagKeyValue", value = format("user:%s$%s", b.tag_key, b.tag_value) }
      }
    },
    {
      for k, b in var.service_budgets : "service-${k}" => {
        limit_usd           = b.limit_usd
        alert_thresholds    = b.alert_thresholds
        forecast_thresholds = b.forecast_thresholds
        actions             = b.actions
        filter              = { name = "Service", value = b.service }
      }
    },
  )

  # --- Actions ------------------------------------------------------------------

  # One entry per action, keyed "<budget key>/<action key>".
  actions = merge([
    for bk, b in local.budgets : {
      for ak, a in b.actions : "${bk}/${ak}" => merge(a, { budget_key = bk, action_key = ak })
    }
  ]...)

  # stop_tagged is a plain notification to the stop topic. Everything else is a
  # native AWS budget action.
  native_actions = { for k, a in local.actions : k => a if a.type != "stop_tagged" }
  tagged_actions = { for k, a in local.actions : k => a if a.type == "stop_tagged" }
  deny_actions   = { for k, a in local.native_actions : k => a if a.type == "deny_policy" }
  ec2_actions    = { for k, a in local.native_actions : k => a if a.type == "stop_ec2" }
  rds_actions    = { for k, a in local.native_actions : k => a if a.type == "stop_rds" }

  # Native actions are billed per budget that has any, not per action.
  native_action_budget_count = length(distinct([for a in values(local.native_actions) : a.budget_key]))

  create_deny_policy      = anytrue([for a in values(local.deny_actions) : a.policy_arn == null])
  deny_policy_name        = "${var.name_prefix}-budget-deny"
  deny_policy_arn_default = "arn:${local.partition}:iam::${local.account_id}:policy/${local.deny_policy_name}"
  deny_policy_arns        = sort(distinct([for a in values(local.deny_actions) : coalesce(a.policy_arn, local.deny_policy_arn_default)]))
  # A role can sit under an IAM path, which is part of its ARN, so cover both forms.
  deny_role_arns = sort(distinct(flatten([
    for a in values(local.deny_actions) : [
      for r in a.roles : [
        "arn:${local.partition}:iam::${local.account_id}:role/${r}",
        "arn:${local.partition}:iam::${local.account_id}:role/*/${r}",
      ]
    ]
  ])))

  ec2_instance_arns = sort(distinct(flatten([
    for a in values(local.ec2_actions) : [
      for id in a.instance_ids : "arn:${local.partition}:ec2:${coalesce(a.region, local.region)}:${local.account_id}:instance/${id}"
    ]
  ])))
  rds_instance_arns = sort(distinct(flatten([
    for a in values(local.rds_actions) : [
      for id in a.instance_ids : "arn:${local.partition}:rds:${coalesce(a.region, local.region)}:${local.account_id}:db:${id}"
    ]
  ])))

  has_stop_topic = length(local.tagged_actions) > 0
  stop_topic_arn = "arn:${local.partition}:sns:${local.region}:${local.account_id}:${var.name_prefix}-budget-stop"

  # --- Notifications ------------------------------------------------------------

  # Alerts go to the alert topic. A stop_tagged action adds a notification to the
  # stop topic. When both land on the same type and threshold they share one
  # notification, because a budget cannot hold two identical ones.
  notification_inputs = {
    for k, b in local.budgets : k => concat(
      [for t in b.alert_thresholds : { type = "ACTUAL", threshold = t, topic = var.sns_topic_arn }],
      [for t in b.forecast_thresholds : { type = "FORECASTED", threshold = t, topic = var.sns_topic_arn }],
      [for a in values(b.actions) : { type = a.notification_type, threshold = a.threshold_percent, topic = local.stop_topic_arn } if a.type == "stop_tagged"],
    )
  }
  notifications = {
    for k, inputs in local.notification_inputs : k => [
      for key, group in { for n in inputs : "${n.type}/${n.threshold}" => n... } : {
        type      = group[0].type
        threshold = group[0].threshold
        topics    = distinct([for n in group : n.topic])
      }
    ]
  }

  # --- Action validation --------------------------------------------------------

  bad_action_keys  = [for k, a in local.actions : k if !can(regex("^[a-zA-Z0-9_-]{1,40}$", a.action_key))]
  bad_types        = [for k, a in local.actions : k if !contains(["deny_policy", "stop_ec2", "stop_rds", "stop_tagged"], a.type)]
  bad_thresholds   = [for k, a in local.actions : k if a.threshold_percent < 1 || a.threshold_percent > 1000]
  bad_notif_types  = [for k, a in local.actions : k if !contains(["ACTUAL", "FORECASTED"], a.notification_type)]
  bad_approvals    = [for k, a in local.actions : k if !contains(["AUTOMATIC", "MANUAL"], a.approval_model)]
  tagged_with_appr = [for k, a in local.tagged_actions : k if a.approval_model != "AUTOMATIC"]
  deny_no_roles    = [for k, a in local.deny_actions : k if length(a.roles) == 0]
  deny_bad_roles   = [for k, a in local.deny_actions : k if !alltrue([for r in a.roles : can(regex("^[a-zA-Z0-9+=,.@_-]{1,64}$", r))])]
  deny_bad_policy  = [for k, a in local.deny_actions : k if a.policy_arn != null && !can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a.policy_arn))]
  stop_no_ids      = [for k, a in merge(local.ec2_actions, local.rds_actions) : k if length(a.instance_ids) == 0]
  ec2_bad_ids      = [for k, a in local.ec2_actions : k if !alltrue([for i in a.instance_ids : can(regex("^i-[0-9a-f]{8,17}$", i))])]
  rds_bad_ids      = [for k, a in local.rds_actions : k if !alltrue([for i in a.instance_ids : can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,62}$", i))])]
  stop_bad_regions = [for k, a in merge(local.ec2_actions, local.rds_actions) : k if a.region != null && !can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", a.region))]
}

# --- Budgets --------------------------------------------------------------------

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
      subscriber_sns_topic_arns = notification.value.topics
    }
  }

  # The stop topic must accept Budgets before a notification can use it.
  depends_on = [aws_sns_topic_policy.budget_stop]

  lifecycle {
    precondition {
      condition     = length(local.bad_action_keys) == 0
      error_message = "Action names must be 1 to 40 characters of letters, digits, hyphens and underscores. Check: ${join(", ", local.bad_action_keys)}."
    }
    precondition {
      condition     = length(local.bad_types) == 0
      error_message = "Action type must be deny_policy, stop_ec2, stop_rds or stop_tagged. Check: ${join(", ", local.bad_types)}."
    }
    precondition {
      condition     = length(local.bad_thresholds) == 0
      error_message = "threshold_percent must be between 1 and 1000. Check: ${join(", ", local.bad_thresholds)}."
    }
    precondition {
      condition     = length(local.bad_notif_types) == 0
      error_message = "notification_type must be ACTUAL or FORECASTED. Check: ${join(", ", local.bad_notif_types)}."
    }
    precondition {
      condition     = length(local.bad_approvals) == 0
      error_message = "approval_model must be AUTOMATIC or MANUAL. Check: ${join(", ", local.bad_approvals)}."
    }
    precondition {
      condition     = length(local.tagged_with_appr) == 0
      error_message = "stop_tagged has no approval step, because it runs through an SNS topic. Leave approval_model as AUTOMATIC. Check: ${join(", ", local.tagged_with_appr)}."
    }
    precondition {
      condition     = length(local.deny_no_roles) == 0 && length(local.deny_bad_roles) == 0
      error_message = "A deny_policy action needs roles, given as IAM role names and not ARNs. Check: ${join(", ", concat(local.deny_no_roles, local.deny_bad_roles))}."
    }
    precondition {
      condition     = length(local.deny_bad_policy) == 0
      error_message = "policy_arn must be an IAM policy ARN. Check: ${join(", ", local.deny_bad_policy)}."
    }
    precondition {
      condition     = length(local.stop_no_ids) == 0
      error_message = "A stop_ec2 or stop_rds action needs instance_ids. To stop resources by tag, use stop_tagged. Check: ${join(", ", local.stop_no_ids)}."
    }
    precondition {
      condition     = length(local.ec2_bad_ids) == 0 && length(local.rds_bad_ids) == 0
      error_message = "stop_ec2 needs EC2 instance IDs such as i-0123456789abcdef0. stop_rds needs RDS instance identifiers. Check: ${join(", ", concat(local.ec2_bad_ids, local.rds_bad_ids))}."
    }
    precondition {
      condition     = length(local.stop_bad_regions) == 0
      error_message = "region must be an AWS region name such as us-east-1. Check: ${join(", ", local.stop_bad_regions)}."
    }
  }
}

# Native budget actions cost about US$0.10 a day per budget beyond the first two.
check "native_action_budgets" {
  assert {
    condition     = local.native_action_budget_count <= 2
    error_message = "${local.native_action_budget_count} budgets have native actions (deny_policy, stop_ec2, stop_rds). The first two are free. Each further budget costs about US$0.10 a day (about US$3 a month). stop_tagged costs nothing extra."
  }
}

# --- Stop topic (stop_tagged) ---------------------------------------------------

resource "aws_sns_topic" "budget_stop" {
  # checkov:skip=CKV_AWS_26:The topic only carries budget notifications. AWS Budgets cannot publish to the AWS managed SNS key, and a customer managed key would add a key policy to maintain for no secret.
  count = local.has_stop_topic ? 1 : 0

  name = "${var.name_prefix}-budget-stop"
  tags = local.tags
}

resource "aws_sns_topic_policy" "budget_stop" {
  count = local.has_stop_topic ? 1 : 0

  arn = aws_sns_topic.budget_stop[0].arn

  # Same shape as the alert topic policy. The ARN is built from the name so the
  # content is known at plan time.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountOwner"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish",
        ]
        Resource  = local.stop_topic_arn
        Condition = { StringEquals = { "AWS:SourceOwner" = local.account_id } }
      },
      {
        Sid       = "AllowBudgetsPublish"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = local.stop_topic_arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:budgets::${local.account_id}:*" }
        }
      },
    ]
  })
}

# --- Native actions -------------------------------------------------------------

resource "aws_iam_policy" "deny" {
  count = local.create_deny_policy ? 1 : 0

  name        = local.deny_policy_name
  description = "Attached to roles by a budget action when spend passes a threshold."
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyNewSpend"
      Effect   = "Deny"
      Action   = var.deny_policy_actions
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "actions" {
  count = length(local.native_actions) > 0 ? 1 : 0

  name = "${var.name_prefix}-budget-actions"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "actions" {
  count = length(local.native_actions) > 0 ? 1 : 0

  name = "budget-actions"
  role = aws_iam_role.actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        for s in [
          {
            Sid       = "AttachDenyPolicyToListedRoles"
            Effect    = "Allow"
            Action    = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
            Resource  = local.deny_role_arns
            Condition = { ArnEquals = { "iam:PolicyARN" = local.deny_policy_arns } }
          },
        ] : s if length(local.deny_actions) > 0
      ],
      [
        for s in [
          {
            Sid      = "StopListedEc2Instances"
            Effect   = "Allow"
            Action   = "ec2:StopInstances"
            Resource = local.ec2_instance_arns
          },
          {
            Sid      = "DescribeEc2InstanceStatus"
            Effect   = "Allow"
            Action   = "ec2:DescribeInstanceStatus"
            Resource = "*"
          },
        ] : s if length(local.ec2_actions) > 0
      ],
      [
        for s in [
          {
            Sid      = "StopListedRdsInstances"
            Effect   = "Allow"
            Action   = "rds:StopDBInstance"
            Resource = local.rds_instance_arns
          },
          {
            Sid      = "DescribeRdsInstances"
            Effect   = "Allow"
            Action   = "rds:DescribeDBInstances"
            Resource = "*"
          },
        ] : s if length(local.rds_actions) > 0
      ],
      [
        for s in [
          {
            Sid      = "RunSsmStopDocuments"
            Effect   = "Allow"
            Action   = "ssm:StartAutomationExecution"
            Resource = "*"
          },
        ] : s if length(local.ec2_actions) + length(local.rds_actions) > 0
      ],
    )
  })
}

resource "aws_budgets_budget_action" "this" {
  for_each = local.native_actions

  budget_name        = aws_budgets_budget.this[each.value.budget_key].name
  action_type        = each.value.type == "deny_policy" ? "APPLY_IAM_POLICY" : "RUN_SSM_DOCUMENTS"
  approval_model     = each.value.approval_model
  notification_type  = each.value.notification_type
  execution_role_arn = aws_iam_role.actions[0].arn
  tags               = local.tags

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = each.value.threshold_percent
  }

  definition {
    dynamic "iam_action_definition" {
      for_each = each.value.type == "deny_policy" ? [each.value] : []

      content {
        policy_arn = coalesce(iam_action_definition.value.policy_arn, one(aws_iam_policy.deny[*].arn))
        roles      = toset(iam_action_definition.value.roles)
      }
    }

    dynamic "ssm_action_definition" {
      for_each = each.value.type == "deny_policy" ? [] : [each.value]

      content {
        action_sub_type = ssm_action_definition.value.type == "stop_ec2" ? "STOP_EC2_INSTANCES" : "STOP_RDS_INSTANCES"
        instance_ids    = toset(ssm_action_definition.value.instance_ids)
        region          = coalesce(ssm_action_definition.value.region, local.region)
      }
    }
  }

  # The email or SNS subscriber hears when an action runs or needs approval.
  subscriber {
    subscription_type = "SNS"
    address           = var.sns_topic_arn
  }

  depends_on = [aws_iam_role_policy.actions]
}
