# ADR-0003 — Tenancy isolation: tiered (pooled + dedicated)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | **Tiered isolation:** standard tenants share **pooled cells** (one DB per tenant in a shared 3-node Raft cluster); enterprise/regulated tenants get **dedicated cells**. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead, Security |
| **Type** | ✅ decided by the business |

## Context

ArcadeDB hosts **many databases per server** but has **no per-database resource quotas** (F2) and has a **history of a cross-DB isolation CVE (CVSS 9.0, fixed ≥ 26.4.1)** (F3). Tenants vary widely in size and sensitivity (A2). We must balance cost (sharing) against blast radius, noisy-neighbour, and compliance (isolation).

## Assumptions it rests on

- A2 (per-tenant size), A7 (SOC2 + GDPR now, HIPAA later), A12 (capacity caps), A14 (namespace isolation sufficient for standard tenants).

## Options considered

### Option A — Tiered: pooled + dedicated (chosen)
- **Pros:** standard tenants are near-free at the margin (shared cell); enterprise/regulated get a hard boundary (dedicated cell = the boundary we actually trust given F3); matches real B2B pricing tiers; lets us put `txWalFlush`, CMK, mTLS, backup cadence per tier.
- **Cons:** two code paths (pooled vs dedicated) in placement + provisioning; capacity caps needed because there are no engine quotas (F2).

### Option B — Pure pooled (everyone shares)
- **Pros:** cheapest; simplest placement.
- **Cons:** unacceptable blast radius for sensitive tenants given the CVE history; noisy-neighbour unmitigated at the engine; no compliance story for regulated tenants.

### Option C — Pure siloed (one cell per tenant)
- **Pros:** strongest isolation everywhere; simplest mental model.
- **Cons:** cost explodes (every tenant pays for a 3-node trio); wasteful for small standard tenants; defeats the "many DBs per server" advantage.

## Decision

**Tiered.** Pooled cells for standard tenants (placed by capacity caps, A12); **dedicated cells** for enterprise/regulated/large tenants. The cell module's `tier` and `cell_isolation` variables ([ADR-0004](0004-cell-backing-namespace.md)) express this. **Non-prod cells may run single-node** to cut cost (HA only matters in prod).

## Reasoning — why this beats the alternatives

Given F2 (no quotas) and F3 (isolation CVE history), **the only boundary we fully trust for sensitive data is a dedicated cell** — so pure pooled is out for regulated tenants. But pure siloed wastes ArcadeDB's core strength (many DBs per server) and is far too expensive for the long tail of small standard tenants (A2). Tiering captures the cost win where isolation needs are low and pays for a hard boundary exactly where it's required — and it aligns with how the business will price tiers.

## Consequences

- **Positive:** cost-efficient for the standard majority; defensible isolation + compliance for enterprise; per-tier tuning (durability, encryption, backup cadence).
- **Negative / costs:** placement/provisioning must handle both paths; **capacity caps + runtime governance are mandatory** for pooled cells ([ADR-0027](0027-runtime-tenant-governance.md)); enterprise economics dominated by dedicated-cell cost → price into the SKU.
- **Follow-ups:** capacity model (A12, §5.4), governance (0027), per-tenant CMK for enterprise ([ADR-0019] / §7.1), dedicated-cell backing (0004).

## Review-trigger

ArcadeDB adds **per-database resource quotas** (would weaken the case for dedicated cells on noisy-neighbour grounds); or the tenant size distribution (A2) shifts so far that pooled caps no longer pay off; or a new compliance regime forces dedicated cells for all.
