---
name: provision-tenant
description: Provision a new tenant (one virtual ArcadeDB database) by driving the control-plane provisioning Step Functions flow. Use when onboarding a tenant or re-running a partially-failed provision (the flow is idempotent).
---

# Provision a tenant

> Onboards one tenant = one virtual ArcadeDB database in its home geo, with a least-priv user, HNSW + Lucene indexes, KMS-backed secret, a backup policy, and an `active` registry record. **Phase note:** the provisioning flow and its Lambda targets are an INTERFACE STUB until Phase 2; executing it against AWS MUTATES the cluster + control plane and is **out of scope until after CTO sign-off and the Phase-2 control-plane rollout**. Dry-run / read-only inspection is fine now.

## Prerequisites

- The tenant's `home_geo` matches **the control plane you are operating** (EU operators run the EU control plane; US operators run the US control plane). There is no cross-geo provisioning — see Safety checks.
- AWS access to the correct geo's account (`ACCOUNT_ID`, region per geo) via SSO; permission to start the `kb-provision-tenant` state machine and read DynamoDB / Secrets Manager.
- Phase 2 deployed: provisioning state machine + its Lambdas wired (currently stubs). If you are pre-Phase-2, you may only validate inputs and read the registry.
- A target cell exists in-geo for this `env`/`tier` with free capacity (confirm with `cell-capacity-report`). If none has room, run `add-cell` **first** — do not pack a full cell.
- The artifact under change: [`statemachine.asl.json`](../../../control-plane/provisioning/statemachine.asl.json); registry contract: [`schema.ts`](../../../control-plane/registry/schema.ts).

## Inputs

| Input | Type | Notes |
|---|---|---|
| `tenant_id` | string | Stable unique id; becomes the registry PK and seeds `db_name`. |
| `home_geo` | `eu` \| `us` | **Immutable residency anchor.** Must equal the control plane's geo. |
| `tier` | `standard` \| `enterprise` | Drives placement, durability (`tx_wal_flush`), backup cadence. |
| `projected_size_gb` | number | Placement signal. `> ~50 GB` (or `enterprise`) → **dedicated cell, never pooled**. |
| `env` | `dev` \| `stage` \| `prod` | Selects the cell pool; prod cells are 3-node/quorum. |

The state machine reads `$.control_plane_geo` (injected by the runner) and compares it to `$.home_geo`.

## Safety checks (MUST pass before proceeding)

