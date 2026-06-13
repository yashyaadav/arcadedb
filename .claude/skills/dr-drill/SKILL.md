---
name: dr-drill
description: Rehearse an in-jurisdiction warm-standby failover (and measure real RPO/RTO) so the team can prove DR works before a real incident. Use quarterly per geo for the planned game-day, and any time you need to validate DR posture after major topology or version changes.
---

# Run a DR game-day

> Quarterly, per-geo, in-jurisdiction warm-standby failover rehearsal: promote the DR cell, repoint registry + Route 53, serve SYNTHETIC traffic, measure actual RPO/RTO vs targets, then fail back. PHASE NOTE: every step that scales, promotes, repoints DNS, or mutates AWS/cluster state is POST-APPROVAL and OUT OF SCOPE until after CTO sign-off and the DR phase is live. Until then this is a tabletop / dry-run only.

## Prerequisites
- A warm-standby 3-node cell exists in the SAME-GEO DR region (ADR-0014), one-per-AZ, currently scaled down to standby capacity.
- Same-geo S3 Cross-Region Replication (CRR) of backups is configured and healthy (`terraform/modules/backup-dr/`), plus EBS snapshot copies into the DR region.
- DR-side registry replica (REGIONAL DynamoDB with in-geo cross-region replication ONLY — NEVER a global EU<->US table, per ADR-0008; see `../../../control-plane/registry/schema.ts`) is live and replicating.
- Route 53 records for the geo endpoint are managed in `terraform/modules/observability/` / landing-zone DNS, with a DR target ready (failover or weighted record).
- `kubectl` context for BOTH the primary and the DR EKS cluster of the geo under test; `aws` CLI with read access in both regions; Spacelift access for any apply.
- A synthetic traffic harness (a small set of throwaway/canary tenants whose data is fabricated, never real customer data) and a way to drive read+write probes through the retrieval proxy (`../../../control-plane/router/index.ts`).
- A clean, reviewed `restore-tenant` runbook on hand (see Related) for the monthly restore test and for any restore needed mid-drill.

## Inputs
- `GEO` — the geo under test: `EU` or `US`. This pins both the primary and the DR region; they MUST be in the same jurisdiction.
- `PRIMARY_REGION` / `DR_REGION` — both in-geo (e.g. EU: `eu-west-1` -> `eu-central-1`; US: `us-east-1` -> `us-west-2`). Confirm both are in `GEO`.
- `ACCOUNT_ID` — the geo's AWS account (placeholder; never cross accounts/geos).
- `CELL_ID` — the DR cell being promoted.
- `DRILL_WINDOW` — scheduled maintenance window (date + start/end, with buffer).
- `SYNTHETIC_TENANTS` — list of canary tenant IDs used to drive load. NO production tenant IDs.
- `TARGETS` — RPO/RTO objectives by tier: Standard RPO <= 6h, RTO <= 4h; Enterprise RPO <= 1h, RTO <= 1-2h.

## Safety checks (MUST pass before proceeding)
- IN-JURISDICTION ONLY (Prime Directive 1 — Residency). `PRIMARY_REGION` and `DR_REGION` are both in `GEO`. There is NO EU<->US data path. Abort immediately if a DR target outside the jurisdiction is selected.
- DR target region is verified in-geo BEFORE any promote/DNS flip. Never point a geo's DR at an out-of-jurisdiction region, even "just to test".
- Minimise blast radius: traffic is SYNTHETIC only. No real tenant requests are routed to the rehearsal; the kill-switch / per-tenant limits in the retrieval proxy stay enforced.
- Quorum (Prime Directive 3): the promoted DR cell MUST come up as 3 nodes, one-per-AZ, with PDB `minAvailable=2`. ArcadeDB Raft needs min 3 for a stable leader — a 2-node promote is NOT a valid prod failover.
- Sizing (Prime Directive 7): DR pods use the SAME `values.yaml` sizing as prod (pod mem limit >= maxPageRAM + heap + overhead). Do not promote into under-sized nodes — an OOM-kill during the drill can crash quorum (`../../../helm/arcadedb/values.yaml`).
- No click-ops (Prime Directive 6): all scale-up / promote / DNS / registry changes go through Terraform/Helm/GitOps with a plan reviewed first; prod-side applies need manual Spacelift approval.
- Encryption (Prime Directive 5): confirm DR EBS volumes, S3 replica bucket, and restored snapshots are KMS-encrypted with the GEO's key (the engine provides none).
- No public DB (Prime Directive 4): DR endpoints expose ONLY the retrieval proxy. Ports 2480/2424/2434/5432/6379/7687 are never on a public subnet/LB in the DR region.
- Backup reality check (ArcadeDB gotcha): backups are hot per-DB ZIPs that EXCLUDE the WAL, with NO incremental and NO PITR. Your achievable RPO is bounded by backup cadence + CRR lag, NOT continuous. Measure against that reality, do not assume zero data loss.
- Restore precondition (ArcadeDB gotcha): if any DB must be restored during the drill, the TARGET DB MUST NOT EXIST first. Never restore over a live DB on the DR cell. Restore is per-DB ZIP + HNSW/Lucene index REBUILD + per-DB user recreation (no PITR, no incremental, WAL excluded) — the index rebuild is slow and counts against RTO.
- Version floor (Prime Directive 2): DR cell runs ArcadeDB >= 26.4.1 and the SAME version as primary. If a drill follows an upgrade, the cross-DB isolation re-audit must already be done.

