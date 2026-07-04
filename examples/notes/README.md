# notes

The daily-driver shape — folders sidebar, note list, editor — authored in markup + Zig. The whole view lives in `src/notes.zml` (compiled at comptime, hot-reloaded in dev builds); `src/model.zig` is the logic: folders and notes as model-owned tables, everything showable derived per rebuild, and persistence as one store file through the effects channel. `src/main.zig` is the wiring — shell scene, the paper/evergreen theme, the store path, and the keyboard map.

```sh
zig build run
```

## What it demonstrates

- **Derived state, never stored** — a note is just its body: the list title is the first non-empty line, the preview snippet is the collapsed text after it, and the "2m / 3h / 1w" timestamps derive from the model's `native_sdk.Clock` seam at view time (a repeating fx timer refreshes them; tests swap in a `TestClock`). Editing a note bumps its edit time, so the list re-sorts under your cursor — the daily-driver behavior, for free, because ordering is derived too.
- **Persistence through file effects with a debounced autosave** — the whole store (folders + notes, byte-counted bodies, binary-safe) serializes to one file in the per-app data directory (`native_sdk.app_dirs`). Edits re-arm a one-shot fx timer (`save_debounce_ms`), structural changes write immediately, and exactly one write is in flight at a time — a save requested mid-write re-persists on the acknowledgement. `init_fx` restores the store before the first paint; a hosts-without-timers rejection degrades to save-on-every-edit, never to silence.
- **Keyboard-first through app shortcuts** — every mutation the buttons reach is also a registered shortcut (declared in `app.zon`, delivered as command events through `on_command`): Cmd+N new note, Cmd+Shift+N new folder, Cmd+Shift+R rename, Cmd+Backspace delete, Cmd+Shift+C copy, Cmd+Opt+Up/Down to walk the list, Cmd+1…7 folder jumps, and Escape to close the dialog or clear the search. The idle editor pane renders the whole map.
- **A modal dialog in markup** — folder create/rename is a `<dialog>` stacked over the app under an `<if>`, with a scrim panel that closes on click (painted with the theme's `shadow` token — nothing else in this app casts shadows, so the token doubles as the backdrop). Validation is inline: empty and duplicate names keep the dialog up with a hint.
- **The pressable-row hotspot idiom** — hit testing resolves the deepest widget, so a panel wrapping text never sees the click. Folder and note rows use the framework's own convention (the one `timelineItem` uses): the panel is the visual, and an empty text leaf stacked over it carries the press handler, the selection state, and the row semantics.
- **Clipboard effects** — Copy pipes the note body through `fx.writeClipboard` (the platform pasteboard seam), one typed Msg with an explicit outcome.
- **Search as a pure filter** — the search field scopes the visible rows (case-insensitive, full text, across folders); the `<for>`/`<else>` empty state explains itself differently for "no notes" and "no matches".

## Fixed capacities

Folders cap at 6 (`max_folders` — the create button disables, the shortcut path reports), notes at 48 x 4 KiB bodies (`max_notes`/`max_note_bytes` — every visible row mounts real widgets, so the cap also keeps the tree far under the 1024-node per-view layout budget; an over-cap paste is clamped with a status note), search at 48 bytes, and the serialized store at ~200 KiB (`max_store_bytes`, sized so a full store always fits under the effect channel's 1 MiB bound).

## Tests

`zig build test` (or root `zig build test-example-notes`) drives the real dispatch paths: title/snippet/relative-time derivation, store round-trips (including garbage, header-only, and orphaned-note inputs), edit → debounce timer → serialized write → pending-save re-persist through the fake effect executor, boot-time restore into the widget tree, the dialog flow through automation `widget-click` (create, duplicate-name hint, rename prefill, scrim click-away, capacity), the whole shortcut map through platform shortcut events, live search filtering, folder/note row clicks through the hotspot overlays, compiled/interpreter markup parity with the dialog closed and open, theming, and three-pane layout at window size.
