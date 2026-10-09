//! Caller-owned storage and explicit font capabilities for whole-run queries.
//! Traversal, output admission, accumulation and neighboring-line decisions
//! belong to the portable query and line planners.
const std = @import("std");
const geometry = @import("geometry");
const types = @import("text_layout_types.zig");
const interaction = @import("text_interaction.zig");
const run = @import("text_run_policy.zig");
pub const Result = struct {
    bounds: ?geometry.RectF,
    position: ?interaction.TextCaretPosition,
    len: usize,
    line_capacity_failed: bool,
};
pub const Query = struct {
    mode: u8,
    offset: usize = 0,
    affinity: interaction.TextCaretAffinity = .upstream,
    point: geometry.PointF = .{},
    range: interaction.TextRange = .{},
    prepared: []const types.TextLine = &.{},
    lines: []types.TextLine = &.{},
    selections: []interaction.TextSelectionRect = &.{},
};
inline fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
inline fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
inline fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("text query integer range"), .little);
}
inline fn setFloat(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn readRect(bytes: []const u8, at: usize) geometry.RectF {
    return .{ .x = float(bytes, at), .y = float(bytes, at + 4), .width = float(bytes, at + 8), .height = float(bytes, at + 12) };
}
fn lineValid(bytes: []const u8, at: usize, text_len: u32, glyph_count: u32) bool {
    return @as(u64, word(bytes, at)) + word(bytes, at + 4) <= text_len and
        (glyph_count == 0 or @as(u64, word(bytes, at + 8)) + word(bytes, at + 12) <= glyph_count) and
        word(bytes, at + 36) <= 1 and word(bytes, at + 44) <= 1 and
        (word(bytes, at + 36) == 0 or word(bytes, at + 40) <= word(bytes, at + 4)) and
        (word(bytes, at + 44) == 0 or word(bytes, at + 48) <= word(bytes, at + 12));
}
/// Validate every write index and capability before invoking host code.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 1024 or result.len != 1024 or result[3] < 1 or result[3] > 2 or
        !std.mem.eql(u8, request[0..3], result[0..3]) or !std.mem.eql(u8, request[4..80], result[4..80])) return false;
    if (word(result, 12) != request.len or word(result, 40) > request.len or
        @as(u64, word(result, 40)) + @as(u64, word(result, 44)) * 64 != request.len) return false;
    const source_len = word(request, 40);
    const text_len = word(request, 548);
    const glyph_count = word(request, 552);
    if (source_len != 1024 + @as(u64, glyph_count) * 32 + @as(u64, text_len) * 5 or
        word(request, 520) + @as(u64, text_len) != source_len or word(request, 524) != source_len or
        !std.mem.eql(u8, request[512..514], result[512..514]) or
        !std.mem.eql(u8, request[516..556], result[516..556]) or
        !std.mem.eql(u8, request[576..592], result[576..592])) return false;
    for ([_]usize{ 92, 100, 116, 184, 188, 248, 272, 308, 312 }) |at| if (word(result, at) > 1) return false;
    if (word(result, 124) > word(request, 8) or word(result, 96) > 14 or word(result, 104) > 14 or
        word(result, 316) > 64 or result[514] > 8 or result[515] > 2 or
        word(result, 556) > (if (result[514] == 0 and glyph_count > 0) glyph_count else text_len) or
        word(result, 564) > 1) return false;
    const reserved_zero = [_]u8{0} ** 72;
    if (!std.mem.eql(u8, result[440..512], &reserved_zero)) return false;
    if (result[3] == 2) return word(result, 80) == 0 and word(result, 84) == 0 and word(result, 92) == 0 and word(result, 100) == 0 and word(result, 304) <= text_len;
    if (word(result, 92) != 0) return false;
    return switch (word(result, 80)) {
        1 => blk: {
            if (word(result, 100) != 1) break :blk false;
            // A new portable subquery can replace the previous completed
            // line state. Immutable facts still match the caller's source.
            var expected: [512]u8 = undefined;
            @memcpy(&expected, result[512..1024]);
            expected[3] = 0;
            if (word(request, 100) != 0 and request[515] == 1 and word(request, 368) == word(result, 368)) @memcpy(&expected, request[512..1024]);
            break :blk run.resultValidFacts(&expected, source_len, 1024, result[512..1024]);
        },
        2 => request[2] == 0 and word(result, 100) == 0 and word(result, 84) < word(request, 8) and word(result, 124) == word(result, 84) + 1 and lineValid(result, 128, text_len, glyph_count),
        3 => request[2] == 1 and word(result, 100) == 0 and word(result, 84) < 64 and word(result, 124) == word(result, 84) + 1 and lineValid(result, 128, text_len, glyph_count),
        4 => (request[2] == 3 or request[2] == 6) and word(result, 100) == 0 and word(result, 84) < word(request, 8) and word(result, 124) == word(result, 84) + 1 and word(result, 320) <= word(result, 324) and word(result, 324) <= text_len,
        else => false,
    };
}
pub fn execute(policy: run.Policy, text: types.DrawText, options: types.TextLayoutOptions, query: Query) Result {
    const allocator = std.heap.page_allocator;
    const glyph_bytes = std.math.mul(usize, text.glyphs.len, 32) catch @panic("text query glyph capacity");
    const text_bytes = std.math.mul(usize, text.text.len, 5) catch @panic("text query byte capacity");
    const source_len = std.math.add(usize, std.math.add(usize, 1024, glyph_bytes) catch @panic("text query source capacity"), text_bytes) catch @panic("text query source capacity");
    const prepared_count = if (query.mode == 1) 64 else query.prepared.len;
    const total = std.math.add(usize, source_len, std.math.mul(usize, prepared_count, 64) catch @panic("text query line capacity")) catch @panic("text query packet capacity");
    if (total > std.math.maxInt(u32)) @panic("text query packet range");
    var small: [8192]u8 = undefined;
    const packet = if (total <= small.len) small[0..total] else allocator.alloc(u8, total) catch @panic("text query allocation");
    defer if (total > small.len) allocator.free(packet);
    @memset(packet, 0);
    run.initialize(packet[512..source_len], 512, 0, text, options, 0, 0, false, .{}, 0, 0);
    put(packet, 520, source_len - text.text.len);
    put(packet, 524, source_len);
    packet[0..6].* = .{ 55, 1, query.mode, 0, @intFromBool(text.text_layout != null), @intFromBool(query.mode >= 5) };
    put(packet, 8, if (query.mode == 0) query.lines.len else if (query.mode == 1) 64 else query.selections.len);
    put(packet, 12, total);
    put(packet, 16, @min(if (query.mode == 3 or query.mode == 6) query.range.start else query.offset, std.math.maxInt(u32)));
    put(packet, 20, @min(query.range.end, std.math.maxInt(u32)));
    put(packet, 24, @intFromEnum(query.affinity));
    setFloat(packet, 28, query.point.x);
    setFloat(packet, 32, query.point.y);
    put(packet, 40, source_len);
    put(packet, 44, prepared_count);
    var line_header: [512]u8 = @splat(0);
    for (query.prepared, 0..) |line, i| {
        run.writeLine(&line_header, line);
        @memcpy(packet[source_len + i * 64 ..][0..56], line_header[320..376]);
    }
    var result: [1024]u8 = undefined;
    var calls: usize = 0;
    const quota = std.math.mul(usize, total, 32) catch @panic("text query continuation range");
    while (true) {
        calls += 1;
        if (calls > quota) @panic("text query did not finish");
        @memset(&result, 0xa5);
        if (policy(packet, &result) != result.len or !resultValid(packet, &result)) @panic("invalid text query continuation");
        if (result[3] == 2) break;
        const action = word(&result, 80);
        const slot = word(&result, 84);
        @memcpy(packet[0..1024], &result);
        switch (action) {
            1 => run.supplyCapability(packet, packet[512..1024], 1024, text, options),
            2 => {
                @memcpy(line_header[320..376], packet[128..184]);
                query.lines[slot] = run.readLine(&line_header);
            },
            3 => @memcpy(packet[source_len + slot * 64 ..][0..56], packet[128..184]),
            4 => query.selections[slot] = .{ .range = .{ .start = word(packet, 320), .end = word(packet, 324) }, .rect = readRect(packet, 328) },
            else => unreachable,
        }
        put(packet, 92, 1);
    }
    const present = word(&result, 272) != 0;
    return .{
        .bounds = if (present) readRect(&result, 256) else null,
        .position = if (present and (query.mode == 4 or query.mode == 7)) .{ .offset = word(&result, 304), .affinity = @enumFromInt(word(&result, 308)) } else null,
        .len = word(&result, 124),
        .line_capacity_failed = word(&result, 312) != 0,
    };
}
