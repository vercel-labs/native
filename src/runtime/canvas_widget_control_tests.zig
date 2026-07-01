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

test "runtime applies pointer values to canvas controls" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-control-values", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 48, 120, 28),
            .text = "Alerts",
            .state = .{ .selected = true },
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(10, 88, 100, 32),
            .value = 0.25,
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 240, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 82,
        .y = 20,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 82,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 84,
        .y = 60,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 84,
        .y = 60,
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 75,
        .y = 104,
    } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 110,
        .y = 104,
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 10,
        .y = 104,
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.nodes[1].widget.value);
    try std.testing.expect(!retained.nodes[2].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[2].widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[3].widget.value);

    const semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expectEqual(@as(?f32, 0), semantics[1].value);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].selected);
    try std.testing.expect(!snapshot.widgets[1].selected);
    try std.testing.expect(!snapshot.widgets[2].selected);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_checkbox_check = false;
    var saw_empty_slider_active = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 4)) saw_checkbox_check = true;
            },
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(4, 2)) {
                    try std.testing.expectEqual(@as(f32, 0), fill.rect.width);
                    saw_empty_slider_active = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_checkbox_check);
    try std.testing.expect(saw_empty_slider_active);
}

test "runtime automation widget click dispatches pointer input" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-click-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 220, 100),
    });

    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 48, 120, 28),
            .text = "Alerts",
            .state = .{ .selected = true },
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 220, 100), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    harness.null_platform.gpu_surface_frame_request_count = 0;

    try harness.runtime.dispatchAutomationCommand(app, "widget-click canvas 2");
    try harness.runtime.dispatchAutomationCommand(app, "widget-click canvas 3");
    try std.testing.expect(harness.runtime.views[0].gpu_input_timestamp_ns > 0);
    try std.testing.expect(harness.runtime.views[0].gpu_pending_input_timestamp_ns > 0);
    try std.testing.expect(harness.null_platform.gpu_surface_frame_request_count > 0);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.gpu_surface_frame_request_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_frame_request_label_storage[0..harness.null_platform.gpu_surface_frame_request_label_len]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.nodes[1].widget.value);
    try std.testing.expect(!retained.nodes[2].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[2].widget.value);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].selected);
    try std.testing.expect(!snapshot.widgets[1].selected);
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "widget-click canvas 0"));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "widget-click canvas 9"));
}

test "runtime batches pointer widget display list refreshes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-pointer-refresh-batch", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 220, 100),
    });

    const controls = [_]canvas.Widget{.{
        .id = 4,
        .kind = .toggle,
        .frame = geometry.RectF.init(10, 20, 112, 32),
        .text = "Live",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 220, 100), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    harness.null_platform.gpu_surface_frame_request_count = 0;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 100,
        .x = 66,
        .y = 36,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_pressed_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .timestamp_ns = 110,
        .x = 66,
        .y = 36,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.nodes[1].widget.value);

    const travel = canvas.toggleWidgetKnobTravel(retained.nodes[1].widget, harness.runtime.views[0].widget_tokens);
    const animations = try harness.runtime.canvasRenderAnimations(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), animations.len);
    try std.testing.expectEqual(canvas.toggleWidgetKnobCommandId(4), animations[0].id);
    try std.testing.expectEqual(@as(u64, 110), animations[0].start_ns);
    try std.testing.expectEqual(harness.runtime.views[0].widget_tokens.motion.durationMs(.fast), animations[0].duration_ms);
    try std.testing.expectApproxEqAbs(-travel, animations[0].from_transform.?.tx, 0.001);
    try std.testing.expectEqual(canvas.Affine.identity(), animations[0].to_transform.?);
    const expected_toggle_dirty = runtimeViewCanvasWidgetDirtyBounds(&harness.runtime.views[0], 1, retained.nodes[1].widget.frame).?;
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_render_animation_dirty_bounds_count);
    try std.testing.expectEqual(canvas.toggleWidgetKnobCommandId(4), harness.runtime.views[0].canvas_render_animation_dirty_bounds[0].id);
    try std.testing.expectEqualDeep(expected_toggle_dirty, harness.runtime.views[0].canvas_render_animation_dirty_bounds[0].bounds.?);

    var overrides: [1]canvas.CanvasRenderOverride = undefined;
    const sampled = try canvas.sampleCanvasRenderAnimations(animations, 110 + 60_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);
    try std.testing.expect(sampled[0].transform.?.tx > -travel);
    try std.testing.expect(sampled[0].transform.?.tx < 0);
    try std.testing.expectEqualDeep(expected_toggle_dirty, runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides(&harness.runtime.views[0], &.{}, sampled).?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 200,
        .x = 66,
        .y = 36,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .timestamp_ns = 210,
        .x = 66,
        .y = 36,
    } });
    const reverse_animations = try harness.runtime.canvasRenderAnimations(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), reverse_animations.len);
    try std.testing.expectEqual(canvas.toggleWidgetKnobCommandId(4), reverse_animations[0].id);
    try std.testing.expectEqual(@as(u64, 210), reverse_animations[0].start_ns);
    try std.testing.expectApproxEqAbs(travel, reverse_animations[0].from_transform.?.tx, 0.001);
}

