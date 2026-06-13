# ADR-0028 — Schema migration: versioned fan-out runner (canary → fleet)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Evolve the KB schema/indexes across tenant DBs with a **versioned, idempotent fan-out migration runner** (dry-run → canary → fleet, batched + rate-limited, per-tenant rollback), exposed via a migration API/CLI + schema registry. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, App team |
| **Type** | ⭐ recommended (overridable) |

## Context

With **one DB per tenant** ([ADR-0003](0003-tenancy-isolation-tiered.md)), every schema/index change is a **fan-out across hundreds/thousands of DBs** — and an uncoordinated change risks a write storm, partial failures, and blocked hot tenants (HNSW/Lucene index builds can be heavy). The app team decides *what* ontology ships; the platform must guarantee *how* it rolls out safely (the §8 seam).

## Assumptions it rests on

- [ADR-0003](0003-tenancy-isolation-tiered.md) (one DB per tenant), A4 (avoid write storms on a read-heavy fleet), A8 (app owns *what*, platform owns *how*).

## Options considered

### Option A — Versioned fan-out runner (chosen)
- **Pros:** a `schema_version` per DB in the registry makes migrations **idempotent + resumable**; **batched + rate-limited** fan-out avoids a write storm; **online, additive-first** changes with **backgrounded index builds** don't block hot tenants; **canary → one cell → fleet** + **per-tenant rollback** + a **dry-run/plan** make it safe + reviewable; a clean API/CLI seam for the app team.
- **Cons:** a real runner (Step Functions / Argo Workflow) + schema registry to build + operate; migration authors must follow the additive-first discipline.

### Option B — Ad-hoc per-DB scripts
- **Pros:** nothing to build up front.
- **Cons:** no versioning/idempotency/resumability; easy to cause a write storm or partial-failure mess across thousands of DBs; no canary/rollback/dry-run; not safe or auditable at fleet scale; terrible hand-over.

## Decision

**A versioned, idempotent fan-out runner** (Step Functions / Argo Workflow) keyed on per-DB `schema_version`, batched + rate-limited, additive-first with backgrounded index builds, canary→fleet rollout, per-tenant rollback, and a dry-run/plan — surfaced as the `migrate-schema` skill + a migration API/CLI + schema registry.

## Reasoning — why this beats the alternatives

Fan-out across a large fleet of independent DBs is precisely where **ad-hoc scripts become dangerous** — one bad change, multiplied by thousands of DBs, with no idempotency or rollback, is an outage. A versioned runner makes the operation safe, resumable, reviewable (dry-run), and gradual (canary→fleet) — and gives the app team a clean seam without exposing them to the fan-out mechanics.

## Consequences

- **Positive:** safe, idempotent, gradual, rollback-able schema evolution at fleet scale; clean app-team seam; auditable.
- **Negative / costs:** the runner + schema registry + the additive-first authoring discipline must be built + taught; migrations are gated (slower than a raw script, by design).
- **Follow-ups:** `schema_version` in the registry; the runner (Phase 2); the `migrate-schema` skill (dry-run/canary/fleet/rollback); coordinate the schema-registry seam with the app team ([ADR-0025](0025-scope-data-layer-platform.md)).

## Review-trigger

Fleet size or change cadence outgrows the runner's throughput; ArcadeDB changes index-build semantics; or the app team's schema-change pattern shifts.
