---
name: tenant-usage-report
description: Generate a per-tenant usage report (query count, p95 latency, storage, vector ops, write volume) from the metering stream + AMP for billing/showback, noisy-neighbour detection, and capacity input. Use when finance needs showback, SRE suspects a noisy tenant, or you are planning cell capacity.
---

# Tenant usage report

> READ-ONLY reporting over the per-tenant metering stream + Amazon Managed Prometheus (AMP). Use for billing/showback, noisy-neighbour detection, and as capacity-planning input. Phase note: this skill performs NO mutations to AWS or the cluster, so it is safe to run pre- and post-go-live; it only reads existing telemetry. (If telemetry is not yet emitting because the CTO package is not applied, the report will be empty — that is expected until observability is live.)

## Prerequisites
- Read access to the geo's **AMP workspace** (one workspace per geo — EU and US are separate; query each in its own region). Endpoint comes from the observability module output `amp_prometheus_endpoint`; workspace id from `amp_workspace_id`. See `../../../terraform/modules/observability/`.
- Read access to the **per-tenant metering stream** sink that carries `UsageMeter` records (control plane → metering). Schema: `../../../control-plane/registry/schema.ts` (`UsageMeter` interface: `ts, geo, tenant_id, cell_id, query_count, query_p95_ms, write_volume_bytes, vector_ops, storage_bytes`).
- `awscli` v2 configured for the target geo region, with `aps:QueryMetrics` / `aps:GetSeries` on the workspace (use SigV4-signed queries to AMP). Optional: AMG (`grafana_endpoint`) for a visual cross-check.
- Tenant → cell mapping from the registry (`../../../control-plane/registry/schema.ts`) so you can attribute usage to the right cell when a geo has multiple cells.
- Know the reporting window (e.g. last full billing month, or a 7-day noisy-neighbour window).

## Inputs
- `GEO` — `eu` or `us` (selects the AMP workspace + region; never mix — see Safety checks).
- `REGION` — the geo's AWS region (geo-specific; e.g. EU = eu-central-1, US = us-east-1). Use placeholders; confirm against the landing zone.
- `WINDOW_START`, `WINDOW_END` — ISO-8601 UTC bounds of the report.
- `TENANT_ID` (optional) — restrict to one tenant; omit for all tenants in the geo.
- `MODE` — one of `billing` (showback totals), `noisy-neighbour` (rank by share + p95), `capacity` (trend vs. cell ceiling).
- `ACCOUNT_ID` — placeholder for the geo's account.

## Safety checks (MUST pass before proceeding)
- **Residency (Directive 1):** Query ONLY the AMP workspace and metering sink in `GEO`'s own region. Never join, copy, or export EU tenant usage into US tooling (or vice versa), and do not stage the output in a cross-geo bucket. Run the report once per geo, separately. This is the single most important check — usage records are tenant data.
- **Read-only (no mutations):** This skill issues only `GET`/range queries and stream reads. It MUST NOT write to ArcadeDB, the registry, AMP, or any cell. No approval gate is needed precisely because nothing is mutated; if a step seems to require write/apply, STOP — it does not belong in this skill.
- **No public DB (Directive 4):** Do NOT reach the report by hitting an ArcadeDB port (2480/2424/2434/5432/6379/7687) directly, and never expose AMP/the metering sink publicly to "make reporting easier." Query through the managed AMP endpoint only.
- **Source of truth for usage = metering stream, not the engine:** ArcadeDB has **NO per-DB resource quotas and NO native usage/audit**. Per-tenant numbers come from the metering stream (emitted by the retrieval proxy / control plane) and AMP, NOT from the database. Do not attempt to derive billing from engine internals.
- **`/prometheus` MIME-type bug:** Cell metrics reach AMP via the ADOT scrape that already applies the text-parser workaround (ADR-0017). Always read from AMP, never scrape `/prometheus` directly in this report — a direct scrape can mis-parse and give wrong totals.
- **Attribution sanity:** A DB cannot be split across nodes and a single cell has a single-leader write ceiling. If a tenant's usage looks impossibly high for one cell, verify the tenant→cell mapping before reporting (don't double-count across cells).

## Steps
1. **Confirm geo + window.** Set `GEO`, `REGION`, `WINDOW_START`, `WINDOW_END`, `MODE`. Re-read the Residency safety check: you will run this whole flow once for EU and once for US, never together.
2. **Resolve targets from Terraform outputs (read-only):**
   ```sh
   cd ../../../terraform/modules/observability
   terraform output -raw amp_prometheus_endpoint   # AMP query endpoint for GEO
   terraform output -raw amp_workspace_id
   ```
   (Run against the `GEO`-specific workspace/state. `terraform output` reads state only — no plan/apply, no mutation.)
