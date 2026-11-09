const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const policy = sdk.runtime.testing.render_animation_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const huge: u64 = 9007199254740993;
const max = std.math.maxInt(u64);
const Animation = canvas.CanvasRenderAnimation;
const Override = canvas.CanvasRenderOverride;

var context: u8 = 0;
fn harness(owner: ?policy.Policy) !*sdk.runtime.TestHarness() {
    const h = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    errdefer h.destroy(std.testing.allocator);
    try h.start(.{ .context = &context, .name = "animation-parity", .source = sdk.platform.WebViewSource.html(""), .render_override_policy = owner });
    h.null_platform.gpu_surfaces = true;
    _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
    return h;
}
fn viewEqual(a: anytype, b: @TypeOf(a)) !void {
    try exact(a.canvas_render_animations, b.canvas_render_animations);
    try exact(a.canvas_render_animation_count, b.canvas_render_animation_count);
    try exact(a.canvas_render_animation_dirty_bounds, b.canvas_render_animation_dirty_bounds);
    try exact(a.canvas_render_animation_dirty_bounds_count, b.canvas_render_animation_dirty_bounds_count);
    try exact(a.canvas_frame_render_overrides, b.canvas_frame_render_overrides);
    try exact(a.canvas_frame_render_override_count, b.canvas_frame_render_override_count);
}
fn seed(view: anytype, animations: []const Animation, overrides: []const Override) void {
    @memset(&view.canvas_render_animations, .{ .id = 93, .duration_ms = 42, .to_opacity = 0.123 });
    @memcpy(view.canvas_render_animations[0..animations.len], animations);
    view.canvas_render_animation_count = animations.len;
    @memset(&view.canvas_frame_render_overrides, .{ .id = 94, .opacity = 0.321, .transform = .translate(7, 8) });
    @memcpy(view.canvas_frame_render_overrides[0..overrides.len], overrides);
    view.canvas_frame_render_override_count = overrides.len;
    @memset(&view.canvas_render_animation_dirty_bounds, .{ .id = 95, .bounds = .init(7, 8, 9, 10) });
    for (animations, 0..) |animation, i| view.canvas_render_animation_dirty_bounds[i] = .{ .id = animation.id, .bounds = if (i % 2 == 0) .init(1, 2, -3, 4) else null };
    view.canvas_render_animation_dirty_bounds_count = animations.len;
}
fn finishParity(a: anytype, b: @TypeOf(a), animations: []const Animation, overrides: []const Override, now: u64) !void {
    seed(a, animations, overrides);
    seed(b, animations, overrides);
    if (a.pruneCompletedNoopCanvasRenderAnimations(now)) a.compactCanvasFrameRenderOverrideNoops();
    try exact(a.canvasRenderAnimationsActive(now), policy.finishFrame(b, now, core.nativeWindowPolicy));
    try viewEqual(a, b);
    core.rt.frameReset();
}
test "compiled render animation retirement preserves full storage exact timestamps duplicates and cleanup" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const a = try harness(null);
    defer a.destroy(std.testing.allocator);
    const b = try harness(null);
    defer b.destroy(std.testing.allocator);
    const ends = [_]?f32{ null, -0.0, 0.5, 1, std.math.nan(f32), std.math.inf(f32) };
    const clocks = [_]u64{ 0, 4294967295, huge, max - 1_000_000, max };
    const durations = [_]u32{ 0, 1, 500, std.math.maxInt(u32) };
    const overrides = [_]Override{ .{ .id = huge }, .{ .id = huge, .opacity = 1 }, .{ .id = 0, .opacity = -0.0 }, .{ .id = max, .transform = .{} }, .{ .id = max, .transform = .translate(0.1, 0) }, .{ .id = 2, .opacity = std.math.nan(f32) } };
    for (clocks) |start| for (durations) |duration| {
        var animations: [54]Animation = undefined;
        var count: usize = 0;
        for ([_]u64{ 0, huge, max }) |id| for ([_]canvas.CanvasRenderAnimationLoop{ .none, .ping_pong, .wrap }) |loop| for (ends) |end| {
            animations[count] = .{ .id = id, .start_ns = start, .duration_ms = duration, .loop = loop, .to_opacity = end };
            count += 1;
        };
        const span = @as(u64, duration) * 1_000_000;
        for ([_]u64{ 0, start, start -| 1, start +| 1, (start +| span) -| 1, start +| span, max }) |now| {
            try finishParity(&a.runtime.views[0], &b.runtime.views[0], &animations, &overrides, now);
        }
    };
    var transforms = [_]Animation{ .{ .id = huge, .from_transform = .translate(7, 8), .to_transform = .{} }, .{ .id = huge, .to_transform = .translate(-0.0, -0.0), .from_rotation = 0, .to_rotation = 270 }, .{ .id = huge, .to_transform = .translate(0.00001, 0) }, .{ .id = max, .to_transform = .{ .a = std.math.nan(f32) } } };
    try finishParity(&a.runtime.views[0], &b.runtime.views[0], &transforms, &overrides, max);
    for (&transforms) |*animation| animation.loop = .wrap;
    try finishParity(&a.runtime.views[0], &b.runtime.views[0], &transforms, &overrides, max);
}
test "compiled render animation admission preserves exact capacity precedence and inert replacements" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]usize{ 0, 1, 2, 2048 }) |capacity| {
        const good = [_]Animation{ .{ .id = huge }, .{ .id = huge }, .{ .id = max } };
        const bad = [_]Animation{.{ .id = 0 }};
        if (capacity < good.len) try std.testing.expectError(error.RenderAnimationListFull, policy.admit(&good, 0, 0, capacity, core.nativeWindowPolicy)) else try std.testing.expect(!try policy.admit(&good, 0, 0, capacity, core.nativeWindowPolicy));
        try std.testing.expectError(if (capacity == 0) error.RenderAnimationListFull else error.InvalidViewOptions, policy.admit(&bad, 0, 0, capacity, core.nativeWindowPolicy));
        try std.testing.expect(try policy.admit(&.{}, 0, 0, capacity, core.nativeWindowPolicy));
        try std.testing.expect(!try policy.admit(&.{}, 1, 0, capacity, core.nativeWindowPolicy));
        try std.testing.expect(!try policy.admit(&.{}, 0, 1, capacity, core.nativeWindowPolicy));
        core.rt.frameReset();
    }
}
fn dirtyParity(view: anytype, animations: []const Animation) !void {
    const expected = sdk.runtime.testing.referenceAnimationScheduleDirtyBounds(view, animations);
    try exact(expected, policy.schedule(view, animations, core.nativeWindowPolicy));
    core.rt.frameReset();
}
test "compiled render animation replacement damage preserves first-match IDs f32 transforms and rotation extents" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const h = try harness(null);
    defer h.destroy(std.testing.allocator);
    const view = &h.runtime.views[0];
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{ .id = huge, .rect = .init(-2, 1, 17, 13), .fill = .{ .color = .rgb8(30, 80, 130) } } },
        .{ .fill_rect = .{ .id = huge, .rect = .init(-999, -999, 9999, 9999), .fill = .{ .color = .rgb8(30, 80, 130) } } },
        .{ .fill_rect = .{ .id = max, .rect = .init(10, 10, -8, -4), .fill = .{ .color = .rgb8(30, 80, 130) } } },
    };
    // Populate retained storage directly to exercise the reference's
    // first-match contract, including duplicate IDs refused at admission.
    try view.copyCanvasDisplayList(.{ .commands = &commands });
    seed(view, &.{}, &.{ .{ .id = huge, .transform = .translate(-5, 9) }, .{ .id = max }, .{ .id = 0 }, .{ .id = huge + 1 } });
    var animations = [_]Animation{ .{ .id = huge, .from_transform = .translate(3, -4), .to_transform = .{ .a = -1, .b = 0.25, .c = 0.1, .d = 1, .tx = 3, .ty = 4 } }, .{ .id = max, .from_rotation = 0, .to_rotation = 360, .rotation_center = .init(0.125, -1.75) }, .{ .id = huge + 1, .to_transform = .translate(900, 900) }, .{ .id = 0 } };
    try dirtyParity(view, &animations);
    try dirtyParity(view, &.{});
    const values = [_]f32{ -16777216, -240.00002, -1, -0.0, 0, 0.000001, 1.0000001, 23.999998, 24.000002, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    for (values) |value| {
        animations[1].rotation_center = .init(value, value);
        try dirtyParity(view, &animations);
    }
    for (0..6) |axis| for (values) |value| {
        if (builtin.mode != .ReleaseFast and !std.math.isFinite(value)) continue;
        animations[0].to_transform = .{};
        switch (axis) {
            0 => animations[0].to_transform.?.a = value,
            1 => animations[0].to_transform.?.b = value,
            2 => animations[0].to_transform.?.c = value,
            3 => animations[0].to_transform.?.d = value,
            4 => animations[0].to_transform.?.tx = value,
            else => animations[0].to_transform.?.ty = value,
        }
        try dirtyParity(view, &animations);
    };
}

