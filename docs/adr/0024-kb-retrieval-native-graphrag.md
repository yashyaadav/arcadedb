# ADR-0024 — KB retrieval: ArcadeDB-native GraphRAG behind a `RetrievalProvider` (with escape hatch)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Start with **ArcadeDB-native GraphRAG** (graph + HNSW vectors + Lucene full-text) **behind a `RetrievalProvider` interface**, with a documented **escape hatch** to externalise vectors. A Phase-2 benchmark gates the decision. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead, App team |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB natively offers **graph + documents + HNSW vectors + Lucene full-text** in one engine (F7), enabling true GraphRAG (vector recall → graph traversal for context expansion → full-text rerank) with **one backup/residency/HA story**. Risks: HNSW maturity, **vector-index RAM competes with the page cache** (must be counted in the capacity model), and recall quality on real data are unproven for our workload.

## Assumptions it rests on

- A6 (native HNSW recall/latency/RAM acceptable — **Low confidence, benchmark-gated**), A2 (sizing incl. vector RAM), A8 (data-layer scope; ingestion is app-owned).

## Options considered

### Option A — Native GraphRAG behind an interface + escape hatch (chosen)
- **Pros:** one engine = one residency/HA/backup story (fewer moving parts, lower cost); **graph + vector co-located** is the GraphRAG differentiator (context expansion without cross-store joins); the `RetrievalProvider` interface means we can externalise vectors later **without an app rewrite**; the benchmark gate de-risks the bet before GA.
- **Cons:** HNSW maturity risk; vector RAM competes with the page cache (sizing pressure); recall quality unproven → carries the risk until the benchmark.

### Option B — External vector store from day one (OpenSearch Serverless / Aurora pgvector)
- **Pros:** mature vector search; isolates vector RAM from the DB page cache.
- **Cons:** a **second data store** to run, secure, back up, and keep in-geo (residency × 2); cross-store joins for graph context expansion (loses the co-located GraphRAG advantage); higher cost + complexity before we've proven we need it.

## Decision

**Native GraphRAG behind `RetrievalProvider`**, count vector RAM in the capacity model, and **gate at Phase 2** with a recall/latency/RAM benchmark on real KB data. If native fails the gate, flip the provider config to **OpenSearch Serverless (vector)** or **Aurora pgvector** (in-geo) — vectors only — with no app rewrite.

## Reasoning — why this beats the alternatives

The unified engine is **simpler, cheaper, and the GraphRAG differentiator** — but the recall/RAM risk is real and unproven (A6 is our lowest-confidence assumption). The right move is therefore not to choose blindly but to **make the choice reversible**: build behind an interface, count the RAM, and let a real-data benchmark decide before GA. That captures the upside of native while bounding the downside to "flip a config", which neither a blind native bet nor a premature external store would.

## Consequences

- **Positive:** one residency/HA/backup story; co-located GraphRAG; a reversible, benchmark-gated decision; portability via the interface.
- **Negative / costs:** vector RAM competes with page cache (size for it, R6); recall risk carried until Phase 2; the interface + an external-provider implementation must both exist (even if external is dormant).
- **Follow-ups:** define `RetrievalProvider`; the Phase-2 benchmark gate (verification matrix); count vector RAM in the capacity caps (A12); keep the ingest source re-ingestable (doubles as the sub-hour-RPO escape hatch, §7.4).

## Review-trigger

The Phase-2 benchmark fails (take the escape hatch before GA); ArcadeDB's HNSW matures significantly; or vector RAM pressure forces externalisation for specific hot tenants.
