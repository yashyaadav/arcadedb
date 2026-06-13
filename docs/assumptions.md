# Assumptions & Decision Log

> **Living document.** Part of the CTO approval package (Phase D). Every assumption
> the design rests on is recorded here with **why we made it**, **what breaks if it's
> wrong**, our **confidence**, a **validation owner + when**, and a link to the ADR(s)
> it feeds. **Rule (enforced as a `CLAUDE.md` convention + CI check): no assumption
> stands without an entry here, and no decision lands without an ADR stating its reasoning.**
>
> Today's date for this revision: **2026-06-13**. Relative dates are converted to absolute.

## How to use this log

- When you make a new assumption, add a row to the [register](#assumptions-register) and (if it drives a decision) link it from the relevant ADR's "Assumptions it rests on" section.
- When an assumption is **validated**, update its **Status** to `validated (YYYY-MM-DD)` and note the evidence; if **invalidated**, mark it and open/append the ADR(s) it affects (the **Impact if wrong** column tells you what to revisit).
- Confidence: **High** (well-supported / business-confirmed) · **Med** (reasonable default, plausibly wrong) · **Low** (guess, needs validation before it hardens).
- Review triggers: each assumption is revisited at the **validation milestone** below and at any ADR review-trigger that references it.

---

## Assumptions register

| ID | Assumption | Why we assume / chose it (reasoning) | Impact if wrong | Confidence | Validate (owner / when) | Status | Links |
|---|---|---|---|---|---|---|---|
| **A1** | **Budget:** cost-conscious, not cost-starved. | Pay for managed control-plane (AMP/AMG/Secrets) + Graviton, defer premium tiers → fastest safe baseline. | Instance tiers / HA-in-dev change; may need to drop managed services for self-hosted. | Med | Finance, at sign-off | Open | [ADR-0017](adr/0017-observability-amp-amg.md), [ADR-0018](adr/0018-secrets-secrets-manager-eso.md), §10 |
| **A2** | **Per-tenant size:** standard 1–20 GB (p95 < 50 GB), enterprise ≤ ~500 GB. **Most load-bearing assumption.** | Sets cell capacity caps + node sizing; most B2B KBs are small-to-mid. | Re-derive caps, re-size nodes, cost shift; a tenant > one node forces a dedicated cell / vector externalisation. | Med | Platform owner — measure first ~20 tenants (Phase 2) | Open | [ADR-0003](adr/0003-tenancy-isolation-tiered.md), §5.4, F-scaling |
| **A3** | **Launch footprint:** 50 standard + 2–3 enterprise tenants per geo. | Business-confirmed; anchors capacity + cost. | Cell count + cost shift. | High | **Confirmed by business** | Validated (2026-06-13) | §5.4, §10 |
| **A4** | **Workload shape:** read-heavy RAG, write bursts on ingest/re-index. | Drives read-replica fan-out + single-leader writes + `txWalFlush` tiering. | Write-ceiling planning changes; may need more cells sooner. | Med | Load test (Phase 1–2) | Open | [ADR-0013](adr/0013-durability-txwalflush-per-tier.md), §5.5 |
| **A5** | **ArcadeDB leader-forwarding is reliable for writes.** | Lets the client route via the Service (simpler router). | Client must discover the leader itself; router gets more complex. | Med | Phase-1 validation on the pinned version | Open | §5.4, [ADR-0012](adr/0012-version-floor-26-4-1.md) |
| **A6** | **Native HNSW recall/latency/RAM is acceptable** for GraphRAG. | Unified engine = fewer moving parts, one residency/HA story. | Take the externalise-vectors escape hatch (OpenSearch Serverless / pgvector). | Low | Phase-2 benchmark **gate** on real KB data | Open | [ADR-0024](adr/0024-kb-retrieval-native-graphrag.md), §6 |
| **A7** | **Compliance = SOC 2 Type II + GDPR now; HIPAA designed-for, not implemented.** | Standard B2B path; HIPAA via dedicated cells when needed. | Add BAA / dedicated cells / extra controls; possibly re-scope encryption + audit. | Med | Legal, at sign-off | Open | §7.1, [ADR-0003](adr/0003-tenancy-isolation-tiered.md) |
| **A8** | **Scope = data-layer platform; app in a separate account via in-geo PrivateLink.** | Cleanest hand-over + blast-radius/billing separation; residency-preserving. | Platform must own more (ingestion/metering/RTBF workflow); re-scope §8 seams. | Med | App team, at sign-off | Open | [ADR-0025](adr/0025-scope-data-layer-platform.md), [ADR-0026](adr/0026-app-connectivity-privatelink.md), §8 |
| **A9** | **euc1/euw1, use1/usw2 have full service parity** (AMP/AMG/EKS/Secrets/Backup GA). | Keeps EU DR in-EU; standard, well-supported regions. | Swap regions; possibly a different in-geo DR pair. | High | Platform — Phase-0 date-stamped service-availability check | Open | [ADR-0006](adr/0006-regions-eu-us-pairs.md), §5.2 |
| **A10** | **Cost basis = on-demand list price, both geos, pre-Savings-Plans.** | Conservative upper bound for planning. | Real bill is lower with Savings Plans / RIs (−30–50 % on compute). | High | FinOps review (Phase 4) | Open | §10 |
| **A11** | **CI/Git host = GitHub (Actions).** | Stated requirement; broad ecosystem for the policy-gate actions used. | Swap the CI section only (GitLab/Bitbucket pipelines); skill/hook refs unchanged. | High | Confirmed (problem statement) | Validated (2026-06-13) | §7.6 |
| **A12** | **Cell capacity caps:** ~150 standard DBs OR ~60 % `maxPageRAM` committed OR ~70 % disk (whichever trips first). | Starting heuristic derived from A2; bounds placement since there are no per-DB quotas (F2). | Re-derive from real per-tenant size + working-set metrics; cell count shifts. | Low | Platform — tune from AMP metrics after first ~20 tenants | Open | §5.4, [ADR-0003](adr/0003-tenancy-isolation-tiered.md) |
| **A13** | **DB node baseline = `r7g.2xlarge`** (64 GiB) → `maxPageRAM=32g`, `-Xmx=8g`, pod limit ~46–48 GiB. | Best price-performance for a RAM/throughput-bound JVM; satisfies the sizing rule (prime directive #7). | Re-size nodes; cost shift; possibly `io2` for IOPS-bound tenants. | Med | Platform — Phase-1 sizing validation + load test | Open | [ADR-0009](adr/0009-node-compute-graviton.md), §5.5 |
| **A14** | **A single regional EKS cluster can safely back many pooled cells** (namespace isolation + NetworkPolicy + per-DB users is sufficient for *standard* tenants). | Big cost saving; blast radius already bounded by the per-cell Raft group; the trusted boundary for sensitive data is the dedicated cell anyway. | Move more tenants to dedicated clusters; cost up. | Med | Security review (Phase 2) + continuous isolation probe | Open | [ADR-0004](adr/0004-cell-backing-namespace.md), §7.1 |
| **A15** | **Backup cadence (standard 6 h / enterprise 1 h) meets tenants' RPO expectations.** | Tiered to balance cost vs RPO; no PITR available natively (F5). | Tighten cadence (cost up) or add the re-ingestable-source escape hatch for sub-hour RPO. | Med | Platform + product — confirm RPO with first enterprise tenants | Open | [ADR-0015](adr/0015-backup-cronjob-sidecar.md), §7.4 |
| **A16** | **`txWalFlush=0/1` is acceptable for standard tenants; `=2` (fsync) only for enterprise/regulated.** | Throughput for standard, strict durability where it's paid for. | More tenants need fsync → lower write throughput / bigger nodes. | Med | Phase-1 durability test + per-tenant SLA | Open | [ADR-0013](adr/0013-durability-txwalflush-per-tier.md), §5.5 |
| **A17** | **The `/prometheus` MIME-type bug persists on the pinned version** and needs a scrape-side workaround. | Documented known bug (F6); cheaper to assume present and verify than to assume fixed. | Drop the workaround if a future pinned version fixes it (revisit at each version bump). | Med | Platform — Phase-1 scrape validation | Open | [ADR-0017](adr/0017-observability-amp-amg.md), §7.5 |

---

## Validation milestones (when each assumption gets tested)

| Milestone | Assumptions validated |
|---|---|
| **At CTO sign-off** | A1, A7, A8 (business/legal/app-team confirmations) |
| **Phase 0** | A9 (date-stamped service-availability check) |
| **Phase 1** | A5, A13, A16, A17 (single-cell HA, sizing, durability, scrape) |
| **Phase 2** | A2, A4, A6 (real tenant sizes, workload shape, the **vector benchmark gate**), A12, A14, A15 |
| **Phase 4** | A10 (FinOps review with real bill) |

## Change log

| Date | Change |
|---|---|
| 2026-06-13 | Seeded from plan §5.2 + §8; added in-line assumptions A11–A17 (CI host, caps, node baseline, EKS multi-cell backing, backup cadence, txWalFlush tiering, MIME bug). |
