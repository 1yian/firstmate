#!/usr/bin/env bash
# Opt-in live guard: an Orca terminal whose agent has exited to a bare login
# shell is positively detected as recovery-grade `dead` (the exited-to-shell
# wedge), while the cheap snapshot still calls it `ambiguous`.
#
# This is a harness-dependent check: its verdict comes from the REAL rendered
# terminal screen (a bare login-shell prompt) plus Orca's own terminal-list and
# worktree-ps fields. A fake CLI can only echo the assumption already written
# into the fixture, so this exercises the installed runtime end to end: it
# creates a disposable worktree with a terminal running NO agent - exactly the
# state a crashed/exited agent leaves, a PTY fallen back to the login shell - and
# proves fm_backend_orca_agent_state escalates that connected-no-agent terminal
# to `dead` so the existing recovery/relaunch path can clear and relaunch it,
# instead of wedging on `ambiguous` and needing a manual `orca terminal close`.
#
# tests/fm-backend-orca.test.sh is the portable regression that pins the
# classifier logic everywhere (positive conjunction, every single-deviation
# negative, and the two-read persistence guard) with no harness; this is the
# harness-gated counterpart. Run it after every Orca upgrade and before trusting
# refreshed Orca evidence in docs/verification/runtime-backends.md.
#
# Isolation: a throwaway git repo under a temp dir, registered with Orca only for
# the duration of the run. It creates exactly one disposable worktree, never
# launches an agent, and removes the worktree (and closes its terminal) before
# exiting. It never touches the fleet's worktrees, homes, or tasks.
set -u

if [ "${FM_ORCA_EXITED_TO_SHELL_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_ORCA_EXITED_TO_SHELL_LIVE_E2E=1 to run the live Orca exited-to-shell recovery guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORCA_BIN=${FM_ORCA_BIN:-$(command -v orca || true)}
[ -n "$ORCA_BIN" ] && [ -x "$ORCA_BIN" ] \
  || fail "orca CLI not found; install it or set FM_ORCA_BIN. This guard refuses to pass without checking the real runtime."

ORCA_VERSION=""
for plist in /Applications/Orca.app/Contents/Info.plist "${FM_ORCA_APP_PLIST:-}"; do
  [ -n "$plist" ] && [ -f "$plist" ] || continue
  ORCA_VERSION=$(defaults read "${plist%/Contents/Info.plist}/Contents/Info" CFBundleShortVersionString 2>/dev/null \
    || plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)
  [ -n "$ORCA_VERSION" ] && break
done
[ -n "$ORCA_VERSION" ] || ORCA_VERSION="unknown"
printf 'harness: Orca %s (%s)\n' "$ORCA_VERSION" "$ORCA_BIN"

HARNESS_LABEL="Orca $ORCA_VERSION"
harness_fail() {  # <message>
  fail "$1 [harness: $HARNESS_LABEL]"
}

command -v node >/dev/null 2>&1 || harness_fail "node not found; the Orca adapter parses JSON with node"

# Confirm the runtime is actually ready, or this guard proves nothing.
if ! "$ORCA_BIN" status --json 2>/dev/null | node -e '
const fs = require("fs");
let d; try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
const r = (d.result) || {};
const rt = r.runtime || {};
const reachable = rt.reachable ?? r.runtimeReachable;
const state = rt.state || r.runtimeState || "";
process.exit(reachable === true && state === "ready" ? 0 : 1);
'; then
  harness_fail "Orca runtime is not ready (start Orca and wait for the runtime); refusing to claim a verified result"
fi

# shellcheck source=bin/backends/orca.sh
. "$ROOT/bin/backends/orca.sh"

# A real, fast two-read settle so this exercises the persistence guard for real.
export FM_ORCA_EXITED_SHELL_SETTLE=1

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-orca-exited-shell.XXXXXX")
REPO="$LAB/repo"
WT_NAME="fm-orca-exited-shell-$$"
CREATED_WT_ID=""

cleanup_all() {
  [ -n "$CREATED_WT_ID" ] && "$ORCA_BIN" worktree rm --worktree "id:$CREATED_WT_ID" --force --json >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q --allow-empty -m "live-e2e fixture"
git -C "$REPO" branch -M main

# Create the worktree and reuse its primary terminal - a login shell with NO
# agent launched, which is exactly the exited-to-shell end state.
RAW=$(fm_backend_orca_worktree_create "$REPO" "$WT_NAME") \
  || harness_fail "fm_backend_orca_worktree_create failed against the real Orca runtime"
CREATED_WT_ID=${RAW%%$'\t'*}
REST=${RAW#*$'\t'}
WT_PATH=${REST%%$'\t'*}
TERM=""
[ "$REST" != "$WT_PATH" ] && TERM=${REST#*$'\t'}
[ -n "$CREATED_WT_ID" ] || harness_fail "worktree create returned no worktree id"
[ -n "$TERM" ] || TERM=$(fm_backend_orca_worktree_startup_terminal "$CREATED_WT_ID" 2>/dev/null || true)
[ -n "$TERM" ] || harness_fail "could not obtain the worktree's primary terminal handle"

# Wait for the login shell to actually render its prompt, or the screen read
# proves nothing. Poll the positive bare-shell detector on the real screen.
CAPS=$(fm_backend_orca_composer_caps)
rendered_bare_shell=0
for _ in $(seq 1 30); do
  SCREEN=$(fm_backend_orca_composer_capture "$TERM" 2>/dev/null || true)
  if [ -n "$SCREEN" ] && fm_composer_screen_is_bare_shell "$CAPS" "$SCREEN"; then
    rendered_bare_shell=1
    break
  fi
  sleep 0.5
done
[ "$rendered_bare_shell" = 1 ] \
  || harness_fail "the worktree's terminal never rendered a recognizable bare login-shell prompt; screen tail:"$'\n'"$SCREEN"

# The cheap snapshot must still be conservative: connected terminal, no
# attributable agent = ambiguous (it deliberately does not read the screen).
SNAP=$(fm_backend_orca_agent_snapshot "$TERM")
case "$SNAP" in
  *"liveness=ambiguous"*) : ;;
  *) harness_fail "expected the cheap snapshot to stay ambiguous for a connected no-agent terminal, got: $SNAP" ;;
esac

# The recovery-grade classifier must escalate that ambiguous terminal to `dead`
# via the exited-to-shell probe, so the existing dead/missing recovery path can
# clear and relaunch it instead of wedging.
STATE=$(fm_backend_orca_agent_state "$TERM")
[ "$STATE" = dead ] \
  || harness_fail "expected exited-to-shell to classify the bare-shell terminal as recovery-grade dead, got: $STATE"

pass "Orca $ORCA_VERSION: a connected terminal at a bare login shell (no agent) is snapshot-ambiguous but classified recovery-grade dead by the exited-to-shell probe"
