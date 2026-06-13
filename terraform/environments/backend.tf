###############################################################################
# environments — S3 backend (per-geo bucket, native locking — ADR-0022).
#
# Placeholder. `tofu init -backend=false` (CTO-package validation) SKIPS this.
# At apply time (post-approval) configure per env via `-backend-config`, e.g.:
#
#   tofu init \
#     -backend-config="bucket=kb-tfstate-eu" \
#     -backend-config="key=environments/eu-prod/terraform.tfstate" \
#     -backend-config="region=eu-central-1" \
#     -backend-config="use_lockfile=true"
#
# EU state MUST live in the EU bucket; US state in the US bucket (residency).
###############################################################################

terraform {
  backend "s3" {
    # All values supplied via -backend-config per environment (no hardcoded geo).
    encrypt = true
    # use_lockfile = true   # S3-native state locking (Terraform/OpenTofu >= 1.10)
  }
}
