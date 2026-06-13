---
name: rotate-secrets
description: Rotates ArcadeDB credentials for the multi-tenant KB platform — per-tenant DB users (normal, automated rotation) and the SET-ONCE root admin (rotate = provision a new admin, retire the old). Use for scheduled/ad-hoc credential rotation, suspected leak, or operator off-boarding.
---

# Rotate secrets

> What/when: rotate ArcadeDB credentials with zero downtime — either (A) a per-tenant DB user via the rotation Lambda + ESO re-sync, or (B) the root admin, which is SET-ONCE and is "rotated" by provisioning a NEW admin user and retiring the old one. Phase note: this is a DAY-2 runbook. The CTO package is NOT yet applied to AWS; every step that mutates AWS, Secrets Manager, or the cluster is an approval gate and is OUT OF SCOPE until after CTO sign-off / go-live.

## Prerequisites
- Read-only AWS access to the target geo account (`ACCOUNT_ID`), in the correct region (EU tenant -> EU region; US tenant -> US region). NEVER reach across geos (Directive 1: no EU<->US data path).
- `kubectl` context for the cell's EKS cluster, scoped to the tenant's namespace.
- Permission to invoke the rotation Lambda and to push a Spacelift run (for any AWS-mutating step). Prod apply needs manual approval (Directive 6: no click-ops).
- External Secrets Operator (ESO) is installed and the tenant's `ExternalSecret` is healthy (it backs the K8s secret from Secrets Manager).
- The gitleaks pre-commit hook is active (see `../../../.claude/settings.json`) — it WILL block any commit containing a secret. Never paste a credential into a file, diff, PR, or ticket.
- Know which procedure you need: A = per-tenant DB user; B = root/admin.

## Inputs
- `TENANT_ID` — the tenant whose DB user is rotating (procedure A).
- `GEO` — `eu` or `us`; selects account + region. Must match the tenant's residency (Directive 1).
- `CELL_ID` / cluster + namespace for the tenant.
- Secrets Manager secret ARN/name for the credential (e.g. `arcadedb/<GEO>/<TENANT_ID>/db-user`).
- `ESO_EXTERNALSECRET` — name of the `ExternalSecret` that syncs that secret into K8s.
- Reason for rotation (scheduled / leak / off-boarding) — for the audit note (ArcadeDB has NO native audit; record it externally).
- Procedure B only: desired new admin username + a ticket/ADR reference for the retirement record.

## Safety checks (MUST pass before proceeding)
- Residency (Directive 1): confirm `GEO` matches the tenant's jurisdiction and you are operating ONLY in that geo's account/region. No cross-geo credential, secret, or connection. EU stays EU.
- No public exposure (Directive 4): rotation talks to the DB over the internal service only. Confirm ports 2480/2424/2434/5432/6379/7687 are NOT on a public subnet/LB. Never open a public path to run an `ALTER USER`.
- Encryption (Directive 5): the Secrets Manager secret MUST be KMS-encrypted (engine provides none). Do not stage the credential anywhere unencrypted (local file, clipboard manager, chat).
- No secret in a diff: the gitleaks hook blocks commits — do not work around it. If you accidentally staged a secret, unstage and treat it as a leak (rotate immediately).
- Root is SET-ONCE (ArcadeDB F4): you CANNOT re-set the root password via the init env var. Do NOT attempt to "re-set the root password" or re-run the init secret. Procedure B provisions a new admin instead. The init root secret stays IMMUTABLE.
- Restore-safety is unaffected: this skill does not touch DBs/backups, but never combine a rotation with a restore (RESTORE REQUIRES THE TARGET DB TO NOT EXIST — out of scope here).
- No downtime: rotation is online. Writes go to the leader; reads fan to replicas (per-DB Raft). Rotating a user must not require a restart or break quorum (prod = 3 nodes, PDB minAvailable=2, Directive 3).
- Approval gates: any AWS/Secrets Manager/cluster mutation in prod requires manual approval (Spacelift). Plan before apply (Directive 6).

---

## Steps

### Procedure A — Rotate a per-tenant DB user (normal, automated)

