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
