# feed

The infinite-scroll timeline — the windowed virtual list proof. A 100,000-post synthetic corpus (every post derives deterministically from its index; no network, no storage) scrolls through one `ui.virtualList`, and the view only ever builds the rows on screen.

```sh
native dev
```

## What it demonstrates

- **The windowed virtual list** — the view asks `ui.virtualWindow` which item range is visible (the runtime owns the viewport math: retained scroll offset + viewport → index range, fixed 84pt rows so 100k of them are pure arithmetic), builds ONLY those rows from the model, and hands both to `ui.virtualList`. Widget-node cost is the window plus overscan — a dozen-odd rows — never the dataset; the automation snapshot's `widget_nodes=` telemetry proves it at the full corpus.
- **The runtime owns the scroll** — no `on_scroll` binding anywhere: wheel, kinetic, and keyboard scrolling apply engine-side, the native scroll driver takes over on macOS, and each scroll observation re-derives the view so the window follows the offset. The scrollbar spans the full virtual extent (8.4M points at 100k posts) — it always tells the truth.
- **Infinite fetch through `on_reach_end`** — approaching the end of the loaded posts dispatches one `load_more` Msg (hysteresis built in: fire within one viewport of the end, re-arm past one and a half — which the appended batch causes on its own by growing the extent), and `update` appends the next 500 posts toward the 100k cap. No timers, no polling, no fetch storms.
- **Identity outlives the window** — every row is keyed by its post index, so its structural id is the same whenever it windows in; per-post state (likes, boosts, the selected row) lives in the model keyed by that same index. Like a post, scroll a hundred rows away, scroll back: same id, same wash, count still bumped.
- **A deterministic corpus** — `postAt(index)` hashes the index into author/handle/body/counts, so tests assert on exact content at post 90,000 without fixtures, and every platform renders the same timeline.
- **House flat rows** — avatar initials, bold author line, single-line body (`wrap = false`, the honest one-line contract), muted action chips from the built-in icon set, stock design tokens re-derived from the OS appearance. No cards, no borders, no brand marks.

## Fixed capacities

The corpus caps at 100,000 posts (`max_posts`); the model boots with 500 (`initial_batch`) and appends 500 per reach-end fetch (`fetch_batch`). Rows are a fixed 84 points (`post_row_extent`) — the windowed virtual list's v1 contract is uniform row extents — with 4 rows of overscan on each side. Per-post interaction state is two 100k bitsets (~25 KB of model), keyed by post index.

## Tests

`native test` (or root `zig build test-example-feed`) drives the real dispatch paths: deterministic post derivation, batch appends against the corpus cap, window-only tree builds with stable row identity across shifts, wheel scrolling through the runtime with the view re-windowing (no scroll Msg bound), like-state surviving a scroll away and back under the same structural id, reach-end firing once per approach through real dispatch, and snapshot telemetry showing `widget_nodes` viewport-sized at 100k posts while the scroll semantics report the full extent.
