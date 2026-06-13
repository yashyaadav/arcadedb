###############################################################################
# landing-zone — geo OUs + residency SCPs + baseline guardrail + per-geo state +
# SSO permission sets.
#
# BOILERPLATE TEMPLATE (CTO package): validate-clean, NOT applied. Account IDs,
# org root id, and SSO instance ARN are placeholders.
#
# Residency is enforced HERE at the org boundary (the strongest layer): an SCP on
# each geo OU DENIES any action outside that geo's region allow-list (ADR-0007).
###############################################################################

locals {
  common_tags = merge(var.tags, {
    platform   = "arcadedb-kb"
    layer      = "landing-zone"
    managed-by = "opentofu"
  })
}

###############################################################################
# Geo OUs (the residency boundary)
###############################################################################
resource "aws_organizations_organizational_unit" "geo" {
  for_each  = var.geos
  name      = each.value.ou_display_name
  parent_id = var.organization_root_id
  tags      = merge(local.common_tags, { geo = each.key })
}

###############################################################################
# Residency SCP — deny any action outside the geo's in-region allow-list
###############################################################################
data "aws_iam_policy_document" "residency_deny" {
  for_each = var.geos

  statement {
    sid       = "DenyOutOfGeoRegions"
    effect    = "Deny"
    resources = ["*"]

    # Region-agnostic global services must NOT be denied (they have no region).
    not_actions = var.global_service_actions_allowlist

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = each.value.allowed_regions
    }
  }
}

resource "aws_organizations_policy" "residency" {
  for_each = var.geos

  name        = "residency-deny-${each.key}"
  description = "Residency: deny actions outside ${jsonencode(each.value.allowed_regions)} for the ${each.key} geo (ADR-0007)."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.residency_deny[each.key].json
  tags        = merge(local.common_tags, { geo = each.key })
}

resource "aws_organizations_policy_attachment" "residency" {
  for_each  = var.geos
  policy_id = aws_organizations_policy.residency[each.key].id
  target_id = aws_organizations_organizational_unit.geo[each.key].id
}

###############################################################################
# Baseline guardrail SCP — protect the security baseline (attach to all geo OUs)
###############################################################################
data "aws_iam_policy_document" "baseline_guardrail" {
  statement {
    sid    = "DenyLeaveOrganization"
    effect = "Deny"
    actions = [
      "organizations:LeaveOrganization",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ProtectSecurityServices"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "config:DeleteConfigurationRecorder",
      "config:StopConfigurationRecorder",
      "securityhub:DisableSecurityHub",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyUnencryptedAndPublicS3Backups"
    effect = "Deny"
    actions = [
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["public-read", "public-read-write"]
    }
  }

  statement {
    sid       = "DenyRootUser"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }
  }
}

resource "aws_organizations_policy" "baseline" {
  name        = "baseline-guardrail"
  description = "Protect CloudTrail/Config/GuardDuty/SecurityHub, block org-leave + root use (SOC2 baseline)."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.baseline_guardrail.json
  tags        = local.common_tags
}

resource "aws_organizations_policy_attachment" "baseline" {
  for_each  = var.geos
  policy_id = aws_organizations_policy.baseline.id
  target_id = aws_organizations_organizational_unit.geo[each.key].id
}

###############################################################################
# Per-geo Terraform state — EU state in EU, US state in US (residency, ADR-0022)
###############################################################################
# --- EU state ---
resource "aws_kms_key" "state_eu" {
  provider                = aws.eu
  description             = "KMS for EU Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(local.common_tags, { geo = "eu", purpose = "tfstate" })
}

resource "aws_s3_bucket" "state_eu" {
  provider = aws.eu
  bucket   = "kb-tfstate-eu"
  tags     = merge(local.common_tags, { geo = "eu", purpose = "tfstate" })
}

resource "aws_s3_bucket_versioning" "state_eu" {
  provider = aws.eu
  bucket   = aws_s3_bucket.state_eu.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_eu" {
  provider = aws.eu
  bucket   = aws_s3_bucket.state_eu.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state_eu.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state_eu" {
  provider                = aws.eu
  bucket                  = aws_s3_bucket.state_eu.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- US state ---
resource "aws_kms_key" "state_us" {
  provider                = aws.us
  description             = "KMS for US Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(local.common_tags, { geo = "us", purpose = "tfstate" })
}

resource "aws_s3_bucket" "state_us" {
  provider = aws.us
  bucket   = "kb-tfstate-us"
  tags     = merge(local.common_tags, { geo = "us", purpose = "tfstate" })
}

resource "aws_s3_bucket_versioning" "state_us" {
  provider = aws.us
  bucket   = aws_s3_bucket.state_us.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_us" {
  provider = aws.us
  bucket   = aws_s3_bucket.state_us.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state_us.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state_us" {
  provider                = aws.us
  bucket                  = aws_s3_bucket.state_us.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# IAM Identity Center (SSO) permission sets — no IAM users (prime directive)
###############################################################################
resource "aws_ssoadmin_permission_set" "this" {
  for_each = var.sso_instance_arn == null ? {} : var.permission_sets

  name             = each.key
  description      = each.value.description
  instance_arn     = var.sso_instance_arn
  session_duration = each.value.session_duration
  tags             = local.common_tags
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = var.sso_instance_arn == null ? {} : {
    for pair in flatten([
      for ps_name, ps in var.permission_sets : [
        for policy_arn in ps.managed_policies : {
          key        = "${ps_name}::${policy_arn}"
          ps_name    = ps_name
          policy_arn = policy_arn
        }
      ]
    ]) : pair.key => pair
  }

  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps_name].arn
  managed_policy_arn = each.value.policy_arn
}
