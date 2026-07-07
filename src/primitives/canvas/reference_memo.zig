//! Memoized per-pixel command results for the reference renderer.
//!
//! Every reference-renderer command is a deterministic per-pixel
//! function: the output byte at (x, y) depends only on the command's
//! parameters, the pixel's coordinates, and the destination bytes the
//! command may read (the pixel itself for blends, a kernel-radius apron
//! around it for the backdrop blur). That purity means a command whose
//! parameters AND readable source bytes are identical to a previous run
//! must produce identical output bytes — so the renderer can replay the
//! stored result instead of re-running the loop.
//!
//! Why this exists: hosts that re-render a retained scene every frame
//! (the docs live previews) were paying the full cost of the heavyweight
//! per-pixel commands — the modal scrim's full-viewport Gaussian blur,
//! the surface drop shadow's distance field, the scrim wash's
//! full-viewport blend — for repaints that only changed a caret or a
//! line of text ABOVE those layers. With the memo, the stable layers
//! replay as row copies and only the actual change re-renders.
//!
//! Honesty contract: this is pure memoization. A hit replays bytes that
//! are equal to what re-rendering would produce, by construction of the
//! key. Rendering stays deterministic and pinned reference signatures
//! cannot move, memoized or not — the memo only moves time.
//!
//! Ownership: callers hand the renderer a memo that outlives the render
//! pass (one per live scene). Misses allocate entry pixel storage from
//! the memo's allocator; allocation failure simply skips storing — the
//! command still renders, just unmemoized.

const std = @import("std");

pub const ReferenceRenderMemo = struct {
    /// Distinct heavyweight commands one retained scene realistically
    /// carries: the tile background, the modal scrim's blur + wash, the
    /// surface shadow, fill, and border, a few control fills/borders
    /// over the threshold, and a couple of widget backdrops. Eviction is
    /// least-recently-used beyond that — an eviction loop (more stable
    /// big commands than entries) only costs time, never correctness.
    pub const max_entries: usize = 16;

    /// Everything a memoized command's output pixels are a pure function
    /// of. Two runs with equal keys produce equal bytes, so replaying
    /// the stored pixels is exact, not approximate.
    pub const Key = struct {
        surface_width: usize,
        surface_height: usize,
        rect_x: usize,
        rect_y: usize,
        rect_width: usize,
        rect_height: usize,
        /// Hash of the command's own parameters: kind, value fields,
        /// opacity, transform — everything that parametrizes the
        /// per-pixel function (built by the renderer, which knows the
        /// command types).
        params_hash: u64,
        /// Hash of every destination row the command can read before it
        /// writes: the rect expanded vertically by the read apron
        /// (kernel radius for blur, zero for single-pixel blends),
        /// full-width rows. Hashing whole rows keeps the span contiguous
        /// and is a superset of the horizontal apron — a wider hash can
        /// only cause a spurious miss, never a wrong hit.
        source_hash: u64,
    };

    const Entry = struct {
        key: Key = undefined,
        /// The command's output pixels for its rect, tightly packed
        /// RGBA8 rows (`rect_width * 4` bytes per row).
        pixels: []u8 = &.{},
        used: bool = false,
        /// LRU stamp from the memo clock; refreshed on every hit.
        stamp: u64 = 0,
    };

    allocator: std.mem.Allocator,
    entries: [max_entries]Entry = @splat(.{}),
    clock: u64 = 0,
    /// Commands smaller than this many pixels render directly: the memo
    /// trades a hash of the source region per frame for the loop, and
    /// that trade only wins on large rects. Tests may lower it to
    /// exercise the memo on small surfaces.
    min_pixels: usize = 32 * 1024,
    /// Hit/miss counters: observability for tests and profiling only.
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ReferenceRenderMemo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReferenceRenderMemo) void {
        for (&self.entries) |*entry| {
            if (entry.pixels.len > 0) self.allocator.free(entry.pixels);
            entry.* = .{};
        }
    }

    /// Build the key for a command about to run: hashes the destination
    /// rows it can read (rect expanded vertically by `apron_rows`,
    /// clamped to the surface). `source` is the surface's pixel buffer
    /// BEFORE the command writes anything.
    pub fn keyFor(
        source: []const u8,
        surface_width: usize,
        surface_height: usize,
        rect_x: usize,
        rect_y: usize,
        rect_width: usize,
        rect_height: usize,
        apron_rows: usize,
        params_hash: u64,
    ) Key {
        const apron_top = rect_y -| apron_rows;
        const apron_bottom = @min(surface_height, rect_y + rect_height + apron_rows);
        const row_bytes = surface_width * 4;
        const hashed = source[apron_top * row_bytes .. apron_bottom * row_bytes];
        return .{
            .surface_width = surface_width,
            .surface_height = surface_height,
            .rect_x = rect_x,
            .rect_y = rect_y,
            .rect_width = rect_width,
            .rect_height = rect_height,
            .params_hash = params_hash,
            .source_hash = std.hash.Wyhash.hash(0x5c72_11b8, hashed),
        };
    }

    /// The stored output pixels for this key, or null on miss. A hit
    /// refreshes the entry's LRU stamp.
    pub fn find(self: *ReferenceRenderMemo, key: Key) ?[]const u8 {
        for (&self.entries) |*entry| {
            if (!entry.used) continue;
            if (!std.meta.eql(entry.key, key)) continue;
            self.clock += 1;
            entry.stamp = self.clock;
            self.hits += 1;
            return entry.pixels;
        }
        self.misses += 1;
        return null;
    }

    /// Claim storage for this key's output pixels and return it for the
    /// caller to fill (rect rows, tightly packed). Evicts the least
    /// recently used entry when full; returns null when the allocator
    /// cannot supply the buffer (the command simply stays unmemoized).
    pub fn store(self: *ReferenceRenderMemo, key: Key) ?[]u8 {
        const byte_len = key.rect_width * key.rect_height * 4;
        if (byte_len == 0) return null;
        var victim: *Entry = &self.entries[0];
        for (&self.entries) |*entry| {
            if (!entry.used) {
                victim = entry;
                break;
            }
            if (entry.stamp < victim.stamp) victim = entry;
        }
        if (victim.pixels.len != byte_len) {
            if (victim.pixels.len > 0) self.allocator.free(victim.pixels);
            victim.pixels = &.{};
            victim.used = false;
            victim.pixels = self.allocator.alloc(u8, byte_len) catch return null;
        }
        self.clock += 1;
        victim.key = key;
        victim.stamp = self.clock;
        victim.used = true;
        return victim.pixels;
    }
};
