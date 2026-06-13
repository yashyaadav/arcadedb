# ADR-0019 — TLS/mTLS: ALB/NLB-terminated + NetworkPolicy; mesh/mTLS for enterprise

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Terminate TLS at the ALB/NLB (ACM certs); protect east-west with **private subnets + default-deny NetworkPolicy**; add **mTLS (service mesh or ArcadeDB native keystore)** for enterprise/regulated cells. |
| **Date** | 2026-06-13 |
| **Deciders** | Security, Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB ports never leave the cluster (prime directive #4); the platform API is fronted by an internal NLB → PrivateLink (§5.5, [ADR-0026](0026-app-connectivity-privatelink.md)). In-cluster east-west (control plane ↔ ArcadeDB) runs on private subnets. Enterprise/regulated tenants may contractually require **encryption in transit everywhere, including east-west**, whereas blanket mTLS for all standard pooled cells adds latency + operational complexity for limited benefit on an already-private network.

## Assumptions it rests on

- A7 (compliance tiers), [ADR-0003](0003-tenancy-isolation-tiered.md) (tiering), [ADR-0023](0023-cni-cilium.md) (NetworkPolicy).

## Options considered

### Option A — Edge TLS + NetworkPolicy baseline; mTLS for enterprise (chosen)
- **Pros:** strong, simple in-transit protection at the edge (ACM); east-west defended by private subnets + default-deny NetworkPolicy (Cilium); pay the mTLS latency/ops cost only where contractually required (enterprise/regulated); incremental — can dial up.
- **Cons:** standard pooled east-west is "private + policy-restricted" rather than encrypted; two postures to manage.

### Option B — Native keystore mTLS everywhere
- **Pros:** uniform encryption in transit, even east-west, for all tenants.
- **Cons:** latency + cert-management overhead on every cell (including standard); ArcadeDB keystore config + rotation toil at scale; marginal benefit on an already-private, policy-restricted network for standard tenants.

## Decision

**Edge TLS (ACM at ALB/NLB) + private subnets + default-deny NetworkPolicy as the baseline; mTLS (mesh or ArcadeDB native keystore) added for enterprise/regulated cells.** Expressed per tier in the cell module.

## Reasoning — why this beats the alternatives

In-transit risk on a **private, default-deny network** is already low for standard tenants, so blanket mTLS taxes the majority for limited gain. Tiering puts the strongest control (mTLS) exactly where it's contractually demanded (enterprise/regulated) and keeps the standard path simple and fast — consistent with the overall tiered-isolation philosophy ([ADR-0003](0003-tenancy-isolation-tiered.md)).

## Consequences

- **Positive:** strong edge encryption for all; mTLS where it's paid for; lower latency/ops for the standard majority.
- **Negative / costs:** standard east-west isn't encrypted (mitigated by private subnets + NetworkPolicy); two postures + cert management; mesh/keystore introduction for enterprise.
- **Follow-ups:** ACM certs + TLS at ALB/NLB; default-deny NetworkPolicies per namespace; mesh/keystore option in the cell module for enterprise; cert-expiry alerting (<30d).

## Review-trigger

A compliance regime mandates east-west encryption for all tenants; mesh mTLS becomes near-zero-cost; or an audit finding requires it.
