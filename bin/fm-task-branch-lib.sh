#!/usr/bin/env bash
# fm-task-branch-lib.sh - single owner of a ship worker's task branch name.
#
# A newly created worker branch is the plain task-id slug (`<id>`), with no
# prefix. Tasks created before that change carry the legacy `fm/<id>` branch and
# keep it until they land, so every consumer that must FIND an existing task
# branch resolves through fm_task_branch_resolve rather than assuming one name.
#
# fm_task_branch <id>
#   Prints the branch name a new worker creates for task <id>.
# fm_task_branch_legacy <id>
#   Prints the legacy branch name (`fm/<id>`) older tasks still carry.
# fm_task_branch_resolve <git-dir> <id> [<worktree>]
#   Prints the existing local task branch for <id> in <git-dir>. When a task
#   worktree is given and is checked out on one of the two candidate names, that
#   branch wins, so a stray same-named branch never outranks the task's own.
#   Otherwise the plain slug wins over the legacy name. Returns 1, printing
#   nothing, when neither branch exists.
#
# No side effects on source. set -u / set -e safe.

fm_task_branch() {
  printf '%s\n' "$1"
}

fm_task_branch_legacy() {
  printf 'fm/%s\n' "$1"
}

fm_task_branch_resolve() {
  local dir=$1 id=$2 wt=${3:-} current candidate
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    current=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    for candidate in "$(fm_task_branch "$id")" "$(fm_task_branch_legacy "$id")"; do
      if [ "$current" = "$candidate" ] \
        && git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  for candidate in "$(fm_task_branch "$id")" "$(fm_task_branch_legacy "$id")"; do
    if git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
