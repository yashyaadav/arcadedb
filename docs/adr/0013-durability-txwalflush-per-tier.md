# ADR-0013 — Durability: `txWalFlush` per tier

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Set ArcadeDB **`txWalFlush` per tier**: `=2` (fsync per commit) for enterprise/regulated, `=0`/`1` for standard. Not a single global default. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Product |
| **Type** | ⭐ recommended (overridable) |

## Context

ArcadeDB's `txWalFlush` controls write-ahead-log flushing: `0` = no fsync per commit (fastest, a node crash can lose the last commits), higher values fsync for durability at a throughput cost. Backups exclude the WAL (F5) and there is no PITR, so on a crash the WAL durability setting directly bounds how much committed data a single node can lose between replication + backup. Tenants differ: standard tenants favour throughput on a re-ingestable KB; enterprise/regulated tenants need strict durability.

## Assumptions it rests on

- A16 (txWalFlush tiering acceptable), A4 (write bursts on ingest), A15 (backup cadence), A2/A7 (tiers).

## Options considered

### Option A — Per-tier `txWalFlush` (chosen)
- **Pros:** pay the fsync throughput cost only where durability is contracted (enterprise); standard tenants get higher write throughput on a re-ingestable KB; aligns durability with the SKU and the SLA.
- **Cons:** per-cell/per-tier configuration to manage + document; mixing tiers means understanding which cell runs which setting.

### Option B — Global `txWalFlush=2` everywhere
- **Pros:** simplest; strongest durability for all.
- **Cons:** every standard tenant pays the fsync throughput cost (bigger nodes / lower throughput) for durability they may not need on a re-ingestable KB — poor cost/throughput trade for the majority.

### Option C — Global `txWalFlush=0` everywhere
- **Pros:** fastest writes.
- **Cons:** unacceptable durability for enterprise/regulated tenants; can't offer a strict-durability SLA.

## Decision

**`txWalFlush` is a per-tier (per-cell) setting:** `2` for enterprise/regulated/dedicated cells; `0` or `1` for standard pooled cells (tunable per workload). Expressed via the cell module `tier` and Helm values; documented in [helm/CLAUDE.md](../../helm/CLAUDE.md).

## Reasoning — why this beats the alternatives

Durability is a **per-tenant contractual property**, not a global constant. Tiering lets us honour strict-durability SLAs for enterprise while not taxing the standard majority's throughput for guarantees they don't need (and whose data is re-ingestable anyway, §6/§7.4). A global setting forces a single bad trade in one direction or the other.

## Consequences

- **Positive:** durability matched to SLA + cost; better standard-tier throughput; clear enterprise durability story.
- **Negative / costs:** per-tier config + documentation; load-test both settings (Phase 1, A16); operators must know a cell's tier before reasoning about write durability.
- **Follow-ups:** wire `txWalFlush` into the cell module + Helm values per tier; write p95 SLO accounts for fsync overhead (§7.5); document in the upgrade/restore runbooks.

## Review-trigger

A16 invalidated (standard tenants need stricter durability); ArcadeDB changes WAL/flush semantics; or backup cadence (A15) changes the acceptable data-loss window.
