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

test "runtime tracks retained canvas widget cursor intent" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-cursor", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 160),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 12, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(10, 52, 140, 32), .text = "Query" },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(10, 96, 140, 24), .value = 0.5 },
        .{ .id = 5, .kind = .split_divider, .frame = geometry.RectF.init(10, 128, 140, 16) },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    var snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_cursor_count);

    // Buttons follow the NATIVE cursor register: the arrow, exactly like
    // the platform's own controls. Hovering one changes nothing on the
    // cursor channel — no platform write happens — because the pointing
    // hand is a hyperlink affordance, not a control affordance.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 24 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_cursor_count);

    // Editable text keeps the I-beam — the first hover that actually
    // moves the channel, so the platform write (with window and label)
    // is observable here.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 64 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.text, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.text, harness.null_platform.view_cursor);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.view_cursor_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.view_cursor_label_storage[0..harness.null_platform.view_cursor_label_len]);

    const disabled_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 12, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(10, 52, 140, 32), .text = "Query", .state = .{ .disabled = true } },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(10, 96, 140, 24), .value = 0.5 },
        .{ .id = 5, .kind = .split_divider, .frame = geometry.RectF.init(10, 128, 140, 16) },
    };
    var disabled_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const disabled_layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &disabled_children }, geometry.RectF.init(0, 0, 240, 160), &disabled_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", disabled_layout);
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.null_platform.view_cursor);

    // Sliders keep the arrow too — at rest AND during a drag — matching
    // native sliders on every platform. No cursor write fires.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 108 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.view_cursor_count);

    // Split dividers are the resize affordance — that part of the
    // register is unchanged.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 134 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(platform.Cursor.resize_horizontal, canvas_view.cursor);
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.resize_horizontal, harness.null_platform.view_cursor);

    var view_json_buffer: [4096]u8 = undefined;
    const view_json = try writeViewJson(canvas_view, &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"cursor\":\"resize_horizontal\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 220, .y = 148 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 4), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.null_platform.view_cursor);
}

test "composite list row hovers as one surface: wash, cursor, and pressed wash cover the row" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-row-hover", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 160),
    });

    // The two-line list row shape (title + snippet) the showcase list
    // panes render: text children are hit targets (selection), but hover
    // must attribute to the row.
    const snippet = canvas.Widget{ .id = 6, .kind = .text, .frame = geometry.RectF.init(0, 0, 160, 20), .text = "Snippet line" };
    const inner_row = canvas.Widget{ .id = 5, .kind = .row, .frame = geometry.RectF.init(0, 0, 0, 20), .children = &.{snippet} };
    const title = canvas.Widget{ .id = 4, .kind = .text, .frame = geometry.RectF.init(0, 0, 120, 20), .text = "Title" };
    const column = canvas.Widget{ .id = 3, .kind = .column, .layout = .{ .gap = 8 }, .children = &.{ title, inner_row } };
    const row = canvas.Widget{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 72), .layout = .{ .padding = geometry.InsetsF.all(10) }, .children = &.{column} };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{row} }, geometry.RectF.init(0, 0, 320, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const title_frame = retained.findById(4).?.frame.normalized();
    const snippet_frame = retained.findById(6).?.frame.normalized();
    const row_frame = retained.findById(2).?.frame.normalized();

    // Probe the title interior, the gap between the lines, the snippet
    // interior, and the row's padding corner: every point hovers the ROW
    // and shows the pointer cursor — no dead zones inside one surface.
    const probes = [_]geometry.PointF{
        title_frame.center(),
        .{ .x = title_frame.center().x, .y = (title_frame.maxY() + snippet_frame.y) / 2 },
        snippet_frame.center(),
        .{ .x = row_frame.x + 3, .y = row_frame.y + 3 },
        .{ .x = row_frame.maxX() - 3, .y = snippet_frame.center().y },
    };
    for (probes) |probe| {
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "canvas",
            .kind = .pointer_move,
            .x = probe.x,
            .y = probe.y,
        } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
        // The hover wash is the row's affordance; the cursor stays the
        // native arrow (list rows are controls, not hyperlinks).
        try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    }

    // A press over the snippet lights the row's pressed wash (the render
    // state resolves it through the same fall-through the click takes).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = snippet_frame.center().x,
        .y = snippet_frame.center().y,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvasWidgetRenderState().pressed_id.?);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = snippet_frame.center().x,
        .y = snippet_frame.center().y,
    } });

    // Off the row: hover clears and the cursor stays the arrow it never
    // left (the channel is read from the runtime — the platform write
    // only fires on change, and a row hover never changes it).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .x = row_frame.center().x,
        .y = row_frame.maxY() + 20,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
}

