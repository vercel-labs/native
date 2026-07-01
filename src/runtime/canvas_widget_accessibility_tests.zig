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

test "runtime automation snapshot exposes canvas list roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-list-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(20, 30, 240, 160),
    });

    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Inbox" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Archive" },
    };
    const list = canvas.Widget{
        .id = 1,
        .kind = .list,
        .text = "Mailboxes",
        .layout = .{ .gap = 4 },
        .children = &rows,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 3), snapshot.widgets.len);
    try std.testing.expectEqual(@as(u64, 1), snapshot.widgets[0].id);
    try std.testing.expectEqualStrings("list", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Mailboxes", snapshot.widgets[0].name);
    try std.testing.expect(snapshot.widgets[0].parent_id == null);
    try std.testing.expectEqualDeep(geometry.RectF.init(20, 30, 240, 160), snapshot.widgets[0].bounds);
    try std.testing.expectEqualStrings("listitem", snapshot.widgets[1].role);
    try std.testing.expectEqualStrings("Inbox", snapshot.widgets[1].name);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.widgets[1].parent_id);
    try std.testing.expectEqualDeep(geometry.RectF.init(20, 30, 240, 32), snapshot.widgets[1].bounds);
    try std.testing.expect(snapshot.widgets[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), snapshot.widgets[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), snapshot.widgets[1].list.item_count);
    try std.testing.expectEqualStrings("listitem", snapshot.widgets[2].role);
    try std.testing.expectEqualStrings("Archive", snapshot.widgets[2].name);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.widgets[2].parent_id);
    try std.testing.expect(snapshot.widgets[2].list.present);
    try std.testing.expectEqual(@as(u32, 1), snapshot.widgets[2].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), snapshot.widgets[2].list.item_count);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=list name=\"Mailboxes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=listitem name=\"Inbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "parent=#1") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "list=[index=0,count=2]") != null);
}

test "runtime preserves virtualized list item semantics" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-virtual-list-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 160),
    });

    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Four" },
        .{ .id = 7, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Five" },
        .{ .id = 8, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Six" },
        .{ .id = 9, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Seven" },
        .{ .id = 10, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Eight" },
        .{ .id = 11, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Nine" },
    };
    const list = canvas.Widget{
        .id = 1,
        .kind = .list,
        .text = "Mailboxes",
        .value = 45,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &rows,
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 240, 50), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(usize, 6), retained.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), retained.nodes[0].widget.children.len);
    try std.testing.expectEqual(@as(usize, 0), retained.nodes[3].widget.children.len);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 6), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].virtual_range.present);
    try std.testing.expectEqual(@as(u32, 0), snapshot.widgets[0].virtual_range.start_index);
    try std.testing.expectEqual(@as(u32, 5), snapshot.widgets[0].virtual_range.end_index);
    try std.testing.expectEqual(@as(u32, 1), snapshot.widgets[0].virtual_range.first_visible_index);
    try std.testing.expectEqual(@as(u32, 3), snapshot.widgets[0].virtual_range.last_visible_index);
    try std.testing.expectEqual(@as(u32, 5), snapshot.widgets[0].virtual_range.rendered_count);
    try std.testing.expectEqual(@as(u64, 4), snapshot.widgets[3].id);
    try std.testing.expect(snapshot.widgets[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), snapshot.widgets[3].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), snapshot.widgets[3].list.item_count);
    try std.testing.expectEqual(@as(u64, 6), snapshot.widgets[5].id);
    try std.testing.expect(snapshot.widgets[5].list.present);
    try std.testing.expectEqual(@as(u32, 4), snapshot.widgets[5].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), snapshot.widgets[5].list.item_count);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#4 role=listitem name=\"Two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "virtual=[start=0,end=5,first=1,last=3,rendered=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "list=[index=2,count=10]") != null);
}

