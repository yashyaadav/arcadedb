---
name: review-terraform-plan
description: Analyse an OpenTofu/Terraform plan (or `tofu show -json` output) BEFORE approval and produce a per-change risk summary plus a clear APPROVE/REJECT recommendation. Use whenever a plan is awaiting the Spacelift approval gate — especially for any prod / geo-prod stack, or any change touching security groups, KMS, IAM, state/backup buckets, StatefulSets, or PVCs.
---

# Review a Terraform plan

> Read a tofu/terraform plan before approval, score every change for risk, and hand back a go/no-go that NEVER approves a prime-directive violation. **Phase note:** this skill is **BUILD-TIME and read-only** — it inspects plan JSON and never applies. The *apply* it gates is AWS-mutating and is out of scope until after CTO sign-off and the relevant phase; the actual approve/apply happens later in Spacelift behind a mandatory manual approver ([ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md), prime directive #6).

## Prerequisites

- A plan to review: either the Spacelift run's proposed plan, or a local `tofu plan -out=tfplan` you can render to JSON. Reviewing JSON (`tofu show -json tfplan`) is strongly preferred over scrollable human output — it is the same shape the policy gates consume.
- `tofu` (or `terraform`) and `jq` available locally; `conftest` available to run the policy gates ([`../../../policy/conftest`](../../../policy/conftest)).
- The target stack's **geo** and **env** (e.g. `eu` / `prod`) and that geo's **`allowed_regions`** allow-list (e.g. EU: `eu-central-1`, `eu-west-1`; US: `us-east-1`, `us-west-2`). You feed this to the residency gate.
- Read access to the repo so you can map resource addresses back to modules ([`../../../terraform/modules/cell`](../../../terraform/modules/cell), [`.../eks`](../../../terraform/modules/eks), [`.../backup-dr`](../../../terraform/modules/backup-dr), [`.../observability`](../../../terraform/modules/observability), [`../../../terraform/landing-zone`](../../../terraform/landing-zone)).
- This skill makes **no** AWS or cluster calls. If you find yourself authenticating to AWS, stop — that is the apply phase, not the review.

## Inputs

| Input | Example | Notes |
|---|---|---|
| `plan_json` | `plan.json` | Output of `tofu show -json tfplan`. The primary input. |
| `plan_human` | Spacelift plan log | Optional secondary read; JSON is authoritative. |
| `stack` | `eu-prod/cell-kb-eu-prod-std-02` | Which stack/environment this plan belongs to. |
| `geo` | `eu` \| `us` | Residency boundary for the residency gate. |
| `env` | `prod` \| `stage` \| `dev` | `prod` triggers quorum/PDB checks (prime directive #3). |
| `allowed_regions` | `["eu-central-1","eu-west-1"]` | The geo allow-list passed to `residency.rego`. |

## Safety checks (MUST pass before proceeding)

These are the **blocking** conditions. If ANY is present, the recommendation is **REJECT** — a plan with a prime-directive violation is NEVER approvable, regardless of urgency.

- **No public DB (prime directive #4):** REJECT if any `aws_security_group`/`aws_security_group_rule` ingress opens an ArcadeDB port — **2480, 2424, 2434, 5432, 6379, 7687** — to a public CIDR (`0.0.0.0/0` or `::/0`), or if any DB port lands on a public subnet / internet-facing LB. This is exactly what [`no_public_db.rego`](../../../policy/conftest/no_public_db.rego) enforces; treat a `conftest` deny here as final.
- **Residency (prime directive #1):** REJECT if any out-of-geo AWS **region/AZ literal** appears anywhere in the plan (e.g. a `us-*` string in an EU stack), or if the change creates any EU↔US data path (cross-geo replication, a global DynamoDB table, a cross-region S3 replication rule, a cross-geo KMS grant). [`residency.rego`](../../../policy/conftest/residency.rego) walks every string against `allowed_regions`; a deny is final.
- **No destroy of stateful resources:** REJECT if the plan `delete`s (or `delete`+`create` / `replace`) any stateful resource — **PersistentVolumeClaim, PersistentVolume, StatefulSet, `aws_kms_key`/alias, the Terraform state bucket or its lock table, the backup bucket/objects, EBS volumes or snapshots, the DynamoDB tenant registry / cell catalog**. ArcadeDB has NO incremental/PITR backup and backups EXCLUDE the WAL, so a destroyed PVC or snapshot can be unrecoverable; a recreated StatefulSet can drop the Raft data and break the cell. (Legitimate teardown goes through [`retire-cell`](../retire-cell/SKILL.md) / [`deprovision-tenant`](../deprovision-tenant/SKILL.md), reviewed as such — not an incidental destroy.)
- **Quorum / PDB intact (prime directive #3):** for `env=prod`, REJECT if the plan sets a DB cell to `replicas < 3`, removes/loosens the PodDisruptionBudget, or drops `minAvailable` below 2. Prod = 3 nodes one-per-AZ. (Non-prod single-node is allowed — do not flag it for dev/stage.)
- **KMS / IAM / role / SCP / policy changes are SENSITIVE — flag and gate, never silently approve:** any change to `aws_kms_key`/key policy/grant/alias, IAM roles/policies/`assume_role`, `aws_organizations_policy` (SCP), or trust relationships must be called out as a blocking-review item requiring a **named human approver** in Spacelift. A KMS key *destroy* is an automatic REJECT (encrypt-everything, prime directive #5 — the engine provides none; losing the key loses the data).
- **No public DB exposure via networking:** REJECT if the plan attaches a DB Service/Ingress/LB to a public subnet, flips `map_public_ip_on_launch`, or adds an internet gateway route reaching the DB tier (prime directive #4).
- **No click-ops drift (prime directive #6):** the plan must come from the GitOps/Terraform source of truth and run through Spacelift. If the plan is reconciling away a manual console/`kubectl` change (i.e. the human edit, not the code, is "correct"), STOP — fix the code, do not approve a plan that papers over click-ops.

If none of the above trip, the plan may still carry **non-blocking risks** (cost, in-place resource churn, replacements of stateless resources) — report those, but they do not by themselves force a REJECT.

## Steps

1. **Get the plan as JSON.** From the Spacelift run, export the proposed plan; or locally:
   ```bash
   tofu -chdir=terraform/environments plan -var-file=<geo-env>/terraform.tfvars -out=tfplan
   tofu -chdir=terraform/environments show -json tfplan > plan.json
   ```
   Do not run `apply`. This skill reads JSON only.
2. **Run the policy gates first (authoritative, machine-checked).** These encode prime directives #1 and #4 and are unit-tested ([`../../../policy/conftest/README.md`](../../../policy/conftest/README.md)):
   ```bash
   # residency — inject the geo allow-list, then test
   jq '. + {parameters: {allowed_regions: ["eu-central-1","eu-west-1"]}}' plan.json \
     | conftest test - --policy policy/conftest --namespace main

   # no-public-DB — no parameters needed
   conftest test plan.json --policy policy/conftest --namespace main
   ```
   **Any `conftest` deny ⇒ REJECT.** Record the exact deny message(s) verbatim in the output. (Conftest covers residency + no-public-DB only; the remaining safety checks below are not yet machine-gated, so you must perform them by hand.)
3. **Enumerate and classify every change.** Walk `resource_changes[]` and bucket each by action:
   ```bash
   jq -r '.resource_changes[] | "\(.change.actions|join(","))\t\(.type)\t\(.address)"' plan.json | sort
   ```
   - `create` → low risk by default (note new SGs/IAM/KMS for review).
   - `update` (in-place) → check *what* changed (`jq '.resource_changes[] | select(.address=="...") | .change.before, .change.after'`).
   - `delete` / `replace` (i.e. actions `["delete","create"]` or `["create","delete"]`) → **scrutinise**: is the target stateful (PVC/PV/StatefulSet/KMS/state bucket/backup bucket/registry table/EBS/snapshot)? If yes → blocking.
4. **Apply the manual safety checks** (the items above that conftest does not cover): stateful destroys, prod quorum/PDB, KMS/IAM/role/SCP changes, public DB exposure via subnet/LB, and click-ops drift. For each hit, capture the resource address and the specific reason.
5. **Map addresses to intent.** For each flagged change, resolve which module/stack it lives in (cell / eks / backup-dr / observability / landing-zone). A destroy in `backup-dr` or a KMS change in `landing-zone` is higher-blast-radius than a label tweak in `observability`. Confirm the change matches a *declared* intent (e.g. an `add-cell` PR should only **create**; a `retire-cell` PR may legitimately destroy that one cell's resources — anything beyond its scope is suspect).
6. **Build the per-change risk table** (address · action · risk `BLOCKING|HIGH|MEDIUM|LOW` · prime-directive / gotcha cited · one-line reason).
7. **Decide and emit the recommendation.** If any BLOCKING item exists → **REJECT** with the list of blockers and the remediation. If only HIGH/MEDIUM/LOW remain → **APPROVE (with conditions)** or **APPROVE**, listing required human sign-offs (e.g. a named approver for any KMS/IAM/SCP change). Never output APPROVE while a prime-directive violation stands.
8. **Handoff (no mutation here).** Post the summary on the PR / Spacelift run. The **actual approve + apply is the AWS-mutating step** and is **out of scope until after CTO sign-off**; even then it requires the **mandatory manual prod approver in Spacelift** ([ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md), prime directive #6). This skill stops at the recommendation.

## Verification

- `conftest test` on the plan JSON returns **0 failures** for both residency and no-public-DB (and you re-ran it after any plan regeneration).
- Every `delete`/`replace` action in `resource_changes[]` has been individually accounted for, and none targets a stateful resource (PVC/PV/StatefulSet/KMS/state bucket/backup bucket/registry/EBS/snapshot) unless the change is an explicitly-scoped teardown via [`retire-cell`](../retire-cell/SKILL.md) / [`deprovision-tenant`](../deprovision-tenant/SKILL.md).
- For `env=prod` cell stacks: the resulting `replicas` is ≥ 3 and the PDB with `minAvailable ≥ 2` is present and unchanged (or strengthened).
- No DB port (2480/2424/2434/5432/6379/7687) appears in any ingress with a public CIDR, and no DB Service/LB/subnet became public.
- The risk table covers **100%** of `resource_changes[]` (count matches `jq '.resource_changes | length' plan.json`), and the final line is an unambiguous **APPROVE** / **APPROVE (with conditions)** / **REJECT**.
- Output asserts no AWS mutation occurred (this was a read-only review).

## Rollback / if it goes wrong

- **This skill cannot break anything** — it only reads plan JSON. There is nothing to roll back. The safety value is in *catching* a bad plan before approval.
- **If you (or a gate) flagged BLOCKING:** do NOT approve. Send the plan back to the author with the blockers; the code must be fixed and a fresh plan produced and re-reviewed from step 1. Never hand-edit the plan or approve "just this once".
- **If a bad plan was already approved/applied** (review missed it or was bypassed): this is an incident — run [`incident-triage`](../incident-triage/SKILL.md). Specifically: a public DB port ⇒ revoke at the SG immediately; a destroyed PVC/snapshot/KMS key ⇒ DR/restore path ([`restore-tenant`](../restore-tenant/SKILL.md), EBS snapshots — remember restore REQUIRES the target DB to NOT exist and backups exclude the WAL, so expect data loss back to the last hot ZIP/snapshot); a quorum/PDB regression ⇒ restore replicas to 3 and the PDB via a corrective plan.
- **If conftest itself errors** (not a deny — a parse/policy error): do not interpret "no deny" as a pass. Fix the invocation (correct `--namespace`, valid JSON, allow-list injected) and re-run; treat an un-run gate as a blocker.

## Related

- [ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md) — Spacelift runner; OPA policy gates + **mandatory manual prod approval**; this skill complements the gates pre-approval.
- [`../../../policy/conftest`](../../../policy/conftest) — the machine gates: [`residency.rego`](../../../policy/conftest/residency.rego) (prime directive #1), [`no_public_db.rego`](../../../policy/conftest/no_public_db.rego) (prime directive #4), and [`README.md`](../../../policy/conftest/README.md) for how to run them.
- [`security-baseline-check`](../security-baseline-check/SKILL.md) — broader, point-in-time posture audit (complements this per-plan review).
- [`add-cell`](../add-cell/SKILL.md) / [`retire-cell`](../retire-cell/SKILL.md) / [`upgrade-arcadedb`](../upgrade-arcadedb/SKILL.md) — common change types whose plans you will review here.
- [ADR-0007](../../../docs/adr/0007-residency-enforcement-scp.md) — residency SCP (the runtime twin of the residency gate).
- Modules under review: [`../../../terraform/modules/cell`](../../../terraform/modules/cell), [`.../eks`](../../../terraform/modules/eks), [`.../backup-dr`](../../../terraform/modules/backup-dr), [`.../observability`](../../../terraform/modules/observability), [`../../../terraform/landing-zone`](../../../terraform/landing-zone).
