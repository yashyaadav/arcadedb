# `environments` — per-geo/env instantiation

A **single shared root config** (`main.tf` + `variables.tf` + `providers.tf` +
`kms.tf`) that wires the modules into a full stack, parameterised by a
**`terraform.tfvars` per geo/env**:

```
environments/
├── main.tf, variables.tf, providers.tf, kms.tf, outputs.tf, backend.tf, versions.tf
├── eu-prod/terraform.tfvars      # 1 pooled std cell + 2 enterprise cells (3-node)
├── eu-stage/terraform.tfvars     # prod-like (3-node), smaller nodes
├── eu-dev/terraform.tfvars       # single-node (no HA) — cost
├── us-prod/terraform.tfvars      # mirror in the US geo
├── us-stage/terraform.tfvars
└── us-dev/terraform.tfvars
```

Wiring order: `network → eks → observability → backup-dr → cell(s)`. KMS keys
(EBS/backups/secrets/logs) and the VPC-flow-logs role are created in `kms.tf`
(encrypt-everything, prime directive #5).

> **CTO-package status:** validate-clean integration of all modules, **not applied**.
> This root config doubles as the **integration test** — `tofu validate` here
> proves the modules compose. Account IDs / SSO group IDs / PagerDuty endpoints
> are placeholders.

## Validate the whole composition (no AWS)

```bash
tofu -chdir=terraform/environments init -backend=false
tofu -chdir=terraform/environments validate
```

## Plan/apply a specific env (POST-APPROVAL ONLY — not in this package)

```bash
tofu -chdir=terraform/environments init \
  -backend-config="bucket=kb-tfstate-eu" \
  -backend-config="key=environments/eu-prod/terraform.tfstate" \
  -backend-config="region=eu-central-1" \
  -backend-config="use_lockfile=true"

tofu -chdir=terraform/environments plan -var-file=eu-prod/terraform.tfvars
```

**EU state goes in the EU bucket, US state in the US bucket** (residency, ADR-0022).
In production this runs through Spacelift with mandatory prod approval (ADR-0020).

## Footprint per env (matches the HLD §5.4 worked example)

| Env | Cells | Replicas | Nodes | Notes |
|---|---|---|---|---|
| `*-prod` | 1 std pooled + 1–2 enterprise | 3 | r7g.2xlarge | full HA + enterprise WORM backups |
| `*-stage` | 1 std | 3 | r7g.xlarge | prod-like for validation |
| `*-dev` | 1 std | **1** | r7g.xlarge | single-node, no HA (cost — R10) |

## Notes

- **Enterprise cells** here use `cell_isolation = "namespace"` for the template.
  Production enterprise/regulated tenants may use `cell_isolation = "cluster"`
  (a dedicated EKS cluster) — that's a separate stack instantiation (ADR-0004).
- **Helm releases** default to Argo CD management (`manage_helm_release = false`);
  flip to `true` for a Terraform-driven cell.
- The **DR stack** (warm standby in `dr_region`) is a sibling instantiation whose
  `backup-dr` outputs feed `dr_bucket_arn` / `dr_backup_vault_arn` here.
