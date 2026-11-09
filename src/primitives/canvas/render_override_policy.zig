const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const cache = @import("render_cache_policy.zig");
const numericFlags = @import("render_plan_policy.zig").numericFlags;

pub const DamageEntry = struct { id: u64, bounds: ?geometry.RectF };
pub const Result = struct { bounds: ?geometry.RectF, dirty: ?geometry.RectF, animation_dirty: ?geometry.RectF };

/// Only copied exact identities and numeric records cross this boundary.
/// Resource payloads and untouched output slots retain native ownership.
pub fn merge(scheduled: []const canvas.CanvasRenderOverride, explicit: []const canvas.CanvasRenderOverride, output: []canvas.CanvasRenderOverride, policy: cache.Policy, workspace: *cache.Workspace) canvas.Error![]const canvas.CanvasRenderOverride {
    const count = scheduled.len + explicit.len;
    const request = workspace.request[0 .. 32 + count * 40];
    header(request, 0, scheduled.len, explicit.len, 0, 0, output.len);
    for (scheduled, 0..) |value, i| putOverride(request, 32 + i * 40, value);
    for (explicit, 0..) |value, i| putOverride(request, 32 + (scheduled.len + i) * 40, value);
    const result = workspace.result[0 .. 16 + @min(count, output.len) * 4];
    const length = policy(request, result);
    if (length < 16 or length > result.len) @panic("truncated compiled override merge");
    const written = word(result, 0);
    const failed = word(result, 4);
    if (written > @min(count, output.len) or failed > 1 or word(result, 8) != 0 or word(result, 12) != 0 or length != 16 + @as(usize, written) * 4) @panic("invalid compiled override merge");
    for (0..written) |i| {
        const source = word(result, 16 + i * 4);
        if (source >= count) @panic("invalid compiled override source");
        output[i] = if (source < scheduled.len) scheduled[source] else explicit[source - scheduled.len];
    }
    if (failed == 1) return error.RenderOverrideListFull;
    return output[0..written];
}

pub fn applyAndDamage(commands: []canvas.RenderCommand, previous: []const canvas.CanvasRenderOverride, next: []const canvas.CanvasRenderOverride, entries: anytype, policy: cache.Policy, workspace: *cache.Workspace) Result {
    const command_at = 32 + (previous.len + next.len) * 40;
    const entry_at = command_at + commands.len * 92;
    const request = workspace.request[0 .. entry_at + entries.len * 28];
    header(request, 1, previous.len, next.len, commands.len, entries.len, 0);
    for (previous, 0..) |value, i| putOverride(request, 32 + i * 40, value);
    for (next, 0..) |value, i| putOverride(request, 32 + (previous.len + i) * 40, value);
    for (commands, 0..) |command, i| {
        const at = command_at + i * 92;
        putId(request, at, command.id orelse 0);
        putWord(request, at + 8, @intFromBool(command.id != null));
        putFloat(request, at + 12, command.opacity);
        putAffine(request, at + 16, command.transform);
        putRect(request, at + 40, command.local_bounds);
        putRect(request, at + 56, command.bounds);
        putOptional(request, at + 72, command.clip);
    }
    for (entries, 0..) |entry, i| {
        const at = entry_at + i * 28;
        putId(request, at, entry.id);
        putOptional(request, at + 8, entry.bounds);
    }
    const result = workspace.result[0 .. 64 + commands.len * 44];
    const length = policy(request, result);
    if (length != result.len or word(result, 0) != commands.len) @panic("invalid compiled override command results");
    for (commands, 0..) |*command, i| {
        const at = 64 + i * 44;
        command.opacity = float(result, at);
        command.transform = affine(result, at + 4);
        command.bounds = rect(result, at + 28);
    }
    return .{ .bounds = optionalRect(result, 4), .dirty = optionalRect(result, 24), .animation_dirty = optionalRect(result, 44) };
}

fn header(request: []u8, mode: u8, first: usize, second: usize, commands: usize, entries: usize, capacity: usize) void {
    @memset(request, 0);
    request[0] = 14;
    request[1] = mode;
    request[2] = numericFlags();
    putWord(request, 4, first);
    putWord(request, 8, second);
    putWord(request, 12, commands);
    putWord(request, 16, entries);
    putWord(request, 20, capacity);
}
fn putOverride(bytes: []u8, at: usize, value: canvas.CanvasRenderOverride) void {
    putId(bytes, at, value.id);
    putWord(bytes, at + 8, @as(u32, @intFromBool(value.opacity != null)) | (@as(u32, @intFromBool(value.transform != null)) << 1));
    putFloat(bytes, at + 12, value.opacity orelse 0);
    putAffine(bytes, at + 16, value.transform orelse .{});
}
fn putId(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
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
fn rect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(float(bytes, at), float(bytes, at + 4), float(bytes, at + 8), float(bytes, at + 12));
}
fn putOptional(bytes: []u8, at: usize, value: ?geometry.RectF) void {
    putWord(bytes, at, @intFromBool(value != null));
    putRect(bytes, at + 4, value orelse .{});
}
fn optionalRect(bytes: []const u8, at: usize) ?geometry.RectF {
    const present = word(bytes, at);
    if (present > 1) @panic("invalid compiled override bounds");
    return if (present == 0) null else rect(bytes, at + 4);
}
fn putAffine(bytes: []u8, at: usize, value: canvas.Affine) void {
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| putFloat(bytes, at + i * 4, @field(value, field));
}
fn affine(bytes: []const u8, at: usize) canvas.Affine {
    return .{ .a = float(bytes, at), .b = float(bytes, at + 4), .c = float(bytes, at + 8), .d = float(bytes, at + 12), .tx = float(bytes, at + 16), .ty = float(bytes, at + 20) };
}
