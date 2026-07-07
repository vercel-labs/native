# Native SDK deck example

The radical sibling of `examples/soundboard`: the **same app** — the same committed music catalog with albums, tracks, transport, seek, queue, and search — wearing a completely different product identity. Soundboard is the clean house-catalog look; deck is a piece of rack-mount audio hardware. Same catalog, same audio files, same runtime, same widget engine and token system — a different product. That contrast is the demo: "Beautiful by default. Customizable by design."

## Design brief (v2: the true two-window shape)

**Identity.** A desktop audio deck in the classic hardware-player lineage, and its classic two-window *shape*: a **small, fixed-size player** (460x180, `resizable = false`) that IS the device — dense chrome, a hidden-inset titlebar whose gold cap band is the drag region — plus a **matching playlist rack unit** in its own window (460x440), racked in and out by the chunky `PL` key or `primary+L`. No library in the player; no transport in the playlist. Everything on screen should read as *hardware* — plates, hairlines, engraved labels — not as a document.

**Palette.** Chassis blacks stepped by machining depth (`#090B0A` case, `#0F1311` faceplate, `#161C19` raised plates), steel hairline borders (`#263029`), and a single dominant hue: phosphor green `#36E28A` for everything *live* — the VFD readout, the spectrum, the playing row, the filled seek range. Dim phosphor `#687C70` for idle/engraved labels. Signal amber `#F5B942` is reserved for the queue (the one "pending" state). No shadows, no blur: light in this product comes from emission, not elevation.

**Type.** Mono-first. Every readout — timecode, track numbers, durations, band captions, status counts — is the mono face; sans survives only on button plates and track titles. Small and tight: body 12, labels 11, compact density. Engraved captions are uppercase mono at reduced scale ("SPECTRUM//32").

**The player (main window).** Fixed 460x180 in the classic main-window proportions. Top to bottom: the gold cap band (drag region; the traffic lights sit ON the gold like machine screws, cleared by the live `on_chrome` inset), the VFD glass (chrome-drawn seven-segment elapsed readout, the rotating **title marquee**, a `TRK NN` + timecode echo line, and the phosphor progress strip), the spectrum glass (a real chart — a markup `<chart>` with 32 phosphor bars plus a paper-white peak trace), the long-travel seek fader, and the transport row (prev/play/next keys in a recessed well, VOL fader + output meter in a second well, the amber queue badge, and the `PL` key).

**The marquee is honest.** The scroller is a pure function of (track id, elapsed ms): the composed `TITLE /// ARTIST /// ALBUM` line rotates one character per half-second of *playback* time, so pausing freezes it exactly like the spectrum (the clock stops) and the same model state always yields the same window of text. The suite asserts the rotation, the freeze, and the wrap.

**The playlist rack (second window).** A model-declared window (`UiApp.windows_fn` + `window_view`): PRESENCE in the declared set is visibility, so the `PL` key just flips `playlist_open` and the runtime reconciles — a user's titlebar close dispatches `.playlist_closed` and the model agrees. Inside: ONE flat song list — the dense track ledger over the whole library (pressable rows, per-row native context menus: Play Next / Copy Title), the bottom deck strip (the loaded record's sleeve window plus the amber up-next cues), and the markup status strip (search field, queue badge, match counter). No album rail, no sub-collections: the rack is a list of songs, and search narrows it. Fixed 460x440, hidden-inset titlebar with its own cap strip as the drag region.

**Chrome language: classic hardware-player-era maximalism over real texture.** The `UiApp.chrome` display-list pass draws the sculpted hardware layer in two fixed-count halves. Behind the widgets: the chassis fill, the **AI-generated brushed-plate texture** (one `draw_image` of a registered 256x256 asset at 0.5 opacity — real grain where v1 faked 170 hairline strokes), the machined faceplate gradient, the gold cap band, the window's outer bevel, a ridged grip band, four corner screws, and recessed wells behind the transport cluster and the output block. In front: inset bevel frames around the VFD, spectrum, and seek glass, CRT scanlines, a diagonal glare wash, raised bevels on the four keys, and the seven-segment readout drawn as sheared hexagon paths — ghost segments always faintly lit (VFD ghosting), live segments doubled with a translucent glow stroke. Textures support the chassis feel; the machining stays vector.

**Control vs. readout.** The VFD carries the authoritative playback readout (segment digits + timecode + the phosphor progress strip); the long-travel fader below the glass is the seek *control*. That split is honest engine design, not decoration: slider positions are runtime-owned between rebuilds (the engine's reconcile rule — a scrubber that was also the model-driven readout would fight the user's hand), so the fader is re-keyed per track and snaps home on every load while the strip tracks the clock.

