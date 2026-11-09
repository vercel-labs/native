//! Raw copied window observations; storage and OS capabilities stay native.
const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { begin, finish, focus, keyboard, host, replay, focused_index };
pub const Verb = enum(u8) { close, hide, show, focus, minimize };
pub const Outcome = enum(u32) { success, failed, window_not_found };
pub const Options = struct {
    id: u64 = 0,
    value: bool = false,
    app_active: ?bool = null,
    cursor: usize = 0,
    target: usize = 0,
    saved: u32 = 0,
    outcome: Outcome = .success,
    label: []const u8 = "",
    frame: geometry.RectF = .zero(),
    variant: u8 = 0,
};
pub const Program = struct {
    status: u32,
    selected: ?usize,
    decisions: u32,
    mask: u32,
    flags: u32,
    active: bool,
    frame: geometry.RectF,
    pub fn has(self: Program, bit: u32) bool {
        return self.decisions & bit != 0;
    }
    pub fn admitted(self: Program) !void {
        if (self.status != 0) return error.WindowNotFound;
    }
    pub fn apply(self: Program, info: *platform.WindowInfo) void {
        if (self.mask & 1 != 0) info.open = self.flags & 1 != 0;
        if (self.mask & 2 != 0) info.focused = self.flags & 2 != 0;
        if (self.mask & 4 != 0) info.hidden = self.flags & 4 != 0;
    }
};
pub fn flags(info: platform.WindowInfo) u32 {
    return @as(u32, @intFromBool(info.open)) | (@as(u32, @intFromBool(info.focused)) << 1) | (@as(u32, @intFromBool(info.hidden)) << 2);
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn plan(policy: Policy, runtime: anytype, mode: Mode, options: Options) Program {
    if (platform.max_windows != 16 or platform.max_views != 32 or platform.max_window_label_bytes != 64 or runtime.window_count > 16 or runtime.view_count > 32) @panic("window lifecycle observation capacity");
    var request: [128 + 16 * 128 + 32 * 16]u8 = @splat(0);
    request[0..4].* = .{ 81, 1, @intFromEnum(mode), options.variant };
    put(&request, 4, @intCast(runtime.window_count));
    put(&request, 8, @intCast(runtime.view_count));
    put(&request, 12, @intFromBool(options.value));
    std.mem.writeInt(u64, request[16..24], options.id, .little);
    put(&request, 24, std.math.cast(u32, options.cursor) orelse std.math.maxInt(u32));
    put(&request, 28, std.math.cast(u32, options.target) orelse std.math.maxInt(u32));
    // Oversized lookup labels cannot match a stored label; preserve that miss
    // without borrowing or truncating them into an existing window identity.
    const label_length = @min(options.label.len, 65);
    put(&request, 32, options.saved);
    put(&request, 36, @intFromEnum(options.outcome));
    put(&request, 40, @intCast(label_length));
    put(&request, 44, @intFromBool(options.app_active orelse runtime.app_active));
    for ([_]f32{ options.frame.x, options.frame.y, options.frame.width, options.frame.height }, 0..) |value, i| put(&request, 48 + i * 4, @bitCast(value));
    if (label_length <= 64) @memcpy(request[64..][0..label_length], options.label);
    for (runtime.windows[0..runtime.window_count], 0..) |*window, i| {
        const at = 128 + i * 128;
        if (window.info.label.len > 64) @panic("window lifecycle label capacity");
        std.mem.writeInt(u64, request[at..][0..8], window.info.id, .little);
        put(&request, at + 8, flags(window.info) | (@as(u32, @intFromBool(window.activate_on_show)) << 3) | (@as(u32, @intFromBool(window.main_frame_set)) << 4));
        put(&request, at + 12, @intCast(window.info.label.len));
        @memcpy(request[at + 64 ..][0..window.info.label.len], window.info.label);
    }
    var at = 128 + runtime.window_count * 128;
    for (runtime.views[0..runtime.view_count]) |*view| {
        std.mem.writeInt(u64, request[at..][0..8], view.window_id, .little);
        put(&request, at + 8, @intFromBool(view.keyboard_active));
        at += 16;
    }
    var output: [64]u8 = @splat(0xa5);
    const length = policy(request[0..at], &output);
    if (length != output.len or word(&output, 0) != 1 or word(&output, 4) != @intFromEnum(mode) or word(&output, 8) > 1 or word(&output, 20) > 7 or word(&output, 24) & ~word(&output, 20) != 0 or word(&output, 28) > 1) @panic("invalid compiled window lifecycle shape");
    for (output[48..]) |byte| if (byte != 0) @panic("invalid compiled window lifecycle reserved bytes");
    const selected = word(&output, 12);
    if (selected != std.math.maxInt(u32) and selected >= runtime.window_count) @panic("invalid compiled window lifecycle selection");
    const decisions = word(&output, 16);
    const allowed: u32 = switch (mode) {
        .begin => 16,
        .finish => 15,
        .focus => 32,
        .keyboard => 1,
        .host => 148,
        .replay => 71,
        .focused_index => 0,
    };
    if (decisions & ~allowed != 0 or (word(&output, 8) != 0 and mode != .begin) or (selected == std.math.maxInt(u32) and mode != .begin and mode != .keyboard and mode != .replay)) @panic("invalid compiled window lifecycle admission");
    const mask = word(&output, 20);
    const status = word(&output, 8);
    const empty = selected == std.math.maxInt(u32);
    const valid = switch (mode) {
        .begin => if (status != 0) mask == 0 and decisions == 0 else !empty and mask == switch (options.variant) {
            0 => @as(u32, 7),
            1 => 6,
            2 => 4,
            else => 0,
        } and (decisions == 0 or options.variant == 3),
        .finish => selected == options.cursor and (if (decisions == 8) mask == switch (options.variant) {
            0 => @as(u32, 7),
            1 => 6,
            2 => 4,
            else => 0,
        } else mask == 0 and (decisions == 2 or decisions == 3 or decisions == 6)),
        .focus => selected == options.cursor and mask == 2,
        .keyboard => empty and mask == 0,
        .host => selected == options.cursor and mask == 5 and (decisions == 4 or decisions == 16 or decisions == 132 or decisions == 144),
        .replay => if (decisions == 64) mask == 0 else !empty and ((decisions == 3 and mask == 7) or (decisions == 6 and mask == 4)),
        .focused_index => selected == options.cursor and mask == 0,
    };
    if (!valid or ((mode != .keyboard and mode != .focused_index) and word(&output, 28) != 0)) @panic("invalid compiled window lifecycle program");
    if (decisions & 128 == 0) {
        for (output[32..48]) |byte| if (byte != 0) @panic("invalid compiled window lifecycle unused frame");
    } else if (word(&output, 32) != 0 or word(&output, 36) != 0) @panic("invalid compiled window lifecycle content origin");
    return .{ .status = word(&output, 8), .selected = if (selected == std.math.maxInt(u32)) null else selected, .decisions = decisions, .mask = word(&output, 20), .flags = word(&output, 24), .active = word(&output, 28) == 1, .frame = .init(@bitCast(word(&output, 32)), @bitCast(word(&output, 36)), @bitCast(word(&output, 40)), @bitCast(word(&output, 44))) };
}
