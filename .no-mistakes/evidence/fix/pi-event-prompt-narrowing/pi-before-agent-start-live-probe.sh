#!/usr/bin/env bash
# Live probe: drive the REAL Pi SDK (AgentSession + ExtensionRunner + DefaultResourceLoader)
# with the tracked fm-branch-supervision.ts (and, separately, fm-primary-pi-watch.ts) loaded
# through Pi's own resource loader. The only fake is a local provider whose fetch is
# intercepted in-process (no request leaves the machine, no credential is read).
#
# usage: pi-before-agent-start-live-probe.sh <source-tree> <pi-package-dir> <away|control|watch>
#   away    - a captain outcome is presented as a dedicated fm-branch-process triggerTurn run;
#             the away record appears in before_agent_start (before the context event). The
#             dedicated processing run must be ABORTED (no provider call against the parked main).
#   control - same without an away record: the processing run must proceed and reach the model
#             with the processing request in context.
#   watch   - the watcher extension sees a custom triggerTurn run and a user prompt run under the
#             real SDK without raising an extension error.
set -u
SRC=$1 PI_PACKAGE_DIR=$2 MODE=$3
ROOT_REAL=$(cd "$SRC" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-bas-probe.XXXXXX")
trap 'rm -rf "$T"' EXIT
repo="$T/repo" home="$T/home" agentdir="$T/agent"
mkdir -p "$repo/.pi/extensions/lib" "$repo/node_modules/@earendil-works" "$repo/bin" "$home/state" "$home/config" "$home/sessions" "$agentdir"
cp -L "$SRC/.pi/extensions/fm-branch-supervision.ts" "$SRC/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/"
cp -L "$SRC"/.pi/extensions/lib/*.ts "$repo/.pi/extensions/lib/"
cp "$SRC/bin/fm-operational-input.sh" "$repo/bin/"
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then printf 'confirmed %s\n' "$2" >> "$FM_PROBE_WATCH_LOG"; exit 0; fi
printf 'arm pid=%s\n' "$$" >> "$FM_PROBE_WATCH_LOG"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=probe-gen\n' "$$"
trap 'exit 0' TERM INT
while :; do
  if [ -e "$FM_PROBE_WATCH_TRIGGER" ]; then r=$(cat "$FM_PROBE_WATCH_TRIGGER"); rm -f "$FM_PROBE_WATCH_TRIGGER"; printf '%s\n' "$r"; exit 0; fi
  sleep 0.02
done
SH
chmod +x "$repo/bin/"*.sh
for p in pi-coding-agent; do ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/$p"; done
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"
cat > "$agentdir/models.json" <<'JSON'
{"providers":{"fm-probe":{"baseUrl":"https://fm-probe.invalid/v1","api":"openai-completions","apiKey":"fm-probe-placeholder",
 "models":[{"id":"fm-probe-model","name":"fm probe","contextWindow":8192,"maxTokens":512}]}}}
JSON
if [ "$MODE" = watch ]; then PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts"; ROOT_FOR_PLUGIN="$repo"; else PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts"; ROOT_FOR_PLUGIN="$ROOT_REAL"; fi
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT_FOR_PLUGIN" FM_REAL_ROOT="$ROOT_REAL" PLUGIN="$PLUGIN" MODE="$MODE" \
  FM_PROBE_WATCH_LOG="$T/watch.log" FM_PROBE_WATCH_TRIGGER="$T/watch.trigger" \
  PI_CODING_AGENT_DIR="$agentdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" NODE_NO_WARNINGS=1 \
  node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME, mode = process.env.MODE, realRoot = process.env.FM_REAL_ROOT;
const pkg = resolve(process.env.PI_PACKAGE_DIR);
const version = JSON.parse(readFileSync(`${pkg}/package.json`, "utf8")).version;
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } =
  await import(pathToFileURL(`${pkg}/dist/index.js`).href);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const sh = (script, ...args) => {
  const r = spawnSync("bash", [`${realRoot}/bin/${script}`, ...args], { encoding: "utf8", env: { ...process.env, FM_ROOT_OVERRIDE: realRoot } });
  if (r.status !== 0) throw new Error(`${script} ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
};
let seq = null;
if (mode !== "watch") {
  sh("fm-branch-outcome.sh", "processed-init");
  seq = Number(sh("fm-branch-outcome.sh", "append", "--task", "probe-task", "--verdict", "captain", "--summary", "PR https://example.invalid/pr/1 needs the captain"));
}
const requests = [];
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-probe.invalid/")) throw new Error(`unexpected network request: ${url}`);
  requests.push(typeof init?.body === "string" ? init.body : "");
  const chunk = (delta, finish) => `data: ${JSON.stringify({ id: "p", object: "chat.completion.chunk", created: 1, model: "fm-probe-model", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  return new Response(chunk({ role: "assistant", content: `reply ${requests.length}` }, null) + chunk({}, "stop") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } });
};
const log = [];
let settled = 0, probeApi;
const agentDir = process.env.PI_CODING_AGENT_DIR;
const settings = SettingsManager.create(home, agentDir);
const loader = new DefaultResourceLoader({
  cwd: home, agentDir, settingsManager: settings,
  additionalExtensionPaths: [process.env.PLUGIN],
  extensionFactories: [{ name: "fm-bas-probe", factory: (pi) => {
    probeApi = pi;
    pi.on("before_agent_start", (event) => {
      const entry = { event: "before_agent_start", messageType: event.messageType ?? "(absent)", hasPrompt: "prompt" in event,
        customType: event.message?.customType ?? null };
      log.push(entry);
      if (mode === "away" && event.message?.customType === "fm-branch-process") {
        sh("fm-afk-contract.sh", "enter", "--words", "probe: away while the processing run is starting");
        entry.awayRecordCreated = existsSync(`${home}/state/.afk-contract`);
      }
    });
    pi.on("agent_end", () => log.push({ event: "agent_end", providerCalls: requests.length }));
    pi.on("agent_settled", () => { settled += 1; });
  } }],
  noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const registry = new ModelRegistry(runtime);
await registry.refresh();
const { session } = await createAgentSession({
  cwd: home, sessionManager: SessionManager.create(home, `${home}/sessions`), settingsManager: settings, resourceLoader: loader,
  modelRuntime: runtime, model: registry.find("fm-probe", "fm-probe-model"), noTools: "builtin",
});
const extErrors = [];
session.extensionRunner.onError((e) => extErrors.push(`${e.extensionPath ?? ""} ${e.event ?? ""}: ${e.error ?? e.message ?? JSON.stringify(e)}`));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (pred, ms = 8000) => { for (let i = 0; i < ms / 50 && !pred(); i += 1) await sleep(50); return pred(); };
const out = { pi: version, mode };
let ok = false;
if (mode === "watch") {
  const arm = session.getToolDefinition("fm_watch_arm_pi");
  const armed = await arm.execute("probe-arm", {}, undefined, undefined, {});
  if (!armed.details?.ok) throw new Error(`watcher did not arm: ${JSON.stringify(armed.details)}`);
  // A custom triggerTurn run while idle: Pi 1.2 raises before_agent_start with messageType "custom" and no prompt.
  probeApi.sendMessage({ customType: "fm-probe-custom", content: "probe custom turn", display: false }, { triggerTurn: true });
  await waitFor(() => settled >= 1);
  // An idle watcher wake: the extension sends a user message; before_agent_start carries its prompt and consumes it.
  writeFileSync(process.env.FM_PROBE_WATCH_TRIGGER, "signal: probe idle wake\n");
  const confirmed = () => existsSync(process.env.FM_PROBE_WATCH_LOG) && readFileSync(process.env.FM_PROBE_WATCH_LOG, "utf8").includes("confirmed ");
  await waitFor(() => confirmed() && settled >= 2);
  out.providerCalls = requests.length;
  out.wakeDeliveredAndConfirmed = confirmed();
  out.extensionErrors = extErrors;
  ok = settled >= 2 && out.wakeDeliveredAndConfirmed && extErrors.length === 0
    // Pi 1.2 raises before_agent_start for the idle custom run (messageType "custom", no prompt);
    // Pi 1.1 raises it only for prompt runs.
    && (version.startsWith("1.1.") || log.some((e) => e.event === "before_agent_start" && e.messageType === "custom" && !e.hasPrompt))
    && log.some((e) => e.event === "before_agent_start" && e.hasPrompt);
} else {
  await session.prompt("Finish the requested work.");
  // The branch presents the unprocessed captain outcome at agent_settled as a triggerTurn custom message.
  await waitFor(() => settled >= 2, 8000);
  await sleep(300);
  const processingStarts = log.filter((e) => e.event === "before_agent_start" && e.customType === "fm-branch-process");
  out.processingRunStarted = processingStarts.length > 0;
  out.providerCalls = requests.length;
  out.processingRequestReachedModel = requests.slice(1).some((b) => b.includes(`[seq ${seq},`));
  out.outcomeStillUnprocessed = sh("fm-branch-outcome.sh", "unprocessed").includes(`"seq":${seq}`);
  out.extensionErrors = extErrors;
  if (mode === "away") {
    // Parked main: the dedicated processing turn must be aborted at the context boundary (no provider call).
    ok = out.processingRunStarted && requests.length === 1 && out.outcomeStillUnprocessed && extErrors.length === 0;
  } else {
    ok = out.processingRunStarted && requests.length >= 2 && out.processingRequestReachedModel && extErrors.length === 0;
  }
}
out.events = log;
out.result = ok ? "PASS" : "FAIL";
console.log(JSON.stringify(out, null, 1));
session.dispose();
process.exit(ok ? 0 : 1);
EOF
