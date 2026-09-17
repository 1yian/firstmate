// Firstmate's home-persistent omp transcript presentation toggle.
//
// A port of .pi/extensions/fm-calm.ts for the omp fork. The Calm policy, the
// transcript-class allowlist, and the sprite geometry are shared: this file installs
// only the omp-specific presentation adapters and the /calm command. The omp-specific
// differences from Pi are stated once here:
//   - omp exposes no setWorkingVisible / setHiddenThinkingLabel on ExtensionUIContext.
//     The stock working spinner is gated through InteractiveMode.ensureLoadingAnimation
//     (./lib/fm-calm-working-loader.ts); thinking hide is policy-only in the assistant
//     layout adapter.
//   - agent_end without a continuation replaces Pi's agent_settled for run lifetime.
//   - Native tool renderers are adapted in place rather than by replacing tool
//     definitions, because omp exposes shared renderer functions with a first-wins
//     ToolDefinition registry like Pi.
//   - No supervision-branch tools exist; fm_watch_arm_omp calm rendering is owned by
//     fm-primary-omp-watch.ts, which listens for FIRSTMATE_CALM_PRESENTATION_EVENT.
//   - The standard-ANSI working-ship widget and sprite geometry are shared verbatim
//     with Pi through ../../.pi/extensions/lib/fm-calm-working-ship.ts.
//
// docs/configuration.md owns config/calm. docs/calm.md owns captain-facing behavior,
// and docs/calm-mode-feasibility.md owns the version-scoped evidence.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { Container, type TUI } from "@oh-my-pi/pi-tui";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";
import {
  clearLiveWorkingLoader,
  installCalmWorkingLoaderGate,
} from "./lib/fm-calm-working-loader.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "../../.pi/extensions/lib/fm-calm-working-ship.ts";

type ExtensionUIContext = {
  setWidget: (
    key: string,
    factory: ((tui: TUI) => unknown) | undefined,
    options?: { placement?: string },
  ) => void;
  setStatus: (key: string, value: unknown) => void;
  setWorkingMessage?: (message: string | undefined) => void;
  getToolsExpanded: () => boolean;
  setToolsExpanded: (expanded: boolean) => void;
  getEditorText: () => string;
  onTerminalInput: (handler: (data: string) => unknown) => () => void;
  notify: (message: string, level?: string) => void;
  ctx?: unknown;
};

type ExtensionCommandContext = {
  ui: ExtensionUIContext;
  hasUI?: boolean;
};

type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: { ui: ExtensionUIContext }) => unknown) => void;
  registerCommand?: (
    name: string,
    command: {
      description: string;
      handler: (args: string, ctx: ExtensionCommandContext) => Promise<void> | void;
    },
  ) => void;
  events?: {
    emit: (event: string, data: unknown) => void;
    on?: (event: string, handler: (data: unknown) => void) => void;
  };
  registerMessageRenderer?: (customType: string, renderer: (...args: unknown[]) => unknown) => void;
  registerEntryRenderer?: (customType: string, renderer: (...args: unknown[]) => unknown) => void;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Each presentation adapter probes the exact omp API it patches. If a future omp
// removes that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: skipped ${name} adapter on omp. ${reason}`);
  }
}

// Adapt presentation only: native schemas, approval policy, and execution stay owned by
// omp. omp exposes one shared renderer function per built-in tool name, so patching the
// function reaches every tool row without ever replacing a tool definition.
const CALM_TOOL_RENDERERS = [
  "readToolRenderer",
  "bashToolRenderer",
  "editToolRenderer",
  "writeToolRenderer",
  "grepToolRenderer",
  "globToolRenderer",
] as const;
const CALM_TOOL_RENDERER_PATCH = Symbol.for("firstmate:calm-tool-renderer:omp");

type ToolRenderer = {
  renderCall: (...args: unknown[]) => unknown;
  renderResult: (...args: unknown[]) => unknown;
  [CALM_TOOL_RENDERER_PATCH]?: { hides: typeof calmPresentationHides };
};

