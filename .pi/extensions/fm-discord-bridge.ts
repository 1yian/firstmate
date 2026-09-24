// fm-discord-bridge.ts - bridge the firstmate Pi primary session to one Discord channel.
//
// Pi port of .omp/extensions/fm-discord-bridge.ts, with the same behavior:
//
// Inbound:  messages in BRIDGE_CHANNEL_ID are injected into this session as a
//           user turn (pi.sendUserMessage, queued as a followUp while busy).
// Outbound: assistant TEXT blocks are posted back to the channel. Tool calls,
//           tool results, thinking, and user echoes are never posted.
// Typing:   Discord "typing..." is shown while the agent is working.
//
// Own bot token: BRIDGE_BOT_TOKEN. Nothing is shared with the mini yian / relay path.
// Pi auto-discovers this file from the project's .pi/extensions/, which also
// happens in every crewmate worktree and secondmate home of this repo, so the
// gate below keeps it a silent no-op everywhere except the one primary home.
//
// Env (process env first, then the firstmate home's .env):
//   BRIDGE_BOT_TOKEN     required - the firstmate-bridge Discord bot token
//   BRIDGE_CHANNEL_ID    required - the one channel to bridge
//   BRIDGE_GUILD_ID      optional - sanity only
//   BRIDGE_GROQ_API_KEY  optional - Groq Whisper transcription of voice messages
//   BRIDGE_GROQ_MODEL    optional - Groq transcription model
//
// Design notes:
//  - Outbound reads Pi's structured message_end events, never the TUI.
//    Assistant text is role=assistant with a content block type=text; toolCall
//    and thinking blocks are skipped, so a mixed [text,toolCall] message posts
//    only its text. Tool results (role=toolResult), user turns, and custom
//    messages are never posted. message_end fires only for live messages, so a
//    resumed session's history is never replayed.
//  - Inbound polls the Discord REST API every 2s for new messages not authored
//    by this bot in the channel, then injects them via pi.sendUserMessage.
//  - No gateway websocket: REST polling keeps the extension dependency-free.
//  - Pi tears down and recreates the extension runtime on reload and on every
//    session replacement (/new, /resume, /fork), so timers are runtime-scoped
//    and cleared on session_shutdown, while the one-time "online" announcement,
//    the bot identity, and the inbound cursor are process-scoped on globalThis.

import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// The one primary firstmate home this bridge may run in.
const PRIMARY_HOME = "/Users/yian/Projects/firstmate";

const API = "https://discord.com/api/v10";
const REPLY_MAX = 1900;
const INBOUND_POLL_MS = 2000;
const TYPING_REFRESH_MS = 8000; // Discord typing lasts ~10s
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp)$/i;
const VIDEO_EXT = /\.(mp4|mov|webm|mkv|avi|m4v)$/i;
const AUDIO_EXT = /\.(ogg|oga|mp3|m4a|wav|flac|opus|webm)$/i;
const UPLOADABLE =
  /\.(png|jpe?g|gif|webp|bmp|svg|mp4|mov|webm|mkv|avi|m4v|ogg|oga|mp3|m4a|wav|flac|opus|pdf|txt|csv|json|md|zip)$/i;
const MEDIA_DIR = join(tmpdir(), "fm-discord-bridge");

interface DiscordAttachment {
  url?: string;
  filename?: string;
  waveform?: unknown;
}

interface DiscordMessage {
  id: string;
  content?: string;
  flags?: number;
  author?: { id?: string };
  attachments?: DiscordAttachment[];
  message_snapshots?: Array<{ message?: { content?: string; attachments?: DiscordAttachment[] } }>;
}

interface PendingOutbound {
  clean: string;
  paths: string[];
  uploadsDone: boolean;
  noteDelivered: boolean;
  sentParts: number;
}

interface ProcessBridgeState {
  announcedOnline: boolean;
  botUserId: string | null;
  lastMessageId: string | null;
  outbound: PendingOutbound[];
  draining: boolean;
  lastDrainOk: number;
}

