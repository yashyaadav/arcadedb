# ADR-0026 — App connectivity: separate account + in-geo PrivateLink

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | The AI-SaaS app runs in a **separate AWS account** and reaches the platform's retrieval/provisioning API over **AWS PrivateLink**, **in-geo only** (EU app ↔ EU platform). |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security, App team |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB ports never leave the cluster (prime directive #4); the platform API is fronted by an internal NLB. The app is a separate workload that must consume that API. We need connectivity that is **private (no public exposure), residency-preserving (no EU↔US path), and blast-radius/billing-separated**, consistent with the data-layer scope ([ADR-0025](0025-scope-data-layer-platform.md)).

## Assumptions it rests on

- A8 (separate app account), prime directive #1 (residency) + #4 (no public DB), [ADR-0025](0025-scope-data-layer-platform.md).

## Options considered

### Option A — Separate account + in-geo PrivateLink (chosen)
- **Pros:** **private** (NLB → VPC endpoint service, no public exposure); **residency-preserving** (PrivateLink is regional → an EU app connects to the EU platform only, no cross-geo path); clean **blast-radius + billing + security separation** between app and platform accounts; fine-grained allow-listing of the consuming account; no VPC CIDR coordination/peering sprawl.
- **Cons:** PrivateLink endpoint cost; endpoint-service + consumer wiring to manage; one-directional (consumer → service) by design (fine for this use).

### Option B — Co-located in-cluster (app runs in the platform cluster/account)
- **Pros:** lowest latency; no PrivateLink cost; simplest networking.
- **Cons:** couples app + platform blast radius, billing, and security; muddies the data-layer scope + hand-over; app churn now lands in the platform's account/cluster.

### Option C — VPC peering / Transit Gateway between accounts
- **Pros:** general-purpose connectivity.
- **Cons:** CIDR coordination; broader network exposure than a single endpoint service; easier to accidentally create a cross-geo path (residency risk); more to secure than PrivateLink's narrow service exposure.

## Decision

**Separate app account consuming the platform's retrieval/provisioning API over in-geo PrivateLink** (internal NLB → VPC endpoint service; TLS via ACM; the consuming account allow-listed). No cross-geo connectivity exists.

## Reasoning — why this beats the alternatives

PrivateLink uniquely gives **private + regional (residency-safe) + narrowly-scoped** connectivity without CIDR coordination — it exposes exactly one service to exactly the allow-listed account, and being regional it **cannot** create an EU↔US path. Co-location is cheaper/simpler but sacrifices the blast-radius/billing/hand-over separation that motivates the whole scope decision; peering/TGW is broader and more residency-risky than we need.

## Consequences

- **Positive:** private, residency-safe, separated connectivity; minimal exposure surface; clean hand-over boundary.
- **Negative / costs:** PrivateLink endpoint cost; endpoint-service/consumer config; per-geo endpoint services.
- **Follow-ups:** internal NLB → VPC endpoint service per geo; consumer allow-list (app account); verify "no EU app → US platform path" (Phase 3 residency evidence); document the consumer setup for the app team.

## Review-trigger

A8 changes (co-location chosen); PrivateLink cost becomes material; or a new connectivity need (bidirectional) emerges.
