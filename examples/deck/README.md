# Native SDK deck example

The radical sibling of `examples/soundboard`: the **same conceptual app** — a local music library with albums, tracks, transport, seek, queue, and search — wearing a completely different product identity. Soundboard is the clean, shadcn-derived catalog; deck is a piece of rack-mount audio hardware. Same domain, same runtime, same widget engine and token system — a different product. That contrast is the demo: "Beautiful by default. Customizable by design."

## Design brief

**Identity.** A 2U rack-unit digital deck in the Winamp lineage: dense, pixel-tight chrome; a black anodized chassis; one glowing phosphor readout; controls machined into the faceplate instead of floating on cards. Everything on screen should read as *hardware* — plates, hairlines, engraved labels — not as a document.

**Palette.** Chassis blacks stepped by machining depth (`#090B0A` case, `#0F1311` faceplate, `#161C19` raised plates), steel hairline borders (`#263029`), and a single dominant hue: phosphor green `#36E28A` for everything *live* — the VFD readout, the spectrum, the playing row, the filled seek range. Dim phosphor `#687C70` for idle/engraved labels. Signal amber `#F5B942` is reserved for the queue (the one "pending" state). No shadows, no blur: light in this product comes from emission, not elevation.

**Type.** Mono-first. Every readout — timecode, track numbers, durations, band captions, status counts — is the mono face; sans survives only on button plates and track titles. Small and tight: body 12, labels 11, compact density. Engraved captions are uppercase mono at reduced scale ("SPECTRUM // 32 BAND").

**Chrome language: full Winamp-era maximalism.** This skin exists to show the extreme the token system plus the sanctioned chrome pass can reach — ornament over restraint, density over whitespace, a physical device rather than a web page. The `UiApp.chrome` display-list pass (the same seam gpu-dashboard uses for one hero gradient) draws a sculpted hardware layer in two fixed-count halves: behind the widgets, a brushed chassis texture (170 vertical hairlines), the machined faceplate gradient capped by a gold band, a gold brand plate with "D E C K" engraved dark into it, raised outer bevels, a ridged grip band, corner screws with slots and catch-lights, and recessed wells behind the transport cluster and the output block; in front of the widgets, inset bevel frames around every glass, CRT scanlines across the VFD, the spectrum, and the PERF analyzer, a diagonal glare wash, raised bevel edges on the three chunky transport keys, the status-strip ridge with its own screws — and a seven-segment elapsed readout drawn as sheared hexagon paths, ghost segments always faintly lit (VFD ghosting) and live segments doubled with a translucent glow stroke. Captions are letter-spaced mono caps (the bitmap-face feel, honestly). The spectrum analyzer — phosphor bars plus a paper-white peak trace — is a real `ui.chart` widget driven by the playback clock: not a texture, not a GIF; golden-testable pixels, scanlined by the chrome like everything else on the glass.

**Control vs. readout.** The VFD carries the authoritative playback readout (timecode + a phosphor progress strip); the long-travel fader below it is the seek *control*. That split is honest engine design, not decoration: slider positions are runtime-owned between rebuilds (the engine's reconcile rule — a scrubber that was also the model-driven readout would fight the user's hand), so the fader is re-keyed per track and snaps home on every load while the strip tracks the clock.

**Dark-only, by the brief.** Hardware faceplates do not have a light mode; the OS appearance changes nothing here. Accessibility still beats brand: a high-contrast request abandons the widget skin for the framework's high-contrast dark palette and strips the chrome pass to structure (textures, gold, glare, and scanlines go transparent; bevels fall back to the border token; the segment readout switches to the high-contrast text color) — same command counts, honest contrast. Reduce-motion zeroes the motion tokens.

**Two faces.** `LIB` is the working layout — faceplate up top, album rail + track ledger below. `PERF` collapses the library into a full-width analyzer (the "show" face), the deck equivalent of a mini/party mode.

## Same app, different identity

Deck deliberately shares soundboard's domain: the same fictional 48-track/8-album library, the same honest playback simulation (a repeating runtime timer effect advances the progress clock; no audio is decoded), the same queue/search/seek/transport model shapes, the same context-menu `pbcopy` effect. Set the two side by side and every difference you see is *skin*: design tokens (palette, radii, typography, density, per-control visual tokens) plus custom-drawn chrome through the sanctioned view APIs. No engine fork, no private renderer hooks.

## Authoring split

- `src/statusbar.zml` — the bottom status strip (search field, match counter, queue badge, LIB/PERF toggle), compiled at comptime; the test suite also runs it through the runtime interpreter and asserts engine parity.
- `src/view.zig` — the Zig-only chrome: the faceplate (brand plate, VFD glass readout with mono paragraph spans, transport cluster, output block), the `ui.chart` spectrum analyzer, the album rail, the dense track ledger with per-row native context menus, and the PERF layout.
- `src/model.zig` — the library data, playback/queue/search/view state, the deterministic spectrum function, and `update`.
- `src/chrome.zig` — the sculpted hardware layer, drawn through the `UiApp.chrome` display-list pass in two exact-count halves (prefix behind the widgets, suffix in front). The counts are module constants; the suite rebuilds the chrome across model states (idle, playing, PERF, high contrast) and holds them, because the runtime rejects a build that misses its declared count.
- `src/theme.zig` — the widget skin: a dark-only token set (palette, 1–3px radii, mono-heavy typography, compact density) plus per-control visual tokens (`controls.*`) that restyle buttons, toggle chips, the search field, the slider, and the scrollbar without touching any widget code.
- `src/main.zig` — app wiring: shell scene, shortcut command map, tokens fn, the slider sync hook.

## The spectrum is honest

Playback is simulated (soundboard's contract), so the analyzer visualizes the *simulation*: a pure function of (track id, elapsed ms) produces 32 band levels — sum-of-sines shaped by a per-track seed and a mid-weighted envelope. Deterministic by construction: the same model state always yields the same bars (the suite asserts it), pausing freezes the bars because the progress clock stops, and an idle deck shows the noise floor. The bands render as one `.chart` widget — a phosphor bar series plus a paper-white peak-trace line — so the visualization rethemes, invalidates, and screenshots like every other widget.

## Keyboard

Registered app shortcuts (`app.zon`, delivered as command events): `primary+P` play/pause, `primary+←`/`primary+→` previous/next, `primary+K` toggle LIB/PERF, `Escape` clears the search. The seek slider takes arrow-key steps when focused (the widget keyboard path).

## Fixed capacities

- 8 albums x 6 tracks (comptime library data, shared fiction with soundboard).
- 16-entry play-next queue; a full queue drops the request and counts it.
- 48-byte search buffer.
- 32 spectrum bands (one `.chart` widget, well under the per-series point budget).
- Two context-menu items per ledger row: 48 rows x 2 = 96 of the 128-item per-view budget.
- Widget tree peaks under 512 nodes of the 1024 per-view budget (full ledger).

## Run

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the deterministic suite (transport/queue/search dispatch through the fake effects executor, spectrum determinism, engine parity, theming, layout budgets, automation click-through):

```sh
zig build test -Dplatform=null
```

Verify live through the automation harness:

```sh
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/deck &
native automate assert 'gpu_nonblank=true' 'role=button name="Play or pause"' 'role=listitem name="First Light"'
```
