const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = canvas.RenderOverridePolicy;
const Override = canvas.CanvasRenderOverride;
const huge: u64 = 9007199254740993;
const sentinel = Override{ .id = 99, .opacity = 0.125, .transform = .translate(93, 94) };
const draw = canvas.CanvasCommand{ .fill_rect = .{ .id = huge, .rect = .init(-2, 1, 17, 13), .fill = .{ .color = canvas.Color.rgb8(30, 80, 130) } } };
const command = canvas.RenderCommand{ .command = draw, .id = huge, .opacity = 0.75, .clip = .init(-5, -7, 26, 31), .transform = .{ .a = 0.9, .b = -0.2, .c = 0.3, .d = 1.1, .tx = 1.125, .ty = -0.125 }, .local_bounds = .init(-2, 1, 17, 13), .bounds = .init(-2, 1, 17, 13) };

fn mergeParity(scheduled: []const Override, explicit: []const Override, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(Override, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(Override, capacity);
    defer std.testing.allocator.free(b);
    @memset(a, sentinel);
    @memset(b, sentinel);
    var workspace = canvas.RenderCacheWorkspace.initOverrides(core.nativeWindowPolicy, scheduled.len, explicit.len, 0, 0, capacity);
    defer workspace.deinit();
    const expected = sdk.runtime.testing.mergeCanvasRenderOverrides(scheduled, explicit, a);
    const actual = policy.merge(scheduled, explicit, b, core.nativeWindowPolicy, &workspace);
    if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
    try exact(a, b);
}

test "compiled override merge preserves exact IDs duplicates replacements and complete capacity prefixes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const scheduled = [_]Override{ .{ .id = huge, .opacity = 0.25 }, .{ .id = huge, .opacity = 0.5 }, .{ .id = huge + 1, .transform = .translate(5, -7) }, .{ .id = 0 } };
    const explicit = [_]Override{ .{ .id = huge, .opacity = 0.75 }, .{ .id = huge, .transform = .translate(-5, 7) }, .{ .id = huge + 2 }, .{ .id = 0, .opacity = -0.0 }, .{ .id = std.math.maxInt(u64), .opacity = 1 } };
    for ([_]usize{ 0, 1, 3, 4, 5, 6, 15 }) |capacity| {
        try mergeParity(&scheduled, &explicit, capacity);
        try mergeParity(&.{}, &explicit, capacity);
        try mergeParity(&scheduled, &.{}, capacity);
        core.rt.frameReset();
    }
}

fn applyParity(input: []const canvas.RenderCommand, previous: []const Override, next: []const Override, entries: []const policy.DamageEntry) !void {
    const a = try std.testing.allocator.dupe(canvas.RenderCommand, input);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.dupe(canvas.RenderCommand, input);
    defer std.testing.allocator.free(b);
    const dirty = canvas.renderOverrideDirtyBounds(a, previous, next);
    const bounds = canvas.applyRenderOverrides(a, next);
    var workspace = canvas.RenderCacheWorkspace.initOverrides(core.nativeWindowPolicy, previous.len, next.len, input.len, entries.len, 0);
    defer workspace.deinit();
    const result = policy.applyAndDamage(b, previous, next, entries, core.nativeWindowPolicy, &workspace);
    try exact(bounds, result.bounds);
    try exact(dirty, result.dirty);
    try exact(a, b);
    const harness = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var context: u8 = 0;
    try harness.start(.{ .context = &context, .name = "override-parity", .source = sdk.platform.WebViewSource.html("") });
    harness.null_platform.gpu_surfaces = true;
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
    const view = &harness.runtime.views[0];
    for (entries, 0..) |entry, i| view.canvas_render_animation_dirty_bounds[i] = .{ .id = entry.id, .bounds = entry.bounds };
    view.canvas_render_animation_dirty_bounds_count = entries.len;
    try exact(sdk.runtime.testing.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides(view, previous, next), result.animation_dirty);
}

