# Contributing

Thanks for taking a look. This repository is a **design package** — a High-Level
Design, boilerplate Infrastructure-as-Code, and a Claude Code operating model for a
multi-tenant ArcadeDB platform on AWS. It is shared as a reference / portfolio
artifact. **Nothing here is applied to AWS** (see the status banner in the
[README](README.md)).

Feedback, questions, and discussion are very welcome — especially on the
architecture and the decision records.

## Ways to contribute

- **Open an issue** to ask a question, point out a flaw in the reasoning, or suggest
  an improvement to the design or the docs.
- **Open a pull request** for typos, broken links, doc clarity, or additional
  validation. For anything that changes a design choice, please open an issue first
  so the reasoning can be captured in an [ADR](docs/adr/).

## Ground rules for changes

This repo enforces its own invariants — please keep them intact:

1. **Every decision gets an ADR.** Use [`docs/adr/0000-template.md`](docs/adr/0000-template.md)
   (or the `new-adr` skill) and add a row to the index in
   [`docs/architecture.md`](docs/architecture.md). Every new assumption gets a row in
   [`docs/assumptions.md`](docs/assumptions.md).
2. **Don't break the prime directives** (see [`CLAUDE.md`](CLAUDE.md)): residency,
   version floor (ArcadeDB ≥ 26.4.1), quorum (prod cells = 3 nodes), no public
   database, encrypt everything, no click-ops, the memory-sizing rule. The hooks in
   [`.claude/settings.json`](.claude/settings.json) block violations automatically.
3. **Validate before you commit.** Everything below is offline and touches no AWS:

   ```bash
   make validate   # fmt + tofu validate + tflint + conftest + helm lint + kubeconform
   ```

   Keep `make validate` green.
4. **Match the surrounding style.** Pin versions; keep diagrams in sync with the IaC.

## Code of conduct

Be kind and constructive. This is a small project; treat collaborators the way
you'd want to be treated.
