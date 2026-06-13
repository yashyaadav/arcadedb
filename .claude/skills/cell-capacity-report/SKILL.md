---
name: cell-capacity-report
description: Produce a read-only, per-cell capacity report from AMP metrics — DB count, page-cache commit, and disk used against the A12 caps — and recommend add-cell vs rebalance plus flag tenants projected to outgrow a node. Use before scaling a geo, during weekly capacity review, or when a placement looks tight.
---

# Cell capacity report

> Reads AMP (Amazon Managed Prometheus) + the tenant/cell registry and reports, per cell, how close each cell is to its A12 placement caps; recommends add-cell vs rebalance and flags any tenant projected to outgrow a single node. **READ-ONLY** — this skill performs NO mutations to AWS, the cluster, or the registry, so it is safe to run in any phase (pre or post CTO sign-off). Acting on its recommendations (add-cell, rebalance) is a separate, approval-gated step.

## Prerequisites

- Read access to the geo's **AMP** workspace(s) (one per region/geo — there is no cross-geo workspace; see [ADR-0017](../../../docs/adr/0017-observability-amp-amg.md)) and to **AMG** dashboards.
- Read access to the **cell catalog** in the tenant registry (DynamoDB `CellRecord` / `TenantRecord`; see [`schema.ts`](../../../control-plane/registry/schema.ts)). Caps live in `CellRecord.caps`, observed usage in `CellRecord.usage`.
- `awscli` v2 with credentials for the target geo's account (`ACCOUNT_ID`), `kubectl` read context for the regional EKS cluster (optional, for cross-check), and `jq`.
- Familiarity with the capacity model: a cell is **full when ANY ONE cap trips** — there is no averaging. (A12)
- Know which **geo** (EU or US) and **region** you are reporting on. Run the report per geo; never join EU and US metrics into one view (Directive 1, residency).

## Inputs

| Input | Example | Notes |
|---|---|---|
| `GEO` | `eu` \| `us` | Selects the AMP workspace + registry GSI partition; never mixed. |
| `REGION` | `eu-central-1` / `us-east-1` | Geo-specific; use the right account `ACCOUNT_ID`. |
| `TIER` (optional) | `standard` \| `enterprise` \| `all` | Caps apply per pooled (standard) cell; dedicated/enterprise cells host one tenant. |
| `LOOKBACK` | `14d` (default) | Window for the growth-trend / "weeks-to-full" projection. |
| `NEAR_FULL_THRESHOLD` | `0.85` (default) | Fraction of a cap at which a cell is flagged "nearing full". |

## Safety checks (MUST pass before proceeding)

- **This skill must remain read-only.** It only issues AMP query API reads and DynamoDB `GetItem`/`Query` reads. If any step would mutate AWS, the cluster, the registry, or Git — STOP; that belongs in [`add-cell`](../add-cell/SKILL.md) or a rebalance runbook, behind manual approval (Directive 6, no click-ops; prod apply needs Spacelift approval).
- **Stay in-geo (Directive 1, residency).** Query only the target geo's AMP workspace and the target geo's regional registry table. Do NOT correlate EU metrics with US metrics or copy EU data into a US-region report artifact. EU data + any derived report stays in EU.
- **No DB endpoints touched.** This report reads metrics only; it never connects to `2480/2424/2434/5432/6379/7687` and never reaches a DB on a public path (Directive 4).
- **Caps are placement bounds, not runtime limits.** A12 caps say *where* a tenant can land; they do NOT stop a live runaway query. Do not present "cell not full" as "cell is safe under load" — runtime safety is the proxy's job (kill-switch / circuit-breaker, [ADR-0027](../../../docs/adr/0027-runtime-tenant-governance.md)). If a cell looks healthy on caps but co-tenants are suffering, that is an incident, not a capacity problem → [`incident-triage`](../incident-triage/SKILL.md).
- **Trust the registry caps, verify the metric.** Read effective caps from `CellRecord.caps` (they may have been tuned from the defaults). The A12 defaults are the starting heuristic only: `max_standard_dbs ≈ 150`, `max_page_ram_commit_ratio ≈ 0.60`, `max_disk_used_ratio ≈ 0.70`.
- **Account for the `/prometheus` MIME bug (F6/A17).** ArcadeDB returns `Content-Type: application/json` for `/prometheus`. If a cell shows zero/stale ArcadeDB metrics in AMP, suspect a broken scrape (missing text-parser/`fallback_scrape_protocol` workaround), NOT an empty cell — verify before reporting a cell as idle. See [`values.yaml`](../../../helm/arcadedb/values.yaml) metrics block and [observability module](../../../terraform/modules/observability/).

