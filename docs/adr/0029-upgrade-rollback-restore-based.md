# ADR-0029 — Upgrade & rollback: canary cells + restore-based rollback

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Upgrade ArcadeDB via a **quorum-preserving rolling process** (replicas first, leader last) rolled out **canary cell → one prod cell → fleet**; treat upgrades as **forward-only** with **restore-from-backup to the prior version** as the only true rollback. |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead, Security |
| **Type** | ⭐ recommended (overridable) |

## Context

There is **no ArcadeDB Operator** — we own day-2 upgrade logic (F6). Raft needs quorum maintained throughout (F1, prime directive #3). Critically, **there is no PITR and an on-disk format change can make a downgrade impossible** (F5) — so a "roll back the image" strategy is unsafe. Every upgrade must also **re-audit cross-DB isolation** (F3).

## Assumptions it rests on

- F1/F3/F5/F6 (Raft, CVE re-audit, no PITR, no operator), [ADR-0012](0012-version-floor-26-4-1.md) (pinned versions), [ADR-0015](0015-backup-cronjob-sidecar.md) (verified backups exist).

## Options considered

### Option A — Canary + quorum-preserving rolling upgrade + restore-based rollback (chosen)
- **Pros:** never drops below quorum (replicas upgraded one-at-a-time, wait for re-join + lag→0 + `/ready`; leader last via graceful step-down); **canary → one cell → fleet** limits blast radius; a **verified fresh backup before every upgrade** + a **rehearsed restore-based rollback** is the only rollback that survives a format change (F5); post-upgrade isolation re-audit (F3); automatable as an Argo Workflow with health gates.
- **Cons:** restore-based rollback is slow (it's a restore) → upgrades must be cautious + well-tested; we build + maintain the upgrade workflow ourselves; canary adds time to fleet-wide rollouts.

### Option B — Forward-only, no rollback plan
- **Pros:** simplest; fastest rollouts.
- **Cons:** a bad upgrade with a format change is **unrecoverable** (R2: Low × High) — unacceptable for a multi-tenant data layer.

### Option C — Rely on default StatefulSet rollout
- **Pros:** least code.
- **Cons:** doesn't guarantee quorum-aware ordering (replicas-then-leader), health gating, mixed-version checks, or the pre-upgrade backup + isolation re-audit; risks bouncing quorum.

## Decision

**Quorum-preserving rolling upgrade (replicas first one-at-a-time, leader last), rolled out canary cell → one prod cell → fleet, automated as an Argo Workflow with health gates; a verified fresh backup before every upgrade; restore-from-backup to the prior version as the rollback; post-upgrade cross-DB isolation re-audit.** Read release notes for format/compat changes first. Surfaced as the `upgrade-arcadedb` skill.

## Reasoning — why this beats the alternatives

F5 (no PITR + possible format change) makes **image-rollback unsafe**, so the only rollback that always works is **restore-to-prior-version** — which in turn *requires* a verified pre-upgrade backup as a hard gate. F1/#3 make quorum-aware ordering mandatory, and F6 means we can't lean on an operator, so we automate the safe ordering + health gates ourselves. Canary staging bounds the blast radius of the residual risk. Default StatefulSet rollout and forward-only both omit one or more of these non-negotiables.

## Consequences

- **Positive:** quorum never broken during upgrades; bounded blast radius; a rollback that survives format changes; isolation re-verified each time.
- **Negative / costs:** we build + maintain the upgrade workflow; rollback is slow (restore) so upgrades must be cautious; canary adds rollout time; pre-upgrade backup is mandatory (gate).
- **Follow-ups:** the Argo upgrade workflow + health gates; the `upgrade-arcadedb` runbook (PDB check, replicas-first, leader-last, re-audit); rehearse restore-based rollback on the canary (verification matrix); release-note review step.

## Review-trigger

ArcadeDB ships an Operator or PITR / safe downgrade; a release introduces an on-disk format change (raises the rollback-rehearsal bar); or canary findings change the rollout policy.
