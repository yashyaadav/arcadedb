# Operating this platform with Claude Code

> The cloud-ops team's guide to running the ArcadeDB KB platform **with Claude
> Code**. The `.claude/` directory (hooks, skills, settings) is a **first-class
> hand-over asset you own and run** (HLD §3.5). This guide covers: install + run,
> the permissions model, which skill maps to which runbook, what each hook
> enforces and why, and how to safely extend a skill or hook.

## 1. Why AI-assisted ops here

ArcadeDB has sharp edges (set-once root, restore-into-a-non-existent-DB, no
per-DB quotas, quorum-fragile upgrades, residency). The AI operating model turns
each of those into a **guided, guard-railed procedure**: skills carry the safety
checks, and hooks **deterministically block** the dangerous mistakes regardless
of who is at the keyboard. You move fast *and* safely.

## 2. Install & run

```bash
# 1. Install Claude Code (CLI) — see your internal onboarding.
# 2. Clone the platform repo and open it:
git clone <repo> && cd arcadedb
# 3. Authenticate to AWS via SSO (IAM Identity Center) — no IAM users:
aws sso login --profile kb-<geo>-<env>
# 4. Set your active working context (drives the hooks' context injection):
echo "eu-prod" > .claude/active-context
# 5. Start Claude Code in the repo. SessionStart loads the cell catalog;
#    UserPromptSubmit injects the active geo/env + prime-directive reminder.
```

Claude Code reads the **`CLAUDE.md` hierarchy** (root + `terraform/`, `helm/`,
`control-plane/`, `docs/`) as project memory, the **skills** in
`.claude/skills/`, and the **hooks** in `.claude/settings.json`.

## 3. Permissions model

- **Identity:** IAM Identity Center (SSO) permission sets — `PlatformReadOnly`
  (default), `PlatformAdmin`, `BreakGlass` (alarmed). **No IAM users.** Skills
  reference SSO roles + repo-relative scripts, never a builder's laptop state.
- **`.claude/settings.json` allowlist:** common **read-only** commands
  (`tofu validate`, `helm lint`, `kubeconform`, `conftest`, `git status/diff/log`,
  `kubectl get/describe`) run without a prompt. Mutating commands prompt.
- **`deny` list:** `terraform/tofu apply|destroy` and reads of state/secrets
  (`*.tfstate`, `.env`, `*.pem`, `*.key`) are denied outright.
- **Apply path:** all `apply` goes through **Spacelift** with **mandatory manual
  approval on prod / any geo-prod apply** (ADR-0020). Claude never applies directly.

## 4. Runbook ⇄ skill map (1:1)

Invoke a skill with `/<skill-name>`. Each `SKILL.md` is self-contained
(prerequisites · inputs · safety checks · steps · verification · rollback).

| Runbook (HLD §7) | Skill | What it guards |
|---|---|---|
| Provision tenant | [`/provision-tenant`](../../.claude/skills/provision-tenant/SKILL.md) | geo assertion, least-priv user, indexes, secret, backup, audit, idempotency |
| Deprovision tenant | [`/deprovision-tenant`](../../.claude/skills/deprovision-tenant/SKILL.md) | final backup, legal-hold check, clean reversal |
| Add a cell | [`/add-cell`](../../.claude/skills/add-cell/SKILL.md) | additive + zero-downtime; 3-AZ, sizing, in-geo, approval |
| Retire a cell | [`/retire-cell`](../../.claude/skills/retire-cell/SKILL.md) | empty-first, no quorum impact, backups retained |
| Upgrade ArcadeDB | [`/upgrade-arcadedb`](../../.claude/skills/upgrade-arcadedb/SKILL.md) | replicas-first/leader-last, never <2 healthy, post-upgrade isolation re-audit, restore-based rollback |
| Restore a tenant | [`/restore-tenant`](../../.claude/skills/restore-tenant/SKILL.md) | **target DB must not exist**, index rebuild, in-geo bucket |
| DR game-day | [`/dr-drill`](../../.claude/skills/dr-drill/SKILL.md) | in-jurisdiction failover, measure RPO/RTO, fail back |
| Rotate secrets | [`/rotate-secrets`](../../.claude/skills/rotate-secrets/SKILL.md) | tenant rotation; **set-once root** = new admin user |
| Capacity report | [`/cell-capacity-report`](../../.claude/skills/cell-capacity-report/SKILL.md) | caps (DBs / maxPageRAM / disk), add-cell vs rebalance |
| Incident triage | [`/incident-triage`](../../.claude/skills/incident-triage/SKILL.md) | quorum/leader/OOM/disk/AZ/region + per-tenant kill-switch |
| Schema migration | [`/migrate-schema`](../../.claude/skills/migrate-schema/SKILL.md) | dry-run→canary→fleet, batched, per-tenant rollback |
| Usage report | [`/tenant-usage-report`](../../.claude/skills/tenant-usage-report/SKILL.md) | per-tenant metering + noisy-neighbour view |
| Tenant erasure (RTBF) | [`/tenant-erasure`](../../.claude/skills/tenant-erasure/SKILL.md) | drop / crypto-shred / record-purge + deletion evidence |
| Review TF plan | [`/review-terraform-plan`](../../.claude/skills/review-terraform-plan/SKILL.md) | flag public DB SG, stateful destroy, residency, KMS/IAM |
| New ADR | [`/new-adr`](../../.claude/skills/new-adr/SKILL.md) | every decision gets an ADR with reasoning |
| Security baseline | [`/security-baseline-check`](../../.claude/skills/security-baseline-check/SKILL.md) | SCP, encryption, no public DB, audit layers, signed image |

