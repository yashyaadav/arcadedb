#!/usr/bin/env bash
###############################################################################
# PostToolUse · *.tf — auto-fmt + validate + tflint the touched module/env.
# Surfaces failures back to Claude (exit 2) so they get fixed immediately.
# Offline only (init -backend=false); never touches AWS.
###############################################################################
set -uo pipefail

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except Exception: print("")' 2>/dev/null)"

case "$FILE" in
  *.tf|*.tfvars) ;;
  *) exit 0 ;;
esac

DIR="$(dirname "$FILE")"
TF="$(command -v tofu || command -v terraform || true)"
[ -z "$TF" ] && { echo "post-tf: tofu/terraform not installed — skipping" >&2; exit 0; }

# Auto-format (in place) — keeps diffs clean.
"$TF" fmt "$FILE" >/dev/null 2>&1 || true

# init -backend=false + validate the directory.
if ! "$TF" -chdir="$DIR" init -backend=false -input=false -no-color >/tmp/post-tf-init.log 2>&1; then
  echo "post-tf: init failed in $DIR:" >&2; tail -20 /tmp/post-tf-init.log >&2; exit 2
fi
if ! OUT="$("$TF" -chdir="$DIR" validate -no-color 2>&1)"; then
  echo "post-tf: validate FAILED in $DIR:" >&2; echo "$OUT" >&2; exit 2
fi

# tflint (best-effort).
if command -v tflint >/dev/null 2>&1; then
  ( cd "$DIR" && tflint --no-color ) >/tmp/post-tf-tflint.log 2>&1 || {
    echo "post-tf: tflint findings in $DIR:" >&2; tail -20 /tmp/post-tf-tflint.log >&2; exit 2; }
fi

echo "post-tf: $DIR fmt+validate+tflint OK"
exit 0
