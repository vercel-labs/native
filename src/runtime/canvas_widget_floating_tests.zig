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

test "keyboard scrolling a shown tooltip's trigger out of the tree hides it" {
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

    // End scrolls the focused scroll view to its bottom: trigger One
    // leaves the interactive tree (clipped out), the hover reconcile
    // clears it, and the SAME machine step hides its tooltip — the
    // point-blind scroll path (kinetic steps and native drivers share
    // this exact reconcile).
    try tooltipKey(harness, app, "end", tooltip_t0 + 100 * tooltip_ms);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_tooltip_shown_id);
    try std.testing.expect(try tooltipHidden(harness, 5));
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
    // intent earned against the old one does not transfer.
    const replacement = tooltipRebuildChildren(9, false);
    try expectTooltipRebuildReset(harness, app, &replacement);
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
