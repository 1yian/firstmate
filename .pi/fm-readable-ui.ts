// Firstmate readable Pi transcript: sentence-per-line assistant prose and one-line tool rows.
//
// Two presentation-only behaviors built solely on Pi's public extension API:
//   - pi.registerMarkdownTransformer (Pi 0.84.0+) starts each prose sentence of an assistant
//     reply on its own line, inside paragraphs, list items, and block quotes only.
//   - pi.registerToolRenderer (Pi 1.0.1+) draws every collapsed tool call as one row,
//     `● tool(subject) - meta`, and restores each tool's own rendering when expanded (ctrl+o).
// Nothing here registers or wraps a tool's execution, patches a Pi component prototype, or
// changes a session entry, model input, tool result, or theme: the active theme keeps owning
// every Markdown and tool color.
//
// The behavior is modeled on the glamour-dark and tool-lines Claude Code mods at
// https://github.com/Tickloop/claude-mods. That repository publishes no license, so no code
// is copied from it; this file is an independent implementation of the same display ideas.
//
// Composition:
//   - Firstmate Calm (.pi/extensions/fm-calm.ts) publishes its state on the
//     `firstmate:calm-presentation` event. While Calm is on, or while Calm forces stock
//     rendering for /export, every tool row is drawn exactly as it would be without this file,
//     so Calm's hiding stays authoritative. No Calm module is imported.
//   - Tool renderer resolvers run before registered tool definitions, so wrapping `next()`
//     keeps Calm's, FFF's, and every other extension's renderers as the expanded view.
//   - /export and /share render stock rows for that one command, as Calm does, so exported
//     HTML keeps Pi's own call headers and template rendering.
// docs/pi-readable-ui.md owns installation and the user-facing contract.
import { keyHint, type ExtensionAPI, type ToolRenderers } from "@earendil-works/pi-coding-agent";
import {
  Box,
  Container,
  getCapabilities,
  getImageDimensions,
  getKeybindings,
  imageFallback,
  Marked,
  stripTerminalSequences,
  Text,
  truncateToWidth,
  visibleWidth,
  wrapTextWithAnsi,
  type Component,
} from "@earendil-works/pi-tui";

// ---------------------------------------------------------------------------
// Sentence layout
// ---------------------------------------------------------------------------

