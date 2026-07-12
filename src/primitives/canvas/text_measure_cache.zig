//! Batched text-measurement advances: one provider call per text RUN.
//!
//! Line breaking used to measure the growing line prefix once per UTF-8
//! cluster through `TextMeasureProvider.measureWidth` — O(L²) bytes
//! measured per line, one host round-trip per cluster on platforms whose
//! provider crosses an FFI boundary. This module turns that into ONE
//! batched provider call per run: the host returns per-cluster advances
//! for the whole run, and every consumer breaks lines (or sums slice
//! widths) from cumulative advances exactly the way the deterministic
//! estimator path always has.
//!
//! Advance layout contract (shared with `PlatformServices.
//! measure_text_advances_fn` and `TextMeasureProvider.measure_advances_fn`):
//! the output array is per BYTE, `text.len` entries. The advance of the
//! UTF-8 cluster starting at byte `i` is stored at index `i`; the
//! cluster's continuation bytes hold exactly 0. A slice width is
//! therefore the plain sum of its byte range (adding the interleaved
//! zeros is an exact f32 identity), and a cluster walk reads one entry
//! per lead byte — no cluster-index bookkeeping on either side.
//!
//! Caching: fetched runs are retained in a bounded, least-recently-used
//! keyed store so steady-state rebuilds of unchanged text skip the
//! provider entirely. Keys cover the text BYTES (content hash, not
//! pointer identity — retained text storage rewrites bytes in place),
//! the font id, the size, the provider identity (context + function),
//! and the global measure generation below. Runs longer than a cache
//! slot use a single uncached scratch slot (still one batched call per
//! fetch); runs longer than the scratch fall back to the caller's
//! unbatched path.
//!
//! Generation: `bumpTextMeasureGeneration` invalidates every cached
//! advance (and the retained wrap results keyed on the same generation
//! in text_spans.zig). The runtime bumps it when a font registers (the
//! host just learned a new face for an id), when the platform appearance
//! flips (theme-derived typography may re-resolve host fonts), and when
//! a runtime constructs (so a recycled provider context pointer from a
//! previous runtime in the same process can never serve stale advances).
//!
//! Thread model: storage is threadlocal, matching the runtime's
//! single-threaded frame path and the other threadlocal planner scratch
//! in this codebase (`text_layout_cache.zig`'s probe tables, the canvas
//! packet baseline scratch). Two runtimes on two threads simply keep
//! independent caches. The generation counter is a process-wide atomic
//! so an invalidation on the runtime loop thread is seen everywhere.
//!
//! Lifetime rule for returned slices: a returned advances slice aliases
//! cache (or scratch) storage and is only valid until the NEXT
//! `textRunAdvances` call on the same thread — consume it immediately;
//! never hold it across another fetch.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("root.zig");
const text_metrics = @import("text_metrics.zig");

const FontId = canvas.FontId;
const TextMeasureProvider = text_metrics.TextMeasureProvider;

/// Per-entry advance capacity in text bytes. Sized for real paragraph
/// runs (chat messages, markdown blocks); longer runs use the oversize
/// scratch slot below.
pub const max_cached_advance_run_bytes: usize = 2048;

/// Retained entries. 256 slots of 2048 f32 advances is 2 MiB of
/// threadlocal storage — the same order as the runtime's other
/// fixed-capacity pools. Capacity must exceed the hot set of runs that
/// FETCH per rebuild (wrapping paragraphs and elided labels on the
/// mounted screen; per-frame bounds only peek, see
/// `cachedTextRunAdvances`), because least-recently-used eviction
/// degrades to a 100% miss rate the moment the steadily revisited set
/// outgrows the slots — measured live as a plan-stage regression before
/// the peek/fetch split.
pub const advance_cache_capacity: usize = 256;

/// Oversize scratch: one slot covering runs up to the per-view text
/// budget (`canvas_limits.max_canvas_text_bytes_per_view`). A run this
/// long still gets ONE batched call per fetch; it just is not retained
/// across other fetches.
pub const max_batched_advance_run_bytes: usize = 32768;

