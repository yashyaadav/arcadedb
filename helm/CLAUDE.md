# CLAUDE.md — helm/

Directory rules for the ArcadeDB cell chart. Inherits the root
[`CLAUDE.md`](../CLAUDE.md). Validate with `helm lint` + `kubeconform`; never
`helm install` against a real cluster in Phase D.

## ArcadeDB values conventions

- **Image**: `image.tag` must be a semver **≥ 26.4.1**, never `latest`; prefer
  pinning `image.digest` in prod (the chart `fail`s on a violation).
- **Replicas**: 3 in prod (PDB `minAvailable: 2`). Non-prod may be 1.
- **One pod per AZ**: hard `podAntiAffinity` on `topology.kubernetes.io/zone`;
  schedule onto the DB nodes via `nodeSelector: {workload: arcadedb}` + the
  matching toleration.

## The sizing rule (THE #1 gotcha — prime directive #7)

`sizing.podMemoryLimitGib` **must be ≥** `maxPageRAMGib + heapGib + overheadGib`.
The chart **refuses to render** otherwise (template `fail`). Give most RAM to the
off-heap page cache (`maxPageRAM`), keep heap modest, and **leave `cpuLimit`
empty** — a tight CPU limit throttles the JVM and starves Raft heartbeats →
leader flapping.

Worked example (`r7g.2xlarge`, 64 GiB): `maxPageRAMGib: 32`, `heapGib: 8`,
`overheadGib: 6`, `podMemoryLimitGib: 46`.

## txWalFlush tiering (ADR-0013)

`arcadedb.txWalFlush`: **2 (fsync)** for enterprise/regulated, **0/1** for
standard (throughput). Set per cell; do not default-and-forget.

## Probes

`/ready` (HTTP 204, no auth) for readiness/liveness; **generous startup probe**
(`failureThreshold` high) — ArcadeDB + index load can be slow on big DBs.

## The /prometheus MIME-type workaround (F6 / assumption A17)

ArcadeDB returns `Content-Type: application/json` for `/prometheus`. Use ONE of:
1. **Scraper-side (preferred)**: force the text parser
   (`fallbackScrapeProtocol: PrometheusText0.0.4` in the PodMonitor, or the ADOT
   `fallback_scrape_protocol`).
2. **Sidecar**: `metrics.mimeWorkaround.sidecar.enabled=true`.
Revisit at every version bump — drop it if a release fixes the bug.

## The quorum-preserving upgrade (no Operator → we own it — ADR-0029)

Do **not** rely on the bare StatefulSet RollingUpdate. Upgrades run via the
quorum-aware Argo workflow (`upgrade-arcadedb` skill): pre-flight health + fresh
backup → **replicas first, one at a time** (wait for re-join + lag→0 + `/ready`)
→ **leader last** (graceful step-down) → **re-audit cross-DB isolation**.
Forward-only: rollback = restore-from-backup to the prior version.

## Other

- **Root password is set-once (F4)**: injected from a secret at first boot only;
  "rotate root" = provision a new admin user (`rotate-secrets` skill).
- **Never a public LoadBalancer** — the client Service is ClusterIP; external app
  access is via the platform API → internal NLB → PrivateLink (ADR-0026).
- NetworkPolicies are owned by the Terraform `cell` module; don't duplicate here.

## Validate

```bash
helm lint helm/arcadedb
helm template arcadedb helm/arcadedb | kubeconform -strict -ignore-missing-schemas -summary
```
