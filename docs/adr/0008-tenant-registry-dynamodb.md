# ADR-0008 — Tenant registry: regional DynamoDB (never a global table)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Store the tenant registry + cell catalog in **regional DynamoDB** (PITR on, DR-replicated **within the geo only**). **Never** a global EU↔US table. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

The control plane needs a low-latency, highly-available store mapping `tenant_id → home_geo, tier, cell_id, db_name, status, …` (§5.4), read on the hot path (router resolves tenant → cell) and written during provisioning. It must be **residency-safe**: an EU tenant's registry record must not be replicated to the US.

## Assumptions it rests on

- A8 (data-layer scope), prime directive #1 (residency), A4 (read-heavy).

## Options considered

### Option A — Regional DynamoDB, in-geo DR replication (chosen)
- **Pros:** serverless, single-digit-ms, highly available; **PITR** for the registry itself; per-geo isolation is the default (a regional table doesn't cross regions); in-geo DR via DynamoDB cross-region replication *within the jurisdiction*; IAM-scoped, KMS-encrypted; no servers to operate (hand-over friendly).
- **Cons:** key/access-pattern design must be deliberate (GSIs for placement queries); DynamoDB modelling discipline.

### Option B — DynamoDB **global table** (EU+US)
- **Pros:** one logical table, automatic multi-region.
- **Cons:** **directly violates residency** — a global EU↔US table replicates EU records to the US. Disqualified by prime directive #1.

### Option C — Relational (RDS/Aurora) registry
- **Pros:** flexible queries, familiar SQL.
- **Cons:** servers/instances to operate + patch; HA + in-geo DR more work; overkill for a key-value access pattern; higher fixed cost.

## Decision

**Regional DynamoDB**, one table per geo, PITR enabled, KMS-encrypted, in-geo DR replication only. Placement queries served by GSIs (e.g. by `geo+env+tier+status`). Global tables are **forbidden** by policy.

## Reasoning — why this beats the alternatives

The residency invariant **eliminates** the global-table option outright, and DynamoDB's regional default makes the safe choice the easy one. Its serverless, low-latency, PITR-backed profile fits the hot-path read pattern and the no-servers hand-over goal far better than running Aurora for what is fundamentally a key-value catalog.

## Consequences

- **Positive:** residency-safe by default; serverless + PITR; fast hot-path reads; minimal ops burden.
- **Negative / costs:** access patterns must be designed up front (GSIs); the "never global table" rule must be enforced (policy + review); cross-region in-geo replication setup for DR.
- **Follow-ups:** registry schema ([control-plane/registry/](../../control-plane/registry/)); a guard against global-table creation in the OPA gate; in-geo DR replication config (Phase 2).

## Review-trigger

Access patterns outgrow DynamoDB's model (heavy ad-hoc querying); or AWS changes global-table residency semantics; or registry data volume/cost shifts the calculus.