test "runtime automation snapshot exposes canvas data grid roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-data-grid-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(20, 30, 320, 180),
    });

    const header_cells = [_]canvas.Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]canvas.Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &row_cells },
    };
    const grid = canvas.Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(grid, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 7), snapshot.widgets.len);
    try std.testing.expectEqualStrings("grid", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Deployments", snapshot.widgets[0].name);
    try std.testing.expect(snapshot.widgets[0].parent_id == null);
    try std.testing.expectEqualDeep(geometry.RectF.init(20, 30, 320, 180), snapshot.widgets[0].bounds);
    try std.testing.expect(snapshot.widgets[0].grid_row_index == null);
    try std.testing.expect(snapshot.widgets[0].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[0].grid_column_count);
    try std.testing.expectEqualStrings("row", snapshot.widgets[1].role);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.widgets[1].parent_id);
    try std.testing.expectEqual(@as(?usize, 0), snapshot.widgets[1].grid_row_index);
    try std.testing.expect(snapshot.widgets[1].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[1].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[1].grid_column_count);
    try std.testing.expectEqualStrings("gridcell", snapshot.widgets[2].role);
    try std.testing.expectEqualStrings("Project", snapshot.widgets[2].name);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.widgets[2].parent_id);
    try std.testing.expectEqualDeep(geometry.RectF.init(20, 30, 160, 28), snapshot.widgets[2].bounds);
    try std.testing.expectEqual(@as(?usize, 0), snapshot.widgets[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), snapshot.widgets[2].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[2].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[2].grid_column_count);
    try std.testing.expect(snapshot.widgets[2].actions.focus);
    try std.testing.expect(snapshot.widgets[2].actions.select);
    try std.testing.expect(!snapshot.widgets[2].actions.press);
    try std.testing.expectEqualStrings("gridcell", snapshot.widgets[5].role);
    try std.testing.expectEqualStrings("Edge API", snapshot.widgets[5].name);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.widgets[5].parent_id);
    try std.testing.expectEqualDeep(geometry.RectF.init(20, 60, 160, 28), snapshot.widgets[5].bounds);
    try std.testing.expectEqual(@as(?usize, 1), snapshot.widgets[5].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), snapshot.widgets[5].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[5].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.widgets[5].grid_column_count);
    try std.testing.expect(snapshot.widgets[5].actions.select);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=grid name=\"Deployments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#6 role=gridcell name=\"Edge API\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "grid=[row_index=1,column_index=0,row_count=2,column_count=2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,select]") != null);
}

test "runtime moves focused canvas data grid cells with arrow keys" {
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        last_target_id: canvas.ObjectId = 0,
        last_target_kind: canvas.WidgetKind = .stack,
        last_key: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-data-grid-navigation", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    self.last_key = keyboard_event.keyboard.key;
                    if (keyboard_event.target) |target| {
                        self.last_target_id = target.id;
                        self.last_target_kind = target.kind;
                    }
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(20, 30, 320, 180),
    });

    const header_cells = [_]canvas.Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]canvas.Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &row_cells },
    };
    const grid = canvas.Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(grid, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.data_cell, app_state.last_target_kind);
    try std.testing.expectEqualStrings("arrowright", app_state.last_key);

    const right_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!right_snapshot.widgets[2].focused);
    try std.testing.expect(right_snapshot.widgets[3].focused);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 6), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 6), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_target_id);
    try std.testing.expectEqual(@as(u32, 4), app_state.widget_keyboard_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_target_id);
    try std.testing.expectEqualStrings("end", app_state.last_key);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_target_id);
    try std.testing.expectEqualStrings("home", app_state.last_key);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .option = true },
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_target_id);
    try std.testing.expectEqual(@as(u32, 7), app_state.widget_keyboard_count);
}

