# Native SDK deck example

The radical sibling of `examples/soundboard`: the **same app** — the same committed music catalog with albums, tracks, transport, seek, queue, and search — wearing a completely different product identity. Soundboard is the clean house-catalog look; deck is a piece of vintage rack-mount audio hardware. Same catalog, same audio files, same runtime, same widget engine and token system — a different product. That contrast is the demo: "Beautiful by default. Customizable by design."

## Design brief (v3: the vintage hi-fi rack unit)

**Identity.** A desktop audio deck styled as a vintage component hi-fi rack unit, in the classic two-window *shape*: a **fixed-size player** (512x264, `resizable = false`) that IS the device — warm enamel fascia, a hidden-inset titlebar whose cream cap band is the drag region — plus a **matching playlist unit** in its own window (460x440), racked in and out by the chunky `PL` key or `primary+L`. No library in the player; no transport in the playlist. Everything on screen should read as *hardware* — enamel plates, recessed screws, smoked-glass bays, silkscreened lettering — not as a document.

**Palette: two materials.** Warm cream/putty **enamel** for the chassis (`#E7E1D1` faceplate family, `#2C2820` silkscreen ink, `#A9A18A` putty hairlines) around dark **smoked glass** display bays (`#0C100D`) that print in a single phosphor green at three registers: live `#3EE08A`, resting `#A8D8B4`, engraved `#608068`. Signal amber `#ECB24A` is reserved for the queue and the failure stamps — the one non-green hue on the glass. The token table allocates its slots by material (see `src/theme.zig`); this skin is **custom by design** and deliberately does not follow the framework's theme packs or the OS color scheme.

**Type.** Mono-first. Every readout — timecode, track numbers, durations, band captions, status counts — is the mono face; sans survives only on track titles. Small and tight: body 12, labels 11, compact density. Engraved captions are uppercase mono at reduced scale ("SPECTRUM//32").

**The player (main window).** Fixed 512x264. Top to bottom: the enamel cap band (drag region; the traffic lights sit on the enamel beside the raised, embossed **DECK** brand plate and the unit's model designation), then two rows of glass bays — the **main display** (chrome-drawn seven-segment elapsed readout, the rotating **title marquee**, a `TRK NN` + timecode line, the honest bitrate/size readout, and the phosphor progress strip) beside the **art bay** (the loaded record's real cover), and the **spectrum bay** (a real chart — a markup `<chart>` with 32 phosphor bars plus a pale peak trace, segmented by the glass scanlines) beside the **band monitor** (five phosphor ladders on stamped frequency stops) — then the long-travel seek fader, and the transport row: five chunky beveled keys with dark glyphs (prev / play / pause / stop / next) in a recessed well, the **rotary volume knob** with its phosphor position dot, the amber queue badge, and the `PL` key.

**Honesty on the fascia.** The band monitor wears the equalizer LOOK but is a *visualizer*: the deck's audio surface has volume and seek and nothing else — no equalizer DSP, no balance bus — so the ladders average the same pure spectrum function the chart binds instead of faking sliders that would move nothing. The volume knob is the opposite case: the *control* is a real slider widget (drag, arrow keys, automation, the focus ring all work) and the chrome draws the analog knob face over the same frame, its dot angle derived from the same `volume_fraction` the slider syncs. And the bitrate readout states only what the manifest actually knows (bytes and duration → average kbps + file size); no invented sample rates, no codec badges.

**The marquee is honest.** The scroller is a pure function of (track id, elapsed ms): the composed `TITLE /// ARTIST /// ALBUM` line rotates one character per half-second of *playback* time, so pausing freezes it exactly like the spectrum and the band monitor (the clock stops) and the same model state always yields the same window of text. The suite asserts the rotation, the freeze, and the wrap.

**The playlist unit (second window).** A model-declared window (`UiApp.windows_fn` + `window_view`): PRESENCE in the declared set is visibility, so the `PL` key just flips `playlist_open` and the runtime reconciles — a user's titlebar close dispatches `.playlist_closed` and the model agrees. Inside: an enamel chassis around one big smoked-glass **playlist bay** — ONE flat song list over the whole library as numbered phosphor rows (pressable, per-row native context menus: Play Next / Copy Title), durations right-aligned, the loaded row lifted on a phosphor-tinted wash — plus the bottom deck strip (the loaded record's sleeve window and the amber up-next cues) and the markup status strip (glass search inset, queue badge, match counter). No album rail, no sub-collections: the rack is a list of songs, and search narrows it.

**Chrome language: machined enamel over honest texture.** The `UiApp.chrome` display-list pass draws the sculpted hardware layer in two fixed-count halves — pure fills, hairlines, gradients, and paths; **no bitmap skin assets anywhere**. Behind the widgets: the enamel chassis fill and warm faceplate gradient, a sparse comb of near-invisible grain hairlines, the cap band with its raised brand plate, the window's outer bevel, a ridged grip band, four recessed corner screws, and inset wells behind the transport cluster and the volume block. In front: inset bevel frames around the five glass bays and the seek fader, scanlines and a diagonal glare wash on the glass, the seven-segment readout drawn as sheared hexagon paths (ghost segments always faintly lit, live segments doubled with a glow stroke), the band monitor's ladders, the volume knob face, and raised bevels on the six keys.

