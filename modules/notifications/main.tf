data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  slack_enabled = var.slack_webhook_ssm_param != null

  topic_name = "${var.name_prefix}-alerts"
  topic_arn  = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${local.topic_name}"

  function_name  = "${var.name_prefix}-slack-notifier"
  log_group_name = "/aws/lambda/${local.function_name}"
  log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"

  ssm_param_arn = local.slack_enabled ? "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.slack_webhook_ssm_param}" : null
}

# --- SNS topic ------------------------------------------------------------------

resource "aws_sns_topic" "this" {
  name              = local.topic_name
  kms_master_key_id = var.kms_key_arn
  tags              = local.tags

  lifecycle {
    precondition {
      condition     = length(var.emails) > 0 || local.slack_enabled
      error_message = "Set at least one notification target: emails or slack_webhook_ssm_param."
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  arn = aws_sns_topic.this.arn

  # The topic ARN is built from its name instead of read from the resource, so the
  # policy content is known at plan time and the tests can inspect it.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Same statement SNS puts on a new topic, so the account keeps full control.
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
        Resource  = local.topic_arn
        Condition = { StringEquals = { "AWS:SourceOwner" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "AllowBudgetsPublish"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = local.topic_arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:*" }
        }
      },
      {
        Sid       = "AllowCostAnomalyDetectionPublish"
        Effect    = "Allow"
        Principal = { Service = "costalerts.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = local.topic_arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.emails)

  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Slack notifier Lambda ------------------------------------------------------

data "archive_file" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  type             = "zip"
  source_dir       = "${path.module}/../../lambda/slack_notifier"
  output_path      = "${path.module}/.build/slack_notifier.zip"
  output_file_mode = "0666"
  excludes         = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  # checkov:skip=CKV_AWS_158:Logs hold alert text only, never the webhook URL. The default CloudWatch encryption is enough for a single-account baseline.
  # checkov:skip=CKV_AWS_338:Retention is a user setting (default 30 days). Forcing a year of logs would add cost for no benefit here.
  count = local.slack_enabled ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  name = local.function_name
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  name = "slack-notifier"
  role = aws_iam_role.slack_notifier[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${local.log_group_arn}:*"
        },
        {
          Sid      = "ReadWebhookParameter"
          Effect   = "Allow"
          Action   = "ssm:GetParameter"
          Resource = local.ssm_param_arn
        },
      ],
      var.ssm_kms_key_arn == null ? [] : [
        {
          Sid      = "DecryptWebhookParameter"
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = var.ssm_kms_key_arn
        },
      ],
    )
  })
}

resource "aws_lambda_function" "slack_notifier" {
  # checkov:skip=CKV_AWS_116:SNS retries failed deliveries. A dead-letter queue would add a resource to run for a Lambda that only posts alerts.
  # checkov:skip=CKV_AWS_117:The function only calls SSM and the Slack webhook. A VPC would need a NAT gateway, which costs far more than this module saves.
  # checkov:skip=CKV_AWS_115:Reserved concurrency fails in new accounts, where the default limit leaves nothing to reserve. SNS delivery is low volume.
  # checkov:skip=CKV_AWS_272:Code signing is out of scope. The code ships in this module and is packaged by Terraform.
  # checkov:skip=CKV_AWS_50:X-Ray tracing needs extra IAM permissions and adds cost. The logs show every invocation, which is enough for a function that posts to a webhook.
  # checkov:skip=CKV_AWS_173:The environment holds the parameter name, not the webhook URL. The URL stays in SSM.
  count = local.slack_enabled ? 1 : 0

  function_name    = local.function_name
  description      = "Posts finops baseline alerts and reports to Slack."
  role             = aws_iam_role.slack_notifier[0].arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  architectures    = ["arm64"]
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.slack_notifier[0].output_path
  source_code_hash = data.archive_file.slack_notifier[0].output_base64sha256
  tags             = local.tags

  environment {
    variables = {
      LOG_LEVEL               = var.log_level
      SLACK_WEBHOOK_SSM_PARAM = var.slack_webhook_ssm_param
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.slack_notifier[0].name
  }

  depends_on = [aws_iam_role_policy.slack_notifier]
}

resource "aws_lambda_permission" "sns_invoke_slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  statement_id  = "AllowInvokeFromSns"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.this.arn
}

resource "aws_sns_topic_subscription" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  topic_arn = aws_sns_topic.this.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier[0].arn

  depends_on = [aws_lambda_permission.sns_invoke_slack_notifier]
}
