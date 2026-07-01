const std = @import("std");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");
const extensions = @import("../extensions/root.zig");
const window_state = @import("../window_state/root.zig");
const runtime_module = @import("root.zig");
const bridge_payload = @import("bridge_payload.zig");
const canvas_frame = @import("canvas_frame.zig");

const App = runtime_module.App;
const Runtime = runtime_module.Runtime;
const Options = runtime_module.Options;
const Event = runtime_module.Event;
const LifecycleEvent = runtime_module.LifecycleEvent;
const CommandEvent = runtime_module.CommandEvent;
const Command = runtime_module.Command;
const CommandSource = runtime_module.CommandSource;
const FrameDiagnostics = runtime_module.FrameDiagnostics;
const ShortcutEvent = runtime_module.ShortcutEvent;
const Appearance = runtime_module.Appearance;
const GpuFrame = runtime_module.GpuFrame;
const GpuSurfaceFrameEvent = runtime_module.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = runtime_module.GpuSurfaceResizeEvent;
const GpuSurfaceInputEvent = runtime_module.GpuSurfaceInputEvent;
const CanvasWidgetPointerEvent = runtime_module.CanvasWidgetPointerEvent;
const CanvasWidgetKeyboardEvent = runtime_module.CanvasWidgetKeyboardEvent;
const CanvasWidgetDisplayListChrome = runtime_module.CanvasWidgetDisplayListChrome;
const CanvasPresentationMode = runtime_module.CanvasPresentationMode;
const CanvasPresentationResult = runtime_module.CanvasPresentationResult;
const CanvasWidgetAccessibilityActionKind = runtime_module.CanvasWidgetAccessibilityActionKind;
const CanvasWidgetAccessibilityAction = runtime_module.CanvasWidgetAccessibilityAction;
const CanvasWidgetFileDropEvent = runtime_module.CanvasWidgetFileDropEvent;
const CanvasWidgetDragEvent = runtime_module.CanvasWidgetDragEvent;
const InvalidationReason = runtime_module.InvalidationReason;
const TestHarness = runtime_module.TestHarness;
const max_canvas_commands_per_view = runtime_module.max_canvas_commands_per_view;
const max_canvas_widget_nodes_per_view = runtime_module.max_canvas_widget_nodes_per_view;

const jsonStringField = bridge_payload.jsonStringField;
const jsonNumberField = bridge_payload.jsonNumberField;
const jsonBoolField = bridge_payload.jsonBoolField;
const canvasRenderAnimationFinalOverrideNoop = canvas_frame.canvasRenderAnimationFinalOverrideNoop;
const copyInto = runtime_module.testing.copyInto;
const writeViewJson = runtime_module.testing.writeViewJson;
const canvasFrameScratchStorage = runtime_module.testing.canvasFrameScratchStorage;
const runtimeViewInfo = runtime_module.testing.runtimeViewInfo;
const runtimeViewCanvasFrameRenderOverrides = runtime_module.testing.runtimeViewCanvasFrameRenderOverrides;
const runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides = runtime_module.testing.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides;
const runtimeViewWidgetSemantics = runtime_module.testing.runtimeViewWidgetSemantics;
const runtimeViewSetCanvasWidgetSelected = runtime_module.testing.runtimeViewSetCanvasWidgetSelected;
const runtimeViewCanvasWidgetDirtyBounds = runtime_module.testing.runtimeViewCanvasWidgetDirtyBounds;
const dispatchAutomationWidgetAction = runtime_module.testing.dispatchAutomationWidgetAction;
const shellBoundsForWindow = runtime_module.testing.shellBoundsForWindow;
const reloadWindows = runtime_module.testing.reloadWindows;
const canvasWidgetSemanticsById = runtime_module.testing.canvasWidgetSemanticsById;
const platformWidgetAccessibilityNodeById = runtime_module.testing.platformWidgetAccessibilityNodeById;
const builtinBridgeErrorCode = runtime_module.testing.builtinBridgeErrorCode;
const builtinBridgeErrorMessage = runtime_module.testing.builtinBridgeErrorMessage;

fn testViewByLabel(views: []const platform.ViewInfo, label: []const u8) ?platform.ViewInfo {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}

fn testCanvasWidgetPartId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

test "runtime loads app source into platform webview" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "test", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectEqual(platform.WebViewSourceKind.html, harness.null_platform.loaded_source.?.kind);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", harness.null_platform.loaded_source.?.bytes);
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.frameDiagnostics().frame_index);
}

test "runtime lets start hook create views before startup source loads" {
    const TestApp = struct {
        created_view: bool = false,
        source_loaded_after_start: bool = false,

        fn start(context: *anyopaque, runtime: *Runtime) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = try runtime.createView(.{
                .window_id = 1,
                .label = "startup-toolbar",
                .kind = .toolbar,
                .frame = geometry.RectF.init(0, 0, 640, 44),
                .role = "toolbar",
            });
            self.created_view = true;
        }

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.source_loaded_after_start = self.created_view;
            return platform.WebViewSource.html("<h1>Native shell</h1>");
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "startup-native-shell",
                .source = platform.WebViewSource.html(""),
                .source_fn = source,
                .start_fn = start,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(app_state.created_view);
    try std.testing.expect(app_state.source_loaded_after_start);
    try std.testing.expectEqualStrings("<h1>Native shell</h1>", harness.null_platform.loaded_source.?.bytes);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expectEqualStrings("startup-toolbar", views[1].label);
}

test "runtime exposes startup WebView and native views through generic view API" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "views", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const toolbar = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
        .role = "toolbar",
        .accessibility_label = "Main toolbar",
        .text = "Tools",
        .command = "app.toolbar",
    });
    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expect(toolbar.id > 0);
    try std.testing.expectEqualStrings("toolbar", toolbar.label);
    try std.testing.expectEqualStrings("Main toolbar", toolbar.accessibility_label);
    try std.testing.expectEqualStrings("Tools", toolbar.text);
    try std.testing.expectEqualStrings("app.toolbar", toolbar.command);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqual(platform.ViewKind.webview, views[0].kind);
    try std.testing.expect(views[0].id > 0);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expect(views[0].focused);
    try std.testing.expectEqual(platform.ViewKind.toolbar, views[1].kind);
    try std.testing.expectEqual(toolbar.id, views[1].id);
    try std.testing.expectEqualStrings("toolbar", views[1].label);
    try std.testing.expect(!views[1].focused);

    try harness.runtime.focusView(1, "toolbar");
    const focused_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(!focused_views[0].focused);
    try std.testing.expect(focused_views[1].focused);

    try harness.runtime.focusView(1, "main");
    const refocused_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(refocused_views[0].focused);
    try std.testing.expect(!refocused_views[1].focused);

    try harness.runtime.focusView(1, "toolbar");
    const updated = try harness.runtime.updateView(1, "toolbar", .{
        .frame = geometry.RectF.init(0, 0, 640, 52),
        .visible = false,
        .accessibility_label = "Primary actions toolbar",
        .text = "Actions",
        .command = "app.toolbar.updated",
    });
    try std.testing.expectEqual(@as(f32, 52), updated.frame.height);
    try std.testing.expectEqual(toolbar.id, updated.id);
    try std.testing.expect(!updated.visible);
    try std.testing.expect(!updated.focused);
    try std.testing.expectEqualStrings("Primary actions toolbar", updated.accessibility_label);
    try std.testing.expectEqualStrings("Actions", updated.text);
    try std.testing.expectEqualStrings("app.toolbar.updated", updated.command);

    const repaired_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(testViewByLabel(repaired_views, "main").?.focused);
    try std.testing.expect(!testViewByLabel(repaired_views, "toolbar").?.focused);

    try harness.runtime.closeView(1, "toolbar");
    const remaining = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("main", remaining[0].label);
    try std.testing.expect(remaining[0].focused);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 96, 32),
    });
    try harness.runtime.focusView(1, "action");
    const disabled = try harness.runtime.updateView(1, "action", .{ .enabled = false });
    try std.testing.expect(!disabled.focused);
    var repaired_disabled_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(testViewByLabel(repaired_disabled_views, "main").?.focused);
    try std.testing.expect(!testViewByLabel(repaired_disabled_views, "action").?.focused);
    try harness.runtime.closeView(1, "action");

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 320, 640, 32),
    });
    try harness.runtime.focusView(1, "status");
    try harness.runtime.closeView(1, "status");
    repaired_disabled_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), repaired_disabled_views.len);
    try std.testing.expectEqualStrings("main", repaired_disabled_views[0].label);
    try std.testing.expect(repaired_disabled_views[0].focused);
}

test "runtime createView routes webview kind through WebView backend" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-view", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview-host",
        .kind = .stack,
        .frame = geometry.RectF.init(40, 50, 360, 280),
    });

    const preview = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .parent = "preview-host",
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(10, 10, 320, 240),
        .layer = 5,
        .bridge_enabled = true,
    });
    try std.testing.expectEqual(platform.ViewKind.webview, preview.kind);
    try std.testing.expect(preview.id > 0);
    try std.testing.expectEqualStrings("preview-host", preview.parent.?);
    try std.testing.expectEqualStrings("zero://app/preview.html", preview.url);
    try std.testing.expect(preview.bridge_enabled);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(f32, 50), preview.frame.x);
    try std.testing.expectEqual(@as(f32, 60), preview.frame.y);
    try std.testing.expectEqual(@as(f32, 50), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 60), harness.null_platform.webviews[0].frame.y);

    const updated = try harness.runtime.updateView(1, "preview", .{
        .url = "zero://app/updated.html",
        .layer = 8,
    });
    try std.testing.expectEqualStrings("zero://app/updated.html", updated.url);
    try std.testing.expectEqual(preview.id, updated.id);
    try std.testing.expectEqual(@as(i32, 8), updated.layer);

    const moved_host = try harness.runtime.updateView(1, "preview-host", .{
        .frame = geometry.RectF.init(80, 90, 360, 280),
    });
    try std.testing.expectEqual(@as(f32, 80), moved_host.frame.x);
    try std.testing.expectEqual(@as(f32, 90), moved_host.frame.y);
    try std.testing.expectEqual(@as(f32, 90), harness.runtime.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 100), harness.runtime.webviews[0].frame.y);
    try std.testing.expectEqual(@as(f32, 90), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 100), harness.null_platform.webviews[0].frame.y);

    const moved_preview = try harness.runtime.updateView(1, "preview", .{
        .frame = geometry.RectF.init(20, 24, 320, 240),
    });
    try std.testing.expectEqual(@as(f32, 100), moved_preview.frame.x);
    try std.testing.expectEqual(@as(f32, 114), moved_preview.frame.y);
    try std.testing.expectEqual(@as(f32, 100), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 114), harness.null_platform.webviews[0].frame.y);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 3), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    const listed_preview = testViewByLabel(views, "preview").?;
    try std.testing.expectEqual(preview.id, listed_preview.id);
    try std.testing.expectEqualStrings("preview-host", listed_preview.parent.?);

    try harness.runtime.focusView(1, "preview");
    try harness.runtime.closeView(1, "preview");
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    const remaining = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expectEqualStrings("main", remaining[0].label);
    try std.testing.expect(remaining[0].focused);
}

test "runtime rejects invalid native view parents" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-view-parents", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectError(error.ViewNotFound, harness.runtime.createView(.{
        .window_id = 1,
        .label = "orphan",
        .kind = .button,
        .parent = "missing",
        .frame = geometry.RectF.init(0, 0, 96, 32),
    }));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });

    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.createView(.{
        .window_id = 1,
        .label = "self",
        .kind = .stack,
        .parent = "self",
        .frame = geometry.RectF.init(0, 0, 120, 80),
    }));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.view_count);

    const action = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    try std.testing.expectEqualStrings("toolbar", action.parent.?);
}

test "runtime closes native view descendants and logical WebView children with parent" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "parent-close", .source = platform.WebViewSource.html("<h1>Close</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "pane",
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 640, 360),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "controls",
        .kind = .stack,
        .parent = "pane",
        .frame = geometry.RectF.init(8, 8, 220, 96),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .parent = "controls",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .parent = "pane",
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(240, 8, 320, 240),
    });
    try std.testing.expectEqual(@as(usize, 3), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);

    try harness.runtime.focusView(1, "action");
    try harness.runtime.closeView(1, "pane");

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expect(views[0].focused);
}

test "runtime traverses focus across WebViews and native controls" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "focus-traversal", .source = platform.WebViewSource.html("<h1>Focus</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "disabled-action",
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 120, 28),
        .enabled = false,
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(0, 44, 640, 360),
    });

    const first = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("toolbar", first.label);
    try std.testing.expect(first.focused);

    const second = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("preview", second.label);

    const wrapped = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("main", wrapped.label);

    const previous = try harness.runtime.focusPreviousView(1);
    try std.testing.expectEqualStrings("preview", previous.label);

    var views_buffer: [5]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    for (views) |view| {
        if (std.mem.eql(u8, view.label, "preview")) {
            try std.testing.expect(view.focused);
        } else {
            try std.testing.expect(!view.focused);
        }
    }
}

test "runtime rejects reserved GPU surface view kind until a backend supports it" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-surface", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    }));

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime rejects unsupported GPU surface configuration" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-surface-config", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .gpu_surface = .{ .backend = .none },
    }));
    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "transparent-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .gpu_surface = .{ .alpha_mode = .premultiplied },
    }));
    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "wide-color-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .gpu_surface = .{ .color_space = .display_p3 },
    }));
    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "unpaced-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .gpu_surface = .{ .vsync = false },
    }));

    const supported = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "supported-canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .gpu_surface = .{
            .backend = .metal,
            .pixel_format = .bgra8_unorm,
            .present_mode = .timer,
            .alpha_mode = .@"opaque",
            .color_space = .srgb,
            .vsync = true,
        },
    });
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", supported.gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, supported.gpu_color_space);
    try std.testing.expect(supported.gpu_vsync);
}

test "runtime retains canvas display lists on GPU surface views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var text_storage = [_]u8{ 'O', 'K' };
    var stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    var glyphs = [_]canvas.Glyph{
        .{ .id = 42, .x = 12, .y = 24, .advance = 9 },
    };
    var path = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(1, 2), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    var commands: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 320, 240),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(320, 240),
            .stops = &stops,
        } },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = canvas.Color.rgb8(15, 23, 42) },
    });
    try builder.drawText(.{
        .id = 3,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(16, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = text_storage[0..],
        .glyphs = &glyphs,
    });

    const info = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());
    try std.testing.expectEqual(@as(u64, 1), info.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), info.canvas_command_count);

    text_storage[0] = 'N';
    stops[0].offset = 0.5;
    glyphs[0].id = 900;
    path[0].points[0] = geometry.PointF.init(99, 99);

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 3), retained.commandCount());
    switch (retained.commands[0]) {
        .fill_rect => |value| switch (value.fill) {
            .linear_gradient => |gradient| {
                try std.testing.expectEqual(@as(f32, 0), gradient.stops[0].offset);
                try std.testing.expectEqual(@as(f32, 1), gradient.stops[0].color.r);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[1]) {
        .fill_path => |value| try std.testing.expectEqual(@as(f32, 1), value.elements[0].points[0].x),
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[2]) {
        .draw_text => |value| {
            try std.testing.expectEqualStrings("OK", value.text);
            try std.testing.expectEqual(@as(u32, 42), value.glyphs[0].id);
        },
        else => return error.TestUnexpectedResult,
    }

    const snapshot = harness.runtime.automationSnapshot("Canvas");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 1), canvas_view.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), canvas_view.canvas_command_count);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(snapshot, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=3") != null);
}

test "runtime builds canvas frame plans from retained GPU canvas state" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(24, 24, 27) },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(16, 16, 160, 72),
            .radius = canvas.Radius.all(12),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(16, 16),
                .end = geometry.PointF.init(176, 88),
                .stops = &stops,
            } },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(28, 48),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "OK",
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [4]canvas.RenderCommand = undefined;
    var render_batches: [4]canvas.RenderBatch = undefined;
    var resources: [4]canvas.RenderResource = undefined;
    var resource_cache_entries: [4]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [4]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [4]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]canvas.GlyphAtlasCacheAction = undefined;
    var changes: [4]canvas.DiffChange = undefined;
    const frame = try harness.runtime.canvasFramePlan(1, "canvas", null, .{
        .frame_index = 9,
        .timestamp_ns = 100,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(u64, 9), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 100), frame.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 240), frame.surface_size);
    try std.testing.expect(frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 2), frame.display_list.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_plan.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(canvas.RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 320, 240), frame.dirty_bounds.?);
}

test "runtime canvas frame plan computes incremental dirty from previous display list" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 320, 240),
    });

    const previous_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
    };
    const next_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(20, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [0]canvas.RenderResource = .{};
    var resource_cache_entries: [0]canvas.RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]canvas.RenderResourceCacheAction = .{};
    var glyphs: [0]canvas.GlyphAtlasEntry = .{};
    var changes: [2]canvas.DiffChange = undefined;
    const frame = try harness.runtime.canvasFramePlan(1, "canvas", .{ .commands = &previous_commands }, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 240), frame.surface_size);
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 1), frame.changes.len);
    try std.testing.expectEqual(canvas.DiffKind.changed, frame.changes[0].kind);
    try std.testing.expectEqual(@as(?canvas.ObjectId, 1), frame.changes[0].id);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 60, 40), frame.dirty_bounds.?);
}

test "runtime next canvas frame tracks presented state and resource cache" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(24, 24, 27) },
    };
    const first_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(40, 40),
            .stops = &stops,
        } },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [4]canvas.RenderCommand = undefined;
    var render_batches: [4]canvas.RenderBatch = undefined;
    var resources: [4]canvas.RenderResource = undefined;
    var resource_cache_entries: [4]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [8]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [4]canvas.GlyphAtlasEntry = undefined;
    var changes: [4]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(first_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), first_frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.views[0].presented_canvas_revision);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_resource_cache_count);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.changes.len);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_resource_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_profile_work_units);

    const moved_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(20, 0, 40, 40),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(40, 40),
            .stops = &stops,
        } },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &moved_commands });

    const moved_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expect(!moved_frame.full_repaint);
    try std.testing.expect(moved_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), moved_frame.changes.len);
    try std.testing.expectEqual(canvas.DiffKind.changed, moved_frame.changes[0].kind);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 60, 40), moved_frame.dirty_bounds.?);
    try std.testing.expectEqual(@as(usize, 1), moved_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].presented_canvas_revision);
}

test "runtime next canvas frame repaints when retained surface size changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame-resize", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [2]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [2]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(320, 240),
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);

    const resized_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(640, 360),
    }, frame_storage);
    try std.testing.expect(resized_frame.full_repaint);
    try std.testing.expect(resized_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), resized_frame.render_plan.commandCount());
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), resized_frame.dirty_bounds.?);
}

test "runtime next canvas frame retains renderer cache families" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-render-caches", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const path_elements = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path_elements,
            .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .dst = geometry.RectF.init(32, 4, 18, 18),
        } },
        .{ .shadow = .{
            .id = 3,
            .rect = geometry.RectF.init(58, 8, 20, 14),
            .radius = canvas.Radius.all(5),
            .blur = 8,
            .color = canvas.Color.rgba8(15, 23, 42, 80),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    const overrides = [_]canvas.CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
    }};
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(96, 48),
        .render_overrides = &overrides,
    }, canvasFrameScratchStorage(&harness.runtime));
    const first_gpu_packet_summary = first_frame.gpuPacketSummary();
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expectEqual(@as(usize, 1), first_frame.path_geometry_plan.geometryCount());
    try std.testing.expect(first_frame.path_geometry_plan.vertexCount() > 0);
    try std.testing.expect(first_frame.path_geometry_plan.indexCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), first_frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_plan.opacityLayerCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_plan.effectCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_plan.shadowCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.visual_effect_cache_plan.uploadCount());

    const first_info = runtimeViewInfo(harness.runtime.views[0]);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_path_geometry_count);
    try std.testing.expect(first_info.canvas_frame_path_geometry_vertex_count > 0);
    try std.testing.expect(first_info.canvas_frame_path_geometry_index_count > 0);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_image_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_layer_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(@as(usize, 1), first_info.canvas_frame_visual_effect_upload_count);
    try std.testing.expectEqual(first_gpu_packet_summary.command_count, first_info.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cache_action_count, first_info.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cached_resource_command_count, first_info.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), first_info.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(first_info.canvas_frame_gpu_packet_representable);
    try std.testing.expect(first_info.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, first_info.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 4608), first_info.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 4608), first_info.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), first_info.canvas_frame_profile_dirty_ratio);

    const first_gpu_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), first_gpu_frame.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(first_gpu_packet_summary.command_count, first_gpu_frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cache_action_count, first_gpu_frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(first_gpu_packet_summary.cached_resource_command_count, first_gpu_frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), first_gpu_frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(first_gpu_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expect(first_gpu_frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, first_gpu_frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 4608), first_gpu_frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 4608), first_gpu_frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), first_gpu_frame.canvas_frame_profile_dirty_ratio);

    var view_json_buffer: [8192]u8 = undefined;
    const view_json = try writeViewJson(first_info, &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFramePathGeometryCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameImageCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameLayerCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameVisualEffectCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCacheActionCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCachedResourceCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketUnsupportedCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketRepresentable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileWorkUnits\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileRisk\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileSurfaceArea\":4608") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyArea\":4608") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyRatio\":1") != null);

    const retained_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(96, 48),
        .render_overrides = &overrides,
    }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expect(!retained_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.path_geometry_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.image_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.layer_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained_frame.visual_effect_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.visual_effect_cache_plan.retainCount());

    const retained_info = runtimeViewInfo(harness.runtime.views[0]);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_image_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_layer_retain_count);
    try std.testing.expectEqual(@as(usize, 1), retained_info.canvas_frame_visual_effect_retain_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(retained_info.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), retained_info.canvas_frame_profile_work_units);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.idle, retained_info.canvas_frame_profile_risk);
}

