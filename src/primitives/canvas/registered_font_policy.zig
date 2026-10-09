//! Fixed copied font continuation. Native owns font bytes and buffers;
//! portable traversal and all measurement decisions belong to TypeScript.
const std = @import("std");
const metrics = @import("text_metrics.zig");
const font_ttf = @import("font_ttf.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { width, advances, ink };
// Supply the target arithmetic fact for the reference's f32 minNum/maxNum
// lowering: ARM64 resolves opposite zeros canonically; x86 keeps the later
// operand. Bits encode negative-zero results for min(+,-), min(-,+),
// max(+,-), max(-,+). TypeScript still owns all extrema decisions.
const zero_rules: u8 = switch (@import("builtin").cpu.arch) {
    .aarch64, .aarch64_be => 3,
    else => 5,
};
// The 128-byte continuation contains header/font facts [0,32), traversal
// [32,44), native glyph replies [44,72), action/cell/pen/ink [72,104),
// native text window [104,112), byte emission [112,124), and admission.
// Native reply ranges stay bit-identical across every policy call.
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn setFloat(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @bitCast(value));
}
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len != 128 or result.len != 128 or !std.mem.eql(u8, request[0..3], result[0..3]) or
        !std.mem.eql(u8, request[4..32], result[4..32]) or
        !std.mem.eql(u8, request[44..72], result[44..72]) or
        !std.mem.eql(u8, request[104..112], result[104..112]) or result[3] < 1 or result[3] > 2) return false;
    const length = word(request, 8);
    const first = word(result, 32);
    const last = word(result, 36);
    const cp = word(result, 40);
    const action = word(result, 72);
    const emit_first = word(result, 112);
    const emit_last = word(result, 116);
    if ((request[3] == 0 or word(request, 72) != 1) and cp != word(request, 40)) return false;
    if (first > length or last < first or last > length or word(result, 44) > 65535 or word(result, 52) > 2 or
        word(result, 84) > 1 or word(result, 104) > 4 or word(result, 124) > 1 or action > 4 or
        (result[3] == 2) != (action == 0) or (cp != 0xffffffff and (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)))) return false;
    if (emit_first > emit_last or emit_last > length or emit_last - emit_first > 4) return false;
    if (emit_last != 0 and (request[2] != @intFromEnum(Mode.advances) or emit_first != word(request, 32) or emit_last != first)) return false;
    if (action == 1 and first >= length) return false;
    if ((action == 2 or action == 3) and (cp == 0xffffffff or last == first)) return false;
    if (action == 4 and (word(result, 44) == 0 or request[2] != @intFromEnum(Mode.ink))) return false;
    return true;
}
pub const Result = struct { width: f32, accepted: bool, ink: metrics.TextInkMetrics };
pub fn measure(policy: Policy, registered_face: ?*const font_ttf.Face, font: u64, text: []const u8, size: f32, mode: Mode, advances: []f32) Result {
    if (mode == .advances and advances.len < text.len) @panic("registered font advance buffer too short");
    const face = registered_face orelse &font_ttf.geist_regular;
    var request: [128]u8 = @splat(0);
    var result: [128]u8 = undefined;
    request[0..5].* = .{ 62, 1, @intFromEnum(mode), 0, @intFromBool(registered_face != null) };
    request[5] = zero_rules;
    put(&request, 8, std.math.cast(u32, text.len) orelse @panic("registered font text too large"));
    std.mem.writeInt(u64, request[12..20], font, .little);
    setFloat(&request, 20, size);
    setFloat(&request, 24, face.units_per_em);
    setFloat(&request, 28, face.advance(0));
    var remaining: u64 = @as(u64, @intCast(text.len)) * 5 + 2;
    while (true) {
        if (remaining == 0) @panic("registered font continuation did not progress");
        remaining -= 1;
        @memset(&result, 0xa5);
        if (policy(&request, &result) != result.len or !resultValid(&request, &result)) @panic("invalid registered font decision");
        request = result;
        const emit_first: usize = word(&request, 112);
        const emit_last: usize = word(&request, 116);
        if (emit_last > emit_first) {
            advances[emit_first] = float(&request, 120);
            @memset(advances[emit_first + 1 .. emit_last], 0);
        }
        switch (word(&request, 72)) {
            0 => return .{ .width = float(&request, 80), .accepted = word(&request, 124) == 1, .ink = .{ .min_x = float(&request, 88), .max_x = float(&request, 92), .min_y = float(&request, 96), .max_y = float(&request, 100) } },
            1 => {
                const at: usize = word(&request, 32);
                const count = @min(4, text.len - at);
                put(&request, 104, @intCast(count));
                @memset(request[108..112], 0);
                @memcpy(request[108..][0..count], text[at..][0..count]);
            },
            2, 3 => {
                const glyph = face.glyphIndex(@intCast(word(&request, 40)));
                put(&request, 44, glyph);
                setFloat(&request, 48, if (glyph != 0) face.advance(glyph) else 0);
            },
            4 => {
                const bounds = face.glyphBounds(@intCast(word(&request, 44))) catch {
                    put(&request, 52, 2);
                    continue;
                };
                put(&request, 52, if (bounds != null) 1 else 0);
                if (bounds) |value| {
                    setFloat(&request, 56, value.x);
                    setFloat(&request, 60, value.y);
                    setFloat(&request, 64, value.width);
                    setFloat(&request, 68, value.height);
                }
            },
            else => unreachable,
        }
    }
}

test "registered font copied continuation bounds all capabilities and destination writes" {
    var request: [128]u8 = @splat(0);
    request[0..5].* = .{ 62, 1, 1, 0, 1 };
    put(&request, 8, 8);
    var result = request;
    result[3] = 1;
    put(&result, 72, 1);
    put(&result, 124, 1);
    try std.testing.expect(resultValid(&request, &result));
    for ([_]usize{ 0, 1, 2, 4, 8, 12, 16, 20, 24, 28, 44, 48, 52, 56, 60, 64, 68, 104, 108 }) |at| {
        var bad = result;
        bad[at] ^= 1;
        try std.testing.expect(!resultValid(&request, &bad));
    }
    request = result;
    put(&result, 36, 4);
    put(&result, 40, 65);
    put(&result, 72, 2);
    try std.testing.expect(resultValid(&request, &result));
    for ([_]u32{ 0xd800, 0xdfff, 0x110000, 0xffffffff }) |cp| {
        var bad = result;
        put(&bad, 40, cp);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    request = result;
    put(&result, 32, 4);
    put(&result, 72, 1);
    put(&result, 116, 4);
    try std.testing.expect(resultValid(&request, &result));
    for ([_]u32{ 5, 9, 0xffffffff }) |last| {
        var bad = result;
        put(&bad, 116, last);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    for ([_]usize{ 32, 36, 72, 84, 112, 124 }) |at| {
        var bad = result;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &bad));
    }
}
