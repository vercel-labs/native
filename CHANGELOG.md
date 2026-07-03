# Changelog

All notable changes to zero-native will be documented in this file.

## Unreleased

### New Features

- **Native-rendered apps by default**: `zero-native init` now scaffolds a native-rendered app — a declarative `.zml` markup view plus Zig logic — with web frontends available via `--frontend next|vite|react|svelte|vue`.
- **Markup authoring (`.zml`)**: HTML-inspired views with flex layout, `{bindings}` to model fields and functions, typed `on-*` message dispatch, `for`/`if` structure tags, and keyed identity (including `global-key` for items that move between containers). A deliberately closed expression grammar keeps logic in Zig.
- **Comptime markup compilation**: views compile at build time into direct field access — release binaries carry no parser, and markup or binding mistakes are compile errors with line and column.
- **Hot reload**: dev builds watch the `.zml` file and update the running window in place, preserving model state, selection, and widget identity — no JS engine involved.
- **`UiApp` runtime loop**: apps are a `Model`, a `Msg` union, `update`, and a view; the runtime owns install, presentation, resize, typed event dispatch, timers, chrome display lists, and animations. All examples run on it.
- **Declarative `canvas.Ui` builder**: the programmatic escape hatch under the markup — structural widget identity (no hand-assigned ids), typed message handlers, flex-first layout, payload-carrying constructors for text edits and slider values.
- **Linux canvas presentation**: native-rendered apps run on Linux through a software path (GTK drawing areas, cairo blits of the deterministic reference renderer), with pointer, keyboard, scroll, IME composition, and HiDPI support.
- **CoreText-backed text metrics**: layout measures with the same fonts presentation draws on macOS, via a pluggable provider that leaves tests and the reference renderer deterministic.
- **Platform timers**: `runtime.startTimer`/`cancelTimer` with typed timer events and `UiApp` message mapping — the first way for apps to do time-based updates.
- **Effect system (spawn + streaming)**: TEA's Cmd half — `update` gains an optional effects channel (`.update_fx`; two-argument apps unchanged) with `fx.spawn(.{ .key, .argv, .stdin, .on_line, .on_exit })` and `fx.cancel(key)`. Subprocesses run on runtime-owned worker threads (thread-per-spawn, 16-slot cap); stdout lines and exits post to a bounded MPSC queue, a new thread-safe `PlatformServices.wake_fn` nudges the platform loop (macOS main-queue dispatch, GTK `g_idle_add`, Win32 `PostMessage`, null platform an atomic counter tests drain), and the loop thread drains completions into typed Msgs — the model is never touched off-thread. Overflow is never silent (rejected spawns, dropped-line counts, truncation flags), cancel kills and reaps with exactly one `cancelled` exit Msg and no line Msgs after it, and the fake effect executor lets tests assert on spawn requests and feed synthetic lines/exits deterministically. `examples/effects-probe` is the live dogfood: a minutes-long shell stream into a native list with a working Cancel, verified over the automation snapshot on macOS and GTK.
- **Effect system (HTTP fetch)**: `fx.fetch(.{ .key, .method, .url, .headers, .body, .timeout_ms, .on_response })` runs one HTTP(S) request on a runtime-owned worker thread and delivers its terminal outcome as exactly one typed Msg carrying `zero_native.EffectResponse` — a delivered response's real status plus a binary-safe body (non-2xx included), or an explicit failure taxonomy: `rejected` (never started: slots busy, duplicate key, bad URL/scheme, over-capacity URL/headers/payload), `connect_failed`, `tls_failed`, `protocol_failed`, `timed_out`, `cancelled` — nothing fails silently. Bodies are bounded at 256 KiB (longer arrives truncated and flagged), the whole exchange honors a per-fetch timeout (default 30 s), `fx.cancel(key)` ends a fetch with exactly one `cancelled` Msg and nothing after it, and fetches share the 16 effect slots and caller-chosen key space with spawns. The fake executor records fetch requests (`pendingFetchAt`) and answers them synthetically (`feedResponse`); the real path is tested end to end against a loopback `std.http.Server` fixture — no external network.
- **Effect init hook (`init_fx`)**: TEA's init command — `UiApp.Options.init_fx` runs exactly once on the installing frame, after the effects channel is bound and before the first view build, so a boot-time `fx.spawn`/`fx.fetch` starts before anything renders and its loading state is in the very first paint. Works with either update form; replaces the guarded-`on_frame` idiom for startup effects (`on_frame` stays the per-frame diagnostics hook). The fake executor records the boot spawn when set before the first frame, so TestHarness tests assert it deterministically.
- **Effect collect mode (`.output = .collect`)**: whole-stdout delivery for tools that emit one giant line (`gh --json`, `jq -c`) — up to 512 KiB of stdout arrives once on the exit Msg as `EffectExit.output` instead of being destroyed by the 4 KiB line cap, together with the child's stderr tail (last 4 KiB, `EffectExit.stderr_tail` — previously stderr was hard-ignored and needed an sh re-route to diagnose failures). No `on_line` Msgs fire for a collect spawn; overflow arrives cut with `output_truncated`/`stderr_truncated` set, never silently; a worker-side reader drains stderr concurrently so chatty children cannot deadlock. The fake executor mirrors it (`feedLine` accumulates, new `feedStderr`, `feedExit` delivers the payloads) and the real path is covered by POSIX-portable process tests (100 KB single-line delivery byte-exact, stderr tail on failure, truncation past the bound).
- **Markup validation: handlers on non-hit-target elements are errors**: `on-press` (and every `on-*`) on layout containers and decoration leaves (`row`, `column`, `stack`, `tabs`, `toggle-group`, `badge`, ...) used to be a silent no-op — the engine never hit-tests those kinds, so the handler could never fire. It is now a validation error with a teaching message (put the handler on a leaf like `list-item` or `text`, or on a control), enforced by `markup check`, the LSP diagnostics, the runtime interpreter, and a compile error in the comptime engine. The element set derives from the engine's single hit-target predicate (`canvas.widgetKindHitTarget`, now shared by runtime pointer dispatch and hit-testing) with a sync test so drift is impossible.
- **Automation screenshots**: `zero-native automate screenshot` renders a canvas view through the reference renderer to a deterministic PNG, enabling golden-image verification for tests and agents.
- **Snapshot assertions (`automate assert`)**: `zero-native automate assert '<regex>' ...` polls `snapshot.txt` until every pattern matches (default 30s via `--timeout-ms`; `--absent` inverts to "must be gone"), replacing grep-and-sleep chains in smoke scripts. Failure is CI-friendly and evidence-carrying: non-zero exit, each missing pattern named, and the snapshot tail printed. The regex subset is grep-like (literals, `.`, `*` `+` `?`, `^`/`$` line anchors, `[...]` classes, `\d \w \s`) with no groups/alternation — pass multiple patterns instead.
- **Scaffolded CI workflow**: `zero-native init` now writes `.github/workflows/ci.yml` — a null-platform `zig build test` job for every frontend, plus (for native apps) a Linux Xvfb automation smoke job that builds with `-Dautomation=true`, launches the app's real binary, runs `automate wait` + `automate assert` against the accessibility snapshot, and requires a non-empty `automate screenshot` artifact. Both jobs fetch the zero-native checkout into the path `build.zig.zon` expects; the repo's scaffold CI job parses every generated workflow as YAML. New docs page: [Testing in CI](https://zero-native.dev/testing/ci).
- **`.zml` tooling**: `zero-native markup check` (instant grammar validation with positions), `zero-native markup lsp` (diagnostics, completion, hover), and a TextMate grammar with editor setup under `editors/zml/`.
- **Framework build helper**: `zero_native.addApp` gives an app a complete build from a five-line build.zig; the shared runner lives in the framework.
- **Mobile canvas embed host**: `zero_native.addMobileLib` compiles a user's `UiApp` into the mobile embed static library — `zero_native_app_create` instantiates it on a gpu_surface scene (window 1, "mobile-surface") pumped by the host's frame callback, frames render to pixels retrievable over the ABI (`zero_native_app_render_pixels`), and the previously missing scroll/viewport-state/frame-state/semantics-by-id/text-geometry symbols are exported. The fixed WebView shell remains the default `zig build lib`; `examples/mobile-canvas` shows the new seam.
- **iOS simulator presentation**: the mobile embed library cross-compiles with `-Dtarget=aarch64-ios-simulator`, and a minimal ObjC shim (`examples/mobile-canvas/ios/`) presents the host's CPU-rendered frames on a CAMetalLayer — CADisplayLink pumps `zero_native_app_frame`, changed frames upload via `MTLTexture replaceRegion` and blit to the drawable. `run.sh` builds the .app bundle without an .xcodeproj, installs it on a simulator, and verifies a non-blank screenshot; `zig build lib -Dmobile=true` builds ui-inbox the same way.
- **iOS simulator input fidelity**: the canvas shim forwards real UITouch sequences through the embed ABI — taps press widgets, over-slop pans drive the existing scroll reconciliation, and other drags keep pointer-drag semantics; the system keyboard shows/hides off the new `zero_native_app_text_input_state` export (textbox focus = IME intent), typed text flows through `zero_native_app_text`, and UITextInput marked text maps onto the same `zero_native_app_ime` composition path desktop hosts use. `zero_native_app_set_automation_dir` points the runtime's automation snapshots into the app's data container, and `examples/mobile-canvas/ios/verify_input.sh` proves it hardware-true on the simulator with a generated XCUITest runner (no .xcodeproj): injected tap grows the inbox, the keyboard appears/types/hides, and drag-scroll moves the list offset — all asserted against automation snapshots.
- **Mobile safe-area layout**: viewport chrome insets are a runtime concept — `Runtime.viewportInsetsForWindow` combines the surface's safe-area and keyboard insets, and `UiApp` deflates widget layout by them while the canvas keeps painting edge to edge. Desktop reports zero insets, so desktop layout is unchanged; on iOS, content lays out clear of the Dynamic Island and home indicator, relayouts on real rotation, and honors the 3x device scale — verified by `examples/mobile-canvas/ios/verify_layout.sh` (snapshot assertions plus an XCUITest rotation, no .xcodeproj) and pure-Zig embed tests.
- **Mobile platform text metrics**: new embed export `zero_native_app_set_text_measure` registers a shim-provided measure callback as the runtime's text-measure provider — the mobile counterpart of the desktop `measure_text_fn` service. The iOS shim registers a CoreText/UIFont measure mirroring the macOS host, so layout uses real typographic widths (launch with `--estimator-text-metrics` for the deterministic estimator); a negative return per run falls back to the estimator, and goldens stay byte-identical.
- **Android canvas presentation + touch (compile-proven)**: the mobile embed library cross-compiles with plain `-Dtarget=aarch64-linux-android` / `x86_64-linux-android` (no NDK sysroot — the static lib links no libc) with all 32 ABI symbols, built PIC so its thread-locals emit TLSDESC relocations the NDK linker accepts inside a shared object (`addMobileLib` sets this for Android targets; a `test-example-mobile-canvas-lib-android` gate keeps the cross-compile green). A minimal NativeActivity C shim (`examples/mobile-canvas/android/`, no Gradle, no Java — `hasCode=false`) mirrors the iOS shim: AChoreographer pumps `zero_native_app_frame`, revision-gated frames row-copy RGBA8 into the locked `ANativeWindow` buffer (no swizzle — `WINDOW_FORMAT_RGBA_8888` matches the renderer), AMotionEvent touch forwards through the same touch-slop tap/scroll/drag state machine, content-rect safe areas feed the viewport export, and a `debug.zero_native.automation` system property points automation snapshots at the app's files dir. `run.sh` builds, signs (aapt2/zipalign/apksigner, no Gradle), installs, and verifies non-blank screenshot + snapshot + injected `adb input tap`. Honest status: no Android SDK/NDK/emulator was available on the dev machine, so the shim compile, APK assembly, and on-device rungs are unverified — the Zig cross-compile, symbol surface, and PIC relocations are machine-checked; the shim passed a strict `-Wall -Wextra -Werror` syntax check against stub NDK headers only. Soft keyboard/IME and platform text metrics are deliberately not wired (need Java-side glue; the ABI seams exist).
- **`native-ui` agent skill**: the complete markup and UiApp authoring reference, served through the skills CLI.
- **Inline styled text spans**: a `.text` paragraph can carry mixed-style runs — weight (regular/medium/bold), italic, monospace, color token overrides, underline, strikethrough, a relative size scale, and link payloads — in one wrapped block. Wrapping and measurement are span-aware through both the deterministic estimator and the platform text-measure provider (weights ride reserved sans font-id variants, so measured text always matches drawn text); stacked span paragraphs reserve their real wrapped height. Authored via `ui.paragraph(.{ .on_link = Ui.linkMsg(.open_url) }, spans)`; single-style text keeps its classic byte-identical path.
- **Real span faces on macOS**: the reserved sans span font ids (3 medium, 4 bold, 5 italic, 6 bold italic) resolve to real faces in the AppKit host's shared draw + measure font resolution — Geist Medium/Bold by name when installed, an NSFontManager family conversion otherwise, and the matching SF weight as the guaranteed floor (weighted ids never fall back to the regular face); italics prefer a real italic face and otherwise synthesize a sheared font matrix so the slant is always visible without changing advance widths. The iOS embed shim's CoreText measure callback mirrors the same id-to-face mapping so measured layout matches a future iOS draw path. Ids 0-2 and the deterministic estimator are byte-for-byte unchanged.
- **Hit-testable links**: link spans grow hit-area children with `role=link` semantics (pointer cursor, automation-clickable, focusable); pressing one dispatches the paragraph's `on_link` message carrying the link payload through the ordinary typed handler table.
- **`zero_native.markdown`**: a GitHub-flavored-markdown subset mapped onto the widget tree + span model — `#`–`###` headings (token-derived sizes), paragraphs with bold/italic/code/strikethrough/links, bullet/ordered/task lists (task items are display-only disabled checkboxes), fenced code blocks on a surface panel, blockquotes, horizontal rules, and `<details>`/`<summary>` collapsibles driven by caller-owned expanded flags (`details_expanded` + `on_details`). Std-only, arena-allocated, capacity-bounded; malformed input degrades to literal text and never fails the build fn. dev-2's README renders through it in a reference-renderer golden test.
- **Arena-taking scalar bindings**: `{summary}` binds `pub fn summary(m: *const Model, arena: std.mem.Allocator) []const u8` directly — derived display strings format into the build arena and work in text interpolation, attribute values, and message payloads (both engines, identical trees). The old one-element-`<for>` workaround is obsolete. Equality (`{a == b}`) deliberately rejects arena-computed values with a teaching error (compare source fields, or bind a bool fn), and string-producing bindings now pass to templates as scalar value args rather than iterables of bytes.
- **`<markdown>` element**: markup views render markdown declaratively — `<markdown source="{issue_body}" on-link="open_url" on-details="toggle_details" details-expanded="{details_expanded}" />` wires `zero_native.markdown` in both engines with identical structural ids and dispatch. `source` is one `{binding}` (arena fns encouraged); `on-link`/`on-details` are bare Msg tags whose payloads (URL, details index) the runtime supplies; `details-expanded` resolves a `[]const bool` through the same sources `for each` accepts; everything but `source` is optional. The validator, `markup check`, and the LSP (docs, completion, hover) all know the element and teach on misuse.
- **Full component catalog in markup**: every built-in component is now expressible in `.zml` — 26 new elements covering tab strips and grouped controls (`tabs`, `toggle-group`, `toggle-button`, `button-group`, `radio-group`, `breadcrumb`, `pagination`), tables (`table`/`table-row`/`table-cell` with structural validation), surfaces (`accordion`, `alert`, `bubble`, `dialog`, `drawer`, `sheet`, `resizable`, `dropdown-menu`), controls and leaves (`select`, `switch`, `avatar`, `tooltip`, `input`, `combobox`, `skeleton`, `spinner`) — implemented in both the interpreter and the comptime compiler with parity tests, plus teaching validator messages (misplaced table rows, element children inside text leaves). Kinds that fundamentally need Zig (icon/image assets, data-grid cell templates, anchored popovers) are documented exclusions guarded by a coverage test.
- **Markdown pipe tables**: `zero_native.markdown` now renders GFM pipe tables onto the real `table`/`table-row`/`table-cell` widgets — bold header row, `:---`/`:--:`/`---:` per-column start/center/end alignment, the full inline grammar inside cells (code, bold, links — links in cells are clickable hit targets), `\|` for a literal pipe, and word-wrapped cells (columns share the width equally in v1). Table cells (`data_cell`) learned to carry inline text spans engine-wide: layout, wrapped-height reservation, intrinsic sizing, link hotspots, and rendering all ride the existing span-paragraph machinery, additive for classic single-line cells. Malformed pipe blocks (missing or mismatched delimiter row, more than 8 columns) degrade to plain paragraphs, never a build failure.
- **Stepper + timeline components**: two shadcn-conventioned composites for pipeline UIs, available from `canvas.Ui` and as markup elements in both engines with parity tests. `ui.stepper` / `<stepper active="{i}"><step>Work</step>...</stepper>` renders a horizontal stage track — number-or-check badge indicators, hairline connectors, completed/active/pending states derived from the active index, list/listitem semantics with each step's state and position in its label. `ui.timelineItem` / `<timeline><timeline-item title="..." description="..." meta="..." variant="primary" on-press="open_step:{entry.slot}" /></timeline>` renders ledger items — variant-colored indicator dot (or glyph text), connector rail, bold title, wrapped muted description, muted meta line, and (when pressable) a trailing chevron plus a full-area press hotspot riding the paragraph-link overlay convention, focusable with role `listitem`. The validator teaches structure (step only inside stepper, timeline-item only inside timeline, closed attribute sets), and `markup check`, the LSP (docs, completion, hover), and the `native-ui` skill all know the elements.
- **`ui.nav` navigation stack**: a within-pane push/pop container for a model-owned stack (TEA: the app model holds the active index; out-of-range clamps). Pages are index-keyed so a page's widget ids — and with them engine-owned scroll offsets and text edits — are stable across swaps; `retain = true` keeps inactive pages mounted but hidden (engine state preserved; hidden pages drop out of rendering, hit-testing, focus traversal, and semantics), while the default unmounts them. v1 swaps instantly — animated push/pop is documented future work — and focus transfer on push/pop stays an explicit `update` concern.

- **Streaming HTTP responses (`fx.fetch` `.response = .stream`)**: the response body frames into `on_line` Msgs as lines arrive — the spawn `.lines` contract over HTTP — with the terminal `on_response` Msg carrying the real status and an empty body. Built for NDJSON/SSE endpoints that hold the connection open for a command's whole lifetime (Vercel Sandbox exec with wait+logs, agent event streams): `fx.cancel(key)` mid-stream stops the lines and delivers exactly one `.cancelled` terminal, the whole-exchange `timeout_ms` covers the stream's full lifetime, and queue-dropped lines that no later line reported land on the terminal's `dropped_before` — never silent. The fake executor feeds stream fetches through `feedLine` + `feedResponse`; the real path is covered by a loopback fixture streaming NDJSON slowly (flush-per-event with real time between events) including a cancel-mid-stream test.
- **Per-effect line bounds (`max_line_bytes`)**: `.lines` spawns and `.stream` fetches can raise the 4 KiB delivered-line bound up to a 256 KiB ceiling (`max_effect_line_bytes_ceiling`) — agent CLIs emit whole events as single NDJSON lines that the default cap destroyed (a long `claude -p --output-format stream-json` answer arrived as unrecoverable truncation), and envelope protocols wrap another stream's lines inside their own (sandbox exec NDJSON envelopes carrying JSON-escaped agent events), so the ceiling holds a full 64 KiB inner line with escaping overhead and framing to spare — at 64 KiB, a near-ceiling inner line was unrecoverable because the wrapped line blew the same bound both layers individually fit in. Bounds above the default heap-allocate the effect's line buffer plus a per-line transfer allocation only for oversized lines (the ceiling itself costs nothing until an effect opts in); over-ceiling (or zero) requests are rejected through the effect's terminal Msg, never silently clamped; lines beyond the granted bound still arrive truncated and flagged. Verified with a real process emitting a >4 KiB single line delivered byte-exact.
- **File effects (`fx.writeFile` / `fx.readFile`)**: TEA-friendly file persistence — session snapshots, app state — without smuggling an `Io` handle from `main` into `update`. Same discipline as spawn and fetch: bounded (1 KiB paths, 1 MiB files), key-based (shared key space and 16 slots), run on a worker thread, and exactly one terminal Msg (`zero_native.EffectFileResult`) with an explicit outcome: `.ok`, `.not_found` (reads only — writes create missing parent directories), `.io_failed`, `.truncated` (an over-bound read delivers its first 1 MiB under its own outcome, not a flag, so a cut JSON snapshot cannot parse as whole), `.rejected` (slots busy, duplicate key, bad path — and over-bound write payloads, rejected outright because a partial write would corrupt the file), `.cancelled`. The fake executor records file requests (`pendingFileAt`) and answers them synthetically (`feedFileResult`); the real path is tested against `std.testing.tmpDir` (round trip, parent creation, whole-file replace, not_found, over-bound truncation, cancel-race terminal rewrite).
- **Facade time API (wall + monotonic, testable)**: `zero_native.nowMs()` / `nowNanoseconds()` read the wall clock and `monotonicMs()` / `monotonicNanoseconds()` the duration clock, directly (no `std.Io` handle — callable from `update`/`init_fx`), implemented per-OS once in the framework (POSIX `clock_gettime`, Windows `RtlGetSystemTimePrecise`/QPC; previously every app re-implemented this because Zig 0.16 put `std.time.milliTimestamp` behind `Io`). For time-dependent logic, `zero_native.Clock` is the seam the model stores (`.system` reads the real clocks) and `zero_native.TestClock` the deterministic hand-cranked test double (`advanceMs` moves both clocks, `setWallMs` jumps the wall alone, NTP-style).
- **Clipboard shortcuts + text selection & copy**: cmd/ctrl+C/X/V now work in native-rendered text. In editable fields the runtime resolves the shortcut against its own editor state — copy writes the selection through the platform clipboard seam (NSPasteboard / GTK / Win32; in-memory on the null platform for tests), cut copies then delivers the delete as an ordinary `insert_text ""` edit so TEA mirrors stay consistent, and paste arrives as a normal `insert_text` edit clamped to the view's text capacity with a loud `edit_truncated` flag on the keyboard event (`canvas.TextBuffer` gained the matching `truncated` flag and clamps oversized insertions at a UTF-8 boundary instead of dropping them). Static text is now selectable: click-drag inside one `.text` widget — plain wrapped text or a span paragraph (markdown issue bodies, transcripts) — selects with a rendered highlight, cmd/ctrl+C copies, pressing elsewhere clears, and the selection survives rebuilds while the text is unchanged and is exposed through semantics and automation snapshots (`selection=a..b`). Automation `widget-key` accepts modifier chords (`cmd+c`, `ctrl+shift+arrowleft`), so agents can drive select/copy/paste live; verified end to end on macOS against the real NSPasteboard. Deliberate v1 limits: selection is per-widget (no cross-widget document model), and cmd+A does not select static text (it stays a text-input affordance).
- **Platform image decoding**: a new `PlatformServices.decode_image_fn` seam decodes encoded image bytes (PNG, JPEG, and whatever else the OS ships) into straight-alpha RGBA8 through the platform codec — CGImageSource on macOS, gdk-pixbuf on GTK, WIC on Windows — so the framework bundles no image decoders. The null platform gets a deterministic test decoder for the strict PNG subset the canvas PNG writer emits, so tests drive the full decode path from raw RGBA fixtures with no codec in the tree.
- **Runtime image registration (`ImageId`)**: apps register decoded RGBA pixels at runtime under caller-chosen ids — `fx.registerImage`/`fx.registerImageBytes` (decode + register in one step) / `fx.unregisterImage` on the effects channel, `Runtime.registerCanvasImage`/`registerCanvasImageBytes`/`unregisterCanvasImage` underneath — and reference them from `image`, `icon_button`, and `avatar` widgets. The runtime owns bounded pixel copies (16 slots × 1 MiB, `canvas_limits` style, overflow always loud) and threads them into every view's frame plan, so registered images render through the GPU packet path (upload/retain/evict off content fingerprints; re-registering an id re-uploads automatically), the software presentation path, and `renderCanvasScreenshot`/automation screenshots — goldens can assert on them. A draw referencing an unregistered id skips instead of failing the frame, making "not loaded yet" a first-class transient state.
- **Avatar images with initials fallback**: `ui.avatar(.{ .image = id }, "ZN")` renders a registered image clipped to the avatar circle (`cover` fit) and falls back to the centered initials while the id is 0 — the shadcn avatar contract. The fetch-avatar path is one update arm: `fx.fetch` the bytes, `fx.registerImageBytes` on the response, and write the id into the model only on success, so initials show while loading and stay after a failed fetch or decode. `ui.image(.{ .image = id })` is the plain image leaf.
- **Binary image-upload side-channel — frames with images stay on the GPU packet path**: image pixels used to ride the gpu packet JSON as byte arrays, so one 128px avatar (64 KiB RGBA ≈ 256 KiB of JSON) blew the 128 KiB packet bound and silently evicted the WHOLE frame to the software pixels path — whose reference renderer draws placeholder block glyphs, so an app visibly degraded exactly when its images finished loading (ovation live: real text while an issue loads, block glyphs once the avatar lands, recurring every frame an image was visible). Pixels now travel out-of-band through a new platform seam — `PlatformServices.uploadGpuSurfaceImage` (id, width, height, raw straight-alpha RGBA8) / `removeGpuSurfaceImage` — driven by the packet's upload cache actions at present time (which also covers caller-supplied `CanvasFrameOptions.image_resources` sets that never pass the registry, e.g. gpu-components) and the unregister path; packets carry only id + fingerprint references, never pixel payloads. The macOS AppKit host owns a host-wide image store keyed by id (create/replace on upload, shared by every gpu-surface view; per-view caches now apply evict actions before uploads so an id re-registered under a new fingerprint in one packet keeps its fresh image), the null platform records the upload/replace/remove lifecycle for tests, and absent images (an id referenced while unregistered — mid-fetch, LRU-evicted) skip on the packet host exactly like the CPU reference renderer instead of failing the frame back to pixels. Re-registration re-uploads off the content fingerprint (the LRU-churn shape); software/pixels presentation, screenshots, GTK/Win32, and the mobile embed path are unchanged. Live-verified in ovation on Metal: real glyphs with real avatars through a 13-issue click-through, where the same drive previously flipped the window to block glyphs.

### Improvements

- **Every effect-facing name is on the facade**: `zero_native.FetchResponseMode` and `zero_native.EffectExecutor` are exported (both existed but were missing from the root module, so tests compared enum literals), together with the effect capacity constants (`max_effects`, `max_effect_line_bytes`, `max_effect_line_bytes_ceiling`, `max_effect_body_bytes`, `max_effect_collect_bytes`, `default_effect_fetch_timeout_ms`, and the rest) — everything an app or its tests reference now comes from `zero_native.*`.
- **Automation CLI misroutes fail loudly**: `zero-native automate` used to create `.zig-cache/zero-native-automation/` under whatever cwd it ran from and print `queued <command>` — a command sent from the wrong directory landed in a dir no app reads and looked exactly like "the click did nothing". The CLI no longer creates the dir (only the running app does): a missing dir is now an error naming the absolute path it looked at and how to fix it, every queued command prints the absolute dir it wrote to, and `list`/`snapshot` name the dir when no app is connected.
- **Dispatch degrades instead of dying**: a handler/update error inside the platform callback used to set `failed` and exit the whole app (`error.CallbackFailed`, seen live minutes into a streaming session). Dispatch now catches handler errors, records them in a bounded ring — queryable via `runtime.dispatchErrors()`, published in automation snapshots (`dispatch_errors=` count plus `error event=... name=...` lines), and traced as `dispatch.error` records at error level — and keeps running. Trace logging can no longer fail dispatch either: sink capacity failures drop the record and count the loss (`dropped_trace_records=` in snapshots), `StdoutTraceSink`/file logging format through new bounded `trace.formatTextBounded`/`formatJsonLineBounded` helpers (oversized records truncate with a marker or rewrite as minimal valid JSON instead of erroring), and the TestHarness's bounded sink no longer caps how many frames a test can dispatch.
- **Automation `set_text` routes through the real input path**: `widget-action <id> set_text <value>` now synthesizes focus, a select-all key, and a text-input event through the same `gpu_surface_input` dispatch real typing uses, so the app receives the matching `on_input` edits and an elm-style model mirror stays consistent with the on-screen field (previously it wrote the runtime editor directly and the model never heard about it — Send buttons stayed disabled while the field visibly held text). Accessibility `set_text` actions take the same path.
- **Definite `width`/`height`**: explicit sizes on ui-builder options and markup attributes are now definite — the value is both the minimum and maximum bound, so a pane's intrinsic content can neither shrink it nor silently overflow it and starve siblings (`resizable` keeps `width` as its initial width). The widget model gains a `max_size` layout channel (0 = unbounded); trees that only set `min_size` from Zig keep the classic floor behavior. Migration: markup/`ElementOptions` `width`/`height` previously acted as min-only floors — content larger than the declared size used to widen the box, now it wraps/clips inside it.
- **Flex overflow diagnostics**: when children's minimum extents exceed their container, debug builds log a `zero_canvas_layout` diagnostic naming the container kind, axis, and overflow in pixels — layout overflow is never silent.
- **Axis-aware `separator`**: a separator inside a row is now a thin vertical divider (stroke width in the row axis, full height across) instead of consuming its 160px horizontal-rule default length; columns keep the classic horizontal rule. Rendering was already orientation-aware; layout now matches.
- **Opt-in text wrapping**: `<text wrap="true">` / `ElementOptions.wrap` word-wraps a text leaf through the existing span-paragraph machinery (a single-span paragraph, no forked text pipeline), wrapping at the width the widget receives and reserving the wrapped height in columns. Default stays the single-line path, byte-identical, in both markup engines.
- **Markdown autolinks**: bare `http(s)://` URLs at word boundaries become link spans (GFM-style, trailing punctuation trimmed, paren-balance aware), and `#123` issue references linkify behind `Options.issue_link_base` / the `<markdown issue-link-base="...">` attribute (target = base ++ number, dev-2 MarkdownView boundary semantics) — refs stay plain text without the option since resolving them needs repo context.
- **Widget capacity**: per-view limits raised to real-app scale (256 widgets, 1024 display-list commands), with the runtime constructing strictly in place so no embedding can overflow a thread stack.
- **Engine reconciliation**: container intrinsic sizing measured engine-side; scroll offsets and editable text both survive rebuilds until the source changes (programmatic changes win); accessibility actions derive from typed handlers.
- **CI**: native example tests against real GTK, macOS GPU smokes, a headless Linux canvas smoke under Xvfb, and native template scaffolding now run in CI.
- **Windows canvas smoke in CI**: the Windows gpu_surface software path (child HWND, WM_TIMER, SetDIBitsToDevice) is now CI-protected — `windows-canvas-smoke` cross-compiles ui-inbox for x86_64-windows-gnu and drives it under Wine + Xvfb, asserting software presentation, automation widget clicks, and real XTEST pointer/keyboard input.
- **Windows canvas IME composition**: the Windows gpu_surface host now maps `WM_IME_COMPOSITION` (plus start/end and focus loss) onto the same shared IME events the macOS and GTK hosts emit — GCS_COMPSTR preedit updates become `ime_set_composition` with the full preedit text and a UTF-8 byte cursor from GCS_CURSORPOS, an emptied or abandoned composition becomes `ime_cancel_composition`, and GCS_RESULTSTR follows the AppKit/GTK commit contract (result equal to the pending preedit commits the buffered composition; different text cancels first and inserts as plain `text_input`). `WM_IME_COMPOSITION` is fully handled so the IME never synthesizes duplicate WM_CHARs, and `ISC_SHOWUICOMPOSITIONWINDOW` is suppressed so the canvas draws the preedit inline. Mapping covered by host unit tests and source-contract checks; verified compiling and non-regressive under Wine (Wine cannot drive a real IME headless — real-hardware IME verification remains pending).
- **Windows effects verification under Wine**: `windows-effects-smoke` cross-compiles `examples/effects-probe` for x86_64-windows-gnu and proves the effect system's live Windows path under Wine + Xvfb — `fx.spawn` launches `cmd.exe`, streamed lines land in the model through the worker → `PostMessageW` wake → loop-thread drain pipeline (wake events asserted in the trace log, not inferred), and `fx.cancel` terminates the child with the line count provably frozen. The probe's stream command is now platform-conditional (`/bin/sh` on POSIX, `cmd /c for /L` paced by `ping` on Windows).

### Bug Fixes

- **GTK shell**: initial window allocation now reflows shell views, and overlay z-order lets native overlays receive pointer input.
- **Linux startup**: the runtime is heap-allocated in all runners, fixing a startup crash under default stack limits.
- **Docs site security**: `next` and `postcss` advisories patched.

### Contributors

- @ctate

## 0.3.0

<!-- release:start -->

### New Features

- **Keyboard shortcuts**: Add app-level keyboard shortcuts with manifest and runtime configuration, native delivery to Zig `Event.shortcut`, and typed JavaScript `window.zero` shortcut events (#62).
- **Manifest-driven runner shortcuts**: Load `app.zon` shortcuts automatically in generated runners, with a `RunOptions.shortcuts` override for apps that build shortcut lists in Zig (#62).

### Improvements

- **Shortcut documentation and validation**: Document the `app.zon` shortcut schema, portable key names, modifier behavior, backend support, and validation limits (#62).
- **Windows WebView2 child bridges**: Enable bridge-enabled trusted child WebViews on Windows WebView2, bringing that backend closer to the macOS and Linux system WebView behavior (#62).

### Bug Fixes

- **Shortcut matching and delivery**: Fix shortcut modifier handling, shifted punctuation matching, backend event routing, and edge cases across AppKit, GTK, WebView2, and macOS CEF (#62).

### Contributors

- @ctate
<!-- release:end -->

## 0.2.0

### New Features

- **Layered WebView runtime**: Model each native window as a stack of named WebViews, including the reserved startup `main` WebView and child WebViews with frame, layer, zoom, transparency, routing, resizing, reload, and close support across the native backends (#28).
- **JavaScript WebView API**: Add typed `window.zero.webviews.*` helpers and `zero-native.webview.*` built-in bridge commands for create, list, setFrame, navigate, setZoom, setLayer, and close operations (#28).
- **Isolated child WebViews**: Keep child WebViews bridge-isolated by default, allow trusted child chrome with `bridge: true`, enforce navigation policy on child URLs, and scope WebView commands to the calling native window (#28).
- **Browser example**: Add a browser-style example that demonstrates layered WebViews, browser controls, isolated page content, frontend asset handling, and the root `zig build run-browser` command (#28).
- **zero-native skills**: Ship CLI-served agent skills and reference material for building and automating zero-native apps (#38).

### Improvements

- **WebView and bridge documentation**: Document WebView APIs, built-in bridge commands, security boundaries, backend support, packaging, testing, and app model updates (#28, #38).
- **WebView smoke coverage**: Extend automation smoke tests to exercise child WebView create, resize, navigate, and close operations for system WebView and macOS CEF builds (#28).
- **CEF runtime builds**: Harden the CEF runtime workflows across macOS, Linux, and Windows, including Windows runtime build fixes (#25, #26).
- **macOS compatibility**: Set the native app baseline to macOS 11 (#22).
- **Contributor guidance**: Clarify signed commit requirements and contribution PR guidance (#10).

### Bug Fixes

- **Windows WebView builds**: Fix Windows WebView build failures before the layered WebView release.
- **React example dependencies**: Include the missing React example type dependencies (#11).
- **GitHub release notes**: Avoid duplicate contributor lists when creating GitHub releases (#24).
- **macOS package permissions**: Preserve executable permissions for packaged macOS app binaries (#39).

### Contributors

- @Anshuman71
- @PrathamGhaywat
- @ctate

## 0.1.9

### New Features

- **Linux and Windows desktop support**: Add platform-aware CEF tooling, Linux and Windows desktop build paths, Windows native host plumbing, and cross-platform CEF runtime packaging/release coverage.

### Contributors

- @ctate

## 0.1.8

### Bug Fixes

- **Install completion delay** - Drain redirected GitHub responses during postinstall so npm exits immediately after the native binary is installed.

### Contributors

- @ctate

## 0.1.7

### Improvements

- **Install progress** - Show native binary download progress and checksum status during the npm postinstall step.

### Contributors

- @ctate

## 0.1.6

### Improvements

- **Init next steps** - Print the follow-up commands after scaffolding so users can immediately run their new app.

### Contributors

- @ctate

## 0.1.5

### Bug Fixes

- **macOS local asset loading** - Prefer current-directory asset roots during local `zig build run` so Vite-based examples render their production bundles instead of blank windows.

### Contributors

- @ctate

## 0.1.4

### Bug Fixes

- **Scaffolded app builds** - Ship the framework source tree in the npm package and make `zero-native init` point generated apps at the installed package root so `zig build run` can resolve `src/root.zig`.
- **Long scaffold names** - Keep generated Zig package names within Zig's 32-character manifest limit.
- **Next scaffold builds** - Include the Node.js type package that Next expects for TypeScript projects.
- **Frontend dependency versions** - Generate projects with current Next, React, Vite, Vue, Svelte, and plugin versions.
- **Svelte scaffold builds** - Use the matching Svelte Vite plugin in generated Svelte projects.

### Contributors

- @ctate

## 0.1.3

### Bug Fixes

- **CLI package homepage** - Point npm package metadata at `https://zero-native.dev`.
- **Current-directory init** - Support `zero-native init --frontend <framework>` as shorthand for scaffolding into the current directory.
- **CLI usage errors** - Exit cleanly for invalid CLI arguments instead of printing Zig stack traces for expected user input mistakes.

### Contributors

- @ctate

## 0.1.2

### Bug Fixes

- **npm install fallback** - Do not fail package installation or point global shims at missing binaries when a native release asset is unavailable.
- **Release asset ordering** - Upload the macOS arm64 native binary and `CHECKSUMS.txt` before publishing the npm package so postinstall downloads succeed immediately.

### Contributors

- @ctate

## 0.1.1

### Bug Fixes

- **npm package homepage** - Add the zero-native repository homepage to the CLI package metadata.
- **Chromium example launches** - Stage the CEF framework correctly for the `hello` and `webview` examples when running with `-Dweb-engine=chromium`.
- **Linux WebKitGTK build** - Update navigation policy and external URI handling for current WebKitGTK and GTK4 headers.
- **macOS WebView smoke test** - Use the emitted CLI binary and queue automation early enough for stable CI smoke tests.

### Release Process

- **GitHub releases** - Create missing GitHub releases from marked changelog entries when npm already has the version.
- **CEF runtime release** - Publish the prepared macOS arm64 CEF runtime used by `zero-native cef install`.

### Contributors

- @ctate

## 0.1.0

### Initial Release

- Initial pre-release development version.
