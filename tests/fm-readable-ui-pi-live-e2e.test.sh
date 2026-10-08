#!/usr/bin/env bash
# tests/fm-readable-ui-pi-live-e2e.test.sh - the live guard for .pi/fm-readable-ui.ts
# (live-harness-optin family).
#
# The extension's two behaviors are judged from what the INSTALLED Pi draws, so per
# .agents/skills/firstmate-coding-guidelines they are proven end to end in a private tmux
# server with a scratch Pi agent directory, from the user's side of the terminal:
#   - a canned session reopened without the extension keeps Pi's stock rows and flowing
#     prose, which keeps every later case non-vacuous;
#   - with it, collapsed tool calls are one `● tool(subject) - meta` row each, with the
#     supplied subject clipped to 35 cells and exit, timeout, interruption, and unknown-tool
#     errors visible; ctrl+o restores Pi's own output; prose starts each sentence on its own
#     line while code, tables, and abbreviations stay whole; at a narrow width in fullscreen
#     mode the status meta still shows;
#   - with Firstmate Calm on, every tool row matches a Calm-only run character for
#     character, so Calm's hiding stays authoritative while prose layout still applies;
#   - /export embeds the same pre-rendered tool HTML as a run without the extension;
#   - a local faux provider streams a reply whose inline code and link arrive incomplete,
#     runs a failing command and an interrupted one, and the reopened session shows the same
#     rows while its stored text keeps the original prose.
# It fails naming pi and `pi --version`.
#
# No prompt reaches a real provider: the streamed turns come from Pi's in-process faux
# provider, so no model tokens are spent and the gate is default-on wherever pi, tmux, and
# node are installed (fm_live_gate): FM_READABLE_UI_PI_LIVE=1 forces it (an absent tool then
# fails instead of skipping) and =0 disables it.
# Refresh docs/verification/runtime-backends.md ("Pi readable transcript") from this guard's
# output after any Pi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_READABLE_UI_PI_LIVE pi tmux node

EXT="$ROOT/.pi/fm-readable-ui.ts"
CALM="$ROOT/.pi/extensions/fm-calm.ts"
[ -f "$EXT" ] || fail "readable transcript extension missing at $EXT"

