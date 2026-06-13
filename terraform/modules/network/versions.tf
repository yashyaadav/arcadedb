# Provider + version pins (mirrors the repo-wide convention — see terraform/README.md).
# Floor: OpenTofu/Terraform >= 1.10 for S3-native state locking (ADR-0022).
# Pin all providers (prime directive: pin all versions).
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }
  }
}
