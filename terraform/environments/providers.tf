###############################################################################
# environments — provider configuration.
#
# aws: the workload account in this geo/env. kubernetes/helm: against the EKS
# cluster this config creates (exec auth via `aws eks get-token`). No connection
# is made during `validate` (offline) — only at plan/apply (post-approval).
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      platform           = "arcadedb-kb"
      geo                = var.geo
      env                = var.env
      managed-by         = "opentofu"
      residency-boundary = var.geo
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
