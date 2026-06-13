---
name: new-adr
description: Scaffold a new Architecture Decision Record from the repo template, fill every section (incl. Reasoning + Review-trigger), and wire it into the ADR index and assumptions log. Use whenever you make ANY design/architecture/ops choice in this repo — the enforced rule is "no decision lands without an ADR stating its reasoning."
---

# Scaffold a new ADR

> Create a new Architecture Decision Record so a choice is captured with its reasoning, alternatives, and review-trigger, then link it into the HLD index and the assumptions log. **Phase note:** this is a **BUILD-TIME, docs-only** skill — it edits files in `docs/` and creates no AWS/cluster resources, so it is in scope in every phase (including pre-CTO-sign-off). It mutates nothing outside the repo and needs no approval gate.

## Prerequisites

- Repo write access on a feature branch (these are docs changes; commit them with the change they justify — the ADR and the code/IaC land together).
- You have read the directory rules in [`../../../docs/CLAUDE.md`](../../../docs/CLAUDE.md): **no decision lands without an ADR that states its reasoning, and no assumption stands without a `docs/assumptions.md` entry** (a CLAUDE.md convention **and** a CI check).
- Familiarity with the template: [`../../../docs/adr/0000-template.md`](../../../docs/adr/0000-template.md).
- You know which [prime directives / ArcadeDB facts (F1–F7)](../../../docs/architecture.md) and which [assumptions (A1–A17)](../../../docs/assumptions.md) the decision touches.

## Inputs

| Input | Example | Notes |
|---|---|---|
| `title` | `External vector store fallback` | The decision in a few words. Kebab-cased for the filename. |
| `kebab_title` | `external-vector-store-fallback` | Derived from `title`: lowercase, words joined by `-`, no punctuation. |
| `status` | `Proposed` \| `Accepted` \| `Superseded by ADR-NNNN` \| `Deprecated` | New ADRs are usually `Proposed` until reviewed, then `Accepted`. |
| `type` | `✅ decided by the business` \| `⭐ recommended (overridable)` | Use ✅ only for business-confirmed choices; default to ⭐. |
| `decision` | one line | The choice made, unambiguous, with scope (e.g. "for prod cells only"). |
| `deciders` | roles | Roles not names where possible (e.g. "Platform owner, Security"). |
| `assumption_ids` | `A2, A6` | The `assumptions.md` IDs this rests on. Add a NEW one there first if it doesn't exist. |
| `superseded_target` | `ADR-0024` | Only if this ADR replaces an existing decision (see Safety checks). |

## Safety checks (MUST pass before proceeding)