## Steps
1. ANNOUNCE & SCHEDULE. Confirm the `DRILL_WINDOW`, notify stakeholders + on-call, file the change ticket, and post a clear "synthetic traffic only / no customer impact expected" notice. Record start time T0 for RTO measurement.
2. PRE-FLIGHT (read-only). Re-run every Safety check above. Verify the DR cluster is reachable, version >= 26.4.1 and equal to primary, and that no real traffic is configured to reach the DR endpoint.
3. VERIFY DR DATA FRESHNESS (read-only).
   - S3 CRR: confirm the latest per-DB backup ZIPs have replicated to the in-geo DR bucket and note each object's replication timestamp (this drives RPO).
   - EBS snapshot copies: confirm the most recent snapshots are present in `DR_REGION` and KMS-encrypted.
   - Registry replica: confirm the DR registry is current (replication lag near zero) per `schema.ts`.
   - Record the freshest-recoverable timestamp per tenant tier — this is the basis for measured RPO.
4. SCALE UP THE WARM-STANDBY CELL. [APPROVAL GATE — AWS/cluster-mutating; Spacelift apply.] Via Terraform/Helm (`terraform/modules/cell/`, `terraform/modules/eks/`, `helm/arcadedb/values.yaml`) scale `CELL_ID` from standby to the full 3-node, one-per-AZ topology with prod sizing. Plan first; apply only after approval. Wait for all 3 pods `/ready` (HTTP 204) and a stable Raft leader.
5. PROMOTE THE DR CELL. [APPROVAL GATE — mutating.] Promote the standby cell to active for the geo's databases (bring up writable leader; replicas fan reads). Remember: WRITES go to the leader, READS fan to replicas; confirm exactly one leader per DB. If a DB is missing on DR, restore it via `restore-tenant` (target DB MUST NOT EXIST first) — do NOT restore over anything live. Restoring a per-DB ZIP is NOT instant: the WAL is excluded and HNSW/Lucene indexes + per-DB users must be REBUILT after the import before the DB is queryable, and that rebuild dominates restore time — budget it into RTO.
6. REPOINT THE REGISTRY. [APPROVAL GATE — mutating.] Flip the control plane to the in-geo DR registry replica so tenant->cell routing resolves to the promoted cell (`../../../control-plane/registry/schema.ts`, `../../../control-plane/router/index.ts`). Keep the kill-switch + per-tenant caps enforced. In-geo store only.
7. FLIP ROUTE 53. [APPROVAL GATE — AWS-mutating; Spacelift apply.] Switch the geo endpoint to the DR retrieval-proxy target (DR_REGION). Apply via GitOps/Terraform. Confirm the DR target is in-geo BEFORE applying. Record the time the flip completes.
8. SERVE SYNTHETIC TRAFFIC. Drive read + write probes for `SYNTHETIC_TENANTS` ONLY through the proxy against the promoted cell. Confirm writes land on the leader and reads succeed from replicas. NEVER route real tenant traffic.
9. MEASURE.
   - RTO = (time first synthetic request succeeds end-to-end on DR) - T0 (or - declared-incident time if simulating). Compare vs `TARGETS` per tier.
   - RPO = (drill cutover time) - (freshest-recoverable data timestamp from Step 3) per tier. Compare vs `TARGETS`.
   - Log both, plus any step that exceeded its sub-budget, into the drill record.
