###############################################################################
# modules/backup-dr — outputs
###############################################################################

output "backup_bucket_name" {
  description = "Primary in-geo backup S3 bucket name (CronJob sidecar writes here)."
  value       = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  description = "Primary backup bucket ARN."
  value       = aws_s3_bucket.backups.arn
}

output "backup_vault_arn" {
  description = "AWS Backup vault ARN (use as a copy destination from the other region's plan)."
  value       = aws_backup_vault.this.arn
}

output "backup_vault_name" {
  description = "AWS Backup vault name."
  value       = aws_backup_vault.this.name
}

output "replication_enabled" {
  description = "Whether in-geo CRR is configured."
  value       = var.dr_bucket_arn != null
}

output "object_lock_enabled" {
  description = "Whether S3 Object Lock (WORM) is enabled."
  value       = var.enable_object_lock
}