**Dark-only, by the brief.** Hardware faceplates do not have a light mode; the OS appearance changes nothing here. Accessibility still beats brand: a high-contrast request abandons the widget skin for the framework's high-contrast dark palette and strips the chrome pass to structure (the texture moves offscreen; gold, glare, and scanlines go transparent; bevels fall back to the border token; the segment readout switches to the high-contrast text color) — same command counts, honest contrast. Reduce-motion zeroes the motion tokens.

## Texture assets

Two small committed textures (256x256, ~256KB pixel budget each, well inside the 16-slot/1MB registry bounds), generated with `gpt-image-2`, toned with ImageMagick, and packed into the strict PNG subset (`tools/pack_textures.zig` mirrors `canvas.png.writeRgba8` byte for byte) so they decode both live (CGImageSource) and under the deterministic test decoder. `init_fx` registers them through `fx.registerImageBytes`; a failed decode leaves the id 0 and presentation degrades to pure vector (the suite covers the codec-less path).

- `src/textures/plate.png` — under the player's chrome pass (one `draw_image`, 0.5 opacity). Prompt: *"Seamless tileable texture of dark brushed metal, black anodized aluminum faceplate, very fine horizontal brushing grain, extremely subtle, desaturated, near-black charcoal tones, no logos, no text, no scratches, uniform lighting, flat, photographic macro texture"*
- `src/textures/weave.png` — the playlist rack's backdrop (an `image` leaf under the content; secondary windows have no chrome pass). Prompt: *"Seamless tileable texture of very fine dark carbon fiber weave, micro twill pattern, near-black desaturated grey-green tint, extremely subtle low-contrast, no highlights, no logos, no text, uniform flat lighting, photographic macro texture"*

Regeneration (see `tools/pack_textures.zig` for the exact pipeline):

```sh
ai image -m openai/gpt-image-2 --size 1024x1024 -o /tmp/plate-raw.png "<prompt>"
magick /tmp/plate-raw.png -resize 256x256 -modulate 100,30,100 -brightness-contrast -8x0 /tmp/plate.png   # weave: -modulate 100,45,100 -brightness-contrast -10x0
magick /tmp/plate.png -depth 8 rgba:/tmp/plate.rgba
zig run tools/pack_textures.zig -- /tmp/plate.rgba 256 256 src/textures/plate.png
```

## Same app, different identity

Deck deliberately shares soundboard's domain, and now its *data*: the same committed catalog (`src/music_manifest.zon`, byte-identical to the soundboard's, generated by `tools/prepare-example-music.sh`), the same on-disk audio (the mp3s live once, in `examples/soundboard/assets/music/` — gitignored; the deck plays them by relative path), the same queue/search/seek/transport model shapes, the same context-menu `pbcopy` effect. Set the two side by side and every difference you see is *skin plus window shape*: design tokens, custom-drawn chrome, and a model-declared second window — all through the sanctioned view APIs. No engine fork, no private renderer hooks.

## Real playback

Pressing play issues `fx.playAudio` on the runtime's audio effect channel — on macOS that is the platform's real player, so the deck plays actual audio. Every report arrives as a typed Msg through the ordinary update path: the `loaded` acknowledgment carries the decoded duration (the manifest value is the display default until then), `position` ticks advance the progress clock (~500ms cadence, only while playing), one `completed` fires at natural end (the play-next queue wins over album order), and `failed` reports a missing file or a platform without audio playback. The VOL fader rides `fx.setAudioVolume`, the long-travel fader seeks through `fx.seekAudio`, and pause holds the platform player in place.

**The NO MEDIA state is honest.** The audio files are gitignored: on a machine that never ran the prepare script, the first play lands one `failed` event and the deck clears to an unmistakable degraded state — the VFD marquee stamps `NO MEDIA` in signal amber and the channel line reads `RUN TOOLS/PREPARE-EXAMPLE-MUSIC.SH`. Never a crash, never silence; browsing, search, and queueing work without the mp3s because the catalog is committed, and the next play attempt is the retry.

## Album art

The manifest's eight covers are committed beside it (`src/art/*.jpg`, 512px). `init_fx` registers them through the same image channel as the textures (cover image id = album id offset past the two texture ids), and the playlist rack's bottom deck strip carries the loaded record's **sleeve window** — the current album's cover in a small glass pane beside the up-next cues. The covers are JPEG: live macOS decodes them through the platform codec; the null platform's strict test decoder refuses them, so under `-Dplatform=null` every cover id stays 0 and the sleeve degrades to an engraved vector plate — the suite pins the degrade, not the decode. The player faceplate stays art-free on purpose: the 460x180 chassis is machined text and glass, and the marquee already names the record.

## Authoring split

