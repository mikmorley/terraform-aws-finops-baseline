output "topic_arn" {
  description = "ARN of the SNS topic that receives every alert and report."
  value       = aws_sns_topic.this.arn
}

output "topic_name" {
  description = "Name of the SNS topic."
  value       = aws_sns_topic.this.name
}

output "slack_notifier_function_arn" {
  description = "ARN of the Slack notifier Lambda, or null when Slack is off."
  value       = one(aws_lambda_function.slack_notifier[*].arn)
}

output "slack_notifier_function_name" {
  description = "Name of the Slack notifier Lambda, or null when Slack is off."
  value       = one(aws_lambda_function.slack_notifier[*].function_name)
}

output "slack_notifier_log_group_name" {
  description = "Name of the CloudWatch log group of the Slack notifier Lambda, or null when Slack is off."
  value       = one(aws_cloudwatch_log_group.slack_notifier[*].name)
}
