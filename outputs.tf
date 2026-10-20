output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives every alert and report. Subscribe your own endpoints to it if you like."
  value       = module.notifications.topic_arn
}

output "slack_notifier_function_name" {
  description = "Name of the Slack notifier Lambda, or null when Slack is off."
  value       = module.notifications.slack_notifier_function_name
}

output "account_budget_name" {
  description = "Name of the account budget."
  value       = module.budgets.account_budget_name
}

output "tag_budget_names" {
  description = "Names of the tag budgets, keyed by the keys of `tag_budgets`."
  value       = module.budgets.tag_budget_names
}

output "service_budget_names" {
  description = "Names of the service budgets, keyed by the keys of `service_budgets`."
  value       = module.budgets.service_budget_names
}

output "budget_action_ids" {
  description = "IDs of the native budget actions, keyed `<budget>/<action>`. Empty when no action uses a native AWS action."
  value       = module.budgets.action_ids
}

output "native_action_budget_count" {
  description = "Number of budgets with native actions. The first two are free. Each further one costs about US$0.10 a day."
  value       = module.budgets.native_action_budget_count
}

output "anomaly_monitor_arns" {
  description = "ARNs of the anomaly monitors the subscription covers, or an empty list when anomaly detection is off."
  value       = flatten(module.anomaly_detection[*].monitor_arns)
}

output "anomaly_subscription_arn" {
  description = "ARN of the anomaly subscription, or null when anomaly detection is off."
  value       = one(module.anomaly_detection[*].subscription_arn)
}

output "active_cost_allocation_tag_keys" {
  description = "Tag keys the module activates as cost allocation tags."
  value       = flatten(module.cost_allocation_tags[*].active_tag_keys)
}

output "scheduler_function_name" {
  description = "Name of the scheduler Lambda, or null when the scheduler is off."
  value       = one(module.scheduler[*].function_name)
}

output "scheduler_schedule_names" {
  description = "Names of the stop and start schedules, keyed `stop` and `start`. Empty when the scheduler is off."
  value       = one(module.scheduler[*].schedule_names) == null ? {} : one(module.scheduler[*].schedule_names)
}

output "cost_report_function_name" {
  description = "Name of the cost report Lambda, or null when the report is off. Invoke it by hand to send a report now."
  value       = one(module.cost_report[*].function_name)
}

output "cost_report_schedule_name" {
  description = "Name of the cost report schedule, or null when the report is off."
  value       = one(module.cost_report[*].schedule_name)
}