3. **Pull metering records for the window** from the per-tenant metering stream sink (the canonical billing source). Filter `geo == GEO` and `WINDOW_START <= ts <= WINDOW_END`; group by `tenant_id` (and `cell_id` for multi-cell geos). Aggregate per tenant:
   - `query_count` → sum
   - `query_p95_ms` → max (or time-weighted) across the window
   - `storage_bytes` → last value in window (point-in-time, not summed)
   - `vector_ops` → sum
   - `write_volume_bytes` → sum
4. **Cross-check against AMP (read-only range queries).** Sign queries with SigV4 to the AMP endpoint from step 2. Reconcile the per-tenant Prometheus series with the metering aggregates (they should agree within scrape granularity). Use the tenant label exported by the proxy. Example range query (adjust metric/label names to the deployed exporter):
   ```
   GET {amp_prometheus_endpoint}/api/v1/query_range
     ?query=sum by (tenant_id) (increase(arcadedb_proxy_query_total{geo="GEO"}[1h]))
     &start=WINDOW_START&end=WINDOW_END&step=1h
   ```
   Repeat per metric (query latency p95 via `histogram_quantile`, vector ops, write bytes, storage gauge).
5. **Compute per `MODE`:**
   - `billing` — emit the per-tenant totals table (one row per `tenant_id`); attach `cell_id` for traceability.
   - `noisy-neighbour` — rank tenants by share of cell `query_count` / `write_volume_bytes` and by `query_p95_ms`; flag any tenant exceeding the share threshold. (Remediation — proxy per-tenant limits / kill-switch — is a SEPARATE skill and is out of scope here.)
   - `capacity` — trend each cell's aggregate writes vs. the single-leader write ceiling; rising trend ⇒ recommend ADDING A CELL (a DB/cell cannot be split or scaled by node count). Do not recommend autoscaling the DB tier.
6. **Assemble the report** as a table (or CSV/JSON) tagged with `GEO`, `REGION`, window, and generation timestamp. Keep the artifact within `GEO`'s region/tooling.
7. **Repeat for the other geo** as a fully independent run (new step 1). Do NOT concatenate EU and US into one cross-geo file.

> No AWS- or cluster-mutating steps exist in this skill, therefore no Spacelift / manual approval gate applies. If you find yourself about to apply Terraform or write to a DB, you are in the wrong runbook.

## Verification
- Metering-stream aggregates and AMP range-query results agree within scrape granularity for at least the top tenants (per-metric reconciliation in step 4). Large divergence ⇒ a scrape/exporter gap, investigate before publishing.
- Row count = number of active tenants in `GEO` for the window (cross-check against the registry tenant list).
- `storage_bytes` is reported as a point-in-time gauge, not a sum (a summed gauge is the classic bug — confirm it isn't inflated).
- Spot-check one tenant's `query_count` against AMG (`grafana_endpoint`) if enabled — the dashboard panel should match the report.
- The output artifact contains ONLY `GEO` tenants and lives in `GEO` tooling/region (residency self-audit).

## Rollback / if it goes wrong
- Nothing to roll back — this skill mutates nothing. If a run is wrong, discard the artifact and re-run.
- **Empty/partial data:** likely the observability stack isn't applied yet (pre-go-live), the ADOT scrape isn't running, or the metering stream isn't emitting. Confirm `../../../terraform/modules/observability/` is deployed for `GEO` and that the retrieval proxy is publishing `UsageMeter` records.
- **Metering vs. AMP disagree:** trust the metering stream for billing (canonical), flag the AMP gap to observability owners; check the `/prometheus` MIME-type workaround is active in the scrape (ADR-0017).
- **Suspected residency mistake** (e.g. an EU tenant appeared in a US run, or output was staged cross-geo): STOP, delete the artifact, and escalate per the data-residency incident process — treat as a potential Directive 1 breach.

## Related
- ADR-0017 — Observability: AMP + AMG + CloudWatch Logs: `../../../docs/adr/0017-observability-amp-amg.md`
- Observability Terraform module (AMP/AMG endpoints, outputs): `../../../terraform/modules/observability/`
- `UsageMeter` registry schema (field source of truth): `../../../control-plane/registry/schema.ts`
- Architecture & assumptions: `../../../docs/architecture.md`, `../../../docs/assumptions.md`
- Retrieval proxy (emits metering + enforces per-tenant limits/kill-switch — remediation lives there, not here): `../../../control-plane/router/index.ts`
