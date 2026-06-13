###############################################################################
# modules/cell — one ArcadeDB cell (namespace + StorageClass + Helm + PDB +
# NetworkPolicy + governance).
#
# BOILERPLATE TEMPLATE (CTO package): validate-clean OFFLINE, NOT applied.
# Uses only TYPED kubernetes resources (no kubernetes_manifest) so `tofu
# validate` works without a live cluster.
#
# Invariants enforced as plan-time preconditions:
#   - quorum (prod replicas >= 3)                  prime directive #3
#   - version floor (ArcadeDB >= 26.4.1)           ADR-0012
#   - sizing rule (pod limit >= page+heap+overhead) prime directive #7
#   - residency (region in-geo)                    ADR-0007
###############################################################################

locals {
  namespace     = coalesce(var.namespace, var.cell_id)
  region_in_geo = contains(var.allowed_regions, var.region)
  is_prod       = var.env == "prod"

  # Durability per tier (ADR-0013): enterprise => fsync (2), standard => 1.
  tx_wal_flush = var.tx_wal_flush != null ? var.tx_wal_flush : (var.tier == "enterprise" ? 2 : 1)

  pod_mem_request = coalesce(var.pod_memory_request_gib, var.pod_memory_limit_gib)
  required_mem    = var.maxpage_ram_gib + var.heap_gib + var.overhead_gib

  storage_class_name = "${var.cell_id}-gp3-kms"
  backup_prefix      = coalesce(var.backup_prefix, "cell/${var.cell_id}")

  # Version-floor parse (ADR-0012). null if the tag isn't a clean semver.
  ver         = try(regex("^v?(?P<maj>\\d+)\\.(?P<min>\\d+)\\.(?P<pat>\\d+)", var.arcadedb_image_tag), null)
  ver_num     = local.ver == null ? 0 : (tonumber(local.ver.maj) * 1000000 + tonumber(local.ver.min) * 1000 + tonumber(local.ver.pat))
  floor_num   = 26 * 1000000 + 4 * 1000 + 1 # 26.4.1
  meets_floor = local.ver_num >= local.floor_num

  image_ref = var.arcadedb_image_digest != null ? "${var.arcadedb_image_repository}@${var.arcadedb_image_digest}" : "${var.arcadedb_image_repository}:${var.arcadedb_image_tag}"

  common_labels = merge(var.tags, {
    "app.kubernetes.io/part-of"      = "arcadedb-kb"
    "platform.kb/cell-id"            = var.cell_id
    "platform.kb/geo"                = var.geo
    "platform.kb/env"                = var.env
    "platform.kb/tier"               = var.tier
    "platform.kb/managed-by"         = "opentofu"
    "platform.kb/residency-boundary" = var.geo
  })
}

###############################################################################
# Plan-time invariant guards (fail fast, in-IaC defence in depth)
###############################################################################
resource "terraform_data" "invariants" {
  lifecycle {
    precondition {
      condition     = local.region_in_geo
      error_message = "RESIDENCY VIOLATION: region ${var.region} not in ${var.geo} allow-list ${jsonencode(var.allowed_regions)} (ADR-0007)."
    }
    precondition {
      condition     = !local.is_prod || var.replicas >= 3
      error_message = "QUORUM VIOLATION: prod cells require replicas >= 3 (got ${var.replicas}) — prime directive #3."
    }
    precondition {
      condition     = !local.is_prod || var.pdb_min_available >= 2
      error_message = "QUORUM VIOLATION: prod cells require pdb_min_available >= 2 (got ${var.pdb_min_available}) — prime directive #3."
    }
    precondition {
      condition     = local.meets_floor
      error_message = "VERSION FLOOR VIOLATION: ArcadeDB tag '${var.arcadedb_image_tag}' < 26.4.1 or not semver. Pin a semver >= 26.4.1 (ADR-0012)."
    }
    precondition {
      condition     = var.pod_memory_limit_gib >= local.required_mem
      error_message = "SIZING RULE VIOLATION: pod_memory_limit_gib (${var.pod_memory_limit_gib}) < maxPageRAM+heap+overhead (${local.required_mem}) — prime directive #7."
    }
  }
}

###############################################################################
# Namespace (the cell)
###############################################################################
resource "kubernetes_namespace_v1" "cell" {
  metadata {
    name = local.namespace
    labels = merge(local.common_labels, {
      "platform.kb/cell"                   = var.cell_id
      "pod-security.kubernetes.io/enforce" = "restricted"
    })
    annotations = {
      "platform.kb/backup-bucket"  = coalesce(var.backup_bucket, "UNSET")
      "platform.kb/backup-prefix"  = local.backup_prefix
      "platform.kb/cell-isolation" = var.cell_isolation
    }
  }
}

