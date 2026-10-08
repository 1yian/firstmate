// Drive the real optional extension through Pi CLI discovery and public SDK sessions.
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { pathToFileURL } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";
import assert from "node:assert/strict";
const root = process.env.FM_OPTCHAT_ROOT;
const scratch = process.env.FM_OPTCHAT_SCRATCH;
const publishedPackage = process.env.FM_OPTCHAT_PACKAGE;
const packageRoot = path.join(scratch, "patched-package");
const prepare = [path.join(root, ".pi/optchat/package.mjs"), "prepare", publishedPackage, packageRoot];
assert.equal(JSON.parse(execFileSync(process.execPath, prepare, { encoding: "utf8" })).reused, false);
assert.equal(JSON.parse(execFileSync(process.execPath, prepare, { encoding: "utf8" })).reused, true);
const sdkRoot = process.env.PI_PACKAGE_DIR;
const sdk = await import(pathToFileURL(path.join(sdkRoot, "dist/index.js")).href);
const ai = await import(pathToFileURL(path.join(sdkRoot, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
const { createAgentSession, ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager } = sdk;
const { createAssistantMessageEventStream, getCurrentSystemPrompt, getCurrentSystemMessage } = ai;
const deadline = setTimeout(() => { console.error("OptChat end-to-end safety deadline"); process.exit(2); }, 45000);
assert.equal(JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"))).version, "0.7.2");

function home(name, profile) {
  const real = path.join(scratch, `real-${name}`);
  const alias = path.join(scratch, `alias-${name}`);
  fs.mkdirSync(path.join(real, ".pi/extensions/lib"), { recursive: true });
  fs.symlinkSync(real, alias, "dir");
  fs.copyFileSync(path.join(root, ".pi/extensions/fm-optchat.ts"), path.join(real, ".pi/extensions/fm-optchat.ts"));
  fs.copyFileSync(path.join(root, ".pi/extensions/lib/fm-optchat-compat.ts"), path.join(real, ".pi/extensions/lib/fm-optchat-compat.ts"));
  fs.cpSync(path.join(root, ".pi/optchat"), path.join(real, ".pi/optchat"), { recursive: true });
  fs.mkdirSync(path.join(real, "config/optchat"), { recursive: true });
  fs.symlinkSync(packageRoot, path.join(real, "config/optchat/package"), "dir");
  fs.writeFileSync(path.join(real, "config/optchat.json"), JSON.stringify({ enabled: true, package: "config/optchat/package", memoryHome: "data/optchat", profile, thinking: "off" }));
  const dir = path.join(real, "data/optchat/profiles", profile);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "AGENTS.md"), "Existing Firstmate task records and current approvals remain authoritative. No alternative delegation.\n");
  fs.writeFileSync(path.join(dir, "config.json"), JSON.stringify({ memorySearch: true, compactor: { provider: "not-configured", model: "must-inherit", thinking: "off" }, subagent: { provider: "not-configured", model: "unused", thinking: "off" } }));
  execFileSync("git", ["init", "-q", dir]);
  execFileSync("git", ["-C", dir, "config", "user.name", "Memory fixture"]);
  execFileSync("git", ["-C", dir, "config", "user.email", "fixture@example.invalid"]);
  fs.writeFileSync(path.join(real, "AGENTS.md"), "FIRSTMATE_CONTEXT_TOKEN: current policy, not recalled approval.\n");
  return { real, alias, profile, dir };
}
function savedChild(owner) {
  const file = path.join(owner.dir, "runs/connected-fixture.optchat.json");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const record = { id: "connected-fixture", task: "Harmless prior connected conversation", cwd: owner.real,
    model: "fixture", thinking: "off", parentSession: "historical-fixture", started: 1,
    depth: 1, state: "running", connected: true, guidance: [],
    handoff: { reason: "owner-stopped", text: "Harmless saved child handoff. Historical evidence only." } };
  const recordBytes = `${JSON.stringify(record, null, 2)}\n`;
  fs.writeFileSync(file, recordBytes);
  const legacy = SessionManager.create(owner.real, path.dirname(file));
  legacy.appendMessage({ role: "user", content: "Harmless historical child conversation.", timestamp: 1 });
  legacy.appendMessage({ role: "assistant", content: [{ type: "text", text: "Historical fixture complete." }], api: "openai-completions", provider: "counterfactual", model: "fixture", timestamp: 2, stopReason: "stop",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
  assert(fs.existsSync(legacy.getSessionFile()));
  const pendingReports = path.join(owner.dir, "pending-reports.json");
  const reports = [{ text: "Harmless saved disconnected-child report.", count: 1 }];
  const reportBytes = `${JSON.stringify(reports, null, 2)}\n`;
  fs.writeFileSync(pendingReports, reportBytes);
  return { file, record, recordBytes, pendingReports, reports, reportBytes, legacyMetadata: path.join(path.dirname(file), `${legacy.getSessionId()}.optchat.json`) };
}
async function connection(file) {
  return new Promise(resolve => {
    const socket = net.createConnection(file);
    socket.setTimeout(2000, () => { socket.destroy(); resolve("timeout"); });
    socket.on("error", error => { socket.destroy(); resolve(error.code); });
    socket.on("connect", () => { socket.destroy(); resolve("connected"); });
  });
}
// Both published and default-enabled patched packages retain normal window/recovery behavior.
async function upstreamCounterfactual(name, sourcePackage) {
  const owner = home(name, name);
  const child = savedChild(owner);
  process.chdir(owner.alias); process.env.OPTCHAT_HOME = path.join(owner.real, "data/optchat");
  process.env.PI_CODING_AGENT_DIR = path.join(owner.real, "agent"); delete process.env.FM_TASK_ID;
  fs.writeFileSync(path.join(owner.dir, "config.json"), JSON.stringify({ compactor: { provider: "counterfactual", model: "fixture", thinking: "off" }, subagent: { provider: "counterfactual", model: "fixture", thinking: "off" } }));
  const runtime = await ModelRuntime.create({ authPath: path.join(owner.real, "auth.json"), modelsPath: null, modelsStorePath: path.join(owner.real, "models.json"), refreshOnCreate: false });
  runtime.registerProvider("counterfactual", { apiKey: "synthetic", api: "openai-completions", baseUrl: "https://invalid.local", models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 100000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }], streamSimple: model => stream(model, "Synthetic historical recovery response.", false) });
  const manager = SessionManager.create(owner.alias, path.join(owner.real, "sessions")); manager.appendCustomEntry("optchat.profile", { name });
  const settings = SettingsManager.inMemory({ compaction: { enabled: false }, cacheWarming: "off", retry: { enabled: false } });
  const loader = new DefaultResourceLoader({ cwd: owner.alias, agentDir: process.env.PI_CODING_AGENT_DIR, settingsManager: settings, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, additionalExtensionPaths: [path.join(sourcePackage, "src/index.ts")] });
  await loader.reload(); assert.deepEqual(loader.getExtensions().errors, []);
  const errors = [];
  const session = (await createAgentSession({ cwd: owner.alias, agentDir: process.env.PI_CODING_AGENT_DIR, modelRuntime: runtime, model: runtime.getModel("counterfactual", "fixture"), settingsManager: settings, sessionManager: manager, resourceLoader: loader, tools: ["zoom"] })).session;
  try {
    await session.bindExtensions({ onError: error => errors.push(error) });
    assert.equal(await connection(path.join(owner.dir, "windows.sock")), "connected");
    for (let i = 0; i < 100 && !JSON.parse(fs.readFileSync(child.file)).handoff.delivered; i++) await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(JSON.parse(fs.readFileSync(child.file)).handoff.delivered, true);
    assert(fs.existsSync(child.legacyMetadata));
    // The handoff marker precedes a separate queued-report callback; idle at
    // that instant is not evidence that startup has dispatched both inputs.
    const deliveries = () => manager.getEntries().filter(entry =>
      (entry.type === "custom_message" && entry.content === child.reports[0].text) ||
      (entry.type === "message" && entry.message.role === "user" && JSON.stringify(entry.message.content).includes(child.reports[0].text)));
    for (let i = 0; i < 150 && !deliveries().length; i++) await new Promise(resolve => setTimeout(resolve, 20));
    await session.waitForIdle();
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(deliveries().length, 1, "default-enabled source must dispatch the pending child report exactly once");
    assert(!manager.getEntries().some(entry => entry.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "error"));
    assert(loader.getExtensions().extensions.some(extension => extension.tools.has("spawn"))); assert.deepEqual(errors, []);
  } finally { await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" }); session.dispose(); }
  console.log(`PASS ${name}: connected-window listener and saved-child recovery remain enabled by default`);
}
await upstreamCounterfactual("published", publishedPackage);
await upstreamCounterfactual("patched", packageRoot);
console.log("PASS package preparation: published source preserved, pinned separate patch, idempotent destination");
const primary = home("primary", "main");
const secondmate = home("secondmate", "domain");
function stream(model, content, compression) {
  const reply = { role: "assistant", api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(),
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: compression || typeof content === "string" ? "stop" : "toolUse",
    content: typeof content === "string" ? [{ type: "text", text: content }] : content };
  const events = createAssistantMessageEventStream();
  queueMicrotask(() => { events.push({ type: "done", reason: reply.stopReason, message: reply }); events.end(); });
  return events;
}
async function drive(owner, provider) {
  process.chdir(owner.alias); process.env.FM_HOME = owner.alias; delete process.env.FM_TASK_ID;
  process.env.PI_CODING_AGENT_DIR = path.join(owner.real, "agent");
  const runtime = await ModelRuntime.create({ authPath: path.join(owner.real, "auth.json"), modelsPath: null, modelsStorePath: path.join(owner.real, "catalog.json"), refreshOnCreate: false });
  const requests = []; const errors = []; let release; let started; let hold = false;
  const child = savedChild(owner);
  runtime.registerProvider(provider, { apiKey: "synthetic", api: "openai-completions", baseUrl: "https://invalid.local", models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 100000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    streamSimple(model, context) {
      const system = getCurrentSystemPrompt(context.messages);
      if (system.startsWith("You write the memory of OptChat")) return stream(model, "work: synthetic conversation summarized.", true);
      requests.push(structuredClone(context.messages));
      assert.equal(context.messages[0].timestamp, 0, "authority trailer changed upstream system metadata");
      const declarations = getCurrentSystemMessage(context.messages)?.toolsAdded ?? [];
      assert(declarations.every(tool => typeof tool.parameters === "object"), "model-visible tool schemas were lost");
      assert(declarations.some(tool => tool.name === "zoom"), "model-visible memory tool declaration was lost");
      assert(declarations.some(tool => tool.name === "bash"), "model-visible built-in tool declaration was lost");
      const last = context.messages.at(-1);
      const text = typeof last?.content === "string" ? last.content : (last?.content || []).filter(part => part.type === "text").map(part => part.text).join("\n");
      if (hold && text.includes("STREAM_USER")) {
        const events = createAssistantMessageEventStream();
        started();
        const deferred = new Promise(resolve => { release = resolve; });
        void deferred.then(() => { hold = false; const result = stream(model, "Streaming work complete.", false); void (async () => { for await (const event of result) events.push(event); events.end(); })(); });
        return events;
      }
      if (last?.role === "user" && text.includes("RECALL_COLOR")) return stream(model, [{ type: "toolCall", id: "recall", name: "zoom", arguments: { id: 2, n: 1 } }], false);
      if (last?.role === "user" && text.includes("LONG_TOOL_OUTPUT")) return stream(model, [{ type: "toolCall", id: "long-output", name: "bash", arguments: {
        command: `${JSON.stringify(process.execPath)} -e 'process.stdout.write("HEAD_LONG_RESULT\\n"+"a".repeat(24000)+"\\nMIDDLE_REQUIRED_DECISION\\n"+"b".repeat(24000)+"\\nTAIL_LONG_RESULT\\n")'`,
      } }], false);
      if (last?.role === "user" && text.includes("RECALL_LONG_RESULT")) return stream(model, [{ type: "toolCall", id: "long-search", name: "search", arguments: { text: "Complete tool result:" } }], false);
      if (last?.role === "toolResult" && last.toolName === "search") {
        const id = Number(text.match(/\n(\d+)(?: | ·)/)?.[1]); assert(Number.isSafeInteger(id));
        return stream(model, [{ type: "toolCall", id: "long-zoom", name: "zoom", arguments: { id, n: 1 } }], false);
      }
      if (last?.role === "toolResult" && last.toolName === "zoom" && text.includes("Complete tool result:")) {
        const file = JSON.parse(text.match(/Complete tool result: ("[^"\n]+")/)?.[1]);
        return stream(model, [{ type: "toolCall", id: "long-read", name: "read", arguments: { path: file } }], false);
      }
      return stream(model, "Synthetic response.", false);
    },
  });
  const settings = SettingsManager.inMemory({ compaction: { enabled: false }, cacheWarming: "off", retry: { enabled: false } });
  let session;
  async function open(manager) {
    const loader = new DefaultResourceLoader({ cwd: owner.alias, agentDir: path.join(owner.real, "agent"), settingsManager: settings,
      noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
      agentsFilesOverride: () => ({ agentsFiles: [{ path: path.join(owner.real, "AGENTS.md"), content: "FIRSTMATE_CONTEXT_TOKEN: current policy, not recalled approval." }] }),
      additionalExtensionPaths: [path.join(owner.alias, ".pi/extensions/fm-optchat.ts")] });
    await loader.reload(); assert.deepEqual(loader.getExtensions().errors, []);
    const extension = loader.getExtensions().extensions.find(item => item.path.endsWith("fm-optchat.ts"));
    assert(!extension.tools.has("spawn")); assert(!extension.tools.has("tell"));
    assert(!extension.commands.has("complete")); assert(!extension.commands.has("tell-main"));
    session = (await createAgentSession({ cwd: owner.alias, agentDir: path.join(owner.real, "agent"), modelRuntime: runtime, model: runtime.getModel(provider, "fixture"), settingsManager: settings, resourceLoader: loader, sessionManager: manager, tools: ["zoom", "date", "search", "bash", "read"] })).session;
    await session.bindExtensions({ onError: error => errors.push(error) });
    assert(!fs.existsSync(path.join(owner.dir, "windows.sock")));
    assert.equal(await connection(path.join(owner.dir, "windows.sock")), "ENOENT");
    assert.equal(fs.readFileSync(child.file, "utf8"), child.recordBytes, "disabled recovery rewrote a child record");
    assert(!fs.existsSync(child.legacyMetadata), "disabled child recovery adopted an old child session");
    assert.equal(fs.readFileSync(child.pendingReports, "utf8"), child.reportBytes, "disabled recovery consumed/rewrote pending child reports");
  }
  async function close() { await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" }); session.dispose(); }
  async function notify(token, type = "fm-branch-process") {
    const n = requests.length;
    await session.sendCustomMessage({ customType: type, content: token, display: false }, { triggerTurn: true, deliverAs: "followUp" });
    await session.waitForIdle();
    const additions = requests.slice(n); assert.equal(additions.length, 1);
    const request = additions[0]; assert(getCurrentSystemPrompt(request).includes("FIRSTMATE_CONTEXT_TOKEN"));
    assert(getCurrentSystemPrompt(request).includes("<firstmate_memory_authority>"));
    assert.equal(request.filter(message => message.role !== "system" && JSON.stringify(message.content).includes(token)).length, 1);
    assert(JSON.stringify(request.at(-1).content).includes(token));
  }
  const manager = SessionManager.create(owner.alias, path.join(owner.real, "sessions"));
  await open(manager);
  assert.equal(requests.length, 0, "disabled child recovery made a model request");
  for (const panel of ["usage", "activity", "agents", "model"]) await session.prompt(`/optchat ${panel}`);
  assert.equal(requests.length, 0, "mixed agent-control inspector was reached");
  console.log(`PASS SDK ${owner.profile}: no connected-window socket, native connection refused, child recovery and mixed controls disabled`);
  await notify("STARTUP_ONLY_TOKEN", "firstmate-sessionstart-nudge");
  await session.prompt("The release color is amber. " + "Harmless original detail. ".repeat(35));
  await notify("IDLE_TOKEN");
  const saved = manager.getSessionFile(); await close();
  await open(SessionManager.open(saved)); await notify("RESTART_TOKEN");
  await session.prompt("RECALL_COLOR");
  assert(session.messages.some(message => message.role === "toolResult" && message.toolName === "zoom" && JSON.stringify(message.content).includes("release color is amber")));
  await session.prompt("LONG_TOOL_OUTPUT");
  const original = session.messages.find(message => message.role === "toolResult" && message.toolCallId === "long-output");
  assert(original); assert(JSON.stringify(original.content).includes("MIDDLE_REQUIRED_DECISION"));
  assert(!JSON.stringify(original.content).includes("characters omitted"));
  const nextRequest = requests.find(request => request.at(-1)?.role === "toolResult" && request.at(-1)?.toolCallId === "long-output");
  assert.deepEqual(nextRequest.at(-1), original, "current decision lost part of a large result");
  const persisted = fs.readFileSync(saved, "utf8").trim().split("\n").map(line => JSON.parse(line));
  assert.deepEqual(persisted.find(entry => entry.message?.toolCallId === "long-output").message, JSON.parse(JSON.stringify(original)));
  const memoryEntries = fs.readdirSync(path.join(owner.dir, "main")).flatMap(name => fs.readFileSync(path.join(owner.dir, "main", name), "utf8").trim().split("\n").map(line => JSON.parse(line)));
  const excerpt = memoryEntries.find(entry => entry.kind === "echo" && entry.text.startsWith("bash: Complete tool result:"));
  assert(excerpt); assert(!excerpt.text.includes("MIDDLE_REQUIRED_DECISION"));
  const fullResultFile = JSON.parse(excerpt.text.match(/Complete tool result: ("[^"\n]+")/)[1]);
  assert.deepEqual(JSON.parse(fs.readFileSync(fullResultFile, "utf8")), JSON.parse(JSON.stringify(original)));
  assert.equal(fs.statSync(fullResultFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(fullResultFile)).mode & 0o777, 0o700);
  await close(); await open(SessionManager.open(saved));
  await session.prompt("RECALL_LONG_RESULT");
  const recovered = session.messages.find(message => message.role === "toolResult" && message.toolCallId === "long-read");
  assert(recovered); assert(JSON.stringify(recovered.content).includes("MIDDLE_REQUIRED_DECISION"));
  assert(!JSON.stringify(recovered.content).includes("characters omitted"));
  console.log(`PASS SDK ${owner.profile}: full current/canonical output, private lossless archive, and search/zoom/read recovery after restart`);
  hold = true; let ready; const inFlight = new Promise(resolve => { ready = resolve; }); started = ready;
  const running = session.prompt("STREAM_USER"); await inFlight;
  const before = requests.length;
  await session.sendCustomMessage({ customType: "fm-branch-process", content: "FOLLOWUP_TOKEN", display: false }, { triggerTurn: true, deliverAs: "followUp" });
  release(); await running; await session.waitForIdle(); assert.equal(requests.length - before, 1);
  await notify("MERGE_INFORMATION_TOKEN", "fm-branch-merge");
  assert(!session.getAllTools().some(tool => ["spawn", "tell"].includes(tool.name)));
  assert(!session.extensionRunner.getRegisteredCommands().some(command => ["complete", "tell-main"].includes(command.name)));
  const canonical = session.messages.filter(message => message.role === "custom");
  assert(canonical.some(message => message.customType === "firstmate-sessionstart-nudge" && message.content === "STARTUP_ONLY_TOKEN"));
  assert(canonical.some(message => message.customType === "fm-branch-merge" && message.content === "MERGE_INFORMATION_TOKEN"));
  const receipt = JSON.parse(fs.readFileSync(path.join(owner.real, "state/optchat-activation.json")));
  assert.equal(receipt.phase, "active"); assert.equal(receipt.profile, owner.profile); assert.equal(receipt.compactor.provider, provider);
  assert.equal(receipt.sessionId, session.sessionManager.getSessionId()); assert.deepEqual(errors, []);
  await close();
  console.log(`PASS SDK ${owner.profile}: notification-first, idle, resumed, recall, streaming, policy, canonical records, provider and delegation boundaries`);
  // Exercise inability to save the original, through a real tool run, not a stub.
  const archiveDir = path.join(owner.dir, "firstmate-results");
  fs.renameSync(archiveDir, `${archiveDir}-saved`); fs.writeFileSync(archiveDir, "Fixture refuses an archive directory.\n");
  await open(SessionManager.open(saved));
  const beforeFailure = requests.length;
  await session.prompt("LONG_TOOL_OUTPUT");
  assert.equal(requests.length - beforeFailure, 1, "archiving failure allowed a follow-up model decision");
  assert(errors.some(error => JSON.stringify(error).includes("Could not preserve complete tool output")));
  assert(session.messages.some(message => message.role === "toolResult" && JSON.stringify(message.content).includes("MIDDLE_REQUIRED_DECISION")));
  await close(); fs.unlinkSync(archiveDir); fs.renameSync(`${archiveDir}-saved`, archiveDir);
  console.log(`PASS SDK ${owner.profile}: archiving failure stops the next decision and preserves canonical output`);
}
await drive(primary, "main-fixture"); await drive(secondmate, "vertex-fixture");
// Worker exclusion uses the same configured home. No profile callback or memory tools may register.
process.chdir(primary.alias); process.env.FM_HOME = primary.alias; process.env.FM_TASK_ID = "isolated-worker";
const workerLoader = new DefaultResourceLoader({ cwd: primary.alias, agentDir: path.join(primary.real, "worker-agent"), noExtensions: true, noSkills: true, noContextFiles: true,
  additionalExtensionPaths: [path.join(primary.alias, ".pi/extensions/fm-optchat.ts")] });
await workerLoader.reload(); assert.deepEqual(workerLoader.getExtensions().errors, []);
const worker = workerLoader.getExtensions().extensions.find(extension => extension.path.endsWith("fm-optchat.ts"));
assert.equal(worker.handlers.size, 0); assert.equal(worker.tools.size, 0); assert.equal(worker.commands.size, 0); assert.equal(worker.flags.size, 0);
console.log("PASS worker: configured supervisor package registers nothing");
delete process.env.FM_TASK_ID;
const project = path.join(primary.real, "project"); fs.mkdirSync(project); process.chdir(project);
const projectLoader = new DefaultResourceLoader({ cwd: project, agentDir: path.join(primary.real, "project-agent"), noExtensions: true, noSkills: true, noContextFiles: true,
  additionalExtensionPaths: [path.join(primary.alias, ".pi/extensions/fm-optchat.ts")] });
await projectLoader.reload(); assert.deepEqual(projectLoader.getExtensions().errors, []);
assert.equal(projectLoader.getExtensions().extensions[0].handlers.size, 0);
const branchResources = new DefaultResourceLoader({ cwd: primary.alias, agentDir: path.join(primary.real, "branch-agent"), noExtensions: true, noSkills: true, noContextFiles: true });
await branchResources.reload(); assert.equal(branchResources.getExtensions().extensions.length, 0);
console.log("PASS project/branch resources: home-bound guard and no-extension loader register no memory");
// Refuse changed dependency sources before executing the configured extension.
const changed = path.join(scratch, "changed-package"); fs.cpSync(packageRoot, changed, { recursive: true });
fs.appendFileSync(path.join(changed, "src/index.ts"), "\n// Unexpected dependency change.\n");
const refused = spawnSync(process.execPath, [path.join(root, ".pi/optchat/package.mjs"), "prepare", publishedPackage, changed], { encoding: "utf8" });
assert.equal(refused.status, 1); assert(refused.stderr.includes("fingerprint differs"));
const wrongVersion = path.join(scratch, "wrong-version"); fs.cpSync(publishedPackage, wrongVersion, { recursive: true });
const versionInfo = JSON.parse(fs.readFileSync(path.join(wrongVersion, "package.json"))); versionInfo.version = "999.0.0";
fs.writeFileSync(path.join(wrongVersion, "package.json"), JSON.stringify(versionInfo));
const versionRefusal = spawnSync(process.execPath, [path.join(root, ".pi/optchat/package.mjs"), "prepare", wrongVersion, path.join(scratch, "must-not-exist")], { encoding: "utf8" });
assert.equal(versionRefusal.status, 1); assert(versionRefusal.stderr.includes("Expected pi-optchat@0.7.2"));
assert(!fs.existsSync(path.join(scratch, "must-not-exist")));
const bad = home("bad", "bad"); fs.unlinkSync(path.join(bad.real, "config/optchat/package")); fs.symlinkSync(changed, path.join(bad.real, "config/optchat/package"));
process.chdir(bad.alias); process.env.FM_HOME = bad.alias; process.env.PI_CODING_AGENT_DIR = path.join(bad.real, "agent");
const badLoader = new DefaultResourceLoader({ cwd: bad.alias, agentDir: process.env.PI_CODING_AGENT_DIR, noExtensions: true, noSkills: true, noContextFiles: true, additionalExtensionPaths: [path.join(bad.alias, ".pi/extensions/fm-optchat.ts")] });
await badLoader.reload(); assert(badLoader.getExtensions().errors.some(error => JSON.stringify(error).includes("fingerprint differs")));
assert(!fs.existsSync(path.join(bad.real, "state/optchat-activation.json")));
console.log("PASS dependency guard: unexpected source changes refuse preparation and runtime activation, without repair");
// CLI auto-discovery has no OptChat flag or transient OPTCHAT_HOME export; the home config owns both.
const cli = home("cli", "cli");
const providerFile = path.join(cli.real, "provider.ts");
fs.writeFileSync(providerFile, `import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
export default function(pi){pi.registerProvider('cli-fixture',{api:'openai-completions',apiKey:'synthetic',baseUrl:'https://invalid.local',models:[{id:'fixture',name:'Fixture',reasoning:false,input:['text'],contextWindow:100000,maxTokens:1000,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}],streamSimple(model){const stream=createAssistantMessageEventStream();const message={role:'assistant',api:model.api,provider:model.provider,model:model.id,timestamp:Date.now(),usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',content:[{type:'text',text:'Synthetic CLI response.'}]};queueMicrotask(()=>{stream.push({type:'done',reason:'stop',message});stream.end();});return stream;}});}
`);
const env = { ...process.env, FM_HOME: cli.alias, PI_CODING_AGENT_DIR: path.join(cli.real, "agent"), PI_TELEMETRY: "0" };
delete env.FM_TASK_ID; delete env.OPTCHAT_HOME;
const args = [path.join(sdkRoot, "dist/cli.js"), "--offline", "--approve", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-builtin-tools", "--thinking", "off", "--model", "cli-fixture/fixture", "--session-dir", path.join(cli.real, "sessions"), "-e", providerFile, "--print"];
let saved;
for (const phase of ["launch", "exact-session restart", "recovery"] ) {
  const result = spawnSync(process.execPath, [...args, ...(saved ? ["--session", saved] : []), "Harmless synthetic CLI input."], { cwd: cli.alias, env, encoding: "utf8", timeout: 12000, maxBuffer: 1024 * 1024 });
  assert.equal(result.status, 0, `${phase}: ${result.stderr}`);
  const receipt = JSON.parse(fs.readFileSync(path.join(cli.real, "state/optchat-activation.json")));
  assert.equal(receipt.phase, "active"); assert.equal(receipt.profile, "cli"); assert.equal(receipt.compactor.provider, "cli-fixture");
  if (saved) assert.equal(receipt.sessionFile, saved); else saved = receipt.sessionFile;
  console.log(`PASS CLI ${phase}: automatic discovery and persistent profile, no OptChat exports/flags`);
}
clearTimeout(deadline);
console.log("PASS all real Pi optional-memory scenarios (local scripted providers only)");
