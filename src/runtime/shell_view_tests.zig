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

test "runtime loads app source into platform webview" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "test", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

test "runtime validates native-surface adoption before reaching the platform" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "surface-adoption", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    var fake_surface: u32 = 0;
    const handle: *anyopaque = @ptrCast(&fake_surface);

    // Unknown containers and webview-backed labels reject before any
    // platform call; only a real native view reaches the service seam,
    // where the null platform reports the capability honestly missing.
    try std.testing.expectError(error.ViewNotFound, harness.runtime.adoptViewSurface(1, "missing", handle));
    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.adoptViewSurface(1, "main", handle));
    try std.testing.expectError(error.ViewNotFound, harness.runtime.releaseViewSurface(1, "missing"));

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "guest-display",
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 640, 480),
    });
    try std.testing.expect(!harness.runtime.supports(.view_surface_adoption));
    try std.testing.expectError(error.UnsupportedService, harness.runtime.adoptViewSurface(1, "guest-display", handle));
    try std.testing.expectError(error.UnsupportedService, harness.runtime.releaseViewSurface(1, "guest-display"));
}

test "runtime rejects invalid native view parents" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-view-parents", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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
