const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = canvas.virtual_extent_policy;
const Table = canvas.VirtualExtentTable;
const Measure = canvas.VirtualExtentMeasurement;
fn pair() [2]Table {
    return .{ .{}, .{ .policy = core.nativeWindowPolicy } };
}
fn expectTables(a: *const Table, b: *const Table) !void {
    inline for (.{ "id", "item_count", "index_base", "gap", "uniform_estimate", "covered_count", "chunk_count", "measured_count", "measured_prefix_dirty", "measured_total_delta", "pending_offset_delta", "last_build_total", "last_build_viewport", "anchor_physical", "anchor_offset_before", "estimate_fn", "estimate_context" }) |field| try exact(@field(a, field), @field(b, field));
    try exact(a.chunk_prefix[0 .. a.chunk_count + 1], b.chunk_prefix[0 .. b.chunk_count + 1]);
    try exact(a.measured_index[0..a.measured_count], b.measured_index[0..b.measured_count]);
    try exact(a.measured_delta[0..a.measured_count], b.measured_delta[0..b.measured_count]);
    if (!a.measured_prefix_dirty) try exact(a.measured_prefix[0..a.measured_count], b.measured_prefix[0..b.measured_count]);
    if (!a.measured_prefix_dirty) {
        try exact(a.totalExtent(), b.totalExtent());
        for ([_]usize{ 0, 1, 63, 64, 65, 127, a.item_count / 2, a.item_count, a.item_count + 1 }) |i| {
            try exact(a.offsetAtPhysical(i), b.offsetAtPhysical(i));
            try exact(a.extentAtPhysical(i), b.extentAtPhysical(i));
        }
        for ([_]f32{ -1, -0.0, 0, 1, 63, 99, 1000, a.totalExtent(), std.math.inf(f32), std.math.nan(f32) }) |offset| try exact(a.indexAtOffset(offset), b.indexAtOffset(offset));
    }
}
fn sync(tables: *[2]Table, args: canvas.VirtualExtentSyncArgs) !void {
    const reference = tables[0].sync(args);
    try exact(reference, tables[1].sync(args));
    try expectTables(&tables[0], &tables[1]);
}
fn batch(tables: *[2]Table, anchor: usize, rendered: ?f32, rows: []const Measure) !void {
    for (tables) |*table| table.applyMeasurements(anchor, rendered, rows);
    try expectTables(&tables[0], &tables[1]);
}
const Estimate = struct {
    value: f32 = 4.125,
    fn read(context: ?*const anyopaque, index: u64) f32 {
        const self: *const Estimate = @ptrCast(@alignCast(context.?));
        return if (index % 17 == 0) std.math.nan(f32) else if (index % 19 == 0) -1 else self.value + @as(f32, @floatFromInt(index % 11)) * 0.0625;
    }
};
test "compiled extent shape reconciliation preserves all retained state and refreshed callbacks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tables = pair();
    var estimates = Estimate{};
    var args = canvas.VirtualExtentSyncArgs{ .id = 9007199254740993, .item_count = 130, .index_base = 9007199254741100, .gap = 1.125, .estimate_fn = Estimate.read, .estimate_context = &estimates };
    try sync(&tables, args);
    try batch(&tables, 65, null, &.{ .{ .physical = 2, .extent = 17.25 }, .{ .physical = 69, .extent = 0.125 }, .{ .physical = 128, .extent = 99.5 } });
    estimates.value = 8.375;
    args.gap = 2.25;
    try sync(&tables, args);
    args.item_count = 193;
    try sync(&tables, args);
    args.index_base -= 7;
    args.item_count = 190;
    try sync(&tables, args);
    args.index_base += 9;
    args.item_count = 140;
    estimates.value = 12.625;
    args.gap = 3.375;
    try sync(&tables, args);
    args.item_count = 64;
    try sync(&tables, args);
    args.item_count = 0;
    try sync(&tables, args);
    args.id += 1;
    args.item_count = 65;
    args.gap = std.math.nan(f32);
    try sync(&tables, args);
    for (&tables) |*table| table.reset();
    try sync(&tables, args);
}
test "compiled extent corrections preserve atomic dirty state epsilon and nonfinite measurements" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tables = pair();
    try sync(&tables, .{ .id = 1, .item_count = 130, .index_base = 0xfffffffffffffe00, .uniform_estimate = 10, .gap = 0.25 });
    for (&tables) |*table| table.beginCorrections(65, null);
    try expectTables(&tables[0], &tables[1]);
    for ([_]Measure{ .{ .physical = 5, .extent = 10.25 }, .{ .physical = 2, .extent = 10.250001 }, .{ .physical = 129, .extent = std.math.inf(f32) }, .{ .physical = 1, .extent = std.math.nan(f32) }, .{ .physical = 2, .extent = 10.5 }, .{ .physical = 999, .extent = 40 } }) |row| {
        for (&tables) |*table| table.recordMeasured(row.physical, row.extent);
        try expectTables(&tables[0], &tables[1]);
    }
    for (&tables) |*table| table.endCorrections();
    try expectTables(&tables[0], &tables[1]);
    try exact(tables[0].takePendingOffsetDelta(), tables[1].takePendingOffsetDelta());
    try exact(tables[0].takePendingOffsetDelta(), tables[1].takePendingOffsetDelta());
    try batch(&tables, 900, -7.125, &.{ .{ .physical = 1, .extent = 17.5 }, .{ .physical = 64, .extent = 33.125 } });
}
test "compiled extent eviction preserves farthest endpoint ties and ordered batch admission" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tables = pair();
    try sync(&tables, .{ .id = 2, .item_count = 6000, .index_base = 9007199254740993, .uniform_estimate = 8 });
    var rows: [2048]Measure = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .physical = 1000 + i, .extent = 10 + @as(f32, @floatFromInt(i % 5)) };
    try batch(&tables, 2024, null, &rows);
    try batch(&tables, 2024, null, &.{ .{ .physical = 999, .extent = 50 }, .{ .physical = 3048, .extent = 50 }, .{ .physical = 3050, .extent = 50 }, .{ .physical = 2030, .extent = 55 } });
    try batch(&tables, 1000, null, &.{ .{ .physical = 998, .extent = 30 }, .{ .physical = 1001, .extent = 100 }, .{ .physical = 999, .extent = 22 } });
    try batch(&tables, 3047, null, &.{ .{ .physical = 3050, .extent = 30 }, .{ .physical = 3047, .extent = 20 } });
}
test "compiled extent chunk budget and extrapolated tail survive prepend shrink and reset" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tables = pair();
    var args = canvas.VirtualExtentSyncArgs{ .id = 3, .item_count = 262150, .index_base = 700, .uniform_estimate = 0.125, .gap = 0.0625 };
    try sync(&tables, args);
    try batch(&tables, 262144, null, &.{ .{ .physical = 262148, .extent = 5.125 }, .{ .physical = 262143, .extent = 0 } });
    args.item_count += 70;
    try sync(&tables, args);
    args.index_base -= 1;
    try sync(&tables, args);
    args.item_count = 262143;
    try sync(&tables, args);
}
test "compiled variable ranges retain complete native records and elastic f32 bounds" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tables = pair();
    try sync(&tables, .{ .id = 4, .item_count = 140, .uniform_estimate = 7.375, .gap = 1.125 });
    try batch(&tables, 31, null, &.{ .{ .physical = 2, .extent = 50.125 }, .{ .physical = 31, .extent = 0.5 } });
    for ([_]f32{ -std.math.inf(f32), -1000, -0.0, 0, 1, 230.125, 10000, std.math.inf(f32), std.math.nan(f32) }) |offset| {
        for ([_]f32{ -1, 0, 0.125, 100.25, 900 }) |viewport| {
            for ([_]usize{ 0, 1, 63, 200 }) |overscan| {
                const options = canvas.VirtualVariableRangeOptions{ .item_count = 140, .viewport_extent = viewport, .scroll_offset = offset, .overscan = overscan };
                try exact(canvas.virtualVariableListRange(options, &tables[0]), canvas.virtualVariableListRange(options, &tables[1]));
            }
        }
    }
    const reference = canvas.VirtualVariableRangeOptions{ .item_count = 65, .index_base = 9007199254740993, .uniform_estimate = 2.5, .gap = 1, .viewport_extent = 50, .scroll_offset = 100, .overscan = 5 };
    var compiled = reference;
    compiled.policy = core.nativeWindowPolicy;
    try exact(canvas.virtualVariableListRange(reference, null), canvas.virtualVariableListRange(compiled, null));
}
test "compiled variable window consumes pending corrections and trailing pins against prior geometry" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Msg = enum { noop };
    const Context = struct {
        table: *Table,
        state: canvas.VirtualWindowState,
        fn extent(context: ?*anyopaque, _: canvas.ObjectId) ?*Table {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.table;
        }
        fn window(context: ?*anyopaque, _: canvas.ObjectId) ?canvas.VirtualWindowState {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.state;
        }
    };
    var tables = pair();
    for ([_]bool{ false, true }) |mounted| for ([_]f32{ -10, 0, 98.9, 99, 100, 200, std.math.nan(f32) }) |offset| {
        for (&tables) |*table| {
            table.reset();
            _ = table.sync(.{ .id = canvas.globalWidgetId(.scroll_view, .{ .str = "extent" }), .item_count = 50, .uniform_estimate = 10, .gap = 1 });
            table.pending_offset_delta = 7;
            table.last_build_total = 200;
            table.last_build_viewport = 100;
        }
        var ranges: [2]canvas.VirtualListRange = undefined;
        for (&tables, 0..) |*table, i| {
            var context = Context{ .table = table, .state = .{ .offset = offset, .viewport_extent = 100, .mounted = mounted } };
            var ui = canvas.Ui(Msg).init(std.testing.allocator);
            ui.virtual_window_source = Context.window;
            ui.virtual_window_context = &context;
            ui.virtual_extent_source = Context.extent;
            ui.virtual_extent_context = &context;
            ui.virtual_extent_policy = if (i == 1) core.nativeWindowPolicy else null;
            ranges[i] = ui.virtualWindow(.{ .id = "extent", .item_count = 50, .item_extent = 10, .gap = 1, .anchor = .trailing });
        }
        try exact(ranges[0], ranges[1]);
        try expectTables(&tables[0], &tables[1]);
    };
}
test "compiled extent slot and coverage decisions preserve exact identities and declared order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Identity = struct { id: u64 };
    var tables = [_]Identity{ .{ .id = 0xffffffffffffffff }, .{ .id = 9007199254740993 }, .{ .id = 11 } };
    const declarations = [_]Identity{ .{ .id = 0xffffffffffffffff }, .{ .id = 11 } };
    try std.testing.expect(policy.slot(core.nativeWindowPolicy, 0, &tables, &declarations) == null);
    try std.testing.expectEqual(@as(usize, 1), policy.slot(core.nativeWindowPolicy, 9007199254740993, &tables, &declarations).?.index);
    const recycled = policy.slot(core.nativeWindowPolicy, 14, &tables, &declarations).?;
    try std.testing.expect(recycled.recycle);
    try std.testing.expectEqual(@as(usize, 1), recycled.index);
    try std.testing.expect(policy.slot(core.nativeWindowPolicy, 14, &tables, &tables) == null);
    tables[2].id = 0;
    try std.testing.expectEqual(@as(usize, 2), policy.slot(core.nativeWindowPolicy, 14, &tables, &declarations).?.index);
    try std.testing.expect(!policy.undercovered(core.nativeWindowPolicy, 100, 30, 40, 2, 28, 43));
    try std.testing.expect(policy.undercovered(core.nativeWindowPolicy, 100, 30, 40, 2, 29, 43));
    try std.testing.expect(policy.undercovered(core.nativeWindowPolicy, 100, 30, 40, 2, 28, 42));
}

