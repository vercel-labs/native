const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("canvas_preview_core");
const decoder = @import("canvas_preview_decoder");
const main = @import("canvas_preview_reference.zig");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const Adapter = native_sdk.TsUiApp(core);
const PreviewApp = Adapter.App;

const preview_origins = [_][]const u8{ "zero://inline", "zero://app", "https://example.com", "https://native-sdk.dev" };

fn createApp() !*PreviewApp {
    return Adapter.create(testing.allocator, .{}, .{
        .name = "canvas-preview",
        .scene = main.shell_scene,
        .canvas_label = main.canvas_label,
        .view = decoder.build,
        .on_command = core.commandMsg,
    });
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

fn equal(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    // Callback implementation addresses differ between compiled policies
    // and their native reference. Compare all widget data; the complete
    // driver snapshots and replay exercise the callback behavior.
    if (comptime @typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (comptime @typeInfo(Child) == .pointer and @typeInfo(@typeInfo(Child).pointer.child) == .@"fn") return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "compiled_scroll_policy")) continue;
            try equal(@field(expected, field.name), @field(actual, field.name));
        },
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try equal(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |a, b| try equal(a, b);
        } else try std.testing.expectEqual(expected, actual),
        .array => for (expected, actual) |a, b| try equal(a, b),
        .@"union" => |info| if (info.tag_type != null) {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) {
                inline else => |value, tag| try equal(value, @field(actual, @tagName(tag))),
            }
        } else @compileError("untagged parity value"),
        else => try std.testing.expectEqual(expected, actual),
    }
}

fn compare(native: *const main.Model, model: *const core.Model) !void {
    try testing.expectEqualStrings(@tagName(native.page), @tagName(model.page));
    try testing.expectEqual(@as(f64, @floatFromInt(native.reload_token)), model.reload_token);
    try testing.expectEqual(@as(i64, native.reload_count), model.reload_count);
    try testing.expectEqual(native.gpu_frames_seen, model.gpu_frames_seen);
}
fn viewParity(native: *const main.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = main.PreviewUi.init(arena.allocator());
    const expected = try a.finalize(main.view(&a, native));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const root = if (backend == 0) View.build(&b, model) else decoder.build(&b, model);
        core.rt.frameReset();
        const actual = try b.finalize(root);
        try equal(expected.root, actual.root);
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |old, new| {
            try testing.expectEqual(old.id, new.id);
            try testing.expectEqualStrings(@tagName(expected.msgForPointer(old.id, .up).?), @tagName(actual.msgForPointer(new.id, .up).?));
        }
        var left: [64]canvas.WidgetLayoutNode = undefined;
        var right: [64]canvas.WidgetLayoutNode = undefined;
        for ([_]geometry.RectF{ .init(0, 0, 960, 640), .init(0, 0, 1200, 800), .init(0, 0, 720, 520) }) |frame| {
            try equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
        }
    }
}
test "compiled Canvas Preview preserves full model, widget records, handlers and layout" {
    var native = main.Model{};
    var model = core.initialModel();
    defer core.rt.frameReset();
    try compare(&native, model);
    try viewParity(&native, model);
    for (0..48) |i| {
        const action: main.Msg = switch (i % 4) {
            0 => .show_docs,
            1 => .reload,
            2 => .show_example,
            else => .frame_presented,
        };
        main.update(&native, action);
        const msg: core.Msg = switch (action) {
            .show_docs => .show_docs,
            .reload => .reload,
            .show_example => .show_example,
            .frame_presented => .frame_presented,
        };
        model = core.update(model, msg);
        try compare(&native, model);
        try viewParity(&native, model);
    }
}
test "compiled model pane bytes and tray records survive result reset and unrelated calls" {
    const app_state = try createApp();
    defer app_state.destroy();
    var panes: [4]PreviewApp.WebViewPane = undefined;
    try testing.expectEqual(@as(usize, 1), app_state.options.web_panes.?(&app_state.model, &panes));
    core.rt.frameReset();
    const saved = panes[0];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = app_state.model.statusItem(arena.allocator());
    var buffer: [4]u8 = undefined;
    for (0..16) |_| {
        _ = core.nativeThemePolicy(&.{ 0, '#', 'd', 'f', '2', '6', '7', '0' }, &buffer);
        core.rt.frameReset();
        try testing.expectEqualStrings("preview", saved.label);
        try testing.expectEqualStrings("preview-pane", saved.anchor.?);
        try testing.expectEqualStrings(main.example_url, saved.url);
        try testing.expectEqual(@as(u64, 0), saved.reload_token);
    }
    try testing.expectEqual(@as(usize, 0), app_state.options.web_panes.?(&app_state.model, panes[0..0]));
}
test "compiled pane and tray reconciliation retains native navigation counts, resizing and frame ownership" {
    const app_state = try createApp();
    defer app_state.destroy();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const first = try previewWebView(harness);
    const count = harness.null_platform.webview_navigate_count;
    try testing.expectEqualStrings(main.example_url, first.url);
    // The installing frame intentionally skips on_frame; the next live
    // presentation delivers the ordinary journaled frame channel.
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{ .label = main.canvas_label, .size = .init(960, 640), .scale_factor = 1, .frame_index = 2, .timestamp_ns = 2_000_000, .nonblank = true } });
    try testing.expect(app_state.model.gpu_frames_seen);
    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqualStrings("NS", harness.null_platform.lastTrayTitle());
    try testing.expectEqualDeep(@as([]const native_sdk.TrayMenuItem, &main.status_items), harness.null_platform.trayItems());
    core.rt.frameReset();
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .menu_command = .{ .name = main.docs_command, .window_id = 1 } });
    try testing.expectEqualStrings(main.docs_url, (try previewWebView(harness)).url);
    try testing.expectEqual(count + 1, harness.null_platform.webview_navigate_count);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = .{ .item_id = 3 } });
    try testing.expectEqual(@as(i64, 1), app_state.model.reload_count);
    try testing.expectEqual(count + 2, harness.null_platform.webview_navigate_count);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = .{ .item_id = 1 } });
    try testing.expectEqualStrings(main.example_url, (try previewWebView(harness)).url);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .menu_command = .{ .name = "unknown", .window_id = 1 } });
    try testing.expectEqual(count + 3, harness.null_platform.webview_navigate_count);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_resized = .{ .label = main.canvas_label, .window_id = 1, .frame = .init(0, 0, 1200, 800), .scale_factor = 1 } });
    const resized = try previewWebView(harness);
    try testing.expect(resized.frame.width > first.frame.width);
    try testing.expect(resized.frame.height > first.frame.height);
    const layout = try harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    for (layout.nodes) |node| if (std.mem.eql(u8, node.widget.semantics.label, main.pane_anchor)) {
        try testing.expectEqualDeep(node.frame, resized.frame);
    };
}
test {
    _ = @import("canvas_preview_reference_tests.zig");
}
