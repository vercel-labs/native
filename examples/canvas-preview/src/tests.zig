const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const PreviewApp = native_sdk.UiApp(Model, Msg);

const preview_origins = [_][]const u8{ "zero://inline", "zero://app", "https://example.com", "https://native-sdk.dev" };

fn createApp() !*PreviewApp {
    const app_state = try testing.allocator.create(PreviewApp);
    app_state.* = PreviewApp.init(std.heap.page_allocator, .{}, main.options());
    return app_state;
}

fn startedHarness(app_state: *PreviewApp) !*native_sdk.TestHarness() {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(960, 640) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &preview_origins;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(960, 640),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

fn previewWebView(harness: *native_sdk.TestHarness()) !native_sdk.platform.ViewInfo {
    var views_buffer: [8]native_sdk.platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    for (views) |view| {
        if (std.mem.eql(u8, view.label, main.webview_label)) return view;
    }
    return error.TestUnexpectedResult;
}

test "the scene hosts a canvas and a webview in one window, with no implicit main webview" {
    try testing.expectEqual(@as(usize, 2), main.shell_views.len);
    try testing.expect(main.shell_views[0].kind == .gpu_surface);
    try testing.expect(main.shell_views[1].kind == .webview);

    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    // Both architectures live in window 1 — and the canvas-first scene
    // never grows an implicit full-window main webview behind the canvas.
    try testing.expect(harness.runtime.loaded_source == null);
    var views_buffer: [8]native_sdk.platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try testing.expectEqual(@as(usize, 2), views.len);
    var saw_canvas = false;
    var saw_webview = false;
    for (views) |view| {
        if (view.kind == .gpu_surface and std.mem.eql(u8, view.label, main.canvas_label)) saw_canvas = true;
        if (view.kind == .webview and std.mem.eql(u8, view.label, main.webview_label)) saw_webview = true;
        try testing.expect(!std.mem.eql(u8, view.label, "main"));
    }
    try testing.expect(saw_canvas);
    try testing.expect(saw_webview);
}

test "the webview pane tracks the anchor widget frame through install and resize" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    const layout = try harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var anchor_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, main.pane_anchor)) anchor_frame = node.frame;
    }
    try testing.expect(anchor_frame != null);

    const webview = try previewWebView(harness);
    try testing.expectApproxEqAbs(anchor_frame.?.x, webview.frame.x, 0.5);
    try testing.expectApproxEqAbs(anchor_frame.?.y, webview.frame.y, 0.5);
    try testing.expectApproxEqAbs(anchor_frame.?.width, webview.frame.width, 0.5);
    try testing.expectApproxEqAbs(anchor_frame.?.height, webview.frame.height, 0.5);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_resized = .{
        .label = main.canvas_label,
        .window_id = 1,
        .frame = geometry.RectF.init(0, 0, 1200, 800),
        .scale_factor = 1,
    } });
    const resized = try previewWebView(harness);
    try testing.expect(resized.frame.width > webview.frame.width);
    try testing.expect(resized.frame.height > webview.frame.height);
}

test "toolbar and status-item commands navigate and reload the webview" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    try testing.expectEqualStrings(main.example_url, (try previewWebView(harness)).url);
    const navigations_after_install = harness.null_platform.webview_navigate_count;

    // Docs via the command path (toolbar button / menu / status item all
    // dispatch the same command names).
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .menu_command = .{ .name = main.docs_command, .window_id = 1 } });
    try testing.expect(app_state.model.page == .docs);
    try testing.expectEqualStrings(main.docs_url, (try previewWebView(harness)).url);
    try testing.expectEqual(navigations_after_install + 1, harness.null_platform.webview_navigate_count);

    // The menu-bar extra is installed with the declared items; selecting
    // "Reload Preview" (id 3) renavigates the current URL.
    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqualStrings("NS", harness.null_platform.lastTrayTitle());
    try testing.expectEqual(@as(usize, main.status_items.len), harness.null_platform.trayItems().len);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = .{ .item_id = 3 } });
    try testing.expectEqual(@as(u32, 1), app_state.model.reload_count);
    try testing.expectEqualStrings(main.docs_url, (try previewWebView(harness)).url);
    try testing.expectEqual(navigations_after_install + 2, harness.null_platform.webview_navigate_count);
}

test "the view lays out through the canvas engine with the pane anchor mounted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .page = .docs };
    var ui = main.PreviewUi.init(arena);
    const tree = try ui.finalize(main.view(&ui, &model));

    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 960, 640), &nodes);
    var anchor_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, main.pane_anchor)) anchor_frame = node.frame;
    }
    try testing.expect(anchor_frame != null);
    try testing.expect(anchor_frame.?.width > 400);
    try testing.expect(anchor_frame.?.height > 400);
    try testing.expect(anchor_frame.?.x >= 224);
}
