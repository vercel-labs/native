//! Global shortcut report event, packet codec, and set mirror.
const std = @import("std");
const platform = @import("../platform/root.zig");

/// What a global shortcut report says.
pub const EffectGlobalShortcutEventKind = enum(u8) { registered, pressed, released, conflict, unsupported, rejected, stopped };

/// A global shortcut report; `shortcut` slices are drain scratch.
pub const EffectGlobalShortcutEvent = struct {
    key: u64,
    kind: EffectGlobalShortcutEventKind,
    shortcut: platform.Shortcut = .{ .id = "", .key = "" },
    dropped_pending: u32 = 0,
    dropped_total: u32 = 0,
};

const magic = "GS01";
const header_bytes: usize = 8;
pub const max_packet_bytes: usize = header_bytes + platform.max_shortcut_id_bytes + platform.max_shortcut_key_bytes;

pub fn modifierMask(modifiers: platform.ShortcutModifiers) u8 {
    var mask: u8 = 0;
    inline for (std.meta.fields(platform.ShortcutModifiers), 0..) |field, bit| {
        if (@field(modifiers, field.name)) mask |= 1 << bit;
    }
    return mask;
}

pub fn modifiersFromMask(mask: u8) platform.ShortcutModifiers {
    var modifiers: platform.ShortcutModifiers = .{};
    inline for (std.meta.fields(platform.ShortcutModifiers), 0..) |field, bit| @field(modifiers, field.name) = mask & (1 << bit) != 0;
    return modifiers;
}

pub fn encodePacket(buffer: *[max_packet_bytes]u8, kind: EffectGlobalShortcutEventKind, shortcut: platform.Shortcut) []const u8 {
    const id = shortcut.id[0..@min(shortcut.id.len, platform.max_shortcut_id_bytes)];
    const key = shortcut.key[0..@min(shortcut.key.len, platform.max_shortcut_key_bytes)];
    buffer[0..header_bytes].* = (magic ++ .{ @intFromEnum(kind), modifierMask(shortcut.modifiers), @as(u8, @intCast(id.len)), @as(u8, @intCast(key.len)) }).*;
    @memcpy(buffer[header_bytes..][0..id.len], id);
    @memcpy(buffer[header_bytes + id.len ..][0..key.len], key);
    return buffer[0 .. header_bytes + id.len + key.len];
}

pub fn decodeChannelEvent(channel: anytype) EffectGlobalShortcutEvent {
    var event: EffectGlobalShortcutEvent = .{ .key = channel.key, .kind = .rejected, .dropped_pending = channel.dropped_pending, .dropped_total = channel.dropped_total };
    const bytes = channel.bytes;
    if (channel.kind == .closed) event.kind = .stopped;
    if (channel.kind != .data or bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], magic) or bytes.len != header_bytes + bytes[6] + bytes[7]) return event;
    event.kind = std.enums.fromInt(EffectGlobalShortcutEventKind, bytes[4]) orelse .rejected;
    event.shortcut = .{ .id = bytes[header_bytes..][0..bytes[6]], .key = bytes[header_bytes + bytes[6] ..][0..bytes[7]], .modifiers = modifiersFromMask(bytes[5]) };
    return event;
}

pub const Binding = struct { shortcut: platform.OwnedShortcut, kind: EffectGlobalShortcutEventKind };

pub const Session = struct {
    active: bool = false,
    key: u64 = 0,
    platform_configured: bool = false,
    bindings: [platform.max_global_shortcuts]Binding = undefined,
    count: usize = 0,

    pub fn find(self: *const Session, id: []const u8) ?*const Binding {
        for (self.bindings[0..self.count]) |*binding| {
            if (std.mem.eql(u8, binding.shortcut.shortcut().id, id)) return binding;
        }
        return null;
    }
};

pub fn admissible(shortcut: platform.Shortcut, earlier: []const platform.Shortcut) bool {
    platform.validateShortcut(shortcut) catch return false;
    for (earlier) |previous| {
        if (std.mem.eql(u8, previous.id, shortcut.id)) return false;
    }
    return earlier.len < platform.max_global_shortcuts;
}
