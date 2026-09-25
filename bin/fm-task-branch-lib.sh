#!/usr/bin/env bash
# fm-task-branch-lib.sh - single owner of a ship worker's task branch name.
#
# A new worker names its own branch in conventional-commit style,
# `<type>/<slug>`: <type> is one of FM_TASK_BRANCH_TYPES and <slug> is a short
# kebab-case summary of the change (for example `fix/mileage-readback`). The
# worker creates it through bin/fm-task-branch.sh, which refuses a taken name
# and records the choice as `branch=<name>` in the task's metadata, so every
# later tool uses the recorded name instead of guessing one.
#
# Tasks created before recorded names carry no `branch=` and keep the branch they
# already have until they land: the plain task id (`<id>`), or the older legacy
# `fm/<id>`. Every consumer that must FIND a task branch resolves through
# fm_task_branch_resolve rather than assuming one name.
#
# FM_TASK_BRANCH_TYPES
#   The accepted conventional-commit types.
# fm_task_branch_name_valid <name>
#   Succeeds when <name> is `<type>/<slug>` with an accepted type and a
#   lowercase kebab-case slug of at most 48 characters.
# fm_task_branch_recorded <meta-file>
#   Prints the last recorded `branch=` value, or nothing.
# fm_task_branch_plain <id> / fm_task_branch_legacy <id>
#   Print the fallback names older tasks carry: `<id>` and `fm/<id>`.
# fm_task_branch_resolve <git-dir> <id> [<worktree>] [<recorded>]
#   Prints the existing local task branch for <id> in <git-dir>. A recorded name
#   is authoritative: it is the only candidate, and a missing recorded branch
#   returns 1 rather than falling back to another name. Without one, the plain
#   id and then the legacy name are candidates; when the task worktree is given
#   and is checked out on a candidate, that branch wins, so a stray same-named
#   branch never outranks the task's own. Returns 1, printing nothing, when no
#   candidate exists.
# fm_task_branch_candidates_text <id> [<recorded>]
#   Prints the human-readable candidate list for a not-found diagnostic.
# fm_task_branch_first_action <fm-root> <meta-file>
#   Prints the worker instruction that chooses, creates, and records the branch,
#   shared by an ordinary ship brief and a scout promotion.
#
# No side effects on source. set -u / set -e safe.

FM_TASK_BRANCH_TYPES="feat fix refactor perf docs test chore ci build"

fm_task_branch_name_valid() {
  local name=$1 type slug
  case "$name" in
    */*) ;;
    *) return 1 ;;
  esac
  type=${name%%/*}
  slug=${name#*/}
  case " $FM_TASK_BRANCH_TYPES " in
    *" $type "*) ;;
    *) return 1 ;;
  esac
  [ "${#slug}" -le 48 ] || return 1
  printf '%s\n' "$slug" | LC_ALL=C grep -Eqx '[a-z0-9]+(-[a-z0-9]+)*'
}

fm_task_branch_recorded() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F= '$1 == "branch" { sub(/^[^=]*=/, ""); v = $0 } END { if (v != "") print v }' "$1" 2>/dev/null || true
}

fm_task_branch_plain() {
  printf '%s\n' "$1"
}

fm_task_branch_legacy() {
  printf 'fm/%s\n' "$1"
}

fm_task_branch_resolve() {
  local dir=$1 id=$2 wt=${3:-} recorded=${4:-} current candidate
  local candidates=()
  if [ -n "$recorded" ]; then
    candidates=("$recorded")
  else
    candidates=("$(fm_task_branch_plain "$id")" "$(fm_task_branch_legacy "$id")")
  fi
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    current=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    for candidate in "${candidates[@]}"; do
      if [ "$current" = "$candidate" ] \
        && git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  for candidate in "${candidates[@]}"; do
    if git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

fm_task_branch_candidates_text() {
  local id=$1 recorded=${2:-}
  if [ -n "$recorded" ]; then
    printf 'recorded branch %s\n' "$recorded"
  else
    printf 'branch %s nor legacy %s\n' "$(fm_task_branch_plain "$id")" "$(fm_task_branch_legacy "$id")"
  fi
}

fm_task_branch_first_action() {
  local root=$1 meta=$2 q_script q_meta
  q_script=$(printf '%s' "$root/bin/fm-task-branch.sh" | sed "s/'/'\\\\''/g")
  q_meta=$(printf '%s' "$meta" | sed "s/'/'\\\\''/g")
  cat <<EOF
create your task branch, named \`<type>/<slug>\`: \`<type>\` is the conventional-commit type that fits this task (${FM_TASK_BRANCH_TYPES// /, }) and \`<slug>\` is a short kebab-case summary of the change, about 2-5 words and not the task id (for example \`fix/mileage-readback\`).
   Create and record it with \`'$q_script' create '$q_meta' <type>/<slug>\` rather than plain \`git checkout -b\`, so firstmate's tools find it.
   If the name is taken, pick another slug; if the command reports this task already has a recorded branch, continue on that branch.
EOF
}