test "runtime moves focused grouped canvas controls with arrow keys" {
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        last_target_id: canvas.ObjectId = 0,
        last_target_kind: canvas.WidgetKind = .stack,
        last_key: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-grouped-navigation", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    self.last_key = keyboard_event.keyboard.key;
                    if (keyboard_event.target) |target| {
                        self.last_target_id = target.id;
                        self.last_target_kind = target.kind;
                    }
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 360, 180),
    });

    const list_items = [_]canvas.Widget{
        .{ .id = 11, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 30), .text = "Inbox" },
        .{ .id = 12, .kind = .list_item, .frame = geometry.RectF.init(0, 36, 0, 30), .text = "Archive" },
    };
    const menu_items = [_]canvas.Widget{
        .{ .id = 21, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Rename" },
        .{ .id = 22, .kind = .menu_item, .frame = geometry.RectF.init(0, 34, 0, 28), .text = "Archive" },
    };
    const segment_items = [_]canvas.Widget{
        .{ .id = 31, .kind = .segmented_control, .frame = geometry.RectF.init(0, 0, 72, 30), .text = "List" },
        .{ .id = 32, .kind = .segmented_control, .frame = geometry.RectF.init(78, 0, 72, 30), .text = "Grid" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 10, .kind = .list, .frame = geometry.RectF.init(12, 12, 140, 72), .children = &list_items },
        .{ .id = 20, .kind = .menu_surface, .frame = geometry.RectF.init(180, 12, 140, 70), .children = &menu_items },
        .{ .id = 30, .kind = .row, .frame = geometry.RectF.init(12, 108, 150, 30), .children = &segment_items },
        .{ .id = 40, .kind = .button, .frame = geometry.RectF.init(220, 108, 96, 32), .text = "Run" },
    };
    var nodes: [12]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 360, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 11;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.list_item, app_state.last_target_kind);
    try std.testing.expectEqualStrings("arrowdown", app_state.last_key);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), app_state.last_target_id);
    try std.testing.expectEqualStrings("home", app_state.last_key);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), app_state.last_target_id);
    try std.testing.expectEqualStrings("end", app_state.last_key);

    harness.runtime.views[0].canvas_widget_focused_id = 21;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 22), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 22), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.menu_item, app_state.last_target_kind);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 21), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 21), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 22), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 22), app_state.last_target_id);

    harness.runtime.views[0].canvas_widget_focused_id = 31;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.segmented_control, app_state.last_target_kind);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 31), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 31), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), app_state.last_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), app_state.last_target_id);

    harness.runtime.views[0].canvas_widget_focused_id = 40;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 40), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 40), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.button, app_state.last_target_kind);
    try std.testing.expectEqual(@as(u32, 13), app_state.widget_keyboard_count);
}

test "runtime moves focus within shadcn grouped component controls" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-shadcn-group-navigation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 360, 280),
    });

    const button_group_buttons = [_]canvas.Widget{
        .{ .id = 11, .kind = .button, .text = "One" },
        .{ .id = 12, .kind = .button, .text = "Two" },
    };
    const pagination_buttons = [_]canvas.Widget{
        .{ .id = 21, .kind = .button, .text = "1" },
        .{ .id = 22, .kind = .button, .text = "2" },
        .{ .id = 23, .kind = .button, .text = "Next" },
    };
    const toggle_buttons = [_]canvas.Widget{
        .{ .id = 31, .kind = .toggle_button, .text = "B" },
        .{ .id = 32, .kind = .toggle_button, .text = "I" },
    };
    const tab_buttons = [_]canvas.Widget{
        .{ .id = 41, .kind = .segmented_control, .text = "Open" },
        .{ .id = 42, .kind = .segmented_control, .text = "Closed" },
    };
    const radio_buttons = [_]canvas.Widget{
        .{ .id = 51, .kind = .radio, .text = "Card" },
        .{ .id = 52, .kind = .radio, .text = "List" },
    };
    const top_children = [_]canvas.Widget{
        .{ .id = 10, .kind = .button_group, .frame = geometry.RectF.init(12, 12, 180, 34), .layout = builtinShadcnGroupLayout(), .children = &button_group_buttons },
        .{ .id = 20, .kind = .pagination, .frame = geometry.RectF.init(12, 56, 220, 34), .layout = builtinShadcnGroupLayout(), .children = &pagination_buttons },
        .{ .id = 30, .kind = .toggle_group, .frame = geometry.RectF.init(12, 100, 160, 34), .layout = builtinShadcnGroupLayout(), .children = &toggle_buttons },
        .{ .id = 40, .kind = .tabs, .frame = geometry.RectF.init(12, 144, 180, 34), .layout = builtinShadcnGroupLayout(), .children = &tab_buttons },
        .{ .id = 50, .kind = .radio_group, .frame = geometry.RectF.init(12, 188, 180, 34), .layout = builtinShadcnGroupLayout(), .children = &radio_buttons },
        .{ .id = 90, .kind = .button, .frame = geometry.RectF.init(248, 12, 84, 34), .text = "Alone" },
    };
    var nodes: [24]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &top_children }, geometry.RectF.init(0, 0, 360, 280), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 11;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 12), harness.runtime.views[0].canvas_widget_focused_id);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "home" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), harness.runtime.views[0].canvas_widget_focused_id);

    harness.runtime.views[0].canvas_widget_focused_id = 21;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "end" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 23), harness.runtime.views[0].canvas_widget_focused_id);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "home" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 21), harness.runtime.views[0].canvas_widget_focused_id);

    harness.runtime.views[0].canvas_widget_focused_id = 31;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 32), harness.runtime.views[0].canvas_widget_focused_id);

    harness.runtime.views[0].canvas_widget_focused_id = 41;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), harness.runtime.views[0].canvas_widget_focused_id);

    harness.runtime.views[0].canvas_widget_focused_id = 51;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 52), harness.runtime.views[0].canvas_widget_focused_id);

    harness.runtime.views[0].canvas_widget_focused_id = 90;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowleft" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 90), harness.runtime.views[0].canvas_widget_focused_id);
}

