# ADR-0017 — Observability: AMP + AMG + CloudWatch Logs

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Metrics via **Amazon Managed Prometheus (AMP)** + **Amazon Managed Grafana (AMG)**; logs via **Fluent Bit → CloudWatch Logs**; traces via **OpenTelemetry/ADOT**. Handle the ArcadeDB `/prometheus` MIME-type bug at scrape time. |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead |
| **Type** | ✅ decided by the business |

## Context

ArcadeDB exposes Prometheus metrics at `/prometheus` (with a known **MIME-type bug** — it returns `application/json`, F6) and `/ready` for health. We need metrics, dashboards, alerts, logs, and traces across many cells and two geos, with **per-tenant usage metering** (the §8 billing seam) and quorum/leader/backup-age alerting — managed, to keep ops burden low.

## Assumptions it rests on

- A1 (pay for managed observability), A17 (the `/prometheus` MIME bug persists on the pinned version), A10 (cost basis).

## Options considered

### Option A — AMP + AMG + CloudWatch Logs + ADOT (chosen)
- **Pros:** managed Prometheus/Grafana (no self-hosted TSDB/Grafana to run + scale + patch); native AWS auth/KMS; CloudWatch Logs integrates with the org log-archive; ADOT for metrics + traces; standard PromQL/Grafana the ops team knows; per-tenant metering via Prometheus labels + a metered-usage stream.
- **Cons:** AMP/AMG cost; AMG workspace/user management; some Prometheus features lag self-hosted.

### Option B — Datadog (or similar SaaS)
- **Pros:** turnkey, rich features, APM.
- **Cons:** cost at scale; data egress + a **third-party data-processor** raises residency/compliance questions (EU telemetry leaving the EU); another vendor in the trust boundary.

### Option C — Self-managed Prometheus + Grafana (in-cluster)
- **Pros:** no managed-service fee; full control.
- **Cons:** we operate + scale + secure + back up the TSDB and Grafana across many cells/geos — exactly the toil we're trying to avoid for a clean hand-over; HA Prometheus is non-trivial.

## Decision

**AMP + AMG + CloudWatch Logs + ADOT.** Force the Prometheus text parser (or run a tiny header-rewriting sidecar) to work around the `/prometheus` MIME bug; bake the workaround into Helm values. Alert routing Grafana/Alertmanager → SNS → PagerDuty.

## Reasoning — why this beats the alternatives

The decision is **decided by the business** for AWS-native + Prometheus/Grafana. Among ways to deliver that, managed (AMP/AMG) best fits the **clean-hand-over** goal (no TSDB/Grafana to operate) and keeps telemetry in-region (residency) without a third-party processor (ruling out Datadog on residency + cost). Self-managed reintroduces the operational toil we're explicitly avoiding.

## Consequences

- **Positive:** low-ops managed metrics/dashboards; residency-friendly; standard tooling for hand-over; per-tenant metering supported.
- **Negative / costs:** AMP/AMG fees (§10); the `/prometheus` MIME workaround must be carried (revisit at each version bump, A17); AMG access management.
- **Follow-ups:** ADOT scrape config with the MIME workaround in Helm values; the full alert set (quorum, leader-flap, OOM, disk, backup-age, caps, cert-expiry); per-tenant metering stream; tracing across app→PrivateLink→platform→DB.

## Review-trigger

A17 invalidated (MIME bug fixed → drop the workaround); AMP/AMG cost grows materially; or per-tenant metering needs outgrow Prometheus labels.
