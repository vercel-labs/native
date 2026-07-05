//! Deterministic key-lookup scratch for the per-frame planners.
//!
//! The cache planners (resources, text layouts, glyph atlas) and the
//! display-list diff all answer the same two questions per entry: "did
//! the previous frame carry this key?" and "did an earlier entry in THIS
//! frame already claim it?". Linear scans made both O(n^2) per frame —
//! at the 2048-command budget that was the dominant cost of the whole
//! frame plan (measured: ~65-70%% of engine-side interaction cost),
//! paid identically on a 1-character edit and a full scene swap.
//!
//! `HashSlots` is an open-addressing, linear-probing index of `u32`
//! entry indices (stored +1 so zero means empty) over caller-owned key
//! storage. It stores NO keys itself: callers walk the probe chain and
//! compare keys with their existing equality functions, so lookup
//! results are exactly what the old linear scans returned — the
//! LOWEST-index equal entry, because chains preserve insertion order.
//! Planner outputs are therefore byte-identical; only the search cost
//! changes.
//!
//! Capacity discipline: tables must stay at most half full, which
//! `fitsHashSlots` checks against the planner's input sizes BEFORE the
//! index path is taken; oversized inputs (library callers with bigger
//! buffers than the runtime budgets) fall back to the original linear
//! scans. Instances live in `threadlocal` scratch at the use sites —
//! the planners run on one thread at a time and the tables are reset
//! per build, the same pattern as the runtime's frame scratch.

const std = @import("std");

pub fn HashSlots(comptime slot_count: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(slot_count));
    return struct {
        slots: [slot_count]u32 = @splat(0),

        const Self = @This();

        /// Half-full bound: probe chains stay short and insertion can
        /// never wrap the table.
        pub const max_entries = slot_count / 2;

        pub fn reset(self: *Self) void {
            @memset(&self.slots, 0);
        }

        pub const Probe = struct {
            pos: usize,
        };

        pub fn probe(hash: u64) Probe {
            return .{ .pos = @intCast(hash & (slot_count - 1)) };
        }

        /// Next candidate entry index along the probe chain, or null at
        /// the first empty slot (which is where `insert` would place the
        /// key being probed for). The caller compares keys — a returned
        /// candidate is a hash-chain neighbor, not necessarily a match.
        pub fn next(self: *const Self, p: *Probe) ?u32 {
            const stored = self.slots[p.pos];
            if (stored == 0) return null;
            p.pos = (p.pos + 1) & (slot_count - 1);
            return stored - 1;
        }

        /// Insert `index` at the empty slot a fully-walked probe stopped
        /// on. Only valid right after `next` returned null for `p`.
        pub fn insert(self: *Self, p: Probe, index: u32) void {
            self.slots[p.pos] = index + 1;
        }
    };
}

/// True when inputs of the given sizes can use a `HashSlots` index
/// without exceeding the half-full bound.
pub fn fitsHashSlots(comptime slot_count: usize, len: usize) bool {
    return len <= HashSlots(slot_count).max_entries;
}

/// Below this many driving entries the linear scans win: they run in a
/// few microseconds and skip the table resets, which keeps the small-
/// view floor (a chart tick plans in ~20us total) untouched.
pub const min_entries_for_index: usize = 64;

/// 64-bit integer mix (splitmix64 finalizer) for key hashes: the id and
/// fingerprint fields feeding these tables are already well-distributed
/// or sequential ints; the mix spreads both.
pub fn mixHash(value: u64) u64 {
    var x = value;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

/// f32 hashed by bit pattern with negative zero folded onto positive
/// zero, so keys equal under float `==` always hash equal (the key
/// equality functions compare floats with `==`).
pub fn mixF32(hash: u64, value: f32) u64 {
    const normalized: f32 = if (value == 0) 0 else value;
    const bits: u32 = @bitCast(normalized);
    return mixHash(hash ^ bits);
}

test "hash slots find lowest-index equal entry" {
    var table: HashSlots(8) = .{};
    table.reset();
    const keys = [_]u64{ 7, 7, 9 };
    for (keys, 0..) |key, index| {
        var p = HashSlots(8).probe(mixHash(key));
        while (table.next(&p)) |_| {}
        table.insert(p, @intCast(index));
    }
    var p = HashSlots(8).probe(mixHash(7));
    var first_match: ?u32 = null;
    while (table.next(&p)) |candidate| {
        if (keys[candidate] == 7 and first_match == null) first_match = candidate;
    }
    try std.testing.expectEqual(@as(?u32, 0), first_match);
}