- **The enforced repo rule ([`docs/CLAUDE.md`](../../../docs/CLAUDE.md)):** no decision lands without an ADR that states its reasoning. If you are making a choice anywhere in this repo and there is no ADR for it, you MUST create one with this skill **in the same change** — not later. CI checks for it.
- **Next free number, no collision:** the new `NNNN` must be exactly `max(existing) + 1`, zero-padded to 4 digits, and the `NNNN-<kebab-title>.md` filename must not already exist. ADR numbers are never reused (even for retired/superseded ADRs).
- **Never edit a decided ADR's decision (immutability):** a `0000-template.md` rule — if you are changing or reversing an already-`Accepted` ADR, do NOT edit it. Create a NEW ADR, set the old one's **Status** to `Superseded by ADR-NNNN`, and set this new ADR's Context to reference it. The old ADR stays as the historical record.
- **Every section filled — especially the load-bearing ones:** Context · Assumptions it rests on · Options considered (with pros/cons) · Decision · **Reasoning (why this beats the alternatives)** · Consequences · Status · **Review-trigger**. An ADR with an empty Reasoning or Review-trigger is incomplete and will fail review/CI. Tie Context + Reasoning back to the relevant prime directives and ArcadeDB facts (F1–F7) where they bound the choice (e.g. residency for a region choice, F5 "no PITR / restore requires the DB not to exist" for a backup/restore choice).
- **Assumptions are real and linked both ways:** every ID in "Assumptions it rests on" must exist in [`assumptions.md`](../../../docs/assumptions.md). If the decision rests on a NEW assumption, add a row to the assumptions register FIRST (with: assumption · why we chose it · impact if wrong · confidence · validation owner/when · linked ADR), then reference its ID here. The link is bidirectional — the ADR lists the assumption, the assumption row lists the ADR.
- **Index stays in sync:** the [ADR index in `architecture.md` §9](../../../docs/architecture.md#9-decision-record-index-reasoning-lives-in-the-adrs) must get a new row in the same change. A diagram or index that lies is worse than none ([`docs/CLAUDE.md`](../../../docs/CLAUDE.md)).
- **Docs-only, no infra:** this skill must touch ONLY files under `docs/`. If your diff creates or mutates Terraform/Helm/control-plane resources, that is a different skill — STOP and split the change (the ADR documents the decision; the IaC implements it).

## Steps

1. **Pick the next free number.** List the ADR directory and find the highest `NNNN`:
   `ls ../../../docs/adr/ | grep -E '^[0-9]{4}-' | sort | tail -1`
   The new number is that value `+ 1`, zero-padded to 4 (e.g. last is `0029-...` → new is `0030`). Confirm `../../../docs/adr/NNNN-<kebab-title>.md` does NOT already exist.
2. **Copy the template** to the new file (do not author from scratch — preserve the section structure):
   `cp ../../../docs/adr/0000-template.md ../../../docs/adr/NNNN-<kebab-title>.md`
3. **Fill the header table:** Status, Decision (one line), Date (today, absolute — `2026-06-13` format, never a relative date), Deciders (roles), Type (✅/⭐). Remove the template's "How to use" callout block (lines about copying/filling) — it belongs only in `0000-template.md`.
4. **Fill `## Context`** — the forcing function + the constraints that bound the choice (residency, quorum, sizing, hand-over, ArcadeDB engine limits). Cite the relevant prime directives and facts F1–F7.
5. **Fill `## Assumptions it rests on`** — the `assumptions.md` IDs. If a NEW assumption is needed, add it to [`assumptions.md`](../../../docs/assumptions.md) first (see step 9), then list its ID here.
6. **Fill `## Options considered`** — at least two real options, each with **Pros** and **Cons**; include the "do nothing / status quo" option where meaningful; mark which was chosen/rejected.
7. **Fill `## Decision`** (unambiguous, scoped), then **`## Reasoning — why this beats the alternatives`** — the heart of the ADR: why, given the Context + Assumptions, this option wins over the rejected ones. Tie back to F1–F7 / prime directives.
8. **Fill `## Consequences`** (Positive · Negative/costs · Follow-ups/what this obliges us to build) and **`## Review-trigger`** (the concrete signal — a metric threshold, version bump, cost line, invalidated assumption, or date — that should make us revisit). Never leave Reasoning or Review-trigger empty.
9. **Link assumptions both ways.** For each assumption the ADR rests on, ensure its row in [`../../../docs/assumptions.md`](../../../docs/assumptions.md) lists this ADR in its **Links** column. If you added a new assumption, complete every column (why / impact if wrong / confidence / validation owner+when) and add it to the **Validation milestones** table; add a **Change log** entry at the bottom.
10. **Add a row to the ADR index** in [`../../../docs/architecture.md` §9](../../../docs/architecture.md#9-decision-record-index-reasoning-lives-in-the-adrs), matching the existing table columns: `| [NNNN](adr/NNNN-<kebab-title>.md) | <decision> | <✅/⭐ choice> | <main alternative> |`. Keep rows in numeric order.
11. **If superseding:** open the superseded ADR, set its **Status** to `Superseded by ADR-NNNN`, and leave its decision/reasoning intact (immutable history).
12. **Self-review then commit** the ADR + the `architecture.md` and `assumptions.md` edits **together with the change they justify** (same branch/PR).

## Verification

- **File + naming:** `../../../docs/adr/NNNN-<kebab-title>.md` exists, `NNNN` is unique and is `max+1`, kebab title matches the H1 (`# ADR-NNNN — <Title>`).
- **No empty sections:** grep the file for each required heading and confirm each has content — especially **Reasoning** and **Review-trigger**:
  `grep -n '^## ' ../../../docs/adr/NNNN-<kebab-title>.md` should list Context, Assumptions it rests on, Options considered, Decision, Reasoning, Consequences, Review-trigger.
- **Index row present:** the new `[NNNN](...)` row appears in `architecture.md` §9, in order, with all four columns.
- **Assumption links resolve both ways:** every `A#` cited in the ADR exists in `assumptions.md`, and each of those rows' Links column references this ADR.
- **No dangling links:** every relative link in the new ADR resolves (template uses `../` from `docs/adr/`).
- **CI green:** the "no decision without an ADR / no assumption without an entry" CI check (per [`docs/CLAUDE.md`](../../../docs/CLAUDE.md)) passes on the branch.

## Rollback / if it goes wrong

- This is docs-only and reversible with git — nothing in AWS or the cluster is touched.
- **Wrong number / collision:** `git rm` the new file, delete the index row, redo step 1. Do not renumber an already-merged ADR (numbers are stable); supersede instead.
- **Accidentally edited a decided ADR's decision:** `git checkout -- ../../../docs/adr/<that-file>.md` to restore it, then capture the change as a NEW superseding ADR.
- **Index/assumptions drift:** if `architecture.md` §9 or `assumptions.md` got out of sync, fix them in the same PR — never merge an ADR without its index row and assumption links (CI will block it anyway).

## Related

- [`../../../docs/adr/0000-template.md`](../../../docs/adr/0000-template.md) — the template this skill copies and fills.
- [`../../../docs/CLAUDE.md`](../../../docs/CLAUDE.md) — the enforced ADR/assumptions rules and required sections.
- [`../../../docs/assumptions.md`](../../../docs/assumptions.md) — assumptions register (link new/affected assumptions here).
- [`../../../docs/architecture.md` §9](../../../docs/architecture.md#9-decision-record-index-reasoning-lives-in-the-adrs) — the ADR index (HLD) you add a row to.
- Skills that should TRIGGER a new ADR when their decision logic changes: [`add-cell`](../add-cell/SKILL.md), [`upgrade-arcadedb`](../upgrade-arcadedb/SKILL.md), [`migrate-schema`](../migrate-schema/SKILL.md), [`restore-tenant`](../restore-tenant/SKILL.md) — e.g. changing a capacity cap, durability tier, or backup/restore strategy.
