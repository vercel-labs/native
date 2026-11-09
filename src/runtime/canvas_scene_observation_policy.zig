//! Copied scene observations. Native owns lazy bounds capabilities, retained
//! summaries, bounded output storage and presentation execution.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const limits = @import("canvas_limits.zig");
const wire = canvas.glyph_atlas_policy;
pub const Policy = wire.Policy;
const max_count = limits.max_canvas_commands_per_view;
const Scratch = struct {
    request: [64 + max_count * 64]u8 = undefined,
    result: [64 + max_count * 32]u8 = undefined,
};
const scratch = canvas.lazy_tls.LazyTls(Scratch);

fn header(bytes: []u8, mode: u8) void {
    @memset(bytes, 0);
    bytes[0..4].* = .{ 76, 1, mode, 0 };
}
fn putEntry(bytes: []u8, at: usize, id: ?u64, bounds: ?geometry.RectF) void {
    wire.put(bytes, at, @as(u32, @intFromBool(id != null)) | (@as(u32, @intFromBool(bounds != null)) << 1));
    std.mem.writeInt(u64, bytes[at + 4 ..][0..8], id orelse 0, .little);
    putRect(bytes, at + 16, bounds orelse .{});
}
pub fn resultValid(result: []const u8, mode: u8) bool {
    if (result.len < 64 or wire.word(result, 0) != 1 or mode > 6) return false;
    for (result[32..64]) |byte| if (byte != 0) return false;
    if (mode == 0) {
        if (wire.word(result, 8) > 1 or result.len != 64 + @as(usize, wire.word(result, 4)) * 16) return false;
        for (result[12..32]) |byte| if (byte != 0) return false;
        var at: usize = 64;
        while (at < result.len) : (at += 16) if (wire.word(result, at) > 2 or wire.word(result, at + 12) != 0) return false;
        return true;
    }
    if (result.len != 64 or wire.word(result, 4) > (if (mode <= 4) @as(u32, 1) else 0)) return false;
    for (result[12..16]) |byte| if (byte != 0) return false;
    if (mode != 1 and wire.word(result, 8) != 0) return false;
    if (mode <= 2) {
        for (result[16..32]) |byte| if (byte != 0) return false;
    } else if (mode == 5 or mode == 6) {
        for (result[20..32]) |byte| if (byte != 0) return false;
    }
    return true;
}
fn call(request: []const u8, output: []u8, owner: Policy) []const u8 {
    const length = owner(request, output);
    if (length > output.len or !resultValid(output[0..length], request[2])) @panic("invalid compiled scene observation result");
    for (output[32..64]) |byte| if (byte != 0) @panic("invalid scene observation reserved result");
    return output[0..length];
}

pub fn diff(view: anytype, output: []canvas.DiffChange, owner: Policy) ![]const canvas.DiffChange {
    // Ask the compiled owner before observing any command identities.
    var admission: [64]u8 = undefined;
    header(&admission, 0);
    std.mem.writeInt(u64, admission[16..24], view.canvas_revision, .little);
    std.mem.writeInt(u64, admission[24..32], view.presented_canvas_revision, .little);
    wire.put(&admission, 40, 1);
    var admitted: [64]u8 = undefined;
    const decision = call(&admission, &admitted, owner);
    if (decision.len != 64 or wire.word(decision, 4) != 0 or wire.word(decision, 8) > 1) @panic("invalid scene diff admission");
    if (wire.word(decision, 8) == 0) return output[0..0];
    const previous = view.presented_canvas_commands[0..view.presented_canvas_command_count];
    const current = view.canvasDisplayList().commands;
    if (previous.len > max_count or current.len > max_count) @panic("scene observation input exceeds native storage");
    const storage = scratch.get();
    const request = storage.request[0 .. 64 + (previous.len + current.len) * 32];
    header(request, 0);
    wire.put(request, 4, @intCast(previous.len));
    wire.put(request, 8, @intCast(current.len));
    std.mem.writeInt(u64, request[16..24], view.canvas_revision, .little);
    std.mem.writeInt(u64, request[24..32], view.presented_canvas_revision, .little);
    std.mem.writeInt(u64, request[32..40], output.len, .little);
    for (previous, 0..) |entry, i| putEntry(request, 64 + i * 32, entry.id, null);
    for (current, 0..) |command, i| putEntry(request, 64 + (previous.len + i) * 32, command.objectId(), null);
    const borrowed_result = call(request, &storage.result, owner);
    // Keep the recipe owned across a bounds provider that reenters planning.
    var owned_result: [64 + max_count * 32]u8 = undefined;
    @memcpy(owned_result[0..borrowed_result.len], borrowed_result);
    const result = owned_result[0..borrowed_result.len];
    const count: usize = wire.word(result, 4);
    if (count > previous.len + current.len or result.len != 64 + count * 16) @panic("invalid scene diff action count");
    for (result[8..32]) |byte| if (byte != 0) @panic("invalid scene diff reserved result");
    var length: usize = 0;
    for (0..count) |i| {
        const at = 64 + i * 16;
        const kind = wire.word(result, at);
        const before = wire.word(result, at + 4);
        const after = wire.word(result, at + 8);
        if (kind > 2 or wire.word(result, at + 12) != 0 or
            (kind != 0 and before >= previous.len) or (kind != 1 and after >= current.len) or
            (kind == 0 and before != 0xffffffff) or (kind == 1 and after != 0xffffffff)) @panic("invalid scene diff action");
        const change: canvas.DiffChange = switch (kind) {
            0 => .{ .kind = .added, .id = current[after].objectId(), .next_index = after, .dirty_bounds = current[after].bounds() },
            1 => .{ .kind = .removed, .id = previous[before].id, .dirty_bounds = previous[before].bounds },
            else => .{ .kind = .changed, .id = current[after].objectId(), .previous_index = before, .next_index = after, .dirty_bounds = unionBounds(previous[before].bounds, current[after].bounds(), owner) },
        };
        // Bounds are deliberately observed before the capacity check, exactly
        // as in the native reference. Earlier complete changes remain owned.
        if (length >= output.len) return error.DiffListFull;
        output[length] = change;
        length += 1;
    }
    return output[0..length];
}

