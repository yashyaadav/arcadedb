# Provider + version pins — see terraform/README.md. Floor >= 1.10 (ADR-0022).
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }
  }
}
