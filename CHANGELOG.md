# Changelog

All notable changes to the Native SDK (formerly zero-native) will be documented in this file.

## 0.4.0

<!-- release:start -->

### New Features

- **zero-native is now the Native SDK**: The toolkit, CLI, and packages are renamed end to end — the CLI binary is `native`, the Zig module and build helper are `native_sdk` (`native_sdk.addApp`, `native_sdk.addMobileLib`), the embed C ABI prefix is `native_sdk_*`, and the npm CLI package is `@native-sdk/cli`.
- **Native-rendered apps by default**: `native init` scaffolds a native-rendered app — a declarative `.native` markup view plus Zig logic on the `UiApp` runtime (a `Model`, a `Msg` union, `update`, and a view) — with web frontends still available via `--frontend next|vite|react|svelte|vue`.
  - Native markup: HTML-inspired views with flex layout, `{bindings}` to model fields and functions, typed `on-*` message dispatch, `for`/`if`/`else` structure tags (multi-child `for` bodies, `<else>` empty states), and keyed identity; a deliberately closed grammar keeps logic in Zig.
  - Comptime compilation: views compile at build time into direct field access — release binaries carry no parser, and markup or binding mistakes are compile errors with line and column.
  - Hot reload: dev builds watch every `.native` file — imported components and fragments embedded in Zig views included — and update the running window in place, preserving model state, selection, and widget identity.
  - Expressions in bindings: arithmetic, comparisons, boolean logic, string concatenation, and a closed 17-function formatting library (`fixed`, `thousands`, `date`/`time`, `pad`, `plural`, ...), evaluated bit-identically by both markup engines; string-producing model functions bind directly through the build arena.
  - Cross-file components: `<import>` splices template files (transitively, with cycle and duplicate diagnostics), template args take literal defaults, `<slot/>` marks where use-site children land, and `native eject component` transfers a library composite's canonical source into your app exactly once.
  - `canvas.Ui`, the programmatic builder under the markup: structural widget identity, typed message handlers, flex-first layout, and per-element `opacity`/`transform` render channels for animated composition.
- **The model–view contract, checked in both directions**: `native check` verifies every binding path, iterable, key, message tag, payload type, and expression in every `.native` file against the app's reflected `Model`/`Msg` surface in milliseconds — with did-you-mean suggestions and a dead-state lint for model fields and messages no view uses.
- **Markup tooling**: `native markup check` (instant validation with positions), a language server (diagnostics, completion, hover), a TextMate grammar with editor setup, `native markup dump` over the canonical serialized document format, and the `native-ui` agent skill — the complete authoring reference, served through the skills CLI.
- **Two-way tooling**: `native automate provenance` reports where a live widget was authored (file, byte span, template instantiation chain), and `native automate edit` writes minimal-diff attribute and text edits back into the markup source — validated before anything touches the file, with hot reload closing the loop.
- **Full component catalog**: every built-in component is expressible in markup — tabs, tables, dialogs, drawers, sheets, selects, comboboxes, accordions, menus, badges, avatars, tooltips, inputs, and more — implemented in both engines with parity tests, alongside new composites in markup and Zig:
  - Charts (`<chart>` / `ui.chart`): line, area, bar, and band series drawn through the vector path pipeline with design-token colors, deterministic downsampling past 256 points, axis labels on a nice-step lattice, and pointer hover details.
  - Markdown (`<markdown>` / `native_sdk.markdown`): a GitHub-flavored subset — headings, inline styles, links, lists, task lists, fenced code, blockquotes, pipe tables, autolinks, and model-driven collapsibles — that degrades malformed input to text and never fails a build.
  - Disclosure trees with the full ARIA tree keymap, steppers and timeline items, input groups with focus-within rings, chat bubbles with reaction pills and thread-width caps, and a `ui.nav` push/pop page container with stable per-page state.
  - Resizable split panes with model-owned fractions, keyboard and assistive resize, and optional eased animation on model-driven moves.
  - Windowed virtual lists: viewport-sized widget budgets at 100,000 items, variable row extents that converge to measured truth without visible jumps, tail anchoring for chat transcripts, and `on_reach_end`/`on_reach_start` for infinite fetch and history loading.
  - Anchored floating surfaces (dropdowns, selects, popovers) that float above the tree with edge auto-flip; dismissal (Escape, click-outside, assistive dismiss) is a Msg the model owns, and focused selects get the full open/navigate/commit keymap.
  - Vector icons: an SVG stroke-icon subset parser, 50 curated built-in icons, leading or trailing icon slots on buttons, toggle chips, list and menu rows, badges, and timeline items, app-registered icons comptime-parsed from your own SVGs, model-bound icon names, and a loud missing-icon fallback.
