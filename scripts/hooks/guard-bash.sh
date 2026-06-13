#!/usr/bin/env bash
###############################################################################
# PreToolUse · Bash guard-rail (deterministic — the harness runs this).
#
# Blocks (exit 2) the dangerous shell actions the prime directives forbid:
#   - terraform/tofu apply|destroy        (NO AWS in the CTO package; prod via Spacelift+approval)
#   - kubectl delete statefulset|pvc|pdb   (quorum / data loss risk)
#   - aws mutating call in an out-of-geo region (residency, ADR-0007)
#   - git commit with secrets in the diff  (gitleaks, if installed)
#
# Reads the tool-call JSON on stdin; exit 0 = allow, exit 2 = block (stderr shown).
###############################################################################
set -uo pipefail

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null)"

[ -z "$CMD" ] && exit 0

block() { echo "BLOCKED by guard-bash: $1" >&2; exit 2; }

# 1) No terraform/tofu apply or destroy (Phase D = no AWS; prod via Spacelift + approval).
if printf '%s' "$CMD" | grep -Eiq '\b(terraform|tofu)\b.*\b(apply|destroy)\b'; then
  block "terraform/tofu apply|destroy is not permitted (prime directive #6). CTO package is NOT applied to AWS; post-approval, apply goes through Spacelift with mandatory prod approval."
fi

# 2) No kubectl delete of stateful/quorum resources.
if printf '%s' "$CMD" | grep -Eiq '\bkubectl\b.*\bdelete\b.*(statefulset|sts|pvc|persistentvolumeclaim|pdb|poddisruptionbudget)'; then
  block "kubectl delete of statefulset/pvc/pdb risks quorum + data loss (prime directive #3). Use the documented runbook/skill instead."
fi

# 3) Residency: aws mutating call must target an in-geo region.
ALLOWED_REGIONS_REGEX='eu-central-1|eu-west-1|us-east-1|us-west-2'
if printf '%s' "$CMD" | grep -Eiq '\baws\b'; then
  REGION="$(printf '%s' "$CMD" | grep -Eo -- '--region[ =][a-z0-9-]+' | head -1 | sed -E 's/--region[ =]//')"
  if [ -n "$REGION" ] && ! printf '%s' "$REGION" | grep -Eq "^($ALLOWED_REGIONS_REGEX)$"; then
    block "aws --region '$REGION' is outside the in-geo allow-list (residency, ADR-0007). Allowed: eu-central-1, eu-west-1, us-east-1, us-west-2."
  fi
fi

# 4) Secret scan before commits (best-effort; needs gitleaks installed).
if printf '%s' "$CMD" | grep -Eiq '\bgit\b.*\bcommit\b'; then
  if command -v gitleaks >/dev/null 2>&1; then
    if ! gitleaks protect --staged --no-banner >/dev/null 2>&1; then
      block "gitleaks found a potential secret in the staged diff. Remove it before committing (prime directive #5)."
    fi
  else
    echo "guard-bash: gitleaks not installed — skipping secret scan (install it for the secret-in-diff guard)." >&2
  fi
fi

exit 0
