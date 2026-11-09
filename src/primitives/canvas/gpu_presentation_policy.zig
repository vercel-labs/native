//! Copied capability outcomes and bounded presentation instructions. Native
//! stores state and invokes services without selecting portable policy.
const std = @import("std");
const geometry = @import("geometry");
const wire = @import("glyph_atlas_policy.zig");
pub const Policy = wire.Policy;
pub const Phase = enum(u8) { start, gathered, edits, patch, full, binary, json };
pub const Outcome = enum(u8) { ok, overflow, unsupported };
pub const Instruction = enum(u32) { gather, edits, patch, full, binary, json, done, fallback };
pub const Refusal = enum(u32) { none, missing_service, binary_overflow, json_overflow, original };
pub const Facts = struct {
    binary: bool,
    json: bool,
    current: bool = false,
    baseline_valid: bool = false,
    baseline_pixels: bool = false,
    count: usize = 0,
    upserts: usize = 0,
    generation: u64 = 0,
    surface: geometry.SizeF = .{},
    scale: f32 = 1,
    baseline_surface: geometry.SizeF = .{},
    baseline_scale: f32 = 1,
};
pub const Program = struct {
    instruction: Instruction,
    invalidate_baseline: bool,
    patch_refused: bool,
    adopt_baseline: bool,
    full_present: bool,
    refusal: Refusal,
    generation: u64,
};
/// Validate the whole envelope before interpreting selectors. Semantic
/// decisions are accepted from the compiled owner, never recomputed here.
pub fn resultValid(result: []const u8) bool {
    return result.len == 32 and wire.word(result, 0) == 1 and wire.word(result, 4) <= 7 and
        wire.word(result, 8) <= 15 and wire.word(result, 12) <= 4 and
        wire.word(result, 24) == 0 and wire.word(result, 28) == 0;
}
pub fn plan(facts: Facts, phase: Phase, outcome: Outcome, owner: Policy) Program {
    var request: [64]u8 = @splat(0);
    request[0..4].* = .{ 74, 1, @intFromEnum(phase), @intFromEnum(outcome) };
    const flags = @as(u32, @intFromBool(facts.binary)) | (@as(u32, @intFromBool(facts.json)) << 1) |
        (@as(u32, @intFromBool(facts.current)) << 2) | (@as(u32, @intFromBool(facts.baseline_valid)) << 3) |
        (@as(u32, @intFromBool(facts.baseline_pixels)) << 4);
    wire.put(&request, 4, flags);
    wire.put(&request, 8, facts.count);
    wire.put(&request, 12, facts.upserts);
    std.mem.writeInt(u64, request[16..24], facts.generation, .little);
    wire.float(&request, 24, facts.surface.width);
    wire.float(&request, 28, facts.surface.height);
    wire.float(&request, 32, facts.scale);
    wire.float(&request, 36, facts.baseline_surface.width);
    wire.float(&request, 40, facts.baseline_surface.height);
    wire.float(&request, 44, facts.baseline_scale);
    var result: [32]u8 = @splat(0xa5);
    const length = owner(&request, &result);
    if (length > result.len or !resultValid(result[0..length])) @panic("invalid compiled GPU presentation program");
    const mutations = wire.word(&result, 8);
    return .{ .instruction = @enumFromInt(wire.word(&result, 4)), .invalidate_baseline = mutations & 1 != 0, .patch_refused = mutations & 2 != 0, .adopt_baseline = mutations & 4 != 0, .full_present = mutations & 8 != 0, .refusal = @enumFromInt(wire.word(&result, 12)), .generation = std.mem.readInt(u64, result[16..24], .little) };
}

test "GPU presentation copied transport bounds instructions mutations and reserved bytes" {
    var result: [32]u8 = @splat(0);
    wire.put(&result, 0, 1);
    try std.testing.expect(resultValid(&result));
    for ([_]usize{ 0, 4, 8, 12, 24, 28 }) |at| {
        var bad = result;
        wire.put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&bad));
    }
    for (0..result.len) |length| try std.testing.expect(!resultValid(result[0..length]));
}
