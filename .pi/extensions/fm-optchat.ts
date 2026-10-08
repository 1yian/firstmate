// Optional supervisor-only conversation recall. Configured once in FM_HOME/config/optchat.json;
// Pi project discovery re-loads this extension on normal launch, restart and recovery.
// Configuration schema and setup: docs/configuration.md, Optional Pi supervisor memory.
// Prepare the pinned pi-optchat@0.7.2 dependency patch and profile locally before enabling.
// No package download, account change, alternative delegation, or history import happens here.
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync, realpathSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { withFirstmateOptChat } from "./lib/fm-optchat-compat.ts";

interface Config {
  enabled: true;
  package: string;
  memoryHome: string;
  profile: string;
  compactorModel?: string;
  thinking?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
}
interface ProfileSettings {
  compactor: { provider: string; model: string; thinking: string };
  subagent: { provider: string; model: string; thinking: string };
  [key: string]: unknown;
}
interface Profiles {
  loadConfig(directory: string): ProfileSettings;
  saveConfig(directory: string, settings: ProfileSettings): void;
  instructions(directory: string): string;
}
const codeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const home = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || codeRoot);
const receiptPath = resolve(home, "state/optchat-activation.json");

function readConfig(): Config | undefined {
  const file = resolve(home, "config/optchat.json");
  if (!existsSync(file)) return;
  const value = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  if (value.enabled === false || value.enabled === undefined) return;
  if (value.enabled !== true || typeof value.package !== "string" || !value.package ||
      typeof value.memoryHome !== "string" || !value.memoryHome ||
      typeof value.profile !== "string" || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(value.profile) ||
      (value.compactorModel !== undefined && (typeof value.compactorModel !== "string" || !value.compactorModel)) ||
      (value.thinking !== undefined && (typeof value.thinking !== "string" || !["off", "minimal", "low", "medium", "high", "xhigh"].includes(value.thinking)))) {
    throw new Error("Invalid supervisor conversation-memory configuration in config/optchat.json");
  }
  return { enabled: true, package: value.package, memoryHome: value.memoryHome, profile: value.profile,
    compactorModel: value.compactorModel as string | undefined, thinking: value.thinking as Config["thinking"] };
}

