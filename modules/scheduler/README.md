# scheduler

Stops and starts dev resources outside working hours. Tag an EC2 instance, RDS instance or Aurora cluster, and a Lambda stops it in the evening and starts it in the morning. Each run posts a summary to your SNS topic.

```hcl
module "scheduler" {
  source = "mikmorley/finops-baseline/aws//modules/scheduler"

  name_prefix   = "finops"
  sns_topic_arn = module.notifications.topic_arn

  timezone   = "Australia/Brisbane"
  stop_cron  = "cron(0 19 ? * MON-FRI *)"
  start_cron = "cron(0 7 ? * MON-FRI *)"

  tags = { Project = "acme" }
}
```

Then tag what you want scheduled, with the default tag:

```sh
aws ec2 create-tags --resources i-0123456789abcdef0 --tags Key=Schedule,Value=office-hours
```

Start with `dry_run = true`. Every run then reports what it would stop or start and changes nothing.

## What it creates

| Resource | Purpose |
|---|---|
| Lambda `<name_prefix>-scheduler`, its IAM role and CloudWatch log group | Finds tagged resources and stops or starts them |
| EventBridge schedules `<name_prefix>-scheduler-stop` and `-start`, and an IAM role for them | Invoke the Lambda in `timezone` |
| Lambda permission and SNS subscription | Only when `budget_stop_enabled` is true |

The Lambda uses Python 3.13 on arm64 with only the standard library and boto3. Terraform packages it with no build step. It times out after 5 minutes.

## What it stops

A resource is scheduled when it has the tag `tag_key` with the value `tag_value`. The defaults are `Schedule` and `office-hours`. `resource_types` picks the services: `ec2` covers EC2 instances, `rds` covers RDS instances and Aurora clusters.

A stop run acts on running (`available` for RDS) resources. A start run acts on stopped ones. Resources in any other state are left alone.

The Lambda skips resources that AWS cannot stop or that stopping would break. Each skip appears in the summary with its reason:

| Resource | Skipped when |
|---|---|
| EC2 | The instance belongs to an Auto Scaling group (the group would replace it) |
| EC2 | It is a spot instance, or its root volume is instance store |
| RDS instance | It belongs to a cluster (tag the cluster instead) |
| RDS instance | It is a read replica, or it has read replicas |
| Aurora cluster | It is a replica cluster, or it runs Aurora Serverless v1 |

One resource failing does not stop the run. The Lambda records the error as a failure and moves on. It also reports a failure when it cannot list a service, for example because of a missing permission.

## Summary message

After each run that touched or skipped anything, the Lambda publishes to `sns_topic_arn`. Email subscribers get a short text body. The Slack notifier gets a JSON payload and formats it. A run that finds nothing publishes nothing.

A failed publish is logged and does not fail the run, because the changes have already happened.

## IAM

The Lambda role can:

- Write its own log group, and publish to the one SNS topic (plus use the topic key if you pass `sns_kms_key_arn`).
- Call `ec2:DescribeInstances`, `rds:DescribeDBInstances` and `rds:DescribeDBClusters` on `*`. These calls do not support resource-level permissions.
- Stop and start EC2 instances, RDS instances and Aurora clusters in its own account and region, only when the resource carries the schedule tag. An IAM condition on `aws:ResourceTag/<tag_key>` enforces that.

A resource type you leave out of `resource_types` gets no permissions at all.

## Stopping from a budget

Set `budget_stop_enabled = true` and `budget_stop_topic_arn` to an SNS topic and the Lambda subscribes to it. Any message on that topic runs a stop. The budgets module creates such a topic for its `stop_tagged` actions. Pass its `stop_topic_arn` output here, and the tagged resources stop when the budget passes the action's threshold.

There is no approval step on this path. The Lambda stops everything with the tag as soon as the message arrives. Budget alerts run hours behind real spend, so this is a brake and not a hard limit. `dry_run` applies to this path too.

## Reserved concurrency

`reserved_concurrency` defaults to `-1`, which reserves nothing. Two runs can then overlap, for example a budget stop during the evening schedule. Stop and start are safe to repeat, so the worst case is a duplicate call.

Set it to `1` to rule overlap out. New AWS accounts have a default limit of 10 concurrent executions, which leaves nothing to reserve, and a reservation then fails at apply time. Ask AWS to raise the limit first.

## Region

The Lambda only sees EC2 and RDS resources in the region it runs in. For another region, add a second module instance with an aliased provider:

```hcl
module "scheduler_sydney" {
  source    = "mikmorley/finops-baseline/aws//modules/scheduler"
  providers = { aws = aws.sydney }
  # ...
}
```

Use a different `name_prefix` for each instance, because IAM role names are global. The module has no provider block and does not set the per-resource `region` argument.

## Limitations

