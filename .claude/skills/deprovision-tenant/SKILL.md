---
name: deprovision-tenant
description: Offboards a tenant cleanly (drop DB, revoke secret, mark registry, emit audit) by driving the deprovision state machine. Use for normal contract end / churn — NOT for legal Right-To-Be-Forgotten erasure (use tenant-erasure).
---

# Deprovision a tenant

> Normal offboarding of a tenant whose contract ended: take an optional final retained backup, drop the tenant's ArcadeDB database, revoke its secret, set registry `status=deprovisioning`→`erased`, and emit an audit record. This is NOT legal erasure (RTBF/DSAR) — for that use the `tenant-erasure` skill, which intentionally skips the retained backup. PHASE NOTE: all mutating steps below (state-machine execution, DB drop, secret deletion, registry write, backup) touch live AWS/cluster resources and are OUT OF SCOPE until after CTO sign-off and go-live; until then this runbook is a dry-read walkthrough only.

## Prerequisites

- The CTO package is applied and the target geo's control plane is live (this is a Day-2 runbook).
- You can assume the **in-geo** control-plane role for the tenant's `home_geo` (`eu` or `us`). You must operate from the matching region — never the paired/foreign geo.
- Read access to the regional tenant registry (DynamoDB, ADR-0008) and Step Functions execute permission for `../../../control-plane/provisioning/deprovision.asl.json`.
- A signed deprovisioning ticket / change record with the tenant_id and explicit confirmation the contract has ended.
- Confirmation this is **normal offboarding**, not RTBF. If a data-subject erasure obligation applies, STOP and use `tenant-erasure`.

## Inputs

- `tenant_id` — exact id from the registry (`TenantRecord.tenant_id`).
- `home_geo` — `eu` | `us`; MUST equal the control plane you are running in (`control_plane_geo`).
- `env` — `dev` | `stage` | `prod` (prod requires the approval gate below).
- `retain_final_backup` — `true` for normal offboarding (default), `false` only when erasure is intended (then use `tenant-erasure` instead).
- `retention_window` — how long the final ZIP is kept before lifecycle expiry (per `backup_policy` / contract).
- Change-ticket reference for the audit trail.

## Safety checks (MUST pass before proceeding)

- **Confirm identity, twice.** Re-read `tenant_id` AND `home_geo` from the registry and read them back to the requester. ArcadeDB has **no per-DB resource quotas or soft fences** (the control plane / retrieval proxy is the only enforcement point), so the engine will not stop you from dropping the wrong DB — and a drop is unrecoverable except from backup.
- **Geo match (Directive 1 — Residency).** `home_geo` MUST equal this control plane's geo. The state machine's `AssertHomeGeo` fails closed with `ResidencyViolation` otherwise. Never run an EU tenant's deprovision from US (or vice-versa); there is NO EU↔US data path, and the final backup must land in-jurisdiction (ADR-0006/0007).
- **No legal hold.** Verify the tenant is NOT under legal hold or active investigation. If held, ABORT — do not drop the DB and do not let lifecycle expire the final backup. The `FinalBackup` step is legal-hold aware; honor it.
- **Final backup before drop (normal offboarding).** Ensure `retain_final_backup=true` so a final hot ZIP exists before the DB is dropped. Note the ArcadeDB backup gotchas: it is a hot per-DB ZIP that **EXCLUDES the WAL**, has **no incremental and no PITR**, and **no native S3 target** — our pipeline (ADR-0015) copies the ZIP to the in-geo, KMS-encrypted bucket; supplement with the EBS snapshot lineage (ADR-0016). If you skip the backup you are doing erasure — switch skills.
- **Encryption (Directive 5).** The retained backup bucket and any snapshot are KMS-encrypted (the engine provides none). Do not stage the ZIP anywhere unencrypted.
- **Not a write you can split.** A tenant DB lives on one cell's leader; deprovision affects only that cell. Confirm `cell_id` from the registry so you operate against the right cell.
- **Prod approval (Directive 6 — No click-ops).** For `env=prod`, the destructive run requires manual approval (Spacelift change / signed ticket). Do not invoke the drop ad hoc from a shell.

## Steps

> All steps from 3 onward MUTATE AWS/cluster state and are post-approval / post-go-live only.