###############################################################################
# StorageClass — gp3, KMS-encrypted, WaitForFirstConsumer, expandable (HLD §5.5)
###############################################################################
resource "kubernetes_storage_class_v1" "cell" {
  count = var.manage_storage_class ? 1 : 0

  metadata {
    name   = local.storage_class_name
    labels = local.common_labels
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain" # never auto-delete a DB volume
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type       = "gp3"
    iops       = tostring(var.volume_iops)
    throughput = tostring(var.volume_throughput_mibps)
    encrypted  = "true"
    kmsKeyId   = coalesce(var.ebs_kms_key_arn, "alias/aws/ebs")
  }
}

###############################################################################
# PodDisruptionBudget — protect quorum during drains/upgrades (prime directive #3)
###############################################################################
resource "kubernetes_pod_disruption_budget_v1" "cell" {
  metadata {
    name      = "${var.cell_id}-pdb"
    namespace = kubernetes_namespace_v1.cell.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    min_available = var.pdb_min_available
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "arcadedb"
        "app.kubernetes.io/instance" = var.cell_id
      }
    }
  }
}

###############################################################################
# NetworkPolicies — default-deny + explicit allows (cross-tenant containment)
###############################################################################
resource "kubernetes_network_policy_v1" "default_deny" {
  count = var.enable_default_deny_networkpolicy ? 1 : 0

  metadata {
    name      = "${var.cell_id}-default-deny"
    namespace = kubernetes_namespace_v1.cell.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_intra_cell" {
  count = var.enable_default_deny_networkpolicy ? 1 : 0

  metadata {
    name      = "${var.cell_id}-allow-intra-cell"
    namespace = kubernetes_namespace_v1.cell.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # Raft peer traffic within the cell (HTTP 2480, binary 2424, Raft 2434).
    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
    # DNS egress
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_platform_ingress" {
  count = var.enable_default_deny_networkpolicy ? 1 : 0

  metadata {
    name      = "${var.cell_id}-allow-platform-ingress"
    namespace = kubernetes_namespace_v1.cell.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "arcadedb" }
    }
    policy_types = ["Ingress"]

    dynamic "ingress" {
      for_each = toset(var.allowed_ingress_namespaces)
      content {
        from {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = ingress.value }
          }
        }
        # ArcadeDB HTTP (2480) + Bolt (7687) only — never public (prime directive #4).
        ports {
          port     = "2480"
          protocol = "TCP"
        }
        ports {
          port     = "7687"
          protocol = "TCP"
        }
      }
    }
  }
}

###############################################################################
# ResourceQuota / LimitRange — namespace-level governance (F2 mitigation)
###############################################################################
resource "kubernetes_resource_quota_v1" "cell" {
  count = var.enable_resource_quota ? 1 : 0

  metadata {
    name      = "${var.cell_id}-quota"
    namespace = kubernetes_namespace_v1.cell.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    hard = {
      "requests.cpu"    = tostring(var.replicas * tonumber(var.cpu_request))
      "requests.memory" = "${var.replicas * local.pod_mem_request}Gi"
      "limits.memory"   = "${var.replicas * var.pod_memory_limit_gib}Gi"
      "pods"            = tostring(var.replicas + 2) # DB pods + backup/jobs headroom
    }
  }
}

###############################################################################
# ArcadeDB Helm release (optional — Argo CD manages it in the GitOps model)
###############################################################################
resource "helm_release" "arcadedb" {
  count = var.manage_helm_release ? 1 : 0

  name      = var.cell_id
  namespace = kubernetes_namespace_v1.cell.metadata[0].name

  # Either a remote chart (repository+chart+version) or a local chart path.
  repository = var.local_chart_path == null ? var.chart_repository : null
  chart      = var.local_chart_path == null ? var.chart_name : var.local_chart_path
  version    = var.local_chart_path == null ? var.chart_version : null

  # Don't auto-create the namespace — we manage it above (for labels/policies).
  create_namespace = false
  atomic           = true
  timeout          = 600
  wait             = true

  values = [
    yamlencode({
      image = {
        repository = var.arcadedb_image_repository
        tag        = var.arcadedb_image_tag
        digest     = var.arcadedb_image_digest
      }
      replicaCount = var.replicas
      cellId       = var.cell_id
      arcadedb = {
        maxPageRAMgib = var.maxpage_ram_gib
        heapGib       = var.heap_gib
        txWalFlush    = local.tx_wal_flush
      }
      resources = {
        requests = {
          cpu    = var.cpu_request
          memory = "${local.pod_mem_request}Gi"
        }
        limits = merge(
          { memory = "${var.pod_memory_limit_gib}Gi" },
          var.cpu_limit == null ? {} : { cpu = var.cpu_limit },
        )
      }
      persistence = {
        storageClassName = var.manage_storage_class ? local.storage_class_name : null
        size             = "${var.volume_size_gib}Gi"
      }
      nodeSelector = { workload = "arcadedb" }
      tolerations = [{
        key      = "workload"
        operator = "Equal"
        value    = "arcadedb"
        effect   = "NoSchedule"
      }]
    }),
    var.extra_values_yaml,
  ]

  depends_on = [
    terraform_data.invariants,
    kubernetes_storage_class_v1.cell,
  ]
}
