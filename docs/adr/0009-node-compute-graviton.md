# ADR-0009 — Node compute: Graviton (arm64), r7g family for DB nodes

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Run DB nodes on **Graviton / arm64** (`r7g` family); verify the arm64 ArcadeDB image digest in CI. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, FinOps |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB is a **RAM/throughput-bound JVM** workload: most RAM goes to the off-heap page cache (`maxPageRAM`), heap is modest, and Raft heartbeats are CPU-latency-sensitive (§5.5, prime directive #7). The memory-optimised `r7g` (Graviton3) family offers the best price-per-GiB-RAM and strong sustained throughput. ArcadeDB is a JVM (multi-arch capable) so arm64 is viable — but the image must actually be published/mirrored for arm64.

## Assumptions it rests on

- A13 (`r7g.2xlarge` baseline: maxPageRAM=32g, Xmx=8g, pod limit ~46–48 GiB), A1 (cost-conscious), A4 (read-heavy, RAM-bound).

## Options considered

### Option A — Graviton arm64, r7g for DB (chosen)
- **Pros:** ~20–40 % better price-performance vs comparable x86; memory-optimised `r7g` matches the page-cache-heavy profile; lower power/cost aligns with FinOps; JVM runs well on arm64.
- **Cons:** must ensure an **arm64 image** (mirror/verify digest in CI); any native/JNI deps (e.g. some Lucene/vector paths) must be arm64-clean — validate in Phase 1; mixed-arch fleets need care.

### Option B — x86 (m7i/r7i)
- **Pros:** maximum compatibility; no arch-verification step; widest third-party support.
- **Cons:** higher cost for the same RAM/throughput; gives up the Graviton price-performance win that matters for a RAM-bound fleet at scale.

## Decision

**Graviton arm64, `r7g` for stateful DB nodes**, with a **CI step that verifies the arm64 image digest** before it can be deployed. x86 kept as a documented fallback if an arm64 incompatibility surfaces.

## Reasoning — why this beats the alternatives

For a RAM-bound JVM fleet that will be the dominant cost line (§10), Graviton's price-performance is the single biggest sustainable cost lever, and `r7g`'s memory optimisation fits `maxPageRAM` sizing exactly (A13). The only real risk — arm64 image/native-dep compatibility — is cheaply de-risked by a CI digest check + a Phase-1 validation, and x86 remains a clean fallback.

## Consequences

- **Positive:** materially lower compute cost (compounds with Savings Plans); right-sized memory-optimised instances for the page cache.
- **Negative / costs:** arm64 image must be mirrored + digest-verified ([ADR-0012](0012-version-floor-26-4-1.md), supply chain §7.1); native-dep validation in Phase 1; vector-index RAM still competes with the page cache (size for it, A6).
- **Follow-ups:** CI image-arch verification; Phase-1 sizing + native-dep validation (A13); FinOps Savings Plans on the `r7g` line (A10).

## Review-trigger

An arm64 incompatibility in the pinned ArcadeDB/Lucene/vector stack; Graviton price-performance advantage erodes; or a newer Graviton generation (`r8g`) warrants a bump.
