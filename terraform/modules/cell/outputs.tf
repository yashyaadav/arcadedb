###############################################################################
# modules/cell — outputs (also feed the tenant registry / cell catalog)
###############################################################################

output "cell_id" {
  description = "The cell id."
  value       = var.cell_id
}

output "namespace" {
  description = "Kubernetes namespace for the cell."
  value       = kubernetes_namespace_v1.cell.metadata[0].name
}

output "tier" {
  description = "Tenancy tier (standard | enterprise)."
  value       = var.tier
}

output "cell_isolation" {
  description = "namespace | cluster (ADR-0004)."
  value       = var.cell_isolation
}

output "replicas" {
  description = "Configured ArcadeDB replica count."
  value       = var.replicas
}

output "tx_wal_flush" {
  description = "Effective txWalFlush (derived from tier if not set)."
  value       = local.tx_wal_flush
}

output "image_ref" {
  description = "Fully-qualified image reference (digest-pinned if provided)."
  value       = local.image_ref
}

output "storage_class_name" {
  description = "The gp3-KMS StorageClass name (null if not managed here)."
  value       = var.manage_storage_class ? local.storage_class_name : null
}

output "backup_prefix" {
  description = "S3 key prefix for this cell's backups (register in the cell catalog)."
  value       = local.backup_prefix
}

output "headless_service_fqdn" {
  description = "Convention for the cell's headless Service FQDN (Raft peer discovery)."
  value       = "${var.cell_id}-headless.${kubernetes_namespace_v1.cell.metadata[0].name}.svc.cluster.local"
}

output "sizing_summary" {
  description = "Resolved memory sizing (sanity-check the sizing rule)."
  value = {
    maxpage_ram_gib      = var.maxpage_ram_gib
    heap_gib             = var.heap_gib
    overhead_gib         = var.overhead_gib
    required_min_gib     = local.required_mem
    pod_memory_limit_gib = var.pod_memory_limit_gib
  }
}
