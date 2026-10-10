#!/usr/bin/env bash
# Control for S5: under the documented FM_CAPTAIN_RE, a main-home watcher with a
# direct child must NOT wake on a routine working: append, and MUST wake on a
# milestone: append. Real bin/fm-watch.sh in a disposable lab home.
set -u
cd "${ROOT:?}" || exit 1
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_CAPTAIN_RE; do unset "$v"; done
timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die' "$s" "$@"; }
RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
run_case() { # <label> <appended line>
  local LAB rc
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"; bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
  export TMUX_TMPDIR="$LAB/tmux"
  printf 'window=firstmate:fm-infra\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=s.lab\n' "$LAB" "$LAB" > "$LAB/state/infra.meta"
  printf 'working: applying production infrastructure\n' > "$LAB/state/infra.status"
  FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/infra.status"'
  ( sleep 3; printf '%s\n' "$2" >> "$LAB/state/infra.status" ) &
  FM_HOME="$LAB" FM_CAPTAIN_RE="$RE" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 15 bin/fm-watch.sh > "$LAB/watch.out" 2>&1; rc=$?
  wait
  printf '[%s] appended: %s\n  watcher rc=%s (142 = still absorbing at the 15s limit, no wake)\n  watcher output: %s\n' "$1" "$2" "$rc" "$(cat "$LAB/watch.out")"
  rm -rf "$LAB"
}
run_case control "working: still applying production infrastructure"
run_case milestone "milestone [at=$(date +%s)]: production terraform applied (25 added, 0 destroyed)"
