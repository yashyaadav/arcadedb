# ArcadeDB on AWS — Multi-Tenant Knowledge Base Platform

> **Status: CTO approval package (Phase D).** This repository contains the
> **High-Level Design**, **basic boilerplate IaC templates**, and the **Claude
> Code day-one handover kit** that ship to the CTO for sign-off **before any AWS
> spend**. Nothing here is applied to AWS. Account IDs and other sensitive values
> are placeholders. See [`docs/architecture.md`](docs/architecture.md) for the
> design and [the plan](#whats-in-this-package) for what each part covers.

A production-grade home on AWS for **ArcadeDB**, serving as the data-layer
foundation of a multi-tenant Knowledge Base for an AI SaaS. One virtual database
per tenant; two jurisdictions (EU + US) with hard GDPR residency; built and
operated **with Claude Code** for a clean hand-over to a cloud-ops team.

## What's in this package

| Part | Where | What |
|---|---|---|
| **1. High-Level Design** | [`docs/architecture.md`](docs/architecture.md), [`docs/adr/`](docs/adr/), [`docs/assumptions.md`](docs/assumptions.md) | End-to-end solution, all architecture diagrams, one ADR per decision (context · options · decision · reasoning · consequences), and the living assumptions log. |
| **2. Boilerplate IaC** | [`terraform/`](terraform/), [`helm/`](helm/), [`control-plane/`](control-plane/), [`.github/workflows/`](.github/workflows/) | Parameterised, instantiable Terraform/OpenTofu modules (network · eks · cell · backup-dr · observability) + landing zone, example `tfvars` per geo/env, a documented Helm `values.yaml`, control-plane interface stubs, and CI policy-gate workflows. |
| **3. Claude handover kit** | [`CLAUDE.md`](CLAUDE.md), [`.claude/`](.claude/), [`docs/runbooks/claude-code-operations.md`](docs/runbooks/claude-code-operations.md) | Root + nested `CLAUDE.md`, guard-rail hooks in `.claude/settings.json`, a self-contained `SKILL.md` per runbook, and the "operating this platform with Claude Code" guide. |

## The seven prime directives (never violated — see [`CLAUDE.md`](CLAUDE.md))

1. **Residency** — EU tenant data and backups stay in EU regions; DR pairs stay in-jurisdiction; no EU↔US data path exists.
2. **Version floor** — ArcadeDB **≥ 26.4.1** (closes the cross-DB isolation CVE + Raft HA); re-audit isolation after every upgrade.
3. **Quorum** — every prod cell runs **3 nodes**, one per AZ, with a PodDisruptionBudget `minAvailable: 2`.
4. **No public database** — ArcadeDB ports are never on a public subnet or public load balancer.
5. **Encrypt everything** at the platform layer (EBS/S3/Secrets/snapshots via KMS) — the engine provides none.
6. **No click-ops** — every resource is Terraform/Helm/GitOps; reproducible from a clean state.
7. **Sizing rule** — pod memory limit ≥ `maxPageRAM` + JVM heap + overhead, or the kernel OOM-kills a node and risks quorum.

## Repository layout

```
arcadedb/
├── CLAUDE.md                     # root project memory + prime directives
├── .claude/                      # settings.json hooks + skills (the AI operating model)
├── terraform/
│   ├── landing-zone/             # Org/OUs, SCPs (residency deny), IAM IC, KMS, state
│   ├── modules/{network,eks,cell,backup-dr,observability}/
│   └── environments/{eu,us}-{dev,stage,prod}/   # example tfvars per geo/env
├── helm/arcadedb/values.yaml     # pinned image, replicas=3, sizing, probes, MIME workaround
├── control-plane/                # registry schema, Step Functions ASL, router (interface stubs)
├── policy/conftest/              # OPA/Rego residency + "no public DB" gates
├── docs/                         # architecture.md (HLD), adr/, assumptions.md, runbooks/
└── .github/workflows/            # CI policy gates (tfsec, checkov, trivy, conftest, kubeconform, cosign)
```

## Validating this package locally (no AWS, no credentials)

```bash
make validate     # fmt + init -backend=false + validate + tflint + conftest + helm lint + kubeconform
```

Individual targets are documented in the [`Makefile`](Makefile). **None of these
commands touch AWS.** `terraform`/`tofu` run with `-backend=false` and never
`plan`/`apply` against a real account.

## What happens after sign-off (NOT in this package)

On CTO approval we author the **Low-Level Design** (`docs/lld.md`) and execute
**Phases 0–4** (real build + apply). See [`docs/architecture.md`](docs/architecture.md) §"Rollout phases".
