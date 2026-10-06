//! Copied replay admission plans. Native retains exact record storage and blobs.
const std = @import("std");
const effects = @import("effects.zig");
const platform = @import("../platform/root.zig");
const limits = @import("canvas_limits.zig");
const reference = @import("replay_policy_reference.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Blob = enum(u8) { none, pty, file, image, persist, db };
pub const Plan = struct {
    damage: u16,
    regenerates: bool,
    blob: Blob,
    pub fn damaged(self: Plan, bit: u4) bool {
        return self.damage & (@as(u16, 1) << bit) != 0;
    }
};
pub fn request(record: effects.EffectResultRecord) [256]u8 {
    var bytes: [256]u8 = @splat(0);
    bytes[0..16].* = .{ 20, @intFromEnum(record.kind), @intFromEnum(record.exit_reason), @intFromEnum(record.file_op), @intFromEnum(record.file_event), @intFromEnum(record.file_outcome), @intFromEnum(record.image_outcome), @intFromEnum(record.channel_kind), @intFromEnum(record.video_kind), @intFromEnum(record.audio_kind), @intFromEnum(record.pty_kind), @intFromEnum(record.persist_outcome), @intFromEnum(record.credentials_operation), @intFromEnum(record.credentials_outcome), @intFromEnum(record.fetch_outcome), @intFromEnum(record.clipboard_outcome) };
    std.mem.writeInt(i32, bytes[16..20], record.code, .little);
    std.mem.writeInt(i32, bytes[20..24], record.pty_signal, .little);
    const words = [_]u64{ record.payload.len, record.file_blob_len, record.file_total, @as(u64, @bitCast(record.file_mtime_ms)), record.image_blob_len, record.image_width, record.image_height, record.video_position_ms, record.video_duration_ms, record.video_width, record.video_height, record.video_token, record.audio_position_ms, record.audio_duration_ms, record.pty_blob_len, record.pty_dropped_writes, record.persist_blob_len, record.db_blob_len, record.credentials_secret_len, effects.effect_file_stream_chunk_bytes, effects.max_effect_channel_bytes, platform.max_decoded_image_dimension, limits.max_registered_canvas_image_pixel_bytes_ceiling, effects.max_effect_pty_chunk_bytes, effects.max_effect_persist_snapshot_bytes, effects.max_effect_db_page_bytes, effects.max_effect_credentials_secret_bytes };
    for (words, 0..) |word, i| std.mem.writeInt(u64, bytes[24 + i * 8 ..][0..8], word, .little);
    bytes[240..248].* = .{ @intFromBool(record.file_rejected_admission), @intFromBool(record.file_exists), @intFromBool(record.video_playing), @intFromBool(record.video_buffering), @intFromBool(record.truncated), @intFromBool(std.mem.allEqual(u8, &record.credentials_salt, 0)), @intFromBool(std.mem.allEqual(u8, &record.credentials_digest, 0)), 0 };
    // Closed relational outcome count is a schema fact, not an admission verdict.
    bytes[248] = @intCast(@typeInfo(effects.EffectDbOutcome).@"enum".fields.len);
    return bytes;
}
// The native branch is retained for explicit Zig-core applications.
pub fn plan(policy: Policy, record: effects.EffectResultRecord) Plan {
    if (policy) |callback| {
        const input = request(record);
        var output: [8]u8 = undefined;
        if (callback(&input, &output) != output.len) @panic("invalid compiled replay plan size");
        if (output[2] > 1 or output[3] > 5 or !std.mem.allEqual(u8, output[4..], 0) or output[1] & 128 != 0) @panic("invalid compiled replay plan");
        return .{ .damage = std.mem.readInt(u16, output[0..2], .little), .regenerates = output[2] != 0, .blob = @enumFromInt(output[3]) };
    }
    return .{ .damage = reference.damage(record), .regenerates = reference.effectRegeneratesUnderReplay(record), .blob = switch (record.kind) {
        .pty => if (record.pty_blob_len > 0) .pty else .none,
        .file => if (record.file_blob_len > 0) .file else .none,
        .image => if (record.image_blob_len > 0) .image else .none,
        .persist => if (record.persist_blob_len > 0) .persist else .none,
        .db => if (record.db_blob_len > 0) .db else .none,
        else => .none,
    } };
}

pub const Stage = enum(u8) { header, chrome_admission, arm, chrome_consumed, feed_error, verify, end };
pub const Action = enum(u8) { proceed, protocol_refusal, platform_refusal, damage, arm, chrome_divergence, propagate, drain, effect_divergence, unsupported, verify };
pub fn coordinate(policy: Policy, stage: Stage, a: u8, b: bool, c: bool) Action {
    const bytes = [_]u8{ 21, @intFromEnum(stage), a, @intFromBool(b), @intFromBool(c), 0, 0, 0 };
    if (policy) |callback| {
        var output: [4]u8 = undefined;
        if (callback(&bytes, &output) != output.len or output[0] > 10 or !std.mem.allEqual(u8, output[1..], 0)) @panic("invalid compiled replay coordination plan");
        return @enumFromInt(output[0]);
    }
    return switch (stage) {
        .header => if (a == 0) .protocol_refusal else if (b and !c) .platform_refusal else .proceed,
        .chrome_admission => if (a != 0 or b) .damage else .proceed,
        .arm => if (a == 0) .arm else .proceed,
        .chrome_consumed => if (a != 0 or b) .chrome_divergence else .proceed,
        .feed_error => if (a == 0) (if (b) .propagate else .drain) else if (a == 1) .effect_divergence else .unsupported,
        .verify => if (a != 0) .verify else .proceed,
        .end => if (a != 0) .chrome_divergence else .proceed,
    };
}
