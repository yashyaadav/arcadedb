# Helm chart: `arcadedb` (one cell)

A thin, **quorum-correct** chart for a single ArcadeDB cell: a 3-node Raft
StatefulSet with a headless Service (peer discovery), client Service (ClusterIP,
never public), PodDisruptionBudget, `/ready` probes, the memory sizing rule, and
the `/prometheus` MIME-type workaround.

> **CTO-package status:** documented template — **`helm lint` + `kubeconform`
> clean**, not deployed. Renders 5 core resources by default (+ CronJob, PodMonitor,
> sidecar when enabled). Align field names with the upstream
> [arcadedb-helm](https://github.com/ArcadeData/arcadedb-helm) chart schema in Phase 1.

## What it renders

| Template | Resource | Invariant |
|---|---|---|
| `statefulset.yaml` | StatefulSet (3 replicas) | quorum #3; sizing rule #7; AZ anti-affinity (ADR-0010); digest-pinned image (ADR-0012); `txWalFlush` (ADR-0013) |
| `service-headless.yaml` | Headless Service | Raft peer discovery (F1) |
| `service-client.yaml` | ClusterIP Service | **never a public LB** (#4) |
| `pdb.yaml` | PodDisruptionBudget | `minAvailable: 2` (#3) |
| `serviceaccount.yaml` | ServiceAccount | Pod Identity binding point |
| `backup-cronjob.yaml` | CronJob (opt-in) | hot ZIP → S3 (ADR-0015) |
| `podmonitor.yaml` | PodMonitor (opt-in, CRD) | `/prometheus` scrape + MIME workaround (F6) |

## Built-in guard-rails (render-time `fail`)

The chart **refuses to render** on a prime-directive violation — the same
checks as the Terraform `cell` module and the `.claude/` hooks:

- **Sizing rule** — `podMemoryLimitGib < maxPageRAM + heap + overhead` → fail.
- **Version floor** — `image.tag` empty or `latest` (and no digest) → fail.

## The `/prometheus` MIME-type workaround (F6 / A17)

ArcadeDB returns `Content-Type: application/json` for `/prometheus`. Two options,
both in `values.yaml` under `metrics`:

1. **Scraper-side (preferred):** force the text parser —
   `fallbackScrapeProtocol: PrometheusText0.0.4` (rendered into the PodMonitor),
   or the equivalent ADOT/Prometheus `fallback_scrape_protocol`.
2. **Sidecar:** `metrics.mimeWorkaround.sidecar.enabled=true` runs a tiny reverse
   proxy that rewrites the `Content-Type`.

Revisit at every version bump — drop the workaround if a release fixes the bug.

## Validate (no cluster)

```bash
helm lint helm/arcadedb
helm template arcadedb helm/arcadedb | kubeconform -strict -ignore-missing-schemas -summary
```

## Key values

See [`values.yaml`](values.yaml) — every block is documented. Most-set per cell:
`cellId`, `image.tag`/`image.digest`, `replicaCount`, `sizing.*`,
`arcadedb.txWalFlush`, `arcadedb.rootPasswordSecret.name`,
`persistence.storageClassName`, `metrics.*`, `backup.*`.

## Notes / Phase-1 follow-ups

- **Root password is set-once (F4):** injected at first boot only; "rotate root"
  = provision a new admin user (`rotate-secrets` skill), never re-set the var.
- Align `JAVA_OPTS` / `arcadedb.*` setting names + `maxPageRAM` units with the
  pinned ArcadeDB version's docs (this template is best-effort).
- NetworkPolicies are owned by the Terraform `cell` module (avoid duplication);
  enable here only if the chart is the sole manager.
- Upgrades use the quorum-aware Argo workflow (ADR-0029), not the bare
  StatefulSet RollingUpdate.
