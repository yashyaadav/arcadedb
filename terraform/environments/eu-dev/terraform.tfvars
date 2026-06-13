###############################################################################
# EU dev — SINGLE-NODE cells (no HA) to cut ~2/3 of non-prod DB cost (§7 / R10).
# replicas=1 is allowed in non-prod (the quorum precondition only fires for prod).
###############################################################################

geo             = "eu"
env             = "dev"
name            = "kb-eu-dev"
region          = "eu-central-1"
dr_region       = "eu-west-1"
allowed_regions = ["eu-central-1", "eu-west-1"]

vpc_cidr             = "10.11.0.0/16"
azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
private_subnet_cidrs = ["10.11.0.0/20", "10.11.16.0/20", "10.11.32.0/20"]
intra_subnet_cidrs   = ["10.11.48.0/22", "10.11.52.0/22", "10.11.56.0/22"]
public_subnet_cidrs  = ["10.11.60.0/24", "10.11.61.0/24", "10.11.62.0/24"]
single_nat_gateway   = true # dev: one NAT (cost)

cluster_version   = "1.31"
db_instance_types = ["r7g.xlarge"]

cells = {
  "std-01" = {
    tier                 = "standard"
    replicas             = 1 # single-node (no HA) — non-prod cost lever
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 16
    heap_gib             = 4
    overhead_gib         = 4
    pod_memory_limit_gib = 24
    volume_size_gib      = 100
  }
}

tags = { owner = "platform-team", cost-center = "kb-platform" }
