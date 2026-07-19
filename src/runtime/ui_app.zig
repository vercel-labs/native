//! Runtime-owned application loop for the declarative ui builder.
//!
//! `UiApp(Model, Msg)` wraps an elm-style app — model value, `update`
//! function, `view` function — as a `native_sdk.App`, owning everything the
//! builder examples previously hand-rolled: the two-arena rebuild swap, the
//! first-frame install choreography (`setCanvasWidgetLayout` +
//! `emitCanvasWidgetDisplayList`), presentation buffers, resize handling,
//! and typed pointer/keyboard dispatch through the tree's handler table.
//!
//! An app becomes: declare `Model` and `Msg`, write `update` and `view`,
//! and hand them to `UiApp` with a shell scene containing one `gpu_surface`
//! view. Shell command events can map into messages through `on_command`.
//!
//! Secondary windows are model-declared: `Options.windows_fn` returns the
//! window descriptors that should exist right now (presence IS
//! visibility), `Options.window_view` builds each declared window's
//! canvas tree, the runtime reconciles declared against live windows
//! after every rebuild, input from any window dispatches Msgs with its
//! window identity, and a user close dispatches the descriptor's
//! `on_close` Msg — the dismissal precedent, applied to windows.
//!
//! Markup apps choose an engine per build: `Options.markup` runs the
//! runtime parser/interpreter (dev, hot reload), while
//! `canvas.CompiledMarkupView(Model, Msg, source).build` handed to
//! `Options.view` compiles the same source at comptime (release, no parser
//! in the binary — pair with `UiAppWithFeatures(..., .{ .runtime_markup =
//! false })` so the watch machinery compiles out too). Setting both keeps
//! the compiled view until the watched file first changes on disk.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const core = @import("core.zig");
const canvas_frame = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const launch_timing = @import("launch_timing.zig");
const runtime_effects = @import("effects.zig");
const ui_app_provenance = @import("ui_app_provenance.zig");

const Runtime = core.Runtime;
const App = core.App;
const Event = core.Event;

const ui_app_log = std.log.scoped(.zero_ui_app);

/// Maximum number of webview panes a `UiApp` can drive (`Options.web_panes`).
pub const max_web_panes: usize = 4;

/// Approach-end hysteresis for `on_reach_end`, in viewports from the
/// content end: fire when the offset comes within one viewport, re-arm
/// only past one and a half — so the fire and re-arm boundaries never
/// chatter, and a freshly appended batch (which grows the extent) is
/// what re-arms the next approach.
pub const reach_end_fire_ratio: f32 = 1.0;
pub const reach_end_rearm_ratio: f32 = 1.5;

/// Approach-START hysteresis for `on_reach_start` (load older history in
/// tail-anchored transcripts): the mirror of the reach-end band — fire
/// when the offset comes within one viewport of the content start,
/// re-arm only past one and a half. Prepending a batch re-arms on its
/// own because the offset grows by the prepended extent (the viewport
/// anchor), exactly as appending re-arms reach-end by growing the
/// extent.
pub const reach_start_fire_ratio: f32 = 1.0;
pub const reach_start_rearm_ratio: f32 = 1.5;

/// A correction of at least this many points (the anchor-preserving
/// offset delta a variable-extent window left pending after the measure
/// step) earns the one coverage-style retry build, so the first
/// presented frame after a mount or a big estimate miss is already
/// correction-consumed. Below it, the delta rides to the next rebuild —
/// offsets and geometry still shift together, atomically.
pub const virtual_correction_retry_threshold: f32 = 0.5;

/// Comptime feature selection for `UiAppWithFeatures`.
pub const UiAppFeatures = struct {
    /// Ship the runtime markup engine (parser + interpreter) in the app.
    /// Required for `Options.markup` — runtime-parsed embedded sources and
    /// watch-based hot reload. Disable it in builds whose view comes from
    /// `canvas.CompiledMarkupView` so no parser code (or its diagnostics)
    /// ships in the binary; the markup machinery then compiles to nothing.
    runtime_markup: bool = true,
};

pub fn UiApp(comptime ModelT: type, comptime MsgT: type) type {
    return UiAppWithFeatures(ModelT, MsgT, .{});
}

