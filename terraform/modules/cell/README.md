# Module: `cell`

The **heart of the platform.** One `cell` = one 3-node ArcadeDB Raft cluster in
its own namespace, with its own StorageClass, PodDisruptionBudget, default-deny
NetworkPolicy, namespace governance, and backup prefix (HLD §5.4). It is the unit
of **capacity, blast radius, and tenant placement**. Adding a cell is purely
additive (ADR-0021).

> **CTO-package status:** basic boilerplate template — validate-clean **offline**
> (typed kubernetes resources, no `kubernetes_manifest`), **not applied to AWS**.

## Invariants enforced as plan-time preconditions

The module **fails the plan** (a `terraform_data` precondition) if any prime
directive is violated — defence-in-depth alongside the `.claude/` hooks and the CI gates:

| Invariant | Rule | Source |
|---|---|---|
| **Residency** | `region ∈ allowed_regions` | prime directive #1, ADR-0007 |
| **Quorum** | prod `replicas >= 3` and `pdb_min_available >= 2` | prime directive #3 |
| **Version floor** | ArcadeDB tag is semver `>= 26.4.1` | ADR-0012 |
| **Sizing rule** | `pod_memory_limit_gib >= maxPageRAM + heap + overhead` | prime directive #7 |

Non-prod cells may run `replicas = 1` (single-node, no HA) to cut cost — the
quorum precondition only fires for `env = prod`.

## What it creates

| Resource | Notes |
|---|---|
| `kubernetes_namespace_v1` | The cell. PSA `restricted`; backup bucket/prefix + isolation annotations. |
| `kubernetes_storage_class_v1` | **gp3, KMS-encrypted, `WaitForFirstConsumer`, expandable, `Retain`** (AZ-pinned volumes; never auto-delete a DB volume). |
| `kubernetes_pod_disruption_budget_v1` | `minAvailable = 2` — protects quorum during drains/upgrades. |
| `kubernetes_network_policy_v1` ×3 | **default-deny** + allow-intra-cell (Raft peers + DNS) + allow-platform-ingress (control-plane/retrieval/observability → 2480/7687 only; never public). |
| `kubernetes_resource_quota_v1` | Namespace quota (belt-and-braces; engine has no per-DB quotas — F2). |
| `helm_release.arcadedb` | Optional (Argo CD manages it in the GitOps model). Wires image (digest-pinnable), replicas, `maxPageRAM`/heap/`txWalFlush`, resources (no tight CPU limit), persistence, DB-node toleration. |

## Tier-driven defaults

- `txWalFlush` derives from `tier`: **enterprise = 2 (fsync)**, standard = 1 (ADR-0013) — override with `tx_wal_flush`.
- `cell_isolation = namespace` (pooled) or `cluster` (dedicated EKS for enterprise, ADR-0004).

## Usage — a standard pooled prod cell

```hcl
module "cell_std_01" {
  source = "../../modules/cell"

  cell_id         = "kb-eu-prod-std-01"
  geo             = "eu"
  env             = "prod"
  region          = "eu-central-1"
  allowed_regions = ["eu-central-1", "eu-west-1"]
  tier            = "standard"

  replicas             = 3
  arcadedb_image_tag   = "26.4.1"
  arcadedb_image_digest = "sha256:REPLACE_WITH_MIRRORED_DIGEST" # prod: pin by digest

  # Sizing (r7g.2xlarge / A13): 32 + 8 + 6 = 46 <= 46 limit ✔
  maxpage_ram_gib      = 32
  heap_gib             = 8
  overhead_gib         = 6
  pod_memory_limit_gib = 46

  ebs_kms_key_arn = module.kms.ebs_key_arn
  backup_bucket   = module.backup_dr.backup_bucket_name

  # Argo manages the release in GitOps; here we just create the namespace scaffolding:
  manage_helm_release = false
}
```

## Usage — a non-prod single-node cell (cost)

```hcl
module "cell_dev" {
  source          = "../../modules/cell"
  cell_id         = "kb-eu-dev-std-01"
  geo             = "eu"
  env             = "dev"
  region          = "eu-central-1"
  allowed_regions = ["eu-central-1", "eu-west-1"]
  replicas        = 1   # allowed in non-prod
  # ...sizing scaled down...
}
```

## Key outputs (feed the cell catalog / registry)

`cell_id`, `namespace`, `tier`, `cell_isolation`, `replicas`, `tx_wal_flush`,
`image_ref`, `storage_class_name`, `backup_prefix`, `headless_service_fqdn`,
`sizing_summary`.

## Validate (no AWS, no cluster)

```bash
tofu init -backend=false && tofu validate && tflint
```

## Phase-0/LLD follow-ups

- Align the Helm `values` block exactly with the chart's schema (see [helm/arcadedb/values.yaml](../../../helm/arcadedb/values.yaml)).
- Add the internal Service/NLB + PrivateLink wiring (ADR-0026) — kept out of the
  cell to preserve "no public DB".
- Wire the backup CronJob sidecar (it lives in `backup-dr` / the chart).
- Register cell outputs into the DynamoDB cell catalog via the control plane.