test "runtime dispatches routed canvas widget pointer events" {
    const TestApp = struct {
        raw_input_count: u32 = 0,
        widget_pointer_count: u32 = 0,
        widget_keyboard_count: u32 = 0,
        widget_key_down_count: u32 = 0,
        widget_text_input_count: u32 = 0,
        last_view_label: []const u8 = "",
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_keyboard_phase: canvas.WidgetKeyboardPhase = .key_up,
        last_target_id: canvas.ObjectId = 0,
        last_target_kind: canvas.WidgetKind = .stack,
        last_keyboard_target_id: canvas.ObjectId = 0,
        last_keyboard_target_kind: canvas.WidgetKind = .stack,
        last_route_len: usize = 0,
        last_keyboard_route_len: usize = 0,
        last_keyboard_key: []const u8 = "",
        last_keyboard_text: []const u8 = "",
        last_keyboard_shift: bool = false,
        last_keyboard_super: bool = false,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-input", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_input => {
                    self.raw_input_count += 1;
                },
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_view_label = pointer_event.view_label;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_route_len = pointer_event.route.len;
                    if (pointer_event.target) |target| {
                        self.last_target_id = target.id;
                        self.last_target_kind = target.kind;
                    } else {
                        self.last_target_id = 0;
                        self.last_target_kind = .stack;
                    }
                },
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    switch (keyboard_event.keyboard.phase) {
                        .key_down => self.widget_key_down_count += 1,
                        .text_input => self.widget_text_input_count += 1,
                        .key_up => {},
                    }
                    self.last_view_label = keyboard_event.view_label;
                    self.last_keyboard_phase = keyboard_event.keyboard.phase;
                    self.last_keyboard_route_len = keyboard_event.route.len;
                    self.last_keyboard_key = keyboard_event.keyboard.key;
                    self.last_keyboard_text = keyboard_event.keyboard.text;
                    self.last_keyboard_shift = keyboard_event.keyboard.modifiers.shift;
                    self.last_keyboard_super = keyboard_event.keyboard.modifiers.super;
                    if (keyboard_event.target) |target| {
                        self.last_keyboard_target_id = target.id;
                        self.last_keyboard_target_kind = target.kind;
                    } else {
                        self.last_keyboard_target_id = 0;
                        self.last_keyboard_target_kind = .stack;
                    }
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 160),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 12, 96, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .text_field,
            .frame = geometry.RectF.init(10, 52, 140, 32),
            .text = "Query",
        },
    };
    const root = canvas.Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
        .button = 0,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.raw_input_count);
    try std.testing.expectEqualStrings("canvas", app_state.last_view_label);
    try std.testing.expectEqual(canvas.WidgetPointerPhase.down, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.button, app_state.last_target_kind);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_route_len);
    try std.testing.expect(harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 12, 96, 32), harness.runtime.pendingDirtyRegions()[0]);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 3), snapshot.widgets.len);
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[1].focused);
    try std.testing.expect(snapshot.widgets[1].hovered);
    try std.testing.expect(snapshot.widgets[1].pressed);
    try std.testing.expect(!snapshot.widgets[1].selected);
    try std.testing.expect(!snapshot.widgets[2].focused);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .shift = true, .primary = true },
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_key_down_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u32, 2), app_state.raw_input_count);
    try std.testing.expectEqual(canvas.WidgetKeyboardPhase.key_down, app_state.last_keyboard_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.button, app_state.last_keyboard_target_kind);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_keyboard_route_len);
    try std.testing.expectEqualStrings("enter", app_state.last_keyboard_key);
    try std.testing.expectEqualStrings("", app_state.last_keyboard_text);
    try std.testing.expect(app_state.last_keyboard_shift);
    try std.testing.expect(app_state.last_keyboard_super);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_key_down_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u32, 3), app_state.raw_input_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_keyboard_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.text_field, app_state.last_keyboard_target_kind);
    try std.testing.expectEqualStrings("tab", app_state.last_keyboard_key);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    // Focus dirty bounds include the ring's 2px outside offset.
    try std.testing.expectEqualDeep(geometry.RectF.init(7, 49, 146, 38), harness.runtime.pendingDirtyRegions()[0]);

    const tab_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!tab_snapshot.widgets[1].focused);
    try std.testing.expect(tab_snapshot.widgets[2].focused);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try std.testing.expectEqual(@as(u32, 4), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 3), app_state.widget_key_down_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u32, 4), app_state.raw_input_count);
    try std.testing.expectEqual(canvas.WidgetKeyboardPhase.text_input, app_state.last_keyboard_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_keyboard_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.text_field, app_state.last_keyboard_target_kind);
    try std.testing.expectEqualStrings("a", app_state.last_keyboard_key);
    try std.testing.expectEqualStrings("a", app_state.last_keyboard_text);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try std.testing.expectEqual(@as(u32, 5), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 4), app_state.widget_key_down_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u32, 5), app_state.raw_input_count);
    try std.testing.expectEqual(canvas.WidgetKeyboardPhase.key_down, app_state.last_keyboard_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_keyboard_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.text_field, app_state.last_keyboard_target_kind);
    try std.testing.expectEqualStrings("a", app_state.last_keyboard_key);
    try std.testing.expectEqualStrings("a", app_state.last_keyboard_text);
    try std.testing.expect(app_state.last_keyboard_super);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqual(@as(u32, 6), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 5), app_state.widget_key_down_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u32, 6), app_state.raw_input_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);
    try std.testing.expectEqual(canvas.WidgetKind.button, app_state.last_keyboard_target_kind);
    try std.testing.expect(app_state.last_keyboard_shift);
}