## Steps

> All steps below are **read-only**. No approval gate is required to run the report. Approval gates apply only to acting on the output.

1. **Pin scope.** Set `GEO`, `REGION`, `TIER`, `LOOKBACK`. Resolve the geo's AMP workspace id and the registry table for that geo. Confirm you are pointed at the correct `ACCOUNT_ID` for the geo (do not cross geos).

2. **List the cells in scope.** Query the cell catalog for `geo = $GEO` (and `tier` if filtering): registry `CellRecord` via the `geo#env#tier#status` GSI. Capture for each cell: `cell_id`, `geo`, `region`, `tier`, `cell_isolation` (`namespace` pooled vs `cluster` dedicated), and `caps` (`max_standard_dbs`, `max_page_ram_commit_ratio`, `max_disk_used_ratio`).

3. **Pull live usage from AMP** (per cell, over `LOOKBACK`). Query the geo's AMP workspace (read-only `query`/`query_range` API). Map metrics to the three caps:
   - **DB count** → number of databases on the cell (per-cell ArcadeDB DB gauge, cross-checked against `count` of `TenantRecord` with that `cell_id`). Compare to `max_standard_dbs`.
   - **Page-cache commit ratio** → committed off-heap page cache ÷ configured `maxPageRAM` for the cell (baseline `maxPageRAMGib=32` per [`values.yaml`](../../../helm/arcadedb/values.yaml)/A13). Compare to `max_page_ram_commit_ratio`. This is the RAM working-set signal, NOT pod memory limit.
   - **Disk used ratio** → used ÷ provisioned on the cell's data volume (PVC/EBS). Compare to `max_disk_used_ratio`.
   - Take the **current** value and a `LOOKBACK` linear trend for each (for "weeks-to-full").

4. **Compute per-cell status** (read `CellRecord.usage` as a cross-check, but treat the live AMP value as source of truth):
   - `utilization = max(db_count/max_standard_dbs, page_ram_commit_ratio/max_page_ram_commit_ratio, disk_used_ratio/max_disk_used_ratio)` — the **worst** of the three, because ANY one tripping makes the cell full (A12).
   - Status = `FULL` if `utilization >= 1.0`; `NEARING_FULL` if `>= NEAR_FULL_THRESHOLD`; else `OK`.
   - Record **which** cap is the binding constraint per cell (DBs vs page-RAM vs disk) — it drives the recommendation.

5. **Project growth.** For each `NEARING_FULL`/`FULL` cell, project the binding metric forward from its `LOOKBACK` trend and report an estimated **weeks-to-full** (or "already full"). Note pooled cells fill on whichever of the three caps trends fastest.

6. **Flag tenants outgrowing a node.** For every tenant in scope, read last observed size (`TenantRecord.size_bytes_last`, fed by A2/A12 per [`schema.ts`](../../../control-plane/registry/schema.ts)) and its `LOOKBACK` growth; project size forward. Flag any **standard** tenant projected to approach or exceed a single node's serviceable size (A2: standard p95 < 50 GB; a tenant `> ~50 GB` / approaching one node's RAM-working-set must never sit in a pooled cell). Cross-check `CellRecord.usage.largest_tenant_bytes`. A DB cannot be split across nodes and a cell has a single-leader write ceiling, so an outgrowing tenant needs a **dedicated cell**, not a bigger pooled cell.

