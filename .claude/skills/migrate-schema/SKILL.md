---
name: migrate-schema
description: Fan-out a versioned, idempotent schema/index migration across all tenant DBs (dry-run → canary → fleet, batched + rate-limited, additive-first, per-tenant rollback). Use when the app team ships a new KB ontology/index change and it must roll out safely across the fleet.
---

# Migrate schema across tenant DBs

> Rolls a single versioned schema/index change across every tenant's virtual ArcadeDB database — one DB per tenant ([ADR-0003](../../../docs/adr/0003-tenancy-isolation-tiered.md)) means one change fans out across hundreds/thousands of DBs — gated as **dry-run → canary → one cell → fleet**, batched + rate-limited, additive-first, with backgrounded index builds and per-tenant rollback ([ADR-0028](../../../docs/adr/0028-schema-migration-fanout.md)). **Phase note:** the fan-out runner (Step Functions / Argo Workflow) + migration API/CLI are an INTERFACE STUB until Phase 2; executing a migration against AWS MUTATES tenant DBs and is **out of scope until after CTO sign-off and the Phase-2 control-plane rollout**. Authoring a migration and running the **dry-run/plan** (read-only) is fine now.

## Prerequisites

- You operate the control plane **for one geo** (EU operators run the EU control plane; US operators run the US control plane). A migration run **never crosses geos** — run it once per geo, from inside that geo. There is no EU↔US data path (PD #1, [ADR-0007](../../../docs/adr/0007-residency-enforcement-scp.md)).
- AWS access to the correct geo's account (`ACCOUNT_ID`, region per geo) via SSO; permission to start the `kb-migrate-schema` runner and to read/write the regional registry (DynamoDB) + read Secrets Manager.
- The **app team's migration artifact** authored against the schema-registry seam ([ADR-0025](../../../docs/adr/0025-scope-data-layer-platform.md)): a single migration that declares a **new `schema_version`** (monotonic integer), `up` (apply) and `down` (rollback) operations, and is **idempotent** (safe to re-apply) and **additive-first**.
- Registry contract with the per-DB version field: [`schema.ts`](../../../control-plane/registry/schema.ts) — `TenantRecord.schema_version`.
- Pre-Phase-2 you may **only** author the migration and run the dry-run/plan against the registry. No DB writes.

## Inputs

| Input | Type | Notes |
|---|---|---|
| `migration_id` | string | Stable id for this migration (audit + resume key). |
| `target_schema_version` | number | The **new** `schema_version` this migration moves DBs to. Must be exactly `current_max + 1`. |
| `geo` | `eu` \| `us` | Must equal the control plane you are operating. Migration runs once per geo. |
| `env` | `dev` \| `stage` \| `prod` | Scope to one env per run; promote dev → stage → prod separately. |
| `canary_tenant_id` | string | One low-risk tenant for the first (canary) wave. |
| `canary_cell_id` | string | One cell for the second wave (one-cell soak before fleet). |
| `batch_size` | number | DBs per batch (start small, e.g. 10–25). |
| `rate_limit_qps` | number | Max migration ops/sec per cell (write-storm guard, A4). |
| `index_build_mode` | `background` | **Always `background`** for HNSW/Lucene rebuilds (see Safety checks). |

## Safety checks (MUST pass before proceeding)

- **Residency (PD #1):** `geo == control_plane_geo`. The runner's first state asserts this and `Fail`s on mismatch. Never migrate a tenant from the other geo's control plane — no EU↔US data path; the registry is **regional**, never a global table ([ADR-0008](../../../docs/adr/0008-tenant-registry-dynamodb.md)).
- **Never a blocking rebuild on a hot tenant (core gotcha, A4):** HNSW (vector) and Lucene (full-text) index builds are heavy. They **MUST run in the background** so a hot tenant's reads/writes are not stalled. A foreground/blocking rebuild on an active DB is forbidden — `index_build_mode` must be `background`.
- **Additive-first ([ADR-0028]):** prefer additive changes (new type, new property, new index) that old + new app code both tolerate. **Defer destructive changes** (drop/rename/narrowing constraint) to a later, separately-gated migration after all readers/writers are on the new version. A single migration that is simultaneously additive **and** destructive is rejected at plan time.
- **Respect rate limits (write-storm guard, A4):** the fleet is read-heavy; an uncoordinated fan-out is a write storm that can starve the **single Raft leader per cell** (writes go to the leader; ArcadeDB has **no per-DB quotas** so nothing else throttles it). `batch_size` + `rate_limit_qps` are mandatory and enforced per cell.
- **Idempotent + resumable ([ADR-0028]):** the migration's `up`/`down` must be idempotent, and the runner is keyed on per-DB `schema_version`. A DB already at `target_schema_version` is **skipped**, so a re-run resumes a partial fan-out and never double-applies.
- **No click-ops (PD #6):** never run `ALTER`/`CREATE INDEX` by hand against a node. The migration goes **only** through the fan-out runner so it stays versioned, batched, audited, and resumable.
- **No public DB / VPC-internal only (PD #4):** the runner reaches DBs over the internal path. Ports 2480/2424/2434/5432/6379/7687 are never publicly reachable.
- **No native audit (gotcha):** ArcadeDB emits none — the runner emits the per-DB audit event (old → new `schema_version`) as the app-layer substitute.
- **Approval gate:** running the migration against AWS (anything past the dry-run) is a **mutating, post-sign-off action**. Get the documented approval before `start-execution`.

## Steps

> The runner is **idempotent + resumable**: it skips any DB already at `target_schema_version` and records the new version per DB on success, so any wave can be safely re-run. Waves are strictly ordered — do not skip ahead. Order/states per [ADR-0028](../../../docs/adr/0028-schema-migration-fanout.md).

1. **Author the migration.** With the app team, write the single migration declaring `target_schema_version` (= `current_max + 1`), `up`/`down`, additive-first, idempotent, `index_build_mode=background`. Confirm the prior `schema_version` (the rollback target) is well-defined.
2. **Dry-run / plan (read-only — safe now).** Run the runner in plan mode for `geo + env`. It reports, **per DB**, current `schema_version`, whether it will change, and the exact ops (incl. which indexes rebuild in background). Review for: any destructive op, any DB already ahead, residency mismatch. Example (placeholder — plan mode does not mutate):
   ```bash
   aws stepfunctions start-execution \
     --state-machine-arn arn:aws:states:REGION:ACCOUNT_ID:stateMachine:kb-migrate-schema \
     --name "plan-${migration_id}-$(date +%s)" \
     --input '{"migration_id":"<id>","target_schema_version":<n>,"geo":"<eu|us>","env":"<dev|stage|prod>","mode":"plan"}'
   ```
3. **[APPROVAL GATE — AWS-mutating, post-sign-off]** Obtain the documented approval before any wave that writes to tenant DBs.
4. **Wave 1 — CANARY (one tenant).** Apply to `canary_tenant_id` only. Set `mode:"apply"`, `scope:"tenant"`. On success the runner sets that DB's `schema_version=target_schema_version` in the registry and emits an audit event. **Soak** (watch the canary's health + the app team's smoke tests) before continuing.
5. **Wave 2 — ONE CELL.** Apply to `canary_cell_id`, batched + rate-limited (`batch_size`, `rate_limit_qps`). Watch leader write pressure on that cell (single-leader ceiling) and background index-build progress. Soak before fleet.
6. **Wave 3 — FLEET.** Apply to the remaining cells in `geo + env`, batched + rate-limited per cell. The runner walks DBs not yet at `target_schema_version`, in batches, honoring the QPS cap. Example:
   ```bash
   aws stepfunctions start-execution \
     --state-machine-arn arn:aws:states:REGION:ACCOUNT_ID:stateMachine:kb-migrate-schema \
     --name "apply-fleet-${migration_id}-$(date +%s)" \
     --input '{"migration_id":"<id>","target_schema_version":<n>,"geo":"<eu|us>","env":"<dev|stage|prod>","mode":"apply","scope":"fleet","batch_size":<n>,"rate_limit_qps":<n>,"index_build_mode":"background"}'
   ```
   If a batch fails, the runner halts (does not silently roll past failures); fix the cause and **re-run the same input** — already-migrated DBs are skipped.
7. **Promote across envs.** Repeat the canary → cell → fleet sequence for the next `env` (dev → stage → prod), and run the **whole sequence independently in the other geo** from its own control plane.

## Verification

- **Per-DB version recorded:** every targeted DB shows `schema_version == target_schema_version` in the registry ([`schema.ts`](../../../control-plane/registry/schema.ts) `TenantRecord.schema_version`). No DB left at the prior version (unless intentionally out of scope).
- **Idempotency:** re-run the fleet apply — it reports **0 DBs changed** (all skipped at the target version).
- **Index builds completed:** HNSW + Lucene rebuilds finished **in the background**; no hot tenant saw blocked reads/writes during the run (check latency/error dashboards for canary + cell waves).
- **No write storm:** per-cell write/leader metrics stayed within bounds during fan-out (no quorum/leader instability, no OOM-kill); the QPS cap was respected.
- **Audit trail:** one schema-migration audit event per DB (old → new `schema_version`) — the substitute for ArcadeDB's missing native audit.
- **App smoke tests** pass against canary + cell tenants on the new schema before fleet/prod promotion.

## Rollback / if it goes wrong

- **Per-tenant rollback ([ADR-0028]):** for any affected tenant, run the migration's `down` to the **prior `schema_version`** via the runner (`mode:"rollback"`, `scope:"tenant"`, `target_schema_version=<prior>`). The runner applies `down`, sets the registry back to the prior version, and emits an audit event. Rollback is idempotent — re-running is safe.
- **Halt mid-fan-out:** stop the runner; in-flight DBs either fully completed (recorded) or were skipped (untouched) — the per-DB `schema_version` is the source of truth, so partial state is consistent and resumable.
- **Stuck/heavy index build:** because builds are `background`, the DB stays serving; if a build is unhealthy, roll that tenant back (drops the new index) rather than blocking the tenant.
- **Destructive change regret:** additive-first means the old shape still exists, so rollback is non-lossy. (This is *why* destructive ops are deferred to a separate later migration — never bundle them.)
- **Do NOT** hand-edit a DB or the registry to "fix" a version mismatch, and do NOT restore over a live DB to undo a migration (restore requires the target DB to **not exist** — that is data loss, not a rollback). Use `down` / per-tenant rollback.

## Related

- [ADR-0028 — Schema migration: versioned fan-out runner](../../../docs/adr/0028-schema-migration-fanout.md) (the decision this skill implements)
- [ADR-0003 — Tenancy isolation (one DB per tenant)](../../../docs/adr/0003-tenancy-isolation-tiered.md), [ADR-0025 — Data-layer/platform scope seam](../../../docs/adr/0025-scope-data-layer-platform.md)
- Registry `schema_version`: [`control-plane/registry/schema.ts`](../../../control-plane/registry/schema.ts)
- Skills: [`provision-tenant`](../provision-tenant/SKILL.md) (creates HNSW + Lucene indexes at onboarding), [`upgrade-arcadedb`](../upgrade-arcadedb/SKILL.md) (re-audit isolation after upgrades), [`restore-tenant`](../restore-tenant/SKILL.md) (restore needs the target DB absent — not a migration undo), [`cell-capacity-report`](../cell-capacity-report/SKILL.md) (check leader/write headroom before a fan-out)