test "runtime GPU surface frame event exposes renderer cache family counters" {
    const TestApp = struct {
        frame_count: u32 = 0,
        last_path_geometry_count: usize = 0,
        last_path_geometry_upload_count: usize = 0,
        last_image_count: usize = 0,
        last_image_upload_count: usize = 0,
        last_layer_count: usize = 0,
        last_layer_upload_count: usize = 0,
        last_visual_effect_count: usize = 0,
        last_visual_effect_upload_count: usize = 0,
        last_gpu_packet_command_count: usize = 0,
        last_gpu_packet_cache_action_count: usize = 0,
        last_gpu_packet_cached_resource_command_count: usize = 0,
        last_gpu_packet_unsupported_command_count: usize = 0,
        last_gpu_packet_representable: bool = false,

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    self.frame_count += 1;
                    self.last_path_geometry_count = frame_event.canvas_frame_path_geometry_count;
                    self.last_path_geometry_upload_count = frame_event.canvas_frame_path_geometry_upload_count;
                    self.last_image_count = frame_event.canvas_frame_image_count;
                    self.last_image_upload_count = frame_event.canvas_frame_image_upload_count;
                    self.last_layer_count = frame_event.canvas_frame_layer_count;
                    self.last_layer_upload_count = frame_event.canvas_frame_layer_upload_count;
                    self.last_visual_effect_count = frame_event.canvas_frame_visual_effect_count;
                    self.last_visual_effect_upload_count = frame_event.canvas_frame_visual_effect_upload_count;
                    self.last_gpu_packet_command_count = frame_event.canvas_frame_gpu_packet_command_count;
                    self.last_gpu_packet_cache_action_count = frame_event.canvas_frame_gpu_packet_cache_action_count;
                    self.last_gpu_packet_cached_resource_command_count = frame_event.canvas_frame_gpu_packet_cached_resource_command_count;
                    self.last_gpu_packet_unsupported_command_count = frame_event.canvas_frame_gpu_packet_unsupported_command_count;
                    self.last_gpu_packet_representable = frame_event.canvas_frame_gpu_packet_representable;
                },
                else => {},
            }
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "gpu-canvas-frame-event-render-caches",
                .source = platform.WebViewSource.html("<h1>Hello</h1>"),
                .event_fn = event,
            };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const path_elements = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path_elements,
            .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .dst = geometry.RectF.init(32, 4, 18, 18),
        } },
        .{ .shadow = .{
            .id = 3,
            .rect = geometry.RectF.init(58, 8, 20, 14),
            .radius = canvas.Radius.all(5),
            .blur = 8,
            .color = canvas.Color.rgba8(15, 23, 42, 80),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    const animations = [_]canvas.CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = 0,
        .duration_ms = 1000,
        .from_opacity = 0.5,
        .to_opacity = 1,
    }};
    _ = try harness.runtime.setCanvasRenderAnimations(1, "canvas", &animations);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(96, 48),
        .scale_factor = 1,
        .frame_index = 7,
        .timestamp_ns = 500_000_000,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.frame_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_image_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_image_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_layer_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_layer_upload_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_visual_effect_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_visual_effect_upload_count);
    try std.testing.expect(app_state.last_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_gpu_packet_cache_action_count > 0);
    try std.testing.expect(app_state.last_gpu_packet_cached_resource_command_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_gpu_packet_representable);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_image_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_layer_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_visual_effect_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_command_count, frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_cache_action_count, frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(app_state.last_gpu_packet_cached_resource_command_count, frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);
}

test "runtime next canvas GPU packet returns backend handoff commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 128, 64),
    });

    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{
            .id = 10,
            .rect = geometry.RectF.init(0, 0, 64, 64),
            .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
        } },
        .{ .fill_rounded_rect = .{
            .id = 11,
            .rect = geometry.RectF.init(72, 8, 40, 24),
            .radius = canvas.Radius.all(8),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(72, 8),
                .end = geometry.PointF.init(112, 32),
                .stops = &stops,
            } },
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    const packet = try harness.runtime.nextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = 9_000,
        .surface_size = geometry.SizeF.init(128, 64),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands);

    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    try std.testing.expectEqual(@as(u64, 3), packet.frame_index);
    try std.testing.expectEqual(@as(u64, 9_000), packet.timestamp_ns);
    try std.testing.expectEqual(canvas.CanvasRenderPassLoadAction.clear, packet.load_action);
    try std.testing.expectEqualDeep(geometry.SizeF.init(128, 64), packet.surface_size);
    try std.testing.expectEqual(@as(f32, 2), packet.scale);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 128, 64), packet.scissor.?);
    try std.testing.expectEqual(@as(usize, 2), packet.commandCount());
    try std.testing.expectEqual(@as(usize, 1), packet.cachedResourceCommandCount());
    try std.testing.expectEqual(canvas.CanvasGpuCommandKind.fill_rect_solid, packet.commands[0].kind);
    try std.testing.expectEqual(@as(?canvas.RenderPipelineKind, .solid), packet.commands[0].pipeline);
    try std.testing.expectEqual(@as(?canvas.ObjectId, 10), packet.commands[0].id);
    try std.testing.expectEqual(canvas.CanvasGpuCommandKind.fill_rounded_rect_gradient, packet.commands[1].kind);
    try std.testing.expectEqual(@as(?canvas.RenderPipelineKind, .linear_gradient), packet.commands[1].pipeline);
    try std.testing.expect(packet.commands[1].uses_resource);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(packet.commandCount(), frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(packet.cacheActionCount(), frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(packet.cachedResourceCommandCount(), frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);

    var clean_gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    const clean_packet = try harness.runtime.nextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 4,
        .timestamp_ns = 10_000,
        .surface_size = geometry.SizeF.init(128, 64),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &clean_gpu_commands);
    try std.testing.expect(!clean_packet.requiresRender());
    try std.testing.expect(clean_packet.fullyRepresentable());
    try std.testing.expectEqual(@as(u64, 4), clean_packet.frame_index);
    try std.testing.expectEqual(canvas.CanvasRenderPassLoadAction.skip, clean_packet.load_action);
    try std.testing.expectEqual(@as(usize, 0), clean_packet.commandCount());
}

test "runtime presents next canvas GPU packet" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-present", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 12,
        .timestamp_ns = 44_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer);

    try std.testing.expect(packet.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), packet.commandCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_packet_present_label_storage[0..harness.null_platform.gpu_surface_packet_present_label_len]);
    try std.testing.expectEqual(@as(u64, 12), harness.null_platform.gpu_surface_packet_present_frame_index);
    try std.testing.expectEqual(@as(u64, 44_000), harness.null_platform.gpu_surface_packet_present_timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(96, 48), harness.null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqualDeep([4]u8{ 247, 249, 252, 255 }, harness.null_platform.gpu_surface_packet_present_clear_color_rgba8);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_requires_render);
    try std.testing.expectEqual(packet.commandCount(), harness.null_platform.gpu_surface_packet_present_command_count);
    try std.testing.expectEqual(packet.cacheActionCount(), harness.null_platform.gpu_surface_packet_present_cache_action_count);
    try std.testing.expectEqual(packet.cachedResourceCommandCount(), harness.null_platform.gpu_surface_packet_present_cached_resource_command_count);
    try std.testing.expectEqual(packet.unsupported_command_count, harness.null_platform.gpu_surface_packet_present_unsupported_command_count);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_json_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, packet_json_buffer[0..harness.null_platform.gpu_surface_packet_present_json_len], "\"commands\":[") != null);

    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    try std.testing.expect(!presented_frame.canvas_frame_full_repaint);
    try std.testing.expect(presented_frame.canvas_frame_dirty_bounds == null);
}

test "runtime presents canvas GPU packet with separate presentation scale" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    const packet = try harness.runtime.presentNextCanvasGpuPacketWithScale(1, "canvas", .{
        .frame_index = 12,
        .timestamp_ns = 44_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer, @as(f32, 1));

    try std.testing.expect(packet.requiresRender());
    try std.testing.expectEqual(@as(f32, 1), packet.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime direct canvas GPU packet reports unsupported when JSON buffer is too small" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-direct-buffer", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 41,
        .rect = geometry.RectF.init(8, 6, 32, 20),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnsupportedService, harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{
        .frame_index = 13,
        .timestamp_ns = 45_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), canvas.Color.rgb8(247, 249, 252), &gpu_commands, &packet_json_buffer));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
}

test "runtime presents next canvas frame through packet presenter when available" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-packet", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(4, 4, 24, 18),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [96 * 48 * 4]u8 = undefined;
    var scratch: [96 * 48 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 21,
        .timestamp_ns = 88_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(20, 24, 32), null);

    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expect(result.frame.requiresRender());
    try std.testing.expect(result.packet_representable);
    try std.testing.expectEqual(@as(usize, 1), result.packet_command_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep([4]u8{ 20, 24, 32, 255 }, harness.null_platform.gpu_surface_packet_present_clear_color_rgba8);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime auto-present packet honors presentation scale without invalidating retained frame" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-packet-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 96, 48),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(4, 4, 24, 18),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [96 * 48 * 4]u8 = undefined;
    var scratch: [96 * 48 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 21,
        .timestamp_ns = 88_000,
        .surface_size = geometry.SizeF.init(96, 48),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(20, 24, 32), @as(f32, 1));

    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expectEqual(@as(f32, 2), result.frame.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime falls back to pixels when packet JSON buffer is too small" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-packet-buffer-fallback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 4, 4),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = canvas.Color.rgb8(37, 99, 235) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [32]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
}

test "runtime falls back to pixel presentation when packet presenter is unavailable" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 4, 4),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expect(result.frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime pixel fallback honors presentation scale without invalidating retained frame" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-auto-pixels-presentation-scale", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 4, 4),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [4 * 4 * 4]u8 = undefined;
    var scratch: [4 * 4 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 22,
        .timestamp_ns = 89_000,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), @as(f32, 1));

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(f32, 2), result.frame.scale);
    try std.testing.expectEqual(@as(f32, 1), harness.null_platform.gpu_surface_present_scale_factor);
    try std.testing.expectEqual(@as(f32, 2), harness.runtime.views[0].presented_canvas_scale);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
}

test "runtime pixel fallback renders provided canvas image resources" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-image-pixels", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packets = false;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 2, 2),
    });

    const commands = [_]canvas.CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 1, 1),
        .sampling = .nearest,
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    const image_pixels = [_]u8{ 11, 22, 33, 255 };
    const image_resources = [_]canvas.ReferenceImage{.{
        .id = 42,
        .width = 1,
        .height = 1,
        .pixels = &image_pixels,
    }};
    var gpu_commands: [max_canvas_commands_per_view]canvas.CanvasGpuCommand = undefined;
    var packet_json_buffer: [16 * 1024]u8 = undefined;
    var pixels: [2 * 2 * 4]u8 = undefined;
    var scratch: [2 * 2 * 4]u8 = undefined;
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 23,
        .timestamp_ns = 90_000,
        .surface_size = geometry.SizeF.init(2, 2),
        .scale = 1,
        .image_resources = &image_resources,
    }, canvasFrameScratchStorage(&harness.runtime), &gpu_commands, &packet_json_buffer, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0), null);

    try std.testing.expectEqual(CanvasPresentationMode.pixels, result.mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep([4]u8{ 11, 22, 33, 255 }, harness.null_platform.gpu_surface_present_sample_rgba);
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_plan.images[0].width);
    try std.testing.expectEqual(@as(usize, 1), result.frame.image_plan.images[0].height);
    try std.testing.expectEqualSlices(u8, &image_pixels, result.frame.image_plan.images[0].pixels);
}

test "runtime next canvas frame retains and evicts glyph atlas cache" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-glyph-cache", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "A",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [1]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [1]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [1]canvas.TextLine = undefined;
    var text_layout_cache_entries: [1]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [2]canvas.TextLayoutCacheAction = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 1), first_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), first_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), first_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), clean_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_text_layout_retain_count);

    const next_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "B",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 1), changed_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_cache_count);
    try std.testing.expectEqual(@as(u32, 'B'), harness.runtime.views[0].canvas_frame_glyph_atlas_cache[0].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_evict_count);
}

test "runtime next canvas frame keeps recent unused text caches warm" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-text-cache-retention", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(12, 32),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "A",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(32, 32),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "B",
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [2]canvas.RenderBatch = undefined;
    var resources: [2]canvas.RenderResource = undefined;
    var resource_cache_entries: [2]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [2]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [2]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [2]canvas.TextLine = undefined;
    var text_layout_cache_entries: [2]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [4]canvas.TextLayoutCacheAction = undefined;
    var changes: [2]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    };

    _ = try harness.runtime.setCanvasFrameBudget(1, "canvas", .{
        .max_glyph_atlas_uploads = 1,
        .max_text_layout_uploads = 1,
    });
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expectEqual(@as(usize, 2), first_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), first_frame.text_layout_cache_plan.uploadCount());
    const first_budget_status = first_frame.budgetStatus();
    try std.testing.expect(first_budget_status.glyph_atlas_uploads_over);
    try std.testing.expect(first_budget_status.text_layout_uploads_over);
    try std.testing.expectEqual(@as(usize, 2), first_budget_status.exceededCount());
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.views[0].canvas_frame_budget_status.exceededCount());

    const second_commands = [_]canvas.CanvasCommand{first_commands[0]};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &second_commands });
    const second_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(second_frame.requiresRender());
    try std.testing.expect(second_frame.budgetStatus().ok());
    try std.testing.expectEqual(@as(usize, 2), second_frame.glyph_atlas_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), second_frame.glyph_atlas_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.glyph_atlas_cache_plan.evictCount());
    try std.testing.expectEqual(@as(u64, 2), second_frame.glyph_atlas_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), second_frame.glyph_atlas_cache_plan.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(usize, 2), second_frame.text_layout_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), second_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), second_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(u64, 2), second_frame.text_layout_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), second_frame.text_layout_cache_plan.entries[1].last_used_frame);
}

test "runtime canvas frame scratch storage includes text layout caches" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-scratch-text-cache", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 160, 80),
    });

    const first_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "First",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &first_commands });

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_plan.lineCount());
    try std.testing.expectEqual(@as(usize, 1), first_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);

    const next_commands = [_]canvas.CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 5,
        .size = 14,
        .origin = geometry.PointF.init(12, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "Second",
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next_commands });

    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, canvasFrameScratchStorage(&harness.runtime));
    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), changed_frame.text_layout_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 0), changed_frame.text_layout_cache_plan.evictCount());
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.views[0].canvas_frame_text_layout_cache_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].canvas_frame_text_layout_retain_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_text_layout_evict_count);
}

test "runtime next canvas frame applies render override dirty regions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-next-frame-overrides", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 40, 20),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 40, 20), first_frame.dirty_bounds.?);

    const overrides = [_]canvas.CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
        .transform = canvas.Affine.translate(10, 0),
    }};
    const moved_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .render_overrides = &overrides,
    }, frame_storage);
    try std.testing.expect(!moved_frame.full_repaint);
    try std.testing.expect(moved_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), moved_frame.changes.len);
    try std.testing.expectEqual(@as(f32, 0.5), moved_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.translate(10, 0), moved_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 20, 10), moved_frame.dirty_bounds.?);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 20, 10), harness.runtime.views[0].canvas_frame_dirty_bounds.?);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 3,
        .previous_render_overrides = &overrides,
        .render_overrides = &overrides,
    }, frame_storage);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_dirty_bounds == null);
}

test "runtime schedules canvas render animations without display list rebuild" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-runtime-animation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 40, 20),
    });
    try std.testing.expectEqual(@as(u64, 0), try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const start_ns: u64 = 1_000_000_000;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(40, 20),
        .timestamp_ns = start_ns,
        .nonblank = true,
    } });
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1, .timestamp_ns = start_ns }, frame_storage);
    try std.testing.expectEqual(start_ns, try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .timestamp_ns = start_ns + 60_000_000,
        .x = 12,
        .y = 8,
    } });
    try std.testing.expectEqual(start_ns + 60_000_000, try harness.runtime.canvasRenderAnimationStartNs(1, "canvas"));
    const initial_revision = harness.runtime.views[0].canvas_revision;

    const animations = [_]canvas.CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = start_ns,
        .duration_ms = 1_000,
        .easing = .linear,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(10, 0),
        .to_transform = canvas.Affine.identity(),
    }};
    _ = try harness.runtime.setCanvasRenderAnimations(1, "canvas", &animations);
    try std.testing.expectEqual(@as(usize, 1), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const mid_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .timestamp_ns = start_ns + 500_000_000,
    }, frame_storage);
    try std.testing.expectEqual(initial_revision, harness.runtime.views[0].canvas_revision);
    try std.testing.expect(!mid_frame.full_repaint);
    try std.testing.expect(mid_frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), mid_frame.changes.len);
    try std.testing.expectEqual(@as(f32, 0.5), mid_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.translate(5, 0), mid_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 15, 10), mid_frame.dirty_bounds.?);
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const final_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 3,
        .timestamp_ns = start_ns + 1_000_000_000,
    }, frame_storage);
    try std.testing.expect(final_frame.requiresRender());
    try std.testing.expectEqual(@as(f32, 1), final_frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(canvas.Affine.identity(), final_frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 15, 10), final_frame.dirty_bounds.?);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), (try harness.runtime.canvasRenderAnimations(1, "canvas")).len);
    try std.testing.expectEqual(@as(usize, 0), runtimeViewCanvasFrameRenderOverrides(&harness.runtime.views[0]).len);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 4,
        .timestamp_ns = start_ns + 1_016_000_000,
    }, frame_storage);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
}

test "runtime classifies render animation final overrides for cleanup" {
    try std.testing.expect(canvasRenderAnimationFinalOverrideNoop(.{
        .id = 1,
        .to_opacity = 1,
        .to_transform = canvas.Affine.identity(),
    }));
    try std.testing.expect(!canvasRenderAnimationFinalOverrideNoop(.{
        .id = 2,
        .to_opacity = 0,
    }));
    try std.testing.expect(!canvasRenderAnimationFinalOverrideNoop(.{
        .id = 3,
        .to_transform = canvas.Affine.translate(8, 0),
    }));
}

test "runtime presents next canvas frame pixels" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-present-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 4, 4),
    });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };
    var pixels: [8 * 8 * 4]u8 = undefined;
    var scratch: [8 * 8 * 4]u8 = undefined;

    const frame = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, frame_storage, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(usize, 8), harness.null_platform.gpu_surface_present_width);
    try std.testing.expectEqual(@as(usize, 8), harness.null_platform.gpu_surface_present_height);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 4, 4), harness.null_platform.gpu_surface_present_dirty_bounds.?);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), harness.null_platform.gpu_surface_present_byte_len);
    const presented_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expect(!presented_frame.canvas_frame_requires_render);
    try std.testing.expect(!presented_frame.canvas_frame_full_repaint);
    try std.testing.expect(presented_frame.canvas_frame_dirty_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), presented_frame.canvas_frame_profile_work_units);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.idle, presented_frame.canvas_frame_profile_risk);

    const changed_commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(2, 1, 1, 2),
        .fill = .{ .color = canvas.Color.rgb8(0, 128, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &changed_commands });
    const changed_frame = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(4, 4),
        .scale = 2,
    }, frame_storage, &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));

    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expect(!changed_frame.full_repaint);
    try std.testing.expect(changed_frame.dirty_bounds != null);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep(changed_frame.dirty_bounds.?, harness.null_platform.gpu_surface_present_dirty_bounds.?);
}

test "runtime next canvas frame presents empty canvas once" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-empty-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [1]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(320, 240),
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(first_frame.requiresRender());
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 320, 240), first_frame.dirty_bounds.?);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.views[0].presented_canvas_revision);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_requires_render);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_full_repaint);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(320, 240),
    }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expect(!harness.runtime.views[0].canvas_frame_requires_render);
    try std.testing.expect(!harness.runtime.views[0].canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_frame_change_count);
    try std.testing.expect(harness.runtime.views[0].canvas_frame_dirty_bounds == null);
}

