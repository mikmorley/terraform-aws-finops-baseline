output "account_budget_name" {
  description = "Name of the account budget."
  value       = aws_budgets_budget.this["account"].name
}

output "account_budget_arn" {
  description = "ARN of the account budget."
  value       = aws_budgets_budget.this["account"].arn
}

output "tag_budget_names" {
  description = "Names of the tag budgets, keyed by the keys of `tag_budgets`."
  value       = { for k, _ in var.tag_budgets : k => aws_budgets_budget.this["tag-${k}"].name }
}

output "service_budget_names" {
  description = "Names of the service budgets, keyed by the keys of `service_budgets`."
  value       = { for k, _ in var.service_budgets : k => aws_budgets_budget.this["service-${k}"].name }
}

output "action_ids" {
  description = "IDs of the native budget actions, keyed `<budget>/<action>`. Budget keys are `account`, `tag-<key>` and `service-<key>`."
  value       = { for k, a in aws_budgets_budget_action.this : k => a.action_id }
}

output "native_action_budget_count" {
  description = "Number of budgets that have native actions. The first two are free. Each further one costs about US$0.10 a day."
  value       = local.native_action_budget_count
}

output "stop_topic_arn" {
  description = "ARN of the SNS topic that `stop_tagged` actions notify, or null when there are none. Pass it to the scheduler module as `budget_stop_topic_arn`."
  value       = one(aws_sns_topic.budget_stop[*].arn)
}

output "deny_policy_arn" {
  description = "ARN of the deny policy this module created, or null when every `deny_policy` action brings its own `policy_arn`."
  value       = one(aws_iam_policy.deny[*].arn)
}

output "actions_role_arn" {
  description = "ARN of the role AWS Budgets assumes to run native actions, or null when there are none."
  value       = one(aws_iam_role.actions[*].arn)
}
