# ADR-0015 — Backup mechanism: CronJob sidecar → S3 (over the auto-backup plugin)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Take hot per-DB ZIP backups via a **Kubernetes CronJob sidecar** that calls the backup API, verifies, uploads to S3 (SSE-KMS), and records status in the registry — in preference to ArcadeDB's in-engine auto-backup plugin. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB backup is **online/hot, per-DB, ZIP, excludes WAL; no incremental, no PITR, no native S3 target** (F5). We need verifiable, observable, residency-safe backups landing in S3 with per-tenant retention tiers and registry-tracked status. The engine has an auto-backup plugin, but it writes locally and gives us little control/observability and no S3 target.

## Assumptions it rests on

- A15 (cadence: standard 6h / enterprise 1h), prime directive #1 (in-geo), prime directive #5 (encrypt).

## Options considered

### Option A — CronJob sidecar → verify → S3 (chosen)
- **Pros:** full control over cadence, retention tiers, and **verification** (test the ZIP before trusting it); explicit **S3 upload** (the engine has no native S3 target); **registry status + observability** (last-backup-age alerting); residency-safe bucket layout `s3://kb-backups-<geo>-<env>/cell/<cell>/<tenant>/<ts>.zip` with in-geo CRR + Object Lock for enterprise; runs as ordinary K8s workload (hand-over friendly).
- **Cons:** we build + operate the sidecar/CronJob; more moving parts than "turn on the plugin".

### Option B — In-engine auto-backup plugin
- **Pros:** built-in, least code.
- **Cons:** writes **locally** (still need to get it to S3); weaker observability/verification; less control over per-tenant cadence/retention; doesn't fit the registry-tracked, alertable model.

## Decision

**CronJob sidecar → verify → S3**, with EBS snapshots as the complementary layer ([ADR-0016](0016-snapshot-aws-backup.md)). Standard 6h / enterprise 1h cadence; tiered retention; in-geo CRR; Object Lock for enterprise; status written to the registry and alerted on (last-backup-age > SLA).

## Reasoning — why this beats the alternatives

Because the engine omits an S3 target, **incremental, and PITR**, backups are a place we must add safety ourselves — and that means **verification + observability + explicit S3 control**, which the sidecar gives and the plugin does not. "Untested backups are not backups": the sidecar's verify-then-record loop is the difference between a backup strategy and a hope. The extra operational surface is justified by backups being the last line of defence (no PITR).

## Consequences

- **Positive:** verifiable, observable, residency-safe S3 backups with per-tenant tiers + registry status + age alerting.
- **Negative / costs:** we own the sidecar/CronJob + its IAM (Pod Identity → S3); ZIP excludes WAL (covered by EBS snapshots, 0016); restore has the "target DB must not exist" gotcha (F5) baked into the [restore-tenant] runbook.
- **Follow-ups:** backup-dr module (CronJob, S3 SSE-KMS, CRR, Object Lock); last-backup-age alert; monthly restore-a-random-tenant test; the restore runbook + index rebuild.

## Review-trigger

ArcadeDB adds a native S3 target / incremental / PITR (re-evaluate the sidecar); backup volume/cost shifts; or restore time threatens RTO (lean harder on EBS-snapshot whole-cell restore).
