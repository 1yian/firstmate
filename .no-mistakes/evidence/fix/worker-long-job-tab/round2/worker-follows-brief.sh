#!/usr/bin/env bash
# Ordinary worker following the round-2 generated brief's job-tab steps literally:
#   1. require $HERDR_PANE_ID (else stop and ask firstmate)
#   2. herdr pane current --pane "$HERDR_PANE_ID" -> workspace id
#   3. herdr tab create --workspace <id> --label <job-name> --no-focus
#   4. herdr pane run <new-pane-id> "<command with its own timeout>"
#   5. reuse the tab, list tabs, close only the tab created.
set -u
LOG=${1:?log path}
exec >"$LOG" 2>&1
echo "## worker env: HERDR_SESSION=${HERDR_SESSION:-<unset>} HERDR_PANE_ID=${HERDR_PANE_ID:-<unset>}"
echo "## step 1: require HERDR_PANE_ID"
if [ -z "${HERDR_PANE_ID:-}" ]; then echo "STOP: not in a Herdr pane; asking firstmate instead of selecting another workspace"; exit 3; fi
echo "## step 2: herdr pane current --pane \"\$HERDR_PANE_ID\""
cur=$(herdr pane current --pane "$HERDR_PANE_ID") || { echo "STOP: cannot identify workspace; ask firstmate"; exit 4; }
ws=$(printf '%s' "$cur" | jq -r '.result.pane.workspace_id // empty')
[ -n "$ws" ] || { echo "STOP: cannot identify workspace; ask firstmate"; exit 4; }
echo "resolved workspace=$ws (pane=$(printf '%s' "$cur" | jq -r .result.pane.pane_id))"
echo "## global focus at this moment (for contrast):"
herdr workspace list | jq -c '[.result.workspaces[]|{workspace_id,label,focused}]'
echo "## step 3: herdr tab create --workspace $ws --label nm-pipeline --no-focus"
created=$(herdr tab create --workspace "$ws" --label nm-pipeline --no-focus)
tab=$(printf '%s' "$created" | jq -r '.result.tab.tab_id')
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
echo "new tab=$tab label=$(printf '%s' "$created" | jq -r .result.tab.label) focused=$(printf '%s' "$created" | jq -r .result.tab.focused) new pane=$pane"
herdr tab list --workspace "$ws" | jq -c '[.result.tabs[] | {tab_id,label,focused}]'
JOB1="python3 -c 'import subprocess,sys; r=subprocess.run([\"sh\",\"-c\",\"for i in 1 2 3; do echo tick \$i; sleep 1; done; echo JOB1-\$((40+2))\"], timeout=60); sys.exit(r.returncode)'"
echo "## step 4: herdr pane run $pane <bounded job 1>"
herdr pane run "$pane" "$JOB1" >/dev/null
herdr pane wait-output "$pane" --match JOB1-42 --timeout 30000 >/dev/null && echo "job1 finished in $pane"
echo "## step 5: reuse the same tab for job 2"
JOB2="python3 -c 'import subprocess,sys; r=subprocess.run([\"sh\",\"-c\",\"echo second-job; sleep 1; echo JOB2-\$((40+3))\"], timeout=60); sys.exit(r.returncode)'"
herdr pane run "$pane" "$JOB2" >/dev/null
herdr pane wait-output "$pane" --match JOB2-43 --timeout 30000 >/dev/null && echo "job2 finished in $pane"
echo "## job pane output"
herdr pane read "$pane" --lines 14 --format text
echo "## step 6: list my workspace's tabs before reporting done"
herdr tab list --workspace "$ws" | jq -c '[.result.tabs[] | {tab_id,label}]'
echo "## step 7: close only the tab I created ($tab)"
herdr tab close "$tab" | jq -c .result
herdr tab list --workspace "$ws" | jq -c '[.result.tabs[] | {tab_id,label}]'
echo "WORKER-DONE"