- **Text engine**:
  - Inline styled spans — weight (resolved to real faces), italic, monospace, color tokens, underline, strikethrough, size scale, per-span backgrounds, and hit-testable links — wrap as one paragraph in Zig and markup alike.
  - Honest single-line text: unwrapped text elides with a trailing ellipsis by default, an `overflow` policy knob keeps the deliberate hard cut available, and word wrap is an explicit opt-in — paint always agrees with measurement.
  - `heading`/`display` typography rungs on the token ladder, first-class text alignment, and fixed grid column counts.
- **Selection and clipboard**: cmd/ctrl+C/X/V in editable fields through the platform clipboard, click-drag selection with copy on static text (surviving rebuilds, exposed to semantics and automation), and clipboard effects for app code.
- **Interaction model**:
  - Presses fall through to the nearest pressable ancestor, so any element with a handler is a real hit target — nested pressables resolve to the deepest one, and text selection still works inside pressable rows.
  - Press-and-hold, double-click, Enter as a list row's primary action, and an app-level key fallback (`Options.on_key`) with pinned precedence — quiet list rows stay transparent to app-owned selection models.
  - Source-driven `autofocus`, observable typed scroll events (`on_scroll`), a built-in search-field clear affordance, and a quiet-hover style knob for content tiles.
- **Effect system**: the update loop's command half — `update` gains an effects channel of bounded, key-addressed effects that deliver exactly one terminal Msg each and are fully testable against a deterministic fake executor:
  - `fx.spawn` runs subprocesses with streamed lines or whole-output collect mode (stderr tail included), raisable per-effect line bounds, and cancellation; `fx.fetch` runs HTTP(S) requests with an explicit failure taxonomy, timeouts, and a streaming response mode for line-oriented endpoints.
  - `fx.readFile`/`fx.writeFile` persistence, `fx.startTimer`/`fx.cancelTimer`, `fx.writeClipboard`/`fx.readClipboard`, `fx.registerImageBytes` for runtime images, `fx.closeWindow`/`fx.minimizeWindow`, and the `init_fx` boot hook so loading states are in the very first paint.
  - A facade time API (`nowMs`, `monotonicMs`) plus `Clock`/`TestClock` seams for deterministic time-dependent logic.
- **Audio, end to end on five platforms**: `fx.playAudio` with full transport (pause, resume, stop, seek, volume), real decoded durations, position ticks, and honest completion and failure reports — AVFoundation on macOS, Media Foundation on Windows, GStreamer on Linux, and the experimental mobile hosts on iOS (AVFoundation) and Android (MediaPlayer).
  - Streaming with a verified track cache: URL sources resolve local file, then size-verified cache, then progressive stream (filling the cache in parallel for the next play), with honest `buffering` states and explicit failures — never a silent stall.
  - Real spectrum analysis on macOS, Windows, and Linux: 32 log-spaced bands at ~25 Hz from the app's own playback, journaled at the effect boundary so record/replay repaints identical bars; hosts that cannot analyze report the capability honestly instead of fabricating bands.