test "runtime batches keyboard widget display list refreshes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-keyboard-refresh-batch", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 100),
    });

    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 20, 96, 32),
            .text = "One",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(118, 20, 96, 32),
            .text = "Two",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 240, 100), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    harness.runtime.views[0].focused = false;
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.null_platform.gpu_surface_frame_request_count = 0;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .timestamp_ns = 100,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expect(harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
}

test "runtime automation widget drag dispatches pointer input" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-drag-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 220, 100),
    });

    const controls = [_]canvas.Widget{.{
        .id = 4,
        .kind = .slider,
        .frame = geometry.RectF.init(10, 20, 100, 32),
        .value = 0.25,
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 220, 100), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    harness.null_platform.gpu_surface_frame_request_count = 0;

    try harness.runtime.dispatchAutomationCommand(app, "widget-drag canvas 4 0.25 0.82");
    try std.testing.expect(harness.runtime.views[0].gpu_input_timestamp_ns > 0);
    try std.testing.expect(harness.runtime.views[0].gpu_pending_input_timestamp_ns > 0);
    try std.testing.expect(harness.null_platform.gpu_surface_frame_request_count > 0);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.gpu_surface_frame_request_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_frame_request_label_storage[0..harness.null_platform.gpu_surface_frame_request_label_len]);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 0.82), retained.nodes[1].widget.value, 0.001);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[0].hovered);
    try std.testing.expect(!snapshot.widgets[0].pressed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.82), snapshot.widgets[0].value.?, 0.001);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "widget-drag canvas 0 0.25 0.82"));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchAutomationCommand(app, "widget-drag canvas 9 0.25 0.82"));
}

