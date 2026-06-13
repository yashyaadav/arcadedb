# ADR-0018 — Secrets: AWS Secrets Manager + External Secrets Operator

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Store secrets in **AWS Secrets Manager**, sync into Kubernetes with the **External Secrets Operator (ESO)** via Pod Identity. Handle ArcadeDB's **set-once root password** specially. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Security |
| **Type** | ✅ decided by the business |

## Context

ArcadeDB has **no native encryption** and a **set-once root password** (F4): the root credential is fixed at first boot and cannot be re-set via the init var. Per-tenant DB credentials, on the other hand, are normal and rotatable. We need KMS-encrypted secret storage, controlled sync into pods (no static creds), and rotation for tenant credentials — all residency-safe.

## Assumptions it rests on

- A1 (pay for Secrets Manager), F4 (set-once root), prime directive #5 (KMS), [ADR-0011](0011-workload-identity-pod-identity.md) (Pod Identity).

## Options considered

### Option A — Secrets Manager + ESO (chosen)
- **Pros:** managed, KMS-encrypted, IAM-scoped, regional (residency-safe); **native rotation** (Lambda) for tenant credentials; ESO syncs secrets into K8s as native Secrets without static cloud creds (Pod Identity); audited via CloudTrail; familiar + hand-over-friendly.
- **Cons:** Secrets Manager per-secret cost; ESO is another controller to run; rotation Lambdas to maintain.

### Option B — HashiCorp Vault
- **Pros:** powerful, dynamic secrets, broad backend support.
- **Cons:** we operate + scale + secure + back up Vault (HA, unseal, upgrades) across geos — significant toil against the clean-hand-over goal; overkill for the secret patterns we have.

### Option C — SSM Parameter Store (SecureString)
- **Pros:** cheap, simple, KMS-encrypted.
- **Cons:** **no built-in rotation**; weaker secret-lifecycle features; would hand-build rotation for tenant credentials.

## Decision

**Secrets Manager + ESO** via Pod Identity. **Root password:** generate before first boot, inject via env, **mark the secret immutable**; "rotating root" = provision a *new* admin server-user (documented procedure), never re-set the init var. **Tenant credentials:** normal rotatable secrets (rotation Lambda → ArcadeDB `ALTER USER` → Secrets Manager → ESO re-sync), surfaced by the [rotate-secrets] skill.

## Reasoning — why this beats the alternatives

The decision is **business-decided** for Secrets Manager + ESO. Among options it best fits the no-static-creds + managed + rotation + residency requirements without the operational burden of running Vault. The set-once root constraint (F4) is an ArcadeDB quirk we encode as a special procedure regardless of store, so it doesn't change the store choice — but it *must* be documented so no one tries (and fails) to rotate root the normal way.

## Consequences

- **Positive:** managed, encrypted, rotatable, residency-safe secrets; no static cloud creds in pods; audited.
- **Negative / costs:** per-secret cost; ESO + rotation Lambdas to operate; the **set-once root** procedure is a sharp edge that must be trained/documented (and a hook prevents naive root re-set attempts).
- **Follow-ups:** ESO + Pod Identity wiring; root-secret immutability + the new-admin-user procedure; tenant-credential rotation Lambda; ESO-sync-failure alert.

## Review-trigger

ArcadeDB changes root-password semantics; Secrets Manager cost grows materially; or a need for dynamic/short-lived DB creds emerges (re-evaluate Vault).
