###############################################################################
# modules/cell — input variables
#
# A "cell" = one 3-node ArcadeDB Raft cluster in its own namespace, with its own
# StorageClass, PDB, default-deny NetworkPolicy, resource governance, and backup
# prefix (HLD §5.4). The unit of capacity + blast radius + tenant placement.
#
# Invariants encoded as plan-time preconditions (see main.tf):
#   - quorum: prod replicas >= 3 (prime directive #3)
#   - version floor: ArcadeDB image >= 26.4.1 (ADR-0012)
#   - sizing rule: pod mem limit >= maxPageRAM + heap + overhead (prime directive #7)
#   - residency: region in-geo (ADR-0007)
###############################################################################

variable "cell_id" {
  description = "Unique cell id, e.g. \"kb-eu-prod-std-01\" or \"kb-eu-prod-ent-acme\"."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,50}$", var.cell_id))
    error_message = "cell_id must be lowercase alphanumeric/hyphen, 5-51 chars, starting with a letter."
  }
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
  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "region" {
  type        = string
  description = "AWS region (must be in-geo)."
}

variable "allowed_regions" {
  type        = list(string)
  description = "In-geo region allow-list (residency guard, ADR-0007)."
}

variable "tier" {
  type        = string
  description = "Tenancy tier: standard (pooled) | enterprise (dedicated). Drives txWalFlush + governance defaults."
  default     = "standard"
  validation {
    condition     = contains(["standard", "enterprise"], var.tier)
    error_message = "tier must be one of: standard, enterprise."
  }
}

variable "cell_isolation" {
  type        = string
  description = "namespace (pooled, shared cluster) | cluster (dedicated EKS cluster). ADR-0004."
  default     = "namespace"
  validation {
    condition     = contains(["namespace", "cluster"], var.cell_isolation)
    error_message = "cell_isolation must be one of: namespace, cluster."
  }
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for the cell. Defaults to cell_id."
  default     = null
}

# ─── Quorum / replicas ──────────────────────────────────────────────────────
variable "replicas" {
  type        = number
  description = "ArcadeDB replicas. Prod MUST be >= 3 (quorum); non-prod MAY be 1 (cost)."
  default     = 3
  validation {
    condition     = var.replicas >= 1 && var.replicas <= 7
    error_message = "replicas must be between 1 and 7 (odd numbers recommended for Raft)."
  }
}

variable "pdb_min_available" {
  type        = number
  description = "PodDisruptionBudget minAvailable. Prime directive #3 => 2 for a 3-node cell."
  default     = 2
}

# ─── Image (version floor + digest pinning) ─────────────────────────────────
variable "arcadedb_image_repository" {
  type        = string
  description = "ArcadeDB image repo (mirror into per-region ECR for prod)."
  default     = "arcadedata/arcadedb"
}

variable "arcadedb_image_tag" {
  type        = string
  description = "ArcadeDB image tag. MUST be a semver >= 26.4.1 (ADR-0012). Never \"latest\"."
  default     = "26.4.1"
}

variable "arcadedb_image_digest" {
  type        = string
  description = "Optional image digest (sha256:...) for immutable, tamper-evident deploys (recommended in prod)."
  default     = null
}

# ─── Helm chart ─────────────────────────────────────────────────────────────
variable "manage_helm_release" {
  type        = bool
  description = "If true, this module installs the ArcadeDB Helm release. If false, Argo CD manages it (GitOps, ADR-0021)."
  default     = true
}

variable "chart_repository" {
  type        = string
  description = "Helm repo URL for the ArcadeDB chart (empty if using a local chart path)."
  default     = "https://arcadedata.github.io/arcadedb-helm"
}

variable "chart_name" {
  type        = string
  description = "Helm chart name."
  default     = "arcadedb"
}

variable "chart_version" {
  type        = string
  description = "Pinned Helm chart version (ADR-0012: pin all versions)."
  default     = "0.1.0"
}