Per-tenant DB credentials are normal, rotatable secrets. The flow: rotation Lambda -> ArcadeDB `ALTER USER` -> update Secrets Manager -> ESO re-syncs the K8s secret -> clients reconnect. No downtime.

1. **Confirm scope (read-only).** Verify `TENANT_ID`, `GEO`, cluster/namespace, and the Secrets Manager secret name. Re-confirm residency and that you are in the correct geo account/region (Safety: Directive 1).
2. **Pre-check ESO + current connections (read-only).** Confirm the `ExternalSecret` is `SecretSynced=True`:
   ```sh
   kubectl -n <namespace> get externalsecret <ESO_EXTERNALSECRET> \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
   ```
   Note current `refreshInterval` so you know the worst-case sync delay.
3. **[APPROVAL GATE — AWS-MUTATING] Trigger the rotation Lambda.** The Lambda performs the `ALTER USER <tenant_user> SET PASSWORD ...` against the tenant's DB on the leader, generates the new secret, and writes the new version to Secrets Manager (KMS-encrypted). Invoke via the approved path (Spacelift/console with manual approval in prod), e.g.:
   ```sh
   aws lambda invoke --function-name arcadedb-rotate-db-user-<GEO> \
     --region <GEO-region> \
     --payload '{"tenantId":"<TENANT_ID>","reason":"<scheduled|leak|offboarding>"}' \
     /tmp/rotate-out.json
   ```
   Do NOT print or echo the new password. The Lambda — not you — is the only thing that should see plaintext.
4. **Confirm Secrets Manager has a new version (read-only).** Check the secret advanced to a new `VersionId` / `AWSCURRENT` stage:
   ```sh
   aws secretsmanager describe-secret --secret-id arcadedb/<GEO>/<TENANT_ID>/db-user \
     --region <GEO-region> \
     --query '{Updated:LastChangedDate,Stages:VersionIdsToStages}'
   ```
   Do not run `get-secret-value` to a terminal/file (Safety: no secret in a diff/log).
5. **Force/await ESO re-sync.** ESO picks up the new `AWSCURRENT` and updates the K8s secret. To avoid waiting the full `refreshInterval`, nudge it:
   ```sh
   kubectl -n <namespace> annotate externalsecret <ESO_EXTERNALSECRET> \
     force-sync="$(date +%s)" --overwrite
   kubectl -n <namespace> get externalsecret <ESO_EXTERNALSECRET> -w
   ```
   Wait for `SecretSynced=True` and a fresh `status.refreshTime`.
6. **Confirm clients reconnect.** Consumers (the retrieval proxy / per-tenant clients) must pick up the rotated K8s secret. If they don't hot-reload secrets, perform a rolling restart of ONLY the client deployment (not the ArcadeDB StatefulSet):
   ```sh
   kubectl -n <namespace> rollout restart deployment/<retrieval-proxy-or-client>
   kubectl -n <namespace> rollout status  deployment/<retrieval-proxy-or-client>
   ```
   The ArcadeDB StatefulSet is NOT restarted — rotation is online and must preserve quorum (Directive 3).
7. **Record the rotation externally.** ArcadeDB has no native audit — log who/when/why and the new `VersionId` (NOT the value) in your ops record/ticket.

### Procedure B — "Rotate" the root / admin (SET-ONCE — provision a new admin)

The root password is SET-ONCE (ArcadeDB F4). You CANNOT change it via the init env var, and you must never re-set it. "Rotating root" means: provision a NEW server-level admin user, switch operators to it, and retire the old admin. The init root secret stays immutable.

1. **Confirm scope + residency (read-only).** Identify the cell(s) in the correct geo. Decide the new admin username (e.g. `ops-admin-<yyyymm>`). Open/attach the retirement ticket referencing ADR-0018.
2. **[APPROVAL GATE — CLUSTER-MUTATING] Create the new admin server-user.** Connect to the leader over the internal service (never a public path, Directive 4) using current admin creds, and create a new server user with the required admin privileges. Use the ArcadeDB server-user mechanism (server config / `CREATE USER` with admin role per your version >= 26.4.1):
   - Grant the privileges the operators actually need (least privilege).
   - Do NOT touch or re-set the init root user. It remains as the immutable bootstrap identity.