test "runtime routes captured canvas pointer drags without outside release activation" {
    const TestApp = struct {
        command_count: u32 = 0,
        widget_pointer_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,
        last_route_len: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-pointer-capture", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => self.command_count += 1,
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_route_len = pointer_event.route.len;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .command = "widget.run",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 64, 96, 32),
            .text = "Stop",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 220,
        .y = 28,
        .delta_x = 200,
    } });
    try std.testing.expectEqual(canvas.WidgetPointerPhase.move, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_route_len);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 220,
        .y = 28,
    } });
    try std.testing.expectEqual(canvas.WidgetPointerPhase.up, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_route_len);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(u32, 0), app_state.command_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 28,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
}

test "runtime cancels captured canvas widget pointers without activation" {
    const TestApp = struct {
        command_count: u32 = 0,
        raw_input_count: u32 = 0,
        widget_pointer_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,
        last_route_len: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-pointer-cancel", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => self.command_count += 1,
                .gpu_surface_input => self.raw_input_count += 1,
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_route_len = pointer_event.route.len;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .command = "widget.run",
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(12, 64, 96, 32),
            .text = "Live",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);
    // A pressed button still shows the native arrow — the cursor channel
    // never leaves arrow for controls, only for links/text/dividers.
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_cancel,
        .x = 220,
        .y = 28,
    } });
    try std.testing.expectEqual(canvas.WidgetPointerPhase.cancel, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_route_len);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len > 0);
    try std.testing.expectEqual(@as(u32, 0), app_state.command_count);

    const cancel_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 3), cancel_snapshot.widgets.len);
    try std.testing.expect(cancel_snapshot.widgets[1].focused);
    try std.testing.expect(!cancel_snapshot.widgets[1].hovered);
    try std.testing.expect(!cancel_snapshot.widgets[1].pressed);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(u32, 0), app_state.command_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 76,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_pressed_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_cancel,
        .x = 20,
        .y = 76,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 76,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(3).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(3).?.widget.value);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(@as(u32, 0), app_state.command_count);
    try std.testing.expectEqual(@as(u32, 6), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 6), app_state.raw_input_count);
}

