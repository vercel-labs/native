const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const cache = @import("render_cache_policy.zig");
const numericFlags = @import("render_plan_policy.zig").numericFlags;

pub const Patch = struct {
    bounds: ?geometry.RectF = null,
    rects: [canvas.max_canvas_frame_dirty_rects]geometry.RectF = undefined,
    rect_count: usize = 0,
};
pub const Result = struct { full_repaint: bool, bounds: ?geometry.RectF, rect_count: usize };
pub const Input = struct {
    presentation: bool = false,
    full_repaint: bool,
    surface_size: geometry.SizeF,
    scale: f32,
    render_bounds: ?geometry.RectF,
    override_bounds: ?geometry.RectF = null,
    animation_bounds: ?geometry.RectF = null,
    refinement: ?Patch = null,
    sample_extent_multiplier: f32 = 1,
};

/// Buffers are native-owned and shared with the other ordered frame policies.
/// Only numeric facts cross; command payloads and GPU resources stay native.
pub fn finalize(input: Input, changes: []const canvas.DiffChange, commands: []const canvas.RenderCommand, rects: *[canvas.max_canvas_frame_dirty_rects]geometry.RectF, policy: cache.Policy, workspace: *cache.Workspace) Result {
    var blur_count: usize = 0;
    for (commands) |command| if (command.command == .blur) {
        blur_count += 1;
    };
    const refinement_rects = if (input.refinement) |refined| refined.rects[0..refined.rect_count] else &.{};
    const request = workspace.request[0 .. 128 + changes.len * 20 + refinement_rects.len * 16 + blur_count * 68];
    header(request, if (input.presentation) 1 else 0, input, changes.len, refinement_rects.len, blur_count, 0, 0);
    for (changes, 0..) |change, i| putOptional(request, 128 + i * 20, change.dirty_bounds);
    const rect_at = 128 + changes.len * 20;
    for (refinement_rects, 0..) |rect, i| putRect(request, rect_at + i * 16, rect);
    var at = rect_at + refinement_rects.len * 16;
    for (commands) |command| switch (command.command) {
        .blur => |blur| {
            putRect(request, at, blur.rect);
            inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| putFloat(request, at + 16 + i * 4, @field(command.transform, field));
            putOptional(request, at + 40, command.clip);
            putFloat(request, at + 60, command.opacity);
            putFloat(request, at + 64, blur.radius);
            at += 68;
        },
        else => {},
    };
    const result = call(request, policy, workspace, 0, 0);
    installRects(result, rects);
    return .{ .full_repaint = word(result, 0) == 1, .bounds = optionalRect(result, 16), .rect_count = word(result, 4) };
}

pub fn patch(baseline_keys: []const u64, baseline_fingerprints: []const u64, baseline_bounds: []const geometry.RectF, current: anytype, matched: []bool, stable: []bool, upsert: []bool, policy: cache.Policy, workspace: *cache.Workspace) ?Patch {
    const baseline = baseline_keys.len;
    const request = workspace.request[0 .. 128 + (baseline + current.len) * 32];
    header(request, 3, .{ .full_repaint = false, .surface_size = .{}, .scale = 1, .render_bounds = null }, 0, 0, 0, baseline, current.len);
    for (baseline_keys, 0..) |key, i| putEntry(request, 128 + i * 32, key, baseline_fingerprints[i], baseline_bounds[i]);
    for (current, 0..) |entry, i| putEntry(request, 128 + (baseline + i) * 32, entry.key, entry.fingerprint, entry.bounds);
    const result = call(request, policy, workspace, baseline, current.len);
    const written = word(result, 8);
    var at = 64 + @as(usize, written) * 16;
    for (0..baseline) |i| {
        if (result[at] > 1 or result[at + 1] > 1) @panic("invalid compiled damage match flags");
        matched[i] = result[at] == 1;
        stable[i] = result[at + 1] == 1;
        at += 2;
    }
    for (0..current.len) |i| {
        if (result[at] > 1) @panic("invalid compiled damage upsert flags");
        upsert[i] = result[at] == 1;
        at += 1;
    }
    if (word(result, 12) == 0) return null;
    var value = Patch{ .bounds = optionalRect(result, 16), .rect_count = word(result, 4) };
    installRects(result, &value.rects);
    return value;
}

