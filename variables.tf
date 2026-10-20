variable "name_prefix" {
  description = "Prefix for the names of all resources, for example `finops`."
  type        = string
  default     = "finops"

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

# --- Notifications --------------------------------------------------------------

variable "notifications" {
  description = <<-EOT
    Where alerts and reports go. At least one of `emails` and `slack_webhook_ssm_param` is required.
    - `emails`: addresses to subscribe to the SNS topic. Each recipient must confirm the subscription.
    - `slack_webhook_ssm_param`: name of an existing SSM SecureString parameter that holds a Slack incoming webhook URL, for example `/finops/slack-webhook`. The module never accepts the URL itself.
    - `ssm_kms_key_arn`: customer managed KMS key that encrypts that parameter, if it does not use the default `aws/ssm` key.
    - `kms_key_arn`: customer managed KMS key for the SNS topic. Its key policy must allow `budgets.amazonaws.com` and `costalerts.amazonaws.com` to call `kms:GenerateDataKey*` and `kms:Decrypt`. Never use the AWS managed `alias/aws/sns` key.
    - `log_level` and `log_retention_days`: for the Slack notifier Lambda.
  EOT
  type = object({
    emails                  = optional(list(string), [])
    slack_webhook_ssm_param = optional(string)
    ssm_kms_key_arn         = optional(string)
    kms_key_arn             = optional(string)
    log_level               = optional(string, "INFO")
    log_retention_days      = optional(number, 30)
  })

  validation {
    condition     = length(var.notifications.emails) > 0 || var.notifications.slack_webhook_ssm_param != null
    error_message = "Set at least one notification target: notifications.emails or notifications.slack_webhook_ssm_param."
  }
}

# --- Budgets --------------------------------------------------------------------

variable "account_budget" {
  description = <<-EOT
    The monthly budget for the whole account, in US dollars.
    - `limit_usd`: the monthly limit. Must be above zero.
    - `alert_thresholds`: alert when actual spend passes each of these percentages of the limit. Default 50, 80 and 100.
    - `forecast_thresholds`: alert when forecast spend passes each of these percentages. Default 100.
    - `actions`: opt-in responses to this budget, keyed by a name you choose. Off by default. Each action has `type` (`deny_policy`, `stop_ec2`, `stop_rds` or `stop_tagged`), `threshold_percent`, `notification_type` (`ACTUAL` or `FORECASTED`), `approval_model` (`AUTOMATIC` or `MANUAL`), and the fields for its type: `roles` and `policy_arn` for `deny_policy`, `instance_ids` and `region` for `stop_ec2` and `stop_rds`. `stop_tagged` has no approval step and needs `scheduler.enabled`. See the budgets module README.
    The first two budgets with native actions are free. Each further one costs about US$0.10 a day.
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
}

variable "tag_budgets" {
  description = "Extra monthly budgets for resources with a tag, keyed by a name you choose. Each entry takes `tag_key`, `tag_value`, `limit_usd` and the same `alert_thresholds`, `forecast_thresholds` and `actions` as `account_budget`. Activate the tag key in `cost_allocation_tag_keys`, or tag budgets see no spend."
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
}

variable "service_budgets" {
  description = "Extra monthly budgets for one AWS service, keyed by a name you choose. Each entry takes `service` (the name Cost Explorer shows, for example `Amazon Elastic Compute Cloud - Compute`), `limit_usd` and the same `alert_thresholds`, `forecast_thresholds` and `actions` as `account_budget`."
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
}

variable "deny_policy_actions" {
  description = "IAM actions the deny policy blocks when a `deny_policy` budget action runs and brings no `policy_arn`. The default stops the listed roles from launching or starting EC2 and RDS resources."
  type        = list(string)
  default = [
    "ec2:RunInstances",
    "ec2:StartInstances",
    "rds:CreateDBInstance",
    "rds:CreateDBCluster",
    "rds:StartDBInstance",
    "rds:StartDBCluster",
  ]
}

# --- Anomaly detection ----------------------------------------------------------

variable "anomaly_detection" {
  description = <<-EOT
    Cost Anomaly Detection. An alert needs an anomaly of at least `min_impact_usd` dollars and at least `min_impact_pct` percent above expected spend.
    - `enabled`: turn the feature on or off. Default on.
    - `min_impact_usd` and `min_impact_pct`: the two thresholds. Defaults 10 and 20.
    - `create_service_monitor`: create the per-service monitor. An account can hold only one, so set false and fill `existing_monitor_arns` if yours already has one.
    - `existing_monitor_arns`: ARNs of monitors that already exist.
    - `tag_monitors`: extra monitors by tag, keyed by a name you choose, each with `tag_key` and `tag_values`.
  EOT
  type = object({
    enabled                = optional(bool, true)
    min_impact_usd         = optional(number, 10)
    min_impact_pct         = optional(number, 20)
    create_service_monitor = optional(bool, true)
    existing_monitor_arns  = optional(list(string), [])
    tag_monitors = optional(map(object({
      tag_key    = string
      tag_values = list(string)
    })), {})
  })
  default = {}
}

# --- Cost allocation tags -------------------------------------------------------

variable "cost_allocation_tag_keys" {
  description = "Tag keys to activate as cost allocation tags, for example `[\"Environment\", \"Project\"]`. Tag budgets and tag monitors need their keys here, or already active. AWS refuses to activate a key that no billed resource has used yet, so tag a resource first."
  type        = list(string)
  default     = []
}

# --- Scheduler ------------------------------------------------------------------

variable "scheduler" {
  description = <<-EOT
    Stops and starts tagged EC2, RDS and Aurora resources outside working hours. Off by default.
    - `enabled`: turn the scheduler on.
    - `timezone`: IANA time zone for both schedules, for example `Australia/Brisbane`.
    - `tag_key` and `tag_value`: the tag that marks a resource for scheduling.
    - `stop_cron` and `start_cron`: `cron()` expressions evaluated in `timezone`.
    - `resource_types`: `ec2`, `rds` or both. `rds` covers RDS instances and Aurora clusters.
    - `dry_run`: report what would happen and change nothing.
    - `reserved_concurrency`: the default -1 reserves nothing. Set 1 to rule out overlapping runs, after raising the account concurrency limit. A reservation fails in new accounts.
    - `log_level` and `log_retention_days`: for the Lambda.
  EOT
  type = object({
    enabled              = optional(bool, false)
    timezone             = optional(string, "UTC")
    tag_key              = optional(string, "Schedule")
    tag_value            = optional(string, "office-hours")
    stop_cron            = optional(string, "cron(0 19 ? * MON-FRI *)")
    start_cron           = optional(string, "cron(0 7 ? * MON-FRI *)")
    resource_types       = optional(list(string), ["ec2", "rds"])
    dry_run              = optional(bool, false)
    reserved_concurrency = optional(number, -1)
    log_level            = optional(string, "INFO")
    log_retention_days   = optional(number, 30)
  })
  default = {}
}

# --- Cost report ----------------------------------------------------------------

variable "cost_report" {
  description = <<-EOT
    A weekly cost report sent to the notification targets. On by default.
    - `enabled`: turn the report on or off.
    - `schedule`: `cron()` expression evaluated in `timezone`. Default 09:00 on Mondays.
    - `timezone`: IANA time zone, for example `Australia/Brisbane`.
    - `period_days`: days the report covers. Match it to the schedule: 7 for weekly.
    - `log_level` and `log_retention_days`: for the Lambda.
    Each run makes five Cost Explorer requests at US$0.01 each.
  EOT
  type = object({
    enabled            = optional(bool, true)
    schedule           = optional(string, "cron(0 9 ? * MON *)")
    timezone           = optional(string, "UTC")
    period_days        = optional(number, 7)
    log_level          = optional(string, "INFO")
    log_retention_days = optional(number, 30)
  })
  default = {}
}