test "compiled extent hot queries use bounded scalar records and preserve borrowed core bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.modelSnapshot();
    const owned = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(owned);
    const Recorder = struct {
        var counts = [_]usize{0} ** 13;
        var bytes = [_]usize{0} ** 13;
        var largest: usize = 0;
        fn call(request: []const u8, output: []u8) usize {
            if (request.len > 1 and request[0] == 10) {
                largest = @max(largest, request.len);
                counts[request[1]] += 1;
                bytes[request[1]] += request.len;
            }
            return core.nativeWindowPolicy(request, output);
        }
    };
    Recorder.counts = [_]usize{0} ** 13;
    Recorder.bytes = [_]usize{0} ** 13;
    var table = Table{ .policy = Recorder.call };
    _ = table.sync(.{ .id = 7, .item_count = 3000, .uniform_estimate = 10, .gap = 1 });
    try std.testing.expectEqual(@as(usize, 3), Recorder.counts[9]);
    try std.testing.expect(Recorder.largest <= 4128);
    var rows: [2048]Measure = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .physical = i, .extent = 12 };
    table.applyMeasurements(20, null, &rows);
    try std.testing.expectEqual(@as(usize, 1), Recorder.counts[1]);
    try std.testing.expectEqual(@as(usize, 64 + 2048 * 16), Recorder.bytes[1]);
    Recorder.counts = [_]usize{0} ** 13;
    Recorder.bytes = [_]usize{0} ** 13;
    _ = table.sync(.{ .id = 7, .item_count = 3000, .uniform_estimate = 10, .gap = 1 });
    _ = canvas.virtualVariableListRange(.{ .item_count = 3000, .viewport_extent = 100, .scroll_offset = 1234, .overscan = 3 }, &table);
    try std.testing.expectEqual(@as(usize, 0), Recorder.counts[1]);
    try std.testing.expect(Recorder.bytes[10] <= Recorder.counts[10] * 284);
    var total: usize = 0;
    for (Recorder.bytes) |count| total += count;
    // Two logarithmic searches, each with <=63 estimate facts per step.
    // No chunk/sparse table snapshot is allowed on a hot query.
    try std.testing.expect(Recorder.counts[9] == 0);
    try std.testing.expect(Recorder.counts[12] > 0 and Recorder.counts[12] <= 26);
    try std.testing.expect(total <= 10000);
    try std.testing.expectEqualSlices(u8, owned, borrowed);
    try std.testing.expectEqualSlices(u8, owned, core.modelSnapshot());
}

