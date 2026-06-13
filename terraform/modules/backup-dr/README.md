# Module: `backup-dr`

Layered backup + DR for ArcadeDB cells (HLD §7.4, ADR-0014/0015/0016):

- **(A) Hot per-DB ZIP → S3** — a versioned, **SSE-KMS** bucket with **in-geo
  Cross-Region Replication**, tier-aware lifecycle, and optional **Object Lock
  (WORM)**. The CronJob sidecar that *produces* the ZIPs runs in-cluster
  (Helm/GitOps); this module is the AWS-side target it writes to.
- **(B) AWS Backup EBS snapshots** — a KMS-encrypted vault + plan that snapshots
  the ArcadeDB data volumes and copies them **in-geo** to the DR vault, with
  optional **Vault Lock** immutability.

> **CTO-package status:** basic boilerplate template — validate-clean, **not applied**.
> Residency: `region` and `dr_region` are both guarded to the in-geo allow-list.

## What it creates

| Resource | Notes |
|---|---|
| `aws_s3_bucket.backups` (+ versioning, SSE-KMS, public-access-block, TLS-only policy) | Layout `kb-backups-<geo>-<env>` → `cell/<cell>/<tenant>/<ts>.zip`. |
| `aws_s3_bucket_object_lock_configuration` | COMPLIANCE-mode WORM (enterprise). |
| `aws_s3_bucket_lifecycle_configuration` | Standard (`cell/`) vs enterprise (`enterprise/`) retention + tiering. |
| S3 replication role + `aws_s3_bucket_replication_configuration` | **In-geo CRR only** to `dr_bucket_arn`, KMS re-encrypt at destination. |
| `aws_backup_vault` (+ optional Vault Lock) | KMS-encrypted snapshot vault. |
| `aws_backup_plan` + `aws_backup_selection` | ~6h EBS snapshots, retention, **in-geo copy** to `dr_backup_vault_arn`; selects volumes tagged `platform=arcadedb-kb`. |
| `aws_backup` IAM role | Standard AWS Backup service roles. |

## Residency

`dr_bucket_arn` / `dr_backup_vault_arn` must point at resources in `dr_region`,
which is guarded to be **in-geo**. The destination bucket/vault are created by a
**second instance of this module in the DR region** (see the environment example).

## Usage (primary region)

```hcl
module "backup_dr" {
  source = "../../modules/backup-dr"

  name               = "kb-eu-prod"
  geo                = "eu"
  env                = "prod"
  region             = "eu-central-1"
  dr_region          = "eu-west-1"
  allowed_regions    = ["eu-central-1", "eu-west-1"]
  backup_kms_key_arn = module.kms.backups_key_arn

  dr_bucket_arn         = module.backup_dr_replica.backup_bucket_arn   # in eu-west-1
  dr_bucket_kms_key_arn = module.kms_dr.backups_key_arn
  dr_backup_vault_arn   = module.backup_dr_replica.backup_vault_arn

  enable_object_lock       = true   # enterprise WORM
  enable_backup_vault_lock = true
}
```

## Key outputs

`backup_bucket_name`, `backup_bucket_arn`, `backup_vault_arn`, `backup_vault_name`,
`replication_enabled`, `object_lock_enabled`.

## Phase-0/LLD follow-ups

- The hot-ZIP CronJob + verification + registry status (in Helm/control-plane).
- Restore tooling ("target DB must not exist" + index rebuild — `restore-tenant` skill).
- Cross-account/region KMS key policies for replication.
