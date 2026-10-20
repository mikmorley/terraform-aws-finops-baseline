# notifications

One SNS topic for every alert and report in the finops baseline. AWS Budgets, Cost Anomaly Detection, the scheduler and the cost report all publish to it. Email recipients subscribe directly. An optional Lambda forwards each message to a Slack incoming webhook.

The module works on its own:

```hcl
module "notifications" {
  source = "<owner>/finops-baseline/aws//modules/notifications"

  name_prefix = "finops"
  emails      = ["ops@example.com"]

  # Optional. Name of an existing SecureString parameter, never the URL itself.
  slack_webhook_ssm_param = "/finops/slack-webhook"

  tags = { Project = "acme" }
}
```

Set at least one of `emails` or `slack_webhook_ssm_param`. A plan with neither fails.

## What it creates

| Resource | When |
|---|---|
| SNS topic `<name_prefix>-alerts` and its topic policy | Always |
| One email subscription per address | `emails` is set |
| Slack notifier Lambda, IAM role, CloudWatch log group, SNS subscription | `slack_webhook_ssm_param` is set |

The topic policy lets `budgets.amazonaws.com` and `costalerts.amazonaws.com` publish, and only for your account (`aws:SourceAccount`). It also keeps the default statement that gives the account owner full control.

## Email

Each address receives a confirmation email from AWS. Alerts do not arrive until the recipient clicks the link. Terraform cannot confirm the subscription for them.

## Slack

Create the webhook in Slack, then store the URL yourself. The module never sees it, so it never lands in Terraform state:

```sh
aws ssm put-parameter \
  --name /finops/slack-webhook \
  --type SecureString \
  --value 'https://hooks.slack.com/services/...'
```

Create the parameter in the same region as the module. The Lambda reads it with `ssm:GetParameter` when it first runs in a container, then keeps it in memory. The IAM policy covers that one parameter. If you encrypt the parameter with your own KMS key, pass the key as `ssm_kms_key_arn` and the role gets `kms:Decrypt` on it. The default `aws/ssm` key needs nothing extra.

The Lambda uses only the Python standard library and boto3, so Terraform packages it with no build step. Slack gets one message per SNS record. A failed post raises an error, and SNS retries the delivery.

### Message formats

| Message | Source | Slack output |
|---|---|---|
| AWS Budgets notification (plain text) | `aws_budgets_budget` | Budget name, alert type, threshold, amount |
| Cost Anomaly Detection notification (JSON) | `aws_ce_anomaly_subscription` | Service, total impact, root causes, console link |
| `{"kind": "cost_report", ...}` | cost report Lambda | Spend against budget, forecast, top services, biggest change, open anomalies |
| `{"kind": "scheduler_summary", ...}` | scheduler Lambda | Counts of stopped, started, skipped and failed, plus the reason for each skip or failure |
| Anything else | any publisher | The subject and the raw text |

The generic message means an unrecognised or malformed payload still reaches Slack.

Publishers that want a readable email should send the SNS `json` message structure, with the payload under `default` for Lambda and a plain-text version under `email`.

`cost_report` fields: `period`, `month_to_date_usd`, `budget_limit_usd`, `forecast_usd` (may be null), `top_services` (list of `service`, `amount_usd`), `biggest_change` (`service`, `change_usd`, `change_pct`) and `anomalies` (list of `service`, `impact_usd`). Every field is optional. The cost report also sends `notes`, a list of strings about missing data, which the notifier ignores.

`scheduler_summary` fields: `action`, `dry_run`, `counts` (`stopped`, `started`, `skipped`, `failed`) and `details` (list of `resource`, `type`, `outcome`, `reason`). The scheduler also sends `trigger` (`schedule` or `budget`) and `details_omitted`, which the notifier ignores.

## Encryption

The topic is unencrypted by default. Set `kms_key_arn` to a customer managed key to encrypt it. Two rules apply:

