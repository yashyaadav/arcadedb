# ADR-0006 — Regions: eu-central-1→eu-west-1, us-east-1→us-west-2

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | EU primary **eu-central-1 (Frankfurt)** → DR **eu-west-1 (Ireland)**; US primary **us-east-1** → DR **us-west-2**. DR is **jurisdiction-locked**. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

We deploy in two jurisdictions (EU + US) with a warm-standby DR region per geo ([ADR-0014](0014-dr-strategy-warm-standby.md)). **DR must stay in-jurisdiction** (prime directive #1) — an EU primary's DR must be another EU region. We need full service parity (EKS, AMP, AMG, Secrets Manager, AWS Backup) in all four regions.

## Assumptions it rests on

- A9 (these regions have full service parity), prime directive #1 (residency).

## Options considered

### Option A — euc1→euw1, use1→usw2 (chosen)
- **Pros:** Frankfurt is the canonical EU enterprise region; Ireland is a mature in-EU DR pair (low latency, full parity); us-east-1/us-west-2 are the two most feature-complete US regions and are geographically separated (independent failure domains); all four are GA for everything we need.
- **Cons:** us-east-1 has a reputation for being the "first to break" on large AWS incidents; Frankfurt can be marginally pricier than some EU regions.

### Option B — Other EU/US pairs (e.g. euw1 primary, or use2/usw2)
- **Pros:** could shave cost or avoid us-east-1's incident history.
- **Cons:** less canonical for EU enterprise (Frankfurt expectation); some pairs reduce geographic separation or service parity; marginal benefit vs the churn of deviating from the well-trodden choice.

## Decision

**eu-central-1 → eu-west-1** and **us-east-1 → us-west-2**, both DR pairs in-jurisdiction. Region is a cell-placement dimension; the registry's `home_geo` and the residency SCPs ([ADR-0007](0007-residency-enforcement-scp.md)) bind tenants and resources to a geo.

## Reasoning — why this beats the alternatives

These are the **most feature-complete, well-supported regions in each jurisdiction**, with mature in-geo DR partners that satisfy residency and give independent failure domains. The choice optimises for parity + hand-over familiarity over marginal cost/incident-history tuning, which we can revisit once real traffic exists. The us-east-1 incident-history concern is mitigated by the warm-standby DR in us-west-2.

## Consequences

- **Positive:** full service parity assumed across all four; in-geo DR satisfies residency; canonical regions ease hand-over.
- **Negative / costs:** us-east-1 incident exposure (mitigated by DR + SLOs); a date-stamped parity check is required (A9) because service availability changes over time.
- **Follow-ups:** Phase-0 service-availability check (A9); per-geo KMS keys; geo-pinned S3 CRR ([ADR-0015](0015-backup-cronjob-sidecar.md)).

## Review-trigger

A9 parity check fails for any region; a major us-east-1 incident pattern changes the risk calculus; or a new in-geo region offers materially better cost/latency.