pub fn widen(frame: *canvas.CanvasFrame, scale: f32, policy: cache.Policy) void {
    if (frame.full_repaint or scale == frame.scale) return;
    var workspace = cache.Workspace.initDamage(policy, 0, 0, 0, 0);
    defer workspace.deinit();
    const request = workspace.request[0 .. 128 + frame.dirty_rect_count * 16];
    header(request, 2, .{ .full_repaint = frame.full_repaint, .surface_size = frame.surface_size, .scale = scale, .render_bounds = frame.dirty_bounds }, 0, frame.dirty_rect_count, 0, 0, 0);
    putFloat(request, 100, frame.scale);
    for (frame.dirtyRects(), 0..) |rect, i| putRect(request, 128 + i * 16, rect);
    const result = call(request, policy, &workspace, 0, 0);
    installRects(result, &frame.dirty_rects);
    frame.dirty_bounds = optionalRect(result, 16);
    frame.dirty_rect_count = word(result, 4);
}

fn header(request: []u8, mode: u8, input: Input, changes: usize, rects: usize, blurs: usize, baseline: usize, current: usize) void {
    @memset(request, 0);
    request[0] = 15;
    request[1] = mode;
    request[2] = numericFlags();
    request[3] = @as(u8, @intFromBool(input.full_repaint)) | (@as(u8, @intFromBool(input.refinement != null)) << 1);
    putFloat(request, 4, input.surface_size.width);
    putFloat(request, 8, input.surface_size.height);
    putFloat(request, 12, input.scale);
    putOptional(request, 16, input.render_bounds);
    putOptional(request, 36, input.override_bounds);
    putOptional(request, 56, input.animation_bounds);
    putOptional(request, 76, if (input.refinement) |value| value.bounds else null);
    putFloat(request, 96, input.sample_extent_multiplier);
    putWord(request, 104, changes);
    putWord(request, 108, rects);
    putWord(request, 112, blurs);
    putWord(request, 116, baseline);
    putWord(request, 120, current);
    putWord(request, 124, canvas.max_canvas_frame_dirty_rects);
}
fn call(request: []const u8, policy: cache.Policy, workspace: *cache.Workspace, baseline: usize, current: usize) []const u8 {
    const result = workspace.result[0 .. 64 + canvas.max_canvas_frame_dirty_rects * 16 + baseline * 2 + current];
    const length = policy(request, result);
    if (length < 64 or length > result.len) @panic("truncated compiled damage result");
    const count = word(result, 4);
    const written = word(result, 8);
    if (word(result, 0) > 1 or word(result, 12) > 1 or written > canvas.max_canvas_frame_dirty_rects or count > written or length != 64 + @as(usize, written) * 16 + baseline * 2 + current) @panic("invalid compiled damage result");
    for (result[36..64]) |byte| if (byte != 0) @panic("invalid compiled damage reserved field");
    return result[0..length];
}
fn installRects(result: []const u8, output: *[canvas.max_canvas_frame_dirty_rects]geometry.RectF) void {
    for (0..word(result, 8)) |i| output[i] = readRect(result, 64 + i * 16);
}
fn putEntry(bytes: []u8, at: usize, key: u64, fingerprint: u64, bounds: geometry.RectF) void {
    std.mem.writeInt(u64, bytes[at..][0..8], key, .little);
    std.mem.writeInt(u64, bytes[at + 8 ..][0..8], fingerprint, .little);
    putRect(bytes, at + 16, bounds);
}
fn putWord(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn putFloat(bytes: []u8, at: usize, value: f32) void {
    putWord(bytes, at, @as(u32, @bitCast(value)));
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn putRect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| putFloat(bytes, at + i * 4, @field(value, field));
}
fn readRect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(float(bytes, at), float(bytes, at + 4), float(bytes, at + 8), float(bytes, at + 12));
}
fn putOptional(bytes: []u8, at: usize, value: ?geometry.RectF) void {
    putWord(bytes, at, @intFromBool(value != null));
    putRect(bytes, at + 4, value orelse .{});
}
fn optionalRect(bytes: []const u8, at: usize) ?geometry.RectF {
    const present = word(bytes, at);
    if (present > 1) @panic("invalid compiled damage bounds");
    return if (present == 0) null else readRect(bytes, at + 4);
}