test "runtime reconciles canvas control state across layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-control-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 280, 220),
    });

    const list_items = [_]canvas.Widget{
        .{
            .id = 5,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 30),
            .text = "Overview",
            .state = .{ .selected = true },
        },
        .{
            .id = 6,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 36, 0, 30),
            .text = "Customers",
        },
    };
    const mode_items = [_]canvas.Widget{
        .{
            .id = 7,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(0, 0, 72, 30),
            .text = "List",
            .state = .{ .selected = true },
        },
        .{
            .id = 8,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(80, 0, 72, 30),
            .text = "Grid",
        },
    };
    const data_cells = [_]canvas.Widget{
        .{
            .id = 11,
            .kind = .data_cell,
            .frame = geometry.RectF.init(0, 0, 72, 30),
            .text = "Edge",
            .state = .{ .selected = true },
        },
        .{
            .id = 12,
            .kind = .data_cell,
            .frame = geometry.RectF.init(80, 0, 72, 30),
            .text = "Billing",
        },
    };
    const menu_items = [_]canvas.Widget{
        .{
            .id = 13,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 0, 0, 30),
            .text = "Copy",
            .state = .{ .selected = true },
        },
        .{
            .id = 14,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 36, 0, 30),
            .text = "Archive",
        },
    };
    const radio_items = [_]canvas.Widget{
        .{
            .id = 16,
            .kind = .radio,
            .frame = geometry.RectF.init(0, 0, 80, 30),
            .text = "Monthly",
            .state = .{ .selected = true },
        },
        .{
            .id = 17,
            .kind = .radio,
            .frame = geometry.RectF.init(88, 0, 72, 30),
            .text = "Annual",
        },
    };
    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 48, 120, 28),
            .text = "Alerts",
            .state = .{ .selected = true },
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(10, 88, 120, 32),
            .value = 0.5,
        },
        .{
            .id = 10,
            .kind = .list,
            .frame = geometry.RectF.init(150, 10, 110, 72),
            .children = &list_items,
        },
        .{
            .kind = .row,
            .frame = geometry.RectF.init(10, 140, 160, 30),
            .children = &mode_items,
        },
        .{
            .kind = .row,
            .frame = geometry.RectF.init(10, 178, 160, 30),
            .children = &data_cells,
        },
        .{
            .id = 15,
            .kind = .menu_surface,
            .frame = geometry.RectF.init(150, 96, 110, 72),
            .children = &menu_items,
        },
        .{
            .kind = .row,
            .frame = geometry.RectF.init(150, 178, 160, 30),
            .children = &radio_items,
        },
    };
    var nodes: [20]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 280, 220), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .toggle });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 3, .action = .toggle });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 4, .action = .increment });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 6, .action = .select });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 8, .action = .select });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 12, .action = .select });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 14, .action = .select });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 17, .action = .select });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(2).?.widget.value);
    try std.testing.expect(!retained.findById(3).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(3).?.widget.value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), retained.findById(4).?.widget.value, 0.001);
    try std.testing.expect(!retained.findById(5).?.widget.state.selected);
    try std.testing.expect(retained.findById(6).?.widget.state.selected);
    try std.testing.expect(!retained.findById(7).?.widget.state.selected);
    try std.testing.expect(retained.findById(8).?.widget.state.selected);
    try std.testing.expect(!retained.findById(11).?.widget.state.selected);
    try std.testing.expect(retained.findById(12).?.widget.state.selected);
    try std.testing.expect(!retained.findById(13).?.widget.state.selected);
    try std.testing.expect(retained.findById(14).?.widget.state.selected);
    try std.testing.expect(!retained.findById(16).?.widget.state.selected);
    try std.testing.expect(retained.findById(17).?.widget.state.selected);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(2).?.widget.value);
    try std.testing.expect(!retained.findById(3).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(3).?.widget.value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), retained.findById(4).?.widget.value, 0.001);
    try std.testing.expect(!retained.findById(5).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(5).?.widget.value);
    try std.testing.expect(retained.findById(6).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(6).?.widget.value);
    try std.testing.expect(!retained.findById(7).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(7).?.widget.value);
    try std.testing.expect(retained.findById(8).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(8).?.widget.value);
    try std.testing.expect(!retained.findById(11).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(11).?.widget.value);
    try std.testing.expect(retained.findById(12).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(12).?.widget.value);
    try std.testing.expect(!retained.findById(13).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(13).?.widget.value);
    try std.testing.expect(retained.findById(14).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(14).?.widget.value);
    try std.testing.expect(!retained.findById(16).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(16).?.widget.value);
    try std.testing.expect(retained.findById(17).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(17).?.widget.value);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    const semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 2).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 3).?.value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), canvasWidgetSemanticsById(semantics, 4).?.value.?, 0.001);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 5).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 6).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 7).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 8).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 11).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 12).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 13).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 14).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 16).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 17).?.value);
}