/// Process-wide invalidation stamp for everything keyed on measured
/// text: cached advances here and retained wrap results downstream.
/// Starts at 1 so a zero-initialized key can never match.
///
/// The stamp is atomic so a bump on the runtime loop thread is seen by
/// every thread's threadlocal cache — except on wasm32, which has no
/// 64-bit atomics to compile and no second thread to synchronize with
/// (the docs live preview runs single-threaded by construction), so it
/// uses a plain counter behind the same accessors.
const generation_needs_atomic = !builtin.target.cpu.arch.isWasm();
var text_measure_generation: if (generation_needs_atomic) std.atomic.Value(u64) else u64 =
    if (generation_needs_atomic) std.atomic.Value(u64).init(1) else 1;

pub fn textMeasureGeneration() u64 {
    if (generation_needs_atomic) return text_measure_generation.load(.monotonic);
    return text_measure_generation;
}

pub fn bumpTextMeasureGeneration() void {
    if (generation_needs_atomic) {
        _ = text_measure_generation.fetchAdd(1, .monotonic);
    } else {
        text_measure_generation += 1;
    }
}

/// Cache key. `hash` covers the text bytes; the rest pins the exact
/// measurement context. Float size is compared by bit pattern (sizes are
/// finite positive reals here; bitwise equality is the honest identity).
const AdvanceKey = struct {
    hash: u64 = 0,
    text_len: usize = 0,
    font_id: FontId = 0,
    size_bits: u32 = 0,
    provider_context: usize = 0,
    provider_fn: usize = 0,
    generation: u64 = 0,
    used: bool = false,
};

const AdvanceEntry = struct {
    key: AdvanceKey = .{},
    last_used: u64 = 0,
};

/// The whole per-thread cache behind one lazily heap-allocated pointer:
/// at ~2.25 MiB this was the single largest block in the static TLS
/// template every OS thread's loader had to clone. Init happens on the
/// first `textRunAdvances`/`cachedTextRunAdvances` call of a thread —
/// the measuring thread by construction — so threads that never measure
/// text never allocate it. The storage arrays carry no default and stay
/// uninitialized, exactly like the `= undefined` statics they replace.
const AdvanceCache = struct {
    entries: [advance_cache_capacity]AdvanceEntry = @splat(.{}),
    storage: [advance_cache_capacity][max_cached_advance_run_bytes]f32,
    oversize_key: AdvanceKey = .{},
    oversize_storage: [max_batched_advance_run_bytes]f32,
    /// Monotonic use tick driving least-recently-used eviction.
    use_tick: u64 = 0,
    /// Fetch statistics for tests and the render benchmark: how many
    /// batched provider calls actually happened vs how many lookups were
    /// answered from retained entries.
    fetch_count: u64 = 0,
    hit_count: u64 = 0,
};
const advance_cache = @import("lazy_tls.zig").LazyTls(AdvanceCache);

pub fn textAdvanceFetchCount() u64 {
    const cache = advance_cache.peek() orelse return 0;
    return cache.fetch_count;
}

pub fn textAdvanceHitCount() u64 {
    const cache = advance_cache.peek() orelse return 0;
    return cache.hit_count;
}

fn advanceKeyFor(provider: *const TextMeasureProvider, font_id: FontId, size: f32, text: []const u8) AdvanceKey {
    return .{
        .hash = std.hash.Wyhash.hash(0x746578746164, text),
        .text_len = text.len,
        .font_id = font_id,
        .size_bits = @bitCast(size),
        .provider_context = @intFromPtr(provider.context),
        .provider_fn = if (provider.measure_advances_fn) |advances_fn| @intFromPtr(advances_fn) else 0,
        .generation = textMeasureGeneration(),
        .used = true,
    };
}

fn advanceKeysEqual(a: AdvanceKey, b: AdvanceKey) bool {
    return a.used and b.used and
        a.hash == b.hash and
        a.text_len == b.text_len and
        a.font_id == b.font_id and
        a.size_bits == b.size_bits and
        a.provider_context == b.provider_context and
        a.provider_fn == b.provider_fn and
        a.generation == b.generation;
}

/// A fetched advances array is only trustworthy if every entry is a
/// finite, non-negative number: layout accumulates them into widths, so
/// a single NaN would poison every break decision after it. Reject the
/// whole batch and let the caller fall back to the unbatched seam (which
/// carries its own per-call fallback to the estimator).
fn advancesValid(advances: []const f32) bool {
    for (advances) |advance| {
        if (!(advance >= 0) or !std.math.isFinite(advance)) return false;
    }
    return true;
}

