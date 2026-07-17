const support = @import("test_support.zig");
const canvas_limits = @import("canvas_limits.zig");
const max_canvas_widget_anchored_per_view = canvas_limits.max_canvas_widget_anchored_per_view;
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
    // Seed a non-arrow cursor (only a link hover produces this in the
    // wild) so the reset back to arrow below is observable.
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

test "runtime escape with no focused widget dismisses the topmost mounted anchored surface" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-escape-fallback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 360, 220),
    });

    // Two anchored menus mounted at once (two crumb switchers open),
    // nothing focused: the trigger was plain text and took no focus.
    const first_menu = [_]canvas.Widget{.{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(8, 28, 120, 60),
        .layout = .{ .anchor = .{} },
    }};
    const second_menu = [_]canvas.Widget{.{
        .id = 5,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(148, 28, 120, 60),
        .layout = .{ .anchor = .{} },
    }};
    const crumbs = [_]canvas.Widget{
        .{ .id = 2, .kind = .stack, .frame = geometry.RectF.init(8, 8, 120, 20), .children = &first_menu },
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(148, 8, 120, 20), .children = &second_menu },
    };
    const root = canvas.Widget{
        .id = 1,
        .kind = .column,
        .frame = geometry.RectF.init(0, 0, 360, 220),
        .children = &crumbs,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, root.frame, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);

    const escape: platform.Event = .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } };

    // Topmost (last in tree order — the late z-pass paints it on top)
    // dismisses first; the earlier surface stays.
    try harness.runtime.dispatchPlatformEvent(app, escape);
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(5).?.widget.semantics.hidden);
    try std.testing.expect(!retained.findById(3).?.widget.semantics.hidden);

    // The next Escape finds the remaining mounted surface.
    try harness.runtime.dispatchPlatformEvent(app, escape);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.findById(3).?.widget.semantics.hidden);

    // With nothing mounted, Escape dismisses nothing (no error, no
    // stray invalidation-by-dismissal).
    try harness.runtime.dispatchPlatformEvent(app, escape);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(1).?.widget.semantics.hidden);
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
    // Seed a non-arrow cursor (only a link hover produces this in the
    // wild) so the settle back to arrow below is observable.
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
    // The button outside the popover hovers with the native arrow — the
    // seeded link-hand from above settles back to the control register.
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
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
    // Native register: a pressed button keeps the arrow cursor.
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);

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

// -------------------------------------------- anchored-tooltip hover intent
//
// Anchored tooltips are RUNTIME-owned presentation chrome: the model never
// hears hover, and visibility steps only on journaled input timestamps and
// presented-frame timestamps (never a wall clock), so every scenario below
// is also a replay-determinism statement.

const TooltipMsg = union(enum) { pressed };
const TooltipUi = canvas.Ui(TooltipMsg);

/// Three toolbar triggers, each owning an anchored tooltip through the
/// stack-wraps-trigger-plus-surface pattern the dropdown uses. The third
/// declares `tooltip_delay = 0` (markup `tooltip-delay="0"`), the
/// instant-show escape hatch.
fn buildTooltipToolbar(ui: *TooltipUi) TooltipUi.Node {
    return ui.row(.{ .gap = 12, .padding = 16 }, .{
        ui.el(.stack, .{}, .{
            ui.button(.{}, "Bold"),
            ui.el(.tooltip, .{ .text = "Bold the selection", .anchor = .above }, .{}),
        }),
        ui.el(.stack, .{}, .{
            ui.button(.{}, "Italic"),
            ui.el(.tooltip, .{ .text = "Italicize the selection", .anchor = .above }, .{}),
        }),
        ui.el(.stack, .{}, .{
            ui.button(.{}, "Link"),
            ui.el(.tooltip, .{ .text = "Insert a link", .anchor = .above, .tooltip_delay = 0 }, .{}),
        }),
    });
}

const TooltipToolbar = struct {
    button_ids: [3]canvas.ObjectId,
    button_centers: [3]geometry.PointF,
    tooltip_ids: [3]canvas.ObjectId,
};

fn installTooltipToolbar(harness: anytype, app: App, arena: std.mem.Allocator) !TooltipToolbar {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 420, 160),
    });
    var ui = TooltipUi.init(arena);
    const tree = try ui.finalize(buildTooltipToolbar(&ui));
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 420, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    var toolbar: TooltipToolbar = .{ .button_ids = @splat(0), .button_centers = @splat(geometry.PointF.zero()), .tooltip_ids = @splat(0) };
    var button_count: usize = 0;
    var tooltip_count: usize = 0;
    const view = &harness.runtime.views[0];
    for (view.widget_layout_nodes[0..view.widget_layout_node_count]) |node| {
        switch (node.widget.kind) {
            .button => {
                toolbar.button_ids[button_count] = node.widget.id;
                toolbar.button_centers[button_count] = node.frame.center();
                button_count += 1;
            },
            .tooltip => {
                toolbar.tooltip_ids[tooltip_count] = node.widget.id;
                tooltip_count += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), button_count);
    try std.testing.expectEqual(@as(usize, 3), tooltip_count);
    return toolbar;
}

fn tooltipHover(harness: anytype, app: App, point: geometry.PointF, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .x = point.x,
        .y = point.y,
        .timestamp_ns = timestamp_ns,
    } });
}

fn tooltipFrame(harness: anytype, app: App, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(420, 160),
        .timestamp_ns = timestamp_ns,
    } });
}

fn tooltipHidden(harness: anytype, tooltip_id: canvas.ObjectId) !bool {
    const view = &harness.runtime.views[0];
    const node_index = view.canvasWidgetNodeIndexById(tooltip_id) orelse return error.TestUnexpectedResult;
    return view.widget_layout_nodes[node_index].widget.semantics.hidden;
}

const tooltip_t0: u64 = 10_000_000_000;
const tooltip_ms: u64 = std.time.ns_per_ms;

test "sweeping across tooltip triggers shows nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-sweep", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Anchored tooltips adopt hidden: nothing is shown before any hover.
    for (toolbar.tooltip_ids[0..2]) |tooltip_id| {
        try std.testing.expect(try tooltipHidden(harness, tooltip_id));
    }

    // The pointer crosses Bold and Italic 80ms apart — well under the
    // 600ms intent delay — with a presented frame after each move. No
    // tooltip frame paints anywhere along the sweep.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 16 * tooltip_ms);
    try tooltipHover(harness, app, toolbar.button_centers[1], tooltip_t0 + 80 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 96 * tooltip_ms);
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 160 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 176 * tooltip_ms);

    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    for (toolbar.tooltip_ids[0..2]) |tooltip_id| {
        try std.testing.expect(try tooltipHidden(harness, tooltip_id));
    }
}

test "hover dwell past the delay shows the anchored tooltip on the frame clock" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-dwell", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Hover arms the delay; frames keep painting while it runs (the
    // pump), but the tooltip stays hidden short of the deadline.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipFrame(harness, app, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // An armed delay keeps the frame channel alive so the deadline can
    // fire without any further input.
    try std.testing.expect(harness.runtime.invalidated);

    // The first presented frame at/past the deadline shows the tooltip —
    // a deterministic frame on the recorded clock.
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[1]));

    // Leaving the trigger hides it again.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
}

test "leaving the trigger before the delay disarms the tooltip" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-disarm", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 300 * tooltip_ms);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Off the trigger before the deadline: disarmed for good — frames
    // past the would-be deadline change nothing.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 400 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipFrame(harness, app, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
}

test "the warm window transfers instantly between triggers and expires" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-warm", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn the first tooltip with a full dwell.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Move to the sibling inside the warm window: Bold's tooltip hides
    // and Italic's shows IMMEDIATELY — no delay, no frame needed.
    try tooltipHover(harness, app, toolbar.button_centers[1], tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[1]));

    // Leaving re-warms; a return WITHIN the window is instant again.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 1200 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Leave and let the warm window LAPSE: the next trigger waits the
    // full delay again.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 1300 * tooltip_ms);
    try tooltipHover(harness, app, toolbar.button_centers[1], tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipFrame(harness, app, tooltip_t0 + 2700 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "tooltip-delay zero restores the instant hover show" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-instant", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Link declares tooltip_delay = 0: the hover event itself shows the
    // tooltip, no dwell, no warm window, no frame in between.
    try tooltipHover(harness, app, toolbar.button_centers[2], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[2]));

    // And leaving hides it just as immediately.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
}

fn tooltipNodeFrame(harness: anytype, widget_id: canvas.ObjectId) !geometry.RectF {
    const view = &harness.runtime.views[0];
    const node_index = view.canvasWidgetNodeIndexById(widget_id) orelse return error.TestUnexpectedResult;
    return view.widget_layout_nodes[node_index].frame;
}

