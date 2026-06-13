---
name: incident-triage
description: Guided decision tree to triage live ArcadeDB cell incidents (quorum loss, leader flapping, OOMKilled pod, disk full, AZ/region loss, noisy-neighbour) and pick the correct, residency-safe remediation. Use the moment an alert fires or a tenant reports degraded retrieval.
---

# Incident triage

> What/when: a fast, branching runbook for on-call to classify a live ArcadeDB incident and apply the safe remediation. Phase note: triage, diagnosis, and the per-tenant kill-switch are always available; any step that mutates AWS/EKS/EBS or the cluster is a POST-APPROVAL action (Spacelift / manual approval, Prime Directive 6) and is out of scope until after CTO sign-off and the relevant phase.

## Prerequisites
- `kubectl` context for the affected geo's EKS cluster (EU or US — NEVER cross EU<->US, Prime Directive 1).
- Read access to Grafana/Prometheus dashboards (see `../../../terraform/modules/observability/`). Note the `/prometheus` MIME-type bug — use the text-parser workaround if scraping the endpoint directly.
- Access to the control-plane retrieval proxy/router (`../../../control-plane/router/index.ts`) to operate the per-tenant kill-switch.
- PagerDuty (or equivalent) ability to declare/escalate a P1.
- Knowledge of which cell maps to the affected tenant(s) (control-plane registry, `../../../control-plane/registry/schema.ts`).
- For any AWS/EKS-mutating step: Spacelift access + a second approver (Prime Directive 6).

## Inputs
- `GEO` — `eu` or `us` (drives which cluster/account/region you touch; NEVER mix).
- `CELL` — the ArcadeDB cell (StatefulSet) involved, e.g. `cell-03`.
- `NAMESPACE` — k8s namespace for the cell.
- `ALERT` — the firing alert / symptom (quorum, leader-flap, OOMKilled, disk-full, AZ-loss, region-loss, noisy-neighbour).
- `TENANT_ID` — affected tenant(s), if tenant-scoped (needed for kill-switch).
- `ACCOUNT_ID` — AWS account placeholder for the geo (geo-specific).

## Safety checks (MUST pass before proceeding)
- Confirm `GEO` and that every command/console targets the SAME jurisdiction. No EU<->US data path, no cross-geo failover (Prime Directive 1). DR pairs are in-jurisdiction only.
- Do NOT delete a PVC or recreate a lost pod with an EMPTY volume in another AZ. A rescheduled pod gets a new IP but the SAME headless FQDN and re-joins the existing Raft group using its existing volume; an empty volume forces full re-replication and can extend an outage (see Steps §A).
- Prod cell = 3 nodes, one-per-AZ, PDB `minAvailable=2` (Prime Directive 3). On full-AZ loss the other 2 nodes still hold quorum — do NOT panic-rebuild.
- WRITES go to the leader; READS fan to replicas (leader-based Raft, min 3). Losing the leader is survivable if 2 nodes remain; losing 2 of 3 = quorum loss = writes stop.
- No native per-DB resource quotas — a runaway tenant is contained by the retrieval proxy's per-tenant limits + kill-switch, NOT by the engine (Prime Directive / ArcadeDB fact).
- Sizing rule (Prime Directive 7): pod mem limit >= maxPageRAM + heap + overhead. On OOMKilled, verify this BEFORE bumping limits, or you will OOM again and risk quorum.
- Any node-pool, EBS, or Helm change is no-click-ops: Terraform/Helm/GitOps, plan before apply, prod apply needs manual approval (Prime Directive 6). Never let Karpenter/cluster-autoscaler scale the DB tier — the DB tier is fixed StatefulSet capacity.
- Never restore a backup over a live/existing DB and never "fix" auth by re-setting the root password in place — both are forbidden (restore requires the target DB to NOT exist; root password is set-once, rotate by provisioning a NEW admin user). Not part of triage, but do not reach for them here.

## Steps

First, classify. Run the quick triage snapshot, then jump to the matching branch.

0. Triage snapshot (read-only, safe):
   ```
   kubectl -n $NAMESPACE get pods -o wide -l app=arcadedb,cell=$CELL
   kubectl -n $NAMESPACE describe statefulset $CELL
   kubectl -n $NAMESPACE get events --sort-by=.lastTimestamp | tail -n 40
   ```
   Note: ready pods (target 3/3), `/ready` probe is HTTP 204; pod AZ topology; restart counts; last-state reasons (OOMKilled?). Check the cell's Raft leader + replica lag in Grafana.

   Decision tree:
   - 2+ pods up, writes failing or no stable leader -> §B leader flapping.
   - <2 of 3 pods Ready / Raft can't elect -> §C quorum loss (P1).
   - Pod `Last State: OOMKilled` -> §D.
   - PVC near/at 100%, write errors / read-only -> §E disk full.
   - All pods in ONE AZ gone, 2 others healthy -> §A full-AZ loss.
   - Whole region's cells down / region unreachable -> §F region loss (P1).
   - One tenant driving CPU/IO/page churn, others degraded -> §G noisy-neighbour.

