# Native SDK split-collapse example

The smallest honest pane-collapse animation harness: a two-pane split whose sidebar collapses and expands over 180 ms, built to measure frame pacing during a layout tween and to demonstrate the runtime layout-tween primitive against the manual idiom it replaces.

Three driving modes, selected by environment variable:

- Default (runtime tween): `layoutTweens(model)` in `src/core.ts` declares the split's target fraction and the runtime eases the rendered fraction toward it, one step per presented frame. No per-frame messages are needed, and reduced-motion appearances snap.
- `SPLIT_COLLAPSE_MARKUP=1` (markup tween): the same primitive declared in `src/app.native`. The split's model-derived `resize-duration` becomes 180 ms, and its bound `value` becomes the resting target.
- `SPLIT_COLLAPSE_MANUAL=1` (manual ticks): `frameMsg` returns a tick carrying the exact presented nanosecond timestamp; `update` eases the fraction, and every tick rebuilds the view. Markup mode takes precedence when both variables are enabled.

Every tween step logs its arrival cadence on stderr (`tween-frame dt_ms=...` in manual mode, `tween-echo fraction=...` in the runtime and markup modes), so a driver can count the visible steps of the 180 ms collapse and read the real deltas between frames.

Extra knobs:

- `SPLIT_COLLAPSE_AUTO_MS=<interval>` arms a repeating auto-toggle so the tween runs without automation. Parsing preserves the native unsigned 64-bit syntax; intervals that cannot convert to nanoseconds receive the timer's rejected terminal.
- `SPLIT_COLLAPSE_WEB=1` snaps a live webview to the content pane, so the tween reflows real web content beside the collapsing sidebar.

Run with the macOS system backend:

```sh
native dev
```

Run the compiled app tests headless:

```sh
native test -Dplatform=null
```
