# `landing-zone`

The org-level baseline that makes residency and the security posture **structural**:
geo OUs, **residency-deny SCPs**, a baseline guardrail SCP, **per-geo Terraform
state** (EU state in the EU), and **IAM Identity Center** permission sets.

> **CTO-package status:** basic boilerplate template — validate-clean, **not applied**.
> Org root id, account IDs, and SSO instance ARN are placeholders. Assumes Control
> Tower + AFT created the org + core accounts (ADR-0005); this layers the geo
> boundary + state + access on top.

## What it creates

| Resource | Why |
|---|---|
| `aws_organizations_organizational_unit.geo` (eu, us) | The **residency boundary** — workload accounts live under their geo OU. |
| `aws_organizations_policy.residency` + attachment | **SCP denies any action outside the geo's region allow-list** (the strongest residency layer, ADR-0007). Global services are allow-listed via `not_actions`. |
| `aws_organizations_policy.baseline` + attachment | Protects CloudTrail/Config/GuardDuty/SecurityHub; blocks org-leave + root use (SOC2 baseline). |
| Per-geo KMS + S3 state buckets (`aws.eu` / `aws.us` providers) | **EU state stays in the EU**; SSE-KMS, versioned, public-access-blocked, S3-native locking (ADR-0022). |
| `aws_ssoadmin_permission_set` (PlatformAdmin, ReadOnly, BreakGlass) | **No IAM users** — access via SSO permission sets only. |

## The residency SCP (the key control)

```
Deny  *  (except global services)  when  aws:RequestedRegion ∉ {geo allow-list}
```

This is **Phase-0's exit-criterion test**: *the SCP provably blocks a non-EU
region action in an EU account.* The CI OPA gate (`policy/conftest/residency.rego`)
catches out-of-geo region literals before apply; the SCP catches them at runtime
even if the IaC is wrong — defence in depth.

## Usage

```hcl
# providers configured in providers.tf (management acct + aws.eu + aws.us)
module not required — this is a root config. Set terraform.tfvars then:
#   tofu init && tofu plan   (NOT in the CTO package — post-approval only)
```

Key variables: `organization_root_id`, `geos` (OU name + allowed_regions per geo),
`eu_state_region` / `us_state_region`, `sso_instance_arn`, `permission_sets`,
`global_service_actions_allowlist`. See [`variables.tf`](variables.tf) and
[`terraform.tfvars.example`](terraform.tfvars.example).

## Validate (no AWS)

```bash
tofu init -backend=false && tofu validate && tflint
```

## Phase-0/LLD follow-ups

- Account assignment of permission sets to accounts (`aws_ssoadmin_account_assignment`).
- KMS key policies (currently default); per-account workload CMKs live in env stacks.
- Wire Control Tower / AFT account-vending; CloudTrail org trail + Config aggregator
  (Control Tower-managed) referenced, not duplicated.
- S3 state backend blocks per environment point at these buckets.
