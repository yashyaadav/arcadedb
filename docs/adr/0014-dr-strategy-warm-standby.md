# ADR-0014 — DR strategy: warm standby (per geo, in-jurisdiction)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | DR = **warm standby** per geo: a minimal running 3-node cluster in the in-geo DR region, fed by in-geo S3 + EBS-snapshot copies; failover = scale up + promote + repoint registry + flip Route 53. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, CTO |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB has **no built-in cross-region replication** and **no PITR**; restore is per-DB ZIP + index rebuild, which is slow (F5). Raft is **single-leader per cluster** (F1) — there is no active-active across regions. We need a DR posture that meets the RPO/RTO targets (standard ≤6h/≤4h, enterprise ≤1h/≤1–2h) **within the jurisdiction** (prime directive #1).

## Assumptions it rests on

- A9 (in-geo DR region parity), A15 (backup cadence sets RPO), prime directive #1.

## Options considered

### Option A — Warm standby (chosen)
- **Pros:** a small cluster is already running in the DR region, so failover is **scale-up + promote + cut-over**, not a cold rebuild — meets RTO that pure restore can't; fed by in-geo S3 CRR + snapshot copies (residency-safe); cost is bounded (minimal standby footprint, scaled up only on failover).
- **Cons:** ongoing cost of the standby cluster (more than pilot-light); standby must be kept fed + patched in lock-step.

### Option B — Pilot light (data replicated, compute off)
- **Pros:** cheapest DR.
- **Cons:** failover requires standing up + restoring the cluster (ArcadeDB restore + **HNSW/Lucene index rebuild is too slow**) → blows the RTO. Disqualified on RTO grounds.

### Option C — Active-active (multi-region)
- **Pros:** near-zero RTO; no failover event.
- **Cons:** **ArcadeDB has no cross-region replication and Raft is single-leader** — active-active isn't supported by the engine; building it would mean app-level dual-write across regions, which also breaks residency for cross-geo. Disqualified.

## Decision

**Warm standby per geo, in-jurisdiction.** Standby is a minimal running 3-node cell; in-geo S3 CRR + EBS-snapshot copy feed it; the registry is already DR-replicated in-geo; failover scales the standby, promotes it, repoints the registry, and flips Route 53. **DR game-day quarterly; restore-a-random-tenant monthly.**

## Reasoning — why this beats the alternatives

The engine's lack of cross-region replication + PITR + the slowness of index-rebuild restore **rules out both active-active and pilot-light** on capability/RTO grounds. Warm standby is the only posture that hits the RTO targets while respecting residency and keeping cost bounded — it trades a modest always-on standby cost for an achievable, rehearsable failover.

## Consequences

- **Positive:** achievable RTO without active-active; residency-safe (in-geo feeds); rehearsable, scripted failover ([dr-drill] skill).
- **Negative / costs:** standby cluster running cost per geo; standby must be fed + version-matched continuously; failover is an event (brief unavailability), not seamless.
- **Follow-ups:** in-geo S3 CRR + snapshot copy ([ADR-0015](0015-backup-cronjob-sidecar.md)/[ADR-0016](0016-snapshot-aws-backup.md)); Route 53 health checks + failover routing; the `dr-drill` runbook + quarterly game-day; re-ingestable source as the sub-hour-RPO escape hatch (§7.4).

## Review-trigger

ArcadeDB adds cross-region replication or PITR (re-evaluate active-active / pilot-light); RTO/RPO targets tighten; or DR standby cost becomes material relative to the win.
