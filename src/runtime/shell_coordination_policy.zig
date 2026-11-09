//! Copied shell facts; native owns storage, borrowed descriptors and OS calls.
const std = @import("std");
const platform = @import("../platform/root.zig");
const manifest = @import("app_manifest");
pub const Policy = *const fn ([]const u8, []u8) usize;
comptime {
    if (manifest.max_shell_windows != 16 or manifest.max_shell_views_per_window != 128 or platform.max_windows != 16 or platform.max_views != 32 or platform.max_webviews != 16 or @typeInfo(platform.ViewKind).@"enum".fields.len != 19 or @intFromEnum(platform.ViewKind.webview) != 0 or @intFromEnum(platform.ViewKind.gpu_surface) != 17 or @intFromEnum(platform.ViewKind.progress_indicator) != 18 or @bitSizeOf(platform.WindowId) != 64 or @bitSizeOf(usize) > 64) @compileError("update shell coordination wire capacities");
}
pub const Mode = enum(u8) { scene, equal, apply, rollback, restore, bind, admission, presentation };
pub const Program = struct {
    status: u32,
    decisions: u32,
    selected: ?usize,
    count: usize,
    choices: [16]u32 = @splat(0),
    pub fn admit(self: Program) !void {
        switch (self.status) {
            0 => {},
            1 => return error.WindowLimitReached,
            2 => return error.DuplicateViewLabel,
            3 => return error.ViewLimitReached,
            4 => return error.WebViewLimitReached,
            else => unreachable,
        }
    }
};
pub fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn request(mode: Mode, facts: u32, count: u32, cursor: u32) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    bytes[0..3].* = .{ 84, 1, @intFromEnum(mode) };
    put(&bytes, 4, facts);
    put(&bytes, 8, count);
    put(&bytes, 12, cursor);
    return bytes;
}
pub fn plan(policy: Policy, bytes: []const u8) Program {
    const mode = std.enums.fromInt(Mode, bytes[2]) orelse @panic("invalid shell mode");
    var output: [88]u8 = @splat(0xa5);
    const length = policy(bytes, &output);
    if (length < 24 or length > output.len or word(&output, 0) != 1 or word(&output, 4) != @intFromEnum(mode)) @panic("invalid compiled shell coordination header");
    var p = Program{ .status = word(&output, 8), .decisions = word(&output, 12), .selected = if (word(&output, 16) == std.math.maxInt(u32)) null else word(&output, 16), .count = word(&output, 20) };
    const allowed: u32 = switch (mode) {
        .scene, .equal, .bind => 1,
        .apply => 15,
        .restore => 3,
        .rollback, .admission => 0,
        .presentation => 15,
    };
    if (mode == .admission) {
        if (p.decisions > 2 or (p.status != 0 and p.status < 2) or p.status > 4) @panic("invalid shell admission result");
    } else if (p.decisions & ~allowed != 0 or p.status > @as(u32, if (mode == .bind) 1 else 0)) @panic("invalid shell decisions");
    if (p.count > 16 or length != 24 + p.count * 4 or (mode == .scene and p.count != word(bytes, 8)) or (mode != .scene and p.count != 0)) @panic("invalid shell choices");
    for (p.choices[0..p.count], 0..) |*choice, i| {
        choice.* = word(&output, 24 + i * 4);
        if (choice.* > 127 or choice.* & 3 == 3) @panic("invalid shell window choice");
    }
    if (mode == .bind and (p.status == 1 and (p.selected != null or p.decisions != 0 or word(bytes, 8) != 16) or p.status == 0 and p.decisions == 0 and p.selected != null and p.selected.? >= word(bytes, 8))) @panic("invalid shell binding disposition");
    if (p.selected) |slot| {
        if (mode == .rollback) {
            if (slot >= word(bytes, 8) or slot + 1 != word(bytes, 12)) @panic("invalid shell rollback slot");
        } else if (mode == .bind) {
            if (slot >= 16 or slot > word(bytes, 8) or (p.decisions != 0 and slot != word(bytes, 8))) @panic("invalid shell binding slot");
        } else @panic("unexpected shell selection");
    } else if (mode == .rollback and word(bytes, 12) != 0 or mode == .bind and p.status == 0) @panic("missing shell selection");
    return p;
}
/// Exact opaque-byte comparison, including oversized invalid labels. Bounded
/// chunks preserve equality without truncating labels into stored identities.
pub fn equal(policy: Policy, left: []const u8, right: []const u8) bool {
    var bytes = request(.equal, @intFromBool(left.len == right.len), 0, 0);
    if (plan(policy, &bytes).decisions == 0) return false;
    var at: usize = 0;
    while (at < left.len) {
        const n = @min(16, left.len - at);
        bytes = request(.equal, 1, @intCast(n), 0);
        @memcpy(bytes[16..][0..n], left[at..][0..n]);
        @memcpy(bytes[32..][0..n], right[at..][0..n]);
        if (plan(policy, &bytes).decisions == 0) return false;
        at += n;
    }
    return true;
}
/// Stream current borrowed descriptors in bounded chunks. Source callbacks may
/// replace a previously validated view slice; creation retains its own gate.
pub fn scene(policy: Policy, windows: []const manifest.ShellWindow, empty_source: bool) Program {
    if (windows.len > 16) @panic("shell scene capacity");
    var result = Program{ .status = 0, .decisions = 0, .selected = null, .count = windows.len };
    var bytes: [64 + 4 + 128 * 13]u8 = @splat(0);
    for (windows, 0..) |window, index| {
        var at: usize = 0;
        var observations: u32 = 0;
        while (true) {
            const count: usize = @min(window.views.len - at, 128);
            bytes[0..64].* = request(.scene, @intFromBool(empty_source), 1, observations);
            bytes[64] = @intFromBool(window.initially_hidden);
            bytes[65] = @intFromBool(window.x != null or window.y != null);
            std.mem.writeInt(u16, bytes[66..68], @intCast(count), .little);
            for (window.views[at..][0..count], 0..) |view, i| {
                const slot = 68 + i * 13;
                bytes[slot] = @intFromEnum(view.kind);
                std.mem.writeInt(u64, bytes[slot + 1 ..][0..8], view.label.len, .little);
                @memset(bytes[slot + 9 ..][0..4], 0);
                @memcpy(bytes[slot + 9 ..][0..@min(view.label.len, 4)], view.label[0..@min(view.label.len, 4)]);
            }
            const chunk = plan(policy, bytes[0 .. 68 + count * 13]);
            observations = chunk.choices[0] >> 4;
            result.choices[index] = chunk.choices[0] & 15;
            result.decisions |= chunk.decisions;
            at += count;
            if (at == window.views.len) break;
        }
    }
    return result;
}
pub fn presentation(policy: Policy, window: manifest.ShellWindow) struct { show: platform.WindowShowMode, placement: platform.WindowInitialPlacement } {
    var bytes: [192]u8 = @splat(0);
    var at: usize = 0;
    var result: u32 = 0;
    while (true) {
        const count: usize = @min(window.views.len - at, 128);
        bytes[0..64].* = request(.presentation, @as(u32, @intFromBool(window.initially_hidden)) | (@as(u32, @intFromBool(window.x != null or window.y != null)) << 2), @intCast(count), @intFromBool(result & 8 != 0));
        for (window.views[at..][0..count], 0..) |view, i| bytes[64 + i] = @intFromEnum(view.kind);
        result = plan(policy, bytes[0 .. 64 + count]).decisions;
        at += count;
        if (at == window.views.len) break;
    }
    return .{ .placement = if (result & 4 != 0) .explicit else .default, .show = switch (result & 3) {
        0 => .immediate,
        1 => .hidden,
        2 => .on_first_present,
        else => unreachable,
    } };
}
