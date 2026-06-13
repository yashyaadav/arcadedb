# Design process — where this started

This folder keeps the **raw inputs** to the project, preserved as a record of how the
design was reasoned out from a blank page. They are intentionally unpolished — the
*finished* design lives elsewhere (see below).

| File | What it is |
|---|---|
| [`problem_statement.txt`](problem_statement.txt) | The original problem I was handed: host ArcadeDB on AWS as the foundation of a multi-tenant Knowledge Base for an AI SaaS, with a clean day-one hand-over — *"plan, deploy and operate this foundational infrastructure using AI."* |
| [`raw_plan.md`](raw_plan.md) | The first comprehensive plan I wrote to attack that problem — the load-bearing ArcadeDB facts, the options weighed, and the phased approach. This is the draft that the polished design grew out of. |

## For the actual design, read these instead

- **[`../design-overview.md`](../design-overview.md)** — the 2-page summary.
- **[`../architecture.md`](../architecture.md)** — the full High-Level Design + diagrams.
- **[`../adr/`](../adr/)** — one Architecture Decision Record per decision (context ·
  options · decision · reasoning · consequences).
- **[`../assumptions.md`](../assumptions.md)** — the living assumptions log.

> Kept deliberately: showing the path from a four-line problem statement to a
> reasoned, guard-railed design package is part of the story.
