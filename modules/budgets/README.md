# budgets

Monthly AWS budgets in US dollars. One budget covers the whole account. You can add budgets for a tag or for a single service. Each budget sends actual-spend and forecast alerts to the SNS topic you pass in.

Actions are opt-in and off by default. A budget can also deny new spend, stop resources or run a stop through the scheduler when it passes a threshold.

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

Actions add more resources. See [Actions](#actions).

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

## Actions

An action responds to a budget instead of only telling you about it. Add `actions` to `account_budget`, to a tag budget or to a service budget. Each action has a name, a `type` and a threshold:

```hcl
account_budget = {
  limit_usd = 100
  actions = {
    deny-new-spend = {
      type              = "deny_policy"
      threshold_percent = 100
      roles             = ["dev-deployer"]
      approval_model    = "MANUAL"
    }
    stop-dev = {
      type              = "stop_tagged"
      threshold_percent = 120
    }
  }
}
```

| Type | What happens at the threshold | Approval |
|---|---|---|
| `deny_policy` | AWS attaches a deny policy to the roles in `roles` | `AUTOMATIC` or `MANUAL` |
| `stop_ec2` | AWS stops the EC2 instances in `instance_ids` | `AUTOMATIC` or `MANUAL` |
| `stop_rds` | AWS stops the RDS instances in `instance_ids` | `AUTOMATIC` or `MANUAL` |
| `stop_tagged` | The scheduler Lambda stops every resource with its schedule tag | None, always automatic |

`notification_type` is `ACTUAL` (default) or `FORECASTED`. `MANUAL` approval sends an approval request to your alert topic, and nothing happens until someone approves it in the Budgets console.

Billing data runs hours behind real spend, so an action is a brake and not a hard limit.

### Deny policy

The module creates one policy, `<name_prefix>-budget-deny`, and attaches it to the roles when the budget passes the threshold. The default policy denies `ec2:RunInstances`, `ec2:StartInstances`, `rds:CreateDBInstance`, `rds:CreateDBCluster`, `rds:StartDBInstance` and `rds:StartDBCluster`. Change the list with `deny_policy_actions`, or bring your own policy with `policy_arn` on the action.

Give role names, not ARNs. Do not list the scheduler's role, because the deny policy would block its start run.

### Stop by instance ID

`stop_ec2` takes EC2 instance IDs. `stop_rds` takes RDS instance identifiers. Both run an AWS Systems Manager document in `region`, which defaults to the provider region. Use these when the resources are fixed. A stopped-and-replaced instance gets a new ID, and the action then stops nothing.

### Stop by tag

`stop_tagged` creates an SNS topic, `<name_prefix>-budget-stop`, and adds a budget notification at the threshold that publishes to it. Pass the `stop_topic_arn` output to the scheduler module as `budget_stop_topic_arn`. The scheduler Lambda then stops everything that carries its schedule tag, found at that moment, so new and replaced resources are covered.

The tag comes from the scheduler module (`tag_key` and `tag_value`), not from this module. Without a scheduler subscribed to the topic, a `stop_tagged` action does nothing.

This path has no approval step, and the module rejects `MANUAL` for it. It costs nothing beyond the Lambda run, because it is a plain notification and not a native action.

### Cost

Budget monitoring and alerts are free. The first two budgets with native actions (`deny_policy`, `stop_ec2`, `stop_rds`) are free in each account. Each further budget costs about US$0.10 a day, about US$3 a month, however many actions it has. The `native_action_budget_count` output shows the number, and Terraform prints a warning when it passes two. Check the current price on the AWS Budgets pricing page.

### Permissions

When any native action exists, the module creates the role `<name_prefix>-budget-actions`, which `budgets.amazonaws.com` assumes. Its policy covers only what the actions need:

- Attach and detach the deny policy on the listed roles.
- Stop the listed EC2 and RDS instances, and read their state.
- Start SSM automation, which runs the stop documents. This permission cannot be narrowed to a resource.

The permission list follows AWS examples. Check it on your first apply, because a missing permission shows up when the action runs and not when you create it.

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
- Actions run on billing data, so they are late by hours. An action reacts after the money is spent.
- The module does not reverse actions. When a budget resets, detach the deny policy or start the resources yourself.
- Native actions need the resources and roles to be in the same account as the budget.

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
| [aws_budgets_budget_action.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget_action) | resource |
| [aws_iam_policy.deny](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.actions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.actions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_sns_topic.budget_stop](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.budget_stop](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_budget"></a> [account\_budget](#input\_account\_budget) | The monthly budget for the whole account, in US dollars.<br/>- `limit_usd`: the monthly limit. Must be above zero.<br/>- `alert_thresholds`: alert when actual spend passes each of these percentages of the limit.<br/>- `forecast_thresholds`: alert when forecast spend passes each of these percentages of the limit. AWS needs some spend history before it can forecast, so a new account may get no forecast alert at first.<br/>Each percentage is between 1 and 1000 and appears once per list. AWS allows at most 10 alerts per budget.<br/>- `actions`: opt-in responses to this budget, keyed by a name you choose. Off by default. Each action has:<br/>  - `type`: `deny_policy` attaches a deny policy to `roles`. `stop_ec2` and `stop_rds` stop the `instance_ids` you list. `stop_tagged` stops every resource carrying the scheduler's tag.<br/>  - `threshold_percent` and `notification_type` (`ACTUAL` or `FORECASTED`): when the action fires.<br/>  - `approval_model`: `AUTOMATIC` (default) or `MANUAL`. `stop_tagged` has no approval step and must stay `AUTOMATIC`.<br/>  - `roles` and `policy_arn` (`deny_policy` only): the IAM role names to restrict, and an existing deny policy. Without `policy_arn` the module creates one from `deny_policy_actions`.<br/>  - `instance_ids` and `region` (`stop_ec2` and `stop_rds`): EC2 instance IDs or RDS instance identifiers, in `region` (default: the provider region).<br/>  Every action except `stop_tagged` is a native AWS action. The first two budgets with native actions are free in the account. Each further one costs about US$0.10 a day (about US$3 a month), however many actions it has. | <pre>object({<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>    actions = optional(map(object({<br/>      type              = string<br/>      threshold_percent = number<br/>      notification_type = optional(string, "ACTUAL")<br/>      approval_model    = optional(string, "AUTOMATIC")<br/>      roles             = optional(list(string), [])<br/>      policy_arn        = optional(string)<br/>      instance_ids      = optional(list(string), [])<br/>      region            = optional(string)<br/>    })), {})<br/>  })</pre> | n/a | yes |
| <a name="input_deny_policy_actions"></a> [deny\_policy\_actions](#input\_deny\_policy\_actions) | IAM actions the module-created deny policy blocks. It only exists when a `deny_policy` action has no `policy_arn`. The default stops the roles you list from launching or starting EC2 and RDS resources. A role that runs the scheduler Lambda should not be in the list, or the start run fails. | `list(string)` | <pre>[<br/>  "ec2:RunInstances",<br/>  "ec2:StartInstances",<br/>  "rds:CreateDBInstance",<br/>  "rds:CreateDBCluster",<br/>  "rds:StartDBInstance",<br/>  "rds:StartDBCluster"<br/>]</pre> | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the names of all resources, for example `finops`. | `string` | n/a | yes |
| <a name="input_service_budgets"></a> [service\_budgets](#input\_service\_budgets) | Extra monthly budgets that cover one AWS service. The map key becomes part of the budget name, for example `ec2` gives `finops-service-ec2`.<br/>- `service`: the service name exactly as Cost Explorer shows it, for example `Amazon Elastic Compute Cloud - Compute`.<br/>- `limit_usd`, `alert_thresholds`, `forecast_thresholds`, `actions`: same meaning and rules as in `account_budget`.<br/>AWS matches the name as written and does not reject a wrong one, so a typo gives a budget that never sees any spend. | <pre>map(object({<br/>    service             = string<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>    actions = optional(map(object({<br/>      type              = string<br/>      threshold_percent = number<br/>      notification_type = optional(string, "ACTUAL")<br/>      approval_model    = optional(string, "AUTOMATIC")<br/>      roles             = optional(list(string), [])<br/>      policy_arn        = optional(string)<br/>      instance_ids      = optional(list(string), [])<br/>      region            = optional(string)<br/>    })), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_sns_topic_arn"></a> [sns\_topic\_arn](#input\_sns\_topic\_arn) | ARN of the SNS topic that receives every budget alert, usually the `topic_arn` output of the notifications module. Its policy must let `budgets.amazonaws.com` publish. | `string` | n/a | yes |
| <a name="input_tag_budgets"></a> [tag\_budgets](#input\_tag\_budgets) | Extra monthly budgets that cover only resources with a given tag. The map key becomes part of the budget name, for example `env-dev` gives `finops-tag-env-dev`.<br/>- `tag_key` and `tag_value`: the tag to match. Write the key without the `user:` prefix, the module adds it.<br/>- `limit_usd`, `alert_thresholds`, `forecast_thresholds`, `actions`: same meaning and rules as in `account_budget`.<br/>The tag key must be activated as a cost allocation tag first, and it only matches costs billed after activation. Until then the budget shows no spend. The cost-allocation-tags module activates keys for you. | <pre>map(object({<br/>    tag_key             = string<br/>    tag_value           = string<br/>    limit_usd           = number<br/>    alert_thresholds    = optional(list(number), [50, 80, 100])<br/>    forecast_thresholds = optional(list(number), [100])<br/>    actions = optional(map(object({<br/>      type              = string<br/>      threshold_percent = number<br/>      notification_type = optional(string, "ACTUAL")<br/>      approval_model    = optional(string, "AUTOMATIC")<br/>      roles             = optional(list(string), [])<br/>      policy_arn        = optional(string)<br/>      instance_ids      = optional(list(string), [])<br/>      region            = optional(string)<br/>    })), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to every taggable resource. The module adds `ManagedBy` itself. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_account_budget_arn"></a> [account\_budget\_arn](#output\_account\_budget\_arn) | ARN of the account budget. |
| <a name="output_account_budget_name"></a> [account\_budget\_name](#output\_account\_budget\_name) | Name of the account budget. |
| <a name="output_action_ids"></a> [action\_ids](#output\_action\_ids) | IDs of the native budget actions, keyed `<budget>/<action>`. Budget keys are `account`, `tag-<key>` and `service-<key>`. |
| <a name="output_actions_role_arn"></a> [actions\_role\_arn](#output\_actions\_role\_arn) | ARN of the role AWS Budgets assumes to run native actions, or null when there are none. |
| <a name="output_deny_policy_arn"></a> [deny\_policy\_arn](#output\_deny\_policy\_arn) | ARN of the deny policy this module created, or null when every `deny_policy` action brings its own `policy_arn`. |
| <a name="output_native_action_budget_count"></a> [native\_action\_budget\_count](#output\_native\_action\_budget\_count) | Number of budgets that have native actions. The first two are free. Each further one costs about US$0.10 a day. |
| <a name="output_service_budget_names"></a> [service\_budget\_names](#output\_service\_budget\_names) | Names of the service budgets, keyed by the keys of `service_budgets`. |
| <a name="output_stop_topic_arn"></a> [stop\_topic\_arn](#output\_stop\_topic\_arn) | ARN of the SNS topic that `stop_tagged` actions notify, or null when there are none. Pass it to the scheduler module as `budget_stop_topic_arn`. |
| <a name="output_tag_budget_names"></a> [tag\_budget\_names](#output\_tag\_budget\_names) | Names of the tag budgets, keyed by the keys of `tag_budgets`. |
<!-- END_TF_DOCS -->