test "pointer travels into hoverable tooltip content and it stays open until leaving both" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-hoverable", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn Bold's tooltip with a full dwell.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // The anchored tooltip floats ABOVE the trigger with a gap between
    // them; crossing that gap (a point between the tooltip's bottom
    // edge and the trigger's top edge, inside the transit corridor)
    // must not hide it — WCAG 1.4.13 wants hover-revealed content
    // reachable by pointer, and Base UI tooltips default `hoverable`.
    const tooltip_frame = try tooltipNodeFrame(harness, toolbar.tooltip_ids[0]);
    const trigger_frame = try tooltipNodeFrame(harness, toolbar.button_ids[0]);
    try std.testing.expect(tooltip_frame.maxY() < trigger_frame.y);
    const gap_point = geometry.PointF{
        .x = toolbar.button_centers[0].x,
        .y = (tooltip_frame.maxY() + trigger_frame.y) / 2,
    };
    try tooltipHover(harness, app, gap_point, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Frames inside the transit bound change nothing.
    try tooltipFrame(harness, app, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Arriving inside the tooltip's own frame holds it open outright
    // (the tooltip stays out of hit-testing; the hold is the intent
    // machine's geometric test), and gliding within it stays free.
    try tooltipHover(harness, app, tooltip_frame.center(), tooltip_t0 + 850 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_transit_deadline_ns);
    try tooltipHover(harness, app, .{ .x = tooltip_frame.center().x + 4, .y = tooltip_frame.center().y }, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Leaving BOTH regions (away from the corridor) hides on the move
    // itself, with the usual pointer-hide warm window: the neighboring
    // trigger explains itself instantly.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 2100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try tooltipHover(harness, app, toolbar.button_centers[1], tooltip_t0 + 2200 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "a pointer parked in the anchor gap resolves the transit on the frame clock" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-transit", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    const tooltip_frame = try tooltipNodeFrame(harness, toolbar.tooltip_ids[0]);
    const trigger_frame = try tooltipNodeFrame(harness, toolbar.button_ids[0]);
    const gap_point = geometry.PointF{
        .x = toolbar.button_centers[0].x,
        .y = (tooltip_frame.maxY() + trigger_frame.y) / 2,
    };
    try tooltipHover(harness, app, gap_point, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // The transit is BOUNDED: it holds while frames stay inside the
    // grace, keeps the frame channel pumping so the deadline can fire
    // without further input, and a pointer that parks in the gap
    // resolves on the recorded frame clock — hidden, with the usual
    // pointer-hide warm window (replay hits the same frame).
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_transit_deadline_ns != 0);
    try std.testing.expect(harness.runtime.invalidated);
    try tooltipFrame(harness, app, tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipFrame(harness, app, tooltip_t0 + 1101 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
}

test "a collinear apex holds only the corridor's segment, never the infinite line" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-degenerate", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn Bold's tooltip with a full dwell, then park the pointer ON
    // the trigger's top edge: still the owner (top edge is inclusive),
    // so the corridor apex re-seeds EXACTLY collinear with that edge —
    // the degenerate-fan setup, since the apex-to-adjacent-corner
    // triangle over the trigger's top edge now has zero area.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    const trigger_frame = try tooltipNodeFrame(harness, toolbar.button_ids[0]);
    const tooltip_frame = try tooltipNodeFrame(harness, toolbar.tooltip_ids[0]);
    const edge_apex = geometry.PointF{ .x = toolbar.button_centers[0].x, .y = trigger_frame.y };
    try tooltipHover(harness, app, edge_apex, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(edge_apex.x, harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(edge_apex.y, harness.runtime.views[0].canvas_tooltip_pointer_from.y);

    // The NORMAL corridor still works from this apex: stepping into the
    // anchor gap keeps the tooltip up on the bounded grace, and a frame
    // inside the grace changes nothing.
    const gap_point = geometry.PointF{
        .x = toolbar.button_centers[0].x,
        .y = (tooltip_frame.maxY() + trigger_frame.y) / 2,
    };
    try tooltipHover(harness, app, gap_point, tooltip_t0 + 750 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_transit_deadline_ns != 0);
    try tooltipFrame(harness, app, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Motion ALONG the apex's collinear line, beyond the trigger's
    // actual corners (into the row padding left of Bold): the collapsed
    // triangle contains only its boundary segment, so this is OUTSIDE
    // the corridor — the tooltip hides on the move itself with the
    // usual pointer-hide warmth instead of re-arming the grace forever
    // along the infinite line.
    try std.testing.expect(trigger_frame.x > 4);
    const along_line = geometry.PointF{ .x = 2, .y = trigger_frame.y };
    try tooltipHover(harness, app, along_line, tooltip_t0 + 850 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_transit_deadline_ns);
}

test "pointer cancel dismisses the content-held tooltip immediately, focus-shown survives" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-cancel-held", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn Bold's tooltip, then park the pointer INSIDE the tooltip's
    // own frame: the content hold — and, because the tooltip is not a
    // hit target, hovered_id is already 0 here, so a cancel-to-0 is no
    // hover transition and the transition gate alone cannot see it.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    const tooltip_frame = try tooltipNodeFrame(harness, toolbar.tooltip_ids[0]);
    try tooltipHover(harness, app, tooltip_frame.center(), tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // The pointer leaves the view: cancel's immediate-hide semantics
    // hold for the content-held tooltip too — hidden on the cancel
    // itself, warm window closed, stored position gone, and no frame
    // ever resurrects it.
    try tooltipPointer(harness, app, .pointer_cancel, tooltip_frame.center(), tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_transit_deadline_ns);
    try std.testing.expect(harness.runtime.views[0].canvas_last_pointer_position == null);
    try tooltipFrame(harness, app, tooltip_t0 + 1500 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // A FOCUS-shown tooltip survives a pointer cancel: the keyboard
    // holds it, and the pointer's departure says nothing about it —
    // unlike view blur, where the keyboard itself leaves.
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try tooltipPointer(harness, app, .pointer_cancel, .{ .x = 5, .y = 150 }, tooltip_t0 + 1700 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));
}

/// A scrollable toolbar column: a scroll_view whose two stacks each
/// wrap a trigger button and its anchored tooltip, viewport 40 points
/// tall so a 40-point scroll swaps which trigger sits under a
/// stationary pointer. Explicit ids; `first_delay_zero` opts the first
/// tooltip into instant show for the tests that need a shown tooltip
/// without a dwell.
fn installTooltipScrollFixture(harness: anytype, app: App, first_delay_zero: bool) !void {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 40),
    });
    const first_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "One" },
        .{ .id = 5, .kind = .tooltip, .text = "First action", .tooltip_delay_ms = if (first_delay_zero) 0 else -1, .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const second_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "Two" },
        .{ .id = 7, .kind = .tooltip, .text = "Second action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 160, 32), .children = &first_children },
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 48, 160, 32), .children = &second_children },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &stacks },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

fn tooltipScroll(harness: anytype, app: App, delta_y: f32, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = delta_y,
        .timestamp_ns = timestamp_ns,
    } });
}

test "wheel scroll steps the tooltip intent machine like a pointer move" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-scroll", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipScrollFixture(harness, app, false);

    // Hover trigger One: its tooltip arms the default delay.
    try tooltipHover(harness, app, .{ .x = 12, .y = 12 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_armed_id);

    // Scrolling One out from under the stationary pointer disarms it,
    // and trigger Two arriving under the pointer arms per normal — the
    // same transition a real pointer move onto Two would step.
    try tooltipScroll(harness, app, 40, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_owner_id);

    // The scroll-armed dwell completes on the frame clock like any other.
    try tooltipFrame(harness, app, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 7));

    // Scrolling back swaps triggers again: the SHOWN tooltip hides with
    // the usual warm window, so One's tooltip shows instantly.
    try tooltipScroll(harness, app, -40, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 7));
    try std.testing.expect(!try tooltipHidden(harness, 5));

    // A scroll that leaves the pointer over neither trigger (the
    // scroll view's own gap) hides the shown tooltip on the scroll
    // itself (point-blind semantics: the content moved, not the
    // pointer — no transit corridor applies).
    try tooltipScroll(harness, app, 24, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
}

test "keyboard scrolling re-hit-tests the stationary pointer against the post-scroll tree" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-scroll-key", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipScrollFixture(harness, app, true);

    // Focus the scroll view with a click on trigger-free space, then
    // earn One's tooltip (delay 0) with a hover; the click's press
    // reset already ran, so the hover re-earns cleanly.
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 12, .y = 36 }, tooltip_t0);
    try tooltipPointer(harness, app, .pointer_up, .{ .x = 12, .y = 36 }, tooltip_t0 + 20 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_focused_id);
    try tooltipHover(harness, app, .{ .x = 12, .y = 12 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);

    // End scrolls the focused scroll view to its bottom. The keyboard
    // scroll carries no pointer position of its own, so the reconcile
    // re-hit-tests the STORED one (the pointer is stationary at 12,12):
    // trigger One scrolled out from under it — its tooltip hides with
    // the usual warm window — and trigger Two arrived under it, so the
    // warm window transfers the show exactly as a wheel scroll (or a
    // real pointer move) would. Kinetic steps and native drivers share
    // this exact reconcile.
    try tooltipKey(harness, app, "end", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
    try std.testing.expect(!try tooltipHidden(harness, 7));

    // Home scrolls back to the top: Two leaves from under the pointer,
    // One returns beneath it, and the warm transfer swaps the shown
    // tooltip back — symmetric with the wheel path's sweep.
    try tooltipKey(harness, app, "home", tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 7));
    try std.testing.expect(!try tooltipHidden(harness, 5));
}

