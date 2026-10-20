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
  description = "ARN of the SNS topic that receives every anomaly alert, usually the `topic_arn` output of the notifications module. Its policy must let `costalerts.amazonaws.com` publish."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]{1,256}$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN, such as arn:aws:sns:us-east-1:123456789012:finops-alerts."
  }
}

variable "min_impact_usd" {
  description = "Alert only when the total dollar impact of an anomaly is at least this much. An anomaly must also reach `min_impact_pct`."
  type        = number
  default     = 10

  validation {
    condition     = var.min_impact_usd > 0
    error_message = "min_impact_usd must be above zero."
  }
}

variable "min_impact_pct" {
  description = "Alert only when the total impact of an anomaly is at least this many percent above the expected spend. An anomaly must also reach `min_impact_usd`."
  type        = number
  default     = 20

  validation {
    condition     = var.min_impact_pct > 0
    error_message = "min_impact_pct must be above zero."
  }
}

variable "create_service_monitor" {
  description = "Create a monitor that watches spend per AWS service. An account can hold only one monitor of this kind, and creating a second one fails. If the account already has one, set this to false and pass its ARN in `existing_monitor_arns`."
  type        = bool
  default     = true
}

variable "existing_monitor_arns" {
  description = "ARNs of anomaly monitors that already exist. The subscription alerts on them as well as on the monitors this module creates."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.existing_monitor_arns : can(regex("^arn:aws[a-z-]*:ce::[0-9]{12}:anomalymonitor/.+$", arn))])
    error_message = "Every entry in existing_monitor_arns must be an anomaly monitor ARN, such as arn:aws:ce::123456789012:anomalymonitor/<id>."
  }

  validation {
    condition     = length(distinct(var.existing_monitor_arns)) == length(var.existing_monitor_arns)
    error_message = "existing_monitor_arns must not repeat an ARN."
  }
}

variable "tag_monitors" {
  description = <<-EOT
    Extra monitors that watch the cost of resources with a tag. The map key becomes part of the monitor name, for example `project` gives `finops-tag-project`.
    - `tag_key`: the tag key, for example `Project`.
    - `tag_values`: the tag values to watch. AWS needs at least one.
    The tag key must be activated as a cost allocation tag first. Until then the monitor sees no spend.
  EOT
  type = map(object({
    tag_key    = string
    tag_values = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.tag_monitors : can(regex("^[a-zA-Z0-9_-]{1,40}$", k))])
    error_message = "tag_monitors keys must be 1 to 40 characters of letters, digits, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for _, m in var.tag_monitors : length(trimspace(m.tag_key)) > 0 && length(m.tag_key) <= 128])
    error_message = "tag_key in tag_monitors must be 1 to 128 characters."
  }

  validation {
    condition     = alltrue([for _, m in var.tag_monitors : length(m.tag_values) > 0 && alltrue([for v in m.tag_values : length(trimspace(v)) > 0])])
    error_message = "tag_values in tag_monitors needs at least one value, and no value may be empty."
  }
}