fn builtinShadcnGroupLayout() canvas.WidgetLayoutStyle {
    return .{ .gap = 4, .cross_alignment = .center };
}

test "runtime publishes canvas widget accessibility snapshots to platform" {
    const WidgetAccessibilityPlatform = struct {
        update_count: usize = 0,
        window_id: platform.WindowId = 0,
        view_label: [platform.max_view_label_bytes]u8 = undefined,
        view_label_len: usize = 0,
        nodes: [16]platform.WidgetAccessibilityNode = undefined,
        node_count: usize = 0,

        fn platformValue(self: *@This()) platform.Platform {
            return .{
                .context = self,
                .name = "widget-a11y",
                .surface_value = .{ .id = 1, .size = geometry.SizeF.init(320, 240), .scale_factor = 1 },
                .run_fn = run,
                .services = .{
                    .context = self,
                    .load_webview_fn = loadWebView,
                    .create_view_fn = createView,
                    .focus_view_fn = focusView,
                    .update_widget_accessibility_fn = updateWidgetAccessibility,
                },
            };
        }

        fn run(context: *anyopaque, handler: platform.EventHandler, handler_context: *anyopaque) anyerror!void {
            _ = context;
            _ = handler;
            _ = handler_context;
        }

        fn createView(context: ?*anyopaque, options: platform.ViewOptions) anyerror!void {
            _ = context;
            _ = options;
        }

        fn focusView(context: ?*anyopaque, window_id: platform.WindowId, label: []const u8) anyerror!void {
            _ = context;
            _ = window_id;
            _ = label;
        }

        fn loadWebView(context: ?*anyopaque, source: platform.WebViewSource) anyerror!void {
            _ = context;
            _ = source;
        }

        fn updateWidgetAccessibility(context: ?*anyopaque, snapshot: platform.WidgetAccessibilitySnapshot) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.update_count += 1;
            self.window_id = snapshot.window_id;
            self.view_label_len = (try copyInto(&self.view_label, snapshot.view_label)).len;
            self.node_count = @min(snapshot.nodes.len, self.nodes.len);
            for (snapshot.nodes[0..self.node_count], 0..) |node, index| {
                self.nodes[index] = node;
            }
        }
    };

    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-platform-a11y", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var platform_state: WidgetAccessibilityPlatform = .{};
    var runtime = Runtime.init(.{ .platform = platform_state.platformValue() });
    var app_state: TestApp = .{};
    try runtime.dispatchPlatformEvent(app_state.app(), .app_start);
    _ = try runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 160),
    });

    const header_cells = [_]canvas.Widget{
        .{ .id = 12, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 13, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]canvas.Widget{
        .{ .id = 15, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 16, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]canvas.Widget{
        .{ .id = 11, .kind = .data_row, .children = &header_cells },
        .{ .id = 14, .kind = .data_row, .children = &row_cells },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(12, 14, 96, 32), .text = "Deploy", .command = "deploy.run" },
        .{ .id = 3, .kind = .checkbox, .frame = geometry.RectF.init(12, 58, 120, 28), .text = "Preview", .state = .{ .selected = true } },
        .{ .id = 4, .kind = .text_field, .frame = geometry.RectF.init(12, 96, 160, 28), .text = "Search", .placeholder = "Search deployments", .text_selection = canvas.TextSelection{ .anchor = 1, .focus = 4 }, .text_composition = canvas.TextRange.init(2, 5), .state = .{ .required = true, .read_only = true, .invalid = true } },
        .{ .id = 5, .kind = .select, .frame = geometry.RectF.init(184, 96, 120, 28), .text = "Production", .state = .{ .expanded = false }, .semantics = .{ .label = "Environment" } },
        .{ .id = 10, .kind = .data_grid, .frame = geometry.RectF.init(12, 132, 220, 64), .text = "Deployments", .layout = .{ .gap = 2 }, .children = &rows },
    };
    var layout_nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 320, 160),
        .semantics = .{ .label = "Actions" },
        .children = &children,
    }, geometry.RectF.init(0, 0, 320, 160), &layout_nodes);
    _ = try runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expect(platform_state.update_count >= 1);
    try std.testing.expectEqual(@as(platform.WindowId, 1), platform_state.window_id);
    try std.testing.expectEqualStrings("canvas", platform_state.view_label[0..platform_state.view_label_len]);
    try std.testing.expectEqual(@as(usize, 12), platform_state.node_count);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.group, platform_state.nodes[0].role);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.button, platform_state.nodes[1].role);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.checkbox, platform_state.nodes[2].role);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.textbox, platform_state.nodes[3].role);
    const grid_node = platformWidgetAccessibilityNodeById(platform_state.nodes[0..platform_state.node_count], 10).?;
    const row_node = platformWidgetAccessibilityNodeById(platform_state.nodes[0..platform_state.node_count], 14).?;
    const cell_node = platformWidgetAccessibilityNodeById(platform_state.nodes[0..platform_state.node_count], 16).?;
    const text_node = platformWidgetAccessibilityNodeById(platform_state.nodes[0..platform_state.node_count], 4).?;
    const select_node = platformWidgetAccessibilityNodeById(platform_state.nodes[0..platform_state.node_count], 5).?;
    try std.testing.expectEqual(@as(?bool, false), select_node.expanded);
    try std.testing.expect(text_node.required);
    try std.testing.expect(text_node.read_only);
    try std.testing.expect(text_node.invalid);
    try std.testing.expect(!text_node.actions.set_text);
    try std.testing.expect(text_node.actions.set_selection);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.grid, grid_node.role);
    try std.testing.expectEqual(@as(?usize, 2), grid_node.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), grid_node.grid_column_count);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.row, row_node.role);
    try std.testing.expectEqual(@as(?usize, 1), row_node.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 2), row_node.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), row_node.grid_column_count);
    try std.testing.expectEqual(platform.WidgetAccessibilityRole.gridcell, cell_node.role);
    try std.testing.expectEqual(@as(?usize, 1), cell_node.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 1), cell_node.grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), cell_node.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), cell_node.grid_column_count);
    try std.testing.expectEqualStrings("Deploy", platform_state.nodes[1].label);
    try std.testing.expect(platform_state.nodes[1].actions.press);
    try std.testing.expect(platform_state.nodes[2].selected);
    try std.testing.expectEqualStrings("Search", platform_state.nodes[3].text_value);
    try std.testing.expectEqualStrings("Search deployments", platform_state.nodes[3].placeholder);
    try std.testing.expectEqualDeep(platform.WidgetAccessibilityTextRange{ .start = 1, .end = 4 }, platform_state.nodes[3].text_selection.?);
    try std.testing.expectEqualDeep(platform.WidgetAccessibilityTextRange{ .start = 2, .end = 5 }, platform_state.nodes[3].text_composition.?);
    try std.testing.expect(!platform_state.nodes[3].actions.set_text);
    try std.testing.expect(platform_state.nodes[3].actions.set_selection);
    try std.testing.expectEqual(@as(f32, 12), platform_state.nodes[1].bounds.x);
    try std.testing.expectEqual(@as(f32, 14), platform_state.nodes[1].bounds.y);

    const published_after_layout = platform_state.update_count;
    try runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .x = 20,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(published_after_layout, platform_state.update_count);

    const published_before_focus = platform_state.update_count;
    _ = try runtime.dispatchCanvasWidgetAccessibilityAction(app_state.app(), 1, "canvas", .{ .id = 2, .action = .focus });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(platform_state.update_count > published_before_focus);
    try std.testing.expect(platform_state.nodes[1].focused);

    try runtime.dispatchPlatformEvent(app_state.app(), .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 3,
        .action = .toggle,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(!platform_state.nodes[2].selected);

    try std.testing.expectError(error.InvalidCommand, runtime.dispatchPlatformEvent(app_state.app(), .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 4,
        .action = .set_text,
        .text = "Customer search",
    } }));
    try std.testing.expectEqualStrings("Search", platform_state.nodes[3].text_value);

    try runtime.dispatchPlatformEvent(app_state.app(), .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 4,
        .action = .set_selection,
        .selection = .{ .start = 3, .end = 11 },
    } });
    try std.testing.expectEqualDeep(platform.WidgetAccessibilityTextRange{ .start = 3, .end = 6 }, platform_state.nodes[3].text_selection.?);

    const scroll_items = [_]canvas.Widget{
        .{ .id = 22, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "One" },
        .{ .id = 23, .kind = .list_item, .frame = geometry.RectF.init(0, 44, 0, 28), .text = "Two" },
        .{ .id = 24, .kind = .list_item, .frame = geometry.RectF.init(0, 88, 0, 28), .text = "Three" },
    };
    const scroll_children = [_]canvas.Widget{
        .{ .id = 21, .kind = .scroll_view, .frame = geometry.RectF.init(16, 16, 140, 56), .children = &scroll_items },
    };
    var scroll_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const scroll_layout = try canvas.layoutWidgetTree(.{
        .id = 20,
        .kind = .panel,
        .children = &scroll_children,
    }, geometry.RectF.init(0, 0, 320, 160), &scroll_nodes);
    _ = try runtime.setCanvasWidgetLayout(1, "canvas", scroll_layout);
    _ = try runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const published_count = platform_state.update_count;

    try runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 32,
        .y = 32,
        .delta_y = 20,
    } });
    const scrolled_layout = try runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(scrolled_layout.findById(21).?.widget.value > 0);
    try std.testing.expectEqual(published_count, platform_state.update_count);
}