test "runtime duplicate GPU surface resize keeps retained canvas frame clean" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-duplicate-resize", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });
    const initial_frame = harness.runtime.views[0].frame;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = initial_frame,
        .scale_factor = 2,
    } });

    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 320, 240),
        .fill = .{ .color = canvas.Color.rgb8(245, 248, 255) },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });

    var render_commands: [1]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [1]canvas.RenderResource = undefined;
    var resource_cache_entries: [1]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [1]canvas.GlyphAtlasEntry = undefined;
    var changes: [2]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 1,
        .surface_size = geometry.SizeF.init(320, 240),
        .scale = 2,
    }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = initial_frame,
        .scale_factor = 2,
    } });
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dirty_region_count);
    try std.testing.expect(harness.runtime.views[0].presented_canvas_valid);

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(320, 240),
        .scale = 2,
    }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = geometry.RectF.init(0, 0, 360, 240),
        .scale_factor = 2,
    } });
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(!harness.runtime.views[0].presented_canvas_valid);
}

test "runtime next canvas frame keeps unchanged clipped display lists incremental" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-clipped-next-frame", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 120, 80),
    });

    const commands = [_]canvas.CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(0, 0, 80, 48) } },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(8, 8, 96, 32), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .pop_clip,
    };
    const changed_commands = [_]canvas.CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(0, 0, 80, 48) } },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(12, 8, 96, 32), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .pop_clip,
    };

    var render_commands: [2]canvas.RenderCommand = undefined;
    var render_batches: [1]canvas.RenderBatch = undefined;
    var resources: [2]canvas.RenderResource = undefined;
    var resource_cache_entries: [2]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [4]canvas.RenderResourceCacheAction = undefined;
    var layers: [2]canvas.RenderLayer = undefined;
    var layer_cache_entries: [2]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [4]canvas.RenderLayerCacheAction = undefined;
    var glyphs: [0]canvas.GlyphAtlasEntry = .{};
    var changes: [4]canvas.DiffChange = undefined;
    const frame_storage = canvas.CanvasFrameStorage{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .layers = &layers,
        .layer_cache_entries = &layer_cache_entries,
        .layer_cache_actions = &layer_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    };

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    const first_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, frame_storage);
    try std.testing.expect(first_frame.full_repaint);
    try std.testing.expect(first_frame.requiresRender());

    const clean_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 2 }, frame_storage);
    try std.testing.expect(!clean_frame.full_repaint);
    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &changed_commands });
    const changed_frame = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 3 }, frame_storage);
    try std.testing.expect(!changed_frame.full_repaint);
    try std.testing.expect(changed_frame.requiresRender());
    try std.testing.expect(changed_frame.dirty_bounds != null);
}

test "runtime invalidates canvas display list dirty regions" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    var initial_commands: [1]canvas.CanvasCommand = undefined;
    var initial_builder = canvas.Builder.init(&initial_commands);
    try initial_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(-10, -10, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(50, 70, 30, 30), harness.runtime.pendingDirtyRegions()[0]);

    var moved_commands: [1]canvas.CanvasCommand = undefined;
    var moved_builder = canvas.Builder.init(&moved_commands);
    try moved_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(10, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(50, 70, 50, 40), harness.runtime.pendingDirtyRegions()[0]);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime requests gpu surface frames for retained canvas changes" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-frame-request", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    var initial_commands: [1]canvas.CanvasCommand = undefined;
    var initial_builder = canvas.Builder.init(&initial_commands);
    try initial_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.gpu_surface_frame_request_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.gpu_surface_frame_request_label_storage[0..harness.null_platform.gpu_surface_frame_request_label_len]);

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", initial_builder.displayList());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    var moved_commands: [1]canvas.CanvasCommand = undefined;
    var moved_builder = canvas.Builder.init(&moved_commands);
    try moved_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(8, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });

    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", moved_builder.displayList());
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.gpu_surface_frame_request_count);
}

test "runtime rejects duplicate canvas ids before replacing retained scene" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-duplicate", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var valid_commands: [1]canvas.CanvasCommand = undefined;
    var valid_builder = canvas.Builder.init(&valid_commands);
    try valid_builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 40, 40),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", valid_builder.displayList());

    const duplicate_commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) } } },
        .{ .blur = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 40, 40), .radius = 4 } },
    };
    try std.testing.expectError(error.DuplicateObjectId, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &duplicate_commands }));

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), retained.commandCount());
    try std.testing.expectEqual(@as(?canvas.ObjectId, 1), retained.commands[0].objectId());
}

test "runtime validates canvas display list command limits" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-limits", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var commands: [max_canvas_commands_per_view + 1]canvas.CanvasCommand = undefined;
    for (&commands) |*command| command.* = .pop_opacity;
    try std.testing.expectError(error.CanvasCommandLimitReached, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands }));
}

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

test "runtime retains canvas widget design tokens" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-design-tokens", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const button = canvas.Widget{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
        .state = .{ .selected = true },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{button} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .colors = .{
            .accent = canvas.Color.rgb8(100, 20, 200),
            .accent_text = canvas.Color.rgb8(255, 250, 240),
        },
        .radius = .{ .md = 7 },
    };
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const themed = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqual(@as(u64, 2), themed.widget_revision);
    try std.testing.expectEqualDeep(tokens, try harness.runtime.canvasWidgetDesignTokens(1, "canvas"));
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const unchanged = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqual(@as(u64, 2), unchanged.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_accent_fill = false;
    var saw_accent_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 1)) {
                    switch (fill.fill) {
                        .color => |color| try std.testing.expectEqualDeep(tokens.colors.accent, color),
                        else => return error.TestUnexpectedResult,
                    }
                    saw_accent_fill = true;
                }
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color);
                    saw_accent_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_accent_fill);
    try std.testing.expect(saw_accent_text);

    const next_tokens = canvas.DesignTokens{
        .colors = .{
            .accent = canvas.Color.rgb8(20, 120, 80),
            .accent_text = canvas.Color.rgb8(240, 255, 250),
        },
    };
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const changed = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", next_tokens);
    try std.testing.expectEqual(@as(u64, 3), changed.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    const changed_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (changed_display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 1)) {
                    switch (fill.fill) {
                        .color => |color| try std.testing.expectEqualDeep(next_tokens.colors.accent, color),
                        else => return error.TestUnexpectedResult,
                    }
                    return;
                }
            },
            else => {},
        }
    }
    return error.TestUnexpectedResult;
}

test "runtime wheel input scrolls retained canvas scroll views" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,
        raw_input_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
                },
                .gpu_surface_input => self.raw_input_count += 1,
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
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.raw_input_count);
    try std.testing.expectEqual(canvas.WidgetPointerPhase.wheel, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_target_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 32), retained.nodes[1].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 20, 180, 32), retained.nodes[2].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 64, 180, 32), retained.nodes[3].frame);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 4), snapshot.widgets.len);
    try std.testing.expectEqual(@as(?f32, 0.5), snapshot.widgets[0].value);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 24.0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 72.0), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 120.0), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expect(snapshot.widgets[0].actions.focus);
    try std.testing.expect(snapshot.widgets[0].actions.increment);
    try std.testing.expect(snapshot.widgets[0].actions.decrement);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, -4, 180, 32), snapshot.widgets[1].bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 40, 180, 32), snapshot.widgets[2].bounds);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#1 role=group") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "value=0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "scroll=[offset=24,viewport=72,content=120]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,increment,decrement]") != null);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_scrolled_button = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(3, 1)) {
                    try std.testing.expectEqualDeep(geometry.RectF.init(0, 20, 180, 32), fill.rect);
                    saw_scrolled_button = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_scrolled_button);

    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity > 0);
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.null_platform.gpu_surface_frame_request_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    var kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), kinetic_layout.nodes[0].widget.value);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    harness.null_platform.gpu_surface_frame_request_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_032_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } });
    const kinetic = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 3), kinetic.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_frame_request_count);

    kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 47.04), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -47.04), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -3.04), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40.96), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity > 0);

    const kinetic_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_kinetic_scrolled_button = false;
    for (kinetic_display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(3, 1)) {
                    try std.testing.expectApproxEqAbs(@as(f32, -3.04), fill.rect.y, 0.01);
                    saw_kinetic_scrolled_button = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_kinetic_scrolled_button);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const clamped = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 4), clamped.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 48), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -48), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -4), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity);

    var settle_frame: usize = 0;
    while (settle_frame < 48) : (settle_frame += 1) {
        harness.runtime.invalidated = false;
        harness.runtime.dirty_region_count = 0;
        _ = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
        kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
        if (@abs(kinetic_layout.nodes[0].widget.value - 48) <= 0.01 and harness.runtime.views[0].widget_scroll_states[0].velocity == 0) break;
    }

    try std.testing.expect(settle_frame < 48);
    try std.testing.expectApproxEqAbs(@as(f32, 48), kinetic_layout.nodes[0].widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -48), kinetic_layout.nodes[1].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -4), kinetic_layout.nodes[2].frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), kinetic_layout.nodes[3].frame.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity);

    const settled_revision = harness.runtime.views[0].widget_revision;
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const idle = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(settled_revision, idle.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime wheel over virtualized scroll does not bubble to parent scroll view" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-virtual-scroll-bubble", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| if (pointer_event.pointer.phase == .wheel) {
                    self.widget_pointer_count += 1;
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
        .frame = geometry.RectF.init(0, 0, 180, 72),
    });

    const virtual_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .list_item, .text = "One" },
        .{ .id = 4, .kind = .list_item, .text = "Two" },
        .{ .id = 5, .kind = .list_item, .text = "Three" },
        .{ .id = 6, .kind = .list_item, .text = "Four" },
    };
    const parent_children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(0, 0, 180, 40),
            .layout = .{ .virtualized = true, .virtual_item_extent = 20 },
            .children = &virtual_children,
        },
        .{ .id = 20, .kind = .button, .frame = geometry.RectF.init(0, 120, 0, 32), .text = "Below" },
    };
    const parent_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &parent_children,
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(parent_scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const initial_revision = harness.runtime.views[0].widget_revision;
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.widget.value);
    try std.testing.expectEqual(initial_revision, harness.runtime.views[0].widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime automation widget wheel timestamps retained canvas scroll input" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-wheel-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 180, 64),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 40, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .scroll_view, .children = &children }, geometry.RectF.init(0, 0, 180, 64), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchAutomationCommand(app, "widget-wheel canvas 1 18");
    try std.testing.expect(harness.runtime.views[0].gpu_input_timestamp_ns > 0);
    try std.testing.expectEqual(harness.runtime.views[0].gpu_input_timestamp_ns, harness.runtime.views[0].gpu_pending_input_timestamp_ns);
    try std.testing.expect(harness.runtime.invalidated);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 18), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);
}

test "runtime automation widget key inputs route to focused canvas widgets" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_command: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-key-automation", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_command = command.name;
                    self.last_source = command.source;
                    self.last_view_label = command.view_label;
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
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(12, 16, 160, 36), .text = "Draft" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(12, 64, 96, 32), .text = "Run", .command = "app.run" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchAutomationCommand(app, "widget-action canvas 2 focus");
    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas a a");

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqualStrings("Drafta", retained.findById(2).?.widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.findById(2).?.widget.text_selection.?);

    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas tab");
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[1].focused);

    try harness.runtime.dispatchAutomationCommand(app, "widget-key canvas enter");
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.run", app_state.last_command);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqualStrings("canvas", app_state.last_view_label);
}

test "runtime applies stored design token scroll physics" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-token-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .scroll = .{
            .wheel_multiplier = 0.5,
            .wheel_velocity_scale = 4,
            .deceleration_per_second = 1,
            .stop_velocity = 0,
        },
    };
    _ = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
    try std.testing.expectEqualDeep(tokens, try harness.runtime.canvasWidgetDesignTokens(1, "canvas"));

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 40,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 20), retained.nodes[0].widget.value);
    try std.testing.expectEqual(@as(f32, -20), retained.nodes[1].frame.y);
    try std.testing.expectEqual(@as(f32, 80), harness.runtime.views[0].widget_scroll_states[0].velocity);

    _ = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 21.28), retained.nodes[0].widget.value, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -21.28), retained.nodes[1].frame.y, 0.001);
    try std.testing.expectEqual(@as(f32, 80), harness.runtime.views[0].widget_scroll_states[0].velocity);
}

test "runtime refreshes hovered canvas widget after scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-hover", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_move,
        .x = 12,
        .y = 12,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.runtime.views[0].canvas_widget_cursor);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].hovered);
    try std.testing.expect(!snapshot.widgets[2].hovered);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 40,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].hovered);
    try std.testing.expect(snapshot.widgets[2].hovered);
}

test "runtime clears focused canvas widget after scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-focus", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.runtime.views[0].canvas_widget_focus_visible_id = 2;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    var route_buffer: [4]canvas.WidgetEventRouteEntry = undefined;
    const initial_route = try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    }, &route_buffer);
    try std.testing.expect(initial_route != null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), initial_route.?.target.?.id);

    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(saw_focus_ring);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[1].focused);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 40,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expect(try harness.runtime.routeCanvasWidgetKeyboardInput(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    }, &route_buffer) == null);

    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    saw_focus_ring = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == testCanvasWidgetPartId(2, 3)) saw_focus_ring = true;
        }
    }
    try std.testing.expect(!saw_focus_ring);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].focused);
    try std.testing.expect(!snapshot.widgets[2].focused);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);
}

test "runtime clears focused canvas widget after kinetic scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-kinetic-focus", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    harness.runtime.views[0].widget_scroll_states[0].velocity = 2500;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const frame = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(u64, 2), frame.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), retained.findById(3).?.frame);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(!snapshot.widgets[1].focused);
    try std.testing.expect(!snapshot.widgets[2].focused);

    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            try std.testing.expect(id != testCanvasWidgetPartId(2, 3));
        }
    }
}

test "runtime reconciles canvas widget render state after keyboard scroll clipping" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-keyboard-scroll-state", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 40),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Two" },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 40),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 1;
    harness.runtime.views[0].canvas_widget_hovered_id = 2;
    harness.runtime.views[0].canvas_widget_cursor = .pointing_hand;
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "pagedown",
    } });

    try std.testing.expectEqual(@as(canvas.ObjectId, 1), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_hovered_id);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.runtime.views[0].canvas_widget_cursor);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 160, 40), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 34), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -34, 160, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 14, 160, 32), retained.findById(3).?.frame);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].focused);
    try std.testing.expect(!snapshot.widgets[1].hovered);
    try std.testing.expect(!snapshot.widgets[2].hovered);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "end",
    } });
    var keyboard_scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), keyboard_scrolled.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -40, 160, 32), keyboard_scrolled.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 8, 160, 32), keyboard_scrolled.findById(3).?.frame);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "home",
    } });
    keyboard_scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), keyboard_scrolled.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 160, 32), keyboard_scrolled.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 48, 160, 32), keyboard_scrolled.findById(3).?.frame);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
}

test "runtime reconciles canvas widget scroll momentum across layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 220, 96),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .children = &children,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity > 0);

    const scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const current_offset = scrolled.findById(1).?.widget.value;
    try std.testing.expectEqual(@as(f32, 24), current_offset);

    const refreshed_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(24, 12, 180, 72),
        .value = current_offset,
        .children = &children,
    };
    const refreshed_widgets = [_]canvas.Widget{
        .{ .id = 10, .kind = .text, .frame = geometry.RectF.init(8, 0, 120, 12), .text = "Activity" },
        refreshed_scroll,
    };
    var refreshed_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const refreshed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &refreshed_widgets }, geometry.RectF.init(0, 0, 220, 96), &refreshed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", refreshed_layout);

    const refreshed = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), refreshed.findById(1).?.widget.value);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[2].velocity > 0);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const kinetic = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 4), kinetic.widget_revision);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    try std.testing.expectEqualDeep(geometry.RectF.init(34, 32, 180, 72), harness.runtime.pendingDirtyRegions()[0]);

    const kinetic_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 47.04), kinetic_layout.findById(1).?.widget.value, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -35.04), kinetic_layout.findById(2).?.frame.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8.96), kinetic_layout.findById(3).?.frame.y, 0.01);
}

test "runtime clamps canvas scroll offset after layout replacement shrinks content" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-clamp-replacement", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 220, 96),
    });

    const full_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const full_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .value = 48,
        .children = &full_children,
    };
    var full_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const full_layout = try canvas.layoutWidgetTree(full_scroll, geometry.RectF.init(0, 0, 180, 72), &full_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", full_layout);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 48), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, -48), retained.findById(2).?.frame.y);

    const short_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
    };
    const short_scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 180, 72),
        .value = 48,
        .children = &short_children,
    };
    var short_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const short_layout = try canvas.layoutWidgetTree(short_scroll, geometry.RectF.init(0, 0, 180, 72), &short_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", short_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(2).?.frame.y);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].offset);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 2), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 72), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 72), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 32), snapshot.widgets[1].bounds);
}

test "runtime chains wheel input from saturated nested canvas scroll views" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,
        last_phase: canvas.WidgetPointerPhase = .hover,
        last_target_id: canvas.ObjectId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-scroll-chain", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => |pointer_event| {
                    self.widget_pointer_count += 1;
                    self.last_phase = pointer_event.pointer.phase;
                    self.last_target_id = if (pointer_event.target) |target| target.id else 0;
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
        .frame = geometry.RectF.init(10, 20, 180, 80),
    });

    const inner_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Inner one" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Inner two" },
    };
    const outer_children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(0, 0, 0, 40),
            .value = 36,
            .children = &inner_children,
        },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 120, 0, 32), .text = "Outer footer" },
    };
    const outer = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &outer_children,
    };

    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(outer, geometry.RectF.init(0, 0, 180, 80), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expectEqual(canvas.WidgetPointerPhase.wheel, app_state.last_phase);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_target_id);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 20, 180, 80), harness.runtime.pendingDirtyRegions()[0]);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqual(@as(f32, 36), retained.nodes[1].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 40), retained.nodes[1].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -60, 180, 32), retained.nodes[2].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -16, 180, 32), retained.nodes[3].frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 96, 180, 32), retained.nodes[4].frame);
    try std.testing.expect(harness.runtime.views[0].widget_scroll_states[0].velocity > 0);
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[1].velocity);
}

test "runtime leaves virtualized canvas scroll views app driven" {
    const TestApp = struct {
        widget_pointer_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-virtual-scroll", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_pointer => self.widget_pointer_count += 1,
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
        .frame = geometry.RectF.init(0, 0, 160, 48),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .layout = .{
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 160, 48), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const retained_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(usize, 0), retained_layout.nodes[0].widget.children.len);
    try std.testing.expectEqual(@as(?u32, 4), retained_layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 20), retained_layout.nodes[0].widget.layout.virtual_item_extent);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .scroll,
        .x = 12,
        .y = 12,
        .delta_y = 20,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.widget_pointer_count);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(layout.nodes[1].frame, retained.nodes[1].frame);
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.views[0].widget_revision);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 5), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 48), snapshot.widgets[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 80), snapshot.widgets[0].scroll.content_extent);
    try std.testing.expect(snapshot.widgets[0].actions.focus);
    try std.testing.expect(snapshot.widgets[0].actions.increment);
    try std.testing.expect(snapshot.widgets[0].actions.decrement);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    const kinetic = try harness.runtime.stepCanvasWidgetKineticScroll(1, "canvas", 16);
    try std.testing.expectEqual(@as(u64, 1), kinetic.widget_revision);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime exposes retained canvas widget text geometry" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-geometry", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 16, 160, 36),
            .text = "Search",
            .text_selection = canvas.TextSelection.collapsed(3),
        },
        .{
            .id = 3,
            .kind = .search_field,
            .frame = geometry.RectF.init(12, 60, 160, 36),
            .text = "Cafe",
            .text_selection = .{ .anchor = 1, .focus = 4 },
            .text_composition = canvas.TextRange.init(2, 4),
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(12, 108, 120, 32),
            .text = "Run",
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const caret = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(caret.caret_bounds != null);
    try std.testing.expect(caret.selection_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), caret.selection_rect_count);
    try std.testing.expect(caret.composition_bounds == null);

    const range = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 3);
    try std.testing.expect(range.caret_bounds == null);
    try std.testing.expect(range.selection_bounds != null);
    try std.testing.expectEqual(@as(usize, 1), range.selection_rect_count);
    try std.testing.expect(range.composition_bounds != null);
    try std.testing.expectEqual(@as(usize, 1), range.composition_rect_count);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 0));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 4));
    try std.testing.expectError(error.InvalidCommand, harness.runtime.canvasWidgetTextGeometry(1, "canvas", 99));
}

