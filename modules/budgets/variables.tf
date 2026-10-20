variable "name_prefix" {
  description = "Prefix for the names of all resources, for example `finops`."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_-]{0,31}$", var.name_prefix))
    error_message = "name_prefix must start with a letter, use only letters, digits, hyphens and underscores, and be at most 32 characters."
  }
}

variable "tags" {
  description = "Tags to apply to every taggable resource. The module adds `ManagedBy` itself."
  type        = map(string)
  default     = {}
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic that receives every budget alert, usually the `topic_arn` output of the notifications module. Its policy must let `budgets.amazonaws.com` publish."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]{1,256}$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN, such as arn:aws:sns:us-east-1:123456789012:finops-alerts."
  }
}

variable "account_budget" {
  description = <<-EOT
    The monthly budget for the whole account, in US dollars.
    - `limit_usd`: the monthly limit. Must be above zero.
    - `alert_thresholds`: alert when actual spend passes each of these percentages of the limit.
    - `forecast_thresholds`: alert when forecast spend passes each of these percentages of the limit. AWS needs some spend history before it can forecast, so a new account may get no forecast alert at first.
    Each percentage is between 1 and 1000 and appears once per list. AWS allows at most 10 alerts per budget.
    - `actions`: opt-in responses to this budget, keyed by a name you choose. Off by default. Each action has:
      - `type`: `deny_policy` attaches a deny policy to `roles`. `stop_ec2` and `stop_rds` stop the `instance_ids` you list. `stop_tagged` stops every resource carrying the scheduler's tag.
      - `threshold_percent` and `notification_type` (`ACTUAL` or `FORECASTED`): when the action fires.
      - `approval_model`: `AUTOMATIC` (default) or `MANUAL`. `stop_tagged` has no approval step and must stay `AUTOMATIC`.
      - `roles` and `policy_arn` (`deny_policy` only): the IAM role names to restrict, and an existing deny policy. Without `policy_arn` the module creates one from `deny_policy_actions`.
      - `instance_ids` and `region` (`stop_ec2` and `stop_rds`): EC2 instance IDs or RDS instance identifiers, in `region` (default: the provider region).
      Every action except `stop_tagged` is a native AWS action. The first two budgets with native actions are free in the account. Each further one costs about US$0.10 a day (about US$3 a month), however many actions it has.
  EOT
  type = object({
    limit_usd           = number
    alert_thresholds    = optional(list(number), [50, 80, 100])
    forecast_thresholds = optional(list(number), [100])
    actions = optional(map(object({
      type              = string
      threshold_percent = number
      notification_type = optional(string, "ACTUAL")
      approval_model    = optional(string, "AUTOMATIC")
      roles             = optional(list(string), [])
      policy_arn        = optional(string)
      instance_ids      = optional(list(string), [])
      region            = optional(string)
    })), {})
  })

  validation {
    condition     = var.account_budget.limit_usd > 0
    error_message = "account_budget.limit_usd must be above zero."
  }

  validation {
    condition = alltrue([
      for t in concat(var.account_budget.alert_thresholds, var.account_budget.forecast_thresholds) : t >= 1 && t <= 1000
    ])
    error_message = "Every threshold in account_budget must be between 1 and 1000 percent."
  }

  validation {
    condition = (
      length(distinct(var.account_budget.alert_thresholds)) == length(var.account_budget.alert_thresholds) &&
      length(distinct(var.account_budget.forecast_thresholds)) == length(var.account_budget.forecast_thresholds)
    )
    error_message = "account_budget thresholds must not repeat within alert_thresholds or within forecast_thresholds."
  }

  validation {
    condition     = length(var.account_budget.alert_thresholds) + length(var.account_budget.forecast_thresholds) >= 1 && length(var.account_budget.alert_thresholds) + length(var.account_budget.forecast_thresholds) <= 10
    error_message = "account_budget needs between 1 and 10 alerts in total (alert_thresholds plus forecast_thresholds)."
  }
}

