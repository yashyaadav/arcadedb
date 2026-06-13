#!/usr/bin/env bash
###############################################################################
# SessionStart — load the current cell catalog / environment context so Claude
# starts each session knowing the landscape. stdout is added to context.
#
# In Phase 2+ this reads the DynamoDB cell catalog. For the CTO package it lists
# the example environments + cells declared in terraform/environments/*/tfvars.
###############################################################################
set -uo pipefail

echo "[session-start] ArcadeDB KB platform — example environments (from terraform/environments):"
for f in "$CLAUDE_PROJECT_DIR"/terraform/environments/*/terraform.tfvars; do
  [ -f "$f" ] || continue
  ENV_DIR="$(basename "$(dirname "$f")")"
  CELLS="$(grep -Eo '"(std|ent)-[a-z0-9-]+"' "$f" 2>/dev/null | tr -d '"' | paste -sd, - 2>/dev/null)"
  echo "  - ${ENV_DIR}: cells=[${CELLS:-none}]"
done

CTX_FILE="$CLAUDE_PROJECT_DIR/.claude/active-context"
if [ -f "$CTX_FILE" ]; then
  echo "[session-start] active context: $(head -1 "$CTX_FILE")"
else
  echo "[session-start] no active context set. Set one: echo 'eu-prod' > .claude/active-context"
fi
echo "[session-start] Phase D (CTO package): NOT applied to AWS. See CLAUDE.md prime directives."
exit 0
