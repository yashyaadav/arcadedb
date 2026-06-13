# CLAUDE.md — ArcadeDB-on-AWS KB Platform (root project memory)

> **Read this first.** This file is the AI operating model's contract. It is loaded
> into every Claude Code session in this repo. Nested `CLAUDE.md` files add
> directory-specific rules (terraform/, helm/, control-plane/, docs/).
> **The hooks in `.claude/settings.json` enforce the non-negotiables below
> deterministically — they are not suggestions.**

## What this repo is

A production-grade home on AWS for **ArcadeDB**, the data-layer foundation of a
multi-tenant Knowledge Base for an AI SaaS. One virtual DB per tenant; two
jurisdictions (EU + US) with hard GDPR residency; built and operated **with
Claude Code** for a clean hand-over to a cloud-ops team.

**Current phase: CTO approval package (Phase D).** The HLD + boilerplate IaC +
this AI kit ship for sign-off **before any AWS spend**. **Nothing is applied to
AWS.** Do not run `terraform/tofu apply`, create cloud resources, or run
cloud-mutating commands until the CTO approves and we enter Phase 0.

Authoritative design: [`docs/architecture.md`](docs/architecture.md) (HLD) ·
[`docs/adr/`](docs/adr/) (one ADR per decision) · [`docs/assumptions.md`](docs/assumptions.md).

## The 7 prime directives — NEVER violate these

1. **Residency** — EU tenant data + backups stay in EU regions; DR pairs stay
   in-jurisdiction; **no EU↔US data path exists**. (ADR-0007)
2. **Version floor** — ArcadeDB **≥ 26.4.1** (closes the CVSS-9.0 cross-DB
   isolation CVE + Raft HA). Re-audit isolation after every upgrade. (ADR-0012)
3. **Quorum** — every **prod** cell = **3 nodes**, one per AZ, PDB
   `minAvailable: 2`. Never drop below quorum. Non-prod may be single-node. (ADR-0010)
4. **No public database** — ArcadeDB ports (2480/2424/2434/5432/6379/7687) are
   never on a public subnet or public LB.
5. **Encrypt everything** at the platform layer (EBS/S3/Secrets/snapshots via
   KMS) — the engine provides none. (F4)
6. **No click-ops** — every resource is Terraform/Helm/GitOps; reproducible from
   clean state. Always plan before apply; prod apply needs manual approval. (ADR-0020)
7. **Sizing rule** — pod memory limit ≥ `maxPageRAM` + JVM heap + overhead, or the
   kernel OOM-kills a node and risks quorum.

## Load-bearing ArcadeDB facts (why this isn't a generic "DB on K8s" repo)

- HA is **leader-based Raft**, GA from 26.4.1, **min 3 nodes**; replication is
  **per-database**; reads can fan to replicas, **writes go to the leader**.
- **No per-DB resource quotas** → the control plane caps cell capacity and the
  retrieval proxy enforces per-tenant runtime limits (ADR-0027).
- **No native encryption, no native audit, root password is set-once** → encrypt
  at AWS layer; build an app-layer audit trail; "rotate root" = new admin user.
- Backup is **hot per-DB ZIP, excludes WAL, no incremental/PITR, no S3 target**;
  **restore requires the target DB to NOT exist**. Supplement with EBS snapshots.
- Official **Helm chart (StatefulSet), no Operator** → we own upgrades; `/ready`
  (HTTP 204) for probes; `/prometheus` has a **MIME-type bug** (workaround in
  the chart).
- Single-leader **write ceiling per cell**; a DB can't be split across nodes →
  scale by adding **cells**, not by enlarging a Raft group.

## Tech stack + pinned versions

| Thing | Pin | Where |
|---|---|---|
| ArcadeDB | **≥ 26.4.1** (pin a digest in prod) | `helm/arcadedb/values.yaml`, cell module |
| OpenTofu / Terraform | **≥ 1.10** (S3-native locking) | `terraform/**/versions.tf` |
| AWS provider | `>= 5.80, < 6.0` | `versions.tf` |
| Helm / kubernetes / random providers | pinned ranges | `versions.tf` |
| Helm chart | `0.1.0` | `helm/arcadedb/Chart.yaml` |
| EKS | `1.31` | env tfvars |
| GitHub Actions | pinned (SHA in prod) | `.github/workflows/` |

## Repo map

```
docs/            HLD (architecture.md), adr/, assumptions.md, runbooks/  ← design + reasoning
terraform/       landing-zone/, modules/{network,eks,cell,backup-dr,observability}/, environments/
helm/arcadedb/   the cell chart (StatefulSet, PDB, probes, sizing, MIME workaround)
control-plane/   registry schema, router/retrieval interfaces, Step Functions ASL (stubs)
policy/conftest/ OPA residency + no-public-DB gates (+ unit tests)
.github/workflows/ CI policy gates
.claude/         settings.json hooks + skills/ (this AI operating model — handed to ops)
```

## Tiering rules (decide cell placement + config)

- **Standard** tenants → **pooled** cells (namespace in a shared EKS cluster),
  `txWalFlush` 0/1, placed by capacity caps (~150 DBs / 60% maxPageRAM / 70% disk).
- **Enterprise/regulated** tenants → **dedicated** cells (optionally a dedicated
  EKS cluster), `txWalFlush=2` (fsync), per-tenant CMK option, 1h backups, Object Lock.
- **The boundary we trust for sensitive data is the dedicated cell.** Pooled cells
  are a cost optimisation guarded by version floor + NetworkPolicy + isolation probe.

## Conventions (enforced as CLAUDE.md rules + CI)

- **Every decision gets an ADR** stating its reasoning (use `docs/adr/0000-template.md`
  or the `new-adr` skill). **Every assumption gets a `docs/assumptions.md` entry**
  (rationale · impact-if-wrong · validation owner · linked ADR).
- Match the surrounding style. Pin all versions. Tag every resource with
  `platform/geo/env/module/managed-by/residency-boundary`.
- Validate before you commit: `make validate` (fmt, validate, tflint, conftest,
  helm lint, kubeconform). All offline; no AWS.

## How to work in this repo (Claude)

- **Plan before apply.** For Terraform, propose a plan and run the
  `review-terraform-plan` skill before any apply (post-approval only).
- **Use the skills** in `.claude/skills/` for operational procedures — they carry
  the safety checks. Day-2 ops: `provision-tenant`, `add-cell`, `upgrade-arcadedb`,
  `restore-tenant`, `dr-drill`, `rotate-secrets`, `cell-capacity-report`,
  `incident-triage`, `migrate-schema`, `tenant-usage-report`, `tenant-erasure`.
  Build-time: `review-terraform-plan`, `new-adr`, `security-baseline-check`.
- **If something is ambiguous or you hit a real fork, ask** — don't guess on
  residency, quorum, version, encryption, or public-exposure questions.
- **Never** lower the ArcadeDB image below 26.4.1, set `replicas < 3` on a prod
  cell, remove a PDB, open a DB port to `0.0.0.0/0`, add an out-of-geo region
  literal, or put a secret in a diff. The hooks will block these; don't try to
  work around them — fix the underlying change.

## Definition of done (for any change here)

1. `make validate` is green. 2. ADR added/updated if it's a decision.
3. `docs/assumptions.md` updated if it rests on a new assumption.
4. The relevant nested `CLAUDE.md` / skill / runbook updated. 5. No prime-directive violation.
