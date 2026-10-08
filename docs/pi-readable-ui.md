# Pi readable transcript

`.pi/fm-readable-ui.ts` is an opt-in Pi extension that makes the interactive transcript easier to scan.
This page is for operators deciding whether to install it and what it changes.

## What it does

- **Sentence layout.**
  Each prose sentence of an assistant reply starts on its own line, inside paragraphs, list items, and block quotes.
  Headings, code, tables, HTML, link labels, inline code, and common abbreviations such as `e.g.`, `Dr.`, initials, and decimal numbers stay whole.
  While a reply streams, inline code or a link that has not finished arriving is never split.
- **One-line tool rows.**
  Each collapsed tool call is drawn as one row, `● tool(subject) - meta`.
  The dot follows the active theme: warning while the call runs, success when it finished, error when it failed.
  The subject is the call's own main argument (for example `command`, `pattern`, `query`, or `path`), clipped to 35 cells and to the terminal width.
  The meta reports `exit N`, `timed out after Ns`, `interrupted`, `terminated`, or `error`, and stays visible at narrow widths, where a row wraps beside its dot up to three rows.
  Expanding tool output (ctrl+o, or clicking a row) restores each tool's own rendering, including its arguments, output, and diffs.

## What stays unchanged

- Session files, model input, tool results, and `/copy` text are untouched; both behaviors are presentation only.
- The active theme owns every color; the extension adds no palette.
- Tool execution is untouched: the extension registers no tool and patches no Pi component.
- User messages and thinking blocks keep Pi's layout.
- `/export` and `/share` keep Pi's own pre-rendered tool HTML.

## Composition

- **Calm.**
  While [Calm](calm.md) is on, every tool row is drawn exactly as it would be without this extension, so Calm decides what is hidden; sentence layout still applies to replies Calm keeps visible.
- **Other tool renderers.**
  The expanded view is whatever renderer the tool already has, including overrides such as `@ff-labs/pi-fff`'s `find` and `grep`, or Pi's generic row for a tool with no renderer.
- **Editors and footers.**
  pi-zentui and the worker native-composer pin are unaffected because the extension never touches the editor, footer, or user rows.

## Install

The extension needs Pi 1.0.1 or newer and has no dependencies beyond Pi itself.
Try it for one session without changing any configuration:

```sh
pi -e /path/to/firstmate/.pi/fm-readable-ui.ts
```

To load it in every Pi session, add the file's absolute path to the `extensions` array in the user-level Pi settings (`~/.pi/agent/settings.json`), then restart Pi or run `/reload`:

```json
{
  "extensions": ["/path/to/firstmate/.pi/fm-readable-ui.ts"]
}
```

Firstmate does not load it on its own: `bin/fm-spawn.sh` launches are unchanged, and the file lives outside `.pi/extensions/` so the primary session does not auto-discover it.
Remove the path from `extensions` to return to Pi's stock transcript.

## Supported limits

- Pi draws one blank line before every tool row, so compact rows are separated by a blank line rather than stacked.
- Images returned by a tool still appear below its row when the terminal can draw them.
- Sentence detection is tuned for English prose; text without spaces between sentences, such as Chinese or Japanese, is left as written.

## Regression entry point

`tests/fm-readable-ui-pi-live-e2e.test.sh` proves both behaviors against the installed Pi from the user's side of the terminal, with [dated evidence](verification/runtime-backends.md#pi-readable-transcript).