1. **Pull the record.** Read the `TenantRecord` from the regional registry and capture `tenant_id`, `home_geo`, `env`, `tier`, `cell_id`, `db_name`, `secret_arn_pointer`, `backup_policy`. Confirm current `status` is `active` or `suspended`. (Read-only.)
2. **Run the safety checklist above.** Confirm tenant_id + geo with the requester, confirm no legal hold, confirm normal-offboarding (not RTBF). (Read-only.)
3. **Set status `deprovisioning`.** Update the registry `status` to `deprovisioning` so the router stops placing new traffic and the kill-switch/governance view (ADR-0027) reflects intent. **[AWS-mutating]**
4. **APPROVAL GATE (prod).** Obtain manual approval for the destructive run (Spacelift / signed change). Do not proceed without it for `env=prod`. **[approval gate]**
5. **Execute the deprovision state machine.** Start an execution of `../../../control-plane/provisioning/deprovision.asl.json` in the **in-geo** region with input including `tenant_id`, `home_geo`, `control_plane_geo`, `db_name`, `cell_id`, `secret_arn_pointer`, `retain_final_backup=true`, `retention_window`, and the change-ticket ref. The state machine runs, in order: **[AWS-mutating]**
   - `AssertHomeGeo` — fails closed (`ResidencyViolation`) if `home_geo ≠ control_plane_geo`.
   - `FinalBackup` — optional, legal-hold-aware final hot ZIP to the in-geo KMS bucket (skipped only when erasure is intended).
   - `DropDatabase` — drops the tenant DB on its cell leader (idempotent — a no-op if already gone; `Catch`→`DeprovisionFailed` on hard error).
   - `RevokeSecrets` — deletes the tenant DB credentials from Secrets Manager (ADR-0018).
   - `EmitDeletionEvidence` — sets registry `status=erased` and emits the audit event + deletion certificate (ArcadeDB has NO native audit — this is the control-plane audit record).
6. **If the run fails,** read `$.error` and **re-run the same execution** — it is idempotent (the drop is a no-op if the DB is already gone, secret deletion and registry write are convergent). Do not hand-delete resources out of band; let the state machine converge so the audit/evidence stays consistent.

## Verification

- State machine execution reached `DeprovisionSucceeded`.
- Registry `TenantRecord.status == erased` for `tenant_id`, with `updated_at` advanced.
- The tenant DB no longer exists on `cell_id`'s leader — a query/connect for `db_name` returns "database does not exist" (this is also the precondition a future restore would need, since RESTORE REQUIRES THE TARGET DB TO NOT EXIST).
- The Secrets Manager secret at `secret_arn_pointer` is deleted/scheduled-for-deletion; ESO no longer syncs it.
- Final retained backup ZIP is present in the **in-geo** KMS-encrypted bucket with the agreed `retention_window` (normal offboarding only).
- A deletion-evidence audit event + certificate were emitted and are retrievable.
- Capacity reclaimed on the cell — re-run `cell-capacity-report` to confirm headroom moved (no per-DB quota exists, so capacity is tracked at the control plane).

## Rollback / if it goes wrong

- **There is no "un-drop."** Once `DropDatabase` succeeds the DB is gone. Recovery is restore-from-backup only: use `restore-tenant` against the final retained ZIP (plus EBS snapshot lineage if needed). Remember RESTORE REQUIRES THE TARGET DB TO NOT EXIST — restore into a fresh/renamed DB, never over a live one.
- **Stopped after `FinalBackup`, before drop:** safe to abort. Reset registry `status` back to `active`/`suspended`; the tenant is unaffected.
- **Drop succeeded but a later step failed:** re-run the execution (idempotent) to converge `RevokeSecrets` + `EmitDeletionEvidence`; do not leave the secret or registry in a half-state.
- **Wrong tenant dropped:** treat as a Sev-1 — invoke `incident-triage`, then `restore-tenant` from that tenant's most recent backup into a new DB and re-point the secret/registry. Preserve all evidence.
- **`ResidencyViolation`:** you ran from the wrong geo. Stop, switch to the correct in-geo control plane, and re-run; never reroute the data across the EU↔US boundary.

## Related

- `tenant-erasure` — RTBF/DSAR legal erasure (same state machine, `retain_final_backup=false`; the load-bearing difference is no retained backup + erasure evidence).
- `provision-tenant` — the inverse onboarding flow.
- `restore-tenant` — recover a tenant DB from backup (only path back after a drop).
- `cell-capacity-report` / `retire-cell` — reclaim/confirm capacity after offboarding.
- Artifacts: `../../../control-plane/provisioning/deprovision.asl.json`, `../../../control-plane/registry/schema.ts`, `../../../control-plane/router/index.ts`.
- ADRs: `../../../docs/adr/0007-residency-enforcement-scp.md`, `../../../docs/adr/0008-tenant-registry-dynamodb.md`, `../../../docs/adr/0015-backup-cronjob-sidecar.md`, `../../../docs/adr/0016-snapshot-aws-backup.md`, `../../../docs/adr/0018-secrets-secrets-manager-eso.md`, `../../../docs/adr/0027-runtime-tenant-governance.md`.
