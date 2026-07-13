# Native SDK soundboard-ts example

The soundboard music library authored entirely in **TypeScript + Native markup** — the launch-bar port of `examples/soundboard`. Zero Zig: the logic tier is the app-core subset under `src/`, transpiled to native at build time as one module; `src/app.native` is the whole view tier and `app.zon` the manifest plus the committed cover assets. The build detects `src/core.ts` in the tree and stages the wiring itself; no JS runtime ships in the binary.

The core is a multi-module reference split of the app-core subset's import-graph support:

- `src/core.ts` — the entry module: Model, Msg, update, subscriptions, the wiring channels, and every exported binding helper (the app's public face — markup and node both see exactly its exports).
- `src/library.ts` — the committed music catalog tables and the pure catalog/presentation helpers over them.
- `src/player.ts` — the pure playback state machine (track starts, queue advance, the launch-override stream rule); type-imports `Model` from the entry (the legal back-edge shape).
- `@native-sdk/core/text` — the SDK's byte-splice text engine, transpiled in for the search field's caret/selection/IME fidelity.

Everything the Zig soundboard's core does is here: the committed music catalog (the same `music_manifest.zon` data, flattened into rodata tables), REAL audio playback through `Cmd.audioPlay` with the engine's source cascade (prepared local file first, the hosted URL as the streaming fallback, size-verified against the manifest's per-track bytes and cached under the platform caches directory), play/pause/prev/next with album wrap, scrub-to-seek on the transport slider, the play-next queue with its context-menu entry, Copy Title onto the clipboard, live search over albums/artists/titles through the full byte-splice text engine, the duration rule (the platform player's estimate never replaces the manifest's measured total), the never-rewind rendered clock, the honest degraded states (stream notice, buffering line, and the local-only assets notice under an empty `NATIVE_SDK_MUSIC_URL_BASE`), registered album covers, the width-adaptive album grid, and the media-key fallback.

```sh
native dev                                  # run the real app
native dev --core --script dev-script.ndjson  # the core-logic loop under node - no renderer
native check                                # subset-check the core's import graph + markup + app.zon
native test -Dplatform=null                 # the hermetic suite
```

The end-to-end proof battery lives in the SDK repo (`tests/ts-core/soundboard_e2e_tests.zig`, run by `zig build test-ts-core-e2e`): it drives this example's real core and shipping markup headlessly through playback, scrub-to-seek, auto-advance, the queue, controlled scroll, the wiring channels (frame width, keys, chrome, covers, the env override), search, clipboard, record→replay, a dispatch-latency budget, the transport bar's layout across a rebuild storm, the theme accent, and the quiet-tile hover posture. An env-gated `PARITY_SHOTS` test in the same suite renders the side-by-side proof states (grid, album detail, songs at two widths) through the deterministic reference renderer for pixel comparison against the Zig original.

## The wiring channels this port uses

The generated wiring detects each channel from an export in `core.ts` (export exists → wired) or from `app.zon`:

- **`frameMsg(model, frame)`** — presented-frame widths land in the model, and `gridColumns` re-derives the Zig original's width→columns rule (232pt tile floor, 24pt padding, 12pt gap) on every rebuild. The core returns `null` for same-width frames, so the idle law holds.
- **`keyMsg(key)`** — the app-level key fallback: Space toggles the transport, the left/right arrows are previous/next track. The runtime's precedence rule applies first, so the search field keeps typing and a focused slider keeps its arrows.
- **`envMsgs`** — `NATIVE_SDK_MUSIC_URL_BASE` arrives as one journaled Msg at install: a non-empty base replaces the stream host wholesale, an empty base means local-only (a failed play then shows the "assets not prepared" notice, the Zig original's launch split). The core itself never reads the environment; replay carries the recorded value.
- **`app.zon .assets.images`** — the committed covers register on the installing frame with id = album id, the `ImageId` the markup avatar bindings reference. The art is JPEG: live hosts decode it through the platform codec; the null test platform's strict PNG-subset decoder refuses it honestly and every cover degrades to initials (which the suite pins).
- **`chromeMsg`** — window-chrome geometry (the tall hidden-inset titlebar app.zon declares) lands before the first view build: the markup header IS the titlebar — the drag surface, a leading spacer sized to the traffic lights, height matched to the band so its controls share the lights' centerline (the Zig original's treatment).
- **`app.zon .theme` + `.theme_accent`** — the geist pack under the Zig original's pink accent identity (`#df2670`, theme.zig's pink_800): the wiring layers `canvas.accentOverrides` over the pack — accent + white knockout ink, the focus ring, the seek slider's filled range — and high-contrast requests skip it (accessibility beats brand), the original's tokens_fn rule through the manifest.

## Where this port still deliberately differs from the Zig soundboard

Every remaining divergence is a decided posture, listed here on purpose. The former titlebar, grid-spacing, hover-wash, selected-row, and accent rows are CLOSED: the port now adopts the original's hidden-inset titlebar through the chromeMsg channel, sizes the album rack with the original's exact width rule, keeps image-forward tiles quiet on hover (`quiet-hover`), wears the inverted accent register on the loaded row, and takes the original's pink accent through `app.zon`'s `theme_accent`.

- **No volume control — resolved for 1:1, decision flagged.** The Zig original ships no volume UI, so the port's stepper (model state, Msg arms, the player-module ladder) was REMOVED in one revertable commit; the engine's `audioSetVolume` verb stays proven by the SDK repo's host e2e fixture. FLAG: the other resolution — adding volume to the Zig original instead — reverts that one commit and restores a proven implementation.
- **The rendered clock ticks at 250ms, not per frame.** Decided: the declarative `Sub.timer` that exists exactly while audio moves is the TS-idiomatic clock (the same motion gating as the original's `on_frame` clock, corrected by the player's position events under the same never-rewind rule). The frame channel is wired for the grid's width, but a per-frame clock arm would trade the idle-law simplicity of the timer for imperceptible smoothness on a text clock.
- **Press plays.** Decided: markup has no double-press event (`on_double_press` is a Zig-builder channel), so track rows follow the touch convention — one press plays — instead of the desktop select-then-double-click pair. The arrow-key selection register goes with it; since the original's play gesture also selects, the LOADED row wears the same inverted accent register in both apps, and the two are visually 1:1 after any play.
- **Cover corners: 8/10pt vs the radius tokens' 6pt.** The original rounds tile covers at 8pt and the detail cover at 10pt through numeric builder radii; markup's `radius` attribute deliberately takes radius TOKENS only, and the geist pack's sm/md/lg all resolve to 6pt. Kept on the token discipline for now — a per-value radius (or richer style-token bindings) is the flagged follow-up; the pixel cost is a 2–4pt corner difference on cover art.
- **The bar's listening mark is the built-in `music` icon, not `app:waveform`.** The original registers its own waveform SVG through Zig (`registerAppIcons`); the generated wiring has no app-icon manifest channel yet — the flagged follow-up (an `app.zon` icons surface beside `.assets.images`).
- **Copy Title is fire-and-forget.** `Cmd.clipboardWrite` has no result routing, so the model counts requests, not confirmed copies.
- **Desktop only.** TypeScript cores build desktop apps today; the compact phone shell is the Zig original's.
