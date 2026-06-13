# ADR-0011 — Workload identity: EKS Pod Identity

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Use **EKS Pod Identity** for workload-to-AWS IAM; keep **IRSA** as a documented fallback. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

Pods need scoped AWS access (External Secrets → Secrets Manager, backup sidecar → S3, ADOT → AMP, etc.) without static credentials. At **many-cluster, many-cell scale** the per-cluster IAM OIDC-provider + trust-policy plumbing of IRSA becomes a maintenance burden. EKS Pod Identity associates an IAM role to a service account via a simple API, no per-cluster OIDC provider.

## Assumptions it rests on

- A14 (many cells per cluster, scale), A1 (operational simplicity).

## Options considered

### Option A — EKS Pod Identity (chosen)
- **Pros:** no per-cluster OIDC provider to manage; simpler role association (an EKS API call, not trust-policy JSON per cluster); scales cleanly across many clusters/cells; AWS-native, supported by the Pod Identity Agent add-on; easier hand-over.
- **Cons:** newer than IRSA (smaller body of community examples); requires the Pod Identity Agent add-on; a few tools still assume IRSA.

### Option B — IRSA (IAM Roles for Service Accounts)
- **Pros:** mature, ubiquitous, well-documented; works everywhere.
- **Cons:** per-cluster IAM OIDC provider + trust-policy management multiplies with cluster count; more boilerplate at our scale.

## Decision

**EKS Pod Identity** as the default; **IRSA documented as a fallback** for any add-on that doesn't yet support Pod Identity.

## Reasoning — why this beats the alternatives

At our intended scale (one regional cluster backing many cells, plus dedicated enterprise clusters), the **per-cluster OIDC/trust-policy overhead of IRSA compounds**, while Pod Identity reduces identity wiring to a simple, uniform association — better for both reliability and hand-over. IRSA's maturity advantage is real, so we keep it as an explicit fallback rather than betting everything on the newer mechanism.

## Consequences

- **Positive:** less IAM plumbing per cluster; uniform, scalable identity model; cleaner hand-over.
- **Negative / costs:** depends on the Pod Identity Agent add-on; occasional tool that needs IRSA → use the fallback; team must learn the newer model.
- **Follow-ups:** Pod Identity associations in the EKS module for ESO, backup sidecar, ADOT, Karpenter controller; document the IRSA fallback path.

## Review-trigger

A required add-on lacks Pod Identity support (use IRSA there); or AWS deprecates/changes either mechanism.