test "runtime drives retained settings and data grid workflow" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-settings-grid-workflow", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(12, 18, 380, 300),
    });

    const mode_items = [_]canvas.Widget{
        .{ .id = 22, .kind = .segmented_control, .frame = geometry.RectF.init(150, 18, 82, 30), .text = "List", .state = .{ .selected = true } },
        .{ .id = 23, .kind = .segmented_control, .frame = geometry.RectF.init(238, 18, 82, 30), .text = "Grid" },
    };
    const header_cells = [_]canvas.Widget{
        .{ .id = 32, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 33, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const edge_cells = [_]canvas.Widget{
        .{ .id = 35, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 36, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const billing_cells = [_]canvas.Widget{
        .{ .id = 38, .kind = .data_cell, .text = "Billing", .layout = .{ .grow = 1 } },
        .{ .id = 39, .kind = .data_cell, .text = "Queued", .layout = .{ .grow = 1 } },
    };
    const rows = [_]canvas.Widget{
        .{ .id = 31, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 34, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &edge_cells },
        .{ .id = 37, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &billing_cells },
    };
    const controls = [_]canvas.Widget{
        .{ .id = 20, .kind = .checkbox, .frame = geometry.RectF.init(18, 18, 116, 28), .text = "Live data" },
        .{ .id = 21, .kind = .toggle, .frame = geometry.RectF.init(18, 58, 116, 28), .text = "Compact", .state = .{ .selected = true } },
        .{ .kind = .row, .frame = geometry.RectF.init(150, 18, 170, 30), .layout = .{ .gap = 6 }, .children = &mode_items },
        .{ .id = 24, .kind = .search_field, .frame = geometry.RectF.init(150, 58, 170, 34), .text = "edge", .semantics = .{ .label = "Deployment search" } },
        .{ .id = 30, .kind = .data_grid, .frame = geometry.RectF.init(18, 112, 330, 94), .text = "Deployments", .layout = .{ .gap = 3 }, .children = &rows },
    };
    const root = canvas.Widget{
        .id = 10,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 360, 236),
        .text = "Deployment settings",
        .children = &controls,
    };
    var nodes: [20]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 360, 236), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 20, .action = .toggle });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 21, .action = .toggle });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 23, .action = .select });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 24, .action = .set_text, .value = "edge customers" });
    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 36, .action = .select });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(20).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(20).?.widget.value);
    try std.testing.expect(!retained.findById(21).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(21).?.widget.value);
    try std.testing.expect(!retained.findById(22).?.widget.state.selected);
    try std.testing.expect(retained.findById(23).?.widget.state.selected);
    try std.testing.expectEqualStrings("edge customers", retained.findById(24).?.widget.text);
    try std.testing.expect(!retained.findById(35).?.widget.state.selected);
    try std.testing.expect(retained.findById(36).?.widget.state.selected);

    var semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(canvas.WidgetRole.grid, canvasWidgetSemanticsById(semantics, 30).?.role);
    try std.testing.expectEqual(@as(?usize, 3), canvasWidgetSemanticsById(semantics, 30).?.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), canvasWidgetSemanticsById(semantics, 30).?.grid_column_count);
    try std.testing.expectEqualStrings("edge customers", canvasWidgetSemanticsById(semantics, 24).?.text_value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 20).?.value);
    try std.testing.expectEqual(@as(?f32, 0), canvasWidgetSemanticsById(semantics, 21).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 23).?.value);
    try std.testing.expectEqual(@as(?usize, 1), canvasWidgetSemanticsById(semantics, 36).?.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 1), canvasWidgetSemanticsById(semantics, 36).?.grid_column_index);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 36).?.value);

    const snapshot = harness.runtime.automationSnapshot("Settings");
    var a11y_buffer: [4096]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#20 role=checkbox name=\"Live data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#24 role=textbox name=\"Deployment search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"edge customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#30 role=grid name=\"Deployments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#36 role=gridcell name=\"Live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "grid=[row_index=1,column_index=1,row_count=3,column_count=2]") != null);

    const next_edge_cells = [_]canvas.Widget{
        .{ .id = 35, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 36, .kind = .data_cell, .text = "Ready", .layout = .{ .grow = 1 } },
    };
    const next_billing_cells = [_]canvas.Widget{
        .{ .id = 38, .kind = .data_cell, .text = "Billing", .layout = .{ .grow = 1 } },
        .{ .id = 39, .kind = .data_cell, .text = "Filtered", .layout = .{ .grow = 1 } },
    };
    const next_rows = [_]canvas.Widget{
        .{ .id = 31, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 34, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &next_edge_cells },
        .{ .id = 37, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &next_billing_cells },
    };
    const next_controls = [_]canvas.Widget{
        .{ .id = 20, .kind = .checkbox, .frame = geometry.RectF.init(18, 18, 116, 28), .text = "Live data" },
        .{ .id = 21, .kind = .toggle, .frame = geometry.RectF.init(18, 58, 116, 28), .text = "Compact", .state = .{ .selected = true } },
        .{ .kind = .row, .frame = geometry.RectF.init(150, 18, 170, 30), .layout = .{ .gap = 6 }, .children = &mode_items },
        .{ .id = 24, .kind = .search_field, .frame = geometry.RectF.init(150, 58, 170, 34), .text = "edge customers", .semantics = .{ .label = "Deployment search" } },
        .{ .id = 30, .kind = .data_grid, .frame = geometry.RectF.init(18, 112, 330, 94), .text = "Deployments", .layout = .{ .gap = 3 }, .children = &next_rows },
    };
    const next_root = canvas.Widget{
        .id = 10,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 360, 236),
        .text = "Deployment settings",
        .children = &next_controls,
    };
    var next_nodes: [20]canvas.WidgetLayoutNode = undefined;
    const next_layout = try canvas.layoutWidgetTree(next_root, geometry.RectF.init(0, 0, 360, 236), &next_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", next_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(20).?.widget.state.selected);
    try std.testing.expect(!retained.findById(21).?.widget.state.selected);
    try std.testing.expect(!retained.findById(22).?.widget.state.selected);
    try std.testing.expect(retained.findById(23).?.widget.state.selected);
    try std.testing.expect(retained.findById(36).?.widget.state.selected);
    try std.testing.expectEqualStrings("Ready", retained.findById(36).?.widget.text);

    semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqualStrings("Ready", canvasWidgetSemanticsById(semantics, 36).?.label);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 36).?.value);
    try std.testing.expectEqual(@as(?f32, 1), canvasWidgetSemanticsById(semantics, 23).?.value);
}

