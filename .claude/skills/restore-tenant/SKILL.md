---
name: restore-tenant
description: Restores a single tenant's virtual DB from an in-geo backup ZIP, then rebuilds derived state (indexes, user, schedule). Use when a tenant DB is corrupted, accidentally dropped, or must be rolled back to a known-good point.
---

# Restore a tenant from backup

> What/when: recover one tenant's DB from its hot backup ZIP into a target cell. Phase note: all AWS/cluster-mutating steps (S3 reads, drop/rename/restore of the DB, user + schedule recreation) are POST-CTO-approval and out of scope until the relevant phase is live. This runbook is a guided runbook — read the Safety checks before touching anything. For losing a whole cell, do NOT loop this skill; see Rollback and `dr-drill`.

## Prerequisites
- Restore is run against ArcadeDB **>= 26.4.1** (Prime Directive 2). Confirm the engine version on the target cell before proceeding.
- `kubectl` context for the **target cell in the tenant's own geo** (EU tenant -> EU cluster only). No cross-geo kubeconfig.
- AWS CLI with read access to the in-geo backup bucket and KMS decrypt on its key (Prime Directive 5; backups are KMS-encrypted, the engine provides nothing).
- Tenant identity confirmed against the control-plane registry: `../../../control-plane/registry/schema.ts` (tenant -> cell -> geo mapping). Never infer the cell.
- Access to the retrieval proxy/control plane to set a per-tenant kill-switch while the DB is unavailable: `../../../control-plane/router/index.ts`.
- Spacelift access for any approval-gated apply (Prime Directive 6 — no click-ops).

## Inputs
- `TENANT` — tenant id (must match registry).
- `CELL` — target cell id (from registry; restore back into the same cell unless doing a planned move).
- `GEO` — `eu` or `us` (from registry; drives bucket + cluster selection).
- `ENV` — `prod` / `nonprod`.
- `TS` — backup timestamp to restore (the `<ts>` in the S3 key). Default: latest in-geo object for the tenant.
- `RTO` — agreed recovery-time objective for this tenant (to compare measured restore time against).

## Safety checks (MUST pass before proceeding)
- **In-geo bucket only (Prime Directive 1 — Residency).** The ZIP MUST come from `s3://kb-backups-<GEO>-<ENV>/...`. Restoring an EU tenant from a US bucket (or vice-versa) is a residency breach — STOP. There is NO EU<->US data path.
- **Restore in-jurisdiction (Prime Directive 1).** Target cell/cluster must be in the same geo as the source bucket. DR pairs are in-jurisdiction.
- **Target DB MUST NOT EXIST (ArcadeDB gotcha).** ArcadeDB **refuses to restore over an existing DB**. If the DB exists you MUST drop or rename it first (Step 4). Never restore on top of live data.
- **ZIP excludes derived state (ArcadeDB gotcha).** The hot backup ZIP **does not contain HNSW vector indexes or Lucene indexes** (and excludes WAL). A restored DB is NOT query-ready until indexes are rebuilt (Step 7). Do not smoke-test or unblock the tenant before rebuild.
- **No PITR / no incremental (ArcadeDB gotcha).** You can only restore to a discrete backup `TS`; writes after that `TS` are lost. Confirm the chosen `TS` with the requester and capture data-loss window in the audit.
- **Root password is set-once (ArcadeDB gotcha).** Do NOT attempt to re-set the init root password during restore. The per-DB least-priv user is RECREATED as a new user (Step 8) — never re-set the root init var.
- **Version floor + isolation (Prime Directive 2).** If the target cell was recently upgraded, the cross-DB isolation re-audit must be complete before reintroducing a tenant DB.
- **Encryption (Prime Directive 5).** Restored data lands on KMS-encrypted EBS; backup object is KMS-encrypted at rest. Verify the KMS key is the in-geo key, not a cross-region copy.
- **Quorum (Prime Directive 3).** In prod the target cell must be healthy (3 nodes, one-per-AZ, PDB minAvailable=2) before adding restore load. Restore writes go to the **leader** (writes are leader-only).
- **Whole-cell loss?** If many/all DBs are gone, do NOT restore 150 ZIPs one-by-one — prefer EBS-snapshot restore of the cell (see Rollback + `dr-drill`).

## Steps
> Steps 3-9 mutate AWS/the cluster. Each is an **APPROVAL GATE** — out of scope until after CTO sign-off / the relevant phase, and prod applies require manual approval in Spacelift (Prime Directive 6).

1. **Confirm identity & mapping (read-only).** Look up `TENANT` in `../../../control-plane/registry/schema.ts` to fix `CELL`, `GEO`, `ENV`. Verify the target cell's ArcadeDB is `>= 26.4.1` and quorum-healthy (`kubectl get pods`, check the StatefulSet has 3 ready in prod). Confirm the requested `TS` and the acceptable data-loss window.
2. **Engage kill-switch (control plane).** Set the per-tenant kill-switch / lower the tenant's limit to zero in the retrieval proxy (`../../../control-plane/router/index.ts`) so clients fail closed instead of hitting a half-restored DB. There are NO per-DB engine quotas — the proxy is the only enforcement point.
3. **[APPROVAL GATE — AWS read] Identify the correct in-geo ZIP.** List and select the object:
   ```
   aws s3 ls s3://kb-backups-<GEO>-<ENV>/cell/<CELL>/<TENANT>/
   # choose <TS>.zip  ->  s3://kb-backups-<GEO>-<ENV>/cell/<CELL>/<TENANT>/<TS>.zip
   ```
   Re-verify `<GEO>` matches the tenant's geo (residency). Copy the ZIP to the leader pod (or a staging PVC) — stays in-region; KMS decrypt happens transparently.
