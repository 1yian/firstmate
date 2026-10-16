#!/usr/bin/env bash
# Worker inside its Herdr pane starts a job that would overrun (sleep 600) bounded by a
# Python timeout wrapper (gtimeout absent), per the brief; then cleans up its tab.
set -u
exec >"$1" 2>&1
echo "gtimeout on PATH: $(command -v gtimeout || echo absent)"
ws=$(herdr pane current --pane "$HERDR_PANE_ID" | jq -r '.result.pane.workspace_id // empty'); [ -n "$ws" ] || { echo STOP; exit 4; }
c=$(herdr tab create --workspace "$ws" --label long-build --no-focus)
tab=$(printf '%s' "$c" | jq -r .result.tab.tab_id); pane=$(printf '%s' "$c" | jq -r .result.root_pane.pane_id)
echo "ws=$ws tab=$tab pane=$pane"
start=$(date +%s)
herdr pane run "$pane" "python3 -c 'import subprocess; subprocess.run([\"sleep\",\"600\"], timeout=3)'; echo EXIT=\$?-end" >/dev/null
herdr pane wait-output "$pane" --match 'EXIT=1-end' --timeout 30000 >/dev/null && echo "job bounded; elapsed=$(( $(date +%s) - start ))s"
herdr pane read "$pane" --lines 6 --format text | grep -E 'TimeoutExpired|EXIT='
herdr tab close "$tab" | jq -c .result
herdr tab list --workspace "$ws" | jq -c '[.result.tabs[]|{tab_id,label}]'
echo OVERRUN-DONE
