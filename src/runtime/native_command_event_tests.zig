const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const trace = support.trace;
const json = support.json;
const canvas = support.canvas;
const automation = support.automation;
const bridge = support.bridge;
const app_manifest = support.app_manifest;
const platform = support.platform;
const security = support.security;
const extensions = support.extensions;
const window_state = support.window_state;
const runtime_module = support.runtime_module;
const bridge_payload = support.bridge_payload;
const canvas_frame = support.canvas_frame;
const App = support.App;
const Runtime = support.Runtime;
const Options = support.Options;
const Event = support.Event;
const LifecycleEvent = support.LifecycleEvent;
const CommandEvent = support.CommandEvent;
const Command = support.Command;
const CommandSource = support.CommandSource;
const FrameDiagnostics = support.FrameDiagnostics;
const ShortcutEvent = support.ShortcutEvent;
const Appearance = support.Appearance;
const GpuFrame = support.GpuFrame;
const GpuSurfaceFrameEvent = support.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = support.GpuSurfaceResizeEvent;
const GpuSurfaceInputEvent = support.GpuSurfaceInputEvent;
const CanvasWidgetPointerEvent = support.CanvasWidgetPointerEvent;
const CanvasWidgetKeyboardEvent = support.CanvasWidgetKeyboardEvent;
const CanvasWidgetDisplayListChrome = support.CanvasWidgetDisplayListChrome;
const CanvasPresentationMode = support.CanvasPresentationMode;
const CanvasPresentationResult = support.CanvasPresentationResult;
const CanvasWidgetAccessibilityActionKind = support.CanvasWidgetAccessibilityActionKind;
const CanvasWidgetAccessibilityAction = support.CanvasWidgetAccessibilityAction;
const CanvasWidgetFileDropEvent = support.CanvasWidgetFileDropEvent;
const CanvasWidgetDragEvent = support.CanvasWidgetDragEvent;
const InvalidationReason = support.InvalidationReason;
const TestHarness = support.TestHarness;
const max_canvas_commands_per_view = support.max_canvas_commands_per_view;
const max_canvas_widget_nodes_per_view = support.max_canvas_widget_nodes_per_view;
const jsonStringField = support.jsonStringField;
const jsonNumberField = support.jsonNumberField;
const jsonBoolField = support.jsonBoolField;
const canvasRenderAnimationFinalOverrideNoop = support.canvasRenderAnimationFinalOverrideNoop;
const copyInto = support.copyInto;
const writeViewJson = support.writeViewJson;
const canvasFrameScratchStorage = support.canvasFrameScratchStorage;
const runtimeViewInfo = support.runtimeViewInfo;
const runtimeViewCanvasFrameRenderOverrides = support.runtimeViewCanvasFrameRenderOverrides;
const runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides = support.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides;
const runtimeViewWidgetSemantics = support.runtimeViewWidgetSemantics;
const runtimeViewSetCanvasWidgetSelected = support.runtimeViewSetCanvasWidgetSelected;
const runtimeViewCanvasWidgetDirtyBounds = support.runtimeViewCanvasWidgetDirtyBounds;
const dispatchAutomationWidgetAction = support.dispatchAutomationWidgetAction;
const shellBoundsForWindow = support.shellBoundsForWindow;
const reloadWindows = support.reloadWindows;
const canvasWidgetSemanticsById = support.canvasWidgetSemanticsById;
const platformWidgetAccessibilityNodeById = support.platformWidgetAccessibilityNodeById;
const builtinBridgeErrorCode = support.builtinBridgeErrorCode;
const builtinBridgeErrorMessage = support.builtinBridgeErrorMessage;
const testViewByLabel = support.testViewByLabel;
const testCanvasWidgetPartId = support.testCanvasWidgetPartId;

test "runtime dispatches native view command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-command", .source = platform.WebViewSource.html("<p>Native</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                    self.last_view_label = command.view_label;
                },
                else => {},
            }
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "refresh-button",
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqualStrings("refresh-button", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 48),
    });
    _ = try harness.runtime.createView(.{
        .label = "toolbar-refresh",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
        .command = "app.refresh",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "toolbar-refresh",
    } });

    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar-refresh", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "toolbar-stack",
        .kind = .stack,
        .parent = "toolbar",
        .frame = geometry.RectF.init(112, 8, 160, 32),
    });
    _ = try harness.runtime.createView(.{
        .label = "toolbar-nested-refresh",
        .kind = .button,
        .parent = "toolbar-stack",
        .frame = geometry.RectF.init(0, 0, 120, 28),
        .command = "app.refresh",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "toolbar-nested-refresh",
    } });

    try std.testing.expectEqual(@as(u32, 3), app_state.command_count);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar-nested-refresh", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "sidebar",
        .kind = .sidebar,
        .frame = geometry.RectF.init(0, 48, 220, 400),
    });
    _ = try harness.runtime.createView(.{
        .label = "filters",
        .kind = .stack,
        .parent = "sidebar",
        .frame = geometry.RectF.init(16, 16, 160, 120),
    });
    _ = try harness.runtime.createView(.{
        .label = "filter-toggle",
        .kind = .toggle,
        .parent = "filters",
        .frame = geometry.RectF.init(0, 0, 120, 28),
        .command = "app.filter.toggle",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.filter.toggle",
        .window_id = 1,
        .view_label = "filter-toggle",
    } });

    try std.testing.expectEqual(@as(u32, 4), app_state.command_count);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqualStrings("filter-toggle", app_state.last_view_label);
}

