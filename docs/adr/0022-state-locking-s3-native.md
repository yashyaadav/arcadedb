# ADR-0022 — Terraform state locking: S3 native (per-geo buckets)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Use **S3 with native state locking** (Terraform ≥ 1.10 / OpenTofu), SSE-KMS, versioned, **per-geo buckets** — no DynamoDB lock table. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

We need remote Terraform state with locking, encryption, and versioning. Crucially, **state itself is data subject to residency** — EU stacks' state must live in the EU (prime directive #1, [ADR-0007](0007-residency-enforcement-scp.md) layer 5). Terraform ≥ 1.10 / OpenTofu added **native S3 state locking** (via a lock file in the bucket with conditional writes), removing the long-standing need for a separate DynamoDB lock table.

## Assumptions it rests on

- A11/[ADR-0002](0002-iac-terraform-opentofu.md) (TF/Tofu ≥ 1.10), prime directive #1 (state is in-geo), prime directive #5 (KMS).

## Options considered

### Option A — S3 native locking, per-geo buckets (chosen)
- **Pros:** **one fewer resource** (no DynamoDB lock table to create/secure/pay for per geo); native to TF ≥ 1.10 / OpenTofu; SSE-KMS + versioning on the bucket; per-geo buckets keep EU state in the EU; simpler backend config.
- **Cons:** requires the ≥ 1.10 floor (already our pin); newer mechanism (less battle-tested than DynamoDB locking, though now GA).

### Option B — S3 + DynamoDB lock table (classic)
- **Pros:** the long-standing, battle-tested pattern; works on older TF.
- **Cons:** an extra DynamoDB table per geo to create, secure, and pay for; more backend wiring; unnecessary now that native locking exists at our version floor.

## Decision

**S3 native locking, SSE-KMS, versioned, per-geo buckets** (EU state in eu-central-1, US state in us-east-1), backend config per stack. The ≥ 1.10 floor is enforced in [versions.tf](../../terraform/versions.tf).

## Reasoning — why this beats the alternatives

Since our version floor is already ≥ 1.10 ([ADR-0002](0002-iac-terraform-opentofu.md)), native S3 locking lets us **delete an entire moving part** (the DynamoDB lock table) with no loss of safety — fewer resources to secure, pay for, and reason about per geo. Per-geo buckets satisfy the residency layer for state. DynamoDB locking's only advantage (maturity) doesn't justify carrying the extra resource now that native locking is GA.

## Consequences

- **Positive:** simpler backend; one fewer per-geo resource; residency-safe, encrypted, versioned state.
- **Negative / costs:** depends on the ≥ 1.10 floor (already pinned); newer locking path (monitor for edge cases).
- **Follow-ups:** per-geo state buckets in the landing zone; backend blocks per stack; bucket policies + KMS + versioning + public-access-block.

## Review-trigger

A native-locking limitation surfaces (fall back to DynamoDB locking); or the TF/Tofu floor changes.
