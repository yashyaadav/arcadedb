###############################################################################
# landing-zone — input variables
#
# Org OUs (geo = hard boundary), residency-deny SCPs, baseline guardrail SCP,
# per-geo Terraform state, and IAM Identity Center permission sets.
# Assumes Control Tower + AFT created the org + core accounts (ADR-0005); this
# config layers the geo boundary + state + access on top.
###############################################################################

variable "home_region" {
  type        = string
  description = "Region for global/management resources (org APIs). Convention: us-east-1."
  default     = "us-east-1"
}

variable "organization_root_id" {
  type        = string
  description = "AWS Organizations root id (r-xxxx) created by Control Tower. Geo OUs hang off this."
  default     = "r-PLACEHOLDER"
}

variable "geos" {
  type = map(object({
    ou_display_name = string
    allowed_regions = list(string)
  }))
  description = "Per-geo OU + in-geo region allow-list. The residency SCP denies any other region."
  default = {
    eu = {
      ou_display_name = "Workloads-EU"
      allowed_regions = ["eu-central-1", "eu-west-1"]
    }
    us = {
      ou_display_name = "Workloads-US"
      allowed_regions = ["us-east-1", "us-west-2"]
    }
  }
}

variable "global_service_actions_allowlist" {
  type        = list(string)
  description = "Global (region-agnostic) service action prefixes the residency SCP must NOT deny."
  default = [
    "iam:*", "organizations:*", "route53:*", "route53domains:*",
    "cloudfront:*", "waf:*", "wafv2:*", "shield:*",
    "sts:*", "support:*", "trustedadvisor:*", "globalaccelerator:*",
    "budgets:*", "ce:*", "cur:*", "account:*", "health:*",
  ]
}

variable "eu_state_region" {
  type        = string
  description = "Region for the EU Terraform state bucket (must be in EU)."
  default     = "eu-central-1"
}

variable "us_state_region" {
  type        = string
  description = "Region for the US Terraform state bucket (must be in US)."
  default     = "us-east-1"
}

variable "sso_instance_arn" {
  type        = string
  description = "IAM Identity Center instance ARN. Null = skip permission-set creation (template-validate)."
  default     = null
}

variable "permission_sets" {
  type = map(object({
    description      = string
    session_duration = optional(string, "PT1H")
    managed_policies = list(string)
  }))
  description = "SSO permission sets (no IAM users — prime directive). Attach to accounts in the LLD."
  default = {
    PlatformAdmin = {
      description      = "Full platform admin (break-glass-adjacent; alarmed in prod)."
      session_duration = "PT1H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
    PlatformReadOnly = {
      description      = "Read-only across the platform (default for ops day-to-day)."
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
    BreakGlass = {
      description      = "Emergency access; use is alarmed + reviewed."
      session_duration = "PT1H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource."
  default     = {}
}