test "compiled estimate queries preserve adversarial f32 grouping and exact large counts" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Rounding = struct {
        fn read(_: ?*const anyopaque, index: u64) f32 {
            return switch (index % 5) {
                0 => 16777216,
                1 => 1,
                2 => 0.125,
                3 => -0.0,
                else => std.math.inf(f32),
            };
        }
    };
    var tables = pair();
    var args = canvas.VirtualExtentSyncArgs{ .id = 71, .item_count = 2051, .estimate_fn = Rounding.read, .gap = 0.125 };
    try sync(&tables, args);
    try batch(&tables, 1023, null, &.{ .{ .physical = 64, .extent = 0.5 }, .{ .physical = 1024, .extent = 19.75 } });
    args.item_count = 2115;
    try sync(&tables, args);
    args.item_count = 1025;
    try sync(&tables, args);
    args = .{ .id = 72, .item_count = 9007199254740997, .uniform_estimate = 0.125, .gap = 0.0625 };
    try sync(&tables, args);
    for ([_]usize{ 9007199254740991, 9007199254740993, 9007199254740997 }) |index| try exact(tables[0].offsetAtPhysical(index), tables[1].offsetAtPhysical(index));
    for ([_]f32{ 1.0e12, 1.0e15, 1.0e16 }) |offset| try exact(tables[0].indexAtOffset(offset), tables[1].indexAtOffset(offset));
}
