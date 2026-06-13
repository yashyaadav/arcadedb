---
name: upgrade-arcadedb
description: Upgrades an ArcadeDB cell (and the fleet) to a new version without dropping quorum, using a canary-first, replicas-before-leader rollout driven by an Argo Workflow with health gates. Use when applying any ArcadeDB version bump (security patch, minor, or major) to prod or non-prod cells.
---

# Upgrade ArcadeDB (quorum-preserving)

> What/when: a guided runbook to move one or more ArcadeDB cells to a higher version tag while keeping Raft quorum and per-tenant availability intact. Phase note: this is a DAY-2 runbook. The CTO package is NOT yet applied to AWS — every step that mutates AWS, EKS, or a running cluster (image rollout, snapshots, restores) is an APPROVAL GATE and is OUT OF SCOPE until after CTO sign-off and the relevant go-live phase. Dry-run and rehearse everything below on the canary first.

We own ArcadeDB upgrades end-to-end: there is **no ArcadeDB Operator** and the official Helm chart ships only a StatefulSet, so day-2 upgrade logic is ours to drive (see [ADR-0029 — Upgrade & rollback: canary cells + restore-based rollback](../../../docs/adr/0029-upgrade-rollback-restore-based.md)). The bare StatefulSet `RollingUpdate` strategy does NOT understand Raft, replication lag, or leader step-down, so we **never rely on it** for the DB tier — we orchestrate with an Argo Workflow that gates on health.

## Prerequisites

