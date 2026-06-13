#!/usr/bin/env bash
###############################################################################
# PostToolUse · control-plane changes — typecheck (if toolchain present) +
# validate Step Functions ASL JSON. Surfaces failures back to Claude (exit 2).
###############################################################################
set -uo pipefail

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except Exception: print("")' 2>/dev/null)"

case "$FILE" in
  */control-plane/*) ;;
  *) exit 0 ;;
esac

# ASL JSON must stay valid JSON.
case "$FILE" in
  *.asl.json|*.json)
    if ! python3 -c "import json; json.load(open('$FILE'))" 2>/tmp/post-cp.log; then
      echo "post-controlplane: invalid JSON in $FILE:" >&2; cat /tmp/post-cp.log >&2; exit 2
    fi
    echo "post-controlplane: $FILE valid JSON" ;;
esac

# TypeScript typecheck — only if the toolchain is installed (Phase 2).
case "$FILE" in
  *.ts)
    CP="$CLAUDE_PROJECT_DIR/control-plane"
    if [ -d "$CP/node_modules" ] && command -v npx >/dev/null 2>&1; then
      if ! OUT="$(cd "$CP" && npx tsc --noEmit 2>&1)"; then
        echo "post-controlplane: tsc FAILED:" >&2; echo "$OUT" >&2; exit 2
      fi
      echo "post-controlplane: tsc OK"
    else
      echo "post-controlplane: TS toolchain not installed — typecheck deferred to Phase 2 CI" >&2
    fi ;;
esac
exit 0
