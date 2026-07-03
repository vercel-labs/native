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
- **Automation screenshots**: `zero-native automate screenshot` renders a canvas view through the reference renderer to a deterministic PNG, enabling golden-image verification for tests and agents.
- **`.zml` tooling**: `zero-native markup check` (instant grammar validation with positions), `zero-native markup lsp` (diagnostics, completion, hover), and a TextMate grammar with editor setup under `editors/zml/`.
- **Framework build helper**: `zero_native.addApp` gives an app a complete build from a five-line build.zig; the shared runner lives in the framework.
- **Mobile canvas embed host**: `zero_native.addMobileLib` compiles a user's `UiApp` into the mobile embed static library — `zero_native_app_create` instantiates it on a gpu_surface scene (window 1, "mobile-surface") pumped by the host's frame callback, frames render to pixels retrievable over the ABI (`zero_native_app_render_pixels`), and the previously missing scroll/viewport-state/frame-state/semantics-by-id/text-geometry symbols are exported. The fixed WebView shell remains the default `zig build lib`; `examples/mobile-canvas` shows the new seam.
- **iOS simulator presentation**: the mobile embed library cross-compiles with `-Dtarget=aarch64-ios-simulator`, and a minimal ObjC shim (`examples/mobile-canvas/ios/`) presents the host's CPU-rendered frames on a CAMetalLayer — CADisplayLink pumps `zero_native_app_frame`, changed frames upload via `MTLTexture replaceRegion` and blit to the drawable. `run.sh` builds the .app bundle without an .xcodeproj, installs it on a simulator, and verifies a non-blank screenshot; `zig build lib -Dmobile=true` builds ui-inbox the same way.
- **iOS simulator input fidelity**: the canvas shim forwards real UITouch sequences through the embed ABI — taps press widgets, over-slop pans drive the existing scroll reconciliation, and other drags keep pointer-drag semantics; the system keyboard shows/hides off the new `zero_native_app_text_input_state` export (textbox focus = IME intent), typed text flows through `zero_native_app_text`, and UITextInput marked text maps onto the same `zero_native_app_ime` composition path desktop hosts use. `zero_native_app_set_automation_dir` points the runtime's automation snapshots into the app's data container, and `examples/mobile-canvas/ios/verify_input.sh` proves it hardware-true on the simulator with a generated XCUITest runner (no .xcodeproj): injected tap grows the inbox, the keyboard appears/types/hides, and drag-scroll moves the list offset — all asserted against automation snapshots.
- **Mobile safe-area layout**: viewport chrome insets are a runtime concept — `Runtime.viewportInsetsForWindow` combines the surface's safe-area and keyboard insets, and `UiApp` deflates widget layout by them while the canvas keeps painting edge to edge. Desktop reports zero insets, so desktop layout is unchanged; on iOS, content lays out clear of the Dynamic Island and home indicator, relayouts on real rotation, and honors the 3x device scale — verified by `examples/mobile-canvas/ios/verify_layout.sh` (snapshot assertions plus an XCUITest rotation, no .xcodeproj) and pure-Zig embed tests.
- **Mobile platform text metrics**: new embed export `zero_native_app_set_text_measure` registers a shim-provided measure callback as the runtime's text-measure provider — the mobile counterpart of the desktop `measure_text_fn` service. The iOS shim registers a CoreText/UIFont measure mirroring the macOS host, so layout uses real typographic widths (launch with `--estimator-text-metrics` for the deterministic estimator); a negative return per run falls back to the estimator, and goldens stay byte-identical.
- **`native-ui` agent skill**: the complete markup and UiApp authoring reference, served through the skills CLI.
- **Inline styled text spans**: a `.text` paragraph can carry mixed-style runs — weight (regular/medium/bold), italic, monospace, color token overrides, underline, strikethrough, a relative size scale, and link payloads — in one wrapped block. Wrapping and measurement are span-aware through both the deterministic estimator and the platform text-measure provider (weights ride reserved sans font-id variants, so measured text always matches drawn text); stacked span paragraphs reserve their real wrapped height. Authored via `ui.paragraph(.{ .on_link = Ui.linkMsg(.open_url) }, spans)`; single-style text keeps its classic byte-identical path.
- **Real span faces on macOS**: the reserved sans span font ids (3 medium, 4 bold, 5 italic, 6 bold italic) resolve to real faces in the AppKit host's shared draw + measure font resolution — Geist Medium/Bold by name when installed, an NSFontManager family conversion otherwise, and the matching SF weight as the guaranteed floor (weighted ids never fall back to the regular face); italics prefer a real italic face and otherwise synthesize a sheared font matrix so the slant is always visible without changing advance widths. The iOS embed shim's CoreText measure callback mirrors the same id-to-face mapping so measured layout matches a future iOS draw path. Ids 0-2 and the deterministic estimator are byte-for-byte unchanged.
- **Hit-testable links**: link spans grow hit-area children with `role=link` semantics (pointer cursor, automation-clickable, focusable); pressing one dispatches the paragraph's `on_link` message carrying the link payload through the ordinary typed handler table.
- **`zero_native.markdown`**: a GitHub-flavored-markdown subset mapped onto the widget tree + span model — `#`–`###` headings (token-derived sizes), paragraphs with bold/italic/code/strikethrough/links, bullet/ordered/task lists (task items are display-only disabled checkboxes), fenced code blocks on a surface panel, blockquotes, horizontal rules, and `<details>`/`<summary>` collapsibles driven by caller-owned expanded flags (`details_expanded` + `on_details`). Std-only, arena-allocated, capacity-bounded; malformed input degrades to literal text and never fails the build fn. dev-2's README renders through it in a reference-renderer golden test.
- **Full component catalog in markup**: every built-in component is now expressible in `.zml` — 26 new elements covering tab strips and grouped controls (`tabs`, `toggle-group`, `toggle-button`, `button-group`, `radio-group`, `breadcrumb`, `pagination`), tables (`table`/`table-row`/`table-cell` with structural validation), surfaces (`accordion`, `alert`, `bubble`, `dialog`, `drawer`, `sheet`, `resizable`, `dropdown-menu`), controls and leaves (`select`, `switch`, `avatar`, `tooltip`, `input`, `combobox`, `skeleton`, `spinner`) — implemented in both the interpreter and the comptime compiler with parity tests, plus teaching validator messages (misplaced table rows, element children inside text leaves). Kinds that fundamentally need Zig (icon/image assets, data-grid cell templates, anchored popovers) are documented exclusions guarded by a coverage test.

### Improvements

- **Widget capacity**: per-view limits raised to real-app scale (256 widgets, 1024 display-list commands), with the runtime constructing strictly in place so no embedding can overflow a thread stack.
- **Engine reconciliation**: container intrinsic sizing measured engine-side; scroll offsets and editable text both survive rebuilds until the source changes (programmatic changes win); accessibility actions derive from typed handlers.
- **CI**: native example tests against real GTK, macOS GPU smokes, a headless Linux canvas smoke under Xvfb, and native template scaffolding now run in CI.
- **Windows canvas smoke in CI**: the Windows gpu_surface software path (child HWND, WM_TIMER, SetDIBitsToDevice) is now CI-protected — `windows-canvas-smoke` cross-compiles ui-inbox for x86_64-windows-gnu and drives it under Wine + Xvfb, asserting software presentation, automation widget clicks, and real XTEST pointer/keyboard input.

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
