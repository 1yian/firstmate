// Firstmate worker posture: every Pi agent that bin/fm-spawn.sh launches
// (crewmate, scout, secondmate, and control-plane relaunch) keeps Pi's native
// composer, even when the user-level Pi config installs a third-party editor
// such as pi-zentui's. Firstmate's composer classifier (bin/fm-composer-lib.sh)
// reads only the native box; a replacement editor makes an idle worker look
// like it is holding typed text, which skips steering doorbells and misleads
// lifecycle control. Only the editor is pinned: footers, message styles, and
// every other surface a user extension installs stay as configured.
//
// This file deliberately lives outside .pi/extensions/ so the primary Pi
// session, which auto-discovers that directory, never loads it; fm-spawn names
// it with -e on worker launches only.
//
// Pi loads -e extensions BEFORE settings packages and runs session_start
// handlers sequentially in load order, so resetting the editor from this
// handler would run before a package installs its own and be overwritten.
// Instead the handler pins the bound UI context: every later
// setEditorComponent call on it restores the native editor. Pi binds a fresh
// UI context on session replacement, and session_start fires again for it,
// so each context is pinned exactly once; /reload keeps its context and the
// marker below prevents a second wrap.
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";

const PINNED = Symbol.for("firstmate.worker-plain-composer");

type PinnableUi = ExtensionUIContext & { [PINNED]?: true };

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const ui = ctx.ui as PinnableUi;
    if (ui[PINNED]) return;
    const setNativeEditor = ui.setEditorComponent.bind(ui);
    ui.setEditorComponent = () => setNativeEditor(undefined);
    ui[PINNED] = true;
    if (ui.getEditorComponent() !== undefined) setNativeEditor(undefined);
  });
}
