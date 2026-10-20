# anomaly-detection

AWS Cost Anomaly Detection with noise control. The module creates monitors and one subscription that publishes to your SNS topic. An alert fires only when an anomaly costs at least a set number of dollars **and** at least a set percent above the expected spend. Defaults are US$10 and 20%.

```hcl
module "anomaly_detection" {
  source = "mikmorley/finops-baseline/aws//modules/anomaly-detection"

  name_prefix   = "finops"
  sns_topic_arn = module.notifications.topic_arn

  min_impact_usd = 10
  min_impact_pct = 20

  tags = { Project = "acme" }
}
```

## What it creates

| Resource | When |
|---|---|
| Service monitor `<name_prefix>-service` | `create_service_monitor` is true (the default) |
| One tag monitor `<name_prefix>-tag-<key>` per `tag_monitors` entry | `tag_monitors` is set |
| Subscription `<name_prefix>-anomaly-alerts` | Always |

The subscription covers every monitor the module creates, plus any ARN in `existing_monitor_arns`. A plan fails if there is nothing to monitor.

## Noise control

The subscription uses a threshold expression with two conditions joined by AND:

- `ANOMALY_TOTAL_IMPACT_ABSOLUTE` is greater than or equal to `min_impact_usd`.
- `ANOMALY_TOTAL_IMPACT_PERCENTAGE` is greater than or equal to `min_impact_pct`.

A US$3 spike that doubles a US$3 line item stays quiet, and so does a 2% rise on a large bill. Lower the numbers for more alerts.

The subscription frequency is `IMMEDIATE`. AWS only delivers to SNS at that frequency. DAILY and WEEKLY summaries work for email only. Email recipients still get alerts, because they subscribe to the SNS topic.

## The service monitor limit

An account can hold only one monitor that watches spend per AWS service. Creating a second one fails at apply time. If your account already has one, find its ARN in the Cost Anomaly Detection console and reuse it:

```hcl
module "anomaly_detection" {
  # ...
  create_service_monitor = false
  existing_monitor_arns  = ["arn:aws:ce::123456789012:anomalymonitor/<monitor-id>"]
}
```

## Tag monitors

Each `tag_monitors` entry creates a custom monitor for one tag key and a list of its values:

```hcl
tag_monitors = {
  project = { tag_key = "Project", tag_values = ["acme"] }
}
```

The monitor sees nothing until you activate the tag key as a cost allocation tag. Activation is not retroactive, and the data can take up to 24 hours to show. The cost-allocation-tags module activates keys.

## Provider region

The module has no provider block and does not set the per-resource `region` argument. Cost Anomaly Detection is a global service, and the AWS provider picks its endpoint. If your default region differs from the one you want, pass an aliased provider to the module:

```hcl
module "anomaly_detection" {
  source    = "mikmorley/finops-baseline/aws//modules/anomaly-detection"
  providers = { aws = aws.us_east_1 }
  # ...
}
```

## Limitations

- A new account stays quiet. AWS needs some spend history before it can call something an anomaly.
- AWS detects anomalies from billing data, which runs hours behind real spend. Alerts can arrive up to a day late.
- If the SNS topic uses a customer managed KMS key, its key policy must allow `costalerts.amazonaws.com`. Without that, alerts fail with no error message.
- The tag monitor specification follows the AWS API format. Check the first tag monitor in the console after you apply.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ce_anomaly_monitor.service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ce_anomaly_monitor) | resource |
| [aws_ce_anomaly_monitor.tag](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ce_anomaly_monitor) | resource |
| [aws_ce_anomaly_subscription.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ce_anomaly_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_create_service_monitor"></a> [create\_service\_monitor](#input\_create\_service\_monitor) | Create a monitor that watches spend per AWS service. An account can hold only one monitor of this kind, and creating a second one fails. If the account already has one, set this to false and pass its ARN in `existing_monitor_arns`. | `bool` | `true` | no |
| <a name="input_existing_monitor_arns"></a> [existing\_monitor\_arns](#input\_existing\_monitor\_arns) | ARNs of anomaly monitors that already exist. The subscription alerts on them as well as on the monitors this module creates. | `list(string)` | `[]` | no |
| <a name="input_min_impact_pct"></a> [min\_impact\_pct](#input\_min\_impact\_pct) | Alert only when the total impact of an anomaly is at least this many percent above the expected spend. An anomaly must also reach `min_impact_usd`. | `number` | `20` | no |
| <a name="input_min_impact_usd"></a> [min\_impact\_usd](#input\_min\_impact\_usd) | Alert only when the total dollar impact of an anomaly is at least this much. An anomaly must also reach `min_impact_pct`. | `number` | `10` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_sns_topic_arn"></a> [sns\_topic\_arn](#input\_sns\_topic\_arn) | ARN of the SNS topic that receives every anomaly alert, usually the `topic_arn` output of the notifications module. Its policy must let `costalerts.amazonaws.com` publish. | `string` | n/a | yes |
| <a name="input_tag_monitors"></a> [tag\_monitors](#input\_tag\_monitors) | Extra monitors that watch the cost of resources with a tag. The map key becomes part of the monitor name, for example `project` gives `finops-tag-project`.<br/>- `tag_key`: the tag key, for example `Project`.<br/>- `tag_values`: the tag values to watch. AWS needs at least one.<br/>The tag key must be activated as a cost allocation tag first. Until then the monitor sees no spend. | <pre>map(object({<br/>    tag_key    = string<br/>    tag_values = list(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_monitor_arns"></a> [monitor\_arns](#output\_monitor\_arns) | ARNs of every monitor the subscription covers: the service monitor, `existing_monitor_arns` and the tag monitors. |
| <a name="output_service_monitor_arn"></a> [service\_monitor\_arn](#output\_service\_monitor\_arn) | ARN of the service monitor this module created, or null when `create_service_monitor` is false. |
| <a name="output_subscription_arn"></a> [subscription\_arn](#output\_subscription\_arn) | ARN of the anomaly subscription that publishes to the SNS topic. |
| <a name="output_tag_monitor_arns"></a> [tag\_monitor\_arns](#output\_tag\_monitor\_arns) | ARNs of the tag monitors, keyed by the keys of `tag_monitors`. |
<!-- END_TF_DOCS -->

Part of [terraform-aws-finops-baseline](https://github.com/mikmorley/terraform-aws-finops-baseline) by [Michael Morley](https://morley.cloud).