test "runtime applies GPU text and IME input to focused canvas text fields" {
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        last_keyboard_phase: canvas.WidgetKeyboardPhase = .key_up,
        last_keyboard_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-mobile-text-ime", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    self.last_keyboard_phase = keyboard_event.keyboard.phase;
                    if (keyboard_event.target) |target| self.last_keyboard_target_id = target.id;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text_field,
            .frame = geometry.RectF.init(10, 10, 160, 32),
            .text = "hello",
            .text_selection = canvas.TextSelection{ .anchor = 1, .focus = 4 },
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    harness.runtime.views[0].focused = true;
    harness.runtime.views[0].canvas_widget_focused_id = 2;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .text_input,
        .text = "a",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    var field = retained.findById(2).?.widget;
    try std.testing.expectEqualStrings("hao", field.text);
    try std.testing.expectEqual(@as(usize, 2), field.text_selection.?.focus);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_keyboard_count);
    try std.testing.expectEqual(canvas.WidgetKeyboardPhase.text_input, app_state.last_keyboard_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_set_composition,
        .text = "é",
        .composition_cursor = 2,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    field = retained.findById(2).?.widget;
    try std.testing.expectEqualStrings("haéo", field.text);
    try std.testing.expect(field.text_composition != null);
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_commit_composition,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    field = retained.findById(2).?.widget;
    try std.testing.expectEqualStrings("haéo", field.text);
    try std.testing.expect(field.text_composition == null);
    try std.testing.expectEqual(@as(u32, 3), app_state.widget_keyboard_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_set_composition,
        .text = "ll",
        .composition_cursor = 2,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .ime_cancel_composition,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    field = retained.findById(2).?.widget;
    try std.testing.expectEqualStrings("haéo", field.text);
    try std.testing.expect(field.text_composition == null);
    try std.testing.expectEqual(@as(u32, 5), app_state.widget_keyboard_count);
}

test "runtime dispatches opted-in canvas widget drag events" {
    const TestApp = struct {
        raw_input_count: u32 = 0,
        widget_pointer_count: u32 = 0,
        widget_drag_count: u32 = 0,
        last_drag_source_id: canvas.ObjectId = 0,
        last_drag_route_len: usize = 0,
        last_drag_x: f32 = 0,
        last_drag_dx: f32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-drag", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_input => self.raw_input_count += 1,
                .canvas_widget_pointer => self.widget_pointer_count += 1,
                .canvas_widget_drag => |drag_event| {
                    self.widget_drag_count += 1;
                    self.last_drag_source_id = if (drag_event.source) |source| source.id else 0;
                    self.last_drag_route_len = drag_event.route.len;
                    self.last_drag_x = drag_event.drag.point.x;
                    self.last_drag_dx = drag_event.drag.delta.dx;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Drag",
            .semantics = .{ .actions = .{ .drag = true } },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 58, 96, 32),
            .text = "Plain",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 44,
        .y = 28,
        .delta_x = 12,
    } });
    try std.testing.expectEqual(@as(u32, 0), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.raw_input_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 28,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 64,
        .y = 30,
        .delta_x = 44,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(u32, 3), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 3), app_state.raw_input_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_drag_source_id);
    try std.testing.expectEqual(@as(usize, 3), app_state.last_drag_route_len);
    try std.testing.expectEqual(@as(f32, 64), app_state.last_drag_x);
    try std.testing.expectEqual(@as(f32, 44), app_state.last_drag_dx);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].actions.drag);
    try std.testing.expect(!snapshot.widgets[2].actions.drag);
}

test "runtime resizes retained canvas resizable widgets from pointer drag" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-resizable-drag", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 260, 120),
    });

    const resizable = canvas.Widget{
        .id = 2,
        .kind = .resizable,
        .frame = geometry.RectF.init(10, 16, 120, 44),
        .text = "Resizable",
        .semantics = .{ .label = "Resizable panel" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{resizable} }, geometry.RectF.init(0, 0, 260, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 126,
        .y = 38,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 156,
        .y = 38,
        .delta_x = 30,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 16, 150, 44), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 16, 150, 44), retained.findById(2).?.widget.frame);

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    switch (display_list.findCommandById(testCanvasWidgetPartId(2, 5)).?.command) {
        .draw_line => |line| try std.testing.expect(line.from.x > 152),
        else => return error.TestUnexpectedResult,
    }

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 10,
        .y = 38,
        .delta_x = -200,
    } });

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 48), retained.findById(2).?.frame.width);

    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 48), retained.findById(2).?.frame.width);
    try std.testing.expectEqual(@as(f32, 48), retained.findById(2).?.widget.frame.width);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    switch (display_list.findCommandById(testCanvasWidgetPartId(2, 5)).?.command) {
        .draw_line => |line| try std.testing.expect(line.from.x < 56),
        else => return error.TestUnexpectedResult,
    }
}

