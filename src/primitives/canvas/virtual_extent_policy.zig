const std = @import("std");
const surface = @import("surface_layout_policy.zig");
pub const Policy = surface.Policy;
pub const Measurement = struct { physical: usize, extent: f32 };
pub const SyncPlan = struct { mode: u8, flags: u8, gap: f32, old_total: f32, first_chunk: usize, shift: usize };

/// Native owns every request/result allocation, callback and retained table.
/// Compiled policy consumes copied sparse state once per measurement batch.
/// Estimate samples and exact storage lookups are explicit native capabilities;
/// no native address or borrowed model/view slice is stored by the reducer.
pub fn sync(policy: Policy, table: anytype, args: anytype, old_total: f32) SyncPlan {
    var request = header(72, 0);
    putInt(&request, 8, table.id);
    putInt(&request, 16, args.id);
    putInt(&request, 24, table.item_count);
    putInt(&request, 32, args.item_count);
    putInt(&request, 40, table.index_base);
    putInt(&request, 48, args.index_base);
    putFloat(&request, 56, args.gap);
    putFloat(&request, 60, old_total);
    var result: [40]u8 = undefined;
    run(policy, &request, &result);
    if (result[0] > 5 or result[1] > 7) @panic("invalid compiled extent sync plan");
    return .{ .mode = result[0], .flags = result[1], .gap = getFloat(&result, 4), .old_total = getFloat(&result, 8), .first_chunk = getInt(&result, 16), .shift = getInt(&result, 24) };
}

pub fn corrections(policy: Policy, table: anytype, mode: u8, anchor: usize, rendered_offset: ?f32, rows: []const Measurement, estimate_prefix: f32, gap_extent: f32) void {
    const allocator = std.heap.page_allocator;
    const request = allocator.alloc(u8, 64 + table.measured_count * 16 + rows.len * 16) catch @panic("extent request allocation failed");
    defer allocator.free(request);
    const result = allocator.alloc(u8, 32 + @as(usize, 2048) * 16) catch @panic("extent result allocation failed");
    defer allocator.free(result);
    @memset(request, 0);
    request[0] = 10;
    request[1] = 1;
    request[2] = if (rendered_offset != null) 1 else 0;
    request[3] = mode;
    putWord(request, 4, @intCast(table.measured_count));
    putWord(request, 8, @intCast(rows.len));
    putWord(request, 12, if (table.measured_prefix_dirty) 1 else 0);
    putInt(request, 16, table.index_base);
    putInt(request, 24, table.item_count);
    putInt(request, 32, anchor);
    putFloat(request, 40, rendered_offset orelse table.anchor_offset_before);
    putFloat(request, 44, table.pending_offset_delta);
    putFloat(request, 48, table.measured_total_delta);
    putFloat(request, 52, estimate_prefix);
    putFloat(request, 56, gap_extent);
    for (0..table.measured_count) |i| {
        const at = 64 + i * 16;
        putInt(request, at, table.measured_index[i]);
        putFloat(request, at + 8, table.measured_delta[i]);
        putFloat(request, at + 12, if (table.measured_prefix_dirty) 0 else table.measured_prefix[i]);
    }
    for (rows, 0..) |row, i| {
        const at = 64 + table.measured_count * 16 + i * 16;
        putInt(request, at, row.physical);
        // Out-of-range rows never invoke the app's estimate callback.
        putFloat(request, at + 8, if (row.physical < table.item_count) table.estimateAt(row.physical) else 0);
        putFloat(request, at + 12, row.extent);
    }
    const length = policy(request, result);
    if (length < 32) @panic("truncated compiled extent correction result");
    const count = getWord(result, 24);
    if (count > 2048 or length != 32 + @as(usize, count) * 16 or getWord(result, 20) > 1 or getWord(result, 28) != 0) @panic("invalid compiled extent correction result");
    table.anchor_physical = getInt(result, 0);
    table.anchor_offset_before = getFloat(result, 8);
    table.pending_offset_delta = getFloat(result, 12);
    table.measured_total_delta = getFloat(result, 16);
    table.measured_prefix_dirty = getWord(result, 20) != 0;
    table.measured_count = count;
    for (0..count) |i| {
        const at = 32 + i * 16;
        table.measured_index[i] = getInt(result, at);
        table.measured_delta[i] = getFloat(result, at + 8);
        if (!table.measured_prefix_dirty) table.measured_prefix[i] = getFloat(result, at + 12);
    }
}

