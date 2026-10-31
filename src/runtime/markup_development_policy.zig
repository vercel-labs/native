//! Borrowed native facts and copied markup-development programs.
const std = @import("std");
const canvas = @import("canvas");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Action = enum(u8) { end, observed_hash, diagnostic, canonicalize, adopt_root, provenance, rebuild_root, restore_fragment, adopt_fragment, switch_arena, clear_diagnostic, adopted_fragment };
pub const Request = struct {
    writer: *std.Io.Writer,
    pub fn begin(writer: *std.Io.Writer, stage: u8) !Request {
        try writer.writeAll(&.{ 32, 1, stage, 0 });
        return .{ .writer = writer };
    }
    pub fn byte(self: Request, value: u8) !void {
        try self.writer.writeByte(value);
    }
    pub fn word(self: Request, value: usize) !void {
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, @intCast(value), .little);
        try self.writer.writeAll(&raw);
    }
    pub fn wide(self: Request, value: u64) !void {
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, value, .little);
        try self.writer.writeAll(&raw);
    }
    pub fn blob(self: Request, value: []const u8) !void {
        try self.word(value.len);
        try self.writer.writeAll(value);
    }
};
pub fn evaluate(callback: *const fn ([]const u8, []u8) usize, input: []const u8, output: []u8) []const u8 {
    const size = callback(input, output);
    if (size > output.len) @panic("invalid markup development result size");
    return output[0..size];
}
pub fn word(result: []const u8, at: usize) u32 {
    if (at > result.len or result.len - at < 4) @panic("short markup development result");
    return std.mem.readInt(u32, result[at..][0..4], .little);
}
pub fn watch(callback: *const fn ([]const u8, []u8) usize, root: bool, view: bool, zero_hash: bool, fragments: bool, count: usize, capacity: usize) [4]u32 {
    var input: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    const r = Request.begin(&writer, 0) catch unreachable;
    for ([_]bool{ root, view, zero_hash, fragments }) |value| r.byte(@intFromBool(value)) catch unreachable;
    r.word(count) catch unreachable;
    r.word(capacity) catch unreachable;
    var output: [16]u8 = undefined;
    const result = evaluate(callback, writer.buffered(), &output);
    if (result.len != 16 or word(result, 0) > 1 or word(result, 4) > 1 or word(result, 8) > @min(count, capacity) or word(result, 12) > 1) @panic("invalid markup watch program");
    return .{ word(result, 0), word(result, 4), word(result, 8), word(result, 12) };
}
pub fn reload(callback: *const fn ([]const u8, []u8) usize, kind: u8, changed: bool, failed: bool, diagnostic: bool, baseline: bool, installed: bool) [12]u8 {
    const input = [_]u8{ 32, 1, 1, 0, kind, @intFromBool(changed), @intFromBool(failed), @intFromBool(diagnostic), @intFromBool(baseline), @intFromBool(installed) };
    var output: [12]u8 = undefined;
    const result = evaluate(callback, &input, &output);
    if (result.len != output.len) @panic("invalid markup reload extent");
    var ended = false;
    for (result) |value| {
        if (value == 0) {
            ended = true;
            continue;
        }
        if (ended or value >= std.meta.fields(Action).len or failed and value != 1 and value != 2 or !failed and value == 2 or kind != 2 and value >= 7 or kind == 2 and value >= 4 and value <= 6 or value == 6 and !installed or value == 7 and !baseline or value == 8 and baseline) @panic("invalid markup reload action");
    }
    if (!ended) @panic("unterminated markup reload program");
    return output;
}
pub fn storage(callback: *const fn ([]const u8, []u8) usize, stage: u8, count: usize, capacity: usize, first: usize, second: usize, path_capacity: usize) [3]u32 {
    var input: [24]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    const r = Request.begin(&writer, stage) catch unreachable;
    for ([_]usize{ count, capacity, @min(first, path_capacity), @min(second, path_capacity), path_capacity }) |value| r.word(value) catch unreachable;
    var output: [12]u8 = undefined;
    const result = evaluate(callback, writer.buffered(), &output);
    if (result.len != 12 or word(result, 0) > 1 or word(result, 4) > @min(first, path_capacity) or word(result, 8) > @min(second, path_capacity)) @panic("invalid markup storage bounds");
    return .{ word(result, 0), word(result, 4), word(result, 8) };
}
pub fn stripPrefix(callback: *const fn ([]const u8, []u8) usize, prefix: []const u8, path: []const u8) []const u8 {
    // Resolver paths are bounded. One excess prefix byte preserves a
    // non-match without allocating or changing loader failure ownership.
    var input: [2 * canvas.ui_markup.max_import_path_len + 16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    const r = Request.begin(&writer, 3) catch unreachable;
    r.blob(prefix[0..@min(prefix.len, path.len + 1)]) catch unreachable;
    r.blob(path) catch unreachable;
    var output: [4]u8 = undefined;
    const result = evaluate(callback, writer.buffered(), &output);
    if (result.len != 4) @panic("invalid markup path extent");
    const start = word(result, 0);
    if (start > path.len or start != 0 and (prefix.len >= path.len or start != prefix.len + 1)) @panic("invalid markup path bounds");
    return path[start..];
}