test "runtime automation snapshot exposes canvas icon roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-icon-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(24, 32, 160, 80),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .icon,
            .frame = geometry.RectF.init(8, 8, 24, 24),
            .text = "?",
            .semantics = .{ .label = "Help" },
        },
        .{
            .id = 3,
            .kind = .icon_button,
            .frame = geometry.RectF.init(40, 4, 32, 32),
            .text = "+",
            .semantics = .{ .label = "Add item" },
        },
    };
    const root = canvas.Widget{ .kind = .stack, .children = &children };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expectEqualStrings("image", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Help", snapshot.widgets[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(32, 40, 24, 24), snapshot.widgets[0].bounds);
    try std.testing.expectEqualStrings("button", snapshot.widgets[1].role);
    try std.testing.expectEqualStrings("Add item", snapshot.widgets[1].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(64, 36, 32, 32), snapshot.widgets[1].bounds);

    var a11y_buffer: [512]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=image name=\"Help\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#3 role=button name=\"Add item\"") != null);
}

test "runtime automation snapshot exposes canvas tooltip roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-tooltip-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(40, 50, 240, 160),
    });

    const tooltip = canvas.Widget{
        .id = 1,
        .kind = .tooltip,
        .frame = geometry.RectF.init(12, 16, 120, 28),
        .text = "Saved",
    };
    var nodes: [1]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tooltip, tooltip.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("tooltip", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Saved", snapshot.widgets[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(52, 66, 120, 28), snapshot.widgets[0].bounds);

    var a11y_buffer: [512]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=tooltip name=\"Saved\"") != null);
}

