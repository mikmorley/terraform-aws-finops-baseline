output "sns_topic_arn" {
  description = "Topic that receives every alert and report."
  value       = module.finops.sns_topic_arn
}

output "account_budget_name" {
  description = "Name of the account budget."
  value       = module.finops.account_budget_name
}

output "native_action_budget_count" {
  description = "Budgets with native actions. The first two are free."
  value       = module.finops.native_action_budget_count
}

output "scheduler_function_name" {
  description = "Scheduler Lambda."
  value       = module.finops.scheduler_function_name
}

output "cost_report_function_name" {
  description = "Cost report Lambda. Invoke it by hand to send a report now."
  value       = module.finops.cost_report_function_name
}
