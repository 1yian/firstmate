#!/usr/bin/env bash
# Opt-in live guard: an Orca-backed spawn reuses the worktree's PRIMARY terminal.
#
# `orca worktree create` creates the worktree AND its first terminal by default,
# but the shape it returns is something only the real Orca runtime can settle:
# `orca worktree create --help` documents result.agentTerminalHandle (with
# --agent) and result.startupTerminal.handle (older runtimes), while the live
# 1.4.x runtime returns NEITHER under `--setup skip` without `--agent` and yet
# still creates the first terminal (present in `orca terminal list`, keyed by
# worktreeId). A fake CLI can only echo the assumption already written into the
# fixture, so this exercises the installed runtime end to end: it proves the
# worktree-create path yields the worktree's own primary terminal, so a spawned
# agent lands in that first tab instead of a second tab beside an idle one.
#
# tests/fm-backend-orca.test.sh is the portable regression that pins the handle
# extraction and the reuse plumbing everywhere; this is the harness-gated
# counterpart. Run it after every Orca upgrade and before trusting refreshed
# Orca evidence in docs/verification/runtime-backends.md.
#
# Isolation: a throwaway git repo under a temp dir, registered with Orca only for
# the duration of the run. It creates exactly one disposable worktree and removes
# it (and closes its terminal) before exiting. It never touches the fleet's
# worktrees, homes, or tasks.
set -u

if [ "${FM_ORCA_PRIMARY_TERMINAL_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_ORCA_PRIMARY_TERMINAL_LIVE_E2E=1 to run the live Orca primary-terminal guard"
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

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-orca-primary.XXXXXX")
REPO="$LAB/repo"
WT_NAME="fm-orca-primary-$$"
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

# Drive the exact code path fm-spawn uses to obtain the reusable terminal.
RAW=$(fm_backend_orca_worktree_create "$REPO" "$WT_NAME") \
  || harness_fail "fm_backend_orca_worktree_create failed against the real Orca runtime"

CREATED_WT_ID=${RAW%%$'\t'*}
REST=${RAW#*$'\t'}
WT_PATH=${REST%%$'\t'*}
RETURNED_TERM=""
[ "$REST" != "$WT_PATH" ] && RETURNED_TERM=${REST#*$'\t'}

[ -n "$CREATED_WT_ID" ] || harness_fail "worktree create returned no worktree id"
[ -n "$WT_PATH" ] || harness_fail "worktree create returned no worktree path"

# THE FIX: the worktree-create path must yield the worktree's own primary
# terminal, so fm-spawn reuses it instead of opening a second tab.
[ -n "$RETURNED_TERM" ] \
  || harness_fail "worktree create did not yield the worktree's primary terminal handle; a spawned agent would land in a second tab"

# The returned handle must be the worktree's actual, sole live terminal - proof
# it is the primary tab and that no second tab exists to reuse.
LIVE_COUNT=$("$ORCA_BIN" terminal list --json 2>/dev/null | node -e '
const fs = require("fs");
const wt = process.argv[1];
let d; try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
const terms = (d.result && d.result.terminals) || [];
const mine = terms.filter(t => t && t.worktreeId === wt && t.connected !== false && t.orphaned !== true);
process.stdout.write(String(mine.length));
' "$CREATED_WT_ID") || harness_fail "orca terminal list failed"

MATCHES=$("$ORCA_BIN" terminal list --json 2>/dev/null | node -e '
const fs = require("fs");
const wt = process.argv[1];
const want = process.argv[2];
let d; try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
const terms = (d.result && d.result.terminals) || [];
const hit = terms.some(t => t && t.worktreeId === wt && t.handle === want);
process.stdout.write(hit ? "yes" : "no");
' "$CREATED_WT_ID" "$RETURNED_TERM") || harness_fail "orca terminal list failed"

[ "$MATCHES" = yes ] \
  || harness_fail "the reused terminal handle ($RETURNED_TERM) is not a terminal of the created worktree"

[ "$LIVE_COUNT" = 1 ] \
  || harness_fail "expected exactly one live terminal (the primary tab) for the worktree, found $LIVE_COUNT; a spawn would leave a stray idle tab"

pass "Orca $ORCA_VERSION: worktree create yields the worktree's sole primary terminal for reuse (no second tab)"