- **Residency (PD #1):** `home_geo == control_plane_geo`. If not, **STOP** — the flow's first state `AssertHomeGeo` will `Fail` with `ResidencyViolation` and there must be **no EU↔US data path**. Never "fix" this by running the other geo's control plane against this tenant. Registry is regional DynamoDB, never a global table (ADR-0008).
- **No root creds (ArcadeDB gotcha):** provisioning creates a **per-DB least-priv user + group**, never root. The root password is SET-ONCE and is **not** what tenants use. Do not pass or reuse root.
- **Placement isolation (PD #3, sizing):** `projected_size_gb > ~50` **or** `tier == enterprise` ⇒ a **dedicated** cell (`cell_isolation: cluster`). A DB cannot be split across nodes; you scale by **adding cells**, not by overloading one. Never place a big/enterprise tenant in a pooled namespace cell.
- **Capacity (no per-DB quotas):** ArcadeDB has **no per-DB resource quotas** — the control plane caps capacity. Confirm the target cell is not `full` (any cap trips: `max_standard_dbs ~150`, `max_page_ram_commit_ratio ~0.60`, `max_disk_used_ratio ~0.70`). Over-packing risks OOM-kill and quorum loss (PD #7).
- **Encryption (PD #5):** the engine provides none. The secret lands in Secrets Manager under KMS; the DB's EBS/snapshots are KMS-encrypted. Do not write creds anywhere else (no plaintext, no ticket, no chat).
- **No click-ops (PD #6):** never `CREATE DATABASE` / `CREATE USER` by hand against a node. Provisioning is **only** via the Step Functions flow so it stays idempotent + audited. The cell itself was created by Terraform/Helm/GitOps.
- **No public DB (PD #4):** you provision **through the control plane / VPC-internal path** only; ports 2480/2424/2434/5432/6379/7687 are never reachable publicly.
- **Approval gate:** running the flow against AWS is a **mutating, post-sign-off action**. Get the documented approval before `start-execution`.

## Steps

> The flow is **idempotent** — every state is a no-op if its effect already exists, so a re-run safely resumes a partial provision. Order is fixed by [`statemachine.asl.json`](../../../control-plane/provisioning/statemachine.asl.json).

1. **Gather + validate inputs.** Confirm `tenant_id`, `home_geo`, `tier`, `projected_size_gb`, `env`. Re-check `home_geo` equals your control-plane geo (Safety check #1).
2. **Pick the cell (placement).** Run `cell-capacity-report` for `home_geo + env + tier`. Apply the placement rule: enterprise or `> ~50 GB` ⇒ dedicated cell; otherwise least-loaded pooled cell with headroom. If none qualifies, run **`add-cell`** before continuing. Record the chosen `cell_id`.
3. **[APPROVAL GATE — AWS-mutating, post-sign-off]** Obtain the documented approval to provision into the live geo account.
4. **Start the provisioning execution** with the validated payload (geo account, correct region). Example (placeholders — do not run pre-approval):
   ```bash
   aws stepfunctions start-execution \
     --state-machine-arn arn:aws:states:REGION:ACCOUNT_ID:stateMachine:kb-provision-tenant \
     --name "provision-${tenant_id}-$(date +%s)" \
     --input '{"tenant_id":"<id>","home_geo":"<eu|us>","tier":"<standard|enterprise>","projected_size_gb":<n>,"env":"<dev|stage|prod>","cell_id":"<from step 2>"}'
   ```
   The flow then executes, in order:
   - `AssertHomeGeo` — residency guard; `Fail`s on cross-geo (PD #1).
   - `CreateDatabase` — creates the tenant DB **replicated 3x** on the chosen cell (no-op if it exists).
   - `CreateLeastPrivUser` — per-DB least-priv user + group, **not root** (set-once-root gotcha; least-privilege).
   - `CreateIndexes` — **HNSW** (vector) + **Lucene** (full-text) for GraphRAG (ADR-0024).
   - `StoreCredentials` — DB creds into Secrets Manager, KMS-encrypted, rotatable (ADR-0018).
   - `RegisterBackup` — backup schedule + retention tier (ADR-0015). Note: backups are hot per-DB ZIPs that **exclude WAL**, with **no incremental / no PITR** — EBS snapshots (ADR-0016) supplement.
   - `UpdateRegistry` — set registry `status=active` and **emit an audit event** (the app-layer substitute for native audit, which ArcadeDB lacks).
5. **Watch the execution** to `Succeed`. On any task failure it routes to `ProvisioningFailed` (emits a failure audit event + marks the registry); fix the cause and **re-run the same input** — idempotency converges.

## Verification

Run the flow **twice with the same input** and confirm the second run is a clean no-op (idempotency), then verify each artifact exists exactly once:

- **DB:** the tenant DB exists on `cell_id`, replicated across the 3 cell nodes (one per AZ in prod). Writes go to the leader, reads fan to replicas.
- **User:** the per-DB least-priv user + group exist; **root was not used**.
- **Indexes:** HNSW and Lucene indexes are present on the DB.
- **Secret:** a Secrets Manager secret holds the DB creds (KMS-encrypted); `secret_arn_pointer` in the registry resolves to it.
- **Backup:** a `backup_policy` is registered with the expected cadence/retention for the tier.
- **Registry + audit:** `TenantRecord.status == active` with correct `home_geo`, `cell_id`, `db_name`; a `create-db` `AuditEvent` (`outcome: success`) was emitted in the correct geo (ADR-0008).
- **Residency:** all of the above live **only** in the home geo's account/region; nothing replicated cross-geo.

## Rollback / if it goes wrong

- **Cross-geo rejection (`ResidencyViolation`):** expected and correct — do not bypass. Provision from the matching geo's control plane.
- **Partial failure:** the flow is idempotent and self-healing — **re-run the same input** to resume from where it stopped. Do not hand-patch resources.
- **Wrong placement (e.g. a big/enterprise tenant landed in a pooled cell, or cell now over cap):** do **not** drop the DB manually. Run **`deprovision-tenant`** to cleanly remove it (drops DB, revokes secret, emits deletion evidence), confirm with `cell-capacity-report` / `add-cell`, then re-provision with corrected placement.
- **Secret created but DB failed (or vice-versa):** re-run; idempotency reconciles. Never leave an orphan secret — `deprovision-tenant` revokes it if you must back out fully.
- **Note:** restore/recovery for an existing tenant is a different runbook (`restore-tenant`); restoring **requires the target DB to not exist** — never restore over a live tenant DB.

## Related

- ADR-0008 — tenant registry: regional DynamoDB, never global table ([adr](../../../docs/adr/0008-tenant-registry-dynamodb.md)).
- ADR-0007 (residency SCP), ADR-0018 (secrets/ESO), ADR-0015 (backup), ADR-0016 (snapshots), ADR-0024 (GraphRAG indexes), ADR-0004 (cell isolation).
- State machine: [`provisioning/statemachine.asl.json`](../../../control-plane/provisioning/statemachine.asl.json); registry contract: [`registry/schema.ts`](../../../control-plane/registry/schema.ts).
- Skills: `deprovision-tenant`, `cell-capacity-report`, `add-cell`, `restore-tenant`, `rotate-secrets`.
- Architecture: [`docs/architecture.md`](../../../docs/architecture.md); assumptions: [`docs/assumptions.md`](../../../docs/assumptions.md).
