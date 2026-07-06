//! Unit tests for the variable-extent offset table: estimate→measure
//! convergence, the anchoring invariant, prepend/truncation identity,
//! and the measured-store budget (one past capacity evicts, never
//! fails).

const std = @import("std");
const testing = std.testing;
const virtual_extents = @import("virtual_extents.zig");

const VirtualExtentTable = virtual_extents.VirtualExtentTable;

/// The wildly-variable test corpus: extents from one line (~18pt) to a
/// hundred lines (~1800pt), deterministic per index. The ESTIMATE is
/// deliberately rough (rounded to 50pt bands) so measurements have real
/// corrections to apply.
fn actualExtent(index: u64) f32 {
    const seed = std.hash.Wyhash.hash(0xeaea_0001, std.mem.asBytes(&index));
    const lines = 1 + seed % 100;
    return 18 * @as(f32, @floatFromInt(lines));
}

fn roughEstimate(context: ?*const anyopaque, index: u64) f32 {
    _ = context;
    const actual = actualExtent(index);
    return @max(50, @round(actual / 50) * 50 - 25);
}

fn exactEstimate(context: ?*const anyopaque, index: u64) f32 {
    _ = context;
    return actualExtent(index);
}

fn syncArgs(count: usize, base: u64) virtual_extents.VirtualExtentSyncArgs {
    return .{
        .id = 7,
        .item_count = count,
        .index_base = base,
        .gap = 8,
        .estimate_fn = roughEstimate,
    };
}

fn createTable() !*VirtualExtentTable {
    const table = try testing.allocator.create(VirtualExtentTable);
    table.* = .{};
    return table;
}

test "offsets are monotone prefix sums over estimates, gaps included" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    const info = table.sync(syncArgs(10_000, 0));
    try testing.expect(info.fresh);

    try testing.expectEqual(@as(f32, 0), table.offsetAtPhysical(0));
    var expected: f32 = 0;
    for (0..64) |i| {
        try testing.expectApproxEqAbs(expected, table.offsetAtPhysical(i), 0.01);
        expected += roughEstimate(null, @intCast(i)) + 8;
    }
    // Chunk-boundary crossing agrees with the linear sum.
    try testing.expectApproxEqAbs(expected, table.offsetAtPhysical(64), 0.01);

    // indexAtOffset inverts offsetAtPhysical across the corpus.
    for ([_]usize{ 0, 1, 63, 64, 65, 500, 9_999 }) |i| {
        const edge = table.offsetAtPhysical(i);
        try testing.expectEqual(i, table.indexAtOffset(edge));
        try testing.expectEqual(i, table.indexAtOffset(edge + 1));
    }
}

test "measured corrections converge the total extent to truth for the visited range" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    _ = table.sync(syncArgs(200, 0));

    var true_total: f32 = 0;
    for (0..200) |i| true_total += actualExtent(@intCast(i));
    true_total += 8 * 199;

    // Estimates alone are off by a real margin somewhere.
    try testing.expect(@abs(table.totalExtent() - true_total) > 1);

    // Visit the whole list in mounted-window-sized batches, the way
    // the measure step does.
    var start: usize = 0;
    while (start < 200) : (start += 20) {
        table.beginCorrections(start, null);
        for (start..@min(200, start + 20)) |i| {
            table.recordMeasured(i, actualExtent(@intCast(i)));
        }
        table.endCorrections();
        _ = table.takePendingOffsetDelta();
    }

    // Fully visited: the geometry is exact.
    try testing.expectApproxEqAbs(true_total, table.totalExtent(), 0.5);
    var expected: f32 = 0;
    for (0..200) |i| {
        try testing.expectApproxEqAbs(expected, table.offsetAtPhysical(i), 0.5);
        expected += actualExtent(@intCast(i)) + 8;
    }
}

