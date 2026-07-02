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

        pub const Options = struct {
            name: []const u8,
            scene: app_manifest.ShellConfig,
            canvas_label: []const u8,
            tokens: canvas.DesignTokens = .{},
            update: *const fn (model: *ModelT, msg: MsgT) void,
            view: *const fn (ui: *Ui, model: *const ModelT) Ui.Node,
            /// Optional mapping from shell command events (menus, shortcuts,
            /// native controls) into messages.
            on_command: ?*const fn (name: []const u8) ?MsgT = null,
        };

        model: ModelT,
        options: Options,
        arenas: [2]std.heap.ArenaAllocator,
        arena_index: usize = 0,
        tree: ?Ui.Tree = null,
        canvas_size: geometry.SizeF = .{ .width = 1, .height = 1 },
        installed: bool = false,
        gpu_commands: [canvas_limits.max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined,
        packet_json: [platform.max_gpu_surface_packet_json_bytes]u8 = undefined,

        pub fn init(backing: std.mem.Allocator, model: ModelT, options: Options) Self {
            return .{
                .model = model,
                .options = options,
                .arenas = .{
                    std.heap.ArenaAllocator.init(backing),
                    std.heap.ArenaAllocator.init(backing),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.arenas[0].deinit();
            self.arenas[1].deinit();
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
            const tree = try ui.finalizeWithTokens(self.options.view(&ui, &self.model), self.options.tokens);

            var nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined;
            const bounds = geometry.RectF.init(0, 0, self.canvas_size.width, self.canvas_size.height);
            const layout = try canvas.layoutWidgetTree(tree.root, bounds, &nodes);
            _ = try runtime.setCanvasWidgetLayout(window_id, self.options.canvas_label, layout);

            self.tree = tree;
            self.arena_index = next_index;
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
                .gpu_surface_frame => |frame_event| try self.handleFrame(runtime, frame_event),
                .gpu_surface_resized => |resize_event| try self.handleResize(runtime, resize_event),
                .canvas_widget_pointer => |pointer_event| try self.handlePointer(runtime, pointer_event),
                .canvas_widget_keyboard => |keyboard_event| try self.handleKeyboard(runtime, keyboard_event),
                else => {},
            }
        }

        fn handleFrame(self: *Self, runtime: *Runtime, frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            if (!std.mem.eql(u8, frame_event.label, self.options.canvas_label)) return;
            if (!self.installed) {
                self.canvas_size = frame_event.size;
                try self.rebuild(runtime, frame_event.window_id);
                _ = try runtime.emitCanvasWidgetDisplayList(frame_event.window_id, self.options.canvas_label, self.options.tokens);
                self.installed = true;
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