var measurements: usize = 0;
var providers: [64]u64 = @splat(0);
fn orderedMeasure(_: ?*anyopaque, _: canvas.FontId, _: f32, _: []const u8) f32 {
    providers[measurements] = @intCast(measurements + 1);
    measurements += 1;
    return @floatFromInt(measurements);
}
test "compiled render animation native bounds capabilities preserve repeated callback order and ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const h = try harness(null);
    defer h.destroy(std.testing.allocator);
    const view = &h.runtime.views[0];
    const provider = canvas.TextMeasureProvider{ .measure_fn = orderedMeasure };
    const commands = [_]canvas.CanvasCommand{
        .{ .draw_text = .{ .id = huge, .size = 12, .color = .rgb8(10, 20, 30), .origin = .init(0, 20), .text = "measure", .measure = &provider } },
        .{ .draw_text = .{ .id = huge, .size = 12, .color = .rgb8(10, 20, 30), .origin = .init(500, 500), .text = "unselected duplicate", .measure = &provider } },
    };
    try view.copyCanvasDisplayList(.{ .commands = &commands });
    seed(view, &.{}, &.{ .{ .id = huge }, .{ .id = huge } });
    const animations = [_]Animation{ .{ .id = huge }, .{ .id = huge }, .{ .id = max } };
    measurements = 0;
    @memset(&providers, 0);
    const expected = sdk.runtime.testing.referenceAnimationScheduleDirtyBounds(view, &animations);
    const count = measurements;
    const calls = providers;
    measurements = 0;
    @memset(&providers, 0);
    const borrowed = core.rt.frameAlloc(u8, 8);
    @memcpy(borrowed, "anim\x00abi");
    try exact(expected, policy.schedule(view, &animations, core.nativeWindowPolicy));
    try exact(count, measurements);
    try exact(calls, providers);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualSlices(u8, "anim\x00abi", borrowed);
}

