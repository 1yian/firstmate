#!/usr/bin/env bash
# tests/fm-composer-pi-worker-editor-live-e2e.test.sh - the live guard for the
# Pi worker composer pin (live-harness-optin family).
#
# bin/fm-spawn.sh loads the tracked .pi/fm-worker-plain-composer.ts into every
# Pi worker so a user-installed editor extension (pi-zentui's rail box, for
# example) cannot replace the native composer that the shared classifier
# (bin/fm-composer-lib.sh) reads. Whether that holds depends on real Pi
# extension load order and UI binding, so per
# .agents/skills/firstmate-coding-guidelines it is proven against the
# INSTALLED Pi in an isolated tmux server:
#   - a scratch Pi agent dir carries a stub third-party editor, auto-discovered
#     like any user extension (so it loads after -e) and installed
#     asynchronously from session_start the way pi-zentui does; without the
#     pin its box must NOT classify empty, which keeps the case non-vacuous;
#   - with the pin the idle composer classifies empty, typed text classifies
#     pending, and both survive session replacement (/new) and /reload, the
#     two points where an editor extension re-runs its installation;
#   - the operator's own Pi configuration, launched with the pin exactly as
#     workers are, also reaches an empty idle composer.
# It fails naming pi and `pi --version`.
#
# No prompt is ever submitted (/new and /reload are local commands), so no
# model tokens are spent and the gate is default-on wherever pi and tmux are
# installed (fm_live_gate): FM_COMPOSER_PI_WORKER_EDITOR_LIVE=1 forces it (an
# absent pi then fails instead of skipping) and =0 disables it.
# Refresh docs/verification/runtime-backends.md ("Pi worker composer pin")
# from this guard's output after any Pi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_PI_WORKER_EDITOR_LIVE pi tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/.pi/fm-worker-plain-composer.ts"
[ -f "$PIN" ] || { printf 'not ok - worker composer pin missing at %s\n' "$PIN" >&2; exit 1; }

SOCKET="fm-pi-worker-editor-$$"
SESSION="piworkereditor"
TMP_ROOT=$(fm_test_tmproot fm-pi-worker-editor-live)
AGENT_DIR="$TMP_ROOT/agent"
CWD="$TMP_ROOT/cwd"
CHECKED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR" "$AGENT_DIR/extensions" "$CWD"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

VERSION=$(pi --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'
LABEL="pi ($VERSION)"

# A left-rail box with a metadata row inside it and no native borders: the
# shape class of pi-zentui's default editor, which the classifier cannot read.
STUB_MARK='stub-model  Stub Provider  high'
printf '{"quietStartup":true}\n' > "$AGENT_DIR/settings.json"
cat > "$AGENT_DIR/extensions/rail-editor.ts" <<TS
import { CustomEditor, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
const plain = (s: string) => s.replace(/\x1b\[[0-9;]*m/g, "");
class RailEditor extends CustomEditor {
  render(width: number): string[] {
    const rows = super.render(Math.max(1, width - 2)).filter((row) => !/^─+\$/.test(plain(row).trim()));
    return [...rows.map((row) => "│ " + row), "│", "│ $STUB_MARK"];
  }
}
export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    await new Promise((resolve) => setTimeout(resolve, 50));
    ctx.ui.setEditorComponent((tui, theme, keybindings) => new RailEditor(tui, theme, keybindings));
  });
}
TS

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 45 -c "$CWD"

launch() {  # <window> <launch-cmd...>
  local win=$1
  shift
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$CWD" -- "$@" \
    || fail "$LABEL: could not launch window $win in the isolated tmux server"
}

screen() {  # <window>
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$1" 2>/dev/null
}

show_tail() {  # <window>
  printf '# %s pane tail:\n' "$1" >&2
  screen "$1" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
}

wait_for_verdict() {  # <window> <verdict> [polls] -> prints the last verdict
  local win=$1 want=$2 budget=${3:-${FM_COMPOSER_PI_WORKER_EDITOR_POLLS:-45}} i=0 verdict=''
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = "$want" ] && break
    i=$((i + 1))
    sleep 1
  done
  printf '%s' "$verdict"
}

wait_for_stub() {  # <window>
  local i=0
  while [ "$i" -lt "${FM_COMPOSER_PI_WORKER_EDITOR_POLLS:-45}" ]; do
    screen "$1" | grep -qF "$STUB_MARK" && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

type_command() {  # <window> <text>
  tmux -L "$SOCKET" send-keys -t "$SESSION:$1" -l "$2"
  sleep 0.3
  tmux -L "$SOCKET" send-keys -t "$SESSION:$1" Enter
}

expect_native_empty() {  # <window> <context>
  local verdict
  verdict=$(wait_for_verdict "$1" empty)
  if [ "$verdict" != empty ]; then
    show_tail "$1"
    fail "$LABEL: $2: pinned idle composer did not classify empty (last verdict: ${verdict:-unreadable})"
  fi
  if screen "$1" | grep -qF "$STUB_MARK"; then
    show_tail "$1"
    fail "$LABEL: $2: the third-party editor replaced the pinned native composer"
  fi
}

# --- 1. Divergence: the stub editor really does blind the classifier --------
launch unpinned env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 pi --no-session
wait_for_stub unpinned || { show_tail unpinned; fail "$LABEL: the stub third-party editor never rendered; the pinned case would be vacuous"; }
sleep 1
unpinned=$(fm_tmux_composer_state "$SESSION:unpinned")
[ "$unpinned" != empty ] || { show_tail unpinned; fail "$LABEL: the stub editor classified empty without the pin; the pinned case would be vacuous"; }
note "$LABEL: stub third-party editor without the pin classifies $unpinned"
tmux -L "$SOCKET" kill-window -t "$SESSION:unpinned" 2>/dev/null || true

# --- 2. The pin keeps the native composer through replacement and reload -----
launch pinned env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 pi --no-session -e "$PIN"
expect_native_empty pinned "startup under a third-party editor"
tmux -L "$SOCKET" send-keys -t "$SESSION:pinned" -l 'held draft'
typed=$(wait_for_verdict pinned pending 10)
[ "$typed" = pending ] || { show_tail pinned; fail "$LABEL: typed text in the pinned composer did not classify pending (last verdict: ${typed:-unreadable})"; }
tmux -L "$SOCKET" send-keys -t "$SESSION:pinned" C-u
expect_native_empty pinned "after clearing the draft"
type_command pinned /new
expect_native_empty pinned "after session replacement (/new)"
type_command pinned /reload
expect_native_empty pinned "after /reload"
CHECKED=$((CHECKED + 1))
pass "$LABEL: the worker pin keeps the native composer (idle empty, typed pending) through /new and /reload under a third-party editor"
tmux -L "$SOCKET" kill-window -t "$SESSION:pinned" 2>/dev/null || true

# --- 3. The operator's own Pi configuration, launched as workers are ---------
launch operator env PI_OFFLINE=1 pi --no-session -e "$PIN"
verdict=$(wait_for_verdict operator empty)
if [ "$verdict" != empty ]; then
  show_tail operator
  fail "$LABEL: the operator's own Pi configuration launched with the worker pin did not reach an empty composer (last verdict: ${verdict:-unreadable})"
fi
CHECKED=$((CHECKED + 1))
pass "$LABEL: the operator's own Pi configuration launched with the worker pin classifies empty"

[ "$CHECKED" -gt 0 ] || fail "live Pi worker composer guard verified nothing; refusing a vacuous pass"
pass "live Pi worker composer guard verified $CHECKED live surface(s)"