- **Images**: a platform decode seam (CGImageSource, gdk-pixbuf, WIC) so the toolkit bundles no image decoders; runtime image registration renders through every path — GPU packets, software presentation, and screenshots — with pixels riding an out-of-band upload channel so image-bearing frames stay on the GPU path; avatars take a bound image with initials fallback.
- **Windowing and chrome**: model-declared secondary windows (presence is visibility; a user close dispatches a Msg), enforced window minimum sizes, and present-before-show so a canvas window never appears blank.
  - Titlebar control on all three desktops: `hidden_inset`, a tall unified-toolbar variant, and fully `chromeless` styles; markup `window-drag` regions; and an `on_chrome` hook carrying the real overlay insets and control-cluster frames — with real system window controls preserved on Linux client-side decorations and Windows DWM caption buttons.
  - Native context menus, declared per widget in Zig or markup (`<context-menu>`): the real OS menu where one exists, an anchored canvas surface elsewhere, editable-text cut/copy/paste defaults, and full automation support for enumerating and invoking items.
  - A menu-bar status item with model-driven title and menu; canvas and WebView panes composed in one window; adoption of app-owned native views into the layout (`adoptViewSurface`); and native scroll drivers on macOS that give every scroll region OS momentum, rubber-band overscroll, and the system overlay scrollbar with zero app code.
- **Experimental iOS and Android host tiers — the toolkit owns the entire mobile app**: complete UIKit and Android hosts ship in the SDK over the embed C ABI, an app project carries zero host code, and embedding a hand-written host stays first-class.
  - `native dev --target ios|android [--device name]` builds, installs, and launches on a simulator or emulator and streams the app log; `native package --target ios` emits an archive-ready Xcode project and `--target android` a complete generated host project plus a debug-signed APK — no build-system project, no plugin matrix.
  - Touch, soft keyboard, and IME forwarding; safe-area and keyboard insets on the window-chrome channel plus host-reported form factor; platform text metrics; platform audio and image decoding; and damage-rect rendering so a keystroke repaints and uploads only the changed region instead of the whole screen.
  - Declared platform chrome: apps project a tab set and primary action as a real system tab bar, and a model-owned page stack drives real push/pop transitions with the system edge-swipe back gesture — navigation state stays in the model and replays deterministically from the Msg journal.
  - The soundboard ships the proof: one codebase, a desktop composition plus a compact phone shell selected by the host-reported form factor, running on the simulator via `native dev --target ios`.
- **Theme packs and design tokens**: named packs — the default register plus `geist`, the design register of the bundled Geist type family — compose with the live system appearance; interaction-state formulas, control metrics, and focus-ring geometry are all token-stated; new `success`/`warning`/`info` semantic color tokens; the stock theme follows the OS light/dark, high-contrast, and reduce-motion settings live; modal scrims blur the content behind them for real; app-registered TrueType fonts resolve everywhere a font id rides.
- **Deterministic rendering core**: a bounded, std-only TTF parser inks real anti-aliased glyphs (bundled Geist and Geist Mono) on every headless path — screenshots, mobile embeds, pixel goldens — while layout measures exactly what gets inked; an allocation-free vector rasterizer with bit-identical cross-platform coverage draws paths, icons, and charts.
- **Automation and testing**: `native automate` gains `assert` (regex polling against the accessibility snapshot), deterministic PNG screenshots, per-stage frame profiling (`profile on`), and widget verbs for hold, secondary click, context-menu invocation, drag, wheel, and tray actions.
  - Deterministic session record and replay: journal every platform event and effect result, then re-run headlessly with checkpoint verification (`native automate record` / `replay --verify`).
  - `native init` scaffolds a CI workflow: null-platform tests for every frontend plus a Linux automation smoke that drives the app's real binary under Xvfb.
- **Accessibility as machine checks**: unnamed interactive controls, icon-only controls without labels, and misused roles are validation errors (degradations report as warnings; `--strict` promotes); a deterministic tree-level audit catches labels that resolve empty at runtime, focus-unreachable widgets, and duplicate sibling labels; and assistive actions actuate through the same activation paths keyboard users take instead of reporting success on nothing.
- **Showcase examples**: calculator, notes (folders, trash, context menus), soundboard (a real music library with playback and search), deck (a radically re-skinned sibling proving theme packs and chrome passes), system-monitor (live effects-driven sampling), markdown-viewer (split-pane editor and preview), and feed (a 100,000-post virtual list) — each with a deterministic test suite, and a prepared real-music catalog that streams out of the box.
- **Docs site**: a full Components section (34 pages) where every preview is rendered offscreen by the engine itself and upgrades on hover to a live engine instance running in-page via a ~306 KB (gzip) wasm build; attribute tables generate from the validator's own vocabulary so docs cannot drift; the whole site restructured native-first with new State & Data Flow, App & Runtime, Theming, and Testing in CI pages.
- **Zero-config toolchain and distribution**: `native dev|build|test|check` work in a directory holding only `app.zon` and `src/` (`native eject` writes the build files exactly once when you want to own them); the pinned Zig toolchain downloads on consent with checksum verification; and `@native-sdk/cli` installs from npm with zero scripts — eight platform binaries plus the SDK source, so `native init && native dev` work offline right after install.
- **One-image app icons**: drop a single square PNG or SVG in `assets/`, and `native package` generates everything — a masked, grid-correct macOS `.icns`, a multi-size Windows `.ico`, Linux hicolor PNGs, and iOS/Android catalog icons — with exact linear-light downscales, teaching errors for bad sources, and no external tools.