test "anchoring invariant: corrections shift the offset by exactly the anchor's displacement" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    _ = table.sync(syncArgs(1_000, 0));

    // The user is looking at item 500 with 30pt of it above the fold.
    const anchor: usize = 500;
    const scroll_offset = table.offsetAtPhysical(anchor) + 30;
    const anchor_screen_position = table.offsetAtPhysical(anchor) - scroll_offset;

    // A correction batch lands for the mounted window (items above and
    // below the anchor both correct).
    table.beginCorrections(anchor, null);
    for (495..520) |i| table.recordMeasured(i, actualExtent(@intCast(i)));
    table.endCorrections();

    // The anchored row's screen position is invariant once the pending
    // delta is applied to the offset — bit-for-bit the definition the
    // engine uses.
    const corrected_offset = scroll_offset + table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(
        anchor_screen_position,
        table.offsetAtPhysical(anchor) - corrected_offset,
        0.001,
    );

    // Corrections strictly BELOW the viewport leave the offset alone.
    table.beginCorrections(anchor, null);
    for (800..830) |i| table.recordMeasured(i, actualExtent(@intCast(i)));
    table.endCorrections();
    try testing.expectEqual(@as(f32, 0), table.takePendingOffsetDelta());
}

test "prepend keeps logical identity: measured extents survive and the offset delta glues the viewport" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    _ = table.sync(syncArgs(100, 1_000));

    // Measure the visible head of the transcript.
    table.beginCorrections(0, null);
    for (0..10) |i| table.recordMeasured(i, actualExtent(@intCast(1_000 + i)));
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    const measured_zero = table.extentAtPhysical(0);
    const offset_of_first = table.offsetAtPhysical(0);
    try testing.expectEqual(@as(f32, 0), offset_of_first);

    // Load 50 older items: base 1000 -> 950, count 100 -> 150.
    const info = table.sync(syncArgs(150, 950));
    try testing.expect(info.prepended);

    // The old first item is physical 50 now, same logical id, same
    // measured extent.
    try testing.expectApproxEqAbs(measured_zero, table.extentAtPhysical(50), 0.001);
    // The pending delta equals the prepended extent, so `offset +
    // delta` shows the exact same content.
    const delta = table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(table.offsetAtPhysical(50), offset_of_first + delta, 0.01);
}

test "head truncation drops stale measurements and pulls the offset back" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    _ = table.sync(syncArgs(100, 0));

    table.beginCorrections(0, null);
    for (0..20) |i| table.recordMeasured(i, actualExtent(@intCast(i)));
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    const removed_extent = table.offsetAtPhysical(10);
    const kept_measured = table.extentAtPhysical(15);

    // Compact the first 10 rows away: base 0 -> 10, count 100 -> 90.
    _ = table.sync(syncArgs(90, 10));
    const delta = table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(-removed_extent, delta, 0.01);
    // Logical 15 is physical 5 now and keeps its measurement.
    try testing.expectApproxEqAbs(kept_measured, table.extentAtPhysical(5), 0.001);
}

test "measured budget: one past capacity evicts the farthest entry, never fails" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    const count = virtual_extents.max_virtual_measured_items + 64;
    _ = table.sync(syncArgs(count, 0));

    // Fill the store to exactly capacity with real corrections (the
    // rough estimate is never within the epsilon of the actual).
    for (0..virtual_extents.max_virtual_measured_items) |i| {
        table.beginCorrections(i, null);
        table.recordMeasured(i, actualExtent(@intCast(i)));
        table.endCorrections();
    }
    _ = table.takePendingOffsetDelta();
    try testing.expectEqual(virtual_extents.max_virtual_measured_items, table.measured_count);

    // One past: anchored at the tail, the farthest-from-anchor entry
    // (index 0) is evicted, the newcomer lands, and the store stays at
    // capacity with coherent geometry.
    const newcomer = virtual_extents.max_virtual_measured_items;
    table.beginCorrections(newcomer, null);
    table.recordMeasured(newcomer, actualExtent(@intCast(newcomer)));
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    try testing.expectEqual(virtual_extents.max_virtual_measured_items, table.measured_count);
    try testing.expectEqual(@as(u64, 1), table.measured_index[0]);
    try testing.expectApproxEqAbs(actualExtent(newcomer), table.extentAtPhysical(newcomer), 0.001);
    // Item 0 drifted back to its estimate — the documented budget
    // behavior, not a failure.
    try testing.expectApproxEqAbs(roughEstimate(null, 0), table.extentAtPhysical(0), 0.001);

    // A far-away incoming measurement while anchored near the store's
    // center is the farthest itself: dropped, store unchanged.
    table.beginCorrections(newcomer / 2, null);
    table.recordMeasured(count - 1, actualExtent(@intCast(count - 1)));
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(roughEstimate(null, @intCast(count - 1)), table.extentAtPhysical(count - 1), 0.001);
}

