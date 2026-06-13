###############################################################################
# modules/observability — outputs
###############################################################################

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID (ADOT remote_write target)."
  value       = aws_prometheus_workspace.this.id
}

output "amp_prometheus_endpoint" {
  description = "AMP Prometheus endpoint."
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "alerts_sns_topic_arn" {
  description = "SNS topic ARN for alert routing (→ PagerDuty)."
  value       = aws_sns_topic.alerts.arn
}

output "platform_log_group_name" {
  description = "Platform CloudWatch log group name."
  value       = aws_cloudwatch_log_group.platform.name
}

output "cell_log_group_names" {
  description = "Map of cell id => CloudWatch log group name."
  value       = { for k, v in aws_cloudwatch_log_group.cells : k => v.name }
}

output "grafana_endpoint" {
  description = "AMG workspace endpoint (null if disabled)."
  value       = var.enable_grafana ? aws_grafana_workspace.this[0].endpoint : null
}
