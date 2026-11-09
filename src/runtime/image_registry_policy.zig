//! Copied metadata transport. Allocation, bytes and synchronization stay native.
const std = @import("std");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { register, encoded, lookup, remove, repaint, media_entry, media_equal, media_lookup, media_purge };
pub const Record = struct { id: u64 = 0, fingerprint: u64 = 0, flags: u32 = 0 };
pub const Options = struct {
    id: u64 = 0,
    width: usize = 0,
    height: usize = 0,
    length: usize = 0,
    budget: usize = 0,
    source_limit: u32 = 8 * 1024 * 1024,
    cursor: usize = 0,
    facts: u32 = 0,
    fingerprint: u64 = 0,
    previous_fingerprint: u64 = 0,
};
pub const Program = struct {
    status: u32,
    selected: ?usize,
    action: u32,
    next: ?usize,
    pub fn admit(self: Program) !void {
        switch (self.status) {
            0 => {},
            1 => return error.InvalidImageId,
            2 => return error.InvalidImageDimensions,
            3 => return error.ImageTooLarge,
            4 => return error.ImageRegistryFull,
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
pub fn plan(policy: Policy, mode: Mode, records: []const Record, capacity: usize, options: Options) Program {
    if (records.len > capacity or capacity > 32) @panic("image registry observation capacity");
    var request: [96 + 32 * 32]u8 = @splat(0);
    request[0..4].* = .{ 82, 1, @intFromEnum(mode), @bitSizeOf(usize) };
    put(&request, 4, @intCast(records.len));
    put(&request, 8, @intCast(capacity));
    put(&request, 12, @intCast(options.cursor));
    put(&request, 16, options.facts);
    put(&request, 20, options.source_limit);
    wide(&request, 24, options.id);
    wide(&request, 32, options.width);
    wide(&request, 40, options.height);
    wide(&request, 48, options.length);
    wide(&request, 56, if (mode == .media_equal) options.previous_fingerprint else options.budget);
    wide(&request, 64, options.fingerprint);
    for (records, 0..) |record, i| {
        const at = 96 + i * 32;
        wide(&request, at, record.id);
        wide(&request, at + 8, record.fingerprint);
        put(&request, at + 16, record.flags);
    }
    var output: [32]u8 = @splat(0xa5);
    const length = policy(request[0 .. 96 + records.len * 32], &output);
    const status = word(&output, 8);
    const selected = word(&output, 12);
    const action = word(&output, 16);
    const next = word(&output, 20);
    if (length != output.len or word(&output, 0) != 1 or word(&output, 4) != @intFromEnum(mode) or status > 4) @panic("invalid compiled image registry shape");
    for (output[24..]) |byte| if (byte != 0) @panic("invalid compiled image registry padding");
    const allowed: u32 = switch (mode) {
        .register, .encoded => 1,
        .lookup, .media_lookup => 0,
        .remove => 2,
        .repaint => 4,
        .media_entry => 1 | 8 | 16 | 32,
        .media_equal => 64,
        .media_purge => 128,
    };
    if (action & ~allowed != 0 or (status != 0 and action != 0) or (status != 0 and mode != .register and mode != .encoded)) @panic("invalid compiled image registry admission");
    if (selected != std.math.maxInt(u32) and (selected >= capacity or (selected >= records.len and !(selected == records.len and (mode == .register or (mode == .media_entry and action == 8)))))) @panic("invalid compiled image registry selection");
    if (next != std.math.maxInt(u32) and (mode != .media_entry or action != 16 or next >= records.len)) @panic("invalid compiled image registry continuation");
    if ((action == 2 or action == 4 or action == 32 or action == 128 or (mode == .register and status == 0)) and selected == std.math.maxInt(u32)) @panic("missing compiled image registry selection");
    return .{ .status = status, .selected = if (selected == std.math.maxInt(u32)) null else selected, .action = action, .next = if (next == std.math.maxInt(u32)) null else next };
}
pub fn imageRecords(runtime: anytype, scratch: []Record) []const Record {
    for (runtime.canvas_image_entries[0..runtime.canvas_image_count], 0..) |entry, i| scratch[i] = .{ .id = entry.id };
    return scratch[0..runtime.canvas_image_count];
}
pub fn mediaRecords(runtime: anytype, scratch: []Record) []const Record {
    for (runtime.media_surface_entries[0..runtime.media_surface_count], 0..) |entry, i| scratch[i] = .{ .id = entry.surface_id, .fingerprint = entry.fingerprint };
    return scratch[0..runtime.media_surface_count];
}
