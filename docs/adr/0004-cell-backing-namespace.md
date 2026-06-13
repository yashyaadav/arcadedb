# ADR-0004 — Cell backing: namespace-per-cell (dedicated cluster for enterprise)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | A **pooled cell = a namespace in a shared regional EKS cluster**; an **enterprise/regulated dedicated cell may be its own EKS cluster**. The cell module exposes `cell_isolation = "namespace" \| "cluster"`. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

A cell is the unit of capacity + blast radius (§5.4): one 3-node Raft group, its PVCs, LB, backup prefix, registry entry. We will run many cells per geo. The question is the Kubernetes backing: one cluster per cell, or many cells per cluster? EKS control planes cost ~$73/mo each, and the **data blast radius is already bounded by the per-cell Raft group** (a cell only holds its own tenants' DBs).

## Assumptions it rests on

- A14 (namespace isolation + NetworkPolicy + per-DB users sufficient for *standard* tenants), A1 (cost-conscious), A3 (footprint).

## Options considered

### Option A — Namespace-per-cell, dedicated cluster for enterprise (chosen)
- **Pros:** one regional EKS control plane amortises across many pooled cells (big cost saving at the agreed footprint); blast radius already bounded by the Raft group; default-deny NetworkPolicy + per-DB users provide intra-cluster isolation; enterprise can still get a whole cluster when the trust boundary demands it.
- **Cons:** pooled cells share an EKS control plane and node fabric (a cluster-wide EKS issue affects multiple cells); requires disciplined NetworkPolicy + namespace RBAC.

### Option B — One EKS cluster per cell
- **Pros:** strongest isolation (separate control plane, fabric) for every cell; simplest blast-radius story.
- **Cons:** ~$73/mo per cell just for the control plane, plus per-cluster add-on overhead (Argo, ESO, Cilium, observability agents) → cost + operational toil explode at scale; slower to add a cell.

## Decision

**Namespace-per-cell on a shared regional EKS cluster for pooled (standard) cells; `cell_isolation = "cluster"` for enterprise/regulated dedicated cells.** Default `namespace`.

## Reasoning — why this beats the alternatives

The data blast radius is **already** contained by the per-cell Raft group and one-DB-per-tenant model, so a separate EKS control plane per cell buys little additional *data* isolation while multiplying cost and add-on toil. Namespace cells capture the cost win for the standard majority; the `cell_isolation` switch lets enterprise/regulated tenants buy a full-cluster boundary when their compliance posture (A7) requires it — without a redesign.

## Consequences

- **Positive:** low marginal cost per pooled cell; fast `add-cell`; full-cluster option preserved for enterprise.
- **Negative / costs:** shared EKS control plane is a (bounded) shared fate for pooled cells; strict NetworkPolicy + RBAC + the continuous isolation probe are mandatory (A14, [ADR-0027](0027-runtime-tenant-governance.md)); cluster-level upgrades touch many cells (sequence carefully, [ADR-0029](0029-upgrade-rollback-restore-based.md)).
- **Follow-ups:** default-deny NetworkPolicies per namespace ([ADR-0023](0023-cni-cilium.md)); Argo ApplicationSet per cell ([ADR-0021](0021-gitops-argocd.md)); security review of namespace isolation in Phase 2 (A14).

## Review-trigger

A14 is invalidated (namespace isolation proves insufficient for standard tenants); or EKS per-cluster cost falls far enough that per-cell clusters become attractive; or a cluster-wide incident demonstrates unacceptable shared fate for pooled cells.