test "a keyboard scroll hides the shown tooltip whose trigger stays partially visible but slid off the pointer" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-scroll-partial", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    // Tall triggers in a short viewport: a page scroll leaves One
    // PARTIALLY visible, the exact hole the old point-blind
    // reconciliation fell into — the trigger still existed in the
    // interactive tree, so hover ownership (and the shown tooltip)
    // was retained even though the stationary pointer no longer sat
    // on it.
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 40),
    });
    const first_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 36), .text = "One" },
        .{ .id = 5, .kind = .tooltip, .text = "First action", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const second_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 36), .text = "Two" },
        .{ .id = 7, .kind = .tooltip, .text = "Second action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 8, 160, 36), .children = &first_children },
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 78, 160, 36), .children = &second_children },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &stacks },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Focus the scroll view via the gap above One, then earn One's
    // tooltip (delay 0) with the pointer parked at (12, 26).
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 12, .y = 4 }, tooltip_t0);
    try tooltipPointer(harness, app, .pointer_up, .{ .x = 12, .y = 4 }, tooltip_t0 + 20 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_focused_id);
    try tooltipHover(harness, app, .{ .x = 12, .y = 26 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);

    // PageDown slides One up so it stays partially visible but ends
    // above the stationary pointer, which now sits in the gap between
    // the triggers: hover moves to the scroll view and the shown
    // tooltip hides — ownership follows the re-hit-test, not the
    // trigger's mere survival.
    try tooltipKey(harness, app, "pagedown", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expect(harness.runtime.views[0].canvasWidgetNodeIndexById(2) != null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));

    // Let the pointer-hide warm window lapse, then PageDown again:
    // trigger Two scrolls UNDER the stored pointer position and arms
    // the normal delay — a fresh dwell, not a warm transfer.
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try tooltipKey(harness, app, "pagedown", tooltip_t0 + 2100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    // The corridor apex re-seeded to the stored position, so the
    // eventual leave fans out from where the pointer really is.
    try std.testing.expectEqual(@as(f32, 12), harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(@as(f32, 26), harness.runtime.views[0].canvas_tooltip_pointer_from.y);
}

test "point-blind scrolls without a trustworthy pointer position close tooltip intent" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-scroll-blind", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipScrollFixture(harness, app, true);

    // The pointer LEAVES the view mid-conversation: earn One's tooltip,
    // then the exit's pointer_cancel closes the whole pointer-owned
    // conversation (shown tooltip AND warm window — no courtesy for a
    // pointer that left) and clears the stored position.
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 12, .y = 36 }, tooltip_t0);
    try tooltipPointer(harness, app, .pointer_up, .{ .x = 12, .y = 36 }, tooltip_t0 + 20 * tooltip_ms);
    try tooltipHover(harness, app, .{ .x = 12, .y = 12 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipPointer(harness, app, .pointer_cancel, .{ .x = 12, .y = 12 }, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expect(harness.runtime.views[0].canvas_last_pointer_position == null);

    // A keyboard scroll now has no position to re-hit-test: the
    // pointer's tooltip conversation CLOSES — the warm window included
    // (an instant re-show is earned by a pointer we cannot place) —
    // instead of guessing where the departed pointer might be. Seed a
    // smoldering warm window directly (cancel already closed the real
    // one) so the blind scroll's own close stays observable.
    harness.runtime.views[0].canvas_tooltip_warm_until_ns = tooltip_t0 + 5000 * tooltip_ms;
    try tooltipKey(harness, app, "end", tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // A KEYBOARD-ONLY session (no pointer event ever): the store was
    // never seeded, so a point-blind scroll closes whatever intent is
    // pending rather than inventing a hover. Seed an armed dwell
    // directly to make the close observable.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
        .timestamp_ns = tooltip_t0 + 300 * tooltip_ms,
    } });
    harness.runtime.views[0].canvas_last_pointer_position = null;
    harness.runtime.views[0].canvas_tooltip_armed_id = 5;
    harness.runtime.views[0].canvas_tooltip_armed_owner_id = 2;
    harness.runtime.views[0].canvas_tooltip_deadline_ns = tooltip_t0 + 1000 * tooltip_ms;
    try tooltipKey(harness, app, "end", tooltip_t0 + 400 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
}

fn tooltipKey(harness: anytype, app: App, key: []const u8, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = key,
        .timestamp_ns = timestamp_ns,
    } });
}

fn tooltipPointer(harness: anytype, app: App, kind: platform.GpuSurfaceInputKind, point: geometry.PointF, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = kind,
        .x = point.x,
        .y = point.y,
        .timestamp_ns = timestamp_ns,
    } });
}

test "keyboard focus-visible shows the tooltip immediately, blur hides it, escape dismisses it" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-focus", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Tab reaches Bold with the visible ring: its tooltip shows on the
    // key itself — keyboard navigation is deliberate, no dwell, no
    // frame in between (shadcn's Base UI-backed instant focus open).
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(toolbar.button_ids[0], harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Focus moving on hides Bold's tooltip and shows Italic's, both
    // immediately.
    try tooltipKey(harness, app, "tab", tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[1]));

    // A focus hide never warms the pointer's skip window: hovering Bold
    // now ARMS the full delay instead of showing instantly — and the
    // pointer arming (or later leaving) another trigger leaves the
    // focus-shown tooltip alone.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 150 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[1]));

    // Escape dismisses the focus-shown tooltip and keeps the keyboard
    // on the trigger; nothing re-reveals without a new focus arrival.
    try tooltipKey(harness, app, "escape", tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[1]));
    try std.testing.expectEqual(toolbar.button_ids[1], harness.runtime.views[0].canvas_widget_focused_id);
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Tabbing away and back re-earns the reveal.
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "programmatic focus hides the focus-shown tooltip and reveals nothing, pointer-shown unaffected" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-programmatic-focus", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Tab earns Bold's focus-shown tooltip through the keyboard seam.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);

    // An accessibility `focus` action (the same direct write autofocus
    // and automation focus funnel through) moves focus to Italic:
    // programmatic focus is the pointer contract, so Bold's focus-owned
    // tooltip HIDES and Italic's does NOT reveal — the click-focus
    // exclusion's rationale (only keyboard focus-visible opens).
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = toolbar.button_ids[1], .action = .focus });
    try std.testing.expectEqual(toolbar.button_ids[1], harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[1]));

    // A hide without warmth: hovering another trigger now arms the full
    // delay instead of showing instantly.
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // POINTER-shown tooltips are unaffected by focus moves: earn Link's
    // tooltip by hover (delay 0), then move focus programmatically —
    // hover still holds it.
    try tooltipHover(harness, app, toolbar.button_centers[2], tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = toolbar.button_ids[0], .action = .focus });
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[2]));
}

/// The autofocus fixture: two buttons owning anchored tooltips through
/// the stack-wraps-trigger pattern. `second_autofocus` flips the second
/// button's autofocus flag on — the edge the NEXT rebuild's
/// source-driven focus move fires on.
fn setTooltipAutofocusLayout(harness: anytype, second_autofocus: bool) !void {
    const first_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "One" },
        .{ .id = 5, .kind = .tooltip, .text = "First action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const second_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "Two", .autofocus = second_autofocus },
        .{ .id = 7, .kind = .tooltip, .text = "Second action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 160, 32), .children = &first_children },
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 48, 160, 32), .children = &second_children },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .stack, .children = &stacks },
        geometry.RectF.init(0, 0, 160, 120),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

test "autofocus arriving on a rebuild hides the focus-shown tooltip and reveals nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-autofocus", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 120),
    });
    try setTooltipAutofocusLayout(harness, false);

    // Tab reaches One with the ring: its tooltip is focus-shown.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);

    // A rebuild flips Two's autofocus on (edge-triggered): the
    // source-driven focus move is programmatic — One's focus-owned
    // tooltip hides, Two's does not reveal, and Two takes focus
    // quietly (no ring; not keyboard focus-visible).
    try setTooltipAutofocusLayout(harness, true);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
    try std.testing.expect(try tooltipHidden(harness, 7));
}

