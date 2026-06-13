# ADR-0000 — Template (copy this for every new decision)

> **How to use:** copy this file to `NNNN-short-kebab-title.md` (next free number),
> fill every section, add a row to the [ADR index in `architecture.md`](../architecture.md#9-decision-record-index-reasoning-lives-in-the-adrs),
> and link any assumptions it rests on to [`assumptions.md`](../assumptions.md).
> **Rule: no decision lands without an ADR that states its reasoning.**
> The `new-adr` skill scaffolds this for you.

| Field | Value |
|---|---|
| **Status** | Proposed · **Accepted** · Superseded by ADR-NNNN · Deprecated |
| **Decision** | _one line — the choice made_ |
| **Date** | YYYY-MM-DD |
| **Deciders** | _roles, not names where possible_ |
| **Type** | ✅ decided by the business · ⭐ recommended (overridable) |

## Context

_What is the problem / forcing function? What constraints (ArcadeDB facts, residency,
budget, hand-over) bound the choice? Link the relevant facts (F1–F7) and prime directives._

## Assumptions it rests on

_List the `assumptions.md` IDs (A1, A2, …) this decision depends on. If one is
invalidated, this ADR is up for review._

## Options considered

### Option A — _name_ (chosen / rejected)
- **Pros:** …
- **Cons:** …

### Option B — _name_
- **Pros:** …
- **Cons:** …

_(Add options as needed. Always include the "do nothing / status quo" option where meaningful.)_

## Decision

_The choice, stated unambiguously, with any scoping (e.g. "for prod cells only")._

## Reasoning — why this beats the alternatives

_The heart of the ADR. Why, given the context + assumptions, this option wins.
Tie back to the ArcadeDB facts and prime directives where relevant._

## Consequences

- **Positive:** …
- **Negative / costs:** …
- **Follow-ups / what this obliges us to build:** …

## Review-trigger

_The concrete signal that should make us revisit this decision (a metric threshold,
a version change, a cost line, an assumption being invalidated, a date)._
