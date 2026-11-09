# markdown-viewer

A split-pane markdown editor/preview authored in TypeScript + Native markup: the left pane is a `textarea` mirrored elm-style into the model, the right pane is one `<markdown>` element bound to the same bytes, so the preview tracks every keystroke with no debounce and no drift. The whole view lives in `src/app.native` (hot-reloaded in dev builds); `src/core.ts` owns the model, messages, effects, and view helpers; `src/state.ts` owns deterministic editing, document, recents, and image transitions. scriptc compiles the core and markup to native code. `src/theme.ts` supplies the two-mode custom palette.

```sh
native dev
```

## What it demonstrates

- **`<markdown>` in markup** — headings on the span scale, inline styles, a safe GitHub-style presentational HTML subset, clickable links (pointer cursor; opened in the system browser through `Cmd.spawnEvents`), first-line-aligned list markers, fenced code lowered through the reusable `code` component with preserved indentation and language-tag syntax highlighting (including JSX/TSX-aware tags and attributes), blockquotes, GFM tables with column alignment, remote table images loaded through the bounded `Cmd.imageLoadWords` effect and passed back as model-owned mappings, and `<details>` blocks whose expansion flags live in the model (`details_expanded: readonly boolean[]`), toggled in `update`.
- **Real file I/O without native dialogs** — the Native SDK has no file-dialog service, so this app uses the honest pattern: an editable path field in the toolbar. **Open** reads it (`Cmd.readFileResult`), **Save** writes the editor back to the current document, **Save As** writes to whatever the field says and adopts it. Every result is one typed Msg with an explicit outcome; failures land in the status bar, never a dialog.
- **Recent files persisted through the same effects** — opened/saved paths join a sidebar list that persists to the per-app data directory through the legacy app-data environment channel and `Cmd.writeFileResult`, and is restored at boot with `Cmd.readFileResult`. These commands use `replace: false` to retain the native duplicate-request behavior.
- **System appearance, followed live** — a refined stone/indigo palette (light and dark) derives per rebuild through `tokenOverrides` from the scheme the `appearance` message delivers, so flipping the OS between light and dark re-themes the window immediately; there is no in-window theme control by design.
- **Controlled scrolling** — the preview's scroll offset is model-owned: `on-scroll` stores the applied offset, the `value` binding echoes it back, so rebuilds (every keystroke re-renders the preview) never lose the reading position.
- **Derived state, never stored** — word/line/byte counts in the status bar are computed from the live document at view time.

Selection and copy in the preview, native scrolling, and the standard edit context menus in the editor are framework defaults — no app code.

## Bundled documents

The sidebar ships four sample documents as exact UTF-8 literals in `src/samples.ts`, with their readable Markdown originals retained under `src/samples/`: a README-style welcome with a table, a full renderer tour, a spec with task lists and details blocks, and a notes page.

## Fixed capacities

Documents cap at 16 KiB (`documentCapacity` — the view retains editor + preview text against the 64 KiB per-view widget-text budget; over-cap opens arrive cut with an explicit `.truncated` outcome, never silently), paths at 512 bytes, the recent list at 6 entries, and `<details>` expansion flags at 16 blocks.

## Tests

`native test` (or root `zig build test-example-markdown-viewer`) drives the compiled app and complete replay snapshots. Root `zig build test-ts-markdown-viewer-e2e` compares the full model, effect requests, native and compiled widget trees, and layout against the independent native reference, retaining its original 18 tests. Together these suites cover the real dispatch paths: open/save/save-as round-trips and recent-list persistence through the fake effect executor, link clicks spawning the browser command, details toggling via automation `widget-click`, editor edits updating the preview and derived counts, the system appearance re-deriving the tokens live through platform events, the controlled preview scroll round-trip, compiled/interpreter markup parity, and automation snapshot assertions over links, table cells, and task checkboxes.

Image identities use two unsigned 32-bit words, preserving the original native 63-bit Wyhash values exactly. The runtime owns decoded pixels, image registration, OS file operations, and browser processes. The core discovers sources, retains successful mappings, cancels removed loads, and releases orphaned registrations.
