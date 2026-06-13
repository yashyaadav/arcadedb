---
name: tenant-erasure
description: Execute the data-layer erasure primitives (DB drop, KMS crypto-shred, targeted record purge) that the app's RTBF/DSAR workflow calls into, and emit deletion evidence. Use ONLY when a documented Right-to-be-Forgotten / Data Subject Access Request erasure has been legally authorized — never for routine offboarding.
---

# Tenant erasure (RTBF / DSAR)

> Performs the IRREVERSIBLE data-layer erasure primitives behind the app's RTBF/DSAR workflow (HLD §7.1): whole-tenant DB DROP, per-tenant KMS CRYPTO-SHRED, or targeted RECORD PURGE — always with deletion evidence. Distinct from normal deprovision (see `deprovision-tenant`), which is a reversible-ish lifecycle teardown; erasure is a compliance act with proof obligations. PHASE NOTE: every mutating step here destroys customer data and/or AWS resources and is OUT OF SCOPE until the CTO package is applied and the request is legally authorized; mutating steps are gated and call out approval.

## Prerequisites
- A legal/compliance-issued erasure ticket with: tenant ID, requester identity, legal basis (e.g. GDPR Art. 17), erasure SCOPE (whole-tenant vs. specific data subject / record set), and the geo (EU or US).
- Confirmation of the tenant's home region from the registry (`../../../control-plane/registry/schema.ts`). EU tenants are processed entirely from EU accounts/regions — residency (Directive 1) means NO data, log, or evidence artifact crosses EU<->US.
- Read access to HLD §7.1 and ADR-0025 (the erasure/DSAR seam this skill implements); ADR-0003 (tiered isolation — which tenants have a dedicated per-tenant CMK); ADR-0007 (residency enforcement, which backs the in-geo boundary below).
- Access to the control-plane deprovision state machine `../../../control-plane/provisioning/deprovision.asl.json` (this skill drives it; it is not run by hand against the cluster).
- AWS auth (SSO) into the correct tenant geo account (`ACCOUNT_ID`), region matching the tenant geo.
- `kubectl` context for the cell hosting the tenant (one virtual DB per tenant); ArcadeDB admin credentials for that cell pulled from KMS-encrypted Secrets (NOT the set-once root; a provisioned admin user — Directive 5 / ArcadeDB root-is-set-once gotcha).
- For crypto-shred mode (enterprise tier): the ARN of the tenant's dedicated per-tenant CMK.

## Inputs
- `TENANT_ID` — the tenant whose data is to be erased.
- `GEO` — `eu` or `us` (selects account/region; enforces residency).
- `MODE` — one of: `db-drop` (whole-tenant DB DROP), `crypto-shred` (destroy per-tenant CMK; enterprise only), `record-purge` (targeted records within the tenant DB).
- `SCOPE` — for `record-purge`: the precise query/predicate or record set (data-subject keys) authorizing exactly what is deleted. For `db-drop`/`crypto-shred`: must equal "whole-tenant".
- `LEGAL_TICKET_ID` — the authorization reference (recorded in evidence).
- `EVIDENCE_RECIPIENTS` — where the deletion certificate is delivered (in-geo only).

