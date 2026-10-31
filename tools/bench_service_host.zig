//! Service-carrier macro-benchmark: BOTH production TypeScript service
//! transports — the out-of-process child (src/runtime/service_host.zig) and
//! the in-process pool (src/runtime/service_pool.zig) — driven through their
//! production HostCallBindings against one bytes-echo service compiled
//! through the production service lane. The echo operation returns its
//! request unchanged, so every number here is the carrier's — child spawn or
//! instance init, framing or the archive call, pipes or the dispatch seam,
//! queueing — not a workload's.
//!
//! Scenarios (per carrier):
//!
//! - cold-start: fresh carrier per trial; one keyed request from admission
//!   to polled completion, INCLUDING the lazy child spawn + hello fence
//!   (child) or the worker-thread spawn + instance init + pairing fence
//!   (pool).
//! - round-trip small/large: warm carrier; sequential keyed request round
//!   trips for a 64 B and a 256 KiB payload (p50/p90/p99).
//! - queued-throughput: N keyed requests admitted back to back and drained.
//!   The child's single worker serializes them; the pool spreads distinct
//!   keys across its instances.
//!
//! Completion delivery is the production seam: the carrier wakes a bound
//! PlatformServices handle after staging each result, and the benchmark
//! polls the binding exactly as Effects does on the loop thread.
//!
//! Run:
//!
//!   zig build bench-service-host -Doptimize=ReleaseFast
//!
//! Wall-clock durations are the measurement; baselines should come from
//! ReleaseFast like the other benchmarks.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const registry = @import("service_registry");
const bench_options = @import("bench_options");

const ChildHost = native_sdk.ServiceHost(registry);
const PoolHost = native_sdk.ServicePool(registry);

const operation_name = "echo.roundTrip";
const scratch_root = ".zig-cache/tmp/service-host-bench";

const cold_trials = 8;
const small_payload_bytes = 64;
const large_payload_bytes = 256 * 1024;
const small_warmup_iterations = 64;
const small_iterations = 4096;
const large_warmup_iterations = 8;
const large_iterations = 512;
const queued_requests = 512;
const queued_passes = 5;

// ------------------------------------------------------------- completion

/// The production wake seam: a carrier wakes the bound PlatformServices
/// handle once per staged result; Effects then polls on the loop thread.
/// The benchmark stands in for that loop thread — count wakes, poll on each.
const Waiter = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    staged: u64 = 0,

    fn services(self: *Waiter) native_sdk.platform.PlatformServices {
        return .{ .context = self, .wake_fn = wake };
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        const self: *Waiter = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(self.io);
        self.staged += 1;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn take(self: *Waiter) void {
        self.mutex.lockUncancelable(self.io);
        while (self.staged == 0) self.condition.waitUncancelable(self.io, &self.mutex);
        self.staged -= 1;
        self.mutex.unlock(self.io);
    }
};

fn Carrier(comptime Host: type, comptime is_pool: bool) type {
    return struct {
        const Self = @This();

        host: Host,
        waiter: Waiter,
        binding: native_sdk.HostCallBinding,
        platform_services: native_sdk.platform.PlatformServices,

        fn create(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !*Self {
            const self = try allocator.create(Self);
            self.host = if (is_pool)
                Host.init(allocator, io, scratch_root, .{})
            else
                Host.init(allocator, io, executable, scratch_root, null);
            self.waiter = .{ .io = io };
            self.binding = self.host.binding();
            self.platform_services = self.waiter.services();
            (self.binding.bind_services_fn orelse unreachable)(self.binding.context, &self.platform_services);
            return self;
        }

        fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            self.host.deinit();
            allocator.destroy(self);
        }

        /// One keyed request from admission to polled completion, in
        /// nanoseconds — the carrier half of a Cmd.request round trip.
        fn roundTrip(self: *Self, key: u64, payload: []const u8) !u64 {
            const begin = native_sdk.monotonicNanoseconds();
            self.binding.request_fn(self.binding.context, operation_name, key, payload);
            self.waiter.take();
            const completion = (self.binding.poll_fn orelse unreachable)(self.binding.context) orelse
                return error.MissingCompletion;
            const elapsed = native_sdk.monotonicNanoseconds() -| begin;
            if (!completion.ok) {
                std.debug.print("bench-service-host: request failed: {s}\n", .{completion.bytes});
                return error.ServiceRequestFailed;
            }
            if (completion.bytes.len != payload.len) return error.EchoLengthMismatch;
            return elapsed;
        }
    };
}

// ----------------------------------------------------------------- series

fn percentileNs(sorted: []const u64, percentile: usize) u64 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * percentile + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

fn fmtUsFromNs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}

// -------------------------------------------------------------- scenarios

fn scenarioColdStart(comptime C: type, allocator: std.mem.Allocator, io: std.Io, executable: []const u8, payload: []const u8, cold_note: []const u8) !void {
    var samples: [cold_trials]u64 = undefined;
    for (&samples) |*sample| {
        const carrier = try C.create(allocator, io, executable);
        defer carrier.destroy(allocator);
        sample.* = try carrier.roundTrip(1, payload);
    }
    var sorted = samples;
    std.sort.pdq(u64, &sorted, {}, std.sort.asc(u64));
    std.debug.print(
        "cold-start              median {d:>7} us  min {d:>7} us  max {d:>7} us  ({d} trials; {s} + first {d} B round trip)\n",
        .{ fmtUsFromNs(percentileNs(&sorted, 50)), fmtUsFromNs(sorted[0]), fmtUsFromNs(sorted[sorted.len - 1]), cold_trials, cold_note, payload.len },
    );
    std.debug.print("  trials (us):", .{});
    for (samples) |sample| std.debug.print(" {d}", .{fmtUsFromNs(sample)});
    std.debug.print("\n", .{});
}

