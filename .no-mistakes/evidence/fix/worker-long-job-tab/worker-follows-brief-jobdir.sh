#!/usr/bin/env bash
# Executes the generated brief's job-tab recipe literally, as an ordinary worker would.
set -u; JOBDIR=${2:?jobdir}
OUT=${1:?transcript path}
exec >"$OUT" 2>&1
echo "worker env: HERDR_SESSION=${HERDR_SESSION:-<unset>} HERDR_PANE_ID=${HERDR_PANE_ID:-<unset>}"
if [ -z "${HERDR_SESSION:-}" ] || [ -z "${HERDR_PANE_ID:-}" ]; then
  echo "STOP: HERDR_SESSION or HERDR_PANE_ID unset/empty - not in a Herdr pane; asking firstmate rather than selecting another workspace"
  exit 3
fi
echo '$ herdr pane current --pane "$HERDR_PANE_ID" --session "$HERDR_SESSION"'
cur=$(herdr pane current --pane "$HERDR_PANE_ID" --session "$HERDR_SESSION") || { echo "STOP: workspace cannot be identified"; exit 4; }
echo "$cur"
ws=$(printf '%s' "$cur" | jq -r '.result.pane.workspace_id // empty')
[ -n "$ws" ] || { echo "STOP: workspace cannot be identified"; exit 4; }
echo "own workspace: $ws"
echo '$ herdr tab create --workspace '"$ws"' --label nm-pipeline --no-focus --session "$HERDR_SESSION"'
tab=$(herdr tab create --workspace "$ws" --label nm-pipeline --no-focus --session "$HERDR_SESSION")
echo "$tab"
tab_id=$(printf '%s' "$tab" | jq -r '.result.tab.tab_id')
pane=$(printf '%s' "$tab" | jq -r '.result.root_pane.pane_id')
echo "job tab: $tab_id pane: $pane"
job="python3 -c 'import subprocess; subprocess.run([\"bash\",\"-c\",\"for i in 1 2 3; do echo long-job tick \$i; sleep 1; done; echo JOB-DONE > ${JOBDIR}/job.out\"], timeout=120)'"
echo "\$ herdr pane run $pane \"$job\" --session \"\$HERDR_SESSION\""
herdr pane run "$pane" "$job" --session "$HERDR_SESSION"
for _ in $(seq 1 30); do [ -f ${JOBDIR}/job.out ] && break; sleep 1; done
echo "job output file: $(cat ${JOBDIR}/job.out 2>/dev/null || echo MISSING)"
echo "$tab_id" > ${JOBDIR}/job-tab-id
echo "$pane" > ${JOBDIR}/job-pane-id
echo "RECIPE-DONE"
