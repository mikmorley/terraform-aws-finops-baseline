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
  description = "ARN of the SNS topic that receives the summary after each run, usually the `topic_arn` output of the notifications module."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]{1,256}$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN, such as arn:aws:sns:us-east-1:123456789012:finops-alerts."
  }
}

variable "sns_kms_key_arn" {
  description = "ARN of the customer managed KMS key that encrypts the SNS topic, if it has one. The scheduler Lambda gets permission to use it so it can publish."
  type        = string
  default     = null

  validation {
    condition     = var.sns_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.sns_kms_key_arn))
    error_message = "sns_kms_key_arn must be a KMS key ARN, such as arn:aws:kms:us-east-1:123456789012:key/<key-id>."
  }
}

variable "tag_key" {
  description = "Key of the tag that marks a resource for scheduling."
  type        = string
  default     = "Schedule"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.:/=+@-]{1,128}$", var.tag_key))
    error_message = "tag_key must be 1 to 128 characters of letters, digits and _ . : / = + - @."
  }
}

variable "tag_value" {
  description = "Value of the tag that marks a resource for scheduling. Resources with the key but another value are left alone."
  type        = string
  default     = "office-hours"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.:/=+@-]{1,256}$", var.tag_value))
    error_message = "tag_value must be 1 to 256 characters of letters, digits and _ . : / = + - @."
  }
}

variable "resource_types" {
  description = "What to stop and start. `ec2` covers EC2 instances. `rds` covers RDS instances and Aurora clusters."
  type        = list(string)
  default     = ["ec2", "rds"]

  validation {
    condition     = length(var.resource_types) > 0 && alltrue([for t in var.resource_types : contains(["ec2", "rds"], t)])
    error_message = "resource_types must list at least one of `ec2` and `rds`."
  }

  validation {
    condition     = length(distinct(var.resource_types)) == length(var.resource_types)
    error_message = "resource_types must not repeat a value."
  }
}

variable "timezone" {
  description = "IANA time zone for both schedules, for example `Australia/Brisbane`. Use `UTC` or a `Region/City` name."
  type        = string
  default     = "UTC"

  validation {
    condition     = can(regex("^(UTC|[A-Za-z_]+(/[A-Za-z0-9_+-]+)+)$", var.timezone))
    error_message = "timezone must be UTC or an IANA name such as Australia/Brisbane."
  }
}

variable "stop_cron" {
  description = "EventBridge Scheduler cron expression for the stop run, evaluated in `timezone`. The default is 19:00 on weekdays."
  type        = string
  default     = "cron(0 19 ? * MON-FRI *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.stop_cron))
    error_message = "stop_cron must be a cron expression such as cron(0 19 ? * MON-FRI *)."
  }
}

variable "start_cron" {
  description = "EventBridge Scheduler cron expression for the start run, evaluated in `timezone`. The default is 07:00 on weekdays."
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.start_cron))
    error_message = "start_cron must be a cron expression such as cron(0 7 ? * MON-FRI *)."
  }
}

variable "dry_run" {
  description = "When true, every run only logs and reports what it would do, and changes nothing. It also applies to stops triggered by `budget_stop_topic_arn`."
  type        = bool
  default     = false
}

variable "budget_stop_topic_arn" {
  description = "ARN of an SNS topic whose messages stop the tagged resources, for example a topic a budget notifies when it passes a threshold. The Lambda treats any message as a stop. There is no approval step on this path. Leave null to turn it off."
  type        = string
  default     = null

  validation {
    condition     = var.budget_stop_topic_arn == null || can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]{1,256}$", var.budget_stop_topic_arn))
    error_message = "budget_stop_topic_arn must be an SNS topic ARN, such as arn:aws:sns:us-east-1:123456789012:finops-budget-stop."
  }
}

variable "reserved_concurrency" {
  description = "Reserved concurrency for the Lambda. The default of -1 reserves nothing. Set it to 1 to stop two runs from overlapping. New AWS accounts have a default limit of 10 concurrent executions, which leaves nothing to reserve, and a reservation then fails at apply time."
  type        = number
  default     = -1

  validation {
    condition     = var.reserved_concurrency >= -1 && floor(var.reserved_concurrency) == var.reserved_concurrency
    error_message = "reserved_concurrency must be a whole number, -1 or higher."
  }
}

variable "log_level" {
  description = "Log level of the scheduler Lambda."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING or ERROR."
  }
}

variable "log_retention_days" {
  description = "Days to keep the scheduler Lambda logs in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts, such as 7, 14, 30 or 90."
  }
}
