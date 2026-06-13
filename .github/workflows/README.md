# CI workflows (policy gates)

GitHub Actions templates implementing the policy gates from HLD §7.6. **CTO-package
status:** templates — valid YAML, **not run** (no repo on GitHub yet, no AWS).
Action versions are pinned by tag; **pin by commit SHA in production** (supply chain).

| Workflow | Gate | Blocks merge on |
|---|---|---|
| [`terraform-validate.yml`](terraform-validate.yml) | fmt + init + validate + tflint | format/validate/lint errors |
| [`terraform-security.yml`](terraform-security.yml) | **tfsec + checkov + Trivy** (config) | HIGH/CRITICAL IaC findings (SARIF → Security tab) |
| [`terraform-policy.yml`](terraform-policy.yml) | **Conftest** residency + no-public-DB | out-of-geo region literal; public DB port |
| [`helm-validate.yml`](helm-validate.yml) | **helm lint + kubeconform** + Trivy | invalid chart/manifests; chart misconfig |
| [`image-supply-chain.yml`](image-supply-chain.yml) | version floor + arm64 + **Trivy image + cosign** | < 26.4.1; no arm64; CRITICAL CVE; unsigned |
| [`control-plane.yml`](control-plane.yml) | typecheck + tests + ASL JSON valid | type/test errors; invalid ASL |

## What runs when

- **On PR:** validate, security, policy unit tests, helm, control-plane — all offline,
  no AWS. These mirror `make validate`.
- **`workflow_dispatch` (post-approval):** `terraform-policy` against a real plan
  (needs OIDC read-only creds); `image-supply-chain` (needs ECR + OIDC push).

## Relationship to the Terraform runner

CI gates are **advisory + blocking on PR**. The **apply** path goes through
**Spacelift** (ADR-0020) with its own OPA gates + **mandatory manual approval on
prod / any geo-prod apply** (prime directive #6). CI never applies.

## Production hardening (Phase 0)

- Pin every action by commit SHA (not tag).
- Add `.checkov.yaml` with justified skips (each skip → a comment/ADR).
- Require these checks in branch protection; require signed commits.
- Wire OIDC roles (read-only for plan, scoped push for ECR).