test "a press cancels the armed tooltip and dismisses the shown one without leaving warmth" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-press", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Press mid-dwell: the armed intent cancels on the down, and the
    // would-be deadline passing changes nothing (no reveal mid- or
    // post-activation).
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipPointer(harness, app, .pointer_down, toolbar.button_centers[0], tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipPointer(harness, app, .pointer_up, toolbar.button_centers[0], tooltip_t0 + 150 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Earn the tooltip, then press its trigger: dismissed immediately,
    // and the press closes the warm window — the SAME unbroken hover
    // never re-shows, and a leave-and-return must re-earn the delay
    // instead of showing instantly.
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 900 * tooltip_ms);
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 2000 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 2600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipPointer(harness, app, .pointer_down, toolbar.button_centers[0], tooltip_t0 + 2700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try tooltipPointer(harness, app, .pointer_up, toolbar.button_centers[0], tooltip_t0 + 2750 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 3400 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipHover(harness, app, .{ .x = 5, .y = 150 }, tooltip_t0 + 3500 * tooltip_ms);
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 3550 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
}

test "keyboard activation dismisses the focus-shown tooltip like a press" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-activate", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Enter on the focused trigger counts as a press: the tooltip
    // dismisses and stays down while focus rests on the trigger.
    try tooltipKey(harness, app, "enter", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expectEqual(toolbar.button_ids[0], harness.runtime.views[0].canvas_widget_focused_id);
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The next focus arrival still reveals (activation dismissed one
    // tooltip, not the register).
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "view blur resets tooltip state and re-stamps hidden, keyboard- and pointer-shown alike" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-view-blur", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "other",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 200, 420, 80),
    });

    // Tab reveals the focus-shown tooltip on the canvas view.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // Focus moving to a SIBLING VIEW blurs the canvas: the keyboard
    // left the whole surface, so the focus-shown tooltip hides, the
    // machine resets, and the semantics tree carries no stale
    // visible-tooltip node.
    try harness.runtime.focusView(1, "other");
    try std.testing.expect(!harness.runtime.views[0].focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    for (runtimeViewWidgetSemantics(&harness.runtime.views[0])) |node| {
        try std.testing.expect(node.id != toolbar.tooltip_ids[0]);
    }

    // The pointer-owned register resets too: earn Link's instant
    // tooltip plus an armed dwell on Bold's, then blur — shown hides,
    // armed disarms, and the warm window closes (a later hover in the
    // returned-to view re-earns the full delay).
    try harness.runtime.focusView(1, "canvas");
    try tooltipHover(harness, app, toolbar.button_centers[2], tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0 + 150 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
    try harness.runtime.focusView(1, "other");
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
}

test "a secondary-button down dismisses the shown tooltip and the context menu still presents" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-right-click", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    // A trigger that declares a context menu AND owns an anchored
    // tooltip (delay 0 so the hover itself shows it).
    const items = [_]canvas.WidgetContextMenuItem{
        .{ .label = "Rename" },
        .{ .label = "Delete" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 80, 96, 32), .text = "Run", .context_menu = &items },
        .{ .id = 3, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try tooltipHover(harness, app, .{ .x = 58, .y = 96 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));

    // The secondary down is consumed by the context-menu gesture and
    // never reaches the widget press pipeline — but "pointer-down
    // dismisses" holds for every button: the tooltip is gone (warm
    // window included) and the native menu presents over clean glass.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .button = 1,
        .x = 58,
        .y = 96,
        .timestamp_ns = tooltip_t0 + 100 * tooltip_ms,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.context_menu_request_count);
}

test "a window-drag down dismisses the shown tooltip before the OS takes the pointer" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-window-drag", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    // A hidden-titlebar shape: a window-drag header row above a trigger
    // that owns an anchored tooltip (delay 0).
    const trigger_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(10, 80, 96, 32), .text = "Run" },
        .{ .id = 4, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 320, 40), .window_drag = true },
        .{ .id = 5, .kind = .stack, .frame = geometry.RectF.init(0, 40, 320, 160), .children = &trigger_children },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try tooltipHover(harness, app, .{ .x = 58, .y = 136 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The primary down on the drag header hands the gesture to the OS
    // and skips the whole widget press pipeline — but the press reset
    // still runs: no tooltip may float while the window moves.
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 160, .y = 20 }, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 4));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
}

test "a content-to-gap transit armed by a 0-to-0 hover still pumps the idle frame clock" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-transit-idle", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn Bold's tooltip, then park INSIDE its frame: the content
    // hold, with hovered_id == 0 (the tooltip is not a hit target).
    try tooltipHover(harness, app, toolbar.button_centers[0], tooltip_t0);
    try tooltipFrame(harness, app, tooltip_t0 + 600 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    const tooltip_frame = try tooltipNodeFrame(harness, toolbar.tooltip_ids[0]);
    const trigger_frame = try tooltipNodeFrame(harness, toolbar.button_ids[0]);
    try tooltipHover(harness, app, tooltip_frame.center(), tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_transit_deadline_ns);

    // Step from the content into the anchor gap: hover stays 0 on BOTH
    // sides (0 -> 0), so nothing about the interaction state changes —
    // the transit grace this move arms is the ONLY new fact. The pump
    // obligation must derive from the pending deadline itself, or an
    // idle app never plans the frame the deadline needs to fire on.
    harness.runtime.invalidated = false;
    const gap_point = geometry.PointF{
        .x = toolbar.button_centers[0].x,
        .y = (tooltip_frame.maxY() + trigger_frame.y) / 2,
    };
    try tooltipHover(harness, app, gap_point, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_transit_deadline_ns != 0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.invalidated);

    // With ZERO further interaction, the grace resolves on the frame
    // clock: a frame inside the bound changes nothing, the first frame
    // past it hides with the usual pointer-hide warmth.
    try tooltipFrame(harness, app, tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipFrame(harness, app, tooltip_t0 + 1201 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
}

test "a scroll re-checks the content hold even when the hover id is unchanged" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-scroll-held", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 120),
    });
    // A scroll view tall enough that the first trigger's below-anchored
    // tooltip sits fully inside the viewport, with a second stack far
    // enough down to give the scroll range.
    const first_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "One" },
        .{ .id = 5, .kind = .tooltip, .text = "First action", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const second_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "Two" },
        .{ .id = 7, .kind = .tooltip, .text = "Second action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 160, 32), .children = &first_children },
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 80, 160, 32), .children = &second_children },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &stacks },
        geometry.RectF.init(0, 0, 160, 60),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Show instantly (delay 0), then park INSIDE the tooltip's frame:
    // the hold. Beneath the frame sits the scroll view itself, so the
    // hover id is 1 — and stays 1 through the scroll below.
    try tooltipHover(harness, app, .{ .x = 12, .y = 16 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    const held_frame = try tooltipNodeFrame(harness, 5);
    const held_point = held_frame.center();
    try std.testing.expect(held_point.y > 32 and held_point.y < 60);
    try tooltipHover(harness, app, held_point, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Wheel-scroll the content up under the stationary pointer: the
    // tooltip's frame slides away while the re-hit-test still lands on
    // the scroll view — the hover id is UNCHANGED on both sides, the
    // exact state a transition gate can never see. The containment
    // re-check keys on the frame, not the id: the hold breaks and the
    // tooltip hides on the scroll itself, usual warmth.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = held_point.x,
        .y = held_point.y,
        .delta_y = 20,
        .timestamp_ns = tooltip_t0 + 200 * tooltip_ms,
    } });
    const scrolled_frame = try tooltipNodeFrame(harness, 5);
    try std.testing.expect(!scrolled_frame.containsPoint(held_point));
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
}

test "leaving tooltip content onto the trigger beneath reprocesses it as a fresh transition" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-held-release", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 200),
    });
    // Trigger One's below-anchored tooltip floats OVER the top of the
    // tall trigger Two beneath it, so a pointer inside the tooltip's
    // frame already records hover on Two — ownership the frame claims.
    const first_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "One" },
        .{ .id = 5, .kind = .tooltip, .text = "First action", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const second_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 80), .text = "Two" },
        .{ .id = 7, .kind = .tooltip, .text = "Second action", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 160, 32), .children = &first_children },
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 40, 160, 80), .children = &second_children },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .stack, .children = &stacks },
        geometry.RectF.init(0, 0, 160, 200),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    // Zero the warm window so the reprocessed trigger observably ARMS
    // its dwell (with the default warm window it would warm-show
    // instantly — also correct, but indistinguishable from a stale
    // instant carry-over of One's show).
    harness.runtime.views[0].widget_tokens.metrics.tooltip_warm_window_ms = 0;

    // Show One's tooltip, then move INTO its frame over Two: hover
    // records Two, but the hover reached Two THROUGH the tooltip's
    // frame, so Two's own tooltip must not arm while the hold lasts.
    try tooltipHover(harness, app, .{ .x = 80, .y = 16 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    const tooltip_frame = try tooltipNodeFrame(harness, 5);
    const overlap_point = geometry.PointF{ .x = tooltip_frame.center().x, .y = @max(tooltip_frame.y + 4, 44) };
    try std.testing.expect(tooltip_frame.containsPoint(overlap_point));
    try std.testing.expect(overlap_point.y > 40);
    try tooltipHover(harness, app, overlap_point, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);

    // Exit the tooltip's frame downward, still on Two: no hover
    // TRANSITION exists (Two was already recorded), but the hold's
    // release is a fresh fact — One hides, and Two is reprocessed as a
    // fresh transition so its dwell arms without a leave-and-re-enter.
    // "No transition" was measured against stale ownership (the frame
    // claimed the hover), not against user intent.
    const exit_point = geometry.PointF{ .x = 80, .y = tooltip_frame.maxY() + 20 };
    try std.testing.expect(exit_point.y < 120);
    harness.runtime.invalidated = false;
    try tooltipHover(harness, app, exit_point, tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_deadline_ns != 0);
    // The armed dwell obligates the pump even though this move changed
    // no interaction state (hover stayed on Two).
    try std.testing.expect(harness.runtime.invalidated);

    // The reprocessed dwell completes on the frame clock like any
    // other — earned by Two's own declaration.
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(!try tooltipHidden(harness, 7));
}

test "a consumed secondary-button stream updates the stored position for point-blind reconciliation" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-secondary-position", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipScrollFixture(harness, app, true);

    // Focus the scroll view, then earn One's tooltip (delay 0): the
    // stored position is the hover's (12, 12).
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 12, .y = 36 }, tooltip_t0);
    try tooltipPointer(harness, app, .pointer_up, .{ .x = 12, .y = 36 }, tooltip_t0 + 20 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_focused_id);
    try tooltipHover(harness, app, .{ .x = 12, .y = 12 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The secondary down is consumed by the context-menu gesture and
    // never reaches the widget interaction pipeline — but the pointer
    // MOVED to press there, so the stored position must follow it (and
    // the down still dismisses, warm window included).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .button = 1,
        .x = 12,
        .y = 4,
        .timestamp_ns = tooltip_t0 + 100 * tooltip_ms,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    const down_position = harness.runtime.views[0].canvas_last_pointer_position orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 12), down_position.x);
    try std.testing.expectEqual(@as(f32, 4), down_position.y);

    // The consumed MOVES of the same stream keep the store fresh too.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .button = 1,
        .x = 12,
        .y = 20,
        .timestamp_ns = tooltip_t0 + 150 * tooltip_ms,
    } });
    const move_position = harness.runtime.views[0].canvas_last_pointer_position orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 12), move_position.x);
    try std.testing.expectEqual(@as(f32, 20), move_position.y);

    // A point-blind keyboard scroll now re-hit-tests the FRESH
    // coordinate: End scrolls trigger Two under (12, 20) — a stale
    // (12, 12)-era store from before the consumed stream would have
    // resolved differently — and Two arms its normal dwell.
    try tooltipKey(harness, app, "end", tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(f32, 12), harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(@as(f32, 20), harness.runtime.views[0].canvas_tooltip_pointer_from.y);
}

