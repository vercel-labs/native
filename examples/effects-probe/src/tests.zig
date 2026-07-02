const std = @import("std");
const zero_native = @import("zero-native");
const main = @import("main.zig");

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const ProbeApp = zero_native.UiApp(Model, Msg);

const shell_views = [_]zero_native.ShellView{
    .{ .label = "probe-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "Effects Probe",
    .width = 560,
    .height = 480,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

fn probeOptions() ProbeApp.Options {
    return .{
        .name = "effects-probe",
        .scene = shell_scene,
        .canvas_label = "probe-canvas",
        .update_fx = main.update,
        .view = main.view,
    };
}

test "start captures the spawn request and streamed lines land in the list" {
    const harness = try zero_native.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(560, 480) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try testing.allocator.create(ProbeApp);
    defer testing.allocator.destroy(app_state);
    app_state.* = ProbeApp.init(std.heap.page_allocator, .{}, probeOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "probe-canvas",
        .size = geometry.SizeF.init(560, 480),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });

    // Start records the request (the fake executor runs nothing).
    try app_state.dispatch(&harness.runtime, 1, .start);
    try testing.expect(app_state.model.streaming);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingSpawnCount());
    const request = app_state.effects.pendingSpawnAt(0).?;
    try testing.expectEqual(main.stream_key, request.key);
    try testing.expectEqualStrings("/bin/sh", request.argv[0]);
    try testing.expectEqualStrings("-c", request.argv[1]);

    // Synthetic lines drain into the model through the wake path.
    try app_state.effects.feedLine(main.stream_key, "stream line 1");
    try app_state.effects.feedLine(main.stream_key, "stream line 2");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try testing.expectEqual(@as(u64, 2), app_state.model.total_lines);
    try testing.expectEqualStrings("stream line 2", app_state.model.lineAt(1));

    // The synthetic exit lands and stops the stream state.
    try app_state.effects.feedExit(main.stream_key, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try testing.expect(!app_state.model.streaming);
    try testing.expectEqual(zero_native.EffectExitReason.exited, app_state.model.last_exit.?.reason);
}

test "cancel stops the stream: queued lines are discarded, exit reports cancelled" {
    const harness = try zero_native.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(560, 480) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try testing.allocator.create(ProbeApp);
    defer testing.allocator.destroy(app_state);
    app_state.* = ProbeApp.init(std.heap.page_allocator, .{}, probeOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "probe-canvas",
        .size = geometry.SizeF.init(560, 480),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });

    try app_state.dispatch(&harness.runtime, 1, .start);
    try app_state.effects.feedLine(main.stream_key, "queued but never shown");
    try app_state.dispatch(&harness.runtime, 1, .cancel);
    try harness.runtime.dispatchPlatformEvent(app, .wake);

    try testing.expectEqual(@as(u64, 0), app_state.model.total_lines);
    try testing.expect(!app_state.model.streaming);
    try testing.expectEqual(zero_native.EffectExitReason.cancelled, app_state.model.last_exit.?.reason);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingSpawnCount());
}

test "the probe view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.streaming = true;
    var ui = main.ProbeUi.init(arena);
    const tree = try ui.finalize(main.view(&ui, &model));

    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 560, 480), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const cancel = findByText(tree.root, .button, "Cancel").?;
    try testing.expect(!cancel.state.disabled);
    const start = findByText(tree.root, .button, "Start stream").?;
    try testing.expect(start.state.disabled);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}
