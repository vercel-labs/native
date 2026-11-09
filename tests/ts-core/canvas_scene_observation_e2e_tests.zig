const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const p = sdk.runtime.testing.scene_observation_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const huge: u64 = 9007199254740993;
const max = std.math.maxInt(u64);
var calls: [7]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 76) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
var context: u8 = 0;
fn harness() !*sdk.runtime.TestHarness() {
    const h = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    errdefer h.destroy(std.testing.allocator);
    h.null_platform.gpu_surfaces = true;
    try h.start(.{ .context = &context, .name = "scene-observation-parity", .source = sdk.platform.WebViewSource.html("") });
    _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(100, 50, 160, 120) });
    return h;
}
fn command(id: u64, x: f32) c.CanvasCommand {
    return .{ .fill_rect = .{ .id = id, .rect = .init(x, 2.25, 8.5, 7), .fill = .{ .color = .rgb8(20, 30, 40) } } };
}
const sentinel = c.DiffChange{ .kind = .scene_changed, .id = max, .previous_index = 777, .next_index = 888, .dirty_bounds = .init(-0.0, -3, 4, 5) };
fn compareDiff(view: anytype, capacity: usize) !void {
    var expected: [16]c.DiffChange = @splat(sentinel);
    var actual = expected;
    const left = view.diffPresentedCanvasSummary(expected[0..capacity]);
    const right = view.diffPresentedCanvasSummaryWithPolicy(actual[0..capacity], observed);
    if (left) |changes| {
        const got = try right;
        try exact(changes.len, got.len);
    } else |err| try std.testing.expectError(err, right);
    try exact(expected, actual);
    core.rt.frameReset();
    try exact(expected, actual);
}
test "compiled scene observation preserves complete summary diffs duplicate first matches and output overflow" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    const view = &h.runtime.views[0];
    const ids = [_]u64{ 0, 1, 7, 0xffffffff, 0x100000000, huge, max };
    var cases: usize = 0;
    for (ids) |before| for (ids) |after| for (0..5) |variant| {
        const commands = [_]c.CanvasCommand{ command(after, 10.25), command(after, -2), .pop_clip, command(9, 20) };
        view.canvas_revision = 0;
        try view.copyCanvasDisplayList(.{ .commands = &commands });
        view.presented_canvas_command_count = 4;
        view.presented_canvas_commands[0] = .{ .id = if (before == 0) null else before, .bounds = .init(1, 2, -4, 6) };
        view.presented_canvas_commands[1] = .{ .id = 8, .bounds = null };
        view.presented_canvas_commands[2] = .{ .id = if (before == 0) null else before, .bounds = .init(100, 200, 4, 6) };
        view.presented_canvas_commands[3] = .{ .bounds = .init(-0.0, 2, 3, 4) };
        view.canvas_revision = if (variant == 1) huge else max;
        view.presented_canvas_revision = if (variant == 0) view.canvas_revision else view.canvas_revision -% 1;
        for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 16 }) |capacity| {
            try compareDiff(view, capacity);
            cases += 1;
        }
    };
    std.debug.print("Complete scene diff programs: {d}\n", .{cases});
}
var measurements: usize = 0;
var measurement_calls: [64]usize = @splat(0);
var reenter_observation = false;
fn measure(_: ?*anyopaque, _: c.FontId, _: f32, text: []const u8) f32 {
    if (reenter_observation) {
        const summary = [_]struct { id: ?u64 = null, bounds: ?sdk.geometry.RectF = null }{.{}};
        std.debug.assert(!p.summaryHasUnkeyed(&summary, observed));
    }
    measurement_calls[measurements] = text.len;
    measurements += 1;
    return @floatFromInt(measurements);
}
fn resetMeasurements() void {
    measurements = 0;
    @memset(&measurement_calls, 0);
}
test "compiled scene observation preserves lazy native bounds order including the overflowing action" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    reenter_observation = true;
    defer reenter_observation = false;
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    const view = &h.runtime.views[0];
    const provider = c.TextMeasureProvider{ .measure_fn = measure };
    const commands = [_]c.CanvasCommand{
        .{ .draw_text = .{ .id = huge, .size = 12, .color = .rgb8(10, 20, 30), .origin = .init(0, 20), .text = "first", .measure = &provider } },
        .{ .draw_text = .{ .id = huge, .size = 12, .color = .rgb8(10, 20, 30), .origin = .init(50, 20), .text = "second duplicate", .measure = &provider } },
        .pop_clip,
        .{ .draw_text = .{ .id = 0, .size = 12, .color = .rgb8(10, 20, 30), .origin = .init(70, 20), .text = "unkeyed", .measure = &provider } },
    };
    try view.copyCanvasDisplayList(.{ .commands = &commands });
    view.canvas_revision = huge;
    view.presented_canvas_revision = huge - 1;
    view.presented_canvas_command_count = 1;
    view.presented_canvas_commands[0] = .{ .id = huge, .bounds = .init(1, 2, 3, 4) };
    for (0..4) |capacity| {
        var expected: [4]c.DiffChange = @splat(sentinel);
        var actual = expected;
        resetMeasurements();
        const left = view.diffPresentedCanvasSummary(expected[0..capacity]);
        const count = measurements;
        const trace = measurement_calls;
        resetMeasurements();
        const borrowed = core.rt.frameAlloc(u8, 8);
        @memcpy(borrowed, "scene\x00ab");
        const right = view.diffPresentedCanvasSummaryWithPolicy(actual[0..capacity], observed);
        if (left) |value| try exact(value.len, (try right).len) else |err| try std.testing.expectError(err, right);
        try exact(expected, actual);
        try exact(count, measurements);
        try exact(trace, measurement_calls);
        try std.testing.expectEqualSlices(u8, "scene\x00ab", borrowed);
        core.rt.frameReset();
    }
    resetMeasurements();
    const unkeyed = view.currentCanvasHasUnkeyed();
    const count = measurements;
    const trace = measurement_calls;
    resetMeasurements();
    try exact(unkeyed, view.currentCanvasHasUnkeyedWithPolicy(observed));
    try exact(count, measurements);
    try exact(trace, measurement_calls);
    try std.testing.expect(unkeyed);
}
test "compiled scene observation copies complete presented summary and unkeyed state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const left = try harness();
    defer left.destroy(std.testing.allocator);
    const right = try harness();
    defer right.destroy(std.testing.allocator);
    for (0..8) |variant| {
        const commands = [_]c.CanvasCommand{ command(if (variant & 1 != 0) 0 else huge, 4), .pop_clip, command(if (variant & 2 != 0) 0 else 1, 20) };
        left.runtime.views[0].canvas_revision = max - variant;
        right.runtime.views[0].canvas_revision = max - variant;
        try left.runtime.views[0].copyPresentedCanvasSummary(.{ .commands = &commands }, .init(64.25, 48.5), 1.75);
        try right.runtime.views[0].copyPresentedCanvasSummaryWithPolicy(.{ .commands = &commands }, .init(64.25, 48.5), 1.75, observed);
        const a = &left.runtime.views[0];
        const b = &right.runtime.views[0];
        try exact(a.presented_canvas_commands[0..a.presented_canvas_command_count], b.presented_canvas_commands[0..b.presented_canvas_command_count]);
        inline for (.{ "presented_canvas_valid", "presented_canvas_surface_size", "presented_canvas_scale", "presented_canvas_revision", "presented_canvas_has_unkeyed", "presented_canvas_command_count" }) |field| try exact(@field(a, field), @field(b, field));
        core.rt.frameReset();
        try exact(a.presented_canvas_commands[0..a.presented_canvas_command_count], b.presented_canvas_commands[0..b.presented_canvas_command_count]);
    }
}
test "compiled scene observation preserves exact dirty projection union and float32 presentation colors" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]f32{ -100, -8.25, -0.0, 0, 0.001, 1, 1.75, 63.25, 1024, 1.0e30, -std.math.inf(f32), std.math.inf(f32), std.math.nan(f32) };
    var count: usize = 0;
    for (values) |x| for (values) |width| for (values) |dirty_width| {
        const view = sdk.geometry.RectF.init(x, -13.25, width, 48.5);
        const dirty = sdk.geometry.RectF.init(-2.25, 3.5, dirty_width, 9.25);
        try exact(sdk.runtime.testing.referenceSceneDirtyProjection(view, dirty), p.projectDirty(view, dirty, observed));
        try exact(sdk.geometry.RectF.unionWith(view.normalized(), dirty.normalized()), p.unionBounds(view, dirty, observed).?);
        try exact(view.normalized(), p.unionBounds(view, null, observed).?);
        count += 3;
        core.rt.frameReset();
    };
    const channels = [_]f32{ -std.math.inf(f32), -1, -0.0, 0, 0.001, 0.49999997, 0.5, 0.50000006, 0.99999994, 1, 2, std.math.inf(f32), std.math.nan(f32) };
    for (channels) |red| for (channels) |green| {
        const color = c.Color.rgba(red, green, 0.25, 1);
        try exact(sdk.runtime.testing.referenceSceneColor(color), p.colorRgba8(color, observed));
        core.rt.frameReset();
    };
    try exact(sdk.runtime.testing.referenceSceneBlurExtent("macos"), p.blurExtent(true, observed));
    for ([_][]const u8{ "null", "linux", "windows", "MACOS", "macos\x00" }) |name| try exact(sdk.runtime.testing.referenceSceneBlurExtent(name), p.blurExtent(false, observed));
    std.debug.print("Complete scene bounds programs: {d}; complete color programs: {d}\n", .{ count, channels.len * channels.len });
}

test "compiled scene observation bounds complete transport results and all reserved fields" {
    var result: [80]u8 = @splat(0);
    std.mem.writeInt(u32, result[0..4], 1, .little);
    for (0..7) |mode| {
        const m: u8 = @intCast(mode);
        try std.testing.expect(p.resultValid(result[0..64], m));
        for (0..64) |length| try std.testing.expect(!p.resultValid(result[0..length], m));
        for (32..64) |at| {
            var bad = result;
            bad[at] = 1;
            try std.testing.expect(!p.resultValid(bad[0..64], m));
        }
        var bad = result;
        std.mem.writeInt(u32, bad[4..8], 0xffffffff, .little);
        try std.testing.expect(!p.resultValid(bad[0..64], m));
    }
    std.mem.writeInt(u32, result[4..8], 1, .little);
    try std.testing.expect(p.resultValid(&result, 0));
    result[76] = 1;
    try std.testing.expect(!p.resultValid(&result, 0));
}
