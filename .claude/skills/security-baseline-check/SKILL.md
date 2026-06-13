---
name: security-baseline-check
description: Read-only audit that verifies the SOC2 + GDPR-residency security baseline (residency SCPs, encryption everywhere, no public DB, audit layers, conftest gates, version floor + signed image, isolation probe, per-geo state) and emits a pass/fail checklist with evidence pointers. Run at build/validate time before any CTO sign-off, before each Spacelift prod apply, after every upgrade, and on a scheduled cadence as the standing compliance evidence check.
---

# Security baseline check

> READ-ONLY posture audit for SOC2 + GDPR residency: confirm every structural control is present and produce a pass/fail checklist with evidence pointers. BUILD-TIME / VALIDATE-TIME skill. PHASE NOTE: this skill itself mutates nothing — it only reads plans, configs, and (post-go-live) live AWS/cluster state. Where a control is "not yet present" because the CTO package has not been applied, record it as `N/A (pre-apply)` against the artifact that WILL provide it, not as a hard FAIL. Once the relevant phase is live, the same control must read PASS against real state.

## Prerequisites
- Read access to this repo at a known commit (the artifacts below are the build-time source of truth).
- `conftest` / `opa` and `tofu` (or `terraform`) installed locally for the policy and plan checks; `cosign` for image-signature verification; `jq` for plan/JSON parsing.
- POST-GO-LIVE only, for the live-state half: read-only `aws` CLI creds in BOTH geo accounts (use the SSO `PlatformReadOnly` permission set, which attaches the `ReadOnlyAccess` managed policy — `terraform/landing-zone/variables.tf`), and read-only `kubectl` contexts for each geo's EKS cluster. Never use write/admin creds for this skill.
- Knowledge of which phase is live (pre-apply vs applied) so each control is scored against the right evidence (artifact vs live state).

## Inputs
- `SCOPE` — `build-time` (repo + plan JSON only) or `full` (repo + plan + live AWS/cluster state). Default to `build-time` until the package is applied.
- `GEOS` — geos to audit: `EU`, `US`, or both. Each is checked independently; controls must hold per-geo.
- `ALLOWED_REGIONS` — the in-geo region allow-list per geo (e.g. EU: `eu-central-1`, `eu-west-1`; US: `us-east-1`, `us-west-2`). Feeds the residency policy parameter; must match the geo OU SCP allow-list.
- `ACCOUNT_ID` — the geo's AWS account (placeholder; one per geo, never crossed).
- `PLAN_JSON` (optional) — path(s) to `tofu show -json` plan output per geo/env to run the conftest gates against a real plan; if absent, run the policy UNIT tests only.
- `VERSION_FLOOR` — `26.4.1` (Prime Directive 2 / ADR-0012). Do not lower.
- `COMMIT` — the git SHA being audited (recorded as evidence).

## Safety checks (MUST pass before proceeding)
- READ-ONLY posture (this skill): make NO changes to AWS, the cluster, Terraform state, or the registry. If any step would mutate, you are off-script — stop. This is an audit, not a remediation run (remediation goes through Terraform/Helm/GitOps + Spacelift — Prime Directive 6).
- Residency of the audit itself (Prime Directive 1): query each geo's account/cluster ONLY from in-geo, and never copy EU evidence into a US store or vice versa. There is NO EU<->US data path, including for audit artifacts.
- Least privilege: use the SSO `PlatformReadOnly` permission set / read-only kube context only. If you cannot complete a check read-only, record it as `BLOCKED` rather than escalating privileges.
- No secret exfiltration: when sampling Secrets Manager / KMS config, read metadata and encryption settings ONLY — never decrypt or print secret values (the engine has NO native encryption or audit; KMS + app-layer audit are the controls being verified, not bypassed).
- Scoring discipline: a control is PASS only with a concrete evidence pointer (file+line, resource ARN, or command output). "Looks fine" is a FAIL. Unknown/unreachable is `BLOCKED`, not PASS.

## Steps
Run each numbered control, capture the evidence pointer, and mark PASS / FAIL / `N/A (pre-apply)` / `BLOCKED`. All steps are READ-ONLY.

1. RECORD CONTEXT. Note `COMMIT`, `SCOPE`, `GEOS`, and `ALLOWED_REGIONS`. Confirm phase (pre-apply vs applied) so each control is scored against the right evidence source.

2. RESIDENCY SCP PRESENT ON EACH GEO OU.
   - Build-time: confirm `terraform/landing-zone` declares `aws_organizations_organizational_unit.geo` (eu, us) and `aws_organizations_policy.residency` + its attachment, denying actions where `aws:RequestedRegion` ∉ the geo allow-list, with a curated global-service `not_actions` allow-list (`terraform/landing-zone/main.tf`, `variables.tf`; ADR-0007). Confirm the SCP's allow-list equals `ALLOWED_REGIONS` for that geo.
   - Live (`full`): for each geo OU, read the attached SCP via `aws organizations list-policies-for-target` (read-only) and confirm the deny + region allow-list match. Phase-0 exit-criterion as evidence: the SCP provably blocks a non-EU region action in an EU account (cite the test result if available).

