###############################################################################
# EU production — agreed day-one footprint: 1 pooled standard cell + 2 enterprise
# dedicated cells (HLD §5.4 / A3). Primary eu-central-1, DR eu-west-1.
#
# Apply (post-approval only):
#   tofu -chdir=terraform/environments init -backend-config="bucket=kb-tfstate-eu" \
#     -backend-config="key=environments/eu-prod/terraform.tfstate" \
#     -backend-config="region=eu-central-1" -backend-config="use_lockfile=true"
#   tofu -chdir=terraform/environments plan -var-file=eu-prod/terraform.tfvars
###############################################################################

geo             = "eu"
env             = "prod"
name            = "kb-eu-prod"
region          = "eu-central-1"
dr_region       = "eu-west-1"
allowed_regions = ["eu-central-1", "eu-west-1"]

vpc_cidr             = "10.10.0.0/16"
azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
private_subnet_cidrs = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
intra_subnet_cidrs   = ["10.10.48.0/22", "10.10.52.0/22", "10.10.56.0/22"]
public_subnet_cidrs  = ["10.10.60.0/24", "10.10.61.0/24", "10.10.62.0/24"]
single_nat_gateway   = false # prod: NAT per AZ (HA)

cluster_version   = "1.31"
db_instance_types = ["r7g.2xlarge"]

cluster_admin_principal_arns = [
  # "arn:aws:iam::ACCOUNT_ID:role/AWSReservedSSO_PlatformAdmin_xxxx",
]

# 50 standard tenants live in std-01 (≈ 1/3 of the ~150 cap). Enterprise tenants
# each get their own cell. Argo CD manages the Helm releases (manage_helm_release=false).
cells = {
  "std-01" = {
    tier                 = "standard"
    cell_isolation       = "namespace"
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 32
    heap_gib             = 8
    overhead_gib         = 6
    pod_memory_limit_gib = 46
    volume_size_gib      = 300
  }
  "ent-acme" = {
    tier                 = "enterprise"
    cell_isolation       = "namespace" # production enterprise may use "cluster" (dedicated EKS) — separate stack
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 48
    heap_gib             = 10
    overhead_gib         = 8
    pod_memory_limit_gib = 66
    volume_size_gib      = 500
  }
  "ent-globex" = {
    tier                 = "enterprise"
    cell_isolation       = "namespace"
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 48
    heap_gib             = 10
    overhead_gib         = 8
    pod_memory_limit_gib = 66
    volume_size_gib      = 500
  }
}

enable_object_lock = true # enterprise WORM backups
# dr_bucket_arn / dr_backup_vault_arn supplied from the eu-west-1 DR stack outputs.

grafana_admin_group_ids = [] # "SSO_GROUP_ID_PLATFORM_ADMIN"
# pagerduty_sns_https_endpoint = "https://events.pagerduty.com/integration/REPLACE/enqueue"

tags = {
  owner       = "platform-team"
  cost-center = "kb-platform"
}
