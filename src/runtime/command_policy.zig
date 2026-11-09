//! Copied command facts and checked selections. Native retains borrowed names,
//! registry storage, exact OS identities, capability results and event lifetime.
const std = @import("std");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const app_manifest = @import("app_manifest");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Dispatch = enum(u8) { app, invalid, updater };
pub const Menu = struct { exists: bool, actionable: bool, row: ?usize, option: ?usize };
pub const Slot = struct { kind: enum(u8) { absent, retained, available, full }, index: ?usize };

comptime {
    if (platform.max_views != 32 or platform.max_view_label_bytes != 64 or platform.max_tray_items != 32 or platform.max_tray_segment_options != 8 or platform.max_status_items != 8 or validation.max_command_id_bytes != 128 or !std.mem.eql(u8, platform.update_check_command, "app.check-for-updates")) @compileError("update command coordination packet limits");
    if (app_manifest.max_commands != 256 or app_manifest.max_command_id_bytes != 128 or app_manifest.max_command_title_bytes != 128) @compileError("update command catalog packet limits");
}

const Packet = struct {
    bytes: []u8,
    len: usize = 0,
    fn append(self: *Packet, bytes: []const u8) void {
        if (bytes.len > self.bytes.len - self.len) @panic("command packet capacity");
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn word(self: *Packet, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.append(&bytes);
    }
    fn identity(self: *Packet, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.append(&bytes);
    }
    fn written(self: *const Packet) []const u8 {
        return self.bytes[0..self.len];
    }
};
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn run(policy: Policy, request: []const u8, result: []u8) void {
    if (policy(request, result) != result.len) @panic("invalid compiled command result size");
}
fn text(policy: Policy, operation: u8, value: []const u8, limit: usize) u8 {
    var bytes: [136]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 69, operation, 0, 0 });
    packet.word(std.math.cast(u32, value.len) orelse std.math.maxInt(u32));
    packet.append(value[0..@min(value.len, limit)]);
    var result: [4]u8 = undefined;
    run(policy, packet.written(), &result);
    if (!std.mem.eql(u8, result[1..], &.{ 0, 0, 0 })) @panic("invalid compiled command reserved bytes");
    return result[0];
}
pub fn dispatch(policy: Policy, name: []const u8) Dispatch {
    return std.enums.fromInt(Dispatch, text(policy, 0, name, 128)) orelse @panic("invalid compiled command dispatch");
}
pub fn bridgeLabel(policy: Policy, label: []const u8) []const u8 {
    return switch (text(policy, 4, label, 64)) {
        0 => label,
        1 => "",
        else => @panic("invalid compiled command label"),
    };
}

pub fn catalog(policy: Policy, commands: []const app_manifest.Command) !void {
    var bytes: [8 + 256 * (8 + 128 + 128)]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 69, 5, 0, 0 });
    packet.word(std.math.cast(u32, commands.len) orelse std.math.maxInt(u32));
    if (commands.len <= 256) for (commands) |*command| {
        packet.word(std.math.cast(u32, command.id.len) orelse std.math.maxInt(u32));
        packet.word(std.math.cast(u32, command.title.len) orelse std.math.maxInt(u32));
        packet.append(command.id[0..@min(command.id.len, 128)]);
        packet.append(command.title[0..@min(command.title.len, 128)]);
    };
    var result: [4]u8 = undefined;
    run(policy, packet.written(), &result);
    if (!std.mem.eql(u8, result[1..], &.{ 0, 0, 0 })) @panic("invalid compiled command catalog reserved bytes");
    return switch (result[0]) {
        0 => {},
        1 => error.InvalidCommand,
        2 => error.InvalidName,
        3 => error.DuplicateCommand,
        else => @panic("invalid compiled command catalog admission"),
    };
}

