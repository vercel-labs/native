//! Copied geometry/coverage transport. Caller-owned buffers and pixel sinks
//! remain native; the policy owns all vector decisions and error prefixes.
const std = @import("std");
const vector = @import("vector.zig");
const drawing = @import("drawing.zig");
const geometry = @import("geometry");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
const allocator = std.heap.page_allocator;
const word = wire.word;
const put = wire.put;
const float = wire.float;
const readFloat = wire.readFloat;
fn allocate(len: usize) []u8 {
    return allocator.alloc(u8, len) catch @panic("vector raster allocation failed");
}
fn errorStatus(status: u32) vector.Error!void {
    switch (status) {
        0 => {},
        1 => return error.VectorPathTooComplex,
        2 => return error.VectorRasterTooWide,
        else => @panic("invalid vector raster status"),
    }
}
fn signed(bytes: []const u8, at: usize) i32 {
    return @bitCast(word(bytes, at));
}
fn setSigned(bytes: []u8, at: usize, value: i32) void {
    put(bytes, at, @as(u32, @bitCast(value)));
}
fn edges(bytes: []u8, at: usize, raster: anytype) void {
    for (raster.edges[0..raster.edge_count], 0..) |edge, i| {
        inline for (.{ "x0", "y0", "x1", "y1", "dir" }, 0..) |field, j| float(bytes, at + i * 20 + j * 4, @field(edge, field));
    }
}
fn invoke(policy: Policy, request: []const u8, result: []u8) []const u8 {
    @memset(result, 0xa5);
    const len = policy(request, result);
    if (len > result.len or !resultValid(request, result[0..len])) @panic("invalid vector raster decision");
    return result[0..len];
}

/// Bounds every selector, extent and destination write before materializing.
/// No native geometry or coverage planner is called to validate decisions.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 4 or request[0] != 66 or request[1] != 1 or request[2] > 3 or result.len < 32 or word(result, 0) > 2 or word(result, 24) != 0 or word(result, 28) != 0) return false;
    const count: usize = word(result, 4);
    if (request[2] < 2) {
        if (request.len < 96 or count > word(request, 8) or word(result, 0) > 1 or count < word(request, 12) or result.len != 32 + count * 20) return false;
        const initial: usize = word(request, 12);
        const inputs: usize = word(request, 4);
        if (inputs > (request.len - 96) / 28 or initial > (request.len - 96 - inputs * 28) / 20 or request.len != 96 + inputs * 28 + initial * 20 or !std.mem.eql(u8, request[96 + inputs * 28 ..], result[32 .. 32 + initial * 20])) return false;
        for (0..count) |i| {
            const at = 32 + i * 20;
            if (readFloat(result, at + 16) != 1 and readFloat(result, at + 16) != -1) return false;
            inline for (0..4) |j| if (!std.math.isFinite(readFloat(result, at + j * 4))) return false;
        }
        return true;
    }
    if (request.len < 80) return false;
    const x0 = signed(result, 8);
    const y0 = signed(result, 12);
    const x1 = signed(result, 16);
    const y1 = signed(result, 20);
    if (x1 < x0 or y1 < y0) return false;
    const width: usize = @intCast(@as(i64, x1) - x0);
    if (request[2] == 2) return result.len == 32 and count == 0 and (word(result, 0) == 0 or word(result, 0) == 2) and (word(result, 0) == 2) == (width > vector.max_raster_width) and (width == 0 or (x0 >= signed(request, 32) and x1 <= signed(request, 40) and y0 >= signed(request, 36) and y1 <= signed(request, 44)));
    const first = signed(request, 48);
    const rows = word(request, 52);
    if (x0 < signed(request, 32) or x1 > signed(request, 40) or y0 < signed(request, 36) or y1 > signed(request, 44)) return false;
    if (word(result, 0) > 1 or width > vector.max_raster_width or rows == 0 or rows > 16 or count > rows or first < y0 or @as(i64, first) + rows > y1 or result.len != 32 + width * count * 4 or (word(result, 0) == 0 and count != rows)) return false;
    var at: usize = 32;
    while (at < result.len) : (at += 4) {
        const value = readFloat(result, at);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return false;
    }
    return true;
}

test "vector raster copied transport rejects unbounded extents and payload writes" {
    var request: [80]u8 = @splat(0);
    request[0..4].* = .{ 66, 1, 2, 0 };
    setSigned(&request, 40, 9000);
    setSigned(&request, 44, 10);
    var result: [32]u8 = @splat(0);
    try std.testing.expect(resultValid(&request, &result));
    setSigned(&result, 16, 9000);
    setSigned(&result, 20, 10);
    try std.testing.expect(!resultValid(&request, &result));
    put(&result, 0, 2);
    try std.testing.expect(resultValid(&request, &result));
    setSigned(&result, 16, 9001);
    try std.testing.expect(!resultValid(&request, &result));
    request[2] = 3;
    put(&request, 52, 1);
    var pixels: [36]u8 = @splat(0);
    put(&pixels, 4, 1);
    setSigned(&pixels, 16, 1);
    setSigned(&pixels, 20, 1);
    float(&pixels, 32, 0.5);
    try std.testing.expect(resultValid(&request, &pixels));
    for ([_]f32{ -1, 1.0001, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        float(&pixels, 32, bad);
        try std.testing.expect(!resultValid(&request, &pixels));
    }
    float(&pixels, 32, 0.5);
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28 }) |at| {
        var bad = pixels;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    for ([_]usize{ 0, 3, 31, 32, 35 }) |len| try std.testing.expect(!resultValid(&request, pixels[0..len]));
}