pub fn windowOffset(policy: Policy, offset: f32, pending: f32, total: f32, viewport: f32, old_total: f32, old_viewport: f32, trailing: bool, mounted: bool, retained: bool) f32 {
    var request = header(32, 2);
    request[3] = @as(u8, if (trailing) 1 else 0) | @as(u8, if (mounted) 2 else 0) | @as(u8, if (retained) 4 else 0);
    const values = [_]f32{ offset, pending, total, viewport, old_total, old_viewport };
    for (values, 0..) |value, i| putFloat(&request, 4 + i * 4, value);
    var result: [4]u8 = undefined;
    run(policy, &request, &result);
    return getFloat(&result, 0);
}
pub const Bounds = struct { active: bool, offset: f32, layout: f32, end_query: f32 };
pub fn bounds(policy: Policy, count: usize, total: f32, viewport: f32, offset: f32) Bounds {
    var request = header(32, 3);
    putInt(&request, 8, count);
    putFloat(&request, 16, total);
    putFloat(&request, 20, viewport);
    putFloat(&request, 24, offset);
    var result: [16]u8 = undefined;
    run(policy, &request, &result);
    if (getWord(&result, 0) > 1) @panic("invalid compiled extent bounds");
    return .{ .active = getWord(&result, 0) != 0, .offset = getFloat(&result, 4), .layout = getFloat(&result, 8), .end_query = getFloat(&result, 12) };
}
pub const Indices = struct { start: usize, end: usize, first: usize, last: usize };
pub fn indices(policy: Policy, count: usize, first: usize, end_probe: usize, overscan: usize) Indices {
    var request = header(48, 4);
    putInt(&request, 8, count);
    putInt(&request, 16, first);
    putInt(&request, 24, end_probe);
    putInt(&request, 32, overscan);
    var result: [32]u8 = undefined;
    run(policy, &request, &result);
    return .{ .start = getInt(&result, 0), .end = getInt(&result, 8), .first = getInt(&result, 16), .last = getInt(&result, 24) };
}
pub fn finish(policy: Policy, total: f32, end_extent: f32, before: f32, anchor: f32, offset: f32, layout: f32) [6]f32 {
    var request = header(32, 5);
    const values = [_]f32{ total, end_extent, before, anchor, offset, layout };
    for (values, 0..) |value, i| putFloat(&request, 4 + i * 4, value);
    var result: [24]u8 = undefined;
    run(policy, &request, &result);
    var output: [6]f32 = undefined;
    for (&output, 0..) |*value, i| value.* = getFloat(&result, i * 4);
    return output;
}
pub fn slot(policy: Policy, id: u64, tables: anytype, declarations: anytype) ?struct { index: usize, recycle: bool } {
    var request: [24 + 254 * 16]u8 = undefined;
    @memset(&request, 0);
    request[0] = 10;
    request[1] = 6;
    request[2] = surface.anchorFlags(0, false) >> 3;
    if (tables.len > 254 or declarations.len > 254) @panic("extent slot wire capacity");
    putWord(&request, 4, @intCast(tables.len));
    putWord(&request, 8, @intCast(declarations.len));
    putInt(&request, 16, id);
    for (tables, 0..) |table, i| putInt(&request, 24 + i * 8, table.id);
    for (declarations, 0..) |record, i| putInt(&request, 24 + (tables.len + i) * 8, record.id);
    var result: [2]u8 = undefined;
    run(policy, request[0 .. 24 + (tables.len + declarations.len) * 8], &result);
    if (result[0] > 1 or (result[1] != 255 and result[1] >= tables.len)) @panic("invalid compiled extent slot");
    return if (result[1] == 255) null else .{ .index = result[1], .recycle = result[0] != 0 };
}
pub fn undercovered(policy: Policy, count: usize, first: usize, end_probe: usize, overscan: usize, start: usize, end: usize) bool {
    var request = header(64, 7);
    const values = [_]usize{ count, first, end_probe, overscan, start, end };
    for (values, 0..) |value, i| putInt(&request, 8 + i * 8, value);
    var result: [1]u8 = undefined;
    run(policy, &request, &result);
    if (result[0] > 1) @panic("invalid compiled extent coverage");
    return result[0] != 0;
}
pub fn shift(policy: Policy, pending: f32, delta: f32, subtract: bool) f32 {
    var request = header(16, 8);
    request[3] = if (subtract) 1 else 0;
    putFloat(&request, 4, pending);
    putFloat(&request, 8, delta);
    var result: [4]u8 = undefined;
    run(policy, &request, &result);
    return getFloat(&result, 0);
}
/// Estimate callbacks are sampled by native code. Chunk arithmetic crosses
/// in batches of at most sixteen chunks, without copying retained sparse state.
pub fn rebuild(policy: Policy, table: anytype, first: usize) void {
    var cursor = first;
    while (true) {
        var request = header(24, 14);
        putInt(&request, 8, table.item_count);
        putInt(&request, 16, cursor);
        var plan: [40]u8 = undefined;
        run(policy, &request, &plan);
        const covered = getWord(&plan, 0);
        const chunks = getWord(&plan, 4);
        const chunk = getWord(&plan, 8);
        const end_chunk = getWord(&plan, 12);
        const start = getWord(&plan, 16);
        const end = getWord(&plan, 20);
        const active = getWord(&plan, 24);
        if (covered > 262144 or chunks > 4096 or chunk > end_chunk or end_chunk > chunks or end_chunk - chunk > 16 or end > covered or end < start or end - start > 1024 or active > 1) @panic("invalid compiled extent rebuild plan");
        table.covered_count = covered;
        table.chunk_count = chunks;
        if (active == 0) return;
        if (end_chunk == chunk) @panic("nonprogressing compiled extent rebuild plan");
        var facts = header(32 + 1024 * 4, 9);
        putWord(&facts, 4, end - start);
        putFloat(&facts, 8, table.chunk_prefix[chunk]);
        for (start..end) |i| putFloat(&facts, 32 + (i - start) * 4, table.estimateAt(i));
        var result: [16 * 4]u8 = undefined;
        run(policy, facts[0 .. 32 + (end - start) * 4], result[0 .. (end_chunk - chunk) * 4]);
        for (chunk..end_chunk) |i| table.chunk_prefix[i + 1] = getFloat(&result, (i - chunk) * 4);
        cursor = end_chunk;
    }
}
pub const Query = struct { prefix: f32, gap: f32, offset: f32 };
/// TypeScript selects the physical/cache/logical plan. Native reads only the
/// requested storage and callback samples and supplies exact conversion facts.
pub fn query(policy: Policy, table: anytype, index: usize, mode: u8) Query {
    const builtin = @import("builtin");
    var request = header(48, 13);
    request[3] = mode | @as(u8, if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 4 else 0);
    putInt(&request, 8, table.item_count);
    putInt(&request, 16, index);
    putInt(&request, 24, table.index_base);
    putInt(&request, 32, table.covered_count);
    putInt(&request, 40, table.chunk_count);
    var plan: [64]u8 = undefined;
    run(policy, &request, &plan);
    const physical = getInt(&plan, 0);
    const logical = getInt(&plan, 8);
    const start = getInt(&plan, 16);
    const extra = getInt(&plan, 24);
    const gap_count = getInt(&plan, 32);
    const chunk = getWord(&plan, 40);
    const count = getWord(&plan, 44);
    const tail = getWord(&plan, 48);
    const empty = getWord(&plan, 52);
    if (physical > table.item_count or chunk > table.chunk_count or count > 63 or tail > 1 or empty > 1 or start > table.covered_count or count > table.covered_count - start) @panic("invalid compiled extent query plan");
    var facts = header(40 + 63 * 4, 15);
    facts[3] = @intCast(tail | (empty << 1));
    putWord(&facts, 4, count);
    putFloat(&facts, 8, if (empty == 1) 0 else table.chunk_prefix[chunk]);
    putFloat(&facts, 12, if (empty == 1) 0 else table.chunk_prefix[table.chunk_count]);
    putFloat(&facts, 16, @floatFromInt(extra));
    putFloat(&facts, 20, @floatFromInt(table.covered_count));
    putFloat(&facts, 24, if (mode == 1) table.measuredDeltaBefore(logical) else if (mode == 2) table.measured_total_delta else 0);
    putFloat(&facts, 28, table.gap);
    putFloat(&facts, 32, @floatFromInt(gap_count));
    for (0..count) |i| putFloat(&facts, 40 + i * 4, table.estimateAt(start + i));
    var result: [12]u8 = undefined;
    run(policy, facts[0 .. 40 + count * 4], &result);
    return .{ .prefix = getFloat(&result, 0), .gap = getFloat(&result, 4), .offset = getFloat(&result, 8) };
}
pub fn prefix(policy: Policy, table: anytype, index: usize) f32 {
    return query(policy, table, index, 0).prefix;
}
pub fn scalar(policy: Policy, estimate: f32, delta: f32, gap: f32, count: usize, extent: bool) f32 {
    var request = header(24, 11);
    request[3] = if (extent) 1 else 0;
    putFloat(&request, 4, estimate);
    putFloat(&request, 8, delta);
    putFloat(&request, 12, gap);
    putFloat(&request, 16, @floatFromInt(count));
    var result: [4]u8 = undefined;
    run(policy, &request, &result);
    return getFloat(&result, 0);
}
pub fn search(policy: Policy, table: anytype, offset: f32) usize {
    const builtin = @import("builtin");
    var request = header(40, 12);
    request[3] = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 1 else 0;
    putInt(&request, 8, table.item_count);
    putFloat(&request, 32, offset);
    var result: [32]u8 = undefined;
    while (true) {
        run(policy, &request, &result);
        const active = getWord(&result, 24);
        if (active > 1) @panic("invalid compiled extent search result");
        const low = getInt(&result, 0);
        const high = getInt(&result, 8);
        const mid = getInt(&result, 16);
        if (low > high or (table.item_count != 0 and high >= table.item_count) or mid < low or mid > high) @panic("invalid compiled extent search bounds");
        if (active == 0) return low;
        putInt(&request, 16, low);
        putInt(&request, 24, high);
        putFloat(&request, 32, getFloat(&result, 28));
        putFloat(&request, 36, table.offsetAtPhysical(mid));
        request[3] |= 2;
    }
}
fn header(comptime length: usize, operation: u8) [length]u8 {
    var request = [_]u8{0} ** length;
    request[0] = 10;
    request[1] = operation;
    request[2] = surface.anchorFlags(0, false) >> 3;
    return request;
}
fn run(policy: Policy, request: []const u8, result: []u8) void {
    if (policy(request, result) != result.len) @panic("invalid compiled extent result length");
}
fn putInt(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn getInt(bytes: []const u8, at: usize) usize {
    return std.math.cast(usize, std.mem.readInt(u64, bytes[at..][0..8], .little)) orelse @panic("extent integer exceeds host range");
}
fn putWord(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn getWord(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn putFloat(bytes: []u8, at: usize, value: f32) void {
    putWord(bytes, at, @bitCast(value));
}
fn getFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(getWord(bytes, at));
}
