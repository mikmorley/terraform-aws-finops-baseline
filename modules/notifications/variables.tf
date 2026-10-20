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

variable "emails" {
  description = "Email addresses to subscribe to the topic. Each recipient must confirm the subscription before alerts arrive."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for email in var.emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Every entry in emails must be a valid email address."
  }
}

variable "slack_webhook_ssm_param" {
  description = "Name of an existing SSM SecureString parameter that holds a Slack incoming webhook URL, for example `/finops/slack-webhook`. It must start with `/` and live in the same region as the notifier Lambda. The module never accepts the URL itself. Leave null to skip Slack."
  type        = string
  default     = null

  validation {
    condition     = var.slack_webhook_ssm_param == null || can(regex("^/[a-zA-Z0-9_./-]*[a-zA-Z0-9_.-]$", var.slack_webhook_ssm_param))
    error_message = "slack_webhook_ssm_param must be a parameter name that starts with `/` and does not end with `/`, such as /finops/slack-webhook."
  }
}

variable "ssm_kms_key_arn" {
  description = "ARN of the customer managed KMS key that encrypts the Slack webhook parameter. Set it only if the parameter does not use the default `aws/ssm` key. The notifier Lambda gets `kms:Decrypt` on this key."
  type        = string
  default     = null

  validation {
    condition     = var.ssm_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.ssm_kms_key_arn))
    error_message = "ssm_kms_key_arn must be a KMS key ARN, such as arn:aws:kms:us-east-1:123456789012:key/<key-id>."
  }
}

variable "kms_key_arn" {
  description = "ARN of a customer managed KMS key to encrypt the SNS topic. Null leaves the topic unencrypted. Do not use the AWS managed `alias/aws/sns` key: its policy cannot be edited, so AWS Budgets and Cost Anomaly Detection cannot publish to the topic. The key policy must allow `budgets.amazonaws.com` and `costalerts.amazonaws.com` to call `kms:GenerateDataKey*` and `kms:Decrypt`, or alerts fail silently."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN, such as arn:aws:kms:us-east-1:123456789012:key/<key-id>."
  }
}

variable "log_level" {
  description = "Log level of the Slack notifier Lambda."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING or ERROR."
  }
}

variable "log_retention_days" {
  description = "Days to keep the Slack notifier Lambda logs in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention period that CloudWatch Logs supports, such as 7, 30, 90 or 365."
  }
}
