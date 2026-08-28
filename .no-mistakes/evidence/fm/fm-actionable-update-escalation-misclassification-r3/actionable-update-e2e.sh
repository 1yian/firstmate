#!/usr/bin/env bash
set -eu
ROOT=/Users/kunchen/.no-mistakes/worktrees/52b07e9083e7/01M12PPCPPK0MFWMRG952X5BCK
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M12PPCPPK0MFWMRG952X5BCK
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-actionable-evidence)
case_dir=$(make_case actionable-update)
state="$case_dir/state"
fakebin="$case_dir/fakebin"
status="$state/release.status"
first_out="$case_dir/first.out"
drain_out="$case_dir/drain.out"
drain_err="$case_dir/drain.err"
replay_out="$case_dir/replay.out"
printf 'done:\t\tBackpass 0.1.7 release and local install completed\nworking: tidying release notes\n' > "$status"
export FM_FAKE_CREW_STATE='state: working · source: pane · actively working'
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$first_out" &
pid=$!
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; echo 'ERROR: watcher did not surface'; exit 1; fi
wait "$pid"
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2> "$drain_err"
before=$(wc -l < "$state/.wake-queue" | tr -d ' ')
printf 'working: cleanup continued\n' >> "$status"
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
  "$ROOT/bin/fm-watch.sh" > "$replay_out" &
pid=$!
i=0
while [ "$i" -lt 200 ]; do
  streak=$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] && break
  kill -0 "$pid" 2>/dev/null || { echo 'ERROR: watcher re-queued the surfaced completion'; exit 1; }
  sleep 0.1
done
kill -0 "$pid" 2>/dev/null || { echo 'ERROR: watcher exited during replay check'; exit 1; }
after=$(wc -l < "$state/.wake-queue" | tr -d ' ')
replay_bytes=$(wc -c < "$replay_out" | tr -d ' ')
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
printf '%s\n' '=== Crew status batch (tabs rendered as <TAB>) ==='
perl -pe 's/\t/<TAB>/g' "$status"
printf '%s\n' '=== First real watcher result ==='
cat "$first_out"
printf '%s\n' '=== Main-session drain output ==='
cat "$drain_out"
printf '%s\n' '=== Later routine append and heartbeat replay check ==='
printf 'watcher remained active: yes\nheartbeat recovery ran: yes\nadditional queued wakes: %s\nreplay output bytes: %s\n' "$((after - before))" "$replay_bytes"