variable "local_chart_path" {
  type        = string
  description = "If set, use a local chart path instead of chart_repository (e.g. the repo's helm/arcadedb)."
  default     = null
}

variable "extra_values_yaml" {
  type        = string
  description = "Additional Helm values YAML merged last (per-cell overrides)."
  default     = ""
}

# ─── Memory sizing (the #1 gotcha — prime directive #7) ─────────────────────
variable "maxpage_ram_gib" {
  type        = number
  description = "ArcadeDB off-heap page cache (maxPageRAM), GiB. The bulk of RAM."
  default     = 32
}

variable "heap_gib" {
  type        = number
  description = "JVM heap (-Xmx), GiB. Keep modest."
  default     = 8
}

variable "overhead_gib" {
  type        = number
  description = "JVM/OS/metaspace/vector-index overhead headroom, GiB."
  default     = 6
}

variable "pod_memory_limit_gib" {
  type        = number
  description = "Pod memory LIMIT, GiB. MUST be >= maxPageRAM + heap + overhead (prime directive #7)."
  default     = 46
}

variable "pod_memory_request_gib" {
  type        = number
  description = "Pod memory REQUEST, GiB. Defaults to the limit (Guaranteed QoS) if null."
  default     = null
}

variable "cpu_request" {
  type        = string
  description = "CPU request (e.g. \"4\")."
  default     = "4"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit. NULL recommended — a tight CPU limit starves Raft heartbeats → leader flapping (HLD §5.5)."
  default     = null
}

# ─── Durability (per tier — ADR-0013) ───────────────────────────────────────
variable "tx_wal_flush" {
  type        = number
  description = "ArcadeDB txWalFlush. Null => derived from tier (enterprise=2 fsync, standard=1)."
  default     = null
  validation {
    condition     = var.tx_wal_flush == null || contains([0, 1, 2], var.tx_wal_flush)
    error_message = "tx_wal_flush must be one of: null, 0, 1, 2."
  }
}

# ─── Storage (gp3, KMS, WaitForFirstConsumer — HLD §5.5) ────────────────────
variable "manage_storage_class" {
  type        = bool
  description = "Create the per-cell gp3 KMS StorageClass (set false if a shared one exists)."
  default     = true
}

variable "ebs_kms_key_arn" {
  type        = string
  description = "KMS key ARN for EBS volume encryption (prime directive #5)."
  default     = null
}

variable "volume_size_gib" {
  type        = number
  description = "Per-node EBS volume size (GiB)."
  default     = 200
}

variable "volume_iops" {
  type        = number
  description = "gp3 provisioned IOPS."
  default     = 6000
}

variable "volume_throughput_mibps" {
  type        = number
  description = "gp3 provisioned throughput (MiB/s)."
  default     = 250
}

# ─── Backup prefix (registered with the cell — ADR-0015) ────────────────────
variable "backup_bucket" {
  type        = string
  description = "S3 bucket for hot per-DB ZIP backups (from backup-dr module)."
  default     = null
}

variable "backup_prefix" {
  type        = string
  description = "S3 key prefix for this cell's backups. Defaults to cell/<cell_id>."
  default     = null
}

# ─── Governance ─────────────────────────────────────────────────────────────
variable "enable_default_deny_networkpolicy" {
  type        = bool
  description = "Create a default-deny NetworkPolicy for the cell namespace (cross-tenant containment, ADR-0023)."
  default     = true
}

variable "allowed_ingress_namespaces" {
  type        = list(string)
  description = "Namespaces allowed to reach this cell (control plane, retrieval, observability)."
  default     = ["control-plane", "retrieval", "observability"]
}

variable "enable_resource_quota" {
  type        = bool
  description = "Apply a namespace ResourceQuota (belt-and-braces; the engine has no per-DB quotas — F2)."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Labels/annotations merged onto cell resources."
  default     = {}
}
