# CLAUDE.md — terraform/

Directory rules for the IaC. Inherits the root [`CLAUDE.md`](../CLAUDE.md)
prime directives. **Phase D: validate only — never `apply`.**

## Module boundaries

- `landing-zone/` — org OUs + **residency SCPs** + baseline guardrail + per-geo
  state + SSO permission sets. Root config (has its own providers, incl. `aws.eu`/`aws.us`).
- `modules/network` — 3-AZ private VPC + endpoints (no public DB).
- `modules/eks` — regional cluster; **per-AZ MNG for the stateful DB tier**
  (AZ-pinned, tainted, autoscaling off), Karpenter for stateless, Pod Identity.
- `modules/cell` — one ArcadeDB cell (namespace, gp3-KMS StorageClass, PDB,
  default-deny NetworkPolicy, governance, optional Helm release). **The heart.**
- `modules/backup-dr` — backup S3 (SSE-KMS + in-geo CRR + Object Lock) + AWS Backup.
- `modules/observability` — AMP + AMG + alerts + log groups + SNS→PagerDuty.
- `environments/` — one shared root config + a `tfvars` per geo/env. Validating
  it exercises the whole composition.

## Hard rules (hooks + CI enforce)

- **Residency**: every module taking `region` also takes `allowed_regions` and a
  `terraform_data` precondition fails the plan if `region ∉ allowed_regions`.
  **Never write an out-of-geo region literal** (the OPA gate + SCP also catch it).
- **No public DB**: never set a security-group ingress for ports
  2480/2424/2434/5432/6379/7687 with `cidr_blocks = ["0.0.0.0/0"]`.
- **Quorum**: the cell module enforces prod `replicas >= 3` + `pdb_min_available >= 2`.
- **Version floor**: cell module enforces ArcadeDB tag `>= 26.4.1`.
- **Encrypt everything**: pass a KMS key to EBS/S3/Secrets/logs (no plaintext).
- **Pin all versions** in `versions.tf` (floor `>= 1.10`).

## State layout

S3 backend, SSE-KMS, versioned, **per-geo bucket**, **S3-native locking**
(`use_lockfile=true`, no DynamoDB lock table — ADR-0022). EU state in the EU
bucket, US state in the US bucket. Backend config is supplied per environment
via `-backend-config` (see `environments/backend.tf`).

## Naming

`kb-<geo>-<env>[-<role>]` (e.g. `kb-eu-prod`, cell `kb-eu-prod-std-01`). Tags:
`platform`, `geo`, `env`, `module`, `managed-by`, `residency-boundary`.

## How to run plan/apply (POST-APPROVAL only)

Via **Spacelift** (ADR-0020): stack graph landing-zone → network → eks → cell;
**mandatory manual approval on prod / any geo-prod apply**. Locally, plan only,
and run the **`review-terraform-plan`** skill before any approval — it flags a DB
SG opened to the world, a destroy of stateful resources, residency violations,
and KMS/role changes.

## Validate (this is all we do in Phase D)

```bash
make tf-validate   # init -backend=false + validate, every module + env
make tflint
make fmt-check
```
