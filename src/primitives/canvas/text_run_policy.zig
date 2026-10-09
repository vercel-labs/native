//! Copied transport for portable ordinary text planning. The host executes
//! requested font capabilities and copies results into caller-owned state.
const std = @import("std");
const types = @import("text_layout_types.zig");
const metrics = @import("text_metrics.zig");
const cache = @import("text_measure_cache.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Result = struct {
    line: ?types.TextLine,
    cursor: usize,
    index: usize,
    finished: bool,
    scalar: f32,
    offset: usize,
};
pub fn capabilityKind(mode: u8, phase: u32, draw_measure: bool) ?u32 {
    return switch (mode) {
        0 => switch (phase) {
            1, 12 => 3,
            3, 14, 17, 22, 32 => 1,
            11, 15, 24 => 5,
            19, 21 => 2,
            31 => 4,
            else => null,
        },
        1 => switch (phase) {
            1 => 3,
            3 => 1,
            else => null,
        },
        2 => if (phase == 40) 1 else null,
        3 => switch (phase) {
            42 => if (draw_measure) 1 else 2,
            43 => 1,
            else => null,
        },
        4 => switch (phase) {
            31 => 4,
            32 => 1,
            else => null,
        },
        5 => if (phase == 50) 1 else null,
        6 => switch (phase) {
            60 => 6,
            61 => 7,
            else => null,
        },
        8 => switch (phase) {
            50 => 1,
            62 => 6,
            else => null,
        },
        else => null,
    };
}
inline fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
inline fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
inline fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("text run integer range"), .little);
}
inline fn setFloat(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
pub fn writeLine(bytes: []u8, line: types.TextLine) void {
    put(bytes, 320, line.text_start);
    put(bytes, 324, line.text_len);
    put(bytes, 328, line.glyph_start);
    put(bytes, 332, line.glyph_len);
    setFloat(bytes, 336, line.bounds.x);
    setFloat(bytes, 340, line.bounds.y);
    setFloat(bytes, 344, line.bounds.width);
    setFloat(bytes, 348, line.bounds.height);
    setFloat(bytes, 352, line.baseline);
    put(bytes, 356, @intFromBool(line.elided_text_len != null));
    put(bytes, 360, line.elided_text_len orelse 0);
    put(bytes, 364, @intFromBool(line.elided_glyph_len != null));
    put(bytes, 368, line.elided_glyph_len orelse 0);
    setFloat(bytes, 372, line.ellipsis_advance);
}
pub fn readLine(bytes: []const u8) types.TextLine {
    return .{
        .text_start = word(bytes, 320),
        .text_len = word(bytes, 324),
        .glyph_start = word(bytes, 328),
        .glyph_len = word(bytes, 332),
        .bounds = .{ .x = float(bytes, 336), .y = float(bytes, 340), .width = float(bytes, 344), .height = float(bytes, 348) },
        .baseline = float(bytes, 352),
        .elided_text_len = if (word(bytes, 356) != 0) word(bytes, 360) else null,
        .elided_glyph_len = if (word(bytes, 364) != 0) word(bytes, 368) else null,
        .ellipsis_advance = float(bytes, 372),
    };
}
/// Reject altered source, invalid ranges, malformed result flags and
/// unrecognized capability continuations before any host callback runs.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    return resultValidFacts(request[0..@min(request.len, 512)], request.len, 512, result);
}
pub fn resultValidFacts(request: []const u8, source_len: usize, facts_start: usize, result: []const u8) bool {
    if (request.len < 512 or result.len != 512 or result[3] < 1 or result[3] > 2 or
        !std.mem.eql(u8, request[0..3], result[0..3]) or !std.mem.eql(u8, request[4..80], result[4..80])) return false;
    const text_len = word(request, 36);
    const glyph_count = word(request, 40);
    const advance_at: u64 = facts_start + @as(u64, glyph_count) * 32;
    const text_at: u64 = advance_at + @as(u64, text_len) * 4;
    if (text_at > source_len or word(request, 8) != text_at or word(request, 12) != source_len or text_at + text_len != source_len) return false;
    const reserved_zero = [_]u8{0} ** 136;
    if (!std.mem.eql(u8, result[376..512], &reserved_zero)) return false;
    if (word(result, 296) > 1 or word(result, 300) > 1 or word(result, 356) > 1 or word(result, 364) > 1) return false;
    if (request[2] == 2 or request[2] == 3) if (!std.mem.eql(u8, request[320..384], result[320..384])) return false;
    if (result[3] == 2) {
        if (word(result, 96) != 0 or word(result, 100) != 0 or word(result, 112) != 0) return false;
        if (request[2] == 0 and word(result, 300) != 0) {
            if (@as(u64, word(result, 320)) + word(result, 324) > text_len or
                (glyph_count > 0 and @as(u64, word(result, 328)) + word(result, 332) > glyph_count) or
                word(result, 292) != @as(u64, word(request, 48)) + 1 or
                word(result, 288) > (if (glyph_count > 0) glyph_count else text_len) or
                (word(result, 356) != 0 and word(result, 360) > word(result, 324)) or
                (word(result, 364) != 0 and word(result, 368) > word(result, 332))) return false;
        }
        if ((request[2] == 1 or request[2] == 3) and word(result, 308) > text_len) return false;
        return true;
    }
    if (word(result, 112) != 0 or word(result, 104) > word(result, 108) or word(result, 108) > text_len) return false;
    const expected = capabilityKind(request[2], word(result, 96), request[7] & 2 != 0) orelse return false;
    if (word(result, 100) != expected) return false;
    if ((expected == 3 or expected == 4) and (word(result, 104) != 0 or word(result, 108) != text_len)) return false;
    if ((expected == 5 or expected == 7) and (word(result, 104) != 0 or word(result, 108) != 0)) return false;
    if (request[3] == 1 and std.mem.eql(u8, request[96..112], result[96..112]) and std.mem.eql(u8, request[144..512], result[144..512])) return false;
    return true;
}
pub fn execute(
    policy: Policy,
    mode: u8,
    text: types.DrawText,
    options: types.TextLayoutOptions,
    cursor: usize,
    index: usize,
    finished: bool,
    line: types.TextLine,
    offset: usize,
    x: f32,
) Result {
    const allocator = std.heap.page_allocator;
    const glyph_bytes = std.math.mul(usize, text.glyphs.len, 32) catch @panic("text run glyph capacity");
    const advance_at = std.math.add(usize, 512, glyph_bytes) catch @panic("text run packet capacity");
    const advance_bytes = std.math.mul(usize, text.text.len, 4) catch @panic("text run advance capacity");
    const text_at = std.math.add(usize, advance_at, advance_bytes) catch @panic("text run packet capacity");
    const total = std.math.add(usize, text_at, text.text.len) catch @panic("text run text capacity");
    if (total > std.math.maxInt(u32)) @panic("text run packet range");
    var small_request: [4096]u8 = undefined;
    const request = if (total <= small_request.len) small_request[0..total] else allocator.alloc(u8, total) catch @panic("text run request allocation");
    defer if (total > small_request.len) allocator.free(request);
    var result: [512]u8 = undefined;
    initialize(request, 512, mode, text, options, cursor, index, finished, line, offset, x);
    const quota = std.math.mul(usize, total, 8) catch @panic("text run continuation range");
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > quota) @panic("text run continuation did not finish");
        @memset(&result, 0xa5);
        if (policy(request, &result) != result.len or !resultValid(request, &result)) @panic("invalid text run continuation");
        if (result[3] == 2) break;
        @memcpy(request[0..512], &result);
        supplyCapability(request, request[0..512], 512, text, options);
    }
    return .{
        .line = if (word(&result, 300) != 0 or mode == 4) readLine(&result) else null,
        .cursor = word(&result, 288),
        .index = word(&result, 292),
        .finished = word(&result, 296) != 0,
        .scalar = float(&result, 304),
        .offset = word(&result, 308),
    };
}

