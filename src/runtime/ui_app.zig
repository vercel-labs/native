//! Runtime-owned application loop for the declarative ui builder.
//!
//! `UiApp(Model, Msg)` wraps an elm-style app — model value, `update`
//! function, `view` function — as a `zero_native.App`, owning everything the
//! builder examples previously hand-rolled: the two-arena rebuild swap, the
//! first-frame install choreography (`setCanvasWidgetLayout` +
//! `emitCanvasWidgetDisplayList`), presentation buffers, resize handling,
//! and typed pointer/keyboard dispatch through the tree's handler table.
//!
//! An app becomes: declare `Model` and `Msg`, write `update` and `view`,
//! and hand them to `UiApp` with a shell scene containing one `gpu_surface`
//! view. Shell command events can map into messages through `on_command`.
//!
//! Markup apps choose an engine per build: `Options.markup` runs the
//! runtime parser/interpreter (dev, hot reload), while
//! `canvas.CompiledMarkupView(Model, Msg, source).build` handed to
//! `Options.view` compiles the same source at comptime (release, no parser
//! in the binary — pair with `UiAppWithFeatures(..., .{ .runtime_markup =
//! false })` so the watch machinery compiles out too). Setting both keeps
//! the compiled view until the watched file first changes on disk.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const core = @import("core.zig");
const canvas_frame = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_effects = @import("effects.zig");

