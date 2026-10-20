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
  description = "ARN of the SNS topic that receives the report, usually the `topic_arn` output of the notifications module."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]{1,256}$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS topic ARN, such as arn:aws:sns:us-east-1:123456789012:finops-alerts."
  }
}

variable "sns_kms_key_arn" {
  description = "ARN of the customer managed KMS key that encrypts the SNS topic, if it has one. The report Lambda gets permission to use it so it can publish."
  type        = string
  default     = null

  validation {
    condition     = var.sns_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.sns_kms_key_arn))
    error_message = "sns_kms_key_arn must be a KMS key ARN, such as arn:aws:kms:us-east-1:123456789012:key/<key-id>."
  }
}

variable "schedule" {
  description = "EventBridge Scheduler cron expression for the report, evaluated in `timezone`. The default is 09:00 every Monday. Each run makes five Cost Explorer requests at US$0.01 each."
  type        = string
  default     = "cron(0 9 ? * MON *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.schedule))
    error_message = "schedule must be a cron expression such as cron(0 9 ? * MON *)."
  }
}

variable "timezone" {
  description = "IANA time zone for the schedule, for example `Australia/Brisbane`. Use `UTC` or a `Region/City` name."
  type        = string
  default     = "UTC"

  validation {
    condition     = can(regex("^(UTC|[A-Za-z_]+(/[A-Za-z0-9_+-]+)+)$", var.timezone))
    error_message = "timezone must be UTC or an IANA name such as Australia/Brisbane."
  }
}

variable "period_days" {
  description = "Length of the report period in days. The report covers this many days up to yesterday and compares them with the same number of days before. Match it to the schedule: 7 for a weekly report."
  type        = number
  default     = 7

  validation {
    condition     = var.period_days >= 1 && var.period_days <= 31 && floor(var.period_days) == var.period_days
    error_message = "period_days must be a whole number from 1 to 31."
  }
}

variable "budget_name" {
  description = "Name of the account budget to compare spend against, for example the `account_budget_name` output of the budgets module. The Lambda reads its limit when it runs. Leave null to leave the budget out of the report."
  type        = string
  default     = null

  validation {
    condition     = var.budget_name == null || can(regex("^[^:\\\\]{1,100}$", var.budget_name))
    error_message = "budget_name must be 1 to 100 characters and must not contain `:` or `\\`."
  }
}

variable "log_level" {
  description = "Log level of the report Lambda."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING or ERROR."
  }
}

variable "log_retention_days" {
  description = "Days to keep the report Lambda logs in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts, such as 7, 14, 30 or 90."
  }
}
