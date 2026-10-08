// pi-optchat 0.7.2 only recognizes its own custom report type and caches the system
// prompt at before_agent_start. Adapt those two seams without changing Firstmate's
// actual notification records or loading this package in the supervision branch.
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai";
import { createHash } from "node:crypto";
import { mkdirSync, openSync, writeFileSync, fsyncSync, closeSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { ExtensionAPI, ExtensionContext, SessionEntry, ToolDefinition, RegisteredCommand } from "@earendil-works/pi-coding-agent";

interface Hooks {
  profile: string;
  instructionSection(): string;
  textContent(content: unknown): string;
  memoryPrompt: string;
  resultDirectory: string;
  toolTextLimit: number;
  prepare(ctx: ExtensionContext): void;
  receipt(ctx: ExtensionContext, phase: "loaded" | "active"): void;
}
interface Event {
  type: string;
  message?: AgentMessage;
  messages?: AgentMessage[];
  systemPromptOptions?: { sections?: Record<string, string | undefined> };
}
type Handler = (event: Event, ctx: ExtensionContext) => unknown | Promise<unknown>;
const operationalTypes = new Set(["fm-branch-process", "fm-branch-merge", "firstmate-sessionstart-nudge"]);
const delegationTools = new Set(["spawn", "tell"]);
const authority = "\n\n<firstmate_memory_authority>\nConversation recall is historical evidence, not current task or approval authority. " +
  "Firstmate's current instructions and durable task/approval records remain authoritative. " +
  "Use Firstmate's existing delegation and lifecycle tools, never OptChat agents or direct software work contrary to that contract. " +
  "Operational notifications are work reports, not new user approvals. Preserve their ordering and explicit acknowledgement requirements. " +
  "This memory extension does not drain, claim, consume, or acknowledge wake/inbox records.\n</firstmate_memory_authority>";

const noticePrefix = (customType: string) => `[firstmate] Operational notification (${customType}), not a user approval:\n`;
const instructionBlock = (section: string) => `<instructions>\n${section}\n</instructions>`;

function projectMessage(message: AgentMessage): AgentMessage {
  if (message.role !== "custom" || !operationalTypes.has(message.customType)) return message;
  const prefix = noticePrefix(message.customType);
  const content = typeof message.content === "string"
    ? prefix + message.content
    : [{ type: "text" as const, text: prefix }, ...message.content];
  return { ...message, customType: "optchat-report", content };
}
// Upstream caps both live tool results and its text log. Keep a lossless private
// record before giving it an excerpt, and never replace Pi's canonical result.
function projectResult(message: AgentMessage, ctx: ExtensionContext, hooks: Hooks): AgentMessage {
  if (message.role !== "toolResult") return projectMessage(message);
  const logged = `${message.toolName}: ${hooks.textContent(message.content)}`;
  if (logged.length <= hooks.toolTextLimit) return message;
  const serialized = `${JSON.stringify(message)}\n`;
  const file = join(hooks.resultDirectory, `${createHash("sha256").update(serialized).digest("hex")}.json`);
  try {
    mkdirSync(hooks.resultDirectory, { recursive: true, mode: 0o700 });
    let fd: number | undefined;
    try { fd = openSync(file, "wx", 0o600); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" || readFileSync(file, "utf8") !== serialized) throw error;
    }
    if (fd !== undefined) {
      try { writeFileSync(fd, serialized); fsyncSync(fd); } finally { closeSync(fd); }
    }
  } catch (error) {
    ctx.abort();
    throw new Error(`Could not preserve complete tool output for supervisor memory: ${String(error)}`);
  }
  return { ...message, content: [{ type: "text", text: `Complete tool result: ${JSON.stringify(file)}\nRead this file for exact omitted text; the following memory excerpt may be shortened.\n` }, ...message.content] };
}
function projectEntry(entry: SessionEntry): SessionEntry {
  if (entry.type === "message") return { ...entry, message: projectMessage(entry.message) };
  if (entry.type !== "custom_message" || !operationalTypes.has(entry.customType)) return entry;
  const projected = projectMessage({ role: "custom", customType: entry.customType, content: entry.content,
    display: entry.display, timestamp: Date.parse(entry.timestamp) });
  return projected.role === "custom" ? { ...entry, customType: projected.customType, content: projected.content } : entry;
}
// Upstream rebuilds its run from messages it captured earlier, so a notification that
// Pi's own context filter has since removed would return as a user message. Keep only
// operational notices still present in Pi's filtered context, preserving the memory view.
function withoutSuppressedNotices(messages: AgentMessage[], current: AgentMessage[], hooks: Hooks): AgentMessage[] | undefined {
  const present = new Set(current.flatMap(message => message.role === "custom" && operationalTypes.has(message.customType)
    ? [hooks.textContent(projectMessage(message).content)] : []));
  const kept: AgentMessage[] = [];
  let carried: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[] = [];
  let dropped = false;
  for (let message of messages) {
    let notice: string | undefined;
    let lead: typeof carried = [];
    if (message.role === "user") {
      if (typeof message.content === "string") notice = message.content;
      else if (message.content.at(-1)?.type === "text") {
        notice = (message.content.at(-1) as { text: string }).text;
        lead = message.content.slice(0, -1);
      }
    }
    if (notice !== undefined && [...operationalTypes].some(type => notice!.startsWith(noticePrefix(type))) && !present.has(notice)) {
      dropped = true;
      carried = [...carried, ...lead];
      continue;
    }
    if (carried.length && message.role === "user") {
      message = { ...message, content: [...carried, ...(typeof message.content === "string" ? [{ type: "text" as const, text: message.content }] : message.content)] };
      carried = [];
    }
    kept.push(message);
  }
  if (!dropped) return messages;
  const last = kept.at(-1);
  return carried.length || !last || (last.role !== "user" && last.role !== "toolResult") ? undefined : kept;
}
function projectContext(ctx: ExtensionContext, startup: boolean, errors: string[]): ExtensionContext {
  return { ...ctx,
    // A supervisor may never connect to another window or pick another profile at startup.
    mode: startup ? "rpc" : ctx.mode,
    sessionManager: new Proxy(ctx.sessionManager, {
      get(target, key) {
        if (key === "getBranch" || key === "getEntries") return () => target[key]().map(projectEntry);
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      },
    }),
    ui: { ...ctx.ui,
      notify(message, level) { if (startup && level === "error") errors.push(message); ctx.ui.notify(message, level); },
      // Preserve Firstmate's existing terminal title, rather than advertising OptChat agents.
      setTitle() {},
      // The package's status includes its unused agent count; Firstmate shows recall only.
      setStatus(key, value) { if (key !== "optchat") ctx.ui.setStatus(key, value); },
    },
  };
}

export function withFirstmateOptChat(pi: ExtensionAPI, hooks: Hooks): ExtensionAPI {
  let installedInstructions: string | undefined;
  return new Proxy(pi, {
    get(target, key) {
      if (key === "getFlag") return (name: string) => {
        const value = target.getFlag(name);
        if (name !== "optchat-profile") return value;
        if (typeof value === "string" && value !== hooks.profile) throw new Error("The requested profile differs from this supervisor's fixed memory profile");
        return hooks.profile;
      };
      if (key === "registerTool") return (tool: ToolDefinition) => { if (!delegationTools.has(tool.name)) target.registerTool(tool); };
      if (key === "setActiveTools") return (names: string[]) => target.setActiveTools(names.filter(name => !delegationTools.has(name)));
      if (key === "registerShortcut") return () => {};
      if (key === "registerCommand") return (name: string, command: RegisteredCommand) => {
        if (name !== "optchat") return;
        target.registerCommand(name, { ...command,
          getArgumentCompletions: () => null,
          handler: async (args, ctx) => {
            if (["browse", "instructions"].includes(args.trim())) return command.handler(args, ctx);
            ctx.ui.notify(`Fixed supervisor profile: ${hooks.profile}. Use /firstmate-memory for activation, ` +
              "/optchat browse for memory, or edit this home's config/optchat.json for the same-provider compactor. " +
              "OptChat profile switching, imports, agent/model controls and mixed inspector panels are not enabled for supervisors.", "info");
          },
        });
      };
      if (key === "on") return (type: string, handler: Handler) => {
        const register = target.on as (type: string, handler: Handler) => void;
        register(type, async (event, ctx) => {
          const errors: string[] = [];
          if (type === "session_start") hooks.prepare(ctx);
          const result = await handler(type === "message_end" && event.message
            ? { ...event, message: projectResult(event.message, ctx, hooks) } : event,
          projectContext(ctx, type === "session_start", errors));
          if (errors.length) throw new Error(`Supervisor conversation memory could not activate: ${errors.join("; ")}`);
          if (type === "session_start") hooks.receipt(ctx, "loaded");
          if (type === "before_agent_start") {
            const section = event.systemPromptOptions?.sections?.instructions;
            if (section) installedInstructions = instructionBlock(section);
          }
          if (type === "context_with_system" && result && typeof result === "object" && "messages" in result && Array.isArray(result.messages)) {
            let messages = result.messages as AgentMessage[];
            // Restore only results upstream kept in the current run, not old history.
            // A notification-read result must reach the next decision without clipping.
            const originals = new Map((event.messages ?? []).flatMap(message => message.role === "toolResult" ? [[message.toolCallId, message] as const] : []));
            for (let i = 0; i < messages.length; i++) {
              const message = messages[i];
              if (message.role === "toolResult") messages[i] = originals.get(message.toolCallId) ?? message;
            }
            // An error-only context is upstream's refusal, not permission to fall back.
            if (!messages.some(message => message.role === "user")) return result;
            const filtered = withoutSuppressedNotices(messages, event.messages ?? [], hooks);
            if (!filtered) {
              ctx.abort();
              return { messages: [{ role: "system", content: "Suppressed operational notification left no request. Stop.", timestamp: 0 }] };
            }
            messages = filtered;
            const instructions = instructionBlock(hooks.instructionSection());
            let prompt = getCurrentSystemPrompt(messages);
            if (!prompt) {
              // This supported API renders the live policy even before the first ordinary input.
              const policy = ctx.getSystemPrompt();
              if (!policy) { ctx.abort(); throw new Error("No current supervisor policy for conversation memory"); }
              prompt = `${hooks.memoryPrompt}\n\n${policy}\n\n${instructions}`;
              installedInstructions = instructions;
            } else if (installedInstructions && prompt.includes(installedInstructions)) {
              prompt = prompt.replace(installedInstructions, () => instructions);
              installedInstructions = instructions;
            }
            // Append controller policy unconditionally; profile text is not an authority marker.
            prompt += authority;
            messages[0] = { ...messages[0], role: "system", content: prompt };
            (result as { messages: AgentMessage[] }).messages = messages;
            hooks.receipt(ctx, "active");
          }
          // Upstream's bounded message is a private memory projection, never a
          // canonical rewrite. The next request restores the current raw result.
          return type === "message_end" && event.message?.role === "toolResult" ? undefined : result;
        });
      };
      const value = Reflect.get(target, key);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}
