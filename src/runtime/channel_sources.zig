//! Explicit native external-producer capabilities. Portable app state and
//! channel lifecycle stay in the app; this source owns a detached OS sampler.
const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const clock = @import("clock.zig");
const sample_interval_ms = 500;
const max_line_bytes = 96;

pub fn start(name: []const u8, payload: []const u8, handle: effects.ChannelHandle) !void {
    if (!std.mem.eql(u8, name, "native-sdk.process.samples")) return error.UnknownChannelSource;
    if (payload.len != 0) return error.InvalidChannelSourceArguments;
    if (comptime builtin.single_threaded) return error.UnsupportedChannelSource;
    try startSamplerThread(handle);
}

fn startSamplerThread(handle: effects.ChannelHandle) std.Thread.SpawnError!void {
    const thread = try std.Thread.spawn(.{}, samplerMain, .{handle});
    thread.detach();
}

/// The app-owned source: real process readings on a real thread, paced
/// by its own sleep — the loop never ticks for it.
fn samplerMain(handle: effects.ChannelHandle) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const started_ms = clock.monotonicMs();
    var index: u64 = 0;
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sample_interval_ms), .awake) catch return;
        index += 1;
        var buffer: [max_line_bytes]u8 = undefined;
        const line = formatSample(&buffer, index, started_ms);
        // The post's answer is the worker's whole protocol — "retry
        // later" and "stop forever" are different answers on purpose.
        switch (handle.post(line)) {
            // Staged: one `.data` Msg delivers on the next drain.
            .accepted => {},
            // Transient back-pressure: THIS sample is dropped and
            // counted — the next delivered event carries the totals
            // and the status line reports them — but sampling
            // continues. A stalled drain is not a stop.
            .dropped_full => {},
            // A programming error by construction here: samples are
            // bounded at max_line_bytes, far under the channel's
            // post bound — no retry of the same bytes could ever land.
            .dropped_oversized => unreachable,
            // The occupancy is over for good — Stop closed the
            // channel, or the app tore down. Wind down.
            .closed => return,
        }
    }
}

/// One reading of this process: sample ordinal, uptime, and (where the
/// OS reports it) the peak resident set size.
fn formatSample(buffer: []u8, index: u64, started_ms: u64) []const u8 {
    const now_ms = clock.monotonicMs();
    const uptime_ms: u64 = if (now_ms > started_ms) now_ms - started_ms else 0;
    const rss_kb = currentMaxRssKb();
    if (rss_kb > 0) {
        return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s, peak rss {d} KiB", .{
            index, uptime_ms / 1000, (uptime_ms % 1000) / 100, rss_kb,
        }) catch "sample";
    }
    return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s", .{
        index, uptime_ms / 1000, (uptime_ms % 1000) / 100,
    }) catch "sample";
}

/// This process's peak resident set size in KiB, 0 where unavailable.
/// macOS reports `maxrss` in bytes, Linux in KiB — normalized here.
fn currentMaxRssKb() u64 {
    if (builtin.os.tag == .windows or !builtin.link_libc) return 0;
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return 0;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return if (builtin.os.tag.isDarwin()) raw / 1024 else raw;
}