4. **[APPROVAL GATE — cluster mutate] Ensure the target DB does not exist.** If a stale/corrupt DB is present, **DROP** it (if it is the broken copy you are replacing) or **RENAME** it to `<TENANT>_quarantine_<TS>` (if you need to keep it for forensics). The restore will fail until the target name is free. Run against the **leader** (writes are leader-only).
5. **[APPROVAL GATE — cluster mutate] Restore the ZIP.** Execute the ArcadeDB restore of `<TS>.zip` into the (now non-existent) target DB name on the leader. Replication is per-DB and leader-based, so the DB will replicate out to the cell's replicas after creation.
6. **Wait for replication.** Confirm the restored DB appears on all replica nodes in the cell (reads fan to replicas; a missing replica means partial availability).
7. **[APPROVAL GATE — cluster mutate] Rebuild derived indexes.** The ZIP excluded them — rebuild **HNSW vector indexes** and **Lucene full-text indexes** for the DB. The DB is NOT usable for retrieval until this completes. Monitor build progress and memory (Prime Directive 7 — pod mem limit must cover maxPageRAM + heap + overhead; index rebuild is memory-heavy, do not OOM-kill and break quorum).
8. **[APPROVAL GATE — cluster mutate] Recreate the per-DB least-priv user.** Create a NEW per-DB user with least privilege for this tenant's DB (do NOT re-set the root init password — root is set-once). Store the credential in KMS-encrypted Secrets (Prime Directive 5). Update the control plane / proxy with the new credential reference.
9. **[APPROVAL GATE] Re-register the backup schedule.** Re-attach the tenant's hot-backup schedule so the restored DB is protected again (see `../../../terraform/modules/backup-dr/`). A restored DB with no schedule is unprotected — this is not optional.
10. **Smoke-test a query.** Run a representative retrieval (a vector + a Lucene query) directly and via the proxy to confirm indexes resolve and the new user authenticates.
11. **Release kill-switch.** Restore the tenant's normal limits in the proxy only after Step 10 passes.
12. **Emit audit.** The engine has NO native audit — record: tenant, cell, geo, source S3 key, `TS`, data-loss window, who approved, drop-vs-rename decision, measured restore duration, and pass/fail of smoke test. Emit to the platform audit sink.

## Verification
- DB exists on the leader **and** every replica in the cell (per-DB replication complete).
- HNSW and Lucene indexes report built/online; smoke-test vector + full-text queries return expected results.
- New per-DB least-priv user authenticates; root init var was untouched.
- Backup schedule is re-registered and its next run is scheduled (check `backup-dr` outputs).
- Kill-switch released; proxy shows the tenant at normal limits.
- `/ready` returns HTTP 204 on all target pods; quorum intact (3/3 in prod).
- **Measured restore time recorded and compared against `RTO`.** If restore time > `RTO`, flag it in the audit and raise a follow-up (e.g. pre-staged EBS snapshots or smaller per-cell tenant counts).

## Rollback / if it goes wrong
- **Restore fails "DB already exists":** the target name was not free — re-do Step 4 (drop/rename) and retry. Never force-restore over a live DB.
- **Restore corrupt / wrong `TS`:** drop the freshly-restored DB and restart from Step 3 with the correct in-geo `TS`. The quarantined original (if you renamed in Step 4) is still available for forensics.
- **OOM during index rebuild:** indexes are derived — a killed rebuild is safe to re-run after correcting pod memory limits (Prime Directive 7). Do not lift the kill-switch until indexes are online.
- **Many DBs lost / whole-cell event:** abandon per-tenant ZIP restore. Restore the cell from **EBS snapshots** (faster than 150 ZIPs and avoids per-DB index rebuilds where the snapshot captured them), then reconcile against the registry. Coordinate via `dr-drill`. Keep everything in-geo (Prime Directive 1).
- **Residency doubt at any point:** STOP. Do not proceed with any object whose bucket/region is not the tenant's geo.

## Related
- [ADR-0015](../../../docs/adr/0015-backup-cronjob-sidecar.md) — backup mechanism (hot per-DB ZIP → S3 via CronJob sidecar; the source of these ZIPs).
- [ADR-0016](../../../docs/adr/0016-snapshot-aws-backup.md) — EBS snapshot orchestration (the whole-cell recovery path; preferred over restoring 150 ZIPs).
- [ADR-0014](../../../docs/adr/0014-dr-strategy-warm-standby.md) — warm-standby DR (in-jurisdiction).
- Backup/DR Terraform module: `../../../terraform/modules/backup-dr/`
- [`dr-drill`](../dr-drill/SKILL.md) skill — whole-cell EBS-snapshot recovery rehearsal.
- Control plane: registry `../../../control-plane/registry/schema.ts`, router/proxy `../../../control-plane/router/index.ts`
- Helm values (probes, memory limits): `../../../helm/arcadedb/values.yaml`
- Assumptions / architecture: `../../../docs/assumptions.md`, `../../../docs/architecture.md`