3. **[APPROVAL GATE — AWS-MUTATING] Store the new admin credential in Secrets Manager (KMS-encrypted).** Create a NEW secret (e.g. `arcadedb/<GEO>/admin/ops-admin-<yyyymm>`), version-controlled via the approved IaC/Spacelift path. The Lambda or a sealed process should write it; never paste the plaintext into a file/diff (gitleaks will block it anyway).
4. **Wire operators/automation to the new admin via ESO.** Point the operator/automation `ExternalSecret` at the new secret and confirm `SecretSynced=True` (same checks as Procedure A, steps 5-6). Verify any tooling that authenticated as the old admin now uses the new one.
5. **[APPROVAL GATE — CLUSTER-MUTATING] Retire the old admin user.** Once everything authenticates with the new admin and is verified, DISABLE/REMOVE the old admin server-user (not root). Leave the immutable init root as-is — it is the bootstrap identity of last resort, kept under break-glass.
6. **Document the change.** Record in the ADR-0018 thread / ops register: old admin retired, new admin name + secret `VersionId` (NOT value), date, operator, and reason. Because the engine has no audit, this written record IS the audit trail.

---

## Verification
- Procedure A:
  - Secrets Manager shows a new `AWSCURRENT` `VersionId`, more recent `LastChangedDate`.
  - `ExternalSecret` reports `Ready/SecretSynced=True` with a fresh `refreshTime`; the K8s secret's `resourceVersion` advanced.
  - Client pods are running and serving (`rollout status` succeeded); the retrieval proxy successfully queries the tenant DB with the new credential — no auth errors in logs.
  - ArcadeDB StatefulSet pods unchanged (no restarts), quorum intact (3/3 ready in prod), `/ready` returns HTTP 204.
- Procedure B:
  - New admin can authenticate to the leader and perform an admin op; operator tooling/automation uses it.
  - Old admin can NO longer authenticate (retired).
  - Init root secret is UNCHANGED (never re-set).
  - Retirement recorded against ADR-0018.
- Both: cross-DB isolation unaffected; no public port exposed; everything stayed in-geo.

## Rollback / if it goes wrong
- ESO didn't sync / clients can't auth (Procedure A): ESO and Secrets Manager keep prior versions. Move the `AWSPREVIOUS` version back to `AWSCURRENT` (via the approved path), force an ESO re-sync, and confirm clients reconnect. Then re-attempt the rotation. Do NOT restart the ArcadeDB StatefulSet to "fix" auth — it won't help and risks quorum.
- Rotation Lambda failed mid-way (DB password changed but Secrets Manager not updated, or vice versa): treat as drift. Re-run the Lambda (idempotent path) or, if needed, re-`ALTER USER` to match the secret's current version — over the internal service only. Keep the old version available until the new one is confirmed working.
- New admin (Procedure B) is broken or over/under-privileged: do NOT delete the old admin until the new one is verified. If already retired, use break-glass: the immutable init root (never re-set, kept sealed) to re-provision a correct admin, then retire the bad one.
- Accidentally exposed a secret (in a diff/log/chat): treat as a confirmed leak. Immediately re-run the relevant rotation, invalidate the exposed version, and note it in the audit record. The gitleaks hook should have blocked a commit — if it did, fix the file, never bypass the hook.

## Related
- ADR-0018 — secrets: Secrets Manager + ESO, and the SET-ONCE root handling: `../../../docs/adr/0018-secrets-secrets-manager-eso.md`
- Control plane: rotation/provisioning state machines `../../../control-plane/provisioning/statemachine.asl.json`, registry `../../../control-plane/registry/schema.ts`, router `../../../control-plane/router/index.ts`
- Helm values (probes, secret mounts): `../../../helm/arcadedb/values.yaml`
- Backup/DR module (separate flow — never combine with rotation): `../../../terraform/modules/backup-dr/`
- Hooks (gitleaks pre-commit): `../../../.claude/settings.json`
- Architecture + assumptions: `../../../docs/architecture.md`, `../../../docs/assumptions.md`
