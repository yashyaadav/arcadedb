###############################################################################
# environments — per-purpose KMS keys (encrypt everything — prime directive #5).
# Separate CMKs for EBS, backups (S3), secrets (EKS), and logs (ADR-0019 / §7.1).
###############################################################################

locals {
  kms_purposes = ["ebs", "backups", "secrets", "logs"]
}

resource "aws_kms_key" "this" {
  for_each                = toset(local.kms_purposes)
  description             = "${var.name} ${each.value} CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(var.tags, { purpose = each.value })
}

resource "aws_kms_alias" "this" {
  for_each      = toset(local.kms_purposes)
  name          = "alias/${var.name}-${each.value}"
  target_key_id = aws_kms_key.this[each.value].key_id
}

###############################################################################
# VPC Flow Logs IAM role (used by the network module)
###############################################################################
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream",
      "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}