VERSION=$(pi --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'
LABEL="pi ($VERSION)"
SOCKET="fm-readable-ui-$$"
TMP_ROOT=$(fm_test_tmproot fm-readable-ui-live)
AGENT_DIR="$TMP_ROOT/agent"
CWD="$TMP_ROOT/cwd"
FM_CONFIG="$TMP_ROOT/fmconfig"
CANNED="$TMP_ROOT/canned.jsonl"
CHECKED=0
mkdir -p "$AGENT_DIR" "$CWD/src" "$FM_CONFIG" "$TMP_ROOT/sessions"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

note() { printf '# %s\n' "$1"; }
die() { fail "$LABEL: $1"; }

printf '{"quietStartup":true,"theme":"dark","collapseChangelog":true,"lastChangelogVersion":"%s","cacheWarming":"off"}\n' \
  "$VERSION" > "$AGENT_DIR/settings.json"
printf 'const port: number = 8080;\n' > "$CWD/src/index.ts"

# --- Canned session: every collapsed-row status and the prose shapes that must stay whole ---
node - "$CWD" "$CANNED" <<'JS' || die "could not write the canned session"
const [cwd, out] = process.argv.slice(2);
const fs = require("node:fs");
const t0 = Date.parse("2026-10-08T07:00:00Z");
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const lines = [{ type: "session", version: 3, id: "0199c1a0-0000-7000-8000-00000000f00d", timestamp: new Date(t0).toISOString(), cwd }];
let n = 0, parent = null;
const push = (message) => {
  const id = (++n).toString(16).padStart(8, "0");
  lines.push({ type: "message", id, parentId: parent, timestamp: new Date(t0 + n * 1000).toISOString(), message: { ...message, timestamp: t0 + n * 1000 } });
  parent = id;
};
const assistant = (content, stopReason) => push({ role: "assistant", content, api: "anthropic-messages", provider: "anthropic", model: "canned", usage, stopReason });
const result = (id, toolName, text, isError = false, details) => push({ role: "toolResult", toolCallId: id, toolName, content: [{ type: "text", text }], details, isError });
push({ role: "user", content: "Check the build and tell me what broke." });
assistant([
  { type: "toolCall", id: "c1", name: "bash", arguments: { command: "npm run build --workspace packages/app && echo done", timeout: 120 } },
  { type: "toolCall", id: "c2", name: "read", arguments: { path: `${cwd}/src/index.ts`, offset: 10, limit: 3 } },
  { type: "toolCall", id: "c3", name: "grep", arguments: { pattern: "TODO\\(build\\)", path: "src" } },
  { type: "toolCall", id: "c4", name: "bash", arguments: { command: "sleep 300 && curl -s https://example.invalid/health", timeout: 5 } },
  { type: "toolCall", id: "c5", name: "bash", arguments: { command: "make watch" } },
  { type: "toolCall", id: "c6", name: "lab_unknown_tool", arguments: { query: "is this registered?" } },
], "toolUse");
result("c1", "bash", "> tsc -p .\n\nsrc/index.ts(14,7): error TS2322: Type 'string' is not assignable to type 'number'.\n\nCommand exited with code 2", true);
result("c2", "read", "10\tconst line0 = 0;\n11\tconst line1 = 1;\n12\tconst line2 = 2;");
result("c3", "grep", "src/index.ts:14: // TODO(build): fix type");
result("c4", "bash", "Command timed out after 5 seconds", true);
result("c5", "bash", "watching...\n\nCommand aborted", true);
result("c6", "lab_unknown_tool", "Tool lab_unknown_tool not found", true);
assistant([{ type: "text", text: [
  "## Build status",
  "",
  "The build failed because port was typed as a number but assigned a string. I changed it to the numeric literal, e.g. `8080`, which matches the type. Dr. Smith's note is unrelated.",
  "",
  "- First item has two sentences. This is the second one.",
  "",
  "> Quoted context with one sentence. And another sentence here.",
  "",
  "```ts",
  "const port: number = 8080; // Keep. Code is never split.",
  "```",
  "",
  "| Check | Result |",
  "|---|---|",
  "| build | fixed. verified |",
  "",
  "Version 2.5 shipped on time. Next steps are listed above.",
].join("\n") }], "stop");
fs.writeFileSync(out, lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
JS

# --- Helpers -------------------------------------------------------------------
PI_BASE=(pi --offline --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve)

launch() {  # <name> <width> <tui-mode> <pi args...>
  local name=$1 width=$2 mode=$3
  shift 3
  tmux -L "$SOCKET" new-session -d -s "$name" -x "$width" -y 120 -c "$CWD" -- \
    env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 FM_CONFIG_OVERRIDE="$FM_CONFIG" \
    "${PI_BASE[@]}" --tui-mode "$mode" "$@" \
    || die "could not launch $name in the isolated tmux server"
}

screen() {  # <name>
  tmux -L "$SOCKET" capture-pane -p -J -S -400 -t "$1" 2>/dev/null
}

raw_screen() {  # <name>: rows exactly as drawn, without joining wrapped lines
  tmux -L "$SOCKET" capture-pane -p -S -400 -t "$1" 2>/dev/null
}

wait_for() {  # <name> <fixed text> [polls]
  local i=0 budget=${3:-${FM_READABLE_UI_POLLS:-300}}
  while [ "$i" -lt "$budget" ]; do
    screen "$1" | grep -qF -- "$2" && return 0
    i=$((i + 1))
    sleep 0.1
  done
  printf '# %s screen tail:\n' "$1" >&2
  screen "$1" | grep '[^[:space:]]' | tail -25 | sed 's/^/#   /' >&2
  return 1
}

has_line() {  # <name> <exact line after trimming>
  screen "$1" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//' | grep -qxF -- "$2"
}

expect_line() {  # <name> <exact line> <why>
  has_line "$1" "$2" || { screen "$1" | grep '[^[:space:]]' | tail -40 | sed 's/^/#   /' >&2; die "$3 (missing line: $2)"; }
}

refuse_text() {  # <name> <fixed text> <why>
  if screen "$1" | grep -qF -- "$2"; then
    screen "$1" | grep '[^[:space:]]' | tail -40 | sed 's/^/#   /' >&2
    die "$3 (unexpected: $2)"
  fi
}

prose_region() {  # <name>: transcript above the editor, visible characters only, so layout-only differences vanish
  screen "$1" | awk '/^─+$/ { exit } { print }' | tr -d '[:space:]│'
}

kill_session() { tmux -L "$SOCKET" kill-session -t "$1" 2>/dev/null || true; }

reopen() {  # <name> <width> <tui-mode> [extra pi args...]
  local name=$1 width=$2 mode=$3 copy="$TMP_ROOT/$1.jsonl"
  shift 3
  cp "$CANNED" "$copy"
  launch "$name" "$width" "$mode" --session "$copy" "$@"
}

ROW_EXIT='● bash(npm run build --workspace packages…) - exit 2'
ROW_TIMEOUT='● bash(sleep 300 && curl -s https://examp…) - timed out after 5s'
ROW_INTERRUPTED='● bash(make watch) - interrupted'
ROW_UNKNOWN='● lab_unknown_tool(is this registered?) - error'

# --- 1. Divergence: stock Pi draws its own rows and flowing prose ---------------
reopen stock 110 regular
wait_for stock 'Version 2.5 shipped on time. Next steps are listed above.' \
  || die "stock Pi never drew the canned reply as one flowing paragraph; later cases would be vacuous"
refuse_text stock '● bash(' "stock Pi already draws compact rows; the extension case would be vacuous"
wait_for stock 'Command exited with code 2' || die "stock Pi did not show the failing command's output"
note "$LABEL: stock rows and flowing prose confirmed without the extension"
kill_session stock

# --- 2. Collapsed rows, prose layout, and expansion in regular mode -------------
reopen wide 110 regular -e "$EXT"
wait_for wide "$ROW_EXIT" || die "the failing command did not collapse to one row with its exit code"
for row in "$ROW_TIMEOUT" "$ROW_INTERRUPTED" "$ROW_UNKNOWN" '● grep(TODO\(build\))'; do
  expect_line wide "$row" "a collapsed tool call did not draw its one-row summary"
done
read_subject="$CWD/src/index.ts"
[ "${#read_subject}" -le 35 ] || read_subject="${read_subject:0:34}…"
expect_line wide "● read($read_subject)" "the read row did not keep its supplied path clipped to 35 cells"
refuse_text wide 'const line0 = 0;' "a collapsed row still showed its result output"
expect_line wide 'Version 2.5 shipped on time.' "the closing sentences were not split onto their own lines"
expect_line wide 'Next steps are listed above.' "the closing sentences were not split onto their own lines"
expect_line wide 'I changed it to the numeric literal, e.g. 8080, which matches the type.' "an abbreviation split its sentence"
expect_line wide 'This is the second one.' "a list item's second sentence was not on its own line"
expect_line wide '│ And another sentence here.' "a quoted second sentence was not on its own quoted line"
expect_line wide 'const port: number = 8080; // Keep. Code is never split.' "code inside a fence was split"
screen wide | grep -qF '│ build │ fixed. verified │' || die "a table cell was split"
CHECKED=$((CHECKED + 1))
pass "$LABEL: collapsed rows show subject and status; prose starts each sentence on its own line"

tmux -L "$SOCKET" send-keys -t wide C-o
wait_for wide 'const line0 = 0;' || die "ctrl+o did not restore the read output"
for text in 'Command exited with code 2' '$ npm run build --workspace packages/app && echo done' \
  'Command timed out after 5 seconds' '"query": "is this registered?"' 'Tool lab_unknown_tool not found'; do
  screen wide | grep -qF -- "$text" || die "expanded rows did not restore Pi's own rendering (missing: $text)"
done
refuse_text wide "$ROW_EXIT" "an expanded row kept its collapsed summary"
CHECKED=$((CHECKED + 1))
pass "$LABEL: ctrl+o restores each tool's own call, output, and generic fallback"
kill_session wide

# --- 3. Narrow fullscreen: status meta stays visible and rows fit ---------------
reopen narrow 44 fullscreen -e "$EXT"
wait_for narrow '- exit 2' || die "the narrow row lost its exit status"
for text in '- timed out after 5s' '- interrupted' '- error'; do
  screen narrow | grep -qF -- "$text" || die "a narrow row lost its status meta (missing: $text)"
done
long=$(raw_screen narrow | node -e 'for (const line of require("node:fs").readFileSync(0, "utf8").split("\n")) if ([...line].length > 44) { process.stdout.write(line); break; }')
[ -z "$long" ] || die "a narrow fullscreen row overflowed 44 columns: $long"
CHECKED=$((CHECKED + 1))
pass "$LABEL: at 44 columns in fullscreen mode every row fits and keeps its status meta"
kill_session narrow

# --- 4. Calm on: tool rows exactly as Calm draws them ---------------------------
printf 'on\n' > "$FM_CONFIG/calm"
reopen calmonly 110 regular -e "$CALM"
reopen calmext 110 regular -e "$CALM" -e "$EXT"
wait_for calmonly 'Version 2.5 shipped on time.' || die "the Calm-only run never drew the reply"
wait_for calmext 'Next steps are listed above.' || die "the Calm run with the extension never drew the reply"
expect_line calmext 'Next steps are listed above.' "prose layout stopped applying while Calm is on"
refuse_text calmext '● bash(' "a compact row appeared although Calm is on"
screen calmext | grep -qF '"query": "is this registered?"' || die "Calm on lost Pi's generic row for an unregistered tool"
[ "$(prose_region calmonly)" = "$(prose_region calmext)" ] \
  || die "with Calm on, the transcript differs from a Calm-only run beyond prose line breaks"
CHECKED=$((CHECKED + 1))
pass "$LABEL: with Calm on, rows match a Calm-only run character for character and prose layout still applies"
kill_session calmonly
kill_session calmext
printf 'off\n' > "$FM_CONFIG/calm"

# --- 5. /export keeps Pi's own pre-rendered tool HTML ----------------------------
export_html() {  # <name> <pi args...> -> path of the exported HTML
  local name=$1 out="$TMP_ROOT/$1.html"
  shift
  reopen "$name" 110 regular "$@"
  wait_for "$name" 'Next steps are listed above' || die "$name never drew the canned session"
  tmux -L "$SOCKET" send-keys -t "$name" -l "/export $out"
  tmux -L "$SOCKET" send-keys -t "$name" Enter
  wait_for "$name" "$out" || die "$name did not confirm its export"
  printf '%s\n' "$out"
}
html_stock=$(export_html exportstock)
html_ext=$(export_html exportext -e "$EXT")
wait_for exportext "$ROW_EXIT" || die "rows did not return to their collapsed summary after /export"
# shellcheck disable=SC2016 # Literal JavaScript.
verdict=$(node -e '
const fs = require("node:fs");
const read = (file) => {
  const html = fs.readFileSync(file, "utf8");
  const raw = /<script id="session-data"[^>]*>([\s\S]*?)<\/script>/.exec(html)[1].trim();
  try { return JSON.parse(Buffer.from(raw, "base64").toString("utf8")); } catch { return JSON.parse(raw); }
};
const a = read(process.argv[1]).renderedTools ?? {};
const b = read(process.argv[2]).renderedTools ?? {};
if (Object.keys(a).length === 0) process.stdout.write("empty");
else process.stdout.write(JSON.stringify(a) === JSON.stringify(b) ? "same" : "different");
' "$html_stock" "$html_ext") || die "could not read the exported session data"
[ "$verdict" != empty ] || die "stock /export pre-rendered no tools; the comparison would be vacuous"
[ "$verdict" = same ] || die "/export pre-rendered different tool HTML with the extension"
CHECKED=$((CHECKED + 1))
pass "$LABEL: /export embeds the same pre-rendered tool HTML as stock Pi, and rows collapse again afterwards"
kill_session exportstock
kill_session exportext

# --- 6. Live streaming, failure, interruption, and reopening ---------------------
cat > "$TMP_ROOT/faux-turns.ts" <<'TS'
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROSE = "The run finished. Use `npm run build. Then` again only if needed, e.g. after edits. " +
  "See [the guide. Part two](https://example.com/guide) for details! Was that clear? Yes.";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "readable-ui-faux-api",
    provider: "readable-ui-faux",
    models: [{ id: "scripted", name: "Readable UI faux", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 512 }],
    tokensPerSecond: 4,
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("readable-ui-faux", {
    baseUrl: "http://127.0.0.1/unused", apiKey: "test-only", api: faux.api, models: faux.models, streamSimple: faux.streamSimple,
  });
  const run = (name: string, responses: Parameters<typeof faux.setResponses>[0], prompt: string) =>
    pi.registerCommand(name, {
      description: "Run one scripted readable-ui turn.",
      handler: async (_args, ctx) => {
        const model = ctx.modelRegistry.find("readable-ui-faux", "scripted");
        if (!model || !(await pi.setModel(model))) throw new Error("faux model unavailable");
        faux.setResponses(responses);
        pi.sendUserMessage(prompt);
      },
    });
  run("readable-stream", [
    fauxAssistantMessage([fauxToolCall("bash", { command: "echo partial output; exit 3" }, { id: "live1" })], { stopReason: "toolUse" }),
    fauxAssistantMessage([fauxText(PROSE)]),
  ], "stream a reply");
  run("readable-hold", [
    fauxAssistantMessage([fauxToolCall("bash", { command: "sleep 30; echo too late" }, { id: "live2" })], { stopReason: "toolUse" }),
    fauxAssistantMessage([fauxText("Stopped.")]),
  ], "hold a command");
}
TS
launch live 100 regular --session-dir "$TMP_ROOT/sessions" -e "$TMP_ROOT/faux-turns.ts" -e "$EXT"
wait_for live '────' || die "the live session never reached its composer"
tmux -L "$SOCKET" send-keys -t live -l '/readable-stream'
tmux -L "$SOCKET" send-keys -t live Enter
frames=0
open_code=0
open_link=0
split_inside_markup=''
i=0
while [ "$i" -lt 1200 ]; do
  frame=$(screen live)
  case "$frame" in *'Use `npm run build'* | *'Use npm run build'*) frames=$((frames + 1)) ;; esac
  # Pi draws unfinished markup literally, so a visible backtick or bracket means it is still open.
  case "$frame" in *'Use `npm run build'*) open_code=$((open_code + 1)) ;; esac
  case "$frame" in *'See [the guide.'*) open_link=$((open_link + 1)) ;; esac
  if printf '%s\n' "$frame" | sed 's/^[[:space:]]*//' | grep -qE '^(Then` again|Then again|Part two)'; then
    split_inside_markup=$(printf '%s\n' "$frame" | grep -E '^[[:space:]]*(Then|Part two)' | head -1)
    break
  fi
  printf '%s\n' "$frame" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF 'Yes.' && break
  i=$((i + 1))
  sleep 0.05
