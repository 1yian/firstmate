#!/usr/bin/env bash
set -eu
ROOT="/Users/kunchen/.no-mistakes/worktrees/52b07e9083e7/01M12YWPZRYESBKX7D6FXTNT6K"
. "$ROOT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot actionable-routing-evidence)

wait_for_exit_demo() {
  local pid=$1 i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

dir=$(make_case hidden-actionable-demo)
state="$dir/state"
fakebin="$dir/fakebin"
status_file="$state/release.status"
watch_out="$dir/watch.out"
drain_out="$dir/drain.out"

printf 'done: release and local installation completed successfully\n' > "$status_file"
printf 'working: tidying release notes\n' >> "$status_file"
export FM_FAKE_CREW_STATE='state: working · source: pane · actively working'
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$watch_out" &
pid=$!
wait_for_exit_demo "$pid"
unset FM_FAKE_CREW_STATE
FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null

printf '%s\n' 'STATUS STREAM (actionable completion followed by routine work):'
cat "$status_file"
printf '%s\n' 'WATCHER OUTPUT (main session is awakened):'
cat "$watch_out"
printf '%s\n' 'DURABLE WAKE DRAIN (queued signal delivered to firstmate):'
cat "$drain_out"
printf '%s\n' 'SURFACED EVENT IDENTITY:'
cat "$state/.hb-surfaced-release"
printf '\n'
