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

test "runtime rejects canvas display lists on non-GPU views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-canvas-reject", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{
        .id = 1,
        .size = geometry.SizeF.init(390, 844),
        .scale_factor = 3,
        .safe_area_insets = geometry.InsetsF.init(47, 0, 34, 0),
    });
    defer harness.destroy(std.testing.allocator);
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

test "shell window resizable reaches the platform create seam" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-resizable", .source = platform.WebViewSource.html("<h1>Host</h1>") };
        }
    };

    // The bug this locks down: app.zon said `resizable = false`, the runtime carried
    // it, and the macOS host dropped it at the C ABI (hardcoded
    // NSWindowStyleMaskResizable). Lock the runtime-to-platform half:
    // the created window's options arrive with the flag intact.
    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
    };
    const fixed_window: app_manifest.ShellWindow = .{
        .label = "fixed",
        .title = "Fixed",
        .width = 320,
        .height = 480,
        .resizable = false,
        .views = &shell_views,
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const window = try harness.runtime.createShellWindow(fixed_window, platform.WebViewSource.html("<h1>Fixed</h1>"));
    var window_index: usize = 0;
    var found = false;
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == window.id) {
            window_index = index;
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(!harness.null_platform.window_resizable[window_index]);

    // The default stays resizable.
    const open_window: app_manifest.ShellWindow = .{
        .label = "open",
        .title = "Open",
        .width = 640,
        .height = 480,
        .views = &shell_views,
    };
    const second = try harness.runtime.createShellWindow(open_window, platform.WebViewSource.html("<h1>Open</h1>"));
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == second.id) {
            try std.testing.expect(harness.null_platform.window_resizable[index]);
        }
    }
}

test "shell window titlebar style reaches the platform create seam" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-titlebar", .source = platform.WebViewSource.html("<h1>Host</h1>") };
        }
    };

    // Same seam discipline as `resizable`: chrome is fixed at create
    // time, so the created window's options must arrive with the
    // declared titlebar style intact.
    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
    };
    const inset_window: app_manifest.ShellWindow = .{
        .label = "inset",
        .title = "Inset",
        .width = 640,
        .height = 480,
        .titlebar = .hidden_inset,
        .views = &shell_views,
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const window = try harness.runtime.createShellWindow(inset_window, platform.WebViewSource.html("<h1>Inset</h1>"));
    var found = false;
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == window.id) {
            found = true;
            try std.testing.expectEqual(platform.WindowTitlebarStyle.hidden_inset, harness.null_platform.window_titlebar[index]);
        }
    }
    try std.testing.expect(found);

    // The tall variant rides the same seam.
    const tall_window: app_manifest.ShellWindow = .{
        .label = "tall",
        .title = "Tall",
        .width = 640,
        .height = 480,
        .titlebar = .hidden_inset_tall,
        .views = &shell_views,
    };
    const tall = try harness.runtime.createShellWindow(tall_window, platform.WebViewSource.html("<h1>Tall</h1>"));
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == tall.id) {
            try std.testing.expectEqual(platform.WindowTitlebarStyle.hidden_inset_tall, harness.null_platform.window_titlebar[index]);
        }
    }

    // The chromeless opt-in (fully-skinned apps: no titlebar band, no
    // system buttons) rides the same seam.
    const chromeless_window: app_manifest.ShellWindow = .{
        .label = "chromeless",
        .title = "Chromeless",
        .width = 640,
        .height = 480,
        .titlebar = .chromeless,
        .views = &shell_views,
    };
    const chromeless = try harness.runtime.createShellWindow(chromeless_window, platform.WebViewSource.html("<h1>Chromeless</h1>"));
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == chromeless.id) {
            try std.testing.expectEqual(platform.WindowTitlebarStyle.chromeless, harness.null_platform.window_titlebar[index]);
        }
    }

    // The default stays standard chrome.
    const standard_window: app_manifest.ShellWindow = .{
        .label = "standard",
        .title = "Standard",
        .width = 640,
        .height = 480,
        .views = &shell_views,
    };
    const second = try harness.runtime.createShellWindow(standard_window, platform.WebViewSource.html("<h1>Standard</h1>"));
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, index| {
        if (info.id == second.id) {
            try std.testing.expectEqual(platform.WindowTitlebarStyle.standard, harness.null_platform.window_titlebar[index]);
        }
    }
}

test "canvas shell windows present before they become visible" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "present-before-show", .source = platform.WebViewSource.html("<h1>Host</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    // A canvas window (any gpu_surface view) is created ORDERED OUT:
    // the runtime derives `.show = .on_first_present` from its views.
    const canvas_views = [_]app_manifest.ShellView{
        .{ .label = "settings-canvas", .kind = .gpu_surface, .fill = true },
    };
    const canvas_window: app_manifest.ShellWindow = .{
        .label = "settings",
        .title = "Settings",
        .width = 480,
        .height = 360,
        .views = &canvas_views,
    };
    const window = try harness.runtime.createShellWindow(canvas_window, null);
    const index = for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, i| {
        if (info.id == window.id) break i;
    } else return error.WindowNotFound;
    try std.testing.expectEqual(platform.WindowShowMode.on_first_present, harness.null_platform.window_show[index]);
    try std.testing.expect(!harness.null_platform.window_visible[index]);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_shown_seq[index]);

    // The first canvas present makes it visible — present strictly
    // BEFORE the visibility flip (the ordering contract).
    try harness.runtime.options.platform.services.presentGpuSurfacePacket(.{
        .window_id = window.id,
        .label = "settings-canvas",
        .surface_size = geometry.SizeF.init(480, 360),
        .json = "{\"v\":1}",
    });
    try std.testing.expect(harness.null_platform.window_visible[index]);
    try std.testing.expect(harness.null_platform.window_first_present_seq[index] != 0);
    try std.testing.expect(harness.null_platform.window_first_present_seq[index] < harness.null_platform.window_shown_seq[index]);

    // A webview shell window keeps immediate visibility: its engine
    // owns first paint.
    const webview_views = [_]app_manifest.ShellView{
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
    };
    const webview_window: app_manifest.ShellWindow = .{
        .label = "docs",
        .title = "Docs",
        .width = 640,
        .height = 480,
        .views = &webview_views,
    };
    const second = try harness.runtime.createShellWindow(webview_window, platform.WebViewSource.html("<h1>Docs</h1>"));
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |info, i| {
        if (info.id == second.id) {
            try std.testing.expectEqual(platform.WindowShowMode.immediate, harness.null_platform.window_show[i]);
            try std.testing.expect(harness.null_platform.window_visible[i]);
        }
    }
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
    const runtime = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(runtime);
    Runtime.initAt(runtime, .{ .platform = host.platformValue() });
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
    Runtime.initAt(runtime, .{ .platform = null_platform.platform() });
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(900, 600) });
    defer harness.destroy(std.testing.allocator);
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

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
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