### §A — Pod lost / full-AZ loss (DEFAULT to "let Raft heal")
1. Identify scope: one pod (single AZ blip) vs. all pods in one AZ down.
2. CRITICAL — do nothing destructive. A lost pod will be rescheduled by the StatefulSet onto a node (when capacity returns), re-attach its EXISTING PVC, get a new IP but the SAME stable headless FQDN, and re-join the existing Raft group. This is the fast path. Do NOT:
   - delete the PVC,
   - `kubectl delete pod` to "force" it onto another AZ with a fresh volume,
   - recreate the member with an empty volume (forces full re-replication of the DB).
3. Full-AZ loss: the remaining 2 nodes hold quorum (minAvailable=2). Writes continue via the leader; reads continue. Confirm the PDB prevented a 3rd eviction.
4. If the AZ outage is prolonged and the EBS volume in the dead AZ is unrecoverable, capacity recovery (new node in a healthy AZ, restoring the member's data via EBS snapshot) is an **AWS-MUTATING, POST-APPROVAL** action — open a change in Spacelift, plan before apply, get a second approver. Out of scope until the relevant phase.

### §B — Leader flapping
1. Confirm symptom: leadership re-elections in logs/metrics, intermittent write failures, replica lag spikes.
2. Check for the underlying cause (usually NOT "the leader is bad"): node pressure (CPU/mem), network partition between AZs, GC pauses (heap too small per sizing rule), or a single overloaded node. Look at per-pod CPU/mem and `kubectl describe node`.
3. If one tenant is driving the load -> go to §G (kill-switch) to stabilise, then reassess.
4. If it's GC/heap or memory pressure, it converges with §D (sizing). Do NOT repeatedly restart pods to "pick a new leader" — that prolongs flapping. Let Raft settle once load is removed.
5. Persisting flapping after load is controlled may indicate a config/sizing fix (Helm values) — that is a **POST-APPROVAL** Helm/GitOps change (plan before apply).

### §C — Quorum loss (<2 of 3) — P1
1. **PAGE immediately** — declare P1 (quorum loss = writes stopped for that cell's tenants).
2. Read-only assess: how many pods Ready, why the others are down (Pending/CrashLoop/OOMKilled/AZ gone). Do NOT delete PVCs.
3. If pods are Pending due to no node capacity in their AZ, the fix is restoring capacity in-AZ (the rescheduled pod re-attaches its existing PVC and re-joins). Capacity provisioning is **AWS-MUTATING, POST-APPROVAL** (Spacelift, second approver).
4. If pods are OOMKilled -> apply §D logic (sizing) — but any limit change is **POST-APPROVAL** Helm.
5. Never attempt to "force a single survivor to be leader" by deleting peers — you risk split-brain/data loss. Preserve volumes; restore the 2nd healthy member so Raft can re-form quorum.
6. If data on a member is provably lost, recovery is via EBS snapshot of that member (NOT restore-over-existing). Cross-reference `dr-drill`. POST-APPROVAL.

### §D — OOMKilled pod
1. Confirm `Last State: OOMKilled` and which container.
2. Apply the sizing rule (Prime Directive 7) BEFORE changing anything: required pod mem limit >= `maxPageRAM` + JVM heap + overhead. Read current values from `../../../helm/arcadedb/values.yaml`. If the limit is below that sum, the limit (or maxPageRAM/heap) is misconfigured.
3. Immediate containment if OOM is tenant-driven (a tenant blowing the page cache): use the §G kill-switch to suspend that tenant — this is safe and reversible and does NOT mutate AWS.
4. The actual fix (raise mem limit and/or lower maxPageRAM/heap so the inequality holds) is a Helm `values.yaml` change = **POST-APPROVAL** GitOps (plan before apply, manual approval). Do NOT hand-edit the running pod — it will be reconciled away, and an under-sized limit OOM-kills again and can cost quorum.
5. Let the StatefulSet reschedule the pod onto its existing PVC after the corrected values roll out.

### §E — Disk full
1. Confirm: PVC usage at/near 100%, write errors or DB gone read-only. Check `kubectl -n $NAMESPACE exec` df on the data mount, and the volume-usage metric.
2. Verify the StorageClass has `allowVolumeExpansion: true` (see `../../../terraform/modules/eks/` / cell module storage config).
3. Containment: if a single tenant's ingest is filling the disk, use the §G kill-switch to stop the bleed (safe, reversible).
4. Expand the PVC (edit the PVC request size; expansion is online for supported EBS gp3). This grows an **EBS volume = AWS-MUTATING, POST-APPROVAL** — do it via Terraform/GitOps with plan + manual approval, not ad-hoc kubectl, in prod. Never shrink. Never delete the PVC.
5. Backups note: ArcadeDB backup is a hot per-DB ZIP that EXCLUDES WAL and has no incremental/PITR/native-S3 — do NOT rely on "just restore" to escape a disk-full; fix the volume. Supplement with EBS snapshots.

### §F — Region loss — P1
1. **PAGE immediately** — declare P1.
2. Confirm scope: entire region's EKS/cells unreachable (not just one AZ — that's §A).
3. Residency gate: failover/recovery MUST stay in-jurisdiction. EU stays EU, US stays US (Prime Directive 1). There is NO EU<->US failover path — do not even consider it.
4. Invoke the DR runbook `dr-drill` for the in-region recovery / in-jurisdiction DR pair. All recovery infra actions are **AWS-MUTATING, POST-APPROVAL** (Spacelift, second approver) and bound by the DR plan.
5. Keep tenants informed; use the kill-switch (§G) only if you must shed load during partial recovery.

### §G — Noisy-neighbour / runaway tenant — KILL-SWITCH
1. Identify the offending `TENANT_ID` (top CPU/IO/query-rate tenant on the cell; control-plane proxy metrics).
2. Engage the per-tenant kill-switch in the retrieval proxy to suspend that tenant's traffic. See `../../../control-plane/router/index.ts` (per-tenant limits + kill-switch). This is the ONLY engine-independent throttle — ArcadeDB has no per-DB quotas. The kill-switch is safe, reversible, and does NOT mutate AWS/cluster.
3. Suspending one tenant protects the other tenants sharing the cell and can stabilise §B (flapping) / §D (OOM) / §E (disk) caused by that tenant.
4. After the tenant is contained and the cell is healthy, re-enable the tenant via the proxy. If the tenant legitimately needs more capacity, the long-term fix is ADD A CELL (single-leader write ceiling per cell; a DB can't be split across nodes) — capacity planning + new cell is **POST-APPROVAL** Terraform/GitOps, out of scope for triage.

## Verification
- §0/general: `kubectl -n $NAMESPACE get pods -l cell=$CELL` shows 3/3 Ready; `/ready` returns 204; one stable Raft leader; replica lag back to baseline in Grafana.
- §A: lost pod is Running again on its EXISTING PVC with the same FQDN, re-joined Raft (no full re-replication observed).
- §B: no new leader elections for a sustained window; write latency/error rate back to baseline.
- §C: quorum re-formed (>=2 Ready, leader elected, writes succeeding); P1 can be downgraded.
- §D: pod stays up with no new OOMKilled; mem usage below the limit; sizing inequality holds in `values.yaml`.
- §E: PVC has free space, DB out of read-only, writes succeed; StorageClass shows `allowVolumeExpansion: true`.
- §F: in-region/in-jurisdiction recovery confirmed per `dr-drill`; NO data crossed jurisdictions.
- §G: offending tenant suspended (proxy shows kill-switch active), other tenants' latency/errors recovered; tenant re-enabled cleanly afterwards.

## Rollback / if it goes wrong
- Kill-switch (§G): fully reversible — re-enable the tenant in `../../../control-plane/router/index.ts`. No state change to undo.
- If you (wrongly) deleted a pod and it landed with an empty volume: STOP, do not delete more peers; let the empty member re-replicate from the leader (slow but safe) — never delete the healthy survivors. Re-evaluate as a §C if quorum is now at risk.
- POST-APPROVAL infra changes (EBS expand, node capacity, Helm sizing): roll back via the GitOps revert + Spacelift plan/apply (manual approval). Never roll back by hand-editing live cluster objects.
- If an action would cross EU<->US, ABORT — it is a residency violation (Prime Directive 1); escalate instead.
- If unsure whether quorum is safe to touch: page and treat as P1 rather than risk split-brain/data loss.

## Related
- Skill: `dr-drill` (region/AZ recovery, in-jurisdiction DR pair).
- ADR-0027 (see `../../../docs/adr/0027-runtime-tenant-governance.md`) — runtime tenant governance: app-layer limits + circuit-breaker + the per-tenant kill-switch used in §G.
- ADR-0010 (see `../../../docs/adr/0010-node-provisioning-mng-karpenter.md`) — node provisioning: MNG per-AZ for the stateful DB tier, Karpenter only for stateless. Basis for "never let an autoscaler consolidate/scale the DB tier" (Safety checks, §A).
- ADR-0007 (see `../../../docs/adr/0007-residency-enforcement-scp.md`) — residency enforcement / no cross-geo data path (the no-EU<->US rule in §F and Safety checks).
- `../../../control-plane/router/index.ts` — retrieval proxy per-tenant limits + kill-switch.
- `../../../helm/arcadedb/values.yaml` — sizing (maxPageRAM/heap/limits), probes.
- `../../../terraform/modules/observability/`, `../../../terraform/modules/eks/`, `../../../terraform/modules/cell/`, `../../../terraform/modules/backup-dr/`.
- `../../../docs/architecture.md`, `../../../docs/assumptions.md`.
