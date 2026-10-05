const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const geometry = sdk.geometry;
const policy = canvas.RenderDamagePolicy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const testing = sdk.runtime.testing;
const sentinel: geometry.RectF = .init(91, 92, 93, 94);

fn snap(bounds: ?geometry.RectF, scale: f32, surface: geometry.SizeF) !void {
    var frame = canvas.CanvasFrame{ .dirty_bounds = bounds, .surface_size = surface, .scale = -19 };
    const expected = testing.referenceDamageSnap(bounds, scale, 1, surface);
    policy.widen(&frame, scale, core.nativeWindowPolicy);
    try exact(expected, frame.dirty_bounds);
    try std.testing.expectEqual(@as(usize, 0), frame.dirty_rect_count);
}
test "compiled device snapping matches native f32 bits at fractional grids clipping and finite range edges" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]f32{ -16777216, -240.00002, -1, -0.0, 0, 0.000001, 1.0000001, 23.999998, 24.000002, 16777216, 20000000, -3.0e38, 1.0e38 };
    const scales = [_]f32{ 0, -1, 0.75, 1, 1.3, 1.5, 1.75, 2, 2.5, std.math.inf(f32), std.math.nan(f32) };
    for (scales) |scale| for (values) |value| {
        for ([_]geometry.SizeF{ .{}, .init(800.00006, 599.99994), .init(-800, -600) }) |surface| {
            try snap(.init(value, 3.125, 17.25, 13.5), scale, surface);
            try snap(.init(3.125, value, -17.25, -13.5), scale, surface);
            core.rt.frameReset();
        }
    };
    try snap(null, 1.3, .init(800, 600));
    try snap(.init(-3.0e38, -3.0e38, 1.0e38, 1.0e38), 2, .{});
    try snap(.init(1.0e38, 1.0e38, 2.0e38, 2.0e38), 2, .{});
}
test "compiled effective scale widening preserves complete dirty backing state after dropped clusters and no ops" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]f32{ 1, 1.3, 1.75, 2 }) |scale| for ([_]bool{ false, true }) |full| {
        var a = canvas.CanvasFrame{ .scale = 2, .surface_size = .init(100, 80), .full_repaint = full, .dirty_bounds = .init(-3, -4, 75, 68), .dirty_rect_count = 4, .dirty_rects = .{ .init(-30, -30, 1, 1), .init(10, 10, 4, 3), .init(45, 30, 7, 4), .init(900, 900, 1, 1), sentinel, sentinel, sentinel, sentinel } };
        var b = a;
        testing.referenceDamageWiden(&a, scale);
        policy.widen(&b, scale, core.nativeWindowPolicy);
        try exact(a, b);
        core.rt.frameReset();
    };
}
const Entry = testing.DamageCurrentCommand;
fn patchParity(keys: []const u64, fingerprints: []const u64, bounds: []const geometry.RectF, current: []const Entry) !void {
    const View = struct { canvas_packet_baseline_count: usize, canvas_packet_baseline_keys: []const u64, canvas_packet_baseline_fingerprints: []const u64, canvas_packet_baseline_bounds: []const geometry.RectF };
    var view = View{ .canvas_packet_baseline_count = keys.len, .canvas_packet_baseline_keys = keys, .canvas_packet_baseline_fingerprints = fingerprints, .canvas_packet_baseline_bounds = bounds };
    const a = try std.testing.allocator.alloc(bool, keys.len * 2 + current.len);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(bool, a.len);
    defer std.testing.allocator.free(b);
    @memset(a, false);
    @memset(b, true);
    const expected = testing.referenceDamagePatch(&view, current, a[0..keys.len], a[keys.len .. keys.len * 2], a[keys.len * 2 ..]);
    var workspace = canvas.RenderCacheWorkspace.initDamage(core.nativeWindowPolicy, 0, 0, keys.len, current.len);
    defer workspace.deinit();
    const actual = policy.patch(keys, fingerprints, bounds, current, b[0..keys.len], b[keys.len .. keys.len * 2], b[keys.len * 2 ..], core.nativeWindowPolicy, &workspace);
    try exact(a, b);
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |value| {
        try exact(value.bounds, actual.?.bounds);
        try exact(value.rect_count, actual.?.rect_count);
        try exact(value.rects[0..value.rect_count], actual.?.rects[0..actual.?.rect_count]);
    }
}
test "compiled retained edits preserve exact keys fingerprints ordered clusters scratch flags and reorder refusal" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var keys: [40]u64 = undefined;
    var fingerprints: [40]u64 = undefined;
    var bounds: [40]geometry.RectF = undefined;
    var current: [40]Entry = undefined;
    for (&keys, &fingerprints, &bounds, &current, 0..) |*key, *fingerprint, *rect, *entry, i| {
        key.* = 9007199254740993 + i * 8192;
        fingerprint.* = std.math.maxInt(u64) - i;
        rect.* = .init(@floatFromInt((i % 10) * 24), @floatFromInt((i / 10) * 32), 7, 9);
        entry.* = .{ .key = key.*, .fingerprint = fingerprint.* +% 1, .bounds = rect.*, .render_index = @intCast(i) };
    }
    for ([_]usize{ 0, 1, 7, 8, 9, 16, 40 }) |count| {
        try patchParity(keys[0..count], fingerprints[0..count], bounds[0..count], current[0..count]);
        try patchParity(keys[0..count], fingerprints[0..count], bounds[0..count], &.{});
        try patchParity(&.{}, &.{}, &.{}, current[0..count]);
        core.rt.frameReset();
    }
    for (&current, 0..) |*entry, i| entry.fingerprint = fingerprints[i];
    try patchParity(&keys, &fingerprints, &bounds, &current);
    std.mem.swap(Entry, &current[0], &current[1]);
    try patchParity(&keys, &fingerprints, &bounds, &current);
    current[0].fingerprint +%= 1;
    try patchParity(&keys, &fingerprints, &bounds, &current);
}
const Storage = @import("render_cache_e2e_tests.zig").Storage;
const frameEqual = @import("render_cache_e2e_tests.zig").frameEqual;
var calls: [4]usize = .{0} ** 4;
var request_pointer: ?[*]const u8 = null;
var result_pointer: ?[*]u8 = null;
var shared = true;
fn observed(request: []const u8, result: []u8) usize {
    if (request[0] == 15) calls[request[1]] += 1;
    if (request[0] >= 12 and request[0] <= 15) {
        if (request_pointer) |pointer| shared = shared and pointer == request.ptr else request_pointer = request.ptr;
        if (result_pointer) |pointer| shared = shared and pointer == result.ptr else result_pointer = result.ptr;
    }
    return core.nativeWindowPolicy(request, result);
}
fn reset() void {
    calls = .{0} ** 4;
    request_pointer = null;
    result_pointer = null;
    shared = true;
}
fn draw(id: u64, rect: geometry.RectF, variant: bool) canvas.CanvasCommand {
    return .{ .fill_rect = .{ .id = id, .rect = rect, .fill = .{ .color = if (variant) canvas.Color.rgb8(80, 90, 130) else canvas.Color.rgb8(20, 30, 50) } } };
}
test "diagnostic damage full frames blur footprints and earliest errors match the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const old = canvas.DisplayList{ .commands = &.{draw(1, .init(10.125, 12.75, 12.375, 17.5), false)} };
    const lists = [_]canvas.DisplayList{
        .{ .commands = &.{draw(1, .init(10.125, 12.75, 12.375, 17.5), true)} },
        .{ .commands = &.{ draw(1, .init(10.125, 12.75, 12.375, 17.5), true), .{ .blur = .{ .id = 2, .rect = .init(22, 15, 9, 8), .radius = 3 } } } },
        .{ .commands = &.{ draw(1, .init(10.125, 12.75, 12.375, 17.5), true), .{ .push_clip = .{ .rect = .init(26, 18, 5, 4) } }, .{ .transform = .{ .a = 0.9, .b = -0.2, .c = 0.3, .d = 1.1, .tx = 1.125, .ty = -0.125 } }, .{ .blur = .{ .id = 2, .rect = .init(22, 15, 9, 8), .radius = 3 } }, .pop_clip } },
    };
    for (lists) |list| for ([_]f32{ 1, 1.3, 1.75, 2 }) |scale| for ([_]f32{ 1, 3, 0, std.math.nan(f32) }) |multiplier| {
        const options = canvas.CanvasFrameOptions{ .scale = scale, .surface_size = .init(800.00006, 599.99994), .backdrop_blur_sample_extent_multiplier = multiplier };
        var owned = options;
        owned.render_damage_policy = observed;
        reset();
        try frameEqual(try list.framePlan(old, options, a.value), try list.framePlan(old, owned, b.value));
        try std.testing.expectEqual(@as(usize, 1), calls[0]);
        try std.testing.expect(shared);
        core.rt.frameReset();
    };
    var limited_a = a.value;
    var limited_b = b.value;
    limited_a.changes = limited_a.changes[0..0];
    limited_b.changes = limited_b.changes[0..0];
    reset();
    try std.testing.expectError(error.DiffListFull, lists[0].framePlan(old, .{}, limited_a));
    try std.testing.expectError(error.DiffListFull, lists[0].framePlan(old, .{ .render_damage_policy = observed }, limited_b));
    try exact([_]usize{0} ** 4, calls);
    inline for (@typeInfo(canvas.CanvasFrameStorage).@"struct".fields) |field| try exact(@field(a.value, field.name), @field(b.value, field.name));
}
extern fn nsc_core_native_view(out: *[*]const u8, len: *usize) callconv(.c) void;
test "damage copied calls preserve borrowed model view and shared native buffers without reset" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.modelSnapshot();
    const saved = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(saved);
    var view: [*]const u8 = undefined;
    var length: usize = 0;
    nsc_core_native_view(&view, &length);
    const saved_view = try std.testing.allocator.dupe(u8, view[0..length]);
    defer std.testing.allocator.free(saved_view);
    var workspace = canvas.RenderCacheWorkspace.initDamage(core.nativeWindowPolicy, 1, 0, 1, 1);
    defer workspace.deinit();
    const request = workspace.request.ptr;
    const result = workspace.result.ptr;
    const current = [_]Entry{.{ .key = 9007199254740993, .fingerprint = 1, .bounds = .init(20, 30, 4, 6), .render_index = 0 }};
    var matched: [1]bool = undefined;
    var stable: [1]bool = undefined;
    var upsert: [1]bool = undefined;
    const patch = policy.patch(&.{9007199254740993}, &.{0}, &.{.init(10, 20, 4, 6)}, &current, &matched, &stable, &upsert, core.nativeWindowPolicy, &workspace).?;
    var rects = [_]geometry.RectF{sentinel} ** canvas.max_canvas_frame_dirty_rects;
    _ = policy.finalize(.{ .presentation = true, .full_repaint = false, .surface_size = .init(800, 600), .scale = 1.3, .render_bounds = .init(0, 0, 800, 600), .refinement = patch }, &.{}, &.{}, &rects, core.nativeWindowPolicy, &workspace);
    try std.testing.expectEqualSlices(u8, saved, borrowed);
    try std.testing.expectEqualSlices(u8, saved_view, view[0..length]);
    try std.testing.expect(request == workspace.request.ptr and result == workspace.result.ptr);
}

