#!/usr/bin/env bash
###############################################################################
# UserPromptSubmit — inject the active geo/env/cell context + a one-line reminder
# of the prime directives. stdout is added to the session context.
#
# The "active" geo/env is read from .claude/active-context (operator-set), or
# defaults to "unset" — operators run `echo "eu-prod" > .claude/active-context`.
###############################################################################
set -uo pipefail

CTX_FILE="$CLAUDE_PROJECT_DIR/.claude/active-context"
ACTIVE="$( [ -f "$CTX_FILE" ] && head -1 "$CTX_FILE" || echo 'unset' )"

cat <<EOF
[platform-context] active geo/env: ${ACTIVE}
[prime-directives] residency (EU↔US never) · ArcadeDB >= 26.4.1 · prod quorum 3 + PDB minAvailable 2 · no public DB · encrypt-everything (KMS) · no click-ops (plan before apply) · pod mem limit >= maxPageRAM+heap+overhead.
[phase] CTO approval package — NOT applied to AWS. Do not run terraform/tofu apply or cloud-mutating commands.
EOF
exit 0
