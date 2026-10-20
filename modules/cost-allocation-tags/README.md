# cost-allocation-tags

Activates your tag keys as cost allocation tags. Tag budgets and tag-based anomaly monitors only see a tag after it is active.

```hcl
module "cost_allocation_tags" {
  source  = "mikmorley/finops-baseline/aws//modules/cost-allocation-tags"
  version = "~> 0.8.0"

  tag_keys = ["Environment", "Project"]
}
```

The module creates one `aws_ce_cost_allocation_tag` per key, with status `Active`. It has no other inputs and creates nothing else.

## Before you apply

AWS refuses to activate a key that no billed resource has used yet. Tag at least one running resource with each key first. If you apply too early, the apply fails with an error from the Cost Explorer API, and a second apply works once the tag has shown up in billing data.

Activation has three more effects:

- It is not retroactive. Costs from before activation never get the tag.
- The data can take up to 24 hours to show.
- It applies to the whole account, not to this module's resources.

Until the tag has data, a tag budget reports no spend and never alerts, and a tag monitor sees nothing.

## Tag keys

Write each key as it appears on your resources. Do not add the `user:` prefix that the console shows. The module rejects keys that start with it, repeat, or use characters AWS does not allow in tag keys. Keys are case-sensitive, so `project` and `Project` are different tags.

## Provider region

The module has no provider block and does not set the per-resource `region` argument. Cost Explorer is a global service, and the AWS provider picks its endpoint. If your default region differs from the one you want, pass an aliased provider to the module:

```hcl
module "cost_allocation_tags" {
  source    = "mikmorley/finops-baseline/aws//modules/cost-allocation-tags"
  providers = { aws = aws.us_east_1 }
  # ...
}
```

## Limitations

- Terraform cannot tell at plan time whether a key has been seen on a billed resource, so the first apply can fail for a new tag.
- The module does not tag your resources. Add the tags yourself, for example with the `default_tags` block of the AWS provider.

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
| [aws_ce_cost_allocation_tag.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ce_cost_allocation_tag) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_tag_keys"></a> [tag\_keys](#input\_tag\_keys) | Tag keys to activate as cost allocation tags, for example `["Environment", "Project"]`. Write each key as it appears on your resources, without the `user:` prefix. AWS refuses to activate a key that no billed resource has used yet, so tag a resource first. Activation is not retroactive, and the data can take up to 24 hours to show. | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_active_tag_keys"></a> [active\_tag\_keys](#output\_active\_tag\_keys) | Tag keys this module activates as cost allocation tags. |
<!-- END_TF_DOCS -->

Part of [terraform-aws-finops-baseline](https://github.com/mikmorley/terraform-aws-finops-baseline) by [Michael Morley](https://morley.cloud).