test "runtime applies text input to focused canvas text fields" {
    const TestApp = struct {
        widget_keyboard_count: u32 = 0,
        widget_text_input_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_keyboard => |keyboard_event| {
                    self.widget_keyboard_count += 1;
                    if (keyboard_event.keyboard.phase == .text_input) self.widget_text_input_count += 1;
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
        .frame = geometry.RectF.init(0, 0, 240, 120),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 168,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.widget_keyboard_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.widget_text_input_count);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Querya", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("Search", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("Querya", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 6, .end = 6 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_inserted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Querya", text.text);
                    saw_inserted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_inserted_text);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "b",
        .text = "b",
        .modifiers = .{ .primary = true, .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Querya", retained.nodes[1].widget.text);
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "backspace",
    } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Query", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 5 }, snapshot.widgets[0].text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "x",
        .text = "x",
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("x", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .command = true },
    } });
    try std.testing.expectEqual(@as(u64, 7), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try std.testing.expectEqual(@as(u64, 8), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try std.testing.expectEqual(@as(u64, 9), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 9), harness.runtime.views[0].widget_revision);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("x", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_deleted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("x", text.text);
                    saw_deleted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_deleted_text);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Search", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("x", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 1), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 1 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);
}

test "runtime applies text input to canvas textareas" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-textarea-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const textarea = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 180, 84),
        .text = "First",
        .semantics = .{ .label = "Message" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 188,
        .y = 28,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "!",
        .text = "!",
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
        .modifiers = .{ .shift = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!\n", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);
    const newline_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(newline_geometry.caret_bounds.?.y > textarea.frame.y + 24);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowright",
        .modifiers = .{ .command = true },
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);

    const textarea_revision = harness.runtime.views[0].widget_revision;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowup",
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(u64, textarea_revision), harness.runtime.views[0].widget_revision);
    try std.testing.expectEqualStrings("First!\n", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(7), retained.nodes[1].widget.text_selection.?);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "Second" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("First!\nSecond", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(13, 13), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);

    const text_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    try std.testing.expect(text_geometry.caret_bounds != null);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Message", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("First!\nSecond", snapshot.widgets[0].text_value);
    try std.testing.expect(snapshot.widgets[0].actions.set_text);
    try std.testing.expect(snapshot.widgets[0].actions.set_selection);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_textarea_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("First!\nSecond", text.text);
                    try std.testing.expect(text.text_layout != null);
                    try std.testing.expectEqual(canvas.TextWrap.word, text.text_layout.?.wrap);
                    saw_textarea_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_textarea_text);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "\nThird\nFourth\nFifth\nSixth\nSeventh\nEighth" });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.value > 0);
    try std.testing.expect(canvas.textInputMaxScrollOffsetForWidget(retained.nodes[1].widget, .{}) > 0);
    const scrolled_viewport = canvas.textInputViewportForWidget(retained.nodes[1].widget, .{}).?;
    const scrolled_geometry = try harness.runtime.canvasWidgetTextGeometry(1, "canvas", 2);
    const scrolled_caret = scrolled_geometry.caret_bounds.?;
    try std.testing.expect(scrolled_caret.y >= scrolled_viewport.y - 0.001);
    try std.testing.expect(scrolled_caret.maxY() <= scrolled_viewport.maxY() + 0.001);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const scrolled_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_textarea_clip = false;
    for (scrolled_display_list.commands) |command| {
        switch (command) {
            .push_clip => |clip| {
                if (clip.id == testCanvasWidgetPartId(2, 16)) {
                    try std.testing.expectEqualDeep(scrolled_viewport, clip.rect);
                    saw_textarea_clip = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_textarea_clip);
}

test "runtime applies ime composition edits to canvas text fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-ime", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 240, 120),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 3, .focus = 4 } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_selected_text = false;
    var saw_selection_fill = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 3)) saw_selection_fill = true;
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Cafe", text.text);
                    saw_selected_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_selected_text);
    try std.testing.expect(saw_selection_fill);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "\xc3\xa9", .cursor = 2 } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(3, 5), retained.nodes[1].widget.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_composed_text = false;
    var saw_composition_underline = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 4)) {
                    try std.testing.expectEqualStrings("Caf\xc3\xa9", text.text);
                    saw_composed_text = true;
                }
            },
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 5)) saw_composition_underline = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_composed_text);
    try std.testing.expect(saw_composition_underline);

    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Name", snapshot.widgets[0].name);
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 5, .end = 5 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 3, .end = 5 }, snapshot.widgets[0].text_composition.?);

    var a11y_buffer: [1024]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"Caf\xc3\xa9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=3..5") != null);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .commit_composition);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = " noir", .cursor = 5 } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9 noir", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextRange.init(5, 10), retained.nodes[1].widget.text_composition.?);
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);

    try harness.runtime.focusView(1, "canvas");
    harness.runtime.views[0].canvas_widget_focused_id = 2;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(u64, 6), harness.runtime.views[0].widget_revision);

    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.editCanvasWidgetText(1, "canvas", 99, .commit_composition));
}

test "runtime clips canvas widget text edit dirty bounds to scroll ancestors" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clipped-text-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 48),
    });

    const partially_visible_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 40, 0, 32),
        .text = "Draft",
    }};
    var partially_visible_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const partially_visible_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &partially_visible_children },
        geometry.RectF.init(0, 0, 160, 48),
        &partially_visible_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", partially_visible_layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "!" });
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDirtyRegions().len);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 60, 160, 8), harness.runtime.pendingDirtyRegions()[0]);

    const fully_clipped_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 64, 0, 32),
        .text = "Draft",
    }};
    var fully_clipped_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const fully_clipped_layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &fully_clipped_children },
        geometry.RectF.init(0, 0, 160, 48),
        &fully_clipped_nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", fully_clipped_layout);

    try std.testing.expectError(error.InvalidCommand, harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = "!" }));
}

test "runtime clips canvas widget control dirty bounds to scroll ancestors" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-clipped-control-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(10, 20, 160, 48),
    });

    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 40, 0, 32),
        .text = "Partially visible",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 160, 48),
        &nodes,
    );
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const dirty = try runtimeViewSetCanvasWidgetSelected(&harness.runtime.views[0], 2, true);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 40, 160, 8), dirty.?);
}

test "runtime reconciles canvas text edit state across layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });

    const moved_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(20, 24, 180, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var moved_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const moved_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{moved_text_field} }, geometry.RectF.init(0, 0, 260, 140), &moved_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", moved_layout);

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Cafe", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 1, .focus = 4 }, retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const composed_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Caf\xc3\xa9",
        .semantics = .{ .label = "Name" },
    };
    var composed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const composed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{composed_text_field} }, geometry.RectF.init(0, 0, 260, 140), &composed_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", composed_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 5, .end = 5 }, snapshot.widgets[0].text_selection.?);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 5 }, snapshot.widgets[0].text_composition.?);

    const replaced_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Reset",
        .semantics = .{ .label = "Name" },
    };
    var replaced_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const replaced_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{replaced_text_field} }, geometry.RectF.init(0, 0, 260, 140), &replaced_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", replaced_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Reset", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
}

test "runtime preserves canvas text edits across unchanged source layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-source-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Draft",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = canvas.TextSelection.collapsed(5) });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .insert_text = " updated" });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft updated", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);

    const moved_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Draft",
        .semantics = .{ .label = "Name" },
    };
    var moved_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const moved_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{moved_text_field} }, geometry.RectF.init(0, 0, 260, 140), &moved_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", moved_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Draft updated", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(13), retained.nodes[1].widget.text_selection.?);

    const replaced_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Reset",
        .semantics = .{ .label = "Name" },
    };
    var replaced_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const replaced_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{replaced_text_field} }, geometry.RectF.init(0, 0, 260, 140), &replaced_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", replaced_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Reset", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
}

test "runtime avoids dirty regions for reconciled canvas text edit layout replacement" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-reconcile-dirty", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);

    const refreshed_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Caf\xc3\xa9",
        .semantics = .{ .label = "Name" },
    };
    var refreshed_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const refreshed_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{refreshed_text_field} }, geometry.RectF.init(0, 0, 260, 140), &refreshed_nodes);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", refreshed_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}

test "runtime drops canvas text edit state when layout replacement disables text field" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-disabled-text-reconcile", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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
        .frame = geometry.RectF.init(20, 30, 260, 140),
    });

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Cafe",
        .semantics = .{ .label = "Name" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 260, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.views[0].canvas_widget_focused_id = 2;
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_selection = .{ .anchor = 1, .focus = 4 } });
    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "af\xc3\xa9", .cursor = 4 } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(5), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(1, 5), retained.nodes[1].widget.text_composition.?);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    const disabled_text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(24, 28, 184, 36),
        .text = "Caf\xc3\xa9",
        .state = .{ .disabled = true },
        .semantics = .{ .label = "Name" },
    };
    var disabled_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const disabled_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{disabled_text_field} }, geometry.RectF.init(0, 0, 260, 140), &disabled_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", disabled_layout);

    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Caf\xc3\xa9", retained.nodes[1].widget.text);
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
    try std.testing.expect(retained.nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);

    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("Caf\xc3\xa9", snapshot.widgets[0].text_value);
    try std.testing.expect(!snapshot.widgets[0].enabled);
    try std.testing.expect(!snapshot.widgets[0].focused);
    try std.testing.expect(snapshot.widgets[0].text_selection == null);
    try std.testing.expect(snapshot.widgets[0].text_composition == null);
}

test "runtime applies pointer selection to canvas text fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-pointer-selection", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 20,
        .y = 24,
    } });
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, 0), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_drag,
        .x = 47,
        .y = 24,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 3 }, retained.nodes[1].widget.text_selection.?);
    var snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Query", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 3 }, snapshot.widgets[0].text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const selected_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_selection_fill = false;
    for (selected_display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(2, 3)) saw_selection_fill = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_selection_fill);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "X",
        .text = "X",
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Xry", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(1), retained.nodes[1].widget.text_selection.?);
    snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Xry", snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 1, .end = 1 }, snapshot.widgets[0].text_selection.?);
}

test "runtime maps canvas text pointer selection with stored design tokens" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-text-pointer-token-selection", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 160, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const tokens = canvas.DesignTokens{
        .typography = .{ .body_size = 20 },
    };
    _ = try harness.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);

    const point = geometry.PointF.init(47, 24);
    const expected = canvas.textSelectionForWidgetPoint(text_field, point, null, tokens).?;
    const default_selection = canvas.textSelectionForWidgetPoint(text_field, point, null, .{}).?;
    try std.testing.expect(expected.focus != default_selection.focus);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = point.x,
        .y = point.y,
    } });

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(expected, retained.nodes[1].widget.text_selection.?);
}

test "runtime applies text input to focused canvas search fields" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-search-edit", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
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

    const search_field = canvas.Widget{
        .id = 2,
        .kind = .search_field,
        .frame = geometry.RectF.init(12, 16, 180, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{search_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 188,
        .y = 24,
    } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "x",
        .text = "x",
    } });
    try std.testing.expectEqual(@as(u64, 2), harness.runtime.views[0].widget_revision);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryx", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(6, 6), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Queryx", snapshot.widgets[0].text_value);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_search_icon = false;
    var saw_inserted_text = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 3)) {
                    saw_search_icon = true;
                }
            },
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 9)) {
                    try std.testing.expectEqualStrings("Queryx", text.text);
                    saw_inserted_text = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_search_icon);
    try std.testing.expect(saw_inserted_text);

    _ = try harness.runtime.editCanvasWidgetText(1, "canvas", 2, .{ .set_composition = .{ .text = "ing", .cursor = 3 } });
    try std.testing.expectEqual(@as(u64, 3), harness.runtime.views[0].widget_revision);

    const composing = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryxing", composing.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(9), composing.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(6, 9), composing.nodes[1].widget.text_composition.?);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 4), harness.runtime.views[0].widget_revision);

    const restored = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Queryx", restored.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(6), restored.nodes[1].widget.text_selection.?);
    try std.testing.expect(restored.nodes[1].widget.text_composition == null);
    const restored_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("Queryx", restored_snapshot.widgets[0].text_value);
    try std.testing.expect(restored_snapshot.widgets[0].text_composition == null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u64, 5), harness.runtime.views[0].widget_revision);

    const cleared = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("", cleared.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), cleared.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, 0), runtimeViewWidgetSemantics(&harness.runtime.views[0])[0].text_selection.?);
    const cleared_snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expectEqualStrings("", cleared_snapshot.widgets[0].text_value);
    try std.testing.expectEqualDeep(automation.snapshot.TextRange{ .start = 0, .end = 0 }, cleared_snapshot.widgets[0].text_selection.?);

    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const cleared_display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_search_placeholder = false;
    for (cleared_display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.id == testCanvasWidgetPartId(2, 9)) {
                    try std.testing.expectEqualStrings("Search", text.text);
                    saw_search_placeholder = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_search_placeholder);
}

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

test "runtime rejects canvas display lists on non-GPU views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-canvas-reject", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 220, 320, 20),
    });

    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.setCanvasDisplayList(1, "status", .{}));

    var render_commands: [0]canvas.RenderCommand = .{};
    var render_batches: [0]canvas.RenderBatch = .{};
    var resources: [0]canvas.RenderResource = .{};
    var resource_cache_entries: [0]canvas.RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]canvas.RenderResourceCacheAction = .{};
    var glyphs: [0]canvas.GlyphAtlasEntry = .{};
    var changes: [0]canvas.DiffChange = .{};
    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.canvasFramePlan(1, "status", null, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    }));
}

test "runtime rejects oversized shell before creating partial views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-too-large", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    var labels: [platform.max_views + 1][16]u8 = undefined;
    var shell_views: [platform.max_views + 1]app_manifest.ShellView = undefined;
    for (&shell_views, 0..) |*view, index| {
        const label = try std.fmt.bufPrint(&labels[index], "button-{d}", .{index});
        view.* = .{
            .label = label,
            .kind = .button,
            .width = 80,
            .height = 24,
        };
    }

    try std.testing.expectError(error.ViewLimitReached, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime rolls back shell views when a later view fails" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-rollback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "canvas", .kind = .gpu_surface, .width = 320, .height = 240 },
    };

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime applies GPU shell view presentation options" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-gpu-options", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const shell_views = [_]app_manifest.ShellView{.{
        .label = "canvas",
        .kind = .gpu_surface,
        .width = 320,
        .height = 240,
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    }};

    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const canvas_view = testViewByLabel(views, "canvas").?;
    try std.testing.expectEqual(platform.ViewKind.gpu_surface, canvas_view.kind);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, canvas_view.gpu_backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, canvas_view.gpu_pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, canvas_view.gpu_present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", canvas_view.gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, canvas_view.gpu_color_space);
    try std.testing.expect(canvas_view.gpu_vsync);
}

test "runtime restores main webview state when shell creation fails after main update" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "main-shell-rollback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    harness.runtime.windows[0].main_parent = try copyInto(&harness.runtime.windows[0].main_parent_storage, "existing-parent");
    const previous_frame = harness.runtime.windows[0].main_frame;
    const previous_frame_set = harness.runtime.windows[0].main_frame_set;
    const previous_layer = harness.runtime.windows[0].main_layer;
    const previous_parent = harness.runtime.windows[0].main_parent.?;

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "main", .kind = .webview, .fill = true, .layer = 7 },
        .{ .label = "canvas", .kind = .gpu_surface, .width = 320, .height = 240 },
    };

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));
    try std.testing.expectEqual(previous_frame.x, harness.runtime.windows[0].main_frame.x);
    try std.testing.expectEqual(previous_frame.y, harness.runtime.windows[0].main_frame.y);
    try std.testing.expectEqual(previous_frame.width, harness.runtime.windows[0].main_frame.width);
    try std.testing.expectEqual(previous_frame.height, harness.runtime.windows[0].main_frame.height);
    try std.testing.expectEqual(previous_frame_set, harness.runtime.windows[0].main_frame_set);
    try std.testing.expectEqual(previous_layer, harness.runtime.windows[0].main_layer);
    try std.testing.expectEqualStrings(previous_parent, harness.runtime.windows[0].main_parent.?);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
}

test "runtime materializes manifest shell windows into laid out views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-materialize", .source = platform.WebViewSource.html("<h1>Host</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "refresh-button", .kind = .button, .parent = "toolbar", .accessibility_label = "Refresh workspace", .text = "Refresh", .command = "app.refresh" },
        .{ .label = "toolbar-search", .kind = .search_field, .parent = "toolbar", .text = "Search" },
        .{ .label = "toolbar-progress", .kind = .progress_indicator, .parent = "toolbar", .role = "Syncing" },
        .{ .label = "toolbar-mode", .kind = .segmented_control, .parent = "toolbar", .text = "List|Grid", .command = "app.view.mode" },
        .{ .label = "toolbar-icon", .kind = .icon_button, .parent = "toolbar", .text = "R", .command = "app.refresh.icon" },
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 52, .role = "Toolbar" },
        .{ .label = "sidebar-live", .kind = .checkbox, .parent = "sidebar", .x = 18, .y = 92, .text = "Live" },
        .{ .label = "sidebar-mode", .kind = .toggle, .parent = "sidebar", .x = 18, .y = 128, .text = "Mode" },
        .{ .label = "sidebar-row", .kind = .list_item, .parent = "sidebar", .x = 18, .y = 170, .width = 180, .text = "Inbox", .command = "app.open.inbox" },
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 240, .role = "Sidebar" },
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 28, .text = "Ready" },
    };
    const shell_window: app_manifest.ShellWindow = .{
        .label = "shell",
        .title = "Shell",
        .width = 1000,
        .height = 700,
        .restore_policy = .center_on_primary,
        .views = &shell_views,
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const window = try harness.runtime.createShellWindow(shell_window, platform.WebViewSource.html("<h1>Shell</h1>"));
    try std.testing.expectEqual(@as(platform.WindowId, 2), window.id);
    try std.testing.expectEqualStrings("shell", window.label);

    var views_buffer: [13]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(window.id, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const refresh = testViewByLabel(views, "refresh-button").?;
    const search = testViewByLabel(views, "toolbar-search").?;
    const progress = testViewByLabel(views, "toolbar-progress").?;
    const mode = testViewByLabel(views, "toolbar-mode").?;
    const icon = testViewByLabel(views, "toolbar-icon").?;
    const sidebar = testViewByLabel(views, "sidebar").?;
    const checkbox = testViewByLabel(views, "sidebar-live").?;
    const toggle = testViewByLabel(views, "sidebar-mode").?;
    const row = testViewByLabel(views, "sidebar-row").?;
    const content = testViewByLabel(views, "content").?;
    const statusbar = testViewByLabel(views, "statusbar").?;

    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expectEqual(@as(f32, 0), toolbar.frame.x);
    try std.testing.expectEqual(@as(f32, 0), toolbar.frame.y);
    try std.testing.expectEqual(@as(f32, 1000), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 52), toolbar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.button, refresh.kind);
    try std.testing.expectEqualStrings("toolbar", refresh.parent.?);
    try std.testing.expectEqualStrings("Refresh workspace", refresh.accessibility_label);
    try std.testing.expectEqualStrings("Refresh", refresh.text);
    try std.testing.expectEqualStrings("app.refresh", refresh.command);
    try std.testing.expectEqual(@as(f32, 8), refresh.frame.x);
    try std.testing.expectEqual(@as(f32, 10), refresh.frame.y);
    try std.testing.expectEqual(@as(f32, 96), refresh.frame.width);
    try std.testing.expectEqual(@as(f32, 32), refresh.frame.height);

    try std.testing.expectEqual(platform.ViewKind.search_field, search.kind);
    try std.testing.expectEqualStrings("toolbar", search.parent.?);
    try std.testing.expectEqualStrings("Search", search.text);
    try std.testing.expectEqual(@as(f32, 112), search.frame.x);
    try std.testing.expectEqual(@as(f32, 12), search.frame.y);
    try std.testing.expectEqual(@as(f32, 220), search.frame.width);
    try std.testing.expectEqual(@as(f32, 28), search.frame.height);

    try std.testing.expectEqual(platform.ViewKind.progress_indicator, progress.kind);
    try std.testing.expectEqualStrings("toolbar", progress.parent.?);
    try std.testing.expectEqualStrings("Syncing", progress.role);
    try std.testing.expectEqual(@as(f32, 340), progress.frame.x);
    try std.testing.expectEqual(@as(f32, 14), progress.frame.y);
    try std.testing.expectEqual(@as(f32, 24), progress.frame.width);
    try std.testing.expectEqual(@as(f32, 24), progress.frame.height);

    try std.testing.expectEqual(platform.ViewKind.segmented_control, mode.kind);
    try std.testing.expectEqualStrings("toolbar", mode.parent.?);
    try std.testing.expectEqualStrings("List|Grid", mode.text);
    try std.testing.expectEqualStrings("app.view.mode", mode.command);
    try std.testing.expectEqual(@as(f32, 372), mode.frame.x);
    try std.testing.expectEqual(@as(f32, 10), mode.frame.y);
    try std.testing.expectEqual(@as(f32, 168), mode.frame.width);
    try std.testing.expectEqual(@as(f32, 32), mode.frame.height);

    try std.testing.expectEqual(platform.ViewKind.icon_button, icon.kind);
    try std.testing.expectEqualStrings("toolbar", icon.parent.?);
    try std.testing.expectEqualStrings("R", icon.text);
    try std.testing.expectEqualStrings("app.refresh.icon", icon.command);
    try std.testing.expectEqual(@as(f32, 548), icon.frame.x);
    try std.testing.expectEqual(@as(f32, 10), icon.frame.y);
    try std.testing.expectEqual(@as(f32, 32), icon.frame.width);
    try std.testing.expectEqual(@as(f32, 32), icon.frame.height);

    try std.testing.expectEqual(platform.ViewKind.sidebar, sidebar.kind);
    try std.testing.expectEqual(@as(f32, 0), sidebar.frame.x);
    try std.testing.expectEqual(@as(f32, 52), sidebar.frame.y);
    try std.testing.expectEqual(@as(f32, 240), sidebar.frame.width);
    try std.testing.expectEqual(@as(f32, 648), sidebar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.checkbox, checkbox.kind);
    try std.testing.expectEqualStrings("Live", checkbox.text);
    try std.testing.expectEqual(@as(f32, 18), checkbox.frame.x);
    try std.testing.expectEqual(@as(f32, 92), checkbox.frame.y);
    try std.testing.expectEqual(@as(f32, 96), checkbox.frame.width);
    try std.testing.expectEqual(@as(f32, 32), checkbox.frame.height);

    try std.testing.expectEqual(platform.ViewKind.toggle, toggle.kind);
    try std.testing.expectEqualStrings("Mode", toggle.text);
    try std.testing.expectEqual(@as(f32, 18), toggle.frame.x);
    try std.testing.expectEqual(@as(f32, 128), toggle.frame.y);
    try std.testing.expectEqual(@as(f32, 96), toggle.frame.width);
    try std.testing.expectEqual(@as(f32, 32), toggle.frame.height);

    try std.testing.expectEqual(platform.ViewKind.list_item, row.kind);
    try std.testing.expectEqualStrings("Inbox", row.text);
    try std.testing.expectEqualStrings("app.open.inbox", row.command);
    try std.testing.expectEqual(@as(f32, 18), row.frame.x);
    try std.testing.expectEqual(@as(f32, 170), row.frame.y);
    try std.testing.expectEqual(@as(f32, 180), row.frame.width);
    try std.testing.expectEqual(@as(f32, 32), row.frame.height);

    try std.testing.expectEqual(platform.ViewKind.statusbar, statusbar.kind);
    try std.testing.expectEqualStrings("Ready", statusbar.text);
    try std.testing.expectEqual(@as(f32, 240), statusbar.frame.x);
    try std.testing.expectEqual(@as(f32, 672), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 760), statusbar.frame.width);
    try std.testing.expectEqual(@as(f32, 28), statusbar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.webview, content.kind);
    try std.testing.expect(content.bridge_enabled);
    try std.testing.expectEqualStrings("zero://app/content.html", content.url);
    try std.testing.expectEqual(@as(f32, 240), content.frame.x);
    try std.testing.expectEqual(@as(f32, 52), content.frame.y);
    try std.testing.expectEqual(@as(f32, 760), content.frame.width);
    try std.testing.expectEqual(@as(f32, 620), content.frame.height);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = window.id,
        .size = geometry.SizeF.init(1200, 800),
        .scale_factor = 1,
    } });

    const resized_views = harness.runtime.listViews(window.id, &views_buffer);
    const resized_toolbar = testViewByLabel(resized_views, "toolbar").?;
    const resized_sidebar = testViewByLabel(resized_views, "sidebar").?;
    const resized_content = testViewByLabel(resized_views, "content").?;
    const resized_statusbar = testViewByLabel(resized_views, "statusbar").?;

    try std.testing.expectEqual(@as(f32, 1200), resized_toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 748), resized_sidebar.frame.height);
    try std.testing.expectEqual(@as(f32, 960), resized_content.frame.width);
    try std.testing.expectEqual(@as(f32, 720), resized_content.frame.height);
    try std.testing.expectEqual(@as(f32, 772), resized_statusbar.frame.y);
}