- Do not use the AWS managed key `alias/aws/sns`. You cannot edit its key policy, so Budgets and Cost Anomaly Detection cannot publish to the topic.
- The key policy of a customer managed key must allow `budgets.amazonaws.com` and `costalerts.amazonaws.com` to call `kms:GenerateDataKey*` and `kms:Decrypt`. Without that, alerts fail with no error message.

The module does not create or edit the key. It also does not grant itself access to the key, so manage the key policy yourself.

## Provider region

The module has no provider block and does not set the per-resource `region` argument. Resources go to whichever region the calling provider uses. To deploy somewhere other than your default region, pass an aliased provider:

```hcl
module "notifications" {
  source    = "<owner>/finops-baseline/aws//modules/notifications"
  providers = { aws = aws.us_east_1 }
  # ...
}
```

The topic, the Lambda and the SSM parameter all live in the provider's region.

## Limitations

- Budget alerts run hours behind real spend, so Slack and email messages do too.
- Slack formatting follows the message layouts AWS documents. Check the first real budget and anomaly alert against your Slack channel. Any layout the parser misses falls back to the generic message.
- Only Slack incoming webhooks are supported. AWS Chatbot and Microsoft Teams are not.

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
| [aws_cloudwatch_log_group.slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.sns_invoke_slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_sns_topic.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_sns_topic_subscription.slack_notifier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [archive_file.slack_notifier](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_emails"></a> [emails](#input\_emails) | Email addresses to subscribe to the topic. Each recipient must confirm the subscription before alerts arrive. | `list(string)` | `[]` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of a customer managed KMS key to encrypt the SNS topic. Null leaves the topic unencrypted. Do not use the AWS managed `alias/aws/sns` key: its policy cannot be edited, so AWS Budgets and Cost Anomaly Detection cannot publish to the topic. The key policy must allow `budgets.amazonaws.com` and `costalerts.amazonaws.com` to call `kms:GenerateDataKey*` and `kms:Decrypt`, or alerts fail silently. | `string` | `null` | no |
| <a name="input_log_level"></a> [log\_level](#input\_log\_level) | Log level of the Slack notifier Lambda. | `string` | `"INFO"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days to keep the Slack notifier Lambda logs in CloudWatch. | `number` | `30` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_slack_webhook_ssm_param"></a> [slack\_webhook\_ssm\_param](#input\_slack\_webhook\_ssm\_param) | Name of an existing SSM SecureString parameter that holds a Slack incoming webhook URL, for example `/finops/slack-webhook`. It must start with `/` and live in the same region as the notifier Lambda. The module never accepts the URL itself. Leave null to skip Slack. | `string` | `null` | no |
| <a name="input_ssm_kms_key_arn"></a> [ssm\_kms\_key\_arn](#input\_ssm\_kms\_key\_arn) | ARN of the customer managed KMS key that encrypts the Slack webhook parameter. Set it only if the parameter does not use the default `aws/ssm` key. The notifier Lambda gets `kms:Decrypt` on this key. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_slack_notifier_function_arn"></a> [slack\_notifier\_function\_arn](#output\_slack\_notifier\_function\_arn) | ARN of the Slack notifier Lambda, or null when Slack is off. |
| <a name="output_slack_notifier_function_name"></a> [slack\_notifier\_function\_name](#output\_slack\_notifier\_function\_name) | Name of the Slack notifier Lambda, or null when Slack is off. |
| <a name="output_slack_notifier_log_group_name"></a> [slack\_notifier\_log\_group\_name](#output\_slack\_notifier\_log\_group\_name) | Name of the CloudWatch log group of the Slack notifier Lambda, or null when Slack is off. |
| <a name="output_topic_arn"></a> [topic\_arn](#output\_topic\_arn) | ARN of the SNS topic that receives every alert and report. |
| <a name="output_topic_name"></a> [topic\_name](#output\_topic\_name) | Name of the SNS topic. |
<!-- END_TF_DOCS -->
