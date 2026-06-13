# Provider + version pins — see terraform/README.md. Floor >= 1.10 (ADR-0022).
# The cell module configures NO providers; the environment root supplies the
# kubernetes/helm connection (cluster endpoint + auth).
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.35.0, < 3.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.16.0, < 3.0.0"
    }
  }
}
