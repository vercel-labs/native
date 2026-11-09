# feed

The infinite-scroll timeline — the VARIABLE-extent windowed virtual list proof. A 100,000-post synthetic corpus of MIXED-HEIGHT posts (every post derives deterministically from its index; no network, no storage) scrolls through one `<virtual-list>`, and the view only ever builds the rows on screen.

```sh
native dev
```

## What it demonstrates

- **The variable-extent windowed virtual list** — rows size to their wrapped bodies (one-liners, multi-sentence takes, the occasional long-form wall). The TypeScript core provides `postExtentEstimate` (body byte count over an assumed line width) and `timelineRows(model, range)`. Markup declares a `<virtual-window>` and a keyed `<virtual-list>`; the runtime supplies the complete retained range, and the query builds only those rows. The engine measures the rows it mounts and corrects its offset table, anchored on the first visible row — the scrollbar converges toward measured truth as you ride, and visible content never jumps. Widget-node cost is the window plus overscan — a dozen-odd rows — never the dataset; the automation snapshot's `widget_nodes=` telemetry proves it at the full corpus.
- **The runtime owns the scroll** — no `on_scroll` binding anywhere: wheel, kinetic, and keyboard scrolling apply engine-side, the native scroll driver takes over on macOS (its content size tracking the converging extent), and each scroll observation re-derives the view so the window follows the offset. The scrollbar spans the full virtual extent — millions of points at 100k mixed-height posts — and tells the best truth it has.
- **Infinite fetch through `on-reach-end`** — approaching the end of the loaded posts dispatches one `load_more` Msg (hysteresis built in: fire within one viewport of the end, re-arm past one and a half — which the appended batch causes on its own by growing the extent), and `update` appends the next 500 posts toward the 100k cap. No timers, no polling, no fetch storms.
- **Identity outlives the window** — every row is keyed by its post index, so its structural id is the same whenever it windows in; per-post state (likes, boosts, the selected row) lives in the model keyed by that same index. Like a post, scroll a hundred rows away, scroll back: same id, same wash, count still bumped.
- **A deterministic corpus** — `postAt(index)` hashes the index into author/handle/body/counts, so tests assert on exact content at post 90,000 without fixtures, and every platform renders the same timeline.
- **House flat rows** — avatar initials, bold author line, a wrapped multi-line body sized by its content, muted action chips from the built-in icon set, stock design tokens re-derived from the OS appearance. No cards, no borders, no brand marks.

## Fixed capacities

The corpus caps at 100,000 posts ; the model boots with 500 and appends 500 per reach-end fetch. Rows are as tall as their wrapped bodies — most posts run one to three sentences, every 13th is a longer take, every 47th a long-form wall (`postBodySentences`) — with 4 rows of overscan on each side. The engine's measured-correction store is budgeted per list; posts beyond it drift back to their estimates until revisited. Per-post interaction state is two 100k bitsets (~25 KB of model), keyed by post index.

## Tests

`native test` drives the shipped compiled app through interaction, viewport changes, and sealed replay. `zig build test-ts-feed-e2e` from the SDK root compares complete models, bitset padding, restored counters, exact high-index corpus content, widget trees and layout across the native reference, interpreted markup, compiled markup, and compiled TypeScript view. It also records and replays scroll/action journals with complete snapshots and checkpoints. The original native tests live beside the reference in `tests/ts-core`; the example ships only `src/core.ts`, `src/corpus.ts`, and `src/app.native`.
