# ADR-0005 — Landing zone: AWS Control Tower + Account Factory for Terraform (AFT)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Bootstrap the multi-account estate with **AWS Control Tower + Account Factory for Terraform (AFT)**; Terraform then owns all workload infra. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

We need a **SOC2-credible multi-account baseline** fast (org CloudTrail, AWS Config, a Log Archive account, an Audit account, guardrails) and we must **vend geo-scoped accounts repeatably** (eu-dev/stage/prod, us-dev/stage/prod under separate OUs that form the residency boundary, §5.2). Account vending itself must be GitOps-driven (prime directive #6).

## Assumptions it rests on

- A7 (SOC2 + GDPR), A1 (budget), A9 (region pairs).

## Options considered

### Option A — Control Tower + AFT (chosen)
- **Pros:** managed baseline (org CloudTrail/Config, Log Archive + Audit accounts, guardrails) out of the box → fastest path to a SOC2-credible org; **AFT keeps account vending in Terraform/GitOps**, so geo-scoped accounts are reproducible; well-trodden, hand-over-friendly.
- **Cons:** Control Tower opinionation/region constraints; some "magic" the team must learn; AFT pipeline is an extra moving part.

### Option B — Pure-Terraform landing zone (e.g. a community LZ module)
- **Pros:** full control, no Control Tower opinionation; everything in one tool.
- **Cons:** we build + own the entire org baseline (CloudTrail org trail, Config aggregator, log-archive immutability, guardrail SCP scaffolding) ourselves → slower, more to get wrong on the compliance baseline; weaker managed guardrails.

## Decision

**Control Tower + AFT** for the org baseline and account vending; Terraform (via Spacelift, [ADR-0020](0020-tf-runner-spacelift.md)) for all workload infra. Residency SCPs ([ADR-0007](0007-residency-enforcement-scp.md)) are applied on the geo OUs.

## Reasoning — why this beats the alternatives

The compliance baseline (immutable central logs, delegated audit, org-wide config) is **exactly the part you don't want to hand-roll** under a SOC2 timeline — Control Tower gives it managed. AFT preserves our non-negotiable "no click-ops" by keeping account creation in Terraform. A pure-TF LZ is more flexible but spends our scarcest resource (time-to-credible-baseline) re-implementing what Control Tower manages.

## Consequences

- **Positive:** fast, credible multi-account baseline; reproducible geo-scoped account vending; clean OU structure for the residency boundary.
- **Negative / costs:** Control Tower region/opinionation constraints (validate against A9 in Phase 0); AFT pipeline to operate; some lock-in to the Control Tower model.
- **Follow-ups:** OU + SCP design (0007), per-geo state buckets (0022), IAM Identity Center (0011 context).

## Review-trigger

Control Tower constraints block a needed region/config (re-evaluate pure-TF LZ); or the org outgrows the Control Tower model.
