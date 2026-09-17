// omp operational-user transcript adapter for Calm.
// Patches InteractiveMode.addMessageToChat from @oh-my-pi/pi-coding-agent so Firstmate
// operational user rows render at zero height while Calm is on, without changing
// delivery or persistence. It probes that exact method and throws if it is missing;
// fm-calm.ts catches that and skips only this adapter with a diagnostic.
// ../../../.pi/extensions/lib/fm-operational-input.ts owns the operational-input
// classifier, and ./fm-calm-visibility.ts owns which classes Calm hides.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "../../../.pi/extensions/lib/fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<
  typeof OmpCodingAgent.UserMessageComponent
>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
  reuseSettledComponent?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: unknown): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings?: () => UserMessageConstructorArgs[1];
  getUserMessageText(message: UserMessageLike): string;
  outputPad?: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:omp-18",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      "type" in block &&
      block.type === "text" &&
      "text" in block &&
      typeof block.text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  if (typeof OmpCodingAgent.InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode");
  }
  // omp ships no type package; assert the runtime prototype shape probed below.
  const prototype = OmpCodingAgent.InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = OmpCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires omp UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      hasLeadingSpacer: boolean,
    ) {
      super(text, markdownTheme, outputPad);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const markdownTheme =
      typeof this.getMarkdownThemeWithSettings === "function"
        ? this.getMarkdownThemeWithSettings()
        : OmpCodingAgent.getMarkdownTheme();
    const component = new CalmOperationalUserMessageComponent(
      text,
      markdownTheme,
      this.outputPad ?? 0,
      this.chatContainer.children.length > 0,
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