fn scenarioRoundTrip(
    comptime name: []const u8,
    carrier: anytype,
    allocator: std.mem.Allocator,
    payload: []const u8,
    warmup: usize,
    iterations: usize,
) !void {
    for (0..warmup) |_| _ = try carrier.roundTrip(1, payload);
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);
    for (samples) |*sample| sample.* = try carrier.roundTrip(1, payload);
    std.sort.pdq(u64, samples, {}, std.sort.asc(u64));
    std.debug.print(
        name ++ " p50 {d:>7} us  p90 {d:>7} us  p99 {d:>7} us  ({d} iterations after {d} warmup; {d} B payload)\n",
        .{
            fmtUsFromNs(percentileNs(samples, 50)),
            fmtUsFromNs(percentileNs(samples, 90)),
            fmtUsFromNs(percentileNs(samples, 99)),
            iterations,
            warmup,
            payload.len,
        },
    );
}

fn scenarioQueuedThroughput(carrier: anytype, payload: []const u8, drain_note: []const u8) !void {
    var passes: [queued_passes]u64 = undefined;
    for (&passes) |*pass| {
        const begin = native_sdk.monotonicNanoseconds();
        for (0..queued_requests) |index| {
            carrier.binding.request_fn(carrier.binding.context, operation_name, @intCast(index + 1), payload);
        }
        for (0..queued_requests) |_| {
            carrier.waiter.take();
            const completion = (carrier.binding.poll_fn orelse unreachable)(carrier.binding.context) orelse
                return error.MissingCompletion;
            if (!completion.ok) return error.ServiceRequestFailed;
        }
        pass.* = native_sdk.monotonicNanoseconds() -| begin;
    }
    var sorted = passes;
    std.sort.pdq(u64, &sorted, {}, std.sort.asc(u64));
    const median_ns = percentileNs(&sorted, 50);
    const requests_per_second = if (median_ns == 0) 0 else (@as(u64, queued_requests) * std.time.ns_per_s) / median_ns;
    std.debug.print(
        "queued-throughput       {d:>6} req/s  ({d} keyed requests admitted back to back, median drain of {d} passes: {d} us; {d} B payload; {s})\n",
        .{ requests_per_second, queued_requests, queued_passes, fmtUsFromNs(median_ns), payload.len, drain_note },
    );
}

fn runCarrier(
    comptime C: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    small_payload: []const u8,
    large_payload: []const u8,
    cold_note: []const u8,
    drain_note: []const u8,
) !void {
    try scenarioColdStart(C, allocator, io, executable, small_payload, cold_note);
    const carrier = try C.create(allocator, io, executable);
    defer carrier.destroy(allocator);
    // First request pays the lazy start; everything after is warm.
    _ = try carrier.roundTrip(1, small_payload);
    try scenarioRoundTrip("round-trip-small       ", carrier, allocator, small_payload, small_warmup_iterations, small_iterations);
    try scenarioRoundTrip("round-trip-large       ", carrier, allocator, large_payload, large_warmup_iterations, large_iterations);
    try scenarioQueuedThroughput(carrier, small_payload, drain_note);
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, scratch_root) catch {};
    try cwd.createDirPath(io, scratch_root);
    defer cwd.deleteTree(io, scratch_root) catch {};

    const executable = try cwd.realPathFileAlloc(io, bench_options.service_executable, allocator);
    defer allocator.free(executable);

    const small_payload = try allocator.alloc(u8, small_payload_bytes);
    defer allocator.free(small_payload);
    const large_payload = try allocator.alloc(u8, large_payload_bytes);
    defer allocator.free(large_payload);
    for (small_payload, 0..) |*byte, index| byte.* = @truncate(index);
    for (large_payload, 0..) |*byte, index| byte.* = @truncate(index * 31);

    std.debug.print(
        "\nbench-service-host: service carrier round trips ({t}-{t}, {t})\n",
        .{ builtin.cpu.arch, builtin.os.tag, builtin.mode },
    );

    std.debug.print("\n[child-process carrier]\n\n", .{});
    try runCarrier(
        Carrier(ChildHost, false),
        allocator,
        io,
        executable,
        small_payload,
        large_payload,
        "lazy spawn + hello",
        "one worker serializes",
    );

    if (comptime bench_options.has_archive) {
        var width_buffer: [64]u8 = undefined;
        const drain_note = std.fmt.bufPrint(&width_buffer, "{d} pool instances drain distinct keys", .{native_sdk.service_pool.defaultWorkerCount()}) catch "pool instances drain distinct keys";
        std.debug.print("\n[in-process carrier]\n\n", .{});
        try runCarrier(
            Carrier(PoolHost, true),
            allocator,
            io,
            executable,
            small_payload,
            large_payload,
            "worker spawn + instance init + pairing fence",
            drain_note,
        );
    } else {
        std.debug.print("\n[in-process carrier] skipped: this target carries no service archive\n", .{});
    }
    std.debug.print("\n", .{});
}
