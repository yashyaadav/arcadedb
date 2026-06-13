# CLAUDE.md — docs/

Directory rules for the design docs. Inherits the root [`CLAUDE.md`](../CLAUDE.md).

## The enforced rule

**No decision lands without an ADR that states its reasoning, and no assumption
stands without a `docs/assumptions.md` entry.** This is a CLAUDE.md convention
*and* a CI check. When you make a choice or rest on an assumption while working
anywhere in this repo, update these docs in the same change.

## ADRs (`docs/adr/NNNN-*.md`)

- One file per decision, next free `NNNN`, kebab-case title.
- Use [`0000-template.md`](adr/0000-template.md) (or the `new-adr` skill).
- **Required sections**: Context · Assumptions it rests on · Options considered
  (with pros/cons) · Decision · **Reasoning (why this beats the alternatives)** ·
  Consequences · Status · **Review-trigger**.
- After writing, add a row to the ADR index in
  [`architecture.md`](architecture.md#9-decision-record-index-reasoning-lives-in-the-adrs)
  and link any assumptions it rests on.
- Status values: Proposed · Accepted · Superseded by ADR-NNNN · Deprecated.
  Don't edit a decided ADR's decision — supersede it with a new ADR.

## Assumptions log (`docs/assumptions.md`)

Every row records: assumption · **why we chose it** · **impact if wrong** ·
confidence · **validation owner / when** · linked ADR(s). Convert relative dates
to absolute. When validated/invalidated, update Status + the affected ADR(s).

## HLD vs LLD

- [`architecture.md`](architecture.md) is the **High-Level Design** (ships in the
  CTO package). Keep it the single end-to-end narrative + diagrams + ADR index.
- `lld.md` (Low-Level Design) is authored **after CTO sign-off** (Phase 0):
  per-module/resource specs, variable/API schemas, CIDR/IAM/KMS detail. **Do not
  start `lld.md` until the CTO approves.**

## Diagrams

Mermaid, inline in the markdown (renders on GitHub). Keep them in sync with the
IaC — a diagram that lies is worse than none.

## Runbooks (`docs/runbooks/`)

Each operational runbook has a **matching skill** in `.claude/skills/` (1:1 map).
`claude-code-operations.md` is the "operating this platform with Claude Code"
guide handed to the ops team.
