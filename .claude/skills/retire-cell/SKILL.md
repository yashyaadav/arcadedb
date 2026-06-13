---
name: retire-cell
description: Drain and decommission an empty ArcadeDB cell during scale-in by relocating any tenants, removing it from GitOps, and destroying its Terraform. Use when retiring a cell after capacity/consolidation review (e.g., a cell is underutilized or being decommissioned).
---

# Retire a cell (scale in)

> Safely drain an empty cell and decommission it. WHEN: a cell is being scaled in (underutilized/consolidated). This is a DAY-2 ops runbook for post-go-live. The current CTO package is NOT yet applied to AWS — the Terraform destroy and any cluster mutation are POST-APPROVAL (Spacelift) and OUT OF SCOPE until after CTO sign-off / the relevant phase. Read every step before starting; cell retirement is a multi-tenant-move operation, not a one-shot.

## Prerequisites
- Read access to the control-plane registry/catalog (`../../../control-plane/registry/schema.ts`) and router config (`../../../control-plane/router/index.ts`).
- Cluster access (kubectl) to the cell's EKS context and Argo CD access (the cell is rendered by an ApplicationSet generator).
- Spacelift access for the Terraform `cell` stack (`../../../terraform/modules/cell/`) — destroy requires manual approval (no click-ops, Prime Directive 6).
- The companion procedures available: the **restore-tenant** / tenant-move runbook and the **add-cell** skill (the target cell tenants move INTO must already exist and be healthy).
- Knowledge of the cell's geo (EU or US) — every action stays in-jurisdiction.