test "runtime applies mobile viewport insets to shell layout" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "mobile-viewport-shell-layout", .source = platform.WebViewSource.html("<h1>Mobile</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "mobile-header", .kind = .toolbar, .edge = .top, .height = 52 },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{
        .id = 1,
        .size = geometry.SizeF.init(390, 844),
        .scale_factor = 3,
        .safe_area_insets = geometry.InsetsF.init(47, 0, 34, 0),
    });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, shellBoundsForWindow(&harness.runtime, 1));

    var views_buffer: [4]platform.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    var header = testViewByLabel(views, "mobile-header").?;
    var main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 47), header.frame.y);
    try std.testing.expectEqual(@as(f32, 390), header.frame.width);
    try std.testing.expectEqual(@as(f32, 99), main.frame.y);
    try std.testing.expectEqual(@as(f32, 711), main.frame.height);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = 1,
        .size = geometry.SizeF.init(390, 844),
        .scale_factor = 3,
        .safe_area_insets = geometry.InsetsF.init(47, 0, 34, 0),
        .keyboard_insets = geometry.InsetsF.init(0, 0, 320, 0),
    } });

    views = harness.runtime.listViews(1, &views_buffer);
    header = testViewByLabel(views, "mobile-header").?;
    main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 47), header.frame.y);
    try std.testing.expectEqual(@as(f32, 99), main.frame.y);
    try std.testing.expectEqual(@as(f32, 425), main.frame.height);
}

test "runtime lays out created shell windows with native returned bounds" {
    const ShellCreatePlatform = struct {
        create_count: usize = 0,
        load_count: usize = 0,
        views: [4]platform.ViewOptions = undefined,
        view_count: usize = 0,

        fn platformValue(self: *@This()) platform.Platform {
            return .{
                .context = self,
                .name = "shell-create",
                .surface_value = .{ .id = 1, .size = geometry.SizeF.init(640, 480), .scale_factor = 1 },
                .run_fn = run,
                .services = .{
                    .context = self,
                    .create_window_fn = createWindow,
                    .load_window_webview_fn = loadWindowWebView,
                    .create_view_fn = createView,
                },
            };
        }

        fn run(context: *anyopaque, handler: platform.EventHandler, handler_context: *anyopaque) anyerror!void {
            _ = context;
            _ = handler;
            _ = handler_context;
        }

        fn createWindow(context: ?*anyopaque, options: platform.WindowOptions) anyerror!platform.WindowInfo {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.create_count += 1;
            return .{
                .id = options.id,
                .label = options.label,
                .title = options.resolvedTitle("shell-create"),
                .frame = geometry.RectF.init(20, 30, 1200, 800),
                .scale_factor = 2,
                .open = true,
                .focused = false,
            };
        }

        fn loadWindowWebView(context: ?*anyopaque, window_id: platform.WindowId, source: platform.WebViewSource) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = window_id;
            _ = source;
            self.load_count += 1;
        }

        fn createView(context: ?*anyopaque, options: platform.ViewOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.views[self.view_count] = options;
            self.view_count += 1;
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 40 },
    };
    const shell_window: app_manifest.ShellWindow = .{
        .label = "restored",
        .title = "Restored",
        .width = 900,
        .height = 600,
        .views = &shell_views,
    };

    var host: ShellCreatePlatform = .{};
    var runtime = Runtime.init(.{ .platform = host.platformValue() });
    const window = try runtime.createShellWindow(shell_window, platform.WebViewSource.html("<h1>Restored</h1>"));

    try std.testing.expectEqual(@as(usize, 1), host.create_count);
    try std.testing.expectEqual(@as(usize, 1), host.load_count);
    try std.testing.expectEqual(@as(f32, 1200), window.frame.width);
    try std.testing.expectEqual(@as(f32, 800), window.frame.height);
    try std.testing.expectEqual(@as(usize, 3), host.view_count);
    try std.testing.expectEqualStrings("toolbar", host.views[0].label);
    try std.testing.expectEqual(@as(f32, 1200), host.views[0].frame.width);
    try std.testing.expectEqualStrings("content", host.views[1].label);
    try std.testing.expectEqual(platform.ViewKind.webview, host.views[1].kind);
    try std.testing.expectEqual(@as(f32, 50), host.views[1].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), host.views[1].frame.width);
    try std.testing.expectEqual(@as(f32, 710), host.views[1].frame.height);
    try std.testing.expectEqualStrings("statusbar", host.views[2].label);
    try std.testing.expectEqual(@as(f32, 760), host.views[2].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), host.views[2].frame.width);
}

test "runtime lays out startup shell windows with native configured bounds" {
    const TestApp = struct {
        const scene_views = [_]app_manifest.ShellView{
            .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
            .{ .label = "main", .kind = .webview, .url = "zero://app/main.html", .fill = true },
            .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 40 },
        };
        const scene_windows = [_]app_manifest.ShellWindow{.{
            .label = "main",
            .title = "Startup",
            .width = 900,
            .height = 600,
            .views = &scene_views,
        }};

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            _ = context;
            return .{ .windows = &scene_windows };
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "startup-native-bounds",
                .source = platform.WebViewSource.html("<h1>Startup</h1>"),
                .scene_fn = scene,
            };
        }
    };

    var null_platform = platform.NullPlatform.initWithOptions(
        .{ .id = 1, .size = geometry.SizeF.init(640, 480), .scale_factor = 1 },
        .system,
        .{
            .app_name = "Startup",
            .main_window = .{
                .label = "main",
                .title = "Startup",
                .default_frame = geometry.RectF.init(32, 44, 1200, 800),
            },
        },
    );
    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    runtime.* = Runtime.init(.{ .platform = null_platform.platform() });
    var app_state: TestApp = .{};

    try runtime.dispatchPlatformEvent(app_state.app(), .app_start);

    var windows_buffer: [1]platform.WindowInfo = undefined;
    const windows = runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqual(@as(f32, 32), windows[0].frame.x);
    try std.testing.expectEqual(@as(f32, 44), windows[0].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), windows[0].frame.width);
    try std.testing.expectEqual(@as(f32, 800), windows[0].frame.height);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const main = testViewByLabel(views, "main").?;
    const statusbar = testViewByLabel(views, "statusbar").?;

    try std.testing.expectEqual(@as(f32, 1200), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 1200), main.frame.width);
    try std.testing.expectEqual(@as(f32, 710), main.frame.height);
    try std.testing.expectEqual(@as(f32, 760), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 1200), statusbar.frame.width);
}

test "runtime loads canvas-only startup shell without implicit main webview" {
    const TestApp = struct {
        const scene_views = [_]app_manifest.ShellView{.{
            .label = "canvas",
            .kind = .gpu_surface,
            .fill = true,
        }};
        const scene_windows = [_]app_manifest.ShellWindow{.{
            .label = "main",
            .title = "Canvas",
            .width = 800,
            .height = 600,
            .views = &scene_views,
        }};

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            _ = context;
            return .{ .windows = &scene_windows };
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "canvas-only-startup",
                .scene_fn = scene,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(harness.runtime.loaded_source == null);
    try std.testing.expect(harness.null_platform.loaded_source == null);
    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expect(testViewByLabel(views, "main") == null);
    const canvas_view = testViewByLabel(views, "canvas").?;
    try std.testing.expectEqual(platform.ViewKind.gpu_surface, canvas_view.kind);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 800, 600), canvas_view.frame);

    const snapshot = harness.runtime.automationSnapshot("Canvas");
    try std.testing.expect(snapshot.source == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.views.len);
    try std.testing.expectEqualStrings("canvas", snapshot.views[0].label);
}

test "runtime relayouts shell views attached to startup window" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "startup-shell-layout", .source = platform.WebViewSource.html("<h1>Startup</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 30 },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [4]platform.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    var main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 0), main.frame.x);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 800), main.frame.width);
    try std.testing.expectEqual(@as(f32, 520), main.frame.height);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = 1,
        .size = geometry.SizeF.init(900, 500),
        .scale_factor = 1,
    } });

    views = harness.runtime.listViews(1, &views_buffer);
    main = testViewByLabel(views, "main").?;
    const toolbar = testViewByLabel(views, "toolbar").?;
    const statusbar = testViewByLabel(views, "statusbar").?;
    try std.testing.expectEqual(@as(f32, 900), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 470), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 900), main.frame.width);
    try std.testing.expectEqual(@as(f32, 420), main.frame.height);
}

test "runtime relayout uses owned shell view storage" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "owned-shell-layout", .source = platform.WebViewSource.html("<h1>Owned</h1>") };
        }
    };

    var shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    shell_views[0].height = 200;

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = 1,
        .size = geometry.SizeF.init(900, 500),
        .scale_factor = 1,
    } });

    var views_buffer: [3]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 50), toolbar.frame.height);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 450), main.frame.height);
}

test "runtime clamps shell view layout constraints" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-constraints", .source = platform.WebViewSource.html("<h1>Constraints</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar-button", .kind = .button, .parent = "toolbar", .width = 12, .height = 80, .min_width = 32, .max_height = 30, .text = "Go" },
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 20, .min_height = 44 },
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 500, .max_width = 280 },
        .{ .label = "content", .kind = .webview, .url = "zero://inline", .fill = true, .max_width = 480, .max_height = 360 },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [5]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const button = testViewByLabel(views, "toolbar-button").?;
    const sidebar = testViewByLabel(views, "sidebar").?;
    const content = testViewByLabel(views, "content").?;

    try std.testing.expectEqual(@as(f32, 44), toolbar.frame.height);
    try std.testing.expectEqual(@as(f32, 32), button.frame.width);
    try std.testing.expectEqual(@as(f32, 30), button.frame.height);
    try std.testing.expectEqual(@as(f32, 7), button.frame.y);
    try std.testing.expectEqual(@as(f32, 280), sidebar.frame.width);
    try std.testing.expectEqual(@as(f32, 44), sidebar.frame.y);
    try std.testing.expectEqual(@as(f32, 556), sidebar.frame.height);
    try std.testing.expectEqual(@as(f32, 280), content.frame.x);
    try std.testing.expectEqual(@as(f32, 44), content.frame.y);
    try std.testing.expectEqual(@as(f32, 480), content.frame.width);
    try std.testing.expectEqual(@as(f32, 360), content.frame.height);
}

test "runtime lays out stack children by column axis" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-stack-axis", .source = platform.WebViewSource.html("<h1>Stack</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 240 },
        .{ .label = "filters", .kind = .stack, .parent = "sidebar", .x = 18, .y = 24, .width = 180, .height = 140, .axis = .column },
        .{ .label = "filter-title", .kind = .label, .parent = "filters", .text = "Filters" },
        .{ .label = "filter-live", .kind = .checkbox, .parent = "filters", .text = "Live" },
        .{ .label = "filter-mode", .kind = .toggle, .parent = "filters", .text = "Focus" },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [8]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const stack = testViewByLabel(views, "filters").?;
    const title = testViewByLabel(views, "filter-title").?;
    const live = testViewByLabel(views, "filter-live").?;
    const mode = testViewByLabel(views, "filter-mode").?;

    try std.testing.expectEqual(platform.ViewKind.stack, stack.kind);
    try std.testing.expectEqualStrings("filters", title.parent.?);
    try std.testing.expectEqual(@as(f32, 8), title.frame.x);
    try std.testing.expectEqual(@as(f32, 8), title.frame.y);
    try std.testing.expectEqual(@as(f32, 8), live.frame.x);
    try std.testing.expectEqual(@as(f32, 40), live.frame.y);
    try std.testing.expectEqual(@as(f32, 8), mode.frame.x);
    try std.testing.expectEqual(@as(f32, 80), mode.frame.y);
}

test "runtime lays out split panes and parented webview frames" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-split", .source = platform.WebViewSource.html("<h1>Split</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
        .{ .label = "navigator", .kind = .sidebar, .parent = "body", .width = 220 },
        .{ .label = "main", .kind = .webview, .parent = "body", .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [6]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const body = testViewByLabel(views, "body").?;
    const navigator = testViewByLabel(views, "navigator").?;
    const main = testViewByLabel(views, "main").?;

    try std.testing.expectEqual(platform.ViewKind.split, body.kind);
    try std.testing.expectEqual(@as(f32, 0), body.frame.x);
    try std.testing.expectEqual(@as(f32, 44), body.frame.y);
    try std.testing.expectEqual(@as(f32, 800), body.frame.width);
    try std.testing.expectEqual(@as(f32, 556), body.frame.height);
    try std.testing.expectEqualStrings("body", navigator.parent.?);
    try std.testing.expectEqual(@as(f32, 0), navigator.frame.x);
    try std.testing.expectEqual(@as(f32, 0), navigator.frame.y);
    try std.testing.expectEqual(@as(f32, 220), navigator.frame.width);
    try std.testing.expectEqual(@as(f32, 556), navigator.frame.height);
    try std.testing.expectEqualStrings("body", main.parent.?);
    try std.testing.expectEqual(@as(f32, 220), main.frame.x);
    try std.testing.expectEqual(@as(f32, 44), main.frame.y);
    try std.testing.expectEqual(@as(f32, 580), main.frame.width);
    try std.testing.expectEqual(@as(f32, 556), main.frame.height);
}

test "runtime platform window close clears shell views and child WebViews" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "platform-close", .source = platform.WebViewSource.html("<h1>Close</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "content", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "Main",
        .frame = geometry.RectF.init(0, 0, 800, 600),
        .scale_factor = 1,
        .open = false,
        .focused = false,
    } });

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expect(harness.runtime.windows[0].main_parent == null);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 0), views.len);
}

test "runtime loads scene hook as native shell startup" {
    const TestApp = struct {
        const scene_views = [_]app_manifest.ShellView{
            .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 48, .role = "Toolbar" },
            .{ .label = "refresh", .kind = .button, .parent = "toolbar", .text = "Refresh", .command = "app.refresh" },
            .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
            .{ .label = "status", .kind = .statusbar, .edge = .bottom, .height = 28, .text = "Ready" },
        };
        const scene_windows = [_]app_manifest.ShellWindow{.{
            .label = "workspace",
            .title = "Scene Shell",
            .width = 900,
            .height = 600,
            .views = &scene_views,
        }};

        scene_called: bool = false,
        source_called_after_scene: bool = false,

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.scene_called = true;
            return .{ .windows = &scene_windows };
        }

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.source_called_after_scene = self.scene_called;
            return platform.WebViewSource.html("<h1>Scene content</h1>");
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "scene-shell",
                .source_fn = source,
                .scene_fn = scene,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(900, 600) });
    const state_store = window_state.Store.init(std.testing.io, ".zig-cache/test-runtime-scene-window-state", ".zig-cache/test-runtime-scene-window-state/windows.zon");
    harness.runtime.options.window_state_store = state_store;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(app_state.scene_called);
    try std.testing.expect(app_state.source_called_after_scene);
    try std.testing.expectEqualStrings("<h1>Scene content</h1>", harness.null_platform.loaded_source.?.bytes);

    var windows_buffer: [2]platform.WindowInfo = undefined;
    const windows = harness.runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("workspace", windows[0].label);
    try std.testing.expectEqualStrings("Scene Shell", windows[0].title);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "Native Startup",
        .frame = geometry.RectF.init(0, 0, 900, 600),
        .scale_factor = 1,
        .open = true,
        .focused = true,
    } });

    const updated_windows = harness.runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), updated_windows.len);
    try std.testing.expectEqualStrings("workspace", updated_windows[0].label);
    try std.testing.expectEqualStrings("Scene Shell", updated_windows[0].title);
    var state_buffer: [window_state.max_serialized_bytes]u8 = undefined;
    const persisted = (try state_store.loadWindow("workspace", &state_buffer)).?;
    try std.testing.expectEqualStrings("workspace", persisted.label);
    try std.testing.expectEqualStrings("Scene Shell", persisted.title);

    var views_buffer: [8]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const refresh = testViewByLabel(views, "refresh").?;
    const main = testViewByLabel(views, "main").?;
    const status = testViewByLabel(views, "status").?;

    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expectEqualStrings("Toolbar", toolbar.role);
    try std.testing.expectEqual(platform.ViewKind.button, refresh.kind);
    try std.testing.expectEqualStrings("app.refresh", refresh.command);
    try std.testing.expectEqual(platform.ViewKind.webview, main.kind);
    try std.testing.expectEqual(@as(f32, 48), main.frame.y);
    try std.testing.expectEqual(@as(f32, 524), main.frame.height);
    try std.testing.expectEqual(platform.ViewKind.statusbar, status.kind);
    try std.testing.expectEqualStrings("Ready", status.text);
}

test "runtime automation snapshot includes generic views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "snapshot-views", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 440, 640, 40),
        .role = "status",
        .text = "Ready",
    });
    try harness.runtime.focusView(1, "status");

    const snapshot = harness.runtime.automationSnapshot("Snapshot");
    try std.testing.expect(snapshot.views.len >= 2);
    try std.testing.expectEqualStrings("main", snapshot.views[0].label);
    try std.testing.expectEqual(platform.ViewKind.webview, snapshot.views[0].kind);
    try std.testing.expect(!snapshot.views[0].focused);
    try std.testing.expectEqualStrings("status", snapshot.views[1].label);
    try std.testing.expectEqual(platform.ViewKind.statusbar, snapshot.views[1].kind);
    try std.testing.expectEqualStrings("Ready", snapshot.views[1].text);
    try std.testing.expect(snapshot.views[1].focused);
}

test "runtime configures platform keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const shortcuts = [_]platform.Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredShortcuts().len);
    try std.testing.expectEqualStrings("command.palette", harness.null_platform.configuredShortcuts()[0].id);
}