test "runtime refreshes widget owned display list from canvas input" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-display-list-input", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 180, 80),
    });

    const controls = [_]canvas.Widget{.{
        .id = 2,
        .kind = .checkbox,
        .frame = geometry.RectF.init(10, 10, 120, 28),
        .text = "Live",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 180, 80), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 18,
        .y = 20,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 18,
        .y = 20,
    } });

    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_checkbox_check = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 4)) saw_checkbox_check = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_checkbox_check);
}

test "runtime routes canvas widget pointers using design token layers" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-layered-input", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 100),
    });

    const widgets = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(8, 8, 96, 64),
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 80, 32),
            .text = "Base",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 160, 100), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var route_entries: [4]canvas.WidgetEventRouteEntry = undefined;
    const default_route = (try harness.runtime.routeCanvasWidgetPointerInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 20,
    }, &route_entries)).?;
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), default_route.target.?.id);

    _ = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", .{
        .layer = .{
            .base = 10,
            .floating = 20,
            .overlay = 0,
            .modal = 30,
        },
    });
    const lowered_overlay_route = (try harness.runtime.routeCanvasWidgetPointerInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 20,
    }, &route_entries)).?;
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), lowered_overlay_route.target.?.id);
}

test "runtime selects canvas widgets from pointer and keyboard activation" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-select-controls", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 150),
    });

    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .frame = geometry.RectF.init(10, 10, 120, 32),
            .text = "Inbox",
        },
        .{
            .id = 3,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(10, 52, 120, 32),
            .text = "Grid",
        },
        .{
            .id = 4,
            .kind = .data_cell,
            .frame = geometry.RectF.init(10, 94, 120, 32),
            .text = "Edge API",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 240, 150), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 20,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(2).?.widget.value);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 62,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 220,
        .y = 62,
    } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(3).?.widget.state.selected);

    harness.runtime.views[0].canvas_widget_focused_id = 4;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "space",
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    harness.runtime.views[0].canvas_widget_focused_id = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .option = true },
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(3).?.widget.state.selected);
    try std.testing.expect(retained.findById(4).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(4).?.widget.value);

    const semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expectEqual(@as(?f32, 0), semantics[1].value);
    try std.testing.expectEqual(@as(?f32, 1), semantics[2].value);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].selected);
    try std.testing.expect(!snapshot.widgets[1].selected);
    try std.testing.expect(snapshot.widgets[2].selected);
}