const Runtime = core.Runtime;
const App = core.App;
const Event = core.Event;

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

        /// The app's effect system (TEA's Cmd half): `fx.spawn` /
        /// `fx.cancel` from an `update_fx`-style update. See
        /// `runtime/effects.zig` for capacities and semantics.
        pub const Effects = runtime_effects.Effects(MsgT);

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

        pub const MarkupOptions = struct {
            /// Markup source embedded into the binary: parsed on the first
            /// build when no `view` is set, and otherwise the baseline the
            /// watched file is compared against. (Release builds should
            /// prefer `canvas.CompiledMarkupView(...).build` on `view`,
            /// which parses at comptime instead.)
            source: []const u8,
            /// Optional file to poll in dev: when its content changes the
            /// file is re-parsed and the next rebuild uses the new view,
            /// keeping model state. Parse failures keep the last good view
            /// and set `markup_diagnostic`. Requires `io`. Watching runs a
            /// low-cost repeating runtime timer (`markup_watch_timer_id`),
            /// so leave it unset in release builds.
            watch_path: ?[]const u8 = null,
            io: ?std.Io = null,
        };

        pub const Options = struct {
            name: []const u8,
            scene: app_manifest.ShellConfig,
            canvas_label: []const u8,
            tokens: canvas.DesignTokens = .{},
            /// Model-derived design tokens. When set, this is consulted on
            /// every install and rebuild instead of the static `tokens`,
            /// and `pixel_snap.scale` is stamped with the live surface
            /// scale afterwards: the model owns scheme/contrast/motion,
            /// the runtime owns the surface scale.
            tokens_fn: ?*const fn (model: *const ModelT) canvas.DesignTokens = null,
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
            /// Optional mapping from shell command events (menus, shortcuts,
            /// native controls) into messages.
            on_command: ?*const fn (name: []const u8) ?MsgT = null,
            /// Optional mapping from runtime timer events (started via
            /// `runtime.startTimer`) into messages. Framework-reserved timer
            /// ids (>= `platform.reserved_timer_id_base`) are handled
            /// internally and never reach this callback.
            on_timer: ?*const fn (id: u64, timestamp_ns: u64) ?MsgT = null,
            /// Optional mapping from system appearance changes into
            /// messages so the model can own color scheme, contrast, and
            /// reduce-motion state (and `tokens_fn` can derive from it).
            on_appearance: ?*const fn (appearance: platform.Appearance) ?MsgT = null,
            /// Optional mapping from presented gpu frames (carrying the
            /// renderer diagnostics the runtime recorded) into messages.
            /// Called after presenting every frame except the installing
            /// one.
            on_frame: ?*const fn (model: *const ModelT, frame: platform.GpuFrame) ?MsgT = null,
            /// Reads runtime-owned widget state (slider values, scroll
            /// offsets) back into the model before update and rebuild so
            /// the next source tree does not stomp it.
            sync: ?*const fn (model: *ModelT, layout: canvas.WidgetLayoutTree) void = null,
        };

        model: ModelT,
        options: Options,
        arenas: [2]std.heap.ArenaAllocator,
        arena_index: usize = 0,
        tree: ?Ui.Tree = null,
        canvas_size: geometry.SizeF = .{ .width = 1, .height = 1 },
        canvas_window_id: platform.WindowId = 1,
        installed: bool = false,
        pixel_snap_scale: f32 = 1,
        frame_timestamp_ns: u64 = 0,
        markup_arenas: [2]std.heap.ArenaAllocator,
        markup_arena_index: usize = 0,
        markup_view: ?MarkupView = null,
        markup_source_hash: u64 = 0,
        /// Set when the embedded or watched markup failed to parse or build;
        /// cleared on the next successful parse. Apps may render it.
        markup_diagnostic: ?canvas.ui_markup.MarkupErrorInfo = null,
        layout_nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined,
        gpu_commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined,
        packet_json: [platform.max_gpu_surface_packet_json_bytes]u8 = undefined,
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

        pub fn init(backing: std.mem.Allocator, model: ModelT, options: Options) Self {
            std.debug.assert(options.view != null or options.markup != null);
            std.debug.assert((options.update != null) != (options.update_fx != null));
            if (comptime !features.runtime_markup) std.debug.assert(options.markup == null);
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
                .effects = Effects.init(backing),
            };
        }

        pub fn deinit(self: *Self) void {
            self.effects.deinit();
            self.arenas[0].deinit();
            self.arenas[1].deinit();
            self.markup_arenas[0].deinit();
            self.markup_arenas[1].deinit();
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
            };
        }

        /// Apply a message and rebuild the widget tree. Runtime-owned
        /// widget state is synced into the model first so `update` sees
        /// current slider values and scroll offsets.
        pub fn dispatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId, msg: MsgT) anyerror!void {
            self.effects.bindServices(&runtime.options.platform.services);
            self.effects.bindEnviron(runtime.options.environ);
            self.syncModel(runtime, window_id);
            self.applyMsg(msg);
            try self.rebuild(runtime, window_id);
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
            self.effects.bindServices(&runtime.options.platform.services);
            self.effects.bindEnviron(runtime.options.environ);
            self.syncModel(runtime, self.canvas_window_id);
            var dispatched = false;
            while (self.effects.takeMsg()) |msg| {
                self.applyMsg(msg);
                dispatched = true;
            }
            if (dispatched) try self.rebuild(runtime, self.canvas_window_id);
        }

        /// The design tokens for the next rebuild: static `tokens`, or the
        /// model-derived `tokens_fn` with the surface scale stamped into
        /// `pixel_snap.scale`.
        pub fn effectiveTokens(self: *const Self) canvas.DesignTokens {
            const tokens_fn = self.options.tokens_fn orelse return self.options.tokens;
            var tokens = tokens_fn(&self.model);
            tokens.pixel_snap.scale = self.pixel_snap_scale;
            return tokens;
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
        pub fn rebuild(self: *Self, runtime: *Runtime, window_id: platform.WindowId) anyerror!void {
            self.syncModel(runtime, window_id);
            const tokens = runtime.tokensWithTextMeasure(self.effectiveTokens());
            const next_index = self.arena_index ^ 1;
            _ = self.arenas[next_index].reset(.retain_capacity);
            var ui = Ui.init(self.arenas[next_index].allocator());
            const node = try self.buildViewNode(&ui);
            const tree = try ui.finalizeWithTokens(node, tokens);

            // Widget layout is inset by the runtime's viewport chrome
            // (safe areas + keyboard on mobile, zero on desktop); the
            // canvas itself stays surface-sized so chrome and the clear
            // color still paint edge to edge under notches and bars.
            const bounds = geometry.RectF.fromSize(self.canvas_size).deflate(runtime.viewportInsetsForWindow(window_id));
            const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, &self.layout_nodes);

            if (self.options.chrome) |chrome| {
                try self.installChromeDisplayList(runtime, window_id, chrome, layout, tokens);
            } else {
                _ = try runtime.setCanvasWidgetLayout(window_id, self.options.canvas_label, layout);
                if (self.installed and self.options.tokens_fn != null) {
                    _ = try runtime.emitCanvasWidgetDisplayList(window_id, self.options.canvas_label, tokens);
                }
            }

            self.tree = tree;
            self.arena_index = next_index;
            try self.scheduleAnimations(runtime, window_id);
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
                            self.markup_diagnostic = .{
                                .line = view.diagnostic.line,
                                .column = view.diagnostic.column,
                                .message = view.diagnostic.message,
                            };
                        }
                        return err;
                    };
                }
            }
            const view = self.options.view.?;
            return view(ui, &self.model);
        }

        /// Parse and activate a markup source (the reload seam: hot reload
        /// and tests go through this). Failures keep the previous view and
        /// set `markup_diagnostic`.
        pub fn reloadMarkup(self: *Self, source: []const u8) anyerror!void {
            if (comptime !features.runtime_markup) return error.MarkupEngineDisabled;
            const next_index = self.markup_arena_index ^ 1;
            _ = self.markup_arenas[next_index].reset(.retain_capacity);
            const arena = self.markup_arenas[next_index].allocator();
            const owned_source = try arena.dupe(u8, source);
            var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
            const view = MarkupView.initDiagnostic(arena, owned_source, &diagnostic) catch |err| {
                if (err == error.MarkupSyntax) self.markup_diagnostic = diagnostic;
                return err;
            };
            self.markup_view = view;
            self.markup_arena_index = next_index;
            self.markup_source_hash = std.hash.Wyhash.hash(0, source);
            self.markup_diagnostic = null;
        }

        /// Dev-mode hot reload: start the repeating runtime timer that polls
        /// the watched markup file. Runs once, on first install, and only
        /// when a watch path and io are configured.
        fn startMarkupWatch(self: *Self, runtime: *Runtime) void {
            if (comptime !features.runtime_markup) return;
            const markup_options = self.options.markup orelse return;
            if (markup_options.watch_path == null or markup_options.io == null) return;
            // With a compiled `view` also set, the embedded source is the
            // baseline: the interpreter only takes over once the watched
            // file diverges from it.
            if (self.options.view != null and self.markup_source_hash == 0) {
                self.markup_source_hash = std.hash.Wyhash.hash(0, markup_options.source);
            }
            runtime.startTimer(markup_watch_timer_id, markup_watch_interval_ns, true) catch {};
        }

        /// Timer-driven poll of the watched markup file: re-parse when its
        /// content changes. A failed parse keeps the last good view running
        /// and records the diagnostic. A successful reload rebuilds, which
        /// invalidates the canvas and schedules the presenting frame.
        fn pollMarkupWatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId) void {
            if (comptime !features.runtime_markup) return;
            const markup_options = self.options.markup orelse return;
            const watch_path = markup_options.watch_path orelse return;
            const io = markup_options.io orelse return;

            var buffer: [256 * 1024]u8 = undefined;
            const source = readWatchedFile(io, watch_path, &buffer) catch return;
            const hash = std.hash.Wyhash.hash(0, source);
            if (hash == self.markup_source_hash) return;
            self.reloadMarkup(source) catch {
                self.markup_source_hash = hash;
                return;
            };
            if (self.installed) self.rebuild(runtime, window_id) catch {};
        }

        /// Reserved framework timer id for the markup watch poll. Application
        /// timer ids must stay below `platform.reserved_timer_id_base`.
        pub const markup_watch_timer_id: u64 = platform.reserved_timer_id_base | 0x2e70_a11c;
        const markup_watch_interval_ns: u64 = 500 * std.time.ns_per_ms;

        fn readWatchedFile(io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
            var file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            return buffer[0..try file.readPositionalAll(io, buffer, 0)];
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
                        try self.dispatch(runtime, command.window_id, msg);
                    }
                },
                .appearance_changed => |appearance| {
                    const map = self.options.on_appearance orelse return;
                    if (map(appearance)) |msg| {
                        try self.dispatch(runtime, self.canvas_window_id, msg);
                    }
                },
                .timer => |timer_event| try self.handleTimer(runtime, timer_event),
                .effects_wake => try self.drainEffects(runtime),
                .gpu_surface_frame => |frame_event| try self.handleFrame(runtime, frame_event),
                .gpu_surface_resized => |resize_event| try self.handleResize(runtime, resize_event),
                .canvas_widget_pointer => |pointer_event| try self.handlePointer(runtime, pointer_event),
                .canvas_widget_keyboard => |keyboard_event| try self.handleKeyboard(runtime, keyboard_event),
                else => {},
            }
        }

        fn handleTimer(self: *Self, runtime: *Runtime, timer_event: platform.TimerEvent) anyerror!void {
            if (timer_event.id == markup_watch_timer_id) {
                self.pollMarkupWatch(runtime, self.canvas_window_id);
                return;
            }
            if (timer_event.id >= platform.reserved_timer_id_base) return;
            const map = self.options.on_timer orelse return;
            if (map(timer_event.id, timer_event.timestamp_ns)) |msg| {
                try self.dispatch(runtime, self.canvas_window_id, msg);
            }
        }

        fn handleFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            if (!std.mem.eql(u8, frame_event.label, self.options.canvas_label)) return;
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
                try self.rebuild(runtime, frame_event.window_id);
                if (self.options.chrome == null) {
                    _ = try runtime.emitCanvasWidgetDisplayList(frame_event.window_id, self.options.canvas_label, runtime.tokensWithTextMeasure(self.effectiveTokens()));
                }
                self.installed = true;
                self.startMarkupWatch(runtime);
            } else if (self.options.tokens_fn != null and @abs(self.pixel_snap_scale - scale) > 0.001) {
                self.pixel_snap_scale = scale;
                try self.rebuild(runtime, frame_event.window_id);
            }
            try self.presentFrame(runtime, frame_event, installing);
            if (installing) return;
            const on_frame = self.options.on_frame orelse return;
            const gpu_frame = runtime.gpuSurfaceFrame(frame_event.window_id, self.options.canvas_label) catch return;
            if (on_frame(&self.model, gpu_frame)) |msg| {
                try self.dispatch(runtime, frame_event.window_id, msg);
            }
        }

        /// Present the planned canvas frame: GPU packet when the platform
        /// has a packet presenter (macOS/Metal — unchanged), otherwise the
        /// CPU reference-rendered pixel path (`presentGpuSurfacePixels`,
        /// e.g. Linux/GTK). A platform whose packet presenter exists but
        /// reports `UnsupportedService` at present time also falls back to
        /// pixels; that attempt forces a full repaint because the failed
        /// packet plan already recorded the frame's presented summary.
        fn presentFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent, installing: bool) anyerror!void {
            // The installing frame must paint unconditionally: on software
            // platforms with no window-manager-driven resizes, nothing else
            // invalidates before the first present, and the surface would
            // stay blank until the first input arrives.
            const services = runtime.options.platform.services;
            const clear_color = self.effectiveTokens().colors.background;
            var packet_attempted = false;
            if (services.present_gpu_surface_packet_fn != null) {
                packet_attempted = true;
                const packet_presented = blk: {
                    _ = runtime.presentNextCanvasGpuPacketWithScale(
                        frame_event.window_id,
                        self.options.canvas_label,
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
                        &self.packet_json,
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
                self.options.canvas_label,
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

        fn handleResize(self: *Self, runtime: *Runtime, resize_event: platform.GpuSurfaceResizeEvent) anyerror!void {
            if (!std.mem.eql(u8, resize_event.label, self.options.canvas_label)) return;
            self.canvas_size = .{ .width = resize_event.frame.width, .height = resize_event.frame.height };
            if (self.installed) try self.rebuild(runtime, resize_event.window_id);
        }

        fn handlePointer(self: *Self, runtime: *Runtime, pointer_event: core.CanvasWidgetPointerEvent) anyerror!void {
            if (!std.mem.eql(u8, pointer_event.view_label, self.options.canvas_label)) return;
            const tree = self.tree orelse return;
            const target = pointer_event.target orelse return;
            if (tree.msgForPointer(target.id, pointer_event.pointer.phase)) |msg| {
                try self.dispatch(runtime, pointer_event.window_id, msg);
            }
        }

        fn handleKeyboard(self: *Self, runtime: *Runtime, keyboard_event: core.CanvasWidgetKeyboardEvent) anyerror!void {
            if (!std.mem.eql(u8, keyboard_event.view_label, self.options.canvas_label)) return;
            const tree = self.tree orelse return;
            const target = keyboard_event.target orelse return;
            if (tree.msgForKeyboard(target.id, keyboard_event.keyboard)) |msg| {
                try self.dispatch(runtime, keyboard_event.window_id, msg);
            }
        }
    };
}