- `kubectl` context for the target cell's EKS cluster (correct **geo**: EU clusters in EU regions, US in US — never cross). Confirm with `kubectl config current-context`.
- `helm`, `argo` CLI, and access to the GitOps repo / Spacelift (Terraform) and Argo CD.
- The target ArcadeDB image tag, pulled and present in the **in-jurisdiction** ECR (EU image in EU ECR, US in US ECR — mirror, do not pull EU images through a US path; Directive #1).
- The release notes for the target version (and every intermediate version you are skipping over).
- The [restore-tenant](../restore-tenant/SKILL.md) skill on hand (rollback path) and a recent successful run of [security-baseline-check](../security-baseline-check/SKILL.md) as a baseline to compare against post-upgrade.
- Maintenance window approved; tenant comms sent if writes may briefly pause during leader step-down.

## Inputs

- `TARGET_TAG` — e.g. `26.4.x` (MUST be `>= 26.4.1`; Directive #2).
- `CELL` — the cell id to upgrade (e.g. `eu-cell-01`), plus its geo/region (`REGION`).
- `ROLLOUT_SCOPE` — one of `canary`, `single-cell`, `fleet`.
- `CURRENT_TAG` — the version currently running (record it; it is the rollback target).
- `ACCOUNT_ID`, `REGION` — placeholders; fill per geo at run time.
- Path to the Argo Workflow template: `../../../control-plane/` (upgrade workflow) — parameterized by `CELL`, `TARGET_TAG`.

## Safety checks (MUST pass before proceeding)

- **Version floor (Directive #2):** `TARGET_TAG` parses to `>= 26.4.1`. Abort otherwise. The upgrade is **forward-only** — plan to re-audit cross-DB isolation afterward (same directive).
- **Read the release notes first.** Confirm whether the target introduces an **on-disk format change** or a compat break. ArcadeDB has NO PITR and NO incremental backup — if the format changes, **downgrade is impossible** and rollback is restore-from-backup only. Note this explicitly in the change ticket.
- **Fresh, verified backup exists (Directive #5 + ArcadeDB backup gotchas):** take a NEW hot per-DB ZIP backup of every DB on the cell *immediately before* upgrade, and **verify it restores** (rehearsal on the canary). Remember: the ZIP **excludes the WAL**, there is no incremental and no PITR, and the backup target must be a **KMS-encrypted S3 bucket in the same jurisdiction** (no native S3 target — the control plane / job ships it). Supplement with a **fresh EBS snapshot** of each node's data volume (also KMS-encrypted, in-region).
- **Health is all green before you touch anything:** every node `/ready` returns HTTP 204, replication lag ~0 on all DBs, no under-replicated DBs, no pending Raft membership changes. Verify via the dashboards in `../../../terraform/modules/observability/`.
- **Quorum is protected (Directive #3):** prod cell = 3 nodes, one per AZ, `PDB minAvailable=2`. The rollout takes **exactly one node at a time** and **never drops below 2 healthy members**. If a non-prod cell is single-node, expect downtime and treat it as canary-class only — do not generalize single-node behavior to prod.
- **No public exposure (Directive #4):** the upgrade changes nothing about networking; confirm no DB port (2480/2424/2434/5432/6379/7687) is on a public subnet/LB before and after. Part of the post-upgrade `security-baseline-check`.
- **Residency (Directive #1):** image source, backups, snapshots, and DR pair all stay in-jurisdiction. No EU<->US data or image path at any step.
- **Sizing unchanged or re-checked (Directive #7):** if the new version changes default heap or `maxPageRAM`, re-verify pod mem limit `>= maxPageRAM + heap + overhead` before rollout, or you risk OOM-kill mid-upgrade (which would drop a member and threaten quorum).
- **No click-ops (Directive #6):** the new image tag lands via GitOps/Helm values change + Argo, **not** `kubectl set image`. Prod apply requires manual approval in Spacelift/Argo.
- **Mixed-version Raft is supported between `CURRENT_TAG` and `TARGET_TAG`.** Confirm in release notes that an N / N+1 mixed cluster can form quorum during the rolling window. If not supported, this becomes an offline migration — STOP and escalate.

## Steps

> Approval gates are marked **[APPROVAL]**. AWS/cluster-mutating steps are marked **[MUTATES]**. Until CTO sign-off / phase go-live, run only the read-only and dry-run portions.

1. **Pin scope and order.** Always roll out in this order regardless of `ROLLOUT_SCOPE`: **canary cell -> one prod cell -> rest of fleet**. Do not start a prod cell until the canary has been upgraded AND its rollback rehearsed (step 9). Do not start the fleet until the first prod cell has soaked (step 8) clean for the agreed window.

2. **Pre-flight (read-only).** Re-run the Safety checks programmatically: poll `/ready` (expect 204) on each pod, query replication status per DB, confirm `TARGET_TAG >= 26.4.1`, and confirm the release-notes findings (format/compat) are recorded in the ticket.

3. **[MUTATES] Take the fresh backup + snapshot.** Trigger a hot per-DB ZIP backup of every DB on `CELL` to the in-region KMS-encrypted S3 bucket, then trigger a KMS-encrypted EBS snapshot of each node's data volume. Wait for both to complete and record their ids. (Backup mechanics + verification live in [restore-tenant](../restore-tenant/SKILL.md).)

4. **[APPROVAL] Land the image tag via GitOps.** Open a PR bumping `image.tag` to `TARGET_TAG` in `../../../helm/arcadedb/values.yaml` (scoped to `CELL`), and confirm `updateStrategy` keeps the StatefulSet on `OnDelete`-style controlled rollout (we drive deletes via Argo, not the controller). Merge requires review; the prod sync requires **manual approval** in Argo CD / Spacelift (Directive #6).

5. **[MUTATES] Run the upgrade Argo Workflow** (`../../../control-plane/` upgrade template), parameterized with `CELL` and `TARGET_TAG`. Do NOT trigger a bare StatefulSet rolling update. The workflow, per cell, performs the gated sequence in steps 6-7. Watch with `argo watch <workflow>`.

6. **Upgrade REPLICAS FIRST, one at a time.** For each replica (never the leader yet):
   a. Confirm at least 2 members healthy before proceeding (PDB will also block, but gate explicitly).
   b. Delete the replica pod so it restarts on `TARGET_TAG`.
   c. **Health gate — wait for ALL of:** the new pod is `Ready`, `/ready` returns 204, the node has **re-joined Raft**, and **replication lag returns to 0** on every DB it hosts. The workflow blocks here; do not advance on a timer.
   d. Repeat for the next replica only after (c) fully passes. Never have more than one replica out at once (keeps you at >=2 healthy; Directive #3).

7. **Upgrade the LEADER LAST, with graceful step-down.**
   a. Trigger a **graceful leader step-down** so an already-upgraded replica is elected leader (writes go to the leader; reads fan to replicas — a clean handoff minimizes the write pause).
   b. Confirm the new leader is on `TARGET_TAG` and serving writes.
   c. Delete the old-leader pod (now a replica); apply the same health gate as 6c (re-join + lag 0 + /ready 204).
   d. The cell is now homogeneous on `TARGET_TAG`. The window where mixed-version Raft existed should now be closed.

8. **Soak.** Let the cell run on `TARGET_TAG` for the agreed soak window. Watch error rates, replication lag, leader stability (no election storms), pod restarts, and OOM events (Directive #7). Tenant write/read smoke tests via the retrieval proxy.

9. **[MUTATES] Rehearse rollback on the canary (canary scope only, before any prod).** Prove the restore-from-backup path actually works on `TARGET_TAG`'s on-disk format vs. the backup you took: provision a scratch DB name, restore the pre-upgrade ZIP into it (RESTORE REQUIRES THE TARGET DB TO NOT EXIST — restore to a NEW name, never over a live DB), and verify data integrity. This is the only proof your rollback is real. See [restore-tenant](../restore-tenant/SKILL.md).

10. **[MUTATES] RE-AUDIT cross-DB isolation (Directive #2).** Run [security-baseline-check](../security-baseline-check/SKILL.md) against the upgraded cell. Confirm tenants cannot see each other's DBs, no DB port is publicly reachable (Directive #4), and the engine's lack of native quotas is still backstopped by the control-plane caps + retrieval-proxy per-tenant limits/kill-switch. Diff against the pre-upgrade baseline.

11. **Promote.** Only after canary is clean + rollback rehearsed: repeat steps 2-8,10 for **one prod cell**; soak; then **fan out to the fleet** cell-by-cell (each cell independently gated — never two prod cells in-flight together unless explicitly approved). Update the registry/version inventory (`../../../control-plane/registry/schema.ts`) to reflect the new running version per cell.

## Verification

- Every pod on the cell reports `TARGET_TAG` (`kubectl get pods -o jsonpath` on the image) and `/ready` returns 204.
- Raft shows a single stable leader, 3 voting members (prod), no pending membership changes, **replication lag 0** on all DBs.
- No OOM-kills or crash-loops during/after rollout; pod restart counts stable post-soak (Directive #7).
- Tenant smoke tests pass through the retrieval proxy (write to leader, read from a replica).
- `security-baseline-check` re-audit passes and **matches or improves** the pre-upgrade baseline: cross-DB isolation intact, no public DB ports (Directives #2, #4).
- Registry/inventory updated; change ticket records `CURRENT_TAG`, `TARGET_TAG`, backup ids, snapshot ids, and the format-change finding.

## Rollback / if it goes wrong

- **Upgrade is forward-only.** If the target introduced an on-disk format change, you **cannot downgrade in place** — rollback = **restore-from-backup to the prior version**.
  1. **[APPROVAL][MUTATES]** Re-pin Helm `image.tag` back to `CURRENT_TAG` via GitOps (approved sync).
  2. **[MUTATES]** Provision fresh DB instances on `CURRENT_TAG` and **restore the pre-upgrade ZIP backups into NEW (non-existent) DB names** — RESTORE REQUIRES THE TARGET DB TO NOT EXIST; never restore over a live/existing DB. Use [restore-tenant](../restore-tenant/SKILL.md).
  3. Note the data delta: the ZIP **excludes the WAL** and there is **no PITR**, so any writes after the backup are lost. Quantify and communicate the RPO gap to affected tenants.
- **A replica fails its health gate (no re-join / lag won't reach 0):** the Argo Workflow halts (it does not advance). Do NOT pull a second member — you would drop below 2 healthy (Directive #3). Investigate the single stuck member; if unrecoverable, restore that member from its EBS snapshot or re-seed it from the leader.
- **Leader step-down stalls or election storms:** pause the workflow, stabilize the current leader, and only resume once a single stable leader holds. Never delete a pod while the cell has no leader.
- **Mixed-version incompatibility surfaces mid-roll** (members won't form quorum across N/N+1): stop, roll the out-of-version member back to `CURRENT_TAG` if no format change occurred, else go to restore-from-backup. Escalate.
- **OOM-kill during rollout (Directive #7):** raise pod mem limit to satisfy `maxPageRAM + heap + overhead` via GitOps before retrying the affected member.

## Related

- [ADR-0029 — Upgrade & rollback: canary cells + restore-based rollback](../../../docs/adr/0029-upgrade-rollback-restore-based.md) — no Operator, quorum-preserving rolling upgrade, restore-based rollback
- [ADR-0012 — Version floor: ArcadeDB ≥ 26.4.1, pinned by digest](../../../docs/adr/0012-version-floor-26-4-1.md) — version floor + mandatory cross-DB isolation re-audit after every upgrade
- [restore-tenant](../restore-tenant/SKILL.md) — backup/restore mechanics and rollback path
- [security-baseline-check](../security-baseline-check/SKILL.md) — post-upgrade cross-DB isolation + public-exposure re-audit
- Helm chart values: [../../../helm/arcadedb/values.yaml](../../../helm/arcadedb/values.yaml)
- Cell / EKS / observability modules: [../../../terraform/modules/cell/](../../../terraform/modules/cell/), [../../../terraform/modules/eks/](../../../terraform/modules/eks/), [../../../terraform/modules/observability/](../../../terraform/modules/observability/)
- Backup/DR module: [../../../terraform/modules/backup-dr/](../../../terraform/modules/backup-dr/)
- Cell version inventory: [../../../control-plane/registry/schema.ts](../../../control-plane/registry/schema.ts)
- Architecture & assumptions: [../../../docs/architecture.md](../../../docs/architecture.md), [../../../docs/assumptions.md](../../../docs/assumptions.md)