test "runtime clears sibling canvas selections in retained groups" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-select-groups", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(30, 40, 260, 180),
    });

    const nav_items = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 32),
            .text = "Overview",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 32),
            .text = "Customers",
        },
    };
    const mode_items = [_]canvas.Widget{
        .{
            .id = 4,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(0, 0, 64, 32),
            .text = "List",
            .state = .{ .selected = true },
        },
        .{
            .id = 5,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(0, 0, 64, 32),
            .text = "Grid",
        },
    };
    const menu_items = [_]canvas.Widget{
        .{
            .id = 6,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Rename",
            .state = .{ .selected = true },
        },
        .{
            .id = 7,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Archive",
        },
    };
    const groups = [_]canvas.Widget{
        .{
            .id = 10,
            .kind = .list,
            .frame = geometry.RectF.init(10, 10, 120, 68),
            .layout = .{ .gap = 4 },
            .children = &nav_items,
        },
        .{
            .id = 0,
            .kind = .row,
            .frame = geometry.RectF.init(10, 96, 140, 32),
            .layout = .{ .gap = 8 },
            .children = &mode_items,
        },
        .{
            .id = 11,
            .kind = .menu_surface,
            .frame = geometry.RectF.init(160, 10, 90, 68),
            .layout = .{ .gap = 4 },
            .children = &menu_items,
        },
    };
    var nodes: [10]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &groups }, geometry.RectF.init(0, 0, 260, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 50,
    } });
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 50,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(2).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.widget.value);
    try std.testing.expect(retained.findById(3).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(3).?.widget.value);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(40, 50, 120, 68), harness.runtime.pendingDirtyRegions()[0]);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.runtime.views[0].canvas_widget_focused_id = 5;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(4).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(4).?.widget.value);
    try std.testing.expect(retained.findById(5).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(5).?.widget.value);

    const semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(?f32, 0), semantics[1].value);
    try std.testing.expectEqual(@as(?f32, 1), semantics[2].value);
    try std.testing.expectEqual(@as(?f32, 0), semantics[3].value);
    try std.testing.expectEqual(@as(?f32, 1), semantics[4].value);
    try std.testing.expect(semantics[6].actions.press);
    try std.testing.expect(semantics[6].actions.select);
    try std.testing.expect(semantics[7].actions.press);
    try std.testing.expect(semantics[7].actions.select);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.runtime.views[0].canvas_widget_focused_id = 7;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "space",
    } });

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(6).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(6).?.widget.value);
    try std.testing.expect(retained.findById(7).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(7).?.widget.value);

    const menu_semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(?f32, 0), menu_semantics[6].value);
    try std.testing.expectEqual(@as(?f32, 1), menu_semantics[7].value);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].selected);
    try std.testing.expect(snapshot.widgets[2].selected);
    try std.testing.expect(!snapshot.widgets[3].selected);
    try std.testing.expect(snapshot.widgets[4].selected);
    try std.testing.expect(!snapshot.widgets[6].selected);
    try std.testing.expect(snapshot.widgets[7].selected);
}

test "runtime applies keyboard values to focused canvas controls" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-control-keyboard", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 180),
    });

    const controls = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 48, 120, 28),
            .text = "Alerts",
            .state = .{ .selected = true },
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(10, 88, 100, 32),
            .value = 0.5,
        },
        .{
            .id = 5,
            .kind = .accordion,
            .frame = geometry.RectF.init(10, 126, 140, 36),
            .text = "Advanced",
        },
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 240, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 2;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "space",
    } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    harness.runtime.views[0].canvas_widget_focused_id = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    harness.runtime.views[0].canvas_widget_focused_id = 4;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
    } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .option = true },
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);

    harness.runtime.views[0].canvas_widget_focused_id = 5;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try std.testing.expectEqual(@as(u64, 7), harness.runtime.views[0].widget_revision);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.nodes[1].widget.value);
    try std.testing.expect(!retained.nodes[2].widget.state.selected);
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[2].widget.value);
    try std.testing.expectEqual(@as(f32, 1), retained.nodes[3].widget.value);
    try std.testing.expect(retained.findById(5).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(5).?.widget.value);

    const semantics = runtimeViewWidgetSemantics(&harness.runtime.views[0]);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expectEqual(@as(?f32, 0), semantics[1].value);
    try std.testing.expectEqual(@as(?f32, 1), semantics[2].value);
    try std.testing.expectEqual(@as(?f32, 1), semantics[3].value);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_full_slider_active = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(4, 2)) {
                    try std.testing.expectEqual(@as(f32, 100), fill.rect.width);
                    saw_full_slider_active = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_full_slider_active);
}