// Words whose trailing period does not end a sentence.
const ABBREVIATIONS = new Set([
  "e.g", "i.e", "etc", "vs", "cf", "approx", "al", "eg", "ie", "viz", "resp", "incl", "esp",
  "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "no", "nos", "fig", "figs", "vol",
  "ch", "sec", "p", "pp", "ca", "est", "dept", "inc", "ltd", "co", "corp", "jan", "feb",
  "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
]);
// Sentence punctuation, optionally followed by closing quotes, brackets, or emphasis markers.
const SENTENCE_END = /[.!?\u2026]["'\u201d\u2019)\]*_~]*$/u;
// Text that may open a new sentence: an uppercase letter, a digit, an opening quote or
// bracket, inline code, or emphasis.
const SENTENCE_OPEN = /^[\p{Lu}\p{N}"'\u201c\u2018([`*_]/u;
// A line that would start a different Markdown block instead of continuing the paragraph.
const BLOCK_OPENER =
  /^(?:[-+*](?:[ \t]|$)|\d{1,9}[.)](?:[ \t]|$)|>|#{1,6}(?:[ \t]|$)|\||`{3,}|~{3,}|<[A-Za-z!?/]|={2,}|-{2,}|\*{3,}|_{3,})/;
const MASK = "\u0000";

// The index of the delimiter closing a link destination "(" or a reference label "[" that
// opened just before `from`, or -1 while it is unfinished. Escapes are skipped, destinations
// may nest balanced parentheses, and a quoted title may hold any delimiter.
function inlineTargetEnd(source: string, from: number, closer: ")" | "]"): number {
  let depth = 1;
  for (let j = from; j < source.length; j++) {
    const ch = source[j];
    if (ch === "\\") {
      j++;
    } else if (closer === "]") {
      if (ch === "]") return j;
    } else if ((ch === '"' || ch === "'") && /\s/.test(source[j - 1] ?? "")) {
      j = source.indexOf(ch, j + 1);
      while (j > 0 && source[j - 1] === "\\") j = source.indexOf(ch, j + 1);
      if (j === -1) return -1;
    } else if (ch === "(") {
      depth++;
    } else if (ch === ")" && --depth === 0) {
      return j;
    }
  }
  return -1;
}

function maskRange(chars: string[], start: number, end: number): void {
  for (let i = start; i < end; i++) chars[i] = MASK;
}

// Masks every span a sentence break must never enter: escapes, inline code, links, images,
// autolinks, inline HTML, and bare URLs. While a reply streams, an unfinished code span or
// link masks the rest of the text, so a break never lands inside markup that is still arriving.
function maskInline(source: string, streaming: boolean): string {
  // Masked by UTF-16 unit so every index still lines up with the source text.
  const units = source.split("");
  const mask = (start: number, end: number) => maskRange(units, start, end);
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === "\\" && i + 1 < source.length) {
      mask(i, i + 2);
      i += 2;
      continue;
    }
    if (ch === "`") {
      let run = 1;
      while (source[i + run] === "`") run++;
      const fence = "`".repeat(run);
      let close = source.indexOf(fence, i + run);
      while (close !== -1 && source[close + run] === "`") close = source.indexOf(fence, close + run + 1);
      if (close === -1) {
        if (streaming) {
          mask(i, source.length);
          break;
        }
        mask(i, i + run);
        i += run;
        continue;
      }
      mask(i, close + run);
      i = close + run;
      continue;
    }
    if (ch === "[" || (ch === "!" && source[i + 1] === "[")) {
      const open = ch === "!" ? i + 1 : i;
      let depth = 0;
      let labelEnd = -1;
      for (let j = open; j < source.length; j++) {
        if (source[j] === "\\") {
          j++;
          continue;
        }
        if (source[j] === "[") depth++;
        else if (source[j] === "]" && --depth === 0) {
          labelEnd = j;
          break;
        }
      }
      if (labelEnd === -1) {
        if (streaming) {
          mask(i, source.length);
          break;
        }
        i++;
        continue;
      }
      const after = source[labelEnd + 1];
      if (after === "(" || after === "[") {
        const end = inlineTargetEnd(source, labelEnd + 2, after === "(" ? ")" : "]");
        if (end === -1) {
          if (streaming) {
            mask(i, source.length);
            break;
          }
          i = labelEnd + 1;
          continue;
        }
        mask(i, end + 1);
        i = end + 1;
        continue;
      }
      // A shortcut reference or plain bracketed text: keep its label whole.
      mask(i, labelEnd + 1);
      i = labelEnd + 1;
      continue;
    }
    if (ch === "<") {
      const end = source.indexOf(">", i + 1);
      if (end !== -1 && /^<(?:[A-Za-z][A-Za-z0-9+.-]*:[^\s<>]*|[^\s<>@]+@[^\s<>@]+|\/?[A-Za-z][^<>]*)>$/.test(source.slice(i, end + 1))) {
        mask(i, end + 1);
        i = end + 1;
        continue;
      }
    }
    const url = /^(?:https?:\/\/|www\.)[^\s<]*/i.exec(source.slice(i));
    if (url && (i === 0 || /[\s(]/.test(source[i - 1] ?? ""))) {
      mask(i, i + url[0].length);
      i += url[0].length;
      continue;
    }
    i++;
  }
  return units.join("");
}

function endsSentence(maskedBefore: string): boolean {
  if (!SENTENCE_END.test(maskedBefore)) return false;
  const word = /(?:^|[\s([])([^\s([]*)$/u.exec(maskedBefore)?.[1] ?? "";
  const bare = word.replace(/^["'\u201c\u2018*_~]+/u, "").replace(/["'\u201d\u2019)\]*_~]+$/u, "");
  if (!bare.endsWith(".")) return true;
  const stem = bare.slice(0, -1);
  if (ABBREVIATIONS.has(stem.toLowerCase())) return false;
  // A single letter before a period is an initial ("J. Smith") or an enumerator ("a.").
  if (/^\p{L}$/u.test(stem)) return false;
  // Dotted abbreviations such as "U.S." or "a.m.".
  if (/^(?:\p{L}\.)+\p{L}$/u.test(stem)) return false;
  return true;
}

// Inserts a CommonMark hard break at every sentence boundary of one block of inline text.
// `indent` prefixes each continuation line, which keeps list-item text inside its item.
function breakSentences(text: string, indent: string, streaming: boolean): string {
  const masked = maskInline(text, streaming);
  let out = "";
  let start = 0;
  for (const gap of masked.matchAll(/[ \t]*\n[ \t]*|[ \t]+/g)) {
    const at = gap.index ?? 0;
    const end = at + gap[0].length;
    if (end >= text.length || at === 0) continue;
    if (!endsSentence(masked.slice(0, at))) continue;
    const after = text.slice(end);
    if (!SENTENCE_OPEN.test(after) || BLOCK_OPENER.test(after)) continue;
    // A line already ending in a hard break needs no second one.
    if (/(?:\\| {2,})$/.test(text.slice(0, at)) || /^ {2,}\n/.test(gap[0])) continue;
    out += `${text.slice(start, at)}\\\n${indent}`;
    start = end;
  }
  return out + text.slice(start);
}

type MdToken = {
  type: string;
  raw: string;
  text?: string;
  items?: MdListItem[];
};
type MdListItem = { raw: string; text: string; task?: boolean };

const markdownLexer = new Marked();

function trailingNewlines(raw: string): string {
  return /\n*$/.exec(raw)?.[0] ?? "";
}

function prefixLines(text: string, first: string, rest: string): string {
  return text
    .split("\n")
    .map((line, index) => (index === 0 ? first + line : line === "" ? line : rest + line))
    .join("\n");
}

function rewriteListItem(item: MdListItem, streaming: boolean): string {
  const marker = /^( {0,3})([-+*]|\d{1,9}[.)])( {1,4})(\[[ xX]\] +)?/.exec(item.raw);
  if (!marker) return item.raw;
  const head = marker[0];
  const indent = " ".repeat(marker[1].length + marker[2].length + marker[3].length);
  const tail = trailingNewlines(item.raw);
  // Rewrite only when the item's own text rebuilds its source exactly; anything else, such as
  // lazy continuation lines or tab indentation, is left untouched.
  if (prefixLines(item.text, head, indent) + tail !== item.raw) return item.raw;
  return prefixLines(rewriteMarkdown(item.text, streaming), head, indent) + tail;
}

function rewriteBlockquote(token: MdToken, streaming: boolean): string {
  if (typeof token.text !== "string") return token.raw;
  const tail = trailingNewlines(token.raw);
  const quote = (text: string) =>
    text
      .split("\n")
      .map((line) => (line === "" ? ">" : `> ${line}`))
      .join("\n");
  if (quote(token.text) + tail !== token.raw) return token.raw;
  return quote(rewriteMarkdown(token.text, streaming)) + tail;
}

function rewriteToken(token: MdToken, streaming: boolean): string {
  switch (token.type) {
    case "paragraph":
    case "text": {
      const tail = trailingNewlines(token.raw);
      const body = token.raw.slice(0, token.raw.length - tail.length);
      return breakSentences(body, "", streaming) + tail;
    }
    case "list":
      if (!token.items || token.items.map((item) => item.raw).join("") !== token.raw) return token.raw;
      return token.items.map((item) => rewriteListItem(item, streaming)).join("");
    case "blockquote":
      return rewriteBlockquote(token, streaming);
    default:
      // Headings, code, tables, HTML, rules, and definitions keep their lines.
      return token.raw;
  }
}

function rewriteMarkdown(markdown: string, streaming: boolean): string {
  const tokens = markdownLexer.lexer(markdown) as unknown as MdToken[];
  if (tokens.map((token) => token.raw).join("") !== markdown) return markdown;
  return tokens.map((token) => rewriteToken(token, streaming)).join("");
}

// ---------------------------------------------------------------------------
// Tool rows
// ---------------------------------------------------------------------------

// Argument names that say what a call acts on, most telling first.
const SUBJECT_KEYS = [
  "command", "file_path", "notebook_path", "pattern", "url", "query", "skill",
  "description", "path", "action", "prompt",
];
const SUBJECT_MAX = 35;
const MAX_ROWS = 3;
const CALM_EVENT = "firstmate:calm-presentation";

function subjectOf(args: unknown): string {
  if (typeof args !== "object" || args === null) return "";
  const fields = args as Record<string, unknown>;
  const key = SUBJECT_KEYS.find((name) => typeof fields[name] === "string" && fields[name] !== "");
  let raw = "";
  if (key) raw = String(fields[key]);
  else if (Object.keys(fields).length > 0) {
    try {
      raw = JSON.stringify(fields);
    } catch {
      raw = "";
    }
  }
  return raw.replace(/\s+/g, " ").trim();
}

function clip(text: string, room: number): string {
  if (room <= 0) return "";
  if (visibleWidth(text) <= room) return text;
  return room === 1 ? "…" : truncateToWidth(text, room, "…");
}

type ResultLike = { content: Array<{ type: string; text?: string; data?: string; mimeType?: string }> };

function resultText(result: ResultLike | undefined): string {
  if (!result) return "";
  return result.content
    .filter((block) => block.type === "text")
    .map((block) => stripTerminalSequences(block.text ?? "").replace(/\r/g, ""))
    .join("\n");
}

// The short status a failed call reports beside its subject. Pi's shell tools end a failed
// result with one status line; any other failure reads as a plain error.
function metaOf(result: ResultLike, isError: boolean): string {
  if (!isError) return "";
  const tail = resultText(result).trimEnd().split("\n").pop()?.trim() ?? "";
  const timedOut = /timed out after (\d+(?:\.\d+)?) ?s(?:econds?)?\b/i.exec(tail);
  if (timedOut) return `timed out after ${timedOut[1]}s`;
  if (/^(?:Command|Operation) aborted\b/i.test(tail)) return "interrupted";
  const exited = /exited with code (-?\d+)/i.exec(tail);
  if (exited) return `exit ${exited[1]}`;
  if (/terminated without an exit code/i.test(tail)) return "terminated";
  return "error";
}

// A result's text, followed by an indicator line per image Pi cannot draw.
function outputText(result: ResultLike | undefined, showImages: boolean): string {
  let output = resultText(result);
  const images = result?.content.filter((block) => block.type === "image") ?? [];
  if (images.length > 0 && (!getCapabilities().images || !showImages)) {
    const indicators = images
      .map((image) => {
        const mimeType = image.mimeType ?? "image/unknown";
        const dims = image.data && image.mimeType ? (getImageDimensions(image.data, image.mimeType) ?? undefined) : undefined;
        return imageFallback(mimeType, dims);
      })
      .join("\n");
    output = output ? `${output}\n${indicators}` : indicators;
  }
  return output;
}

// Pi's own text for a tool row that has no renderer at all.
function stockFallbackText(toolName: string, args: unknown, result: ResultLike | undefined, showImages: boolean, theme: ThemeLike): string {
  let text = theme.fg("toolTitle", theme.bold(toolName));
  const content = JSON.stringify(args, null, 2);
  if (content) text += `\n\n${content}`;
  const output = outputText(result, showImages);
  if (output) text += `\n${output}`;
  return text;
}

const FALLBACK_PREVIEW_LINES = 10;
const COLLAPSED_ARGS_CHARS = 100;

// Pi's own call header for a registered tool that has no call renderer: the title, then its
// arguments as `key=value` pairs, or one `key: value` line each when expanded.
function callHeaderWithArgs(title: string, args: unknown, theme: ThemeLike, expanded: boolean): string {
  const header = theme.fg("toolTitle", theme.bold(title));
  if (args == null) return header;
  const entries: Array<[string, unknown]> = typeof args === "object" && !Array.isArray(args) ? Object.entries(args) : [["args", args]];
  if (entries.length === 0) return header;
  if (expanded) {
    const lines = entries.map(([key, value]) => {
      const text = typeof value === "string" ? value : (JSON.stringify(value, null, 2) ?? String(value));
      return `  ${key}: ${text.replace(/\t/g, "   ").replace(/\r/g, "").split("\n").join("\n    ")}`;
    });
    return `${header}\n${theme.fg("muted", lines.join("\n"))}`;
  }
  const pairs = entries.map(([key, value]) => `${key}=${JSON.stringify(value) ?? String(value)}`).join(" ");
  const preview = pairs.length > COLLAPSED_ARGS_CHARS ? `${pairs.slice(0, COLLAPSED_ARGS_CHARS - 3)}...` : pairs;
  return `${header} ${theme.fg("muted", preview)}`;
}

// Pi's own result body for a registered tool that has no result renderer: the output, cut to a
// preview unless expanded.
function resultFallback(result: ResultLike, expanded: boolean, showImages: boolean, theme: ThemeLike): Component {
  const output = outputText(result, showImages);
  if (!output) return new Container();
  const lines = output.split("\n");
  const shown = expanded ? lines : lines.slice(0, FALLBACK_PREVIEW_LINES);
  const remaining = lines.length - shown.length;
  let text = shown.map((line) => theme.fg("toolOutput", line)).join("\n");
  if (remaining > 0) {
    text += `${theme.fg("muted", `\n... (${remaining} more lines,`)} ${keyHint("app.tools.expand", "to expand")}${theme.fg("muted", ")")}`;
  }
  return new Text(text, 0, 0);
}

type ThemeLike = Parameters<NonNullable<ToolRenderers["renderCall"]>>[1];
type CallContext = Parameters<NonNullable<ToolRenderers["renderCall"]>>[2];

type RowState = {
  // Stock rendering: each base slot keeps its own previous component.
  baseCall?: Component;
  baseResult?: Component;
  shell?: Box;
  fallback?: Text;
  // Compact rendering.
  result?: ResultLike;
  final?: boolean;
  meta?: string;
};

class StockExportSkip extends Error {}

export default function (pi: ExtensionAPI) {
  pi.registerMarkdownTransformer((markdown, context) => {
    if (context.messageType !== "assistant") return markdown;
    return rewriteMarkdown(markdown, context.isStreaming);
  });

  let calmActive = false;
  let calmStockExport = false;
  let exportWindow = false;
  const rows = new Map<object, () => void>();
  const repaintRows = () => {
    for (const invalidate of rows.values()) invalidate();
  };
  const stockMode = () => calmActive || calmStockExport || exportWindow;
  const exporting = () => calmStockExport || exportWindow;

  pi.events.on(CALM_EVENT, (data) => {
    const state = (data ?? {}) as { active?: unknown; stockExportRendering?: unknown };
    const nextActive = state.active === true;
    const nextExport = state.stockExportRendering === true;
    if (nextActive === calmActive && nextExport === calmStockExport) return;
    calmActive = nextActive;
    calmStockExport = nextExport;
    repaintRows();
  });

  pi.on("session_start", (_event, ctx) => {
    rows.clear();
    exportWindow = false;
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    ctx.ui.onTerminalInput((data) => {
      if (!getKeybindings().matches(data, "tui.input.submit")) return undefined;
      const input = ctx.ui.getEditorText().trim();
      if (input !== "/share" && input !== "/export" && !input.startsWith("/export ")) return undefined;
      exportWindow = true;
      setTimeout(() => {
        exportWindow = false;
        repaintRows();
      }, 0);
      return undefined;
    });
  });

  pi.registerToolRenderer((toolName, next): ToolRenderers | undefined => {
    const base = next();
    const baseSelf = base?.renderShell === "self";

    // HTML export draws each renderer's own component without Pi's row shell, and skips a slot the
    // tool does not render. Throwing makes the exporter fall back exactly as it would without us.
    const exportCall = (args: unknown, theme: ThemeLike, context: CallContext): Component => {
      if (!base?.renderCall) throw new StockExportSkip("no call renderer: let the export template draw it");
      return base.renderCall(args, theme, context);
    };

    const remember = (context: CallContext) => {
      if (typeof context.invalidate !== "function") return;
      rows.set(context.state as object, context.invalidate);
    };

    const stockBackground = (theme: ThemeLike, context: CallContext) => (text: string) =>
      theme.bg(context.isPartial ? "toolPendingBg" : context.isError ? "toolErrorBg" : "toolSuccessBg", text);

    // The row exactly as Pi draws it without this extension.
    const stockCall = (args: unknown, theme: ThemeLike, context: CallContext): Component => {
      const state = context.state as RowState;
      if (!base) {
        const fallback = state.fallback ?? new Text("", 1, 1);
        state.fallback = fallback;
        fallback.setCustomBgFn(stockBackground(theme, context));
        const showImages = context.showImages;
        return {
          invalidate: () => fallback.invalidate(),
          render: (width: number) => {
            fallback.setText(stockFallbackText(toolName, args, state.result, showImages, theme));
            return fallback.render(width);
          },
        };
      }
      const call = base.renderCall
        ? base.renderCall(args, theme, { ...context, lastComponent: state.baseCall })
        : new Text(callHeaderWithArgs(toolName, args, theme, context.expanded), 0, 0);
      state.baseCall = call;
      if (baseSelf) return call;
      const shell = state.shell ?? new Box(1, 1);
      state.shell = shell;
      shell.setBgFn(stockBackground(theme, context));
      shell.clear();
      shell.addChild(call);
      return shell;
    };

    const stockResult = (
      result: Parameters<NonNullable<ToolRenderers["renderResult"]>>[0],
      options: Parameters<NonNullable<ToolRenderers["renderResult"]>>[1],
      theme: ThemeLike,
      context: CallContext,
    ): Component => {
      const state = context.state as RowState;
      if (!base) {
        return new Container();
      }
      if (!base.renderResult) {
        const body = resultFallback(result as ResultLike, context.expanded, context.showImages, theme);
        if (baseSelf || !state.shell) return body;
        state.shell.addChild(body);
        return new Container();
      }
      const body = base.renderResult(result, options, theme, { ...context, lastComponent: state.baseResult });
      state.baseResult = body;
      if (baseSelf || !state.shell) return body;
      state.shell.addChild(body);
      return new Container();
    };

    const compactCall = (args: unknown, theme: ThemeLike, context: CallContext): Component => {
      const state = context.state as RowState;
      const { isError, isPartial } = context;
      return {
        invalidate() {},
        // Read row state when drawn: the result slot fills it after this call slot is built.
        render(width: number) {
          const finished = !isPartial && state.final === true;
          const dot = isError ? theme.fg("error", "●") : finished ? theme.fg("success", "●") : theme.fg("warning", "●");
          const meta = finished || isError ? (state.meta ?? (isError ? "error" : "")) : "";
          const metaText = meta ? ` - ${meta}` : "";
          const styledMeta = metaText ? theme.fg(isError ? "error" : "dim", metaText) : "";
          const styledName = (title: string) => `${theme.fg("toolTitle", theme.bold(title))}(`;
          const lead = ` ${dot} ${styledName(toolName)}`;
          const subject = subjectOf(args);
          const room = Math.min(SUBJECT_MAX, width - visibleWidth(lead) - 1 - visibleWidth(metaText));
          if (subject === "" ? room >= 0 : room >= Math.min(8, visibleWidth(subject))) {
            return [truncateToWidth(`${lead}${clip(subject, Math.max(room, 1))})${styledMeta}`, width)];
          }
          // Too narrow for one row: wrap beside the dot, up to three rows, shortening the subject
          // and then the tool name rather than the status meta.
          const gutter = "   ";
          const inner = Math.max(1, width - gutter.length);
          const attempts: Array<[string, string]> = [];
          for (let size = Math.min(SUBJECT_MAX, visibleWidth(subject)); size >= 0; size--) attempts.push([toolName, clip(subject, size)]);
          for (let size = visibleWidth(toolName) - 1; size >= 1; size--) attempts.push([clip(toolName, size), ""]);
          let lines: string[] = [];
          for (const [title, shown] of attempts) {
            lines = wrapTextWithAnsi(`${styledName(title)}${shown})${styledMeta}`, inner);
            if (lines.length <= MAX_ROWS) break;
          }
          lines = lines.slice(0, MAX_ROWS);
          return lines.map((line, index) => truncateToWidth(`${index === 0 ? ` ${dot} ` : gutter}${line}`, width));
        },
      };
    };

    return {
      renderShell: "self",
      renderCall(args, theme, context) {
        if (exporting()) return exportCall(args, theme, context);
        remember(context);
        if (stockMode() || context.expanded) return stockCall(args, theme, context);
        return compactCall(args, theme, context);
      },
      renderResult(result, options, theme, context) {
        remember(context);
        const state = context.state as RowState;
        state.result = result as ResultLike;
        state.final = !options.isPartial;
        state.meta = options.isPartial ? undefined : metaOf(result as ResultLike, context.isError);
        if (exporting()) {
          if (!base?.renderResult) throw new StockExportSkip("no result renderer: let the export template draw it");
          return base.renderResult(result, options, theme, context);
        }
        if (stockMode() || options.expanded) return stockResult(result, options, theme, context);
        return new Container();
      },
    };
  });
}