test "runtime automation snapshot exposes canvas popover dialog roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-popover-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(40, 50, 260, 180),
    });

    const actions = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 96, 32),
        .text = "Open",
    }};
    const popover = canvas.Widget{
        .id = 1,
        .kind = .popover,
        .frame = geometry.RectF.init(12, 16, 180, 120),
        .layout = .{ .padding = geometry.InsetsF.all(10) },
        .semantics = .{ .label = "Command palette" },
        .children = &actions,
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(popover, popover.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expectEqualStrings("dialog", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Command palette", snapshot.widgets[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(52, 66, 180, 120), snapshot.widgets[0].bounds);
    try std.testing.expectEqualStrings("button", snapshot.widgets[1].role);
    try std.testing.expectEqualStrings("Open", snapshot.widgets[1].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(62, 76, 96, 32), snapshot.widgets[1].bounds);

    var a11y_buffer: [512]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=dialog name=\"Command palette\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=button name=\"Open\"") != null);
}

test "runtime automation snapshot exposes canvas menu roles" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-menu-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(40, 50, 260, 180),
    });

    const items = [_]canvas.Widget{
        .{ .id = 2, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Rename" },
        .{ .id = 3, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Archive" },
    };
    const menu = canvas.Widget{
        .id = 1,
        .kind = .menu_surface,
        .frame = geometry.RectF.init(12, 16, 180, 90),
        .layout = .{ .padding = geometry.InsetsF.all(6), .gap = 2 },
        .semantics = .{ .label = "More actions" },
        .children = &items,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(menu, menu.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 3), snapshot.widgets.len);
    try std.testing.expectEqualStrings("menu", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("More actions", snapshot.widgets[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(52, 66, 180, 90), snapshot.widgets[0].bounds);
    try std.testing.expectEqualStrings("menuitem", snapshot.widgets[1].role);
    try std.testing.expectEqualStrings("Rename", snapshot.widgets[1].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(58, 72, 168, 28), snapshot.widgets[1].bounds);
    try std.testing.expectEqualStrings("menuitem", snapshot.widgets[2].role);
    try std.testing.expectEqualStrings("Archive", snapshot.widgets[2].name);

    var a11y_buffer: [4096]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=menu name=\"More actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=menuitem name=\"Rename\"") != null);
}

test "runtime invalidates canvas widget layout and semantics changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(50, 70, 320, 240),
    });

    const initial_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 80, 32),
        .text = "Run",
    }};
    var initial_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const initial = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &initial_children }, geometry.RectF.init(0, 0, 320, 240), &initial_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", initial);

    const moved_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(30, 10, 80, 32),
        .text = "Run",
    }};
    var moved_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const moved = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &moved_children }, geometry.RectF.init(0, 0, 320, 240), &moved_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", moved);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(59.5, 79.5, 101, 33), harness.runtime.pendingDirtyRegions()[0]);

    const renamed_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(30, 10, 80, 32),
        .text = "Run",
        .semantics = .{ .label = "Run report" },
    }};
    var renamed_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const renamed = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &renamed_children }, geometry.RectF.init(0, 0, 320, 240), &renamed_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", renamed);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime keeps unchanged canvas list semantics refresh clean" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-list-clean-refresh", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(20, 30, 260, 180),
    });

    const items = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 30), .text = "Inbox" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 30), .text = "Archive" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 30), .text = "Drafts" },
    };
    const list = canvas.Widget{
        .id = 1,
        .kind = .list,
        .frame = geometry.RectF.init(10, 12, 180, 120),
        .layout = .{ .gap = 4 },
        .children = &items,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 260, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 4), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), snapshot.widgets[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 3), snapshot.widgets[1].list.item_count);
    try std.testing.expect(snapshot.widgets[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), snapshot.widgets[3].list.item_index);
    try std.testing.expectEqual(@as(u32, 3), snapshot.widgets[3].list.item_count);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), snapshot.widgets[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 3), snapshot.widgets[1].list.item_count);
    try std.testing.expect(snapshot.widgets[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), snapshot.widgets[3].list.item_index);
    try std.testing.expectEqual(@as(u32, 3), snapshot.widgets[3].list.item_count);
}

