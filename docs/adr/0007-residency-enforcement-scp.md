# ADR-0007 — Residency enforcement: per-geo OU + SCP deny (defence in depth)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Enforce GDPR residency in **depth**: per-geo OUs with **SCP region-deny**, geo-pinned replication, registry geo-assertion, a **CI residency gate**, and per-geo state — not a single control. |
| **Date** | 2026-06-13 |
| **Deciders** | Security, Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

Prime directive #1: **EU tenant data and backups must never leave the EU**, and DR pairs stay in-jurisdiction. A single enforcement point is a single point of failure for a compliance-critical, externally-audited property. Residency violations (R8) are Low-probability but High-impact.

## Assumptions it rests on

- A7 (GDPR in scope), A9 (in-geo region pairs), A8 (separate app account, in-geo PrivateLink).

## Options considered

### Option A — Defence in depth: SCP + replication-pin + registry assert + CI gate + per-geo state (chosen)
- **Pros:** no single point of failure; SCP is a hard *runtime* deny at the org boundary; the CI/OPA gate fails an out-of-geo region literal *before apply* (shift-left); the registry refuses cross-geo placement at the app layer; per-geo state keeps even Terraform state in-jurisdiction; each layer catches a different failure mode (misconfig, drift, code bug, operator error).
- **Cons:** several mechanisms to build + keep in sync; SCPs need a global-service allowlist (IAM, Route 53, CloudFront, etc. are global) to avoid breaking legitimate calls.

### Option B — App-layer only (registry/router refuses cross-geo)
- **Pros:** simplest; one place to reason about.
- **Cons:** a Terraform misconfig or a console action could still create an out-of-geo resource; no protection against IaC bugs; weakest audit story — unacceptable for a GDPR-critical invariant.

## Decision

**Defence in depth, five layers:** (1) SCP on `Workloads-EU`/`Workloads-US` denying actions where `aws:RequestedRegion` ∉ the geo allow-list (+ a curated global-service allowlist); (2) S3 CRR destinations geo-pinned in Terraform with a validation guard; (3) registry stores `home_geo`, router refuses cross-geo placement; (4) **Conftest/OPA CI gate** failing any out-of-geo region literal ([policy/conftest/residency.rego](../../policy/conftest/residency.rego)); (5) per-geo Terraform state buckets ([ADR-0022](0022-state-locking-s3-native.md)).

## Reasoning — why this beats the alternatives

Residency is **audited and legally load-bearing**; "trust one control" is not defensible to an auditor or a regulator. Layering means a single bug, drift, or operator mistake cannot by itself cause a violation — the SCP stops it at runtime even if the IaC is wrong, and the CI gate stops it before it ever reaches an account. The cost (several mechanisms) is justified by the impact of a violation (R8: Low × High).

## Consequences

- **Positive:** strong, auditable, multi-layer residency guarantee; violations are caught at author-time *and* runtime; evidence for SOC2/GDPR.
- **Negative / costs:** SCP global-service allowlist must be curated and maintained (over-tight SCP breaks global services; over-loose weakens the guarantee); multiple mechanisms to test (Phase 0 exit criterion: *SCP provably blocks a non-EU region action in an EU account*).
- **Follow-ups:** the OPA residency policy + the `security-baseline-check` skill verify the layers are present; PrivateLink in-geo-only ([ADR-0026](0026-app-connectivity-privatelink.md)).

## Review-trigger

AWS changes `aws:RequestedRegion` semantics or the set of global services; a new region is added to a geo (update allow-lists); or an audit finding requires an additional layer.