3. ENCRYPTION ON EVERYWHERE (KMS — the engine provides none; Prime Directive 5).
   - Verify EBS (gp3 StorageClass with KMS key — `terraform/modules/cell/`), S3 buckets (backups + per-geo state: SSE-KMS, versioned, public-access-blocked — `terraform/modules/backup-dr/`, `terraform/landing-zone/`), Secrets Manager (CMK, not the AWS-managed default — `terraform/modules/eks/` / ESO config), AWS Backup snapshots (KMS-encrypted vault — `terraform/modules/backup-dr/`), and CloudWatch log groups (KMS-associated — `terraform/modules/observability/`).
   - Build-time: confirm every such resource passes a KMS key (no plaintext / no AWS-managed default where a CMK is required) per the `terraform/CLAUDE.md` "encrypt everything" rule.
   - Live (`full`): spot-read encryption config read-only (e.g. `aws s3api get-bucket-encryption`, `aws ec2 describe-volumes`, `aws logs describe-log-groups`) — metadata only, never decrypt.

4. NO PUBLIC DB SECURITY GROUP (Prime Directive 4).
   - Confirm NO security group / rule opens an ArcadeDB port (`2480/2424/2434/5432/6379/7687`) to `0.0.0.0/0` or `::/0`. The DB ports must never sit on a public subnet/LB; only the retrieval proxy is reachable, in-geo, via PrivateLink (ADR-0026).
   - Build-time: this is enforced by `policy/conftest/no_public_db.rego` (Step 7) and the cell module's default-deny NetworkPolicy (`terraform/modules/cell/`). Confirm both exist.
   - Live (`full`): read-only `aws ec2 describe-security-groups` filtered to the DB ports; assert no world-open ingress.

5. AUDIT LAYERS WIRED (SOC2).
   - Org-level (build-time): confirm the baseline guardrail SCP protects CloudTrail / Config / GuardDuty / SecurityHub and blocks org-leave + root use (`aws_organizations_policy.baseline` in `terraform/landing-zone/`). Control Tower / AFT provides the org CloudTrail + Config aggregator (referenced, not duplicated — landing-zone README "Phase-0/LLD follow-ups").
   - Org-level (live, `full`): read-only confirm an org CloudTrail is logging, AWS Config is recording, and GuardDuty + SecurityHub are enabled in each geo (`describe`/`list` calls only).
   - App-layer DB-access audit: ArcadeDB has NO native audit, so the audit trail is produced by the retrieval/proxy layer — confirm the proxy emits per-tenant DB-access audit events (`control-plane/router/index.ts`) and that they ship to the geo's audit sink (`terraform/modules/observability/`). This app-layer audit IS the DB audit control; it must be present.

6. CONTINUOUS CROSS-TENANT ISOLATION PROBE RUNNING (ADR-0027, complements Prime Directive 2).
   - Confirm the continuous probe that attempts cross-DB access on every cell and alerts if it EVER succeeds is defined and (live) actually running with a healthy heartbeat and no recent success-to-cross-access alerts.
   - Build-time: confirm the probe + its alert are declared (`control-plane/router/index.ts` governance, `terraform/modules/observability/` alert rule).
   - Live (`full`): confirm the probe's metric is fresh in AMP and the "cross-DB access succeeded" alarm is in OK state for every cell in scope. Any firing = isolation FAIL (highest severity).

7. CONFTEST POLICY GATES PASS (`policy/conftest`).
   - Run the policy UNIT tests (self-contained, no AWS):
     ```bash
     conftest verify --policy policy/conftest    # expect: 7 tests, 7 passed
     ```
   - If `PLAN_JSON` is supplied, run the gates against the real plan per geo (residency needs the geo allow-list injected; no-public-DB needs no params):
     ```bash
     jq '. + {parameters: {allowed_regions: ["<geo regions>"]}}' PLAN_JSON \
       | conftest test - --policy policy/conftest --namespace main      # residency
     conftest test PLAN_JSON --policy policy/conftest --namespace main  # no-public-DB
     ```
   - `residency.rego` = no out-of-geo region/AZ literal in the plan (Prime Directive 1, ADR-0007); `no_public_db.rego` = no DB port open to the world (Prime Directive 4). Both must be clean.

8. ARCADEDB IMAGE >= 26.4.1 AND COSIGN-SIGNED (Prime Directive 2 / ADR-0012).
   - Confirm the image tag in `helm/arcadedb/values.yaml` is `>= VERSION_FLOOR` and pinned by immutable digest (mirrored to per-region ECR). The Edit/Write hook (`.claude/settings.json`) blocks any value below the floor — confirm the hook is present.
   - Verify the cosign signature on the pinned digest (read-only):
     ```bash
     cosign verify <ecr-repo>@<digest> --certificate-identity ... --certificate-oidc-issuer ...
     ```
   - Note: a version bump must be followed by a cross-DB isolation re-audit (ADR-0012) — confirm that obligation is recorded if a recent upgrade happened (see `upgrade-arcadedb`).

