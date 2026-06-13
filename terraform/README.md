# Terraform / OpenTofu — module library + conventions

> **CTO-package status:** these are **basic boilerplate templates** —
> parameterised, instantiable, and **`tofu validate`-clean**, but **NOT applied
> to AWS**. Account IDs and sensitive values are placeholders. There are no live
> resources and no credentials are required to validate. See [ADR-0002](../docs/adr/0002-iac-terraform-opentofu.md).

## Layout

```
terraform/
├── README.md                 # this file
├── landing-zone/             # Org/OUs, SCPs (residency deny), KMS, per-geo state, identity, baseline
├── modules/
│   ├── network/              # 3-AZ private VPC + endpoints (no public DB)
│   ├── eks/                  # regional EKS + node groups (MNG stateful + Karpenter) + Pod Identity
│   ├── cell/                 # one ArcadeDB cell: namespace, StorageClass, Helm release, PDB, NetworkPolicy, backup prefix
│   ├── backup-dr/            # backup S3 (SSE-KMS + in-geo CRR + Object Lock), AWS Backup, warm-standby hooks
│   └── observability/        # AMP, AMG, alert rules, Fluent Bit → CloudWatch
└── environments/             # example tfvars per geo/env (eu/us × dev/stage/prod) — instantiates the modules
```

## Conventions (enforced by hooks + CI)

| Convention | Rule |
|---|---|
| **Version floor** | `required_version = ">= 1.10.0"` in every `versions.tf` (S3-native state locking, [ADR-0022](../docs/adr/0022-state-locking-s3-native.md)). |
| **Pin providers** | Every provider pinned with an explicit constraint (`>= X, < Y`). Prime directive: pin all versions. |
| **Residency** | Every module that takes a `region` also takes `allowed_regions` and fails the plan if `region ∉ allowed_regions`. No out-of-geo region literals (CI OPA gate, [ADR-0007](../docs/adr/0007-residency-enforcement-scp.md)). |
| **No public DB** | No security group opens DB ports (2480/2424/2434/5432/6379/7687) to `0.0.0.0/0`; DB never on a public subnet/LB (prime directive #4). CI OPA gate enforces. |
| **Encrypt everything** | EBS/S3/Secrets/snapshots/log-groups use a KMS key (prime directive #5). |
| **Quorum** | Cell module defaults to `replicas = 3` with a PDB `minAvailable = 2`; non-prod may override to single-node (cost). |
| **Tagging** | Every resource carries `platform`, `geo`, `env`, `module`, `managed-by`, and `residency-boundary` tags via a `common_tags` local. |
| **State** | S3 backend, SSE-KMS, versioned, **per-geo bucket**, native locking. Backend config is per-environment (`backend.tf`, placeholders here). |

## Provider pin reference (the canonical set)

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = ">= 5.80.0, < 6.0.0" }
    helm       = { source = "hashicorp/helm",        version = ">= 2.16.0, < 3.0.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = ">= 2.35.0, < 3.0.0" }
    random     = { source = "hashicorp/random",      version = ">= 3.6.0,  < 4.0.0" }
    tls        = { source = "hashicorp/tls",         version = ">= 4.0.0,  < 5.0.0" }
  }
}
```

Each module declares only the providers it uses. **Modules never configure
providers** — the environment root configures them (region, kube/helm host).

## Validate everything locally (no AWS)

From the repo root:

```bash
make tf-validate     # init -backend=false + validate, every module + env
make tflint          # tflint, every module + env
make fmt-check       # tofu fmt -check -recursive
make conftest        # OPA residency + no-public-DB policies
```

`init -backend=false` downloads providers but **never** contacts AWS or reads
remote state. No target here runs `plan` or `apply`.

## After CTO sign-off (Phase 0 / LLD)

The module bodies are deliberately "basic but real". The LLD (`docs/lld.md`)
adds: full IAM policy documents, KMS key policies, the Spacelift stack graph,
IPAM pools, Karpenter NodePools/EC2NodeClasses, Argo ApplicationSet wiring, and
the control-plane Step Functions ASL. Until then, **do not `apply`**.
