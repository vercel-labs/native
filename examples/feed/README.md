# feed

The infinite-scroll timeline — the VARIABLE-extent windowed virtual list proof. A 100,000-post synthetic corpus of MIXED-HEIGHT posts (every post derives deterministically from its index; no network, no storage) scrolls through one `ui.virtualList`, and the view only ever builds the rows on screen.

```sh
native dev
```

## What it demonstrates

- **The variable-extent windowed virtual list** — rows size to their wrapped bodies (one-liners, multi-sentence takes, the occasional long-form wall). The view provides a cheap per-post extent ESTIMATE (`postExtentEstimate`: body byte count over an assumed line width — rough on purpose), asks `ui.virtualWindow` which item range is visible, builds ONLY those rows, and hands both to `ui.virtualList`. The engine measures the rows it mounts and corrects its offset table, anchored on the first visible row — the scrollbar converges toward measured truth as you ride, and visible content never jumps. Widget-node cost is the window plus overscan — a dozen-odd rows — never the dataset; the automation snapshot's `widget_nodes=` telemetry proves it at the full corpus.
- **The runtime owns the scroll** — no `on_scroll` binding anywhere: wheel, kinetic, and keyboard scrolling apply engine-side, the native scroll driver takes over on macOS (its content size tracking the converging extent), and each scroll observation re-derives the view so the window follows the offset. The scrollbar spans the full virtual extent — millions of points at 100k mixed-height posts — and tells the best truth it has.
- **Infinite fetch through `on_reach_end`** — approaching the end of the loaded posts dispatches one `load_more` Msg (hysteresis built in: fire within one viewport of the end, re-arm past one and a half — which the appended batch causes on its own by growing the extent), and `update` appends the next 500 posts toward the 100k cap. No timers, no polling, no fetch storms.
- **Identity outlives the window** — every row is keyed by its post index, so its structural id is the same whenever it windows in; per-post state (likes, boosts, the selected row) lives in the model keyed by that same index. Like a post, scroll a hundred rows away, scroll back: same id, same wash, count still bumped.
- **A deterministic corpus** — `postAt(index)` hashes the index into author/handle/body/counts, so tests assert on exact content at post 90,000 without fixtures, and every platform renders the same timeline.
- **House flat rows** — avatar initials, bold author line, a wrapped multi-line body sized by its content, muted action chips from the built-in icon set, stock design tokens re-derived from the OS appearance. No cards, no borders, no brand marks.

## Fixed capacities

The corpus caps at 100,000 posts (`max_posts`); the model boots with 500 (`initial_batch`) and appends 500 per reach-end fetch (`fetch_batch`). Rows are as tall as their wrapped bodies — most posts run one to three sentences, every 13th is a longer take, every 47th a long-form wall (`postBodySentences`) — with 4 rows of overscan on each side. The engine's measured-correction store is budgeted per list; posts beyond it drift back to their estimates until revisited. Per-post interaction state is two 100k bitsets (~25 KB of model), keyed by post index.

## Tests

`native test` (or root `zig build test-example-feed`) drives the real dispatch paths: deterministic post derivation and body pricing, batch appends against the corpus cap, window-only tree builds with stable row identity across shifts, wheel scrolling through the runtime with the view re-windowing (no scroll Msg bound), like-state surviving a scroll away and back under the same structural id, reach-end firing once per approach through real dispatch, a scroll-storm test proving measured corrections never move the rows on screen, and snapshot telemetry showing `widget_nodes` viewport-sized at 100k posts while the scroll semantics span the corpus.