10. FAIL BACK. [APPROVAL GATE — mutating; reverse order.] Flip Route 53 back to `PRIMARY_REGION`; repoint the registry to primary; demote/return the DR cell to warm-standby (scale back down) via Terraform/Helm with reviewed plan + Spacelift approval. Reconcile any synthetic data written on DR so it does not propagate. Re-verify primary is serving and healthy.
11. CLOSE OUT. Capture measured RPO/RTO, gaps, and follow-up actions; update `../../../docs/assumptions.md` / ADR-0014 if reality differs from documented targets; close the change ticket.

MONTHLY companion test (lighter, do NOT skip): restore a RANDOM real tenant from backup into a throwaway/non-prod DB name using `restore-tenant` (target DB MUST NOT EXIST), REBUILD its HNSW/Lucene indexes + per-DB users (the ZIP excludes the WAL and does not carry usable indexes), then verify the restore opens and is queryable (run a real vector/text retrieval probe, not just an open), and drop the throwaway DB. This validates backup integrity AND that index-rebuild restore actually works between the quarterly full game-days.

## Verification
- All 3 DR pods report `/ready` (HTTP 204) and the cell shows a single stable Raft leader per DB.
- Synthetic read AND write probes succeed end-to-end through the proxy against the DR cell during the drill.
- Route 53 resolved the geo endpoint to the DR target during the window, then back to primary after fail-back (verify with `dig`/resolver from in-geo, and via the observability dashboards).
- Measured RPO and RTO are recorded for each tier and compared against `TARGETS`; any breach has a logged follow-up.
- DR data freshness evidence (CRR timestamps, EBS snapshot presence, registry lag) is captured.
- Post-failback: primary is serving real traffic, DR cell is back to warm-standby, and NO synthetic data leaked into production DBs.
- No residency violation occurred: every region touched is in `GEO` (`../../../terraform/modules/observability/`, `../../../docs/architecture.md`).

## Rollback / if it goes wrong
- ABORT criteria: residency check fails, DR cell can't reach 3-node quorum, sizing/OOM kills a pod, or any real-traffic exposure is detected. Stop forward steps immediately.
- Fast revert: re-run Step 10 (fail back) in reverse — Route 53 to primary, registry to primary, demote DR cell. Primary was never taken down, so this restores normal serving.
- If a DR DB restore went wrong: drop the bad DB (it must not exist to retry) and re-restore from the verified in-geo backup via `restore-tenant`, then rebuild HNSW/Lucene indexes + per-DB users; never restore over a partially-created DB.
- If quorum is unstable on DR: do not force a 2-node leader; scale back to warm-standby and treat as a finding (Prime Directive 3).
- If synthetic data leaked toward primary: halt fail-back propagation, identify affected DBs, and remediate per the registry/proxy audit before resuming.
- Capture root cause in the drill record and as a Spacelift/GitOps change note; raise an ADR update if the runbook itself was wrong.

## Related
- `../../../docs/adr/0014-dr-strategy-warm-standby.md` — warm-standby in-jurisdiction DR design (source of truth for this drill).
- `../../../docs/adr/0008-tenant-registry-dynamodb.md` — regional DynamoDB registry, in-geo replication only, never a global table.
- `restore-tenant` skill — used for the monthly random-tenant restore test and for any mid-drill DB restore (enforces "target DB must not exist").
- `../../../docs/assumptions.md`, `../../../docs/architecture.md` — RPO/RTO targets, geo topology, residency boundaries.
- `../../../terraform/modules/backup-dr/`, `.../cell/`, `.../eks/`, `.../observability/`, `../../../terraform/landing-zone/` — DR infra, CRR, snapshots, DNS.
- `../../../helm/arcadedb/values.yaml` — DR cell sizing/probes (`/ready` 204).
- `../../../control-plane/registry/schema.ts`, `../../../control-plane/router/index.ts` — registry repoint + per-tenant limits / kill-switch.