test "runtime dispatches automation canvas widget actions" {
    const TestApp = struct {
        command_count: u32 = 0,
        widget_keyboard_count: u32 = 0,
        widget_drag_count: u32 = 0,
        widget_file_drop_count: u32 = 0,
        file_drop_count: u32 = 0,
        raw_input_count: u32 = 0,
        last_command: []const u8 = "",
        last_keyboard_target_id: canvas.ObjectId = 0,
        last_keyboard_key: []const u8 = "",
        last_drag_source_id: canvas.ObjectId = 0,
        last_drag_dx: f32 = 0,
        last_drop_target_id: canvas.ObjectId = 0,
        last_drop_path_count: usize = 0,
        last_drop_first_path: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-automation-actions", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_command = command.name;
                },
                .gpu_surface_input => self.raw_input_count += 1,
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    if (keyboard_event.target) |target| self.last_keyboard_target_id = target.id;
                    self.last_keyboard_key = keyboard_event.keyboard.key;
                },
                .canvas_widget_drag => |drag_event| {
                    self.widget_drag_count += 1;
                    if (drag_event.source) |source| self.last_drag_source_id = source.id;
                    self.last_drag_dx = drag_event.drag.delta.dx;
                },
                .canvas_widget_file_drop => |drop_event| {
                    self.widget_file_drop_count += 1;
                    if (drop_event.target) |target| self.last_drop_target_id = target.id;
                    self.last_drop_path_count = drop_event.drop.paths.len;
                    self.last_drop_first_path = if (drop_event.drop.paths.len > 0) drop_event.drop.paths[0] else "";
                },
                .files_dropped => self.file_drop_count += 1,
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const scroll_items = [_]canvas.Widget{
        .{ .id = 8, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Row one" },
        .{ .id = 9, .kind = .button, .frame = geometry.RectF.init(0, 64, 0, 32), .text = "Row two" },
        .{ .id = 10, .kind = .button, .frame = geometry.RectF.init(0, 128, 0, 32), .text = "Row three" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 10, 96, 32), .text = "Run", .command = "widget.run", .semantics = .{ .actions = .{ .drag = true } } },
        .{ .id = 3, .kind = .checkbox, .frame = geometry.RectF.init(10, 52, 96, 28), .text = "Enabled" },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(10, 88, 120, 24), .value = 0.5, .semantics = .{ .label = "Amount" } },
        .{ .id = 5, .kind = .text_field, .frame = geometry.RectF.init(10, 122, 150, 32), .text = "Draft" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(170, 10, 120, 32), .text = "Inbox" },
        .{ .id = 7, .kind = .scroll_view, .frame = geometry.RectF.init(170, 52, 120, 48), .children = &scroll_items },
        .{ .id = 11, .kind = .button, .frame = geometry.RectF.init(170, 110, 120, 32), .text = "Upload", .semantics = .{ .actions = .{ .drop_files = true } } },
        .{ .id = 12, .kind = .menu_item, .frame = geometry.RectF.init(170, 146, 120, 28), .text = "Archive" },
    };
    var nodes: [13]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .press });
    try std.testing.expect(harness.runtime.views[0].gpu_input_timestamp_ns > 0);
    try std.testing.expect(harness.runtime.views[0].gpu_pending_input_timestamp_ns > 0);
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("widget.run", app_state.last_command);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);

    // The accessibility press rides the SAME key-driven activation the
    // automation press verb uses: the app hears the enter key on the
    // target and the widget's command dispatches through the real
    // activation path. A direct-command shortcut here would skip the
    // keyboard channel, and any widget wired through message handlers
    // instead of a command string would report success while actuating
    // nothing.
    const keyboard_count_before_ax_press = app_state.widget_keyboard_count;
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 2, .action = .press });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("widget.run", app_state.last_command);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(keyboard_count_before_ax_press + 1, app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("enter", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .drag, .value = "18 2" });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_drag_source_id);
    try std.testing.expectEqual(@as(f32, 18), app_state.last_drag_dx);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 2, .action = .drag, .text = "8 1" });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_drag_source_id);
    try std.testing.expectEqual(@as(f32, 8), app_state.last_drag_dx);

    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 2,
        .action = .drag,
    } });
    try std.testing.expectEqual(@as(u32, 3), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_drag_source_id);
    try std.testing.expectEqual(@as(f32, 16), app_state.last_drag_dx);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .toggle });
    try std.testing.expectEqual(@as(?f32, 1), runtimeViewWidgetSemantics(&harness.runtime.views[0])[2].value);
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .drag }));

    // The accessibility toggle is the same space-key toggle: the
    // retained value flips back AND the app hears the key — an
    // echo-only flip would leave the model behind and revert on the
    // next rebuild.
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 3, .action = .toggle });
    try std.testing.expectEqual(@as(?f32, 0), runtimeViewWidgetSemantics(&harness.runtime.views[0])[2].value);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("space", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 4, .action = .increment });
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), runtimeViewWidgetSemantics(&harness.runtime.views[0])[3].value.?, 0.001);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("arrowright", app_state.last_keyboard_key);

    // The accessibility increment on a slider is the same arrow step
    // the automation verb dispatches: value moves through the keyboard
    // intent and the app hears the arrow key on the slider.
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 4, .action = .increment });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), runtimeViewWidgetSemantics(&harness.runtime.views[0])[3].value.?, 0.001);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("arrowright", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 6, .action = .select });
    try std.testing.expectEqual(@as(?f32, 1), runtimeViewWidgetSemantics(&harness.runtime.views[0])[5].value);

    // A lone menu item in an ACTIONS group (no sibling declares a
    // committed row): the select action focuses it but mints no
    // selection — only picker groups with a declared committed row
    // move one.
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 12, .action = .select });
    const selected_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!selected_layout.findById(12).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), selected_layout.findById(12).?.widget.value);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 7, .action = .increment });
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 40.8), scrolled_layout.findById(7).?.widget.value, 0.001);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("pagedown", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 7, .action = .decrement });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0.0), scrolled_layout.findById(7).?.widget.value);
    try std.testing.expectEqualStrings("pageup", app_state.last_keyboard_key);

    // AX scroll steps ride the page keys the automation verbs use, so
    // the app's keyboard channel hears them like any live page scroll.
    const keyboard_count_before_ax_scroll = app_state.widget_keyboard_count;
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 7, .action = .increment });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 40.8), scrolled_layout.findById(7).?.widget.value, 0.001);
    try std.testing.expectEqual(keyboard_count_before_ax_scroll + 1, app_state.widget_keyboard_count);
    try std.testing.expectEqualStrings("pagedown", app_state.last_keyboard_key);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 7, .action = .decrement });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0.0), scrolled_layout.findById(7).?.widget.value);
    try std.testing.expectEqual(keyboard_count_before_ax_scroll + 2, app_state.widget_keyboard_count);
    try std.testing.expectEqualStrings("pageup", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 11, .action = .drop_files, .value = "/tmp/report.csv /tmp/chart.png" });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_file_drop_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.file_drop_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), app_state.last_drop_target_id);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_drop_path_count);
    try std.testing.expectEqualStrings("/tmp/report.csv", app_state.last_drop_first_path);
    try std.testing.expectEqualStrings("drop:files", harness.null_platform.lastWindowEventName());
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/report.csv\",\"/tmp/chart.png\"]") != null);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 11, .action = .drop_files, .text = "/tmp/accessibility.csv" });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_file_drop_count);
    try std.testing.expectEqual(@as(u32, 2), app_state.file_drop_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 11), app_state.last_drop_target_id);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_drop_path_count);
    try std.testing.expectEqualStrings("/tmp/accessibility.csv", app_state.last_drop_first_path);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/accessibility.csv\"]") != null);
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 11, .action = .drop_files }));
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 11, .action = .drop_files }));
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .drop_files, .value = "/tmp/report.csv" }));

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .set_text, .value = "Hello world" });
    try std.testing.expectEqualStrings("Hello world", runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].label);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .set_composition, .value = "!" });
    try std.testing.expectEqualStrings("Hello world!", runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_value);
    try std.testing.expectEqualDeep(canvas.TextRange.init(11, 12), runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_composition.?);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .commit_composition });
    try std.testing.expectEqualStrings("Hello world!", runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_value);
    try std.testing.expect(runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_composition == null);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .set_composition, .value = " draft" });
    try std.testing.expectEqualStrings("Hello world! draft", runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_value);
    try std.testing.expectEqualDeep(canvas.TextRange.init(12, 18), runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_composition.?);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .cancel_composition });
    try std.testing.expectEqualStrings("Hello world!", runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_value);
    try std.testing.expect(runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_composition == null);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .set_selection, .value = "0 5" });
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, 5), runtimeViewWidgetSemantics(&harness.runtime.views[0])[4].text_selection.?);
    const selection_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(selection_snapshot.widgets[4].actions.set_selection);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 5 }, selection_snapshot.widgets[4].text_selection.?);
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 5, .action = .set_selection, .value = "nope" }));
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .set_selection, .value = "0 1" }));

    try std.testing.expect(app_state.widget_keyboard_count >= 3);
    try std.testing.expect(app_state.raw_input_count >= 3);
}

