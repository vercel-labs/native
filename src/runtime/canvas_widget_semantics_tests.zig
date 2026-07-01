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

test "runtime retains canvas widget layout for automation semantics" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
        .semantics = .{ .label = "Run query" },
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const info = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try std.testing.expectEqual(@as(u64, 1), info.widget_revision);
    try std.testing.expectEqual(@as(usize, 2), info.widget_node_count);
    try std.testing.expectEqual(@as(usize, 1), info.widget_semantics_count);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(59.5, 81.5, 97, 33), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(usize, 2), retained.nodeCount());
    try std.testing.expectEqualStrings("Run", retained.nodes[1].widget.text);
    try std.testing.expectEqualStrings("Run query", retained.nodes[1].widget.semantics.label);
    try std.testing.expectEqual(@as(usize, 0), retained.nodes[1].widget.children.len);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 1), canvas_view.widget_revision);
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqual(@as(u64, 2), snapshot.widgets[0].id);
    try std.testing.expectEqualStrings("button", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Run query", snapshot.widgets[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(60, 82, 96, 32), snapshot.widgets[0].bounds);
    try std.testing.expect(!snapshot.widgets[0].hovered);
    try std.testing.expect(!snapshot.widgets[0].pressed);
    try std.testing.expect(!snapshot.widgets[0].selected);
    try std.testing.expect(snapshot.widgets[0].actions.focus);
    try std.testing.expect(snapshot.widgets[0].actions.press);
    try std.testing.expect(!snapshot.widgets[0].actions.toggle);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,press]") != null);
}

test "runtime automation snapshot exposes canvas widget text ranges" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-range-semantics", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 240, 120),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 180, 36),
        .text = "Deploy",
        .text_selection = .{ .anchor = 1, .focus = 4 },
        .text_composition = canvas.TextRange.init(2, 5),
        .semantics = .{ .label = "Release name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("textbox", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("Release name", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("Deploy", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 4 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 2, .end = 5 }, snapshot.widgets[0].text_composition.?);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#2 role=textbox name=\"Release name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"Deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "selection=1..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=2..5") != null);
}

test "runtime emits canvas display list from focused widget layout" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-display-list", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 320, 240),
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
            .kind = .button,
            .frame = geometry.RectF.init(10, 56, 96, 32),
            .text = "Stop",
            .state = .{ .hovered = true, .pressed = true, .focused = true },
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 24,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const info = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{
        .colors = .{
            .accent = canvas.Color.rgb8(10, 20, 30),
            .focus_ring = canvas.Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    });
    try std.testing.expectEqual(@as(u64, 1), info.canvas_revision);
    try std.testing.expectEqual(@as(usize, 6), info.canvas_command_count);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len > 0);

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_runtime_focus = false;
    var saw_stale_focus = false;
    var saw_run_text = false;
    for (retained.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_runtime_focus = true;
            if (id == testCanvasWidgetPartId(3, 3)) saw_stale_focus = true;
        }
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 1)) {
                    switch (fill.fill) {
                        .color => |color| try std.testing.expectEqualDeep(canvas.Color.rgb8(10, 20, 30), color),
                        else => return error.TestUnexpectedResult,
                    }
                }
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Run", text.text);
                    saw_run_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_runtime_focus);
    try std.testing.expect(!saw_stale_focus);
    try std.testing.expect(saw_run_text);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 24,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);

    const changed_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Changed",
    }};
    var changed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const changed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &changed_children }, geometry.RectF.init(0, 0, 320, 240), &changed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", changed_layout);

    const retained_after_widget_update = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_changed_text = false;
    for (retained_after_widget_update.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Changed", text.text);
                    saw_changed_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_changed_text);

    var manual_commands: [1]canvas.CanvasCommand = undefined;
    var manual_builder = canvas.Builder.init(&manual_commands);
    try manual_builder.drawText(.{ .id = 900, .font_id = 1, .size = 12, .origin = geometry.PointF.init(4, 16), .color = canvas.Color.rgb8(1, 2, 3), .text = "Manual" });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", manual_builder.displayList());

    const manual_changed_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Ignored",
    }};
    var manual_changed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const manual_changed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &manual_changed_children }, geometry.RectF.init(0, 0, 320, 240), &manual_changed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", manual_changed_layout);

    const manual_retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), manual_retained.commandCount());
    switch (manual_retained.commands[0]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Manual", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "runtime shows canvas widget focus rings only for keyboard-visible focus" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-view-focus-render-state", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "other",
        .kind = .button,
        .frame = geometry.RectF.init(260, 0, 80, 32),
        .text = "Other",
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
            .kind = .button,
            .frame = geometry.RectF.init(10, 56, 96, 32),
            .text = "Stop",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 24,
    } });
    try std.testing.expect(harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focus_visible_id);

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(!saw_focus_ring);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].focused);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focus_visible_id);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(3, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(saw_focus_ring);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[1].focused);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.focusView(1, "other");
    try std.testing.expect(!harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(3, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(!saw_focus_ring);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(!snapshot.widgets[1].focused);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.focusView(1, "canvas");
    try std.testing.expect(harness.runtime.views[0].focused);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(3, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(saw_focus_ring);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[1].focused);
}

test "runtime ignores stale canvas widget keyboard focus when canvas view loses focus" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-view-focus-keyboard-route", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "other",
        .kind = .button,
        .frame = geometry.RectF.init(260, 0, 80, 32),
        .text = "Other",
    });

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 140, 32),
        .text = "Query",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
    } });
    try std.testing.expect(harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    var route_buffer: [4]canvas.WidgetEventRouteEntry = undefined;
    const key_route = try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    }, &route_buffer);
    try std.testing.expect(key_route != null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), key_route.?.target.?.id);

    const text_route = try harness.runtime.routeCanvasWidgetTextInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    }, &route_buffer);
    try std.testing.expect(text_route != null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), text_route.?.target.?.id);

    try harness.runtime.focusView(1, "other");
    try std.testing.expect(!harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    }, &route_buffer) == null);
    try std.testing.expect(try harness.runtime.routeCanvasWidgetTextInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    }, &route_buffer) == null);
}

test "runtime clears focused canvas widget when layout replacement hides it" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-hidden-focus", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(50, 70, 320, 160),
    });

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 80, 32),
        .text = "Run",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.runtime.views[0].canvas_widget_focus_visible_id = 2;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_focused_ring = false;
    for (retained.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focused_ring = true;
        }
    }
    try std.testing.expect(saw_focused_ring);

    const hidden_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 80, 32),
        .text = "Run",
        .semantics = .{ .hidden = true },
    }};
    var hidden_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const hidden_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &hidden_children }, geometry.RectF.init(0, 0, 320, 160), &hidden_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", hidden_layout);

    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 2);
    try std.testing.expectEqualDeep(geometry.RectF.init(59.5, 79.5, 81, 33), harness.runtime.pendingDirtyRegions()[0]);
    try std.testing.expectEqualDeep(geometry.RectF.init(59, 79, 82, 34), harness.runtime.pendingDirtyRegions()[1]);

    const retained_after_hide = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_stale_focused_ring = false;
    var saw_hidden_button_part = false;
    for (retained_after_hide.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_stale_focused_ring = true;
            if (id == testCanvasWidgetPartId(2, 1) or
                id == testCanvasWidgetPartId(2, 2) or
                id == testCanvasWidgetPartId(2, 4))
            {
                saw_hidden_button_part = true;
            }
        }
    }
    try std.testing.expect(!saw_stale_focused_ring);
    try std.testing.expect(!saw_hidden_button_part);
}