test "a window-drag consumed down updates the stored position" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-drag-position", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });
    const trigger_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(10, 80, 96, 32), .text = "Run" },
        .{ .id = 4, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 320, 40), .window_drag = true },
        .{ .id = 5, .kind = .stack, .frame = geometry.RectF.init(0, 40, 320, 160), .children = &trigger_children },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try tooltipHover(harness, app, .{ .x = 58, .y = 136 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The down on the drag header hands the gesture to the OS and skips
    // the widget interaction pipeline — but it is the last position the
    // view will hear before the OS owns the pointer, so the store must
    // record it: a later point-blind reconcile hit-tests where the
    // pointer really went down, not where it hovered before.
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 160, .y = 20 }, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    const stored = harness.runtime.views[0].canvas_last_pointer_position orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 160), stored.x);
    try std.testing.expectEqual(@as(f32, 20), stored.y);
}

/// A raw-widget tooltip fixture with EXPLICIT ids (the rebuild tests
/// swap trees, so ids must be author-controlled): a stack wrapping a
/// trigger button (id 2) and its anchored tooltip (id 3),
/// tooltip-delay 0 so the hover itself shows it.
fn tooltipRebuildChildren(trigger_id: canvas.ObjectId, disabled: bool) [2]canvas.Widget {
    return .{
        .{
            .id = trigger_id,
            .kind = .button,
            .frame = geometry.RectF.init(10, 40, 96, 32),
            .text = "Run",
            .state = .{ .disabled = disabled },
        },
        .{
            .id = 3,
            .kind = .tooltip,
            .text = "Runs the job",
            .tooltip_delay_ms = 0,
            .layout = .{ .anchor = .{ .placement = .above } },
        },
    };
}

fn installTooltipRebuildFixture(harness: anytype, app: App) !void {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
    const children = tooltipRebuildChildren(2, false);
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Hover the trigger: delay 0 shows the tooltip on the move itself.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

fn expectTooltipRebuildReset(harness: anytype, app: App, replacement: []const canvas.Widget) !void {
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = replacement }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // The owning trigger is gone (removed, rekeyed, or disabled): the
    // adoption prune resets the whole intent slot and re-stamps the
    // surviving tooltip node hidden — no stale semantics.hidden=false.
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expect(try tooltipHidden(harness, 3));

    // And nothing appears later: frames past any would-be deadline
    // leave the tooltip down.
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
}

test "a rebuild that removes the tooltip's trigger resets the shown tooltip" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-owner-gone", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRebuildFixture(harness, app);

    // The tooltip node SURVIVES the rebuild; only its trigger vanishes.
    const replacement = [_]canvas.Widget{tooltipRebuildChildren(2, false)[1]};
    try expectTooltipRebuildReset(harness, app, &replacement);
}

test "a rebuild that rekeys the tooltip's trigger resets the shown tooltip" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-owner-rekeyed", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRebuildFixture(harness, app);

    // Same structure, new trigger id: a new id is a new widget, so the
    // intent earned against the old one does not transfer — the shown
    // slot resets and the warm window closes with it. The replacement
    // declares the DEFAULT delay so the distinction stays observable:
    // the new widget sits under the stationary pointer, and the
    // adoption re-hit-test treats it exactly like a trigger scrolled
    // under the pointer — it earns a FRESH dwell (owner re-recorded
    // against the new id), never an instant carry-over of the old
    // widget's show.
    var replacement = tooltipRebuildChildren(9, false);
    replacement[1].tooltip_delay_ms = -1;
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &replacement }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_armed_owner_id);

    // The fresh dwell completes on the frame clock like any other —
    // earned by the new widget's own declaration, not inherited.
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

test "a rebuild that disables the tooltip's trigger resets the shown tooltip" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-owner-disabled", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRebuildFixture(harness, app);

    // A disabled trigger leaves hover (and focus) routing entirely, so
    // no interaction could ever hide the tooltip again: the prune must
    // not wait for one.
    const replacement = tooltipRebuildChildren(2, true);
    try expectTooltipRebuildReset(harness, app, &replacement);
}

test "a failed adoption leaves the shown tooltip's registers coherent and hideable" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-adoption-failure", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRebuildFixture(harness, app);

    // A replacement that BOTH breaks the shown binding (trigger 2 is
    // gone) AND blows the retained anchored-surface budget, so
    // adoption fails inside copyWidgetLayoutTree — after the pre-diff
    // visibility stamp, before anything destructive. The old
    // register-mutating prune ran ahead of this failure: it cleared
    // the shown slot while the OLD tree stayed retained and stamped
    // visible — a tooltip no transition could ever hide again.
    var overflow_children: [max_canvas_widget_anchored_per_view + 1]canvas.Widget = undefined;
    for (&overflow_children, 0..) |*widget, child_index| {
        widget.* = .{
            .id = @intCast(100 + child_index),
            .kind = .tooltip,
            .text = "Overflow",
            .layout = .{ .anchor = .{ .placement = .above } },
        };
    }
    var overflow_nodes: [max_canvas_widget_anchored_per_view + 2]canvas.WidgetLayoutNode = undefined;
    const overflow_layout = try canvas.layoutWidgetTree(
        .{ .kind = .stack, .children = &overflow_children },
        geometry.RectF.init(0, 0, 220, 120),
        &overflow_nodes,
    );
    try std.testing.expectError(
        error.WidgetAnchoredSurfaceLimitReached,
        harness.runtime.setCanvasWidgetLayout(1, "canvas", overflow_layout),
    );

    // The failed adoption changed NOTHING: the old tree is still
    // retained with its tooltip visibly shown, and the registers still
    // own that stamp.
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));

    // And the tooltip stays HIDEABLE through a normal transition: the
    // pointer leaving the trigger hides it exactly as if the failed
    // rebuild never happened.
    try tooltipHover(harness, app, .{ .x = 5, .y = 110 }, tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
}

/// The rebuild-relocation fixture: a wrapper stack at an
/// author-controlled x carrying the trigger (id 2) and its anchored
/// tooltip (id 3) — same ids at every position, so a rebuild that
/// moves the stack relocates the SAME binding instead of breaking it
/// (the prune keeps it; only geometry changed).
fn setTooltipRelocationLayout(harness: anytype, trigger_x: f32, delay_ms: i32) !void {
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = delay_ms, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(trigger_x, 60, 96, 32), .children = &children },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .stack, .children = &stacks },
        geometry.RectF.init(0, 0, 320, 160),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

fn installTooltipRelocationView(harness: anytype, app: App) !void {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 160),
    });
}

