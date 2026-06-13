###############################################################################
# EU stage — prod-like topology (3-node) on smaller nodes for pre-prod validation.
###############################################################################

geo             = "eu"
env             = "stage"
name            = "kb-eu-stage"
region          = "eu-central-1"
dr_region       = "eu-west-1"
allowed_regions = ["eu-central-1", "eu-west-1"]

vpc_cidr             = "10.12.0.0/16"
azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
private_subnet_cidrs = ["10.12.0.0/20", "10.12.16.0/20", "10.12.32.0/20"]
intra_subnet_cidrs   = ["10.12.48.0/22", "10.12.52.0/22", "10.12.56.0/22"]
public_subnet_cidrs  = ["10.12.60.0/24", "10.12.61.0/24", "10.12.62.0/24"]
single_nat_gateway   = true

cluster_version   = "1.31"
db_instance_types = ["r7g.xlarge"]

cells = {
  "std-01" = {
    tier                 = "standard"
    replicas             = 3 # prod-like HA for realistic validation
    arcadedb_image_tag   = "26.4.1"
    maxpage_ram_gib      = 16
    heap_gib             = 4
    overhead_gib         = 4
    pod_memory_limit_gib = 24
    volume_size_gib      = 150
  }
}

tags = { owner = "platform-team", cost-center = "kb-platform" }