// Process-scoped state survives Pi's runtime replacement on /new, /resume, /fork, and reload.
function processState(): ProcessBridgeState {
  const key = Symbol.for("firstmate.fm-discord-bridge.state");
  // SAFETY: the key is a registry symbol only this extension writes, always holding a ProcessBridgeState.
  const holder = globalThis as unknown as Record<symbol, ProcessBridgeState | undefined>;
  let state = holder[key];
  if (!state) {
    state = {
      announcedOnline: false,
      botUserId: null,
      lastMessageId: null,
      outbound: [],
      draining: false,
      lastDrainOk: Date.now(),
    };
    holder[key] = state;
  }
  return state;
}

// Lightweight always-on diagnostics: append one line to a fixed file so an
// outbound wedge is inspectable without attaching to the live Pi process.
// Best-effort; never throws.
function dbg(msg: string): void {
  try {
    appendFileSync("/tmp/fm-bridge-debug.log", `${new Date().toISOString()} ${msg}\n`);
  } catch {
    return;
  }
}

// Read config from process.env first, then fall back to the firstmate home's
// .env file. firstmate does not source .env into the harness process (it reads
// keys on demand via fm-env-lib.sh), so process.env.BRIDGE_* is normally empty
// and the .env file is parsed here, matching fm-env-lib's one-key rule.
function readDotenvValue(key: string): string | undefined {
  try {
    const home = process.env.FM_HOME || process.cwd();
    for (const file of [join(home, ".env"), join(process.cwd(), ".env")]) {
      if (!existsSync(file)) continue;
      for (const raw of readFileSync(file, "utf8").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const match = line.match(new RegExp(`^(?:export\\s+)?${key}=(.*)$`));
        if (match) return match[1].trim().replace(/^['"]|['"]$/g, "");
      }
    }
  } catch {
    // An unreadable .env means the key is unset; the bridge then stays off.
    return undefined;
  }
  return undefined;
}

function env(key: string): string | undefined {
  const value = process.env[key];
  if (value && value.trim()) return value.trim();
  return readDotenvValue(key);
}

// Gate: this bridge runs ONLY in the primary firstmate home, nowhere else.
// Not on crewmate workers, not on secondmate homes (worktrees of this repo),
// not on any other firstmate directory. Exact realpath match against the one primary.
function isPrimaryHomeSession(): boolean {
  if (env("FM_TASK_ID")) return false;
  const cwd = process.cwd();
  let cwdReal = cwd;
  try {
    cwdReal = realpathSync(cwd);
  } catch {
    // Unresolvable cwd: compare the raw path, which can only match the primary if it is the primary.
    cwdReal = cwd;
  }
  return cwdReal === PRIMARY_HOME || cwdReal.toLowerCase() === PRIMARY_HOME.toLowerCase(); // case-insensitive FS
}

// Split long text at line boundaries under Discord's limit.
function chunk(text: string, max = REPLY_MAX): string[] {
  const out: string[] = [];
  let cur = "";
  for (const line of text.split("\n")) {
    if ((cur + "\n" + line).length > max) {
      if (cur) out.push(cur);
      if (line.length > max) {
        for (let i = 0; i < line.length; i += max) out.push(line.slice(i, i + max));
        cur = "";
      } else cur = line;
    } else cur = cur ? cur + "\n" + line : line;
  }
  if (cur) out.push(cur);
  return out;
}

// Pull uploadable local file paths out of assistant text; return {clean, paths}.
// Recognizes, in order: an explicit `MEDIA:/abs/path` line; a markdown image
// `![alt](/abs/path)`; and a backtick-wrapped `/abs/path`. Only paths that exist
// on disk AND look like image/video/audio/doc get uploaded; everything else stays
// as text. The matched tokens are stripped from the outgoing message.
function extractMedia(text: string): { clean: string; paths: string[] } {
  const paths: string[] = [];
  const seen = new Set<string>();

  const consider = (p: string | undefined): "new" | "dup" | false => {
    if (!p) return false;
    const candidate = p.trim();
    if (!candidate.startsWith("/")) return false;
    if (!UPLOADABLE.test(candidate)) return false;
    if (seen.has(candidate)) return "dup"; // already collected: still strip its token from text
    try {
      if (!existsSync(candidate) || !statSync(candidate).isFile()) return false;
    } catch {
      return false;
    }
    seen.add(candidate);
    paths.push(candidate);
    return "new";
  };

  const lines = text.split("\n").map((line) => {
    // 1) explicit MEDIA: line -> drop the whole line
    const media = line.match(/^\s*MEDIA:\s*(\/\S+)\s*$/);
    if (media && consider(media[1])) return null;
    // 2) markdown image ![alt](/abs/path) -> strip the token (whether new or dup)
    let out = line.replace(/!\[[^\]]*\]\((\/[^)\s]+)\)/g, (whole, p: string) => (consider(p) ? "" : whole));
    // 3) backtick-wrapped absolute path `/abs/path` -> strip the token
    out = out.replace(/`(\/[^`\s]+)`/g, (whole, p: string) => (consider(p) ? "" : whole));
    return out;
  });

  const clean = lines
    .filter((line): line is string => line !== null)
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return { clean, paths };
}

// Only assistant text blocks; never thinking, tool calls, tool results, user, or custom messages.
function assistantText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const { role, content } = message as { role?: unknown; content?: unknown };
  if (role !== "assistant" || !Array.isArray(content)) return "";
  return content
    .filter((block): block is { type: "text"; text: string } =>
      typeof block === "object" && block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();
}

export default function (pi: ExtensionAPI) {
  if (!isPrimaryHomeSession()) return; // silent no-op anywhere but the primary home

  const TOKEN = env("BRIDGE_BOT_TOKEN");
  const CHANNEL = env("BRIDGE_CHANNEL_ID");
  if (!TOKEN || !CHANNEL) {
    // Bridge disabled: no token/channel. Never throw - must not break the session.
    pi.on("session_start", (_event, ctx) => {
      if (ctx.hasUI) ctx.ui.notify("fm-discord-bridge: BRIDGE_BOT_TOKEN/CHANNEL not set, bridge off", "info");
    });
    return;
  }
  const GROQ_KEY = env("BRIDGE_GROQ_API_KEY");
  const GROQ_MODEL = env("BRIDGE_GROQ_MODEL") || "whisper-large-v3-turbo";

  const shared = processState();
  let runtimeCtx: ExtensionContext | null = null;
  let inboundTimer: ReturnType<typeof setInterval> | null = null;
  let typingTimer: ReturnType<typeof setInterval> | null = null;
  let outboundTimer: ReturnType<typeof setTimeout> | null = null;
  let watchdogTimer: ReturnType<typeof setInterval> | null = null;
  let polling = false;
  let working = false;

  async function dGET(path: string): Promise<unknown> {
    try {
      const r = await fetch(`${API}${path}`, { headers: { Authorization: `Bot ${TOKEN}` } });
      if (!r.ok) return null;
      return await r.json();
    } catch {
      return null;
    }
  }

  async function dPOST(path: string, body: unknown, attempt = 0): Promise<unknown> {
    const r = await fetch(`${API}${path}`, {
      method: "POST",
      headers: { Authorization: `Bot ${TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    // Rate limited: honor retry_after and retry a few times before giving up.
    if (r.status === 429) {
      let waitMs = 1000;
      try {
        const j = JSON.parse(await r.text()) as { retry_after?: unknown } | null;
        if (typeof j?.retry_after === "number") waitMs = Math.ceil(j.retry_after * 1000) + 250;
      } catch {
        waitMs = 1000;
      }
      if (attempt < 5) {
        await new Promise((res) => setTimeout(res, waitMs));
        return dPOST(path, body, attempt + 1);
      }
      throw new Error(`dPOST ${path} rate-limited, gave up after ${attempt} retries`);
    }
    // Hard failure: throw so the outbound drain does NOT advance past this message.
    if (!r.ok) throw new Error(`dPOST ${path} failed HTTP ${r.status}`);
    // Some endpoints (e.g. POST /typing) return 204 No Content; parsing would throw.
    const text = await r.text();
    if (!text) return null;
    try {
      return JSON.parse(text);
    } catch {
      return null;
    }
  }

  async function postToDiscord(text: string): Promise<void> {
    const t = text.trim();
    if (!t) return;
    for (const part of chunk(t)) await dPOST(`/channels/${CHANNEL}/messages`, { content: part });
  }

  async function showTyping(): Promise<void> {
    try {
      await dPOST(`/channels/${CHANNEL}/typing`, {});
    } catch {
      return;
    }
  }

  // Download a Discord attachment URL to a local file, return its path.
  async function downloadAttachment(url: string, filename: string): Promise<string | null> {
    try {
      const r = await fetch(url);
      if (!r.ok) return null;
      const buf = Buffer.from(await r.arrayBuffer());
      mkdirSync(MEDIA_DIR, { recursive: true });
      const safe = filename.replace(/[^\w.-]/g, "_");
      const dest = join(MEDIA_DIR, `${Date.now()}_${safe}`);
      writeFileSync(dest, buf);
      return dest;
    } catch {
      return null;
    }
  }

  // Transcribe an audio file via Groq Whisper.
  async function transcribeGroq(filePath: string): Promise<string | null> {
    if (!GROQ_KEY) return null;
    try {
      const form = new FormData();
      form.append("file", new Blob([readFileSync(filePath)]), basename(filePath));
      form.append("model", GROQ_MODEL);
      form.append("response_format", "text");
      const r = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
        method: "POST",
        headers: { Authorization: `Bearer ${GROQ_KEY}` },
        body: form,
      });
      if (!r.ok) return null;
      return (await r.text()).trim();
    } catch {
      return null;
    }
  }

  // Upload a local file to the channel as a Discord attachment (multipart).
  async function uploadToDiscord(filePath: string, note = ""): Promise<boolean> {
    try {
      if (!existsSync(filePath)) return false;
      const form = new FormData();
      if (note.trim()) form.append("payload_json", JSON.stringify({ content: note.slice(0, REPLY_MAX) }));
      form.append("files[0]", new Blob([readFileSync(filePath)]), basename(filePath));
      const r = await fetch(`${API}/channels/${CHANNEL}/messages`, {
        method: "POST",
        headers: { Authorization: `Bot ${TOKEN}` }, // no Content-Type: FormData sets the boundary
        body: form,
      });
      return r.ok;
    } catch {
      return false;
    }
  }

  // ---- Outbound: post one assistant message's text, uploading referenced media ----
  async function deliverOutbound(item: PendingOutbound): Promise<void> {
    if (item.paths.length && !item.uploadsDone) {
      item.noteDelivered = !item.clean;
      for (const p of item.paths) {
        const ok = await uploadToDiscord(p, item.noteDelivered ? "" : item.clean);
        if (ok) item.noteDelivered = true;
      }
      item.uploadsDone = true;
    }
    // If no upload carried the text (all failed), still post it.
    const text = item.paths.length && item.noteDelivered ? "" : item.clean.trim();
    const parts = text ? chunk(text) : [];
    for (let i = item.sentParts; i < parts.length; i++) {
      await dPOST(`/channels/${CHANNEL}/messages`, { content: parts[i] });
      item.sentParts = i + 1;
    }
  }

  function queueOutbound(text: string): void {
    const { clean, paths } = extractMedia(text);
    shared.outbound.push({ clean, paths, uploadsDone: false, noteDelivered: false, sentParts: 0 });
    void drainOutbound();
  }

  async function drainOutbound(): Promise<void> {
    if (shared.draining) return; // don't let a slow post overlap the next tick
    shared.draining = true;
    try {
      while (shared.outbound.length) {
        const item = shared.outbound[0];
        try {
          await deliverOutbound(item);
        } catch (e) {
          // Post failed (rate-limit exhausted / network). Keep this message at the
          // head of the queue and STOP; the next tick retries it instead of
          // silently dropping it.
          dbg(`outbound post failed, will retry: ${String(e).slice(0, 120)}`);
          return;
        }
        if (shared.outbound[0] === item) shared.outbound.shift();
      }
    } catch (e) {
      dbg(`drainOutbound error: ${String(e).slice(0, 160)}`);
    } finally {
      shared.draining = false;
      shared.lastDrainOk = Date.now(); // watchdog heartbeat: updated every completed tick
    }
  }

  // Outbound: self-rescheduling tick, not a bare setInterval. Each tick always
  // schedules the next one in finally, so a rejected drain can never kill the
  // loop. A watchdog re-arms if ticks stall (e.g. draining stuck true) so outbound
  // self-heals instead of silently dying on long uptime.
  function startOutbound(ctx: ExtensionContext): void {
    if (outboundTimer) return;
    const tick = (): void => {
      drainOutbound()
        .catch((e) => dbg(`drainOutbound rejected: ${String(e).slice(0, 140)}`))
        .finally(() => {
          if (runtimeCtx === ctx) outboundTimer = setTimeout(tick, 1000);
        });
    };
    tick();
    if (!watchdogTimer) {
      watchdogTimer = setInterval(() => {
        // If no completed tick for 15s, the loop is wedged: force-clear and re-arm.
        if (Date.now() - shared.lastDrainOk > 15000) {
          dbg(`outbound watchdog: ${Math.round((Date.now() - shared.lastDrainOk) / 1000)}s since last tick, re-arming`);
          shared.draining = false;
          if (outboundTimer) clearTimeout(outboundTimer);
          shared.lastDrainOk = Date.now();
          tick();
        }
      }, 10000);
    }
  }

  // ---- Inbound: poll channel for new messages, inject each as a user turn ----
  async function pollInbound(): Promise<void> {
    if (polling) return;
    polling = true;
    try {
      const query = shared.lastMessageId ? `?after=${shared.lastMessageId}&limit=10` : `?limit=1`;
      const msgs = await dGET(`/channels/${CHANNEL}/messages${query}`);
      if (!Array.isArray(msgs) || msgs.length === 0) return;
      // Discord returns newest-first; process oldest-first.
      for (const msg of (msgs as DiscordMessage[]).reverse()) {
        shared.lastMessageId = msg.id;
        if (msg.author?.id === shared.botUserId) continue; // ignore ONLY our own posts (prevent loop); accept all other bots
        await handleInbound(msg);
      }
    } finally {
      polling = false;
    }
  }

  async function handleInbound(msg: DiscordMessage): Promise<void> {
    let text = (msg.content || "").trim();
    let attachments: DiscordAttachment[] = Array.isArray(msg.attachments) ? msg.attachments : [];

    // Forwarded messages carry no top-level content/attachments; the real payload
    // lives in message_snapshots[0].message (flags bit 1<<14 = 16384 marks a forward).
    for (const snapshot of Array.isArray(msg.message_snapshots) ? msg.message_snapshots : []) {
      const sm = snapshot?.message;
      if (!sm) continue;
      const sc = (sm.content || "").trim();
      if (sc) text = [text, sc].filter(Boolean).join("\n").trim();
      if (Array.isArray(sm.attachments) && sm.attachments.length) attachments = attachments.concat(sm.attachments);
    }

    const mediaLines: string[] = [];
    const transcripts: string[] = [];
    for (const att of attachments) {
      const url = att?.url;
      const name = att?.filename || "file";
      if (!url) continue;
      // Discord voice messages: flag bit 1<<13 (8192), or an attachment carrying a waveform.
      const isVoice = Boolean(msg.flags && (msg.flags & 8192)) || att?.waveform !== undefined;
      const local = await downloadAttachment(url, name);
      if (!local) continue;
      if (isVoice || (AUDIO_EXT.test(name) && !VIDEO_EXT.test(name))) {
        const transcript = await transcribeGroq(local);
        if (transcript) transcripts.push(transcript);
        else mediaLines.push(`[audio attachment: ${local} (transcription failed)]`);
      } else if (IMAGE_EXT.test(name)) {
        mediaLines.push(`[image: ${local}]`);
      } else if (VIDEO_EXT.test(name)) {
        mediaLines.push(`[video: ${local}]`);
      } else {
        mediaLines.push(`[file: ${local}]`);
      }
    }

    // Voice transcript(s) become the message body.
    if (transcripts.length) text = [text, ...transcripts].filter(Boolean).join("\n").trim();
    // Reference downloaded image/video/file paths so the agent can open them.
    if (mediaLines.length) text = [text, ...mediaLines].filter(Boolean).join("\n").trim();
    if (!text) return;
    injectUserTurn(text);
  }

  function injectUserTurn(text: string): void {
    // An idle session starts a turn at once; a busy one queues the message as a
    // followUp delivered after the current run instead of steering it mid-run.
    const idle = runtimeCtx ? runtimeCtx.isIdle() : true;
    try {
      if (idle) pi.sendUserMessage(text);
      else pi.sendUserMessage(text, { deliverAs: "followUp" });
    } catch {
      try {
        pi.sendUserMessage(text, { deliverAs: "followUp" });
      } catch {
        // The session cannot accept input right now; never throw into Pi's event loop.
        return;
      }
    }
  }

  function stopTyping(): void {
    working = false;
    if (typingTimer) {
      clearInterval(typingTimer);
      typingTimer = null;
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    runtimeCtx = ctx;
    if (!shared.botUserId) {
      const me = (await dGET("/users/@me")) as { id?: string } | null;
      shared.botUserId = me?.id ?? null;
    }
    // Post "online" ONCE per process: session_start also fires on reload and on
    // every /new, /resume, and /fork within the same process.
    if (!shared.announcedOnline) {
      shared.announcedOnline = true;
      dbg("bridge online (build: pi outbound-hardened)");
      try {
        await postToDiscord("firstmate bridge online.");
      } catch (e) {
        dbg(`online post failed: ${String(e).slice(0, 120)}`);
      }
    }
    // First start in this process: pull the cursor to "now" so history is not replayed.
    // A later runtime keeps the process cursor, so messages sent during a session switch still arrive.
    if (!shared.lastMessageId) {
      const latest = await dGET(`/channels/${CHANNEL}/messages?limit=1`);
      if (Array.isArray(latest) && latest[0]) shared.lastMessageId = (latest[0] as DiscordMessage).id;
    }
    if (runtimeCtx !== ctx) return; // shut down while awaiting
    if (!inboundTimer) inboundTimer = setInterval(() => void pollInbound(), INBOUND_POLL_MS);
    startOutbound(ctx);
  });

  pi.on("message_end", (event) => {
    const text = assistantText(event.message);
    if (text) queueOutbound(text);
  });

  pi.on("agent_start", () => {
    working = true;
    if (!typingTimer) {
      void showTyping();
      typingTimer = setInterval(() => {
        if (working) void showTyping();
      }, TYPING_REFRESH_MS);
    }
  });

  // agent_settled is Pi's final boundary: no retry, compaction, or queued followUp will continue.
  pi.on("agent_settled", () => stopTyping());

  // Runtime teardown (quit, reload, or session replacement): release this runtime's timers.
  // No "offline" post: session_shutdown also fires on ordinary /new, /resume, /fork, and
  // reload within a live process, so posting there would spam false offline notices.
  pi.on("session_shutdown", () => {
    runtimeCtx = null;
    stopTyping();
    if (inboundTimer) {
      clearInterval(inboundTimer);
      inboundTimer = null;
    }
    if (outboundTimer) {
      clearTimeout(outboundTimer);
      outboundTimer = null;
    }
    if (watchdogTimer) {
      clearInterval(watchdogTimer);
      watchdogTimer = null;
    }
  });
}
