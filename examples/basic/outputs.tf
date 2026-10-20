output "sns_topic_arn" {
  description = "Topic that receives every alert and report."
  value       = module.finops.sns_topic_arn
}

output "account_budget_name" {
  description = "Name of the account budget."
  value       = module.finops.account_budget_name
}
