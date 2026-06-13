###############################################################################
# modules/eks — input variables
#
# A regional, PRIVATE EKS cluster that backs many namespace-cells (ADR-0004),
# with per-AZ Managed Node Groups for the STATEFUL DB tier (ADR-0010), a small
# system MNG, and Karpenter scaffolding for the STATELESS tiers. Pod Identity
# is the workload-identity mechanism (ADR-0011).
###############################################################################

variable "name" {
  description = "Cluster name prefix, e.g. \"kb-eu-prod\"."
  type        = string
}

variable "geo" {
  description = "Jurisdiction (residency boundary)."
  type        = string
  validation {
    condition     = contains(["eu", "us"], var.geo)
    error_message = "geo must be one of: eu, us."
  }
}

variable "env" {
  description = "Environment: dev | stage | prod."
  type        = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "region" {
  description = "AWS region. Must be in-geo (validated against allowed_regions)."
  type        = string
}

variable "allowed_regions" {
  description = "In-geo region allow-list (residency guard, ADR-0007)."
  type        = list(string)
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.31"
}

variable "private_subnet_ids" {
  description = "Private DATA subnet IDs (from the network module), one per AZ."
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the EKS-managed ENIs (intra subnets recommended). Defaults to private if empty."
  type        = list(string)
  default     = []
}

variable "secrets_kms_key_arn" {
  description = "KMS key ARN for EKS secrets envelope encryption (prime directive #5)."
  type        = string
  default     = null
}

variable "endpoint_private_access" {
  description = "Enable the private API endpoint (should be true)."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable the public API endpoint. Default false (private cluster); if true, restrict public_access_cidrs."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "Allowed CIDRs for the public API endpoint (only used if endpoint_public_access)."
  type        = list(string)
  default     = []
}

variable "enabled_cluster_log_types" {
  description = "EKS control-plane log types → CloudWatch (audit layer 1)."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin via EKS Access Entries (SSO permission-set roles, not IAM users)."
  type        = list(string)
  default     = []
}

# One MNG per AZ for the stateful DB tier (AZ-pinned, no Karpenter consolidation).
variable "stateful_node_groups" {
  description = <<-EOT
    Map of stateful DB node groups, one per AZ. Key = logical name (e.g. "db-az-a").
    Each: { subnet_id, instance_types, min_size, max_size, desired_size, disk_size_gib, capacity_type }
    AMI is Graviton/arm64 (ADR-0009). Tainted workload=arcadedb:NoSchedule.
  EOT
  type = map(object({
    subnet_id      = string
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gib  = optional(number, 100)
    capacity_type  = optional(string, "ON_DEMAND")
  }))
  default = {}
}

variable "system_node_group" {
  description = "Small system MNG for add-ons (CoreDNS, controllers, ESO, ADOT)."
  type = object({
    instance_types = optional(list(string), ["m7g.large"])
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gib  = optional(number, 50)
  })
  default = {}
}

variable "enable_karpenter" {
  description = "Create Karpenter controller/node IAM scaffolding for the STATELESS tiers (NodePools applied via GitOps)."
  type        = bool
  default     = true
}

variable "eks_addons" {
  description = "Managed EKS add-ons to install (versions resolved by EKS unless pinned in the LLD)."
  type        = list(string)
  default     = ["coredns", "kube-proxy", "eks-pod-identity-agent", "aws-ebs-csi-driver"]
}

variable "pod_identity_associations" {
  description = "Extra Pod Identity associations: list of { namespace, service_account, role_arn }."
  type = list(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
  default = []
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
