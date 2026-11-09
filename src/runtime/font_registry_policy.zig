//! Copied font metadata; bytes, parsing and lifetime remain native capabilities.
const std = @import("std");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { register, lookup, unsupported_host, provider, repaint, refresh };
pub const Options = struct {
    id: u64 = 0,
    minimum_id: u64 = 64,
    length: usize = 0,
    budget: usize = 0,
    built_count: usize = 0,
    facts: u32 = 0,
};
pub const Program = struct {
    status: u32,
    selected: ?usize,
    action: u32,
    pub fn admit(self: Program) !void {
        switch (self.status) {
            0 => {},
            1 => return error.InvalidFontId,
            2 => return error.ReservedFontId,
            3 => return error.FontTooLarge,
            4 => return error.FontIdInUse,
            5 => return error.FontRegistryFull,
            6 => return error.FontHostRegistrationUnsupported,
            else => unreachable,
        }
    }
};
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
pub fn plan(policy: Policy, mode: Mode, ids: []const u64, count: usize, options: Options) Program {
    if (count > 8 or (mode == .register or mode == .lookup) and ids.len != count) @panic("font registry observation capacity");
    var request: [128]u8 = @splat(0);
    request[0..3].* = .{ 83, 1, @intFromEnum(mode) };
    put(&request, 4, @intCast(count));
    put(&request, 8, 8);
    put(&request, 12, options.facts);
    wide(&request, 16, options.id);
    wide(&request, 24, options.minimum_id);
    wide(&request, 32, options.length);
    wide(&request, 40, options.budget);
    put(&request, 48, @intCast(options.built_count));
    for (ids, 0..) |id, i| wide(&request, 64 + i * 8, id);
    var output: [16]u8 = @splat(0xa5);
    const length = policy(request[0 .. 64 + count * 8], &output);
    const status = word(&output, 4);
    const selected = word(&output, 8);
    const action = word(&output, 12);
    if (length != output.len or word(&output, 0) != 1 or status > 6) @panic("invalid compiled font registry shape");
    const maximum_action: u32 = switch (mode) {
        .register => 3,
        .lookup, .unsupported_host => 0,
        .provider => 2,
        .repaint, .refresh => 1,
    };
    if (action > maximum_action or (status != 0 and action != 0) or (status != 0 and mode != .register and mode != .unsupported_host) or (status == 6 and mode != .unsupported_host) or (mode == .unsupported_host and status != 0 and status != 6)) @panic("invalid compiled font registry admission");
    if (selected != std.math.maxInt(u32) and (mode != .register and mode != .lookup or selected >= 8 or selected > count or (selected == count and !(mode == .register and status == 0)))) @panic("invalid compiled font registry selection");
    if (mode == .register and status == 0 and (selected != count or (action != 1 and action != 3))) @panic("missing compiled font registration");
    return .{ .status = status, .selected = if (selected == std.math.maxInt(u32)) null else selected, .action = action };
}
pub fn registryIds(runtime: anytype, scratch: *[8]u64) []const u64 {
    for (runtime.canvas_font_entries[0..runtime.canvas_font_count], 0..) |entry, i| scratch[i] = entry.id;
    return scratch[0..runtime.canvas_font_count];
}
