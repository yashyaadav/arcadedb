# Policy gates (OPA / Conftest)

Hard CI policy gates that enforce the prime directives **before apply** — the
shift-left twins of the org SCPs (ADR-0007). Residency is a CI gate, not just an
SCP (HLD §7.6).

| Policy | Enforces | Source |
|---|---|---|
| [`residency.rego`](residency.rego) | No out-of-geo AWS region/AZ literal anywhere in the plan. | prime directive #1, ADR-0007 |
| [`no_public_db.rego`](no_public_db.rego) | No security group/rule opens an ArcadeDB port (2480/2424/2434/5432/6379/7687) to `0.0.0.0/0` or `::/0`. | prime directive #4 |

Each policy ships with unit tests (`*_test.rego`) so the gates themselves are
verified.

## Run the policy unit tests (self-contained, no AWS)

```bash
conftest verify --policy policy/conftest    # or: make conftest
# => 7 tests, 7 passed
```

## How they run in CI (post-approval, against real plans)

The GitHub workflow (`.github/workflows/terraform-policy.yml`) generates plan
JSON and tests it, passing the geo allow-list as parameters:

```bash
tofu -chdir=terraform/environments plan -var-file=eu-prod/terraform.tfvars -out=tfplan
tofu -chdir=terraform/environments show -json tfplan > plan.json

# residency: inject the geo allow-list and test
jq '. + {parameters: {allowed_regions: ["eu-central-1","eu-west-1"]}}' plan.json \
  | conftest test - --policy policy/conftest --namespace main

# no-public-DB needs no parameters
conftest test plan.json --policy policy/conftest --namespace main
```

## Input contract

- **`residency.rego`** — walks every string in the plan; flags any value matching
  an AWS region/AZ pattern that is not in `input.parameters.allowed_regions`.
- **`no_public_db.rego`** — inspects `aws_security_group` ingress and
  `aws_security_group_rule` (from both `resource_changes[]` and
  `planned_values...resources[]` plan shapes).

## Adding a policy

1. Add `mypolicy.rego` (`package main`, `deny contains msg if {...}`).
2. Add `mypolicy_test.rego` with `test_*` rules using `with input as {...}`.
3. `conftest verify --policy policy/conftest` must stay green.
4. Wire it into the CI workflow + reference it from an ADR if it encodes a decision.
