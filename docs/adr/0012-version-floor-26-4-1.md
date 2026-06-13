# ADR-0012 — Version floor: ArcadeDB ≥ 26.4.1, pinned by digest

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Pin ArcadeDB to **≥ 26.4.1**, deployed by **immutable image digest** mirrored into ECR; **re-audit cross-DB isolation after every upgrade**. |
| **Date** | 2026-06-13 |
| **Deciders** | Security, Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

Two load-bearing facts force a version floor: (F3) a **cross-DB isolation CVE at CVSS 9.0 fixed in 26.4.1** — below this, tenant isolation cannot be trusted at all; and (F1) **Raft HA is GA from 26.4.1**. Running anything older breaks both the security model (tenant isolation) and the availability model (HA). "Latest, unpinned" is also unsafe — an uncontrolled bump could introduce an on-disk format change or a regression with no rehearsed rollback (no PITR, F5).

## Assumptions it rests on

- F3/F1 (the CVE + Raft GA), A5 (leader-forwarding on the pinned version), A17 (the `/prometheus` MIME bug on the pinned version).

## Options considered

### Option A — Pin ≥ 26.4.1 by digest, controlled bumps (chosen)
- **Pros:** closes the CVSS-9.0 isolation CVE; gets GA Raft HA; digest pinning makes deployments reproducible + tamper-evident; controlled bumps let us read release notes, rehearse restore-based rollback, and re-audit isolation each time.
- **Cons:** we must actively track + test new releases; digest mirroring adds a CI step; we forgo "newest features immediately".

### Option B — Older version
- **Pros:** none material.
- **Cons:** **leaves the CVSS-9.0 isolation CVE open** and lacks GA Raft HA — disqualified.

### Option C — Latest, unpinned (`:latest`)
- **Pros:** always newest features/fixes.
- **Cons:** non-reproducible; an uncontrolled bump risks an on-disk format change with **no safe rollback** (F5) and an un-audited isolation surface (F3). Unacceptable for a multi-tenant DB.

## Decision

**Floor = 26.4.1; pin a specific `>=26.4.1` tag by digest, mirrored to per-region ECR; bumps are deliberate, release-noted, canary-first, and followed by a cross-DB isolation re-audit** ([ADR-0029](0029-upgrade-rollback-restore-based.md), [upgrade-arcadedb] skill). Hooks **block** edits setting the image below the floor.

## Reasoning — why this beats the alternatives

The CVE (F3) makes < 26.4.1 a non-starter for a multi-tenant platform, and the lack of PITR (F5) makes uncontrolled "latest" dangerous. Digest pinning + controlled, canary-first bumps is the only option that satisfies both the security floor and the reproducibility/rollback discipline the data layer requires.

## Consequences

- **Positive:** trusted isolation baseline + GA HA; reproducible, tamper-evident deployments; disciplined upgrade path.
- **Negative / costs:** active release-tracking + digest mirroring; re-audit work after every upgrade; deliberate (slower) feature adoption.
- **Follow-ups:** ECR mirror + cosign signing + digest in Helm values; the `<26.4.1` Edit/Write hook; post-upgrade isolation re-audit + the continuous isolation probe ([ADR-0027](0027-runtime-tenant-governance.md)).

## Review-trigger

A new ArcadeDB security advisory; a release with relevant fixes/features; or a format-change note in release notes (raises the rollback-rehearsal bar).
