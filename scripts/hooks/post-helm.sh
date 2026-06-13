#!/usr/bin/env bash
###############################################################################
# PostToolUse · helm chart/manifest changes — helm lint + kubeconform.
# Surfaces failures back to Claude (exit 2). Offline; no cluster.
###############################################################################
set -uo pipefail

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except Exception: print("")' 2>/dev/null)"

case "$FILE" in
  */helm/*) ;;
  *) exit 0 ;;
esac

CHART="$CLAUDE_PROJECT_DIR/helm/arcadedb"
[ -d "$CHART" ] || exit 0

if command -v helm >/dev/null 2>&1; then
  if ! OUT="$(helm lint "$CHART" 2>&1)"; then
    echo "post-helm: helm lint FAILED:" >&2; echo "$OUT" >&2; exit 2
  fi
  if command -v kubeconform >/dev/null 2>&1; then
    if ! OUT="$(helm template arcadedb "$CHART" 2>&1 | kubeconform -strict -ignore-missing-schemas -summary 2>&1)"; then
      echo "post-helm: kubeconform FAILED:" >&2; echo "$OUT" >&2; exit 2
    fi
  fi
  echo "post-helm: helm lint + kubeconform OK"
else
  echo "post-helm: helm not installed — skipping" >&2
fi
exit 0