test "accessibility press actuates widgets wired through message handlers" {
    // The defect this pins: a widget whose press wiring is a bound
    // message handler (no `command` string — every markup `on-press`
    // and Zig-builder `on_press` widget) published `press` to the
    // platform accessibility tree, and performing it reported success
    // while dispatching nothing the app could hear. The honest route is
    // the key-driven activation the automation press verb uses: the app
    // receives the enter key ON the target, so the same typed dispatch
    // a keyboard user's activation reaches fires the handler.
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        last_keyboard_target_id: canvas.ObjectId = 0,
        last_keyboard_key: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-ax-press-handlers", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    if (keyboard_event.target) |target| self.last_keyboard_target_id = target.id;
                    self.last_keyboard_key = keyboard_event.keyboard.key;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const children = [_]canvas.Widget{
        // A commandless button: the segmented-switcher shape (a tab
        // that binds on_press and nothing else).
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 10, 96, 32), .text = "Songs" },
        // A plain list row with a bound press (the album-card shape):
        // quiet focus makes plain rows transparent to keys, so the
        // dispatch must escalate this target to the ring register or
        // the synthesized enter routes as a target-less event.
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(10, 52, 200, 40), .text = "Exit Signs", .semantics = .{ .actions = .{ .press = true } } },
        // No press wiring at all: the runtime must refuse, never
        // succeed-and-do-nothing.
        .{ .id = 4, .kind = .text, .frame = geometry.RectF.init(10, 104, 96, 20), .text = "8 of 8" },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 2, .action = .press });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("enter", app_state.last_keyboard_key);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 3, .action = .press });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("enter", app_state.last_keyboard_key);
    // The escalation is observable: the row now holds the ring
    // register, exactly what a Tab-then-Enter would have left.
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focus_visible_id);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 4, .action = .press }));
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);
}

