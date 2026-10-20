data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  function_name  = "${var.name_prefix}-cost-report"
  log_group_name = "/aws/lambda/${local.function_name}"
  log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"
  # Built from the name so the policy content is known at plan time and tests can read it.
  function_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.function_name}"
  budget_arn   = var.budget_name == null ? null : "arn:${local.partition}:budgets::${local.account_id}:budget/${var.budget_name}"
}

# --- Lambda ---------------------------------------------------------------------

data "archive_file" "cost_report" {
  type             = "zip"
  source_dir       = "${path.module}/../../lambda/cost_report"
  output_path      = "${path.module}/.build/cost_report.zip"
  output_file_mode = "0666"
  excludes         = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "cost_report" {
  # checkov:skip=CKV_AWS_158:Logs hold spend figures and service names only. The default CloudWatch encryption is enough for a single-account baseline.
  # checkov:skip=CKV_AWS_338:Retention is a user setting (default 30 days). Forcing a year of logs would add cost for no benefit here.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "cost_report" {
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

resource "aws_iam_role_policy" "cost_report" {
  name = "cost-report"
  role = aws_iam_role.cost_report.id

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
          Sid      = "PublishReport"
          Effect   = "Allow"
          Action   = "sns:Publish"
          Resource = var.sns_topic_arn
        },
        {
          # Cost Explorer does not support resource-level permissions.
          Sid      = "ReadCostExplorer"
          Effect   = "Allow"
          Action   = ["ce:GetCostAndUsage", "ce:GetCostForecast", "ce:GetAnomalies"]
          Resource = "*"
        },
      ],
      var.sns_kms_key_arn == null ? [] : [
        {
          Sid      = "UseTopicKey"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
          Resource = var.sns_kms_key_arn
        },
      ],
      var.budget_name == null ? [] : [
        {
          Sid      = "ReadAccountBudget"
          Effect   = "Allow"
          Action   = "budgets:ViewBudget"
          Resource = local.budget_arn
        },
      ],
    )
  })
}

resource "aws_lambda_function" "cost_report" {
  # checkov:skip=CKV_AWS_116:Scheduler retries failed invocations. A dead-letter queue would add a resource to run for a weekly report.
  # checkov:skip=CKV_AWS_117:The function only calls AWS APIs. A VPC would need a NAT gateway or endpoints, which cost far more than this module saves.
  # checkov:skip=CKV_AWS_115:The function runs once a week. Reserved concurrency fails in new accounts, where the default limit leaves nothing to reserve.
  # checkov:skip=CKV_AWS_272:Code signing is out of scope. The code ships in this module and is packaged by Terraform.
  # checkov:skip=CKV_AWS_50:X-Ray tracing needs extra IAM permissions and adds cost. The logs show every run.
  # checkov:skip=CKV_AWS_173:The environment holds the topic ARN, the period and the budget name only, nothing secret.
  function_name    = local.function_name
  description      = "Posts a weekly AWS cost report to the finops baseline SNS topic."
  role             = aws_iam_role.cost_report.arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.cost_report.output_path
  source_code_hash = data.archive_file.cost_report.output_base64sha256
  tags             = local.tags

  environment {
    variables = merge(
      {
        LOG_LEVEL     = var.log_level
        SNS_TOPIC_ARN = var.sns_topic_arn
        PERIOD_DAYS   = tostring(var.period_days)
      },
      var.budget_name == null ? {} : {
        ACCOUNT_ID  = local.account_id
        BUDGET_NAME = var.budget_name
      },
    )
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.cost_report.name
  }

  depends_on = [aws_iam_role_policy.cost_report]
}

# --- EventBridge Scheduler ------------------------------------------------------

resource "aws_iam_role" "schedule" {
  name = "${local.function_name}-schedule"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "schedule" {
  name = "invoke-cost-report-lambda"
  role = aws_iam_role.schedule.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = local.function_arn
    }]
  })
}

resource "aws_scheduler_schedule" "this" {
  # checkov:skip=CKV_AWS_297:The schedule input holds only a fixed trigger label. A customer managed key would add cost and a key policy to keep for no secret.
  name                         = local.function_name
  description                  = "Runs the weekly finops cost report."
  schedule_expression          = var.schedule
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.cost_report.arn
    role_arn = aws_iam_role.schedule.arn
    input    = jsonencode({ trigger = "schedule" })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }

  depends_on = [aws_iam_role_policy.schedule]
}
