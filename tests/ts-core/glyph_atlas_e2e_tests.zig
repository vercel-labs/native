const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var crossings: usize = 0;
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 61) crossings += 1;
    return core.nativeWindowPolicy(request, output);
}
fn compare(commands: []const c.CanvasCommand, capacity: usize) !void {
    const a = try std.testing.allocator.alloc(c.GlyphAtlasEntry, capacity);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(c.GlyphAtlasEntry, capacity);
    defer std.testing.allocator.free(b);
    var reference = c.GlyphAtlasPlanner.init(a);
    var candidate = c.GlyphAtlasPlanner.init(b);
    const list = c.DisplayList{ .commands = commands };
    const native = reference.build(list);
    crossings = 0;
    const compiled = candidate.buildCompiled(list, observed);
    if (native) |plan| try exact(plan, try compiled) else |err| try std.testing.expectError(err, compiled);
    try std.testing.expectEqual(@as(usize, 1), crossings);
    try exact(reference.len, candidate.len);
    try exact(a[0..reference.len], b[0..candidate.len]);
    // Every field is copied before another call resets the result arena.
    const view = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    try exact(a[0..reference.len], b[0..candidate.len]);
    core.rt.frameReset();
}
fn run(bytes: []const u8, font: u64, size: f32, x: f32, y: f32, glyphs: []const c.Glyph) c.CanvasCommand {
    return .{ .draw_text = .{ .id = 1, .font_id = font, .size = size, .origin = .{ .x = x, .y = y }, .color = c.Color.rgb8(1, 2, 3), .text = bytes, .glyphs = glyphs } };
}
test "compiled glyph atlas preserves complete malformed text entries order and capacity partial state" {
    _ = core.initialModel();
    var bytes: [4]u8 = undefined;
    for (0..256) |lead| {
        bytes = .{ @intCast(lead), 0x80, 'A', 0xbf };
        const commands = [_]c.CanvasCommand{ .{ .pop_clip = {} }, run(&bytes, 0xf123456789abcdef, 13.25, -0.25, 1.2499999, &.{}), run(&bytes, 0xf123456789abcdef, 13.25, -0.25, 1.2499999, &.{}) };
        for ([_]usize{ 0, 1, 2, 8 }) |capacity| try compare(&commands, capacity);
    }
    for ([_][]const u8{ "", " \n\t\r", "A café 🙂 界 →", "\xc0\x80\xed\xa0\x80\xf4\x90\x80\x80", "\xe2\x80", "\x80\x81\xbfA", "A\x80\x80B" }) |text| {
        for ([_]f32{ -0.0, 0, -13.25, 13.25, 16777216 }) |size| {
            const commands = [_]c.CanvasCommand{run(text, 0x100000001, size, -0.25000003, 0.99999994, &.{})};
            for ([_]usize{ 0, 1, 3, 32 }) |capacity| try compare(&commands, capacity);
        }
    }
}
test "compiled glyph atlas preserves shaped font overrides signed zero nonfinite and subpixel edges" {
    _ = core.initialModel();
    const glyphs = [_]c.Glyph{ .{ .id = 7, .x = 0.25, .y = -0.5 }, .{ .id = 7, .font_id = 0x100000002, .x = -0.25, .y = 0.5 }, .{ .id = 0xffffffff, .x = 16777216, .y = -16777216 }, .{ .id = 7, .x = 0.25, .y = -0.5 } };
    for ([_]f32{ -0.0, 0, 0.125, -13.25, 13.25, std.math.inf(f32), std.math.nan(f32) }) |size| {
        for ([_]f32{ -1.0000001, -1, -0.75000006, -0.75, -0.25000003, -0.25, -0.0, 0.24999999, 0.25, 0.99999994, 1, 16777216, std.math.inf(f32), std.math.nan(f32) }) |origin| {
            const commands = [_]c.CanvasCommand{ run("ignored", 0xffffffffffffffff, size, origin, origin, &glyphs), run("", 0xffffffffffffffff, size, origin, origin, &glyphs) };
            for ([_]usize{ 0, 1, 3, 8 }) |capacity| try compare(&commands, capacity);
        }
    }
    const commands = [_]c.CanvasCommand{ run("", 5, -0.0, 0, 0, glyphs[0..1]), run("", 5, 0.0, 0, 0, glyphs[0..1]) };
    try compare(&commands, 1);
}
test "compiled glyph atlas indexed collisions high identities oversized linear path and cache retention agree" {
    _ = core.initialModel();
    const glyphs = try std.testing.allocator.alloc(c.Glyph, 8300);
    defer std.testing.allocator.free(glyphs);
    for (glyphs, 0..) |*glyph, i| glyph.* = .{ .id = @intCast(i % 257), .font_id = 0xf123456700000000 + i % 73, .x = @as(f32, @floatFromInt(i % 13)) / 4.0, .y = -0.25 };
    const commands = [_]c.CanvasCommand{ run("", 1, 13.25, 0.25, 0, glyphs), run("", 1, 13.25, 0.25, 0, glyphs) };
    for ([_]usize{ 0, 1, 63, 64, 257, 8192, 8300 }) |capacity| try compare(&commands, capacity);
    var entries: [512]c.GlyphAtlasEntry = undefined;
    const list = c.DisplayList{ .commands = &.{run("AA café 🙂 界", 0x100000001, 13.25, -0.25, 0.5, &.{})} };
    const plan = try list.glyphAtlasPlanWithPolicy(&entries, observed);
    var old: [512]c.GlyphAtlasCacheEntry = undefined;
    for (plan.entries, 0..) |entry, i| old[i] = .{ .key = entry.key, .last_used_frame = 0xfffffffffffffff0 };
    var a: [512]c.GlyphAtlasCacheEntry = undefined;
    var b: [512]c.GlyphAtlasCacheEntry = undefined;
    var aa: [512]c.GlyphAtlasCacheAction = undefined;
    var ba: [512]c.GlyphAtlasCacheAction = undefined;
    for ([_]u64{ 0, 0xfffffffffffffff1, 0xffffffffffffffff }) |frame| {
        try exact(try plan.cachePlanWithRetention(old[0..plan.entries.len], frame, 2, &a, &aa), try plan.cachePlanWithPolicy(core.nativeWindowPolicy, old[0..plan.entries.len], frame, 2, &b, &ba));
    }
    core.rt.frameReset();
}
