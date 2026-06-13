###############################################################################
# environments — wire the modules into a full geo/env stack.
#
# BOILERPLATE TEMPLATE (CTO package): validate-clean integration of all modules,
# NOT applied. Run `tofu validate` here to check the modules compose correctly.
#
# Order: network -> eks -> observability -> backup-dr -> cell(s).
###############################################################################

module "network" {
  source = "../modules/network"

  name            = var.name
  geo             = var.geo
  env             = var.env
  region          = var.region
  allowed_regions = var.allowed_regions

  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  private_subnet_cidrs = var.private_subnet_cidrs
  intra_subnet_cidrs   = var.intra_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway

  flow_logs_kms_key_arn = aws_kms_key.this["logs"].arn
  flow_logs_role_arn    = aws_iam_role.flow_logs.arn

  tags = var.tags
}

module "eks" {
  source = "../modules/eks"

  name            = var.name
  geo             = var.geo
  env             = var.env
  region          = var.region
  allowed_regions = var.allowed_regions
  cluster_version = var.cluster_version

  private_subnet_ids       = module.network.private_subnet_ids
  control_plane_subnet_ids = module.network.intra_subnet_ids
  secrets_kms_key_arn      = aws_kms_key.this["secrets"].arn

  cluster_admin_principal_arns = var.cluster_admin_principal_arns

  # One stateful MNG per AZ (AZ-pinned). desired=1 (one DB pod per AZ).
  stateful_node_groups = {
    for idx, az in var.azs : "db-${substr(az, length(az) - 1, 1)}" => {
      subnet_id      = module.network.private_subnet_ids[idx]
      instance_types = var.db_instance_types
      min_size       = 1
      max_size       = 2
      desired_size   = 1
    }
  }

  tags = var.tags
}

module "observability" {
  source = "../modules/observability"

  name             = var.name
  geo              = var.geo
  env              = var.env
  region           = var.region
  allowed_regions  = var.allowed_regions
  logs_kms_key_arn = aws_kms_key.this["logs"].arn

  cell_log_groups              = keys(var.cells)
  grafana_admin_group_ids      = var.grafana_admin_group_ids
  pagerduty_sns_https_endpoint = var.pagerduty_sns_https_endpoint

  tags = var.tags
}

module "backup_dr" {
  source = "../modules/backup-dr"

  name            = var.name
  geo             = var.geo
  env             = var.env
  region          = var.region
  dr_region       = var.dr_region
  allowed_regions = var.allowed_regions

  backup_kms_key_arn  = aws_kms_key.this["backups"].arn
  dr_bucket_arn       = var.dr_bucket_arn
  dr_backup_vault_arn = var.dr_backup_vault_arn
  enable_object_lock  = var.enable_object_lock

  tags = var.tags
}

module "cell" {
  source   = "../modules/cell"
  for_each = var.cells

  cell_id         = "${var.name}-${each.key}"
  geo             = var.geo
  env             = var.env
  region          = var.region
  allowed_regions = var.allowed_regions
  tier            = each.value.tier
  cell_isolation  = each.value.cell_isolation

  replicas              = each.value.replicas
  arcadedb_image_tag    = each.value.arcadedb_image_tag
  arcadedb_image_digest = each.value.arcadedb_image_digest

  maxpage_ram_gib      = each.value.maxpage_ram_gib
  heap_gib             = each.value.heap_gib
  overhead_gib         = each.value.overhead_gib
  pod_memory_limit_gib = each.value.pod_memory_limit_gib
  volume_size_gib      = each.value.volume_size_gib

  ebs_kms_key_arn     = aws_kms_key.this["ebs"].arn
  backup_bucket       = module.backup_dr.backup_bucket_name
  manage_helm_release = each.value.manage_helm_release

  tags = var.tags

  depends_on = [module.eks]
}
