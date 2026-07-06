//! Variable-extent windowed virtual lists: the offset table behind
//! `Ui.virtualWindow` when rows are NOT uniform (chat transcripts,
//! mixed-height feeds, markdown-bearing lists).
//!
//! The honest contract, in one paragraph: the APP provides a cheap
//! per-item extent ESTIMATE (a fn of the item index — line counts, byte
//! counts, anything O(1)); the ENGINE measures the rows it actually
//! mounts and keeps a bounded table of measured actuals. Scroll
//! geometry (item offsets, the total content extent, index-at-offset)
//! is prefix sums over the estimates PATCHED by the measured deltas, so
//! the scrollbar converges to truth as the user visits the list. The
//! scrollbar may therefore adjust as estimates correct — that is the
//! honest behavior every virtualized-list system has — but corrections
//! NEVER move content the user is looking at: every correction batch is
//! anchored on a caller-chosen row, and the table reports the offset
//! delta that keeps that row's position invariant
//! (`pending_offset_delta`, consumed together with the patched offsets
//! at the next window computation, so offset and geometry always shift
//! atomically).
//!
//! Bookkeeping is budgeted, canvas_limits-style (fixed, documented,
//! loud):
//! - Estimate prefix sums are cached per CHUNK of
//!   `virtual_extent_chunk` items, so offset queries cost one partial
//!   chunk scan and data changes recompute only the chunks they touch.
//!   `max_virtual_extent_chunks` bounds the cache; items past the
//!   covered range extrapolate at the covered average extent (at
//!   262k+ items the extrapolation error is far below one scrollbar
//!   pixel, and it corrects itself as the tail is ever reached).
//! - Measured actuals are bounded by `max_virtual_measured_items` per
//!   list. When the table is full, the entry FARTHEST from the current
//!   anchor is evicted and that row drifts back to its estimate until
//!   revisited — bounded memory, documented drift, no failure mode.
//!
//! Items are keyed by LOGICAL index: `index_base + physical_index`.
//! A tail-anchored transcript that loads older history PREPENDS items
//! by decreasing `index_base`, so logical identities (and their
//! measured extents) never shift; the table folds the prepended extent
//! into `pending_offset_delta` so the viewport stays glued to what it
//! was showing.

const std = @import("std");

/// Per-item extent estimate: cheap, pure, O(1) — derived from model
/// facts (line counts, attachment presence), never from layout. The
/// index is LOGICAL (`index_base + physical`), so estimates stay keyed
/// to item identity across prepends.
pub const VirtualExtentEstimateFn = *const fn (context: ?*const anyopaque, index: u64) f32;

/// Items per estimate-prefix chunk. 64 keeps the partial-scan cost of
/// an offset query trivial while one chunk recompute stays cheap.
pub const virtual_extent_chunk: usize = 64;

/// Estimate-prefix chunks cached per list: 4096 chunks x 64 items
/// covers 262,144 items exactly; larger lists extrapolate the tail at
/// the covered average (see the module doc). 4096 x 4 bytes = 16 KiB
/// per list.
pub const max_virtual_extent_chunks: usize = 4096;

/// Items whose estimates the table covers exactly.
pub const max_virtual_extent_items: usize = virtual_extent_chunk * max_virtual_extent_chunks;

/// Measured actuals retained per list. A mounted window is a few dozen
/// rows, so 2048 covers ~50+ visited windows before eviction starts;
/// 2048 x (8 + 4 + 4) bytes = 32 KiB per list.
pub const max_virtual_measured_items: usize = 2048;

/// Measured extents within this many points of the current belief are
/// not corrections (text metrics jitter, snap rounding).
pub const virtual_extent_epsilon: f32 = 0.25;

fn nonNegativeFinite(value: f32) f32 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}

/// What `sync` observed about the data change since the last build —
/// enough for the caller to implement tail anchoring (stick to the
/// bottom on append) without retaining its own copy of the counts.
pub const VirtualExtentSyncInfo = struct {
    /// The table had no prior state for this list (first build, or the
    /// slot was recycled): callers should treat retained offsets as
    /// authoritative and skip anchoring heuristics.
    fresh: bool = false,
    /// Items appended at the tail (same base, count grew).
    appended: bool = false,
    /// Items prepended at the head (`index_base` decreased); their
    /// estimated extent was already folded into `pending_offset_delta`.
    prepended: bool = false,
    /// Total content extent BEFORE this sync (estimates + corrections +
    /// gaps), for was-at-bottom checks. 0 when `fresh`.
    old_total_extent: f32 = 0,
};

