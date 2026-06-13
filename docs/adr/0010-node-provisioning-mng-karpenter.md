# ADR-0010 — Node provisioning: Managed Node Groups (stateful) + Karpenter (stateless)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | **Managed Node Groups, one per AZ, for the stateful DB tier**; **Karpenter for stateless** workloads; a small system node group for add-ons. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

Raft quorum is fragile to node churn: if an autoscaler **consolidates a node out from under a DB pod**, the pod is evicted, its AZ-bound EBS volume is stranded, and the cell can drop below quorum or trigger a full re-replication (§5.5, prime directive #3). Stateless workloads (control plane, retrieval, jobs) *benefit* from aggressive, cost-optimising autoscaling. EBS is AZ-bound, so DB nodes must be AZ-pinned.

## Assumptions it rests on

- A13 (node sizing), prime directive #3 (quorum), prime directive #7 (sizing).

## Options considered

### Option A — MNG (stateful, per-AZ) + Karpenter (stateless) (chosen)
- **Pros:** DB nodes are **predictable + AZ-pinned** (one MNG per AZ), so quorum is never disturbed by consolidation; Karpenter gives fast, cost-optimal scaling + bin-packing for stateless tiers; clear separation of "stable" vs "elastic" capacity.
- **Cons:** two provisioning mechanisms to operate; MNG scaling is coarser/slower (acceptable for a fixed 3-node DB tier).

### Option B — All-Karpenter
- **Pros:** one provisioner; best bin-packing everywhere; least config.
- **Cons:** Karpenter consolidation/drift can evict a DB pod and **bounce quorum** or strand an EBS volume — directly threatens prime directive #3 unless heavily fenced with `do-not-disrupt`/PDB exceptions, at which point it's effectively a static group anyway. Too risky as the default for the stateful tier.

### Option C — All-MNG (cluster-autoscaler)
- **Pros:** predictable; familiar.
- **Cons:** poorer bin-packing + slower/cost-inefficient scaling for the bursty stateless tier; misses Karpenter's flexibility where it's safe and valuable.

## Decision

**MNG one-per-AZ for stateful DB nodes (`r7g`, taint `workload=arcadedb:NoSchedule`, AZ-pinned), Karpenter for stateless, a small system MNG for add-ons.** DB pods use AZ node-affinity + anti-affinity + the PDB.

## Reasoning — why this beats the alternatives

The quorum invariant is non-negotiable, and the cheapest way to guarantee it is to **keep the DB tier on stable, AZ-pinned nodes that no autoscaler will consolidate** — which is exactly MNG-per-AZ. Karpenter's real value (fast, cost-optimal scaling) applies to the stateless tiers where eviction is harmless, so we use it there. All-Karpenter would require so much fencing on the DB tier that it loses its advantage while adding risk.

## Consequences

- **Positive:** quorum protected by construction; cost-optimal scaling where it's safe; clear capacity model.
- **Negative / costs:** two mechanisms to operate; DB-tier capacity is comparatively static (intended); careful taints/affinity to keep stateless pods off DB nodes and vice-versa.
- **Follow-ups:** taints/tolerations + AZ affinity in Helm values ([helm/arcadedb/values.yaml](../../helm/arcadedb/values.yaml)); Karpenter NodePools for stateless in the EKS module; PDB `minAvailable: 2`.

## Review-trigger

Karpenter adds robust stateful-safe guarantees (e.g. reliable volume-aware, do-not-disrupt-by-default for PVC-bound pods); or DB-tier elasticity needs grow (unlikely for a fixed Raft group).