**Control vs. readout.** The display carries the authoritative playback readout (segment digits + timecode + the phosphor progress strip); the long-travel fader below the glass is the seek *control*. That split is honest engine design, not decoration: slider positions are runtime-owned between rebuilds (the engine's reconcile rule — a scrubber that was also the model-driven readout would fight the user's hand), so the fader is re-keyed per track and snaps home on every load while the strip tracks the clock.

**One finish, by the brief.** Hardware has exactly one enamel; the OS appearance changes nothing here. Accessibility still beats brand: a high-contrast request abandons the widget skin for the framework's high-contrast light palette and strips the chrome pass to structure (grain, glare, and scanlines go transparent; bevels fall back to the border token; the readouts switch to the high-contrast text color) — same command counts, honest contrast. Reduce-motion zeroes the motion tokens.

## Same app, different identity

Deck deliberately shares soundboard's domain, and its *data*: the same committed catalog (`src/music_manifest.zon`, byte-identical to the soundboard's copy, generated by `tools/prepare-example-music.sh`), the same on-disk audio (the mp3s live once, in `examples/soundboard/assets/music/` — gitignored; the deck plays them by relative path), the same queue/search/seek/transport model shapes, the same context-menu `pbcopy` effect. Set the two side by side and every difference you see is *skin plus window shape*: design tokens, custom-drawn chrome, and a model-declared second window — all through the sanctioned view APIs. No engine fork, no private renderer hooks.

## Real playback

Pressing play issues `fx.playAudio` on the runtime's audio effect channel — on macOS that is the platform's real player, so the deck plays actual audio. Every report arrives as a typed Msg through the ordinary update path: the `loaded` acknowledgment carries the decoded duration (the manifest value is the display default until then), `position` ticks advance the progress clock (~500ms cadence, only while playing), one `completed` fires at natural end (the play-next queue wins over album order), and `failed` reports a missing file or a platform without audio playback. The volume knob rides `fx.setAudioVolume`, the long-travel fader seeks through `fx.seekAudio`, PAUSE holds the platform player in place, and STOP pauses it AND seeks home — halt-and-rewind with the record still loaded, the classic stop-vs-pause distinction.

**Tracks stream on demand out of the box.** The audio files are gitignored, but the committed manifest's `.url_base` points at the hosted mirror of the prepared catalog, so a fresh clone plays with zero setup: a missing local file streams instead of failing — the display stamps `BUFFERING` while the stream waits for bytes, playback starts as soon as they arrive, and the same bytes fill a local cache (`~/Library/Caches/deck/audio/`, keyed by URL hash and size-verified against the manifest's per-track `.bytes`; delete the directory to clear it) so the next play is local. `NATIVE_SDK_MUSIC_URL_BASE` overrides the base at launch (set it empty to disable streaming); `tools/prepare-example-music.sh` is the path for offline local files and for regenerating or self-hosting the catalog. A dead stream — offline with a cold cache, a mid-flight drop — stamps `STREAM LOST` with `CHECK THE CONNECTION AND RETRY`: a network problem, a network remedy.

**The NO MEDIA state is honest.** With streaming explicitly disabled and no prepared local files, the first play lands one `failed` event and the deck clears to an unmistakable degraded state — the display marquee stamps `NO MEDIA` in signal amber and the channel line reads `RUN TOOLS/PREPARE-EXAMPLE-MUSIC.SH`: there is genuinely no way to play, and the remedy names the script that fixes it. Never a crash, never silence; browsing, search, and queueing work without the mp3s because the catalog is committed, and the next play attempt is the retry.

## Album art

The manifest's eight covers are committed beside it (`src/art/*.jpg`, 512px) and they are the only images this app registers (cover image id = album id). `init_fx` registers them through the runtime image channel, the player's **art bay** shows the loaded record's cover in its own glass window, and the playlist unit's deck strip carries the same cover as the **sleeve window** beside the up-next cues. The covers are JPEG: live macOS decodes them through the platform codec; the null platform's strict test decoder refuses them, so under `-Dplatform=null` every cover id stays 0 and both surfaces degrade to engraved vector plates — the suite pins the degrade, not the decode.

## Authoring split

