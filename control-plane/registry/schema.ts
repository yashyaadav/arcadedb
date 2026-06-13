/**
 * Tenant Registry + Cell Catalog — type definitions (interface stub).
 *
 * CTO-package status: INTERFACE STUB. These types define the control-plane data
 * contract (HLD §5.4). The backing store is regional DynamoDB — NEVER a global
 * table (residency, ADR-0008). Implementation lands in Phase 2.
 *
 * Residency invariant: a tenant's records live only in their `home_geo`'s
 * regional table. The router refuses cross-geo placement (defence in depth with
 * the SCP + CI gate, ADR-0007).
 */

/** Hard residency boundary. */
export type Geo = "eu" | "us";

export type Env = "dev" | "stage" | "prod";

/** Tenancy tier drives placement, durability, encryption, and backup cadence. */
export type Tier = "standard" | "enterprise";

export type TenantStatus =
  | "provisioning"
  | "active"
  | "suspended" // kill-switch / governance (ADR-0027)
  | "deprovisioning"
  | "erased"; // RTBF/DSAR complete (deletion evidence emitted)

/** Read consistency the retrieval layer requests (read/write split, §5.4). */
export type ConsistencyLevel = "read_your_writes" | "eventual" | "strong";

/** ADR-0013: WAL flush per tier. 0/1 standard, 2 (fsync) enterprise. */
export type TxWalFlush = 0 | 1 | 2;

/**
 * One tenant = one virtual ArcadeDB database.
 * DynamoDB: PK = `tenant_id`. GSI1 = `home_geo#env#tier#status` (placement queries).
 */
export interface TenantRecord {
  tenant_id: string;
  home_geo: Geo; // residency anchor — immutable after creation
  env: Env;
  tier: Tier;
  cell_id: string; // which cell hosts this tenant's DB
  db_name: string; // the ArcadeDB database name (one per tenant)
  status: TenantStatus;
  consistency_level: ConsistencyLevel;
  /** Pointer to the Secrets Manager secret holding this tenant's DB creds. */
  secret_arn_pointer: string;
  /** Last observed size (bytes) — feeds the capacity model (A2/A12). */
  size_bytes_last: number;
  /** Backup policy id (cadence + retention tier). */
  backup_policy: string;
  /** Per-DB schema version (fan-out migration runner, ADR-0028). */
  schema_version: number;
  created_at: string; // ISO-8601
  updated_at: string; // ISO-8601
}

/**
 * One cell = one 3-node Raft cluster (HLD §5.4). The cell catalog drives
 * placement + GitOps (Argo ApplicationSet per cell, ADR-0021).
 * DynamoDB: PK = `cell_id`. GSI1 = `geo#env#tier#status` (least-loaded queries).
 */
export interface CellRecord {
  cell_id: string;
  geo: Geo;
  env: Env;
  tier: Tier;
  /** ADR-0004: pooled namespace cell vs dedicated EKS cluster. */
  cell_isolation: "namespace" | "cluster";
  status: "provisioning" | "available" | "draining" | "full" | "retired";
  namespace: string;
  /** Effective durability for this cell (ADR-0013). */
  tx_wal_flush: TxWalFlush;
  /** Capacity model (A12). A cell is "full" when ANY cap trips. */
  caps: CellCaps;
  usage: CellUsage;
  /** S3 backup prefix: cell/<cell_id> (ADR-0015). */
  backup_prefix: string;
  arcadedb_image_ref: string; // digest-pinned (ADR-0012)
  created_at: string;
  updated_at: string;
}

/** Placement caps — starting heuristics tied to A2 (tune from metrics). */
export interface CellCaps {
  max_standard_dbs: number; // ~150
  max_page_ram_commit_ratio: number; // ~0.60 of maxPageRAM
  max_disk_used_ratio: number; // ~0.70
}

export interface CellUsage {
  db_count: number;
  page_ram_commit_ratio: number;
  disk_used_ratio: number;
  /** Tenants projected > ~50 GB are never placed in a pooled cell. */
  largest_tenant_bytes: number;
}

/** App-layer DB-access audit event — the SOC2 substitute for engine audit (F4/§7.1). */
export interface AuditEvent {
  ts: string; // ISO-8601
  geo: Geo;
  tenant_id: string;
  cell_id: string;
  db_name: string;
  principal: string; // who
  operation: string; // create-db | query | alter-user | drop-db | restore | ...
  outcome: "success" | "denied" | "error";
  request_id: string;
  /** For erasure (RTBF/DSAR): evidence id + certificate pointer. */
  erasure_evidence_id?: string;
}

/** Per-tenant metered usage (billing seam + noisy-neighbour signal, §7.5). */
export interface UsageMeter {
  ts: string;
  geo: Geo;
  tenant_id: string;
  cell_id: string;
  query_count: number;
  query_p95_ms: number;
  write_volume_bytes: number;
  vector_ops: number;
  storage_bytes: number;
}
