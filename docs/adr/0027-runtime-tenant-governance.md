# ADR-0027 — Runtime tenant governance: app-layer limits + circuit-breaker + kill-switch

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Enforce **per-tenant runtime governance in the retrieval/proxy layer** — query timeouts, result/row caps, rate limits, a cost-guard/circuit-breaker, a manual kill-switch — plus a **continuous cross-tenant isolation probe**. Do not rely on placement caps alone. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB has **no per-database resource quotas** (F2): a single tenant's runaway query (deep traversal, large vector scan, Gremlin OLAP) can saturate a pooled cell live, breaching co-tenant SLOs. Capacity caps ([A12](../assumptions.md)) bound *placement* but do nothing at *runtime*. The CVE history (F3) also warrants an active, continuous check that cross-DB isolation holds in production.

## Assumptions it rests on

- F2 (no engine quotas), F3 (isolation CVE history), [ADR-0003](0003-tenancy-isolation-tiered.md)/[ADR-0004](0004-cell-backing-namespace.md) (pooled cells), A4 (workload shape).

## Options considered

### Option A — App-layer governance + isolation probe (chosen)
- **Pros:** the **only** place we *can* enforce per-tenant limits given F2 (the engine won't); query timeouts + row caps + rate limits + fair-share scheduling contain noisy neighbours; a circuit-breaker sheds/isolates a degrading tenant; a manual kill-switch gives ops an immediate lever; the continuous probe turns the CVE-history risk into a *detected* event, not a silent one; enterprise tenants sidestep it by being alone in a dedicated cell.
- **Cons:** we build + maintain the governance layer + probe; per-tenant config to manage; the proxy is on the hot path (must be fast + HA).

### Option B — Rely on placement caps only
- **Pros:** nothing extra to build.
- **Cons:** **does not stop a live runaway query** — caps are about where a tenant lands, not what it does at runtime; leaves co-tenant SLOs at the mercy of any one tenant; no active isolation check. Inadequate given F2/F3.

## Decision

**Per-tenant runtime governance in the retrieval/proxy layer** (timeouts, result/row caps, QPS + heavy-op budgets with fair-share scheduling, cost-guard/circuit-breaker, manual kill-switch in the `incident-triage` skill) **plus a continuous cross-tenant isolation probe** that attempts cross-DB access on every cell and alerts if it ever succeeds.

## Reasoning — why this beats the alternatives

F2 makes this **non-optional**: if the engine enforces no per-DB quotas, then either the proxy enforces them or nothing does — and "nothing" means one tenant can take down a pooled cell. Placement caps are necessary but insufficient because they act before runtime. The isolation probe is the active complement to the version floor + post-upgrade re-audit, converting a latent CVE-class risk into an alertable signal.

## Consequences

- **Positive:** pooled cells are safe to share; runaway tenants are contained without breaching co-tenant SLOs; ops have a kill-switch; isolation regressions are detected, not silent.
- **Negative / costs:** the governance layer + probe are platform components to build, make HA, and tune; per-tenant limits to configure per tier; proxy latency budget.
- **Follow-ups:** implement limits/breaker/kill-switch in the retrieval layer (Phase 2); the continuous isolation probe + alert; per-tenant metering doubles as noisy-neighbour detection ([ADR-0017](0017-observability-amp-amg.md)); `incident-triage` skill carries the kill-switch.

## Review-trigger

ArcadeDB adds per-database resource quotas (reduces reliance on the app layer); a new isolation CVE (raises probe priority); or proxy latency from governance becomes material.