## 5. What each hook enforces (and why)

Hooks are **deterministic** — the harness runs them, not the model. Sources are
in [`scripts/hooks/`](../../scripts/hooks/); wiring is in
[`.claude/settings.json`](../../.claude/settings.json).

| Hook (event) | Enforces | Why |
|---|---|---|
| `guard-bash.sh` (PreToolUse·Bash) | blocks `apply`/`destroy`; `kubectl delete` of statefulset/pvc/pdb; `aws` in an out-of-geo region; gitleaks before commit | prevents the irreversible / residency / quorum / secret mistakes |
| `guard-edit.sh` (PreToolUse·Edit/Write, **config files only**) | blocks ArcadeDB `< 26.4.1`/`:latest`; a DB port to `0.0.0.0/0`; prod `replicas < 3`; PDB removal; out-of-geo region literal | makes prime-directive violations hard to commit |
| `post-tf.sh` (PostToolUse) | auto-fmt + `init -backend=false` + `validate` + `tflint` the touched module | fast feedback; keeps the tree green |
| `post-helm.sh` (PostToolUse) | `helm lint` + `kubeconform` on chart changes | catches invalid manifests |
| `post-controlplane.sh` (PostToolUse) | ASL-JSON validity + (Phase 2) `tsc` | keeps the control-plane contracts valid |
| `inject-context.sh` (UserPromptSubmit) | injects active geo/env + prime-directive reminder | keeps every turn residency/quorum-aware |
| `session-start.sh` (SessionStart) | loads the cell catalog / environments | situational awareness |

**Proving the guards (handover acceptance):** try to make each forbidden change
and confirm it is blocked — image `< 26.4.1`, `replicas < 3` on a prod cell, a DB
SG to `0.0.0.0/0`, an out-of-geo region literal, and a secret in a diff. (See HLD
§12 verification matrix; the hooks were unit-tested for block/allow at build.)

## 6. Safely extending a skill or hook

- **Add/edit a skill:** create `.claude/skills/<name>/SKILL.md` with the standard
  structure (frontmatter `name` + `description`; sections: Prerequisites, Inputs,
  Safety checks, Steps, Verification, Rollback, Related). Use `/new-adr` if the
  change encodes a decision. Keep it self-contained.
- **Add/edit a hook:** edit a script in `scripts/hooks/` and wire it in
  `.claude/settings.json`. **Test it both ways** (a case it must block → exit 2;
  a case it must allow → exit 0) before committing — the existing scripts are the
  pattern. A hook that over-blocks is as harmful as one that under-blocks.
- **Never** weaken a prime-directive guard to unblock yourself — fix the
  underlying change instead. If a guard is wrong, fix the guard *and* add a test.

## 7. Enablement / acceptance (Phase 4 sign-off)

The hand-over is complete when the ops team, **unaided and using the skills**:
runs a real `/provision-tenant`, a `/restore-tenant`, and a partial `/dr-drill`;
edits one skill or hook themselves; and confirms the hooks block the
prime-directive violations. See HLD §11 (Phase 4) and §12.

## 8. Optional standing automation

Scheduled Claude agents for routine, read-only checks the ops team can adopt:
nightly `/cell-capacity-report`, a backup-age audit, and a weekly
`/security-baseline-check`. Keep these read-only; anything mutating stays
interactive with the approval gates.
