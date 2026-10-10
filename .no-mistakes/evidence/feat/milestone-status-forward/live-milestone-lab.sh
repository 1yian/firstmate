#!/usr/bin/env bash
# Live lab drive of production-milestone forwarding: two disposable lab homes
# (a main firstmate and a secondmate bound to it), real bin/ scripts, no fakes,
# no FM_*_OVERRIDE relocation, tmux confined to the lab's private socket dir.
set -u
ROOT=${ROOT:?run from the gate worktree with ROOT set}
cd "$ROOT" || exit 1
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_CAPTAIN_RE; do unset "$v"; done
MAIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$MAIN"
MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$MATE"
bin/fm-lab-home.sh create "$MAIN" >/dev/null; bin/fm-lab-home.sh create "$MATE" >/dev/null
mkdir -p "$MAIN/tmux" "$MATE/tmux"
export TMUX_TMPDIR="$MATE/tmux"
cleanup() { for p in $(jobs -p); do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$MAIN" "$MATE"; }
trap cleanup EXIT

timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die' "$s" "$@"; }
say() { printf '\n### %s\n' "$*"; }
show() { printf -- '--- %s\n' "$1"; if [ -f "$1" ]; then cat "$1"; else echo '(absent)'; fi; }

# Secondmate binding, in the exact format bin/fm-home-seed.sh writes.
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$(cd "$MAIN" && pwd -P)" > "$MATE/.fm-secondmate-parent"
: > "$MATE/AGENTS.md"
# Main home's record of the secondmate.
printf 'window=firstmate:fm-mate\nendpoint_task_id=mate\nworktree=%s\nproject=%s\nharness=pi\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=aegiscx\n' "$MATE" "$MATE" "$MATE" > "$MAIN/state/mate.meta"
printf 'working: delegated scope: AegisCX production cutover\n' > "$MAIN/state/mate.status"
# The secondmate's child ship task (the CNP incident shape).
mkdir -p "$MATE/projects/aegiscx"; git -C "$MATE/projects/aegiscx" init -q; git -C "$MATE/projects/aegiscx" -c user.name=lab -c user.email=lab@x commit -q --allow-empty -m init
printf 'window=firstmate:fm-cutover\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=s1.lab\n' "$MATE/projects/aegiscx" "$MATE/projects/aegiscx" > "$MATE/state/cutover.meta"
printf 'working: building the AegisCX 4.21.0 release\n' > "$MATE/state/cutover.status"

say "S1: child appends the go-live milestones; real secondmate watcher polls"
printf 'milestone [at=%s]: AegisCX 4.21.0 released to production\nworking: watching the rollout\nnote: rollout dashboards green\nmilestone [at=%s]: production terraform applied (25 added, 0 destroyed)\nworking: preparing the first full run\nmilestone: first full production run started (run 1)\n' "$(date +%s)" "$(date +%s)" >> "$MATE/state/cutover.status"
show "$MATE/state/cutover.status"
FM_HOME="$MATE" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  timeout 60 bin/fm-watch.sh > "$MATE/watch1.out" 2>&1; echo "mate watcher exit=$?"
show "$MATE/watch1.out"
echo "== parent channel (main home state/mate.status) after mate poll:"
show "$MAIN/state/mate.status"

say "S2: second poll does not re-deliver (once-only)"
before=$(wc -l < "$MAIN/state/mate.status")
FM_HOME="$MATE" bin/fm-inactive-reconcile.sh scan; echo "scan exit=$?"
FM_HOME="$MATE" bin/fm-inactive-reconcile.sh scan; echo "scan exit=$?"
after=$(wc -l < "$MAIN/state/mate.status")
echo "parent lines before=$before after=$after"

say "S3: main watcher (default vocabulary) wakes on the forwarded milestone"
export TMUX_TMPDIR="$MAIN/tmux"
FM_HOME="$MAIN" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  timeout 60 bin/fm-watch.sh > "$MAIN/watch.out" 2>&1; echo "main watcher exit=$?"
show "$MAIN/watch.out"
FM_HOME="$MAIN" bin/fm-wake-drain.sh > "$MAIN/drain.out" 2> "$MAIN/drain.err"; echo "drain exit=$?"
show "$MAIN/drain.out"; show "$MAIN/drain.err"

say "S4: child finishes; terminal done: still delivered after milestones, latest-state not shadowed"
printf 'done: AegisCX 4.21.0 live in production, first full run healthy\nmilestone: second production run started (run 2)\n' >> "$MATE/state/cutover.status"
export TMUX_TMPDIR="$MATE/tmux"
FM_HOME="$MATE" bin/fm-inactive-reconcile.sh scan; echo "scan exit=$?"
show "$MAIN/state/mate.status"
echo "last_status_line(child) = $(bash -c '. bin/fm-classify-lib.sh; last_status_line "$1"' _ "$MATE/state/cutover.status")"
echo "fm-crew-state-free classify: terminal? $(bash -c '. bin/fm-classify-lib.sh; status_is_terminal_verb "milestone: x" && echo yes || echo no')"

say "S5: main home with FM_CAPTAIN_RE set to the documented value still wakes on a direct child's milestone"
export TMUX_TMPDIR="$MAIN/tmux"
FM_HOME="$MAIN" bin/fm-wake-drain.sh >/dev/null 2>&1 || true
printf 'window=firstmate:fm-infra\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=s2.lab\n' "$MAIN" "$MAIN" > "$MAIN/state/infra.meta"
printf 'working: applying production infrastructure\n' > "$MAIN/state/infra.status"
FM_HOME="$MAIN" bash -c '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/infra.status"; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/mate.status"' 2>/dev/null
RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
( sleep 4; printf 'milestone [at=%s]: production terraform applied (25 added, 0 destroyed)\n' "$(date +%s)" >> "$MAIN/state/infra.status" ) &
FM_HOME="$MAIN" FM_CAPTAIN_RE="$RE" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  timeout 60 bin/fm-watch.sh > "$MAIN/watch2.out" 2>&1; echo "main watcher (FM_CAPTAIN_RE) exit=$?"
show "$MAIN/watch2.out"
FM_HOME="$MAIN" bin/fm-wake-drain.sh > "$MAIN/drain2.out" 2>/dev/null; show "$MAIN/drain2.out"

say "S6 (adversarial): FM_CAPTAIN_RE override vs routine working: (control) and milestone"
FM_CAPTAIN_RE="$RE" bash -c '. bin/fm-classify-lib.sh; for l in "working: applying production infrastructure" "milestone: AegisCX 4.21.0 released to production" "note: staging deploy done"; do status_is_captain_relevant "$l" && r=relevant || r=not-relevant; echo "FM_CAPTAIN_RE=<documented>  $r  <- $l"; done'
echo "lab homes removed at exit"