done
[ -z "$split_inside_markup" ] || die "a streaming sentence break landed inside inline code or a link: $split_inside_markup"
[ "$open_code" -gt 0 ] && [ "$open_link" -gt 0 ] \
  || die "no frame caught the reply with its inline code and link still open (code $open_code, link $open_link); the streaming case would be vacuous"
wait_for live 'Was that clear?' || die "the streamed reply never finished"
expect_line live 'The run finished.' "the streamed reply's first sentence was not on its own line"
expect_line live 'Use npm run build. Then again only if needed, e.g. after edits.' "a break landed inside inline code"
expect_line live 'See the guide. Part two (https://example.com/guide) for details!' "a break landed inside a link"
expect_line live '● bash(echo partial output; exit 3) - exit 3' "the live failing command did not collapse with its exit code"
note "$LABEL: streamed reply observed across $frames frames ($open_code with open inline code, $open_link with an open link) without a break inside them"

tmux -L "$SOCKET" send-keys -t live -l '/readable-hold'
tmux -L "$SOCKET" send-keys -t live Enter
wait_for live '● bash(sleep 30; echo too late)' || die "the running command did not draw its row"
refuse_text live '● bash(sleep 30; echo too late) -' "a running command already showed a final status"
tmux -L "$SOCKET" send-keys -t live Escape
wait_for live '● bash(sleep 30; echo too late) - interrupted' || die "the interrupted command did not show interrupted"
CHECKED=$((CHECKED + 1))
pass "$LABEL: live streaming, a failing command, and an interrupted command draw the expected rows"
kill_session live

saved=$(find "$TMP_ROOT/sessions" -name '*.jsonl' -type f | head -1)
[ -n "$saved" ] || die "the live session was not saved"
# shellcheck disable=SC2016 # Literal Markdown backticks, not a command substitution.
grep -qF 'The run finished. Use `npm run build. Then` again' "$saved" \
  || die "the stored assistant text changed; prose layout must stay presentation-only"
launch reopened 100 regular --session "$saved" -e "$EXT"
wait_for reopened '● bash(sleep 30; echo too late) - interrupted' || die "the reopened session lost the interrupted row"
expect_line reopened '● bash(echo partial output; exit 3) - exit 3' "the reopened session lost the failing row"
expect_line reopened 'Was that clear?' "the reopened session lost sentence layout"
CHECKED=$((CHECKED + 1))
pass "$LABEL: the reopened session redraws the same rows and layout while its stored text keeps the original prose"
kill_session reopened

[ "$CHECKED" -gt 0 ] || fail "readable transcript guard verified nothing; refusing a vacuous pass"
pass "live readable transcript guard verified $CHECKED surface(s) on $LABEL"
