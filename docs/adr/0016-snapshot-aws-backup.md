# ADR-0016 — Snapshot orchestration: AWS Backup (over DLM)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Orchestrate EBS snapshots (and cross-region in-geo copies) with **AWS Backup**, not Data Lifecycle Manager (DLM). |
| **Date** | 2026-06-13 |
| **Deciders** | Platform lead |
| **Type** | ⭐ recommended (overridable) |

## Context

The hot per-DB ZIP backups exclude the WAL (F5), so we complement them with **EBS snapshots every 4–6h** that capture WAL/on-disk state, KMS-encrypted, copied to the in-geo DR region ([ADR-0014](0014-dr-strategy-warm-standby.md)). We need centralised policy, cross-region copy, encryption, retention, and **auditable compliance reporting** for SOC2.

## Assumptions it rests on

- A7 (SOC2 needs backup compliance evidence), prime directive #1 (in-geo copy), prime directive #5 (KMS).

## Options considered

### Option A — AWS Backup (chosen)
- **Pros:** centralised backup **plans + vaults** across services; built-in **cross-region copy** (geo-pinned), **Vault Lock** (immutability) for compliance, KMS encryption, and **Backup Audit Manager** reporting for SOC2; org-level backup policies; one pane for EBS (and later more).
- **Cons:** slightly more setup than DLM; AWS Backup pricing model to track.

### Option B — Data Lifecycle Manager (DLM)
- **Pros:** simple, cheap EBS-snapshot scheduling.
- **Cons:** EBS-only, no centralised plans/vaults, weaker cross-region/immutability/compliance-reporting story; doesn't give the SOC2 evidence + Vault Lock we want.

## Decision

**AWS Backup** with per-geo backup plans + vaults, KMS-encrypted, geo-pinned cross-region copy, Vault Lock for enterprise retention, and Backup Audit Manager for compliance evidence.

## Reasoning — why this beats the alternatives

The complementary EBS layer exists precisely for **durability + compliance**, so the orchestrator should give us **immutability (Vault Lock), geo-pinned copy, and audit reporting** out of the box — which AWS Backup does and DLM does not. The modest extra setup buys the SOC2 evidence + cross-region-in-geo guarantees we'd otherwise hand-build.

## Consequences

- **Positive:** centralised, compliant, immutable, geo-pinned snapshot management with audit reporting; one model that can extend to other services.
- **Negative / costs:** AWS Backup pricing + vault storage; plan/vault configuration per geo; copy destinations must be geo-validated (residency).
- **Follow-ups:** backup-dr module (AWS Backup plan/vault, copy action, Vault Lock); residency check on copy destinations; whole-cell EBS-snapshot restore path in the DR runbook.

## Review-trigger

AWS Backup cost grows materially; DLM gains the missing compliance features; or snapshot cadence/retention needs change.