test "a rebuild that relocates the same-ID trigger away from the stationary pointer disarms and hides" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-relocate-away", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRelocationView(harness, app);
    try setTooltipRelocationLayout(harness, 10, -1);

    // Arm the default dwell on the trigger, then rebuild with the SAME
    // ids relocated away from the stationary pointer: identity survives
    // the prune, but the re-hit-test sees the pointer over nothing —
    // the armed intent disarms on the rebuild itself, and frames past
    // the would-be deadline reveal nothing.
    try tooltipHover(harness, app, .{ .x = 58, .y = 76 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try setTooltipRelocationLayout(harness, 180, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try tooltipFrame(harness, app, tooltip_t0 + 800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));

    // Earn the SHOWN tooltip back in place, then relocate again: the
    // shown tooltip hides on the rebuild itself — no pointer event, no
    // frame needed — with the usual pointer-hide warmth (the content
    // moved, not the pointer: no transit corridor applies).
    try setTooltipRelocationLayout(harness, 10, -1);
    try tooltipHover(harness, app, .{ .x = 58, .y = 76 }, tooltip_t0 + 900 * tooltip_ms);
    try tooltipFrame(harness, app, tooltip_t0 + 1500 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try setTooltipRelocationLayout(harness, 180, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
    try tooltipFrame(harness, app, tooltip_t0 + 2500 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "a rebuild that moves a trigger under the stored pointer arms the normal dwell" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-relocate-under", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRelocationView(harness, app);
    try setTooltipRelocationLayout(harness, 180, -1);

    // Park the pointer over empty space (seeding the stored position,
    // earning no warmth), then rebuild with the trigger relocated
    // UNDER it: the re-hit-test arms the normal dwell — owner recorded,
    // corridor apex seeded from the stored truth — and the dwell
    // completes on the frame clock like any other.
    try tooltipHover(harness, app, .{ .x = 58, .y = 76 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try setTooltipRelocationLayout(harness, 10, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_deadline_ns != 0);
    try std.testing.expectEqual(@as(f32, 58), harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(@as(f32, 76), harness.runtime.views[0].canvas_tooltip_pointer_from.y);
    try tooltipFrame(harness, app, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

test "a rebuild re-checks the content hold against the tooltip's new frame" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-relocate-held", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRelocationView(harness, app);
    try setTooltipRelocationLayout(harness, 10, 0);

    // Show instantly (delay 0) and park the pointer INSIDE the
    // tooltip's frame: the content hold, with hovered_id == 0 (the
    // tooltip is not a hit target) — the exact state no hover
    // transition can see.
    try tooltipHover(harness, app, .{ .x = 58, .y = 76 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    const held_point = (try tooltipNodeFrame(harness, 3)).center();
    try tooltipHover(harness, app, held_point, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);

    // An unchanged rebuild keeps the hold: the containment re-check
    // against the (same) adopted frame still passes and re-seeds the
    // corridor apex from the stored position.
    try setTooltipRelocationLayout(harness, 10, 0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
    try std.testing.expectEqual(held_point.x, harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(held_point.y, harness.runtime.views[0].canvas_tooltip_pointer_from.y);

    // A rebuild that MOVES the tooltip's frame out from under the
    // stationary pointer breaks the hold honestly: hidden on the
    // rebuild itself, usual warmth, and no frame resurrects it.
    try setTooltipRelocationLayout(harness, 180, 0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);
    try tooltipFrame(harness, app, tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "a rebuild without a trustworthy pointer position closes pointer intent, focus-shown survives" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-relocate-blind", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRelocationView(harness, app);
    try setTooltipRelocationLayout(harness, 10, -1);

    // A keyboard-only session: tab earns the focus-shown tooltip, and
    // a rebuild (no stored pointer position anywhere) leaves it alone —
    // the keyboard holds it; the blind close is pointer-owned only.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try setTooltipRelocationLayout(harness, 180, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, 3));

    // Pointer-owned intent with no position to re-hit-test closes on
    // the rebuild — the blind-scroll policy. Seed an armed dwell and a
    // warm window directly (no pointer event may seed the store).
    harness.runtime.views[0].canvas_tooltip_armed_id = 3;
    harness.runtime.views[0].canvas_tooltip_armed_owner_id = 2;
    harness.runtime.views[0].canvas_tooltip_deadline_ns = tooltip_t0 + 1000 * tooltip_ms;
    harness.runtime.views[0].canvas_tooltip_warm_until_ns = tooltip_t0 + 5000 * tooltip_ms;
    try setTooltipRelocationLayout(harness, 10, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    // And the focus-shown tooltip still stands after the pointer-owned
    // close.
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

test "an unchanged rebuild with a hidden anchored tooltip diffs clean" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-rebuild-clean", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
    const children = tooltipRebuildChildren(2, false);
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try std.testing.expect(try tooltipHidden(harness, 3));

    // Rebuild the byte-identical tree: the runtime's own hidden stamp
    // is applied to the reconciled scratch BEFORE the diff, so the
    // rebuild reports NO invalidation and accumulates no dirty region —
    // the source's authored visibility never reaches the diff.
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const frame_requests_before = harness.null_platform.gpu_surface_frame_request_count;
    var rebuild_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const rebuild_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 120), &rebuild_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild_layout);

    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
    // Exactly the one settle request every rebuild performs
    // unconditionally (widget-revision bookkeeping, tooltip or not):
    // the hidden tooltip adds nothing on top of it.
    try std.testing.expectEqual(frame_requests_before + 1, harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expect(try tooltipHidden(harness, 3));
}

test "a shown tooltip keeps its visible state across an unchanged rebuild without flicker" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-rebuild-shown", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipRebuildFixture(harness, app);

    // Rebuild the same tree while the tooltip is SHOWN: the pre-diff
    // prune (against the reconciled tree) keeps the binding alive, so
    // the pre-diff stamp marks the scratch tooltip VISIBLE and the
    // diff stays clean — the retained node never passes through a
    // hidden state, so there is no hide-then-show frame pair to paint.
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const children = tooltipRebuildChildren(2, false);
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    // And the frame clock advancing past any stale deadline changes
    // nothing: the rebuild carried no armed state to fire.
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

// ------------------------------------------- adoption binding changes
//
// A reactive rebuild that ADDS, REPLACES, or REKEYS a tooltip beneath
// an owner whose own ID is stable produces no hover delta (the
// re-hit-test resolves the same trigger) and no stale register (there
// was no intent bound to the NEW tooltip for the prune to validate),
// so only the adoption binding-change step can see it. These tests pin
// the matrix — mount/replace/unmount x hovered/focus-visible x
// armed/shown — plus the unchanged-binding rebuild staying inert.

/// Stable-owner binding fixture: the trigger keeps id 2 in every
/// variant while the tooltip beneath it mounts (`tooltip_id` != 0),
/// unmounts (0), or rekeys (a different id). `trigger_kind` lets the
/// provenance test swap the button for an editable field.
fn setTooltipBindingLayoutInWindow(runtime: *Runtime, window_id: platform.WindowId, trigger_kind: canvas.WidgetKind, tooltip_id: canvas.ObjectId, delay_ms: i32) !void {
    var children: [2]canvas.Widget = undefined;
    children[0] = .{
        .id = 2,
        .kind = trigger_kind,
        .frame = geometry.RectF.init(10, 40, 96, 32),
        .text = "Run",
    };
    var child_count: usize = 1;
    if (tooltip_id != 0) {
        children[child_count] = .{
            .id = tooltip_id,
            .kind = .tooltip,
            .text = "Runs the job",
            .tooltip_delay_ms = delay_ms,
            .layout = .{ .anchor = .{ .placement = .above } },
        };
        child_count += 1;
    }
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .kind = .stack, .children = children[0..child_count] },
        geometry.RectF.init(0, 0, 220, 120),
        &nodes,
    );
    _ = try runtime.setCanvasWidgetLayout(window_id, "canvas", layout);
}

fn setTooltipBindingLayout(harness: anytype, trigger_kind: canvas.WidgetKind, tooltip_id: canvas.ObjectId, delay_ms: i32) !void {
    try setTooltipBindingLayoutInWindow(&harness.runtime, 1, trigger_kind, tooltip_id, delay_ms);
}

fn installTooltipBindingView(harness: anytype, app: App) !void {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
}

test "a tooltip mounting beneath the hovered trigger mid-hover arms the fresh dwell" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-mount", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 0, 0);

    // Hover the bare trigger: nothing exists to arm.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);

    // The rebuild mounts the tooltip beneath the SAME trigger id: no
    // hover delta, no stale register — only the binding-change step
    // can arm it, and mounting mid-hover never insta-shows (the dwell
    // is the intent filter; a rebuild proves nothing about the user).
    try setTooltipBindingLayout(harness, .button, 3, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    // Corridor apex seeded from the stored position, per normal arming.
    try std.testing.expectEqual(@as(f32, 58), harness.runtime.views[0].canvas_tooltip_pointer_from.x);
    try std.testing.expectEqual(@as(f32, 56), harness.runtime.views[0].canvas_tooltip_pointer_from.y);
    const deadline = harness.runtime.views[0].canvas_tooltip_deadline_ns;
    try std.testing.expect(deadline != 0);

    // Movement WITHIN the trigger before the dwell behaves normally:
    // gliding within one trigger is free — same armed id, same
    // deadline, still hidden.
    try tooltipHover(harness, app, .{ .x = 70, .y = 60 }, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(deadline, harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The dwell completes on the frame clock like any other.
    try tooltipFrame(harness, app, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(!try tooltipHidden(harness, 3));
}

test "a rebuild that rekeys the tooltip beneath a shown trigger hides the old and re-earns the dwell" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-rekey", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 3, 0);

    // Delay 0: the hover itself shows tooltip 3.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Rekey the tooltip under the stable, still-hovered trigger: the
    // prune kills the old binding (a new id is a new widget) and
    // closes the warm window with it — no instant carry-over of the
    // old widget's show — and the binding-change step re-earns the
    // NEW tooltip through its own declared dwell.
    try setTooltipBindingLayout(harness, .button, 9, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 9));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_deadline_ns != 0);

    // The fresh dwell completes on the frame clock.
    try tooltipFrame(harness, app, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 9));
}

test "a tooltip mounting beneath the focus-visible trigger reveals immediately" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-focus", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 0, 0);

    // Tab reaches the bare trigger: the ring stands, nothing reveals.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The rebuild mounts the tooltip beneath the standing KEYBOARD
    // focus-visible: it reveals on the rebuild itself — no dwell, no
    // frame — because focus is the user's standing intent (shadcn's
    // Base UI-backed instant focus-visible open). A keyboard-only
    // session has no stored pointer position, so this also pins the
    // blind-close path still running the focus half.
    try setTooltipBindingLayout(harness, .button, 3, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_shown_owner_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);

    // Rekey under the focus-SHOWN tooltip: the old binding dies in the
    // prune (old hides), and the new one re-earns per the FOCUS rule —
    // immediately, keyboard focus still standing.
    try setTooltipBindingLayout(harness, .button, 9, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, 9));
}

test "a tooltip mounting beneath a pointer-established ring arms the dwell, never the focus reveal" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-caret", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .text_field, 0, 0);

    // Click INTO the editable: ring and caret however focus arrived
    // (the caret contract), but the provenance is the POINTER's.
    try tooltipPointer(harness, app, .pointer_down, .{ .x = 58, .y = 56 }, tooltip_t0);
    try tooltipPointer(harness, app, .pointer_up, .{ .x = 58, .y = 56 }, tooltip_t0 + 20 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);

    // The rebuild mounts the tooltip beneath that ring: NO immediate
    // reveal (Base UI's focus-visible guard against click-focus opens
    // extends to adoption-time bindings) — but the pointer honestly
    // rests on the trigger, so the HOVER half arms the normal dwell.
    try setTooltipBindingLayout(harness, .text_field, 3, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
}

/// Two focus stops — the first trigger owns a rekeyable tooltip
/// (`tooltip_id`), the second is a bare button — so Tab can genuinely
/// LEAVE the trigger and return: a fresh keyboard arrival, not the
/// early-returned in-place move a single-focusable tree would produce.
fn setTooltipDismissalLayout(harness: anytype, tooltip_id: canvas.ObjectId) !void {
    const trigger_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 160, 32), .text = "Run" },
        .{ .id = tooltip_id, .kind = .tooltip, .text = "Runs the job", .layout = .{ .anchor = .{ .placement = .below } } },
    };
    const stacks = [_]canvas.Widget{
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 160, 32), .children = &trigger_children },
        .{ .id = 6, .kind = .button, .frame = geometry.RectF.init(0, 80, 160, 32), .text = "Other" },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .stack, .children = &stacks },
        geometry.RectF.init(0, 0, 220, 120),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

test "keyboard activation's dismissal holds through the activation's own rebuild rekeying the tooltip" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-activate-rekey", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipDismissalLayout(harness, 3);

    // Tab reaches the trigger: focus-shown tooltip, keyboard ring.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Enter dismisses like a press — and the trigger stays visibly
    // focus-visible through the dismissal: the consumed register is
    // the reveal PROVENANCE, never the ring, which renders from
    // `canvas_widget_focus_visible_id`.
    try tooltipKey(harness, app, "enter", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvasWidgetRenderState().focus_visible_id.?);

    // The activation's own model rebuild rekeys the tooltip beneath
    // the still-focused trigger (3 -> 9): the adoption binding-
    // reconcile sees a changed binding under a standing ring, but the
    // dismissal SPENT the reveal intent — the tooltip stays down while
    // focus rests on the trigger, on the rebuild and on every later
    // frame.
    try setTooltipDismissalLayout(harness, 9);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expect(try tooltipHidden(harness, 9));
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Tab away and back re-earns the immediate reveal: a fresh
    // keyboard ARRIVAL re-grants the contract at the one provenance
    // write.
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 6), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, 9));
}

