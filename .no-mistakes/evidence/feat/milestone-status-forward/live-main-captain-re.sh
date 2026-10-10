#!/usr/bin/env bash
# Live lab drive: a MAIN-home ship child appends a production milestone while the
# operator runs the real watcher with FM_CAPTAIN_RE set to the documented
# default value. Shows whether the watcher absorbs routine progress and whether
# it wakes on the milestone. Also shows the pure classifier answer.
# Usage: live-main-captain-re.sh <firstmate-tree> <label>
set -u
TREE=$1; LABEL=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ms-main.XXXXXX"); MAIN="$WORK/main"
trap 'for p in $(jobs -p); do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
"$TREE/bin/fm-lab-home.sh" create "$MAIN" >/dev/null || exit 1
CHILD=aegis-deploy
mkdir -p "$MAIN/projects/$CHILD"; git -C "$MAIN/projects/$CHILD" init -q
printf '%s\n' "window=fm-lab-none:fm-$CHILD" "worktree=$MAIN/projects/$CHILD" "project=$MAIN/projects/$CHILD" \
  "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s1.lab" > "$MAIN/state/$CHILD.meta"
LEDGER="$MAIN/state/$CHILD.status"
printf 'working: applying production infrastructure\n' > "$LEDGER"
drain_ack() {
  local out seq gen
  out=$(FM_HOME="$MAIN" "$TREE/bin/fm-wake-drain.sh" 2>&1)
  printf '%s\n' "$out" | grep -E 'signal|annotation|BACKSTOP|^'"$CHILD"' |OPEN DECISION' | sed 's/^/  drain | /'
  seq=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1/p' | tail -1)
  gen=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\2/p' | tail -1)
  [ -z "$seq" ] || FM_HOME="$MAIN" "$TREE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
arm() { FM_HOME="$MAIN" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$TREE/bin/fm-watch.sh" > "$1" 2>&1 & echo $!; }
waitexit() { local i=0; while [ $i -lt "$2" ] && kill -0 "$1" 2>/dev/null; do sleep 0.25; i=$((i+1)); done; kill -0 "$1" 2>/dev/null && echo alive || echo exited; }

echo "=== [$LABEL] FM_CAPTAIN_RE='$FM_CAPTAIN_RE'"
. "$TREE/bin/fm-classify-lib.sh"
for l in 'milestone [at=1791591000]: production terraform applied (25 added, 0 destroyed)' 'working: planning the first run'; do
  if status_is_captain_relevant "$l"; then r=relevant; else r=not-relevant; fi
  echo "classifier: status_is_captain_relevant '$l' -> $r"
done
pid=$(arm "$WORK/w0.out"); echo "first arm on the initial working: line -> $(waitexit "$pid" 20)"; kill "$pid" 2>/dev/null
sed 's/^/  watcher | /' "$WORK/w0.out"; drain_ack
pid=$(arm "$WORK/w1.out"); sleep 3
printf 'working: still applying\n' >> "$LEDGER"
echo "after a routine working: append -> watcher $(waitexit "$pid" 24)"
sed 's/^/  watcher | /' "$WORK/w1.out"
if kill -0 "$pid" 2>/dev/null; then :; else drain_ack; pid=$(arm "$WORK/w1b.out"); sleep 3; fi
printf 'milestone [at=1791591000]: production terraform applied (25 added, 0 destroyed)\n' >> "$LEDGER"
echo "after the milestone append -> watcher $(waitexit "$pid" 40)"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
cat "$WORK"/w1*.out 2>/dev/null | sed 's/^/  watcher | /'
drain_ack
echo "=== [$LABEL] done"
