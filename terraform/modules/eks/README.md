# Module: `eks`

A **regional, private EKS cluster** that backs many ArcadeDB namespace-cells
(ADR-0004), with the **MNG-stateful + Karpenter-stateless** node strategy
(ADR-0010) and **EKS Pod Identity** for workload IAM (ADR-0011).

> **CTO-package status:** basic boilerplate template — parameterised + validate-clean,
> **not applied to AWS**. IAM policies are starter-grade (tightened in the LLD).

## What it creates

| Resource | Notes |
|---|---|
| `aws_eks_cluster` | Private API by default; secrets KMS-encrypted; control-plane logs → CloudWatch; `authentication_mode = API` (Access Entries). |
| `aws_iam_role.cluster` / `.node` | Cluster + shared node roles with the standard managed policies. |
| `aws_eks_access_entry` / `_access_policy_association` | Cluster-admin for SSO permission-set role ARNs (no IAM users). |
| `aws_eks_node_group.stateful` (per AZ) | **AZ-pinned** (single subnet), **Graviton arm64**, tainted `workload=arcadedb:NoSchedule`, `cluster-autoscaler/enabled=false`, `ignore_changes` on desired size. |
| `aws_eks_node_group.system` | Small multi-AZ group for add-ons. |
| `aws_eks_addon` | CoreDNS, kube-proxy, **eks-pod-identity-agent**, aws-ebs-csi-driver. |
| `aws_eks_pod_identity_association` | EBS CSI + Karpenter + caller-supplied associations. |
| Karpenter IAM | Controller role + starter policy + Pod Identity association (NodePools are GitOps). |

## Why the node split matters

The **stateful DB tier must never be consolidated** by an autoscaler — that would
evict a Raft pod, strand its AZ-bound EBS volume, and risk quorum (prime directive
#3). So DB nodes live on **per-AZ MNGs**, AZ-pinned and tainted, with autoscaling
off. Stateless tiers (control plane, retrieval, jobs) use **Karpenter** for fast,
cost-optimal scaling where eviction is harmless. See [ADR-0010](../../docs/adr/0010-node-provisioning-mng-karpenter.md).

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  name            = "kb-eu-prod"
  geo             = "eu"
  env             = "prod"
  region          = "eu-central-1"
  allowed_regions = ["eu-central-1", "eu-west-1"]
  cluster_version = "1.31"

  private_subnet_ids       = module.network.private_subnet_ids
  control_plane_subnet_ids = module.network.intra_subnet_ids
  secrets_kms_key_arn      = module.kms.eks_key_arn

  cluster_admin_principal_arns = [
    "arn:aws:iam::ACCOUNT_ID:role/AWSReservedSSO_PlatformAdmin_xxxx",
  ]

  # One stateful MNG per AZ (r7g for the page-cache-heavy JVM — ADR-0009/A13).
  stateful_node_groups = {
    "db-az-a" = { subnet_id = module.network.private_subnet_ids[0], instance_types = ["r7g.2xlarge"], min_size = 1, max_size = 2, desired_size = 1 }
    "db-az-b" = { subnet_id = module.network.private_subnet_ids[1], instance_types = ["r7g.2xlarge"], min_size = 1, max_size = 2, desired_size = 1 }
    "db-az-c" = { subnet_id = module.network.private_subnet_ids[2], instance_types = ["r7g.2xlarge"], min_size = 1, max_size = 2, desired_size = 1 }
  }
}
```

## Key outputs

`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`,
`cluster_security_group_id` (DB ports allowed only from this SG), `oidc_issuer_url`
(IRSA fallback), `node_role_arn`, `karpenter_controller_role_arn`.

## Validate (no AWS)

```bash
tofu init -backend=false && tofu validate && tflint
```

## Phase-0/LLD follow-ups

- Replace starter Karpenter policy with the official tightened policy.
- Pin add-on versions; add Cilium (ADR-0023) install (currently VPC-CNI policy on
  the node role as a fallback — Cilium overlay is applied via GitOps).
- Add the internal NLB → PrivateLink endpoint service for the platform API (ADR-0026).
- Wire ADOT/ESO Pod Identity roles via `pod_identity_associations`.
