###############################################################################
# modules/backup-dr — input variables
#
# Layered backup + DR (HLD §7.4, ADR-0014/0015/0016):
#   (A) hot per-DB ZIP -> S3 (SSE-KMS, versioned, in-geo CRR, Object Lock for ent)
#   (B) AWS Backup EBS snapshots (KMS, in-geo copy to the DR vault)
# Residency: CRR + snapshot copy destinations MUST be in-geo (prime directive #1).
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix, e.g. \"kb-eu-prod\"."
}

variable "geo" {
  type        = string
  description = "Jurisdiction (residency boundary)."
  validation {
    condition     = contains(["eu", "us"], var.geo)
    error_message = "geo must be one of: eu, us."
  }
}

variable "env" {
  type        = string
  description = "Environment: dev | stage | prod."
}

variable "region" {
  type        = string
  description = "Primary region (must be in-geo)."
}

variable "dr_region" {
  type        = string
  description = "In-geo DR region for CRR + snapshot copies (MUST be in allowed_regions)."
}

variable "allowed_regions" {
  type        = list(string)
  description = "In-geo region allow-list. Both region and dr_region must be members (ADR-0007)."
}

variable "backup_kms_key_arn" {
  type        = string
  description = "KMS key ARN for the backup S3 bucket + AWS Backup vault (prime directive #5)."
}

variable "dr_bucket_arn" {
  type        = string
  description = "ARN of the IN-GEO DR replica bucket (created by a backup-dr instance in dr_region). Null disables CRR."
  default     = null
}

variable "dr_bucket_kms_key_arn" {
  type        = string
  description = "KMS key ARN in the DR region for replicated objects."
  default     = null
}

variable "dr_backup_vault_arn" {
  type        = string
  description = "AWS Backup vault ARN in the DR region for snapshot copies. Null disables copy."
  default     = null
}

variable "enable_object_lock" {
  type        = bool
  description = "Enable S3 Object Lock (WORM) — recommended for enterprise retention (ADR-0015)."
  default     = false
}

variable "object_lock_retention_days" {
  type        = number
  description = "Object Lock COMPLIANCE retention (days) when enabled."
  default     = 35
}

variable "standard_retention_days" {
  type        = number
  description = "Lifecycle expiration for standard-tier backups."
  default     = 30
}

variable "enterprise_retention_days" {
  type        = number
  description = "Lifecycle expiration for enterprise-tier backups (prefix enterprise/*)."
  default     = 365
}

variable "snapshot_schedule" {
  type        = string
  description = "AWS Backup cron for EBS snapshots (every ~6h)."
  default     = "cron(0 0,6,12,18 * * ? *)"
}

variable "snapshot_retention_days" {
  type        = number
  description = "AWS Backup snapshot retention (days)."
  default     = 14
}

variable "enable_backup_vault_lock" {
  type        = bool
  description = "Apply AWS Backup Vault Lock (immutability) — enterprise/compliance."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource."
  default     = {}
}
