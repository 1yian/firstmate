#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "/Users/kunchen/.no-mistakes/worktrees/52b07e9083e7/01M1FYYX65TA7TZTJFPKXZQ2NX/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

# One owner for the readiness budget every unready-successor test below spends
# on purpose. Both plugins start a successor arm through a login shell and
# SIGTERM it when it stays silent past this budget, so the budget has to outlast
# a cold login-shell start. A successor killed before its first statement never
# appends its arm row and never installs the TERM trap these tests observe, so
# too small a budget reports a lost successor instead of the bounded recovery
# under test. A stock login shell already costs about 200ms on an idle
# workstation, and a loaded CI runner is slower, so keep an order of magnitude
# over that rather than a value that only holds locally. The wait loops in those
# tests are sized against this number.
ARM_READY_TIMEOUT_MS=2000

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_pi_session_replacement_carries_inflight_actionable_close() {
  local repo home plugin log marker_root trigger stop out status
  repo="$TMP_ROOT/pi-session-replacement-handoff-root"
  home="$TMP_ROOT/pi-session-replacement-handoff-home"
  log="$TMP_ROOT/pi-session-replacement-handoff.log"
  marker_root="$TMP_ROOT/pi-session-replacement-handoff-markers"
  trigger="$TMP_ROOT/pi-session-replacement-handoff.trigger"
  stop="$TMP_ROOT/pi-session-replacement-handoff.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$marker_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
marker=$(mktemp "${FM_MARKER_ROOT:?}/arm.XXXXXX") || exit 1
cleanup() { rm -f "$marker"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf 'arm pid=%s marker=%s\n' "$$" "$marker" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=replacement-fixture\n' "$$"
while :; do
  if [ -e "$FM_TRIGGER_FILE" ]; then
    outcome=$(cat "$FM_TRIGGER_FILE")
    rm -f "$FM_TRIGGER_FILE"
    printf 'signal: %s\n' "$outcome"
    exit 0
  fi
  [ ! -e "$FM_STOP_FILE" ] || exit 0
  sleep 0.02
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_MARKER_ROOT="$marker_root" FM_TRIGGER_FILE="$trigger" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let releaseOldDelivery = () => {};
const oldDeliveryRelease = new Promise((resolve) => {
  releaseOldDelivery = resolve;
});
let oldDeliveryStarted = false;

function makePi(blockDelivery = false) {
  const handlers = new Map();
  const eventHandlers = new Map();
  let tool = null;
  const prompts = [];
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      prompts.push(message);
    },
    events: {
      on(event, handler) {
        eventHandlers.set(event, [...(eventHandlers.get(event) ?? []), handler]);
      },
      emit(event, data) {
        if (blockDelivery && event === "fm-branch-supervision:dispatch") {
          oldDeliveryStarted = true;
          data.accept(oldDeliveryRelease);
        }
        for (const handler of eventHandlers.get(event) ?? []) handler(data);
      },
    },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function armRows() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter((row) => row.startsWith("arm "))
    .map((row) => {
      const match = /pid=(\d+) marker=(\S+)/.exec(row);
      return match ? { pid: match[1], marker: match[2] } : { pid: "", marker: "" };
    });
}

function liveArms() {
  return armRows().filter((arm) => arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid));
}

async function waitFor(pred, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/replacement-race.meta`, "project=/projects/replacement-race\nwindow=fm-replacement-race\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\treplacement-race.status\tsignal: replacement-race actionable outcome\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const previous = makePi(true);
mod.default(previous.pi);
const initial = await previous.getTool().execute("initial-arm", {}, undefined, undefined, {});
if (!initial.details?.ok || !String(initial.details.message).includes("started Pi extension arm child")) {
  throw new Error(`initial arm failed: ${JSON.stringify(initial.details)}`);
}
await waitFor(() => liveArms().length === 1, "initial live arm");

writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-race actionable outcome\n");
await waitFor(() => oldDeliveryStarted, "old-session accepted branch delivery");
if (previous.prompts.length !== 0) {
  throw new Error(`accepted old-session branch wake reached main: ${previous.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 2, "old-session successor");
writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-successor actionable outcome\n");
await waitFor(() => liveArms().length === 0, "mid-delivery successor actionable close");

await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await waitFor(() => liveArms().length === 0, "retired old-session successor");

const replacement = makePi(false);
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=durable-handoff`);
replacementMod.default(replacement.pi);
const replacementStart = replacement.handlers.get("session_start")?.({
  type: "session_start",
  reason: "new",
  previousSessionFile: "/tmp/previous.jsonl",
}, {});
await new Promise((resolve) => setTimeout(resolve, 50));
await waitFor(() => liveArms().length === 1 && armRows().length >= 3, "replacement arm before old delivery settlement");
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`replacement raced the accepted old-session delivery: ${replacement.prompts.join(" | ")}`);
}
writeFileSync(
  `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`,
  "{malformed handoff\n",
);
releaseOldDelivery();
await replacementStart;
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: replacement-successor actionable outcome")),
  "replacement-session successor actionable delivery",
);
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`settled old-session branch delivery was replayed: ${replacement.prompts.join(" | ")}`);
}
if (replacement.prompts.filter((message) => message.includes("signal: replacement-successor actionable outcome")).length !== 1) {
  throw new Error(`replacement session did not receive exactly one carried successor outcome: ${replacement.prompts.join(" | ")}`);
}
if (!replacement.prompts.some((message) => message.includes("could not clear a delivered replacement-session actionable wake"))) {
  throw new Error(`handoff cleanup failure was not surfaced: ${replacement.prompts.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 700));
if (replacement.prompts.filter((message) => message.includes("could not clear a delivered replacement-session actionable wake")).length !== 1) {
  throw new Error(`persistent handoff cleanup failure repeated alerts: ${replacement.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 3, "replacement live arm");
const redundant = await replacement.getTool().execute("replacement-redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`replacement did not retain automatic arm ownership: ${JSON.stringify(redundant.details)}`);
}

await new Promise((resolve) => setTimeout(resolve, 100));
if (liveArms().length !== 1) {
  throw new Error(`old delivery completion disturbed replacement ownership: ${JSON.stringify(liveArms())}`);
}
const replacementWake = replacement.prompts.find((message) => message.includes("signal: replacement-successor actionable outcome")) ?? "";
console.log(`SCENARIO=same-process /new during blocked actionable delivery`);
console.log(`OLD_ACCEPTED_WAKE_REPLAYED=${replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))}`);
console.log(`MID_DELIVERY_WAKE_COUNT=${replacement.prompts.filter((message) => message.includes("signal: replacement-successor actionable outcome")).length}`);
console.log(`REPLACEMENT_LIVE_ARM_COUNT=${liveArms().length}`);
console.log(`REPLACEMENT_TOTAL_ARM_GENERATIONS=${armRows().length}`);
console.log(`WAKE_SURFACE=${JSON.stringify(replacementWake)}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session replacement must auto-arm and carry an in-flight actionable close"
  [ -n "$out" ] || fail "Pi session-replacement evidence test printed no end-user state"
  printf '%s\n' "$out"
  pass "Pi session replacement auto-arms and carries its in-flight actionable close"
}


test_pi_session_replacement_carries_inflight_actionable_close
