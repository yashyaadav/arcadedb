#!/usr/bin/env bash
###############################################################################
# PreToolUse · Edit/Write/MultiEdit guard-rail (deterministic).
#
# Blocks (exit 2) edits that would violate a prime directive in the new content:
#   - ArcadeDB image tag < 26.4.1 (or :latest)        (version floor, ADR-0012)
#   - a DB port opened to 0.0.0.0/0 / ::/0            (no public DB, #4)
#   - replicas < 3 in a prod context                  (quorum, #3)
#   - removing/disabling the PodDisruptionBudget       (quorum, #3)
#   - an out-of-geo region literal in an EU/US file    (residency, ADR-0007)
#
# Reads the tool-call JSON on stdin; inspects new_string/content + file_path.
###############################################################################
set -uo pipefail

INPUT="$(cat)"

FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except Exception: print("")' 2>/dev/null)"

# New content across Write (content), Edit (new_string), and MultiEdit (edits[].new_string).
NEW="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    ti=json.load(sys.stdin).get("tool_input",{})
    new=ti.get("new_string") or ti.get("content") or ti.get("new_str") or ""
    for e in (ti.get("edits") or []):
        new += "\n" + (e.get("new_string") or "")
    sys.stdout.write(new)
except Exception:
    pass' 2>/dev/null)"

[ -z "$NEW" ] && exit 0

# Only enforce on CONFIG files (IaC). Prose/docs (.md, etc.) legitimately
# *describe* these patterns (e.g. "never open 2480 to 0.0.0.0/0") and must not be
# blocked. This matches the plan's intent: guard IaC edits, not documentation.
case "$FILE" in
  *.tf|*.tfvars|*.tfvars.json|*.yaml|*.yml|*.tpl|*.json|*.hcl) ;;
  *) exit 0 ;;
esac

block() { echo "BLOCKED by guard-edit ($FILE): $1" >&2; exit 2; }

# 1) ArcadeDB version floor — flag a tag/appVersion below 26.4.1 or :latest.
#    Matches arcadedb image tags like 'arcadedata/arcadedb:25.x', tag: "26.3.0", appVersion: 26.0.0
if printf '%s' "$NEW" | grep -Eiq 'arcadedb'; then
  if printf '%s' "$NEW" | grep -Eiq 'arcadedb[^0-9]{0,40}:latest|tag:[[:space:]]*"?latest"?'; then
    block "ArcadeDB image must not be ':latest' — pin a semver >= 26.4.1 (ADR-0012)."
  fi
  # Extract version-like tokens near 'arcadedb' or 'tag:'/'appVersion:' and check the floor.
  BAD="$(printf '%s' "$NEW" | grep -Eio '(arcadedb[":[:space:]]{0,8}|tag:[[:space:]]*"?|appVersion:[[:space:]]*"?)([0-9]+\.[0-9]+\.[0-9]+)' \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
        | awk -F. '{ if ($1<26 || ($1==26 && $2<4) || ($1==26 && $2==4 && $3<1)) print $0 }' | head -1)"
  if [ -n "$BAD" ]; then
    block "ArcadeDB version '$BAD' is below the 26.4.1 floor (closes the CVSS-9.0 isolation CVE) — ADR-0012."
  fi
fi

# 2) No public DB — a DB port range with a public CIDR.
if printf '%s' "$NEW" | grep -Eq '0\.0\.0\.0/0|::/0'; then
  if printf '%s' "$NEW" | grep -Eiq '24(80|24|34)|5432|6379|7687|db.?port|arcadedb'; then
    block "a DB port appears to be opened to 0.0.0.0/0 (no public DB — prime directive #4). DB ports allow only the cluster/VPC SG."
  fi
fi

# 3) Quorum — replicas < 3 in a PROD context (avoid matching "non-prod"/"pre-prod").
IS_PROD=0
printf '%s' "$FILE" | grep -Eiq '(^|[/_-])prod($|[/._-])' && IS_PROD=1
printf '%s' "$NEW" | grep -Eiq 'env[":[:space:]=]+"?prod"?(\b|$)' && IS_PROD=1
if [ "$IS_PROD" = "1" ]; then
  # match a complete replica count of 0-2 (not e.g. 12); allow >=3.
  if printf '%s' "$NEW" | grep -Eiq 'replica[a-zA-Z_]*[":[:space:]=]+[0-2]([^0-9]|$)'; then
    block "prod cells require replicas >= 3 (quorum — prime directive #3). Non-prod may be single-node."
  fi
fi

# 4) Quorum — don't disable/remove the PDB.
if printf '%s' "$NEW" | grep -Eiq 'pdb[":[:space:]].*enabled[":[:space:]]*false|enable_pdb[[:space:]]*=[[:space:]]*false|minAvailable[":[:space:]]*[01]\b'; then
  block "the PodDisruptionBudget protects Raft quorum (minAvailable: 2) — do not disable it or drop minAvailable below 2 (prime directive #3)."
fi

# 5) Residency — an out-of-geo region literal in a geo-scoped file.
case "$FILE" in
  *eu-*|*/eu/*|*-eu-*)
    if printf '%s' "$NEW" | grep -Eo '(us|ap|sa|ca|me|af)-[a-z]+-[0-9]+' | grep -Evq '^$'; then
      R="$(printf '%s' "$NEW" | grep -Eo '(us|ap|sa|ca|me|af)-[a-z]+-[0-9]+' | head -1)"
      block "out-of-geo region '$R' in an EU-scoped file (residency — ADR-0007). EU resources stay in EU regions."
    fi ;;
  *us-*|*/us/*|*-us-*)
    if printf '%s' "$NEW" | grep -Eo '(eu|ap|sa|ca|me|af)-[a-z]+-[0-9]+' | grep -Evq '^$'; then
      R="$(printf '%s' "$NEW" | grep -Eo '(eu|ap|sa|ca|me|af)-[a-z]+-[0-9]+' | head -1)"
      block "out-of-geo region '$R' in a US-scoped file (residency — ADR-0007). US resources stay in US regions."
    fi ;;
esac

exit 0