pub fn accumulate(raster: anytype, elements: []const drawing.PathElement, transform: drawing.Affine, tolerance: f32, limit: usize, style: ?vector.StrokeStyle, policy: Policy) vector.Error!void {
    const len = std.math.add(usize, 96, std.math.mul(usize, elements.len, 28) catch @panic("vector raster request too large")) catch @panic("vector raster request too large");
    const request = allocate(std.math.add(usize, len, raster.edge_count * 20) catch @panic("vector raster request too large"));
    defer allocator.free(request);
    @memset(request, 0);
    request[0..4].* = .{ 66, 1, @intFromBool(style != null), @import("numeric_capabilities.zig").numericFlags() };
    put(request, 4, elements.len);
    put(request, 8, raster.edges.len);
    put(request, 12, raster.edge_count);
    put(request, 16, limit);
    float(request, 24, tolerance);
    if (style) |s| {
        float(request, 28, s.width);
        float(request, 32, s.miter_limit);
        put(request, 36, @intFromEnum(s.cap));
        put(request, 40, @intFromEnum(s.join));
    }
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |field, i| float(request, 48 + i * 4, @field(transform, field));
    inline for (.{ "min_x", "min_y", "max_x", "max_y" }, 0..) |field, i| float(request, 72 + i * 4, @field(raster, field));
    for (elements, 0..) |element, i| {
        const at = 96 + i * 28;
        put(request, at, @intFromEnum(element.verb));
        for (element.points, 0..) |point, j| {
            float(request, at + 4 + j * 8, point.x);
            float(request, at + 8 + j * 8, point.y);
        }
    }
    edges(request, len, raster);
    const buffer = allocate(32 + raster.edges.len * 20);
    defer allocator.free(buffer);
    const result = invoke(policy, request, buffer);
    raster.edge_count = word(result, 4);
    inline for (.{ "min_x", "min_y", "max_x", "max_y" }, 0..) |field, i| @field(raster, field) = readFloat(result, 8 + i * 4);
    for (0..raster.edge_count) |i| inline for (.{ "x0", "y0", "x1", "y1", "dir" }, 0..) |field, j| {
        @field(raster.edges[i], field) = readFloat(result, 32 + i * 20 + j * 4);
    };
    try errorStatus(word(result, 0));
}

pub fn sweep(raster: anytype, rule: vector.FillRule, clip: vector.ClipRect, sink: anytype, policy: Policy) vector.Error!void {
    const request = allocate(80 + raster.edge_count * 20);
    defer allocator.free(request);
    @memset(request, 0);
    request[0..4].* = .{ 66, 1, 2, @import("numeric_capabilities.zig").numericFlags() };
    put(request, 4, raster.edge_count);
    put(request, 8, raster.crossings.len);
    put(request, 12, @intFromEnum(rule));
    inline for (.{ "min_x", "min_y", "max_x", "max_y" }, 0..) |field, i| float(request, 16 + i * 4, @field(raster, field));
    inline for (.{ "x0", "y0", "x1", "y1" }, 0..) |field, i| setSigned(request, 32 + i * 4, @field(clip, field));
    edges(request, 80, raster);
    var header: [32]u8 = undefined;
    const bounds = invoke(policy, request, &header);
    try errorStatus(word(bounds, 0));
    const x = signed(bounds, 8);
    const y_end = signed(bounds, 20);
    const width: usize = @intCast(@as(i64, signed(bounds, 16)) - x);
    var y = signed(bounds, 12);
    if (width == 0 or y == y_end) return;
    const buffer = allocate(32 + width * 16 * 4);
    defer allocator.free(buffer);
    request[2] = 3;
    while (y < y_end) {
        const rows: usize = @intCast(@min(16, @as(i64, y_end) - y));
        setSigned(request, 48, y);
        put(request, 52, rows);
        const result = invoke(policy, request, buffer);
        if (!std.mem.eql(u8, result[8..24], header[8..24])) @panic("vector raster coverage extent changed");
        const completed = word(result, 4);
        for (0..completed) |row| for (0..width) |col| {
            const coverage = readFloat(result, 32 + (row * width + col) * 4);
            if (coverage != 0) sink.pixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), coverage);
        };
        try errorStatus(word(result, 0));
        y = @intCast(@as(i64, y) + @as(i64, @intCast(rows)));
    }
}
