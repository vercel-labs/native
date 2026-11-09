const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;

fn checkText(plans: []const canvas.TextLayoutPlan, old: []const canvas.TextLayoutCacheEntry, capacity: usize, actions: usize, frame: u64, retention: u64) !void {
    const allocator = std.testing.allocator;
    const a = try allocator.alloc(canvas.TextLayoutCacheEntry, capacity);
    defer allocator.free(a);
    const b = try allocator.alloc(canvas.TextLayoutCacheEntry, capacity);
    defer allocator.free(b);
    const aa = try allocator.alloc(canvas.TextLayoutCacheAction, actions);
    defer allocator.free(aa);
    const ba = try allocator.alloc(canvas.TextLayoutCacheAction, actions);
    defer allocator.free(ba);
    var reference = canvas.TextLayoutCachePlanner.init(a, aa);
    var candidate = canvas.TextLayoutCachePlanner.init(b, ba);
    const native = reference.buildMany(plans, old, frame, retention);
    const compiled = candidate.buildCompiled(.{ .plans = plans }, old, frame, retention, core.nativeWindowPolicy);
    if (native) |plan| try exact(plan, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(reference.entry_len, candidate.entry_len);
    try exact(reference.action_len, candidate.action_len);
    try exact(a[0..reference.entry_len], b[0..candidate.entry_len]);
    try exact(aa[0..reference.action_len], ba[0..candidate.action_len]);
}
fn checkGlyph(plans: []const canvas.GlyphAtlasEntry, old: []const canvas.GlyphAtlasCacheEntry, capacity: usize, actions: usize, frame: u64, retention: u64) !void {
    const allocator = std.testing.allocator;
    const a = try allocator.alloc(canvas.GlyphAtlasCacheEntry, capacity);
    defer allocator.free(a);
    const b = try allocator.alloc(canvas.GlyphAtlasCacheEntry, capacity);
    defer allocator.free(b);
    const aa = try allocator.alloc(canvas.GlyphAtlasCacheAction, actions);
    defer allocator.free(aa);
    const ba = try allocator.alloc(canvas.GlyphAtlasCacheAction, actions);
    defer allocator.free(ba);
    var reference = canvas.GlyphAtlasCachePlanner.init(a, aa);
    var candidate = canvas.GlyphAtlasCachePlanner.init(b, ba);
    const native = reference.build(.{ .entries = plans }, old, frame, retention);
    const compiled = candidate.buildCompiled(.{ .entries = plans }, old, frame, retention, core.nativeWindowPolicy);
    if (native) |plan| try exact(plan, try compiled) else |err| try std.testing.expectError(err, compiled);
    try exact(reference.entry_len, candidate.entry_len);
    try exact(reference.action_len, candidate.action_len);
    try exact(a[0..reference.entry_len], b[0..candidate.entry_len]);
    try exact(aa[0..reference.action_len], ba[0..candidate.action_len]);
}
fn textKey(id: u64, value: f32) canvas.TextLayoutKey {
    return .{ .font_id = 9007199254740993, .fingerprint = id, .size = value, .origin = .init(1.125, -0.0), .max_width = 99.5, .line_height = 17.25, .wrap = .word, .alignment = .end, .overflow = .clip, .text_len = 9007199254740995, .glyph_count = 9007199254740997 };
}
fn glyphKey(id: u32, value: f32) canvas.GlyphAtlasKey {
    return .{ .font_id = 9007199254740993, .glyph_id = id, .size = value, .subpixel_x = 255, .subpixel_y = 17 };
}
test "compiled text cache preserves complete keys bounds lines order and capacity-error partial state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const lines = [_]canvas.TextLine{ .{}, .{} };
    const current = [_]canvas.TextLayoutPlan{ .{ .key = textKey(9, 12), .layout = .{ .lines = &lines, .bounds = .init(-1, 2, 99, 31) } }, .{ .key = textKey(9, 12) }, .{ .key = textKey(10, 12) } };
    const old = [_]canvas.TextLayoutCacheEntry{ .{ .key = textKey(9, 12), .line_count = 90, .last_used_frame = 1 }, .{ .key = textKey(9, 12), .last_used_frame = 8 }, .{ .key = textKey(11, 12), .bounds = .init(2, 3, 4, 5), .last_used_frame = 9 }, .{ .key = textKey(11, 12), .last_used_frame = 9 }, .{ .key = textKey(12, 12), .last_used_frame = 1 } };
    for ([_]usize{ 0, 1, 2, 3, 9 }) |capacity| for ([_]usize{ 0, 1, 2, 3, 9 }) |actions| try checkText(&current, &old, capacity, actions, 10, 2);
}
test "compiled glyph cache preserves full keys duplicate first matches and capacity-error partial state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const current = [_]canvas.GlyphAtlasEntry{ .{ .key = glyphKey(1, 12), .command_index = 8, .glyph_index = 2 }, .{ .key = glyphKey(1, 12), .command_index = 9, .glyph_index = 3 }, .{ .key = glyphKey(2, 12), .command_index = 10, .glyph_index = 4 } };
    const old = [_]canvas.GlyphAtlasCacheEntry{ .{ .key = glyphKey(1, 12), .last_used_frame = 1 }, .{ .key = glyphKey(1, 12), .last_used_frame = 8 }, .{ .key = glyphKey(3, 12), .last_used_frame = 9 }, .{ .key = glyphKey(3, 12), .last_used_frame = 9 }, .{ .key = glyphKey(4, 12), .last_used_frame = 1 } };
    for ([_]usize{ 0, 1, 2, 3, 9 }) |capacity| for ([_]usize{ 0, 1, 2, 3, 9 }) |actions| try checkGlyph(&current, &old, capacity, actions, 10, 2);
}
test "compiled text and glyph retention preserve exact uint64 frame age and rollback" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 1, 9007199254740993, 0xffffffffffffffff }) |frame| for ([_]u64{ 0, 1, 99, 0xffffffffffffffff }) |retention| for ([_]u64{ 0, frame, frame -| 1, frame -| 99, 0xffffffffffffffff }) |last| {
        try checkText(&.{}, &.{.{ .key = textKey(1, 12), .last_used_frame = last }}, 1, 1, frame, retention);
        try checkGlyph(&.{}, &.{.{ .key = glyphKey(1, 12), .last_used_frame = last }}, 1, 1, frame, retention);
    };
}
test "compiled text and glyph caches preserve NaN infinity and signed-zero equality" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -0.0, 0, 12.125 }) |value| {
        try checkText(&.{ .{ .key = textKey(1, value) }, .{ .key = textKey(1, value) } }, &.{.{ .key = textKey(1, value), .last_used_frame = 10 }}, 9, 9, 10, 2);
        try checkGlyph(&.{ .{ .key = glyphKey(1, value), .command_index = 0, .glyph_index = 0 }, .{ .key = glyphKey(1, value), .command_index = 1, .glyph_index = 0 } }, &.{.{ .key = glyphKey(1, value), .last_used_frame = 10 }}, 9, 9, 10, 2);
    }
    try checkText(&.{.{ .key = textKey(1, -0.0) }}, &.{.{ .key = textKey(1, 0), .last_used_frame = 9 }}, 9, 9, 10, 2);
    try checkGlyph(&.{.{ .key = glyphKey(1, -0.0), .command_index = 0, .glyph_index = 0 }}, &.{.{ .key = glyphKey(1, 0), .last_used_frame = 9 }}, 9, 9, 10, 2);
}
test "compiled caches preserve indexed and oversized-library lookup order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const allocator = std.testing.allocator;
    for ([_]usize{ 63, 64, 2048, 4097 }) |count| {
        const current = try allocator.alloc(canvas.TextLayoutPlan, count);
        defer allocator.free(current);
        const old = try allocator.alloc(canvas.TextLayoutCacheEntry, count);
        defer allocator.free(old);
        for (current, old, 0..) |*p, *q, i| {
            p.* = .{ .key = textKey(9007199254740993 + i / 2, 12) };
            q.* = .{ .key = p.key, .last_used_frame = 9, .line_count = i };
        }
        try checkText(current, old, count, count * 2, 10, 2);
    }
    for ([_]usize{ 63, 64, 8192, 16385 }) |count| {
        const current = try allocator.alloc(canvas.GlyphAtlasEntry, count);
        defer allocator.free(current);
        const old = try allocator.alloc(canvas.GlyphAtlasCacheEntry, count);
        defer allocator.free(old);
        for (current, old, 0..) |*p, *q, i| {
            p.* = .{ .key = glyphKey(@intCast(i / 2), 12), .command_index = i, .glyph_index = i };
            q.* = .{ .key = p.key, .last_used_frame = 9 };
        }
        try checkGlyph(current, old, count, count * 2, 10, 2);
    }
}
test "compiled cache policy preserves borrowed app model and view bytes" {
    _ = core.initialModel();
    const borrowed = core.modelSnapshot();
    defer core.rt.frameReset();
    const before = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(before);
    try checkText(&.{.{ .key = textKey(1, 12) }}, &.{}, 1, 1, 10, 2);
    try checkGlyph(&.{.{ .key = glyphKey(1, 12), .command_index = 0, .glyph_index = 0 }}, &.{}, 1, 1, 10, 2);
    try std.testing.expectEqualSlices(u8, before, borrowed);
}