test "both runtime damage consumers preserve complete incremental frames retained refinement and shared owners" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const native = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer native.destroy(std.testing.allocator);
    const compiled = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer compiled.destroy(std.testing.allocator);
    var context: u8 = 0;
    for ([_]@TypeOf(native){ native, compiled }, 0..) |h, lane| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = &context, .name = "damage-parity", .source = sdk.platform.WebViewSource.html(""), .render_damage_policy = if (lane == 1) observed else null, .render_cache_policy = if (lane == 1) observed else null, .render_plan_policy = if (lane == 1) observed else null, .render_override_policy = if (lane == 1) observed else null });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
    }
    try std.testing.expect(compiled.runtime.render_damage_policy == observed);
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    var old = [_]canvas.CanvasCommand{ draw(1, .init(10.125, 12.75, 12.375, 17.5), false), draw(2, .init(100.125, 82.75, 12.375, 17.5), false) };
    var next = old;
    for (0..4) |phase| {
        next[0] = draw(1, .init(10.125 + @as(f32, @floatFromInt(phase)), 12.75, 12.375, 17.5), phase % 2 == 1);
        for ([_]@TypeOf(native){ native, compiled }) |h| {
            _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &next });
            const target = &h.runtime.views[0];
            target.presented_canvas_valid = phase != 0;
            target.canvas_packet_baseline_valid = phase != 0;
            target.canvas_packet_baseline_surface_size = .init(160, 120);
            target.canvas_packet_baseline_scale = 1.3;
            target.canvas_packet_baseline_count = 2;
            for (old, 0..) |command, i| {
                var render: [1]canvas.RenderCommand = undefined;
                const plan = try (canvas.DisplayList{ .commands = &.{command} }).renderPlan(&render);
                const gpu_command = canvas.canvasGpuCommandFromRenderCommand(plan.commands[0], i);
                const fingerprint = canvas.canvasGpuCommandFingerprint(gpu_command);
                target.canvas_packet_baseline_keys[i] = canvas.canvasGpuPacketCommandKey(gpu_command, fingerprint);
                target.canvas_packet_baseline_fingerprints[i] = fingerprint;
                target.canvas_packet_baseline_bounds[i] = plan.commands[0].bounds;
            }
        }
        const options = canvas.CanvasFrameOptions{ .frame_index = 9007199254740993 + phase, .timestamp_ns = 33, .surface_size = .init(160, 120), .scale = 1.3, .full_repaint = phase == 0 };
        reset();
        try frameEqual(try native.runtime.canvasFramePlan(1, "canvas", .{ .commands = &old }, options, a.value), try compiled.runtime.canvasFramePlan(1, "canvas", .{ .commands = &old }, options, b.value));
        try std.testing.expectEqual(@as(usize, 1), calls[0]);
        try std.testing.expect(shared);
        reset();
        try frameEqual(try native.runtime.nextCanvasFrame(1, "canvas", options, a.value), try compiled.runtime.nextCanvasFrame(1, "canvas", options, b.value));
        try std.testing.expectEqual(@as(usize, 1), calls[1]);
        if (phase > 0) try std.testing.expectEqual(@as(usize, 1), calls[3]);
        try std.testing.expect(shared);
        old = next;
        core.rt.frameReset();
    }
}
