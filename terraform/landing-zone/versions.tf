# Provider + version pins — see terraform/README.md. Floor >= 1.10 (ADR-0022).
#
# Three aws provider configs:
#   - default  : the management account (org APIs are global; pin to us-east-1).
#   - aws.eu   : EU state region (EU Terraform state stays in the EU — residency).
#   - aws.us   : US state region.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }
  }
}
