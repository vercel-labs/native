//! Copied animation facts and batched scalar numeric capabilities. TypeScript
//! owns sampling; native owns the request storage and caller's output lifetime.
const std = @import("std");
const canvas = @import("canvas");
pub const Policy = *const fn ([]const u8, []u8) usize;
const allocator = std.heap.page_allocator;
const stride = 144;

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("motion transport exceeds wire range"), .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn affine(bytes: []u8, at: usize, value: canvas.Affine) void {
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| float(bytes, at + i * 4, @field(value, field));
}
fn readAffine(bytes: []const u8, at: usize) canvas.Affine {
    var result: canvas.Affine = undefined;
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| @field(result, field) = readFloat(bytes, at + i * 4);
    return result;
}
fn size(count: usize, width: usize) usize {
    return std.math.add(usize, 32, std.math.mul(usize, count, width) catch @panic("motion transport size overflow")) catch @panic("motion transport size overflow");
}
fn header(request: []u8, mode: u8, count: usize, capacity: usize, timestamp_ns: u64) void {
    @memset(request, 0);
    request[0..4].* = .{ 73, 1, mode, canvas.renderNumericFlags() };
    put(request, 4, count);
    put(request, 8, capacity);
    wide(request, 16, timestamp_ns);
}
fn record(bytes: []u8, at: usize, value: canvas.CanvasRenderAnimation) void {
    wide(bytes, at, value.id);
    wide(bytes, at + 8, value.start_ns);
    put(bytes, at + 16, value.duration_ms);
    put(bytes, at + 20, @intFromEnum(value.easing));
    put(bytes, at + 24, @intFromEnum(value.loop));
    put(bytes, at + 28, @as(u32, @intFromBool(value.from_opacity != null)) |
        (@as(u32, @intFromBool(value.to_opacity != null)) << 1) |
        (@as(u32, @intFromBool(value.from_transform != null)) << 2) |
        (@as(u32, @intFromBool(value.to_transform != null)) << 3) |
        (@as(u32, @intFromBool(value.from_rotation != null)) << 4) |
        (@as(u32, @intFromBool(value.to_rotation != null)) << 5));
    float(bytes, at + 32, value.spring.mass);
    float(bytes, at + 36, value.spring.stiffness);
    float(bytes, at + 40, value.spring.damping);
    float(bytes, at + 44, value.from_opacity orelse 0);
    float(bytes, at + 48, value.to_opacity orelse 0);
    affine(bytes, at + 52, value.from_transform orelse .{});
    affine(bytes, at + 76, value.to_transform orelse .{});
    float(bytes, at + 100, value.from_rotation orelse 0);
    float(bytes, at + 104, value.to_rotation orelse 0);
    float(bytes, at + 108, value.rotation_center.x);
    float(bytes, at + 112, value.rotation_center.y);
}
/// Validate selectors, cache writes and output extents before touching native
/// buffers. Numeric operands are policy-owned and are not derived again here.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 32 or request[0] != 73 or request[1] != 1 or request[2] > 1 or
        result.len < 32 or word(result, 0) != 1 or word(result, 4) > 2 or !std.mem.allEqual(u8, result[12..32], 0)) return false;
    const count = word(request, 4);
    if (@as(u64, count) * stride + 32 != request.len) return false;
    const used = word(result, 8);
    if (word(result, 4) == 1) {
        if (used == 0 or @as(u64, used) > @as(u64, count) * 2 or @as(u64, used) * 16 + 32 != result.len) return false;
        var previous: u32 = 0;
        var seen: u32 = 0;
        for (0..used) |i| {
            const at = 32 + i * 16;
            const source = word(result, at);
            const slot = word(result, at + 4);
            if (source >= count or slot >= 5 or (i > 0 and source < previous)) return false;
            if (i == 0 or source != previous) seen = 0;
            const bit = @as(u32, 1) << @intCast(slot);
            if (seen & bit != 0 or word(request, 32 + @as(usize, source) * stride + 116) & bit != 0 or
                word(result, at + 8) != ([_]u32{ 3, 0, 1, 1, 2 })[slot]) return false;
            seen |= bit;
            previous = source;
        }
        return true;
    }
    if (used > count or used > word(request, 8) or @as(u64, used) * 48 + 32 != result.len or
        (word(result, 4) == 2 and used != word(request, 8)) or (request[2] == 1 and (word(result, 4) != 0 or used != 1))) return false;
    var previous: u32 = 0;
    for (0..used) |i| {
        const at = 32 + i * 48;
        const source = word(result, at);
        if (source >= count or (i > 0 and source <= previous) or word(result, at + 4) != 0 or
            word(result, at + 16) == 0 or word(result, at + 16) > 3 or
            !std.mem.eql(u8, result[at + 8 ..][0..8], request[32 + @as(usize, source) * stride ..][0..8])) return false;
        previous = source;
    }
    return true;
}
fn run(policy: Policy, request: []u8, output: []u8) []const u8 {
    for (0..4) |_| {
        @memset(output, 0xa5);
        const len = policy(request, output);
        if (len > output.len or !resultValid(request, output[0..len])) @panic("invalid motion sampling decision");
        const result = output[0..len];
        if (word(result, 4) != 1) return result;
        // Every request is validated before any primitive executes or any
        // continuation slot changes. At most three batches precede a sample.
        for (0..word(result, 8)) |i| {
            const at = 32 + i * 16;
            const target = 32 + @as(usize, word(result, at)) * stride;
            const slot = word(result, at + 4);
            const argument = readFloat(result, at + 12);
            const value: f32 = switch (word(result, at + 8)) {
                0 => @exp(argument),
                1 => @cos(argument),
                2 => @sin(argument),
                3 => @sqrt(argument),
                else => unreachable,
            };
            float(request, target + 120 + @as(usize, slot) * 4, value);
            put(request, target + 116, word(request, target + 116) | (@as(u32, 1) << @intCast(slot)));
        }
    }
    @panic("motion sampling continuation did not finish");
}
pub fn sample(animations: []const canvas.CanvasRenderAnimation, timestamp_ns: u64, output: []canvas.CanvasRenderOverride, policy: Policy) canvas.Error![]const canvas.CanvasRenderOverride {
    const request = allocator.alloc(u8, size(animations.len, stride)) catch @panic("motion transport allocation failed");
    defer allocator.free(request);
    header(request, 0, animations.len, output.len, timestamp_ns);
    for (animations, 0..) |value, i| record(request, 32 + i * stride, value);
    const buffer = allocator.alloc(u8, size(animations.len, 48)) catch @panic("motion transport allocation failed");
    defer allocator.free(buffer);
    const result = run(policy, request, buffer);
    const used = word(result, 8);
    for (output[0..used], 0..) |*value, i| {
        const at = 32 + i * 48;
        const mask = word(result, at + 16);
        value.* = .{
            .id = std.mem.readInt(u64, result[at + 8 ..][0..8], .little),
            .opacity = if (mask & 1 != 0) readFloat(result, at + 20) else null,
            .transform = if (mask & 2 != 0) readAffine(result, at + 24) else null,
        };
    }
    if (word(result, 4) == 2) return error.RenderOverrideListFull;
    return output[0..used];
}
pub fn progress(easing: canvas.Easing, spring: canvas.SpringToken, start_ns: u64, duration_ms: u32, timestamp_ns: u64, policy: Policy) f32 {
    var request: [32 + stride]u8 = undefined;
    header(&request, 1, 1, 1, timestamp_ns);
    record(&request, 32, .{ .id = 1, .easing = easing, .spring = spring, .start_ns = start_ns, .duration_ms = duration_ms });
    var output: [80]u8 = undefined;
    return readFloat(run(policy, &request, &output), 52);
}
