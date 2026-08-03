//! Gate harness: drives the inbox app core through a scalar C ABI and
//! measures correctness, determinism, and keystroke-path latency. The run1k
//! mode writes the snapshot+effect log whose digest is the transpiler gate.
//!
//! Modes:
//!   smoke              — fixed short sequence, print snapshot hex (cross-impl oracle)
//!   run1k <out-file>   — deterministic 1k-message sequence; write snapshot+effect log
//!   bench10k           — 10k keystroke-path dispatches; latency stats (ns)

const std = @import("std");
const impl = @import("impl");

fn snapshotHex(alloc: std.mem.Allocator) ![]u8 {
    const len: usize = @intFromFloat(impl.snapshot());
    const hex = try alloc.alloc(u8, len * 2);
    const digits = "0123456789abcdef";
    for (0..len) |i| {
        const b: u8 = @intFromFloat(impl.snapshotByte(@floatFromInt(i)));
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0xf];
    }
    return hex;
}

fn smoke(alloc: std.mem.Allocator) !void {
    impl.reset();
    impl.pushText(104);
    impl.pushText(105);
    _ = impl.dispatch(4, 0, 0, 0, 0, 0);
    _ = impl.dispatch(0, 0, 0, 0, 0, 0);
    _ = impl.dispatch(1, 4, 0, 0, 0, 0);
    _ = impl.dispatch(2, 1, 0, 0, 0, 0);
    _ = impl.dispatch(5, 0, 0, 0, 0, 28.5);
    const hex = try snapshotHex(alloc);
    std.debug.print("smoke snapshot {s}\n", .{hex});
    std.debug.print("smoke effects {d}\n", .{@as(u64, @intFromFloat(impl.effectLen()))});
}

const SplitMix = struct {
    state: u64,
    fn next(self: *SplitMix) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    fn below(self: *SplitMix, n: u64) u64 {
        return self.next() % n;
    }
};

// One deterministic pseudo-random message; exercises every Msg arm,
// including multi-byte UTF-8 inserts, compositions, invalid toggle ids,
// and fractional chrome insets.
fn sendRandomMsg(rng: *SplitMix) void {
    const roll = rng.below(100);
    if (roll < 45) {
        // draft edits dominate, like real typing
        const edit = rng.below(11);
        switch (edit) {
            0, 1, 2, 3 => { // insert 1-3 chars, sometimes multi-byte UTF-8
                const n = 1 + rng.below(3);
                for (0..n) |_| {
                    if (rng.below(8) == 0) {
                        // U+00E9 é = 0xC3 0xA9
                        impl.pushText(0xc3);
                        impl.pushText(0xa9);
                    } else {
                        impl.pushText(@floatFromInt(0x61 + rng.below(26)));
                    }
                }
                _ = impl.dispatch(4, 0, 0, 0, 0, 0);
            },
            4 => _ = impl.dispatch(4, 1, 0, 0, 0, 0), // delete_backward
            5 => _ = impl.dispatch(4, 2, 0, 0, 0, 0), // delete_forward
            6 => _ = impl.dispatch(4, @floatFromInt(3 + rng.below(2)), 0, 0, 0, 0), // word deletes
            7 => _ = impl.dispatch(4, 6, @floatFromInt(rng.below(6)), @floatFromInt(rng.below(2)), 0, 0), // move_caret
            8 => _ = impl.dispatch(4, 7, @floatFromInt(rng.below(40)), @floatFromInt(rng.below(40)), 0, 0), // set_selection
            9 => { // set_composition then commit or cancel
                const n = rng.below(4);
                for (0..n) |_| impl.pushText(@floatFromInt(0x61 + rng.below(26)));
                const cursor: f64 = if (rng.below(2) == 0) -1 else @floatFromInt(rng.below(5));
                _ = impl.dispatch(4, 8, cursor, 0, 0, 0);
                _ = impl.dispatch(4, if (rng.below(2) == 0) 9 else 10, 0, 0, 0, 0);
            },
            else => _ = impl.dispatch(4, 5, 0, 0, 0, 0), // clear
        }
    } else if (roll < 65) {
        _ = impl.dispatch(0, 0, 0, 0, 0, 0); // add
    } else if (roll < 80) {
        _ = impl.dispatch(1, @floatFromInt(rng.below(80)), 0, 0, 0, 0); // toggle (some ids invalid)
    } else if (roll < 88) {
        _ = impl.dispatch(2, @floatFromInt(rng.below(3)), 0, 0, 0, 0); // set_filter
    } else if (roll < 94) {
        _ = impl.dispatch(3, 0, 0, 0, 0, 0); // clear_done
    } else {
        // chrome_changed with fractional insets
        const left: f64 = @as(f64, @floatFromInt(rng.below(120))) * 0.5;
        const top: f64 = @as(f64, @floatFromInt(rng.below(160))) * 0.5;
        _ = impl.dispatch(5, 0, 0, 0, left, top);
    }
}

