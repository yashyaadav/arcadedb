# ADR-0001 — Compute platform: EKS

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Decision** | Run ArcadeDB and the control plane on **Amazon EKS (Kubernetes)** using the official ArcadeDB Helm chart (StatefulSets). |
| **Date** | 2026-06-13 |
| **Deciders** | CTO, Platform lead |
| **Type** | ✅ decided by the business |

## Context

ArcadeDB ships an **official Helm chart that deploys a StatefulSet** and documents Kubernetes as a first-class target (F6). HA is leader-based Raft requiring a **stable 3-node group with per-pod persistent volumes and stable network identity** (F1). We need to run *many* such clusters (cells) per region, scale them independently, and hand the platform to a cloud-ops team that expects mainstream tooling. The platform must also host stateless control-plane and retrieval components.

## Assumptions it rests on

- A1 (budget: can pay for a managed control plane), A4 (workload shape), A14 (a regional cluster can back many pooled cells).

## Options considered

### Option A — EKS / Kubernetes (chosen)
- **Pros:** ArcadeDB's official chart targets it; StatefulSet + headless Service + PVC give exactly the stable identity + per-pod storage Raft needs; PodDisruptionBudget directly encodes the quorum invariant (#3); one regional control plane backs many cells (cost); huge ecosystem (Argo CD, External Secrets, Cilium, Karpenter) the ops team already knows; managed control plane (EKS) removes master-node toil.
- **Cons:** Kubernetes operational complexity; we own day-2 DB logic (no operator, F6); stateful workloads on K8s need care (AZ-pinned EBS, anti-affinity).

### Option B — ECS (Fargate/EC2)
- **Pros:** simpler than K8s; less to operate.
- **Cons:** no official ArcadeDB support; StatefulSet-equivalents (stable identity, ordered start, per-task EBS) are awkward; weaker fit for Raft peer discovery; smaller ecosystem for the policy/GitOps stack; Fargate can't attach the EBS volumes a DB needs the way we want.

### Option C — Plain EC2 + systemd / Nomad
- **Pros:** maximum control; no orchestrator overhead.
- **Cons:** we rebuild scheduling, rolling upgrades, secret injection, service discovery, and autoscaling by hand; worst hand-over story; slowest to a safe baseline.

## Decision

**Amazon EKS**, official ArcadeDB Helm chart, StatefulSets, one regional EKS cluster backing many namespace-cells (pooled) with optional dedicated clusters for enterprise (see [ADR-0004](0004-cell-backing-namespace.md)).

## Reasoning — why this beats the alternatives

The deciding factor is **fit to ArcadeDB's HA model and its official tooling**: the chart, StatefulSet semantics, headless Service peer discovery, and PDB map one-to-one onto Raft's needs (F1, F6). ECS and raw EC2 would force us to re-implement those primitives with less vendor support. EKS also gives the richest, most familiar ecosystem for the guard-rails and GitOps the hand-over depends on, and lets one control plane amortise across many cells.

## Consequences

- **Positive:** clean mapping to ArcadeDB HA; mainstream, hand-over-friendly tooling; per-cell blast radius via namespaces + PDB.
- **Negative / costs:** EKS control-plane fee (~$73/cluster/mo); Kubernetes complexity; **we own the upgrade/rollback logic ourselves** (F6, [ADR-0029](0029-upgrade-rollback-restore-based.md)); careful stateful-on-K8s patterns required ([ADR-0010](0010-node-provisioning-mng-karpenter.md)).
- **Follow-ups:** node-group strategy (0010), CNI (0023), workload identity (0011), GitOps (0021).

## Review-trigger

ArcadeDB ships a managed cloud offering, or a Kubernetes Operator that materially reduces day-2 burden; or EKS cost becomes a dominant line at small scale (revisit single-cluster-many-cells).