test "runtime exposes configured command catalog" {
    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
    };
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.runtime.options.commands = &commands;

    var output: [4]Command = undefined;
    const listed = harness.runtime.listCommands(&output);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("app.refresh", listed[0].id);
    try std.testing.expectEqualStrings("Refresh", listed[0].title);
    try std.testing.expect(listed[0].enabled);
    try std.testing.expectEqualStrings("app.sidebar.toggle", listed[1].id);
    try std.testing.expect(listed[1].checked);

    var narrow_output: [1]Command = undefined;
    const narrow = harness.runtime.listCommands(&narrow_output);
    try std.testing.expectEqual(@as(usize, 1), narrow.len);
    try std.testing.expectEqualStrings("app.refresh", narrow[0].id);
}

test "runtime dispatches menu command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "menu-command", .source = platform.WebViewSource.html("<p>Menu</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                },
                else => {},
            }
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .menu_command = .{
        .name = "app.refresh",
        .window_id = 1,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.menu, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
}

test "runtime dispatches tray item commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_tray_item_id: platform.TrayItemId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "tray-command", .source = platform.WebViewSource.html("<p>Tray</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_tray_item_id = command.tray_item_id;
                },
                else => {},
            }
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.createTray(.{ .items = &.{
        .{ .id = 7, .label = "Refresh", .command = "app.refresh" },
        .{ .id = 8, .label = "Legacy" },
    } });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = 7 });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.tray, app_state.last_source);
    try std.testing.expectEqual(@as(platform.TrayItemId, 7), app_state.last_tray_item_id);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = 8 });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("tray.action", app_state.last_name);
    try std.testing.expectEqual(@as(platform.TrayItemId, 8), app_state.last_tray_item_id);

    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{
        .{ .id = 9, .label = "One", .command = "app.one" },
        .{ .id = 9, .label = "Two" },
    }));
    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{.{ .label = "Missing id", .command = "app.missing-id" }}));
}

test "runtime dispatches file drop events to app and window bridge" {
    const TestApp = struct {
        drop_count: u32 = 0,
        last_window_id: platform.WindowId = 0,
        last_paths: []const []const u8 = &.{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "file-drop", .source = platform.WebViewSource.html("<p>Drops</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .files_dropped => |drop| {
                    self.drop_count += 1;
                    self.last_window_id = drop.window_id;
                    self.last_paths = drop.paths;
                },
                else => {},
            }
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const dropped_paths = [_][]const u8{ "/tmp/one\nname.txt", "/tmp/two.txt" };
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .files_dropped = .{
        .window_id = 1,
        .paths = &dropped_paths,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.drop_count);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_paths.len);
    try std.testing.expectEqualStrings("/tmp/one\nname.txt", app_state.last_paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.txt", app_state.last_paths[1]);
    try std.testing.expectEqualStrings("drop:files", harness.null_platform.lastWindowEventName());
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/one\\nname.txt\",\"/tmp/two.txt\"]") != null);
}

test "runtime routes file drops to retained canvas widget targets" {
    const TestApp = struct {
        drop_count: u32 = 0,
        widget_drop_count: u32 = 0,
        last_widget_target_id: canvas.ObjectId = 0,
        last_widget_route_len: usize = 0,
        last_widget_path_count: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "canvas-widget-file-drop", .source = platform.WebViewSource.html("<p>Drops</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_file_drop => |drop| {
                    self.widget_drop_count += 1;
                    self.last_widget_target_id = if (drop.target) |target| target.id else 0;
                    self.last_widget_route_len = drop.route.len;
                    self.last_widget_path_count = drop.drop.paths.len;
                },
                .files_dropped => self.drop_count += 1,
                else => {},
            }
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const drop_children = [_]canvas.Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 80, 32),
        .text = "Upload",
    }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .row,
        .frame = geometry.RectF.init(16, 16, 140, 52),
        .semantics = .{ .actions = .{ .drop_files = true } },
        .children = &drop_children,
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const dropped_paths = [_][]const u8{ "/tmp/card.png", "/tmp/copy.txt" };
    try harness.runtime.dispatchPlatformEvent(app, .{ .files_dropped = .{
        .window_id = 1,
        .view_label = "canvas",
        .point = geometry.PointF.init(28, 28),
        .paths = &dropped_paths,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_drop_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.drop_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_widget_target_id);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_widget_route_len);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_widget_path_count);
    try std.testing.expectEqualStrings("drop:files", harness.null_platform.lastWindowEventName());
    const detail = harness.null_platform.lastWindowEventDetail();
    try std.testing.expect(std.mem.indexOf(u8, detail, "\"viewLabel\":\"canvas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "\"x\":28") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "\"paths\":[\"/tmp/card.png\",\"/tmp/copy.txt\"]") != null);
}
