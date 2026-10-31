//! The compiled coordinator returns caller-owned bytes before every collect.
const std = @import("std");
const invocation = @import("invocation.zig");
const sidecar = @import("sidecar.zig");
const testing = std.testing;

fn currentFacadeSource(arena: std.mem.Allocator) ![]const u8 {
    const originated = try std.mem.replaceOwned(u8, arena, sidecar.minimal_valid_json, "{\"name\": \"Model\", \"fields\":", "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\":");
    return std.mem.replaceOwned(u8, arena, originated, "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}", "{\"name\": \"label_set\", \"member\": \"value\", \"payload\": {\"kind\": \"bytes\"}}");
}

test "plans preserve raw bytes, last selection and fixed projection order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = [_][]const u8{ "corewire", "--sidecar", "old", "--profile", "p", "--facade", "f\xff", "--out", "m", "--sidecar", "input\xfe", "--out", "m2", "--effective-sidecar", "e" };
    const plan = try invocation.plan(arena, &args);
    try testing.expectEqual(@as(u8, 0), plan.exit_code);
    try testing.expectEqual(@as(?usize, 10), plan.input);
    try testing.expectEqual(@as(usize, 4), plan.outputs.len);
    try testing.expectEqualStrings("mirror", @tagName(plan.outputs[0].kind));
    try testing.expectEqual(@as(usize, 12), plan.outputs[0].path_index);
    try testing.expectEqualStrings("facade", @tagName(plan.outputs[1].kind));
    try testing.expectEqual(@as(usize, 6), plan.outputs[1].path_index);
    try testing.expectEqualStrings("profile", @tagName(plan.outputs[2].kind));
    try testing.expectEqualStrings("effective", @tagName(plan.outputs[3].kind));
    const refused = try invocation.plan(arena, &.{ "corewire", "--bad\xff" });
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
    try testing.expect(std.mem.startsWith(u8, refused.@"error", "corewire: unknown argument \"--bad\xff\"\n\nusage:"));
    try testing.expectEqualStrings("--facade", plan.outputs[1].flag);
}

test "alias facts preserve input and pair priority with raw path bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = [_][]const u8{ "a\xff", "INPUT" };
    const rows = [_][]const bool{ &.{ false, false, true }, &.{ true, false, false } };
    const pair = try invocation.aliases(arena, "input", &paths, &rows);
    try testing.expectEqualStrings("corewire: two outputs name one file (a\xff) — the later projection would overwrite the earlier\n", pair);
    const input = try invocation.aliases(arena, "input", &.{"INPUT"}, &.{&.{ true, false }});
    try testing.expectEqualStrings("corewire: output INPUT names the sidecar itself — generating would destroy the input contract\n", input);
    const identity = try invocation.aliases(arena, "input", &.{"a\xff"}, &.{&.{ true, false }});
    try testing.expectEqualStrings("corewire: output a\xff resolves to the sidecar's own file — generating would destroy the input contract\n", identity);
    try testing.expect(std.mem.indexOf(u8, pair, "a\xff") != null);
}

test "core invocation owns complete results across all alternating ABI operations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try currentFacadeSource(arena);
    var diagnostics = sidecar.Diagnostics{ .arena = arena };
    const parsed = try sidecar.read(arena, source, &diagnostics);
    const args = [_][]const u8{ "corewire", "--sidecar", "input", "--out", "mirror", "--facade", "facade", "--profile", "profile", "--effective-sidecar", "effective", "--f64-slot", "Model.count" };
    const plan = try invocation.plan(arena, &args);
    const first = try invocation.core(arena, parsed, plan, &args, .{}, source);
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    const stable = try std.json.Stringify.valueAlloc(arena, first, .{});
    const effective_copy = try arena.dupe(u8, first.effective);
    try testing.expect(std.mem.indexOf(u8, first.mirror, "count: f64,") != null);
    try testing.expect(std.mem.indexOf(u8, first.profile, "Model.count") == null);
    const untouched = try invocation.effective(arena, source, &.{});
    try testing.expectEqualStrings(source, untouched);
    for (0..4) |_| {
        const unknown = try invocation.plan(arena, &.{ "corewire", "--unknown\xff" });
        try testing.expectEqual(@as(u8, 2), unknown.exit_code);
        _ = try invocation.aliases(arena, "input", &.{"output"}, &.{&.{ false, false }});
        const projected = try invocation.effective(arena, source, &.{"Model.count"});
        try testing.expectEqualStrings(effective_copy, projected);
        const next = try invocation.core(arena, parsed, plan, &args, .{}, source);
        try testing.expectEqualStrings(stable, try std.json.Stringify.valueAlloc(arena, next, .{}));
        try testing.expectEqualStrings(stable, try std.json.Stringify.valueAlloc(arena, first, .{}));
        try testing.expectEqualStrings("--out", plan.outputs[0].flag);
        try testing.expectEqualStrings(source, untouched);
    }
}

test "invalid profile entry bytes refuse only when a profile is selected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = sidecar.Diagnostics{ .arena = arena };
    const source = try currentFacadeSource(arena);
    const parsed = try sidecar.read(arena, source, &diagnostics);
    const args = [_][]const u8{ "corewire", "--sidecar", "input", "--facade", "f\xff", "--profile", "p", "--optimization", "invalid" };
    const plan = try invocation.plan(arena, &args);
    const entry: invocation.Entry = .{ .text = "", .utf8 = false, .bytes = "f\xff" };
    const refused = try invocation.core(arena, parsed, plan, &args, entry, source);
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
    try testing.expect(std.mem.startsWith(u8, refused.@"error", "corewire: the profile's entry spelling \"f\xff\" is not valid UTF-8"));
    const facade_args = args[0..5];
    const accepted = try invocation.core(arena, parsed, try invocation.plan(arena, facade_args), facade_args, entry, source);
    try testing.expectEqual(@as(u8, 0), accepted.exit_code);
    try testing.expect(accepted.facade.len > 0);
    try testing.expectEqual(@as(usize, 0), accepted.profile.len);
    try testing.expect(std.mem.indexOf(u8, refused.@"error", "f\xff") != null);
}

test "unrelated entry facts precede UTF-8 and optimization refusals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = sidecar.Diagnostics{ .arena = arena };
    const source = try currentFacadeSource(arena);
    const parsed = try sidecar.read(arena, source, &diagnostics);
    const args = [_][]const u8{ "corewire", "--sidecar", "input", "--check", "--optimization", "bad" };
    const result = try invocation.core(arena, parsed, try invocation.plan(arena, &args), &args, .{ .unrelated = true, .utf8 = false, .facade_path = "f\xff", .profile_directory = "p\xfe" }, source);
    try testing.expectEqual(@as(u8, 2), result.exit_code);
    try testing.expect(std.mem.startsWith(u8, result.@"error", "corewire: --facade f\xff has no path relative to the --profile directory p\xfe"));
}
