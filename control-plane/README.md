# `control-plane` (interface stubs)

The regional, residency-aware control plane (HLD §5.4). **CTO-package status:
interface stubs** — types, the Step Functions ASL, and the router/retrieval
interfaces that define the contracts. Implementation lands in **Phase 2**.

```
control-plane/
├── registry/schema.ts              # TenantRecord, CellRecord, AuditEvent, UsageMeter (DynamoDB — ADR-0008)
├── router/index.ts                 # Placement, Router (read/write split), TenantGovernance, KillSwitch, RetrievalProvider
├── provisioning/statemachine.asl.json    # Step Functions: provision (idempotent, audited)
└── provisioning/deprovision.asl.json     # Step Functions: deprovision / erasure (RTBF/DSAR, deletion evidence)
```

## Contracts encoded here

| Contract | File | Anchor |
|---|---|---|
| Tenant + cell catalog data model (regional DynamoDB, never global) | `registry/schema.ts` | ADR-0008, ADR-0007 |
| Placement (geo+env+tier+capacity; big/enterprise → dedicated) | `router/index.ts` | §5.4, A12 |
| Leader-aware routing (writes→leader, reads→replicas) | `router/index.ts` | F1, A5 |
| Per-tenant runtime governance + kill-switch | `router/index.ts` | ADR-0027 |
| `RetrievalProvider` swap seam (native ↔ external vectors) | `router/index.ts` | ADR-0024 |
| Idempotent, audited provisioning | `provisioning/statemachine.asl.json` | §5.4 |
| Data-layer erasure + deletion evidence | `provisioning/deprovision.asl.json` | §7.1 |

## Residency in the control plane

Both state machines **assert `home_geo` == the control plane's geo** as their
first step and `Fail` with `ResidencyViolation` otherwise. The `Router`'s
`assertInGeo` does the same on the hot path — defence in depth with the SCP +
CI gate (ADR-0007).

## Validate (types only; no runtime in this package)

```bash
cd control-plane && npm install && npm run typecheck   # Phase 2 (needs Node/TS toolchain)
python3 -c "import json; json.load(open('provisioning/statemachine.asl.json'))"  # ASL is valid JSON
```

> The CTO-package `make validate` does **not** require the Node toolchain — these
> are contract stubs. Type-checking + unit tests are wired in Phase 2.

## Phase-2 follow-ups

- Lambda implementations behind the ASL task ARNs (create-db, create-user,
  create-indexes, store-secret, register-backup, registry-activate, drop, evidence).
- DynamoDB table + GSIs + PITR + in-geo DR replication (ADR-0008).
- The retrieval proxy implementing `Router` + `TenantGovernance` + `KillSwitch`.
- The native-vs-external vector benchmark behind `RetrievalProvider` (A6 gate).
- Schema-migration fan-out runner (ADR-0028) + app-layer audit pipeline (§7.1).