test "runtime rejects automation canvas widget actions for scroll clipped targets" {
    const TestApp = struct {
        widget_drag_count: u32 = 0,
        widget_file_drop_count: u32 = 0,
        file_drop_count: u32 = 0,
        raw_input_count: u32 = 0,
        last_drag_source_id: canvas.ObjectId = 0,
        last_drop_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clipped-automation-actions", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_input => self.raw_input_count += 1,
                .canvas_widget_drag => |drag_event| {
                    self.widget_drag_count += 1;
                    if (drag_event.source) |source| self.last_drag_source_id = source.id;
                },
                .canvas_widget_file_drop => |drop_event| {
                    self.widget_file_drop_count += 1;
                    if (drop_event.target) |target| self.last_drop_target_id = target.id;
                },
                .files_dropped => self.file_drop_count += 1,
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 48),
    });

    const selectable_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible" },
    };
    var selectable_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const selectable_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .value = 40, .children = &selectable_children },
        geometry.RectF.init(0, 0, 160, 48),
        &selectable_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", selectable_layout);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].actions.select);
    try std.testing.expect(snapshot.widgets[2].actions.select);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -32, 160, 32), snapshot.widgets[1].bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 16, 160, 32), snapshot.widgets[2].bounds);

    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .select }));
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(2).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.widget.value);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .select });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(3).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(3).?.widget.value);

    const drag_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden drag", .semantics = .{ .actions = .{ .drag = true } } },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible drag", .semantics = .{ .actions = .{ .drag = true } } },
    };
    var drag_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const drag_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .value = 40, .children = &drag_children },
        geometry.RectF.init(0, 0, 160, 48),
        &drag_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", drag_layout);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].actions.drag);
    try std.testing.expect(snapshot.widgets[2].actions.drag);
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .drag, .value = "8 0" }));
    try std.testing.expectEqual(@as(u32, 0), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.raw_input_count);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .drag, .value = "8 0" });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_drag_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_drag_source_id);

    const drop_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden drop", .semantics = .{ .actions = .{ .drop_files = true } } },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible drop", .semantics = .{ .actions = .{ .drop_files = true } } },
    };
    var drop_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const drop_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .value = 40, .children = &drop_children },
        geometry.RectF.init(0, 0, 160, 48),
        &drop_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", drop_layout);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].actions.drop_files);
    try std.testing.expect(snapshot.widgets[2].actions.drop_files);
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .drop_files, .value = "/tmp/hidden.csv" }));
    try std.testing.expectEqual(@as(u32, 0), app_state.widget_file_drop_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.file_drop_count);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .drop_files, .value = "/tmp/visible.csv" });
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_file_drop_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.file_drop_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_drop_target_id);
}

test "runtime rejects automation canvas widget actions for clip content clipped targets" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clip-content-automation-actions", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(64, 0, 32, 32), .text = "Clipped" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 32, 32), .text = "Visible" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .stack, .layout = .{ .clip_content = true }, .children = &children },
        geometry.RectF.init(0, 0, 48, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].actions.select);
    try std.testing.expect(snapshot.widgets[2].actions.select);

    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .select }));
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(2).?.widget.state.selected);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .select });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(3).?.widget.state.selected);
    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(?f32, 1), snapshot.widgets[2].value);
}

