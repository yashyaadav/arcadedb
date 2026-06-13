# `.claude/` — the AI operating model (a first-class hand-over asset)

This directory **ships in the repo and is owned by the cloud-ops team** (HLD §3.5).
It lets operators run the platform with the same AI assistance and the same
guard-rails the platform was built with.

```
.claude/
├── settings.json     # deterministic guard-rail hooks + a safe-command allowlist
├── active-context    # operator-set active geo/env (e.g. "eu-prod"); read by hooks
└── skills/           # one self-contained SKILL.md per operational runbook (1:1 map)
```

## Guard-rail hooks (`settings.json` → `scripts/hooks/`)

| Event | Script | Enforces |
|---|---|---|
| PreToolUse · Bash | `guard-bash.sh` | no `apply`/`destroy`; no `kubectl delete` of stateful/quorum resources; no `aws` in an out-of-geo region; gitleaks before commit |
| PreToolUse · Edit/Write | `guard-edit.sh` | (config files only) ArcadeDB ≥ 26.4.1; no public DB port; prod replicas ≥ 3; PDB intact; no out-of-geo region literal |
| PostToolUse · Edit/Write | `post-tf.sh`, `post-helm.sh`, `post-controlplane.sh` | auto-fmt + validate + tflint / helm lint + kubeconform / ASL-JSON + typecheck |
| UserPromptSubmit | `inject-context.sh` | injects active geo/env + a prime-directive reminder |
| SessionStart | `session-start.sh` | loads the cell catalog / environment context |

These are **deterministic** — the harness runs them regardless of who is at the
keyboard. They make residency, quorum, version-floor, "no public DB", and
secret-in-diff violations hard to commit. That is what makes the hand-over safe.

## Skills (`skills/<name>/SKILL.md`)

Each runbook (§7) has a matching skill so ops execute procedures AI-assisted and
self-serve (no tribal knowledge). Invoke as `/<skill-name>`. Every `SKILL.md` is
self-contained: **prerequisites · inputs · safety checks · steps · verification**.

Run-time (day-2): `provision-tenant`, `deprovision-tenant`, `add-cell`,
`retire-cell`, `upgrade-arcadedb`, `restore-tenant`, `dr-drill`, `rotate-secrets`,
`cell-capacity-report`, `incident-triage`, `migrate-schema`, `tenant-usage-report`,
`tenant-erasure`. Build-time: `review-terraform-plan`, `new-adr`,
`security-baseline-check`.

See [`docs/runbooks/claude-code-operations.md`](../docs/runbooks/claude-code-operations.md)
for the full operating guide (install, permissions, which skill ↔ which runbook,
what each hook enforces, and how to safely extend a skill/hook).

## Setting the active context

```bash
echo "eu-prod" > .claude/active-context   # operators set this per working session
```
