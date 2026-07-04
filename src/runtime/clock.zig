//! The runtime's real clocks and the app-facing time seam.
//!
//! Zig 0.16 routes `std.time.milliTimestamp`-style reads through `std.Io`,
//! which `update` deliberately never sees — so every app that wanted a
//! ledger timestamp re-implemented `clock_gettime` per OS. These helpers
//! are the framework's one implementation: direct OS clock reads (no `Io`
//! handle, callable from `update`/`init_fx`/`view`), plus a tiny `Clock`
//! value type that models can hold so tests substitute a deterministic
//! `TestClock` — the determinism story is "real clock behind a seam you
//! can swap", exactly like the fake effect executor.
//!
//! Two clocks, two questions:
//! - wall (`nowMs`/`nowNanoseconds`): "what time is it?" — Unix epoch,
//!   jumps when the OS clock is adjusted. For timestamps humans read.
//! - monotonic (`monotonicMs`/`monotonicNanoseconds`): "how long did it
//!   take?" — an arbitrary origin that never goes backwards. For
//!   durations and elapsed-time math.
//!
//! Unsupported targets (wasi) read 0 rather than failing — the same
//! honest degradation the automation timestamps always had. Freestanding
//! targets have no OS clock at all, so an embedding host (the docs wasm
//! preview) injects its monotonic time through
//! `setFreestandingMonotonicNanoseconds` and both monotonic reads follow
//! it; without a host feed they read 0, the old honest degradation.

const std = @import("std");
const builtin = @import("builtin");
const clock_module = @This();

/// Host-fed monotonic time for `freestanding` builds (single-threaded by
/// construction — wasm32-freestanding has no threads to race). Clamped
/// monotone so a jittery host feed can never run the clock backwards.
var freestanding_monotonic_ns: u64 = 0;

/// Feed the freestanding monotonic clock (no-op on targets with a real
/// OS clock). The wasm preview host calls this with the page's
/// `performance.now()` before dispatching input and frame events, so
/// runtime code reading the clock seam observes real elapsed time.
pub fn setFreestandingMonotonicNanoseconds(ns: u64) void {
    if (builtin.os.tag != .freestanding) return;
    if (ns > freestanding_monotonic_ns) freestanding_monotonic_ns = ns;
}

/// Wall-clock nanoseconds since the Unix epoch (REALTIME). 0 when the
/// target has no readable clock (wasi).
pub fn nowNanoseconds() i128 {
    switch (builtin.os.tag) {
        .windows => {
            // 100 ns intervals since 1601-01-01, rebased to the Unix epoch.
            const epoch_ns: i96 = @as(i96, std.time.epoch.windows) * std.time.ns_per_s;
            return @as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
        },
        .wasi, .freestanding, .emscripten => return 0,
        else => {
            var ts: std.posix.timespec = undefined;
            switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
                .SUCCESS => return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec,
                else => return 0,
            }
        },
    }
}

/// Wall-clock milliseconds since the Unix epoch — the ledger-timestamp
/// helper (`started_ms`/`ended_ms` fields, "what time is it?").
pub fn nowMs() i64 {
    return @intCast(@divTrunc(nowNanoseconds(), std.time.ns_per_ms));
}

/// Monotonic nanoseconds from an arbitrary origin: never decreases, not
/// affected by wall-clock adjustments — the duration clock ("how long
/// did it take?"). 0 when the target has no readable clock (wasi).
pub fn monotonicNanoseconds() u64 {
    switch (builtin.os.tag) {
        .windows => {
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            var frequency: std.os.windows.LARGE_INTEGER = undefined;
            if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
            if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
            if (frequency <= 0) return 0;
            const ticks: u128 = @intCast(@max(counter, 0));
            return @intCast(ticks * std.time.ns_per_s / @as(u128, @intCast(frequency)));
        },
        .freestanding => return freestanding_monotonic_ns,
        .wasi, .emscripten => return 0,
        else => {
            var ts: std.posix.timespec = undefined;
            switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
                .SUCCESS => return timestampToU64(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec),
                else => return 0,
            }
        },
    }
}

/// Monotonic milliseconds from an arbitrary origin. Subtract two reads
/// for an elapsed duration; the absolute value means nothing.
pub fn monotonicMs() u64 {
    return monotonicNanoseconds() / std.time.ns_per_ms;
}

