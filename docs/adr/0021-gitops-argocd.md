# ADR-0021 — GitOps: Argo CD (app-of-apps + per-cell ApplicationSets)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Deploy Kubernetes workloads with **Argo CD** (app-of-apps), using **per-cell ApplicationSets** so adding a cell = adding a generator entry. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

Adding a cell must be **purely additive + zero-downtime** (§5.4): a new namespace/StatefulSet/PVCs/LB/backup prefix forms its own Raft group and registers as available. We want declarative, auditable, self-healing deployment of the ArcadeDB Helm release + per-cell add-ons across many cells and two geos, templated per cell, with dev→stage→prod × eu/us promotion (config only, never data).

## Assumptions it rests on

- A3 (footprint scales by adding cells), [ADR-0004](0004-cell-backing-namespace.md) (namespace cells), prime directive #6 (GitOps).

## Options considered

### Option A — Argo CD, app-of-apps + ApplicationSets (chosen)
- **Pros:** **ApplicationSet generators** make "add a cell" a one-line, templated change → matches the additive cell model exactly; app-of-apps structures the fleet; strong UI + RBAC + SSO; self-healing/drift correction; mature, widely known (hand-over friendly); good multi-cluster support for dedicated enterprise clusters.
- **Cons:** Argo CD is a component to run + secure + upgrade; ApplicationSet templating has a learning curve.

### Option B — Flux
- **Pros:** lightweight, GitOps-toolkit, good multi-tenancy primitives.
- **Cons:** smaller UI/UX; ApplicationSet-style fleet templating is less turnkey than Argo's; team familiarity tilts to Argo.

## Decision

**Argo CD**, app-of-apps with **per-cell ApplicationSets** templating the ArcadeDB Helm values per cell; promotion via dev→stage→prod folders × an eu/us overlay; **config/infra promoted, never data**.

## Reasoning — why this beats the alternatives

Argo's **ApplicationSet generators** are the cleanest expression of our cell model: scaling the fleet is literally adding a generator entry, with no bespoke glue — which directly serves the "adding a cell is additive + zero-downtime" requirement. Its UI/RBAC/maturity also help the cloud-ops hand-over. Flux is a fine GitOps engine but its fleet-templating + UX are a weaker fit for this specific pattern.

## Consequences

- **Positive:** additive, declarative, self-healing cell deployment; one-line add-cell; strong audit + UI for ops; multi-cluster ready for enterprise.
- **Negative / costs:** Argo CD to operate/secure; ApplicationSet templates to maintain; must guard against promoting data (config-only promotion discipline).
- **Follow-ups:** ApplicationSet per cell wired to the registry/cell-catalog; the `add-cell`/`retire-cell` skills add/remove generator entries; Kyverno signed-image admission alongside Argo ([ADR-0012](0012-version-floor-26-4-1.md)).

## Review-trigger

Argo CD operational burden grows; the org standardises on Flux; or ApplicationSet limitations block a needed cell-templating pattern.
