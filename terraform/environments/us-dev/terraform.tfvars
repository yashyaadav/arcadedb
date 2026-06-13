###############################################################################
# US dev — SINGLE-NODE cell (no HA) for cost. Mirror of eu-dev in the US geo.
###############################################################################

geo             = "us"
env             = "dev"
name            = "kb-us-dev"
region          = "us-east-1"
dr_region       = "us-west-2"
allowed_regions = ["us-east-1", "us-west-2"]

vpc_cidr             = "10.21.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
private_subnet_cidrs = ["10.21.0.0/20", "10.21.16.0/20", "10.21.32.0/20"]
intra_subnet_cidrs   = ["10.21.48.0/22", "10.21.52.0/22", "10.21.56.0/22"]
public_subnet_cidrs  = ["10.21.60.0/24", "10.21.61.0/24", "10.21.62.0/24"]
single_nat_gateway   = true

cluster_version   = "1.31"
db_instance_types = ["r7g.xlarge"]

cells = {
  "std-01" = {
    tier                 = "standard"
    replicas             = 1
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 16
    heap_gib             = 4
    overhead_gib         = 4
    pod_memory_limit_gib = 24
    volume_size_gib      = 100
  }
}

tags = { owner = "platform-team", cost-center = "kb-platform" }
