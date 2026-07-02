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

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const core = @import("core.zig");
const canvas_limits = @import("canvas_limits.zig");

const Runtime = core.Runtime;
const App = core.App;
const Event = core.Event;

pub fn UiApp(comptime ModelT: type, comptime MsgT: type) type {
    return struct {
        const Self = @This();

        pub const Ui = canvas.Ui(MsgT);

        pub const MarkupView = canvas.MarkupView(ModelT, MsgT);

        pub const MarkupOptions = struct {
            /// Markup source compiled into the binary (release, and the
            /// fallback until the watch path parses).
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
            update: *const fn (model: *ModelT, msg: MsgT) void,
            /// Hand-written view. Exactly one of `view` and `markup` must be
            /// set.
            view: ?*const fn (ui: *Ui, model: *const ModelT) Ui.Node = null,
            /// Markup view. Exactly one of `view` and `markup` must be set.
            markup: ?MarkupOptions = null,
            /// Optional mapping from shell command events (menus, shortcuts,
            /// native controls) into messages.
            on_command: ?*const fn (name: []const u8) ?MsgT = null,
            /// Optional mapping from runtime timer events (started via
            /// `runtime.startTimer`) into messages. Framework-reserved timer
            /// ids (>= `platform.reserved_timer_id_base`) are handled
            /// internally and never reach this callback.
            on_timer: ?*const fn (id: u64, timestamp_ns: u64) ?MsgT = null,
        };

        model: ModelT,
        options: Options,
        arenas: [2]std.heap.ArenaAllocator,
        arena_index: usize = 0,
        tree: ?Ui.Tree = null,
        canvas_size: geometry.SizeF = .{ .width = 1, .height = 1 },
        canvas_window_id: platform.WindowId = 1,
        installed: bool = false,
        markup_arenas: [2]std.heap.ArenaAllocator,
        markup_arena_index: usize = 0,
        markup_view: ?MarkupView = null,
        markup_source_hash: u64 = 0,
        /// Set when the embedded or watched markup failed to parse or build;
        /// cleared on the next successful parse. Apps may render it.
        markup_diagnostic: ?canvas.ui_markup.MarkupErrorInfo = null,
        gpu_commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined,
        packet_json: [platform.max_gpu_surface_packet_json_bytes]u8 = undefined,

        pub fn init(backing: std.mem.Allocator, model: ModelT, options: Options) Self {
            std.debug.assert((options.view == null) != (options.markup == null));
            return .{
                .model = model,
                .options = options,
                .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
                .markup_arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.arenas[0].deinit();
            self.arenas[1].deinit();
            self.markup_arenas[0].deinit();
            self.markup_arenas[1].deinit();
        }

        pub fn app(self: *Self) App {
            return .{
                .context = self,
                .name = self.options.name,
                .scene_fn = sceneFn,
                .event_fn = eventFn,
            };
        }

        /// Apply a message and rebuild the widget tree.
        pub fn dispatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId, msg: MsgT) anyerror!void {
            self.options.update(&self.model, msg);
            try self.rebuild(runtime, window_id);
        }

        /// Rebuild the widget tree from the model and hand it to the
        /// runtime, which copies and reconciles it. The previous tree's
        /// arena stays alive until the following rebuild so the handler
        /// table remains valid between events.
        pub fn rebuild(self: *Self, runtime: *Runtime, window_id: platform.WindowId) anyerror!void {
            const next_index = self.arena_index ^ 1;
            _ = self.arenas[next_index].reset(.retain_capacity);
            var ui = Ui.init(self.arenas[next_index].allocator());
            const node = try self.buildViewNode(&ui);
            const tree = try ui.finalizeWithTokens(node, self.options.tokens);

            var nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined;
            const bounds = geometry.RectF.init(0, 0, self.canvas_size.width, self.canvas_size.height);
            const layout = try canvas.layoutWidgetTree(tree.root, bounds, &nodes);
            _ = try runtime.setCanvasWidgetLayout(window_id, self.options.canvas_label, layout);

            self.tree = tree;
            self.arena_index = next_index;
        }

        fn buildViewNode(self: *Self, ui: *Ui) anyerror!Ui.Node {
            if (self.options.view) |view| return view(ui, &self.model);
            const view = &(self.markup_view orelse blk: {
                try self.reloadMarkup(self.options.markup.?.source);
                break :blk self.markup_view.?;
            });
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

        /// Parse and activate a markup source (the reload seam: hot reload
        /// and tests go through this). Failures keep the previous view and
        /// set `markup_diagnostic`.
        pub fn reloadMarkup(self: *Self, source: []const u8) anyerror!void {
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
            const markup_options = self.options.markup orelse return;
            if (markup_options.watch_path == null or markup_options.io == null) return;
            runtime.startTimer(markup_watch_timer_id, markup_watch_interval_ns, true) catch {};
        }

        /// Timer-driven poll of the watched markup file: re-parse when its
        /// content changes. A failed parse keeps the last good view running
        /// and records the diagnostic. A successful reload rebuilds, which
        /// invalidates the canvas and schedules the presenting frame.
        fn pollMarkupWatch(self: *Self, runtime: *Runtime, window_id: platform.WindowId) void {
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
                .timer => |timer_event| try self.handleTimer(runtime, timer_event),
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
            self.canvas_window_id = frame_event.window_id;
            if (!self.installed) {
                self.canvas_size = frame_event.size;
                try self.rebuild(runtime, frame_event.window_id);
                _ = try runtime.emitCanvasWidgetDisplayList(frame_event.window_id, self.options.canvas_label, self.options.tokens);
                self.installed = true;
                self.startMarkupWatch(runtime);
            }
            _ = runtime.presentNextCanvasGpuPacketWithScale(
                frame_event.window_id,
                self.options.canvas_label,
                .{
                    .frame_index = frame_event.frame_index,
                    .timestamp_ns = frame_event.timestamp_ns,
                    .surface_size = frame_event.size,
                    .scale = frame_event.scale_factor,
                    .full_repaint = frame_event.canvas_frame_full_repaint,
                },
                runtime.canvasFrameScratchStorage(),
                self.options.tokens.colors.background,
                &self.gpu_commands,
                &self.packet_json,
                null,
            ) catch |err| switch (err) {
                error.UnsupportedService => {},
                else => return err,
            };
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