7. **Recommend, per cell** (recommendation only — no action taken):
   - **DBs are the binding cap** (page-RAM + disk still low) → **rebalance**: place new/movable tenants on a less-loaded in-geo cell of the same tier; add a cell only if all in-geo cells are also DB-bound.
   - **Page-RAM or disk is the binding cap** → **add-cell** (rebalancing rarely helps a RAM/disk-bound cell; the working set / data volume is the limit). → [`add-cell`](../add-cell/SKILL.md).
   - **Any cell `FULL`** or **no in-geo same-tier cell can absorb growth** → **add-cell** in-geo (Directive 1: the new cell stays in `$GEO`).
   - **Tenant projected to outgrow a node** → **dedicated cell** for that tenant (`cell_isolation` per [ADR-0003](../../../docs/adr/0003-tenancy-isolation-tiered.md)/[ADR-0004](../../../docs/adr/0004-cell-backing-namespace.md)) → [`add-cell`](../add-cell/SKILL.md) with `tier=enterprise`/dedicated.

8. **Emit the report** (text/markdown table; do NOT write a mutation). Suggested columns: `cell_id | geo | tier | isolation | db_count/cap | page_ram_ratio/cap | disk_ratio/cap | status | binding_cap | weeks_to_full | recommendation`. Plus a **tenants-to-watch** section (tenant, current size, projected size, "→ dedicated cell"). Keep the artifact in-geo; do not email/store EU report data outside EU (Directive 1).

## Verification

- The report covers **every** cell returned in step 2 (no cell silently dropped — a dropped cell usually means a broken scrape, F6/A17, not an empty cell).
- Each cell's `utilization` equals the **max** of the three normalized ratios (sanity: a cell at 95% disk and 10% DBs is `NEARING_FULL`, not "OK").
- Spot-check one cell: live AMP `db_count` ≈ count of `TenantRecord` with that `cell_id`; live page-RAM/disk ratios are within tolerance of `CellRecord.usage` (large drift ⇒ stale registry usage or scrape gap — note it, don't "fix" it here).
- No write/mutating API call appears in your command history for this run (read-only invariant held).
- Every `FULL`/`NEARING_FULL` cell has a recommendation, and every flagged tenant has a "→ dedicated cell" note.

## Rollback / if it goes wrong

- **Nothing to roll back** — this skill makes no changes. If you accidentally ran a mutating command, STOP and follow [`incident-triage`](../incident-triage/SKILL.md); mutations are out of scope here.
- **A cell shows zero/stale metrics** → do not report it as empty. Suspect the `/prometheus` MIME-type scrape bug (F6/A17) or a scrape-target gap; verify the scrape config / `fallback_scrape_protocol` workaround before drawing conclusions.
- **Registry `usage` disagrees with AMP** → trust live AMP for the decision and flag the drift; do not back-write the registry from this skill (a control-plane reconciler owns `CellRecord.usage`).
- **Recommendation says add-cell but you cannot confirm a real need** → re-run with a longer `LOOKBACK`; adding a cell is cost + ops overhead and is approval-gated, so only escalate to [`add-cell`](../add-cell/SKILL.md) on a confirmed trend.

## Related

- [`add-cell`](../add-cell/SKILL.md) — the mutating, approval-gated follow-up when this report says add a cell (or carve a dedicated cell).
- [`tenant-usage-report`](../tenant-usage-report/SKILL.md) — per-tenant deep dive feeding the "outgrowing a node" flag.
- [`incident-triage`](../incident-triage/SKILL.md) — when a cell is healthy on caps but co-tenants are degraded (runtime, not placement).
- [ADR-0027](../../../docs/adr/0027-runtime-tenant-governance.md) — caps bound placement only; runtime is governed in the proxy (kill-switch/circuit-breaker).
- [ADR-0003](../../../docs/adr/0003-tenancy-isolation-tiered.md) / [ADR-0004](../../../docs/adr/0004-cell-backing-namespace.md) — pooled vs dedicated cells; dedicated cell for outgrowing tenants.
- [ADR-0017](../../../docs/adr/0017-observability-amp-amg.md) — AMP/AMG observability and the `/prometheus` scrape workaround.
- Assumptions [A2](../../../docs/assumptions.md) (per-tenant size, the load-bearing one) and [A12](../../../docs/assumptions.md) (cell capacity caps) — re-tune caps from these metrics after the first ~20 tenants.
- Registry shapes: [`schema.ts`](../../../control-plane/registry/schema.ts) (`CellRecord.caps` / `CellRecord.usage` / `TenantRecord`).