test "text and glyph cache planning cost is measured beside the native reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var plans: [128]canvas.TextLayoutPlan = undefined;
    var old: [128]canvas.TextLayoutCacheEntry = undefined;
    var glyphs: [128]canvas.GlyphAtlasEntry = undefined;
    var old_glyphs: [128]canvas.GlyphAtlasCacheEntry = undefined;
    for (0..128) |i| {
        plans[i] = .{ .key = textKey(i, 12) };
        old[i] = .{ .key = plans[i].key, .last_used_frame = 9 };
        glyphs[i] = .{ .key = glyphKey(@intCast(i), 12), .command_index = i, .glyph_index = i };
        old_glyphs[i] = .{ .key = glyphs[i].key, .last_used_frame = 9 };
    }
    var entries: [256]canvas.TextLayoutCacheEntry = undefined;
    var actions: [256]canvas.TextLayoutCacheAction = undefined;
    var glyph_entries: [256]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_actions: [256]canvas.GlyphAtlasCacheAction = undefined;
    for ([_]?*const fn ([]const u8, []u8) usize{ null, core.nativeWindowPolicy }, 0..) |policy, lane| {
        const begin = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..100) |_| {
            const text = try (canvas.TextLayoutPlanSet{ .plans = &plans }).cachePlanWithPolicy(policy, &old, 10, 2, &entries, &actions);
            const glyph = try (canvas.GlyphAtlasPlan{ .entries = &glyphs }).cachePlanWithPolicy(policy, &old_glyphs, 10, 2, &glyph_entries, &glyph_actions);
            std.mem.doNotOptimizeAway(text);
            std.mem.doNotOptimizeAway(glyph);
            core.rt.frameReset();
        }
        const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - begin;
        std.debug.print("128-layout/128-glyph cache pair lane {d}: {d} ns (including copying and enclosing reset)\n", .{ lane, @divTrunc(elapsed, 100) });
    }
}