variable "tag_budgets" {
  description = <<-EOT
    Extra monthly budgets that cover only resources with a given tag. The map key becomes part of the budget name, for example `env-dev` gives `finops-tag-env-dev`.
    - `tag_key` and `tag_value`: the tag to match. Write the key without the `user:` prefix, the module adds it.
    - `limit_usd`, `alert_thresholds`, `forecast_thresholds`, `actions`: same meaning and rules as in `account_budget`.
    The tag key must be activated as a cost allocation tag first, and it only matches costs billed after activation. Until then the budget shows no spend. The cost-allocation-tags module activates keys for you.
  EOT
  type = map(object({
    tag_key             = string
    tag_value           = string
    limit_usd           = number
    alert_thresholds    = optional(list(number), [50, 80, 100])
    forecast_thresholds = optional(list(number), [100])
    actions = optional(map(object({
      type              = string
      threshold_percent = number
      notification_type = optional(string, "ACTUAL")
      approval_model    = optional(string, "AUTOMATIC")
      roles             = optional(list(string), [])
      policy_arn        = optional(string)
      instance_ids      = optional(list(string), [])
      region            = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.tag_budgets : can(regex("^[a-zA-Z0-9_-]{1,40}$", k))])
    error_message = "tag_budgets keys must be 1 to 40 characters of letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue([
      for _, b in var.tag_budgets :
      can(regex("^[^$]{1,128}$", b.tag_key)) && !startswith(b.tag_key, "user:") && can(regex("^[^$]{1,256}$", b.tag_value))
    ])
    error_message = "tag_key and tag_value must not be empty and must not contain `$`. Write tag_key without the `user:` prefix."
  }

  validation {
    condition     = alltrue([for _, b in var.tag_budgets : b.limit_usd > 0])
    error_message = "limit_usd in tag_budgets must be above zero."
  }

  validation {
    condition = alltrue([
      for _, b in var.tag_budgets : alltrue([for t in concat(b.alert_thresholds, b.forecast_thresholds) : t >= 1 && t <= 1000])
    ])
    error_message = "Every threshold in tag_budgets must be between 1 and 1000 percent."
  }

  validation {
    condition = alltrue([
      for _, b in var.tag_budgets :
      length(distinct(b.alert_thresholds)) == length(b.alert_thresholds) && length(distinct(b.forecast_thresholds)) == length(b.forecast_thresholds)
    ])
    error_message = "Thresholds in tag_budgets must not repeat within alert_thresholds or within forecast_thresholds."
  }

  validation {
    condition = alltrue([
      for _, b in var.tag_budgets : length(b.alert_thresholds) + length(b.forecast_thresholds) >= 1 && length(b.alert_thresholds) + length(b.forecast_thresholds) <= 10
    ])
    error_message = "Each entry in tag_budgets needs between 1 and 10 alerts in total (alert_thresholds plus forecast_thresholds)."
  }
}

variable "service_budgets" {
  description = <<-EOT
    Extra monthly budgets that cover one AWS service. The map key becomes part of the budget name, for example `ec2` gives `finops-service-ec2`.
    - `service`: the service name exactly as Cost Explorer shows it, for example `Amazon Elastic Compute Cloud - Compute`.
    - `limit_usd`, `alert_thresholds`, `forecast_thresholds`, `actions`: same meaning and rules as in `account_budget`.
    AWS matches the name as written and does not reject a wrong one, so a typo gives a budget that never sees any spend.
  EOT
  type = map(object({
    service             = string
    limit_usd           = number
    alert_thresholds    = optional(list(number), [50, 80, 100])
    forecast_thresholds = optional(list(number), [100])
    actions = optional(map(object({
      type              = string
      threshold_percent = number
      notification_type = optional(string, "ACTUAL")
      approval_model    = optional(string, "AUTOMATIC")
      roles             = optional(list(string), [])
      policy_arn        = optional(string)
      instance_ids      = optional(list(string), [])
      region            = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.service_budgets : can(regex("^[a-zA-Z0-9_-]{1,40}$", k))])
    error_message = "service_budgets keys must be 1 to 40 characters of letters, digits, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for _, b in var.service_budgets : length(trimspace(b.service)) > 0])
    error_message = "service in service_budgets must not be empty."
  }

  validation {
    condition     = alltrue([for _, b in var.service_budgets : b.limit_usd > 0])
    error_message = "limit_usd in service_budgets must be above zero."
  }

  validation {
    condition = alltrue([
      for _, b in var.service_budgets : alltrue([for t in concat(b.alert_thresholds, b.forecast_thresholds) : t >= 1 && t <= 1000])
    ])
    error_message = "Every threshold in service_budgets must be between 1 and 1000 percent."
  }

  validation {
    condition = alltrue([
      for _, b in var.service_budgets :
      length(distinct(b.alert_thresholds)) == length(b.alert_thresholds) && length(distinct(b.forecast_thresholds)) == length(b.forecast_thresholds)
    ])
    error_message = "Thresholds in service_budgets must not repeat within alert_thresholds or within forecast_thresholds."
  }

  validation {
    condition = alltrue([
      for _, b in var.service_budgets : length(b.alert_thresholds) + length(b.forecast_thresholds) >= 1 && length(b.alert_thresholds) + length(b.forecast_thresholds) <= 10
    ])
    error_message = "Each entry in service_budgets needs between 1 and 10 alerts in total (alert_thresholds plus forecast_thresholds)."
  }
}

variable "deny_policy_actions" {
  description = "IAM actions the module-created deny policy blocks. It only exists when a `deny_policy` action has no `policy_arn`. The default stops the roles you list from launching or starting EC2 and RDS resources. A role that runs the scheduler Lambda should not be in the list, or the start run fails."
  type        = list(string)
  default = [
    "ec2:RunInstances",
    "ec2:StartInstances",
    "rds:CreateDBInstance",
    "rds:CreateDBCluster",
    "rds:StartDBInstance",
    "rds:StartDBCluster",
  ]

  validation {
    condition     = length(var.deny_policy_actions) > 0 && alltrue([for a in var.deny_policy_actions : can(regex("^[a-zA-Z0-9-]+:[a-zA-Z0-9*?]+$", a))])
    error_message = "deny_policy_actions must list at least one IAM action, such as ec2:RunInstances."
  }
}