### Improvements

- **Performance — frame cost scales with what changed, not view size**:
  - GPU packets ride a compact binary encoding (~10x smaller than JSON, ~40x effective capacity — text-heavy frames no longer silently fall back to software rendering), steady-state frames ship incremental patches (~20x less wire per interaction), and repaints derive per-change dirty-rect lists so pixels between two far-apart changes stay retained.
  - Per-command raster caches stop re-rasterizing unchanged content (host draw p50 dropped an order of magnitude on animated views); frame planning and widget reconciliation moved from quadratic scans to indexed lookups (end-to-end interaction p50 improved ~2.3-3.2x on large views); backdrop blur cost no longer scales with radius; a click emits one display list instead of three.
  - Launch to glass: the first canvas frame presents before the event loop starts, first paint rasterizes across cores, the main WebView is created lazily, and warm launches measured 150→120 ms on the heaviest showcase app; `NATIVE_SDK_WINDOW_TIMING=1` prints a per-phase launch breakdown.
  - Occluded windows throttle to a ~1 Hz heartbeat instead of spinning the frame clock (spectrum reports pause too); accessibility publishes only when the tree actually changed and defer off the input-to-glass path; frame pacing delivers exactly one event per display interval; input latency is measured to the responding present, honestly.
  - `zig build bench-render` runs deterministic interaction scenarios against committed per-scenario budgets, and a percentile GPU perf check gates first-frame and input-to-present latency in CI.
- **Component fidelity**: the built-in components land a refined default look, verified pixel-for-pixel in CI under both theme packs.
  - Measured control geometry and state washes, ring-offset focus rings, flat buttons with a quiet destructive treatment, segmented button groups rendered as one bar with collapsed seams, compact badges, and hairline tables.
  - Reworked accordion, tabs, alert, and card treatments with sensible per-kind layout defaults; skeletons pulse and the caret blinks; select menus read like menus (row highlight, trailing checkmark for the committed option).
  - Native cursor conventions (the pointing hand is reserved for true links), flat list rows, axis-aware separators, and edge-pinned scrolling with opt-in rubber-band overscroll.
- **Capacity and honesty**: per-view widget budgets quadrupled to 1024 nodes (command, glyph, and text budgets raised to match) with headroom telemetry in every snapshot; explicit `width`/`height` are definite bounds; layout overflow is diagnosed, dispatch errors degrade and record instead of exiting the app, and every effect-facing type and constant is exported from the `native_sdk` facade.
- **Teaching validation**: handlers on elements that can never receive them, `gap` on stacking containers, `wrap` on non-text elements, and literal glyphs outside the bundled font's coverage are all positioned teaching errors, enforced identically by the validator, both engines, and the language server.
- **Desktop parity**: the Linux and Windows hosts reach the macOS seam contract — app timers, appearance events, window options at create, interactive window moves, IME composition on Windows, and hidden-titlebar fidelity with real system controls; CI gains Windows canvas and effects smokes under Wine, a headless Linux canvas smoke, and a containerized Linux live-truth harness driving every showcase app on real GTK.
- **Observability**: automation snapshots report the live present path and mode, patch sizes, fallback reasons with byte counts, budget headroom, audio state, tray contents, and per-stage frame percentiles while profiling; `NATIVE_SDK_GPU_DRAW_TRACE=1` attributes every present.
- **Docs and skill accuracy**: the code-signing page documents the real ad-hoc Gatekeeper experience, form-control and picker docs match what the engine ships, the keyboard and interaction seams are documented where developers look, and stale commands and API shapes were fixed across the site.
- **Example polish**: showcase headers carry only working controls under hidden-inset titlebars, the soundboard adopts desktop list-selection conventions, notes gains Recently Deleted and dialog autofocus, the deck refined its hardware identity across feedback passes, system-monitor lands the standard settings flow, and every showcase app ships the zero-config scaffold shape with a real neutral default app icon.
- **Contributor workflow**: changelog fragments (`changelog.d/`) end merge conflicts on this file, and `scripts/gate.sh` runs a tiered local gate that scales with the diff.