pub const VirtualExtentSyncArgs = struct {
    /// List identity (the virtual list's global widget id).
    id: u64,
    item_count: usize,
    /// Logical index of physical item 0. Decrease it (by the prepended
    /// count) when loading older history; increase it when the head is
    /// truncated (bounded transcripts compacting old rows away).
    index_base: u64 = 0,
    /// Vertical gap between rows (part of the stride, not of extents).
    gap: f32 = 0,
    estimate_context: ?*const anyopaque = null,
    /// Null falls back to `uniform_estimate` for every item — the seam
    /// uniform lists use when they only need tail anchoring.
    estimate_fn: ?VirtualExtentEstimateFn = null,
    uniform_estimate: f32 = 0,
};

/// The offset table for ONE variable-extent virtual list. Retained by
/// the app loop across builds (it is ~50 KiB of fixed capacity — keep
/// it off the stack); all methods are single-threaded, called from the
/// view-build/measure path only.
pub const VirtualExtentTable = struct {
    /// 0 = free slot.
    id: u64 = 0,
    item_count: usize = 0,
    index_base: u64 = 0,
    gap: f32 = 0,
    estimate_context: ?*const anyopaque = null,
    estimate_fn: ?VirtualExtentEstimateFn = null,
    uniform_estimate: f32 = 0,

    /// Number of items the chunk cache covers exactly
    /// (`min(item_count, max_virtual_extent_items)`).
    covered_count: usize = 0,
    chunk_count: usize = 0,
    /// chunk_prefix[k] = sum of estimates for physical items
    /// [0, k * virtual_extent_chunk); chunk_prefix[chunk_count] covers
    /// all `covered_count` items.
    chunk_prefix: [max_virtual_extent_chunks + 1]f32 = undefined,

    measured_count: usize = 0,
    /// LOGICAL indices, sorted ascending.
    measured_index: [max_virtual_measured_items]u64 = undefined,
    /// measured extent - estimate at patch time.
    measured_delta: [max_virtual_measured_items]f32 = undefined,
    /// measured_prefix[i] = sum of measured_delta[0..i] (EXCLUSIVE of i).
    measured_prefix: [max_virtual_measured_items]f32 = undefined,
    measured_prefix_dirty: bool = false,
    measured_total_delta: f32 = 0,

    /// The offset shift that keeps the anchored row visually fixed
    /// across the corrections applied since the last consume. The
    /// window computation adds it to the retained scroll offset and
    /// clears it — offsets and geometry move together, atomically.
    pending_offset_delta: f32 = 0,

    /// Geometry of the last window computation (total extent and the
    /// viewport it was computed for): what the trailing anchor's
    /// was-at-the-bottom check compares the retained offset against.
    /// -1 total = no build yet.
    last_build_total: f32 = -1,
    last_build_viewport: f32 = 0,

    /// Correction-batch state (between beginCorrections/endCorrections).
    anchor_physical: usize = 0,
    anchor_offset_before: f32 = 0,

    pub fn reset(self: *VirtualExtentTable) void {
        self.* = .{};
    }

    fn estimateAt(self: *const VirtualExtentTable, physical: usize) f32 {
        if (self.estimate_fn) |estimate| {
            return nonNegativeFinite(estimate(self.estimate_context, self.index_base + @as(u64, physical)));
        }
        return nonNegativeFinite(self.uniform_estimate);
    }

    /// Average covered estimate — the extrapolation extent for items
    /// past the chunk-cache budget.
    fn coveredAverage(self: *const VirtualExtentTable) f32 {
        if (self.covered_count == 0) return 0;
        return self.chunk_prefix[self.chunk_count] / @as(f32, @floatFromInt(self.covered_count));
    }

    fn rebuildChunkPrefixFrom(self: *VirtualExtentTable, first_chunk: usize) void {
        self.covered_count = @min(self.item_count, max_virtual_extent_items);
        self.chunk_count = (self.covered_count + virtual_extent_chunk - 1) / virtual_extent_chunk;
        var chunk = first_chunk;
        if (chunk > self.chunk_count) chunk = self.chunk_count;
        while (chunk < self.chunk_count) : (chunk += 1) {
            var sum: f32 = 0;
            var index = chunk * virtual_extent_chunk;
            const end = @min(self.covered_count, index + virtual_extent_chunk);
            while (index < end) : (index += 1) sum += self.estimateAt(index);
            self.chunk_prefix[chunk + 1] = self.chunk_prefix[chunk] + sum;
        }
    }

    fn rebuildMeasuredPrefix(self: *VirtualExtentTable) void {
        var sum: f32 = 0;
        for (0..self.measured_count) |i| {
            self.measured_prefix[i] = sum;
            sum += self.measured_delta[i];
        }
        self.measured_total_delta = sum;
        self.measured_prefix_dirty = false;
    }

    /// Sum of estimates for physical items [0, index).
    fn estimatePrefix(self: *const VirtualExtentTable, index: usize) f32 {
        const clamped = @min(index, self.item_count);
        if (clamped > self.covered_count) {
            const extra = @as(f32, @floatFromInt(clamped - self.covered_count));
            return self.chunk_prefix[self.chunk_count] + extra * self.coveredAverage();
        }
        const chunk = clamped / virtual_extent_chunk;
        var sum = self.chunk_prefix[chunk];
        var i = chunk * virtual_extent_chunk;
        while (i < clamped) : (i += 1) sum += self.estimateAt(i);
        return sum;
    }

    /// Sum of measured deltas for logical indices < `logical`.
    fn measuredDeltaBefore(self: *const VirtualExtentTable, logical: u64) f32 {
        std.debug.assert(!self.measured_prefix_dirty);
        // Lowest measured slot whose index is >= logical.
        var low: usize = 0;
        var high: usize = self.measured_count;
        while (low < high) {
            const mid = (low + high) / 2;
            if (self.measured_index[mid] < logical) low = mid + 1 else high = mid;
        }
        if (low == self.measured_count) return self.measured_total_delta;
        return self.measured_prefix[low];
    }

    fn measuredSlot(self: *const VirtualExtentTable, logical: u64) ?usize {
        var low: usize = 0;
        var high: usize = self.measured_count;
        while (low < high) {
            const mid = (low + high) / 2;
            if (self.measured_index[mid] < logical) low = mid + 1 else high = mid;
        }
        if (low < self.measured_count and self.measured_index[low] == logical) return low;
        return null;
    }

    /// Current belief about one item's extent: measured if visited,
    /// estimate otherwise.
    pub fn extentAtPhysical(self: *const VirtualExtentTable, physical: usize) f32 {
        const base = self.estimateAt(physical);
        if (self.measuredSlot(self.index_base + @as(u64, physical))) |slot| {
            return @max(0, base + self.measured_delta[slot]);
        }
        return base;
    }

    /// Leading edge of item `physical` (gaps between prior rows
    /// included).
    pub fn offsetAtPhysical(self: *const VirtualExtentTable, physical: usize) f32 {
        const clamped = @min(physical, self.item_count);
        return self.estimatePrefix(clamped) +
            self.measuredDeltaBefore(self.index_base + @as(u64, clamped)) +
            self.gap * @as(f32, @floatFromInt(clamped));
    }

    /// Total content extent: every extent plus the gaps between rows.
    pub fn totalExtent(self: *const VirtualExtentTable) f32 {
        if (self.item_count == 0) return 0;
        return self.estimatePrefix(self.item_count) + self.measured_total_delta +
            self.gap * @as(f32, @floatFromInt(self.item_count - 1));
    }

    /// The item whose span contains `offset` (the first visible item at
    /// a scroll offset). Monotone bisection over `offsetAtPhysical`.
    pub fn indexAtOffset(self: *const VirtualExtentTable, offset: f32) usize {
        if (self.item_count == 0) return 0;
        const target = @max(0, offset);
        // Largest index whose leading edge is <= target.
        var low: usize = 0;
        var high: usize = self.item_count - 1;
        while (low < high) {
            const mid = (low + high + 1) / 2;
            if (self.offsetAtPhysical(mid) <= target) low = mid else high = mid - 1;
        }
        return low;
    }

    /// Reconcile the table against the model's current shape. Detects
    /// appends, prepends (base decreased), head truncation (base
    /// increased), and shrinks; folds prepend/truncation extent into
    /// `pending_offset_delta` so the viewport stays put.
    pub fn sync(self: *VirtualExtentTable, args: VirtualExtentSyncArgs) VirtualExtentSyncInfo {
        std.debug.assert(args.id != 0);
        if (self.id != args.id) self.reset();
        // Estimate plumbing refreshes every build (fn/context/gap may
        // be view-local values); the cached sums only rebuild on shape
        // changes, so a stale-looking fn pointer never forces O(n).
        self.estimate_context = args.estimate_context;
        self.estimate_fn = args.estimate_fn;
        self.uniform_estimate = args.uniform_estimate;

        if (self.id == 0) {
            self.id = args.id;
            self.item_count = args.item_count;
            self.index_base = args.index_base;
            self.gap = nonNegativeFinite(args.gap);
            self.chunk_prefix[0] = 0;
            self.rebuildChunkPrefixFrom(0);
            self.rebuildMeasuredPrefix();
            return .{ .fresh = true };
        }

        var info = VirtualExtentSyncInfo{ .old_total_extent = self.totalExtent() };
        const old_base = self.index_base;
        const old_count = self.item_count;
        self.gap = nonNegativeFinite(args.gap);

        if (args.index_base < old_base) {
            // Prepend: logical identities (and measured extents) keep;
            // every retained item's offset grows by the new head's
            // extent, so the same shift keeps the viewport stable.
            // Entries past a simultaneously truncated tail drop.
            self.dropMeasuredAtOrAbove(args.index_base + @as(u64, args.item_count));
            self.index_base = args.index_base;
            self.item_count = args.item_count;
            self.rebuildChunkPrefixFrom(0);
            if (self.measured_prefix_dirty) self.rebuildMeasuredPrefix();
            const prepended_physical: usize = @intCast(@min(old_base - args.index_base, @as(u64, args.item_count)));
            self.pending_offset_delta += self.offsetAtPhysical(prepended_physical);
            info.prepended = true;
        } else if (args.index_base > old_base) {
            // Head truncation: rows scrolled the viewport up by the
            // removed extent; measured entries outside the new logical
            // range drop.
            const removed_extent = self.offsetAtPhysical(@intCast(@min(args.index_base - old_base, @as(u64, old_count))));
            self.dropMeasuredBelow(args.index_base);
            self.dropMeasuredAtOrAbove(args.index_base + @as(u64, args.item_count));
            self.index_base = args.index_base;
            self.item_count = args.item_count;
            self.rebuildChunkPrefixFrom(0);
            self.pending_offset_delta -= removed_extent;
        } else if (args.item_count > old_count) {
            // Append: only the tail chunks change.
            self.item_count = args.item_count;
            self.rebuildChunkPrefixFrom(old_count / virtual_extent_chunk);
            info.appended = true;
        } else if (args.item_count < old_count) {
            self.dropMeasuredAtOrAbove(self.index_base + @as(u64, args.item_count));
            self.item_count = args.item_count;
            self.rebuildChunkPrefixFrom(args.item_count / virtual_extent_chunk);
        }
        if (self.measured_prefix_dirty) self.rebuildMeasuredPrefix();
        return info;
    }

    fn dropMeasuredBelow(self: *VirtualExtentTable, logical: u64) void {
        var keep_from: usize = 0;
        while (keep_from < self.measured_count and self.measured_index[keep_from] < logical) keep_from += 1;
        if (keep_from == 0) return;
        const remaining = self.measured_count - keep_from;
        std.mem.copyForwards(u64, self.measured_index[0..remaining], self.measured_index[keep_from..self.measured_count]);
        std.mem.copyForwards(f32, self.measured_delta[0..remaining], self.measured_delta[keep_from..self.measured_count]);
        self.measured_count = remaining;
        self.measured_prefix_dirty = true;
    }

    fn dropMeasuredAtOrAbove(self: *VirtualExtentTable, logical: u64) void {
        while (self.measured_count > 0 and self.measured_index[self.measured_count - 1] >= logical) {
            self.measured_count -= 1;
        }
        self.measured_prefix_dirty = true;
    }

    /// Start a correction batch anchored on `anchor_physical` (the first
    /// visible row). `rendered_offset` is the anchor's ACTUAL rendered
    /// leading edge this frame — mounted rows stack at intrinsic
    /// heights, which diverge from the table's pre-measure belief
    /// exactly when unmeasured rows sit inside the window, and the
    /// anchoring invariant is about what the user SEES. Null (pure
    /// table-space callers) falls back to the table's current belief.
    /// `endCorrections` folds the anchor's post-correction offset minus
    /// this baseline into `pending_offset_delta`.
    pub fn beginCorrections(self: *VirtualExtentTable, anchor_physical: usize, rendered_offset: ?f32) void {
        std.debug.assert(!self.measured_prefix_dirty);
        self.anchor_physical = @min(anchor_physical, self.item_count);
        self.anchor_offset_before = rendered_offset orelse self.offsetAtPhysical(self.anchor_physical);
    }

    /// Record one mounted row's measured extent. No-op inside the
    /// epsilon band. When the measured store is full, the entry
    /// FARTHEST from the anchor is evicted (its row drifts back to its
    /// estimate until revisited) — the incoming measurement is dropped
    /// instead if IT is the farthest.
    pub fn recordMeasured(self: *VirtualExtentTable, physical: usize, extent: f32) void {
        if (physical >= self.item_count) return;
        const logical = self.index_base + @as(u64, physical);
        const clean = nonNegativeFinite(extent);
        const estimate = self.estimateAt(physical);
        const delta = clean - estimate;

        if (self.measuredSlot(logical)) |slot| {
            if (@abs(self.measured_delta[slot] - delta) <= virtual_extent_epsilon) return;
            self.measured_delta[slot] = delta;
            self.measured_prefix_dirty = true;
            return;
        }
        if (@abs(delta) <= virtual_extent_epsilon) return;

        if (self.measured_count >= max_virtual_measured_items) {
            const anchor_logical = self.index_base + @as(u64, self.anchor_physical);
            const first_distance = absDistance(self.measured_index[0], anchor_logical);
            const last_distance = absDistance(self.measured_index[self.measured_count - 1], anchor_logical);
            const incoming_distance = absDistance(logical, anchor_logical);
            const evict_last = last_distance >= first_distance;
            const evict_distance = if (evict_last) last_distance else first_distance;
            if (incoming_distance >= evict_distance) return;
            if (evict_last) {
                self.measured_count -= 1;
            } else {
                std.mem.copyForwards(u64, self.measured_index[0 .. self.measured_count - 1], self.measured_index[1..self.measured_count]);
                std.mem.copyForwards(f32, self.measured_delta[0 .. self.measured_count - 1], self.measured_delta[1..self.measured_count]);
                self.measured_count -= 1;
            }
            self.measured_prefix_dirty = true;
        }

        // Insert sorted (windows arrive in ascending order, so this is
        // usually an append or a near-tail insert).
        var slot = self.measured_count;
        while (slot > 0 and self.measured_index[slot - 1] > logical) : (slot -= 1) {}
        std.mem.copyBackwards(u64, self.measured_index[slot + 1 .. self.measured_count + 1], self.measured_index[slot..self.measured_count]);
        std.mem.copyBackwards(f32, self.measured_delta[slot + 1 .. self.measured_count + 1], self.measured_delta[slot..self.measured_count]);
        self.measured_index[slot] = logical;
        self.measured_delta[slot] = delta;
        self.measured_count += 1;
        self.measured_prefix_dirty = true;
    }

    /// Close the batch: refresh the delta prefix sums and record the
    /// anchor's offset shift so the next window computation moves the
    /// scroll offset by exactly the amount that keeps the anchored row
    /// where the user sees it.
    pub fn endCorrections(self: *VirtualExtentTable) void {
        if (self.measured_prefix_dirty) self.rebuildMeasuredPrefix();
        self.pending_offset_delta += self.offsetAtPhysical(self.anchor_physical) - self.anchor_offset_before;
    }

    /// The accumulated anchor-preserving offset shift, consumed exactly
    /// once per window computation.
    pub fn takePendingOffsetDelta(self: *VirtualExtentTable) f32 {
        const delta = self.pending_offset_delta;
        self.pending_offset_delta = 0;
        return delta;
    }
};

