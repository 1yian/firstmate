#!/usr/bin/env bash
# fm-task-branch.sh - a ship worker creates and records its task branch.
#
# Usage: fm-task-branch.sh create <task-meta-file> <type>/<slug>
#
# Run by the worker from inside its own task worktree, as the first action its
# instructions give it (bin/fm-task-branch-lib.sh owns the naming rule and the
# rendered instruction). It:
#   1. validates the name as `<type>/<slug>` (bin/fm-task-branch-lib.sh);
#   2. requires the current directory's repository top level to be the task
#      worktree the metadata records, so it never branches another checkout;
#   3. under the task's metadata lock, refuses a name that is already a local
#      branch or a known remote-tracking branch, so an existing branch is never
#      reused or clobbered, and refuses a different name when the task already
#      recorded one;
#   4. creates the branch with `git checkout -b` (git itself refuses a racing
#      creation of the same name), then records `branch=<name>` in the task
#      metadata by atomic replacement, which every later tool resolves.
#
# Re-running with the recorded name is idempotent: on that branch it only
# confirms; when the recorded branch exists but is not checked out it switches
# to it. An unrecorded existing branch is always refused, even when checked out.
# A creation interrupted before metadata publication requires supervisor recovery,
# never automatic adoption of a branch whose ownership cannot be proven.
#
# Exit status: 0 created or confirmed; 1 refused or failed; 2 usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-branch-lib.sh
. "$SCRIPT_DIR/fm-task-branch-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  echo "usage: fm-task-branch.sh create <task-meta-file> <type>/<slug>" >&2
  exit 2
}

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
fi
[ "$#" -eq 3 ] && [ "$1" = create ] || usage
META=$2
NAME=$3

if ! fm_task_branch_name_valid "$NAME"; then
  echo "error: branch name '$NAME' must be <type>/<slug> with type one of: $FM_TASK_BRANCH_TYPES; slug lowercase kebab-case, at most 48 characters (for example fix/mileage-readback)" >&2
  exit 1
fi
git check-ref-format --branch "$NAME" >/dev/null 2>&1 || {
  echo "error: '$NAME' is not a valid git branch name" >&2
  exit 1
}

case "$META" in
  /*.meta) ;;
  *) echo "error: task metadata must be an absolute path to <task-id>.meta" >&2; exit 2 ;;
esac
STATE=${META%/*}
META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: invalid task metadata path: $META" >&2; exit 2; }
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: task record is unavailable: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}

WT=$(LC_ALL=C awk -F= '$1 == "worktree" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$META")
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: task record names no existing worktree" >&2; exit 1; }
WT_REAL=$(cd "$WT" && pwd -P)
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: run this from inside the task worktree $WT" >&2; exit 1; }
TOP_REAL=$(cd "$TOP" && pwd -P)
[ "$TOP_REAL" = "$WT_REAL" ] || {
  echo "error: current repository $TOP_REAL is not the task worktree $WT_REAL; refusing to branch it" >&2
  exit 1
}

META_TMP=
META_LOCK_HELD=0
cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: task record is unavailable: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}

RECORDED=$(fm_task_branch_recorded "$META")
CURRENT=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -n "$RECORDED" ] && [ "$RECORDED" != "$NAME" ]; then
  echo "error: this task already recorded branch $RECORDED; continue on it (git checkout $RECORDED) instead of creating $NAME" >&2
  exit 1
fi

branch_exists() {
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$1" >/dev/null
}

if [ "$RECORDED" = "$NAME" ]; then
  if [ "$CURRENT" = "$NAME" ]; then
    echo "branch $NAME already recorded and checked out"
    exit 0
  fi
  if branch_exists "$NAME"; then
    git -C "$WT" checkout -q "$NAME" || { echo "error: could not switch to recorded branch $NAME" >&2; exit 1; }
    echo "switched to recorded branch $NAME"
    exit 0
  fi
  echo "error: recorded branch $NAME is missing; ask firstmate to recover it" >&2
  exit 1
fi

if branch_exists "$NAME"; then
  echo "error: branch $NAME already exists; choose a different slug" >&2
  exit 1
fi
if [ -n "$(git -C "$WT" for-each-ref --format='%(refname)' "refs/remotes/*/$NAME" 2>/dev/null)" ]; then
  echo "error: a remote branch named $NAME already exists; choose a different slug" >&2
  exit 1
fi
git -C "$WT" checkout -q -b "$NAME" || { echo "error: could not create branch $NAME" >&2; exit 1; }

META_TMP=$(mktemp "$STATE/.${META##*/}.branch.XXXXXX")
LC_ALL=C awk -F= '$1 != "branch"' "$META" > "$META_TMP"
printf 'branch=%s\n' "$NAME" >> "$META_TMP"
META_MODE=$(stat -c '%a' "$META" 2>/dev/null || stat -f '%Lp' "$META")
chmod "$META_MODE" "$META_TMP"
if ! fm_backlog_atomic_transition publish "$META_TMP" "$META" "task record" "$STATE"; then
  echo "error: branch $NAME was created but could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); ask firstmate to recover its metadata" >&2
  exit 1
fi
META_TMP=
echo "created and recorded branch $NAME"