export default async function firstmateOptChat(pi: ExtensionAPI): Promise<void> {
  // Ship/scout launches have this marker. Secondmates deliberately do not.
  // The cwd check also excludes project workers and a supervision resource loader elsewhere.
  if (process.env.FM_TASK_ID || realpathSync(process.cwd()) !== realpathSync(home)) return;
  const config = readConfig();
  if (!config) return;
  const packageRoot = resolve(home, config.package);
  const packageGuard = await import(pathToFileURL(resolve(codeRoot, ".pi/optchat/package.mjs")).href) as {
    verifyPackage(directory: string): { version: string; patchSha256: string };
  };
  const { version, patchSha256 } = packageGuard.verifyPackage(packageRoot);
  const memoryHome = resolve(home, config.memoryHome);
  const profileDir = resolve(memoryHome, "profiles", config.profile);
  if (!existsSync(resolve(profileDir, "AGENTS.md"))) throw new Error(`Install the ${config.profile} conversation-memory profile before activation`);
  process.env.OPTCHAT_HOME = memoryHome;
  const optchat = (await import(pathToFileURL(resolve(packageRoot, "src/index.ts")).href)).default;
  const profiles = await import(pathToFileURL(resolve(packageRoot, "src/profiles.ts")).href) as Profiles;
  const prompts = await import(pathToFileURL(resolve(packageRoot, "src/prompts.ts")).href) as { MASTER: string; VIEW_DOC: string };
  const memory = await import(pathToFileURL(resolve(packageRoot, "src/memory.ts")).href) as { CAP: number };
  const transcript = await import(pathToFileURL(resolve(packageRoot, "src/transcript.ts")).href) as { textContent(content: unknown): string };
  const guidance = await import(pathToFileURL(resolve(packageRoot, "src/import/guidance.ts")).href) as { IMPORT_GUIDANCE: string };
  if (typeof optchat !== "function" || typeof profiles.loadConfig !== "function" || typeof prompts.VIEW_DOC !== "string" ||
      !Number.isSafeInteger(memory.CAP) || memory.CAP < 1024 || typeof transcript.textContent !== "function" ||
      typeof guidance.IMPORT_GUIDANCE !== "string") {
    throw new Error("The installed conversation-memory package does not expose the supported interface");
  }
  let compactor: ProfileSettings["compactor"] | undefined;
  let activatedAt: string | undefined;
  const receipt = (ctx: ExtensionContext, phase: "loaded" | "active") => {
    ctx.ui.setStatus("firstmate-memory", `${phase === "active" ? "Recall" : "Memory profile"}: ${config.profile}`);
    if (phase === "active" && activatedAt) return;
    if (phase === "active") activatedAt = new Date().toISOString();
    mkdirSync(dirname(receiptPath), { recursive: true });
    const temporary = `${receiptPath}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify({
      phase, profile: config.profile, memoryHome, packageVersion: version, packagePatchSha256: patchSha256,
      sessionId: ctx.sessionManager.getSessionId(), sessionFile: ctx.sessionManager.getSessionFile(),
      pid: process.pid, recordedAt: new Date().toISOString(), activatedAt, compactor,
    }, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, receiptPath);
  };
  const prepare = (ctx: ExtensionContext) => {
    const binding = ctx.sessionManager.getEntries().slice().reverse().find(entry => entry.type === "custom" && entry.customType === "optchat.profile");
    if (binding?.type === "custom") {
      const data = binding.data as { name?: unknown };
      if (data?.name !== config.profile) throw new Error("This session belongs to another memory profile; preserve it and select the intended supervisor session");
    } else pi.appendEntry("optchat.profile", { name: config.profile });
    if (!ctx.model) throw new Error("Select the supervisor model before initializing conversation memory");
    if (ctx.model.provider === "codex-native") throw new Error("Native Codex thread reuse is not supported for conversation compression; use an ordinary Pi provider before enabling memory");
    compactor = { provider: ctx.model.provider, model: config.compactorModel || ctx.model.id, thinking: config.thinking || "low" };
    if (!ctx.modelRegistry.find(compactor.provider, compactor.model)) throw new Error(`Conversation-memory model ${compactor.provider}/${compactor.model} is not supported by this supervisor`);
    const previous = profiles.loadConfig(profileDir);
    // Resolve against this supervisor's own registry/account, never OptChat's first-party defaults.
    profiles.saveConfig(profileDir, { ...previous, compactor,
      subagent: { provider: ctx.model.provider, model: ctx.model.id, thinking: "off" } });
    activatedAt = undefined;
  };
  await optchat(withFirstmateOptChat(pi, {
    profile: config.profile,
    instructionSection: () => `${profiles.instructions(profileDir)}\n\n${guidance.IMPORT_GUIDANCE}`,
    textContent: transcript.textContent,
    memoryPrompt: `${prompts.MASTER}\n\n${prompts.VIEW_DOC}`,
    resultDirectory: resolve(profileDir, "firstmate-results"),
    toolTextLimit: memory.CAP,
    prepare,
    receipt,
  }), { connectedWindows: false });
  pi.registerCommand("firstmate-memory", {
    description: "Show this supervisor's conversation-memory profile and activation receipt",
    handler: async (_args, ctx) => {
      if (!existsSync(receiptPath)) { ctx.ui.notify("No conversation-memory activation receipt yet.", "info"); return; }
      const saved = JSON.parse(readFileSync(receiptPath, "utf8")) as { pid: number; sessionId: string };
      const current = saved.pid === process.pid && saved.sessionId === ctx.sessionManager.getSessionId();
      ctx.ui.notify(current ? JSON.stringify(saved, null, 2) : "The receipt belongs to an earlier process/session, not this supervisor.", "info");
    },
  });
}