pub fn initialize(request: []u8, facts_start: usize, mode: u8, text: types.DrawText, options: types.TextLayoutOptions, cursor: usize, index: usize, finished: bool, line: types.TextLine, offset: usize, x: f32) void {
    const text_at = facts_start + text.glyphs.len * 32 + text.text.len * 4;
    const draw_measure = if (text.text_layout) |o| o.measure orelse text.measure else text.measure;
    @memset(request, 0);
    request[0..8].* = .{ 54, 1, mode, 0, @intFromEnum(options.wrap), @intFromEnum(options.alignment), @intFromEnum(options.overflow), @as(u8, @intFromBool(options.measure != null)) | (@as(u8, @intFromBool(draw_measure != null)) << 1) };
    put(request, 8, text_at);
    put(request, 12, request.len);
    setFloat(request, 16, text.size);
    setFloat(request, 20, text.origin.x);
    setFloat(request, 24, text.origin.y);
    setFloat(request, 28, options.max_width);
    setFloat(request, 32, options.line_height);
    put(request, 36, text.text.len);
    put(request, 40, text.glyphs.len);
    put(request, 44, cursor);
    put(request, 48, index);
    put(request, 52, @intFromBool(finished));
    put(request, 56, @min(offset, std.math.maxInt(u32)));
    setFloat(request, 60, x);
    std.mem.writeInt(u64, request[64..72], text.font_id, .little);
    writeLine(request, line);
    for (text.glyphs, 0..) |glyph, n| {
        const at = facts_start + n * 32;
        setFloat(request, at, glyph.x);
        setFloat(request, at + 4, glyph.y);
        setFloat(request, at + 8, glyph.advance);
        put(request, at + 12, glyph.text_start);
        put(request, at + 16, glyph.text_len);
    }
    @memcpy(request[text_at..], text.text);
}

