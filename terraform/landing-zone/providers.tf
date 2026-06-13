###############################################################################
# landing-zone — provider configuration (management account).
#
# Org/SCP/SSO APIs are global → the default provider pins to a home region.
# Per-geo STATE buckets are created with geo-region aliases so EU state stays in
# the EU (residency, ADR-0007/0022). No credentials are needed to validate.
###############################################################################

provider "aws" {
  region = var.home_region
  # Assume-role into the management account in real use (placeholder here):
  # assume_role { role_arn = var.management_account_role_arn }
}

provider "aws" {
  alias  = "eu"
  region = var.eu_state_region
}

provider "aws" {
  alias  = "us"
  region = var.us_state_region
}
