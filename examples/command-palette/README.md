# Native SDK command-palette example

The keyboard-shortcuts docs use `command.palette` as their example shortcut id and call `openCommandPalette()` in their JavaScript snippet. This app is that example, implemented: a task list where every action is a palette command.

- **Cmd+Shift+P** (the docs' exact binding) toggles the palette; Escape and a click on the scrim close it.
- **Type to filter** across static commands and the per-task "Complete:" commands — the rows are DERIVED from app data, which is the point of a palette.
- **Plain ArrowUp/Down move the selection while you type.** No runtime changes and no app-level key fallback: a single-line field maps unmodified vertical arrows to caret start/end jumps, and the edit-derivation seam stamps that edit onto the dispatched event — so `on-input` hears `move_caret` and the core reinterprets it as list navigation (see `palette_edit` in `src/core.ts`). Unmodified Home/End alias to the same jumps and also navigate; shift-extended selections stay text edits.
- **Enter runs the selected command**; the selection stays visible — the scroll offset is model-owned and follows it.

Run it (macOS):

```sh
native dev
```

Drive it through the automation harness:

```sh
native build -Dautomation=true && ./zig-out/bin/command-palette &
native automate shortcut command.palette
native automate widget-key main-canvas arrowdown
native automate widget-key main-canvas enter
```

Known gap vs the web's cmdk: selection changes are visual (the row wash) — there is no activedescendant-style announcement for screen readers while focus stays in the query field.