test "runtime automation protocol refreshes widget-owned canvas display lists" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-automation-display-list", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const list_items = [_]canvas.Widget{
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 30), .text = "Overview" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 36, 0, 30), .text = "Customers" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(10, 12, 150, 32), .text = "Draft" },
        .{ .id = 3, .kind = .list, .frame = geometry.RectF.init(10, 58, 150, 72), .layout = .{ .gap = 6 }, .children = &list_items },
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_initial_text = false;
    var saw_initial_selection = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 3)) {
                    try std.testing.expectEqualStrings("Draft", text.text);
                    saw_initial_text = true;
                }
            },
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(5, 1)) saw_initial_selection = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_initial_text);
    try std.testing.expect(!saw_initial_selection);

    try harness.runtime.dispatchAutomationCommand(app, "widget-action canvas 2 set-text Launch");

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_updated_text = false;
    var saw_stale_text = false;
    var saw_text_caret = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Launch", text.text);
                    saw_updated_text = true;
                }
                if (std.mem.eql(u8, text.text, "Draft")) saw_stale_text = true;
            },
            .fill_rect => |bar| {
                if (bar.id == testCanvasWidgetPartId(2, 6)) saw_text_caret = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_updated_text);
    try std.testing.expect(!saw_stale_text);
    try std.testing.expect(saw_text_caret);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Launch", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 6, .end = 6 }, snapshot.widgets[0].text_selection.?);

    try harness.runtime.dispatchAutomationCommand(app, "widget-action canvas 5 select");

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_selected_item_fill = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(5, 1)) saw_selected_item_fill = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_selected_item_fill);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[2].selected);
    try std.testing.expect(snapshot.widgets[3].selected);
}

test "runtime preserves canvas chrome when widget-owned display lists refresh" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-chrome-display-list", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(24, 24, 150, 32), .text = "Draft" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 180), &nodes);

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(48, 111, 237) },
        .{ .offset = 1, .color = canvas.Color.rgb8(16, 185, 129) },
    };
    var commands: [max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawText(.{
        .id = 10,
        .font_id = 1,
        .size = 12,
        .origin = geometry.PointF.init(16, 16),
        .color = canvas.Color.rgb8(18, 24, 38),
        .text = "Chrome header",
    });
    try layout.emitDisplayList(&builder, .{});
    try builder.fillRect(.{
        .id = 11,
        .rect = geometry.RectF.init(16, 148, 288, 12),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(16, 148),
            .end = geometry.PointF.init(304, 148),
            .stops = &stops,
        } },
    });

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithChrome(1, "canvas", .{}, .{
        .prefix_command_count = 1,
        .suffix_command_count = 1,
    });

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.findCommandById(10).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("Chrome header", text.text),
        else => return error.UnexpectedCanvasCommand,
    }
    try std.testing.expect(display_list.findCommandById(11) != null);
    try std.testing.expect(display_list.findCommandById(testCanvasWidgetPartId(2, 3)) != null);

    try harness.runtime.dispatchAutomationCommand(app, "widget-action canvas 2 set-text Launch");

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    switch (display_list.findCommandById(10).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("Chrome header", text.text),
        else => return error.UnexpectedCanvasCommand,
    }
    try std.testing.expect(display_list.findCommandById(11) != null);
    switch (display_list.findCommandById(testCanvasWidgetPartId(2, 4)).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("Launch", text.text),
        else => return error.UnexpectedCanvasCommand,
    }
}

test "runtime reserves widget-owned canvas display list command headroom" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-display-list-headroom", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    var nodes: [1]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(16, 16, 120, 20),
        .text = "Headroom",
    }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var info = try harness.runtime.emitCanvasWidgetDisplayListWithChrome(1, "canvas", .{}, .{
        .reserved_command_count = max_canvas_commands_per_view - 1,
    });
    try std.testing.expectEqual(@as(usize, 1), info.canvas_command_count);

    try std.testing.expectError(error.CanvasCommandLimitReached, harness.runtime.emitCanvasWidgetDisplayListWithChrome(1, "canvas", .{}, .{
        .reserved_command_count = max_canvas_commands_per_view,
    }));

    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(testCanvasWidgetPartId(2, 1)) != null);

    info = try harness.runtime.emitCanvasWidgetDisplayListWithChrome(1, "canvas", .{}, .{});
    try std.testing.expectEqual(@as(usize, 1), info.canvas_command_count);
}
