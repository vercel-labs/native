//! Per-stage frame timing: cheap monotonic stamps around the frame
//! pipeline's stage boundaries, stored as rolling windows so automation
//! snapshots (and the render benchmark) can report p50/p90 per stage.
//!
//! Off by default and zero-cost when disabled: every stamp site reads
//! ONE bool before touching the clock, no stage ever allocates, and the
//! rings live in fixed storage on the Runtime (the house budgets style —
//! bounded, value-typed, nothing to deinit). Flip it at runtime with
//! `native automate profile on|off`, or set
//! `runtime.frame_profile.enabled` directly (the benchmark does).
//!
//! Stages fire at different rates — a scroll frame records patch/encode/
//! present but no rebuild; a keystroke records emit without a rebuild —
//! so each stage keeps its own ring and sample count instead of one
//! row per frame. Percentiles are computed only at snapshot time
//! (nearest-rank over a copied, sorted window), never in the
//! frame path.

const std = @import("std");
const runtime_clock = @import("clock.zig");
const snapshot = @import("snapshot_policy.zig");

/// Rolling window length per stage. 128 samples is ~2 s of 60 fps
/// present-side stages and a long memory for sparse stages (rebuilds),
/// while keeping the whole profile struct a few KiB of fixed storage.
pub const max_frame_profile_samples: usize = 128;

/// The instrumented stage boundaries, in pipeline order.
pub const FrameProfileStage = enum {
    /// App build fn + tree finalize (`UiApp.rebuild`'s view build).
    rebuild,
    /// Widget tree layout (`layoutWidgetTreeWithTokens`).
    layout,
    /// Runtime reconcile + invalidation diff (`setCanvasWidgetLayout`).
    reconcile,
    /// Display-list emission (widget commands, chrome-preserving refresh).
    emit,
    /// Accessibility publish (semantics -> platform nodes), which rides
    /// every owned display-list refresh.
    a11y,
    /// Canvas frame planning (render plan + cache plans + text layout).
    plan,
    /// Retained-packet patch derivation (gather + baseline diff).
    patch,
    /// Wire encode (binary patch/full/scissor or JSON).
    encode,
    /// The synchronous host present call (host-side decode + draw ride
    /// inside it on macOS; the split below attributes them).
    present,
    /// Host-side packet decode (macOS packet path, host-stamped).
    host_decode,
    /// Host-side packet draw (macOS packet path, host-stamped).
    host_draw,
    /// Present-completion cadence: the host-reported interval between
    /// consecutive completion events (`frame_interval_ns`). Not a
    /// pipeline stage — a delivery-rate channel, so a paced loop's
    /// refresh-hold (and any dropped frames: max >> p50) is measurable
    /// from the same snapshot line as the stage costs.
    interval,

    pub fn name(self: FrameProfileStage) []const u8 {
        return @tagName(self);
    }
};

pub const frame_profile_stage_count = std.enums.values(FrameProfileStage).len;

/// Snapshot-side stats for one stage: nearest-rank percentiles over the
/// current window plus the lifetime sample count.
pub const FrameProfileStageStats = struct {
    p50_us: u64 = 0,
    p90_us: u64 = 0,
    max_us: u64 = 0,
    /// Samples currently in the window (bounded by
    /// `max_frame_profile_samples`).
    window_len: usize = 0,
    /// Lifetime samples recorded since enable/reset.
    total: u64 = 0,
};