test "runtime dispatches app activation lifecycle events" {
    const TestApp = struct {
        events: [4]LifecycleEvent = undefined,
        len: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "activation", .source = platform.WebViewSource.html("<h1>Activation</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .lifecycle => |lifecycle| {
                    self.events[self.len] = lifecycle;
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    const event_count_before = harness.null_platform.windowEventCount();
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try std.testing.expectEqual(event_count_before + 1, harness.null_platform.windowEventCount());
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.lastWindowEventWindowId());
    try std.testing.expectEqualStrings("app:activate", harness.null_platform.lastWindowEventName());
    try std.testing.expectEqualStrings("{}", harness.null_platform.lastWindowEventDetail());
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(event_count_before + 2, harness.null_platform.windowEventCount());
    try std.testing.expectEqualStrings("app:deactivate", harness.null_platform.lastWindowEventName());

    try std.testing.expectEqual(@as(usize, 4), app_state.len);
    try std.testing.expectEqual(LifecycleEvent.start, app_state.events[0]);
    try std.testing.expectEqual(LifecycleEvent.frame, app_state.events[1]);
    try std.testing.expectEqual(LifecycleEvent.activate, app_state.events[2]);
    try std.testing.expectEqual(LifecycleEvent.deactivate, app_state.events[3]);
}

test "runtime stores and dispatches appearance preferences" {
    const TestApp = struct {
        appearance_count: u32 = 0,
        last_appearance: platform.Appearance = .{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "appearance-preferences", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .appearance_changed => |appearance| {
                    self.appearance_count += 1;
                    self.last_appearance = appearance;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(@as(u32, 1), app_state.appearance_count);
    try std.testing.expectEqual(platform.ColorScheme.dark, app_state.last_appearance.color_scheme);
    try std.testing.expect(app_state.last_appearance.reduce_motion);
    try std.testing.expect(app_state.last_appearance.high_contrast);
    try std.testing.expectEqual(platform.ColorScheme.dark, harness.runtime.appearance.color_scheme);
    try std.testing.expect(harness.runtime.appearance.reduce_motion);
    try std.testing.expect(harness.runtime.appearance.high_contrast);
}

test "runtime dispatches GPU surface events" {
    const TestApp = struct {
        frame_count: u32 = 0,
        resize_count: u32 = 0,
        input_count: u32 = 0,
        last_label: []const u8 = "",
        last_input_kind: platform.GpuSurfaceInputKind = .pointer_move,
        last_gpu_backend: platform.GpuSurfaceBackend = .none,
        last_gpu_pixel_format: platform.GpuSurfacePixelFormat = .none,
        last_gpu_present_mode: platform.GpuSurfacePresentMode = .none,
        last_gpu_alpha_mode: platform.GpuSurfaceAlphaMode = .none,
        last_gpu_color_space: platform.GpuSurfaceColorSpace = .none,
        last_gpu_vsync: bool = false,
        last_gpu_status: platform.GpuSurfaceStatus = .unavailable,
        last_frame_interval_ns: u64 = 0,
        last_canvas_revision: u64 = 0,
        last_canvas_command_count: usize = 0,
        last_canvas_frame_requires_render: bool = false,
        last_canvas_frame_full_repaint: bool = false,
        last_canvas_frame_batch_count: usize = 0,
        last_canvas_frame_encoder_command_count: usize = 0,
        last_canvas_frame_encoder_cache_action_count: usize = 0,
        last_canvas_frame_encoder_bind_pipeline_count: usize = 0,
        last_canvas_frame_encoder_draw_batch_count: usize = 0,
        last_canvas_frame_resource_count: usize = 0,
        last_canvas_frame_resource_upload_count: usize = 0,
        last_canvas_frame_resource_retain_count: usize = 0,
        last_canvas_frame_resource_evict_count: usize = 0,
        last_canvas_frame_glyph_atlas_entry_count: usize = 0,
        last_canvas_frame_gpu_packet_command_count: usize = 0,
        last_canvas_frame_gpu_packet_cache_action_count: usize = 0,
        last_canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
        last_canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
        last_canvas_frame_gpu_packet_representable: bool = false,
        last_canvas_frame_change_count: usize = 0,
        last_canvas_frame_budget_exceeded_count: usize = 0,
        last_canvas_frame_budget_ok: bool = true,
        last_canvas_frame_dirty_bounds: ?geometry.RectF = null,
        last_canvas_frame_profile_work_units: usize = 0,
        last_canvas_frame_profile_risk: platform.CanvasFrameProfileRisk = .idle,
        last_canvas_frame_profile_surface_area: f32 = 0,
        last_canvas_frame_profile_dirty_area: f32 = 0,
        last_canvas_frame_profile_dirty_ratio: f32 = 0,
        last_input_timestamp_ns: u64 = 0,
        last_input_latency_ns: u64 = 0,
        last_input_latency_budget_ns: u64 = 0,
        last_input_latency_budget_exceeded_count: usize = 0,
        last_input_latency_budget_ok: bool = true,
        last_first_frame_latency_ns: u64 = 0,
        last_first_frame_latency_budget_ns: u64 = 0,
        last_first_frame_latency_budget_exceeded_count: usize = 0,
        last_first_frame_latency_budget_ok: bool = true,
        last_widget_revision: u64 = 0,
        last_widget_node_count: usize = 0,
        last_widget_semantics_count: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-events", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    self.frame_count += 1;
                    self.last_label = frame_event.label;
                    self.last_gpu_backend = frame_event.backend;
                    self.last_gpu_pixel_format = frame_event.pixel_format;
                    self.last_gpu_present_mode = frame_event.present_mode;
                    self.last_gpu_alpha_mode = frame_event.alpha_mode;
                    self.last_gpu_color_space = frame_event.color_space;
                    self.last_gpu_vsync = frame_event.vsync;
                    self.last_gpu_status = frame_event.status;
                    self.last_frame_interval_ns = frame_event.frame_interval_ns;
                    self.last_canvas_revision = frame_event.canvas_revision;
                    self.last_canvas_command_count = frame_event.canvas_command_count;
                    self.last_canvas_frame_requires_render = frame_event.canvas_frame_requires_render;
                    self.last_canvas_frame_full_repaint = frame_event.canvas_frame_full_repaint;
                    self.last_canvas_frame_batch_count = frame_event.canvas_frame_batch_count;
                    self.last_canvas_frame_encoder_command_count = frame_event.canvas_frame_encoder_command_count;
                    self.last_canvas_frame_encoder_cache_action_count = frame_event.canvas_frame_encoder_cache_action_count;
                    self.last_canvas_frame_encoder_bind_pipeline_count = frame_event.canvas_frame_encoder_bind_pipeline_count;
                    self.last_canvas_frame_encoder_draw_batch_count = frame_event.canvas_frame_encoder_draw_batch_count;
                    self.last_canvas_frame_resource_count = frame_event.canvas_frame_resource_count;
                    self.last_canvas_frame_resource_upload_count = frame_event.canvas_frame_resource_upload_count;
                    self.last_canvas_frame_resource_retain_count = frame_event.canvas_frame_resource_retain_count;
                    self.last_canvas_frame_resource_evict_count = frame_event.canvas_frame_resource_evict_count;
                    self.last_canvas_frame_glyph_atlas_entry_count = frame_event.canvas_frame_glyph_atlas_entry_count;
                    self.last_canvas_frame_gpu_packet_command_count = frame_event.canvas_frame_gpu_packet_command_count;
                    self.last_canvas_frame_gpu_packet_cache_action_count = frame_event.canvas_frame_gpu_packet_cache_action_count;
                    self.last_canvas_frame_gpu_packet_cached_resource_command_count = frame_event.canvas_frame_gpu_packet_cached_resource_command_count;
                    self.last_canvas_frame_gpu_packet_unsupported_command_count = frame_event.canvas_frame_gpu_packet_unsupported_command_count;
                    self.last_canvas_frame_gpu_packet_representable = frame_event.canvas_frame_gpu_packet_representable;
                    self.last_canvas_frame_change_count = frame_event.canvas_frame_change_count;
                    self.last_canvas_frame_budget_exceeded_count = frame_event.canvas_frame_budget_exceeded_count;
                    self.last_canvas_frame_budget_ok = frame_event.canvas_frame_budget_ok;
                    self.last_canvas_frame_dirty_bounds = frame_event.canvas_frame_dirty_bounds;
                    self.last_canvas_frame_profile_work_units = frame_event.canvas_frame_profile_work_units;
                    self.last_canvas_frame_profile_risk = frame_event.canvas_frame_profile_risk;
                    self.last_canvas_frame_profile_surface_area = frame_event.canvas_frame_profile_surface_area;
                    self.last_canvas_frame_profile_dirty_area = frame_event.canvas_frame_profile_dirty_area;
                    self.last_canvas_frame_profile_dirty_ratio = frame_event.canvas_frame_profile_dirty_ratio;
                    self.last_input_timestamp_ns = frame_event.input_timestamp_ns;
                    self.last_input_latency_ns = frame_event.input_latency_ns;
                    self.last_input_latency_budget_ns = frame_event.input_latency_budget_ns;
                    self.last_input_latency_budget_exceeded_count = frame_event.input_latency_budget_exceeded_count;
                    self.last_input_latency_budget_ok = frame_event.input_latency_budget_ok;
                    self.last_first_frame_latency_ns = frame_event.first_frame_latency_ns;
                    self.last_first_frame_latency_budget_ns = frame_event.first_frame_latency_budget_ns;
                    self.last_first_frame_latency_budget_exceeded_count = frame_event.first_frame_latency_budget_exceeded_count;
                    self.last_first_frame_latency_budget_ok = frame_event.first_frame_latency_budget_ok;
                    self.last_widget_revision = frame_event.widget_revision;
                    self.last_widget_node_count = frame_event.widget_node_count;
                    self.last_widget_semantics_count = frame_event.widget_semantics_count;
                },
                .gpu_surface_resized => |resize_event| {
                    self.resize_count += 1;
                    self.last_label = resize_event.label;
                },
                .gpu_surface_input => |input_event| {
                    self.input_count += 1;
                    self.last_label = input_event.label;
                    self.last_input_kind = input_event.kind;
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

    const created = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 640, 360),
    });
    const initial_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(created.id, initial_frame.surface_id);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, created.gpu_backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, created.gpu_pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, created.gpu_present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", created.gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, created.gpu_color_space);
    try std.testing.expect(created.gpu_vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, created.gpu_status);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, initial_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, initial_frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, initial_frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", initial_frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, initial_frame.color_space);
    try std.testing.expect(initial_frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, initial_frame.status);
    try std.testing.expectEqual(@as(f32, 640), initial_frame.size.width);
    try std.testing.expectEqual(@as(f32, 360), initial_frame.size.height);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.frame_index);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, initial_frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.input_latency_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, initial_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(initial_frame.input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), initial_frame.first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.first_frame_latency_budget_exceeded_count);
    try std.testing.expect(initial_frame.first_frame_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.canvas_command_count);
    try std.testing.expectEqual(@as(u64, 0), initial_frame.widget_revision);
    try std.testing.expectEqual(@as(usize, 0), initial_frame.widget_node_count);
    const budgeted = try harness.runtime.setCanvasFrameBudget(1, "canvas", .{ .max_commands = 1 });
    try std.testing.expectEqual(@as(usize, 0), budgeted.canvas_frame_budget_exceeded_count);
    try std.testing.expect(budgeted.canvas_frame_budget_ok);

    var commands: [2]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.fillRect(.{
        .id = 10,
        .rect = geometry.RectF.init(0, 0, 320, 180),
        .fill = .{ .color = canvas.Color.rgb8(255, 255, 255) },
    });
    try builder.fillRect(.{
        .id = 11,
        .rect = geometry.RectF.init(320, 0, 320, 180),
        .fill = .{ .color = canvas.Color.rgb8(245, 248, 255) },
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());

    const widgets = [_]canvas.Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(12, 12, 96, 32),
        .text = "Run",
        .semantics = .{ .label = "Run report" },
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &widgets }, geometry.RectF.init(0, 0, 640, 360), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    harness.runtime.invalidated = false;
    harness.runtime.views[0].gpu_surface_created_timestamp_ns = 20;

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 2,
        .frame_index = 7,
        .timestamp_ns = 42,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.frame_count);
    try std.testing.expectEqualStrings("canvas", app_state.last_label);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, app_state.last_gpu_backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, app_state.last_gpu_pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, app_state.last_gpu_present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", app_state.last_gpu_alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, app_state.last_gpu_color_space);
    try std.testing.expect(app_state.last_gpu_vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, app_state.last_gpu_status);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, app_state.last_frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 1), app_state.last_canvas_revision);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_canvas_command_count);
    try std.testing.expect(app_state.last_canvas_frame_requires_render);
    try std.testing.expect(app_state.last_canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), app_state.last_canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_resource_evict_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_glyph_atlas_entry_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_cache_action_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_budget_exceeded_count);
    try std.testing.expect(!app_state.last_canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), app_state.last_canvas_frame_dirty_bounds.?);
    try std.testing.expect(app_state.last_canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, app_state.last_canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), app_state.last_canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(@as(u64, 1), app_state.last_widget_revision);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_widget_node_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_widget_semantics_count);
    try std.testing.expectEqual(@as(u64, 22), app_state.last_first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), app_state.last_first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_first_frame_latency_budget_exceeded_count);
    try std.testing.expect(app_state.last_first_frame_latency_budget_ok);
    try std.testing.expect(!harness.runtime.invalidated);
    const frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(created.id, frame.surface_id);
    try std.testing.expectEqual(@as(platform.WindowId, 1), frame.window_id);
    try std.testing.expectEqualStrings("canvas", frame.label);
    try std.testing.expectEqual(@as(f32, 640), frame.size.width);
    try std.testing.expectEqual(@as(f32, 360), frame.size.height);
    try std.testing.expectEqual(@as(f32, 2), frame.scale_factor);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, frame.color_space);
    try std.testing.expect(frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, frame.status);
    try std.testing.expectEqual(@as(u64, 7), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 42), frame.timestamp_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 0), frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 0), frame.input_latency_ns);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), frame.input_latency_budget_exceeded_count);
    try std.testing.expect(frame.input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 22), frame.first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), frame.first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), frame.first_frame_latency_budget_exceeded_count);
    try std.testing.expect(frame.first_frame_latency_budget_ok);
    try std.testing.expect(frame.nonblank);
    try std.testing.expectEqual(@as(u32, 0xff336699), frame.sample_color);
    try std.testing.expectEqual(@as(u64, 1), frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, 2), frame.canvas_command_count);
    try std.testing.expect(frame.canvas_frame_requires_render);
    try std.testing.expect(frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_resource_evict_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_glyph_atlas_entry_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_command_count, frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_cache_action_count, frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(frame.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), frame.canvas_frame_budget_exceeded_count);
    try std.testing.expect(!frame.canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), frame.canvas_frame_dirty_bounds.?);
    try std.testing.expect(frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), frame.canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(@as(u64, 1), frame.widget_revision);
    try std.testing.expectEqual(@as(usize, 2), frame.widget_node_count);
    try std.testing.expectEqual(@as(usize, 1), frame.widget_semantics_count);
    var view_json_buffer: [8192]u8 = undefined;
    const view_json = try writeViewJson(runtimeViewInfo(harness.runtime.views[0]), &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuWidth\":640") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuHeight\":360") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuScale\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFrame\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuTimestampNs\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFrameIntervalNs\":16666667") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputTimestampNs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyNs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetNs\":16666667") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetExceededCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuInputLatencyBudgetOk\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyNs\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetNs\":150000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetExceededCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuFirstFrameLatencyBudgetOk\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuNonblank\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuSampleColor\":4281558681") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuBackend\":\"metal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuPixelFormat\":\"bgra8_unorm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuPresentMode\":\"timer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuAlphaMode\":\"opaque\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuColorSpace\":\"srgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuVsync\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"gpuStatus\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameRequiresRender\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameFullRepaint\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBatchCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderCommandCount\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderCacheActionCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderBindPipelineCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameEncoderDrawBatchCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceUploadCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceRetainCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameResourceEvictCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGlyphAtlasEntryCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCommandCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCacheActionCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketCachedResourceCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketUnsupportedCommandCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameGpuPacketRepresentable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameChangeCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBudgetExceededCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameBudgetOk\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameDirtyBounds\":{\"x\":0,\"y\":0,\"width\":640,\"height\":360}") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileWorkUnits\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileRisk\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileSurfaceArea\":230400") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyArea\":230400") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"canvasFrameProfileDirtyRatio\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"cursor\":\"arrow\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 2,
        .frame_index = 8,
        .timestamp_ns = 43,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.frame_count);
    try std.testing.expect(app_state.last_canvas_frame_requires_render);
    try std.testing.expect(app_state.last_canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 6), app_state.last_canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_encoder_draw_batch_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_command_count > 0);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_cache_action_count > 0);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(app_state.last_canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_canvas_frame_change_count);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_canvas_frame_budget_exceeded_count);
    try std.testing.expect(!app_state.last_canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), app_state.last_canvas_frame_dirty_bounds.?);
    try std.testing.expect(app_state.last_canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, app_state.last_canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), app_state.last_canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), app_state.last_canvas_frame_profile_dirty_ratio);
    const preview_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 8), preview_frame.frame_index);
    try std.testing.expectEqual(@as(u64, 22), preview_frame.first_frame_latency_ns);
    try std.testing.expect(preview_frame.first_frame_latency_budget_ok);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, preview_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfacePixelFormat.bgra8_unorm, preview_frame.pixel_format);
    try std.testing.expectEqual(platform.GpuSurfacePresentMode.timer, preview_frame.present_mode);
    try std.testing.expectEqual(platform.GpuSurfaceAlphaMode.@"opaque", preview_frame.alpha_mode);
    try std.testing.expectEqual(platform.GpuSurfaceColorSpace.srgb, preview_frame.color_space);
    try std.testing.expect(preview_frame.vsync);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, preview_frame.status);
    try std.testing.expectEqual(platform.default_gpu_frame_interval_ns, preview_frame.frame_interval_ns);
    try std.testing.expect(preview_frame.canvas_frame_requires_render);
    try std.testing.expect(preview_frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 6), preview_frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_command_count, preview_frame.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(app_state.last_canvas_frame_gpu_packet_cache_action_count, preview_frame.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 0), preview_frame.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), preview_frame.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expect(preview_frame.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 1), preview_frame.canvas_frame_budget_exceeded_count);
    try std.testing.expect(!preview_frame.canvas_frame_budget_ok);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), preview_frame.canvas_frame_dirty_bounds.?);
    try std.testing.expect(preview_frame.canvas_frame_profile_work_units > 0);
    try std.testing.expectEqual(platform.CanvasFrameProfileRisk.high, preview_frame.canvas_frame_profile_risk);
    try std.testing.expectEqual(@as(f32, 230400), preview_frame.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(@as(f32, 230400), preview_frame.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(@as(f32, 1), preview_frame.canvas_frame_profile_dirty_ratio);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = geometry.RectF.init(0, 0, 800, 450),
        .scale_factor = 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.resize_count);
    try std.testing.expect(harness.runtime.invalidated);
    const resized_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(f32, 800), resized_frame.size.width);
    try std.testing.expectEqual(@as(f32, 450), resized_frame.size.height);
    try std.testing.expectEqual(@as(f32, 2), resized_frame.scale_factor);
    try std.testing.expectEqual(platform.GpuSurfaceBackend.metal, resized_frame.backend);
    try std.testing.expectEqual(platform.GpuSurfaceStatus.ready, resized_frame.status);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 50_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_down, app_state.last_input_kind);
    try std.testing.expect(harness.runtime.invalidated);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 9,
        .timestamp_ns = 70_000_000,
        .frame_interval_ns = 8_333_333,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u32, 3), app_state.frame_count);
    try std.testing.expectEqual(@as(u64, 50_000_000), app_state.last_input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), app_state.last_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), app_state.last_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), app_state.last_input_latency_budget_exceeded_count);
    try std.testing.expect(!app_state.last_input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 8_333_333), app_state.last_frame_interval_ns);

    const latency_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_frame.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 50_000_000), latency_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), latency_frame.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), latency_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(!latency_frame.input_latency_budget_ok);

    const latency_snapshot = harness.runtime.automationSnapshot("GPU");
    const latency_view = testViewByLabel(latency_snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_view.gpu_frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 50_000_000), latency_view.gpu_input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), latency_view.gpu_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), latency_view.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), latency_view.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(!latency_view.gpu_input_latency_budget_ok);
    try std.testing.expectEqual(@as(u64, 22), latency_view.gpu_first_frame_latency_ns);
    try std.testing.expectEqual(@as(u64, 150_000_000), latency_view.gpu_first_frame_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), latency_view.gpu_first_frame_latency_budget_exceeded_count);
    try std.testing.expect(latency_view.gpu_first_frame_latency_budget_ok);

    var latency_json_buffer: [8192]u8 = undefined;
    const latency_json = try writeViewJson(latency_view, &latency_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuFrameIntervalNs\":8333333") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputTimestampNs\":50000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyNs\":20000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyBudgetExceededCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuInputLatencyBudgetOk\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, latency_json, "\"gpuFirstFrameLatencyNs\":22") != null);

    const relaxed_budget = try harness.runtime.setGpuSurfaceInputLatencyBudget(1, "canvas", 25_000_000);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_budget.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_budget.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_budget.gpu_input_latency_budget_ok);
    const relaxed_snapshot = harness.runtime.automationSnapshot("GPU relaxed");
    const relaxed_view = testViewByLabel(relaxed_snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 20_000_000), relaxed_view.gpu_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_view.gpu_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_view.gpu_input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_view.gpu_input_latency_budget_ok);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .timestamp_ns = 100_000_000,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(800, 450),
        .scale_factor = 2,
        .frame_index = 10,
        .timestamp_ns = 120_000_000,
        .nonblank = true,
        .sample_color = 0xff336699,
    } });
    try std.testing.expectEqual(@as(u64, 100_000_000), app_state.last_input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), app_state.last_input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), app_state.last_input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_input_latency_budget_exceeded_count);
    try std.testing.expect(app_state.last_input_latency_budget_ok);

    const relaxed_frame = try harness.runtime.gpuSurfaceFrame(1, "canvas");
    try std.testing.expectEqual(@as(u64, 100_000_000), relaxed_frame.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), relaxed_frame.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 25_000_000), relaxed_frame.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 0), relaxed_frame.input_latency_budget_exceeded_count);
    try std.testing.expect(relaxed_frame.input_latency_budget_ok);
}