pub fn UiAppWithFeatures(comptime ModelT: type, comptime MsgT: type, comptime features: UiAppFeatures) type {
    return struct {
        const Self = @This();

        pub const Ui = canvas.Ui(MsgT);

        pub const MarkupView = canvas.MarkupView(ModelT, MsgT);

        /// The fragment watch exists only where BOTH the runtime markup
        /// engine (the interpreter that builds reloaded fragments) and a
        /// Debug build (the dev loop) are present; everywhere else its
        /// state, polling, and registration collapse to nothing.
        const fragment_watch_enabled = features.runtime_markup and builtin.mode == .Debug;

        /// Fixed budget of watched fragments per app. Registrations past
        /// it are not watched (a teaching warning names the budget when
        /// the watch arms) — a view embedding more compiled fragments
        /// than this wants consolidation more than it wants polling.
        pub const max_watched_fragments: usize = 16;

        /// One registered fragment's hot-reload state.
        const MarkupFragmentSlot = struct {
            /// Two-arena swap, the `markup_arenas` discipline: a reload
            /// resolves into the inactive arena and adopts on success, so
            /// the live document — still referenced by the retained tree
            /// — survives failed parses and failed rebuilds; the inactive
            /// arena is reset only when the next reload attempt begins.
            arenas: [2]std.heap.ArenaAllocator,
            arena_index: usize = 0,
            /// The adopted override document the compiled fragment's
            /// build swaps in through the Ui seam; null while the disk
            /// closure matches the embedded baseline, which keeps the
            /// comptime-compiled path (and drops back to it when an edit
            /// is reverted byte for byte).
            document: ?canvas.ui_markup.MarkupDocument = null,
            /// Hash of the embedded source closure the fragment was
            /// compiled from, computed when the watch arms.
            baseline_hash: u64 = 0,
            /// Hash of the last disk closure seen — the change detector,
            /// updated on every divergence (including failed parses, so
            /// one bad save teaches once, not once per poll).
            hash: u64 = 0,
        };

        fn markupFragmentSlotsInit(backing: std.mem.Allocator) [max_watched_fragments]MarkupFragmentSlot {
            var slots: [max_watched_fragments]MarkupFragmentSlot = undefined;
            for (&slots) |*slot| {
                slot.* = .{ .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                } };
            }
            return slots;
        }

        /// The app's effect system (TEA's Cmd half): `fx.spawn` /
        /// `fx.fetch` / `fx.writeFile` / `fx.readFile` / `fx.cancel`
        /// from an `update_fx`-style update. See `runtime/effects.zig`
        /// for capacities and semantics.
        pub const Effects = runtime_effects.Effects(MsgT);

        /// One app font face registered on the installing frame (see
        /// `Options.fonts`). The face parses at registration —
        /// registration is where invalid files fail, loudly, with a
        /// teaching error naming this entry's `name` — and the id then
        /// resolves everywhere a `canvas.FontId` rides: token overrides
        /// (`typography.font_id` / `mono_font_id`), both renderers,
        /// atlas keys, fingerprints. Glyphs the face does not cover keep
        /// the same per-glyph notdef fallback as the built-in faces —
        /// a registered face never silently cascades into another
        /// family.
        pub const FontRegistration = struct {
            /// App-chosen id, at or above `canvas.min_registered_font_id`
            /// (lower ids are reserved for built-in faces). Permanent for
            /// the app's lifetime; store it in tokens, not handles.
            id: canvas.FontId,
            /// Human name for teaching errors — the asset's file name is
            /// the right choice. Never rendered.
            name: []const u8,
            /// Raw TrueType (`glyf`) bytes: `@embedFile` of a bundled
            /// asset, or bytes loaded before the app starts. Copied at
            /// registration, so transient buffers are fine.
            ttf: []const u8,
        };

        pub const ChromeOptions = struct {
            /// Number of chrome commands preserved in front of the
            /// widget-generated commands.
            prefix_commands: usize,
            /// Number of chrome commands preserved after the
            /// widget-generated commands.
            suffix_commands: usize = 0,
            /// Builds the chrome display-list commands: exactly
            /// `prefix_commands` commands followed by `suffix_commands`
            /// commands.
            build: *const fn (model: *const ModelT, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void,
        };

        /// A live webview region hosted alongside the canvas — the "both
        /// per window" seam. The scene declares the webview shell view
        /// (kind `.webview`, ideally with `.parent` set to the canvas
        /// view's label so pane frames share the canvas coordinate
        /// space); the pane then keeps that webview snapped to a canvas
        /// widget's layout frame and drives navigation from the model.
        pub const WebViewPane = struct {
            /// Shell view label of the scene-declared webview this pane
            /// drives.
            label: []const u8,
            /// Semantics label of the canvas widget whose layout frame
            /// becomes the webview's bounds — typically an empty panel
            /// that reserves the region in the view
            /// (`.semantics = .{ .label = "preview-pane" }`). When null,
            /// `frame` positions the webview directly.
            anchor: ?[]const u8 = null,
            /// Explicit frame used when no `anchor` is set. Canvas-local
            /// when the webview is parented to the canvas view.
            frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
            /// Current URL. Changing it navigates the webview, subject to
            /// the app's `security.navigation.allowed_origins` policy.
            url: []const u8,
            /// Bump to reload the current URL without changing it (the
            /// `reloadToken` consumer shape).
            reload_token: u64 = 0,
        };

        /// Menu-bar extra: a status-bar item with a command menu
        /// (macOS `NSStatusItem`; the system tray elsewhere, where
        /// supported). Selecting a menu item dispatches its `command`
        /// through `on_command` with source `.tray`.
        pub const StatusItemOptions = struct {
            /// Menu-bar button title (used when no icon resolves; macOS
            /// falls back to the app name's first letter when both are
            /// empty).
            title: []const u8 = "",
            /// Template-image path for the status button icon.
            icon_path: []const u8 = "",
            tooltip: []const u8 = "",
            /// Menu items: `label` is the visible title, `command` the
            /// name handed to `on_command`, `id` a unique non-zero id.
            items: []const platform.TrayMenuItem = &.{},
        };

        /// Model-derived status-item state returned by
        /// `Options.status_item_fn`: the live button title and menu.
        /// Slices may point at the scratch the fn received, the model, or
        /// static strings — they only need to outlive the apply (the
        /// runtime and platform copy what they keep).
        pub const StatusItemState = struct {
            title: []const u8 = "",
            items: []const platform.TrayMenuItem = &.{},
        };

        /// Scratch handed to `status_item_fn` so a derived title
        /// (`std.fmt.bufPrint(&scratch.title_buffer, "{d} open", ...)`)
        /// and a built-up item list need no model-side storage. Lives on
        /// the app struct, so returned slices stay valid until the next
        /// apply.
        pub const StatusItemScratch = struct {
            title_buffer: [platform.max_tray_title_bytes]u8 = undefined,
            items: [platform.max_tray_items]platform.TrayMenuItem = undefined,
        };

        /// Budget for model-declared secondary windows (see
        /// `canvas_limits.max_ui_app_windows` for the sizing rationale).
        pub const max_ui_windows: usize = canvas_limits.max_ui_app_windows;

        /// A model-declared secondary window (`Options.windows_fn`):
        /// settings, about, inspectors. Identity is `label`; PRESENCE in
        /// the returned slice is visibility — the runtime reconciles the
        /// declared set against live windows after every rebuild,
        /// creating the missing and closing the no-longer-declared.
        /// There is deliberately no `visible` flag: the platform window
        /// channel is create/focus/close with no hide, so a
        /// hidden-but-open descriptor would lie about what exists. The
        /// model bool that `windows_fn` consults IS the visibility
        /// channel, exactly like a dismissible surface's open flag.
        pub const WindowDescriptor = struct {
            /// Window label: the stable identity across rebuilds, and
            /// the label automation snapshots print for the window.
            label: []const u8,
            /// The gpu_surface view label inside this window:
            /// `window_view` builds its tree, input events route back
            /// through it, and automation verbs address it. Must be
            /// unique across the app — distinct from the main
            /// `canvas_label` and every other descriptor's.
            canvas_label: []const u8,
            /// Window title, applied at creation (the platform window
            /// channel has no retitle; re-create under a new label for a
            /// different title).
            title: []const u8 = "",
            width: f32 = 480,
            height: f32 = 360,
            x: ?f32 = null,
            y: ?f32 = null,
            resizable: bool = true,
            /// Content min-size floor the WINDOW enforces (macOS
            /// `contentMinSize`): the user's resize stops at the floor
            /// instead of the layout clamping/clipping panes below
            /// their declared minimums. The window knows the floor the
            /// framework already knows. 0 = no floor on that axis.
            min_width: f32 = 0,
            min_height: f32 = 0,
            /// Titlebar chrome: `.hidden_inset` extends content under a
            /// transparent titlebar with the title hidden (macOS keeps
            /// the traffic lights) — the modern editor-app pattern —
            /// and `.hidden_inset_tall` is the same shape with the
            /// unified-toolbar-height band (traffic lights vertically
            /// centered, the tall unified-toolbar look). Drag regions and
            /// traffic-light-aware header layout are the dedicated
            /// titlebar-control channel's scope, not this field's.
            /// Platforms without the concept keep standard chrome.
            titlebar: app_manifest.WindowTitlebarStyle = .standard,
            /// Msg dispatched when the USER closes the window (never for
            /// a reconcile close the model itself initiated). The
            /// dismissal precedent: the window is already gone as an
            /// optimistic echo; the model clears its open flag in
            /// `update` — or keeps declaring the window and the next
            /// rebuild re-creates it (source wins).
            on_close: ?MsgT = null,
        };

        /// Scratch handed to `windows_fn` (the `status_item_fn` shape)
        /// so a derived descriptor list needs no model-side storage.
        /// Lives on the app struct; returned slices stay valid until the
        /// next apply.
        pub const WindowsScratch = struct {
            windows: [max_ui_windows]WindowDescriptor = undefined,
        };

        pub const MarkupOptions = struct {
            /// Markup source embedded into the binary: parsed on the first
            /// build when no `view` is set, and otherwise the baseline the
            /// watched file is compared against. (Release builds should
            /// prefer `canvas.CompiledMarkupView(...).build` on `view`,
            /// which parses at comptime instead.)
            source: []const u8,
            /// Embedded sources for the document's `<import>` closure:
            /// one entry per imported file, paths relative to the root
            /// file's directory — the same set `canvas.
            /// CompiledMarkupImports` takes, so one list feeds both
            /// engines. Used to resolve the embedded `source`; watch
            /// reloads resolve against the file system instead (edits to
            /// imported files hot reload too). Leave empty when the
            /// markup imports nothing.
            sources: []const canvas.ui_markup.SourceFile = &.{},
            /// Optional file to poll in dev: when the file — or any file
            /// its imports reach — changes on disk, the closure is
            /// re-resolved and the next rebuild uses the new view,
            /// keeping model state. Parse failures keep the last good view
            /// and set `markup_diagnostic`. Requires `io`. Watching runs a
            /// low-cost repeating runtime timer (`markup_watch_timer_id`),
            /// so leave it unset in release builds.
            watch_path: ?[]const u8 = null,
            io: ?std.Io = null,
        };

        /// Dev-mode hot reload for HYBRID roots: a Zig builder view that
        /// embeds compiled markup fragments registers each fragment's
        /// on-disk source here (`CompiledHeaderView.fragment("src/header.native")`),
        /// and in Debug runs the markup watch polls every registered file
        /// — plus every file each fragment's imports reach — reloading
        /// exactly the fragments a changed file serves. The same degrade
        /// family as the single-root watch: a bad save keeps the last
        /// good view and records the file:line teaching diagnostic, the
        /// next good save recovers. Outside Debug the registration
        /// handles are empty by construction (see `canvas.MarkupFragment`)
        /// and the watch compiles to nothing, so release binaries carry
        /// no source paths and no polling.
        pub const MarkupFragmentWatch = struct {
            /// One handle per compiled fragment, from the fragment
            /// type's `fragment(path)`.
            fragments: []const canvas.MarkupFragment,
            io: std.Io,
        };

        pub const Options = struct {
            name: []const u8,
            scene: app_manifest.ShellConfig,
            canvas_label: []const u8,
            /// Fixed design tokens for an app that owns its look. Leave
            /// null (the default) and the stock tokens FOLLOW THE SYSTEM
            /// appearance: light/dark scheme, high contrast, and reduced
            /// motion derive from the OS setting live — flipping the
            /// system appearance re-themes the running app without a
            /// restart. Set explicit tokens (or `tokens_fn`) to opt out.
            tokens: ?canvas.DesignTokens = null,
            /// Model-derived design tokens. When set, this is consulted on
            /// every install and rebuild instead of the static `tokens`,
            /// and `pixel_snap.scale` is stamped with the live surface
            /// scale afterwards: the model owns scheme/contrast/motion,
            /// the runtime owns the surface scale.
            tokens_fn: ?*const fn (model: *const ModelT) canvas.DesignTokens = null,
            /// Which built-in theme pack the stock tokens resolve when
            /// the app claims neither `tokens` nor `tokens_fn`: the
            /// pack composes with the live system appearance (scheme,
            /// contrast, reduced motion), so a packed app still
            /// re-themes on the OS light/dark flip. Apps that own their
            /// tokens pick a pack themselves via `ThemeOptions.pack`.
            /// The scaffold wires this to app.zon's `theme` field
            /// through `app_runner.manifestThemePack()`.
            theme: canvas.ThemePack = .house,
            /// The app's ONE-accent brand statement over the stock
            /// tokens: when set (and the app claims neither `tokens`
            /// nor `tokens_fn` — apps that own their tokens own their
            /// brand), the accent identity bundle
            /// (`canvas.accentOverrides`: accent + derived knockout
            /// ink, focus ring, slider active range) layers over the
            /// resolved pack on every rebuild. High-contrast requests
            /// skip it — accessibility beats brand, the same rule an
            /// app-owned tokens_fn states by hand. The scaffold wires
            /// this to app.zon's `theme_accent` field through
            /// `app_runner.manifestThemeAccent()`.
            theme_accent: ?canvas.Color = null,
            /// App font faces registered once, on the installing frame,
            /// BEFORE the first view build — so the very first layout
            /// already measures (and the first paint inks) with them.
            /// Reference the entries' ids from `tokens`/`tokens_fn`
            /// (`typography.font_id` for body, `mono_font_id` for mono
            /// runs). A registration failure is a teaching error naming
            /// the font and what is wrong, surfaced through the dispatch
            /// error channel — it never crashes the app and never
            /// silently substitutes a face at render time.
            fonts: []const FontRegistration = &.{},
            /// Non-widget chrome (backgrounds, gradients, titles) rebuilt
            /// together with the widget display list on install, resize,
            /// and every model rebuild via `setCanvasDisplayList` +
            /// `emitCanvasWidgetDisplayListWithChrome`.
            chrome: ?ChromeOptions = null,
            /// Render animations derived from the model and current tree,
            /// re-applied after every rebuild through
            /// `setCanvasRenderAnimations` with the latest frame timestamp
            /// as `start_ns`. Returns the number of animations written to
            /// `out`.
            animations: ?*const fn (model: *const ModelT, tree: *const Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize = null,
            /// Layout tweens derived from the model and current tree,
            /// re-declared after every rebuild through
            /// `startCanvasWidgetLayoutTween` (idempotent: an armed
            /// tween re-declared with the same target keeps its clock).
            /// Where `animations` moves PIXELS (opacity/transform, no
            /// reflow), a layout tween moves LAYOUT: the runtime eases
            /// a split's first-pane fraction from its current rendered
            /// value to the declared target, one step per presented
            /// frame, and the neighboring pane reflows exactly as if
            /// the divider were dragged — no hand-rolled per-frame
            /// Msgs. Declare the RESTING target (derive `to` from the
            /// model's collapsed flag); keep the split's `value` bound
            /// the way drags already require. Reduced-motion
            /// appearances snap instead of animating. Returns the
            /// number of tweens written to `out`.
            layout_tweens: ?*const fn (model: *const ModelT, tree: *const Ui.Tree, out: []canvas.CanvasWidgetLayoutTween) usize = null,
            /// Elm-style update. Set exactly one of `update` and
            /// `update_fx`: the plain form for pure apps, the `_fx` form
            /// when update needs the effects channel. Both drive the
            /// same loop; existing two-argument apps keep compiling
            /// unchanged.
            update: ?*const fn (model: *ModelT, msg: MsgT) void = null,
            /// Effects-capable update: the third parameter spawns and
            /// cancels subprocess effects (`fx.spawn(.{ ... })`,
            /// `fx.cancel(key)`). Effects are update-side only — views
            /// never spawn.
            update_fx: ?*const fn (model: *ModelT, msg: MsgT, fx: *Effects) void = null,
            /// TEA's init command: runs exactly once, on the installing
            /// frame, after the effects channel is bound and before the
            /// first view build — so a boot-time `fx.spawn`/`fx.fetch`
            /// starts before anything renders and any loading state it
            /// sets is in the very first paint. Results arrive as Msgs
            /// through the ordinary update path (either update form).
            /// This replaces the guarded-`on_frame` idiom for startup
            /// effects; `on_frame` remains the per-frame hook for frame
            /// diagnostics and presented-frame reactions.
            init_fx: ?*const fn (model: *ModelT, fx: *Effects) void = null,
            /// Hand-written or comptime-compiled view
            /// (`canvas.CompiledMarkupView(Model, Msg, source).build` slots
            /// in directly). At least one of `view` and `markup` must be
            /// set. When both are set, this view renders until the watched
            /// markup file first diverges from the embedded source, at
            /// which point the interpreter takes over (compiled view for
            /// release, hot reload in dev).
            view: ?*const fn (ui: *Ui, model: *const ModelT) Ui.Node = null,
            /// Runtime-parsed markup view. Requires
            /// `UiAppFeatures.runtime_markup` (the default).
            markup: ?MarkupOptions = null,
            /// Debug-only hot reload for compiled markup fragments a Zig
            /// `view` embeds (see `MarkupFragmentWatch`). Safe to set
            /// unconditionally: outside Debug it degrades to nothing.
            fragment_watch: ?MarkupFragmentWatch = null,
            /// Optional mapping from shell command events (menus, shortcuts,
            /// native controls) into messages.
            on_command: ?*const fn (name: []const u8) ?MsgT = null,
            /// Model-driven selection for declared platform chrome
            /// (`scene.chrome.tabs`): returns the id of the tab the
            /// model currently selects (one of the declared tab ids, or
            /// "" for none). Consulted on install and after every
            /// rebuild — the `status_item_fn` shape — and read by
            /// projecting hosts through `chromeSelectedTab()`, so the
            /// native bar is always a projection of the model: a tap
            /// dispatches the tab's command id through `on_command`,
            /// update moves the model, and this derivation moves the
            /// bar. The bar itself is never the source of truth.
            selected_tab_fn: ?*const fn (model: *const ModelT) []const u8 = null,
            /// Model-driven navigation depth for platform push/pop
            /// transitions: returns how many levels deep the model's
            /// current page sits (0 = the root page, 1 = one push in,
            /// ...). Consulted on install and after every rebuild — the
            /// `selected_tab_fn` cadence — and read by projecting hosts
            /// through `chromeNavigationDepth()`, which poll it and
            /// present a REAL platform transition when the depth grows
            /// (push) or shrinks (pop). The transition is presentation
            /// only: the MODEL owns navigation state, the depth is a
            /// pure derivation of it, and a journal replayed without a
            /// host produces the identical model. Tab switches are
            /// lateral, never depth: derive the depth of the CURRENT
            /// tab's page stack, so switching tabs while a page is open
            /// reads as a tab change (hosts reconcile without a
            /// transition), not a pop.
            navigation_depth_fn: ?*const fn (model: *const ModelT) usize = null,
            /// The command id a projecting host dispatches when the
            /// platform back affordance completes (iOS: the interactive
            /// edge-swipe-back gesture finishing) — the same command
            /// path tab taps and native header buttons ride, mapped to
            /// a Msg in `on_command`, so a gesture-driven back and the
            /// app's own back button are indistinguishable in the Msg
            /// journal. A cancelled gesture dispatches nothing. Set it
            /// together with `navigation_depth_fn`; hosts only arm the
            /// back gesture when both exist (a pop that could dispatch
            /// nothing would be a dead-end affordance).
            navigation_back_command: []const u8 = "",
            /// Optional app-level key FALLBACK for canvas keyboard
            /// input: consulted for a key_down only after widget
            /// routing declines it. The precedence rule (enforced in
            /// `handleKeyboard`, in this order):
            ///   1. A focused widget's bound handler wins — space on a
            ///      focused row activates THAT row, never the fallback.
            ///   2. A focused widget that structurally consumes the key
            ///      — an activation/step intent it answers to, or any
            ///      editable text widget, where typing must stay typing
            ///      (`canvas.isWidgetTextEntry`, checked by KIND so an
            ///      unbound `on_input` changes nothing) — eats it
            ///      silently.
            ///   3. Only then does the key fall through here, including
            ///      when nothing is focused at all.
            /// This is the honest home for unmodified media keys (the
            /// bare-space play/pause convention): chrome shortcuts
            /// (`Shortcut`/`on_command`) deliberately REQUIRE a modifier
            /// on character keys and space, precisely so registration
            /// can never steal typing — a fallback that yields to every
            /// consuming widget can carry them safely.
            on_key: ?*const fn (keyboard: canvas.WidgetKeyboardEvent) ?MsgT = null,
            /// Optional mapping from trackpad pinch gestures into
            /// messages — the app-level gesture channel (the `on_key`
            /// shape). Pinch deliberately bypasses the widget pipeline:
            /// it is a view-global gesture (timeline/canvas zoom is an
            /// app-level concern), delivered phase-explicit (`begin`,
            /// `change`, `end`) with the per-event magnification DELTA
            /// on `change` — a MULTIPLICATIVE delta: the cumulative
            /// gesture scale is the running product of `(1 + scale)`,
            /// applied memorylessly (`zoom *= 1 + scale`); on macOS the
            /// host forwards AppKit's raw `NSEvent.magnification`,
            /// which IS that delta per the browser-engine convention
            /// — and the pointer anchor in
            /// view-local canvas points (`x`/`y`, the zoom-at-cursor
            /// anchor). Every event names its source window and view
            /// (`window_id`/`label`, the `on_frame` identity shape) —
            /// view-local coordinates mean nothing without their view,
            /// so multi-window apps tell pinches apart. Only hosts with
            /// a pinch source emit these (macOS today); everywhere else
            /// the channel simply never fires.
            on_pinch: ?*const fn (pinch: platform.PinchEvent) ?MsgT = null,
            /// Optional mapping from runtime timer events (started via
            /// `runtime.startTimer`) into messages. Framework-reserved timer
            /// ids (>= `platform.reserved_timer_id_base`) are handled
            /// internally and never reach this callback — that includes fx
            /// timers (`fx.startTimer`), which deliver their own `on_fire`
            /// Msgs through the update path instead.
            on_timer: ?*const fn (id: u64, timestamp_ns: u64) ?MsgT = null,
            /// Optional mapping from system appearance changes into
            /// messages so the model can own color scheme, contrast, and
            /// reduce-motion state (and `tokens_fn` can derive from it).
            on_appearance: ?*const fn (appearance: platform.Appearance) ?MsgT = null,
            /// Optional mapping from the MAIN canvas window's chrome
            /// overlay geometry into messages — the hidden-titlebar
            /// (`titlebar = .hidden_inset`/`.hidden_inset_tall`)
            /// coordination channel. `chrome.insets` names the bands
            /// where OS window controls overlay the content (macOS:
            /// titlebar band height on top — compact or tall — and
            /// traffic-light extent on the leading edge), and
            /// `chrome.buttons` is the traffic-light cluster's frame in
            /// content coordinates so a header can vertically center
            /// its controls against the lights; everything is all-zero
            /// in fullscreen, on standard-chrome windows, and on
            /// platforms without the concept. Delivered before the
            /// first view build and again whenever the geometry changes
            /// (fullscreen transitions). Main canvas window only —
            /// declared secondary windows have no chrome hook yet (same
            /// scope note as `sync`).
            ///
            /// Mobile hosts answer the same channel with the viewport's
            /// safe-area insets (notch, status bar, home indicator), so
            /// the padding an app derives here is the one code path on
            /// every platform. Subscribing takes ownership of that
            /// padding: the runtime stops pre-insetting widget layout by
            /// the safe area (it keeps the keyboard's residual overlap),
            /// so an unsubscribed app keeps today's automatic insets.
            on_chrome: ?*const fn (chrome: platform.WindowChrome) ?MsgT = null,
            /// Optional mapping from presented gpu frames (carrying the
            /// renderer diagnostics the runtime recorded) into messages.
            /// Called after presenting every frame except the installing
            /// one.
            on_frame: ?*const fn (model: *const ModelT, frame: platform.GpuFrame) ?MsgT = null,
            /// Reads runtime-owned widget state (slider values, scroll
            /// offsets) back into the model before update and rebuild so
            /// the next source tree does not stomp it. Main canvas only:
            /// declared secondary windows' widget state is runtime-owned
            /// between rebuilds but has no sync hook yet — keep
            /// continuous controls in the secondary windows model-driven
            /// (echo `on_change`/`on_scroll` values back into `value`).
            sync: ?*const fn (model: *ModelT, layout: canvas.WidgetLayoutTree) void = null,
            /// Model-derived webview panes, re-applied after every rebuild
            /// (so also on resize and every dispatched Msg): each pane
            /// snaps its scene-declared webview to a canvas widget's
            /// layout frame, navigates when its URL changes, and reloads
            /// when its `reload_token` changes. Returns the number of
            /// panes written to `out` (at most `max_web_panes`).
            /// Engine-agnostic: the webview backend is whatever the build
            /// selected (`-Dweb-engine=system|cef`); platforms without
            /// child webviews log a warning and continue.
            web_panes: ?*const fn (model: *const ModelT, out: []WebViewPane) usize = null,
            /// Menu-bar extra installed once, on the installing frame.
            /// macOS-proven (`NSStatusItem`); platforms without a
            /// status-bar service log a warning and continue.
            status_item: ?StatusItemOptions = null,
            /// Model-derived status-item title and menu (e.g. an
            /// open-count badge in the menu bar, a latest-items
            /// dropdown), the `web_panes` pattern: consulted on install
            /// and after every rebuild, re-applied only when the output
            /// actually changed. Selections dispatch each item's
            /// `command` through `on_command` with source `.tray` —
            /// exactly the window-menu shape. With `status_item` also
            /// set, the static options provide the icon and tooltip
            /// (and the pre-install defaults); this fn owns title and
            /// items from the installing frame on. Platforms without a
            /// tray title seam keep the menu updates and log the title
            /// gap once.
            status_item_fn: ?*const fn (model: *const ModelT, scratch: *StatusItemScratch) StatusItemState = null,
            /// Model-declared secondary windows, reconciled after every
            /// rebuild (and on the installing frame): windows the model
            /// declares exist, windows it stops declaring close — the
            /// `status_item_fn` shape applied to the window set, so a
            /// settings window is `if (model.settings_open)` declaring a
            /// descriptor, opened by a Msg and closed by one. Requires
            /// `window_view`. A user close dispatches the descriptor's
            /// `on_close` Msg (the dismissal precedent: the engine
            /// already closed it; the model's next declared set is
            /// truth). Reconcile failures degrade to logged warnings —
            /// a failed create never takes the render loop down.
            windows_fn: ?*const fn (model: *const ModelT, scratch: *WindowsScratch) []const WindowDescriptor = null,
            /// Per-window view for declared secondary windows, keyed by
            /// the descriptor's window label — the `view` seam with the
            /// window identity alongside. Rebuilt for every open window
            /// on every dispatched Msg. Markup deliberately binds ONE
            /// window's content (the main canvas): there is no `window`
            /// element in the closed grammar because windows are shell
            /// concerns, not view-tree concerns — a markup-authored
            /// secondary window is a `canvas.CompiledMarkupView` whose
            /// `build` this fn calls for the matching label.
            window_view: ?*const fn (ui: *Ui, model: *const ModelT, window_label: []const u8) Ui.Node = null,
        };

        /// Last-navigated webview pane state, tracked per shell label so
        /// rebuilds only navigate when the URL or reload token actually
        /// changed. Frames are deliberately not cached: they reconcile
        /// against the runtime's live webview state every apply.
        const WebPaneState = struct {
            label_storage: [app_manifest.max_view_label_bytes]u8 = undefined,
            label_len: usize = 0,
            url_storage: [platform.max_webview_url_bytes]u8 = undefined,
            url_len: usize = 0,
            reload_token: u64 = 0,

            fn label(self: *const WebPaneState) []const u8 {
                return self.label_storage[0..self.label_len];
            }

            fn url(self: *const WebPaneState) []const u8 {
                return self.url_storage[0..self.url_len];
            }
        };

        /// Live state for one model-declared secondary window: its own
        /// tree and arena pair (the handler table must stay valid
        /// between events, per window), the runtime window id, and the
        /// close Msg. Slots are keyed by window label and reconciled by
        /// `applyWindows`.
        const WindowSlot = struct {
            label_storage: [platform.max_window_label_bytes]u8 = undefined,
            label_len: usize = 0,
            canvas_label_storage: [app_manifest.max_view_label_bytes]u8 = undefined,
            canvas_label_len: usize = 0,
            window_id: platform.WindowId = 0,
            on_close: ?MsgT = null,
            installed: bool = false,
            canvas_size: geometry.SizeF = .{ .width = 1, .height = 1 },
            /// The device scale of THIS window's surface, adopted from
            /// its own frame and resize events. Secondary windows can sit
            /// on a different-density monitor than the main canvas, so
            /// the scale is per-window state: the app owns ONE appearance,
            /// but each slot's rebuild stamps its own scale into
            /// `pixel_snap.scale` (`slotEffectiveTokens`) so this window's
            /// hairlines snap against the grid it actually renders on.
            /// The main canvas keeps its scale in `Self.pixel_snap_scale`.
            pixel_snap_scale: f32 = 1,
            tree: ?Ui.Tree = null,
            arena_index: usize = 0,
            arenas: [2]std.heap.ArenaAllocator,

            fn init(backing: std.mem.Allocator) WindowSlot {
                return .{ .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                } };
            }

            fn label(self: *const WindowSlot) []const u8 {
                return self.label_storage[0..self.label_len];
            }

            fn canvasLabel(self: *const WindowSlot) []const u8 {
                return self.canvas_label_storage[0..self.canvas_label_len];
            }
        };

        fn windowSlotsInit(backing: std.mem.Allocator) [max_ui_windows]WindowSlot {
            var slots: [max_ui_windows]WindowSlot = undefined;
            for (&slots) |*slot| slot.* = WindowSlot.init(backing);
            return slots;
        }

        model: ModelT,
        options: Options,
        arenas: [2]std.heap.ArenaAllocator,
        arena_index: usize = 0,
        tree: ?Ui.Tree = null,
        canvas_size: geometry.SizeF = .{ .width = 1, .height = 1 },
        canvas_window_id: platform.WindowId = 1,
        installed: bool = false,
        /// Exactly-once guard for `Options.fonts`: registration must not
        /// retry on every frame after a teaching failure (ids that DID
        /// register would then fail `FontIdInUse` and bury the real
        /// error).
        fonts_registered: bool = false,
        /// The runtime's registered-font count the installed trees last
        /// measured against. Registration is permanent with no
        /// unregister, so the count IS the runtime's fonts generation:
        /// a mismatch on a presented frame means a face joined the
        /// registry AFTER the trees were built (late registration
        /// through `runtime.registerCanvasFont` — `Options.fonts` lands
        /// before the installing build), and every installed surface
        /// must rebuild so layout re-measures with the new face
        /// (`rebuildForRegisteredFonts`).
        fonts_built_count: usize = 0,
        /// Exactly-once guard for `Options.init_fx`, independent of
        /// `installed` so a failed install rebuild cannot rerun it.
        init_fx_ran: bool = false,
        /// Last chrome overlay geometry delivered through `on_chrome`,
        /// so resize-driven re-queries only dispatch on actual change
        /// (fullscreen transitions flip it; ordinary resizes do not).
        window_chrome: platform.WindowChrome = .{},
        window_chrome_known: bool = false,
        /// The model's current selected chrome tab id (`selected_tab_fn`
        /// re-derived after every rebuild), stored so projecting hosts
        /// can poll `chromeSelectedTab()` between frames without touching
        /// the model. Command ids are capped by the manifest vocabulary.
        chrome_selected_tab_storage: [app_manifest.max_command_id_bytes]u8 = undefined,
        chrome_selected_tab_len: usize = 0,
        /// The model's current navigation depth (`navigation_depth_fn`,
        /// re-derived after every rebuild) plus whether a derivation has
        /// happened yet, stored so projecting hosts can poll
        /// `chromeNavigationDepth()` between frames without touching the
        /// model. Before the first rebuild (and whenever the app declares
        /// no derivation) hosts read -1 and project no transitions.
        chrome_navigation_depth: usize = 0,
        chrome_navigation_depth_known: bool = false,
        /// The system appearance the platform last reported (delivered
        /// before the first view build, then on every OS-side change).
        /// The stock token derivation reads it when the app sets neither
        /// `tokens` nor `tokens_fn`, so unthemed apps follow the OS
        /// light/dark setting live. Test/null platforms never emit it,
        /// so deterministic runs stay on the default light theme.
        system_appearance: platform.Appearance = .{},
        pixel_snap_scale: f32 = 1,
        frame_timestamp_ns: u64 = 0,
        markup_arenas: [2]std.heap.ArenaAllocator,
        markup_arena_index: usize = 0,
        markup_view: ?MarkupView = null,
        markup_source_hash: u64 = 0,
        /// Set when the embedded or watched markup failed to parse or build;
        /// cleared on the next successful parse. Apps may render it. The
        /// message and path slices point into the storage below (the
        /// resolver formats some messages in the reload arena, which
        /// resets on the next attempt).
        markup_diagnostic: ?canvas.ui_markup.MarkupErrorInfo = null,
        markup_diagnostic_message_storage: [512]u8 = undefined,
        markup_diagnostic_path_storage: [canvas.ui_markup.max_import_path_len]u8 = undefined,
        /// Fragment hot-reload slots (Debug dev runs only), one per
        /// registered fragment in `Options.fragment_watch` order. Exists
        /// only where the fragment watch does, so release binaries carry
        /// none of this state. No default on purpose: every constructor
        /// must initialize the arenas against the backing allocator.
        markup_fragment_slots: if (fragment_watch_enabled) [max_watched_fragments]MarkupFragmentSlot else void,
        /// Widget provenance (write-back's read half): the retained
        /// structural-id -> authored-markup table the `provenance`
        /// automation verb answers from. Exists only in markup-interpreter
        /// builds; filled only while automation is enabled.
        provenance: if (features.runtime_markup) ui_app_provenance.ProvenanceTable else void =
            if (features.runtime_markup) .{} else {},
        /// Import-closure staging for the file table: filled by the
        /// hashing loader during a resolve, committed on adopt so a failed
        /// mid-edit reload can never re-anchor spans to bytes the running
        /// view was not built from.
        provenance_closure: if (features.runtime_markup) ui_app_provenance.ClosureFiles else void =
            if (features.runtime_markup) .{} else {},
        layout_nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined,
        gpu_commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined,
        /// Packet transport buffer, sized for the larger of the two wire
        /// encodings (the compact binary bound; the JSON bound is
        /// smaller and the runtime clamps JSON encodes to it), so a
        /// text-heavy frame that fits either encoding rides the packet
        /// path.
        packet_bytes: [platform.max_gpu_surface_packet_binary_bytes]u8 = undefined,
        /// Allocator backing the arenas and the lazily grown pixel
        /// presentation buffers below.
        backing: std.mem.Allocator,
        /// CPU presentation scratch, used only on platforms without a GPU
        /// packet presenter (or when packet presentation fails at runtime):
        /// heap-allocated lazily, sized to the surface in device pixels, and
        /// grown on resize. Platforms that present packets never allocate
        /// these.
        pixel_buffer: []u8 = &.{},
        pixel_scratch: []u8 = &.{},
        /// Worker threads, completion queue, and spawn slots for the
        /// effect system. Fixed-capacity; lives with the app struct
        /// (heap-allocated like the rest of it).
        effects: Effects,
        /// Applied webview-pane state (`Options.web_panes`), keyed by
        /// shell label.
        web_pane_states: [max_web_panes]WebPaneState = [_]WebPaneState{.{}} ** max_web_panes,
        web_pane_state_count: usize = 0,
        /// Exactly-once guard for `Options.status_item`/`status_item_fn`.
        status_item_installed: bool = false,
        /// True once `createTray` succeeded — the gate for model-driven
        /// tray updates (`status_item_fn`).
        tray_created: bool = false,
        /// The platform reported no tray-title seam; stop retrying (menu
        /// updates keep flowing).
        tray_title_unsupported: bool = false,
        /// Hashes of the last APPLIED model-derived tray state, so
        /// rebuilds only touch the platform when the output changed.
        tray_title_hash: u64 = 0,
        tray_menu_hash: u64 = 0,
        /// Scratch handed to `status_item_fn`; on the app struct so the
        /// returned slices outlive the apply.
        tray_scratch: StatusItemScratch = .{},
        /// Press-and-hold gesture state (`ElementOptions.on_hold`): the
        /// widget id whose press armed the hold timer, and whether the
        /// timer fired for the current gesture (a fired hold suppresses
        /// the release's ordinary press — one gesture, one Msg).
        hold_armed_id: canvas.ObjectId = 0,
        hold_fired: bool = false,
        /// Which canvas the armed hold belongs to (one pointer, one
        /// gesture — but it can be in any window): the view label and
        /// window id recorded at arm time so the fire resolves the right
        /// tree and dispatches with the right window identity.
        hold_view_label_storage: [app_manifest.max_view_label_bytes]u8 = undefined,
        hold_view_label_len: usize = 0,
        hold_window_id: platform.WindowId = 1,
        /// Context-menu presentation fallback state: the widget whose
        /// declared menu is mounted as an anchored canvas surface because
        /// the platform could not present it natively. Set by
        /// `canvas_widget_context_menu_request`, cleared by selection,
        /// dismissal, or the target vanishing from a rebuild. 0 = no
        /// fallback menu open. The synthesized surface itself comes from
        /// `Ui.finalize` (see `Ui.context_menu_fallback_target`).
        context_menu_fallback_target: canvas.ObjectId = 0,
        context_menu_fallback_window_id: platform.WindowId = 1,
        context_menu_fallback_label_storage: [app_manifest.max_view_label_bytes]u8 = undefined,
        context_menu_fallback_label_len: usize = 0,
        /// The windowed virtual lists the LAST build declared
        /// (`Ui.virtualList` records): scroll events on these regions
        /// re-derive the view even without an app `on_scroll` binding,
        /// and the coverage check re-runs a build whose fresh geometry
        /// proved a window too small.
        virtual_windows: [canvas.max_virtual_windows]canvas.VirtualWindowRecord = [_]canvas.VirtualWindowRecord{.{}} ** canvas.max_virtual_windows,
        virtual_window_count: usize = 0,
        /// Scroll regions whose `on_reach_end` fired and has not re-armed
        /// (the approach-end hysteresis state, keyed by widget id).
        reach_end_fired_ids: [canvas.max_virtual_windows]canvas.ObjectId = [_]canvas.ObjectId{0} ** canvas.max_virtual_windows,
        /// The approach-START mirror (`on_reach_start` hysteresis).
        reach_start_fired_ids: [canvas.max_virtual_windows]canvas.ObjectId = [_]canvas.ObjectId{0} ** canvas.max_virtual_windows,
        /// Retained offset tables for VARIABLE-extent virtual lists,
        /// claimed per list identity during builds (`Ui.virtualWindow`
        /// through the extent source) and patched by the post-layout
        /// measure step. Budgeted like the windows themselves — one per
        /// declarable window; a build declaring more variable lists than
        /// slots drops the excess to estimate-only math with a debug
        /// warning.
        virtual_extent_tables: [canvas.max_virtual_windows]canvas.VirtualExtentTable = [_]canvas.VirtualExtentTable{.{}} ** canvas.max_virtual_windows,
        /// Live model-declared secondary windows (`Options.windows_fn`),
        /// keyed by window label.
        window_slots: [max_ui_windows]WindowSlot,
        window_slot_count: usize = 0,
        /// Scratch handed to `windows_fn`; on the app struct so returned
        /// descriptor slices outlive the apply.
        windows_scratch: WindowsScratch = .{},

        /// By-value construction. The Model parameter and the returned
        /// app both ride the caller's stack unless result-location
        /// semantics happen to elide them — at multi-MB Model sizes that
        /// is a stack-overflow trap (the multi-MB-by-value family: fine in
        /// `main`, deadly in tests that keep any sizable local). Prefer
        /// `create`/`destroy`, which never materialize the Model or the
        /// app outside the heap allocation.
        pub fn init(backing: std.mem.Allocator, model: ModelT, options: Options) Self {
            assertOptions(options);
            return .{
                .model = model,
                .options = options,
                .backing = backing,
                .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
                .markup_arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
                .window_slots = windowSlotsInit(backing),
                .markup_fragment_slots = if (comptime fragment_watch_enabled) markupFragmentSlotsInit(backing) else {},
                .effects = Effects.init(backing),
            };
        }

        /// Heap-allocate the app and construct every field — the
        /// Model included — in place, so nothing app-sized ever rides
        /// the stack. The Model starts as its default value; set fields
        /// through the returned pointer before the app runs
        /// (`app.model.count = 1`, `app.model.addTask(...)`). Pair with
        /// `destroy`.
        pub fn create(backing: std.mem.Allocator, options: Options) error{OutOfMemory}!*Self {
            comptime {
                for (@typeInfo(ModelT).@"struct".fields) |field| {
                    if (field.default_value_ptr == null) @compileError(
                        "UiApp.create default-initializes the Model in place, but Model field '" ++ field.name ++
                            "' has no default value - give every Model field a default, or use initInPlace and assign app.model through the pointer yourself",
                    );
                }
            }
            const self = try backing.create(Self);
            initInPlace(self, backing, options);
            self.model = .{};
            return self;
        }

        /// Counterpart to `create`: deinit and free the heap allocation.
        /// Only for apps obtained from `create`.
        pub fn destroy(self: *Self) void {
            const backing = self.backing;
            self.deinit();
            backing.destroy(self);
        }

        /// In-place construction of everything BUT the Model, which is
        /// left undefined: the seam for callers that produce the model
        /// separately. Assign `self.model` immediately after — through
        /// the pointer (`app.model = loadModel()` writes straight into
        /// the app struct via result-location semantics, no stack copy
        /// of the framework's making). Prefer `create` when the Model is
        /// default-initializable.
        pub fn initInPlace(self: *Self, backing: std.mem.Allocator, options: Options) void {
            assertOptions(options);
            self.* = .{
                .model = undefined,
                .options = options,
                .backing = backing,
                .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
                .markup_arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
                .window_slots = windowSlotsInit(backing),
                .markup_fragment_slots = if (comptime fragment_watch_enabled) markupFragmentSlotsInit(backing) else {},
                .effects = Effects.init(backing),
            };
        }

        fn assertOptions(options: Options) void {
            std.debug.assert(options.view != null or options.markup != null);
            std.debug.assert((options.update != null) != (options.update_fx != null));
            // Declared windows need the per-window view to build them.
            std.debug.assert(options.windows_fn == null or options.window_view != null);
            if (comptime !features.runtime_markup) std.debug.assert(options.markup == null);
        }

        pub fn deinit(self: *Self) void {
            // In an app main this usually runs AFTER the runner has
            // already destroyed the platform and runtime (main's defer
            // was declared first, so it fires last). The platform-facing
            // half of this teardown therefore already happened in
            // `stopFn` — effects.deinit is idempotent and severed its
            // services binding there, so this second call frees app-side
            // memory only and never touches the dead platform.
            self.effects.deinit();
            self.arenas[0].deinit();
            self.arenas[1].deinit();
            self.markup_arenas[0].deinit();
            self.markup_arenas[1].deinit();
            if (comptime fragment_watch_enabled) {
                for (&self.markup_fragment_slots) |*slot| {
                    slot.arenas[0].deinit();
                    slot.arenas[1].deinit();
                }
            }
            for (&self.window_slots) |*slot| {
                slot.arenas[0].deinit();
                slot.arenas[1].deinit();
            }
            if (self.pixel_buffer.len > 0) self.backing.free(self.pixel_buffer);
            if (self.pixel_scratch.len > 0) self.backing.free(self.pixel_scratch);
            self.pixel_buffer = &.{};
            self.pixel_scratch = &.{};
        }

        pub fn app(self: *Self) App {
            return .{
                .context = self,
                .name = self.options.name,
                .scene_fn = sceneFn,
                .event_fn = eventFn,
                .stop_fn = stopFn,
                .replay_fn = replayFn,
            };
        }

        /// The app's stop hook (`App.stop`): the runtime guarantees it
        /// runs before its loop returns, i.e. while the platform's
        /// service table is still alive — and that is the LAST such
        /// moment this app gets. Tear the effects channel down here in
        /// full (silence a live audio player, disarm platform timers,
        /// join effect workers that post through the platform's wake
        /// service); the teardown also severs the channel's services
        /// binding, so the `deinit` that main defers — which runs only
        /// AFTER the runner has destroyed platform and runtime — repeats
        /// none of these calls and answers inert instead of reaching
        /// into freed memory.
        fn stopFn(context: *anyopaque, runtime: *Runtime) anyerror!void {
            _ = runtime;
            const self: *Self = @ptrCast(@alignCast(context));
            self.effects.deinit();
        }

        /// Bind the runtime-owned seams onto the effects channel (all
        /// first-bind-sticks): platform services, spawn environment,
        /// image registry, window verbs, and — while a session is being
        /// recorded — the recorder's result journal.
        fn bindEffectsChannel(self: *Self, runtime: *Runtime) void {
            self.effects.bindServices(&runtime.options.platform.services);
            self.effects.bindEnviron(runtime.options.environ);
            self.effects.bindImages(runtime.canvasImageRegistryBinding());
            self.effects.bindWindowActions(.{
                .context = runtime,
                .close_fn = effectsCloseWindowByLabel,
                .minimize_fn = effectsMinimizeWindowByLabel,
            });
            if (runtime.options.session_recorder) |recorder| {
                self.effects.bindJournal(recorder.effectJournal());
            }
        }

        /// Session-replay control (`App.replay_fn`): arm the effects
        /// channel into replay mode before the first replayed event, and
        /// feed journaled results into the stub executor. `.timer`
        /// records never feed — fx-timer fires replay through the
        /// journaled platform `.timer` events, and rejection notices
        /// regenerate from the same deterministic validation.
        fn replayFn(context: *anyopaque, control: core.ReplayControl) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            switch (control) {
                .arm => self.effects.armReplay(),
                .feed => |record| switch (record.kind) {
                    .line => try self.effects.feedLine(record.key, record.payload),
                    .exit => {
                        if (record.payload.len > 0) try self.effects.feedOutput(record.key, record.payload);
                        if (record.stderr_tail.len > 0) try self.effects.feedStderr(record.key, record.stderr_tail);
                        try self.effects.feedExitReason(record.key, record.code, record.exit_reason);
                    },
                    .response => try self.effects.feedResponseOutcome(record.key, record.fetch_outcome, record.status, record.payload),
                    .file => try self.effects.feedFileResult(record.key, record.file_outcome, record.payload),
                    .clipboard => try self.effects.feedClipboardResult(record.key, record.clipboard_outcome, record.payload),
                    // `.host` records ride the route in `code` (0 ok / 1
                    // err); rejections never reach here — they carry
                    // `.rejected` and regenerate from the same
                    // deterministic validation, like `.timer` records.
                    .host => try self.effects.feedHostResult(record.key, record.code == 0, record.payload),
                    .clock => try self.effects.pushReplayClock(record.clock_wall_ms),
                    // `.env` records carry the arm name in `stderr_tail`
                    // and the value in `payload`; the TS adapter's
                    // envMsgs dispatch consumes the queue on the
                    // replayed installing frame (zero env reads).
                    .env => try self.effects.pushReplayEnv(record.stderr_tail, record.payload),
                    // Spectrum records feed through the band-carrying
                    // helper so replay repaints identical bars; every
                    // other audio kind rides the plain shape.
                    .audio => if (record.audio_kind == .spectrum)
                        try self.effects.feedAudioSpectrum(record.audio_bands, record.audio_position_ms, record.audio_duration_ms)
                    else
                        try self.effects.feedAudioEventBuffering(record.audio_kind, record.audio_position_ms, record.audio_duration_ms, record.audio_playing, record.audio_buffering),
                    .timer => {},
                },
            }
        }

        /// Apply a message and rebuild the widget tree. Runtime-owned
        /// widget state is synced into the model first so `update` sees
        /// current slider values and scroll offsets.
        pub fn dispatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId, msg: MsgT) anyerror!void {
            self.bindEffectsChannel(runtime);
            self.syncModel(runtime, self.canvas_window_id);
            self.applyMsg(msg);
            self.publishAudioState(runtime);
            // Before the installing frame there is nothing to render
            // against: canvas size and scale arrive with the first frame
            // event, and the installing rebuild renders whatever model
            // state accumulated here. A pre-install rebuild is discarded
            // work at a default surface size — and appearance/chrome
            // events land before the first frame on every launch, so it
            // used to cost a full view build on the launch path.
            if (!self.installed) return;
            try self.rebuild(runtime, self.canvas_window_id);
            try self.rebuildWindowSlots(runtime);
            // A Msg dispatched FROM a secondary window still rebuilt the
            // main canvas above (one model, every window's view derives
            // from it); `window_id` names the dispatch origin for apps
            // that inspect it, not the rebuild target.
            _ = window_id;
        }

        /// Run `update` through whichever form the app declared; the
        /// effects channel rides along for the `update_fx` form.
        fn applyMsg(self: *Self, msg: MsgT) void {
            if (self.options.update_fx) |update_fx| {
                update_fx(&self.model, msg, &self.effects);
            } else {
                self.options.update.?(&self.model, msg);
            }
        }

        /// Drain the effect completion queue on the loop thread: every
        /// queued line/exit becomes a Msg through its stored constructor
        /// and runs through `update`; one rebuild follows. Called on
        /// `.effects_wake` (the platform marshalled a worker's `wake_fn`
        /// nudge) and each presented frame (host-pumped embeds have no
        /// wake delivery; their frame pump drains naturally).
        pub fn drainEffects(self: *Self, runtime: *Runtime) anyerror!void {
            if (!self.installed) return;
            if (!self.effects.hasPending()) return;
            self.bindEffectsChannel(runtime);
            self.syncModel(runtime, self.canvas_window_id);
            var dispatched = false;
            while (self.effects.takeMsg()) |msg| {
                self.applyMsg(msg);
                dispatched = true;
            }
            self.publishAudioState(runtime);
            if (dispatched) {
                try self.rebuild(runtime, self.canvas_window_id);
                try self.rebuildWindowSlots(runtime);
            }
        }

        /// Mirror the effects channel's audio playback state into the
        /// runtime so the automation snapshot reports it honestly (the
        /// runtime is Msg-type-erased and cannot read the channel
        /// itself). Called wherever a dispatch or drain may have moved
        /// playback.
        fn publishAudioState(self: *Self, runtime: *Runtime) void {
            const audio = self.effects.audioSnapshot();
            runtime.audio_active = audio.active;
            runtime.audio_key = audio.key;
            runtime.audio_playing = audio.playing;
            runtime.audio_buffering = audio.buffering;
            runtime.audio_source = audio.source;
            runtime.audio_position_ms = audio.position_ms;
            runtime.audio_duration_ms = audio.duration_ms;
            runtime.audio_spectrum_bands = audio.spectrum_bands;
            runtime.audio_spectrum_events = audio.spectrum_events;
        }

        /// The design tokens for the next rebuild: the model-derived
        /// `tokens_fn`, explicit static `tokens`, or — the default — the
        /// stock theme derived from the SYSTEM appearance the runtime
        /// tracks (scheme, contrast, reduced motion), so an unthemed app
        /// honors the OS light/dark setting live. Every path carries the
        /// surface scale in `pixel_snap.scale` — the app owns the
        /// appearance, the runtime owns the device scale — so static
        /// tokens snap hairlines against the real surface density too.
        pub fn effectiveTokens(self: *const Self) canvas.DesignTokens {
            if (self.options.tokens_fn) |tokens_fn| {
                var tokens = tokens_fn(&self.model);
                tokens.pixel_snap.scale = self.pixel_snap_scale;
                return tokens;
            }
            if (self.options.tokens) |static_tokens| {
                var tokens = static_tokens;
                tokens.pixel_snap.scale = self.pixel_snap_scale;
                return tokens;
            }
            var tokens = canvas.DesignTokens.theme(.{
                .color_scheme = switch (self.system_appearance.color_scheme) {
                    .light => .light,
                    .dark => .dark,
                },
                .contrast = if (self.system_appearance.high_contrast) .high else .standard,
                .reduce_motion = self.system_appearance.reduce_motion,
                .pack = self.options.theme,
            });
            if (self.options.theme_accent) |accent| {
                // The manifest accent layers over the resolved pack —
                // except under high contrast, where the pack's own loud
                // register wins untouched (accessibility beats brand).
                // The bundle takes the resolved scheme: the dark ring
                // derives desaturated (canvas.accentFocusRing).
                if (!self.system_appearance.high_contrast) {
                    tokens = tokens.withOverrides(canvas.accentOverrides(accent, switch (self.system_appearance.color_scheme) {
                        .light => .light,
                        .dark => .dark,
                    }));
                }
            }
            tokens.pixel_snap.scale = self.pixel_snap_scale;
            return tokens;
        }

        /// The design tokens for a secondary window's rebuild: the same
        /// app-owned appearance as `effectiveTokens`, restamped with the
        /// SLOT's device scale. Each window snaps hairlines against its
        /// own monitor's grid — only the scale differs per window, never
        /// the appearance.
        fn slotEffectiveTokens(self: *const Self, slot: *const WindowSlot) canvas.DesignTokens {
            var tokens = self.effectiveTokens();
            tokens.pixel_snap.scale = slot.pixel_snap_scale;
            return tokens;
        }

        /// Whether the stock tokens derive from the system appearance:
        /// true only when the app claims neither token override, so an
        /// appearance flip must re-derive and re-render.
        fn followsSystemAppearance(self: *const Self) bool {
            return self.options.tokens_fn == null and self.options.tokens == null;
        }

        /// Whether tokens are derived per rebuild (model-owned or
        /// system-followed) rather than a fixed set.
        fn derivesTokens(self: *const Self) bool {
            return self.options.tokens_fn != null or self.followsSystemAppearance();
        }

        /// Whether a rebuild must push its tokens into the runtime's
        /// stored copy. Derived tokens can change with any model or
        /// appearance input, so they always re-emit. Static tokens are
        /// fixed by the app, but the runtime stamps two live values onto
        /// them: the surface scale (`effectiveTokens` — a stored copy
        /// holding a stale scale re-emits so hairlines re-snap after a
        /// move between monitors) and the text-measure provider
        /// (`tokensWithTextMeasure` — the FIRST font registration binds
        /// the runtime's font-aware provider on platforms without host
        /// measurement, and a stored copy still measuring with the
        /// estimator would keep display-list text layout on
        /// pre-registration metrics). Ordinary rebuilds keep skipping
        /// the redundant emission.
        fn rebuildEmitsTokens(self: *const Self, runtime: *Runtime, window_id: platform.WindowId, canvas_label: []const u8, tokens: canvas.DesignTokens) bool {
            if (self.derivesTokens()) return true;
            const stored = runtime.canvasWidgetDesignTokens(window_id, canvas_label) catch return true;
            if (!std.meta.eql(stored.text_measure, tokens.text_measure)) return true;
            return stored.pixel_snap.scale != tokens.pixel_snap.scale;
        }

        /// Read runtime-owned widget state back into the model through the
        /// optional `sync` hook.
        fn syncModel(self: *Self, runtime: *Runtime, window_id: platform.WindowId) void {
            const sync = self.options.sync orelse return;
            if (self.tree == null) return;
            const layout = runtime.canvasWidgetLayout(window_id, self.options.canvas_label) catch return;
            sync(&self.model, layout);
        }

        /// Rebuild the widget tree from the model and hand it to the
        /// runtime, which copies and reconciles it. The previous tree's
        /// arena stays alive until the following rebuild so the handler
        /// table remains valid between events. Apps with a `chrome` hook
        /// also rebuild the retained display list (chrome prefix + widget
        /// commands + chrome suffix) here.
        ///
        /// Windowed virtual lists (`Ui.virtualList`) get their window
        /// source installed here: each `ui.virtualWindow` request
        /// resolves against the RETAINED layout's scroll offset and
        /// viewport for the list's global identity (canvas height at
        /// offset 0 before the list first mounts). When the fresh
        /// layout's geometry proves a window under-covered — the first
        /// build guessed the viewport, or a resize widened it — the view
        /// is derived once more against the fresh geometry, so the
        /// window converges within the same rebuild instead of waiting
        /// for the next Msg.
        pub fn rebuild(self: *Self, runtime: *Runtime, window_id: platform.WindowId) anyerror!void {
            self.syncModel(runtime, window_id);
            if (comptime features.runtime_markup) {
                // Under automation, drive the interpreter from the first
                // frame even when a compiled view is present: provenance
                // (write-back's read half) is stamped by the interpreter,
                // and the engines are parity-proven, so the pixels and
                // structural ids do not change.
                if (runtime.options.automation != null and self.markup_view == null and self.options.markup != null) {
                    self.reloadMarkup(self.options.markup.?.source) catch {};
                }
            }
            var tokens = runtime.tokensWithTextMeasure(self.effectiveTokens());
            const next_index = self.arena_index ^ 1;
            // Widget layout is inset by the runtime's viewport chrome
            // (safe areas + keyboard on mobile, zero on desktop); the
            // canvas itself stays surface-sized so chrome and the clear
            // color still paint edge to edge under notches and bars.
            const bounds = geometry.RectF.fromSize(self.canvas_size).deflate(self.layoutViewportInsets(runtime, window_id));
            var built = try self.buildLayoutPass(runtime, window_id, bounds, tokens, next_index);
            // Window-control clearance is a one-retry pass like the
            // virtual-window coverage retry inside the build: only when
            // the finished layout left a drag header's CONTENT under the
            // OS window-control cluster (Windows caption buttons
            // trailing, macOS traffic lights leading) is the cluster
            // stamped into the tokens for one more build — drag rows
            // then lay their content out clear of it
            // (`canvas.windowControlsClearedContent` inside layout).
            // Apps whose headers already pad through the chrome
            // channel's insets never collide, never retry, and keep a
            // byte-identical layout.
            if (windowControlsReservation(runtime, window_id, self.options.canvas_label, built.layout, tokens)) |controls| {
                tokens.window_controls = controls;
                built = try self.buildLayoutPass(runtime, window_id, bounds, tokens, next_index);
            }
            const tree = built.tree;
            const layout = built.layout;
            launch_timing.lapOnce("first_view_built");

            if (self.options.chrome) |chrome| {
                try self.installChromeDisplayList(runtime, window_id, chrome, layout, tokens);
            } else {
                _ = try runtime.setCanvasWidgetLayout(window_id, self.options.canvas_label, layout);
                if (self.installed and self.rebuildEmitsTokens(runtime, window_id, self.options.canvas_label, tokens)) {
                    _ = try runtime.emitCanvasWidgetDisplayList(window_id, self.options.canvas_label, tokens);
                }
            }

            self.tree = tree;
            self.arena_index = next_index;
            // The fallback menu's target vanished from this build (the
            // model dropped the row, or its menu emptied): the open state
            // has nothing to present, so it closes.
            if (self.contextMenuFallbackTargetForLabel(self.options.canvas_label) != 0 and tree.context_menu_fallback == null) {
                self.clearContextMenuFallback();
            }
            try self.scheduleAnimations(runtime, window_id);
            try self.scheduleLayoutTweens(runtime, window_id);
            self.applyWebPanes(runtime, window_id, layout);
            self.applyStatusItem(runtime);
            self.applyWindows(runtime);
            self.applyChromeSelection();
            self.applyChromeNavigation();
        }

        const BuiltLayout = struct {
            tree: Ui.Tree,
            layout: canvas.WidgetLayoutTree,
        };

        /// One view-build + flex-layout pass of `rebuild`, including the
        /// windowed-virtual-list coverage retry: builds the tree into the
        /// next arena and lays it out against `bounds` with `tokens`.
        /// Extracted so rebuild can run it again with the window-control
        /// reservation stamped when the first pass proved a collision.
        fn buildLayoutPass(
            self: *Self,
            runtime: *Runtime,
            window_id: platform.WindowId,
            bounds: geometry.RectF,
            tokens: canvas.DesignTokens,
            next_index: usize,
        ) anyerror!BuiltLayout {
            var window_source = VirtualWindowResolver{
                .runtime = runtime,
                .window_id = window_id,
                .canvas_label = self.options.canvas_label,
                .fallback_viewport = bounds.height,
            };
            var tree: Ui.Tree = undefined;
            var layout: canvas.WidgetLayoutTree = undefined;
            var pass: usize = 0;
            while (true) {
                _ = self.arenas[next_index].reset(.retain_capacity);
                var ui = Ui.init(self.arenas[next_index].allocator());
                ui.virtual_window_context = @ptrCast(&window_source);
                ui.virtual_window_source = VirtualWindowResolver.resolve;
                ui.virtual_extent_context = @ptrCast(self);
                ui.virtual_extent_source = virtualExtentResolve;
                ui.context_menu_fallback_target = self.contextMenuFallbackTargetForLabel(self.options.canvas_label);
                self.armUiFragmentHost(&ui);
                if (comptime features.runtime_markup) {
                    if (self.markup_view != null and runtime.options.automation != null) {
                        self.provenance.resetRecords();
                        ui.provenance_sink = self.provenance.sink();
                    }
                }
                // Frame-profile stamps (no-ops unless profiling is on): the
                // view build fn + tree finalize is the `rebuild` stage, the
                // flex pass below is `layout`; reconcile/emit are stamped at
                // their runtime-side choke points so input-driven refreshes
                // are attributed too.
                const rebuild_begin = runtime.frame_profile.begin();
                const node = try self.buildViewNode(&ui);
                tree = try ui.finalizeWithTokens(node, tokens);
                runtime.frame_profile.end(.rebuild, rebuild_begin);

                const layout_begin = runtime.frame_profile.begin();
                layout = canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, &self.layout_nodes) catch |err| {
                    // Teach the fix at the failure site: the error name
                    // alone never says which budget or where to trim.
                    if (err == error.WidgetLayoutListFull) {
                        ui_app_log.warn(
                            "widget layout capacity exceeded for view '{s}': the per-view budget is {d} nodes (canvas_limits.max_canvas_widget_nodes_per_view) - reduce always-mounted widgets or virtualize lists",
                            .{ self.options.canvas_label, canvas_limits.max_canvas_widget_nodes_per_view },
                        );
                    }
                    return err;
                };
                runtime.frame_profile.end(.layout, layout_begin);

                self.rememberVirtualWindows(&ui);
                // Measure the mounted rows of every variable-extent
                // list against the fresh layout and patch the retained
                // offset tables (anchored — see the table's contract).
                // A material correction earns the same one-retry pass a
                // coverage miss does, so the installed frame already
                // consumed it; a residual delta rides to the next
                // rebuild, atomically with the geometry either way.
                const corrected = self.measureVirtualWindows(layout);
                pass += 1;
                if (pass >= 2 or (!corrected and !self.virtualWindowsUndercovered(layout))) break;
                window_source.fresh = layout;
            }
            return .{ .tree = tree, .layout = layout };
        }

        /// The window-control cluster's canvas-local frame — but only
        /// when the just-built layout actually left drag-header content
        /// under it, so a rebuild (the main canvas's `rebuild` or a
        /// secondary window's `rebuildWindowSlot`) knows a clearance
        /// retry will change something. Cheap in the common case: a tree
        /// with no visible drag region never even polls the platform's
        /// chrome report, and standard-chrome windows report a zero
        /// cluster. `tokens` must be the tokens the layout was built
        /// with: the scan re-measures text through the same seam to
        /// judge painted bounds, not frames.
        fn windowControlsReservation(runtime: *Runtime, window_id: platform.WindowId, canvas_label: []const u8, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) ?geometry.RectF {
            var has_drag_region = false;
            for (layout.nodes) |node| {
                if (canvas.widgetIsWindowDragRegion(node.widget)) {
                    has_drag_region = true;
                    break;
                }
            }
            if (!has_drag_region) return null;
            const controls = runtime.windowControlsForView(window_id, canvas_label);
            if (controls.width <= 0 or controls.height <= 0) return null;
            if (!canvas.windowDragContentUnderWindowControls(layout.nodes, controls, tokens)) return null;
            return controls;
        }

        /// Re-derive the model's selected chrome tab after a rebuild
        /// (`selected_tab_fn`, the `status_item_fn` cadence): the stored
        /// id is what a projecting host reads through
        /// `chromeSelectedTab()` to keep the native bar mirroring the
        /// model. Without the hook the stored id stays empty and hosts
        /// project no selection.
        fn applyChromeSelection(self: *Self) void {
            const derive = self.options.selected_tab_fn orelse return;
            const id = derive(&self.model);
            const len = @min(id.len, self.chrome_selected_tab_storage.len);
            @memcpy(self.chrome_selected_tab_storage[0..len], id[0..len]);
            self.chrome_selected_tab_len = len;
        }

        /// The model's current selected chrome tab id ("" when the app
        /// declares no `selected_tab_fn`, or before the first rebuild).
        /// Read by embed hosts to project the declared tab set's
        /// selection onto the REAL native control.
        pub fn chromeSelectedTab(self: *const Self) []const u8 {
            return self.chrome_selected_tab_storage[0..self.chrome_selected_tab_len];
        }

        /// Re-derive the model's navigation depth after a rebuild
        /// (`navigation_depth_fn`, the `applyChromeSelection` cadence):
        /// the stored depth is what a projecting host polls through
        /// `chromeNavigationDepth()` to decide push/pop transitions.
        /// Without the hook nothing is stored and hosts read -1.
        fn applyChromeNavigation(self: *Self) void {
            const derive = self.options.navigation_depth_fn orelse return;
            self.chrome_navigation_depth = derive(&self.model);
            self.chrome_navigation_depth_known = true;
        }

        /// The model's current navigation depth, or -1 when the app
        /// declares no `navigation_depth_fn` (or before the first
        /// rebuild) — hosts treat -1 as "no navigation projection" and
        /// present no transitions. Read by embed hosts each tick; one
        /// integer, never a model touch.
        pub fn chromeNavigationDepth(self: *const Self) isize {
            if (!self.chrome_navigation_depth_known) return -1;
            return std.math.lossyCast(isize, self.chrome_navigation_depth);
        }

        /// The declared back command a projecting host dispatches when
        /// the platform back gesture completes ("" when the app declares
        /// no navigation projection — hosts must not arm the gesture).
        /// Static app data, valid for the app's lifetime.
        pub fn chromeNavigationBackCommand(self: *const Self) []const u8 {
            if (self.options.navigation_depth_fn == null) return "";
            return self.options.navigation_back_command;
        }

        /// The window source backing `Ui.virtualWindow` during a rebuild:
        /// resolves a virtual list's retained scroll state (offset of
        /// record + content viewport) by its global identity, preferring
        /// the freshly laid-out geometry on the coverage-retry pass. The
        /// fallback (offset 0 at the canvas height) makes the first
        /// build materialize enough rows to fill the window. Main canvas
        /// only — declared secondary windows have no window source yet
        /// (the `sync` scope note); their builds use each request's
        /// `viewport_fallback`.
        const VirtualWindowResolver = struct {
            runtime: *Runtime,
            window_id: platform.WindowId,
            canvas_label: []const u8,
            fallback_viewport: f32,
            fresh: ?canvas.WidgetLayoutTree = null,

            fn resolve(context: ?*anyopaque, id: canvas.ObjectId) ?canvas.VirtualWindowState {
                const self: *VirtualWindowResolver = @ptrCast(@alignCast(context orelse return null));
                if (self.fresh) |fresh| {
                    if (fresh.findById(id)) |node| return stateForNode(node);
                }
                const layout = self.runtime.canvasWidgetLayout(self.window_id, self.canvas_label) catch
                    return .{ .offset = 0, .viewport_extent = self.fallback_viewport };
                if (layout.findById(id)) |node| return stateForNode(node);
                return .{ .offset = 0, .viewport_extent = self.fallback_viewport };
            }

            fn stateForNode(node: canvas.WidgetLayoutNode) canvas.VirtualWindowState {
                const viewport = node.frame.inset(node.widget.layout.padding).normalized();
                return .{ .offset = node.widget.value, .viewport_extent = viewport.height, .mounted = true };
            }
        };

        /// Keep this build's virtual-window records: the scroll handler
        /// re-derives the view for these regions even without an app
        /// `on_scroll` binding (the window follows the runtime offset).
        fn rememberVirtualWindows(self: *Self, ui: *const Ui) void {
            const records = ui.virtualWindows();
            self.virtual_window_count = records.len;
            @memcpy(self.virtual_windows[0..records.len], records);
        }

        /// Whether any declared virtual window fails to cover the visible
        /// range its FRESH geometry implies (first-build viewport guess,
        /// resize growth): the trigger for the one coverage-retry build.
        fn virtualWindowsUndercovered(self: *const Self, layout: canvas.WidgetLayoutTree) bool {
            for (self.virtual_windows[0..self.virtual_window_count]) |record| {
                const node = layout.findById(record.id) orelse continue;
                const viewport = node.frame.inset(node.widget.layout.padding).normalized();
                if (viewport.isEmpty()) continue;
                if (record.variable) {
                    const table = self.virtualExtentTableForId(record.id) orelse continue;
                    if (record.item_count == 0) continue;
                    const offset = @max(0, node.widget.value);
                    const first_visible = table.indexAtOffset(offset);
                    const visible_end = @min(record.item_count, table.indexAtOffset(offset + viewport.height) + 1);
                    const start = if (first_visible > record.overscan) first_visible - record.overscan else 0;
                    const end = @min(record.item_count, visible_end + record.overscan);
                    if (start < record.start_index or end > record.end_index) return true;
                    continue;
                }
                const item_extent = if (node.widget.layout.virtual_item_extent > 0)
                    node.widget.layout.virtual_item_extent
                else
                    record.item_extent;
                const range = canvas.virtualListRange(.{
                    .item_count = record.item_count,
                    .item_extent = item_extent,
                    .item_gap = record.gap,
                    .viewport_extent = viewport.height,
                    .scroll_offset = node.widget.value,
                    .overscan = record.overscan,
                });
                if (range.start_index < record.start_index or range.end_index > record.end_index) return true;
            }
            return false;
        }

        /// The extent source backing `Ui.virtualWindow` for
        /// variable-extent lists: resolve (or claim) the retained offset
        /// table for a list identity. Slots follow the window budget;
        /// a stale table (its list no longer declared) is recycled
        /// before giving up.
        fn virtualExtentResolve(context: ?*anyopaque, id: canvas.ObjectId) ?*canvas.VirtualExtentTable {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            return self.claimVirtualExtentTable(id);
        }

        fn virtualExtentTableForId(self: *const Self, id: canvas.ObjectId) ?*canvas.VirtualExtentTable {
            if (id == 0) return null;
            for (&self.virtual_extent_tables) |*table| {
                if (table.id == id) return @constCast(table);
            }
            return null;
        }

        fn claimVirtualExtentTable(self: *Self, id: canvas.ObjectId) ?*canvas.VirtualExtentTable {
            if (id == 0) return null;
            for (&self.virtual_extent_tables) |*table| {
                if (table.id == id) return table;
            }
            for (&self.virtual_extent_tables) |*table| {
                if (table.id == 0) return table;
            }
            // All slots busy: recycle one whose list the LAST build no
            // longer declared (per-document lists come and go; their
            // measured state is rebuildable by scrolling).
            recycle: for (&self.virtual_extent_tables) |*table| {
                for (self.virtual_windows[0..self.virtual_window_count]) |record| {
                    if (record.id == table.id) continue :recycle;
                }
                table.reset();
                return table;
            }
            ui_app_log.warn(
                "more than {d} variable-extent virtual lists alive at once (canvas.ui_builder.max_virtual_windows) - the excess builds from estimates alone, without measured corrections",
                .{canvas.max_virtual_windows},
            );
            return null;
        }

        /// Post-layout measure step for variable-extent virtual lists:
        /// read the freshly laid-out extent of every mounted row (the
        /// intrinsic heights the flex pass just computed) into the
        /// retained offset table, anchored on the first visible row so
        /// the pending offset delta keeps it visually fixed. Returns
        /// whether any table accumulated a correction worth the retry
        /// pass.
        fn measureVirtualWindows(self: *Self, layout: canvas.WidgetLayoutTree) bool {
            var corrected = false;
            for (self.virtual_windows[0..self.virtual_window_count]) |record| {
                if (!record.variable or record.item_count == 0) continue;
                const table = self.virtualExtentTableForId(record.id) orelse continue;
                var list_index: usize = 0;
                var found = false;
                for (layout.nodes, 0..) |node, index| {
                    if (node.widget.id == record.id) {
                        list_index = index;
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
                const list_node = layout.nodes[list_index];
                const content = list_node.frame.inset(list_node.widget.layout.padding).normalized();
                if (content.isEmpty()) continue;
                // The correction anchor is the row the layout pass
                // anchored the window on: it was PLACED at the table's
                // leading edge for it, so the table-belief baseline is
                // exactly its rendered position — corrections shift
                // the pending offset by however much the batch moves
                // that edge, and the anchored row stays under the
                // user's eyes.
                table.beginCorrections(list_node.widget.layout.virtual_anchor_index, null);
                for (layout.nodes) |node| {
                    const parent = node.parent_index orelse continue;
                    if (parent != list_index) continue;
                    if (node.widget.layout.anchor != null) continue;
                    const physical = node.widget.semantics.list_item_index orelse continue;
                    table.recordMeasured(@intCast(physical), node.frame.normalized().height);
                }
                table.endCorrections();
                if (@abs(table.pending_offset_delta) > virtual_correction_retry_threshold) corrected = true;
            }
            return corrected;
        }

        fn isVirtualWindowId(self: *const Self, id: canvas.ObjectId) bool {
            if (id == 0) return false;
            for (self.virtual_windows[0..self.virtual_window_count]) |record| {
                if (record.id == id) return true;
            }
            return false;
        }

        /// Approach-end hysteresis (`on_reach_end`): fire when a scroll
        /// lands within `reach_end_fire_ratio` viewports of the content
        /// end and the region is armed; re-arm once the offset sits more
        /// than `reach_end_rearm_ratio` viewports from the end — which
        /// appending a batch causes on its own, since the extent grows
        /// under the unchanged offset. One Msg per approach, never a
        /// fetch storm from a user riding the end of the list.
        fn reachEndShouldFire(self: *Self, id: canvas.ObjectId, scroll_state: canvas.ScrollState) bool {
            if (id == 0 or scroll_state.viewport_extent <= 0) return false;
            const remaining = scroll_state.content_extent - scroll_state.viewport_extent - scroll_state.offset;
            if (remaining > scroll_state.viewport_extent * reach_end_rearm_ratio) {
                self.clearReachEndFired(id);
                return false;
            }
            if (remaining > scroll_state.viewport_extent * reach_end_fire_ratio) return false;
            if (self.reachEndFired(id)) return false;
            self.markReachEndFired(id);
            return true;
        }

        fn reachEndFired(self: *const Self, id: canvas.ObjectId) bool {
            for (self.reach_end_fired_ids) |fired| {
                if (fired == id) return true;
            }
            return false;
        }

        fn markReachEndFired(self: *Self, id: canvas.ObjectId) void {
            for (&self.reach_end_fired_ids) |*slot| {
                if (slot.* == 0 or slot.* == id) {
                    slot.* = id;
                    return;
                }
            }
        }

        fn clearReachEndFired(self: *Self, id: canvas.ObjectId) void {
            for (&self.reach_end_fired_ids) |*slot| {
                if (slot.* == id) slot.* = 0;
            }
        }

        /// Approach-START hysteresis (`on_reach_start`): the mirror of
        /// `reachEndShouldFire` measured from the content start — fire
        /// when a scroll lands within `reach_start_fire_ratio` viewports
        /// of offset 0 and the region is armed; re-arm once the offset
        /// sits more than `reach_start_rearm_ratio` viewports from the
        /// start, which prepending a batch causes on its own (the
        /// viewport anchor grows the offset by the prepended extent).
        /// Same programmatic-jump nuance as reach-end: hysteresis state
        /// only moves on scroll OBSERVATIONS, so a programmatic jump out
        /// of the band re-arms on the next user scroll, not instantly.
        fn reachStartShouldFire(self: *Self, id: canvas.ObjectId, scroll_state: canvas.ScrollState) bool {
            if (id == 0 or scroll_state.viewport_extent <= 0) return false;
            const remaining = scroll_state.offset;
            if (remaining > scroll_state.viewport_extent * reach_start_rearm_ratio) {
                self.clearReachStartFired(id);
                return false;
            }
            if (remaining > scroll_state.viewport_extent * reach_start_fire_ratio) return false;
            if (self.reachStartFired(id)) return false;
            self.markReachStartFired(id);
            return true;
        }

        fn reachStartFired(self: *const Self, id: canvas.ObjectId) bool {
            for (self.reach_start_fired_ids) |fired| {
                if (fired == id) return true;
            }
            return false;
        }

        fn markReachStartFired(self: *Self, id: canvas.ObjectId) void {
            for (&self.reach_start_fired_ids) |*slot| {
                if (slot.* == 0 or slot.* == id) {
                    slot.* = id;
                    return;
                }
            }
        }

        fn clearReachStartFired(self: *Self, id: canvas.ObjectId) void {
            for (&self.reach_start_fired_ids) |*slot| {
                if (slot.* == id) slot.* = 0;
            }
        }

        /// Reconcile the model-declared secondary windows against the
        /// live ones (the `status_item_fn` shape applied to the window
        /// set): close what the model stopped declaring, create what it
        /// started declaring. Failures degrade to logged warnings — a
        /// failed window create never takes the render loop down.
        fn applyWindows(self: *Self, runtime: *Runtime) void {
            const windows_fn = self.options.windows_fn orelse return;
            var declared = windows_fn(&self.model, &self.windows_scratch);
            if (declared.len > max_ui_windows) {
                ui_app_log.warn(
                    "windows_fn declared {d} windows; the budget is {d} (canvas_limits.max_ui_app_windows) - the excess is ignored",
                    .{ declared.len, max_ui_windows },
                );
                declared = declared[0..max_ui_windows];
            }

            // Close first: a label leaving the declared set frees its
            // slot (and its runtime window label) before creations run.
            var index: usize = 0;
            while (index < self.window_slot_count) {
                if (declaredWindowIndex(declared, self.window_slots[index].label()) == null) {
                    self.closeWindowSlot(runtime, index);
                    continue;
                }
                index += 1;
            }

            for (declared) |descriptor| {
                if (self.windowSlotIndexByLabel(descriptor.label)) |slot_index| {
                    // Already live: the close Msg follows the model.
                    self.window_slots[slot_index].on_close = descriptor.on_close;
                    continue;
                }
                self.createWindowSlot(runtime, descriptor);
            }
        }

        fn declaredWindowIndex(declared: []const WindowDescriptor, label: []const u8) ?usize {
            for (declared, 0..) |descriptor, index| {
                if (std.mem.eql(u8, descriptor.label, label)) return index;
            }
            return null;
        }

        fn windowSlotIndexByLabel(self: *Self, label: []const u8) ?usize {
            for (self.window_slots[0..self.window_slot_count], 0..) |*slot, index| {
                if (std.mem.eql(u8, slot.label(), label)) return index;
            }
            return null;
        }

        fn windowSlotByCanvasLabel(self: *Self, canvas_label: []const u8) ?*WindowSlot {
            for (self.window_slots[0..self.window_slot_count]) |*slot| {
                if (std.mem.eql(u8, slot.canvasLabel(), canvas_label)) return slot;
            }
            return null;
        }

        fn windowSlotIndexByWindowId(self: *Self, window_id: platform.WindowId) ?usize {
            for (self.window_slots[0..self.window_slot_count], 0..) |*slot, index| {
                if (slot.window_id == window_id) return index;
            }
            return null;
        }

        fn createWindowSlot(self: *Self, runtime: *Runtime, descriptor: WindowDescriptor) void {
            if (self.window_slot_count >= max_ui_windows) {
                ui_app_log.warn(
                    "declared window '{s}' ignored: more than {d} secondary windows (canvas_limits.max_ui_app_windows)",
                    .{ descriptor.label, max_ui_windows },
                );
                return;
            }
            if (descriptor.label.len == 0 or descriptor.label.len > platform.max_window_label_bytes or
                descriptor.canvas_label.len == 0 or descriptor.canvas_label.len > app_manifest.max_view_label_bytes)
            {
                ui_app_log.warn("declared window '{s}' ignored: window and canvas labels must be non-empty and fit the platform label budgets", .{descriptor.label});
                return;
            }
            if (std.mem.eql(u8, descriptor.canvas_label, self.options.canvas_label) or self.windowSlotByCanvasLabel(descriptor.canvas_label) != null) {
                ui_app_log.warn(
                    "declared window '{s}' ignored: canvas label '{s}' is already bound - every window's canvas label must be unique",
                    .{ descriptor.label, descriptor.canvas_label },
                );
                return;
            }

            const shell_views = [_]app_manifest.ShellView{self.secondaryShellView(descriptor)};
            const info = runtime.createSourcelessShellWindow(.{
                .label = descriptor.label,
                .title = if (descriptor.title.len > 0) descriptor.title else null,
                .width = descriptor.width,
                .height = descriptor.height,
                .x = descriptor.x,
                .y = descriptor.y,
                .resizable = descriptor.resizable,
                .titlebar = descriptor.titlebar,
                .min_width = descriptor.min_width,
                .min_height = descriptor.min_height,
                // Deterministic reopen: the descriptor is the geometry
                // channel, not a persisted frame store.
                .restore_state = false,
                .views = &shell_views,
            }) catch |err| {
                ui_app_log.warn("declared window '{s}' create failed: {s}", .{ descriptor.label, @errorName(err) });
                return;
            };

            const slot = &self.window_slots[self.window_slot_count];
            slot.label_len = descriptor.label.len;
            @memcpy(slot.label_storage[0..descriptor.label.len], descriptor.label);
            slot.canvas_label_len = descriptor.canvas_label.len;
            @memcpy(slot.canvas_label_storage[0..descriptor.canvas_label.len], descriptor.canvas_label);
            slot.window_id = info.id;
            slot.on_close = descriptor.on_close;
            slot.installed = false;
            slot.canvas_size = .{ .width = descriptor.width, .height = descriptor.height };
            // Until this window's first frame reports its real density,
            // assume the main canvas's — new windows usually open on the
            // same monitor, and the installing frame corrects the guess.
            slot.pixel_snap_scale = self.pixel_snap_scale;
            slot.tree = null;
            slot.arena_index = 0;
            self.window_slot_count += 1;
        }

        /// The gpu_surface shell view for a declared window: the
        /// descriptor's canvas label wearing the MAIN canvas's declared
        /// gpu options (backend, pixel format, present mode...), so a
        /// secondary window renders through whatever pipeline the app
        /// already chose for its platform.
        fn secondaryShellView(self: *const Self, descriptor: WindowDescriptor) app_manifest.ShellView {
            var view = app_manifest.ShellView{
                .label = descriptor.canvas_label,
                .kind = .gpu_surface,
                .fill = true,
            };
            for (self.options.scene.windows) |window| {
                for (window.views) |scene_view| {
                    if (scene_view.kind != .gpu_surface) continue;
                    if (!std.mem.eql(u8, scene_view.label, self.options.canvas_label)) continue;
                    view.gpu_backend = scene_view.gpu_backend;
                    view.gpu_pixel_format = scene_view.gpu_pixel_format;
                    view.gpu_present_mode = scene_view.gpu_present_mode;
                    view.gpu_alpha_mode = scene_view.gpu_alpha_mode;
                    view.gpu_color_space = scene_view.gpu_color_space;
                    view.gpu_vsync = scene_view.gpu_vsync;
                    return view;
                }
            }
            return view;
        }

        /// Remove the slot and close its runtime window (the reconcile
        /// close: the model stopped declaring it, so no `on_close` Msg —
        /// the model already knows).
        fn closeWindowSlot(self: *Self, runtime: *Runtime, index: usize) void {
            const window_id = self.window_slots[index].window_id;
            const last = self.window_slot_count - 1;
            var removed = self.window_slots[index];
            self.window_slots[index] = self.window_slots[last];
            self.window_slots[last] = WindowSlot.init(self.backing);
            self.window_slot_count = last;
            removed.arenas[0].deinit();
            removed.arenas[1].deinit();
            runtime.closeWindow(window_id) catch |err| {
                ui_app_log.warn("declared window close failed: {s}", .{@errorName(err)});
            };
        }

        /// Drop a slot whose runtime window is ALREADY gone (the user
        /// closed it): bookkeeping only, no platform call.
        fn forgetWindowSlot(self: *Self, index: usize) ?MsgT {
            const on_close = self.window_slots[index].on_close;
            const last = self.window_slot_count - 1;
            var removed = self.window_slots[index];
            self.window_slots[index] = self.window_slots[last];
            self.window_slots[last] = WindowSlot.init(self.backing);
            self.window_slot_count = last;
            removed.arenas[0].deinit();
            removed.arenas[1].deinit();
            return on_close;
        }

        /// Rebuild every installed secondary window's tree from the
        /// model — every dispatched Msg funnels through here after the
        /// main rebuild, so all open windows always render the same
        /// model generation.
        fn rebuildWindowSlots(self: *Self, runtime: *Runtime) anyerror!void {
            for (self.window_slots[0..self.window_slot_count]) |*slot| {
                if (!slot.installed) continue;
                try self.rebuildWindowSlot(runtime, slot);
            }
        }

        fn rebuildWindowSlot(self: *Self, runtime: *Runtime, slot: *WindowSlot) anyerror!void {
            if (self.options.window_view == null) return;
            var tokens = runtime.tokensWithTextMeasure(self.slotEffectiveTokens(slot));
            const next_index = slot.arena_index ^ 1;
            const bounds = geometry.RectF.fromSize(slot.canvas_size).deflate(runtime.viewportInsetsForWindow(slot.window_id));
            var built = try self.buildWindowSlotPass(slot, bounds, tokens, next_index);
            // The same one-retry window-control clearance the main
            // rebuild runs (see `rebuild`): a secondary hidden-inset
            // window's drag header collides with the OS caption cluster
            // exactly like the main window's, so a proven collision
            // stamps the cluster into THIS slot's tokens (a local copy —
            // other windows keep their own layout) for one more pass.
            if (windowControlsReservation(runtime, slot.window_id, slot.canvasLabel(), built.layout, tokens)) |controls| {
                tokens.window_controls = controls;
                built = try self.buildWindowSlotPass(slot, bounds, tokens, next_index);
            }
            const tree = built.tree;
            const layout = built.layout;
            _ = try runtime.setCanvasWidgetLayout(slot.window_id, slot.canvasLabel(), layout);
            if (slot.installed and self.rebuildEmitsTokens(runtime, slot.window_id, slot.canvasLabel(), tokens)) {
                _ = try runtime.emitCanvasWidgetDisplayList(slot.window_id, slot.canvasLabel(), tokens);
            }
            slot.tree = tree;
            slot.arena_index = next_index;
            // Same close-on-vanish rule as the main canvas rebuild.
            if (self.contextMenuFallbackTargetForLabel(slot.canvasLabel()) != 0 and tree.context_menu_fallback == null) {
                self.clearContextMenuFallback();
            }
        }

        /// One view-build + flex-layout pass of `rebuildWindowSlot`,
        /// the slot-path sibling of `buildLayoutPass`: resets the slot's
        /// next arena (retaining capacity, so the clearance retry reuses
        /// the same pass's memory) and builds the window view against
        /// `bounds` with `tokens`.
        fn buildWindowSlotPass(
            self: *Self,
            slot: *WindowSlot,
            bounds: geometry.RectF,
            tokens: canvas.DesignTokens,
            next_index: usize,
        ) anyerror!BuiltLayout {
            const window_view = self.options.window_view.?;
            _ = slot.arenas[next_index].reset(.retain_capacity);
            var ui = Ui.init(slot.arenas[next_index].allocator());
            ui.context_menu_fallback_target = self.contextMenuFallbackTargetForLabel(slot.canvasLabel());
            self.armUiFragmentHost(&ui);
            const node = window_view(&ui, &self.model, slot.label());
            const tree = try ui.finalizeWithTokens(node, tokens);
            const layout = canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, &self.layout_nodes) catch |err| {
                if (err == error.WidgetLayoutListFull) {
                    ui_app_log.warn(
                        "widget layout capacity exceeded for window '{s}' view '{s}': the per-view budget is {d} nodes (canvas_limits.max_canvas_widget_nodes_per_view) - reduce always-mounted widgets or virtualize lists",
                        .{ slot.label(), slot.canvasLabel(), canvas_limits.max_canvas_widget_nodes_per_view },
                    );
                }
                return err;
            };
            return .{ .tree = tree, .layout = layout };
        }

        /// Re-apply the model-derived webview panes against the freshly
        /// computed widget layout: resolve each pane's anchor widget to a
        /// frame, then patch the scene's webview shell view when the
        /// frame, URL, or reload token changed. Failures degrade to a
        /// logged warning so a missing webview or a denied origin never
        /// takes the render loop down.
        fn applyWebPanes(self: *Self, runtime: *Runtime, window_id: platform.WindowId, layout: canvas.WidgetLayoutTree) void {
            const panes_fn = self.options.web_panes orelse return;
            var panes: [max_web_panes]WebViewPane = undefined;
            const count = @min(panes_fn(&self.model, &panes), max_web_panes);
            for (panes[0..count]) |pane| self.applyWebPane(runtime, window_id, layout, pane);
        }

        fn applyWebPane(self: *Self, runtime: *Runtime, window_id: platform.WindowId, layout: canvas.WidgetLayoutTree, pane: WebViewPane) void {
            var frame = pane.frame;
            if (pane.anchor) |anchor| {
                frame = webPaneAnchorFrame(layout, anchor) orelse {
                    ui_app_log.warn(
                        "webview pane '{s}': no canvas widget carries semantics label '{s}' - mark the region's widget with .semantics = .{{ .label = \"{s}\" }}",
                        .{ pane.label, anchor, anchor },
                    );
                    return;
                };
            }
            // Platform webview frames require a positive size and a
            // non-negative origin; a collapsed or clipped anchor keeps
            // the last applied frame instead of erroring every rebuild.
            if (frame.width < 1 or frame.height < 1) return;
            frame.x = @max(frame.x, 0);
            frame.y = @max(frame.y, 0);

            const state = self.webPaneState(pane.label) orelse {
                ui_app_log.warn("webview pane '{s}' ignored: more than {d} distinct pane labels", .{ pane.label, max_web_panes });
                return;
            };
            // Reconcile the frame against the runtime's actual webview
            // state rather than a cache: shell relayouts (window moves,
            // startup restores) reset scene webviews to their declared
            // frames behind the app's back, and each such reset
            // invalidates the canvas, so the next frame flows back
            // through here and re-snaps the pane.
            const actual_frame = runtime.webViewLocalFrame(window_id, pane.label) orelse {
                ui_app_log.warn(
                    "webview pane '{s}': the scene declares no .webview shell view with this label",
                    .{pane.label},
                );
                return;
            };
            var patch: platform.ViewPatch = .{};
            if (!rectsAlmostEqual(actual_frame, frame)) patch.frame = frame;
            const first_apply = state.url_len == 0;
            if (pane.url.len > 0 and (first_apply or !std.mem.eql(u8, state.url(), pane.url) or state.reload_token != pane.reload_token)) patch.url = pane.url;
            if (patch.frame == null and patch.url == null) return;

            _ = runtime.updateView(window_id, pane.label, patch) catch |err| {
                ui_app_log.warn(
                    "webview pane '{s}' update failed: {s} - the scene must declare a .webview shell view with this label and the URL's origin must be in security.navigation.allowed_origins",
                    .{ pane.label, @errorName(err) },
                );
                return;
            };
            state.reload_token = pane.reload_token;
            const url_len = @min(pane.url.len, state.url_storage.len);
            @memcpy(state.url_storage[0..url_len], pane.url[0..url_len]);
            state.url_len = url_len;
        }

        /// Find or insert the applied-state slot for a pane label.
        fn webPaneState(self: *Self, label: []const u8) ?*WebPaneState {
            for (self.web_pane_states[0..self.web_pane_state_count]) |*state| {
                if (std.mem.eql(u8, state.label(), label)) return state;
            }
            if (self.web_pane_state_count >= max_web_panes) return null;
            const state = &self.web_pane_states[self.web_pane_state_count];
            state.* = .{};
            const label_len = @min(label.len, state.label_storage.len);
            @memcpy(state.label_storage[0..label_len], label[0..label_len]);
            state.label_len = label_len;
            self.web_pane_state_count += 1;
            return state;
        }

        /// The layout frame of the first widget whose semantics label
        /// matches `anchor`.
        fn webPaneAnchorFrame(layout: canvas.WidgetLayoutTree, anchor: []const u8) ?geometry.RectF {
            for (layout.nodes) |node| {
                if (std.mem.eql(u8, node.widget.semantics.label, anchor)) return node.frame;
            }
            return null;
        }

        fn rectsAlmostEqual(a: geometry.RectF, b: geometry.RectF) bool {
            const epsilon: f32 = 0.25;
            return @abs(a.x - b.x) < epsilon and
                @abs(a.y - b.y) < epsilon and
                @abs(a.width - b.width) < epsilon and
                @abs(a.height - b.height) < epsilon;
        }

        /// Rebuild the retained display list around the reconciled widget
        /// layout: chrome prefix, widget commands, chrome suffix. The
        /// runtime then regenerates the widget span on internal state
        /// changes while preserving the chrome via
        /// `emitCanvasWidgetDisplayListWithChrome`.
        fn installChromeDisplayList(self: *Self, runtime: *Runtime, window_id: platform.WindowId, chrome: ChromeOptions, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens) anyerror!void {
            var chrome_commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
            var chrome_builder = canvas.Builder.init(&chrome_commands);
            try chrome.build(&self.model, &chrome_builder, self.canvas_size, tokens);
            const chrome_list = chrome_builder.displayList();
            if (chrome_list.commands.len != chrome.prefix_commands + chrome.suffix_commands) {
                return error.InvalidChromeCommandCount;
            }

            var commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
            var builder = canvas.Builder.init(&commands);
            for (chrome_list.commands[0..chrome.prefix_commands]) |command| try builder.append(command);
            try layout.emitDisplayList(&builder, tokens);
            for (chrome_list.commands[chrome.prefix_commands..]) |command| try builder.append(command);

            _ = try runtime.setCanvasDisplayList(window_id, self.options.canvas_label, builder.displayList());
            _ = try runtime.setCanvasWidgetLayout(window_id, self.options.canvas_label, layout);
            _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, self.options.canvas_label, tokens, .{
                .prefix_command_count = chrome.prefix_commands,
                .suffix_command_count = chrome.suffix_commands,
            });
        }

        /// Re-apply the model-derived render animations with the latest
        /// frame timestamp.
        fn scheduleAnimations(self: *Self, runtime: *Runtime, window_id: platform.WindowId) anyerror!void {
            const animations_fn = self.options.animations orelse return;
            const tree = &(self.tree orelse return);
            var animations: [canvas_limits.max_canvas_render_animations_per_view]canvas.CanvasRenderAnimation = undefined;
            const count = animations_fn(&self.model, tree, self.frame_timestamp_ns, &animations);
            _ = try runtime.setCanvasRenderAnimations(window_id, self.options.canvas_label, animations[0..count]);
        }

        /// Re-declare the model-derived layout tweens after a rebuild.
        /// `startCanvasWidgetLayoutTween` is idempotent per target, so
        /// declaring on every rebuild arms a tween exactly when the
        /// declared target diverges from the rendered value — the
        /// declarative twin of `scheduleAnimations`. A stale id (the
        /// widget left the tree this rebuild) is skipped, not an error:
        /// the hook reads the CURRENT tree, so ids are normally fresh.
        fn scheduleLayoutTweens(self: *Self, runtime: *Runtime, window_id: platform.WindowId) anyerror!void {
            const layout_tweens_fn = self.options.layout_tweens orelse return;
            const tree = &(self.tree orelse return);
            var tweens: [canvas_limits.max_canvas_widget_layout_tweens_per_view]canvas.CanvasWidgetLayoutTween = undefined;
            const count = layout_tweens_fn(&self.model, tree, &tweens);
            for (tweens[0..@min(count, tweens.len)]) |tween| {
                _ = runtime.startCanvasWidgetLayoutTween(window_id, self.options.canvas_label, tween) catch |err| switch (err) {
                    error.InvalidCommand => continue,
                    else => return err,
                };
            }
        }

        fn buildViewNode(self: *Self, ui: *Ui) anyerror!Ui.Node {
            if (comptime features.runtime_markup) {
                // A markup-only app parses its embedded source on the first
                // build; with both `view` and `markup` set, the compiled
                // view renders until the watch loads a changed source.
                if (self.markup_view == null and self.options.view == null) {
                    try self.reloadMarkup(self.options.markup.?.source);
                }
                if (self.markup_view) |*view| {
                    return view.build(ui, &self.model) catch |err| {
                        if (err == error.MarkupBuild) {
                            self.recordMarkupDiagnostic(.{
                                .line = view.diagnostic.line,
                                .column = view.diagnostic.column,
                                .message = view.diagnostic.message,
                                .path = view.diagnostic.path,
                            });
                        }
                        return err;
                    };
                }
            }
            const view = self.options.view.?;
            return view(ui, &self.model);
        }

        /// Parse and activate a markup source (the reload seam: hot reload
        /// and tests go through this). Imports resolve against the
        /// embedded source set (`MarkupOptions.sources`). Failures keep
        /// the previous view and set `markup_diagnostic`.
        pub fn reloadMarkup(self: *Self, source: []const u8) anyerror!void {
            if (comptime !features.runtime_markup) return error.MarkupEngineDisabled;
            const sources: []const canvas.ui_markup.SourceFile = if (self.options.markup) |markup_options| markup_options.sources else &.{};
            var set_loader = canvas.ui_markup.SourceSetLoader{ .set = sources };
            var hashing = HashingLoader.init(set_loader.loader(), source, "");
            if (comptime features.runtime_markup) {
                self.provenance_closure.reset();
                hashing.closure = &self.provenance_closure;
            }
            const next_index = self.markup_arena_index ^ 1;
            _ = self.markup_arenas[next_index].reset(.retain_capacity);
            const arena = self.markup_arenas[next_index].allocator();
            const owned_source = try arena.dupe(u8, source);
            var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
            const document = canvas.ui_markup.resolveImports(arena, "", owned_source, hashing.loader(), &diagnostic) catch |err| {
                if (err == error.MarkupSyntax or err == error.MarkupImport) self.recordMarkupDiagnostic(diagnostic);
                return err;
            };
            // The typed-document pass: attribute expressions parse once
            // here instead of on every frame's build.
            const canonical = try canvas.ui_markup.canonicalize(arena, document);
            self.adoptMarkupDocument(canonical, next_index, hashing.hasher.final());
            // Embedded resolve: root nodes carry an empty src_path, and
            // imported entries are markup-root-relative (joined onto the
            // watched file's directory for their on-disk location).
            self.commitProvenanceFiles("", owned_source, false);
        }

        /// Activate a resolved document built into `arena_index`'s arena.
        fn adoptMarkupDocument(self: *Self, document: canvas.ui_markup.MarkupDocument, arena_index: usize, closure_hash: u64) void {
            self.markup_view = MarkupView.fromDocument(document);
            self.markup_arena_index = arena_index;
            self.markup_source_hash = closure_hash;
            self.markup_diagnostic = null;
        }

        /// Wraps an ImportLoader so the watch's change signal covers the
        /// whole import closure: the hash folds in the root source plus
        /// every file the resolver loads, in resolution order, so an edit
        /// to an IMPORTED file reloads exactly like an edit to the root.
        /// Paths hash RELATIVE to the markup root (`strip_prefix` is the
        /// watched file's directory), so the embedded baseline — whose
        /// source-set paths are already root-relative — and the disk poll
        /// agree byte for byte when nothing changed.
        const HashingLoader = struct {
            inner: canvas.ui_markup.ImportLoader,
            hasher: std.hash.Wyhash,
            strip_prefix: []const u8 = "",
            /// Provenance staging: when set, every loaded file's
            /// resolver-relative path and content hash is recorded so the
            /// adopt step can commit them as write-back anchors.
            closure: ?*ui_app_provenance.ClosureFiles = null,

            fn init(inner: canvas.ui_markup.ImportLoader, root_source: []const u8, strip_prefix: []const u8) HashingLoader {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(root_source);
                return .{ .inner = inner, .hasher = hasher, .strip_prefix = strip_prefix };
            }

            fn loader(self: *HashingLoader) canvas.ui_markup.ImportLoader {
                return .{ .context = @ptrCast(self), .load = load };
            }

            fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
                const self: *HashingLoader = @ptrCast(@alignCast(@constCast(context)));
                const source = self.inner.load(self.inner.context, arena, path) orelse return null;
                var hashed_path = path;
                if (self.strip_prefix.len > 0 and path.len > self.strip_prefix.len and
                    std.mem.startsWith(u8, path, self.strip_prefix) and path[self.strip_prefix.len] == '/')
                {
                    hashed_path = path[self.strip_prefix.len + 1 ..];
                }
                self.hasher.update(hashed_path);
                self.hasher.update(&[_]u8{0});
                self.hasher.update(source);
                if (self.closure) |closure| closure.add(path, std.hash.Wyhash.hash(0, source));
                return source;
            }
        };

        /// Commit the just-adopted closure into the provenance file
        /// table (write-back anchors: per-file loaded-bytes hashes and
        /// on-disk paths). `root_stamped` is the src_path the resolver
        /// stamped on root nodes; `entries_are_disk_paths` is true for
        /// the disk (watch) resolve, whose paths are already cwd-relative.
        /// Committed ONLY on adopt: a failed mid-edit reload keeps the
        /// last-good table so spans and hashes always describe the bytes
        /// the running view was built from.
        fn commitProvenanceFiles(self: *Self, root_stamped: []const u8, root_source: []const u8, entries_are_disk_paths: bool) void {
            if (comptime !features.runtime_markup) return;
            const markup_options = self.options.markup;
            const watch_path: ?[]const u8 = if (markup_options) |m| m.watch_path else null;
            self.provenance.resetFiles();
            self.provenance.watching = watch_path != null and (if (markup_options) |m| m.io != null else false);
            self.provenance.addFile(root_stamped, watch_path orelse "", std.hash.Wyhash.hash(0, root_source)) catch {};
            const disk_prefix: []const u8 = if (watch_path) |path| (std.fs.path.dirname(path) orelse "") else "";
            for (self.provenance_closure.entries[0..self.provenance_closure.len]) |*entry| {
                const stamped = entry.path[0..entry.path_len];
                var disk_buffer: [ui_app_provenance.max_path_bytes]u8 = undefined;
                const disk: []const u8 = if (entries_are_disk_paths)
                    stamped
                else if (watch_path == null)
                    ""
                else if (disk_prefix.len > 0)
                    std.fmt.bufPrint(&disk_buffer, "{s}/{s}", .{ disk_prefix, stamped }) catch ""
                else
                    stamped;
                self.provenance.addFile(stamped, disk, entry.hash) catch {};
            }
        }

        /// Answer an automation `provenance` query for our canvas view
        /// from the retained table and publish the response artifact.
        /// Setting the runtime's handshake flag tells the dispatcher an
        /// answer landed (its fallback teaches when no app responds).
        fn handleProvenanceQuery(self: *Self, runtime: *Runtime, query: core.AutomationProvenanceEvent) anyerror!void {
            if (comptime !features.runtime_markup) return;
            if (!std.mem.eql(u8, query.view_label, self.options.canvas_label)) return;
            const server = runtime.options.automation orelse return;
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try self.provenance.writeResponse(&writer, query.view_label, query.widget_id);
            try server.publishProvenanceResponse(writer.buffered());
            runtime.automation_provenance_published = true;
        }

        /// Store a markup diagnostic and say it out loud once per distinct
        /// failure: build errors recur every frame, and a view that fails
        /// on its FIRST build has no last-good fallback - without a log
        /// line the developer faces a blank window and silence.
        /// Resolver messages can be arena-formatted (cycle paths, duplicate
        /// sites) and the arena resets on the next reload attempt, so the
        /// stored copy owns its bytes.
        fn recordMarkupDiagnostic(self: *Self, info: canvas.ui_markup.MarkupErrorInfo) void {
            const already_reported = if (self.markup_diagnostic) |current|
                current.line == info.line and current.column == info.column and
                    std.mem.eql(u8, current.message, info.message) and std.mem.eql(u8, current.path, info.path)
            else
                false;
            if (!already_reported) {
                // std.debug.print, not std.log: the default scaffold app is
                // ReleaseFast (std.log only passes .err there), while
                // logged errors fail test suites that exercise bad markup
                // on purpose. Direct stderr is visible in both.
                if (info.path.len > 0) {
                    std.debug.print("markup view failed to build ({s}:{d}:{d}): {s}\n", .{ info.path, info.line, info.column, info.message });
                } else {
                    std.debug.print("markup view failed to build ({d}:{d}): {s}\n", .{ info.line, info.column, info.message });
                }
            }
            const message_len = @min(info.message.len, self.markup_diagnostic_message_storage.len);
            @memcpy(self.markup_diagnostic_message_storage[0..message_len], info.message[0..message_len]);
            const path_len = @min(info.path.len, self.markup_diagnostic_path_storage.len);
            @memcpy(self.markup_diagnostic_path_storage[0..path_len], info.path[0..path_len]);
            self.markup_diagnostic = .{
                .line = info.line,
                .column = info.column,
                .message = self.markup_diagnostic_message_storage[0..message_len],
                .path = self.markup_diagnostic_path_storage[0..path_len],
            };
        }

        /// Dev-mode hot reload: start the repeating runtime timer that polls
        /// the watched markup file and every registered fragment. Runs
        /// once, on first install, and only when something is watchable —
        /// a root watch path with io, or (Debug only) registered fragments.
        fn startMarkupWatch(self: *Self, runtime: *Runtime) void {
            if (comptime !features.runtime_markup) return;
            const root_armed = if (self.options.markup) |markup_options|
                markup_options.watch_path != null and markup_options.io != null
            else
                false;
            if (root_armed) {
                const markup_options = self.options.markup.?;
                // With a compiled `view` also set, the embedded sources are
                // the baseline: the interpreter only takes over once the
                // watched closure diverges from them. The baseline hash must
                // be computed the way the poll computes it — over the whole
                // resolved import closure — or the first poll would flag a
                // phantom change.
                if (self.options.view != null and self.markup_source_hash == 0) {
                    self.markup_source_hash = self.embeddedMarkupClosureHash(markup_options);
                }
            }
            const fragments_armed = self.armFragmentWatch();
            if (!root_armed and !fragments_armed) return;
            runtime.startTimer(markup_watch_timer_id, markup_watch_interval_ns, true) catch {};
            // Make the armed watch observable: the automation snapshot
            // header reports `markup_watch=armed|off`, so a dev loop can
            // check the watch instead of bisecting an app that never
            // reloads. The bit stays honest for hybrid apps: registered
            // fragments arm it in Debug, and in release — where the
            // fragment watch compiles out — a compiled-only app reports
            // off.
            if (comptime @hasDecl(Runtime, "setMarkupWatchArmed")) {
                runtime.setMarkupWatchArmed(true);
            }
        }

        /// Seed every registered fragment slot's baseline hash from its
        /// embedded sources (computed the way the poll computes disk
        /// hashes, so an untouched file never phantom-reloads). Returns
        /// whether any fragment is actually watched.
        fn armFragmentWatch(self: *Self) bool {
            if (comptime !fragment_watch_enabled) return false;
            const fragment_watch = self.options.fragment_watch orelse return false;
            if (fragment_watch.fragments.len > max_watched_fragments) {
                ui_app_log.warn(
                    "fragment watch: {d} fragments registered but the watch budget is {d} (max_watched_fragments) - the rest stay compiled-only; consolidate fragments or raise the budget",
                    .{ fragment_watch.fragments.len, max_watched_fragments },
                );
            }
            const count = @min(fragment_watch.fragments.len, max_watched_fragments);
            for (fragment_watch.fragments[0..count], self.markup_fragment_slots[0..count]) |spec, *slot| {
                // Baseline into the slot's inactive arena — reset on the
                // next reload attempt, so this costs nothing durable.
                const scratch_index = slot.arena_index ^ 1;
                _ = slot.arenas[scratch_index].reset(.retain_capacity);
                slot.baseline_hash = embeddedClosureHash(slot.arenas[scratch_index].allocator(), spec.source, spec.sources);
                slot.hash = slot.baseline_hash;
            }
            return count > 0;
        }

        fn embeddedMarkupClosureHash(self: *Self, markup_options: MarkupOptions) u64 {
            // Resolve into the inactive scratch arena purely for the
            // hashing side effect; the arena resets on the next reload.
            const scratch_index = self.markup_arena_index ^ 1;
            _ = self.markup_arenas[scratch_index].reset(.retain_capacity);
            return embeddedClosureHash(self.markup_arenas[scratch_index].allocator(), markup_options.source, markup_options.sources);
        }

        /// Hash an embedded source closure exactly like the disk poll
        /// hashes the on-disk one: root bytes plus every loaded file's
        /// root-relative path and bytes, in resolution order.
        fn embeddedClosureHash(arena: std.mem.Allocator, source: []const u8, sources: []const canvas.ui_markup.SourceFile) u64 {
            if (sources.len == 0) {
                return std.hash.Wyhash.hash(0, source);
            }
            var set_loader = canvas.ui_markup.SourceSetLoader{ .set = sources };
            var hashing = HashingLoader.init(set_loader.loader(), source, "");
            var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
            _ = canvas.ui_markup.resolveImports(
                arena,
                "",
                source,
                hashing.loader(),
                &diagnostic,
            ) catch {};
            return hashing.hasher.final();
        }

        /// Timer-driven poll of the watched markup closure: re-resolve
        /// from disk (imports relative to the watched file) and re-parse
        /// when any file in the closure changes. A failed parse or resolve
        /// keeps the last good view running and records the diagnostic. A
        /// successful reload rebuilds, which invalidates the canvas and
        /// schedules the presenting frame.
        fn pollMarkupWatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId) void {
            if (comptime !features.runtime_markup) return;
            const markup_options = self.options.markup orelse return;
            const watch_path = markup_options.watch_path orelse return;
            const io = markup_options.io orelse return;

            const next_index = self.markup_arena_index ^ 1;
            _ = self.markup_arenas[next_index].reset(.retain_capacity);
            const arena = self.markup_arenas[next_index].allocator();
            const source = readMarkupFile(io, arena, watch_path) orelse return;
            var disk_loader = DiskImportLoader{ .io = io };
            const watch_dir = std.fs.path.dirname(watch_path) orelse "";
            var hashing = HashingLoader.init(disk_loader.loader(), source, watch_dir);
            if (comptime features.runtime_markup) {
                self.provenance_closure.reset();
                hashing.closure = &self.provenance_closure;
            }
            var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
            const document = canvas.ui_markup.resolveImports(arena, watch_path, source, hashing.loader(), &diagnostic) catch |err| {
                const hash = hashing.hasher.final();
                if (hash == self.markup_source_hash) return;
                self.markup_source_hash = hash;
                if (err == error.MarkupSyntax or err == error.MarkupImport) {
                    self.recordMarkupDiagnostic(diagnostic);
                }
                return;
            };
            const hash = hashing.hasher.final();
            if (hash == self.markup_source_hash) return;
            // Canonicalize for per-frame cost only; on OOM the raw
            // document builds identically through attrTyped's fallback.
            const canonical = canvas.ui_markup.canonicalize(arena, document) catch document;
            self.adoptMarkupDocument(canonical, next_index, hash);
            // Disk resolve: root nodes carry the watch path, and imported
            // entries are already cwd-relative disk paths.
            self.commitProvenanceFiles(watch_path, source, true);
            if (self.installed) self.rebuild(runtime, window_id) catch {};
        }

        /// Timer-driven poll of every registered fragment (Debug dev runs
        /// only), riding the same reserved timer as the root watch. Each
        /// fragment's whole import closure is re-resolved and hashed per
        /// poll, so a change to a SHARED imported file reloads every
        /// fragment whose closure reaches it — one edit, one rebuild, all
        /// dependents fresh. Same degrade family as the root watch: a
        /// failed parse keeps that fragment's last good view and records
        /// the file:line diagnostic; a save matching the embedded
        /// baseline drops the fragment back to its compiled path.
        fn pollFragmentWatch(self: *Self, runtime: *Runtime) void {
            if (comptime !fragment_watch_enabled) return;
            const fragment_watch = self.options.fragment_watch orelse return;
            const count = @min(fragment_watch.fragments.len, max_watched_fragments);
            var any_adopted = false;
            for (fragment_watch.fragments[0..count], self.markup_fragment_slots[0..count]) |spec, *slot| {
                const next_index = slot.arena_index ^ 1;
                _ = slot.arenas[next_index].reset(.retain_capacity);
                const arena = slot.arenas[next_index].allocator();
                const source = readMarkupFile(fragment_watch.io, arena, spec.path) orelse continue;
                var disk_loader = DiskImportLoader{ .io = fragment_watch.io };
                const watch_dir = std.fs.path.dirname(spec.path) orelse "";
                var hashing = HashingLoader.init(disk_loader.loader(), source, watch_dir);
                var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
                const document = canvas.ui_markup.resolveImports(arena, spec.path, source, hashing.loader(), &diagnostic) catch |err| {
                    const hash = hashing.hasher.final();
                    if (hash == slot.hash) continue;
                    slot.hash = hash;
                    if (err == error.MarkupSyntax or err == error.MarkupImport) {
                        self.recordMarkupDiagnostic(diagnostic);
                    }
                    continue;
                };
                const hash = hashing.hasher.final();
                if (hash == slot.hash) continue;
                slot.hash = hash;
                if (hash == slot.baseline_hash) {
                    // The edit was reverted byte for byte: back to the
                    // comptime-compiled path, the release-identical one.
                    slot.document = null;
                } else {
                    // Canonicalize for per-frame cost only; on OOM the raw
                    // document builds identically through attrTyped's
                    // fallback.
                    slot.document = canvas.ui_markup.canonicalize(arena, document) catch document;
                }
                slot.arena_index = next_index;
                // One diagnostic channel, adopt clears it — the root
                // watch's contract (`adoptMarkupDocument`): the dev loop
                // edits one file at a time, and the recovering save is
                // what should silence the teaching line.
                self.markup_diagnostic = null;
                any_adopted = true;
            }
            // Fragments build wherever the app's views embed them — the
            // main canvas and declared windows — so a reload re-derives
            // every open view.
            if (any_adopted and self.installed) self.rebuildAllViews(runtime) catch {};
        }

        /// The `override` half of the fragment hot-reload seam (see
        /// `canvas.MarkupFragmentHost`): a compiled fragment asks by
        /// identity key whether the watch adopted a changed document for
        /// it. Null keeps the comptime-compiled path.
        fn markupFragmentOverride(context: *anyopaque, key: *const anyopaque) ?*const anyopaque {
            if (comptime !fragment_watch_enabled) return null;
            const self: *Self = @ptrCast(@alignCast(context));
            const fragment_watch = self.options.fragment_watch orelse return null;
            const count = @min(fragment_watch.fragments.len, max_watched_fragments);
            for (fragment_watch.fragments[0..count], self.markup_fragment_slots[0..count]) |spec, *slot| {
                const spec_key = spec.key orelse continue;
                if (spec_key != key) continue;
                if (slot.document) |*document| return @ptrCast(document);
                return null;
            }
            return null;
        }

        /// The `report` half of the fragment hot-reload seam: a reloaded
        /// fragment that parses but cannot build against this Model/Msg
        /// surfaces the same file:line teaching diagnostic the root
        /// watch's build failures do.
        fn markupFragmentReport(context: *anyopaque, diagnostic: canvas.MarkupFragmentDiagnostic) void {
            if (comptime !fragment_watch_enabled) return;
            const self: *Self = @ptrCast(@alignCast(context));
            self.recordMarkupDiagnostic(.{
                .line = diagnostic.line,
                .column = diagnostic.column,
                .message = diagnostic.message,
                .path = diagnostic.path,
            });
        }

        /// Arm the fragment hot-reload seam on a freshly initialized Ui
        /// (both the main canvas and declared-window builds), so compiled
        /// fragments built anywhere in the app can pick up their reloaded
        /// documents. No-op unless the fragment watch exists and the app
        /// registered fragments.
        fn armUiFragmentHost(self: *Self, ui: *Ui) void {
            if (comptime !fragment_watch_enabled) return;
            if (self.options.fragment_watch == null) return;
            ui.markup_fragment_host = .{
                .context = @ptrCast(self),
                .override = markupFragmentOverride,
                .report = markupFragmentReport,
            };
        }

        /// Disk-backed import loader for the watch: paths come out of the
        /// resolver already relative to the process cwd (they are joined
        /// against the watched file's path, which is cwd-relative — the
        /// dev flow runs apps from the app root).
        const DiskImportLoader = struct {
            io: std.Io,

            fn loader(self: *DiskImportLoader) canvas.ui_markup.ImportLoader {
                return .{ .context = @ptrCast(self), .load = load };
            }

            fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
                const self: *const DiskImportLoader = @ptrCast(@alignCast(context));
                return readMarkupFile(self.io, arena, path);
            }
        };

        const max_markup_watch_file_bytes = 256 * 1024;

        fn readMarkupFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
            var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
            defer file.close(io);
            const buffer = arena.alloc(u8, max_markup_watch_file_bytes) catch return null;
            const len = file.readPositionalAll(io, buffer, 0) catch return null;
            return buffer[0..len];
        }

        /// Reserved framework timer id for the markup watch poll. Application
        /// timer ids must stay below `platform.reserved_timer_id_base`.
        pub const markup_watch_timer_id: u64 = platform.reserved_timer_id_base | 0x2e70_a11c;
        const markup_watch_interval_ns: u64 = 500 * std.time.ns_per_ms;

        /// Reserved framework timer id for the press-and-hold gesture
        /// (`ElementOptions.on_hold`): armed on pointer-down over a widget
        /// with a hold handler, cancelled on release, dispatching the hold
        /// Msg when it fires first. One-shot; distinct from the markup
        /// watch id and the fx-timer range. Defined at the platform layer
        /// so `automate widget-hold` fires the same timer a real gesture
        /// arms.
        pub const press_hold_timer_id: u64 = platform.press_hold_timer_id;
        /// A desktop list-row register (press to open, hold for the
        /// menu): ~350 ms press-and-hold.
        pub const press_hold_duration_ns: u64 = 350 * std.time.ns_per_ms;

        /// Install the menu-bar extra once, on the installing frame.
        /// Selecting one of its items dispatches the item's `command`
        /// through the ordinary `on_command` path (source `.tray`).
        /// Unsupported platforms degrade to a logged warning. With a
        /// `status_item_fn`, the model's derived title/items win from
        /// the very first frame (the static options keep icon+tooltip).
        fn installStatusItem(self: *Self, runtime: *Runtime) void {
            if (self.status_item_installed) return;
            if (self.options.status_item == null and self.options.status_item_fn == null) return;
            self.status_item_installed = true;
            const static = self.options.status_item orelse StatusItemOptions{};
            var title = static.title;
            var items = static.items;
            if (self.options.status_item_fn) |state_fn| {
                const state = state_fn(&self.model, &self.tray_scratch);
                title = state.title;
                items = state.items;
            }
            runtime.createTray(.{
                .title = title,
                .icon_path = static.icon_path,
                .tooltip = static.tooltip,
                .items = items,
            }) catch |err| {
                ui_app_log.warn("status item install failed: {s}", .{@errorName(err)});
                return;
            };
            self.tray_created = true;
            self.tray_title_hash = hashTrayTitle(title);
            self.tray_menu_hash = hashTrayMenu(items);
        }

        /// Re-derive the tray state from the model after a rebuild and
        /// patch only what changed — the `web_panes` shape for the menu
        /// bar. Failures degrade to a logged warning; a rejected
        /// state is remembered so a static model does not warn per frame.
        fn applyStatusItem(self: *Self, runtime: *Runtime) void {
            const state_fn = self.options.status_item_fn orelse return;
            if (!self.tray_created) return;
            const state = state_fn(&self.model, &self.tray_scratch);

            const title_hash = hashTrayTitle(state.title);
            if (title_hash != self.tray_title_hash) {
                self.tray_title_hash = title_hash;
                if (!self.tray_title_unsupported) {
                    runtime.updateTrayTitle(state.title) catch |err| {
                        if (err == error.UnsupportedService) {
                            self.tray_title_unsupported = true;
                            ui_app_log.warn("status item title updates unsupported on this platform: the menu keeps updating, the button title stays \"{s}\"-era static", .{state.title});
                        } else {
                            ui_app_log.warn("status item title update failed: {s}", .{@errorName(err)});
                        }
                    };
                }
            }

            const menu_hash = hashTrayMenu(state.items);
            if (menu_hash != self.tray_menu_hash) {
                self.tray_menu_hash = menu_hash;
                runtime.updateTrayMenu(state.items) catch |err| {
                    ui_app_log.warn("status item menu update failed: {s} (items must carry unique non-zero ids and validated command names)", .{@errorName(err)});
                };
            }
        }

        fn sceneFn(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.options.scene;
        }

        fn eventFn(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    const map = self.options.on_command orelse return;
                    if (map(command.name)) |msg| {
                        // Window-less command sources (status items, app
                        // menus before any window focus) carry window id 0;
                        // dispatch those against the canvas window.
                        const window_id = if (command.window_id == 0) self.canvas_window_id else command.window_id;
                        try self.dispatch(runtime, window_id, msg);
                    }
                },
                .appearance_changed => |appearance| {
                    const changed = !std.meta.eql(self.system_appearance, appearance);
                    self.system_appearance = appearance;
                    if (self.options.on_appearance) |map| {
                        if (map(appearance)) |msg| {
                            try self.dispatch(runtime, self.canvas_window_id, msg);
                            return;
                        }
                    }
                    // No app mapping consumed the change: when the stock
                    // tokens follow the system, re-derive and re-render
                    // live — flipping the OS appearance re-themes the
                    // running app without a restart. Before install the
                    // stored appearance alone is enough: the first build
                    // reads it.
                    if (changed and self.installed and self.followsSystemAppearance()) {
                        try self.rebuild(runtime, self.canvas_window_id);
                        if (self.options.chrome == null) {
                            _ = try runtime.emitCanvasWidgetDisplayList(self.canvas_window_id, self.options.canvas_label, runtime.tokensWithTextMeasure(self.effectiveTokens()));
                        }
                    }
                },
                .timer => |timer_event| try self.handleTimer(runtime, timer_event),
                // Platform audio reports route back through the effects
                // channel into the app's `on_event` Msg (and journal on
                // the way — the recorded boundary).
                .audio => |audio_event| if (self.effects.takeAudioMsg(audio_event)) |msg| {
                    try self.dispatch(runtime, self.canvas_window_id, msg);
                },
                .effects_wake => try self.drainEffects(runtime),
                .gpu_surface_frame => |frame_event| try self.handleFrame(runtime, frame_event),
                .gpu_surface_resized => |resize_event| try self.handleResize(runtime, resize_event),
                .canvas_widget_pointer => |pointer_event| try self.handlePointer(runtime, pointer_event),
                .canvas_widget_keyboard => |keyboard_event| try self.handleKeyboard(runtime, keyboard_event),
                .canvas_widget_scroll => |scroll_event| try self.handleScroll(runtime, scroll_event),
                .canvas_widget_context_menu => |menu_event| try self.handleContextMenu(runtime, menu_event),
                .canvas_widget_context_menu_request => |request_event| try self.handleContextMenuRequest(runtime, request_event),
                .canvas_widget_dismiss => |dismiss_event| try self.handleDismiss(runtime, dismiss_event),
                .canvas_widget_context_press => |press_event| try self.handleContextPress(runtime, press_event),
                .canvas_widget_resize => |resize_event| try self.handleWidgetResize(runtime, resize_event),
                .canvas_widget_change => |change_event| try self.handleWidgetChange(runtime, change_event),
                .window_closed => |closed| try self.handleWindowClosed(runtime, closed),
                .automation_provenance => |query| try self.handleProvenanceQuery(runtime, query),
                // Raw gpu-surface input stays runtime-internal EXCEPT the
                // pinch kinds, which surface through the app-level pinch
                // channel (widget routing never claims a pinch).
                .gpu_surface_input => |input_event| try self.handlePinch(runtime, input_event),
                else => {},
            }
        }

        /// The platform closed a window (the user clicked its close
        /// button): if it was one of ours, forget the slot — the window
        /// is already gone, the optimistic echo — and dispatch the
        /// descriptor's `on_close` Msg so the model owns the close. A
        /// model that keeps declaring the window gets it back on the
        /// next rebuild (source wins), exactly like a dismissed surface.
        fn handleWindowClosed(self: *Self, runtime: *Runtime, closed: core.WindowClosedEvent) anyerror!void {
            const index = self.windowSlotIndexByWindowId(closed.window_id) orelse return;
            const on_close = self.forgetWindowSlot(index);
            if (on_close) |msg| {
                try self.dispatch(runtime, self.canvas_window_id, msg);
            }
        }

        /// The tree whose handler table owns events from `view_label`:
        /// the main canvas or a declared window's.
        fn treeForViewLabel(self: *Self, view_label: []const u8) ?*const Ui.Tree {
            if (std.mem.eql(u8, view_label, self.options.canvas_label)) {
                return if (self.tree) |*tree| tree else null;
            }
            if (self.windowSlotByCanvasLabel(view_label)) |slot| {
                return if (slot.tree) |*tree| tree else null;
            }
            return null;
        }

        fn handleTimer(self: *Self, runtime: *Runtime, timer_event: platform.TimerEvent) anyerror!void {
            if (timer_event.id == markup_watch_timer_id) {
                self.pollMarkupWatch(runtime, self.canvas_window_id);
                self.pollFragmentWatch(runtime);
                return;
            }
            if (timer_event.id == press_hold_timer_id) {
                try self.firePressHold(runtime);
                return;
            }
            // Fired fx timers (`fx.startTimer`) map back to their
            // `on_fire` Msgs; their reserved-range ids never reach
            // `on_timer` (takeTimerMsg ignores ids outside the fx range).
            if (self.effects.takeTimerMsg(timer_event.id, timer_event.timestamp_ns)) |msg| {
                try self.dispatch(runtime, self.canvas_window_id, msg);
                return;
            }
            if (timer_event.id >= platform.reserved_timer_id_base) return;
            const map = self.options.on_timer orelse return;
            if (map(timer_event.id, timer_event.timestamp_ns)) |msg| {
                try self.dispatch(runtime, self.canvas_window_id, msg);
            }
        }

        /// Register the app's declared font faces (`Options.fonts`) with
        /// the runtime, translating each failure into a teaching error
        /// naming the font and what is wrong before propagating it.
        fn registerDeclaredFonts(self: *Self, runtime: *Runtime) anyerror!void {
            for (self.options.fonts) |font| {
                runtime.registerCanvasFont(font.id, font.ttf) catch |err| {
                    switch (err) {
                        error.FontParseFailed => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: {s}",
                            .{ font.name, font.id, canvas.font_ttf.parseFailureReason(font.ttf) orelse "not a parseable TrueType face" },
                        ),
                        error.FontExceedsGlyphBudgets => if (canvas.font_ttf.declaredGlyphMaxima(font.ttf)) |maxima| ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: its 'maxp' declares glyphs up to {d} points / {d} contours, flattened composites up to {d} points / {d} contours, with composites {d} deep of {d} components, beyond the outline budgets ({d} points, {d} contours, {d} composite points, {d} composite contours, {d} deep, {d} components — canvas.font_ttf); past-budget glyphs would render as block fallbacks, so registration refuses the face whole",
                            .{ font.name, font.id, maxima.points, maxima.contours, maxima.composite_points, maxima.composite_contours, maxima.component_depth, maxima.component_elements, canvas.font_ttf.max_glyph_points, canvas.font_ttf.max_glyph_contours, canvas.font_ttf.max_composite_points, canvas.font_ttf.max_composite_contours, canvas.font_ttf.max_composite_depth, canvas.font_ttf.max_composite_components },
                        ) else ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: it declares glyph outlines denser than the renderer's budgets ({d} points / {d} contours per glyph — canvas.font_ttf), so its densest glyphs could not render as outlines",
                            .{ font.name, font.id, canvas.font_ttf.max_glyph_points, canvas.font_ttf.max_glyph_contours },
                        ),
                        error.FontTooLarge => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: the file is {d} bytes but the per-font budget is {d} bytes (canvas_limits.max_registered_canvas_font_bytes)",
                            .{ font.name, font.id, font.ttf.len, canvas_limits.max_registered_canvas_font_bytes },
                        ),
                        error.FontRegistryFull => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: all {d} registered-font slots are in use (canvas_limits.max_registered_canvas_fonts)",
                            .{ font.name, font.id, canvas_limits.max_registered_canvas_fonts },
                        ),
                        error.InvalidFontId => ui_app_log.warn(
                            "font \"{s}\" failed to register: font id 0 is the \"inherit run font\" sentinel; choose an id at or above {d} (canvas.min_registered_font_id)",
                            .{ font.name, canvas.min_registered_font_id },
                        ),
                        error.ReservedFontId => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: ids below {d} are reserved for built-in faces; choose an id at or above {d} (canvas.min_registered_font_id)",
                            .{ font.name, font.id, canvas.min_registered_font_id, canvas.min_registered_font_id },
                        ),
                        error.FontIdInUse => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: that id already holds a registered face, and registered ids are permanent (atlas caches key glyphs by font id) — give each face its own id",
                            .{ font.name, font.id },
                        ),
                        error.FontHostRegistrationUnsupported => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: this platform measures and draws text host-side but cannot learn app fonts, so the face could not be honored pixel-honestly",
                            .{ font.name, font.id },
                        ),
                        else => ui_app_log.warn(
                            "font \"{s}\" (id {d}) failed to register: {s}",
                            .{ font.name, font.id, @errorName(err) },
                        ),
                    }
                    return err;
                };
            }
        }

        fn handleFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            if (!std.mem.eql(u8, frame_event.label, self.options.canvas_label)) {
                return self.handleWindowSlotFrame(runtime, frame_event);
            }
            // Host-pumped embeds deliver no `.wake`; drain pending effect
            // results with the frame tick so this frame presents them.
            try self.drainEffects(runtime);
            self.canvas_window_id = frame_event.window_id;
            self.frame_timestamp_ns = frame_event.timestamp_ns;
            const scale = normalizedSurfaceScale(frame_event.scale_factor);
            var installing = false;
            if (!self.installed) {
                installing = true;
                self.canvas_size = frame_event.size;
                self.pixel_snap_scale = scale;
                // Fonts first: the installing rebuild below is the first
                // layout, and it must already measure with the registered
                // faces. Exactly-once, like init_fx — a failure surfaces
                // through the dispatch error channel and does not retry
                // every frame.
                if (!self.fonts_registered) {
                    self.fonts_registered = true;
                    try registerDeclaredFonts(self, runtime);
                }
                if (self.options.init_fx) |init_fx| {
                    if (!self.init_fx_ran) {
                        self.init_fx_ran = true;
                        self.bindEffectsChannel(runtime);
                        init_fx(&self.model, &self.effects);
                        self.publishAudioState(runtime);
                        // Launch lap (env-gated): boot-effect cost (asset
                        // decode/registration) splits out of the
                        // scene_loaded -> first_view_built window.
                        launch_timing.lapOnce("init_fx_done");
                    }
                }
                // Chrome insets reach the model BEFORE the first view
                // build (`applyMsg`, no dispatch — the installing
                // rebuild below is the one that renders it), so a
                // hidden-titlebar header is padded in the very first
                // paint.
                if (self.chromeInsetsMsg(runtime, frame_event.window_id)) |msg| {
                    self.applyMsg(msg);
                }
                try self.rebuild(runtime, frame_event.window_id);
                if (self.options.chrome == null) {
                    _ = try runtime.emitCanvasWidgetDisplayList(frame_event.window_id, self.options.canvas_label, runtime.tokensWithTextMeasure(self.effectiveTokens()));
                }
                self.installed = true;
                // The installing rebuild measured with everything the
                // registry holds right now (declared fonts registered
                // above, embedder registrations before install): adopt
                // the count so only faces joining AFTER this build
                // trigger the late-registration rebuild.
                self.fonts_built_count = runtime.registeredCanvasFontCount();
                self.startMarkupWatch(runtime);
                self.installStatusItem(runtime);
            } else if (@abs(self.pixel_snap_scale - scale) > 0.001) {
                // The surface moved to a different density (a drag between
                // monitors): EVERY token path carries the scale in
                // `pixel_snap.scale`, so static-token apps rebuild here
                // too — the re-emit inside `rebuild` re-snaps hairlines
                // against the new grid.
                self.pixel_snap_scale = scale;
                try self.rebuild(runtime, frame_event.window_id);
            } else if (frame_event.size.width != self.canvas_size.width or
                frame_event.size.height != self.canvas_size.height)
            {
                // The presented frame IS the drawable's honest size:
                // during a live resize the frames carry the new size
                // before the window-manager resize event lands, and
                // every dispatch-driven rebuild inside that gap (a
                // playback clock tick, a frame-channel Msg) would lay
                // out at the STALE bounds — content anchored to the old
                // bottom edge paints below (or short of) a window that
                // already shrank or grew. Adopt the size and rebuild,
                // exactly what `handleResize` does when the event
                // arrives; the resize event that follows becomes a
                // no-reflow confirmation (its rebuild lays out the same
                // bounds), and fullscreen chrome re-queries stay its
                // job.
                self.canvas_size = frame_event.size;
                try self.rebuild(runtime, frame_event.window_id);
            } else if (runtime.registeredCanvasFontCount() != self.fonts_built_count) {
                // A face joined the registry after install (late
                // registration through the runtime seam). The runtime
                // already invalidated measurement caches and requested
                // frames for every open surface (noteCanvasFontsChanged),
                // but repainting retained geometry only re-inks text
                // measured with the OLD seam answers: honoring the fonts
                // doc's promise — every open surface re-measures — means
                // rebuilding so layout and the re-emitted display lists
                // charge the registered face's advances.
                try self.rebuildForRegisteredFonts(runtime);
            } else if (self.options.web_panes != null) {
                // Re-snap the webview panes each presented frame: a shell
                // relayout that stomped a pane frame also invalidated the
                // canvas, so the reconciliation ride-along here converges
                // without a dedicated event.
                if (runtime.canvasWidgetLayout(frame_event.window_id, self.options.canvas_label)) |layout| {
                    self.applyWebPanes(runtime, frame_event.window_id, layout);
                } else |_| {}
            }
            try self.presentFrame(runtime, frame_event, self.options.canvas_label, installing);
            if (installing) return;
            const on_frame = self.options.on_frame orelse return;
            const gpu_frame = runtime.gpuSurfaceFrame(frame_event.window_id, self.options.canvas_label) catch return;
            if (on_frame(&self.model, gpu_frame)) |msg| {
                try self.dispatch(runtime, frame_event.window_id, msg);
            }
        }

        /// A presented frame for one of the declared secondary windows:
        /// install its tree on the first frame (the same choreography as
        /// the main canvas — build, hand the layout to the runtime, emit
        /// the display list), then present through the shared planner
        /// buffers. Frames for labels no window owns are ignored.
        fn handleWindowSlotFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            const slot = self.windowSlotByCanvasLabel(frame_event.label) orelse return;
            slot.window_id = frame_event.window_id;
            const scale = normalizedSurfaceScale(frame_event.scale_factor);
            var installing = false;
            if (!slot.installed) {
                installing = true;
                slot.canvas_size = frame_event.size;
                slot.pixel_snap_scale = scale;
                try self.rebuildWindowSlot(runtime, slot);
                _ = try runtime.emitCanvasWidgetDisplayList(slot.window_id, slot.canvasLabel(), runtime.tokensWithTextMeasure(self.slotEffectiveTokens(slot)));
                slot.installed = true;
            } else if (@abs(slot.pixel_snap_scale - scale) > 0.001) {
                // THIS window moved to a different density (the main
                // canvas may still be on its old monitor): adopt the
                // slot's scale and rebuild so the re-emit inside
                // `rebuildWindowSlot` re-snaps this window's hairlines —
                // static-token apps included, because the stored copy
                // holds the stale scale (`rebuildEmitsTokens`).
                slot.pixel_snap_scale = scale;
                try self.rebuildWindowSlot(runtime, slot);
            } else if (frame_event.size.width != slot.canvas_size.width or
                frame_event.size.height != slot.canvas_size.height)
            {
                // The slot's drawable resized before its resize event
                // landed (the same live-resize gap the main canvas
                // closes above): adopt the presented size and rebuild so
                // dispatch-driven rebuilds never lay this window out at
                // stale bounds.
                slot.canvas_size = frame_event.size;
                try self.rebuildWindowSlot(runtime, slot);
            } else if (runtime.registeredCanvasFontCount() != self.fonts_built_count) {
                // Late registration, first observed on a secondary
                // window's frame (registration requests frames for every
                // open surface, and arrival order is the platform's):
                // the same all-surfaces rebuild as the main canvas —
                // the count is app-level, so whichever surface's frame
                // lands first re-measures all of them.
                try self.rebuildForRegisteredFonts(runtime);
            }
            try self.presentFrame(runtime, frame_event, slot.canvasLabel(), installing);
        }

        /// A face joined the runtime's font registry after this app's
        /// trees were built: rebuild EVERY installed surface — main
        /// canvas and declared secondary windows — so widget frames and
        /// baked text runs re-measure against the registered face, then
        /// adopt the count. Rebuild re-emits each surface's display list
        /// (`rebuildEmitsTokens` treats a text-measure provider change
        /// as an emit reason), so the repaint the runtime already
        /// requested draws re-measured geometry, not re-inked stale
        /// frames.
        fn rebuildForRegisteredFonts(self: *Self, runtime: *Runtime) anyerror!void {
            try self.rebuildAllViews(runtime);
            // Adopt the count only AFTER the rebuild succeeded:
            // production dispatch degrades errors, so a failed rebuild
            // (widget budget, allocator pressure, a secondary window's
            // emit) that had already adopted the count would mark stale
            // layouts as font-current and never retry. Left unadopted,
            // the error leaves the count mismatched and the next
            // presented frame retries the rebuild.
            self.fonts_built_count = runtime.registeredCanvasFontCount();
        }

        /// Present the planned canvas frame: GPU packet when the platform
        /// has a packet presenter (macOS/Metal — unchanged), otherwise the
        /// CPU reference-rendered pixel path (`presentGpuSurfacePixels`,
        /// e.g. Linux/GTK). A platform whose packet presenter exists but
        /// reports `UnsupportedService` at present time also falls back to
        /// pixels; that attempt forces a full repaint because the failed
        /// packet plan already recorded the frame's presented summary.
        fn presentFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent, canvas_label: []const u8, installing: bool) anyerror!void {
            // The installing frame must paint unconditionally: on software
            // platforms with no window-manager-driven resizes, nothing else
            // invalidates before the first present, and the surface would
            // stay blank until the first input arrives.
            const services = runtime.options.platform.services;
            const clear_color = self.effectiveTokens().colors.background;
            var packet_attempted = false;
            if (services.present_gpu_surface_packet_fn != null or services.present_gpu_surface_packet_binary_fn != null) {
                packet_attempted = true;
                const packet_presented = blk: {
                    _ = runtime.presentNextCanvasGpuPacketWithScale(
                        frame_event.window_id,
                        canvas_label,
                        .{
                            .frame_index = frame_event.frame_index,
                            .timestamp_ns = frame_event.timestamp_ns,
                            .surface_size = frame_event.size,
                            .scale = frame_event.scale_factor,
                            .full_repaint = frame_event.canvas_frame_full_repaint or installing,
                        },
                        runtime.canvasFrameScratchStorage(),
                        clear_color,
                        &self.gpu_commands,
                        &self.packet_bytes,
                        null,
                    ) catch |err| switch (err) {
                        error.UnsupportedService => break :blk false,
                        else => return err,
                    };
                    break :blk true;
                };
                if (packet_presented) return;
            }
            if (services.present_gpu_surface_pixels_fn == null) return;
            self.ensurePixelBuffers(frame_event.size, frame_event.scale_factor) catch return;
            _ = runtime.presentNextCanvasFramePixels(
                frame_event.window_id,
                canvas_label,
                .{
                    .frame_index = frame_event.frame_index,
                    .timestamp_ns = frame_event.timestamp_ns,
                    .surface_size = frame_event.size,
                    .scale = frame_event.scale_factor,
                    .full_repaint = frame_event.canvas_frame_full_repaint or packet_attempted or installing,
                },
                runtime.canvasFrameScratchStorage(),
                self.pixel_buffer,
                self.pixel_scratch,
                clear_color,
            ) catch |err| switch (err) {
                error.UnsupportedService, error.UnsupportedViewKind => {},
                else => return err,
            };
        }

        /// Grow the heap pixel buffers to hold the surface at the given
        /// scale. No-op when they are already large enough.
        fn ensurePixelBuffers(self: *Self, surface_size: geometry.SizeF, scale_factor: f32) anyerror!void {
            const pixel_size = try canvas_frame.canvasSurfacePixelSize(surface_size, scale_factor);
            if (self.pixel_buffer.len < pixel_size.byte_len) {
                if (self.pixel_buffer.len > 0) self.backing.free(self.pixel_buffer);
                self.pixel_buffer = &.{};
                self.pixel_buffer = try self.backing.alloc(u8, pixel_size.byte_len);
            }
            if (self.pixel_scratch.len < pixel_size.byte_len) {
                if (self.pixel_scratch.len > 0) self.backing.free(self.pixel_scratch);
                self.pixel_scratch = &.{};
                self.pixel_scratch = try self.backing.alloc(u8, pixel_size.byte_len);
            }
        }

        fn normalizedSurfaceScale(scale_factor: f32) f32 {
            if (!std.math.isFinite(scale_factor) or scale_factor <= 0) return 1;
            return scale_factor;
        }

        /// Change-detection hashes for the model-derived tray state:
        /// field lengths are folded in so adjacent slices can
        /// never alias across boundaries.
        fn hashTrayTitle(title: []const u8) u64 {
            var hasher = std.hash.Wyhash.init(0x7261795f7469746c); // "ray_titl"
            hasher.update(title);
            return hasher.final();
        }

        fn hashTrayMenu(items: []const platform.TrayMenuItem) u64 {
            var hasher = std.hash.Wyhash.init(0x7261795f6d656e75); // "ray_menu"
            hasher.update(std.mem.asBytes(&items.len));
            for (items) |item| {
                hasher.update(std.mem.asBytes(&item.id));
                hasher.update(std.mem.asBytes(&item.label.len));
                hasher.update(item.label);
                hasher.update(std.mem.asBytes(&item.command.len));
                hasher.update(item.command);
                hasher.update(&.{ @intFromBool(item.separator), @intFromBool(item.enabled) });
            }
            return hasher.final();
        }

        fn handleResize(self: *Self, runtime: *Runtime, resize_event: platform.GpuSurfaceResizeEvent) anyerror!void {
            // Resize events carry the surface density alongside the frame:
            // a move to a different-DPI monitor can arrive as a resize
            // whose LOGICAL size is unchanged (the OS rescales the frame),
            // so the scale must be adopted BEFORE the rebuild below — the
            // rebuild's re-emit then stamps freshly-snapped tokens, and
            // `rebuildEmitsTokens` sees the stored copy's stale scale and
            // forces the emission even when nothing else changed.
            if (!std.mem.eql(u8, resize_event.label, self.options.canvas_label)) {
                const slot = self.windowSlotByCanvasLabel(resize_event.label) orelse return;
                slot.canvas_size = .{ .width = resize_event.frame.width, .height = resize_event.frame.height };
                slot.pixel_snap_scale = normalizedSurfaceScale(resize_event.scale_factor);
                if (slot.installed) try self.rebuildWindowSlot(runtime, slot);
                return;
            }
            self.canvas_size = .{ .width = resize_event.frame.width, .height = resize_event.frame.height };
            self.pixel_snap_scale = normalizedSurfaceScale(resize_event.scale_factor);
            if (!self.installed) return;
            // Fullscreen transitions resize the canvas AND flip the
            // chrome overlay insets (macOS hides the titlebar band and
            // traffic lights); re-query on every resize and dispatch
            // only on change — `dispatch` already rebuilds, so the
            // plain-resize rebuild is the else arm.
            if (self.chromeInsetsMsg(runtime, resize_event.window_id)) |msg| {
                try self.dispatch(runtime, resize_event.window_id, msg);
                return;
            }
            try self.rebuild(runtime, resize_event.window_id);
        }

        /// Layout insets for the main canvas: the runtime's viewport
        /// chrome, minus the safe-area share when the app subscribed to
        /// `on_chrome`. A chrome subscriber owns safe-area padding — the
        /// same contract the macOS hidden-titlebar band delivers over the
        /// identical channel — so mobile surfaces hand it the notch,
        /// status bar, and home indicator bands instead of pre-insetting
        /// layout (which would pad the same band twice). The keyboard is
        /// input avoidance, not chrome: the runtime keeps insetting by
        /// its residual overlap beyond the safe area, so a padded app's
        /// effective clearance still totals max(safe, keyboard) per edge.
        fn layoutViewportInsets(self: *const Self, runtime: *const Runtime, window_id: platform.WindowId) geometry.InsetsF {
            const combined = runtime.viewportInsetsForWindow(window_id);
            if (self.options.on_chrome == null) return combined;
            const safe = runtime.safeAreaInsetsForWindow(window_id);
            return .{
                .top = @max(combined.top - safe.top, 0),
                .right = @max(combined.right - safe.right, 0),
                .bottom = @max(combined.bottom - safe.bottom, 0),
                .left = @max(combined.left - safe.left, 0),
            };
        }

        /// The `on_chrome` delivery gate: query the platform's chrome
        /// overlay geometry for the canvas window and map it to a Msg
        /// when the app subscribed AND the geometry actually changed.
        fn chromeInsetsMsg(self: *Self, runtime: *Runtime, window_id: platform.WindowId) ?MsgT {
            const map = self.options.on_chrome orelse return null;
            const chrome = runtime.options.platform.services.windowChrome(window_id);
            if (self.window_chrome_known and std.meta.eql(chrome, self.window_chrome)) return null;
            self.window_chrome = chrome;
            self.window_chrome_known = true;
            return map(chrome);
        }

        /// Typed press dispatch resolves through the press target — the
        /// deepest widget on the hit path that claims presses — so a press
        /// on a pressable row's plain text children lands on the row's
        /// `on_press`, and a release that ended a text-selection drag
        /// (press_target = null) presses nothing. Press targets with an
        /// `on_hold` handler additionally arm the hold timer on `.down`;
        /// a fired hold suppresses the release's press (one gesture, one
        /// Msg), and any release/cancel disarms it.
        fn handlePointer(self: *Self, runtime: *Runtime, pointer_event: core.CanvasWidgetPointerEvent) anyerror!void {
            const tree = self.treeForViewLabel(pointer_event.view_label) orelse return;
            switch (pointer_event.pointer.phase) {
                .down => {
                    self.disarmHold(runtime);
                    if (pointer_event.press_target) |target| {
                        if (tree.hasHoldHandler(target.id)) {
                            self.hold_armed_id = target.id;
                            self.hold_fired = false;
                            // One pointer, one gesture — but it can be
                            // in any window: remember whose tree armed
                            // it so the fire resolves the right handler
                            // table and window identity.
                            const label_len = @min(pointer_event.view_label.len, self.hold_view_label_storage.len);
                            @memcpy(self.hold_view_label_storage[0..label_len], pointer_event.view_label[0..label_len]);
                            self.hold_view_label_len = label_len;
                            self.hold_window_id = pointer_event.window_id;
                            runtime.startTimer(press_hold_timer_id, press_hold_duration_ns, false) catch {};
                        }
                    }
                },
                .up, .cancel => {
                    const suppressed = self.hold_fired;
                    self.disarmHold(runtime);
                    if (suppressed) return;
                },
                else => {},
            }
            // A pointer gesture that performed a text edit (the search
            // field's built-in clear) maps to the field's `on_input`
            // Msg — the runtime already applied the edit; the model
            // hears it here so a source-owned buffer clears too.
            if (pointer_event.edit) |edit| {
                if (pointer_event.target) |edit_target| {
                    if (tree.msgForTextEdit(edit_target.id, edit)) |msg| {
                        try self.dispatch(runtime, pointer_event.window_id, msg);
                    }
                }
            }
            const target = pointer_event.press_target orelse return;
            // A released press on a synthesized fallback menu item is a
            // context-menu selection, not an ordinary press: it resolves
            // through the target's `.context_menu` handler entry and
            // closes the surface.
            if (pointer_event.pointer.phase == .up) {
                if (try self.dispatchContextMenuFallbackItem(runtime, tree, pointer_event.window_id, target.id)) return;
            }
            // The click count rides the release into typed dispatch: a
            // double-click's second release resolves the target's
            // `on_double_press` handler (falling back to the ordinary
            // press), while its first release already dispatched the
            // single press — select-then-act, the list convention.
            if (tree.msgForPointerClick(target.id, pointer_event.pointer.phase, pointer_event.pointer.click_count)) |msg| {
                try self.dispatch(runtime, pointer_event.window_id, msg);
            }
        }

        fn disarmHold(self: *Self, runtime: *Runtime) void {
            if (self.hold_armed_id != 0 and !self.hold_fired) runtime.cancelTimer(press_hold_timer_id) catch {};
            self.hold_armed_id = 0;
            self.hold_fired = false;
        }

        /// The hold timer fired while the press is still down: dispatch
        /// the armed widget's `on_hold` Msg — through the tree that
        /// armed it, main canvas or a declared window's — and remember
        /// that this gesture consumed its press.
        fn firePressHold(self: *Self, runtime: *Runtime) anyerror!void {
            const armed_id = self.hold_armed_id;
            if (armed_id == 0 or self.hold_fired) return;
            const hold_label = self.hold_view_label_storage[0..self.hold_view_label_len];
            const tree = self.treeForViewLabel(hold_label) orelse return;
            self.hold_fired = true;
            if (tree.msgForHold(armed_id)) |msg| {
                try self.dispatch(runtime, self.hold_window_id, msg);
            }
        }

        /// A dismissible surface was dismissed (Escape, click outside,
        /// automation/accessibility dismiss): the model owns the close
        /// through the surface's `on_dismiss` Msg. The engine already hid
        /// the surface as an optimistic echo; this dispatch makes the
        /// model agree (or deliberately re-open on the next rebuild —
        /// source wins).
        fn handleDismiss(self: *Self, runtime: *Runtime, dismiss_event: core.CanvasWidgetDismissEvent) anyerror!void {
            const tree = self.treeForViewLabel(dismiss_event.view_label) orelse return;
            // The synthesized fallback menu surface has no app-declared
            // on_dismiss (its open state lives here, not in the model):
            // close the state and rebuild, agreeing with the engine's
            // optimistic hide.
            if (self.context_menu_fallback_target != 0) {
                if (tree.context_menu_fallback) |fallback| {
                    if (fallback.surface_id == dismiss_event.id) {
                        self.clearContextMenuFallback();
                        try self.rebuildAllViews(runtime);
                        return;
                    }
                }
            }
            if (tree.msgForDismiss(dismiss_event.id)) |msg| {
                try self.dispatch(runtime, dismiss_event.window_id, msg);
            }
        }

        /// A secondary click with no context menu anywhere on its route:
        /// the desktop press-and-hold alternative — dispatch the press
        /// target's `on_hold` Msg immediately.
        fn handleContextPress(self: *Self, runtime: *Runtime, press_event: core.CanvasWidgetContextPressEvent) anyerror!void {
            const tree = self.treeForViewLabel(press_event.view_label) orelse return;
            const target = press_event.press_target orelse return;
            if (tree.msgForHold(target.id)) |msg| {
                try self.dispatch(runtime, press_event.window_id, msg);
            }
        }

        fn handleKeyboard(self: *Self, runtime: *Runtime, keyboard_event: core.CanvasWidgetKeyboardEvent) anyerror!void {
            const tree = self.treeForViewLabel(keyboard_event.view_label) orelse return;
            // Key precedence, top to bottom — the focused widget always
            // outranks the app-level fallback:
            //   1. a focused widget's bound handler consumes the key
            //      (space on a focused track row plays THAT row);
            //   2. a focused widget that structurally answers the key —
            //      a control intent it maps, or any editable text
            //      widget, where typing must stay typing (checked by
            //      widget KIND, never by whether a handler is bound) —
            //      consumes it silently;
            //   3. only an unclaimed key_down falls through to
            //      `Options.on_key` (a target-less event — nothing
            //      focused — skips straight here).
            if (keyboard_event.target) |target| {
                // Keyboard activation (Enter/Space) of a synthesized fallback
                // menu item is a context-menu selection, same as the pointer
                // path.
                if (self.context_menu_fallback_target != 0) {
                    if (tree.findWidget(target.id)) |widget| {
                        if (canvas.widgetKeyboardControlIntent(widget, keyboard_event.keyboard)) |intent| {
                            if (intent.kind == .press or intent.kind == .select) {
                                if (try self.dispatchContextMenuFallbackItem(runtime, tree, keyboard_event.window_id, target.id)) return;
                            }
                        }
                    }
                }
                if (tree.msgForKeyboard(target.id, keyboard_event.keyboard)) |msg| {
                    try self.dispatch(runtime, keyboard_event.window_id, msg);
                    return;
                }
                if (tree.findWidget(target.id)) |widget| {
                    if (!widget.state.disabled) {
                        if (canvas.isWidgetTextEntry(widget)) return;
                        if (canvas.widgetKeyboardControlIntent(widget, keyboard_event.keyboard) != null) return;
                    }
                }
            }
            const map = self.options.on_key orelse return;
            if (keyboard_event.keyboard.phase != .key_down) return;
            if (map(keyboard_event.keyboard)) |msg| {
                try self.dispatch(runtime, keyboard_event.window_id, msg);
            }
        }

        /// Trackpad pinch reaches the app as the view-global gesture
        /// channel (`Options.on_pinch`): only the pinch kinds of the raw
        /// gpu-surface input surface here — every other raw input kind
        /// stays runtime-internal (widgets and the semantic Msg surface
        /// already carry it). The Msg dispatch rides the same journaled
        /// input event, so a recorded pinch replays to the identical
        /// model.
        fn handlePinch(self: *Self, runtime: *Runtime, input_event: platform.GpuSurfaceInputEvent) anyerror!void {
            const map = self.options.on_pinch orelse return;
            const phase: platform.PinchPhase = switch (input_event.kind) {
                .pinch_begin => .begin,
                .pinch_change => .change,
                .pinch_end => .end,
                else => return,
            };
            if (map(.{
                .window_id = input_event.window_id,
                .label = input_event.label,
                .phase = phase,
                .scale = input_event.scale,
                .x = input_event.x,
                .y = input_event.y,
            })) |msg| {
                try self.dispatch(runtime, input_event.window_id, msg);
            }
        }

        /// Split-fraction changes route through the split's `on_resize`
        /// constructor. The payload is the fraction the runtime already
        /// applied, so a model that stores it and echoes it back into
        /// `value` never fights the split reconcile rule.
        fn handleWidgetResize(self: *Self, runtime: *Runtime, resize_event: core.CanvasWidgetResizeEvent) anyerror!void {
            const tree = self.treeForViewLabel(resize_event.view_label) orelse return;
            if (tree.msgForResize(resize_event.id, resize_event.fraction)) |msg| {
                try self.dispatch(runtime, resize_event.window_id, msg);
            }
        }

        /// Slider value changes from pointer gestures (rail click, scrub
        /// drag) route through the slider's `on_value`/`on_change`
        /// handler. The payload is the value the runtime already applied
        /// (the optimistic echo), and `dispatch` runs the `sync` hook
        /// before update — so a model that mirrors slider state through
        /// `sync` reads the applied value first and its update arm acts
        /// on it, the same contract keyboard slider steps follow.
        fn handleWidgetChange(self: *Self, runtime: *Runtime, change_event: core.CanvasWidgetChangeEvent) anyerror!void {
            const tree = self.treeForViewLabel(change_event.view_label) orelse return;
            if (tree.msgForChange(change_event.id, change_event.value)) |msg| {
                try self.dispatch(runtime, change_event.window_id, msg);
            }
        }

        /// Scroll offset changes route through the scroll container's
        /// `on_scroll` constructor. The payload is the offset the runtime
        /// already applied, so a model that stores it and echoes it back
        /// into `value` never fights the scroll reconcile rule.
        ///
        /// Two ride-alongs per scroll observation:
        /// - `on_reach_end` fires through the approach-end hysteresis
        ///   (`reachEndShouldFire`) — the infinite-scroll fetch signal.
        /// - A windowed virtual list re-derives the view even with no
        ///   Msg bound: its window follows the runtime-owned offset, so
        ///   the scroll itself is the rebuild trigger (main canvas only,
        ///   where the window source is installed).
        fn handleScroll(self: *Self, runtime: *Runtime, scroll_event: core.CanvasWidgetScrollEvent) anyerror!void {
            const tree = self.treeForViewLabel(scroll_event.view_label) orelse return;
            var rebuilt = false;
            if (tree.msgForScroll(scroll_event.id, scroll_event.scroll)) |msg| {
                try self.dispatch(runtime, scroll_event.window_id, msg);
                rebuilt = true;
            }
            if (tree.msgForReachEnd(scroll_event.id)) |msg| {
                if (self.reachEndShouldFire(scroll_event.id, scroll_event.scroll)) {
                    try self.dispatch(runtime, scroll_event.window_id, msg);
                    rebuilt = true;
                }
            }
            if (tree.msgForReachStart(scroll_event.id)) |msg| {
                if (self.reachStartShouldFire(scroll_event.id, scroll_event.scroll)) {
                    try self.dispatch(runtime, scroll_event.window_id, msg);
                    rebuilt = true;
                }
            }
            if (!rebuilt and self.installed and
                std.mem.eql(u8, scroll_event.view_label, self.options.canvas_label) and
                self.isVirtualWindowId(scroll_event.id))
            {
                try self.rebuild(runtime, scroll_event.window_id);
            }
        }

        /// A native context-menu selection: resolve the selected
        /// item's declared `Msg` through the tree's handler table.
        fn handleContextMenu(self: *Self, runtime: *Runtime, menu_event: core.CanvasWidgetContextMenuEvent) anyerror!void {
            const tree = self.treeForViewLabel(menu_event.view_label) orelse return;
            // A selection on this menu closes it whatever the source: an
            // automation-invoked selection while the fallback surface is
            // open must not leave the surface mounted.
            if (self.context_menu_fallback_target == menu_event.target_id) {
                self.clearContextMenuFallback();
            }
            if (tree.msgForContextMenu(menu_event.target_id, menu_event.item_index)) |msg| {
                try self.dispatch(runtime, menu_event.window_id, msg);
            }
        }

        /// The platform could not present a declared context menu
        /// natively: open the anchored-surface fallback — record which
        /// widget's menu is open and rebuild, so `Ui.finalize` mounts the
        /// same declared items as an anchored canvas surface on the
        /// target.
        fn handleContextMenuRequest(self: *Self, runtime: *Runtime, request_event: core.CanvasWidgetContextMenuRequestEvent) anyerror!void {
            const label_len = @min(request_event.view_label.len, self.context_menu_fallback_label_storage.len);
            @memcpy(self.context_menu_fallback_label_storage[0..label_len], request_event.view_label[0..label_len]);
            self.context_menu_fallback_label_len = label_len;
            self.context_menu_fallback_window_id = request_event.window_id;
            self.context_menu_fallback_target = request_event.target_id;
            try self.rebuildAllViews(runtime);
        }

        fn contextMenuFallbackLabel(self: *const Self) []const u8 {
            return self.context_menu_fallback_label_storage[0..self.context_menu_fallback_label_len];
        }

        /// The fallback target `Ui.finalize` should mount for a view
        /// being rebuilt, or 0 when the open fallback (if any) belongs to
        /// a different view.
        fn contextMenuFallbackTargetForLabel(self: *const Self, view_label: []const u8) canvas.ObjectId {
            if (self.context_menu_fallback_target == 0) return 0;
            if (!std.mem.eql(u8, view_label, self.contextMenuFallbackLabel())) return 0;
            return self.context_menu_fallback_target;
        }

        fn clearContextMenuFallback(self: *Self) void {
            self.context_menu_fallback_target = 0;
            self.context_menu_fallback_label_len = 0;
        }

        /// Rebuild every open view without a Msg dispatch — the fallback
        /// menu's open state lives here, not in the model, so opening and
        /// closing it re-derives the views directly.
        fn rebuildAllViews(self: *Self, runtime: *Runtime) anyerror!void {
            if (!self.installed) return;
            try self.rebuild(runtime, self.canvas_window_id);
            try self.rebuildWindowSlots(runtime);
        }

        /// A pointer press or keyboard activation resolved to one of the
        /// fallback surface's synthesized items: close the surface and
        /// dispatch through `msgForContextMenu` — the SAME handler entry
        /// a native selection resolves. Returns true when the id was a
        /// fallback item (consumed either way).
        fn dispatchContextMenuFallbackItem(self: *Self, runtime: *Runtime, tree: *const Ui.Tree, window_id: platform.WindowId, id: canvas.ObjectId) anyerror!bool {
            if (self.context_menu_fallback_target == 0) return false;
            const fallback = tree.context_menu_fallback orelse return false;
            const item_index = fallback.itemIndex(id) orelse return false;
            self.clearContextMenuFallback();
            if (tree.msgForContextMenu(fallback.target_id, item_index)) |msg| {
                try self.dispatch(runtime, window_id, msg);
            } else {
                try self.rebuildAllViews(runtime);
            }
            return true;
        }
    };
}