test "runtime accepts larger retained widget shells for automation" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-large-shell", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 480),
    });

    var items: [24]canvas.Widget = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{
            .id = @intCast(index + 2),
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 18),
            .text = "Item",
        };
    }
    const list = canvas.Widget{
        .id = 1,
        .kind = .list,
        .text = "Workspace list",
        .layout = .{ .gap = 1 },
        .children = &items,
    };

    var nodes: [25]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 320, 480), &nodes);
    try std.testing.expectEqual(@as(usize, 25), layout.nodeCount());

    const info = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try std.testing.expectEqual(@as(u64, 1), info.widget_revision);
    try std.testing.expectEqual(@as(usize, 25), info.widget_node_count);
    try std.testing.expectEqual(@as(usize, 25), info.widget_semantics_count);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 25), snapshot.widgets.len);
    try std.testing.expectEqualStrings("list", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Workspace list", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("listitem", snapshot.widgets[24].role);
    try std.testing.expectEqual(@as(u64, 25), snapshot.widgets[24].id);
    try std.testing.expect(snapshot.widgets[24].list.present);
    try std.testing.expectEqual(@as(u32, 23), snapshot.widgets[24].list.item_index);
    try std.testing.expectEqual(@as(u32, 24), snapshot.widgets[24].list.item_count);
}

