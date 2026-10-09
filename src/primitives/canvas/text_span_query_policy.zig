//! Copied paragraph pages, explicit font capabilities and caller storage for
//! the portable rich-text query coordinator. No compiler allocation escapes.
const std = @import("std");
const geometry = @import("geometry");
const spans_model = @import("text_spans.zig");
const interaction = @import("text_interaction.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Query = struct {
    mode: u8,
    paragraph: []const u8 = "",
    spans: []const spans_model.TextSpan = &.{},
    clip_span: spans_model.TextSpan = .{},
    clip_run: spans_model.TextSpanRun = .{},
    min_x: f32 = 0,
    max_x: f32 = 0,
    point: geometry.PointF = .{},
    range: interaction.TextRange = .{},
    output: []interaction.TextSelectionRect = &.{},
};
pub const Result = struct { present: bool, first: usize, last: usize, x: f32, len: usize };
pub fn bounds(policy: Policy, layout: spans_model.TextSpanLayout, span_index: usize) ?geometry.RectF {
    var scratch = std.heap.stackFallback(4096, std.heap.page_allocator);
    const allocator = scratch.get();
    const total = std.math.add(usize, 24, std.math.mul(usize, layout.runs.len, 24) catch @panic("span bounds run capacity")) catch @panic("span bounds packet capacity");
    const packet = allocator.alloc(u8, total) catch @panic("span bounds allocation");
    defer allocator.free(packet);
    @memset(packet, 0);
    packet[0..2].* = .{ 57, 1 };
    put(packet, 4, layout.runs.len);
    std.mem.writeInt(u64, packet[8..16], span_index, .little);
    setFloat(packet, 16, layout.line_height);
    for (layout.runs, 0..) |run, i| {
        const at = 24 + i * 24;
        std.mem.writeInt(u64, packet[at..][0..8], run.span_index, .little);
        std.mem.writeInt(u64, packet[at + 8 ..][0..8], run.line_index, .little);
        setFloat(packet, at + 16, run.x);
        setFloat(packet, at + 20, run.width);
    }
    var result: [20]u8 = @splat(0xa5);
    if (policy(packet, &result) != result.len or word(&result, 0) > 1) @panic("invalid span bounds result");
    return if (word(&result, 0) != 0) rect(&result, 4) else null;
}
inline fn word(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
inline fn float(b: []const u8, at: usize) f32 {
    return @bitCast(word(b, at));
}
inline fn put(b: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, b[at..][0..4], std.math.cast(u32, value) orelse @panic("span query integer range"), .little);
}
inline fn setFloat(b: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, b[at..][0..4], @bitCast(value), .little);
}
fn offset(source: []const u8, slice: []const u8) ?usize {
    const base = @intFromPtr(source.ptr);
    const ptr = @intFromPtr(slice.ptr);
    if (ptr < base or ptr - base > source.len or slice.len > source.len - (ptr - base)) return null;
    return ptr - base;
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .{ .x = float(b, at), .y = float(b, at + 4), .width = float(b, at + 8), .height = float(b, at + 12) };
}
/// Admission precedes every capability invocation and caller-storage write.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 512 or result.len != 512 or result[3] < 1 or result[3] > 2 or
        !std.mem.eql(u8, request[0..3], result[0..3]) or !std.mem.eql(u8, request[4..80], result[4..80]) or
        word(result, 12) != request.len or word(result, 96) != 0 or word(result, 104) > 1 or word(result, 112) > 1 or
        word(result, 152) > 160 or word(result, 156) > 160 or word(result, 164) > word(request, 8)) return false;
    const reserved_zero = [_]u8{0} ** 168;
    if (!std.mem.eql(u8, result[344..512], &reserved_zero)) return false;
    const mode = request[2];
    const source_len = if (mode == 0) word(request, 40) else word(request, 20);
    if (result[3] == 2) return word(result, 80) == 0 and (word(result, 112) == 0 or
        (word(result, 116) <= source_len and (mode == 1 or (word(result, 116) <= word(result, 120) and word(result, 120) <= source_len))));
    const slot = word(result, 84);
    const first = word(result, 88);
    const last = word(result, 92);
    const phase = word(result, 108);
    const expected_action: u32 = switch (mode) {
        0 => switch (phase) {
            1 => 2,
            10, 12, 15, 16, 19, 20 => 3,
            else => return false,
        },
        1 => switch (phase) {
            21, 22 => 1,
            25 => 3,
            28 => 4,
            else => return false,
        },
        2 => switch (phase) {
            31, 33, 35, 37, 39 => 1,
            41, 42 => 3,
            43, 45 => 5,
            else => return false,
        },
        else => return false,
    };
    if (word(result, 80) != expected_action) return false;
    return switch (word(result, 80)) {
        1 => mode != 0 and first == 0 and last == 0 and slot <= word(request, 144),
        2 => mode == 0 and slot == 0 and first == 0 and last == word(request, 40),
        3 => blk: {
            const count = if (mode == 0) 1 else word(request, 152);
            if (slot >= count or slot >= 160 or first != 0) break :blk false;
            const at = word(request, 32) + @as(usize, slot) * 32;
            if (at + 32 > request.len) break :blk false;
            break :blk last <= word(request, at + 8);
        },
        4 => blk: {
            if (mode != 1 or slot >= word(request, 28) or first > last) break :blk false;
            const at = word(request, 24) + @as(usize, slot) * 16;
            if (at + 16 > request.len) break :blk false;
            break :blk last <= word(request, at + 4);
        },
        5 => mode == 2 and slot < word(request, 8) and slot < word(result, 164) and first == 0 and last == 0 and
            word(result, 116) <= word(result, 120) and word(result, 120) <= source_len,
        else => false,
    };
}
fn writeRun(packet: []u8, query: Query, spans: []const spans_model.TextSpan, run: spans_model.TextSpanRun, slot: usize) void {
    const at = word(packet, 32) + slot * 32;
    if (run.span_index >= spans.len) @panic("span query source run index");
    const span_at = word(packet, 24) + run.span_index * 16;
    const source_offset = offset(spans[run.span_index].text, run.text);
    const paragraph_range = spans_model.textSpanRunParagraphRange(query.paragraph, run);
    put(packet, at, run.span_index);
    put(packet, at + 4, if (query.mode == 0) word(packet, 32) + 160 * 32 else word(packet, span_at) + (source_offset orelse @panic("span query run source alias")));
    put(packet, at + 8, run.text.len);
    put(packet, at + 12, run.line_index);
    setFloat(packet, at + 16, run.x);
    setFloat(packet, at + 20, run.width);
    put(packet, at + 24, if (paragraph_range) |r| r.start else 0);
    put(packet, at + 28, @intFromBool(paragraph_range != null));
}
pub fn execute(policy: Policy, options: spans_model.TextSpanLayoutOptions, query: Query) Result {
    const spans: []const spans_model.TextSpan = if (query.mode == 0) &[_]spans_model.TextSpan{query.clip_span} else query.spans;
    const allocator = std.heap.page_allocator;
    const clip_len = if (query.mode == 0) query.clip_run.text.len else 0;
    const run_at = std.math.add(usize, 512, std.math.mul(usize, spans.len, 16) catch @panic("span query span capacity")) catch @panic("span query source capacity");
    const advances_at = std.math.add(usize, run_at + 160 * 32, clip_len) catch @panic("span query clip capacity");
    const paragraph_at = std.math.add(usize, advances_at, std.math.mul(usize, clip_len, 4) catch @panic("span query advances capacity")) catch @panic("span query packet capacity");
    var total = std.math.add(usize, paragraph_at, query.paragraph.len) catch @panic("span query paragraph capacity");
    for (spans) |span| total = std.math.add(usize, total, span.text.len) catch @panic("span query source capacity");
    if (total > std.math.maxInt(u32)) @panic("span query packet range");
    var small: [8192]u8 = undefined;
    const packet = if (total <= small.len) small[0..total] else allocator.alloc(u8, total) catch @panic("span query allocation");
    defer if (total > small.len) allocator.free(packet);
    @memset(packet, 0);
    packet[0..4].* = .{ 56, 1, query.mode, 0 };
    put(packet, 8, query.output.len);
    put(packet, 12, total);
    put(packet, 16, paragraph_at);
    put(packet, 20, query.paragraph.len);
    put(packet, 24, 512);
    put(packet, 28, spans.len);
    put(packet, 32, run_at);
    put(packet, 36, advances_at);
    put(packet, 40, clip_len);
    put(packet, 44, @min(query.range.start, std.math.maxInt(u32)));
    put(packet, 48, @min(query.range.end, std.math.maxInt(u32)));
    setFloat(packet, 52, query.point.x);
    setFloat(packet, 56, query.point.y);
    setFloat(packet, 60, query.clip_run.width);
    setFloat(packet, 64, query.min_x);
    setFloat(packet, 68, query.max_x);
    setFloat(packet, 72, options.max_width);
    @memcpy(packet[paragraph_at..][0..query.paragraph.len], query.paragraph);
    var at = paragraph_at + query.paragraph.len;
    for (spans, 0..) |span, s| {
        const base = 512 + s * 16;
        const alias = offset(query.paragraph, span.text);
        put(packet, base, at);
        put(packet, base + 4, span.text.len);
        put(packet, base + 8, alias orelse 0);
        put(packet, base + 12, @intFromBool(alias != null));
        @memcpy(packet[at..][0..span.text.len], span.text);
        at += span.text.len;
    }
    var runs: [160]spans_model.TextSpanRun = undefined;
    var initialized_runs: usize = 0;
    if (query.mode == 0) {
        @memcpy(packet[run_at + 160 * 32 ..][0..clip_len], query.clip_run.text);
        var run = query.clip_run;
        run.span_index = 0;
        run.line_index = 0;
        runs[0] = run;
        writeRun(packet, query, spans, run, 0);
        initialized_runs = 1;
    }
    var result: [512]u8 = undefined;
    const quota = std.math.mul(usize, total, 64) catch @panic("span query continuation range");
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > quota) @panic("span query did not finish");
        @memset(&result, 0xa5);
        if (policy(packet, &result) != result.len or !resultValid(packet, &result)) @panic("invalid span query continuation");
        if (result[3] == 2) break;
        const action = word(&result, 80);
        const slot = word(&result, 84);
        const first = word(&result, 88);
        const last = word(&result, 92);
        @memcpy(packet[0..512], &result);
        switch (action) {
            1 => {
                // This invokes the existing portable paragraph planner. The
                // host only materializes its bounded caller-owned scratch page.
                const layout = spans_model.layoutTextSpansFromLine(spans, options, slot, &runs);
                put(packet, 144, layout.line_count);
                setFloat(packet, 148, layout.line_height);
                put(packet, 152, layout.runs.len);
                initialized_runs = @max(initialized_runs, layout.runs.len);
                for (layout.runs, 0..) |run, i| writeRun(packet, query, spans, run, i);
            },
            2 => if (spans_model.spanSliceAdvances(query.clip_span, query.clip_run.text, options, query.clip_run.font_id, query.clip_run.size)) |advances| {
                for (advances, 0..) |value, i| setFloat(packet, advances_at + i * 4, value);
                put(packet, 104, 1);
            },
            3 => {
                if (slot >= initialized_runs or last > runs[slot].text.len) @panic("span query unwritten run capability");
                setFloat(packet, 100, spans_model.measureSpanSlice(spans[runs[slot].span_index], runs[slot].text[0..last], options));
            },
            4 => setFloat(packet, 100, spans_model.measureSpanSlice(spans[slot], spans[slot].text[first..last], options)),
            5 => query.output[slot] = .{ .range = .{ .start = word(packet, 116), .end = word(packet, 120) }, .rect = rect(packet, 128) },
            else => unreachable,
        }
        put(packet, 96, 1);
    }
    return .{ .present = word(&result, 112) != 0, .first = word(&result, 116), .last = word(&result, 120), .x = float(&result, 128), .len = word(&result, 164) };
}