fn absDistance(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

/// Options for a variable-extent window computation (the counterpart of
/// `VirtualListOptions` for `virtualListRange`).
pub const VirtualVariableRangeOptions = struct {
    item_count: usize = 0,
    gap: f32 = 0,
    viewport_extent: f32 = 0,
    scroll_offset: f32 = 0,
    overscan: usize = 0,
    index_base: u64 = 0,
    estimate_context: ?*const anyopaque = null,
    estimate_fn: ?VirtualExtentEstimateFn = null,
    uniform_estimate: f32 = 0,
};

/// The result shape shared with the uniform path lives in tokens.zig
/// (`VirtualListRange`); this module returns plain numbers and lets the
/// caller assemble it, keeping tokens.zig byte-identical.
pub const VirtualVariableRange = struct {
    start_index: usize = 0,
    end_index: usize = 0,
    first_visible_index: usize = 0,
    last_visible_index: usize = 0,
    scroll_offset: f32 = 0,
    layout_offset: f32 = 0,
    content_extent: f32 = 0,
    before_extent: f32 = 0,
    after_extent: f32 = 0,
    /// Leading edge of `first_visible_index` — the layout anchor.
    anchor_extent: f32 = 0,
};

/// Compute the visible+overscan window for a variable-extent list. With
/// a `table` the offsets carry every measured correction; without one
/// (bare builds, plain `finalize` tests) the math runs on pure
/// estimates via a linear scan — O(item_count) worst case, fine for
/// tests, which is why app loops always install a table.
pub fn virtualVariableListRange(options: VirtualVariableRangeOptions, table: ?*const VirtualExtentTable) VirtualVariableRange {
    if (options.item_count == 0 or options.viewport_extent <= 0) return .{};
    const gap = nonNegativeFinite(options.gap);
    const viewport = options.viewport_extent;

    var scratch = VirtualExtentTable{};
    const source: *const VirtualExtentTable = table orelse blk: {
        // Stateless fallback: a throwaway estimate-only table built on
        // the spot (no measured corrections to preserve). The chunk
        // sums cost one pass over the estimates per call — bare-build
        // pricing, not app-loop pricing.
        scratch.id = 1;
        scratch.item_count = options.item_count;
        scratch.index_base = options.index_base;
        scratch.gap = gap;
        scratch.estimate_context = options.estimate_context;
        scratch.estimate_fn = options.estimate_fn;
        scratch.uniform_estimate = options.uniform_estimate;
        scratch.chunk_prefix[0] = 0;
        scratch.rebuildChunkPrefixFrom(0);
        break :blk &scratch;
    };

    const content_extent = source.totalExtent();
    const max_offset = @max(0, content_extent - viewport);
    const raw_offset = if (std.math.isFinite(options.scroll_offset)) options.scroll_offset else 0;
    const offset = std.math.clamp(@max(0, raw_offset), 0, max_offset);
    const layout_offset = std.math.clamp(raw_offset, -viewport, max_offset + viewport);

    const first_visible = @min(options.item_count - 1, source.indexAtOffset(offset));
    var visible_end = @min(options.item_count, source.indexAtOffset(offset + viewport) + 1);
    if (visible_end <= first_visible) visible_end = first_visible + 1;
    const start_index = if (first_visible > options.overscan) first_visible - options.overscan else 0;
    const end_index = @min(options.item_count, visible_end + options.overscan);

    return .{
        .start_index = start_index,
        .end_index = end_index,
        .first_visible_index = first_visible,
        .last_visible_index = visible_end - 1,
        .scroll_offset = offset,
        .layout_offset = layout_offset,
        .content_extent = content_extent,
        .before_extent = source.offsetAtPhysical(start_index),
        .after_extent = @max(0, content_extent - source.offsetAtPhysical(end_index)),
        .anchor_extent = source.offsetAtPhysical(first_visible),
    };
}
