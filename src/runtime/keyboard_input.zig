const std = @import("std");
const platform = @import("../platform/root.zig");

pub const send_chord_name = "native-sdk.keyboard.sendChord";
pub const access_status_name = "native-sdk.keyboard.accessStatus";

pub const Binding = struct {
    context: *anyopaque,
    send_key_chord_fn: *const fn (context: *anyopaque, chord: platform.KeyChord) anyerror!void,
    access_fn: *const fn (context: *anyopaque, prompt: bool) anyerror!platform.KeyboardInputAccess,
};

pub const Result = struct {
    ok: bool,
    bytes: []const u8,
};

pub const max_chord_payload_bytes: usize = 4 + platform.max_shortcut_key_bytes + 8;

const modifier_names = .{ "primary", "command", "control", "option", "shift" };

pub fn isRequestName(name: []const u8) bool {
    return std.mem.eql(u8, name, send_chord_name) or
        std.mem.eql(u8, name, access_status_name);
}

pub fn encodeChord(buffer: *[max_chord_payload_bytes]u8, chord: platform.KeyChord) []const u8 {
    const name = chord.key();
    std.mem.writeInt(u32, buffer[0..4], @intCast(name.len), .little);
    @memcpy(buffer[4..][0..name.len], name);
    var bits: f64 = 0;
    inline for (modifier_names, 0..) |field, bit| {
        if (@field(chord.modifiers, field)) bits += 1 << bit;
    }
    std.mem.writeInt(u64, buffer[4 + name.len ..][0..8], @bitCast(bits), .little);
    return buffer[0 .. 4 + name.len + 8];
}

pub fn decodeChord(payload: []const u8) ?platform.KeyChord {
    if (payload.len < 4) return null;
    const name_len: usize = std.mem.readInt(u32, payload[0..4], .little);
    if (name_len > payload.len - 4 or payload.len - 4 - name_len != 8) return null;
    const bits: f64 = @bitCast(std.mem.readInt(u64, payload[4 + name_len ..][0..8], .little));
    if (!(bits >= 0 and bits < 1 << modifier_names.len) or bits != @floor(bits)) return null;
    const mask: u32 = @intFromFloat(bits);
    var chord = platform.KeyChord.init(payload[4..][0..name_len], .{}) orelse return null;
    inline for (modifier_names, 0..) |field, bit| @field(chord.modifiers, field) = mask & (1 << bit) != 0;
    return chord;
}

pub fn execute(binding: Binding, name: []const u8, payload: []const u8) Result {
    if (std.mem.eql(u8, name, send_chord_name)) {
        const chord = decodeChord(payload) orelse return .{ .ok = false, .bytes = "invalid_request" };
        binding.send_key_chord_fn(binding.context, chord) catch |err| return .{ .ok = false, .bytes = reasonName(err) };
        return .{ .ok = true, .bytes = "" };
    }
    if (payload.len != 1 or payload[0] > 1) return .{ .ok = false, .bytes = "invalid_request" };
    const access = binding.access_fn(binding.context, payload[0] == 1) catch |err| return .{ .ok = false, .bytes = reasonName(err) };
    return .{ .ok = true, .bytes = @tagName(access) };
}

fn reasonName(err: anyerror) []const u8 {
    return switch (err) {
        error.PermissionDenied => "rejected",
        error.UnsupportedService => "unsupported",
        error.KeyboardInputAccessDenied => "denied",
        error.KeyboardInputBlocked => "blocked",
        else => "failed",
    };
}