test "escape's dismissal holds through a rebuild rekeying the tooltip, pointer dwell re-earns" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-escape-rekey", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipDismissalLayout(harness, 3);

    // Tab reveals, Escape dismisses; the ring survives the dismissal.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipKey(harness, app, "escape", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 3));
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvasWidgetRenderState().focus_visible_id.?);

    // A rebuild rekeys the tooltip beneath the still-focused trigger:
    // Escape's dismissal spent the standing reveal intent, so the
    // rekeyed tooltip stays down — "stays down while focus rests on
    // the trigger" holds against adoption, not only against
    // focus-visible transitions.
    try setTooltipDismissalLayout(harness, 9);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expect(try tooltipHidden(harness, 9));
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // The pointer path is untouched by the spent keyboard intent: a
    // hover after the dismissal arms the normal dwell and completes on
    // the frame clock, exactly like any other hover.
    try tooltipHover(harness, app, .{ .x = 200, .y = 60 }, tooltip_t0 + 1000 * tooltip_ms);
    try tooltipHover(harness, app, .{ .x = 80, .y = 16 }, tooltip_t0 + 1100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipFrame(harness, app, tooltip_t0 + 1800 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, 9));
}

test "a rebuild that unmounts the tooltip beneath a hovered trigger disarms the pending dwell" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-unmount", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 3, -1);

    // Arm the dwell, then unmount the tooltip beneath the still-hovered
    // trigger: the transactional prune's case exactly (the armed
    // binding died with its tooltip node) — pinned here for the
    // binding matrix's completeness. Nothing fires later.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try setTooltipBindingLayout(harness, .button, 0, 0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
}

test "an unchanged-binding adoption leaves the armed dwell untouched" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-binding-inert", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 3, -1);

    // Arm the dwell, advance the frame clock (so any buggy RE-arm
    // would stamp a LATER deadline), then rebuild the identical tree:
    // the binding compares equal, so the adoption step stays silent —
    // same armed id, same deadline, same apex, nothing shown.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipFrame(harness, app, tooltip_t0 + 100 * tooltip_ms);
    const deadline = harness.runtime.views[0].canvas_tooltip_deadline_ns;
    try std.testing.expect(deadline != 0);

    try setTooltipBindingLayout(harness, .button, 3, -1);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_tooltip_armed_owner_id);
    try std.testing.expectEqual(deadline, harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // And the original dwell still completes on its own clock.
    try tooltipFrame(harness, app, tooltip_t0 + 700 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
}

// ---------------------------------------- lifecycle blur (deactivate / key)
//
// A tooltip leaves WITH the whole window: app deactivation and window
// key-loss end the tooltip conversation exactly like a view blur (the
// platform convention — macOS help tags and web tooltips drop when
// their window stops hearing the user), and reactivation reveals
// nothing, because both reveal paths are transition-edge-triggered.

fn tooltipHoverInWindow(harness: anytype, app: App, window_id: platform.WindowId, point: geometry.PointF, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = window_id,
        .label = "canvas",
        .kind = .pointer_move,
        .x = point.x,
        .y = point.y,
        .timestamp_ns = timestamp_ns,
    } });
}

fn tooltipHiddenInView(harness: anytype, view_index: usize, tooltip_id: canvas.ObjectId) !bool {
    const view = &harness.runtime.views[view_index];
    const node_index = view.canvasWidgetNodeIndexById(tooltip_id) orelse return error.TestUnexpectedResult;
    return view.widget_layout_nodes[node_index].widget.semantics.hidden;
}

test "app deactivation hides the focus-shown tooltip and reactivation reveals nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-deactivate-focus", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Tab earns Bold's focus-shown tooltip.
    try tooltipKey(harness, app, "tab", tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // The app deactivates: the tooltip leaves with the window — hidden
    // re-stamped (no stale visible node in the a11y tree), the shown
    // slot and its focus ownership cleared.
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);

    // Widget focus bookkeeping survives (focus returns where it was),
    // but reactivation replays no focus-visible TRANSITION, so nothing
    // re-reveals — not on the activate, not on any later frame.
    try std.testing.expectEqual(toolbar.button_ids[0], harness.runtime.views[0].canvas_widget_focus_visible_id);
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));

    // A fresh focus-visible ARRIVAL re-earns the reveal.
    try tooltipKey(harness, app, "tab", tooltip_t0 + 1000 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[1], harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, toolbar.tooltip_ids[1]));
}

test "app deactivation ends the pointer tooltip conversation: shown hides, warm dies, armed disarms" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-deactivate-pointer", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // Earn Link's tooltip by hover (delay 0), then leave it: the hide
    // opens the warm skip window.
    try tooltipHoverInWindow(harness, app, 1, toolbar.button_centers[2], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipHoverInWindow(harness, app, 1, .{ .x = 5, .y = 150 }, tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_warm_until_ns != 0);

    // Deactivation kills the warmth with everything else: the user
    // left the app, so the next hover after reactivation must re-earn
    // the full delay instead of warm-showing instantly.
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    // The stored pointer position deliberately survives (the pointer
    // may still be over the window): pointer truth belongs to the
    // pointer channel, whose own cancel clears it on hosts that scope
    // hover delivery to the key window.
    try std.testing.expect(harness.runtime.views[0].canvas_last_pointer_position != null);

    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try tooltipHoverInWindow(harness, app, 1, toolbar.button_centers[0], tooltip_t0 + 200 * tooltip_ms);
    try std.testing.expectEqual(toolbar.tooltip_ids[0], harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);

    // Deactivating with an ARMED delay disarms it: the deadline never
    // fires, no matter how far the frame clock advances afterward.
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[0]));
}

