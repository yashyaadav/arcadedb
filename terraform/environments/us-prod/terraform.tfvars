###############################################################################
# US production — mirror of eu-prod in the US jurisdiction. Primary us-east-1,
# DR us-west-2. Fully independent stack; NO connectivity to the EU geo.
###############################################################################

geo             = "us"
env             = "prod"
name            = "kb-us-prod"
region          = "us-east-1"
dr_region       = "us-west-2"
allowed_regions = ["us-east-1", "us-west-2"]

vpc_cidr             = "10.20.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
private_subnet_cidrs = ["10.20.0.0/20", "10.20.16.0/20", "10.20.32.0/20"]
intra_subnet_cidrs   = ["10.20.48.0/22", "10.20.52.0/22", "10.20.56.0/22"]
public_subnet_cidrs  = ["10.20.60.0/24", "10.20.61.0/24", "10.20.62.0/24"]
single_nat_gateway   = false

cluster_version   = "1.31"
db_instance_types = ["r7g.2xlarge"]

cells = {
  "std-01" = {
    tier                 = "standard"
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 32
    heap_gib             = 8
    overhead_gib         = 6
    pod_memory_limit_gib = 46
    volume_size_gib      = 300
  }
  "ent-initech" = {
    tier                 = "enterprise"
    replicas             = 3
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 48
    heap_gib             = 10
    overhead_gib         = 8
    pod_memory_limit_gib = 66
    volume_size_gib      = 500
  }
}

enable_object_lock = true

tags = { owner = "platform-team", cost-center = "kb-platform" }