test "re-measuring a changed row updates in place through the epsilon band" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    _ = table.sync(syncArgs(50, 0));

    table.beginCorrections(0, null);
    table.recordMeasured(5, 300);
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(@as(f32, 300), table.extentAtPhysical(5), 0.001);

    // Within epsilon: ignored (no churn from metric jitter).
    table.beginCorrections(0, null);
    table.recordMeasured(5, 300.1);
    table.endCorrections();
    try testing.expectApproxEqAbs(@as(f32, 300), table.extentAtPhysical(5), 0.001);

    // A real change (an edited row) re-corrects in place.
    table.beginCorrections(0, null);
    table.recordMeasured(5, 120);
    table.endCorrections();
    _ = table.takePendingOffsetDelta();
    try testing.expectApproxEqAbs(@as(f32, 120), table.extentAtPhysical(5), 0.001);
    try testing.expect(table.measured_count == 1);
}

test "variable range: window, before-extent, and clamped offsets from estimates alone" {
    // Stateless path (no table): what bare `finalize` builds use.
    const range = virtual_extents.virtualVariableListRange(.{
        .item_count = 1_000,
        .gap = 8,
        .viewport_extent = 600,
        .scroll_offset = 0,
        .overscan = 2,
        .estimate_fn = exactEstimate,
    }, null);
    try testing.expectEqual(@as(usize, 0), range.start_index);
    try testing.expect(range.end_index > 0);
    try testing.expectEqual(@as(f32, 0), range.before_extent);

    var total: f32 = 0;
    for (0..1_000) |i| total += actualExtent(@intCast(i));
    total += 8 * 999;
    try testing.expectApproxEqAbs(total, range.content_extent, 1);

    // Deep offset: the window sits around the item at that offset and
    // before_extent equals the start item's true leading edge.
    const deep = virtual_extents.virtualVariableListRange(.{
        .item_count = 1_000,
        .gap = 8,
        .viewport_extent = 600,
        .scroll_offset = total / 2,
        .overscan = 2,
        .estimate_fn = exactEstimate,
    }, null);
    try testing.expect(deep.start_index > 0);
    try testing.expect(deep.end_index < 1_000);
    var edge: f32 = 0;
    for (0..deep.start_index) |i| edge += actualExtent(@intCast(i)) + 8;
    try testing.expectApproxEqAbs(edge, deep.before_extent, 0.5);
    // The visible span covers the viewport.
    var covered: f32 = 0;
    for (deep.first_visible_index..deep.last_visible_index + 1) |i| covered += actualExtent(@intCast(i)) + 8;
    try testing.expect(covered >= 600 - 8);

    // Overshot offsets clamp; rubber-band keeps the layout offset.
    const over = virtual_extents.virtualVariableListRange(.{
        .item_count = 10,
        .gap = 0,
        .viewport_extent = 600,
        .scroll_offset = 1_000_000,
        .estimate_fn = exactEstimate,
    }, null);
    try testing.expectEqual(@as(usize, 10), over.end_index);
    try testing.expect(over.scroll_offset <= over.content_extent);
}

test "beyond the chunk budget the tail extrapolates at the covered average" {
    const table = try createTable();
    defer testing.allocator.destroy(table);
    const count = virtual_extents.max_virtual_extent_items + 10_000;
    _ = table.sync(.{
        .id = 7,
        .item_count = count,
        .index_base = 0,
        .gap = 0,
        .uniform_estimate = 40,
    });
    // Uniform estimates make the extrapolation exact — the honest
    // budget statement is "past the budget the tail is average-priced".
    try testing.expectApproxEqAbs(@as(f32, 40) * @as(f32, @floatFromInt(count)), table.totalExtent(), 64);
    try testing.expectApproxEqAbs(@as(f32, 40) * @as(f32, @floatFromInt(count - 1)), table.offsetAtPhysical(count - 1), 64);
}
