###############################################################################
# modules/eks — outputs
###############################################################################

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA cert (for kube/helm provider config)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Cluster-managed security group (DB ports allowed only from this SG)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL (IRSA fallback; Pod Identity is the default — ADR-0011)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  description = "Shared MNG node IAM role ARN (also passed to Karpenter EC2NodeClass)."
  value       = aws_iam_role.node.arn
}

output "stateful_node_group_names" {
  description = "Map of logical name => stateful node group name."
  value       = { for k, v in aws_eks_node_group.stateful : k => v.node_group_name }
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN (null if disabled)."
  value       = var.enable_karpenter ? aws_iam_role.karpenter_controller[0].arn : null
}