/// Per-byte cluster advances for the whole run `text`, from the retained
/// cache or a single batched provider call. Null when the provider has
/// no batched entry, the run exceeds the scratch bound, or the host
/// declined (invalid UTF-8, unresolvable font) — callers keep their
/// existing per-prefix measurement path for those.
///
/// The returned slice aliases threadlocal storage: consume it before the
/// next call to this function.
pub fn textRunAdvances(provider: *const TextMeasureProvider, font_id: FontId, size: f32, text: []const u8) ?[]const f32 {
    if (provider.measure_advances_fn == null) return null;
    if (text.len == 0) return &.{};
    if (text.len > max_batched_advance_run_bytes) return null;

    const cache = advance_cache.get();
    const key = advanceKeyFor(provider, font_id, size, text);
    cache.use_tick += 1;

    if (text.len > max_cached_advance_run_bytes) {
        // Oversize runs: one uncached scratch slot, memoized against
        // itself so repeated fetches of the same long run (the line
        // breaker, then elision, then bounds) still pay one call.
        if (advanceKeysEqual(cache.oversize_key, key)) {
            cache.hit_count += 1;
            return cache.oversize_storage[0..text.len];
        }
        cache.oversize_key = .{};
        cache.fetch_count += 1;
        if (!provider.measureAdvances(font_id, size, text, cache.oversize_storage[0..text.len])) return null;
        if (!advancesValid(cache.oversize_storage[0..text.len])) return null;
        cache.oversize_key = key;
        return cache.oversize_storage[0..text.len];
    }

    var victim: usize = 0;
    var victim_tick: u64 = std.math.maxInt(u64);
    for (&cache.entries, 0..) |*entry, index| {
        if (advanceKeysEqual(entry.key, key)) {
            entry.last_used = cache.use_tick;
            cache.hit_count += 1;
            return cache.storage[index][0..text.len];
        }
        // Unused slots evict first (tick 0), then the least recently
        // used entry — honest bounded retention, no clock heuristics.
        const tick = if (entry.key.used) entry.last_used else 0;
        if (tick < victim_tick) {
            victim_tick = tick;
            victim = index;
        }
    }

    cache.entries[victim].key = .{};
    cache.fetch_count += 1;
    if (!provider.measureAdvances(font_id, size, text, cache.storage[victim][0..text.len])) return null;
    if (!advancesValid(cache.storage[victim][0..text.len])) return null;
    cache.entries[victim] = .{ .key = key, .last_used = cache.use_tick };
    return cache.storage[victim][0..text.len];
}

/// Peek: the run's advances IF already retained (or sitting in the
/// oversize slot), never fetching. Per-frame consumers that would
/// otherwise fetch hundreds of retained single-line runs (line-bounds
/// measurement in the frame planner) use this so a run only ever costs
/// a batched host call when something that actually breaks lines
/// fetched it — measured live, fetching from the bounds path turned one
/// memoized host width per run into one full host shape per run per
/// frame once the retained set outgrew the cache.
pub fn cachedTextRunAdvances(provider: *const TextMeasureProvider, font_id: FontId, size: f32, text: []const u8) ?[]const f32 {
    if (provider.measure_advances_fn == null) return null;
    if (text.len == 0) return &.{};
    if (text.len > max_batched_advance_run_bytes) return null;
    // Peek must not allocate a cache that nothing has fetched into yet.
    const cache = advance_cache.peek() orelse return null;
    const key = advanceKeyFor(provider, font_id, size, text);
    if (text.len > max_cached_advance_run_bytes) {
        if (advanceKeysEqual(cache.oversize_key, key)) {
            cache.hit_count += 1;
            return cache.oversize_storage[0..text.len];
        }
        return null;
    }
    for (&cache.entries, 0..) |*entry, index| {
        if (advanceKeysEqual(entry.key, key)) {
            cache.use_tick += 1;
            entry.last_used = cache.use_tick;
            cache.hit_count += 1;
            return cache.storage[index][0..text.len];
        }
    }
    return null;
}

/// Width of `advances[start..end)` — the batched twin of measuring the
/// slice through the provider. Summing in byte order visits the same
/// cluster advances in the same order a per-cluster accumulation would,
/// and the interleaved continuation zeros are exact f32 identities, so
/// the result is bit-identical to the cluster-order sum.
pub fn advanceSliceWidth(advances: []const f32, start: usize, end: usize) f32 {
    var width: f32 = 0;
    for (advances[start..end]) |advance| width += advance;
    return width;
}
