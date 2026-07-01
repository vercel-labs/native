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

test "runtime dismisses nearest canvas floating surface with escape" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-dismiss", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 360, 220),
    });

    const popover_children = [_]canvas.Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(16, 16, 100, 32),
        .text = "Copy",
    }};
    const dialog_children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(18, 52, 160, 96),
            .semantics = .{ .label = "Actions" },
            .children = &popover_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(196, 52, 100, 32),
            .text = "Keep",
        },
    };
    const dialog = canvas.Widget{
        .id = 1,
        .kind = .dialog,
        .frame = geometry.RectF.init(12, 12, 320, 180),
        .text = "Command palette",
        .semantics = .{ .label = "Command palette" },
        .children = &dialog_children,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(dialog, dialog.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 3;
    harness.runtime.views[0].canvas_widget_hovered_id = 3;
    harness.runtime.views[0].canvas_widget_pressed_id = 3;
    harness.runtime.views[0].canvas_widget_cursor = .pointing_hand;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    try std.testing.expect((try harness.runtime.canvasDisplayList(1, "canvas")).findCommandById(testCanvasWidgetPartId(2, 2)) != null);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(1).?.widget.semantics.hidden);
    try std.testing.expect(retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);

    for (runtimeViewWidgetSemantics(&harness.runtime.views[0])) |node| {
        try std.testing.expect(node.id != 2);
        try std.testing.expect(node.id != 3);
    }
    const retained_after_dismiss = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(2, 2)) == null);
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(3, 1)) == null);
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(1, 2)) != null);
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(4, 1)) != null);
}

test "runtime dismisses canvas floating surfaces from automation and accessibility actions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-action-dismiss", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn install(runtime: *Runtime) !void {
            const popover_children = [_]canvas.Widget{.{
                .id = 3,
                .kind = .button,
                .frame = geometry.RectF.init(12, 12, 92, 30),
                .text = "Copy",
            }};
            const children = [_]canvas.Widget{
                .{
                    .id = 1,
                    .kind = .button,
                    .frame = geometry.RectF.init(12, 12, 104, 32),
                    .text = "Open",
                },
                .{
                    .id = 2,
                    .kind = .popover,
                    .frame = geometry.RectF.init(36, 52, 140, 76),
                    .semantics = .{ .label = "Actions" },
                    .children = &popover_children,
                },
            };
            var nodes: [4]canvas.WidgetLayoutNode = undefined;
            const layout = try canvas.layoutWidgetTree(.{ .id = 10, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 160), &nodes);
            _ = try runtime.setCanvasWidgetLayout(1, "canvas", layout);
        }

        fn snapshotWidget(snapshot: automation.snapshot.Input, id: u64) ?automation.snapshot.Widget {
            for (snapshot.widgets) |widget| {
                if (widget.id == id) return widget;
            }
            return null;
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
        .frame = geometry.RectF.init(20, 30, 260, 180),
    });

    try Fixture.install(&harness.runtime);
    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(Fixture.snapshotWidget(snapshot, 2).?.actions.dismiss);
    try std.testing.expect(!Fixture.snapshotWidget(snapshot, 1).?.actions.dismiss);
    try std.testing.expectError(error.InvalidCommand, dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 1, .action = .dismiss }));

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 2, .action = .dismiss });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expect(canvasWidgetSemanticsById(runtimeViewWidgetSemantics(&harness.runtime.views[0]), 2) == null);
    try std.testing.expect(canvasWidgetSemanticsById(runtimeViewWidgetSemantics(&harness.runtime.views[0]), 3) == null);
    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(Fixture.snapshotWidget(snapshot, 2) == null);
    try std.testing.expect(Fixture.snapshotWidget(snapshot, 3) == null);

    try Fixture.install(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 2,
        .action = .dismiss,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expect(canvasWidgetSemanticsById(runtimeViewWidgetSemantics(&harness.runtime.views[0]), 2) == null);
    try std.testing.expect(canvasWidgetSemanticsById(runtimeViewWidgetSemantics(&harness.runtime.views[0]), 3) == null);
}

test "runtime dismisses focused canvas floating surface from outside pointer down" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-outside-dismiss", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const popover_children = [_]canvas.Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 92, 32),
        .text = "Copy",
    }};
    const widgets = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(20, 20, 128, 72),
            .children = &popover_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(176, 40, 92, 32),
            .text = "Outside",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 3;
    harness.runtime.views[0].canvas_widget_hovered_id = 3;
    harness.runtime.views[0].canvas_widget_cursor = .pointing_hand;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 36,
        .y = 36,
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_pressed_id);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 190,
        .y = 52,
    } });

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);

    for (runtimeViewWidgetSemantics(&harness.runtime.views[0])) |node| {
        try std.testing.expect(node.id != 2);
        try std.testing.expect(node.id != 3);
    }
    const retained_after_dismiss = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(2, 2)) == null);
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(3, 1)) == null);
    try std.testing.expect(retained_after_dismiss.findCommandById(testCanvasWidgetPartId(4, 1)) != null);
}

test "runtime traps tab focus inside canvas floating surfaces" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-focus-scope", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 360, 200),
    });

    const popover_children = [_]canvas.Widget{
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 96, 32),
            .text = "First",
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(12, 52, 96, 32),
            .text = "Second",
        },
    };
    const widgets = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 20, 90, 32),
            .text = "Before",
        },
        .{
            .id = 10,
            .kind = .popover,
            .frame = geometry.RectF.init(120, 20, 140, 104),
            .children = &popover_children,
        },
        .{
            .id = 5,
            .kind = .button,
            .frame = geometry.RectF.init(280, 20, 70, 32),
            .text = "After",
        },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 360, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 3;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);
}

test "runtime keeps single focus target scoped inside canvas floating surface" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-single-focus-scope", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 140),
    });

    const popover_children = [_]canvas.Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(12, 12, 96, 32),
        .text = "Only",
    }};
    const widgets = [_]canvas.Widget{
        .{
            .id = 10,
            .kind = .popover,
            .frame = geometry.RectF.init(20, 20, 140, 64),
            .children = &popover_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(180, 20, 64, 32),
            .text = "After",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 3;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
}

test "runtime keeps floating surface open when escape cancels text composition" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-surface-dismiss-ime", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 260, 160),
    });

    const popover_children = [_]canvas.Widget{.{
        .id = 3,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 12, 140, 34),
        .text = "Cafe",
        .text_selection = canvas.TextSelection.collapsed(4),
        .text_composition = canvas.TextRange.init(2, 4),
    }};
    const popover = canvas.Widget{
        .id = 2,
        .kind = .popover,
        .frame = geometry.RectF.init(18, 18, 180, 72),
        .children = &popover_children,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(popover, popover.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 3;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(2).?.widget.semantics.hidden);
    try std.testing.expect(retained.findById(3).?.widget.text_composition == null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect((try harness.runtime.canvasDisplayList(1, "canvas")).findCommandById(testCanvasWidgetPartId(2, 2)) != null);
}

test "runtime clears canvas widget interaction state when layout replacement disables it" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-disabled-interaction", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(40, 50, 220, 120),
    });

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.runtime.views[0].canvas_widget_cursor);

    const disabled_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
        .state = .{ .disabled = true },
    }};
    var disabled_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const disabled_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &disabled_children }, geometry.RectF.init(0, 0, 220, 120), &disabled_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", disabled_layout);

    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expect(!snapshot.widgets[0].enabled);
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(!snapshot.widgets[0].hovered);
    try std.testing.expect(!snapshot.widgets[0].pressed);
}