- `src/statusbar.native` — the playlist unit's status strip (search field, match counter, queue badge), compiled at comptime; the test suite also runs it through the runtime interpreter and asserts engine parity.
- `src/spectrum.native` — the spectrum chart fragment (bar + peak-line series binding model fns), composed into the Zig glass-bay view.
- `src/layout.zig` — the chassis layout table: every shared dimension (window, cap band, glass bays, key plates, wells, the transport row's accumulated x-positions, the playlist unit's stack) on one 4px grid, with comptime asserts holding the sums (the transport row fits its container; the ledger viewport folds on a whole row). Both the widget views and the chrome pass machine against this one table, so the enamel work cannot drift from the controls it hugs.
- `src/music_manifest.zon` — the committed catalog, byte-identical to the soundboard's copy (generated by `tools/prepare-example-music.sh`; edit the script, never this file). The model imports it typed at comptime and derives its flat album/track tables from it — per-album track counts vary, and nothing in the app assumes a stride.
- `src/view.zig` — the Zig fascia for both windows: the player (cap band drag region, display bay with mono paragraph readouts and the marquee, the art bay, the glass around the markup spectrum chart, the band monitor's label row, seek fader, the five-key transport with the volume slider and `PL` key) and the playlist unit (enamel panel chassis, the glass playlist bay with per-row native context menus, the deck strip with the sleeve window and the cues).
- `src/model.zig` — the manifest import and the comptime-derived library tables, playback/queue/search/playlist-window state, the audio-event handling (`loaded`/`position`/`completed`/`failed`), the deterministic spectrum/band-monitor/marquee functions, and `update`.
- `src/chrome.zig` — the sculpted hardware layer, drawn through the `UiApp.chrome` display-list pass in two exact-count halves (prefix behind the widgets, suffix in front) at absolute coordinates spelled from the layout table (the window is fixed-size). The counts are module constants; the suite rebuilds the chrome across model states (idle, playing at both volume extremes, the NO MEDIA degrade, high contrast) and holds them, because the runtime rejects a build that misses its declared count.
- `src/theme.zig` — the widget skin: a one-finish token set split by material (enamel vs glass; the palette rationale lives on the fields) plus per-control visual tokens (`controls.*`) that restyle the keys, the PL toggle, the glass search inset, the faders, and the scrollbar without touching any widget code.
- `src/icons/stop.svg` — the deck's registered stop glyph (the built-in icon set carries no transport square); `main.registerIcons` installs it and views reach it as `app:stop`.
- `src/main.zig` — app wiring: fixed-size hidden-inset shell scene, icon registration, the boot effect registering the album covers, `windows_fn`/`window_view` for the playlist unit, shortcut command map, `on_chrome` insets, tokens fn, the slider sync hook.

## The spectrum is honest

Playback is real, but the analyzer is not an FFT — it visualizes the *playback clock*, and says so: a pure function of (track id, elapsed ms) produces 32 band levels — sum-of-sines shaped by a per-track seed and a mid-weighted envelope, where `elapsed ms` advances only on the platform's position events. Deterministic by construction: the same model state always yields the same bars (the suite asserts it), pausing freezes the bars because the position events stop, and an idle deck shows the noise floor. The bands render as one markup `<chart>` (`src/spectrum.native`), and the band monitor's five ladders average slices of the same function — so every live display on the fascia freezes and replays together.

## Keyboard

Registered app shortcuts (`app.zon`, delivered as command events): `primary+P` play/pause, `primary+←`/`primary+→` previous/next, `primary+L` toggle the playlist window, `Escape` clears the search. The seek fader takes arrow-key steps when focused (the widget keyboard path).

`Space` toggles play/pause from anywhere — the media-app convention, carried by the app-level key fallback (`on_key`) rather than a chrome shortcut (unmodified space cannot be one, by design). A focused widget always wins first: a focused transport key presses itself, and a focused search field keeps typing spaces (`primary+P` is the works-while-typing chord).

## Fixed capacities

- The committed manifest's albums and tracks (comptime-derived tables; per-album counts VARY — the model derives `track_start`/`track_count` per album and never assumes a stride).
- 16-entry play-next queue; a full queue drops the request and counts it.
- 48-byte search buffer.
- 32 spectrum bands (one `.chart` widget, well under the per-series point budget) feeding 5 band-monitor stops.
- 22-character marquee window, one step per 500ms of playback; cue plates cut titles at 16 characters (the catalog holds titles longer than the strip).
- 8 registered images of the 16-slot registry: the album covers alone (each within the 1MB per-slot pixel bound).
- Two context-menu items per ledger row: the full ledger's rows x 2 stay well inside the 512-item per-view budget (the ledger lives alone in the playlist window's view).
- Player tree under 128 widget nodes; playlist tree under 768 of the 1024 per-view budget (full ledger).

## Run

```sh
native dev
```

Run the deterministic suite — hermetic by construction: playback runs through the audio channel's fake executor (the gitignored mp3s are never read), every content assertion derives from the committed manifest, and the strict null-platform decoder pins the JPEG-cover degrade. It covers the manifest table derivation, the five-key transport (including stop's halt-and-rewind), queue/search dispatch, the NO MEDIA failure state, the playlist window round-trip through real dispatch, spectrum/band-monitor/marquee determinism on the position-event clock, cover registration + codec-less fallback, engine parity, theming, chrome command counts, layout budgets, and automation click-through:

```sh
native test -Dplatform=null
```

Verify live through the automation harness:

```sh
native build -Dautomation=true
./zig-out/bin/deck &
native automate assert 'gpu_nonblank=true' 'role=button name="Play"' 'role=button name="Stop"' 'role=button name="Playlist window"'
```