## Inputs
- `CELL_ID` — the cell to retire (e.g., `eu-cell-03`).
- `GEO` — `eu` or `us` (must match the cell's region; data and backups never cross geos).
- `ACCOUNT_ID` — AWS account for the geo (placeholder).
- `REGION` — AWS region for the geo (placeholder; e.g., the EU region for an EU cell).
- Target cell(s) for relocating existing tenants (must be same `GEO`, healthy, with headroom).
- List of tenants currently homed on `CELL_ID` (from the catalog).
- Change ticket / approval reference for the Spacelift destroy.

## Safety checks (MUST pass before proceeding)
- **NEVER destroy a cell with active tenants** (data-loss risk). The catalog tenant count for `CELL_ID` must be exactly 0 before the destroy step. ArcadeDB backup is a hot per-DB ZIP that EXCLUDES the WAL and has NO PITR/incremental — a tenant lost here is not recoverable to the last second.
- **Residency (Directive 1):** the destination cell(s) for moved tenants MUST be in the SAME geo as `CELL_ID`. No EU↔US data path; EU tenant data and backups stay in EU. Verify `GEO` matches on both source and target.
- **No quorum impact on OTHER cells (Directive 3):** retiring `CELL_ID` must not touch peers. A DB cannot be split across nodes and replication is per-DB/per-cell, so draining one cell does not affect another cell's 3-node, one-per-AZ Raft quorum or its PDB `minAvailable=2`. Confirm you are only editing the generator entry for `CELL_ID`, not shared infra.
- **Backups retained (Directive 5 / policy):** per-tenant hot-backup ZIPs and EBS snapshots for retired tenants stay in their KMS-encrypted, in-geo S3/snapshot store per the retention policy. Do NOT delete backups as part of retirement.
- **No click-ops (Directive 6):** every mutation is GitOps/Terraform with plan-before-apply; the Terraform destroy is an approval gate in Spacelift.
- **No public DB (Directive 4):** N/A for teardown, but confirm no temporary public exposure is introduced during tenant moves (ports 2480/2424/2434/5432/6379/7687 stay private).
- **Write-freeze is per tenant, brief:** tenant moves freeze writes for ONE tenant at a time during cutover — never freeze or drain the whole cell's writers at once.

## Steps

1. **Mark the cell `draining` in the catalog (control-plane mutation, no AWS infra change).**
   Update the cell record in the registry (`../../../control-plane/registry/schema.ts` model) to `status: draining`. This signals the router (`../../../control-plane/router/index.ts`) to STOP placing NEW tenants on `CELL_ID`. Existing tenants keep serving. Commit via the control-plane GitOps flow (plan/review). This does not disrupt traffic.

2. **Enumerate existing tenants on `CELL_ID`.**
   Query the catalog for all `TenantRecord`s where `cell_id == CELL_ID` (see `../../../control-plane/registry/schema.ts`). Record the list; this is your move worklist. If the list is empty, skip to step 5.

3. **Relocate each existing tenant FIRST via the tenant-move procedure (per-tenant, in-geo).**
   Do NOT improvise — run the **restore-tenant** / tenant-move runbook for each tenant. For each tenant the procedure is:
   a. **Hot-backup** the tenant DB on `CELL_ID` (per-DB ZIP; excludes WAL — that is expected).
   b. **Brief write-freeze** for THAT tenant only — engage the per-tenant kill-switch / set the tenant's write limit to zero at the retrieval proxy (`../../../control-plane/router/index.ts`) so clients fail closed, then take a final consistent backup. The engine has NO per-DB quotas, so the proxy is the only enforcement point. Writes go to the leader, so freeze at the proxy/registry, not by killing pods.
   c. **Restore into the destination cell** (same `GEO`). RESTORE REQUIRES THE TARGET DB TO NOT EXIST — the destination cell must NOT already have a DB with this tenant's name; restore creates it fresh. Run the restore against the destination cell's **leader** (writes are leader-only).
   d. **Rebuild derived state on the destination — DO NOT SKIP.** The hot backup ZIP excludes HNSW vector indexes and Lucene full-text indexes (and WAL), so the restored DB is NOT query-ready until you **rebuild HNSW + Lucene indexes**, and you must **recreate the per-DB least-priv user** (the engine root password is set-once — NEVER re-set the init var; create a NEW per-DB user and store its credential in KMS-encrypted Secrets, Directive 5). Watch pod memory during the rebuild (Directive 7 — index rebuild is memory-heavy; do not OOM-kill and break the destination cell's quorum). See the **restore-tenant** skill, which owns these exact steps.
   e. **Flip the registry** so the tenant's `cell_id` (and `db_name` if it changed) points to the destination cell; the router now sends reads/writes there. Unfreeze the tenant (lift the per-tenant kill-switch / restore limits at the retrieval proxy).
   f. **Verify the tenant on the destination** (see Verification — including that HNSW/Lucene indexes are online and the new user authenticates), then **drop the tenant DB from `CELL_ID`** so the source cell is truly empty.
   Repeat for every tenant. Keep moves serial (one tenant frozen at a time).

4. **Confirm the cell is empty.**
   Re-query the catalog: tenant count for `CELL_ID` must be 0. Independently confirm on the cell that no per-tenant databases remain (no residual DBs on the StatefulSet pods other than system/built-ins). Do NOT proceed past this point if any tenant or tenant DB remains — this is the hard gate from Safety checks.

5. **Remove the cell from GitOps — delete the Argo ApplicationSet generator entry (cluster-affecting; PR + approval).**
   In the GitOps repo, remove `CELL_ID`'s entry from the ApplicationSet generator (the list that renders one Application per cell from the Helm chart `../../../helm/arcadedb/values.yaml`). Open a PR; on merge, Argo prunes the cell's Application, scaling the cell's StatefulSet down and deleting its k8s objects. **This is a cluster mutation — requires review/approval per Directive 6.** Because it only removes `CELL_ID`'s generator entry, other cells' Applications and quorums are untouched.

6. **Destroy the cell infrastructure via Terraform — APPROVAL GATE (Spacelift, AWS-mutating, POST-CTO sign-off).**
   Run a plan on the `cell` stack (`../../../terraform/modules/cell/`, and any cell-scoped EKS/node resources in `../../../terraform/modules/eks/`) targeting ONLY `CELL_ID`'s resources for the `GEO`/`REGION`. Review the plan: it must show destroy of `CELL_ID` ONLY (nodegroups/EBS/networking scoped to this cell), with NO changes to landing-zone (`../../../terraform/landing-zone/`), shared backup-dr, observability, or peer cells. **Manual approval in Spacelift required.** **Until CTO sign-off / the relevant phase, this step is OUT OF SCOPE — stop at the reviewed plan.**

7. **Retain backups per policy (do NOT delete).**
   Confirm the retired tenants' hot-backup ZIPs and EBS snapshots remain in the in-geo, KMS-encrypted store (`../../../terraform/modules/backup-dr/`) under the configured retention. Retirement removes compute, not backups.

8. **Update the catalog to `retired`.**
   Set the cell record `status: retired` in the registry (control-plane GitOps commit). Record the retirement date and the change/approval reference. The router will never place tenants on a `retired` cell.

## Verification
- **Catalog:** `CELL_ID` shows `status: retired` and tenant count 0; no tenant's `cell_id` references `CELL_ID`.
- **Per moved tenant (during step 3):** the tenant resolves to its destination cell via the router; reads fan to destination replicas and a test write reaches the destination leader; `/ready` returns HTTP 204 on destination pods; HNSW + Lucene indexes report built/online and a representative vector + full-text query returns expected results; the new per-DB least-priv user authenticates; record counts/schema match the source pre-move snapshot.
- **GitOps/Argo:** no Application exists for `CELL_ID`; ApplicationSet generator no longer lists it; other cells' Applications remain `Synced/Healthy`.
- **Other cells unaffected:** peer cells still report 3 ready replicas one-per-AZ, PDB `minAvailable=2` satisfied (no quorum regression — observability dashboards via `../../../terraform/modules/observability/`).
- **Terraform (post-approval):** apply completes; `CELL_ID`'s compute/EBS/nodegroups are gone; no drift on landing-zone or peer-cell stacks.
- **Backups:** retired tenants' backup ZIPs + EBS snapshots still present in-geo per retention policy.

## Rollback / if it goes wrong
- **Before step 5 (no infra removed yet):** flip the cell back to `available` in the catalog (the live cell status; there is no `active` cell status — see `CellRecord.status` in `../../../control-plane/registry/schema.ts`) and re-home any tenant whose move you have not yet committed. Tenants already moved and verified stay on their new home cell — do NOT move them back unless a verification failed.
- **A tenant move fails mid-cutover:** the source DB on `CELL_ID` still exists (you only drop it after verifying the destination). Keep the tenant FROZEN, do NOT drop the source, unfreeze on the SOURCE (revert the `cell_id` flip in the registry), and re-run the move once the destination issue is fixed. Remember: restore needs the target DB to NOT exist, so delete the half-restored DB on the destination (and discard its partial indexes) before retrying.
- **Argo entry removed but you must abort (between step 5 and step 6):** re-add the generator entry and let Argo re-sync the cell; the StatefulSet/PVCs return. Restore tenant DBs from retained backups only if any DB was already dropped (restore into the freshly re-synced, empty cell).
- **After Terraform destroy:** the cell is gone. To recover, treat as a NEW cell — follow the **add-cell** skill to provision, then restore each tenant from retained in-geo backups via the **restore-tenant** skill (restore requires the target DB to not exist, which a fresh cell satisfies; then REBUILD HNSW + Lucene indexes and RECREATE the per-DB user — the ZIP excludes derived state). For a whole-cell loss, prefer EBS-snapshot restore over looping 150 per-DB ZIPs (see `dr-drill`). Backups were retained precisely for this.
- **Quorum scare on a PEER cell during the work:** stop. Retirement should never touch peers; investigate the peer cell independently (it has its own per-cell Raft). Do not continue the destroy until peer quorum is healthy.

## Related
- **add-cell** — provision a new cell (scale out); the inverse of this runbook and the recovery path after an accidental destroy.
- **restore-tenant** / tenant-move runbook — the per-tenant relocation invoked in step 3 (hot-backup → restore into new cell → flip registry → drop from old).
- ADRs: cell-based scaling / single-leader write ceiling and "scale by adding cells"; per-DB replication and quorum model; backup strategy (hot ZIP + EBS snapshots, no PITR) — see `../../../docs/adr/` and `../../../docs/architecture.md`.
- Assumptions and gotchas: `../../../docs/assumptions.md`.
- Control plane: `../../../control-plane/registry/schema.ts`, `../../../control-plane/router/index.ts`, `../../../control-plane/provisioning/deprovision.asl.json`.
