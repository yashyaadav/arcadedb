# Security Policy

## Scope

This repository is a **design package** — a High-Level Design, boilerplate
Infrastructure-as-Code, and a Claude Code operating model. **Nothing here is
deployed to AWS**, and there is no running service to attack. Account IDs, image
digests, and other sensitive values are placeholders; example tenants (`acme`,
`globex`) and `example.com` addresses are illustrative only.

As a result, "security issues" here are **design-level** concerns rather than live
vulnerabilities — for example, a flaw in the residency enforcement, an isolation
gap, a weak default in the Helm `values.yaml`, or a missing guard-rail.

## Reporting

- For a **design-level concern**, please [open an issue](../../issues) describing the
  problem and the affected file(s) / ADR.
- If you would rather report privately, use GitHub's **"Report a vulnerability"**
  (Security advisories) on this repository.

Please do **not** include real secrets, credentials, or customer data in any report.

## Security posture baked into the design

The design treats security as a first-class, enforced property — useful context if
you're reviewing it:

- **Residency in depth (5 layers):** SCP region-deny, geo-pinned replication, a
  registry geo-assertion, a CI policy gate, and per-geo Terraform state.
- **No public database:** ArcadeDB ports are never on a public subnet or public load
  balancer; a Conftest/OPA gate ([`policy/conftest/no_public_db.rego`](policy/conftest/no_public_db.rego))
  fails the build if they are.
- **Encrypt everything** at the AWS layer (EBS / S3 / Secrets / snapshots via KMS).
- **Version floor (ArcadeDB ≥ 26.4.1)** to close the known CVSS-9.0 cross-DB
  isolation CVE, enforced by a deterministic pre-edit hook and CI.
- **Deterministic guard-rail hooks** ([`.claude/settings.json`](.claude/settings.json))
  that block a public DB port, an out-of-geo region, prod replicas < 3, or a secret in
  a diff — regardless of who is at the keyboard.
- **Secret scanning** (`gitleaks`) runs before commits; `.gitignore` excludes state,
  keys, and `.env` files.

See [`docs/architecture.md`](docs/architecture.md) and the
[`security-baseline-check`](.claude/skills/security-baseline-check/) skill for the full
posture.