test "runtime automation snapshot retains widgets from multiple canvas surfaces" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-multi-surface-snapshot", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "left-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 320),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "right-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(250, 0, 240, 320),
    });

    var left_items: [40]canvas.Widget = undefined;
    var right_items: [40]canvas.Widget = undefined;
    for (&left_items, &right_items, 0..) |*left, *right, index| {
        const y = @as(f32, @floatFromInt(index)) * 7;
        left.* = .{
            .id = 100 + @as(canvas.ObjectId, @intCast(index)),
            .kind = .button,
            .frame = geometry.RectF.init(8, y, 120, 6),
            .text = "Left",
        };
        right.* = .{
            .id = 200 + @as(canvas.ObjectId, @intCast(index)),
            .kind = .button,
            .frame = geometry.RectF.init(8, y, 120, 6),
            .text = "Right",
        };
    }

    var left_nodes: [41]canvas.WidgetLayoutNode = undefined;
    var right_nodes: [41]canvas.WidgetLayoutNode = undefined;
    const left_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &left_items }, geometry.RectF.init(0, 0, 240, 320), &left_nodes);
    const right_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &right_items }, geometry.RectF.init(0, 0, 240, 320), &right_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "left-canvas", left_layout);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "right-canvas", right_layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 80), snapshot.widgets.len);
    try std.testing.expectEqualStrings("left-canvas", snapshot.widgets[0].view_label);
    try std.testing.expectEqual(@as(u64, 100), snapshot.widgets[0].id);
    try std.testing.expectEqualStrings("left-canvas", snapshot.widgets[39].view_label);
    try std.testing.expectEqual(@as(u64, 139), snapshot.widgets[39].id);
    try std.testing.expectEqualStrings("right-canvas", snapshot.widgets[40].view_label);
    try std.testing.expectEqual(@as(u64, 200), snapshot.widgets[40].id);
    try std.testing.expectEqualStrings("right-canvas", snapshot.widgets[79].view_label);
    try std.testing.expectEqual(@as(u64, 239), snapshot.widgets[79].id);
}

test "runtime validates canvas widget layout targets and limits" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-limits", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 0, 320, 40),
    });
    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.setCanvasWidgetLayout(1, "status", .{}));

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 40, 320, 240),
    });

    const duplicate_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 2, .kind = .text, .text = "Two" },
    };
    var duplicate_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const duplicate = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &duplicate_children }, geometry.RectF.init(0, 0, 320, 240), &duplicate_nodes);
    try std.testing.expectError(error.DuplicateWidgetId, harness.runtime.setCanvasWidgetLayout(1, "canvas", duplicate));

    const invalid_command_children = [_]canvas.Widget{.{
        .id = 5,
        .kind = .button,
        .text = "Run",
        .command = "bad\ncommand",
    }};
    var invalid_command_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const invalid_command = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &invalid_command_children }, geometry.RectF.init(0, 0, 320, 240), &invalid_command_nodes);
    try std.testing.expectError(error.InvalidCommand, harness.runtime.setCanvasWidgetLayout(1, "canvas", invalid_command));

    var many_nodes: [max_canvas_widget_nodes_per_view + 1]canvas.WidgetLayoutNode = undefined;
    for (&many_nodes, 0..) |*node, index| {
        node.* = .{
            .widget = .{ .id = @intCast(index + 1), .kind = .text, .text = "x" },
            .frame = geometry.RectF.init(0, @floatFromInt(index), 10, 10),
            .depth = 0,
        };
    }
    try std.testing.expectError(error.WidgetNodeLimitReached, harness.runtime.setCanvasWidgetLayout(1, "canvas", .{ .nodes = &many_nodes }));
}
