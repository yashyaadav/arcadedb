---
name: add-cell
description: Scale a geo's capacity out by standing up a brand-new ArcadeDB cell (a 3-node Raft cluster in its own namespace) and registering it for tenant placement. Use when an in-geo cell is full / nearing a placement cap, when onboarding a tenant that needs a dedicated (enterprise/big) cell, or when Placement.place() throws "no in-geo cell can host".
---

# Add a cell (scale out)

> Stand up a new cell to add capacity in one geo. Adding a cell is **purely additive and zero-downtime** — no existing tenant, DB, or Raft group is touched. **Phase note:** the Terraform/apply steps MUTATE AWS + the cluster and are **out of scope until after CTO sign-off** and require **mandatory Spacelift prod approval (prime directive #6)**. Until then, run plan-only and stop at the approval gate.

## Prerequisites

- You know **why** you are adding a cell (read [`cell-capacity-report`](../cell-capacity-report/SKILL.md) first — a cell is `full` when ANY cap trips: `max_standard_dbs`, `max_page_ram_commit_ratio`, `max_disk_used_ratio`). Scaling by adding cells is the ONLY horizontal scale lever — a single cell has a single-leader write ceiling and a DB cannot be split across nodes.
- Repo access with the **cell module** ([`../../../terraform/modules/cell`](../../../terraform/modules/cell)), the **GitOps repo** (Argo CD per-cell `ApplicationSet`, [ADR-0021](../../../docs/adr/0021-gitops-argocd.md)), and the **cell catalog** (regional DynamoDB `CellRecord`, [`../../../control-plane/registry/schema.ts`](../../../control-plane/registry/schema.ts)).
- Spacelift access for the target geo's stack (plan for everyone; **apply needs a manual approver**, [ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md)).
- `kubectl` context for the target **in-geo** regional EKS cluster (or, for `cell_isolation=cluster`, the dedicated enterprise cluster — [ADR-0004](../../../docs/adr/0004-cell-backing-namespace.md)).
- A KMS key ARN in the **target geo** for EBS encryption (prime directive #5).

## Inputs

| Input | Example | Notes |
|---|---|---|
| `cell_id` | `kb-eu-prod-std-02` | Unique, kebab, `^[a-z][a-z0-9-]{4,50}$`. Follow `kb-<geo>-<env>-<role>-NN`. Must NOT collide with any existing/retired catalog entry. |
| `geo` | `eu` \| `us` | Residency boundary. Must match the control plane / state bucket you target. |
| `env` | `prod` | `prod` forces quorum (replicas≥3, PDB minAvailable≥2). |
| `region` | `eu-west-1` | Must be in `allowed_regions` for the geo (plan precondition + SCP). |
| `tier` | `standard` \| `enterprise` | Enterprise → typically `cell_isolation=cluster`, fsync durability. |
| `cell_isolation` | `namespace` \| `cluster` | Default `namespace` (pooled). `cluster` = dedicated EKS for enterprise/regulated. |
| Sizing | maxpage 32 / heap 8 / overhead 6 / **limit 46** GiB | `pod_memory_limit_gib >= maxpage_ram_gib + heap_gib + overhead_gib` (prime directive #7). |
| `ebs_kms_key_arn` | `arn:aws:kms:eu-west-1:ACCOUNT_ID:key/...` | In-geo KMS key. |

## Safety checks (MUST pass before proceeding)

- **Residency (prime directive #1):** `region` ∈ the geo's `allowed_regions`; KMS key, EKS cluster, and DynamoDB catalog table are all in the SAME geo. NO EU↔US data path. The cell module fails the plan if `region ∉ allowed_regions`; do not rely on that alone — verify by eye.
- **Quorum (prime directive #3):** for `env=prod`, `replicas=3` (one per AZ, 3 distinct AZs) and `pdb_min_available=2`. Non-prod MAY be single-node.
- **Sizing (prime directive #7):** confirm `pod_memory_limit_gib >= maxpage_ram_gib + heap_gib + overhead_gib`. Cross-check the module's `sizing_summary` output (`required_min_gib` vs `pod_memory_limit_gib`) so a too-small pod cannot OOM-kill and break quorum.
- **No public DB (prime directive #4):** the cell module's default-deny NetworkPolicy stays on; ports 2480/2424/2434/5432/6379/7687 are NEVER on a public subnet/LB. Ingress limited to `control-plane`, `retrieval`, `observability`.
- **Encrypt everything (prime directive #5):** `ebs_kms_key_arn` set; gp3-KMS StorageClass managed. The engine provides no native encryption.
- **Version floor (prime directive #2 / [ADR-0012](../../../docs/adr/0012-version-floor-26-4-1.md)):** image tag/digest is a pinned semver **≥ 26.4.1**, never `latest`. (No re-audit of cross-DB isolation is required here — this cell is brand new and holds no tenants yet; that re-audit is triggered by **upgrades**, see [`upgrade-arcadedb`](../upgrade-arcadedb/SKILL.md).)
- **No click-ops (prime directive #6):** every change lands via Terraform + GitOps + the catalog. Plan → approve → apply through Spacelift; **no manual `kubectl apply` of the StatefulSet, no console edits.**
- **Additive guarantee:** this skill creates a NEW namespace/StatefulSet/PVCs/Raft group/backup prefix/catalog row only. It must NOT edit, scale, or restart any existing cell. If your diff touches an existing cell's resources, STOP.
- **`cell_id` uniqueness:** confirm no `CellRecord` already exists with this `cell_id` (including `status=retired`) — IDs are not reused.

## Steps

1. **Justify + size.** Run [`cell-capacity-report`](../cell-capacity-report/SKILL.md) for the geo/tier to confirm a real capacity need and to pick caps. Choose `cell_id`, `region`, `tier`, `cell_isolation`, and sizing per the Inputs table.
2. **Add the cell module instance (Terraform).** In the target geo/env environment config, add a `module "<cell_id>"` block sourcing [`../../../terraform/modules/cell`](../../../terraform/modules/cell) with:
   - `cell_id`, `geo`, `env=prod`, `region`, and `allowed_regions` (in-geo).
   - `replicas = 3`, `pdb_min_available = 2` (prod quorum).
   - `arcadedb_image_tag = "26.4.1"` (or higher) — pin a digest in prod (`arcadedb_image_digest`).
   - Sizing satisfying prime directive #7 (e.g. maxpage 32 / heap 8 / overhead 6 / limit 46).
   - `manage_storage_class = true`, `ebs_kms_key_arn = <in-geo key>` (gp3-KMS).
   - `manage_helm_release = false` (Argo CD owns the release — GitOps, [ADR-0021](../../../docs/adr/0021-gitops-argocd.md)).
   - `enable_default_deny_networkpolicy = true`; default `allowed_ingress_namespaces`.
   - `backup_bucket`/`backup_prefix` from the geo's [`backup-dr`](../../../terraform/modules/backup-dr) module (defaults to `cell/<cell_id>`, [ADR-0015](../../../docs/adr/0015-backup-cronjob-sidecar.md)).
3. **Add the Argo CD `ApplicationSet` generator entry (GitOps).** In the per-cell `ApplicationSet`, add ONE generator entry for `<cell_id>` (geo/env/tier overlay, in-geo, sizing values mirroring step 2). This templates the ArcadeDB Helm release for the new cell. Promote config only (dev→stage→prod × eu/us) — **never data** ([ADR-0021](../../../docs/adr/0021-gitops-argocd.md)).
4. **Register the cell in the catalog (`status=available`).** Add a `CellRecord` (PK `cell_id`) to the **regional** DynamoDB cell catalog (NEVER a global table — residency, [ADR-0008](../../../docs/adr/0008-tenant-registry-dynamodb.md)) with `geo`, `env`, `tier`, `cell_isolation`, `namespace`, `tx_wal_flush` (per tier, [ADR-0013](../../../docs/adr/0013-durability-txwalflush-per-tier.md)), `caps`, `backup_prefix`, digest-pinned `arcadedb_image_ref`, and **`status = "available"`** so Placement starts routing NEW tenants here. (No native per-DB quotas exist — F2 — so caps in the catalog + the retrieval proxy are the only capacity controls.)
5. **Plan + review (no mutation yet).** Open the change as a PR; let Spacelift produce a plan for the geo stack (graph: landing-zone → network → eks → **cell**). Run [`review-terraform-plan`](../review-terraform-plan/SKILL.md) — it flags a DB SG opened to the world, residency violations, destroys of stateful resources, and KMS/role changes. **Confirm the plan only CREATES** the new cell's resources and touches NO existing cell.
6. **⛔ APPROVAL GATE — AWS-MUTATING, POST-CTO-SIGN-OFF ONLY.** Get the mandatory **manual prod approval in Spacelift** (prime directive #6 / [ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md)). Do not proceed until approved and until this phase is in scope.
7. **Apply (Spacelift).** Approver runs the Spacelift apply. Terraform creates the namespace, gp3-KMS StorageClass, PDB, default-deny NetworkPolicy, and governance objects; **Argo CD reconciles the new `ApplicationSet` entry** and deploys the ArcadeDB StatefulSet (3 pods, one per AZ) + PVCs.
8. **Let the cell form its Raft group.** The 3 pods discover peers via the headless Service (`<cell_id>-headless.<namespace>.svc.cluster.local`) and elect a leader. This is a fresh, empty cluster — it holds no tenant DBs yet.

## Verification

- **Raft formed, 3/3 healthy:** all 3 pods Ready; the cell elected exactly one leader (its own new Raft group, isolated from every other cell).
  ```bash
  kubectl -n <namespace> get statefulset,pods -o wide   # 3/3, spread across 3 distinct AZs
  kubectl -n <namespace> get pdb                          # ALLOWED DISRUPTIONS respects minAvailable=2
  ```
- **`/ready` on all 3 pods returns HTTP 204:**
  ```bash
  for p in 0 1 2; do kubectl -n <namespace> exec <cell_id>-$p -- \
    curl -s -o /dev/null -w '%{http_code}\n' localhost:2480/ready; done   # expect 204 ×3
  ```
- **Storage encrypted + gp3-KMS:** PVCs Bound to the cell's gp3-KMS StorageClass; underlying EBS volumes encrypted with the in-geo KMS key.
- **No public exposure:** no Service/LB places a DB port (2480/2424/2434/5432/6379/7687) on a public subnet; default-deny NetworkPolicy present (prime directive #4).
- **Catalog reflects reality:** `CellRecord` for `<cell_id>` is `status=available`, correct `geo`/`env`/`tier`, in the **regional** table.
- **Placement uses it / existing cells untouched:** a synthetic in-geo placement request for the matching env+tier resolves to `<cell_id>` (least-loaded). Confirm NO existing cell changed — its pods did not restart, its leader did not change, its tenants saw zero downtime. (Real tenants land here only on next provision via [`provision-tenant`](../provision-tenant/SKILL.md).)

## Rollback / if it goes wrong

Because the cell is additive and empty, rollback is clean and low-risk:

- **Catalog first:** flip the `CellRecord` to `status=draining` (or `provisioning`) so Placement stops sending NEW tenants here. The cell holds no tenants, so nothing to drain.
- **Revert GitOps + Terraform:** revert the PR — remove the `ApplicationSet` generator entry and the cell module block. Re-plan and re-apply through Spacelift (**manual prod approval again**). Argo CD prunes the StatefulSet; Terraform destroys the namespace/PVCs/StorageClass/NetworkPolicy. Then delete the `CellRecord`.
- **Quorum never formed / `/ready` not 204:** check pod scheduling across 3 AZs, memory limits (OOM = under-sized vs the sizing rule, prime directive #7), and KMS key access for EBS. Fix the inputs and re-plan; do NOT hand-edit the StatefulSet (no click-ops).
- **Never** add tenants to a cell that failed verification — for proper teardown of a populated cell use [`retire-cell`](../retire-cell/SKILL.md) (drain → migrate tenants → retire).
- This skill only ever creates resources; it cannot have damaged an existing cell. If a diff/plan ever showed an existing cell being modified or destroyed, you stopped at step 5 — nothing was applied.

## Related

- [`retire-cell`](../retire-cell/SKILL.md) — drain + decommission a cell (the inverse).
- [`cell-capacity-report`](../cell-capacity-report/SKILL.md) — decide when a new cell is needed.
- [`provision-tenant`](../provision-tenant/SKILL.md) — places a new tenant DB onto an `available` cell.
- [`review-terraform-plan`](../review-terraform-plan/SKILL.md) — gate the plan before approval.
- [ADR-0004](../../../docs/adr/0004-cell-backing-namespace.md) — cell = namespace (cluster for enterprise).
- [ADR-0021](../../../docs/adr/0021-gitops-argocd.md) — Argo CD ApplicationSet per cell (additive add-cell).
- [ADR-0020](../../../docs/adr/0020-tf-runner-spacelift.md) — Spacelift (mandatory prod approval).
- [ADR-0008](../../../docs/adr/0008-tenant-registry-dynamodb.md) — regional DynamoDB registry/cell catalog.
- Module: [`../../../terraform/modules/cell`](../../../terraform/modules/cell) · Helm values: [`../../../helm/arcadedb/values.yaml`](../../../helm/arcadedb/values.yaml) · Architecture: [`../../../docs/architecture.md`](../../../docs/architecture.md)
