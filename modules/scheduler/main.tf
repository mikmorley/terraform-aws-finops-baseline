data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { ManagedBy = "terraform-aws-finops-baseline" })

  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  function_name  = "${var.name_prefix}-scheduler"
  log_group_name = "/aws/lambda/${local.function_name}"
  log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"
  # Built from the name so the policy content is known at plan time and tests can read it.
  function_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.function_name}"

  manages_ec2 = contains(var.resource_types, "ec2")
  manages_rds = contains(var.resource_types, "rds")

  # Stop and start are limited to resources that carry the schedule tag.
  tag_condition = { StringEquals = { "aws:ResourceTag/${var.tag_key}" = var.tag_value } }

  schedules = {
    stop  = var.stop_cron
    start = var.start_cron
  }
}

# --- Lambda ---------------------------------------------------------------------

data "archive_file" "scheduler" {
  type             = "zip"
  source_dir       = "${path.module}/../../lambda/scheduler"
  output_path      = "${path.module}/.build/scheduler.zip"
  output_file_mode = "0666"
  excludes         = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "scheduler" {
  # checkov:skip=CKV_AWS_158:Logs hold resource IDs and reasons only. The default CloudWatch encryption is enough for a single-account baseline.
  # checkov:skip=CKV_AWS_338:Retention is a user setting (default 30 days). Forcing a year of logs would add cost for no benefit here.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "scheduler" {
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

resource "aws_iam_role_policy" "scheduler" {
  name = "scheduler"
  role = aws_iam_role.scheduler.id

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
          Sid      = "PublishSummary"
          Effect   = "Allow"
          Action   = "sns:Publish"
          Resource = var.sns_topic_arn
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
      # The describe calls do not support resource-level permissions.
      [
        for s in [
          {
            Sid      = "DescribeEc2"
            Effect   = "Allow"
            Action   = "ec2:DescribeInstances"
            Resource = "*"
          },
          {
            Sid       = "StopStartTaggedEc2"
            Effect    = "Allow"
            Action    = ["ec2:StopInstances", "ec2:StartInstances"]
            Resource  = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"
            Condition = local.tag_condition
          },
        ] : s if local.manages_ec2
      ],
      [
        for s in [
          {
            Sid      = "DescribeRds"
            Effect   = "Allow"
            Action   = ["rds:DescribeDBInstances", "rds:DescribeDBClusters"]
            Resource = "*"
          },
          {
            Sid       = "StopStartTaggedRdsInstances"
            Effect    = "Allow"
            Action    = ["rds:StopDBInstance", "rds:StartDBInstance"]
            Resource  = "arn:${local.partition}:rds:${local.region}:${local.account_id}:db:*"
            Condition = local.tag_condition
          },
          {
            Sid       = "StopStartTaggedAuroraClusters"
            Effect    = "Allow"
            Action    = ["rds:StopDBCluster", "rds:StartDBCluster"]
            Resource  = "arn:${local.partition}:rds:${local.region}:${local.account_id}:cluster:*"
            Condition = local.tag_condition
          },
        ] : s if local.manages_rds
      ],
    )
  })
}

resource "aws_lambda_function" "scheduler" {
  # checkov:skip=CKV_AWS_116:Scheduler retries failed invocations and SNS retries budget stops. A dead-letter queue would add a resource to run for a function that reports in its own summary.
  # checkov:skip=CKV_AWS_117:The function only calls AWS APIs. A VPC would need a NAT gateway or endpoints, which cost far more than this module saves.
  # checkov:skip=CKV_AWS_115:Reserved concurrency is the reserved_concurrency variable. It defaults to none because a reservation fails in new accounts.
  # checkov:skip=CKV_AWS_272:Code signing is out of scope. The code ships in this module and is packaged by Terraform.
  # checkov:skip=CKV_AWS_50:X-Ray tracing needs extra IAM permissions and adds cost. The logs and the SNS summary show every run.
  # checkov:skip=CKV_AWS_173:The environment holds the tag and the topic ARN only, nothing secret.
  function_name                  = local.function_name
  description                    = "Stops and starts tagged EC2, RDS and Aurora resources on a schedule."
  role                           = aws_iam_role.scheduler.arn
  runtime                        = "python3.13"
  handler                        = "handler.lambda_handler"
  architectures                  = ["arm64"]
  timeout                        = 300
  memory_size                    = 128
  reserved_concurrent_executions = var.reserved_concurrency
  filename                       = data.archive_file.scheduler.output_path
  source_code_hash               = data.archive_file.scheduler.output_base64sha256
  tags                           = local.tags

  environment {
    variables = {
      LOG_LEVEL      = var.log_level
      TAG_KEY        = var.tag_key
      TAG_VALUE      = var.tag_value
      RESOURCE_TYPES = join(",", var.resource_types)
      SNS_TOPIC_ARN  = var.sns_topic_arn
      DRY_RUN        = tostring(var.dry_run)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.scheduler.name
  }

  depends_on = [aws_iam_role_policy.scheduler]
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
  name = "invoke-scheduler-lambda"
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
  # checkov:skip=CKV_AWS_297:The schedule input holds only the action and the dry-run flag. A customer managed key would add cost and a key policy to keep for no secret.
  for_each = local.schedules

  name                         = "${local.function_name}-${each.key}"
  description                  = "Runs the ${each.key} action of the finops scheduler."
  schedule_expression          = each.value
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scheduler.arn
    role_arn = aws_iam_role.schedule.arn
    input    = jsonencode({ action = each.key, dry_run = var.dry_run })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }

  depends_on = [aws_iam_role_policy.schedule]
}

# --- Budget stop path -----------------------------------------------------------

resource "aws_lambda_permission" "budget_stop" {
  count = var.budget_stop_enabled ? 1 : 0

  statement_id  = "AllowInvokeFromBudgetStopTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.budget_stop_topic_arn

  lifecycle {
    precondition {
      condition     = var.budget_stop_topic_arn != null
      error_message = "budget_stop_enabled needs budget_stop_topic_arn."
    }
  }
}

resource "aws_sns_topic_subscription" "budget_stop" {
  count = var.budget_stop_enabled ? 1 : 0

  topic_arn = var.budget_stop_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.scheduler.arn

  depends_on = [aws_lambda_permission.budget_stop]
}
