###############################################################################
# environments — outputs
###############################################################################

output "vpc_id" {
  value = module.network.vpc_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "backup_bucket" {
  value = module.backup_dr.backup_bucket_name
}

output "amp_endpoint" {
  value = module.observability.amp_prometheus_endpoint
}

output "cells" {
  description = "Map of cell key => { namespace, tier, replicas, backup_prefix }."
  value = {
    for k, m in module.cell : k => {
      namespace     = m.namespace
      tier          = m.tier
      replicas      = m.replicas
      backup_prefix = m.backup_prefix
      image_ref     = m.image_ref
    }
  }
}
