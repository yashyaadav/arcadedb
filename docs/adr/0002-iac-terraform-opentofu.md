# ADR-0002 — IaC tool: Terraform / OpenTofu (greenfield)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Build the entire AWS landing zone and workload infra with **Terraform / OpenTofu** (HCL), greenfield. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead |
| **Type** | ✅ decided by the business |

## Context

This is a greenfield AWS estate that must be **reproducible from a clean state** (prime directive #6, no click-ops) across multiple accounts and two jurisdictions, with **policy gates** (residency, no-public-DB, encryption) enforceable in CI. We also want the **AI operating model** to drive plans/applies safely, which favours a tool with a first-class `plan` artifact and a rich policy ecosystem.

## Assumptions it rests on

- A11 (GitHub CI), A1 (budget for a TF runner like Spacelift, [ADR-0020](0020-tf-runner-spacelift.md)).

## Options considered

### Option A — Terraform / OpenTofu (chosen)
- **Pros:** cloud-agnostic, huge provider + module ecosystem; explicit `plan` artifact perfect for review + AI guard-rails ([review-terraform-plan] skill); first-class policy tooling (tfsec, checkov, Conftest/OPA) for the residency + no-public-DB gates; OpenTofu (Apache 2.0) avoids BSL licensing concerns and gives **S3-native state locking ≥ 1.10** ([ADR-0022](0022-state-locking-s3-native.md)); ops team familiarity.
- **Cons:** HCL is not a general-purpose language; state management discipline required; multi-account orchestration needs a runner.

### Option B — AWS CDK
- **Pros:** real programming language; good AWS-native ergonomics.
- **Cons:** AWS-only; smaller cross-tool policy-gate ecosystem; `cdk diff` is less reviewer-friendly than `terraform plan` for the guard-rail story; synthesises to CloudFormation (slower, drift quirks).

### Option C — CloudFormation
- **Pros:** native, no state file, drift detection built in.
- **Cons:** verbose; weakest module reuse; poorest fit for multi-account/multi-region cell templating; weaker third-party policy gates.

## Decision

**Terraform / OpenTofu**, OpenTofu ≥ 1.10 as the validated floor (Terraform ≥ 1.10 also supported), with a runner (Spacelift) for multi-account orchestration and mandatory prod approval.

## Reasoning — why this beats the alternatives

The **`plan`-artifact + policy-gate ecosystem** is decisive: it is what makes residency, "no public DB", and quorum invariants enforceable *before apply* and reviewable by both humans and the `review-terraform-plan` skill. Cloud-agnosticism and the OpenTofu licence (Apache 2.0) plus its **built-in S3 state locking** (no DynamoDB lock table to manage) reduce moving parts. CDK/CFN are AWS-native but weaker on exactly the review + policy story the hand-over needs.

## Consequences

- **Positive:** reproducible, reviewable, policy-gated infra; reusable cell module instantiated per geo/env; AI can safely analyse plans.
- **Negative / costs:** state-management discipline; a runner is needed for serious multi-account use (cost); HCL limits some logic (mitigated by keeping control-plane logic in real code, [control-plane/](../../control-plane/)).
- **Follow-ups:** state layout (0022), runner (0020), policy gates (CI workflows + [policy/conftest/](../../policy/conftest/)).

## Review-trigger

OpenTofu/Terraform licensing or roadmap changes materially; or the team standardises on CDK elsewhere and cross-tool consistency outweighs the policy-gate advantage.
