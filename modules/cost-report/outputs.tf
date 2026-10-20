output "function_arn" {
  description = "ARN of the cost report Lambda."
  value       = aws_lambda_function.cost_report.arn
}

output "function_name" {
  description = "Name of the cost report Lambda. Invoke it by hand to send a report now."
  value       = aws_lambda_function.cost_report.function_name
}

output "log_group_name" {
  description = "Name of the CloudWatch log group of the cost report Lambda."
  value       = aws_cloudwatch_log_group.cost_report.name
}

output "schedule_name" {
  description = "Name of the EventBridge schedule that runs the report."
  value       = aws_scheduler_schedule.this.name
}