pub fn supplyCapability(packet: []u8, header: []u8, facts_start: usize, text: types.DrawText, options: types.TextLayoutOptions) void {
    const draw_measure = if (text.text_layout) |o| o.measure orelse text.measure else text.measure;
    const advance_at = facts_start + text.glyphs.len * 32;
    const kind = word(header, 100);
    const start = word(header, 104);
    const end = word(header, 108);
    const phase = word(header, 96);
    switch (kind) {
        1 => {
            const measure = if (phase == 32 or phase == 40 or phase == 42 or phase == 43 or phase == 50) draw_measure else options.measure;
            setFloat(header, 116, metrics.measureTextWidthForFontWithPolicy(measure, options.text_run_policy, text.font_id, text.text[start..end], text.size));
        },
        2 => setFloat(header, 116, metrics.estimateTextAdvanceForBytesWithPolicy(options.text_run_policy, text.font_id, text.text[start..end], text.size)),
        3, 4 => {
            const provider = if (kind == 3) options.measure else draw_measure;
            const advances = if (provider) |p| if (kind == 3) cache.textRunAdvancesWithPolicy(p, options.text_run_policy, text.font_id, text.size, text.text) else cache.cachedTextRunAdvancesWithPolicy(p, options.text_run_policy, text.font_id, text.size, text.text) else null;
            put(header, 120, @intFromBool(advances != null));
            if (advances) |values| for (values, 0..) |value, n| setFloat(packet, advance_at + n * 4, value);
        },
        5 => setFloat(header, 116, metrics.measureTextWidthForFontWithPolicy(options.measure, options.text_run_policy, text.font_id, "\u{2026}", text.size)),
        6, 7 => {
            const ink = if (draw_measure) |p| metrics.measureTextInkWithPolicy(p, options.text_run_policy, text.font_id, text.size, if (kind == 7) "\u{2026}" else text.text[start..end]) else null;
            put(header, 120, @intFromBool(ink != null));
            if (ink) |value| {
                setFloat(header, 124, value.min_x);
                setFloat(header, 128, value.min_y);
                setFloat(header, 132, value.max_x);
                setFloat(header, 136, value.max_y);
            }
        },
        else => unreachable,
    }
    put(header, 112, 1);
}