/// The time seam apps store in the model: `.system` reads the real OS
/// clocks; tests swap in `TestClock.clock()` and advance it by hand so
/// time-dependent updates stay deterministic. Copyable value type —
/// two function pointers and a context, nothing to deinit.
pub const Clock = struct {
    context: ?*anyopaque = null,
    wall_ns_fn: *const fn (context: ?*anyopaque) i128 = systemWallNs,
    monotonic_ns_fn: *const fn (context: ?*anyopaque) u64 = systemMonotonicNs,

    /// The real OS clocks (the default — `Clock{}` is the same value).
    pub const system: Clock = .{};

    pub fn wallNanoseconds(self: Clock) i128 {
        return self.wall_ns_fn(self.context);
    }

    pub fn wallMs(self: Clock) i64 {
        return @intCast(@divTrunc(self.wallNanoseconds(), std.time.ns_per_ms));
    }

    pub fn monotonicNanoseconds(self: Clock) u64 {
        return self.monotonic_ns_fn(self.context);
    }

    pub fn monotonicMs(self: Clock) u64 {
        return self.monotonicNanoseconds() / std.time.ns_per_ms;
    }

    fn systemWallNs(context: ?*anyopaque) i128 {
        _ = context;
        return clock_module.nowNanoseconds();
    }

    fn systemMonotonicNs(context: ?*anyopaque) u64 {
        _ = context;
        return clock_module.monotonicNanoseconds();
    }
};

/// A hand-cranked clock for tests: set the wall time, advance both
/// clocks explicitly, and hand `clock()` to the code under test. The
/// `TestClock` must outlive every `Clock` taken from it (it holds the
/// pointer).
pub const TestClock = struct {
    wall_ns: i128 = 0,
    monotonic_ns: u64 = 0,

    pub fn clock(self: *TestClock) Clock {
        return .{
            .context = self,
            .wall_ns_fn = readWall,
            .monotonic_ns_fn = readMonotonic,
        };
    }

    /// Advance both clocks together, like real time passing.
    pub fn advanceNs(self: *TestClock, ns: u64) void {
        self.wall_ns += ns;
        self.monotonic_ns += ns;
    }

    pub fn advanceMs(self: *TestClock, ms: u64) void {
        self.advanceNs(ms * std.time.ns_per_ms);
    }

    /// Set the wall clock alone (an NTP-style jump); monotonic is
    /// unaffected, exactly like the real clocks.
    pub fn setWallMs(self: *TestClock, ms: i64) void {
        self.wall_ns = @as(i128, ms) * std.time.ns_per_ms;
    }

    fn readWall(context: ?*anyopaque) i128 {
        const self: *TestClock = @ptrCast(@alignCast(context.?));
        return self.wall_ns;
    }

    fn readMonotonic(context: ?*anyopaque) u64 {
        const self: *TestClock = @ptrCast(@alignCast(context.?));
        return self.monotonic_ns;
    }
};

pub fn timestampToU64(value: i128) u64 {
    if (value <= 0) return 0;
    return @intCast(@min(value, std.math.maxInt(u64)));
}

pub fn automationInputTimestampNs() u64 {
    return timestampToU64(nowNanoseconds());
}

test "the real clocks read plausible, ordered values" {
    // Wall: after 2020-01-01 (1577836800 s) and before 2100.
    const wall = nowNanoseconds();
    try std.testing.expect(wall > 1_577_836_800 * @as(i128, std.time.ns_per_s));
    try std.testing.expect(wall < 4_102_444_800 * @as(i128, std.time.ns_per_s));
    const wall_ms = nowMs();
    try std.testing.expect(wall_ms > 1_577_836_800_000);

    // Monotonic: nonzero and never decreasing across consecutive reads.
    const first = monotonicNanoseconds();
    const second = monotonicNanoseconds();
    try std.testing.expect(first > 0);
    try std.testing.expect(second >= first);
}

test "Clock.system reads the real clocks and Clock{} is the same seam" {
    const clock: Clock = .system;
    try std.testing.expect(clock.wallMs() > 1_577_836_800_000);
    try std.testing.expect(clock.monotonicNanoseconds() > 0);
    const default_clock: Clock = .{};
    try std.testing.expect(default_clock.wallMs() > 1_577_836_800_000);
}

test "TestClock is deterministic: advance moves both, setWallMs jumps wall alone" {
    var test_clock: TestClock = .{};
    const clock = test_clock.clock();
    try std.testing.expectEqual(@as(i64, 0), clock.wallMs());
    try std.testing.expectEqual(@as(u64, 0), clock.monotonicMs());

    test_clock.setWallMs(1_700_000_000_000);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), clock.wallMs());
    try std.testing.expectEqual(@as(u64, 0), clock.monotonicMs());

    test_clock.advanceMs(250);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_250), clock.wallMs());
    try std.testing.expectEqual(@as(u64, 250), clock.monotonicMs());
    try std.testing.expectEqual(@as(i128, 1_700_000_000_250 * @as(i128, std.time.ns_per_ms)), clock.wallNanoseconds());
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), clock.monotonicNanoseconds());
}