fn run1k(alloc: std.mem.Allocator, io: std.Io, out_path: []const u8) !void {
    impl.reset();
    var rng = SplitMix{ .state = 0x5eed_ba5e_0000_1234 };
    for (0..1000) |_| sendRandomMsg(&rng);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const hex = try snapshotHex(alloc);
    try out.appendSlice(alloc, "snapshot ");
    try out.appendSlice(alloc, hex);
    try out.appendSlice(alloc, "\neffects ");
    const eff_len: usize = @intFromFloat(impl.effectLen());
    const digits = "0123456789abcdef";
    for (0..eff_len) |i| {
        const b: u8 = @intFromFloat(impl.effectByte(@floatFromInt(i)));
        try out.append(alloc, digits[b >> 4]);
        try out.append(alloc, digits[b & 0xf]);
    }
    try out.appendSlice(alloc, "\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
    std.debug.print("run1k wrote {s} ({d} bytes, {d} effect bytes)\n", .{ out_path, out.items.len, eff_len });
}

// Monotonic awake-time nanoseconds. This maps to CLOCK_UPTIME_RAW on macOS
// while retaining the same benchmark contract on other supported hosts.
inline fn nowNs(io: std.Io) u64 {
    return @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds, 0));
}

fn bench10k(alloc: std.mem.Allocator, io: std.Io) !void {
    impl.reset();
    var rng = SplitMix{ .state = 0xdead_beef_cafe_f00d };
    const iters = 10_000;
    const samples = try alloc.alloc(u64, iters);

    const bench_start = nowNs(io);
    for (0..iters) |i| {
        // Keystroke-shaped mix: mostly single-char inserts.
        const roll = rng.below(1000);
        const t0 = nowNs(io);
        if (roll < 700) {
            impl.pushText(@floatFromInt(0x61 + rng.below(26)));
            _ = impl.dispatch(4, 0, 0, 0, 0, 0);
        } else if (roll < 800) {
            _ = impl.dispatch(4, 1, 0, 0, 0, 0); // backspace
        } else if (roll < 870) {
            _ = impl.dispatch(4, 6, @floatFromInt(rng.below(6)), 0, 0, 0); // caret move
        } else if (roll < 920) {
            _ = impl.dispatch(0, 0, 0, 0, 0, 0); // add (submit)
        } else if (roll < 970) {
            _ = impl.dispatch(1, @floatFromInt(rng.below(80)), 0, 0, 0, 0); // toggle
        } else if (roll < 990) {
            _ = impl.dispatch(2, @floatFromInt(rng.below(3)), 0, 0, 0, 0); // filter
        } else {
            _ = impl.dispatch(3, 0, 0, 0, 0, 0); // clear_done
        }
        samples[i] = nowNs(io) - t0;
    }
    const wall_total = nowNs(io) - bench_start;

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (samples) |s| total += s;
    std.debug.print("bench10k wall total ns: {d} (mean/dispatch incl. harness: {d})\n", .{ wall_total, wall_total / iters });
    std.debug.print(
        "bench10k ns: min={d} p50={d} p90={d} p99={d} p999={d} max={d} mean={d}\n",
        .{
            samples[0],
            samples[iters / 2],
            samples[(iters * 90) / 100],
            samples[(iters * 99) / 100],
            samples[(iters * 999) / 1000],
            samples[iters - 1],
            total / iters,
        },
    );
    // Top 5 outliers for GC-pause inspection.
    std.debug.print("bench10k top5: {d} {d} {d} {d} {d}\n", .{
        samples[iters - 1], samples[iters - 2], samples[iters - 3],
        samples[iters - 4], samples[iters - 5],
    });
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    impl.init();

    const args = try init.minimal.args.toSlice(alloc);
    const mode: []const u8 = if (args.len > 1) args[1] else "smoke";

    if (std.mem.eql(u8, mode, "smoke")) {
        try smoke(alloc);
    } else if (std.mem.eql(u8, mode, "run1k")) {
        try run1k(alloc, init.io, args[2]);
    } else if (std.mem.eql(u8, mode, "bench10k")) {
        try bench10k(alloc, init.io);
    } else {
        std.debug.print("unknown mode {s}\n", .{mode});
    }
}
