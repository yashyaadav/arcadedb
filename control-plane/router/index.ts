/**
 * Placement + leader-aware Router + RetrievalProvider (interface stub).
 *
 * CTO-package status: INTERFACE STUB (HLD §5.4, §6, §7.2). Implementation in
 * Phase 2. Encodes three ArcadeDB-specific rules:
 *   1) Residency: never place/route a tenant outside its home_geo (ADR-0007).
 *   2) Writes → Raft leader; reads → replicas (read/write split, F1).
 *   3) Per-tenant runtime governance (timeouts/limits/breaker/kill-switch, ADR-0027).
 */

import type {
  CellRecord,
  ConsistencyLevel,
  Env,
  Geo,
  TenantRecord,
  Tier,
} from "../registry/schema";

export interface PlacementRequest {
  tenant_id: string;
  home_geo: Geo;
  env: Env;
  tier: Tier;
  projected_bytes: number;
}

export interface PlacementResult {
  cell_id: string;
  db_name: string;
}

/**
 * Placement: pick a cell by geo + env + tier + has_capacity (least-loaded).
 * Big tenants (projected > ~50 GB) or enterprise tier → dedicated cell, never
 * a pooled cell. Adding a cell is additive (ADR-0021).
 */
export interface Placement {
  /** @throws if no in-geo cell can host the tenant (caller triggers add-cell). */
  place(req: PlacementRequest): Promise<PlacementResult>;
  /** True if the cell has headroom under ALL caps (A12). */
  hasCapacity(cell: CellRecord, projectedBytes: number): boolean;
}

export type Operation = "read" | "write";

export interface RouteTarget {
  /** Headless-service FQDN of the target pod/endpoint. */
  endpoint: string;
  role: "leader" | "replica";
}

/**
 * Router: resolves tenant_id → cell + db_name (cached), and picks an endpoint by
 * operation. Writes go to the leader (validate leader-forwarding on the pinned
 * version, A5); reads fan to replicas with the requested consistency.
 */
export interface Router {
  resolve(tenantId: string): Promise<TenantRecord>;
  /** Residency guard: throws if tenant.home_geo !== this router's geo. */
  assertInGeo(tenant: TenantRecord): void;
  route(
    tenantId: string,
    op: Operation,
    consistency?: ConsistencyLevel,
  ): Promise<RouteTarget>;
}

/**
 * Per-tenant runtime governance (ADR-0027). The engine has no per-DB quotas
 * (F2), so the proxy enforces these. A degrading tenant is shed/isolated; a
 * manual kill-switch suspends a tenant's traffic (incident-triage skill).
 */
export interface TenantGovernance {
  queryTimeoutMs: number;
  maxResultRows: number;
  maxConcurrency: number;
  qpsLimit: number;
  heavyOpBudget: number;
  /** Circuit-breaker: shed/isolate when a tenant degrades co-tenants. */
  circuitBreaker: { errorRateThreshold: number; latencyP95MsThreshold: number };
}

export interface KillSwitch {
  suspend(tenantId: string, reason: string): Promise<void>;
  resume(tenantId: string): Promise<void>;
  isSuspended(tenantId: string): Promise<boolean>;
}

/**
 * RetrievalProvider (ADR-0024) — the swappable seam that lets us externalise
 * vectors (OpenSearch Serverless / Aurora pgvector, in-geo) without an app
 * rewrite if the Phase-2 native-HNSW benchmark fails (A6).
 */
export interface RetrievalProvider {
  readonly kind: "arcadedb-native" | "opensearch-serverless" | "aurora-pgvector";
  /** GraphRAG: vector recall → graph traversal → full-text rerank. */
  retrieve(input: RetrievalInput): Promise<RetrievalResult>;
  upsertVectors(tenantId: string, items: VectorItem[]): Promise<void>;
}

export interface RetrievalInput {
  tenantId: string;
  query: string;
  topK: number;
  expandGraphHops?: number;
  rerank?: boolean;
}

export interface VectorItem {
  id: string;
  embedding: number[];
  metadata?: Record<string, unknown>;
}

export interface RetrievalResult {
  hits: Array<{ id: string; score: number; content: string }>;
  latencyMsByHop: { vector: number; graph: number; rerank: number };
}
