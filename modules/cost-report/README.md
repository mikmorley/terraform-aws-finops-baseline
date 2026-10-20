# cost-report

A weekly AWS cost report. A Lambda reads Cost Explorer once a week and publishes a summary to your SNS topic. Email subscribers get plain text. If you use the notifications module with Slack, the same report appears in your channel.

```hcl
module "cost_report" {
  source = "mikmorley/finops-baseline/aws//modules/cost-report"

  name_prefix   = "finops"
  sns_topic_arn = module.notifications.topic_arn
  budget_name   = module.budgets.account_budget_name

  schedule = "cron(0 9 ? * MON *)"
  timezone = "Australia/Brisbane"

  tags = { Project = "acme" }
}
```

## What the report shows

```
Cost report (2026-10-12 to 2026-10-18)

Month to date: $42.10 of $100.00 budget (42.1%)
Forecast for month end: $97.40

Top services (7 days):
- Amazon Elastic Compute Cloud - Compute: $20.00
- Amazon Simple Storage Service: $2.00

Biggest change against the previous 7 days: Amazon Relational Database Service +$10.00 (+100.0%)

Open anomalies (last 7 days): 1
- Amazon Elastic Compute Cloud - Compute: $15.00
```

- **Month to date** is spend from the first of the month up to yesterday. With `budget_name` set, the report also shows the share of the budget limit. The Lambda reads the limit when it runs, so a limit you change outside Terraform is picked up.
- **Forecast** is month-to-date spend plus the Cost Explorer forecast for the rest of the month. It shows as "not available yet" when AWS has too little history.
- **Top services** are the five biggest by cost over the last `period_days` days. Credits and zero-cost services are left out.
- **Biggest change** is the service whose cost moved most against the same number of days before. It shows no percentage for a service that cost nothing before.
- **Open anomalies** are anomalies from the last 7 days that nobody marked as a false alarm or planned activity in the console.

Figures are unblended cost with no filter, so credits and refunds reduce them. Cost Explorer data for the latest day can be incomplete, which is why the report stops at yesterday. The report never fails on a new account or on the first of the month. Missing data shows as zero or as an empty list, and a note at the bottom says what was missing.

## What it creates

| Resource | Purpose |
|---|---|
| Lambda `<name_prefix>-cost-report`, its IAM role and CloudWatch log group | Builds and publishes the report |
| EventBridge schedule `<name_prefix>-cost-report` and an IAM role for it | Invokes the Lambda in `timezone` |

The Lambda uses Python 3.13 on arm64 with only the standard library and boto3. Terraform packages it with no build step.

## Cost of running it

Every Cost Explorer API request costs US$0.01. One run makes five: three `GetCostAndUsage`, one `GetCostForecast` and one `GetAnomalies`. That is US$0.05 a run, about US$0.22 a month on the weekly default. A daily schedule would cost about US$1.50 a month. The Lambda, logs and SNS add fractions of a cent.

## Schedule

`schedule` is a `cron()` expression evaluated in `timezone`. The default is 09:00 every Monday. Set `period_days` to match: 7 for weekly, 1 for daily. The report covers the `period_days` days before today and compares them with the same number of days before that.

To send a report now, invoke the Lambda by hand with any payload. The function name is in the `function_name` output.

## IAM

The Lambda role can:

- Write its own log group and publish to the one SNS topic. With `sns_kms_key_arn` it can also use the topic key.
- Call `ce:GetCostAndUsage`, `ce:GetCostForecast` and `ce:GetAnomalies`. Cost Explorer does not support resource-level permissions, so these apply to `*`.
- Call `budgets:ViewBudget` on the one budget named in `budget_name`, if you set it.

## Provider region

The Lambda always calls Cost Explorer and Budgets through their `us-east-1` endpoints, whatever region it runs in. It publishes to SNS in its own region, so the topic must be in the same region as the module. The module has no provider block and does not set the per-resource `region` argument. To deploy somewhere else, pass an aliased provider to the module:

```hcl
module "cost_report" {
  source    = "mikmorley/finops-baseline/aws//modules/cost-report"
  providers = { aws = aws.sydney }
  # ...
}
```

## Limitations

- Cost Explorer must be enabled for the account. A brand-new account may return no data for a day or so, and the report shows zeros until it does.
- The report covers the single account the module runs in. Organizations and payer accounts are not supported.
- Forecasts need history. A new account shows "not available yet" for the first weeks.
- The anomalies section only lists what Cost Anomaly Detection has already found. Without the anomaly detection module, or in a quiet account, it shows zero.
- A failed publish makes the run fail so the scheduler can retry it. Other failures, such as a missing budget permission, add a note to the report and do not stop it.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | ~> 2.8.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | ~> 2.8.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.cost_report](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.cost_report](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cost_report](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.cost_report](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_scheduler_schedule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [archive_file.cost_report](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_budget_name"></a> [budget\_name](#input\_budget\_name) | Name of the account budget to compare spend against, for example the `account_budget_name` output of the budgets module. The Lambda reads its limit when it runs. Leave null to leave the budget out of the report. | `string` | `null` | no |
| <a name="input_log_level"></a> [log\_level](#input\_log\_level) | Log level of the report Lambda. | `string` | `"INFO"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days to keep the report Lambda logs in CloudWatch. | `number` | `30` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_period_days"></a> [period\_days](#input\_period\_days) | Length of the report period in days. The report covers this many days up to yesterday and compares them with the same number of days before. Match it to the schedule: 7 for a weekly report. | `number` | `7` | no |
| <a name="input_schedule"></a> [schedule](#input\_schedule) | EventBridge Scheduler cron expression for the report, evaluated in `timezone`. The default is 09:00 every Monday. Each run makes five Cost Explorer requests at US$0.01 each. | `string` | `"cron(0 9 ? * MON *)"` | no |
| <a name="input_sns_kms_key_arn"></a> [sns\_kms\_key\_arn](#input\_sns\_kms\_key\_arn) | ARN of the customer managed KMS key that encrypts the SNS topic, if it has one. The report Lambda gets permission to use it so it can publish. | `string` | `null` | no |
| <a name="input_sns_topic_arn"></a> [sns\_topic\_arn](#input\_sns\_topic\_arn) | ARN of the SNS topic that receives the report, usually the `topic_arn` output of the notifications module. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | IANA time zone for the schedule, for example `Australia/Brisbane`. Use `UTC` or a `Region/City` name. | `string` | `"UTC"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_function_arn"></a> [function\_arn](#output\_function\_arn) | ARN of the cost report Lambda. |
| <a name="output_function_name"></a> [function\_name](#output\_function\_name) | Name of the cost report Lambda. Invoke it by hand to send a report now. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Name of the CloudWatch log group of the cost report Lambda. |
| <a name="output_schedule_name"></a> [schedule\_name](#output\_schedule\_name) | Name of the EventBridge schedule that runs the report. |
<!-- END_TF_DOCS -->