/// Window-action resolvers for the effects channel's
/// `WindowActionBinding` (`Effects.closeWindow`/`minimizeWindow`): apps
/// address windows by their declared LABEL (`ShellWindow.label`,
/// `WindowDescriptor.label`), and these resolve the label against the
/// runtime's live window table at call time — a closed or never-opened
/// label is honestly a no-op. Loop-thread only, like every effect call.
fn effectsWindowIdByLabel(runtime: *Runtime, window_label: []const u8) ?platform.WindowId {
    var buffer: [platform.max_windows]platform.WindowInfo = undefined;
    for (runtime.listWindows(&buffer)) |info| {
        if (info.open and std.mem.eql(u8, info.label, window_label)) return info.id;
    }
    return null;
}

fn effectsCloseWindowByLabel(context: *anyopaque, window_label: []const u8) bool {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const window_id = effectsWindowIdByLabel(runtime, window_label) orelse return false;
    // The runtime's own close: bookkeeping flips before the platform
    // call, exactly like a reconcile close — see `Runtime.closeWindow`.
    runtime.closeWindow(window_id) catch return false;
    return true;
}

fn effectsMinimizeWindowByLabel(context: *anyopaque, window_label: []const u8) bool {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const window_id = effectsWindowIdByLabel(runtime, window_label) orelse return false;
    runtime.minimizeWindow(window_id) catch return false;
    return true;
}