test "runtime tracks retained canvas widget cursor intent" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-widget-cursor", .source = platform.WebViewSource.html("<h1>GPU</h1>") };
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
        .frame = geometry.RectF.init(0, 0, 240, 160),
    });

    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 12, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(10, 52, 140, 32), .text = "Query" },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(10, 96, 140, 32), .value = 0.5 },
    };
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &children }, geometry.RectF.init(0, 0, 240, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    var snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_cursor_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 24 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.pointing_hand, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.null_platform.view_cursor);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.view_cursor_window_id);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.view_cursor_label_storage[0..harness.null_platform.view_cursor_label_len]);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 64 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.text, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.text, harness.null_platform.view_cursor);

    const disabled_children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(10, 12, 96, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(10, 52, 140, 32), .text = "Query", .state = .{ .disabled = true } },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(10, 96, 140, 32), .value = 0.5 },
    };
    var disabled_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const disabled_layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .panel, .children = &disabled_children }, geometry.RectF.init(0, 0, 240, 160), &disabled_nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", disabled_layout);
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.null_platform.view_cursor);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 20, .y = 108 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(platform.Cursor.resize_horizontal, canvas_view.cursor);
    try std.testing.expectEqual(@as(usize, 4), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.resize_horizontal, harness.null_platform.view_cursor);

    var view_json_buffer: [4096]u8 = undefined;
    const view_json = try writeViewJson(canvas_view, &view_json_buffer);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"cursor\":\"resize_horizontal\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 220, .y = 148 } });
    snapshot = harness.runtime.automationSnapshot("Cursor");
    try std.testing.expectEqual(platform.Cursor.arrow, testViewByLabel(snapshot.views, "canvas").?.cursor);
    try std.testing.expectEqual(@as(usize, 5), harness.null_platform.view_cursor_count);
    try std.testing.expectEqual(platform.Cursor.arrow, harness.null_platform.view_cursor);
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
    try std.testing.expectEqualDeep(geometry.RectF.init(9, 51, 142, 34), harness.runtime.pendingDirtyRegions()[0]);

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
    try std.testing.expectEqual(platform.Cursor.pointing_hand, harness.runtime.views[0].canvas_widget_cursor);

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

    const keyboard_count_after_automation_press = app_state.widget_keyboard_count;
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 2, .action = .press });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("widget.run", app_state.last_command);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(keyboard_count_after_automation_press, app_state.widget_keyboard_count);

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

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 4, .action = .increment });
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), runtimeViewWidgetSemantics(&harness.runtime.views[0])[3].value.?, 0.001);
    try std.testing.expectEqual(@as(canvas.ObjectId, 4), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("arrowright", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 6, .action = .select });
    try std.testing.expectEqual(@as(?f32, 1), runtimeViewWidgetSemantics(&harness.runtime.views[0])[5].value);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 12, .action = .select });
    const selected_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(selected_layout.findById(12).?.widget.state.selected);
    try std.testing.expectEqual(@as(f32, 1), selected_layout.findById(12).?.widget.value);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 7, .action = .increment });
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 40.8), scrolled_layout.findById(7).?.widget.value, 0.001);
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), app_state.last_keyboard_target_id);
    try std.testing.expectEqualStrings("pagedown", app_state.last_keyboard_key);

    try dispatchAutomationWidgetAction(&harness.runtime, app, .{ .view_label = "canvas", .id = 7, .action = .decrement });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0.0), scrolled_layout.findById(7).?.widget.value);
    try std.testing.expectEqualStrings("pageup", app_state.last_keyboard_key);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 7, .action = .increment });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 40.8), scrolled_layout.findById(7).?.widget.value, 0.001);
    try std.testing.expectEqual(@as(u32, 5), app_state.widget_keyboard_count);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = 7, .action = .decrement });
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0.0), scrolled_layout.findById(7).?.widget.value);
    try std.testing.expectEqual(@as(u32, 5), app_state.widget_keyboard_count);

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
            .draw_line => |line| {
                if (line.id == testCanvasWidgetPartId(2, 6)) saw_text_caret = true;
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
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

test "runtime dispatches shortcut command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        shortcut_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcut-command", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>"), .event_fn = event };
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
                .shortcut => {
                    self.shortcut_count += 1;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .shortcut = .{
        .id = "app.refresh",
        .key = "r",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.shortcut_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.shortcut, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
}

test "runtime configures platform menus" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredMenus().len);
    try std.testing.expectEqualStrings("View", harness.null_platform.configuredMenus()[0].title);
    try std.testing.expectEqualStrings("app.refresh", harness.null_platform.configuredMenus()[0].items[0].command);
}

test "runtime rejects invalid platform menu shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r" },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const long_id = [_]u8{'x'} ** (platform.max_shortcut_id_bytes + 1);
    const shortcuts = [_]platform.Shortcut{.{ .id = long_id[0..], .key = "p" }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid command catalog" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-commands", .source = platform.WebViewSource.html("<h1>Commands</h1>") };
        }
    };

    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.refresh", .title = "Duplicate Refresh" },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.commands = &commands;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.DuplicateCommand, harness.runtime.run(app_state.app()));
}

test "runtime rejects oversized webview source" {
    const TestApp = struct {
        bytes: [platform.max_window_source_bytes + 1]u8 = [_]u8{'x'} ** (platform.max_window_source_bytes + 1),

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "oversized-source", .source = platform.WebViewSource.html(&self.bytes) };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};

    try std.testing.expectError(error.WindowSourceTooLarge, harness.start(app_state.app()));
}

test "runtime refreshes app source and keeps reload fields owned" {
    const TestApp = struct {
        root_path: [8]u8 = "dist-one".*,
        entry: [10]u8 = "index.html".*,
        origin: [13]u8 = "zero://assets".*,

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            return platform.WebViewSource.assets(.{
                .root_path = self.root_path[0..],
                .entry = self.entry[0..],
                .origin = self.origin[0..],
                .spa_fallback = false,
            });
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "asset-source",
                .source_fn = source,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    const secondary = try harness.runtime.createWindow(.{
        .label = "external",
        .title = "External",
        .source = platform.WebViewSource.url("https://example.test"),
    });

    @memcpy(app_state.root_path[0..], "dist-two");
    @memcpy(app_state.entry[0..], "other.html");
    @memcpy(app_state.origin[0..], "zero://mutant");
    try reloadWindows(&harness.runtime, app_state.app());

    @memcpy(app_state.root_path[0..], "dist-bad");
    @memcpy(app_state.entry[0..], "mutant.htm");
    @memcpy(app_state.origin[0..], "zero://future");

    const loaded = harness.null_platform.window_sources[0].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, loaded.kind);
    try std.testing.expectEqualStrings("zero://mutant", loaded.bytes);
    const assets = loaded.asset_options.?;
    try std.testing.expectEqualStrings("dist-two", assets.root_path);
    try std.testing.expectEqualStrings("other.html", assets.entry);
    try std.testing.expectEqualStrings("zero://mutant", assets.origin);
    try std.testing.expect(!assets.spa_fallback);

    const secondary_source = harness.null_platform.window_sources[@intCast(secondary.id - 1)].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.url, secondary_source.kind);
    try std.testing.expectEqualStrings("https://example.test", secondary_source.bytes);
}

test "extension registry receives runtime lifecycle and command hooks" {
    const ModuleState = struct {
        started: bool = false,
        stopped: bool = false,
        commands: u32 = 0,

        fn start(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            try std.testing.expectEqualStrings("null", runtime_context.platform_name);
            const self: *@This() = @ptrCast(@alignCast(context));
            self.started = true;
        }

        fn stop(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stopped = true;
        }

        fn command(context: *anyopaque, runtime_context: extensions.RuntimeContext, command_value: extensions.Command) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, command_value.name, "native.ping")) self.commands += 1;
        }
    };

    var module_state: ModuleState = .{};
    const modules = [_]extensions.Module{.{
        .info = .{ .id = 1, .name = "native-test", .capabilities = &.{.{ .kind = .native_module }} },
        .context = &module_state,
        .hooks = .{ .start_fn = ModuleState.start, .stop_fn = ModuleState.stop, .command_fn = ModuleState.command },
    }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.extensions = .{ .modules = &modules };

    const app = App{ .context = &module_state, .name = "extensions", .source = platform.WebViewSource.html("<p>Extensions</p>") };
    try harness.start(app);
    try harness.runtime.dispatchEvent(app, .{ .command = .{ .name = "native.ping" } });
    try harness.stop(app);

    try std.testing.expect(module_state.started);
    try std.testing.expect(module_state.stopped);
    try std.testing.expectEqual(@as(u32, 1), module_state.commands);
}

test "runtime dispatches bridge messages through policy and handler registry" {
    const BridgeState = struct {
        calls: u32 = 0,

        fn ping(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("native.ping", invocation.request.command);
            try std.testing.expectEqualStrings("zero://inline", invocation.source.origin);
            try std.testing.expectEqual(@as(u64, 4), invocation.source.window_id);
            try std.testing.expectEqualStrings("{\"source\":\"webview\",\"count\":1}", invocation.request.payload);
            return std.fmt.bufPrint(output, "{{\"pong\":true,\"calls\":{d}}}", .{self.calls});
        }
    };

    var bridge_state: BridgeState = .{};
    const policies = [_]bridge.CommandPolicy{.{ .name = "native.ping", .origins = &.{"zero://inline"} }};
    const handlers = [_]bridge.Handler{.{ .name = "native.ping", .context = &bridge_state, .invoke_fn = BridgeState.ping }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    const app = App{ .context = &bridge_state, .name = "bridge", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":{\"source\":\"webview\",\"count\":1}}",
        .origin = "zero://inline",
        .window_id = 4,
    } });

    try std.testing.expectEqual(@as(u32, 1), bridge_state.calls);
    try std.testing.expectEqual(@as(platform.WindowId, 4), harness.null_platform.lastBridgeResponseWindowId());
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true,\"calls\":1}}", harness.null_platform.lastBridgeResponse());
}

test "runtime keeps async bridge response source labels stable" {
    const AsyncState = struct {
        responder: ?bridge.AsyncResponder = null,

        fn later(context: *anyopaque, invocation: bridge.Invocation, responder: bridge.AsyncResponder) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("native.later", invocation.request.command);
            try std.testing.expectEqualStrings("preview", invocation.source.webview_label);
            try std.testing.expectEqualStrings("https://example.com", invocation.source.origin);
            self.responder = responder;
        }
    };

    var async_state: AsyncState = .{};
    const policies = [_]bridge.CommandPolicy{.{ .name = "native.later", .origins = &.{"https://example.com"} }};
    const handlers = [_]bridge.AsyncHandler{.{ .name = "native.later", .context = &async_state, .invoke_fn = AsyncState.later }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .async_registry = .{ .handlers = &handlers },
    };

    var label_buffer = [_]u8{ 'p', 'r', 'e', 'v', 'i', 'e', 'w' };
    const app = App{ .context = &async_state, .name = "async-bridge", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"async\",\"command\":\"native.later\",\"payload\":null}",
        .origin = "https://example.com",
        .window_id = 1,
        .webview_label = label_buffer[0..],
    } });

    @memcpy(label_buffer[0..], "changed");
    try async_state.responder.?.success("async", "{\"delayed\":true}");
    try std.testing.expectEqualStrings("preview", harness.null_platform.lastBridgeResponseWebViewLabel());
    try std.testing.expectEqualStrings("{\"id\":\"async\",\"ok\":true,\"result\":{\"delayed\":true}}", harness.null_platform.lastBridgeResponse());
}

test "runtime maps bridge dispatch failures to response errors" {
    const FailingState = struct {
        fn fail(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = invocation;
            _ = output;
            return error.ExpectedFailure;
        }
    };

    var failing_state: FailingState = .{};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "native.fail", .origins = &.{"zero://inline"} },
        .{ .name = "native.missing", .origins = &.{"zero://inline"} },
        .{ .name = "native.secure", .origins = &.{"zero://inline"} },
    };
    const handlers = [_]bridge.Handler{.{ .name = "native.fail", .context = &failing_state, .invoke_fn = FailingState.fail }};

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    const app = App{ .context = &failing_state, .name = "bridge-errors", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"deny\",\"command\":\"native.secure\",\"payload\":null}",
        .origin = "https://example.invalid",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing\",\"command\":\"native.missing\",\"payload\":null}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"unknown_command\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad\",\"command\":",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var too_large: [bridge.max_message_bytes + 1]u8 = undefined;
    @memset(too_large[0..], 'x');
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = too_large[0..],
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"payload_too_large\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"fail\",\"command\":\"native.fail\",\"payload\":null}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"handler_failed\"") != null);
}

test "runtime creates lists focuses and closes windows" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "windows", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const info = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    try std.testing.expectEqual(@as(platform.WindowId, 2), info.id);
    var output: [platform.max_windows]platform.WindowInfo = undefined;
    const windows = harness.runtime.listWindows(&output);
    try std.testing.expectEqual(@as(usize, 2), windows.len);

    try harness.runtime.focusWindow(info.id);
    try std.testing.expect(harness.runtime.windows[1].info.focused);
    try harness.runtime.closeWindow(info.id);
    try std.testing.expect(!harness.runtime.windows[1].info.open);
}

test "runtime handles built-in JavaScript window bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "window-bridge", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"palette\",\"title\":\"Palette\",\"width\":320,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"palette\"") != null);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.lastBridgeResponseWindowId());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"duplicate\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "already exists") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad-frame\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"bad-frame\",\"width\":0,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Window options are invalid") != null);
    var invalid_frame_windows: [platform.max_windows]platform.WindowInfo = undefined;
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.listWindows(&invalid_frame_windows).len);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"palette\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing\",\"command\":\"zero-native.window.focus\",\"payload\":{\"label\":\"missing\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Window was not found") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.window.focus\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.window.close\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"open\":false") != null);
}

test "runtime handles built-in JavaScript command bridge commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-bridge", .source = platform.WebViewSource.html("<p>Commands</p>"), .event_fn = event };
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

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const command_origins = [_][]const u8{"zero://inline"};
    harness.runtime.options.security.navigation.allowed_origins = &command_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.save\"}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.save", app_state.last_name);
    try std.testing.expectEqual(CommandSource.bridge, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqualStrings("", app_state.last_view_label);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"name\":\"app.save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"source\":\"bridge\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"id\":\"app.open\"}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "toolbar",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("app.open", app_state.last_name);
    try std.testing.expectEqualStrings("toolbar", app_state.last_view_label);
}

test "runtime lists command catalog through built-in JavaScript command API" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-list", .source = platform.WebViewSource.html("<p>Commands</p>") };
        }
    };

    const commands = [_]Command{
        .{ .id = "app.save", .title = "Save" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .enabled = false, .checked = true },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.commands = &commands;
    const command_origins = [_][]const u8{"zero://inline"};
    harness.runtime.options.security.navigation.allowed_origins = &command_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });

    const response = harness.null_platform.lastBridgeResponse();
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"app.save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"app.sidebar.toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"checked\":true") != null);
}

test "runtime gates JavaScript command API with command permission" {
    const TestApp = struct {
        command_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-permission", .source = platform.WebViewSource.html("<p>Commands</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => self.command_count += 1,
                else => {},
            }
        }
    };

    const command_permission = [_][]const u8{security.permission_command};
    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &command_permission;
    var app_state: TestApp = .{};
    try allowed.start(app_state.app());
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.save\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    const commands = [_]Command{.{ .id = "app.save", .title = "Save" }};
    allowed.runtime.options.commands = &commands;
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"list\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"id\":\"app.save\"") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
    denied.init(.{});
    denied.runtime.options.js_window_api = true;
    denied.runtime.options.security.permissions = &filesystem_only;
    try denied.start(app_state.app());
    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.open\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied-list\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime handles built-in JavaScript platform support commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "platform-support", .source = platform.WebViewSource.html("<p>Platform</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(harness.runtime.supports(.native_views));
    try std.testing.expect(!harness.runtime.supports(.gpu_surfaces));

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"native_views\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"name-selector\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"name\":\"recentDocuments\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"controls\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"nativeControlCommands\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"drops\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"fileDrops\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"activation\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"appActivationEvents\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"gpu\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"gpuSurfaces\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":false") != null);

    var chromium_platform = platform.NullPlatform.initWithEngine(.{}, .chromium);
    harness.runtime.options.platform = chromium_platform.platform();
    try std.testing.expect(!harness.runtime.supports(.tray));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"tray\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "\"result\":false") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"missing\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "Platform feature is invalid") != null);
}

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

    var harness: TestHarness() = undefined;
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
    var harness: TestHarness() = undefined;
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

    var harness: TestHarness() = undefined;
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

    var harness: TestHarness() = undefined;
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

    var harness: TestHarness() = undefined;
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

test "runtime handles built-in JavaScript webview bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-bridge", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"x\":10,\"y\":20,\"width\":300,\"height\":200},\"layer\":2,\"transparent\":true,\"bridge\":false}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try std.testing.expectEqualStrings("preview", harness.null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com", harness.null_platform.webviews[0].url);
    try std.testing.expectEqual(@as(i32, 2), harness.null_platform.webviews[0].layer);
    try std.testing.expect(harness.null_platform.webviews[0].transparent);
    try std.testing.expect(!harness.null_platform.webviews[0].bridge_enabled);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"preview\",\"frame\":{\"x\":11,\"y\":22,\"width\":333,\"height\":222}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(f32, 333), harness.null_platform.webviews[0].frame.width);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.webview.navigate\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.org\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqualStrings("https://example.org", harness.null_platform.webviews[0].url);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"preview\",\"zoom\":1.25}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(f64, 1.25), harness.null_platform.webviews[0].zoom);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1.25") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5\",\"command\":\"zero-native.webview.setLayer\",\"payload\":{\"label\":\"preview\",\"layer\":10}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(i32, 10), harness.null_platform.webviews[0].layer);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"6\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"url\":\"zero://inline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":10") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"7\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"main\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":80}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"8\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"main\",\"zoom\":1.1}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1.1") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"9\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "preview",
    } });
    try std.testing.expectEqualStrings("preview", harness.null_platform.lastBridgeResponseWebViewLabel());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"9\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try std.testing.expectEqualStrings("main", harness.null_platform.lastBridgeResponseWebViewLabel());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"10\",\"command\":\"zero-native.webview.close\",\"payload\":{\"label\":\"preview\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);
}

test "runtime handles built-in JavaScript view bridge commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_command: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "view-bridge", .source = platform.WebViewSource.html("<p>Views</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_command = command.name;
                    self.last_source = command.source;
                    self.last_view_label = command.view_label;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const view_origins = [_][]const u8{ "zero://inline", "zero://app" };
    harness.runtime.options.security.navigation.allowed_origins = &view_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"toolbar\",\"kind\":\"toolbar\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":44},\"role\":\"toolbar\",\"accessibilityLabel\":\"Main tools\",\"text\":\"Tools\",\"command\":\"app.tools\",\"layer\":3}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"kind\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accessibilityLabel\":\"Main tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"text\":\"Tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"command\":\"app.tools\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqualStrings("Main tools", harness.null_platform.views[0].accessibility_label);
    try std.testing.expectEqualStrings("app.tools", harness.null_platform.views[0].command);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.tools",
        .window_id = 1,
        .view_label = "toolbar",
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.tools", app_state.last_command);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar", app_state.last_view_label);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.view.focus\",\"payload\":{\"label\":\"toolbar\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3-next\",\"command\":\"zero-native.view.focusNext\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3-prev\",\"command\":\"zero-native.view.focusPrevious\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.view.setFrame\",\"payload\":{\"label\":\"toolbar\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":52}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":52") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5\",\"command\":\"zero-native.view.setVisible\",\"payload\":{\"label\":\"toolbar\",\"visible\":false}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"visible\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":false") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5-list\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"6\",\"command\":\"zero-native.view.update\",\"payload\":{\"label\":\"toolbar\",\"visible\":true,\"enabled\":false,\"role\":\"banner\",\"accessibilityLabel\":\"Primary actions\",\"text\":\"Actions\",\"command\":\"app.actions\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"role\":\"banner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accessibilityLabel\":\"Primary actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"text\":\"Actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"command\":\"app.actions\"") != null);
    try std.testing.expectEqualStrings("Primary actions", harness.null_platform.views[0].accessibility_label);
    try std.testing.expectEqualStrings("app.actions", harness.null_platform.views[0].command);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"7\",\"command\":\"zero-native.view.close\",\"payload\":{\"label\":\"toolbar\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"open\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":false") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
}

