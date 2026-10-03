//! Partition the complete registered test graph without filtering test names.
const std = @import("std");
const Step = std.Build.Step;

pub fn partition(root: *Step, shards: []const *Step) void {
    std.debug.assert(shards.len > 0);
    for (shards) |shard| {
        std.debug.assert(shard != root and shard.dependencies.items.len == 0);
    }
    const original = root.dependencies.toOwnedSlice() catch @panic("OOM");
    var seen = std.AutoHashMap(*Step, void).init(root.owner.allocator);
    defer seen.deinit();
    var index: usize = 0;
    for (original) |dependency| {
        const entry = seen.getOrPut(dependency) catch @panic("OOM");
        if (entry.found_existing) continue;
        // Each registered root retains its entire dependency chain. In
        // particular, compiled app tests still run their reference first.
        shards[index % shards.len].dependOn(dependency);
        index += 1;
    }
    for (shards) |shard| root.dependOn(shard);
}

fn noOp(_: *Step, _: Step.MakeOptions) anyerror!void {}

test "new test roots and ordered app pairs survive complete graph partitioning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Step.init needs only these owner fields; no build graph is executed.
    var owner: std.Build = undefined;
    owner.allocator = arena.allocator();
    owner.debug_stack_frames_count = 0;
    var root = Step.init(.{ .id = .top_level, .name = "test", .owner = &owner, .makeFn = noOp });
    var reference = Step.init(.{ .id = .top_level, .name = "reference", .owner = &owner, .makeFn = noOp });
    var compiled = Step.init(.{ .id = .top_level, .name = "compiled", .owner = &owner, .makeFn = noOp });
    compiled.dependOn(&reference);
    var added = Step.init(.{ .id = .top_level, .name = "new suite", .owner = &owner, .makeFn = noOp });
    root.dependOn(&compiled);
    root.dependOn(&compiled); // Repeated registration must not duplicate a run.
    root.dependOn(&added);
    var first = Step.init(.{ .id = .top_level, .name = "first", .owner = &owner, .makeFn = noOp });
    var second = Step.init(.{ .id = .top_level, .name = "second", .owner = &owner, .makeFn = noOp });
    partition(&root, &.{ &first, &second });
    try std.testing.expectEqualSlices(*Step, &.{ &first, &second }, root.dependencies.items);
    try std.testing.expectEqualSlices(*Step, &.{&compiled}, first.dependencies.items);
    try std.testing.expectEqualSlices(*Step, &.{&added}, second.dependencies.items);
    try std.testing.expectEqualSlices(*Step, &.{&reference}, compiled.dependencies.items);
}