test "window key-loss hides tooltips in that window's views only, re-key reveals nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-key-loss", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // A second window with its own canvas view and a delay-0 tooltip.
    const second = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    _ = try harness.runtime.createView(.{
        .window_id = second.id,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
    const second_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 40, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &second_children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(second.id, "canvas", layout);

    // The startup window holds key; its hover earns normally. The
    // NON-key second window earns NOTHING from the same hover — hosts
    // with always-active tracking areas deliver these for real, and a
    // window the user is not keyed into reveals and arms nothing. The
    // hover bookkeeping itself stays truthful (washes, stored pointer):
    // only tooltip ACTION is suppressed.
    try std.testing.expect(harness.runtime.windows[0].info.focused);
    try tooltipHoverInWindow(harness, app, 1, toolbar.button_centers[2], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 58, .y = 56 }, tooltip_t0 + 50 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[1].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_armed_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));

    // The second window becomes key: the FIRST window's tooltip leaves
    // with its key status — and the key GAIN reveals nothing in the
    // second window (no transition replays), even though the pointer
    // still rests on its trigger.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_focused = second.id });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));

    // A FRESH hover transition in the now-key window earns per the
    // normal rules (delay 0: instant).
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 200, .y = 10 }, tooltip_t0 + 100 * tooltip_ms);
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 58, .y = 56 }, tooltip_t0 + 150 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHiddenInView(harness, 1, 3));

    // Key returns to the first window: the second window's tooltip now
    // drops, and the first window's does NOT spontaneously re-reveal —
    // a key gain replays no hover or focus-visible transition.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_focused = 1 });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
}

test "window key-loss announced loss-first (Windows/GTK ordering) hides the tooltip at the loss itself" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-key-loss-first", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toolbar = try installTooltipToolbar(harness, app, arena.allocator());

    // A second window with its own canvas view and a delay-0 tooltip,
    // exactly like the gain-only key-loss test above.
    const second = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    _ = try harness.runtime.createView(.{
        .window_id = second.id,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
    const second_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 40, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .tooltip, .text = "Runs the job", .tooltip_delay_ms = 0, .layout = .{ .anchor = .{ .placement = .above } } },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &second_children }, geometry.RectF.init(0, 0, 220, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(second.id, "canvas", layout);

    // The startup window holds key; hover earns Link's delay-0 tooltip.
    try std.testing.expect(harness.runtime.windows[0].info.focused);
    try tooltipHoverInWindow(harness, app, 1, toolbar.button_centers[2], tooltip_t0);
    try std.testing.expectEqual(toolbar.tooltip_ids[2], harness.runtime.views[0].canvas_tooltip_shown_id);

    // Windows and GTK announce the key change LOSS-first: a state echo
    // carrying focused=false for the window the user left, BEFORE any
    // gain event for the next one. The tooltip must hide AT the loss —
    // the later gain's dethroning loop sees this window already
    // unfocused, so nothing downstream can fire it.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = 1,
        .label = harness.runtime.windows[0].info.label,
        .title = harness.runtime.windows[0].info.title,
        .frame = harness.runtime.windows[0].info.frame,
        .focused = false,
    } });
    try std.testing.expect(!harness.runtime.windows[0].info.focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);

    // The gain lands afterwards: it changes nothing about the first
    // window (already unfocused, already reset) and reveals nothing in
    // the second (a key gain replays no transition).
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_focused = second.id });
    try std.testing.expect(harness.runtime.windows[1].info.focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, toolbar.tooltip_ids[2]));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));

    // A fresh hover transition in the now-key second window earns
    // instantly (delay 0)...
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 200, .y = 10 }, tooltip_t0 + 100 * tooltip_ms);
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 58, .y = 56 }, tooltip_t0 + 150 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHiddenInView(harness, 1, 3));

    // ...and a loss with NO subsequent gain — the user keyed into some
    // other app's window, so every tracked window is now inactive —
    // still resets: the seam observes the flag's own edge, not any
    // gain's dethroning loop.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = second.id,
        .label = harness.runtime.windows[1].info.label,
        .title = harness.runtime.windows[1].info.title,
        .frame = harness.runtime.windows[1].info.frame,
        .focused = false,
    } });
    try std.testing.expect(!harness.runtime.windows[0].info.focused);
    try std.testing.expect(!harness.runtime.windows[1].info.focused);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));
}

test "a rebuild from the deactivation callback reveals and arms nothing while the app is inactive" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        rebuilt: bool = false,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-deactivate-rebuild", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        // The deactivate callback rebuilds the tree, swapping the
        // trigger's tooltip binding (3 -> 9): the adoption
        // binding-reconcile then sees a changed binding beneath BOTH
        // the retained keyboard focus ring and the stored hover — the
        // exact state that revealed and armed mid-deactivation before
        // the inactive guard, undoing the blur one dispatch later.
        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .lifecycle => |lifecycle| {
                    if (lifecycle != .deactivate) return;
                    self.rebuilt = true;
                    try setTooltipBindingLayoutInWindow(runtime, 1, .button, 9, -1);
                },
                else => {},
            }
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 3, -1);

    // Standing pointer hover AND keyboard focus-visible on the trigger:
    // the tab reveal takes the shown slot (focus-owned) and clears the
    // redundant dwell.
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0);
    try tooltipKey(harness, app, "tab", tooltip_t0 + 10 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(harness.runtime.views[0].canvas_tooltip_shown_from_focus);

    // Deactivation: the reset hides tooltip 3, THEN the callback's
    // rebuild adopts the swapped binding while the app is inactive —
    // nothing reveals, nothing arms, and the new tooltip's semantics
    // stamp hidden (no stale visible node one dispatch after the blur).
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expect(app_state.rebuilt);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!harness.runtime.views[0].canvas_tooltip_shown_from_focus);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_armed_id);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_deadline_ns);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].canvas_tooltip_warm_until_ns);
    try std.testing.expect(try tooltipHidden(harness, 9));

    // Suppression gates ACTION only: the keyboard provenance register
    // and the stored pointer survive, preserved for the next honest
    // transition — acting on them while inactive was the bug, never
    // their persistence.
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focus_visible_id);
    try std.testing.expect(harness.runtime.views[0].canvas_widget_focus_visible_keyboard);
    try std.testing.expect(harness.runtime.views[0].canvas_last_pointer_position != null);

    // Re-activation reveals nothing spontaneously — not on the
    // activate, not on any later frame.
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try tooltipFrame(harness, app, tooltip_t0 + 900 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 9));

    // A fresh hover TRANSITION re-earns the swapped tooltip normally:
    // the preserved stores act again, on a real transition.
    try tooltipHover(harness, app, .{ .x = 5, .y = 5 }, tooltip_t0 + 1000 * tooltip_ms);
    try tooltipHover(harness, app, .{ .x = 58, .y = 56 }, tooltip_t0 + 1100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_armed_id);
    try tooltipFrame(harness, app, tooltip_t0 + 2000 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHidden(harness, 9));
}

test "a tooltip mounting beneath a non-key window's hovered trigger reveals and arms nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-tooltip-nonkey-adoption", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try installTooltipBindingView(harness, app);
    try setTooltipBindingLayout(harness, .button, 0, 0);

    // A second window with its own canvas view and a bare trigger; the
    // startup window keeps key throughout the mount.
    const second = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    _ = try harness.runtime.createView(.{
        .window_id = second.id,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 220, 120),
    });
    try setTooltipBindingLayoutInWindow(&harness.runtime, second.id, .button, 0, 0);
    try std.testing.expect(harness.runtime.windows[0].info.focused);

    // Hover the non-key window's trigger: the bookkeeping stays
    // truthful (wash, stored pointer) — only tooltip ACTION is gated.
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 58, .y = 56 }, tooltip_t0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[1].canvas_widget_hovered_id);

    // A rebuild mounts a DELAY-0 tooltip beneath that hovered trigger:
    // the adoption binding-reconcile sees the change, but the window
    // is not key — no instant show, no arm, semantics stay hidden.
    try setTooltipBindingLayoutInWindow(&harness.runtime, second.id, .button, 3, 0);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_armed_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));

    // Key arriving reveals nothing spontaneously — not on the key
    // event, not on a later frame.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_focused = second.id });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = second.id,
        .label = "canvas",
        .size = geometry.SizeF.init(220, 120),
        .timestamp_ns = tooltip_t0 + 900 * tooltip_ms,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHiddenInView(harness, 1, 3));

    // A fresh hover transition in the now-key window earns instantly
    // (delay 0).
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 200, .y = 10 }, tooltip_t0 + 1000 * tooltip_ms);
    try tooltipHoverInWindow(harness, app, second.id, .{ .x = 58, .y = 56 }, tooltip_t0 + 1050 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[1].canvas_tooltip_shown_id);
    try std.testing.expect(!try tooltipHiddenInView(harness, 1, 3));
}
