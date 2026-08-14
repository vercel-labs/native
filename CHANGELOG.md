# Changelog

All notable changes to the Native SDK (formerly zero-native) will be documented in this file.

## 0.9.1

<!-- release:start -->

### New Features

- **Multi-item macOS menu bars**: Apps can now manage independent, keyed status items with model-driven updates, events, automation, journaling, and regression coverage (#343).
- **Complete TypeScript file effects**: Secure, permission-gated effects now support bounded streaming reads, atomic writes, stat, append, and deletion while preserving deterministic record and replay behavior (#339, #350).
- **Actionable desktop notifications**: Notification replacement identifiers and actions dispatch through the ordinary command path on macOS, Windows, and Linux (#347).
- **Secondary-window lifecycle control**: Window descriptors can declare quit or hide-on-close behavior, preserve hidden-window identity when reopened, and expose the same model-driven window contract to TypeScript apps (#349, #351).
- **Mobile TypeScript cores and services**: TypeScript apps with services now compile into iOS and Android library archives, with mobile packaging and device-level runtime coverage (#346).

### Bug Fixes

- **Safe Linux alert dialogs**: GTK alert dialogs now initialize with a valid empty format string, avoiding a crash from a null constructor argument (#354).
- **Correct compiled-core tuple returns**: The SDK now pins the scriptc tuple-normalization fix and verifies bare-model and effect-tuple ABI returns with a compiled-core regression (#356).

### Improvements

- **Stronger TypeScript core guidance and diagnostics**: Subset rules now distinguish permanent guarantees from deliberately deferred capabilities and point authors to the appropriate service alternative (#345).
- **End-to-end services showcase**: The Feed Reader example now demonstrates the full TypeScript service workflow with typed feed parsing, shared data, fixtures, and replay coverage (#352).
- **Updated compiler integration**: scriptc advances through 0.0.31 with refreshed generated contracts, compatibility fixtures, and compiler-surface references (#344, #356).

### Contributors

- @ctate
- @ElSebas41
- @johnlindquist

<!-- release:end -->

## 0.9.0

### New Features

- **Ordinary TypeScript services behind a typed boundary**: Apps can place filesystem, process, JSON, regex, class, and exact-vendored npm work under `src/services/`; Native SDK generates the checked client and codecs, compiles a pinned static service executable, and carries keyed requests, typed streaming, cooperative cancellation, deadlines, supervision, and deterministic replay across the isolated boundary (#317, #321).
- **Optional in-process TypeScript services**: Services can use the same boundary through a linked, runtime-localized worker pool with per-key FIFO ordering, parallel independent keys, streaming, timeout and trap isolation, and replay that never starts the carrier; the explicit opt-in now follows the compiler's Windows, Linux, macOS, and cross-target matrix while the isolated child remains the automatic default (#334, #337).
- **Engine-owned model persistence**: TypeScript cores can persist committed models through capability-gated, atomically replaced snapshots with generated codecs, debounced writes, backup recovery, explicit restore and migration routes, rollback safety, and journal/replay support (#316).
- **SQLite record storage**: TypeScript and Zig apps can use a capability-gated record store for deterministic atomic CRUD effects backed by bundled SQLite across desktop and mobile hosts, with devhost parity and a complete Record Store example (#320).
- **Checked relational SQLite**: Append-only migrations, build-validated named SQL, transactions, generated typed commands and live-query subscriptions, replay, and the Relational Notes example make relational SQLite a first-class offline data layer across desktop and mobile (#326).
- **Model-driven menu-bar apps**: TypeScript apps can derive status-item labels, icons, tooltips, and rich menus from committed model state, while new macOS effects control hidden startup, fullscreen, Dock visibility, and launch-at-login behavior across both native hosts (#311, #314).
- **Platform services for TypeScript cores**: Typed effects now open external URLs, reveal filesystem paths, and format local time through validated macOS, Linux, and Windows backends (#315).
- **App-scoped credentials**: TypeScript and Zig cores can store, load, and delete credentials through capability- and permission-gated native providers, with redacted journals, deterministic replay placeholders, and hermetic devhost stores across desktop and mobile (#335).
- **Cross-compiled TypeScript cores**: The external core compiler now builds Linux and Windows GNU targets from macOS, Linux, or Windows and macOS targets from macOS, with target-independent contracts and cross-platform end-to-end batteries for Windows and Linux musl (#340).

### Bug Fixes

- **Working documentation root**: `/docs`, `/docs/`, and the matching Markdown route now resolve to the Introduction instead of ending at a 404 (#338).

### Improvements

- **Faster retained desktop frames**: Animation pumping and Windows wake scheduling now avoid stalled or redundant work, profiling uses monotonic frame-correlated telemetry, and physical macOS and Windows performance gates protect input latency and frame budgets (#313).
- **Measured, compiler-truth service tooling**: A dedicated TypeScript Services reference documents the two-tier model and failure semantics; production-carrier benchmarks measure cold start, latency, and throughput; generated compiler-surface references and manifest diffs keep capability claims mechanically honest; and scriptc advances through 0.0.28 with refreshed contracts and calibration (#325, #327, #328, #329, #333, #336).

### Contributors

- @ctate
- @carvalab
- @Railly
- @camilocbarrera

## 0.8.4

### New Features

- **Streaming fetch responses for TypeScript cores**: `Cmd.fetch` can now deliver line-framed HTTP responses through typed message arms with deterministic terminal errors, loud cancellation, duplicate-key rejection, and bounded line sizes; the rebuilt Chatbot example streams Vercel AI Gateway replies with live model selection and a Stop action (#300).
- **Desktop audio capture**: TypeScript cores can start bounded, timestamped microphone or system-output PCM streams on macOS and Windows with explicit lifecycle, permission, drop-count, and replay handling; the new Voice Memo example records, saves, and plays WAV files (#303).
- **Customizable macOS DMG packaging**: `native package` now creates polished drag-to-Applications disk images with generated or custom Retina backgrounds, configurable Finder geometry, positioned app and Applications entries, and staged files, directories, or links (#304).
- **Live TypeScript theme packs**: zero-config TypeScript apps can export `themePack(model)` to switch the built-in theme pack from app state without losing live system scheme, accessibility, accent, or scale inputs (#308).

### Bug Fixes

- **Smooth macOS dialog blur**: Host backdrop blur now uses an optimized three-pass Gaussian approximation and correct dirty-region invalidation, eliminating flat or stale dialog backgrounds while preserving the established scrim treatment (#299).
- **Byte-accurate PTY event keys**: TypeScript PTY event routes now expose echoed session keys as `Uint8Array`, matching the byte-text host, generated facade, and external-core contract (#307).
- **Reliable keyboard widget navigation**: Interactive canvas lists, trees, menus, and anchored controls now retain logical focus across clipped rows, scroll keyboard targets into view, and paint active and focus-visible states consistently (#308).

### Improvements

- **TypeScript component gallery**: The GPU component showcase is now a TypeScript core and Native markup app with isolated interactive specimens, model-driven Default and Geist switching, clearer navigation, and dedicated smoke coverage (#308).

### Contributors

- @ctate
- @marcusschiesser
- @NyxTools-M

## 0.8.3

### Bug Fixes

- **Packaged TypeScript app assets**: Runtime asset lookup now finds bundled macOS resources before the process working directory, so Native markup boot images such as the Kanban agent avatars render after launch (#297).
- **Unclipped drag landing motion**: Dropped cards now stay in the lifted drag layer through their landing animation while neighboring reflow remains clipped within its swimlane (#297).

### Improvements

- **Denser Kanban showcase**: The seeded board now includes twice as many Jira-style tickets and removes redundant issue glyphs from card metadata (#297).

### Contributors

- @ctate

## 0.8.2

### New Features

- **Native drag and drop for TypeScript apps**: Native markup's new `on-drag` channel delivers live, release, and cancellation geometry to compiled cores while the renderer lifts the source under the pointer, preserves one globally keyed insertion slot, animates neighboring items, and supports Escape cancellation; TypeScript cores can also map native multi-file drops into ordinary deterministic messages through `dropMsg` (#285).
- **Desktop notifications from model cores**: TypeScript apps can return fire-and-forget `Cmd.showNotification` effects and Zig apps can call `fx.showNotification`, with bounded validation and suppression during fake execution and session replay (#283).

### Bug Fixes

- **Explicit zero canvas padding**: Programmatic and compiled or interpreted Native markup views now preserve `padding="0"` instead of replacing it with the widget kind's default padding (#288).

### Improvements

- **TypeScript-first app authoring guidance**: Repository instructions, bundled skills, examples, package documentation, and the docs site now consistently lead with TypeScript cores and Native markup for new apps while keeping Zig as the explicit alternative and toolkit-extension tier (#284).
- **Agent ticket Kanban showcase**: The TypeScript Kanban example now presents numbered OpenAI- and Claude-assigned tickets, uses an icon-only add action, keeps columns scrollable, and extends its end-to-end coverage for the updated drag geometry (#295).

### Contributors

- @ctate
- @johnlindquist
- @Railly

## 0.8.1

### New Features

- **Safe presentational HTML in Markdown**: Markdown now lowers common GitHub-style inline and block HTML into native widgets, including links, details, aligned containers, and caller-resolved images, while scripts, styles, forms, embeds, event attributes, and unsupported or malformed markup remain inert literal text (#280).

### Bug Fixes

- **Reliable resolved Markdown images**: image discovery now follows renderable block starts, canonicalizes entity-encoded URLs consistently between loading and lookup, preserves aspect ratios within declared bounds, honors centered and end alignment, and ignores images inside comments, unsupported markup, code, and preformatted blocks (#281).
- **Payload-free HTTP write requests**: `Effects.fetch` now sends an explicit zero-length body for POST, PUT, and PATCH requests without a payload, preventing debug-build crashes and emitting the required `Content-Length: 0` header (#277).

### Improvements

- **History-driven release notes**: release preparation now builds the complete changelog entry and contributor list from the commits since the previous release, replacing the per-change fragment workflow (#278).

### Contributors

- @ctate
- @Railly

## 0.8.0

### New Features

- **Compiler-truth checks for TypeScript cores**: `native check` now ends with the pinned external core compiler's analyzer over the entry with the shipped SDK declarations mapped, so check and build share one compiler verdict. Type errors the frontend's own line would miss fail with the compiler's diagnostics verbatim; an analyzer that cannot reach a verdict defers to the build instead of wedging check.
- **TypeScript cores compile through the external core compiler**: the frontend checks `src/core.ts` and emits its contract sidecar, the exact-pinned compiler builds a native archive, and the app links a generated mirror over it — no JS runtime in the binary, nothing to configure.
- **The TS-to-Zig transpiled lane is removed** (a deliberate pre-1.0 break): `core_compiler = "transpiler"` in app.zon (and `-Dcore-compiler=transpiler`) is refused with a teaching, and `native check` runs the checker and contract only — no emitted Zig lands under `.native/check/`.
- **The compiler is a package dependency**: it ships exact-pinned with the SDK's `packages/core` (repo checkouts install it with `npm ci` there; an npm-installed CLI carries it automatically).
- **The core dev loop is restart-shaped**: markup hot reload and the instant `native dev --core` node loop are unchanged, and a core edit now pays a native compile measured in seconds on rebuild.
- **TypeScript cores are desktop-only for now**: a mobile target with `src/core.ts` is taught before lane selection (the external toolchain does not target mobile yet); Zig and markup cores stay fully supported on mobile.
- **Shipped type declarations**: `@native-sdk/core` now ships generated `sdk/*.d.ts` declaration files beside its TypeScript sources, so external tooling can resolve the SDK's types without compiling them.

### Improvements

- **Leaner TypeScript toolchain installs**: the unused `@typescript/typescript6` compatibility wrapper is no longer a dependency of `@native-sdk/cli` or `@native-sdk/core`. The frontend already imports its compiler directly through the exactly pinned `@typescript/old` alias, while consumer trees carrying their own wrapper remain unaffected.

### Contributors

- @ctate

## 0.7.2

### New Features

- **Geist-style code diffs**: `ui.code` and `<code>` can mark added and removed logical lines with theme-aware full-row washes, renderer-owned `+`/`-` markers, optional line numbers, and unchanged syntax-highlighted clipboard source.

### Improvements

- **Verified Zig setup**: repository and generated CI workflows now install Zig with `vercel-labs/setup-zig`, including signed archive and checksum verification.

### Bug Fixes

- **Theme-accurate disabled buttons**: disabled buttons now keep shadcn's knockout label treatment in the default theme and use Geist's gray-100/gray-700 swap, gray-400 edge, and distinct half-opacity tertiary register in the Geist theme.
- **Canonical documentation routes**: documentation now lives under `/docs/`, with permanent redirects from every previous URL, explicit canonical metadata, `.md` siblings, and a generated `llms.txt` that stays aligned with each page's canonical MDX source.
- **Geist primary tabs match the design system**: tab strips now use the reference 50px row, full-width bottom rail, content-hugging 14px triggers, 24px spacing, and 16px icon treatment without changing default-theme pill tabs; the GPU component gallery now pairs a compact theme picker with a scrollable component tree and focused specimen views.
- **Quiet Windows subprocesses**: `Effects.spawn` no longer opens or flashes a console window when a GUI or tray app launches a console-subsystem helper such as `node.exe`; interactive terminal children remain on the separate PTY API.
- **Responsive Windows GPU surfaces**: Windows now renders retained binary canvas packets with Direct2D and DirectWrite, applies dirty-region patches (including edge-safe GPU-resident backdrop blur), and limits RGBA-to-BGRA conversion and invalidation to dirty pixels when software fallback is required.
- **Exact Windows packet text and chrome**: Packet rendering now refuses when the bundled/custom font path cannot preserve engine-planned metrics, preserves explicitly positioned glyph runs, prevents system glyph substitution, and samples a covered, changed hidden-titlebar pixel for native caption contrast.
- **Truthful GPU backend types**: TypeScript creation options now expose only portable backend requests while view and frame state can report the concrete Direct2D renderer; explicit software requests bypass packet encoding and image uploads and stay on the reference renderer and pixel presenter.
- **Reliable registered-image replacement**: Unregistering and then re-registering identical pixels now recreates the removed GPU resource instead of retaining a stale cache key and silently omitting the image.

### Contributors

- @ctate
- @oshtz

## 0.7.1

### New Features

- **Declarative folder-to-code editor example**: `examples/code-editor` authors its complete view in hot-reloadable `.native` markup, unifies its titlebar, file pane, tab-strip canvas, and editor background, centers the opened folder name beside a trailing ghost Save icon in a custom titlebar, opens or replaces the focused window's folder with Cmd+O, creates independent editor windows with Cmd+N, builds a clean bounded folders-first disclosure tree with outline-free selection-only Up/Down navigation, leaf-to-parent Left movement, Left/Right expansion, in-place disk-backed Enter rename, Cmd+Enter permanent tabs, and folder focus independent from the active editor, and presents editable syntax-highlighted files (including `.mjs` and large practical sources) in a resizable second pane with flat VS Code-style tabs whose active tab has no top accent and breaks the baseline to meet the editor, replaceable italic previews that pin when double-clicked, dirty dots, active/hover close buttons, native Close/Close Others tab menus, wrapping Cmd+Shift+[/] tab cycling, Cmd+W tab-or-empty-window closing, and serialized disk-backed Save/Cmd+S.
- **Generated compiled-core facade**: `corewire --facade` now emits the complete compiler entry and matching profile from the contract sidecar, including explicit `--f64-slot` demotions, authored type provenance, and signed or unsigned integer proofs at every host ingress.
- **Facade contract hardening**: generated entries preserve subdirectory module paths, reconstruct private reachable types without invalid imports, preserve Model-first resolution for homonymous unbound bindings, decode optional and composite record fields with a running cursor, prove nullable integer helpers, handle signed and unsigned text-selection sentinels consistently, and refuse legacy sidecars that lack the authored facts a facade requires.
- **Effective sidecar projection**: `corewire --effective-sidecar` emits the contract after explicit slot demotions, and staged facade/profile/sidecar triples now describe one compiled layout.
- **Editable highlighted code**: `ui.code` and `<code>` keep their read-only default, while `editable` plus `on-input` opts into a syntax-colored multiline editor in both retained and direct rendering, with selection, caret-row highlighting, IME, clipboard, undo/redo, indentation-aware Tab input (tabs or inferred 2–8-space widths, defaulting to two spaces), and no textarea chrome.
- **Markdown source highlighting**: `markdown`/`md` joins the code lexer names with themed headings, lists, emphasis, links, inline and fenced code, and comments; the code-editor example selects it for Markdown files.
- **Stable line-number gutter**: numbered code reserves at least three marker columns, so short files keep a useful gutter while larger line counts still expand it.
- **Double-click messages in Native markup**: `on-double-press` exposes the canvas runtime's additive double-click channel to `.native` views, so the first click can select or preview and the second can perform or pin without a timer. Multi-click chains stay scoped to one control and physical pointer, and a third click returns to the ordinary press action instead of repeating the double action.

### Improvements

- **Composable code presentation**: `ui.code` and `<code>` now provide bare highlighted content without their own background, border, radius, shadow, or padding; wrap them in a panel or card when surface chrome is wanted. An enabled line-number gutter remains opaque while horizontally scrolling so source glyphs cannot clash with its pinned markers.
- **Flat tree keyboard hierarchy**: `treeitem` rows can declare a one-based `tree-level`, letting Left/Right find logical parents and children in loop-rendered flat trees, while `on-change` can keep arrow-key selection distinct from pointer activation.

### Bug Fixes

- **Live code docs preview**: The Code component page now loads its real WASM-backed engine scene instead of silently remaining on the static screenshot fallback.
- **Reliable large-code editing**: editable code now repaints only visible selected glyphs and caches longest-line width measurements, keeping large selections and steady-state no-wrap rendering inside bounded display-list and host-measurement budgets.
- **Complete wrapped long lines**: scrolling a single logical line beyond 128 wrapped rows now pages its visible glyphs instead of leaving the remainder blank.
- **Stable code-editor reads**: switching tabs no longer cancels a pinned file's load, and reopened secondary windows keep monotonic file-effect keys so late completions cannot populate a newer document.
- **Unsaved-edit protection**: opening another folder or closing a secondary editor window now refuses while that window still has dirty documents.
- **Steady editor tabs**: active and inactive tabs now share the same background and label alignment, so filenames no longer shift when selection changes.
- **Balance explorer rows**: file-tree hover and selection backgrounds now keep even visual gutters beside the sidebar edge and split handle while preserving compact label alignment.
- **Complete repository roots**: the explorer now indexes a folder when it expands instead of spending its bounded tree budget in an eager depth-first walk, so large subtrees cannot hide root files or unexplored sibling folders; `.next` and `.pnpm-store` remain visible but are not recursively indexed.
- **Familiar file opening**: Command+Down Arrow now opens the selected tree file as a persistent tab; Command+Enter remains available to the focused control.
- **Visible active tabs**: inactive tabs retain their bottom divider, and opening, clicking, or keyboard-cycling to a tab now minimally scrolls it into view horizontally without shifting an already visible tab.
- **Distinct new windows**: Command+N now opens each editor window slightly down and to the right of the active window so the new window is immediately apparent.
- **Clear empty-window title**: editor windows now show “Code Explorer” in the title bar until a folder is opened.
- **Stable editable-code repainting**: syntax-highlighted editors now keep unique retained command IDs while edited text and highlighted spans occupy different runtime storage, preventing a selected editor from crashing when the app deactivates.
- **Safe large widget text**: views keep their ordinary 64 KiB text pools inline and allocate practical source-file capacity only when a large layout or edit needs it, while edit, presentation, and context-menu workspaces stay off constrained native stacks and large single-line pastes continue stripping line breaks.
- **Folder-only macOS open dialogs**: `allow_directories = true` now matches Linux and Windows by selecting directories rather than allowing files alongside them in AppKit and CEF hosts.
- **Code-editor presentation polish**: JavaScript and TypeScript object keys and typed bindings now use the same syntax color as variables, while CSS declaration names retain their property color; numbered editors also use their full trailing width so fitting lines do not produce false horizontal scrolling.
- **Complete JSX and TSX syntax highlighting**: JSX-family code blocks now combine JavaScript or TypeScript token coloring with JSX tags and attributes instead of treating the whole file as plain HTML outside `{…}` expressions.
- **YAML syntax highlighting**: code surfaces, Markdown fences, and the code-editor example now recognize `yaml` and `yml`, coloring mapping keys, scalars, document markers, anchors, tags, and comments.

### Contributors

- @ctate

## 0.7.0

### New Features

- **Code component**: `ui.code` and markup `<code>` render highlighted source with the Geist Code Block palette in both built-in themes, wrapping by default, opt-in logical line numbers, unwrapped horizontal scrolling, and vertical scrolling for height-constrained surfaces; Markdown fences share the same component.

### Bug Fixes

- **Bounded transformed code rendering**: heavily scaled code surfaces now degrade within the shared command and text-byte budgets instead of rejecting the entire display-list refresh.
- **Polished Markdown lists and code blocks**: bullet and ordered-list markers now align with the first content line, while fenced code preserves source indentation and applies theme-aware highlighting with richer HTML/JSX tags and attributes.

### Contributors

- @ctate

## 0.6.3

### Bug Fixes

- **Native textarea editing shortcuts**: Up/Down now moves or extends the caret across visual lines, Command+Left/Right uses the current line boundary even through unbroken soft wraps, Command+Up/Down reaches the document boundary, and Command+Z / Command+Shift+Z provides bounded per-editor undo and redo from either the keyboard or macOS Edit menu while keeping controlled `TextBuffer` models synchronized.
- **Textarea indentation**: spaces typed at the start of an empty line now remain visible and advance the caret under word wrapping.
- **Textarea pointer selection**: Shift-click now extends the selection from the existing caret instead of replacing it.
- **Textarea line endings**: caret movement, deletion, and controlled selections now treat CRLF line endings as one indivisible boundary.

### Contributors

- @ctate

## 0.6.2

### New Features

- **Reliable desktop overlay windows**: window declarations and runtime creation now support transparent, always-on-top, click-through, and passive-show presentation applied before first visibility; canvas windows reveal after their first alpha-correct present without stealing focus, fall back to a late reveal if rendering wedges, and Windows composites multiple canvas layers while rejecting child surfaces its layered presenter cannot display.
- **Honest backend constraints**: Linux main WebViews inherit transparent-window alpha, macOS Chromium rejects transparent windows because windowed CEF content cannot supply alpha, and transparent Windows windows require chromeless chrome with no application menu because the layered compositor cannot capture Win32 non-client pixels.
- **Resizable transparent Windows windows**: the layered presenter keeps the nearly invisible system resize frame pointer-targetable without filling intentional alpha-zero regions in the client.
- **Hybrid overlay lifecycle**: canvas-only overlay windows stay free of implicit main WebViews in mixed WebView scenes and across hot reloads, while passive Linux windows restore from minimization without taking focus.
- **Reliable explicit focus on macOS**: focusing a system-WebView window now activates the app before asking AppKit to make the window key, so an inactive app can come forward as requested.
- **Imperative canvas overlays**: `runtime.createWindow` and `window.zero.windows.create` keep transparent windows without an explicit source canvas-only across hot reloads, and JavaScript can select the chromeless titlebar Windows requires.
- **Idle overlays stay idle**: transparent canvas windows retain their last presented image without entering a display-rate repaint loop, while software presenters still rebuild fully once when their shared pixel buffer changes surfaces.

### Bug Fixes

- **Container backgrounds render**: explicit backgrounds on `stack`, `row`, and `column` now paint across the laid-out frame with their configured radius.

### Contributors

- @ctate
- @jasonkneen
- @sepehr-safari

## 0.6.1

### Bug Fixes

- **Layered macOS cursors**: GPU surfaces now yield their cursor regions to higher-layer embedded webviews, so links, selectable text, and canvas widgets use the correct cursor in mixed canvas/webview windows such as Workbench.
- **Pointer-selected text edits**: editable fields now send pointer caret and selection changes through `on-input`, so model-owned text buffers delete or replace the highlighted span instead of editing at a stale caret.

### Contributors

- @ctate

## 0.6.0

### New Features

- **The external-source channel — `fx.openChannel`, TEA subscriptions done our way**: apps with long-lived external sources (sockets, file watchers, app-managed worker threads) get a first-class, journaled way to wake the UI loop and produce a Msg — no more timer-polling a shared queue. `fx.openChannel(.{ .key, .on_event, .max_pending? })` returns a THREAD-SAFE `ChannelHandle` whose `post(bytes)` stages into a per-channel non-lossy FIFO, wakes the host, and delivers one `.data` event Msg per accepted post on the next drain (bytes in drain scratch, bounded at `max_effect_channel_bytes`); `fx.closeChannel(key)` flushes the staged backlog and delivers exactly one `.closed` terminal with final drop totals. Channels share the keyed families' one key space — occupied from open until close delivers — and never fail from the caller's view: a duplicate occupied key or a full table answers with one `.rejected` event.
- **Back-pressure is part of the contract, and the post's answer names it**: `post` returns a `ChannelHandle.PostResult` — `.accepted`, `.dropped_full` (staging FIFO full: transient, skip and keep producing), `.dropped_oversized` (bytes over the post bound: a programming error no retry fixes), or `.closed` (the occupancy is over: exit the loop) — so a producer never has to guess "retry later" from "stop forever". Both drop answers count into `dropped_pending`/`dropped_total` on the NEXT delivered event — never silent drops, and never a blocked posting thread given a conforming host wake: the platform's `wake_fn` is contractually a bounded, non-blocking, enqueue-only nudge (documented at `PlatformServices.wake_fn`; every first-party host conforms — macOS `dispatch_async`, GTK `g_idle_add`, Win32 `PostMessageW`), and the runtime holds no channel lock across the call, so even a violating embedder wake hangs only its own posting thread, never a drain, close, or teardown. A violator still inside the hook at teardown is abandoned after a bounded wait, and the platform is then deliberately kept alive — destruction skipped, leaked process-lived, with one loud log — so the stale call can never execute into freed host state. Wakes are exactly as many as the loop needs: a refused post never wakes the host (a wake is issued only when a post makes new work drainable), and accepted posts COALESCE behind one latched wake per drain (a burst costs the host queue one entry, cleared at the drain boundary before it snapshots — so a post racing the drain always lands a fresh wake), meaning neither a refusal storm nor a fast producer can grow the loop's queue. Handle lifetime is safe by construction: the handle resolves through a generation-stamped process-lifetime header, so posts after close, after slot reuse, or after runtime teardown answer `.closed` instead of touching freed memory.
- **The journal fingerprint moves, a conscious break**: the `.channel` effect-record kind journals every delivered event as executor truth at the drain boundary, post bytes INLINE (channel posts are small-message-shaped — no blob store detour). Replay feeds the recorded events verbatim and never NEEDS the source — the channel open is an ordinary replayed dispatch that PARKS the occupancy (the key registers as live, duplicate opens reject symmetrically, admission rejections regenerate) and returns an inert handle whose every post answers `.closed`. Honesty about what re-runs: the opening update re-executes under replay, so a producer launched unconditionally really starts — socket connects and blocking setup before its first post included — and is stopped only AT that first post; `ChannelHandle.live()` is the producer-launch check (false for parked replay handles, refused opens, and closed occupancies — advisory, the post's own answer stays authoritative), so producers that consult it before launching keep replay fully offline, the `examples/channel-monitor` pattern. Impossible records (bytes over the post bound, byte-carrying terminals) refuse replay as damage. Journals from earlier builds are refused at the preamble with the standard re-record teaching.
- **Bridge refusal timing, a conscious break**: TS-tier refusals produced by the bridge itself — duplicate-spawn keys, image validation, channel admission — used to deliver their rejection Msg at the command cycle's own boundary, before anything else could run. They now stage into the engine's seq-stamped pending stream and deliver at the next host drain, so every rejection — engine-refused or bridge-refused — arrives in ONE seq-ordered stream in command order, which is what `Cmd.batch`'s performed-in-order contract requires across layers (a batch mixing the two authorities used to deliver its rejections out of order). The observable difference: a frame may render between the command cycle and the rejection Msg, so an app or test that asserted the rejection landed inside the same cycle now sees the intermediate model rendered once and the rejection one drain later.
- **TS tier first-class**: `Cmd.channelOpen(key, { event })` / `Cmd.channelClose(key)` (wire opcodes 0x15/0x16, additive within cmd_format_version 3) with a five-field event arm matched by name (`key`/`state`/`bytes`/`droppedPending`/`droppedTotal`; the three-member `ChannelState` union checked at build time). Posting is deliberately not a TS verb — transpiled cores are single-threaded: the TS tier opens, closes, and receives, and the native side feeds through `Effects.channelHandle(key)`.
- **`examples/channel-monitor`**: an app-owned worker thread samples its own process and posts each reading; the UI updates only when events arrive — no `fx.startTimer`, no polling, and Stop winds the detached worker down through the handle's own `.closed` answer, while a transient `.dropped_full` only skips a sample — the drop counters reach the status line.
- **Horizontal and two-axis canvas scrolling**: scroll views declare `axis="vertical|horizontal|both"` (builder `axis:`), horizontal offsets ride `value-x` with the same source-wins reconcile as `value`, the engine draws a bottom-edge scrollbar, keyboard scrolling gains Left/Right/Home/End on horizontal-capable regions, and macOS native scroll drivers carry both axes with OS momentum and rubber-band.
- **Independent per-axis wheel routing**: each axis of a wheel/trackpad gesture travels to the nearest ancestor scrollable on that axis, so a horizontal timeline holding a vertical list splits a diagonal gesture — `delta_y` scrolls the list, `delta_x` reaches the timeline.
- **BREAKING — `ScrollState` is two-axis now**: the one-axis `{offset, velocity, viewport_extent, content_extent}` record (TS: `offset`/`velocity`/`viewportExtent`/`contentExtent`) was replaced by per-axis fields `offset_x`/`offset_y`, `velocity_x`/`velocity_y`, `viewport_extent_x`/`viewport_extent_y`, `content_extent_x`/`content_extent_y` (TS: `offsetX`…`contentExtentY`); migrate a vertical region by reading the `_y` fields where it read the old ones — an `on-scroll` arm still declaring the old shape fails the build with a teaching that names the new fields.
- **Hover-driven Msgs — `on-hover-enter` / `on-hover-leave`**: widgets can now bind pointer hover as first-class TEA vocabulary (Elm's `onMouseEnter`/`onMouseLeave`): enter dispatches once when the pointer enters a bound element's hit region, leave once when it exits — discrete containment edges, never per-move — so hover previews, prefetch, and hover cards are ordinary Msgs. Legal on any element in markup and in Zig views (`ElementOptions.on_hover_enter` / `on_hover_leave`), and the TS tier gets the pair for free (payloadless events need no SDK types).
- Binding hover makes the element hover-hittable the way a bound press makes it pressable — but never pressable: clicks keep falling through, no accessibility action is announced, and no hover wash appears (a quiet content tile that binds hover stays visually quiet). Nested bound elements track containment independently; enters fire outermost-first, leaves innermost-first.
- Every enter is answered by exactly one eventual leave: the leave Msg is captured when the enter dispatches, so it still arrives when the exit is the element unmounting. Exits resolve exactly like the hover wash already does — moving off, the pointer leaving the window, dismissals, and content scrolling or reflowing out from under a stationary pointer all re-hit-test the last pointer position — and overlays occlude hover the way they occlude clicks.
- Opt-in and free when unbound: apps that bind no hover handlers keep an empty containment chain, no extra rebuilds, and no journal traffic. Where bound, hover Msgs derive deterministically from already-journaled pointer input, so recorded sessions replay them byte-identically with no journal format change.
- Touch honesty: hover comes from mouse and trackpad pointers only — touch input never synthesizes it, so anything reachable only by hover must stay reachable another way. Deliberate break: reserving pointer-id bit 63 as the touch-source stamp changes the meaning of a journaled field, so the session journal's semantic epoch moves and recordings from earlier builds refuse with the standard re-record teaching.
- `examples/notes`: hovering a note row now previews its title, age, and word count in the status bar (the browser status-line convention) without committing the selection.
- **Named keys grow `delete`, `home`, `end`, `pageup`, `pagedown`, `insert`, and `f1`–`f12`**: every desktop platform now reports them on GPU-surface key events (they previously surfaced on some platforms as private-use strings or not at all), and shortcuts and menu accelerators can bind them. Terminal-style consumers can encode the full navigation and function-key set; none of these require a modifier, matching platform convention (F5 alone is a valid accelerator).
- **Native context menus on Windows and Linux**: a right-click on a widget with a declared menu (or the zero-code editable-text and selected-text defaults) now presents the OS menu at the pointer on Windows (`TrackPopupMenu`) and Linux (`GtkPopoverMenu`), with the selection or dismissal riding the same journaled `context_menu_action` event macOS already emits — one authored menu, one replayable outcome, three desktop platforms.
- The `.context_menus` platform capability now reports true on both system-engine hosts, so feature-gated code takes the native path everywhere the system web engine runs.
- The engine fallback surface (hosts with no native presenter) now anchors the menu at the click point instead of the target widget's edge, matching where the pointer actually is on wide targets.
- Selections now resolve from a present-time snapshot of the shown items, so a menu left open across a rebuild (a timer reordering conditional items) dispatches the item the user saw, never the rebuilt tree's occupant of that slot.
- Deliberate automation-protocol break: recorded `context_menu_action` tokens are per-request generations instead of widget ids, so the protocol semantic epoch moves. Recordings from earlier builds are refused loudly at the preamble (their context-menu selections would otherwise be silently swallowed by the token gate); re-record with this build.
- **Windows pty transport — ConPTY, first-class**: `fx.ptySpawn` and the whole pty family now run on Windows through `CreatePseudoConsole` over an overlapped pipe pair, honoring the exact vocabulary contract the macOS/Linux backends implement — same spawn admission and environment policy (the bound host environment plus `TERM`; env names match case-insensitively, the Windows rule), same all-or-nothing `ptyWrite`, `ptyResize` via `ResizePseudoConsole`, `ptyKill` via `TerminateProcess` plus pseudoconsole teardown (which reaches every descendant still attached to the console), same coalesced output batches and lossless back-pressure, and the same exactly-one exit. The terminal example runs unchanged (its deterministic shell pick adds cmd.exe), and recorded sessions replay offline exactly as on POSIX.
- **Encoding honesty**: the pseudoconsole's pipe contract is UTF-8 with VT sequences in both directions, and the backend creates it with flags 0 — no `PSEUDOCONSOLE_INHERIT_CURSOR`, so conhost never opens with a cursor-position handshake the app would have to answer. There are no console-mode calls to make host-side: the VT modes live inside the pseudoconsole's conhost.
- **Differences stated plainly** (docs' platform matrix moved from "staged" to supported): Windows has exit codes only, so `signaled` never occurs there — a crash surfaces as `exited` with the NTSTATUS bit-cast to `i32` — and ConPTY output is conhost's VT rendering of the child's screen, not the child's raw byte stream.
- **TS tier: the pty command family**: `Cmd.ptySpawn(argv, { cols?, rows?, term?, event })`, `Cmd.ptyWrite(key, bytes)`, `Cmd.ptyResize(key, cols, rows)`, and `Cmd.ptyKill(key)` (wire opcodes 0x19-0x1C) expose the pty vocabulary to transpiled cores, with an event arm matched by field name (`key`/`state`/`bytes`/`code`/`reason`/`signal`/`droppedWrites`), where `key` is the app's own session key so two sessions routing one arm stay distinguishable. The native side owns the transport; the TS tier spawns, writes, resizes, kills, and receives.
- **`<terminal>` — the terminal as a markup built-in**: `ui.terminal(.{ .pty = key, .scrollback, .on_terminal })` (markup `<terminal pty={key} scrollback={offset} on-terminal="...">`) promotes the terminal from the example tier to a first-class element. It binds a model-owned pty effect key — the same id `fx.ptySpawn` named, the media-surface `surface` binding shape — and renders the framework-owned emulator session behind it: the grid painted as real text with geometric box drawing, a theme-derived ANSI palette, selection, cursor, and scrollback, all moved into the canvas (`canvas.TerminalGrid`, the `.terminal` widget kind) from the example. Focused, it routes keys, IME text, and wheel scrollback to the session; the live viewport text rides the widget's accessibility label so screen readers read the real screen and session fingerprints cover cell state.
- **The terminal state contract**: `on-terminal` delivers a `canvas.TerminalState` (`scrollback`, `history`, `cols`, `rows`) after every runtime-applied view-state change, and `scrollback` echoes it back under the scroll `value` source-wins reconcile rule. Only app-visible view state crosses the boundary — the emulator's cells, modes, and selection pins stay framework-owned and are never model state. Expressible in both authoring tiers, matched structurally for transpiled cores.
- **Teachings**: a `<terminal>` without `pty={binding}` is refused as dead markup (the media-surface-without-surface policy); a literal pty key, `pty`/`scrollback`/`on-terminal` on any other element, and children all teach exactly where they belong, in the validator and both markup engines alike.
- **Live `<terminal>` sessions, runtime-owned**: binding a pty key with `<terminal pty={key}>` now renders a REAL session — the runtime feeds the key's journaled pty output into a framework-owned emulator, routes the focused element's keys and IME text back out through `ptyWrite`, answers device queries, scrolls history on the wheel, and drives `ptyResize` from the element's laid-out extent through the shared cell-metrics seam. An app's terminal is `fx.ptySpawn` plus the element: no emulator wiring, no key encoding, no grid plumbing. Because the emulator is fed from the journaled byte stream and every outbound byte crosses the journaled write path, a recorded session replays to the same screen with no shell present.
- **Opt-in emulator, consumer-safe**: `AppOptions.terminal_sessions = true` (with a lazy `ghostty` pin in the app's own `build.zig.zon`) wires libghostty-vt behind the element; every other build — scaffolded apps, the docs preview, transpiled cores — gets a stub that renders the empty terminal surface and never traverses that dependency graph. `native_sdk.runtime.terminal_sessions_enabled` reports which half a build carries.
- **`examples/workbench`**: a live terminal beside a browser in one resizable split — the terminal is the element (no emulator code in the app), the browser is a webview pane snapped to a markup anchor with app-owned navigation history behind back/forward, reload, and an address bar.
- **Terminal — the pty effect vocabulary and a recordable terminal embed**: `fx.ptySpawn(.{ .key, .argv, .cols, .rows, .term?, .on_event })` opens a pseudo-terminal, forks the command onto it as its controlling terminal, and streams output back as coalesced `on_event` Msgs; `fx.ptyWrite(key, bytes)` sends stdin all-or-nothing and returns whether the payload was accepted (a caller that must not lose bytes retains a refusal and retries; verdicts are journaled so replay takes the identical path), `fx.ptyResize(key, cols, rows)` pushes a new grid (SIGWINCH), and `fx.ptyKill(key)` terminates the job. A pty is a spawn with a different transport — it rides the same `command` permission, the same environment policy, the same argv budgets, and the same one key space as spawns, fetches, and channels. macOS and Linux ship the real transport (openpty + a controlling terminal); Windows ships ConPTY (its own fragment); the null platform gets a scriptable fake pty so the whole vocabulary tests headless.
- **Output is coalesced per frame, never per read, and back-pressure is lossless**: bytes arriving between drains deliver as one batch bounded at 64 KiB, so `cat largefile` journals per-frame batches instead of a record per `read()`. The transport's staging ring never drops a byte — a full ring parks the reader and the kernel slows the child, a terminal's native flow control — and the exit event reports `dropped_writes` for any `ptyWrite` refused over the session's life.
- **One exit per spawn, honest classes**: exactly one `.exit` event ends every accepted (and every refused) spawn — `exited` with the child's code, `signaled` with the signal, `cancelled` after `ptyKill`, `rejected` for requests refused before a child existed (bad argv, zero grid, duplicate key, table full, unsupported platform), `spawn_failed` when the pty or exec could not start.
- **Recorded sessions replay byte-identical, offline — no shell present**: output bytes are the effect result, written at effect-result time into the content-addressed blob store beside the journal (`blobs/<sha256[..16]>`, identical batches deduplicated), with the journal record carrying the hash and length. Replay never spawns a process: the `ptySpawn` parks the pty (writes/resizes/kills go inert), the journaled batches and exit feed verbatim from the blob store, and the fingerprint checkpoints verify the replayed emulator grid frame by frame. Adding the pty record kind moved the journal format fingerprint — older recordings refuse at the preamble with the standard re-record teaching.
- **`examples/terminal`**: a keyboard-first terminal at the showcase bar — libghostty-vt (Ghostty's extracted VT core, pinned as the `ghostty-vt` Zig module) owns cell state, damage, scrollback, wrapping, reflow, and selection; the canvas paints the viewport as real text with theme-mapped ANSI-16, exact 256-color and truecolor, and wide CJK cells. Typing rides the IME-correct committed-text channel and the emulator's key encoder; cmd/ctrl+shift+space arms line/block cell selection, cmd/ctrl+arrows page the scrollback, and cmd/ctrl+C copies.
- **`UiApp.Options.on_text`**: the target-less committed-text seam — `on_key`'s typing twin — for apps that consume text without a focused text-entry widget (a terminal grid). Delivered for unclaimed `text_input` after the same widget-precedence routing `on_key` yields to, carrying the committed UTF-8 (IME results included) so consumers stay layout- and input-method-correct. Chrome may also declare a `variable_prefix` prefix whose command count is model-derived, for chrome whose shape changes per frame (a terminal grid, a data plot).
- **Video playback**: a new `<video>` element (registry code 68, attributes `controls`/`autoplay`/`loop`/`muted` at codes 82-85 with `src` riding the existing attribute) plays platform-decoded video through the media-surface texture channel — AVFoundation on macOS decodes straight into the compositor while the app core sees only commands and journaled events; Windows (Media Foundation) and Linux (GStreamer) stage the capability honestly: `video_playback` reports false and the load verbs answer with a teaching plus one explicit failed event until their decoders land.
- **The video command/event vocabulary**: `fx.loadVideo` mirrors the audio channel end to end — local-then-URL source cascade with the http(s) scheme check, transport verbs (`playVideo`/`pauseVideo`/`stopVideo`/`seekVideo`/`setVideoVolume`/`setVideoMuted`/`setVideoLoop`), key-stamped events (`loaded` with stream dimensions and duration, position ticks with the honest `buffering` flag, one `completed` at a non-looping natural end, explicit `failed`/`rejected`), and replace semantics that release the surface claim; TypeScript cores get `Cmd.videoLoad`/`videoCtl` at wire opcodes 0x17/0x18 with the by-name seven-field event-arm convention.
- **The session journal fingerprint moves** (a deliberate break — recordings from earlier builds are refused at the preamble; re-record with this build): the new `.video` effect-result kind (code 13) and platform-event tag journal every delivered event verbatim, so a recorded playback replays byte-identical on a host with no decoder and no texture producer attached, and texture contents stay out of session fingerprints exactly like every media-surface texture.

### Improvements

- **Build fingerprints replace version counters for the session journal and automation protocol**: the journal's `format_version` and the CLI/app `protocol` version are gone in favor of comptime layout fingerprints — a Wyhash over a canonical description reflected from the actual record, event, and command types — so any layout change moves the identity automatically, with no counter to remember to bump and no next integer for parallel branches to contend over. Since no journal or dropbox skew is ever migrated, identity beats ordering: "same or different" was the entire question the integers answered.
- Deliberate break: journals and automation sessions recorded by any earlier build are refused with the re-record teaching (the journal preamble now carries the u64 format fingerprint; the snapshot header stamps `protocol=0x...`), and skew refusals name fingerprints instead of version numbers.
- A small `semantic_epoch` remains for the rare meaning-only change with identical bytes (the context-menu token generations were one); layout changes need no action.
- `zig build print-pins` and `native version` print the fingerprints, so a build's wire identities can be quoted exactly.

### Bug Fixes

- **No more stale fringes when content reflows**: incremental canvas damage now covers the anti-aliasing bleed — the up-to-one-device-pixel ring rasterizers ink past a command's bounds — so a list-detail selection change that reflows conditional content (badge pills removed, shrunk, moved, or replaced under new keys) no longer leaves leftover edge pixels where the old content extended beyond the new. Every finalized incremental dirty rect (the refined union, each refined cluster on the retained-patch wire, and the summary fallback) inflates by one device pixel before surface clipping; full repaints are unchanged.
- **Terminal context menu**: right-clicking a `<terminal>` now presents the standard Copy and Paste actions, copying the emulator selection and sending pasted clipboard text to the bound PTY.
- **Natural terminal editing on macOS**: focused terminals now translate Option+Left/Right to word movement, Command+Left/Right to line boundaries, and Command+Delete to clearing back to the line start, instead of leaking unsupported modifier sequences into the shell prompt; Command+V now sends clipboard text through the terminal's bracketed-paste-aware input path.
- **Selectable terminal text**: `<terminal>` now supports pointer-drag cell selection, double-click word selection, triple-click line selection, and Cmd/Ctrl+C clipboard copy without forwarding the copy chord to the child.
- **Terminal Tab input**: focused live `<terminal>` components now send Tab and Shift+Tab to the PTY for completion, indentation, and TUI navigation, while focus-entry gestures and ended or unbound terminals retain ordinary traversal.
- **Video letterboxes instead of stretching**: the video surface now aspect-fits (contain) the decoded frame — centered at the stream's reported proportions, letterboxed or pillarboxed on black, never distorted. Contain is the video surface's one fit mode, stamped on the `<video>` element and on any app-claimed surface while its playback is live; unknown dimensions before the LOADED report keep the full-frame placeholder, and a source replacement re-fits from the new report. Camera and app-producer media surfaces are untouched.
- **Clear terminal focus**: terminal cursors now fill while their live session owns keyboard focus and switch to a hollow outline when focus leaves or the session ends.
- **Clean workbench terminal chrome**: the full-bleed terminal pane keeps keyboard focus without showing its clipped outer focus ring as a stray horizontal rule beneath the titlebar.
- **Workbench pane focus stays truthful**: clicking the embedded page now blurs the address bar and hollows the terminal caret; clicking either canvas pane restores its expected keyboard focus.

### Contributors

- @ctate
- @startewho

## 0.5.4

### New Features

- **`Cmd.imageLoad` — dynamic images, the first full media pipeline**: apps load images at runtime from disk or the network by a model-owned ImageId, the effect executor resolves the audio cascade's source order (local path first, then a verified content-addressed cache entry under `<caches>/images/`, then the network with an atomic cache install behind it), decodes through the platform codec into the existing registered-image storage, and exactly ONE result Msg comes back — `loaded` with the decoded width/height, or one honest failure class from the same vocabulary the direct registration API raises (`decode_failed`, `too_large`, `registry_full`, `unsupported`, `alloc_failed` — the host refused the memory the registration needed, resource exhaustion rather than corrupt bytes — the fetch taxonomy, `http_status` with the status carried through).
- **TS tier first-class**: `Cmd.imageLoad(id, { path?, url?, cachePath?, expectedBytes? }, { event })` with a five-field result arm matched by name (`id`/`state`/`width`/`height`/`status` — `id` echoes the requested ImageId so concurrent loads sharing one arm stay distinguishable; the fifteen-member `ImageState` union checked at build time), id expressions welcome (ids are model data), `Cmd.imageCancel(id)` ending a live load loudly (the event arm's "cancelled", freeing the id for a same-id retry; an id with no live load no-ops), `Cmd.imageUnregister(id)` releasing a loaded image's registry slot (the gallery eviction move past the 16-slot registry — synchronous registry surgery like registration itself, no result Msg, misses no-op; a load in flight still registers at its terminal, so cancel first to keep the slot free), opcodes 0x12/0x13/0x14 additive within cmd_format_version 3, and `TsUiApp`'s `image_cache_dir` deriving the content-addressed cache path from the URL so update never builds filesystem paths.
- **Markup `<image>` — the runtime-image leaf (element code 67)**: `image="{binding}"` binds the model-owned u64 ImageId in avatar's grammar (binding-only, required on the leaf, negative model values fail the build with a teaching, never a trap), wired through the validator, both engines, `native check`'s model contract, LSP hover docs, and the docs vocabulary; the `image` attribute's scope broadened from avatar-only to avatar+image.
- **Recorded sessions replay byte-identical, offline**: an image load's ENCODED source bytes are the effect result, journaled at effect-result time into a content-addressed blob store beside the journal (`blobs/<sha256[..16]>` in the session directory — identical bytes twice store one blob), with the journal record carrying hash + length and the dedup probe verifying an existing blob's bytes before trusting its name (a damaged blob repairs in place from the bytes in hand — recording self-heals the store instead of sealing a journal replay must refuse); replay reads the blob, verifies it against its address, re-runs decode + registration, and delivers the recorded result with no file, network, or cache touched, refusing loudly when the blob store is missing or damaged.
- **Journal format, stated plainly**: the image records bump the session-journal format to v7 (the `.image` effect-record kind plus the blob-address fields appended to every effect record); v6 and older journals are refused at the preamble with the standard re-record teaching — a v6 reader would have misparsed the longer records as corruption.
- **Zig tier**: `fx.loadImage(.{ .id, .path, .url, .cache_path, .expected_bytes, .on_result })` with `Effects.imageMsg(...)` routing, a fake-executor seam (`pendingImageLoad*`, `feedImageBytes` running the REAL decode+register path, `feedImageResult`), and `imageCachePath` deriving the cache convention; the encoded source is bounded at 1.25 MiB from every source alike and over-bound sources fail whole with `too_large` — a cut image never decodes, so there is no truncated delivery.
- **The menu-bar app lifecycle**: windows can declare `close_policy = "hide"` in app.zon (the default `"quit"` keeps today's behavior for every existing app) — the red close button hides the window instead of quitting, the app keeps running behind its status item, and the macOS Dock reopen re-shows it.
- New window verbs on the effects channel: `fx.showWindow(label)` un-hides and activates a window (the tray "Open" consequence; also restores a minimized window), and `fx.quitApp()` quits gracefully through the same shutdown path a last-window close takes — both mirrored in the TypeScript tier as `Cmd.showWindow(label)` and `Cmd.quitApp()`.
- Hidden state is honest, journaled window state: `WindowState.hidden` rides the frame channel, records into session journals, and replays.
- Implemented on macOS (windowShouldClose + orderOut, Dock reopen) and Windows (WM_CLOSE hides via SW_HIDE; the tray re-shows); Linux GTK has no status item to bring a hidden window back, so `"hide"` is refused loudly at build/create time with a teaching instead of stranding a window.

### Improvements

- **The tofu guard teaches font registration**: the font-coverage teachings — the `native markup check` error, the Debug view-build diagnostic, and the CLI usage text — now name registering a covering face (`UiApp.Options.fonts`) behind a model binding as the first remedy for text beyond bundled coverage, alongside vector icons and plain words.
- **A fonts page in the docs**: `/fonts` documents registering faces for scripts beyond bundled coverage — the `Options.fonts` scaffold shape, every registration-time validation error by name, ownership and lifecycle, how text resolves faces through the typography tokens, and per-platform truth including the unverified mobile seam.
- **The Chinese receipt runs natively on Windows in CI**: a new `zig build test-canvas-fonts` step runs the font-registry suite on the Windows runner, including the receipt test that registers a committed subsetted Noto Sans SC (OFL, license alongside) through the app-fonts seam and proves the rendered string is real ideograph outlines — compared against both the bundled face's rendering and the same registered face's own uncovered-string fallback, so tofu from any face fails the receipt.
- **Registered-image memory is on-demand**: each registered canvas image slot buffer is one lazy 1 MiB allocation from `Runtime.Options.allocator` at the slot's first registration (freed by `Runtime.deinit`; unregister/register churn reuses buffers, so the footprint stays bounded by the high-water slot count), so a runtime that never registers an image no longer carries the former 16 MiB embedded pixel pool.
- **New error on register**: `registerCanvasImage` / `registerCanvasImageBytes` (and the `fx.registerImage` / `fx.registerImageBytes` bindings) now surface `error.OutOfMemory` when a slot's pixel buffer cannot be allocated — the refusal happens before any registry mutation, so the registry is unchanged and the same registration can be retried once memory recovers.

### Bug Fixes

- **Large markup documents compile in the compiled engine**: `CompiledMarkupView` / `CompiledMarkupImports` no longer fail with "evaluation exceeded 1000 backwards branches" on `.native` documents past ~10KB — documents now carry their source size from parse/resolve time, so the comptime canonicalize pass sizes its branch quota in O(1) instead of re-measuring the tree inside the quota argument (which ran under the caller's default budget).
- **Linux `native dev` no longer crashes at startup**: Debug builds on x86_64 Linux segfaulted creating the first shell view (a general protection fault in the GTK host's `native_sdk_gtk_create_view`) because Zig 0.16.0's self-hosted x86_64 backend — the Debug default — mis-places stack-passed arguments in the host call's long mixed signature; the app executable now forces the LLVM backend on x86_64 like every other artifact in the build graph, and the ejected template's build does the same.
- **GTK host string caps**: the Linux host now refuses view create/update calls whose string lengths exceed the platform caps with a teaching warning instead of copying from a corrupted pointer, so a broken C-ABI boundary fails loudly at the seam.
- **Linux Debug scaffold smoke in CI**: a new `linux-dev-smoke` job scaffolds the default template, builds it `-Doptimize=Debug` (the `native dev` mode Release-shaped lanes never exercise), and drives it under Xvfb to the first presented frame.
- **Late-registered fonts re-measure open surfaces**: registering a face after views are installed (`runtime.registerCanvasFont` on a live runtime) now rebuilds every installed `UiApp` surface — the main canvas and declared windows — on the next presented frame, so text laid out before the face joined re-measures with the registered face instead of keeping its pre-registration widths under a repaint.
- **macOS host font state ends with its runtime**: `Runtime.deinit` now returns each registered id's host-side registration — the CoreText descriptor and its measurement caches, including the measured-width cache the host previously retained until memory pressure — so embedders that cycle runtimes no longer accumulate per-process font state; removal is ownership-token guarded, so an older runtime's teardown never removes a newer runtime's live face under a shared id.
- **Breaking**: `PlatformServices.registerGpuSurfaceFont` now returns the host's ownership token for the registration (`u64`; 0 from hosts that retain no per-id state), and the new optional `unregisterGpuSurfaceFont(id, token)` service returns that state at teardown — a deliberate break while the toolkit is pre-1.0, so host font lifetime has an owner. Embedders implementing a custom platform change `register_gpu_surface_font_fn` to return a `u64` token (0 is fine for a stateless accept) and may supply `unregister_gpu_surface_font_fn` to release per-id host state when the registering runtime deinits.
- **Ternaries with spread-literal arms compile from TypeScript cores**: `parsed === null ? q : { ...q, state: "ok", price: parsed }` — and the nested, `!==`, both-arms, argument, object-field, and `x === null ? { ...fallback } : x` spellings — no longer emit Zig that reads the null-narrowing capture before it binds (`use of undeclared identifier`) or evaluates both arms unconditionally; arms that build values statement-by-statement now lower into per-branch blocks feeding a typed temp, so exactly the taken arm runs, and pure-arm ternaries keep their tight `if`/`orelse` expression forms.
- **Optional switch payloads keep their optional through the capture**: reading a `number | null` payload (directly or via a `const` local) inside its `case` no longer mistypes the value as non-null, which routed `msg.parsed === null ? ... : ...` around the narrowing lowering and emitted `?f64` into `f64` slots.
- **Early-exit guards narrow like early returns**: `if (r === null) break;` in a parse loop (and the `continue`, labeled, multi-statement, `throw`-exit, and `if (x !== null) { ... } else { break/return }` spellings) now narrows the optional for the rest of the loop body the way tsc's flow analysis does, instead of emitting Zig field access on the still-optional value; `if (msg.kind !== "num") break;` narrows the union payload the same way.
- **Guard narrowing ends with its block**: a guard's captures no longer leak past the loop body or branch they narrow — reads after the construct see the unnarrowed value again (matching tsc, whose exit path may bypass the guard) instead of referencing an out-of-scope Zig capture.
- **Early switch-clause breaks stop the build**: an unlabeled `break` that exits a `switch` from inside a clause body now teaches at transpile time — Zig's `break` binds loops, so the old emission jumped past the enclosing loop instead of resuming after the switch.
- **A redundant kind guard no longer un-optionals a switch payload**: scoped kind-narrowing now restores the still-optional markers alongside the substitutions it snapshots, so `const marker = msg.kind === "got" ? 1 : 2;` inside `case "got":` no longer leaves a `number | null` payload typed non-null for the rest of the clause (which emitted `if (parsed != null) parsed + marker else 0` — invalid Zig operands on the `?f64`).
- **Inferred locals from narrowed ternaries value non-optional**: `const picked = q === null ? { ...fallback, price: 0 } : q;` (either polarity, no `: Quote` annotation) now types the local by the arm the condition narrows — `Quote`, exactly as tsc infers — instead of the raw optional, which declared a `?Quote` temporary that failed Zig compilation at its first non-optional use (`expected type 'Quote', found '?Quote'`).
- **A redundant nested `switch` on the same subject hands back the outer capture**: the arm cleanup now repopulates its narrowing maps from the snapshot instead of only deleting the arm's additions, so an inner arm's capture that OVERWROTE the outer arm's entry no longer leaks into the continuation after the inner switch (which emitted the inner capture name after its Zig block had closed — `use of undeclared identifier`).
- **Else-if chains keep post-if narrowing**: `if (x === null) return -1; else if (flag) { n = 2; } return x.v + n;` — and the else-if-else, chained else-if-else-if, and `!==`-polarity spellings — now narrow `x` after the statement like the plain-else form does; the else-if emission path returned before applying the post-if narrowing, so the fall-through read landed on the still-optional value (`optional type does not support field access`).
- **Reassigned `let` bindings never fuse into a `const`**: `let p = next(i); if (p === null) continue; p = { ...p, v: 10 };` no longer fuses the declaration and guard into `const p = next(i) orelse continue;` (Zig: `cannot assign to constant`); the binding stays a `var`, the guard keeps its plain null test, and later reads unwrap the live variable — which the assignment path keeps narrowed across provably non-null writes.
- **A branch that widens a narrowed optional stays widened past the merge**: `if (p === null) return -1; if (flag) { p = null; } if (p === null) return 0;` — the branch-exit restore that keeps narrowing CONTAINED (additions inside a branch die at its exit) no longer also resurrects a narrow the branch killed by assigning null (or a fresh optional-returning call); kills now re-apply after every branch, switch-arm, and kind-guard exit and propagate through nested blocks, so the post-merge re-check tests the live value instead of emitting `p.? == null` (Zig: `comparison of 'f64' with null`). The merge is conservative — a kill on any path that can reach the merge drops the narrow, and the re-check tsc demands anyway always compiles.
- **Compound-guard branches keep those kills dead too**: `if (r !== null && r > 0) { p = null; }` — where the branch emits under the chain's `.?` substitutions — no longer resurrects p's killed narrow when that substitution scope restores its snapshot (its restore ran after the branch re-applied the kill); the scope now rides the same kill-frame protocol as branch and switch-arm exits, and so does the chain-condition emitter, so every full-map narrowing restore in the emitter re-deletes killed entries on exit.
- **A kill on an always-exiting branch stays off the surviving flow**: `if (p.v < 0) { p = null; return -1; } return p.v;` inside a null guard — tsc keeps `p` narrowed at the second return because the killing branch left the function, and the emitter now agrees: a branch that always returns (or throws uncaught) drops its kills at the merge instead of deleting the narrow the surviving read depends on (which emitted field access straight onto the `?P`). Kills on paths that resume inside the function — fall-through arms, `break`/`continue` guards in loops, throws caught by an enclosing `try` — still merge outward and drive the post-merge re-check.
- **A guard in a lifted callback covers the trailing return it precedes**: `xs.map((p) => { if (p === null) throw bad; return p.v; })` lifts the callback as its statement prefix plus the trailing return's expression, and the prefix's narrowing scope closed before that expression emitted — the read landed on the raw `?P` (`optional type does not support field access`); prefix and trailing expression now share one flow scope, and the scope still closes before the callback's siblings in the emitted loop body.
- **A do-while body guard covers the trailing test it flows into**: `do { if (p === null) return -1; n += p.v; } while (p.v > 0);` — tsc evaluates the condition after the body, under the body's flow state, but the body's narrowing scope closed before the lowered `if (!(cond)) break;` emitted, so the test read the raw `?P` (`optional type does not support field access`); the body and the trailing test now share one narrowing scope, restored at the loop boundary. A guard read only by the test binds its capture too, `continue`-carried kills still widen the hoisted first-pass test onto the live optional, and `break`-carried kills still land only on the post-loop state.
- **Canvas-app hosts compile silently without a WebView SDK**: the informational `#pragma message` in the GTK host's WebKitGTK stub path (and its Windows WebView2 twin) is gone — zig renders every clang diagnostic of a failing C compile as `error:`, so on machines where a real, unrelated compile error occurred (for example a too-old GTK), the note itself surfaced as the first build-killing error and masked the actual cause; the stub is the expected state of every canvas app and now compiles with zero diagnostics, while a genuinely misconfigured web build still fails loudly via `#error`.
- **GTK host compiles against GLib 2.72**: the host now spells "no application flags" in a way that compiles on GLib older than 2.74, so distros that backport GTK 4.10 onto a GLib 2.72 base (Ubuntu 22.04-derived) build canvas apps out of the box.

### Contributors

- @ctate
- @codehz
- @nextpointer
- @perminder-klair

## 0.5.3

### New Features

- **`<media-surface>` — the dynamic texture channel**: a new element compositing textures produced outside the widget tree (video decoders, camera pipelines, external renderers like mpv) into the layout like any widget, with a stable Zig-tier producer API (`runtime.acquireMediaSurfaceProducer`) pushing RGBA8 frames from any thread — latest-wins, damage-tracked, paced by the compositor's presented-frame clock.
- **Pushes wake an idle compositor**: a push staging new bytes requests one coalesced frame through the platform's thread-safe cross-thread frame request (the automation watcher's wake path), so video keeps playing in an idle demand-driven app and a late-starting producer is adopted promptly; damage-skipped and stale-handle pushes wake nothing, and teardown disarms the binding under the same fence the wake call holds, so an orphaned producer can never wake a dead host.
- **Markup, both engines, and tooling**: `surface="{binding}"` binds the model-owned u64 surface id in the runtime-image-id grammar (binding-only, required, media-surface-scoped with teaching errors), wired through the validator, the compiled and interpreter engines, `native check`'s model contract, LSP hover docs, and a docs component page plus a "Media Producers" recipe.
- **Deterministic by policy**: texture contents are presentation chrome — goldens, reference screenshots, and session fingerprints see only the surface's id-derived placeholder, so a session recorded with a live producer replays fingerprint-identical with no producer attached; live GPU hosts composite the real texture through the existing image upload pipeline.
- **Reserved id namespace**: bit 63 of the ImageId space now belongs to media-surface textures; `registerCanvasImage` rejects ids with it set (`error.InvalidImageId`) so producer textures and registered images can never collide.
- **Cover fit stays inside the frame**: a `cover`-fit media surface carries the image widget's rectangular clip around its texture draw, so the fit-expanded texture can never paint over siblings on hosts that only mask corner radii.
- **Adopted-texture memory is on-demand**: each channel's texture buffer is one lazy frame-budget allocation from the new `Runtime.Options.allocator` at first adoption (freed by the new `Runtime.deinit`), so a runtime with no media producers carries zero media-texture bytes — an embedded pool would have put 32 MiB in every Runtime (measured on the docs wasm preview host: 169.5 MB → 137.5 MB per component tile). The allocator freezes into the runtime at init: mutating `options.allocator` on a live runtime never retargets ownership, so allocations and their frees always pair on one allocator.
- **Trackpad pinch reaches apps**: pinch-to-zoom now flows from the macOS host (`magnifyWithEvent:`) through phase-explicit `pinch_begin`/`pinch_change`/`pinch_end` input events into a view-global app channel — Zig cores declare `Options.on_pinch`, TypeScript cores export `pinchMsg(pinch)` with `PinchPhase`/`PinchEvent` in `@native-sdk/core/events`; each change carries a multiplicative delta (cumulative gesture scale is the product of `1 + scale`, applied memorylessly — `zoom *= 1 + scale`) and the pointer anchor rides view-local `x`/`y` (the pointer location during the gesture — zoom-at-cursor anchoring, not a between-the-fingers midpoint); every event names its source window and view (`window_id`/`label` in Zig, `windowId`/`label` in TypeScript), so multi-window apps tell pinches apart; a terminal Ended/Cancelled event that still measured a nonzero delta arrives as one last change before the end, so the product always matches what the OS reported. On macOS the delta is AppKit's raw per-event `NSEvent.magnification`, forwarded untransformed: raw magnification IS the multiplicative per-event delta — the convention every browser engine ships — so the product of `1 + scale` is the zoom users already experience for the same gesture in Safari and Chrome. The one guard is a per-event floor: a single event's magnification at or below -1 (a zoom inverting through zero scale — physically impossible, only a driver glitch could report it) clamps just above -1, so every emitted factor stays positive. Windows precision-touchpad and GTK gesture sources are staged follow-ups.
- **`widget-pinch` automation verb**: `native automate widget-pinch <view-label> <scale> [x y]` drives the real pinch event stream without a trackpad (`<scale>` is the gesture's FINAL multiplicative zoom — one change carrying `scale - 1`, anchor point defaulting to the view center), journaled like every synthesized input so recorded sessions replay the identical zoom. Automation protocol bumps to v7.
- **Session journal v5**: gpu-surface input records gain the pinch `scale` field and the pinch kinds; readers refuse v4 journals loudly in both directions, per the format's skew discipline — re-record sessions with this build.

### Bug Fixes

- **Registered CJK fonts render dense glyphs**: glyph outline budgets are now sized from real CJK faces (Noto Sans JP/SC/TC/KR measured; 1024 points / 128 contours per glyph), so everyday dense kanji like 鬱 ink as real outlines instead of notdef blocks; the per-font registration size bound rose to 24 MiB so full CJK faces register.
- **Glyph complexity validates at registration, not render**: a face whose `maxp` declares glyphs denser than the outline budgets — simple maxima and flattened-composite maxima (`maxCompositePoints`/`maxCompositeContours`) alike — is refused at registration with a teaching that names its numbers against the budgets (`error.FontExceedsGlyphBudgets`), instead of silently degrading individual glyphs to blocks at render time.
- **Font bytes are heap-allocated on demand**: the registry copies each registered file into an exact-size allocation from the runtime's new `Options.allocator` (freed by the new `Runtime.deinit`), so the 24 MiB bound is validation, not a storage reservation — a runtime with no registered fonts carries zero font bytes, where a reservation-shaped pool would have embedded 192 MiB in every Runtime (measured on the docs wasm preview host: 313.5 MB → 121.5 MB per component tile).
- **`EmbeddedApp.deinit` completes the embed lifecycle**: direct embedders end an embedded app with `defer embedded.deinit()` (idempotent), which returns the runtime's heap-owned registrations — without it, a host creating and destroying apps in one process leaked the registered font storage per cycle. The wrapper hosts and the C ABI's `native_sdk_app_destroy` route their teardown through the same deinit, one lifecycle owner.
- **Glyph raster budgets are derived from the registration gate**: the vector core's glyph-fill capacities (`GlyphRasterizer`: 18,560 edges/crossings, flattening clamped at 16 segments per curve) are computed from the outline budgets registration admits, so a truthfully-declared budget-maximal glyph — a 1024-point zigzag contour included — rasterizes at any size instead of hitting `VectorPathTooComplex` and degrading to the block fallback the gate promises cannot happen; the clamp binds only above ~128-px ems and keeps the polyline within 0.2% of the em, so existing renders are byte-identical.
- **Single-line fields never hold or paint line breaks**: pasting multi-line text into an input, text field, search field, or combobox now strips the line breaks at the edit seam (the HTML value-sanitization rule — lines join with nothing between them), covering clipboard paste from the shortcut and the context menu, typed and automation `text_input`, and IME composition, with the app's `on_input` hearing the same sanitized bytes the editor applied; a paste of only newlines inserts nothing.
- **Defensive render containment**: a single-line value that still holds a `\n` (a model-set value, an old journal) now paints as one line — breaks present as spaces — under a forced content-rect clip, so text can never escape the field's rounded border on any renderer.

### Contributors

- @ctate
- @IFTC-XLKJ
- @WhiteHades
- @jhodges10

## 0.5.2

### New Features

- **Anchored tooltips with hover intent**: `<tooltip anchor="above|below">` beside its trigger in a stack floats against the trigger and hands visibility to the runtime — it shows after the pointer has rested on the trigger for the show delay (default 600ms) and hides on leave, so sweeping a toolbar flashes nothing; after a pointer-hovered tooltip hides on leave, a shared 400ms warm window shows the next trigger's tooltip instantly (the other hide causes below — focus moving on, Escape, a press, view blur — deliberately open no warm window). Delay, warm window, and the behaviors below match shadcn/ui's defaults (Base UI). The model never hears hover, both engines lower it identically, and every transition steps on the recorded input/frame clock, so recorded hover-dwell sessions replay their show/hide frames byte-identically.
- **`tooltip-delay` attribute**: per-tooltip show delay in milliseconds (`0` shows the instant the trigger is hovered); absent follows the new `tooltip_show_delay_ms`/`tooltip_warm_window_ms` metric tokens. Registry attr code 80; static (non-anchored) tooltips keep their classic paint-when-rendered behavior.
- **Keyboard focus reveals immediately**: tabbing onto a tooltip-owning trigger shows its tooltip with no dwell (keyboard navigation is deliberate, and content revealed on hover or focus must not depend on pointer timing); focus moving on or Escape hides it just as immediately, without warming the pointer's skip window.
- **Hoverable content**: a shown tooltip's own bounds hold it open (WCAG 1.4.13; Base UI's `hoverable` default) — the pointer can cross the anchor gap into the tooltip along a bounded safe-polygon corridor, and it hides only after leaving both the trigger and the tooltip (with the usual warm window); the corridor resolves on the recorded frame clock, so replays stay byte-identical.
- **Scroll steps the machine**: every scroll path (wheel, kinetic steps, native drivers, keyboard scrolling) routes its hover change through the same intent transition a pointer move takes — a trigger scrolled out from under the pointer disarms/hides, and a trigger scrolled under it arms per normal.
- **Press dismisses**: ANY pointer-down — primary or secondary, including downs consumed by the context-menu gesture or a window-drag region — or Space/Enter on the focused trigger cancels a pending reveal, dismisses a shown tooltip, and closes the warm window, so an activated control never re-explains itself on the post-click hover. Keyboard activation and Escape also spend the standing focus reveal: a rebuild that replaces or rekeys the tooltip (the activation's own model update, typically) cannot resurrect it — it stays down while focus rests on the trigger, until the keyboard genuinely leaves and returns; the focus ring stays painted, and a later pointer hover re-earns the dwell normally.
- **Rebuild hygiene**: a rebuild that removes, rekeys, disables, or re-parents a tooltip's trigger resets that tooltip's armed/shown/warm state and re-stamps it hidden, even when the tooltip node itself survives.
- **View blur resets**: a canvas view that loses focus (to a sibling view or with the window) drops its entire tooltip conversation — armed delay, shown tooltip (keyboard- and pointer-owned), warm window — and re-stamps hidden, so no stale tooltip floats in a view the keyboard left. The window key-loss reset fires on the flag's own focused→unfocused edge, so it holds however the host announces the change: one gain event (macOS) or loss-before-gain (Windows, GTK), including a loss with no gain at all (every window inactive).

### Improvements

- **Search empty state names its scope**: the system monitor's no-match state now says search only sees the top 128 processes by CPU, so a miss on a quiet process reads as scope, not absence (both tiers).

### Bug Fixes

- **Dark-scheme accent focus rings settle down — and stay visible**: a `theme_accent` (or `canvas.accentOverrides`) now derives its dark-appearance focus ring at half the accent's saturation instead of the raw brand hue, contrast-floored at 3:1 (WCAG non-text) against the lightest dark tone controls commonly sit on (the house muted surface `#262626` — rings draw outside controls, so clearing the lightest adjacent container tone clears the page background and card surface too, in both shipped packs) — desaturation alone can cost a deep accent the bar it cleared (`#008000` fell from 3.9:1 to ~2.6:1 on the background; the floor lifts it back over 3:1 on background and card surface alike) — so the soundboard search field's ring no longer glares neon in dark mode; `canvas.accentFocusRing` exports the derivation so hand-authored token sets (the Zig soundboard's theme) state the identical ring.
- **Breaking**: `canvas.accentOverrides` now takes the resolved `ColorScheme` alongside the accent — a deliberate break while the toolkit is pre-1.0, so the one function under the natural name states the scheme it layers over; pass `.light` to reproduce the previous output exactly.
- **Escape in a search field now reaches your core**: Escape's clear (and its composition cancel) was a runtime-local editor operation — the field emptied on screen while the model kept the stale query and the list stayed filtered. Every keyboard-driven editor mutation now derives ONE edit that is applied to the retained editor AND stamped onto the dispatched event, so `on-input` hears Escape exactly like typing, paste, and the clear affordance — on both authoring tiers, and byte-identically under record→replay.
- **Automation and accessibility composition verbs ride the real input path**: `widget-action set_composition/commit_composition/cancel_composition` now dispatch the same ime input events a live IME session produces (journaled, mirrored to the core), and `set_selection` reaches the core's selection mirror through the stamped-edit channel.
- **Accessibility actions replay without double-dispatch**: a journaled assistive action (press, toggle, set_text, drag, ...) no longer also journals the key/text events its verb synthesizes — replaying the action re-derives them, so recorded AX-driven sessions replay each input exactly once instead of twice.
- **Direct verb calls journal outer-wins too**: an embed host's `widgetAction` and automation `widget_action` commands now record the same single `widget_accessibility_action` record the platform accessibility path does (the enum gained the composition kinds), so replay re-runs the verb — focus included — instead of delivering its untargeted key/ime children to whichever field the session happened to leave focused.
- **Grids keep their declared column slots**: children fewer than a grid's declared `columns` now keep the column-slot width and fill the leading slots, instead of stretching across the freed row — a search that narrows the soundboard album grid below its column count leaves image-forward tiles at their natural size.
- **"terminate request delivered" retires itself**: the system monitor's delivery notice now clears on the next applied sample instead of sitting in the footer forever; failure notes keep sticking (both tiers).
- **System monitor footer says UTC**: the sample-time stamp renders from the journaled clock in UTC, and the footer now labels it "UTC" instead of passing it off as local time — local rendering would need a journaled timezone channel to stay replay-byte-identical, so the label is the honest fix (both the Zig example and the TS port).

### Contributors

- @ctate
- @marcusschiesser

## 0.5.1

### Improvements

- **The TS scaffold's status bar earns its empty state**: a fresh scaffold said "stamped: -1ms" until the first Stamp press; the template's markup now branches on `{stampedMs < 0}` and says "press Stamp for a timestamp" instead — teaching the if/else markup shape in the starter while it's at it.

### Bug Fixes

- **Exact-fit text no longer elides under geometry pixel snapping on Windows**: edge snapping rounds a frame's two edges independently, so a hug-sized text box at a fractional position could come back up to a full device pixel narrower than the label it was measured for — past the elision slack, so the TS scaffold's centered counter painted "…" instead of its digit at 100% scale. The wrap/elision budget (`textWrapMaxWidth`) now hands back the full snap quantum (1/scale, was 0.5/scale), and the epsilon policy is documented at the seam: painted width may exceed the snapped frame by less than `1/scale + text_elision_slack`, always below the smallest real overflow (a glyph).
- **Spawn teardown crash window closed**: the effects channel now joins every spawn, fetch, and file worker thread that converges before its teardown returns (previously it gave up after ~5s and abandoned them), so cancelling or quitting while a real child is still streaming can no longer leave a stale worker writing into freed memory.
- **Spawn cancel reaches the whole process tree**: each spawned child runs in its own process group and cancel/teardown signals the group (POSIX), so shell-wrapped commands (`sh -c "a; b"`) no longer leave orphaned grandchildren holding the stream open past the cancel.
- **Every worker class tears down bounded**: spawn, fetch, and file workers now share one terminal guarantee — teardown returns within a budget and never frees memory a live thread can still touch. A file worker stuck in blocking I/O that nothing can converge (a write to a FIFO with no reader, a stalled network filesystem), or a spawn worker held hostage by a descendant that escaped the kill's process group (`setsid` daemonization, a shell's `set -m` background job) while holding the stdout pipe open, no longer hangs teardown: teardown interrupts the blocked syscall best-effort at half its budget and, past the full 15s, abandons the worker with one warning and a small deliberate leak. Everything an abandoned worker can still reach lives in process-lifetime storage, so the leak stays safe even when the app tears down the allocator behind the channel right after.
- **A fetch that cannot start cancellably is rejected, never run inline**: when the executor cannot start the exchange as a cancelable task, the fetch now delivers one honest `.rejected` terminal instead of silently running an exchange that would evade `cancel`, the timeout, and teardown's join.
- **The npm-installed CLI carries its TypeScript toolchain**: @typescript/typescript6 — and @typescript/old, the exactly-pinned alias of the real compiler its one-line entrypoint re-exports — are now regular dependencies of `@native-sdk/cli`, installed by npm in the same transaction as the CLI itself. The first `native check|dev|build|test` on a TypeScript app needs no network and no install step, and never runs npm: it works offline right after install, on read-only (system-owned) prefixes, and under `NODE_ENV=production` alike, because the bundled transpiler resolves the toolchain by node's own ancestor `node_modules` walk across every layout npm or pnpm produces. A repo checkout whose `packages/core` install hasn't happened yet is taught the one command (`cd <sdk>/packages/core && npm ci --include=dev`), and a direct `zig build` against an unresolvable toolchain fails with the same clean teaching and a resolved SDK path instead of a panic stack trace. TypeScript apps need Node.js 22.15+ (on the 23 line: 23.5+) on every layout — repo checkouts included, because every .ts module rides the same `module.registerHooks` type stripping: on a node without the hook the runner fails fast with a one-line upgrade teaching instead of node's raw `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`.
- **Drag headers lay out clear of the Windows caption buttons**: on hidden-titlebar windows, a `window-drag` header whose app never consumed the chrome channel's trailing inset rendered right-aligned content UNDER the DWM min/max/close cluster (system-monitor-ts's status text was truncated by the caption punch-out). The runtime now detects the collision after layout and re-lays the view once with the cluster reserved (`DesignTokens.window_controls`, stamped like `text_measure`), so drag-header content stops at the cluster's edge on every app — markup and builder, Zig and TS — while headers that already pad through the chrome insets (soundboard's trailing spacer) keep a byte-identical layout. The same mechanism covers the macOS mirror (a leading traffic-light cluster). Anchored floating children of the drag header resolve against the cleared rect too, so an end-aligned floater moves out from under the buttons just like flow content; anchored children of non-drag widgets keep byte-identical placement.
- **Standard titlebars follow dark mode on Windows**: windows with standard chrome now set `DWMWA_USE_IMMERSIVE_DARK_MODE` from the OS app color scheme — at creation (before first show, so a dark launch never flashes a light caption) and again on every appearance broadcast — so a dark-themed app no longer sits under a glaring white titlebar. Hidden-titlebar windows keep their higher-fidelity pixel-sampled caption color, and chromeless windows have no caption to tint.
- **Windows release exes are GUI-subsystem**: `native build` (and therefore everything `native package --target windows` wraps) no longer produces console-subsystem binaries, so launching a packaged app never flashes a terminal window behind it. Debug exes keep the console — the dev loop's logs live there — and redirected logging (`app.exe > log 2>&1`) still works on GUI exes. Packaging now reads the exe's PE subsystem, warns loudly when a console-subsystem binary is wrapped (stale zig-out or hand-supplied `--binary`), and carries the finding in the package stats, pinned by tests over synthetic PE headers. The web-frontend scaffold's standalone `build.zig` (Next/Vite/React/Svelte/Vue and `native init --full`) emits the same release-only assignment, so scaffolded apps get the posture without the SDK build graph.

### Contributors

- @ctate

## 0.5.0

### New Features

- **TypeScript authoring — write app cores in TypeScript**: `native init` now scaffolds a TypeScript app by default — `src/core.ts` (logic), `src/app.native` (view), `app.zon` (manifest), zero Zig to write — and the build transpiles the core to readable arena-backed Zig, so the shipped binary carries no JS engine and no GC and keeps the native dispatch path (~83ns per update). The `@native-sdk/core` package (the SDK cores import, plus the transpiler the CLI runs) publishes to npm with this release at the SDK's version. Zig cores remain first-class (`native init --template zig-core`), mixed TS-core + Zig-helper apps fall out of tree detection naturally, and a TypeScript app can eject to its emitted Zig at any time. The entries below are the pieces of this one feature (#119).
- **examples/ai-chat-ts — an AI chat client authored entirely in TypeScript + Native markup**: a conversation UI over an OpenAI-compatible chat-completions endpoint as two subset modules and zero Zig — `Cmd.fetch` with routed `{status, body}` results, the JSON wire format as pure byte math (`src/api.ts` encodes requests and parses `choices[0].message.content` / `error.message`, refusing anything malformed), conversation history in the Model, the composer on the SDK byte-splice text engine, endpoint/model/key through the env channel (no baked endpoint, no key anywhere in the tree — a teaching state until all three arrive), a model-level in-flight guard, and honest failed states that keep the history with a Retry. The e2e battery (`tests/ts-core/ai_chat_e2e_tests.zig`, in `zig build test-ts-core-e2e`) pins the exact request bytes turn by turn and replays a recorded conversation — transport failure and retry included — byte-identically with zero network; the README states the v1 boundaries plainly (buffered responses, compile-time fetch headers) (#119).
- **Docs: "Where Packages Go"** (`/typescript/packages`): the four first-class patterns behind "can I use npm?" — HTTP/AI APIs through `Cmd.fetch` (with a complete transpile-checked core sample), npm-heavy UIs as embedded web frontends, Node libraries as `Cmd.spawn` sidecars, and pure utilities vendored under `src/` or imported from the curated `@native-sdk/core/*` channel — with the core's no-npm boundary stated as the thing that buys replay, headless testing, and native dispatch speed (#119).
- **Eval wave 2 — six dual-track authoring cases, one language-blind spec each**: the eval harness gains `"frontend": "app-dual"` cases that run the SAME realistic ask on both authoring tracks — `<case>@ts` scaffolds a full TypeScript app (`native init --template ts-core`), `<case>@zig` the Zig app template — graded by shared checks plus per-track behavioral harnesses asserting one spec: fetch-JSON-into-a-sortable-table, debounced notes autosave (starter provided), a pomodoro timer with a completion sound, a seeded stale-cache delete bug to root-cause, a module split with byte-exact CSV export, and a shell-command system-info panel. The ts harnesses decode the Cmd/Sub wire format (`evals/harness-lib/cmdview.zig`); the zig harnesses ride the SDK's fake effects executor inside the workspace's own `native test` graph. `--track ts|zig` selects a lane; each track gets its current skills (`ts-core`+`native-ui` vs `native-ui`+`zig`), and `pnpm metrics` now reports per-track teaching-error encounters alongside first-pass compliance and the violation taxonomy (#119).
- **Transpiler: two real-app fixes the wave surfaced**: byte-element stores of computed values (`buf[i] = src[j]`) now emit with JS's exact ToUint8 wrap instead of stopping as invalid Zig, and records referenced from a declared text-input mirror union stay by value even when the core also stores its editor state in the Model — previously that pointer promotion silently broke `on-input` resolution (runtime view build and `native check`'s model contract alike) for any core keeping a `TextEditState` in its model (#119).
- **examples/soundboard-ts — the soundboard authored entirely in TypeScript + Native markup**: the launch-bar port of the Zig soundboard as three files of truth and zero Zig — `src/core.ts` (the committed catalog as const tables, REAL audio through the `Cmd.audioPlay` stream with the engine's local-then-URL cascade, the play-next queue, Copy Title on the clipboard, a motion-gated `Sub.timer` playback clock, and search through the full byte-splice text engine), `src/app.native` (the whole view: grid, album detail, songs library, context menus, the now-playing transport), and `app.zon`. An end-to-end suite (`zig build test-ts-core-e2e`) drives the shipping core and markup through playback, auto-advance, the stale-event window, volume, clipboard, search, record→replay, and a dispatch-latency budget; the README carries an honest ledger of where the port diverges from the Zig original (#119).
- **Generated TS wiring resolves the theme and the audio cache**: app.zon's `.theme` pack now reaches TypeScript apps (composed with the live system appearance), and the platform caches directory is resolved at launch so a core's URL audio playback caches under the conventional content-addressed path with no `cachePath` in the core (#119).
- **Transpiler emit-contract fixes**: the global `undefined` VALUE now emits the optional empty (`null`) — it previously emitted Zig `undefined`, uninitialized memory — and an early-exit null guard whose narrowed value goes unread emits a plain null test instead of an unused (uncompilable) capture (#119).
- **examples/system-monitor-ts — the system monitor authored entirely in TypeScript + Native markup**: the spawn-showcase port of the Zig system monitor as three files of truth and zero Zig — `src/core.ts` (the 2 s sampling cadence as a declarative `Sub.timer`, collect-mode `Cmd.spawn` for `ps`/`vm_stat`/`meminfo`, pure byte parsers over the collected stdout, the exact top-128-by-CPU selection, the confirmed SIGTERM action, and a runtime boot probe that discovers the host's sampler conventions where the Zig original switches at comptime — with the honest "no sampler for this OS" state when nothing answers), `src/app.native` (the whole view: chromeMsg-driven hidden-inset header, `<chart>` sparklines over the core's NaN-padded windows, the real table register with per-row context menus and controlled scroll, the modal confirmation), and `app.zon`. An end-to-end suite (`zig build test-ts-core-e2e`) drives the shipping core and markup through the probe cascade, the Zig example's committed real captures, the timer cadence with pause, search/sort, the kill round trip, and record→replay; the README carries an honest ledger of where the port diverges from the Zig original (#119).
- **Markup chart series bind f64 iterables**: `<series values="{binding}">` now accepts `[]const f64` model fields, decls, and fns alongside f32 — transpiled TS cores carry every number array as f64, so markup charts were unreachable from a TS model — narrowed per sample into the f32 chart pipeline in both engines, the validator, and `native check`'s model contract (#119).
- **The everyday string methods on core bytes — familiar spellings, byte-honest semantics**: TypeScript cores can now write `s.toUpperCase()`, `s.trim().toLowerCase().includes(q)`, `s.repeat(n)`, `s.padStart(w)`, `s.split(sep)`, `s.startsWith(p)`, `s.indexOf(t)`/`s.lastIndexOf(t)`, and `s.at(i)` directly on `Uint8Array` text. Every length/offset is a BYTE measure, search is byte-wise (`includes`/`indexOf`/`lastIndexOf` dispatch by argument type: bytes needle = substring search, number = the TypedArray element search), case mapping is Unicode 17 SIMPLE case mapping (locale-free, generated tables — 3.1 KiB in the binary — with invalid UTF-8 passing through unchanged), trim strips the exact JS whitespace set over UTF-8, and `split` returns a locally-owned `Uint8Array[]`. Native lowers each call onto rt kernel helpers; node runs the same methods from the same generated tables (devhost polyfill), so both runtimes produce identical bytes by construction — pinned by run-fidelity cases across Greek/Cyrillic casing, growth mappings, invalid-UTF-8 passthrough, repeat/pad edges, and split shapes, plus a machine-checked method matrix (#119).
- **The stays-out spellings teach their reason**: `charCodeAt`/`charAt`/`codePointAt`/`normalize`/`replace`/`replaceAll` on bytes teach the new NS1060 (byte text speaks the byte-honest method set), the locale family teaches NS1005, and the regex-taking methods teach NS1040 — never a bare "property does not exist". `trimAsciiSpaces` stays for LF-preserving line parsing; `.trim()` is the canonical whitespace trim (#119).
- **TS cores: generics, local function values, and the complete-language tail**: user-declared generic functions, interfaces, and type aliases now compile via per-call-site monomorphization from tsc's own resolved type arguments — one readable Zig fn per distinct instantiation (`pick__Task`, `pick__f64`), deduped, covering records/unions/arrays/optionals, recursion inside a generic, generics calling generics, and structural instantiation of generic types (`Box<Task>` → `Box__Task`); unresolvable call sites teach the new NS1053 (#119).
- **Const-bound local function values hoist**: `const scale = (x: number): number => x * 3;` (arrow or function expression) becomes an ordinary module-level fn when capture-free and fully annotated, usable by direct call (recursion included) or as an array-method callback (`xs.map(scale)`); captures, reassignment, storing/returning the value, and record-field calls teach the new NS1054 — and capturing a locally-owned array ends its ownership at the capture (NS1051 machinery) (#119).
- **The small-fry tail lands with node-byte-identical pins**: `for (const [i, x] of xs.entries())` (the destructured-pair loop form), `++`/`--`/assignments in provably order-exact value positions (`arr[i++]`, `const n = ++count`), `?.[i]` and `?.method()` optional-chain hops on supported receivers, plain `number`/`string` switch scrutinees (if/else chains with JS strict-equality and default-position semantics), and `typeof CONST` type-query aliases. Float-valued template holes stay deferred — there is no JS-exact f64 formatter in the runtime yet, and node/native divergence is never an option (#119).
- **TS cores: exceptions and data classes — the complete language, tier 2**: `throw`/`try`/`catch`/`finally` compile as deterministic control flow — a thrown subset value (one error shape per core, the new NS1057) unwinds through a native payload slot to the nearest catch, across helper calls and out of `.map`/`.filter` callbacks; `finally` lowers to a scoped defer running on every exit (control flow inside it teaches the new NS1058, JS's own no-unsafe-finally), the catch binding narrows once (`const err = e as ParseError;`), rethrow and nested try work, and an uncaught throw is a defined panic at the exported boundary — exactly where node's process would crash. Node-parity is pinned in the run-fidelity corpus, throw-mid-mutation of an owned array included (#119).
- **Data classes, no inheritance**: `class Task { fields; constructor; methods }` emits as a plain struct plus module-level functions; `new Task(...)` constructs a record-shaped value, `this` reaches fields and methods, and instance mutation (field writes, `this`-writing methods) follows the same local-ownership rule as arrays (NS1001/NS1051 at the boundaries). The class tail teaches by name: `extends`/`super`/`abstract` (new NS1055), accessors/statics/privates/`#`/class expressions/escaping `this` (new NS1056), generic classes (NS1053), `instanceof` (NS1041); class instances stay local values — Model storage teaches toward records (flagged follow-up) (#119).
- **Two reconcile potholes**: arrays OF byte buffers (`const parts: Uint8Array[] = []`) now route through array ownership — `parts.push(chunk)` on your own array works and runs node-identically (bytes VALUES keep their own discipline) — and a bare reference to a module-level function or const helper is a callback (`xs.map(encodeTurn)`, `xs.toSorted(byAscending)` — the same lowering as the arrow spelled inline), plus shorthand members in union literals (`{ kind: "range", v }`) (#119).
- **TypeScript apps are the `native init` default**: the scaffold is three files of truth and zero Zig — `src/core.ts` (logic), `src/app.native` (view), `app.zon` (manifest) — and the build detects the core from the tree (a `src/core.ts` transpiles at build time through generated wiring; `src/main.zig` stays the Zig core; both at once is a teaching error). The Zig template remains first-class via `native init --template zig-core` (#119).
- **`native dev --core`**: the TypeScript core-logic loop under node — dispatch Msgs as JSON lines, watch the model and effect transcript, run Sub timers and Cmd.delay on a virtual clock. Logic only, honestly not a renderer; `native dev` runs the real app (#119).
- **`native check` checks TypeScript cores**: a `src/core.ts` runs the @native-sdk/core subset checker first (NS diagnostics verbatim), then markup and app.zon as before — with a fresh model contract the markup pass type-checks bindings against the core's emitted model (#119).
- **Markup text input reaches TypeScript cores**: a core declares its own `TextInputEvent` mirror union and `on-input` matches it structurally, translating each runtime event into the core's union at dispatch — markup text field to TS `update` to re-render, end to end (#119).
- **Exported model helpers bind from markup**: an exported single-Model-parameter helper also emits as a Model declaration (`doneCount` binds as `{done_count}`), and `export const viewUnbound = [...]` emits the `view_unbound` lint opt-out — NS1031/NS1032 teach the collision and typo cases (#119).
- **TS cores: runtime fetch header values and journaled env deliveries** — the two gaps the ai-chat example surfaced, closed. `Cmd.fetch` header VALUES may now be runtime bytes (`{ authorization: bearerToken(model.apiKey) }` — header NAMES stay compile-time ASCII, NS1029/NS1030 bounds still gate what is knowable at build time and the engine err-arm rejects the rest); no wire change was needed — record 0x09 always carried values as length-prefixed byte fields built at dispatch time, only the emitter's literal-only rule and the node SDK's `FetchSpec` type moved. And the `envMsgs` channel now journals each launch delivery (an additive `.env` effect record: value in `payload`, arm name in `stderr_tail`, dispatch index in `key`), so replay feeds the RECORDED values with zero env reads — a session recorded with credentials set replays byte-identically on a machine where they are unset or different; journals without env records (older recordings) re-derive from the launch configuration exactly as before. `examples/ai-chat-ts` now sends a real `Authorization: Bearer <key>` header instead of the access_token query-parameter workaround, and its replay e2e drives both the unset-env and changed-env launches. Plus NS1051: an un-annotated spread local (`const turns = [...model.turns, next]`) now teaches its array-type annotation instead of the generic emit-time stop (#119).
- **TypeScript subset: grammar completeness**: the subset now means "TypeScript minus the ecosystem minus the purity violations" — never minus basic syntax. New in the mapping: `do...while` (body-first, `continue` re-tests, exactly node), labeled statements with labeled `break`/`continue` (loops and blocks, lowered to Zig labels), `default` arms on union-`kind` switches (the `else` prong over unnamed arms; dead-code defaults emit nothing), `**`/`**=` (JS pow corners pinned: NaN exponents, `±1 ** ±Infinity`, right-associativity), the shifts `<< >> >>>` and `~` (ToInt32 with the count masked & 31), the full compound-assignment family (`*= /= %= &= |= ^= <<= >>= >>>=` plus guarded `&&= ||= ??=`), unary `+`, const record destructuring (`const { total, done: doneCount } = stats;`), namespace imports over the core's own modules (`import * as util` — values, calls, and qualified types resolve to the flat emitted names), multi-counter for-inits and comma incrementors (`for (let lo = 0, hi = n; lo < hi; lo++, hi--)`), countdown incrementors (`i--`), hole-free template literals, `satisfies`, and the empty statement (#119).
- **Every exclusion now teaches**: twelve new rules close every generic-error hole — NS1039 (namespace aliases are dot-syntax, SDK intrinsics import by name), NS1040 (regexes), NS1041 (runtime type/shape tests: `typeof`/`in`/`instanceof`/`Object.*`), NS1042 (generators), NS1043 (comma/`void`/assignment-as-value), NS1044 (BigInt/Symbol), NS1045 (destructuring beyond const record fields), NS1046 (nested/stored function values and `?.()`), NS1047 (default exports, `export =`, value re-exports), NS1048 (loose `==`), NS1049 (`var`), NS1050 (generic declarations) — and NS1019 broadens to the full fixed-arity story (rest params, `arguments`, call spreads). `var` and generic helpers previously emitted broken Zig silently; both now stop with teachings, and same-file type/value homonyms are caught by NS1038 instead of colliding in the emitted module (#119).
- **The grammar matrix**: a new machine-checked suite (`packages/core/test/grammar_matrix.test.ts`) enumerates every statement, operator, expression, and declaration form of the language and pins each to its verdict (SUPPORTED emits and compiles under Zig; BANNED names its teaching rule; tsc-rejected stays tsc's), so the grammar can never grow a silent gap again. New run-fidelity corpora pin the node-vs-native behavior of every new mapping (pow corners, shift wrapping, `-0` preservation, do-while ordering, labeled-jump targets, default-arm matching, destructured aliases, `??=` on 0-vs-null) (#119).
- **Inference fixes surfaced by the matrix**: the float-demotion fixpoint no longer terminates one pass early (a two-hop chain — field → destructured alias → local — previously stranded a phantom NS1016 conflict), and shorthand `{ x }` properties now wire the VALUE symbol into inference (a shorthand from a host-boundary parameter previously kept a false integer proof and emitted mismatched Zig) (#119).
- **Stock-IDE support for TypeScript apps, working before the npm publish**: `native init` scaffolds `package.json` (the app's name plus an exact `@native-sdk/core` pin) and `tsconfig.json` (the checker's own compiler options, so editor errors match `native check` reality), and the CLI materializes `node_modules/@native-sdk/core` itself — a copy of exactly what the published package will contain — so VS Code et al. resolve `@native-sdk/core` and `@native-sdk/core/text` with full IntelliSense today. `native check|dev|build|test` keep the copy fresh (one info line on refresh) and `native doctor` reports version skew; once the package is on npm, a plain `npm install` writes identical content and the CLI recognizes the version and leaves it alone. None of it is build truth: builds transpile against the SDK checkout and work with node_modules deleted, tree detection still keys on `src/core.ts` alone, and the Zig template is untouched (#119).
- **@native-sdk/core is publish-shaped**: `files: ["sdk"]`, a typed exports map for `.` and `./text`, no bin and no runtime dependencies (the transpiler dependency moved to devDependencies), with a package test pinning the manifest shape. The soundboard-ts and system-monitor-ts example ports carry the same editor surface, and a ts-core e2e suite proves the whole contract with the real tsc: fresh scaffold and both ports typecheck with zero injected paths, and the transpiler still takes the core clean after `rm -rf node_modules` (#119).
- **TS cores: mutating array methods are legal on locally-owned arrays**: an array your function creates (a literal or a `.slice()`/`.map()`/`.filter()`/`.concat()`/`.toSorted()` copy) now takes the full mutating set — `push` (any seed, not just the empty builder), `pop`/`shift` (returning the find-miss optional), `unshift`, `splice` (JS index clamping, the removed array as its value), `reverse`, `fill`, in-place `sort` (the stable toSorted machinery applied in place), and indexed writes — with node-byte-identical semantics pinned by a new run-fidelity corpus (parser stacks, splice corners, shift/unshift order, sort stability, pop-on-empty) and a machine-checked mutation matrix beside the grammar matrix (#119).
- **Teaching errors now fire only at the true semantic boundaries**: shared data keeps NS1001/NS1022 (both rewritten around ownership, NS1022 naming the now-legal `const copy = xs.slice(); copy.sort(cmp);` idiom), and the new NS1051 teaches mutation after an escape — returned from a callback, passed to a call, stored, or aliased — with the escape kind and line named; an escape inside a loop gates the whole loop body, and early-exit returns stay legal (#119).
- **TypeScript cores reach the full app surface**: markup sliders and split dividers deliver their applied 0..1 fraction to a core's one-number float arm (`on-change="scrubbed"` — scrub-to-seek from markup), controlled scroll round-trips through a core-declared `ScrollState` mirror, and the generated wiring detects five host-event channels from plain exports — `frameMsg` (presented frames), `keyMsg` (the app-level key fallback), `appearanceMsg` and `chromeMsg` (system appearance and hidden-titlebar geometry as Msg arms), and `envMsgs` (launch environment variables as journaled boot Msgs) — plus `app.zon` `.assets.images` registered at launch as the `ImageId`s markup avatars bind (#119).
- **Export lists and value re-exports compile in TypeScript cores**: `export { a, b as c }` and `export { x } from "./m.ts"` now bind real names over existing declarations in the flat emitted namespace — un-renamed entries export the declaration itself, renames emit a `pub const c = a;` alias, and re-export chains resolve end to end (node ≡ native, pinned by run-fidelity). Renamed entry-module helpers join the markup binding surface under their exported names; NS1047 narrows to the genuinely unsound tail (`export default`, `export =`, `export * from`, renamed generics/classes, wiring config, SDK re-exports), and NS1014/NS1038 keep entry points and name uniqueness honest across the new forms (#119).
- **Heterogeneous throws with a narrowing catch**: a core may now throw several distinct kind-tagged shapes — the checker collects them into an implicit thrown union (or a declared union whose arms match), the payload slot is that union, and `catch (e)` narrows it with plain kind tests (`if (e.kind === "parse")`) with no `as` ceremony; rethrow re-raises the bound value, narrowing works across callback boundaries, and NS1057 narrows to genuinely unsound throws (untagged values in a mix, tag collisions, untyped escapes, `new Error`). All pinned node ≡ native by run-fidelity (#119).
- **Class statics and erased privacy**: `static` methods lower to receiver-less module functions under the class's mangled names (`Task.fromRow(...)` -> `Task__fromRow`), `static readonly` fields with initializers become module consts (`Task.LIMIT`), and `private`/`protected` keywords are accepted and erased (tsc enforces them at the type level — their whole meaning). Mutable statics teach NS1010 (module state), `this` inside a static member teaches toward the class name, and `#`-fields stay taught; NS1056 narrows accordingly. Pinned node ≡ native by run-fidelity (#119).
- **Three mutation loosenings**: `xs[xs.length] = v` on an owned array is a push (the one growth shape; compound forms stay taught), a reassigned `let` stays owned when every assignment installs a fresh owning construction (each reassignment resets the emitted builder), and passing an owned array into a `readonly T[]` parameter is a BORROW when the callee provably only reads it (coinductive analysis — recursion over borrowed slices stays legal; returns, stores, casts to mutable, and onward passes into mutable positions still end ownership). NS1001/NS1051 copy updated; mutation matrix rows moved and extended; all pinned node ≡ native (#119).
- **Accurate teaching for the Array statics (NS1059)**: `Array.from`/`Array.of`/`Array.fromAsync` now teach their own construction rewrites (the literal, the spread copy, the push-builder loop) instead of the generic runtime-shapes copy; `Array.isArray` keeps NS1041 — it really is a runtime type test. Comma expressions in value position stay taught (NS1043): the split-statement lowering is only JS-order-exact in the pinned positions, so they did not fall out of the machinery for free (#119).

### Improvements

- **The components reference is markup-first**: every component page leads with its Native markup sample (all fences validated against the live `native markup check`), interactive samples show the core side in both authoring languages behind the TS | Zig toggle (accordion, checkbox, radio, dialog, input, scroll, select, slider, split, chart), and the builder form moves to a consistent "Programmatic construction (Zig)" section at the end of each page — real API docs, framed as the Zig tier's programmatic alternative. The section index tells the one-language story, and four samples that shipped unnamed text controls now carry accessible names (#119).
- **The TypeScript authoring package is `@native-sdk/core`**: the transpiler package moved from `packages/ts-app-core` to `packages/core` under its real npm name — cores were already importing `@native-sdk/core`, and the dev-harness resolver now maps that one specifier straight onto the package's own SDK module (#119).
- **TS-first docs with a TS | Zig toggle**: code samples on the flagship pages (Quick Start, App Model, Native UI, State & Data Flow) show TypeScript first with the Zig form one tab away — the reader's language choice is remembered site-wide — and the new [TypeScript Cores](https://native-sdk.dev/typescript) page covers the app-core subset, Cmd/Sub effects, text-is-bytes, the node dev loop, capacity knobs, and the eject story. Toolkit-extension pages stay Zig on purpose: that tier is the machinery itself (#119).
- **Docs code presentation**: the TypeScript | Zig code toggle now renders as the same segmented pill control as the component previews' Default | Geist theme-pack toggle (one shared primitive, identical in dark mode), and code samples can carry a filename header — a file glyph plus the path (```` ```ts:src/core.ts ````), integrated into the toggle's header bar opposite the segments — applied across the quick-start, TypeScript, app-model, native-ui, and config pages' complete-file samples; copied markdown renders the path as a labeled line above a plain fence (#119).
- **Markup binds your model's field names exactly as you wrote them**: TypeScript cores now emit Zig with the TS spellings intact — fields, exported single-model helpers, Msg payload records, and locals alike — so `nextId` binds as `{nextId}` and `doneCount` as `{doneCount}`, ending the dual-naming rule (camelCase in core.ts, snake_case in app.native) that every author had to hold in their head. Zig cores are untouched: their fields were already the names markup binds. The whole pipeline follows from the one change — the model contract, `native check`'s typed pass, both markup engines, hot reload, and the eject story (the emitted module now mirrors your source, and markup keeps binding the same names after you adopt it) (#119).
- The TS-track host surfaces that matched emitted names structurally now speak the TS SDK spellings (`timestampMs`/`intervalMs`, `colorScheme`/`reduceMotion`/`highContrast`, `tabsProjected`, the audio arm's `positionMs`/`durationMs`), and the declared scroll-state mirror accepts the canvas spelling or the TS spelling — never a mix (#119).
- NS1031 collisions are now exact-name collisions (`doneCount` the helper vs `doneCount` the field); `viewUnbound` entries were already the TS names and stay so. Scaffold templates, both ports' views, the ai-chat view, docs, and the skill teach the one rule (#119).
- **zig-core starter parity**: `native init --template zig-core` now scaffolds the same app as the TypeScript template — counter, a ticking switch driving a repeating 1s `fx.startTimer`, a Stamp button reading the journaled clock (`fx.wallMs`), a bindable `total` helper, and the matching markup — with generated full-loop tests covering the timer and clock seams; the quick-start code toggle now shows both starters verbatim (#119).

### Bug Fixes

- **Packaging fails loudly when signing fails**: `native package --signing adhoc|identity` no longer exits 0 while shipping an unsigned bundle — output paths with spaces (`--output "My App.app"`) now sign correctly (the signing pipeline execs argv arrays instead of shell strings, which also unbreaks spaced paths and spaced identities in the notarization helpers), every signed bundle must pass `codesign --verify --deep --strict` before packaging succeeds, any codesign failure stops the package with codesign's own reason, and the package report proves the outcome with a `signing: adhoc (signed, verified)` line (#118).
- **Per-thread memory no longer scales with the canvas scratch**: the render planner's fixed scratch buffers lived in static thread-local storage, so on Windows every thread the process spawned (window host, COM, accessibility, workers) privately committed a full ~6.5 MB copy — most of a small app's working set. The scratch now allocates lazily on the one thread that actually plans frames: a scaffolded counter app's private working set drops ~4x, its `.tls` section shrinks from ~6.5 MB to under 200 bytes, and the executable itself is ~6.5 MB smaller. Linux and macOS binaries shed the same per-thread TLS block (#117).
- **Transpiler: a ternary initializer under null-guard fusion parenthesizes**: `const x = c ? f(a) : g(a); if (x === null) <exit>` lowers to Zig's `orelse` fusion, and the conditional's if/else expression now wraps in parens — bare, the `orelse` bound to the ELSE arm alone (a type error at best, the wrong value at worst). The same guard covers `??` over a ternary left side; pinned in the conformance corpus and the node/native run-fidelity corpus (#119).

### Contributors

- @ctate
- @SunkenInTime
- @sepehr-safari

## 0.4.4

### New Features

- **Native-only host builds (Windows)**: the build graph now infers web use from app.zon — a `.frontend` block, the `"webview"` capability, a `.shell` webview view, or the Chromium engine — and an app that declares none of them compiles its Windows host without the embedded WebView layer: no WebView2 header, no `WebView2Loader.dll` installed, staged, or referenced by the executable. A new `.webview_layer = "auto"|"include"|"exclude"` manifest field (and `-Dweb-layer`) overrides the inference, an exclude that contradicts a web declaration is rejected at validate, configure, and package time, and a native-only build that reaches webview creation at runtime fails fast with a teaching `WebViewLayerNotBuilt` error. `native check` and the package report print the web-layer verdict, and a CI cross-audit asserts the presence/absence of the loader reference in real cross-compiled executables (#107).
- **Native-only host builds (Linux)**: the WebKitGTK compile seam mirrors the Windows one — an app whose app.zon declares no web use compiles its GTK host with `NATIVE_SDK_ALLOW_WEBKITGTK_STUB`, so the executable neither links `webkitgtk-6.0` nor references any `webkit_`/`jsc_` symbol, building needs no WebKitGTK development package, and users need no `libwebkitgtk` at runtime. The web-layer auditor (`tools/audit_web_layer.zig`) grew a hand-rolled ELF reader (DT_NEEDED entries + dynamic symbols) that CI runs both ways: the native-only fixture must scan clean even with the dev package installed, and the Linux canvas smoke now builds on a runner without WebKitGTK at all. `native package` refuses to package a WebKitGTK-linking binary under a native-only decision, record→replay and automation-driven sessions are pinned on native-only apps, and the macOS GPU dashboard smoke asserts a native-only app spawns zero WebKit helper processes (#110).

### Improvements

- **Zig 0.16 guidance**: a new `zig` skill (`native skills get zig`) maps each pre-0.16 std idiom's compile error to the current one — `std.Io` file IO and writers, unmanaged `ArrayList`, `main(std.process.Init)`, spawning, clocks, `{t}`/`{f}` formatting, `build.zig` modules — with the same content for humans as the docs' Zig 0.16 Notes page; the native-ui skill carries the short table, and a failing `native build|test|dev` now points at the catalog when std members come up missing (#105).
- **Lazy Linux WebView startup**: GTK windows now create only GTK chrome at window creation and materialize the main `WebKitWebView` on first web use, so canvas-only apps do not start WebKit processes on Linux; child-WebView bridge responses no longer require a main WebView to exist (#106).

### Contributors

- @ctate
- @WhiteHades

## 0.4.3

### Improvements

- **Linear-light edge blending**: anti-aliased fringes on opaque rounded rectangles, path fills, and strokes now composite through a linear-light coverage path, removing the dark rims that sRGB blending produced on curved geometry while keeping opaque interiors, glyph coverage, and translucent overlays byte-identical (#89).

### Bug Fixes

- **Single-line fields handle overflowing values**: text, selection rects, composition underlines, and the caret now clip to the field's content rect, and a horizontal scroll offset keeps the caret visible — typing past the edge scrolls the value, Home scrolls back, and deleting never leaves trailing emptiness. Covers text fields, inputs, search fields, and comboboxes; values that fit render exactly as before (#90).
- **Cross-drive apps on Windows**: `native dev|build|test` no longer fails with `expected path relative to build root; found absolute path` when the app and the npm-installed SDK live on different drives — the generated build graph now bridges volumes with a `.native/sdk` directory junction (no admin rights needed) and keeps the zon dependency relative; the junction is retargeted automatically when the SDK moves or upgrades. Where the bridge cannot apply (`native eject`, full-shape `native init`, or a filesystem that refuses junctions), the CLI explains the cross-volume constraint and both ways out instead of writing a build Zig would reject (#92).

### Contributors

- @ctate
- @fleeting-zone
- @kvnwdev

## 0.4.2

### Improvements

- **Windows rendering is DPI-aware and sharper**: Windows apps now declare Per-Monitor V2 DPI awareness, each window carries its own device scale, and canvases, native child views, hidden-titlebar sizing, and explicit WebView frames re-render/re-round correctly when moved across mixed-DPI monitors (#81).
- **Smoother canvas geometry**: rounded-rect fills and strokes now render through continuous coverage while eligible hairline borders snap to crisp device-pixel columns, so arcs stay anti-aliased and 1px borders stay sharp under the default house and Geist packs (#81).
- **Canonical package and documentation metadata**: npm package metadata, release automation, docs, templates, and examples now point at the renamed `vercel-labs/native` repository and `native-sdk.dev`; `version:sync` stamps repository/homepage metadata into platform packages and `version:check` rejects drift before publish (#78, #80).

### Bug Fixes

- **Windows embedded WebView is real from a plain checkout**: the WebView2 SDK header and loader are vendored under `third_party/webview2/` (BSD-licensed), every build graph puts the header on the include path, and the host now refuses to compile with the WebView layer silently stubbed — previously every Windows build shipped the stub and WebView loads reported `WebViewNotFound` at runtime (#86).
- **WebView2 host conformance fixes**: a missing lambda capture in the bridge message handler, a mingw-compatible WRL event-handler factory, an `EventToken` shim, and STA COM initialization on the host thread let WebView2 environment creation and bridge messaging run on Windows (#86).
- **WebView2Loader.dll ships with the app**: `zig build` installs the architecture's loader next to the executable, `zig build run` resolves it during dev runs, generated frontend/package commands carry `NATIVE_SDK_PATH`, and `native package --target windows` includes the loader in the artifact (the Evergreen WebView2 runtime itself is preinstalled on current Windows) (#86).
- **Checkbox marks use the vector core**: checked boxes now draw one stroked polyline with round caps and joins instead of two aliased diagonal lines, and stroke caps ride the GPU packet path so the host and reference renderer agree (#87).
- **Path geometry lifetimes are owned by the builder**: chart, spinner, and checkbox path commands no longer borrow threadlocal frame scratch, so separately emitted trees cannot alias each other's path elements (#87).

### Contributors

- @ctate

## 0.4.1

### Bug Fixes

- **npm package assets**: Ship the SDK's root `assets/` directory in `@native-sdk/cli` so installed packages include `assets/native-sdk.manifest`, the default macOS icon, and entitlements needed by generated apps (#72, #75).

### Contributors

- @ctate
- @lzitser23

## 0.4.0

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