var lifecycle_calls: [4]usize = @splat(0);
fn observedLifecycle(request: []const u8, output: []u8) usize {
    if (request[0] == 72) lifecycle_calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
test "compiled render animation runtime hooks preserve complete plans retirement and replacement state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const native = try harness(null);
    defer native.destroy(std.testing.allocator);
    const compiled = try harness(observedLifecycle);
    defer compiled.destroy(std.testing.allocator);
    const Storage = @import("render_cache_e2e_tests.zig").Storage;
    const frameEqual = @import("render_cache_e2e_tests.zig").frameEqual;
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const draw = canvas.CanvasCommand{ .fill_rect = .{ .id = huge, .rect = .init(20, 25, 17, 13), .fill = .{ .color = .rgb8(30, 80, 130) } } };
    for ([_]@TypeOf(native){ native, compiled }) |h| _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{draw} });
    for ([_]@TypeOf(native){ native, compiled }) |h| seed(&h.runtime.views[0], &.{}, &.{});
    const sets = [_][]const Animation{
        &.{.{ .id = huge, .start_ns = huge, .duration_ms = 10, .easing = .linear, .from_opacity = 0.25, .to_opacity = 1, .from_transform = .translate(15, -10), .to_transform = .{} }},
        &.{ .{ .id = huge, .start_ns = huge, .duration_ms = 10, .loop = .wrap, .from_opacity = 1, .to_opacity = 0.5 }, .{ .id = huge, .start_ns = huge, .duration_ms = 10, .loop = .ping_pong, .from_transform = .{}, .to_transform = .translate(5, 3) } },
        &.{.{ .id = huge, .duration_ms = 0, .from_transform = .translate(5, 3), .to_transform = .{} }},
        &.{},
    };
    lifecycle_calls = @splat(0);
    for (sets) |animations| {
        try exact(try native.runtime.setCanvasRenderAnimations(1, "canvas", animations), try compiled.runtime.setCanvasRenderAnimations(1, "canvas", animations));
        try viewEqual(&native.runtime.views[0], &compiled.runtime.views[0]);
        for ([_]u64{ huge - 1, huge, huge + 5_000_000, huge + 10_000_000, huge + 20_000_000 }) |now| {
            const options = canvas.CanvasFrameOptions{ .frame_index = huge, .timestamp_ns = now, .surface_size = .{ .width = 160, .height = 120 }, .full_repaint = true };
            const before = lifecycle_calls;
            const expected_plan = try native.runtime.canvasFramePlan(1, "canvas", null, options, a.value);
            try frameEqual(expected_plan, try compiled.runtime.canvasFramePlan(1, "canvas", null, options, b.value), null);
            try exact(before, lifecycle_calls);
            try viewEqual(&native.runtime.views[0], &compiled.runtime.views[0]);
            const expected = try native.runtime.nextCanvasFrame(1, "canvas", options, a.value);
            try frameEqual(expected, try compiled.runtime.nextCanvasFrame(1, "canvas", options, b.value), null);
            try std.testing.expectEqual(before[0] + 1, lifecycle_calls[0]);
            try viewEqual(&native.runtime.views[0], &compiled.runtime.views[0]);
            try exact(native.runtime.invalidated, compiled.runtime.invalidated);
            try exact(native.runtime.last_invalidation_reason, compiled.runtime.last_invalidation_reason);
            try exact(native.runtime.pendingDirtyRegions(), compiled.runtime.pendingDirtyRegions());
            core.rt.frameReset();
        }
        try exact(try native.runtime.clearCanvasRenderAnimations(1, "canvas"), try compiled.runtime.clearCanvasRenderAnimations(1, "canvas"));
        try viewEqual(&native.runtime.views[0], &compiled.runtime.views[0]);
    }
    try std.testing.expect(lifecycle_calls[1] > 0 and lifecycle_calls[2] > 0 and lifecycle_calls[3] > 0);
    const before = lifecycle_calls;
    try std.testing.expectError(error.InvalidViewOptions, native.runtime.setCanvasRenderAnimations(1, "canvas", &.{.{ .id = 0 }}));
    try std.testing.expectError(error.InvalidViewOptions, compiled.runtime.setCanvasRenderAnimations(1, "canvas", &.{.{ .id = 0 }}));
    try std.testing.expectEqual(before[3] + 1, lifecycle_calls[3]);
    try std.testing.expectEqual(before[2], lifecycle_calls[2]);
    try viewEqual(&native.runtime.views[0], &compiled.runtime.views[0]);
}
extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;
test "compiled render animation calls preserve complete borrowed model and view bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed_model = core.modelSnapshot();
    const saved_model = try std.testing.allocator.dupe(u8, borrowed_model);
    defer std.testing.allocator.free(saved_model);
    var borrowed_view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&borrowed_view, &view_len);
    const saved_view = try std.testing.allocator.dupe(u8, borrowed_view[0..view_len]);
    defer std.testing.allocator.free(saved_view);
    const h = try harness(null);
    defer h.destroy(std.testing.allocator);
    const v = &h.runtime.views[0];
    try v.copyCanvasDisplayList(.{ .commands = &.{.{ .fill_rect = .{ .id = huge, .rect = .init(20, 25, 17, 13), .fill = .{ .color = .rgb8(30, 80, 130) } } }} });
    const animations = [_]Animation{.{ .id = huge, .duration_ms = 0, .to_opacity = 1 }};
    seed(v, &animations, &.{.{ .id = huge, .opacity = 1 }});
    try std.testing.expect(!try policy.admit(&animations, 1, 1, 2048, core.nativeWindowPolicy));
    _ = policy.schedule(v, &animations, core.nativeWindowPolicy);
    try std.testing.expect(!policy.finishFrame(v, max, core.nativeWindowPolicy));
    try std.testing.expectEqual(@as(usize, 0), v.canvas_render_animation_count);
    try std.testing.expectEqual(@as(usize, 0), v.canvas_frame_render_override_count);
    try std.testing.expectEqualSlices(u8, saved_model, borrowed_model);
    try std.testing.expectEqualSlices(u8, saved_view, borrowed_view[0..view_len]);
}
test "compiled render animation copied transport rejects malformed result selectors and write extents" {
    var request: [80]u8 = @splat(0);
    request[0..4].* = .{ 72, 1, 0, 0 };
    var result: [33]u8 = @splat(0);
    result[0] = 1;
    try std.testing.expect(policy.resultValid(&request, result[0..32]));
    for ([_]usize{ 0, 1, 31, 33 }) |len| try std.testing.expect(!policy.resultValid(&request, result[0..len]));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28 }) |at| {
        var bad = result;
        bad[at] = 255;
        try std.testing.expect(!policy.resultValid(&request, bad[0..32]));
    }
    request[2] = 2;
    request[4] = 1;
    request[12] = 1;
    @memset(request[56..60], 255);
    var bounds: [64]u8 = @splat(0);
    bounds[0] = 1;
    bounds[4] = 1;
    try std.testing.expect(policy.resultValid(&request, &bounds));
    bounds[12] = 1;
    try std.testing.expect(!policy.resultValid(&request, &bounds));
    bounds[12] = 0;
    request[56] = 0;
    try std.testing.expect(!policy.resultValid(&request, &bounds));
}