9. PER-GEO TERRAFORM STATE (Prime Directive 1, ADR-0022).
   - Confirm EU state lives in the EU bucket and US state in the US bucket — separate per-geo, SSE-KMS, versioned, public-access-blocked, S3-native locking (`use_lockfile=true`, no DynamoDB lock table) — declared in `terraform/landing-zone/` and consumed via per-environment `-backend-config` (`terraform/environments/backend.tf`).
   - Live (`full`): read-only confirm each geo's state bucket is in-geo, encrypted, and that no state object for one geo resides in the other geo's bucket.

10. EMIT THE CHECKLIST. Produce the pass/fail table (see Verification) with one row per control (2–9), each carrying its status and an evidence pointer. Record `COMMIT` and `SCOPE`. Do NOT write a findings markdown into the repo as a side effect — return the checklist as the skill output.

## Verification
Success = a complete checklist where every control is PASS (or an accepted `N/A (pre-apply)` tied to the artifact that will satisfy it post-apply), each with a concrete evidence pointer. Output shape:

| # | Control (directive) | Status | Evidence pointer |
|---|---|---|---|
| 2 | Residency SCP on each geo OU (PD1, ADR-0007) | PASS / FAIL / N/A(pre-apply) | `terraform/landing-zone/main.tf:…` / SCP ARN |
| 3 | Encryption everywhere via KMS (PD5) | … | resource + KMS key / `get-bucket-encryption` output |
| 4 | No public DB security group (PD4) | … | `policy/conftest/no_public_db.rego` / SG describe |
| 5 | Audit layers wired — org + app-layer DB audit (SOC2) | … | baseline SCP / `control-plane/router/index.ts` |
| 6 | Continuous cross-tenant isolation probe running (ADR-0027) | … | probe def / AMP metric + alarm state |
| 7 | Conftest gates pass (PD1, PD4) | … | `conftest verify` output (7/7) / plan-test result |
| 8 | Image >= 26.4.1 AND cosign-signed (PD2, ADR-0012) | … | `values.yaml` digest / `cosign verify` output |
| 9 | Per-geo Terraform state (PD1, ADR-0022) | … | `environments/backend.tf` / bucket region |

Concrete observable checks: `conftest verify --policy policy/conftest` reports `7 tests, 7 passed`; `cosign verify` returns a valid signature for the pinned digest; the isolation alarm is OK for every in-scope cell; no DB port is world-open; each geo's state bucket region ∈ that geo's allow-list. Any FAIL (or any firing isolation alarm) fails the baseline overall.

## Rollback / if it goes wrong
- This skill mutates nothing, so there is nothing to roll back. If you accidentally ran anything write-shaped, STOP and treat it as an incident — remediation is out of band via Terraform/Helm/GitOps + Spacelift, never ad-hoc (Prime Directive 6).
- If a control FAILS: do NOT fix it inside this skill. File the finding with its evidence pointer and route it: residency/region-literal -> fix the Terraform + re-run the conftest gate; world-open DB SG -> fix the SG + re-run `no_public_db.rego`; below-floor or unsigned image -> bump via `upgrade-arcadedb` (canary-first, then isolation re-audit); missing encryption -> add the KMS key to the resource; missing audit/probe -> wire it before sign-off.
- If a check is `BLOCKED` (no read access / unreachable): record it as BLOCKED, obtain read-only access via the SSO `PlatformReadOnly` set, and re-run — never escalate to write/admin to complete an audit.
- A firing cross-DB isolation alarm is a SECURITY INCIDENT: escalate via `incident-triage` (kill-switch + isolation handling), do not just log it.

## Related
- ADR-0007 (residency enforcement: per-geo OU + SCP + CI gate + per-geo state) — `../../../docs/adr/0007-residency-enforcement-scp.md`
- ADR-0012 (version floor 26.4.1, digest-pinned + cosign, re-audit after upgrade) — `../../../docs/adr/0012-version-floor-26-4-1.md`
- ADR-0022 (per-geo S3-native state locking) — `../../../docs/adr/0022-state-locking-s3-native.md`
- ADR-0027 (runtime tenant governance + continuous isolation probe) — `../../../docs/adr/0027-runtime-tenant-governance.md`
- ADR-0026 (in-geo PrivateLink app connectivity) — `../../../docs/adr/0026-app-connectivity-privatelink.md`
- Policy gates — `../../../policy/conftest/` (`residency.rego`, `no_public_db.rego`, `README.md`)
- Landing zone — `../../../terraform/landing-zone/` (geo OUs, residency + baseline SCPs, per-geo state, SSO permission sets)
- Helm values (image digest + floor) — `../../../helm/arcadedb/values.yaml`
- Hooks (below-floor image block) — `../../../.claude/settings.json`
- Control plane (app-layer DB audit, isolation probe) — `../../../control-plane/router/index.ts`, `../../../control-plane/registry/schema.ts`
- Observability (audit sink, alerts, log groups) — `../../../terraform/modules/observability/`
- Architecture / assumptions — `../../../docs/architecture.md`, `../../../docs/assumptions.md`
- Related skills: `review-terraform-plan`, `upgrade-arcadedb`, `incident-triage`
