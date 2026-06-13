###############################################################################
# modules/observability — input variables
#
# AMP (managed Prometheus) + AMG (managed Grafana) + alert rules + CloudWatch
# log groups + SNS→PagerDuty routing (HLD §7.5, ADR-0017). The /prometheus
# MIME-type workaround lives in the ADOT scrape config (helm values), not here.
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
  description = "AWS region (must be in-geo)."
}

variable "allowed_regions" {
  type        = list(string)
  description = "In-geo region allow-list (residency guard, ADR-0007)."
}

variable "logs_kms_key_arn" {
  type        = string
  description = "KMS key ARN for CloudWatch log groups (prime directive #5)."
  default     = null
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention (days)."
  default     = 90
}

variable "cell_log_groups" {
  type        = list(string)
  description = "Per-cell log group suffixes to create (e.g. cell ids). Empty = just the platform group."
  default     = []
}

variable "enable_grafana" {
  type        = bool
  description = "Create the Amazon Managed Grafana workspace (AMG)."
  default     = true
}

variable "grafana_admin_group_ids" {
  type        = list(string)
  description = "IAM Identity Center (SSO) GROUP IDs granted Grafana ADMIN. No IAM users (prime directive: SSO only)."
  default     = []
}

variable "pagerduty_sns_https_endpoint" {
  type        = string
  description = "PagerDuty (or Alertmanager) HTTPS endpoint subscribed to the alerts SNS topic. Null = no subscription."
  default     = null
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource."
  default     = {}
}
