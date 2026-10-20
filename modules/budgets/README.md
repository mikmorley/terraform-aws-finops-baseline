# budgets

Monthly AWS budgets in US dollars. One budget covers the whole account. You can add budgets for a tag or for a single service. Each budget sends actual-spend and forecast alerts to the SNS topic you pass in.

This version only alerts. Budget actions come in a later release.

```hcl
module "budgets" {
  source = "<owner>/finops-baseline/aws//modules/budgets"

  name_prefix   = "finops"
  sns_topic_arn = module.notifications.topic_arn

  account_budget = {
    limit_usd = 100
  }

  tag_budgets = {
    env-dev = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
  }

  service_budgets = {
    ec2 = { service = "Amazon Elastic Compute Cloud - Compute", limit_usd = 40 }
  }

  tags = { Project = "acme" }
}
```

## What it creates

One `aws_budgets_budget` per entry. Each is a monthly cost budget in USD.

| Budget | Name | Covers |
|---|---|---|
| Account | `<name_prefix>-account` | All costs in the account |
| Tag, one per `tag_budgets` key | `<name_prefix>-tag-<key>` | Costs of resources with one tag key and value |
| Service, one per `service_budgets` key | `<name_prefix>-service-<key>` | Costs of one AWS service |

Filtered budgets overlap with the account budget. A cost counts once in the account budget and again in every filtered budget that matches it.

## Alerts

Each budget has two lists of percentages:

- `alert_thresholds` fires when actual spend goes above that share of the limit. The default is 50, 80 and 100.
- `forecast_thresholds` fires when AWS forecasts that month-end spend will go above that share. The default is 100.

Pass `[]` to turn a list off. A budget needs at least one alert, and AWS allows at most 10 per budget. Percentages run from 1 to 1000, so `200` alerts at twice the limit.

Every alert goes to the SNS topic and nowhere else. The topic policy must let `budgets.amazonaws.com` publish, and the notifications module sets that up. If the topic uses a customer managed KMS key, the key policy must allow Budgets too.

AWS needs some spend history to forecast, so a new account may get no forecast alert for its first weeks.

## Tag budgets

The module filters on `TagKeyValue` with the value `user:<tag_key>$<tag_value>`. Write `tag_key` without the `user:` prefix. Neither the key nor the value may contain `$`.

A tag filter only works after you activate the tag key as a cost allocation tag. Activation is not retroactive, and the data can take up to 24 hours to show. Until then the budget reports no spend and never alerts. The cost-allocation-tags module activates keys, but AWS refuses to activate a key that no billed resource has used yet.

## Service budgets

`service` is the name Cost Explorer shows, for example `Amazon Elastic Compute Cloud - Compute` or `Amazon Relational Database Service`. Copy it from the Service filter in Cost Explorer. AWS does not reject an unknown name. A typo gives a budget that never sees any spend.

## Provider region

The module has no provider block and does not set the per-resource `region` argument. Budgets is a global service, and the AWS provider picks its endpoint. If your default region differs from the one you want, for example because the topic lives elsewhere, pass an aliased provider to the module:

```hcl
module "budgets" {
  source    = "<owner>/finops-baseline/aws//modules/budgets"
  providers = { aws = aws.us_east_1 }
  # ...
}
```

## Limitations

- Budget alerts run hours behind real spend. Do not treat them as a real-time stop.
- The module leaves the cost type settings (taxes, credits, refunds, amortization) unset, so AWS applies its defaults. It does not expose them yet.
- Names are fixed by the prefix and the map key. Renaming a key replaces that budget.
- No budget actions yet. The module only sends alerts.

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
| [aws_budgets_budget.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_budget"></a> [account\_budget](#input\_account\_budget) | The monthly budget for the whole account, in US dollars.<br/>- `limit_usd`: the monthly limit. Must be above zero.<br/>- `alert_thresholds`: alert when actual spend passes each of these percentages of the limit.<br/>- `forecast_thresholds`: alert when forecast spend passes each of these percentages of the limit. AWS needs some spend history before it can forecast, so a new account may get no forecast alert at first.<br/>Each percentage is between 1 and 1000 and appears once per list. AWS allows at most 10 alerts per budget. | <pre>object({<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>  })</pre> | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_service_budgets"></a> [service\_budgets](#input\_service\_budgets) | Extra monthly budgets that cover one AWS service. The map key becomes part of the budget name, for example `ec2` gives `finops-service-ec2`.<br/>- `service`: the service name exactly as Cost Explorer shows it, for example `Amazon Elastic Compute Cloud - Compute`.<br/>- `limit_usd`, `alert_thresholds`, `forecast_thresholds`: same meaning and rules as in `account_budget`.<br/>AWS matches the name as written and does not reject a wrong one, so a typo gives a budget that never sees any spend. | <pre>map(object({<br/>    service             = string<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>  }))</pre> | `{}` | no |
| <a name="input_sns_topic_arn"></a> [sns\_topic\_arn](#input\_sns\_topic\_arn) | ARN of the SNS topic that receives every budget alert, usually the `topic_arn` output of the notifications module. Its policy must let `budgets.amazonaws.com` publish. | `string` | n/a | yes |
| <a name="input_tag_budgets"></a> [tag\_budgets](#input\_tag\_budgets) | Extra monthly budgets that cover only resources with a given tag. The map key becomes part of the budget name, for example `env-dev` gives `finops-tag-env-dev`.<br/>- `tag_key` and `tag_value`: the tag to match. Write the key without the `user:` prefix, the module adds it.<br/>- `limit_usd`, `alert_thresholds`, `forecast_thresholds`: same meaning and rules as in `account_budget`.<br/>The tag key must be activated as a cost allocation tag first, and it only matches costs billed after activation. Until then the budget shows no spend. The cost-allocation-tags module activates keys for you. | <pre>map(object({<br/>    tag_key             = string<br/>    tag_value           = string<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_account_budget_arn"></a> [account\_budget\_arn](#output\_account\_budget\_arn) | ARN of the account budget. |
| <a name="output_account_budget_name"></a> [account\_budget\_name](#output\_account\_budget\_name) | Name of the account budget. |
| <a name="output_service_budget_names"></a> [service\_budget\_names](#output\_service\_budget\_names) | Names of the service budgets, keyed by the keys of `service_budgets`. |
| <a name="output_tag_budget_names"></a> [tag\_budget\_names](#output\_tag\_budget\_names) | Names of the tag budgets, keyed by the keys of `tag_budgets`. |
<!-- END_TF_DOCS -->