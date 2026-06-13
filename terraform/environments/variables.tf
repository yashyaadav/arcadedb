###############################################################################
# environments — shared root config inputs.
#
# This single root config wires network -> eks -> observability -> backup-dr ->
# cell(s). Each geo/env supplies its own values via <geo>-<env>/terraform.tfvars:
#
#   tofu -chdir=terraform/environments plan -var-file=eu-prod/terraform.tfvars
#
# (NOT in the CTO package — plan/apply are post-approval. Here we only validate.)
###############################################################################

variable "geo" {
  type = string
  validation {
    condition     = contains(["eu", "us"], var.geo)
    error_message = "geo must be one of: eu, us."
  }
}

variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "region" {
  type = string
}

variable "dr_region" {
  type = string
}

variable "allowed_regions" {
  type        = list(string)
  description = "In-geo region allow-list (residency)."
}

variable "name" {
  type        = string
  description = "Name prefix, e.g. kb-eu-prod."
}

# ─── Network ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "intra_subnet_cidrs" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type        = bool
  default     = false
  description = "true for non-prod (cost); false for prod (NAT per AZ)."
}

# ─── EKS ────────────────────────────────────────────────────────────────────
variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "db_instance_types" {
  type    = list(string)
  default = ["r7g.2xlarge"]
}

variable "cluster_admin_principal_arns" {
  type    = list(string)
  default = []
}

# ─── Cells ──────────────────────────────────────────────────────────────────
variable "cells" {
  description = "Cells to create in this env. Key = cell_id suffix."
  type = map(object({
    tier                  = optional(string, "standard")
    cell_isolation        = optional(string, "namespace")
    replicas              = optional(number, 3)
    arcadedb_image_tag    = optional(string, "26.4.1")
    arcadedb_image_digest = optional(string, null)
    maxpage_ram_gib       = optional(number, 32)
    heap_gib              = optional(number, 8)
    overhead_gib          = optional(number, 6)
    pod_memory_limit_gib  = optional(number, 46)
    volume_size_gib       = optional(number, 200)
    manage_helm_release   = optional(bool, false) # Argo manages by default (GitOps)
  }))
  default = {}
}

# ─── Backup / DR ────────────────────────────────────────────────────────────
variable "dr_bucket_arn" {
  type    = string
  default = null
}

variable "dr_backup_vault_arn" {
  type    = string
  default = null
}

variable "enable_object_lock" {
  type    = bool
  default = false
}

# ─── Observability ──────────────────────────────────────────────────────────
variable "grafana_admin_group_ids" {
  type    = list(string)
  default = []
}

variable "pagerduty_sns_https_endpoint" {
  type      = string
  default   = null
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
