output "subscription_arn" {
  description = "ARN of the anomaly subscription that publishes to the SNS topic."
  value       = aws_ce_anomaly_subscription.this.arn
}

output "service_monitor_arn" {
  description = "ARN of the service monitor this module created, or null when `create_service_monitor` is false."
  value       = one(aws_ce_anomaly_monitor.service[*].arn)
}

output "tag_monitor_arns" {
  description = "ARNs of the tag monitors, keyed by the keys of `tag_monitors`."
  value       = { for k, m in aws_ce_anomaly_monitor.tag : k => m.arn }
}

output "monitor_arns" {
  description = "ARNs of every monitor the subscription covers: the service monitor, `existing_monitor_arns` and the tag monitors."
  value       = local.monitor_arns
}
