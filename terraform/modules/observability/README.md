# Module: `observability`

Metrics, alerts, logs, and alert routing for the platform (HLD §7.5, ADR-0017):
**Amazon Managed Prometheus (AMP)** + **Amazon Managed Grafana (AMG)** +
starter alert rules + **CloudWatch log groups** + **SNS → PagerDuty**.

> **CTO-package status:** basic boilerplate template — validate-clean, **not applied**.
> Alert expressions are **starter rules** — tune metric names/thresholds in Phase 4.

## What it creates

| Resource | Notes |
|---|---|
| `aws_prometheus_workspace` | AMP — ADOT `remote_write` target. |
| `aws_prometheus_rule_group_namespace` | Starter alerts: **quorum lost (P1)**, leader flapping, replication lag, **OOMKilled**, page-cache eviction, EBS near-full, **backup-age > SLA**, **cell nearing capacity**, **cross-tenant isolation probe failed (P1)**. |
| `aws_sns_topic.alerts` (+ optional HTTPS subscription) | Alert routing to PagerDuty/Alertmanager. KMS-encrypted. |
| `aws_cloudwatch_log_group` (platform + per cell) | Fluent Bit → CloudWatch; KMS-encrypted; retention. |
| `aws_grafana_workspace` (+ ADMIN group association) | AMG, AWS_SSO auth, PROMETHEUS + CLOUDWATCH data sources. |

## The `/prometheus` MIME-type workaround

Lives in the **ADOT scrape config (Helm values)**, not here — ArcadeDB returns
`application/json` for `/prometheus` (F6), so the scrape forces the text parser
(or a header-rewriting sidecar). See [helm/arcadedb/values.yaml](../../../helm/arcadedb/values.yaml)
and assumption A17.

## Usage

```hcl
module "observability" {
  source = "../../modules/observability"

  name             = "kb-eu-prod"
  geo              = "eu"
  env              = "prod"
  region           = "eu-central-1"
  allowed_regions  = ["eu-central-1", "eu-west-1"]
  logs_kms_key_arn = module.kms.logs_key_arn

  cell_log_groups              = ["kb-eu-prod-std-01"]
  grafana_admin_group_ids      = ["SSO_GROUP_ID_PLATFORM_ADMIN"]
  pagerduty_sns_https_endpoint = "https://events.pagerduty.com/integration/REPLACE/enqueue"
}
```

## Key outputs

`amp_workspace_id`, `amp_prometheus_endpoint`, `alerts_sns_topic_arn`,
`platform_log_group_name`, `cell_log_group_names`, `grafana_endpoint`.

## Phase-0/LLD follow-ups

- Replace starter alert expressions with validated metric names from the real
  ArcadeDB `/prometheus` + kube-state-metrics + node-exporter output.
- Grafana dashboards (quorum, per-tenant metering, GraphRAG latency by hop).
- ADOT collector + Pod Identity role (wired via the `eks` module's
  `pod_identity_associations`).
- Distributed tracing (X-Ray / Tempo) across app → PrivateLink → platform → DB.