test "compiled override application and damage preserve all command fields exact keys and optional equality" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var commands = [_]canvas.RenderCommand{ command, command, command, command };
    commands[1].id = null;
    commands[2].id = huge + 1;
    commands[3].id = 0;
    const previous = [_]Override{ .{ .id = huge, .opacity = 0.5, .transform = .translate(-100, 0) }, .{ .id = huge + 1 }, .{ .id = 0, .opacity = 0 } };
    const next = [_]Override{ .{ .id = huge, .opacity = 0.25, .transform = .{ .a = -1, .b = 0.25, .c = 0.1, .d = 1, .tx = 3, .ty = 4 } }, .{ .id = huge, .opacity = 1 }, .{ .id = huge + 1, .transform = .translate(800, 800) }, .{ .id = 0, .opacity = 1 } };
    const entries = [_]policy.DamageEntry{ .{ .id = huge, .bounds = .init(10, 10, -8, -4) }, .{ .id = huge, .bounds = null }, .{ .id = huge + 2, .bounds = .init(-999, -999, 9999, 9999) }, .{ .id = 0, .bounds = .init(0, 0, 1, 1) } };
    try applyParity(&commands, &previous, &next, &entries);
    try applyParity(&commands, &next, &next, &entries);
    try applyParity(&commands, &previous, &.{}, &entries);
    try applyParity(&commands, &.{}, &next, &entries);
    try applyParity(&commands, &.{}, &.{}, &entries);
    try applyParity(&.{}, &previous, &next, &entries);
}

test "compiled override f32 composition clamp clipping and NaN equality match every native field" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]f32{ -16777216, -240.00002, -1, -0.0, 0, 0.000001, 1.0000001, 23.999998, 24.000002, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    var next = [_]Override{.{ .id = huge, .opacity = 0.75, .transform = .translate(3, 4) }};
    for (values) |value| {
        next[0].opacity = value;
        try applyParity(&.{command}, &next, &next, &.{});
        core.rt.frameReset();
    }
    next[0].opacity = 0.5;
    for (0..6) |axis| for (values) |value| {
        if (builtin.mode != .ReleaseFast and !std.math.isFinite(value)) continue;
        next[0].transform = .{};
        switch (axis) {
            0 => next[0].transform.?.a = value,
            1 => next[0].transform.?.b = value,
            2 => next[0].transform.?.c = value,
            3 => next[0].transform.?.d = value,
            4 => next[0].transform.?.tx = value,
            else => next[0].transform.?.ty = value,
        }
        try applyParity(&.{command}, &.{}, &next, &.{});
        core.rt.frameReset();
    };
}

const Storage = @import("render_cache_e2e_tests.zig").Storage;
const frameEqual = @import("render_cache_e2e_tests.zig").frameEqual;
var calls: [2]usize = .{0} ** 2;
var first_request: ?[*]const u8 = null;
var first_result: ?[*]u8 = null;
var shared_buffers = true;
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 14) calls[request[1]] += 1;
    if (request[0] >= 12 and request[0] <= 14) {
        if (first_request) |pointer| {
            shared_buffers = shared_buffers and pointer == request.ptr;
        } else first_request = request.ptr;
        if (first_result) |pointer| {
            shared_buffers = shared_buffers and pointer == output.ptr;
        } else first_result = output.ptr;
    }
    return core.nativeWindowPolicy(request, output);
}
fn resetObserved() void {
    calls = .{0} ** 2;
    first_request = null;
    first_result = null;
    shared_buffers = true;
}

test "both Runtime consumers preserve full override frames damage stored overrides and shared buffer ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const native = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer native.destroy(std.testing.allocator);
    const compiled = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer compiled.destroy(std.testing.allocator);
    var context: u8 = 0;
    for ([_]@TypeOf(native){ native, compiled }, 0..) |h, lane| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = &context, .name = "override-parity", .source = sdk.platform.WebViewSource.html(""), .render_override_policy = if (lane == 1) observed else null, .render_plan_policy = if (lane == 1) observed else null, .render_cache_policy = if (lane == 1) observed else null });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
        _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &.{draw} });
        _ = try h.runtime.setCanvasRenderAnimations(1, "canvas", &.{.{ .id = huge, .start_ns = 100, .duration_ms = 10, .easing = .linear, .from_opacity = 1, .to_opacity = 0.25, .from_transform = .{}, .to_transform = .translate(15, -10) }});
        h.runtime.views[0].canvas_render_animation_dirty_bounds[0] = .{ .id = huge, .bounds = .init(-3, -4, 42, 33) };
        h.runtime.views[0].canvas_render_animation_dirty_bounds_count = 1;
    }
    try std.testing.expect(compiled.runtime.render_override_policy == observed);
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const explicit = [_]Override{.{ .id = huge, .opacity = 0.5, .transform = .translate(-2, 4) }};
    for (0..4) |phase| {
        const options = canvas.CanvasFrameOptions{ .frame_index = huge + phase, .timestamp_ns = 100 + phase * 5_000_000, .surface_size = .{ .width = 160, .height = 120 }, .render_overrides = if (phase == 1) &explicit else &.{}, .full_repaint = phase == 0 };
        resetObserved();
        const diagnostic = try native.runtime.canvasFramePlan(1, "canvas", null, options, a.value);
        try frameEqual(diagnostic, try compiled.runtime.canvasFramePlan(1, "canvas", null, options, b.value), observed);
        try exact([_]usize{ 0, 1 }, calls);
        try std.testing.expect(shared_buffers);
        resetObserved();
        const actual = try native.runtime.nextCanvasFrame(1, "canvas", options, a.value);
        try frameEqual(actual, try compiled.runtime.nextCanvasFrame(1, "canvas", options, b.value), observed);
        try exact([_]usize{ 1, 1 }, calls);
        try std.testing.expect(shared_buffers);
        try exact(@as([]const Override, native.runtime.canvas_frame_render_override_samples[0..1]), @as([]const Override, compiled.runtime.canvas_frame_render_override_samples[0..1]));
        try exact(@as([]const Override, native.runtime.canvas_frame_render_override_combined[0..1]), @as([]const Override, compiled.runtime.canvas_frame_render_override_combined[0..1]));
        try exact(sdk.runtime.testing.runtimeViewCanvasFrameRenderOverrides(&native.runtime.views[0]), sdk.runtime.testing.runtimeViewCanvasFrameRenderOverrides(&compiled.runtime.views[0]));
        core.rt.frameReset();
    }
}

