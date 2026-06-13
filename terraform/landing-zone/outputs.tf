###############################################################################
# landing-zone — outputs
###############################################################################

output "geo_ou_ids" {
  description = "Map of geo => OU id (attach workload accounts here)."
  value       = { for k, v in aws_organizations_organizational_unit.geo : k => v.id }
}

output "residency_scp_ids" {
  description = "Map of geo => residency SCP id."
  value       = { for k, v in aws_organizations_policy.residency : k => v.id }
}

output "baseline_scp_id" {
  description = "Baseline guardrail SCP id."
  value       = aws_organizations_policy.baseline.id
}

output "state_bucket_eu" {
  description = "EU Terraform state bucket name (in-EU)."
  value       = aws_s3_bucket.state_eu.id
}

output "state_bucket_us" {
  description = "US Terraform state bucket name (in-US)."
  value       = aws_s3_bucket.state_us.id
}

output "permission_set_arns" {
  description = "Map of permission-set name => ARN (empty until sso_instance_arn is set)."
  value       = { for k, v in aws_ssoadmin_permission_set.this : k => v.arn }
}
