# ADR-0025 — Scope boundary: data-layer platform + seams

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Scope this as a **data-layer platform** exposing well-defined seams (provisioning/retrieval API, migration API + schema registry, metered-usage stream, erasure/DSAR API). The AI-SaaS app owns ingestion/ontology/billing/RTBF-workflow. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead, App team |
| **Type** | ⭐ recommended (overridable) |

## Context

The KB sits between a data engine (ArcadeDB) and an AI application. We must decide **how much the platform owns** vs the app. The clean-hand-over goal favours handing the cloud-ops team a **stable, certifiable data platform** rather than a fast-iterating AI application. But the app must never be blocked — so the boundary needs explicit seams.

## Assumptions it rests on

- A8 (data-layer scope; app in a separate account), A7 (compliance), the §8 seam table.

## Options considered

### Option A — Data-layer platform + seams (chosen)
- **Pros:** the platform stays **stable + certifiable** (SOC2/GDPR) while the app iterates on top; cleanest hand-over (ops run a *data platform*, not the AI app); clear ownership: platform owns clusters/cells/lifecycle/migration-tooling/metering-data/erasure-primitives/DR/security/residency; app owns ingestion/embedding/ontology/billing/RTBF-workflow; well-defined seams keep the app unblocked.
- **Cons:** requires designing + versioning the seam APIs; some capabilities (e.g. RTBF) are split across the boundary (platform provides mechanics, app owns workflow) → coordination needed.

### Option B — Platform owns ingestion + retrieval (wider)
- **Pros:** fewer seams; app gets more turnkey.
- **Cons:** platform now owns fast-moving, app-specific concerns (chunking, embedding-model choice, re-embedding) → harder to certify + hand over; couples platform release cadence to app product changes.

### Option C — Full-KB (platform owns the whole KB incl. ontology + RTBF workflow)
- **Pros:** single owner end-to-end.
- **Cons:** worst hand-over (ops would run the AI application); blurs compliance ownership; slowest, most coupled.

## Decision

**Data-layer platform + seams** (the §8 table). The platform exposes write/index + bulk-load APIs and the `RetrievalProvider`; ingestion/embedding/ontology/billing/RTBF-workflow are app-owned. Overridable to wider scope if the app team prefers.

## Reasoning — why this beats the alternatives

The hand-over goal is the tie-breaker: a **stable data platform is far easier to certify and hand to a cloud-ops team** than an AI application that changes weekly. Defining seams keeps the app unblocked without dragging app-specific churn into the certifiable core. Wider/full scope would couple the platform's release cadence and compliance surface to product iteration — exactly what we're avoiding.

## Consequences

- **Positive:** stable, certifiable platform; clean hand-over; clear ownership; app unblocked via seams.
- **Negative / costs:** seam APIs to design, version, and document; split responsibilities (e.g. RTBF) require coordination; the app must build ingestion/embedding itself.
- **Follow-ups:** specify each seam (provisioning/retrieval, migration + schema registry, metering stream, erasure/DSAR) in the LLD; app connectivity via PrivateLink ([ADR-0026](0026-app-connectivity-privatelink.md)); confirm scope with the app team at sign-off (A8).

## Review-trigger

A8 changes (app team wants wider platform scope or co-location); or a seam proves too thin/thick in practice.
