# CLAUDE.md — control-plane/

Directory rules for the control plane (registry, router, provisioning,
retrieval). Inherits the root [`CLAUDE.md`](../CLAUDE.md). **CTO package =
interface stubs**; implementation is Phase 2.

## Registry schema (regional DynamoDB — ADR-0008)

- `TenantRecord` (PK `tenant_id`) + `CellRecord` (PK `cell_id`) in `registry/schema.ts`.
- **Regional table only — NEVER a global table** (residency, ADR-0007). An EU
  tenant's records live only in the EU regional table; DR replication is in-geo.
- `home_geo` is **immutable** after creation. `schema_version` per DB drives the
  fan-out migration runner (ADR-0028).
- PITR on. KMS-encrypted. Placement queries via GSIs (`geo#env#tier#status`).

## Provisioning invariants (Step Functions ASL)

- **First step asserts `home_geo` == this control plane's geo**, else `Fail`
  with `ResidencyViolation`. (Both `statemachine.asl.json` and `deprovision.asl.json`.)
- **Idempotent + retryable**: every task is a no-op if already applied; the whole
  flow can be safely re-run (Retry + Catch on each Task).
- Provision order: create DB (3x replicated) → **least-priv per-DB user (not
  root)** → HNSW + Lucene indexes → store secret → register backup → registry
  active + **audit event**.
- Deprovision/erasure: optional final backup → drop DB (or crypto-shred the
  per-tenant CMK) → revoke secret → **emit deletion evidence** (audit + certificate).

## Router invariants (read/write split + governance)

- **Residency**: `assertInGeo` throws if `tenant.home_geo` != the router's geo.
- **Writes → Raft leader, reads → replicas** (validate leader-forwarding on the
  pinned version, A5). Cache `tenant_id → cell + db_name`.
- **Per-tenant governance** (ADR-0027): query timeouts, row caps, rate limits,
  circuit-breaker, and a **kill-switch** (used by `incident-triage`). The engine
  has no per-DB quotas (F2) — the proxy is the only enforcement point.

## RetrievalProvider (ADR-0024)

Keep retrieval behind the `RetrievalProvider` interface so vectors can be
externalised (OpenSearch Serverless / Aurora pgvector, **in-geo**) without an app
rewrite if the Phase-2 native-HNSW benchmark fails (A6). Count vector RAM in the
capacity model.

## The restore rule (F5)

The **target DB must NOT exist** before restore. Any restore tooling must
drop/rename first, then restore the ZIP, then **rebuild HNSW/Lucene indexes** +
per-DB users (see `restore-tenant` skill).

## Validate

```bash
cd control-plane && npm install && npm run typecheck   # Phase 2 toolchain
python3 -c "import json; json.load(open('provisioning/statemachine.asl.json'))"
```
