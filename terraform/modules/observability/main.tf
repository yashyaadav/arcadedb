###############################################################################
# modules/observability — AMP + AMG + alerts + logs + SNS→PagerDuty.
#
# BOILERPLATE TEMPLATE (CTO package): validate-clean, NOT applied.
# Alert expressions are STARTER rules — tune metric names/thresholds in Phase 4
# against real ArcadeDB /prometheus + kube-state-metrics + node-exporter output.
###############################################################################

locals {
  region_in_geo = contains(var.allowed_regions, var.region)

  common_tags = merge(var.tags, {
    platform             = "arcadedb-kb"
    geo                  = var.geo
    env                  = var.env
    module               = "observability"
    managed-by           = "opentofu"
    "residency-boundary" = var.geo
  })
}

resource "terraform_data" "residency_guard" {
  lifecycle {
    precondition {
      condition     = local.region_in_geo
      error_message = "RESIDENCY VIOLATION: region ${var.region} not in ${var.geo} allow-list ${jsonencode(var.allowed_regions)} (ADR-0007)."
    }
  }
}

###############################################################################
# Amazon Managed Prometheus (AMP)
###############################################################################
resource "aws_prometheus_workspace" "this" {
  alias = "${var.name}-amp"
  tags  = local.common_tags
}

# Starter alerting rules (HLD §7.5). Tune in Phase 4.
resource "aws_prometheus_rule_group_namespace" "alerts" {
  name         = "${var.name}-arcadedb-alerts"
  workspace_id = aws_prometheus_workspace.this.id

  data = <<-YAML
    groups:
      - name: arcadedb-quorum
        rules:
          - alert: ArcadeDBQuorumLost
            expr: count by (cell) (up{job="arcadedb"} == 1) < 2
            for: 1m
            labels: { severity: P1, platform: arcadedb-kb }
            annotations:
              summary: "Cell {{ $labels.cell }} below Raft quorum (<2/3 healthy)"
          - alert: ArcadeDBLeaderFlapping
            expr: changes(arcadedb_raft_leader_changes_total[10m]) > 3
            for: 5m
            labels: { severity: P1, platform: arcadedb-kb }
            annotations:
              summary: "Cell {{ $labels.cell }} leader flapping"
          - alert: ArcadeDBReplicationLagHigh
            expr: arcadedb_raft_replication_lag_seconds > 30
            for: 5m
            labels: { severity: P2, platform: arcadedb-kb }
            annotations:
              summary: "Cell {{ $labels.cell }} replication lag > 30s"
      - name: arcadedb-resources
        rules:
          - alert: ArcadeDBPodOOMKilled
            expr: increase(kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace=~".*"}[15m]) > 0
            for: 1m
            labels: { severity: P1, platform: arcadedb-kb }
            annotations:
              summary: "ArcadeDB pod OOMKilled — check the sizing rule (maxPageRAM+heap+overhead)"
          - alert: ArcadeDBPageCacheEvictionHigh
            expr: rate(arcadedb_pagecache_evictions_total[10m]) > 0
            for: 15m
            labels: { severity: P2, platform: arcadedb-kb }
            annotations:
              summary: "Working set exceeding maxPageRAM on {{ $labels.cell }}"
          - alert: EBSVolumeNearFull
            expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) > 0.85
            for: 10m
            labels: { severity: P1, platform: arcadedb-kb }
            annotations:
              summary: "EBS volume > 85% full on {{ $labels.instance }}"
      - name: arcadedb-backup-dr
        rules:
          - alert: BackupAgeExceedsSLA
            expr: time() - arcadedb_backup_last_success_timestamp_seconds > 25200
            for: 5m
            labels: { severity: P2, platform: arcadedb-kb }
            annotations:
              summary: "Last successful backup for {{ $labels.tenant }} older than SLA"
          - alert: CellNearingCapacity
            expr: arcadedb_cell_db_count / arcadedb_cell_db_cap > 0.8
            for: 10m
            labels: { severity: P2, platform: arcadedb-kb }
            annotations:
              summary: "Cell {{ $labels.cell }} nearing capacity cap — run add-cell"
      - name: arcadedb-isolation
        rules:
          - alert: CrossTenantIsolationProbeFailed
            expr: arcadedb_isolation_probe_success == 0
            for: 1m
            labels: { severity: P1, platform: arcadedb-kb }
            annotations:
              summary: "Cross-DB isolation probe SUCCEEDED unexpectedly on {{ $labels.cell }} — investigate immediately (CVE history)"
  YAML
}

###############################################################################
# SNS topic for alerts → PagerDuty (HLD §7.5)
###############################################################################
resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.logs_kms_key_arn
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count                  = var.pagerduty_sns_https_endpoint == null ? 0 : 1
  topic_arn              = aws_sns_topic.alerts.arn
  protocol               = "https"
  endpoint               = var.pagerduty_sns_https_endpoint
  endpoint_auto_confirms = true
}

###############################################################################
# CloudWatch log groups — platform + per cell (Fluent Bit → CloudWatch)
###############################################################################
resource "aws_cloudwatch_log_group" "platform" {
  name              = "/arcadedb/${var.geo}-${var.env}/platform"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "cells" {
  for_each          = toset(var.cell_log_groups)
  name              = "/arcadedb/${var.geo}-${var.env}/cell/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.common_tags
}

###############################################################################
# Amazon Managed Grafana (AMG)
###############################################################################
resource "aws_grafana_workspace" "this" {
  count = var.enable_grafana ? 1 : 0

  name                      = "${var.name}-amg"
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = ["AWS_SSO"]
  permission_type           = "SERVICE_MANAGED"
  data_sources              = ["PROMETHEUS", "CLOUDWATCH"]
  notification_destinations = ["SNS"]

  tags = local.common_tags
}

resource "aws_grafana_role_association" "admins" {
  count        = var.enable_grafana && length(var.grafana_admin_group_ids) > 0 ? 1 : 0
  role         = "ADMIN"
  group_ids    = var.grafana_admin_group_ids
  workspace_id = aws_grafana_workspace.this[0].id
}
