output "function_arn" {
  description = "ARN of the scheduler Lambda."
  value       = aws_lambda_function.scheduler.arn
}

output "function_name" {
  description = "Name of the scheduler Lambda."
  value       = aws_lambda_function.scheduler.function_name
}

output "log_group_name" {
  description = "Name of the CloudWatch log group of the scheduler Lambda."
  value       = aws_cloudwatch_log_group.scheduler.name
}

output "schedule_names" {
  description = "Names of the two EventBridge schedules, keyed by `stop` and `start`."
  value       = { for k, s in aws_scheduler_schedule.this : k => s.name }
}