- A stopped RDS instance or Aurora cluster restarts by itself after 7 days. The next stop run stops it again.
- Stopped resources still cost money for storage. EBS volumes, RDS storage and backups keep billing.
- RDS stops can fail for reasons the Lambda cannot see in advance, for example some Multi-AZ SQL Server setups. The summary lists them as failures.
- Stopping and starting is asynchronous. The Lambda sends the request and does not wait for the resource to change state.
- A resource that is still starting or stopping when the next run begins is left alone until it settles.
- Schedules use `cron()` expressions only. Daylight saving changes follow the time zone.

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
| [aws_cloudwatch_log_group.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.budget_stop](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_scheduler_schedule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_sns_topic_subscription.budget_stop](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [archive_file.scheduler](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_budget_stop_enabled"></a> [budget\_stop\_enabled](#input\_budget\_stop\_enabled) | Subscribe the Lambda to `budget_stop_topic_arn`, so any message on that topic stops the tagged resources. This is a separate switch because Terraform cannot use the ARN of a topic created in the same apply to decide whether to create resources. Set it to true together with `budget_stop_topic_arn`. | `bool` | `false` | no |
| <a name="input_budget_stop_topic_arn"></a> [budget\_stop\_topic\_arn](#input\_budget\_stop\_topic\_arn) | ARN of the SNS topic whose messages stop the tagged resources, for example the `stop_topic_arn` output of the budgets module. The Lambda treats any message as a stop. There is no approval step on this path. Used only when `budget_stop_enabled` is true. | `string` | `null` | no |
| <a name="input_dry_run"></a> [dry\_run](#input\_dry\_run) | When true, every run only logs and reports what it would do, and changes nothing. It also applies to stops triggered by `budget_stop_topic_arn`. | `bool` | `false` | no |
| <a name="input_log_level"></a> [log\_level](#input\_log\_level) | Log level of the scheduler Lambda. | `string` | `"INFO"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days to keep the scheduler Lambda logs in CloudWatch. | `number` | `30` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_reserved_concurrency"></a> [reserved\_concurrency](#input\_reserved\_concurrency) | Reserved concurrency for the Lambda. The default of -1 reserves nothing. Set it to 1 to stop two runs from overlapping. New AWS accounts have a default limit of 10 concurrent executions, which leaves nothing to reserve, and a reservation then fails at apply time. | `number` | `-1` | no |
| <a name="input_resource_types"></a> [resource\_types](#input\_resource\_types) | What to stop and start. `ec2` covers EC2 instances. `rds` covers RDS instances and Aurora clusters. | `list(string)` | <pre>[<br/>  "ec2",<br/>  "rds"<br/>]</pre> | no |
| <a name="input_sns_kms_key_arn"></a> [sns\_kms\_key\_arn](#input\_sns\_kms\_key\_arn) | ARN of the customer managed KMS key that encrypts the SNS topic, if it has one. The scheduler Lambda gets permission to use it so it can publish. | `string` | `null` | no |
| <a name="input_sns_topic_arn"></a> [sns\_topic\_arn](#input\_sns\_topic\_arn) | ARN of the SNS topic that receives the summary after each run, usually the `topic_arn` output of the notifications module. | `string` | n/a | yes |
| <a name="input_start_cron"></a> [start\_cron](#input\_start\_cron) | EventBridge Scheduler cron expression for the start run, evaluated in `timezone`. The default is 07:00 on weekdays. | `string` | `"cron(0 7 ? * MON-FRI *)"` | no |
| <a name="input_stop_cron"></a> [stop\_cron](#input\_stop\_cron) | EventBridge Scheduler cron expression for the stop run, evaluated in `timezone`. The default is 19:00 on weekdays. | `string` | `"cron(0 19 ? * MON-FRI *)"` | no |
| <a name="input_tag_key"></a> [tag\_key](#input\_tag\_key) | Key of the tag that marks a resource for scheduling. | `string` | `"Schedule"` | no |
| <a name="input_tag_value"></a> [tag\_value](#input\_tag\_value) | Value of the tag that marks a resource for scheduling. Resources with the key but another value are left alone. | `string` | `"office-hours"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | IANA time zone for both schedules, for example `Australia/Brisbane`. Use `UTC` or a `Region/City` name. | `string` | `"UTC"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_function_arn"></a> [function\_arn](#output\_function\_arn) | ARN of the scheduler Lambda. |
| <a name="output_function_name"></a> [function\_name](#output\_function\_name) | Name of the scheduler Lambda. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Name of the CloudWatch log group of the scheduler Lambda. |
| <a name="output_schedule_names"></a> [schedule\_names](#output\_schedule\_names) | Names of the two EventBridge schedules, keyed by `stop` and `start`. |
<!-- END_TF_DOCS -->

Part of [terraform-aws-finops-baseline](https://github.com/mikmorley/terraform-aws-finops-baseline) by [Michael Morley](https://morley.cloud).