test "runtime dispatches canvas widget commands from pointer and keyboard activation" {
    const TestApp = struct {
        command_count: u32 = 0,
        widget_pointer_count: u32 = 0,
        widget_keyboard_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-command", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
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
                .canvas_widget_pointer => self.widget_pointer_count += 1,
                .canvas_widget_keyboard => self.widget_keyboard_count += 1,
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
        .frame = geometry.RectF.init(0, 0, 240, 200),
    });

    const widgets = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 96, 32),
            .text = "Run",
            .command = "widget.run",
        },
        .{
            .id = 3,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 56, 140, 32),
            .text = "Q",
        },
        .{
            .id = 4,
            .kind = .menu_item,
            .frame = geometry.RectF.init(128, 12, 96, 32),
            .text = "Archive",
            .command = "widget.archive",
        },
        .{
            .id = 5,
            .kind = .select,
            .frame = geometry.RectF.init(12, 96, 120, 32),
            .text = "Environment",
            .command = "widget.select",
        },
        .{
            .id = 6,
            .kind = .combobox,
            .frame = geometry.RectF.init(12, 136, 140, 32),
            .text = "Production",
            .command = "widget.combo",
        },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 240, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const combobox_semantics = canvasWidgetSemanticsById(runtimeViewWidgetSemantics(&harness.runtime.views[0]), 6).?;
    try std.testing.expectEqual(canvas.WidgetRole.textbox, combobox_semantics.role);
    try std.testing.expectEqualStrings("Production", combobox_semantics.text_value);
    try std.testing.expect(combobox_semantics.actions.press);
    try std.testing.expect(combobox_semantics.actions.set_text);
    try std.testing.expect(combobox_semantics.actions.set_selection);

    harness.runtime.views[0].canvas_widget_focused_id = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try std.testing.expectEqualStrings("Qa", (try harness.runtime.canvasWidgetLayout(1, "canvas")).nodes[2].widget.text);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 20,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("widget.run", app_state.last_name);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqualStrings("canvas", app_state.last_view_label);

    harness.runtime.views[0].canvas_widget_focused_id = 2;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 3), app_state.widget_keyboard_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .option = true },
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 140,
        .y = 20,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 140,
        .y = 20,
    } });
    try std.testing.expectEqual(@as(u32, 3), app_state.command_count);
    try std.testing.expectEqualStrings("widget.archive", app_state.last_name);
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(4).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), retained.findById(4).?.widget.value);

    harness.runtime.views[0].canvas_widget_focused_id = 4;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try std.testing.expectEqual(@as(u32, 4), app_state.command_count);
    try std.testing.expectEqualStrings("widget.archive", app_state.last_name);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(4).?.widget.state.selected);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 108,
    } });
    try std.testing.expectEqual(@as(u32, 5), app_state.command_count);
    try std.testing.expectEqualStrings("widget.select", app_state.last_name);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 108,
    } });
    try std.testing.expectEqual(@as(u32, 5), app_state.command_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 144,
    } });
    try std.testing.expectEqual(@as(u32, 6), app_state.command_count);
    try std.testing.expectEqualStrings("widget.combo", app_state.last_name);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = 20,
        .y = 144,
    } });
    try std.testing.expectEqual(@as(u32, 6), app_state.command_count);

    harness.runtime.views[0].canvas_widget_focused_id = 6;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try std.testing.expectEqual(@as(u32, 7), app_state.command_count);
    try std.testing.expectEqualStrings("widget.combo", app_state.last_name);
}