## Safety checks (MUST pass before proceeding)
- [ ] **Documented legal authorization present.** A valid erasure ticket with requester, legal basis, and explicit SCOPE exists. NO authorization → STOP. (HLD §7.1; the app owns the RTBF/DSAR *workflow*, this skill is the data-layer *mechanism* per ADR-0025)
- [ ] **No active legal hold.** Query the registry / hold register for the tenant and any in-scope subjects. If a legal hold OR litigation hold is set, erasure is FORBIDDEN — STOP and escalate to legal. (HLD §7.1; the deprovision/erasure state machine's `FinalBackup` step is legal-hold aware)
- [ ] **Residency boundary.** `GEO` matches the tenant's home geo in the registry; you are authenticated to the in-geo `ACCOUNT_ID`/region; every command, log, and evidence artifact stays in-jurisdiction. NO EU<->US data path. (Directive 1; residency enforced in depth per ADR-0007)
- [ ] **Irreversibility acknowledged.** All three modes are PERMANENT. There is NO PITR and backups EXCLUDE WAL — once backups/snapshots are also purged there is no recovery. Operator and an approver explicitly accept this in writing in the ticket. (ArcadeDB backup gotcha)
- [ ] **Scope is exact (record-purge).** The predicate deletes ONLY authorized records; dry-run COUNT matches the expected subject record count before any DELETE. Over-broad scope = unauthorized destruction.
- [ ] **Mode/tier match (crypto-shred).** Crypto-shred is valid ONLY for tenants provisioned with a dedicated per-tenant CMK (enterprise). Shared-key tenants CANNOT be crypto-shredded — fall back to `db-drop` + backup purge.
- [ ] **Quorum & blast radius.** `db-drop`/`record-purge` run against the leader of the tenant's cell only; confirm the cell is healthy (3 nodes, one-per-AZ, PDB minAvailable=2) so the erasure write replicates and isn't lost in a failover. Crypto-shred does NOT touch the cluster. (Directive 3)
- [ ] **Kill-switch first.** Engage the retrieval-proxy per-tenant kill-switch (`../../../control-plane/router/index.ts`) so no reads/writes hit the tenant during erasure — ArcadeDB has NO per-DB quotas, so the proxy is the only tenant gate. (ArcadeDB no-quota gotcha)
- [ ] **Approval gate.** Mutating execution requires manual approval (Spacelift for any Terraform/IaC path; named compliance approver on the ticket for data-plane DELETE/DROP). No click-ops. (Directive 6)

## Steps
> All steps below MUTATE customer data / AWS resources and are POST-approval, in-geo only. Steps 1–4 are read/safety; mutation begins at Step 6.

1. **Confirm authorization & scope.** Open the `LEGAL_TICKET_ID`; verify requester, legal basis, `MODE`, and `SCOPE`. Cross-check the mode against the erasure-primitive definitions in HLD §7.1 (DB drop vs. crypto-shred vs. record purge) and confirm crypto-shred is only chosen for a dedicated-CMK enterprise tenant (ADR-0003). If anything is ambiguous, STOP.
2. **Resolve tenant placement.** From `../../../control-plane/registry/schema.ts` read the tenant's `GEO`, cell ID, DB name, tier, and (if enterprise) per-tenant CMK ARN. Verify `GEO` input matches. Authenticate to that geo's `ACCOUNT_ID`/region.
3. **Legal-hold check.** Query the hold register for the tenant and in-scope subjects. Any hold → ABORT and escalate. Record the negative result for evidence.
4. **Quiesce the tenant (kill-switch).** Flip the retrieval-proxy kill-switch for `TENANT_ID` (`../../../control-plane/router/index.ts` config) so no traffic reaches the DB. Confirm 0 in-flight requests.
5. **APPROVAL GATE.** Obtain the compliance approver sign-off recorded on the ticket; for any IaC-driven resource destruction obtain Spacelift run approval. Do not proceed without it. (Directive 6)
6. **Execute the erasure primitive for `MODE`** (drive `../../../control-plane/provisioning/deprovision.asl.json` in erasure mode; it sequences the data-plane action + evidence + downstream purge):

   - **MODE = db-drop (whole-tenant):**
     a. Snapshot the current DB inventory/metadata for evidence (record name, size, record counts) — metadata only, no record content.
     b. Against the tenant cell **leader** (writes go to the leader; per-DB replication propagates the drop to replicas), issue the ArcadeDB `DROP DATABASE <dbname>` for the tenant DB. Do NOT touch other tenants' DBs on the cell.
     c. Confirm the DB no longer lists on the leader AND on each replica.

   - **MODE = crypto-shred (enterprise; CMK destroy):**
     a. Confirm the tenant uses a DEDICATED per-tenant CMK (Step 2). If shared, STOP and switch to db-drop.
     b. APPROVAL/IaC GATE: schedule deletion of the per-tenant CMK (`aws kms schedule-key-deletion --key-id <CMK_ARN> --pending-window-in-days 7`) in the in-geo account. NOTE: AWS enforces a minimum 7-day pending-deletion window; erasure is "complete" at scheduled-deletion time but the key is destroyed at window end — record both timestamps. Optionally `disable-key` immediately to render data unreadable now.
     c. Because the CMK encrypts the tenant's EBS volumes, S3 objects, Secrets, and snapshots (Directive 5), destroying it renders ALL of that ciphertext permanently unrecoverable in one action — this is the value of crypto-shred. Still proceed to Step 7 to remove now-dead artifacts.

   - **MODE = record-purge (targeted):**
     a. DRY RUN: run the SCOPE predicate as a `SELECT count(*)` against the leader; verify the count equals the expected subject record count. Mismatch → STOP.
     b. Against the **leader**, run the bounded `DELETE FROM <type> WHERE <SCOPE predicate>`; capture rows-affected. The DB continues to EXIST; only in-scope records are removed.
     c. Re-run the SELECT count → must be 0 for the predicate.

7. **Purge derived copies (per policy / Directive 1).** Erasure is not done until copies are handled in the SAME geo:
   - **Backups:** delete the tenant's hot per-DB backup ZIPs from the in-geo S3 backup bucket (versions + delete markers). (For crypto-shred this is automatic — the ZIPs are CMK-encrypted ciphertext, already unreadable.)
   - **EBS snapshots:** deregister/delete tenant-scoped EBS snapshots supplementing the engine backup. (Crypto-shred: ciphertext is dead; still delete to remove clutter.)
   - **Replicas:** for db-drop/record-purge confirm the change replicated to all cell replicas (Step 6c); these are not separate copies to purge but must reflect the erasure.
   - Do NOT cross the EU<->US boundary purging copies; each geo's copies are purged from that geo's account only.
8. **Emit DELETION EVIDENCE (always).** ArcadeDB has NO native audit — evidence is produced by the control plane, not the engine:
   a. Write a structured deletion AUDIT EVENT (tamper-evident store) capturing: `TENANT_ID`, `GEO`, `MODE`, `SCOPE`, `LEGAL_TICKET_ID`, legal-hold-clear result, operator + approver, pre-state metadata, rows/objects/keys affected, and UTC timestamps (incl. CMK scheduled + final destroy times for crypto-shred).
   b. Generate the DELETION CERTIFICATE and deliver it to `EVIDENCE_RECIPIENTS` (in-geo only).
9. **Release / finalize.** For db-drop and crypto-shred, hand back to `deprovision-tenant` to remove the now-orphaned registry entry, proxy route, and kill-switch. For record-purge, LIFT the kill-switch to restore normal tenant service.

## Verification
- **db-drop:** `DROP`-target DB does not appear in the DB list on the leader or any replica; control-plane registry shows the tenant erased; backup ZIPs and EBS snapshots for the tenant are gone (`aws s3 ls` / `aws ec2 describe-snapshots` in-geo return nothing).
- **crypto-shred:** `aws kms describe-key --key-id <CMK_ARN>` shows `KeyState=PendingDeletion` (or `Disabled` if disabled immediately); attempts to mount/read the tenant's EBS/S3/Secrets fail with a KMS access/availability error → data is cryptographically unrecoverable. Record final `Deleted` state after the pending window.
- **record-purge:** SCOPE-predicate `SELECT count(*)` returns 0 on the leader and on replicas; DB still serves other (out-of-scope) records; no unrelated record count changed.
- **Evidence:** the audit event is queryable in the tamper-evident store and the deletion certificate was delivered to `EVIDENCE_RECIPIENTS` (in-geo). No evidence artifact left the tenant's jurisdiction (Directive 1).
- **Isolation (post-mutation):** re-confirm no other tenant DB on the cell was affected.

## Rollback / if it goes wrong
- **There is NO undo for a completed erasure** — DB DROP, CMK destruction, and record DELETE are irreversible (no PITR; backups exclude WAL). Rollback applies only to ABORTING before mutation.
- **Before Step 6 (no mutation yet):** safe to abort — just LIFT the kill-switch (Step 4) and close the ticket as not-executed.
- **Crypto-shred within the 7-day window:** if executed in ERROR and caught before the pending-deletion window elapses, `aws kms cancel-key-deletion` and `enable-key` to recover; data behind the CMK becomes readable again. After the window, recovery is impossible. This is the ONLY post-execution recovery path and only for crypto-shred.
- **Partial failure (e.g. DB dropped but backups not yet purged, or replicas out of sync):** the erasure is INCOMPLETE, not reversible — finish the purge (Step 7) and replication check; do NOT attempt to "restore." If a replica is unreachable, hold the ticket OPEN and resume purge once the cell regains quorum; never declare complete with surviving copies.
- **Wrong scope on record-purge (over-deleted):** you cannot restore; treat as a data-loss incident, file an incident, and notify legal — restoring from a backup would resurrect the very data the request erased and is generally NOT permitted.
- **Any residency doubt:** if you suspect an artifact crossed EU<->US, treat as a residency incident immediately (Directive 1).

## Related
- `deprovision-tenant` skill — normal lifecycle teardown (drives the SAME state machine but with `retain_final_backup=true`); this skill calls back into it for db-drop/crypto-shred finalization. The load-bearing difference: erasure takes NO retained backup and emits erasure evidence.
- HLD §7.1 — the authoritative definition of the data-layer erasure primitives (DB drop / crypto-shred / record purge + deletion evidence) the app's RTBF/DSAR workflow calls into: `../../../docs/architecture.md`
- ADR-0025 — scope boundary: erasure/DSAR is a platform-owned *seam*; the app owns the RTBF/DSAR *workflow* and legal process: `../../../docs/adr/0025-scope-data-layer-platform.md`
- ADR-0003 — tiered isolation: which tenants get a dedicated per-tenant CMK (enterprise) and are therefore crypto-shred-eligible: `../../../docs/adr/0003-tenancy-isolation-tiered.md`
- ADR-0007 — residency enforcement in depth (SCP region-deny + registry geo-assert), backing the in-geo boundary every step here asserts: `../../../docs/adr/0007-residency-enforcement-scp.md`
- Control plane: `../../../control-plane/provisioning/deprovision.asl.json` (erasure orchestration), `../../../control-plane/registry/schema.ts` (placement/holds), `../../../control-plane/router/index.ts` (kill-switch)
- Assumptions: `../../../docs/assumptions.md`