pub fn nativeViewSource(policy: Policy, views: anytype, window_id: platform.WindowId, label: []const u8) bool {
    if (views.len > platform.max_views) @panic("command view capacity");
    var bytes: [20 + 64 + platform.max_views * (16 + 128)]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 69, 1, 0, 0 });
    packet.word(@intCast(views.len));
    packet.identity(window_id);
    packet.word(std.math.cast(u32, label.len) orelse std.math.maxInt(u32));
    packet.append(label[0..@min(label.len, 64)]);
    // Iterate pointers: retained views contain large native widget buffers.
    for (views) |*view| {
        const parent = view.parent orelse "";
        if (view.label.len > 64 or parent.len > 64) @panic("command view label capacity");
        packet.append(&.{ @as(u8, @intFromBool(view.open)) | (@as(u8, @intFromBool(view.kind == .toolbar)) << 1) | (@as(u8, @intFromBool(view.parent != null)) << 2), @intCast(view.label.len), @intCast(parent.len), 0 });
        packet.identity(view.window_id);
        packet.word(0);
        packet.append(view.label);
        packet.append(parent);
    }
    var result: [4]u8 = undefined;
    run(policy, packet.written(), &result);
    if (!std.mem.eql(u8, result[1..], &.{ 0, 0, 0 }) or (result[0] != 3 and result[0] != 6)) @panic("invalid compiled command source");
    return result[0] == 3;
}

pub fn menu(policy: Policy, items: anytype, item_id: platform.TrayItemId) Menu {
    if (items.len > platform.max_tray_items) @panic("command menu capacity");
    var bytes: [12 + platform.max_tray_items * (8 + platform.max_tray_segment_options * 8)]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 69, 2, 0, 0 });
    packet.word(@intCast(items.len));
    packet.word(item_id);
    for (items) |*item| {
        const options: []const platform.TraySegmentOption = if (item.segmented) |segment| segment.options else &.{};
        if (options.len > platform.max_tray_segment_options) @panic("command segment capacity");
        packet.word(item.id);
        packet.append(&.{ @as(u8, @intFromBool(item.separator)) | (@as(u8, @intFromBool(item.enabled)) << 1) | (@as(u8, @intFromBool(item.role == .command or item.role == .agent)) << 2) | (@as(u8, @intFromBool(item.command.len > 0)) << 3), @intCast(options.len), 0, 0 });
        for (options) |option| {
            packet.word(option.id);
            packet.append(&.{ @intFromBool(option.enabled), 0, 0, 0 });
        }
    }
    var result: [16]u8 = undefined;
    run(policy, packet.written(), &result);
    const row = read(&result, 4);
    const option = read(&result, 8);
    if (result[0] > 1 or result[1] > 1 or result[2] != 0 or result[3] != 0 or read(&result, 12) != 0) @panic("invalid compiled command menu flags");
    if (row != std.math.maxInt(u32)) {
        if (row >= items.len) @panic("invalid compiled command menu row");
        if (option != std.math.maxInt(u32) and (items[row].segmented == null or option >= items[row].segmented.?.options.len)) @panic("invalid compiled command menu option");
    } else if (option != std.math.maxInt(u32)) @panic("invalid compiled command menu fallback");
    return .{ .exists = result[0] == 1, .actionable = result[1] == 1, .row = if (row == std.math.maxInt(u32)) null else row, .option = if (option == std.math.maxInt(u32)) null else option };
}

pub fn slot(policy: Policy, slots: anytype, id: platform.StatusItemId, admit: bool, count: usize) Slot {
    if (slots.len != 8 or count > 8) @panic("command status capacity");
    var bytes: [80]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 69, 3, 0, 0 });
    packet.word(@intFromBool(admit));
    packet.word(id);
    packet.word(@intCast(count));
    for (slots) |*entry| {
        packet.append(&.{ @intFromBool(entry.active), 0, 0, 0 });
        packet.word(entry.id);
    }
    var result: [8]u8 = undefined;
    run(policy, packet.written(), &result);
    const index = read(&result, 4);
    if (result[0] > 3 or !std.mem.eql(u8, result[1..4], &.{ 0, 0, 0 }) or ((result[0] == 1 or result[0] == 2) != (index < slots.len)) or (index >= slots.len and index != std.math.maxInt(u32))) @panic("invalid compiled command status selection");
    return .{ .kind = @enumFromInt(result[0]), .index = if (index == std.math.maxInt(u32)) null else index };
}
