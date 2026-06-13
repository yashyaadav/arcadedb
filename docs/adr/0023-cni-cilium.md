# ADR-0023 — CNI / NetworkPolicy: Cilium

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Use **Cilium** as the CNI for L7/identity-aware NetworkPolicy + inter-namespace observability; **default-deny** per cell namespace. VPC CNI is the documented alternative. |
| **Date** | 2026-06-13 |
| **Deciders** | Security, Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

Pooled cells share a regional EKS cluster ([ADR-0004](0004-cell-backing-namespace.md)); **default-deny NetworkPolicy per namespace is a primary cross-tenant containment control** for standard tenants (§7.1, given F2/F3). We also want L7-aware policy (restrict to DB ports/paths), identity-aware rules, and good inter-namespace observability to support the continuous isolation probe and noisy-neighbour detection.

## Assumptions it rests on

- A14 (namespace isolation + NetworkPolicy sufficient for standard tenants), [ADR-0003](0003-tenancy-isolation-tiered.md)/[ADR-0004](0004-cell-backing-namespace.md).

## Options considered

### Option A — Cilium (chosen)
- **Pros:** **L7-aware + identity-aware** NetworkPolicy (beyond L3/L4) → tighter cross-namespace containment; rich **Hubble observability** for inter-namespace flows (helps the isolation probe + audit); eBPF performance; widely adopted, hand-over-friendly; can run in EKS.
- **Cons:** replaces/overlays the default VPC CNI (more to operate + upgrade); eBPF/Cilium learning curve; must validate against EKS networking specifics.

### Option B — Amazon VPC CNI (+ NetworkPolicy)
- **Pros:** AWS-native default, least to install; pods get VPC IPs directly; VPC CNI now supports NetworkPolicy.
- **Cons:** L3/L4 NetworkPolicy only (no L7/identity); weaker inter-namespace flow observability; less expressive for the containment + probe story we want in pooled cells.

## Decision

**Cilium** as the CNI with **default-deny NetworkPolicies per cell namespace** and L7 restrictions (DB ports/paths only from the cluster SG / authorised namespaces); **Hubble** for flow observability. VPC CNI documented as the fallback if Cilium-on-EKS friction is unacceptable.

## Reasoning — why this beats the alternatives

Because default-deny NetworkPolicy is a **primary containment control** for pooled cells (and the engine gives us no per-DB isolation guarantees beyond the version floor), the extra expressiveness of **L7/identity-aware policy + flow observability** materially strengthens the boundary and the isolation probe — worth the operational cost. VPC CNI's L3/L4-only policies are a weaker containment story for exactly the shared-cluster case we're most concerned about.

## Consequences

- **Positive:** stronger, L7/identity-aware cross-tenant containment; flow observability for the isolation probe + audit; eBPF performance.
- **Negative / costs:** Cilium to operate + upgrade; EKS-specific validation; learning curve; another component in the hand-over.
- **Follow-ups:** default-deny NetworkPolicy templates per namespace; Hubble wired to observability; validate Cilium-on-EKS in Phase 1; document the VPC CNI fallback.

## Review-trigger

Cilium-on-EKS operational friction proves unacceptable (fall back to VPC CNI); VPC CNI gains L7/identity policy; or an upgrade incompatibility arises.
