# ADR-0020 — Terraform runner: Spacelift (Atlantis as budget alternative)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Run Terraform/OpenTofu through **Spacelift** (stack dependencies, drift detection, OPA policy gates, **mandatory manual approval on prod / any geo-prod apply**). Atlantis is the documented budget alternative. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

We have many stacks across multiple accounts and two geos with **inter-stack dependencies** (landing zone → network → eks → cell), a hard requirement for **policy gates** (residency, no-public-DB) and **mandatory prod approval** (prime directive #6, no click-ops), and **drift detection** for a hand-over-grade estate. A plain CI job running `terraform apply` doesn't give dependency orchestration, drift detection, or native policy gates.

## Assumptions it rests on

- A1 (budget for a runner), A11 (GitHub), [ADR-0007](0007-residency-enforcement-scp.md) (policy gates).

## Options considered

### Option A — Spacelift (chosen)
- **Pros:** native **stack dependencies** + ordering; **drift detection**; built-in **OPA policy gates** (plan/approval/push policies — perfect for residency + no-public-DB + prod-approval); per-stack RBAC + SSO; private workers (can run in-account, residency-safe); strong audit trail.
- **Cons:** commercial cost; another SaaS in the pipeline; learning curve.

### Option B — Atlantis (self-hosted)
- **Pros:** open-source, cheap; PR-driven `plan`/`apply`; familiar.
- **Cons:** we operate it; weaker native dependency orchestration + drift detection; policy gating is more DIY. Kept as the **budget alternative**.

### Option C — Terraform Cloud (TFC)
- **Pros:** managed, good UX, Sentinel policies.
- **Cons:** Sentinel vs our OPA/Conftest standard (tool fragmentation); cost; less flexible workers for in-account/residency than Spacelift private workers.

## Decision

**Spacelift** as the runner, with private workers in-account (residency-safe), OPA policy gates, drift detection, and **mandatory manual approval on prod / any geo-prod apply**. **Atlantis** documented as the budget fallback.

## Reasoning — why this beats the alternatives

The estate's **inter-stack dependencies + drift + policy-gate + prod-approval** needs are exactly Spacelift's core, and its **OPA-native** gates align with our Conftest/OPA residency standard (no Sentinel fragmentation, ruling out TFC on tooling grounds). Atlantis is cheaper but pushes dependency/drift/policy work onto us — fine as a fallback if budget demands, but Spacelift better serves the safe-hand-over goal.

## Consequences

- **Positive:** ordered, drift-detected, policy-gated applies with enforced prod approval and an audit trail; residency-safe private workers.
- **Negative / costs:** Spacelift subscription; another SaaS to integrate + secure; OPA policies to author + maintain.
- **Follow-ups:** stack graph (landing-zone→network→eks→cell); OPA push/plan/approval policies (residency, no-public-DB, no-stateful-destroy); the `review-terraform-plan` skill complements the gates pre-approval.

## Review-trigger

Spacelift cost outweighs the value at our scale (fall back to Atlantis); or the org standardises on a different runner.
