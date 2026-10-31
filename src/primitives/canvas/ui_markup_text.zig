//! Copied byte transport and arena/borrow capabilities for compiled markup
//! text. Programs own byte decisions; native preserves allocation ordering,
//! original integer conversion, and aliases into the caller's input storage.
const std = @import("std");
const Policy = *const fn ([]const u8, []u8) usize;
const chunk_size = 256;

fn request(mode: u8) [32 + chunk_size]u8 {
    var input: [32 + chunk_size]u8 = @splat(0);
    input[0..3].* = .{ 103, 1, mode };
    return input;
}

fn run(owner: Policy, input: []const u8, output: *[16 + chunk_size]u8) []const u8 {
    const size = owner(input, output);
    if (size < 16 or size > output.len or output[0] != 103 or output[1] != 1 or output[2] != input[2] or
        output[3] > 1 or (output[3] != 0 and !(input[2] >= 5 and input[2] <= 7)) or
        size != 16 + @as(usize, std.mem.readInt(u16, output[8..10], .little)) or
        std.mem.readInt(u16, output[10..12], .little) != 0 or std.mem.readInt(u32, output[12..16], .little) != 0)
        @panic("invalid markup text program");
    return output[16..size];
}

pub fn map(owner: Policy, mode: u8, text: []const u8, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    // Exactly the reference dupe, including empty strings. Transport chunks
    // add no arena allocation and impose no maximum on an authored string.
    const out = try arena.dupe(u8, text);
    var at: usize = 0;
    while (true) {
        const len = @min(chunk_size, text.len - at);
        var input = request(mode);
        std.mem.writeInt(u16, input[4..6], @intCast(len), .little);
        @memcpy(input[32..][0..len], text[at..][0..len]);
        var output: [16 + chunk_size]u8 = undefined;
        const bytes = run(owner, input[0 .. 32 + len], &output);
        if (bytes.len != len or std.mem.readInt(u32, output[4..8], .little) != 0) @panic("invalid markup case program");
        @memcpy(out[at..][0..len], bytes);
        at += len;
        if (at == text.len) break;
    }
    return out;
}

fn cuts(owner: Policy, text: []const u8) [2]usize {
    var input = request(2);
    std.mem.writeInt(u16, input[4..6], @intCast(text.len), .little);
    @memcpy(input[32..][0..text.len], text);
    var output: [16 + chunk_size]u8 = undefined;
    const bytes = run(owner, input[0 .. 32 + text.len], &output);
    const first = std.mem.readInt(u16, output[4..6], .little);
    const last = std.mem.readInt(u16, output[6..8], .little);
    if (bytes.len != 0 or first > last or last > text.len) @panic("invalid markup trim program");
    return .{ first, last };
}

pub fn trim(owner: Policy, text: []const u8) []const u8 {
    var first: usize = 0;
    var last = text.len;
    while (first < last) {
        const end = first + @min(chunk_size, last - first);
        const range = cuts(owner, text[first..end]);
        first += range[0];
        if (first != end) break;
    }
    while (last > first) {
        const start = last - @min(chunk_size, last - first);
        const range = cuts(owner, text[start..last]);
        last = if (range[0] == last - start) start else start + range[1];
        if (last != start) break;
    }
    // For all-whitespace input the reference returns its end pointer.
    return text[first..last];
}

pub fn decimal(owner: Policy, mode: u8, value: i64, width: usize, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buffer: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutOfMemory;
    var input = request(mode);
    input[3] = @intCast(width);
    std.mem.writeInt(u16, input[4..6], @intCast(digits.len), .little);
    @memcpy(input[32..][0..digits.len], digits);
    var output: [16 + chunk_size]u8 = undefined;
    const bytes = run(owner, input[0 .. 32 + digits.len], &output);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (mode == 3) {
        if (bytes.len > 26 or std.mem.readInt(u32, output[4..8], .little) != 0) @panic("invalid markup grouping program");
        // The reference appends sign, separators and digits individually.
        for (bytes) |byte| try out.append(arena, byte);
    } else {
        const sign = output[4];
        const zeros = output[5];
        if (sign > 1 or zeros > 6 or output[7] != 0 or bytes.len != @as(usize, sign) + output[6] or bytes.len > 20)
            @panic("invalid markup padding program");
        if (sign == 1) try out.append(arena, bytes[0]);
        if (zeros > 0) try out.appendNTimes(arena, '0', zeros);
        try out.appendSlice(arena, bytes[sign..]);
    }
    return out.items;
}

pub fn timestamp(owner: Policy, mode: u8, seconds: i64, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    var input = request(mode);
    // Every i64 second maps to a day in [-106751991167301,106751991167300],
    // exactly representable as f64. No original timestamp crosses as f64.
    const day: f64 = @floatFromInt(@divFloor(seconds, 86_400));
    std.mem.writeInt(u64, input[16..24], @bitCast(day), .little);
    std.mem.writeInt(u32, input[24..28], @intCast(@mod(seconds, 86_400)), .little);
    var output: [16 + chunk_size]u8 = undefined;
    const bytes = run(owner, input[0..32], &output);
    if (std.mem.readInt(u32, output[4..8], .little) != 0) @panic("invalid markup calendar metadata");
    if (output[3] == 1) {
        if (bytes.len != 0) @panic("invalid markup calendar failure");
        return null;
    }
    const expected: usize = if (mode == 5) 10 else if (mode == 6) 5 else 16;
    if (bytes.len != expected) @panic("invalid markup calendar length");
    return try arena.dupe(u8, bytes);
}

pub fn plural(owner: Policy, count: i64) usize {
    var input = request(8);
    std.mem.writeInt(i64, input[16..24], count, .little);
    var output: [16 + chunk_size]u8 = undefined;
    const bytes = run(owner, input[0..32], &output);
    if (bytes.len != 0 or (output[4] != 1 and output[4] != 2) or output[5] != 0 or output[6] != 0 or output[7] != 0)
        @panic("invalid markup plural program");
    return output[4];
}
