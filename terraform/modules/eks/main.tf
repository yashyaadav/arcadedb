###############################################################################
# modules/eks — regional private EKS cluster + node groups + Pod Identity.
#
# BOILERPLATE TEMPLATE (CTO package): instantiable + validate-clean, NOT applied.
#
# Design anchors:
#   - Private API by default; control-plane logs → CloudWatch (audit).
#   - Secrets envelope-encrypted with KMS (prime directive #5).
#   - Per-AZ Managed Node Groups for the STATEFUL DB tier, AZ-pinned + tainted
#     so no autoscaler consolidates a node out from under a Raft pod (ADR-0010).
#   - Karpenter scaffolding for STATELESS tiers (NodePools via GitOps).
#   - EKS Pod Identity for workload IAM (ADR-0011).
###############################################################################

locals {
  control_plane_subnets = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.private_subnet_ids
  region_in_geo         = contains(var.allowed_regions, var.region)

  common_tags = merge(var.tags, {
    platform             = "arcadedb-kb"
    geo                  = var.geo
    env                  = var.env
    module               = "eks"
    managed-by           = "opentofu"
    "residency-boundary" = var.geo
  })

  # arm64 (Graviton) AMI for the DB tier (ADR-0009). x86 fallback documented in the ADR.
  db_ami_type     = "AL2023_ARM_64_STANDARD"
  system_ami_type = "AL2023_ARM_64_STANDARD"
}

resource "terraform_data" "residency_guard" {
  lifecycle {
    precondition {
      condition     = local.region_in_geo
      error_message = "RESIDENCY VIOLATION: region ${var.region} not in ${var.geo} allow-list ${jsonencode(var.allowed_regions)}."
    }
  }
}

###############################################################################
# IAM — cluster role
###############################################################################
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

###############################################################################
# IAM — node role (shared by MNGs)
###############################################################################
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

###############################################################################
# EKS cluster
###############################################################################
resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = distinct(concat(var.private_subnet_ids, local.control_plane_subnets))
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  dynamic "encryption_config" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      provider {
        key_arn = encryption_config.value
      }
      resources = ["secrets"]
    }
  }

  tags = merge(local.common_tags, { Name = var.name })

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

###############################################################################
# EKS Access Entries — cluster admins (SSO permission-set roles)
###############################################################################
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = local.common_tags
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admins]
}

###############################################################################
# Stateful DB node groups — one per AZ, AZ-pinned + tainted (ADR-0010)
###############################################################################
resource "aws_eks_node_group" "stateful" {
  for_each = var.stateful_node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-${each.key}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [each.value.subnet_id] # AZ-pinned: a single subnet => single AZ

  ami_type       = local.db_ami_type
  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  disk_size      = each.value.disk_size_gib

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "workload"                        = "arcadedb"
    "topology.kubernetes.io/zone-tag" = each.key
  }

  taint {
    key    = "workload"
    value  = "arcadedb"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, {
    Name                                = "${var.name}-${each.key}"
    tier                                = "stateful-db"
    "k8s.io/cluster-autoscaler/enabled" = "false" # never autoscale the DB tier
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # desired managed out-of-band/by ops
  }

  depends_on = [aws_iam_role_policy_attachment.node_managed]
}

###############################################################################
# System node group (add-ons) — small, multi-AZ
###############################################################################
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = local.system_ami_type
  instance_types = var.system_node_group.instance_types
  capacity_type  = "ON_DEMAND"
  disk_size      = var.system_node_group.disk_size_gib

  scaling_config {
    desired_size = var.system_node_group.desired_size
    max_size     = var.system_node_group.max_size
    min_size     = var.system_node_group.min_size
  }

  labels = { "workload" = "system" }

  tags = merge(local.common_tags, { Name = "${var.name}-system", tier = "system" })

  depends_on = [aws_iam_role_policy_attachment.node_managed]
}

###############################################################################
# Managed add-ons (incl. Pod Identity Agent + EBS CSI driver)
###############################################################################
resource "aws_eks_addon" "this" {
  for_each = toset(var.eks_addons)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.system,
  ]
}

###############################################################################
# Pod Identity — EBS CSI driver role + association, plus caller-supplied ones
###############################################################################
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  tags            = local.common_tags
}

resource "aws_eks_pod_identity_association" "extra" {
  for_each = {
    for a in var.pod_identity_associations : "${a.namespace}/${a.service_account}" => a
  }
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
  tags            = local.common_tags
}

###############################################################################
# Karpenter scaffolding (STATELESS tiers). NodePools/EC2NodeClasses are GitOps.
###############################################################################
resource "aws_iam_role" "karpenter_controller" {
  count              = var.enable_karpenter ? 1 : 0
  name               = "${var.name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.common_tags
}

# Starter controller policy — tighten in the LLD against the Karpenter docs.
data "aws_iam_policy_document" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0

  statement {
    sid    = "KarpenterCompute"
    effect = "Allow"
    actions = [
      "ec2:CreateLaunchTemplate", "ec2:CreateFleet", "ec2:RunInstances",
      "ec2:CreateTags", "ec2:TerminateInstances", "ec2:DeleteLaunchTemplate",
      "ec2:Describe*", "pricing:GetProducts", "ssm:GetParameter",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "KarpenterPassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node.arn]
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count  = var.enable_karpenter ? 1 : 0
  name   = "karpenter-controller"
  role   = aws_iam_role.karpenter_controller[0].id
  policy = data.aws_iam_policy_document.karpenter_controller[0].json
}

resource "aws_eks_pod_identity_association" "karpenter" {
  count           = var.enable_karpenter ? 1 : 0
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller[0].arn
  tags            = local.common_tags
}