function installCalmToolRenderers(): void {
  const renderers = OmpCodingAgent as unknown as Record<string, ToolRenderer | undefined>;
  for (const name of CALM_TOOL_RENDERERS) {
    installCalmPresentationAdapter(name, () => {
      const renderer = renderers[name];
      if (
        !renderer ||
        typeof renderer.renderCall !== "function" ||
        typeof renderer.renderResult !== "function"
      ) {
        throw new Error(`omp does not expose ${name}`);
      }
      const installed = renderer[CALM_TOOL_RENDERER_PATCH];
      if (installed) {
        installed.hides = calmPresentationHides;
        return;
      }
      const patch = { hides: calmPresentationHides };
      const originalCall = renderer.renderCall;
      const originalResult = renderer.renderResult;
      renderer.renderCall = function (this: unknown, ...args: unknown[]) {
        return patch.hides("assistant-tool-call") ? new Container() : originalCall.apply(this, args);
      };
      renderer.renderResult = function (this: unknown, ...args: unknown[]) {
        return patch.hides("tool-result") ? new Container() : originalResult.apply(this, args);
      };
      renderer[CALM_TOOL_RENDERER_PATCH] = patch;
    });
  }
  installCalmPresentationAdapter("grouped-read", () => {
    const groupComponent = OmpCodingAgent.ReadToolGroupComponent as unknown as
      | {
          prototype: {
            render: (width: number) => string[];
            [CALM_TOOL_RENDERER_PATCH]?: { hides: typeof calmPresentationHides };
          };
        }
      | undefined;
    const prototype = groupComponent?.prototype;
    if (!prototype || typeof prototype.render !== "function") {
      throw new Error("omp does not expose ReadToolGroupComponent.render");
    }
    const installed = prototype[CALM_TOOL_RENDERER_PATCH];
    if (installed) {
      installed.hides = calmPresentationHides;
      return;
    }
    const patch = { hides: calmPresentationHides };
    const original = prototype.render;
    prototype.render = function (this: unknown, width: number) {
      return patch.hides("assistant-tool-call") ? [] : original.call(this, width);
    };
    prototype[CALM_TOOL_RENDERER_PATCH] = patch;
  });
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("working-loader", installCalmWorkingLoaderGate);
  installCalmToolRenderers();

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  let agentRunActive = false;
  let workingShipShown = false;
  const workingShipAnimation = createCalmWorkingShipAnimation();

  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui: TUI) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      if (showShip) {
        clearLiveWorkingLoader(ui);
        ui.setWorkingMessage?.(undefined);
      }
    } else if (forceStockVisibility && !showShip) {
      ui.setWidget(CALM_WORKING_SHIP_WIDGET_KEY, undefined);
      workingShipShown = false;
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");

  const loadCalmPreference = (): boolean => {
    let stored: string;
    try {
      stored = readFileSync(calmPreferencePath, "utf8").trim();
    } catch {
      return false;
    }
    return stored === "on" || stored === "max";
  };

  const persistCalmPreference = (active: boolean): void => {
    mkdirSync(dirname(calmPreferencePath), { recursive: true });
    const temporaryPath = `${calmPreferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, active ? "on\n" : "off\n", {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, calmPreferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const publishPresentationState = (): void => {
    pi.events?.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  registerFirstmateSyntheticPresentation(pi);

  const agentEndContinues = (event: unknown): boolean => {
    if (!event || typeof event !== "object") return false;
    if ("isTerminal" in event && event.isTerminal === false) return true;
    return "willContinue" in event && event.willContinue === true;
  };

  pi.on?.("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    workingShipAnimation.reset();
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      // omp does not export getKeybindings; match Enter-ish submit conservatively.
      if (data !== "\r" && data !== "\n" && data !== "\r\n") return undefined;
      const input = ctx.ui.getEditorText().trim();
      if (input !== "/share" && input !== "/export" && !input.startsWith("/export ")) {
        return undefined;
      }
      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        // Toggle tools-expanded to force a redraw without a status line.
        try {
          const expanded = ctx.ui.getToolsExpanded();
          ctx.ui.setToolsExpanded(!expanded);
          ctx.ui.setToolsExpanded(expanded);
        } catch {
          // ignore redraw failures
        }
        ctx.ui.setStatus("firstmate-calm", undefined);
      }, 0);
      return undefined;
    });
  });

  pi.on?.("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on?.("agent_end", (event, ctx) => {
    if (agentEndContinues(event)) return;
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on?.("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand?.("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      if (active) clearLiveWorkingLoader(ctx.ui);
      ctx.ui.setStatus("firstmate-calm", undefined);
      try {
        const expanded = ctx.ui.getToolsExpanded();
        ctx.ui.setToolsExpanded(!expanded);
        ctx.ui.setToolsExpanded(expanded);
      } catch {
        // ignore redraw failures
      }
      ctx.ui.notify(
        active
          ? "Calm on: quieter transcript presentation for this Firstmate home."
          : "Calm off: ordinary omp transcript presentation restored.",
        "info",
      );
    },
  });
}
