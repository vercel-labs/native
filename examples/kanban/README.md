# Native SDK Kanban (TypeScript)

This three-column board is authored entirely in TypeScript + Native markup. `src/core.ts` is the model/update tier, `src/app.native` is the view, and `app.zon` is the desktop shell; no JavaScript runtime or app-owned Zig ships in the binary.

Drop one or more files anywhere on the board to add their basenames as Todo cards. The desktop host sends the native file-drop event through the runtime, and the core's `dropMsg` maps the full path list into one deterministic `files_dropped` message before `update` changes the board.

To manually verify the real macOS host path (the guest-VM harness cannot synthesize an AppKit drag session yet):

1. Run `native dev` on macOS.
2. Drag a file from Finder onto a visible card in the canvas, not the titlebar.
3. Verify a new Todo card appears with the dropped file's basename.
4. Repeat over empty board space; the app-level drop still works there.

The first drop traverses the labeled `kanban-canvas` destination with a view-local, top-left-origin point before the app-level `dropMsg` runs. That is the same host data widget `drop_files` hit-testing consumes; the second verifies the ordinary canvas-level fallback remains intact.

Drag any card within a column or across Todo, Doing, and Done. The card itself lifts under the pointer at full opacity, leaving one blank, card-sized slot behind. As the pointer reaches another candidate position, that same reserved slot moves from the source to the candidate and neighboring cards glide around it—there are never two spaces for one card. On release, the same floating card eases from the pointer into the slot. Press Escape during a drag to cancel it and carry the card back to its source slot. Cards can move forwards, backwards, or directly across the board.

Each card represents an agent-owned ticket: the title sits above a compact metadata row with a Jira/Linear-style issue key and the assigned OpenAI or Claude avatar. The avatar artwork is rasterized from SVGL's [OpenAI](https://svgl.app/library/openai.svg) and [Claude AI](https://svgl.app/library/claude-ai-icon.svg) SVGs so it can travel through the app manifest's static image channel.

```sh
native dev
native check
native test -Dplatform=null
```

The example also demonstrates the `chromeMsg` hidden-titlebar channel, derived array helpers that project the single reserved slot without mutating committed cards, immutable reordering, and `global-key` identity across parent changes.

The SDK repository's `tests/ts-core/kanban_e2e_tests.zig` compiles this real core and shipping markup, drives a multi-file platform drop headlessly, verifies the live insertion reflow before release, and reorders cards within and across columns while proving identity is preserved.
