#!/usr/bin/env bash
# Brief's "before reporting done" step: list own workspace tabs scoped to the session, close only the created tab.
set -u; JOBDIR=${2:?jobdir}
exec >"$1" 2>&1
[ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] || { echo STOP; exit 3; }
ws=$(herdr pane current --pane "$HERDR_PANE_ID" --session "$HERDR_SESSION" | jq -r '.result.pane.workspace_id')
tab_id=$(cat ${JOBDIR}/job-tab-id)
echo '$ herdr tab list --workspace '"$ws"' --session "$HERDR_SESSION"'
herdr tab list --workspace "$ws" --session "$HERDR_SESSION" | jq -c '.result.tabs[]|{tab_id,label}'
echo "job already finished (JOB-DONE present: $(cat ${JOBDIR}/job.out))"
echo '$ herdr tab close '"$tab_id"' --session "$HERDR_SESSION"'
herdr tab close "$tab_id" --session "$HERDR_SESSION" | jq -c .
herdr tab list --workspace "$ws" --session "$HERDR_SESSION" | jq -c '.result.tabs[]|{tab_id,label}'
echo CLEANUP-DONE
