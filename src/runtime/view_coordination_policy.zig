//! Copies raw window/view observations; native owns storage and OS execution.
const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { list, adjacent, repair, parent, absolute, platform_frame, local_frame, children, subtree, mutation, window };
pub const Kind = enum(u32) { none, main, native, webview };
pub const Selection = struct { kind: Kind = .none, slot: usize = 0 };
pub const Options = struct {
    window_id: platform.WindowId,
    label: []const u8 = "",
    parent: ?[]const u8 = null,
    variant: u8 = 0,
    capacity: usize = platform.max_views + platform.max_webviews + 1,
    depth: usize = 0,
    cursor: usize = 0,
    clear: bool = false,
    frame: geometry.RectF = .zero(),
};
pub const Program = struct {
    status: u32,
    decision: u32,
    selected: Selection,
    count: usize,
    selections: [platform.max_views + platform.max_webviews + 1]Selection = undefined,
    frame: geometry.RectF = .zero(),
    pub fn admitted(self: *const Program) !void {
        return switch (self.status) {
            0 => {},
            1 => error.WindowNotFound,
            2 => error.ViewNotFound,
            3 => error.InvalidViewOptions,
            4 => error.UnsupportedViewFocus,
            else => unreachable,
        };
    }
};
comptime {
    if (platform.max_windows != 16 or platform.max_views != 32 or platform.max_webviews != 16 or platform.max_view_label_bytes != 64 or platform.max_webview_label_bytes != 64)
        @compileError("update view coordination packet capacities");
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn writeRect(bytes: []u8, at: usize, frame: geometry.RectF) void {
    for ([_]f32{ frame.x, frame.y, frame.width, frame.height }, 0..) |value, i| put(bytes, at + i * 4, @bitCast(value));
}
fn readRect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(@bitCast(word(bytes, at)), @bitCast(word(bytes, at + 4)), @bitCast(word(bytes, at + 8)), @bitCast(word(bytes, at + 12)));
}
fn text(bytes: []u8, at: usize, length_at: usize, value: []const u8) void {
    put(bytes, length_at, std.math.cast(u32, value.len) orelse std.math.maxInt(u32));
    @memcpy(bytes[at..][0..@min(value.len, 64)], value[0..@min(value.len, 64)]);
}
fn selection(bytes: []const u8, at: usize, runtime: anytype) Selection {
    const kind = std.enums.fromInt(Kind, word(bytes, at)) orelse @panic("invalid compiled view selection kind");
    const slot = word(bytes, at + 4);
    const count = switch (kind) {
        .none => 1,
        .main => runtime.window_count,
        .native => runtime.view_count,
        .webview => runtime.webview_count,
    };
    if (slot >= count) @panic("invalid compiled view selection slot");
    return .{ .kind = kind, .slot = slot };
}
pub fn plan(policy: Policy, runtime: anytype, mode: Mode, options: Options) Program {
    if (runtime.window_count > platform.max_windows or runtime.view_count > platform.max_views or runtime.webview_count > platform.max_webviews)
        @panic("view coordination observation capacity");
    var request: [192 + platform.max_windows * 64 + (platform.max_views + platform.max_webviews) * 192]u8 = @splat(0);
    request[0..4].* = .{ 80, 1, @intFromEnum(mode), options.variant };
    put(&request, 4, @intCast(runtime.window_count));
    put(&request, 8, @intCast(runtime.view_count));
    put(&request, 12, @intCast(runtime.webview_count));
    std.mem.writeInt(u64, request[16..24], options.window_id, .little);
    text(&request, 64, 24, options.label);
    put(&request, 28, std.math.maxInt(u32));
    if (options.parent) |parent| text(&request, 128, 28, parent);
    put(&request, 32, @intCast(@min(options.capacity, platform.max_views + platform.max_webviews + 1)));
    put(&request, 36, std.math.cast(u32, options.depth) orelse std.math.maxInt(u32));
    put(&request, 40, std.math.cast(u32, options.cursor) orelse std.math.maxInt(u32));
    put(&request, 44, @intFromBool(options.clear));
    writeRect(&request, 48, options.frame);
    for (runtime.windows[0..runtime.window_count], 0..) |*window, i| {
        const at = 192 + i * 64;
        std.mem.writeInt(u64, request[at..][0..8], window.info.id, .little);
        put(&request, at + 8, @as(u32, @intFromBool(window.info.open)) | (@as(u32, @intFromBool(window.source != null)) << 1) | (@as(u32, @intFromBool(window.main_focused)) << 2) | (@as(u32, @intFromBool(window.main_frame_set)) << 3));
        writeRect(&request, at + 16, window.info.frame);
        writeRect(&request, at + 32, window.main_frame);
        std.mem.writeInt(u64, request[at + 48 ..][0..8], window.main_view_id, .little);
    }
    var at = 192 + runtime.window_count * 64;
    for (runtime.views[0..runtime.view_count]) |*view| {
        writeView(&request, at, view, view.visible, view.enabled);
        at += 192;
    }
    for (runtime.webviews[0..runtime.webview_count]) |*view| {
        writeView(&request, at, view, true, true);
        at += 192;
    }
    var output: [32 + (platform.max_views + platform.max_webviews + 1) * 8]u8 = @splat(0xa5);
    const length = policy(request[0..at], &output);
    if (length < 32 or length > output.len or word(&output, 0) != 1 or word(&output, 4) != @intFromEnum(mode) or word(&output, 8) > 4 or word(&output, 28) != 0)
        @panic("invalid compiled view coordination header");
    var result = Program{ .status = word(&output, 8), .decision = word(&output, 12), .selected = selection(&output, 16, runtime), .count = word(&output, 24) };
    const has_frame = result.status == 0 and (mode == .absolute or mode == .platform_frame or mode == .local_frame);
    if (result.count > result.selections.len or length != 32 + result.count * 8 + @as(usize, if (has_frame) 16 else 0) or ((mode != .list and mode != .children) and result.count != 0) or (mode == .list and result.count > options.capacity) or (result.status != 0 and (result.count != 0 or result.selected.kind != .none or result.decision != 0)))
        @panic("invalid compiled view coordination shape");
    const decision_limit: u32 = switch (mode) {
        .repair, .children => 2,
        .subtree => 1,
        .mutation => 7,
        else => 0,
    };
    if (result.decision > decision_limit or (result.selected.kind != .none and mode != .adjacent and mode != .repair and mode != .mutation))
        @panic("invalid compiled view coordination decision");
    const status_valid = switch (mode) {
        .list, .repair, .children, .subtree, .mutation => result.status == 0,
        .adjacent => result.status == 0 or result.status == 1 or result.status == 4,
        .parent => result.status == 0 or result.status == 2 or result.status == 3,
        .absolute, .platform_frame, .local_frame => result.status <= 3,
        .window => result.status == 0 or result.status == 1,
    };
    if (!status_valid or (mode == .adjacent and result.status == 0 and result.selected.kind == .none) or (mode == .repair and ((result.decision == 2) != (result.selected.kind != .none))) or (mode == .children and (result.decision != @as(u32, options.variant) + 1 or (options.cursor != 0 and result.count > 1))) or (mode == .mutation and ((result.decision & 1 != 0) != (result.selected.kind != .none) or (result.decision & 4 != 0 and result.decision & 2 != 0))))
        @panic("invalid compiled view coordination admission");
    for (result.selections[0..result.count], 0..) |*selected, i| {
        selected.* = selection(&output, 32 + i * 8, runtime);
        if (selected.kind == .none or (mode == .children and selected.kind == .main)) @panic("invalid compiled view coordination list member");
        if (mode == .children and options.cursor != 0 and options.cursor != (if (selected.kind == .native) selected.slot + 1 else selected.slot + 33)) @panic("invalid compiled descendant cursor result");
    }
    if (has_frame) result.frame = readRect(&output, 32);
    return result;
}
fn writeView(bytes: []u8, at: usize, view: anytype, visible: bool, enabled: bool) void {
    if (view.label.len > 64 or (view.parent != null and view.parent.?.len > 64)) @panic("view coordination label capacity");
    std.mem.writeInt(u64, bytes[at..][0..8], view.window_id, .little);
    put(bytes, at + 8, @as(u32, @intFromBool(view.open)) | (@as(u32, @intFromBool(visible)) << 1) | (@as(u32, @intFromBool(enabled)) << 2) | (@as(u32, @intFromBool(view.focused)) << 3));
    text(bytes, at + 64, at + 16, view.label);
    put(bytes, at + 20, std.math.maxInt(u32));
    if (view.parent) |parent| text(bytes, at + 128, at + 20, parent);
    std.mem.writeInt(u64, bytes[at + 24 ..][0..8], view.id, .little);
    writeRect(bytes, at + 32, view.frame);
    if (comptime @hasField(@TypeOf(view.*), "local_frame")) writeRect(bytes, at + 48, view.local_frame);
}
