###############################################################################
# US stage — prod-like (3-node) on smaller nodes. Mirror of eu-stage in the US geo.
###############################################################################

geo             = "us"
env             = "stage"
name            = "kb-us-stage"
region          = "us-east-1"
dr_region       = "us-west-2"
allowed_regions = ["us-east-1", "us-west-2"]

vpc_cidr             = "10.22.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
private_subnet_cidrs = ["10.22.0.0/20", "10.22.16.0/20", "10.22.32.0/20"]
intra_subnet_cidrs   = ["10.22.48.0/22", "10.22.52.0/22", "10.22.56.0/22"]
public_subnet_cidrs  = ["10.22.60.0/24", "10.22.61.0/24", "10.22.62.0/24"]
single_nat_gateway   = true

cluster_version   = "1.31"
db_instance_types = ["r7g.xlarge"]

cells = {
  "std-01" = {
    tier                 = "standard"
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 16
    heap_gib             = 4
    overhead_gib         = 4
    pod_memory_limit_gib = 24
    volume_size_gib      = 150
  }
}

tags = { owner = "platform-team", cost-center = "kb-platform" }
