###############################################################################
# modules/backup-dr — backup S3 (SSE-KMS + in-geo CRR + Object Lock) + AWS Backup.
#
# BOILERPLATE TEMPLATE (CTO package): validate-clean, NOT applied.
#
# The hot per-DB ZIP backup CronJob runs IN-CLUSTER (Helm/GitOps); this module
# provides the AWS-side targets it writes to, plus EBS-snapshot orchestration.
###############################################################################

locals {
  region_in_geo    = contains(var.allowed_regions, var.region)
  dr_region_in_geo = contains(var.allowed_regions, var.dr_region)
  bucket_name      = "kb-backups-${var.geo}-${var.env}"

  common_tags = merge(var.tags, {
    platform             = "arcadedb-kb"
    geo                  = var.geo
    env                  = var.env
    module               = "backup-dr"
    managed-by           = "opentofu"
    "residency-boundary" = var.geo
  })
}

resource "terraform_data" "residency_guard" {
  lifecycle {
    precondition {
      condition     = local.region_in_geo && local.dr_region_in_geo
      error_message = "RESIDENCY VIOLATION: region/dr_region must both be in the ${var.geo} allow-list ${jsonencode(var.allowed_regions)} (ADR-0007)."
    }
  }
}

###############################################################################
# Backup S3 bucket (primary, in-geo)
###############################################################################
resource "aws_s3_bucket" "backups" {
  bucket              = local.bucket_name
  object_lock_enabled = var.enable_object_lock
  tags                = merge(local.common_tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled" # required for CRR + Object Lock
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.backup_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_object_lock_configuration" "backups" {
  count  = var.enable_object_lock ? 1 : 0
  bucket = aws_s3_bucket.backups.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "standard-retention"
    status = "Enabled"
    filter {
      prefix = "cell/"
    }
    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = var.standard_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "enterprise-retention"
    status = "Enabled"
    filter {
      prefix = "enterprise/"
    }
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration {
      days = var.enterprise_retention_days
    }
  }
}

# Enforce TLS-only access (deny non-HTTPS).
data "aws_iam_policy_document" "backups_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups_bucket.json
}

###############################################################################
# Cross-Region Replication — IN-GEO ONLY (residency, prime directive #1)
###############################################################################
data "aws_iam_policy_document" "replication_assume" {
  count = var.dr_bucket_arn == null ? 0 : 1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  count              = var.dr_bucket_arn == null ? 0 : 1
  name               = "${var.name}-s3-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "replication" {
  count = var.dr_bucket_arn == null ? 0 : 1

  statement {
    sid       = "SourceRead"
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }
  statement {
    sid       = "SourceObjectRead"
    effect    = "Allow"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
  statement {
    sid       = "DestReplicate"
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${var.dr_bucket_arn}/*"]
  }
  statement {
    sid       = "KmsDecryptSource"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.backup_kms_key_arn]
  }
  statement {
    sid       = "KmsEncryptDest"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [coalesce(var.dr_bucket_kms_key_arn, var.backup_kms_key_arn)]
  }
}

resource "aws_iam_role_policy" "replication" {
  count  = var.dr_bucket_arn == null ? 0 : 1
  name   = "replication"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "backups" {
  count      = var.dr_bucket_arn == null ? 0 : 1
  bucket     = aws_s3_bucket.backups.id
  role       = aws_iam_role.replication[0].arn
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "in-geo-dr"
    status = "Enabled"
    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = var.dr_bucket_arn
      storage_class = "STANDARD_IA"
      encryption_configuration {
        replica_kms_key_id = coalesce(var.dr_bucket_kms_key_arn, var.backup_kms_key_arn)
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}

###############################################################################
# AWS Backup — EBS snapshots (KMS) + in-geo copy (ADR-0016)
###############################################################################
resource "aws_backup_vault" "this" {
  name        = "${var.name}-vault"
  kms_key_arn = var.backup_kms_key_arn
  tags        = local.common_tags
}

resource "aws_backup_vault_lock_configuration" "this" {
  count               = var.enable_backup_vault_lock ? 1 : 0
  backup_vault_name   = aws_backup_vault.this.name
  changeable_for_days = 3
  min_retention_days  = 7
  max_retention_days  = max(var.snapshot_retention_days, var.enterprise_retention_days)
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-aws-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-ebs-plan"
  tags = local.common_tags

  rule {
    rule_name         = "ebs-snapshots"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.snapshot_schedule
    start_window      = 60
    completion_window = 300

    lifecycle {
      delete_after = var.snapshot_retention_days
    }

    dynamic "copy_action" {
      for_each = var.dr_backup_vault_arn == null ? [] : [var.dr_backup_vault_arn]
      content {
        destination_vault_arn = copy_action.value
        lifecycle {
          delete_after = var.snapshot_retention_days
        }
      }
    }
  }
}

resource "aws_backup_selection" "this" {
  name         = "${var.name}-arcadedb-volumes"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this.id

  # Select EBS volumes tagged as ArcadeDB data (set by the StorageClass / CSI).
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "platform"
    value = "arcadedb-kb"
  }
}
