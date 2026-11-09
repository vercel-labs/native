//! Bounded copied declaration facts. The compiled policy owns validation and
//! identity comparisons; native owns source arrays, buffers and OS execution.
const std = @import("std");
const platform = @import("../platform/root.zig");
pub const Policy = @import("command_policy.zig").Policy;

comptime {
    if (platform.max_tray_items != 32 or platform.max_tray_icon_path_bytes != 4096 or platform.max_tray_title_bytes != 64 or platform.max_tray_tooltip_bytes != 256 or platform.max_tray_item_label_bytes != 256 or platform.max_tray_item_command_bytes != 128 or platform.max_tray_item_detail_bytes != 256 or platform.max_menu_key_bytes != 32 or platform.max_tray_segment_options != 8 or platform.max_tray_segment_label_bytes != 64 or platform.max_tray_chart_values != 32 or platform.max_tray_chart_text_bytes != 128) @compileError("update status validation packet limits");
    for (.{ "command", "info", "header", "hero", "agent", "context", "segmented", "chart" }, 0..) |name, value| if (@intFromEnum(@field(platform.TrayItemRole, name)) != value) @compileError("update status validation role tags");
}

const Packet = struct {
    bytes: []u8,
    len: usize = 0,
    fn append(self: *Packet, bytes: []const u8) void {
        if (bytes.len > self.bytes.len - self.len) @panic("status validation packet capacity");
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn word(self: *Packet, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.append(&bytes);
    }
    fn count(self: *Packet, value: usize) void {
        self.word(std.math.cast(u32, value) orelse std.math.maxInt(u32));
    }
    fn float(self: *Packet, value: f32) void {
        self.word(@bitCast(value));
    }
    fn field(self: *Packet, value: []const u8, limit: usize) void {
        self.count(value.len);
        self.append(value[0..@min(value.len, limit)]);
    }
    fn presentation(self: *Packet, value: platform.TrayPresentation) void {
        self.field(value.title, 64);
        self.float(value.width);
        self.float(value.icon_opacity);
        self.float(value.font_size);
    }
    fn shell(self: *Packet, value: platform.TrayShell) void {
        self.field(value.icon_path, 4096);
        self.field(value.tooltip, 256);
        self.commands(value.activation_command, value.alternate_activation_command, value.open_command);
    }
    fn commands(self: *Packet, activation: []const u8, alternate: []const u8, open: []const u8) void {
        self.field(activation, 128);
        self.field(alternate, 128);
        self.field(open, 128);
    }
    fn menu(self: *Packet, policy: Policy, items: []const platform.TrayMenuItem) void {
        self.count(items.len);
        // The native reference rejects this count without touching any row.
        if (items.len > 32) return;
        const duplicates = oversizedDuplicates(policy, items);
        for (items, 0..) |*item, row| {
            self.word(item.id);
            const flags: u8 = @as(u8, @intFromBool(item.separator)) | (@as(u8, @intFromBool(item.segmented != null)) << 1) | (@as(u8, @intFromBool(item.metric != null)) << 2) | (@as(u8, @intFromBool(item.chart != null)) << 3);
            const m = item.modifiers;
            const modifiers: u8 = @as(u8, @intFromBool(m.primary)) | (@as(u8, @intFromBool(m.command)) << 1) | (@as(u8, @intFromBool(m.control)) << 2) | (@as(u8, @intFromBool(m.option)) << 3) | (@as(u8, @intFromBool(m.shift)) << 4);
            self.append(&.{ @intFromEnum(item.role), flags, modifiers, 0 });
            self.field(item.label, 256);
            self.field(item.command, 128);
            self.field(item.detail, 256);
            self.field(item.key, 32);
            if (item.segmented) |segment| {
                self.count(segment.options.len);
                if (segment.options.len <= 8) for (segment.options, 0..) |option, slot| {
                    self.word(option.id);
                    self.word(@as(u32, @intFromBool(option.selected)) | (@as(u32, duplicates[row][slot]) << 1));
                    self.field(option.label, 64);
                    self.field(option.command, 128);
                };
            }
            if (item.metric) |metric| {
                self.field(metric.primary_text, 256);
                self.field(metric.secondary_text, 256);
                self.field(metric.accessibility_label, 128);
            }
            if (item.chart) |chart| {
                self.count(chart.values.len);
                self.float(chart.min_value);
                self.float(chart.max_value);
                if (chart.values.len <= 32) for (chart.values) |value| self.float(value);
                self.field(chart.leading_caption, 128);
                self.field(chart.trailing_summary, 128);
                self.field(chart.accessibility_label, 128);
            }
        }
    }
};

fn oversizedDuplicates(policy: Policy, items: []const platform.TrayMenuItem) [32][8]u8 {
    var matches: [32][8]u8 = @splat(@splat(0));
    const Query = struct { row: u8, option: u8, id: u32 };
    var queries: [256]Query = undefined;
    var count: usize = 0;
    for (items, 0..) |*item, row| if (item.segmented) |segment| {
        if (segment.options.len <= 8) for (segment.options, 0..) |option, slot| {
            queries[count] = .{ .row = @intCast(row), .option = @intCast(slot), .id = option.id };
            count += 1;
        };
    };
    if (count == 0) return matches;
    for (items, 0..) |*item, row| if (item.segmented) |segment| {
        if (segment.options.len <= 8) continue;
        var first: usize = 0;
        while (first < segment.options.len) {
            const chunk = segment.options[first..][0..@min(segment.options.len - first, 128)];
            var bytes: [16 + 256 * 8 + 128 * 4]u8 = undefined;
            var packet = Packet{ .bytes = &bytes };
            packet.append(&.{ 70, 6, 0, 0 });
            packet.count(row);
            packet.count(count);
            packet.count(chunk.len);
            for (queries[0..count]) |query| {
                packet.append(&.{ query.row, query.option, 0, 0 });
                packet.word(query.id);
            }
            for (chunk) |option| packet.word(option.id);
            var result: [256]u8 = undefined;
            if (policy(bytes[0..packet.len], result[0..count]) != count) @panic("invalid compiled status identity result size");
            for (queries[0..count], result[0..count]) |query, duplicate| {
                if (duplicate > 1) @panic("invalid compiled status identity result");
                matches[query.row][query.option] |= duplicate;
            }
            first += chunk.len;
        }
    };
    return matches;
}

fn finish(policy: Policy, packet: *const Packet) !void {
    var result: [4]u8 = undefined;
    if (policy(packet.bytes[0..packet.len], &result) != result.len or !std.mem.eql(u8, result[1..], &.{ 0, 0, 0 })) @panic("invalid compiled status validation result");
    return switch (result[0]) {
        0 => {},
        1 => error.InvalidTrayOptions,
        2 => error.TrayFieldTooLarge,
        3 => error.InvalidCommand,
        else => @panic("invalid compiled status validation error"),
    };
}
pub fn options(policy: Policy, value: platform.TrayOptions) !void {
    var bytes: [128 * 1024]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 0, 0, 0 });
    packet.field(value.icon_path, 4096);
    packet.field(value.title, 64);
    packet.presentation(value.presentation);
    packet.field(value.tooltip, 256);
    packet.commands(value.activation_command, value.alternate_activation_command, value.open_command);
    packet.menu(policy, value.items);
    try finish(policy, &packet);
}
pub fn shell(policy: Policy, value: platform.TrayShell) !void {
    var bytes: [4800]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 1, 0, 0 });
    packet.shell(value);
    try finish(policy, &packet);
}
pub fn title(policy: Policy, value: []const u8) !void {
    var bytes: [72]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 2, 0, 0 });
    packet.field(value, 64);
    try finish(policy, &packet);
}
pub fn presentation(policy: Policy, value: platform.TrayPresentation) !void {
    var bytes: [84]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 3, 0, 0 });
    packet.presentation(value);
    try finish(policy, &packet);
}
pub fn menu(policy: Policy, value: []const platform.TrayMenuItem) !void {
    var bytes: [128 * 1024]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 4, 0, 0 });
    packet.menu(policy, value);
    try finish(policy, &packet);
}
pub fn identity(policy: Policy, value: platform.StatusItemId) !void {
    var bytes: [8]u8 = undefined;
    var packet = Packet{ .bytes = &bytes };
    packet.append(&.{ 70, 5, 0, 0 });
    packet.word(value);
    try finish(policy, &packet);
}