pub fn currentHasUnkeyed(commands: []const canvas.CanvasCommand, owner: Policy) bool {
    if (commands.len > max_count) @panic("scene observation input exceeds native storage");
    // Bounds providers can reenter planning; keep this probe's copied IDs
    // and continuation in native-owned storage throughout each capability.
    var owned_request: [64 + max_count * 32]u8 = undefined;
    var owned_result: [64]u8 = undefined;
    const request = owned_request[0 .. 64 + commands.len * 32];
    header(request, 1);
    wire.put(request, 8, @intCast(commands.len));
    for (commands, 0..) |command, i| putEntry(request, 64 + i * 32, command.objectId(), null);
    while (true) {
        const result = call(request, &owned_result, owner);
        if (result.len != 64 or wire.word(result, 4) > 1 or wire.word(result, 8) > commands.len) @panic("invalid scene bounds probe");
        if (wire.word(result, 4) == 1) return true;
        const next = wire.word(result, 8);
        if (next == commands.len) return false;
        if (next < wire.word(request, 12)) @panic("scene bounds probe made no progress");
        const bounds = commands[next].bounds();
        wire.put(request, 12, next + 1);
        wire.put(request, 40, if (bounds == null) 1 else 2);
    }
}

pub fn summaryHasUnkeyed(summary: anytype, owner: Policy) bool {
    if (summary.len > max_count) @panic("scene observation input exceeds native storage");
    const storage = scratch.get();
    const request = storage.request[0 .. 64 + summary.len * 32];
    header(request, 2);
    wire.put(request, 8, @intCast(summary.len));
    for (summary, 0..) |entry, i| putEntry(request, 64 + i * 32, entry.id, entry.bounds);
    const result = call(request, &storage.result, owner);
    if (result.len != 64 or wire.word(result, 4) > 1) @panic("invalid scene summary result");
    return wire.word(result, 4) == 1;
}

fn rectangles(a: ?geometry.RectF, b: ?geometry.RectF, mode: u8, owner: Policy) ?geometry.RectF {
    var request: [128]u8 = undefined;
    header(&request, mode);
    wire.put(&request, 64, @intFromBool(a != null));
    putRect(&request, 68, a orelse .{});
    wire.put(&request, 96, @intFromBool(b != null));
    putRect(&request, 100, b orelse .{});
    var output: [64]u8 = undefined;
    const result = call(&request, &output, owner);
    if (result.len != 64 or wire.word(result, 4) > 1) @panic("invalid scene bounds result");
    return if (wire.word(result, 4) == 0) null else .init(float(result, 16), float(result, 20), float(result, 24), float(result, 28));
}
pub fn unionBounds(a: ?geometry.RectF, b: ?geometry.RectF, owner: Policy) ?geometry.RectF {
    return rectangles(a, b, 3, owner);
}
pub fn projectDirty(view: geometry.RectF, dirty: geometry.RectF, owner: Policy) ?geometry.RectF {
    return rectangles(view, dirty, 4, owner);
}
pub fn colorRgba8(color: canvas.Color, owner: Policy) [4]u8 {
    var request: [128]u8 = undefined;
    header(&request, 5);
    inline for (.{ "r", "g", "b", "a" }, 0..) |field, i| wire.float(&request, 64 + i * 4, @field(color, field));
    var output: [64]u8 = undefined;
    _ = call(&request, &output, owner);
    return output[16..20].*;
}
pub fn blurExtent(macos: bool, owner: Policy) f32 {
    var request: [128]u8 = undefined;
    header(&request, 6);
    wire.put(&request, 64, @intFromBool(macos));
    var output: [64]u8 = undefined;
    _ = call(&request, &output, owner);
    return float(&output, 16);
}
fn putRect(bytes: []u8, at: usize, rect: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| wire.float(bytes, at + i * 4, @field(rect, field));
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(wire.word(bytes, at));
}