### Bug Fixes

- **Input and focus**: clicked and tabbed-into fields always show a caret (drawn in the field's own ink, readable in every scheme); Escape dismisses surfaces opened from non-focusable triggers; Enter inserts a newline in textareas (the primary chord submits); programmatic focus is quiet on non-editables; composite rows hover, point, and press as one surface; cross-centered overflow distributes evenly.
- **Model-driven control state**: sliders, exclusive selections, and toggle-button chips follow the model when the source moves (a live drag is never yanked); disabled selection controls render disabled; idle disabled buttons no longer wear an accent outline.
- **Rendering correctness**: pixel snapping no longer wraps exact-fit text or elides exact-fit badges; packet text honors engine line breaks; text bounds cover glyph ink; mono runs read as monospace on every headless path; avatar initials center; the spinner actually spins and sizes to the icon register; offscreen screenshots clear with live tokens; render animations invalidate only the affected commands; one invalid UTF-8 byte can no longer hang the renderer; budget overflows apply atomically instead of tearing the retained tree.
- **macOS**: Debug builds no longer abort at launch on an SDK sanitizer trap; `resizable = false` is honored; frames keep pumping during live resize and menu tracking; occluded windows keep presenting and flush instantly on reveal; quitting mid-playback no longer crashes; the Chromium (CEF) host builds and runs again, verified live with child WebViews.
- **Windows and Linux**: Windows apps launch on real Windows (common-controls manifest, dynamic task-dialog resolution) and builds link again; embed input timestamps and network error classification fixed on Windows; Linux audio no longer sticks in a buffering state; a saturated frame loop no longer freezes GTK windows; runtimes heap-allocate in every runner, fixing startup crashes under default stack limits; GTK initial allocation and overlay z-order fixed.
- **Packaging**: signed bundles keep a valid code signature; packaged apps read their bundled assets and show their display name in the menu bar; archives are labeled with the real optimize mode; unbundled dev runs fall back to the embedded default Dock icon.
- **Automation and CLI reliability**: commands queue with delivery acknowledgments instead of overwriting a single slot; a landing command wakes an idle app (~4 ms consumption); CLI and app handshake on a protocol version, and stale publishers or binaries are refused loudly; parseable payloads land on stdout; clicks aim at the rendered control, not its stretched box; `native dev` runs Debug so hot reload is actually compiled in; no CLI verb exits silently, and `--help` exits 0 everywhere.
- **Hardening**: the markdown renderer survives hostile input (three quadratic blowups fixed, a fuzz corpus added); large models neither exhaust the comptime branch quota nor ride the stack (`UiApp.create` constructs in place); mobile embed libraries stage per target so cross-target builds cannot poison each other; oversized inline window sources fail loudly instead of leaving a blank window; docs live previews build, lay out with the selected pack's tokens, animate, and route keyboard shortcuts correctly.
- **Measured-label controls no longer elide under pixel snapping**: a control sized exactly to its measured label — toggle chips (the system monitor's "PID" sort chip painted "PI…"), buttons, segmented controls and tab triggers, menu and list rows, tooltips, checkbox/radio/switch labels, hug-sized status bars — could lose a fraction of a pixel to render-time geometry snapping and swap real glyphs for an ellipsis. Every measured-label intrinsic width now rounds UP to the snap grid (the badge rule from the previous round), the switch additionally reserves its snapped track extent, and themes without geometry snapping stay bit-identical.

### Contributors

- @ctate
<!-- release:end -->

## 0.3.0

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