- `src/statusbar.native` — the playlist rack's status strip (search field, match counter, queue badge), compiled at comptime; the test suite also runs it through the runtime interpreter and asserts engine parity.
- `src/layout.zig` — the chassis layout table: every shared dimension (window, cap band, glass rows, key plates, wells, the transport cluster's accumulated x-positions, the playlist rack's stack) on one 4px grid, with comptime asserts holding the sums (the transport row fits its container; the ledger viewport folds on a whole row). Both the widget views and the chrome pass machine against this one table, so the metalwork cannot drift from the controls it hugs.
- `src/music_manifest.zon` — the committed catalog, byte-identical to the soundboard's copy (generated by `tools/prepare-example-music.sh`; edit the script, never this file). The model imports it typed at comptime and derives its flat album/track tables from it — per-album track counts vary, and nothing in the app assumes a stride.
- `src/view.zig` — the Zig chrome for both windows: the player (cap band drag region, VFD with mono paragraph readouts and the marquee, the glass panel around the markup spectrum chart, seek fader, transport with the `PL` key) and the playlist rack (weave-texture backdrop image leaf, the flat full-library track ledger with per-row native context menus, the deck strip with the sleeve window and the cues).
- `src/model.zig` — the manifest import and the comptime-derived library tables, playback/queue/search/playlist-window state, the audio-event handling (`loaded`/`position`/`completed`/`failed`), the deterministic spectrum and marquee functions, and `update`.
- `src/chrome.zig` — the sculpted hardware layer, drawn through the `UiApp.chrome` display-list pass in two exact-count halves (prefix behind the widgets, suffix in front) at absolute coordinates spelled from the layout table (the window is fixed-size). The counts are module constants; the suite rebuilds the chrome across model states (idle, playing with textures, high contrast) and holds them, because the runtime rejects a build that misses its declared count.
- `src/theme.zig` — the widget skin: a dark-only token set (palette, 1–3px radii, mono-heavy typography, compact density) plus per-control visual tokens (`controls.*`) that restyle buttons, the PL toggle chip, the search field, the sliders, and the scrollbar without touching any widget code.
- `src/main.zig` — app wiring: fixed-size hidden-inset shell scene, the boot effect registering the textures and the manifest's album covers, `windows_fn`/`window_view` for the playlist rack, shortcut command map, `on_chrome` insets, tokens fn, the slider sync hook.
- `tools/pack_textures.zig` — dev-only: raw RGBA → strict-subset PNG for the committed textures.

## The spectrum is honest

Playback is real, but the analyzer is not an FFT — it visualizes the *playback clock*, and says so: a pure function of (track id, elapsed ms) produces 32 band levels — sum-of-sines shaped by a per-track seed and a mid-weighted envelope, where `elapsed ms` advances only on the platform's position events. Deterministic by construction: the same model state always yields the same bars (the suite asserts it), pausing freezes the bars because the position events stop, and an idle deck shows the noise floor. The bands render as one markup `<chart>` (`src/spectrum.native`: a phosphor bar series plus a paper-white peak-trace line, both binding model fns) — so the visualization rethemes, invalidates, and screenshots like every other widget.

## Keyboard

Registered app shortcuts (`app.zon`, delivered as command events): `primary+P` play/pause, `primary+←`/`primary+→` previous/next, `primary+L` toggle the playlist window, `Escape` clears the search. The seek fader takes arrow-key steps when focused (the widget keyboard path).

## Fixed capacities

- The committed manifest's albums and tracks (comptime-derived tables; per-album counts VARY — the model derives `track_start`/`track_count` per album and never assumes a stride).
- 16-entry play-next queue; a full queue drops the request and counts it.
- 48-byte search buffer.
- 32 spectrum bands (one `.chart` widget, well under the per-series point budget).
- 22-character marquee window, one step per 500ms of playback; cue plates cut titles at 16 characters (the catalog holds titles longer than the strip).
- 10 registered images of the 16-slot registry: 2 textures plus 8 album covers (each within the 1MB per-slot pixel bound).
- Two context-menu items per ledger row: the full ledger's rows x 2 stay well inside the 512-item per-view budget (the ledger lives alone in the playlist window's view).
- Player tree under 128 widget nodes; playlist tree under 768 of the 1024 per-view budget (full ledger).

## Run

```sh
native dev
```

Run the deterministic suite — hermetic by construction: playback runs through the audio channel's fake executor (the gitignored mp3s are never read), every content assertion derives from the committed manifest, and the strict null-platform decoder pins the JPEG-cover degrade. It covers the manifest table derivation, transport/queue/search dispatch, the NO MEDIA failure state, the playlist window round-trip through real dispatch, spectrum and marquee determinism on the position-event clock, texture/cover registration + codec-less fallback, engine parity, theming, chrome command counts, layout budgets, and automation click-through:

```sh
native test -Dplatform=null
```

Verify live through the automation harness:

```sh
native build -Dautomation=true
./zig-out/bin/deck &
native automate assert 'gpu_nonblank=true' 'role=button name="Play or pause"' 'role=button name="Playlist window"'
```
