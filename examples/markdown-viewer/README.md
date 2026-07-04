# markdown-viewer

A split-pane markdown editor/preview authored in markup + Zig: the left pane is a `textarea` mirrored elm-style into the model, the right pane is one `<markdown>` element bound to the same bytes, so the preview tracks every keystroke with no debounce and no drift. The whole view lives in `src/viewer.zml` (hot-reloaded in dev builds); `src/main.zig` is the logic — `Model`, `Msg`, `update`, effects, and a two-mode custom theme.

```sh
zig build run
```

## What it demonstrates

- **`<markdown>` in markup** — headings on the span scale, inline styles, clickable links (pointer cursor; opened in the system browser through `fx.spawn open`/`xdg-open`), task lists, fenced code, blockquotes, GFM tables with column alignment, and `<details>` blocks whose expansion flags live in the model (`details_expanded: [16]bool`), toggled in `update`.
- **Real file I/O without native dialogs** — zero-native has no file-dialog service, so this app uses the honest pattern: an editable path field in the toolbar. **Open** reads it (`fx.readFile`), **Save** writes the editor back to the current document, **Save As** writes to whatever the field says and adopts it. Every result is one typed Msg with an explicit outcome; failures land in the status bar, never a dialog.
- **Recent files persisted through the same effects** — opened/saved paths join a sidebar list that persists to the per-app data directory (`zero_native.app_dirs`, resolved once in `main`) via `fx.writeFile`, and is restored at boot by `init_fx` + `fx.readFile`.
- **Model-owned theming** — a toolbar toggle flips a refined stone/indigo palette (light and dark) derived per rebuild through `tokens_fn`; the system appearance flows in through `on_appearance` until the user overrides it.
- **Derived state, never stored** — word/line/byte counts in the status bar are computed from the live document at view time.

Selection and copy in the preview, native scrolling, and the standard edit context menus in the editor are framework defaults — no app code.

## Bundled documents

The sidebar ships four sample documents embedded from `src/samples/` (they live under `src/` because `@embedFile` is module-rooted there): a README-style welcome with a table, a full renderer tour, a spec with task lists and details blocks, and a notes page.

## Fixed capacities

Documents cap at 16 KiB (`max_document_bytes` — the view retains editor + preview text against the 64 KiB per-view widget-text budget; over-cap opens arrive cut with an explicit `.truncated` outcome, never silently), paths at 512 bytes, the recent list at 6 entries, and `<details>` expansion flags at 16 blocks.

## Tests

`zig build test` (or root `zig build test-example-markdown-viewer`) drives the real dispatch paths: open/save/save-as round-trips and recent-list persistence through the fake effect executor, link clicks spawning the browser command, details toggling via automation `widget-click`, editor edits updating the preview and derived counts, compiled/interpreter markup parity, and automation snapshot assertions over links, table cells, and task checkboxes.