test "override owner remains independent and errors preserve all frame storage before downstream planning" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const previous = [_]Override{.{ .id = huge, .opacity = 0.5, .transform = .translate(1, 3) }};
    const next = [_]Override{.{ .id = huge, .opacity = 0, .transform = .translate(800, 800) }};
    const list = canvas.DisplayList{ .commands = &.{draw} };
    const expected = try list.framePlan(null, .{ .previous_render_overrides = &previous, .render_overrides = &next }, a.value);
    resetObserved();
    try frameEqual(expected, try list.framePlan(null, .{ .render_override_policy = observed, .previous_render_overrides = &previous, .render_overrides = &next }, b.value), null);
    try exact([_]usize{ 0, 1 }, calls);
    for ([_]bool{ false, true }) |stack| {
        var sa = a.value;
        var sb = b.value;
        sa.render_commands = sa.render_commands[0..0];
        sb.render_commands = sb.render_commands[0..0];
        const failed = canvas.DisplayList{ .commands = if (stack) &.{ .pop_clip, draw } else &.{draw} };
        const err = if (stack) error.RenderStackUnderflow else error.RenderListFull;
        resetObserved();
        try std.testing.expectError(err, failed.framePlan(null, .{}, sa));
        try std.testing.expectError(err, failed.framePlan(null, .{ .render_override_policy = observed }, sb));
        try exact([_]usize{ 0, 0 }, calls);
        inline for (@typeInfo(canvas.CanvasFrameStorage).@"struct".fields) |field| try exact(@field(a.value, field.name), @field(b.value, field.name));
        core.rt.frameReset();
    }
}

extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;
test "override copied calls preserve borrowed committed model and native view bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.modelSnapshot();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    var view: [*]const u8 = undefined;
    var view_len: usize = 0;
    nsc_core_native_view(&view, &view_len);
    const saved_view = try std.testing.allocator.dupe(u8, view[0..view_len]);
    defer std.testing.allocator.free(saved_view);
    var workspace = canvas.RenderCacheWorkspace.initOverrides(core.nativeWindowPolicy, 1, 1, 1, 0, 2);
    defer workspace.deinit();
    const request_pointer = workspace.request.ptr;
    const result_pointer = workspace.result.ptr;
    var output = [_]Override{sentinel} ** 2;
    _ = try policy.merge(&.{.{ .id = huge }}, &.{.{ .id = huge, .opacity = 0.5 }}, &output, core.nativeWindowPolicy, &workspace);
    var commands = [_]canvas.RenderCommand{command};
    _ = policy.applyAndDamage(&commands, &.{.{ .id = huge }}, output[0..1], &[_]policy.DamageEntry{}, core.nativeWindowPolicy, &workspace);
    try std.testing.expectEqualSlices(u8, saved, borrowed);
    try std.testing.expectEqualSlices(u8, saved_view, view[0..view_len]);
    try std.testing.expect(request_pointer == workspace.request.ptr and result_pointer == workspace.result.ptr);
}