/// The profile state itself: one bool gate plus per-stage rings. Lives
/// by value on the Runtime and initialized explicitly by `Runtime.initAt`.
pub const FrameProfile = struct {
    /// The runtime toggle (`native automate profile on|off`). Every
    /// stamp site checks this before reading the clock.
    enabled: bool = false,
    policy: snapshot.Policy = null,
    lens: [frame_profile_stage_count]u16 = @splat(0),
    heads: [frame_profile_stage_count]u16 = @splat(0),
    totals: [frame_profile_stage_count]u64 = @splat(0),
    samples_us: [frame_profile_stage_count][max_frame_profile_samples]u32 = @splat(@splat(0)),

    /// Monotonic stamp for a stage begin: 0 (never recorded) when
    /// profiling is off, so `end` costs one compare and nothing else.
    pub inline fn begin(self: *const FrameProfile) u64 {
        if (!self.enabled) return 0;
        return runtime_clock.monotonicNanoseconds();
    }

    /// Record `stage` if `begin` produced a live stamp. Saturating
    /// microseconds; no allocation, no sorting — snapshot time pays for
    /// percentiles, the frame never does.
    pub inline fn end(self: *FrameProfile, stage: FrameProfileStage, begin_ns: u64) void {
        if (begin_ns == 0) return;
        const now = runtime_clock.monotonicNanoseconds();
        const elapsed = snapshot.plan(self.policy, .elapsed, .{ .words = .{ begin_ns, now, 0, 0, 0, 0, 0, 0 } });
        self.recordNs(stage, elapsed.words[0]);
    }

    /// Record an externally measured duration (host-stamped decode/draw
    /// arrive as nanoseconds on the frame event).
    pub fn recordNs(self: *FrameProfile, stage: FrameProfileStage, elapsed_ns: u64) void {
        if (!self.enabled) return;
        const index = @intFromEnum(stage);
        const projection = snapshot.plan(self.policy, .record, .{ .flags = 1, .words = .{ elapsed_ns, self.lens[index], self.heads[index], self.totals[index], 0, 0, 0, 0 } });
        self.samples_us[index][self.heads[index]] = @intCast(projection.words[3]);
        self.lens[index] = @intCast(projection.words[0]);
        self.heads[index] = @intCast(projection.words[1]);
        self.totals[index] = projection.words[2];
    }

    /// Drop every recorded sample (enable state is left alone).
    pub fn reset(self: *FrameProfile) void {
        const projection = snapshot.plan(self.policy, .reset, .{});
        self.lens = @splat(@intCast(projection.words[0]));
        self.heads = @splat(@intCast(projection.words[1]));
        self.totals = @splat(projection.words[2]);
    }

    /// True when any stage holds samples — the snapshot's "print the
    /// frame_profile line at all" gate.
    pub fn hasSamples(self: *const FrameProfile) bool {
        var lengths: [frame_profile_stage_count]u32 = undefined;
        for (self.lens, &lengths) |len, *slot| slot.* = len;
        return snapshot.plan(self.policy, .has_samples, .{ .samples = &lengths }).flags != 0;
    }

    /// Percentiles for one stage over its current window. Copies and
    /// sorts up to `max_frame_profile_samples` u32s — snapshot-path
    /// cost, never frame-path.
    pub fn stats(self: *const FrameProfile, stage: FrameProfileStage) FrameProfileStageStats {
        const index = @intFromEnum(stage);
        const len: usize = self.lens[index];
        const projection = snapshot.plan(self.policy, .stats, .{ .words = .{ len, self.totals[index], 0, 0, 0, 0, 0, 0 }, .samples = self.samples_us[index][0..len] });
        return .{
            .p50_us = projection.words[2],
            .p90_us = projection.words[3],
            .max_us = projection.words[4],
            .window_len = @intCast(projection.words[0]),
            .total = projection.words[1],
        };
    }
};

test "frame profile is inert while disabled" {
    var profile = FrameProfile{};
    try std.testing.expectEqual(@as(u64, 0), profile.begin());
    profile.end(.rebuild, 0);
    profile.recordNs(.rebuild, 1_000_000);
    try std.testing.expect(!profile.hasSamples());
    try std.testing.expectEqual(@as(usize, 0), profile.stats(.rebuild).window_len);
}

test "frame profile records stage durations in microseconds" {
    var profile = FrameProfile{ .enabled = true };
    profile.recordNs(.layout, 1_500); // 1.5 us -> 1
    profile.recordNs(.layout, 2_000_000); // 2 ms -> 2000
    profile.recordNs(.encode, 42_000);
    try std.testing.expect(profile.hasSamples());

    const layout_stats = profile.stats(.layout);
    try std.testing.expectEqual(@as(usize, 2), layout_stats.window_len);
    try std.testing.expectEqual(@as(u64, 2), layout_stats.total);
    try std.testing.expectEqual(@as(u64, 1), layout_stats.p50_us);
    try std.testing.expectEqual(@as(u64, 2000), layout_stats.p90_us);
    try std.testing.expectEqual(@as(u64, 2000), layout_stats.max_us);

    const encode_stats = profile.stats(.encode);
    try std.testing.expectEqual(@as(u64, 42), encode_stats.p50_us);
    // Stages are independent rings.
    try std.testing.expectEqual(@as(usize, 0), profile.stats(.rebuild).window_len);
}

test "frame profile window rolls and percentiles are nearest-rank" {
    var profile = FrameProfile{ .enabled = true };
    // Fill beyond capacity: the window keeps the newest samples.
    var value: u64 = 0;
    while (value < max_frame_profile_samples + 10) : (value += 1) {
        profile.recordNs(.present, value * std.time.ns_per_us);
    }
    const stats = profile.stats(.present);
    try std.testing.expectEqual(max_frame_profile_samples, stats.window_len);
    try std.testing.expectEqual(@as(u64, max_frame_profile_samples + 10), stats.total);
    // Window is [10, 137]: nearest-rank p50 of 128 samples is index 63,
    // p90 is rank ceil(115.2)=116 -> index 115.
    try std.testing.expectEqual(@as(u64, 73), stats.p50_us);
    try std.testing.expectEqual(@as(u64, 125), stats.p90_us);
    try std.testing.expectEqual(@as(u64, 137), stats.max_us);

    profile.reset();
    try std.testing.expect(!profile.hasSamples());
    try std.testing.expect(profile.enabled);
}

test "frame profile begin/end measures real elapsed time" {
    var profile = FrameProfile{ .enabled = true };
    const begin_ns = profile.begin();
    try std.testing.expect(begin_ns > 0);
    profile.end(.rebuild, begin_ns);
    const stats = profile.stats(.rebuild);
    try std.testing.expectEqual(@as(usize, 1), stats.window_len);
}