test "runtime handles GPU surface options in JavaScript view bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-view-bridge", .source = platform.WebViewSource.html("<p>GPU</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.js_window_api = true;
    const view_origins = [_][]const u8{ "zero://inline", "zero://app" };
    harness.runtime.options.security.navigation.allowed_origins = &view_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"gpu\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"canvas\",\"kind\":\"gpuSurface\",\"frame\":{\"width\":320,\"height\":240},\"gpuBackend\":\"metal\",\"gpuPixelFormat\":\"bgra8_unorm\",\"gpuPresentMode\":\"timer\",\"gpuAlphaMode\":\"opaque\",\"gpuColorSpace\":\"srgb\",\"gpuVsync\":true}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    const response = harness.null_platform.lastBridgeResponse();
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"kind\":\"gpu_surface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuBackend\":\"metal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuPixelFormat\":\"bgra8_unorm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuPresentMode\":\"timer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuAlphaMode\":\"opaque\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuColorSpace\":\"srgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuVsync\":true") != null);
}

test "runtime gates JavaScript view API with view permission" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "view-permission", .source = platform.WebViewSource.html("<p>Views</p>") };
        }
    };

    const view_permission = [_][]const u8{security.permission_view};
    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &view_permission;
    var app_state: TestApp = .{};
    try allowed.start(app_state.app());
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    const command_permission = [_][]const u8{security.permission_command};
    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
    denied.init(.{});
    denied.runtime.options.js_window_api = true;
    denied.runtime.options.security.permissions = &command_permission;
    try denied.start(app_state.app());
    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime returns closed webview info before compacting storage" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-close-response", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"first\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"first\",\"url\":\"https://example.com/first\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"second\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"second\",\"url\":\"https://example.com/second\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"close-first\",\"command\":\"zero-native.webview.close\",\"payload\":{\"label\":\"first\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"second\"") == null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try std.testing.expectEqualStrings("second", harness.null_platform.webviews[0].label);
}

test "runtime defaults webview commands to source window" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-source-window", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    const secondary = try harness.runtime.createWindow(.{ .label = "secondary" });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = secondary.id,
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(secondary.id, harness.null_platform.webviews[0].window_id);
    try std.testing.expectEqual(secondary.id, harness.null_platform.lastBridgeResponseWindowId());
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"windowId\":2") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":2,\"label\":\"cross-window\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "must match the calling window") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
}

test "runtime validates webview bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-validation", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-url\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView URL is missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-frame\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":0,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"reserved-label\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"main\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "reserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"native-view\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"native-collision\",\"kind\":\"button\",\"frame\":{\"width\":120,\"height\":32},\"text\":\"Native\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"native-collision\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"native-collision\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "View label already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"bad-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":1e1000}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"max-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"max-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":2147483647}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":2147483647") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"out-of-range-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"bad-layer-range\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":100000000000000000000}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"i32-overflow-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"i32-overflow-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":2147483648}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"min-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"min-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":-2147483648}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":-2147483648") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"i32-underflow-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"i32-underflow-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":-2147483649}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"fractional-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"fractional-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":1.5}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"ok\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"duplicate\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.org\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView label already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-window\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":99,\"label\":\"other\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "must match the calling window") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad-window-id\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":\"1\",\"label\":\"bad-window-id\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "windowId must be a non-negative integer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-webview\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"missing\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView was not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var long_label = [_]u8{'a'} ** (platform.max_webview_label_bytes + 1);
    var long_label_request_buffer: [512]u8 = undefined;
    const long_label_request = try std.fmt.bufPrint(&long_label_request_buffer, "{{\"id\":\"long-label\",\"command\":\"zero-native.webview.create\",\"payload\":{{\"label\":\"{s}\",\"url\":\"https://example.com\",\"frame\":{{\"width\":300,\"height\":200}}}}}}", .{&long_label});
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = long_label_request,
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView label is too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var long_url = [_]u8{'a'} ** (platform.max_webview_url_bytes + 1);
    var long_url_request_buffer: [platform.max_webview_url_bytes + 256]u8 = undefined;
    const long_url_request = try std.fmt.bufPrint(&long_url_request_buffer, "{{\"id\":\"long-url\",\"command\":\"zero-native.webview.create\",\"payload\":{{\"label\":\"too-long-url\",\"url\":\"{s}\",\"frame\":{{\"width\":300,\"height\":200}}}}}}", .{&long_url});
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = long_url_request,
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView URL is too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied-url\",\"command\":\"zero-native.webview.navigate\",\"payload\":{\"label\":\"preview\",\"url\":\"https://blocked.example\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "navigation policy") != null);

    harness.runtime.options.platform.services.set_webview_zoom_fn = null;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"unsupported-zoom\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"preview\",\"zoom\":1.25}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "not available on this platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"escaped\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview \\\"quoted\\\"\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"preview \\\"quoted\\\"\"") != null);
}

test "runtime reports actionable unsupported webview capability errors" {
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedChildWebViews));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedWebViewBridge));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewFrame));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewZoom));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewLayer));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.InvalidWindowOptions));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.DuplicateWindowLabel));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.WindowNotFound));
    try std.testing.expectEqualStrings("This backend does not support child WebViews yet", builtinBridgeErrorMessage(error.UnsupportedChildWebViews));
    try std.testing.expectEqualStrings("This backend does not support bridge-enabled child WebViews yet", builtinBridgeErrorMessage(error.UnsupportedWebViewBridge));
    try std.testing.expectEqualStrings("This backend does not support resizing the main WebView yet", builtinBridgeErrorMessage(error.UnsupportedMainWebViewFrame));
    try std.testing.expectEqualStrings("This backend does not support zooming the main WebView yet", builtinBridgeErrorMessage(error.UnsupportedMainWebViewZoom));
    try std.testing.expectEqualStrings("This backend does not support changing the main WebView layer", builtinBridgeErrorMessage(error.UnsupportedMainWebViewLayer));
}

test "runtime gates JavaScript window API by origin and configured permission" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "window-api-security", .source = platform.WebViewSource.html("<p>Windows</p>") };
    const Harness = TestHarness();

    const denied_origin = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_origin);
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    const denied_permission = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_permission);
    denied_permission.init(.{});
    denied_permission.runtime.options.js_window_api = true;
    denied_permission.runtime.options.security.permissions = &filesystem_only;
    try denied_permission.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"permission\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_permission.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const window_permission = [_][]const u8{security.permission_window};
    const allowed = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &window_permission;
    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
}

test "runtime gates JavaScript webview API by origin and configured permission" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "webview-api-security", .source = platform.WebViewSource.html("<p>WebViews</p>") };
    const Harness = TestHarness();

    const denied_origin = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_origin);
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "WebView API is not permitted") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    const denied_permission = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_permission);
    denied_permission.init(.{});
    denied_permission.runtime.options.js_window_api = true;
    denied_permission.runtime.options.security.permissions = &filesystem_only;
    try denied_permission.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"permission\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_permission.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const window_permission = [_][]const u8{security.permission_window};
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    const allowed = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &window_permission;
    allowed.runtime.options.security.navigation.allowed_origins = &webview_origins;
    try allowed.runtime.dispatchPlatformEvent(app, .app_start);
    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
}

test "runtime gates built-in bridge commands through explicit policy" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "builtin-policy", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    const window_permissions = [_][]const u8{security.permission_window};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.window.create", .permissions = &window_permissions, .origins = &.{"zero://inline"} },
        .{ .name = "zero-native.webview.create", .permissions = &window_permissions, .origins = &.{"zero://inline"} },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.security.permissions = &window_permissions;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"policy-window\",\"title\":\"Policy\",\"width\":320,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"webview\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"policy-webview\",\"url\":\"https://example.com\",\"frame\":{\"width\":320,\"height\":240}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    harness.runtime.options.security.permissions = &.{};
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"denied-window\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime denies built-in dialog bridge commands by default" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "dialog-denied", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.dialog.showMessage\",\"payload\":{\"message\":\"Hello\"}}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime reports dialog bridge validation errors as invalid requests" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "dialog-invalid", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
    const dialog_permission = [_][]const u8{security.permission_dialog};
    const dialog_policy = [_]bridge.CommandPolicy{.{
        .name = "zero-native.dialog.showMessage",
        .permissions = &dialog_permission,
        .origins = &.{"zero://inline"},
    }};
    harness.runtime.options.security.permissions = &dialog_permission;
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &dialog_policy };

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-dialog\",\"command\":\"zero-native.dialog.showMessage\",\"payload\":{\"primaryButton\":\"\"}}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"internal_error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Dialog options are invalid") != null);
}

test "runtime validates native OS actions before platform dispatch" {
    var harness: TestHarness() = undefined;
    harness.init(.{});

    var dialog_paths: [platform.max_dialog_paths_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidDialogOptions, harness.runtime.showOpenDialog(.{}, dialog_paths[0..0]));
    var small_dialog_paths: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, harness.runtime.showOpenDialog(.{}, &small_dialog_paths));
    const long_dialog_title = [_]u8{'x'} ** (platform.max_dialog_title_bytes + 1);
    try std.testing.expectError(error.DialogFieldTooLarge, harness.runtime.showOpenDialog(.{ .title = &long_dialog_title }, &dialog_paths));
    const open_result = try harness.runtime.showOpenDialog(.{ .title = "Open" }, &dialog_paths);
    try std.testing.expectEqual(@as(usize, 1), open_result.count);
    try std.testing.expectEqualStrings("/tmp/zero-native-open.txt", open_result.paths);

    var save_path: [platform.max_dialog_path_bytes]u8 = undefined;
    var small_save_path: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, harness.runtime.showSaveDialog(.{ .default_name = "report.txt" }, &small_save_path));
    const saved = (try harness.runtime.showSaveDialog(.{ .default_name = "report.txt" }, &save_path)).?;
    try std.testing.expectEqualStrings("report.txt", saved);

    try std.testing.expectError(error.InvalidDialogOptions, harness.runtime.showMessageDialog(.{ .primary_button = "" }));
    const dialog_result = try harness.runtime.showMessageDialog(.{ .message = "Proceed?", .primary_button = "OK" });
    try std.testing.expectEqual(platform.MessageDialogResult.primary, dialog_result);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.open_dialog_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.save_dialog_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.message_dialog_count);

    try std.testing.expectError(error.InvalidNotificationOptions, harness.runtime.showNotification(.{ .title = "" }));
    try harness.runtime.showNotification(.{
        .title = "Build finished",
        .subtitle = "zero-native",
        .body = "All checks passed.",
    });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", harness.null_platform.lastNotificationTitle());
    try std.testing.expectEqualStrings("zero-native", harness.null_platform.lastNotificationSubtitle());
    try std.testing.expectEqualStrings("All checks passed.", harness.null_platform.lastNotificationBody());

    try std.testing.expectError(error.NavigationDenied, harness.runtime.openExternalUrl("https://example.com/docs"));
    try std.testing.expectError(error.InvalidExternalUrl, harness.runtime.openExternalUrl("mailto:hello@example.com"));

    const allowed_urls = [_][]const u8{"https://example.com/*"};
    harness.runtime.options.security.navigation.external_links = .{
        .action = .open_system_browser,
        .allowed_urls = &allowed_urls,
    };
    try harness.runtime.openExternalUrl("https://example.com/docs");
    try std.testing.expectEqualStrings("https://example.com/docs", harness.null_platform.lastExternalUrl());

    try std.testing.expectError(error.InvalidRevealPath, harness.runtime.revealPath(""));
    try harness.runtime.revealPath("/tmp/zero-native-example.txt");
    try std.testing.expectEqualStrings("/tmp/zero-native-example.txt", harness.null_platform.lastRevealedPath());

    try std.testing.expectError(error.InvalidRecentDocumentPath, harness.runtime.addRecentDocument(""));
    try harness.runtime.addRecentDocument("/tmp/recent-zero-native-example.txt");
    try std.testing.expectEqualStrings("/tmp/recent-zero-native-example.txt", harness.null_platform.lastRecentDocumentPath());
    try harness.runtime.clearRecentDocuments();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.recentDocumentsClearedCount());

    var clipboard_buffer: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidClipboardOptions, harness.runtime.readClipboardData("", &clipboard_buffer));
    try std.testing.expectError(error.InvalidClipboardOptions, harness.runtime.writeClipboardData(.{ .mime_type = "", .bytes = "text" }));
    try harness.runtime.writeClipboard("plain text");
    try std.testing.expectEqualStrings("plain text", try harness.runtime.readClipboard(&clipboard_buffer));
    try std.testing.expectEqualStrings("text/plain", harness.null_platform.lastClipboardMimeType());
    try harness.runtime.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<strong>bold</strong>" });
    try std.testing.expectEqualStrings("text/html", harness.null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("<strong>bold</strong>", try harness.runtime.readClipboardData("text/html", &clipboard_buffer));

    try std.testing.expectError(error.InvalidCredentialOptions, harness.runtime.setCredential(.{ .service = "", .account = "alice", .secret = "secret-token" }));
    try std.testing.expectError(error.InvalidCredentialOptions, harness.runtime.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "" }));
    try harness.runtime.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "secret-token" });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.credentialSetCount());
    try std.testing.expectEqualStrings("dev.zero-native.test", harness.null_platform.lastCredentialService());
    try std.testing.expectEqualStrings("alice", harness.null_platform.lastCredentialAccount());
    try std.testing.expectEqualStrings("secret-token", harness.null_platform.lastCredentialSecret());

    var credential_buffer: [64]u8 = undefined;
    const secret = (try harness.runtime.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer)).?;
    try std.testing.expectEqualStrings("secret-token", secret);
    try std.testing.expectEqual(@as(?[]const u8, null), try harness.runtime.getCredential(.{ .service = "dev.zero-native.test", .account = "bob" }, &credential_buffer));
    try std.testing.expect(try harness.runtime.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" }));
    try std.testing.expect(!try harness.runtime.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" }));

    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.createTray(.{ .items = &.{.{ .label = "" }} }));
    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{.{ .label = "" }}));
    try harness.runtime.createTray(.{
        .icon_path = "/tmp/tray.png",
        .tooltip = "zero-native",
        .items = &.{
            .{ .id = 1, .label = "Open" },
            .{ .separator = true },
            .{ .id = 2, .label = "Quit", .enabled = false },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("/tmp/tray.png", harness.null_platform.lastTrayIconPath());
    try std.testing.expectEqualStrings("zero-native", harness.null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.trayItems().len);
    try std.testing.expectEqualStrings("Open", harness.null_platform.trayItems()[0].label);
    try std.testing.expect(harness.null_platform.trayItems()[1].separator);
    try std.testing.expect(!harness.null_platform.trayItems()[2].enabled);
    try harness.runtime.updateTrayMenu(&.{.{ .id = 3, .label = "Settings" }});
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.trayUpdateCount());
    try std.testing.expectEqualStrings("Settings", harness.null_platform.trayItems()[0].label);
    try harness.runtime.removeTray();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayRemoveCount());
}

test "runtime gates built-in OS bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "os-bridge", .source = platform.WebViewSource.html("<p>OS</p>") };

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"open\",\"command\":\"zero-native.os.openUrl\",\"payload\":{\"url\":\"https://example.com/docs\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "OS API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{ security.permission_network, security.permission_filesystem, security.permission_notifications };
    const network_permission = [_][]const u8{security.permission_network};
    const filesystem_permission = [_][]const u8{security.permission_filesystem};
    const notifications_permission = [_][]const u8{security.permission_notifications};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.os.openUrl", .permissions = &network_permission, .origins = &origins },
        .{ .name = "zero-native.os.showNotification", .permissions = &notifications_permission, .origins = &origins },
        .{ .name = "zero-native.os.revealPath", .permissions = &filesystem_permission, .origins = &origins },
        .{ .name = "zero-native.os.addRecentDocument", .permissions = &filesystem_permission, .origins = &origins },
        .{ .name = "zero-native.os.clearRecentDocuments", .permissions = &filesystem_permission, .origins = &origins },
    };
    const allowed_urls = [_][]const u8{"https://example.com/*"};

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.security.navigation.external_links = .{
        .action = .open_system_browser,
        .allowed_urls = &allowed_urls,
    };
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"notify\",\"command\":\"zero-native.os.showNotification\",\"payload\":{\"title\":\"Build finished\",\"subtitle\":\"zero-native\",\"body\":\"All checks passed.\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", allowed.null_platform.lastNotificationTitle());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"open\",\"command\":\"zero-native.os.openUrl\",\"payload\":{\"url\":\"https://example.com/docs\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("https://example.com/docs", allowed.null_platform.lastExternalUrl());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"reveal\",\"command\":\"zero-native.os.revealPath\",\"payload\":{\"path\":\"/tmp/zero-native-example.txt\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/zero-native-example.txt", allowed.null_platform.lastRevealedPath());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"recent\",\"command\":\"zero-native.os.addRecentDocument\",\"payload\":{\"path\":\"/tmp/recent-zero-native-example.txt\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/recent-zero-native-example.txt", allowed.null_platform.lastRecentDocumentPath());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"clear-recent\",\"command\":\"zero-native.os.clearRecentDocuments\",\"payload\":{}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.recentDocumentsClearedCount());
}

test "runtime gates built-in clipboard bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "clipboard-bridge", .source = platform.WebViewSource.html("<p>Clipboard</p>") };

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write\",\"command\":\"zero-native.clipboard.writeText\",\"payload\":{\"text\":\"plain text\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "Clipboard API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{security.permission_clipboard};
    const clipboard_permission = [_][]const u8{security.permission_clipboard};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.clipboard.readText", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.writeText", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.read", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.write", .permissions = &clipboard_permission, .origins = &origins },
    };

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write-text\",\"command\":\"zero-native.clipboard.writeText\",\"payload\":{\"text\":\"plain text\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("text/plain", allowed.null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("plain text", allowed.null_platform.lastClipboardData());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"read-text\",\"command\":\"zero-native.clipboard.readText\",\"payload\":{}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":\"plain text\"") != null);

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write-html\",\"command\":\"zero-native.clipboard.write\",\"payload\":{\"mimeType\":\"text/html\",\"data\":\"<strong>bold</strong>\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("text/html", allowed.null_platform.lastClipboardMimeType());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"read-html\",\"command\":\"zero-native.clipboard.read\",\"payload\":{\"mimeType\":\"text/html\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"mimeType\":\"text/html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"data\":\"<strong>bold</strong>\"") != null);
}

test "runtime gates built-in credential bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "credential-bridge", .source = platform.WebViewSource.html("<p>Credentials</p>") };

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"set\",\"command\":\"zero-native.credentials.set\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\",\"secret\":\"secret-token\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "Credentials API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{security.permission_credentials};
    const credential_permission = [_][]const u8{security.permission_credentials};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.credentials.set", .permissions = &credential_permission, .origins = &origins },
        .{ .name = "zero-native.credentials.get", .permissions = &credential_permission, .origins = &origins },
        .{ .name = "zero-native.credentials.delete", .permissions = &credential_permission, .origins = &origins },
    };

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"set\",\"command\":\"zero-native.credentials.set\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\",\"secret\":\"secret-token\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.credentialSetCount());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"get\",\"command\":\"zero-native.credentials.get\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":\"secret-token\"") != null);

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"delete\",\"command\":\"zero-native.credentials.delete\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.credentialDeleteCount());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"get-missing\",\"command\":\"zero-native.credentials.get\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":null") != null);
}

test "runtime builtin JSON field reader only reads top-level fields" {
    const payload =
        \\{"nested":{"label":"wrong"},"label":"palette \"one\"","width":320,"restoreState":false}
    ;
    var buffer: [128]u8 = undefined;
    var storage = json.StringStorage.init(&buffer);
    try std.testing.expectEqualStrings("palette \"one\"", jsonStringField(payload, "label", &storage).?);
    try std.testing.expectEqual(@as(f32, 320), jsonNumberField(payload, "width").?);
    try std.testing.expectEqual(false, jsonBoolField(payload, "restoreState").?);
}

test "runtime returns bridge permission errors through platform response service" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "bridge-denied", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":null}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}
