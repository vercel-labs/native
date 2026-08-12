//! The in-process TypeScript service carrier, end to end. The build compiles
//! this test's core as a library-mode archive AND its src/services tree as a
//! second thread-instanced library archive; both link into this binary, and
//! ServicePool drives the service archive through the same TsUiApp/Effects
//! seam the child-process suite exercises.
//!
//! Coverage: ordinary success + kind-tagged throw, duplicate/unkeyed key
//! admission, live streaming with cancellation, parallel execution across
//! keys, per-key FIFO, cooperative deadlines (including time spent queued),
//! instance poisoning for token-ignoring operations and detected traps, the
//! registry/archive pairing fence, and session replay that never initializes
//! the archive.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("ts_services_core");
const registry = @import("ts_services_registry");

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;
const ServiceCarrier = native_sdk.ServicePool(registry);
const runtime_ns = native_sdk.runtime;

/// Pools allocate from the page allocator in this suite: poisoning tests
/// deliberately abandon worker/instance allocations, and the leak-checking
/// test allocator would report those documented leaks as failures.
const pool_allocator = std.heap.page_allocator;

const canvas_label = "fixture-canvas";
const views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Services Pool",
    .width = 320,
    .height = 200,
    .views = &views,
}};
const scene: native_sdk.ShellConfig = .{ .windows = &windows };

fn view(ui: *App.Ui, model: *const core.Model) App.Ui.Node {
    return ui.text(.{}, ui.fmt("successes {d} failures {d}", .{ model.successes, model.failures }));
}

fn command(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "service.parse")) return .parse;
    if (std.mem.eql(u8, name, "service.fail")) return .fail;
    if (std.mem.eql(u8, name, "service.queued-deadline")) return .queued_deadline;
    if (std.mem.eql(u8, name, "service.stream")) return .stream;
    if (std.mem.eql(u8, name, "service.stream-park")) return .stream_park;
    if (std.mem.eql(u8, name, "service.cancel-stream-park")) return .cancel_stream_park;
    if (std.mem.eql(u8, name, "service.duplicate-parse")) return .duplicate_parse;
    if (std.mem.eql(u8, name, "service.unkeyed-parse")) return .unkeyed_parse;
    if (std.mem.eql(u8, name, "service.duplicate-stream")) return .duplicate_stream;
    return null;
}

fn appOptions() App.Options {
    return .{
        .name = "ts-services-pool-e2e",
        .scene = scene,
        .canvas_label = canvas_label,
        .view = view,
        .on_command = command,
    };
}

const fixture_root = ".zig-cache/tmp/ts-services-pool-e2e";

fn resetFixtureDir() !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, fixture_root) catch {};
    try cwd.createDirPath(std.testing.io, fixture_root);
}

fn sleepMs(ms: i64) !void {
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(ms), .awake);
}

// ------------------------------------------------------- TsUiApp harness

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    transport: ServiceCarrier,

    fn create(recorder: ?*runtime_ns.SessionRecorder, pool: native_sdk.service_pool.PoolOptions) !*Harness {
        try resetFixtureDir();
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.transport = ServiceCarrier.init(pool_allocator, std.testing.io, fixture_root, pool);
        errdefer self.transport.deinit();

        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = native_sdk.geometry.SizeF.init(320, 200),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.runtime.options.session_recorder = recorder;

        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{
            .host_calls = self.transport.binding(),
            .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
        }, appOptions());
        errdefer self.app_state.deinit();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = native_sdk.geometry.SizeF.init(320, 200),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        self.transport.deinit();
        std.testing.allocator.destroy(self);
        std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_root) catch {};
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    fn waitPending(self: *Harness) !void {
        var waited_ms: usize = 0;
        while (waited_ms < 30_000) : (waited_ms += 5) {
            if (self.app_state.effects.hasPending()) return;
            try sleepMs(5);
        }
        self.app_state.effects.deinit();
        return error.TestTimedOut;
    }

    fn settleBoot(self: *Harness) !void {
        try self.waitPending();
        try self.wake();
        try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 1), Bridge.model().successes);
        try std.testing.expect(!Bridge.model().failed);
    }

    fn settleCounts(self: *Harness, successes: i64, failures: i64) !void {
        while (Bridge.model().successes < successes or Bridge.model().failures < failures) {
            try self.waitPending();
            try self.wake();
        }
    }
};

// -------------------------------------------------- binding-level harness

/// Completions copied out of the binding (poll invalidates its bytes on the
/// next call).
const Completion = struct { key: u64, ok: bool, bytes: []u8 };

fn DirectPool(comptime Carrier: type) type {
    return struct {
        const Self = @This();

        pool: Carrier,
        binding: native_sdk.HostCallBinding,
        platform_services: native_sdk.platform.PlatformServices,
        completions: std.ArrayList(Completion) = .empty,

        fn create(pool_options: native_sdk.service_pool.PoolOptions) !*Self {
            try resetFixtureDir();
            const self = try pool_allocator.create(Self);
            self.* = .{
                .pool = Carrier.init(pool_allocator, std.testing.io, fixture_root, pool_options),
                .binding = undefined,
                .platform_services = undefined,
            };
            self.binding = self.pool.binding();
            // The pool only wakes a bound handle; the poll loop below stands
            // in for the loop thread, so an inert wake suffices.
            self.platform_services = .{ .context = self, .wake_fn = wakeNoop };
            (self.binding.bind_services_fn orelse unreachable)(self.binding.context, &self.platform_services);
            return self;
        }

        fn wakeNoop(context: ?*anyopaque) anyerror!void {
            _ = context;
        }

        fn destroy(self: *Self) void {
            self.pool.deinit();
            for (self.completions.items) |completion| pool_allocator.free(completion.bytes);
            self.completions.deinit(pool_allocator);
            pool_allocator.destroy(self);
            std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_root) catch {};
        }

        fn request(self: *Self, name: []const u8, key: u64, payload: []const u8) void {
            self.binding.request_fn(self.binding.context, name, key, payload);
        }

        fn cancel(self: *Self, key: u64) void {
            (self.binding.cancel_fn orelse unreachable)(self.binding.context, key);
        }

        fn drain(self: *Self) !void {
            while ((self.binding.poll_fn orelse unreachable)(self.binding.context)) |completion| {
                try self.completions.append(pool_allocator, .{
                    .key = completion.key,
                    .ok = completion.ok,
                    .bytes = try pool_allocator.dupe(u8, completion.bytes),
                });
            }
        }

        /// Poll until `count` completions accumulate within the stated budget.
        fn awaitCompletionsWithin(self: *Self, count: usize, budget_ms: usize) !void {
            var waited_ms: usize = 0;
            while (waited_ms < budget_ms) : (waited_ms += 2) {
                try self.drain();
                if (self.completions.items.len >= count) return;
                try sleepMs(2);
            }
            return error.TestTimedOut;
        }

        /// Poll until `count` completions accumulated (30 s budget).
        fn awaitCompletions(self: *Self, count: usize) !void {
            return self.awaitCompletionsWithin(count, 30_000);
        }

        fn takeCompletions(self: *Self) []Completion {
            return self.completions.toOwnedSlice(pool_allocator) catch @panic("out of memory collecting service completions");
        }

        fn freeCompletions(items: []Completion) void {
            for (items) |completion| pool_allocator.free(completion.bytes);
            pool_allocator.free(items);
        }
    };
}

/// The canonical ParseRequest encoding: [len u32 LE][source bytes][bool u8].
fn encodeParseRequest(buffer: []u8, source: []const u8) []const u8 {
    std.debug.assert(buffer.len >= source.len + 5);
    buffer[0] = @truncate(source.len);
    buffer[1] = @truncate(source.len >> 8);
    buffer[2] = @truncate(source.len >> 16);
    buffer[3] = @truncate(source.len >> 24);
    @memcpy(buffer[4 .. 4 + source.len], source);
    buffer[4 + source.len] = 0; // caseSensitive = false
    return buffer[0 .. source.len + 5];
}

fn absoluteFixturePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture_root, allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
}

fn monotonicMs() u64 {
    return native_sdk.monotonicNanoseconds() / std.time.ns_per_ms;
}

// ----------------------------------------------------------------- tests

test "in-process success and kind-tagged throw route through Msgs" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.fail");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
    try std.testing.expect(Bridge.model().failed);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"kind\":\"fixture_failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"message\":\"requested failure\"") != null);
    try std.testing.expectEqual(@as(u64, 0), h.transport.poisonedCount());
}

test "in-process duplicate typed service keys reject without disturbing the original request" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.duplicate-parse");
    try h.settleCounts(2, 1);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
}

test "in-process unkeyed typed service requests each receive an independent slot" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.unkeyed-parse");
    try h.settleCounts(3, 0);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 3), Bridge.model().successes);
}

test "in-process duplicate streaming channel admission rejects the newcomer" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.duplicate-stream");
    try h.settleCounts(2, 1);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().chunks), 3), Bridge.model().chunks);
}

test "in-process streaming frames use an external channel before the typed terminal" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.stream");
    while (Bridge.model().successes < 2) {
        try h.waitPending();
        try h.wake();
    }
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().chunks), 3), Bridge.model().chunks);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 2), Bridge.model().successes);
    try std.testing.expect(!Bridge.model().failed);
}

test "in-process stream chunks are live mid-operation and cancel closes the stream" {
    const h = try Harness.create(null, .{ .max_workers = 2 });
    defer h.destroy();
    try h.settleBoot();

    // The operation emits one chunk and parks on its token: observing the
    // chunk while successes is still 1 proves live mid-operation emission.
    try h.menu("service.stream-park");
    while (Bridge.model().chunks < 1) {
        try h.waitPending();
        try h.wake();
    }
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().chunks), 1), Bridge.model().chunks);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 1), Bridge.model().successes);

    try h.menu("service.cancel-stream-park");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().chunks), 1), Bridge.model().chunks);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
    try std.testing.expect(std.mem.eql(u8, Bridge.model().bytes, "cancelled"));
    // The park honored its token inside the grace: no instance abandoned.
    var waited_ms: usize = 0;
    while (h.transport.poisonedCount() == 0 and waited_ms < 500) : (waited_ms += 10) try sleepMs(10);
    try std.testing.expectEqual(@as(u64, 0), h.transport.poisonedCount());
}

test "a streaming completion claimed at the grace boundary still drains" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 1 });
    defer d.destroy();
    d.pool.setRequestTimeoutMs(25);

    var barrier: native_sdk.service_pool.TestCompletionBarrier = .{};
    d.pool.setCompletionBarrierForTesting(&barrier);

    const Channels = struct {
        fn acquire(context: *anyopaque, key: u64) ?native_sdk.ChannelHandle {
            _ = context;
            _ = key;
            // A dead handle is sufficient here: the regression concerns the
            // relay's final drain, not delivery into Effects.
            return .{};
        }
    };
    (d.binding.bind_channels_fn orelse unreachable)(d.binding.context, .{
        .context = d,
        .acquire_fn = Channels.acquire,
    });

    var payload_buffer: [64]u8 = undefined;
    std.mem.writeInt(u64, payload_buffer[0..8], @bitCast(@as(f64, 1)), .little);
    const request_payload = encodeParseRequest(payload_buffer[8..], "feed");
    d.request("feeds.streamPark", 81, payload_buffer[0 .. 8 + request_payload.len]);

    const claim_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = std.Io.Duration.fromSeconds(2),
        .clock = .awake,
    });
    barrier.claimed.waitTimeout(std.testing.io, .{ .deadline = claim_deadline }) catch return error.TestTimedOut;

    // Hold `.completing` past the grace deadline. The supervisor's poison
    // CAS must lose, then retain the stream in its polling path instead of
    // repeatedly continuing above it.
    try sleepMs(native_sdk.service_pool.cooperative_cancel_grace_ms + 50);
    barrier.release.set(std.testing.io);

    try d.awaitCompletionsWithin(1, 2_000);
    const timed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(timed);
    try std.testing.expectEqual(@as(u64, 81), timed[0].key);
    try std.testing.expect(!timed[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, timed[0].bytes, "\"kind\":\"timeout\"") != null);
    try std.testing.expectEqual(@as(u64, 0), d.pool.poisonedCount());
}

test "in-process deadlines include time spent queued behind another operation" {
    // One worker reproduces the child carrier's serialization exactly: the
    // probe's deadline burns while it queues behind the blocker.
    const h = try Harness.create(null, .{ .max_workers = 1 });
    defer h.destroy();
    // The blocker writes its relative started marker into the process cwd;
    // in-process services share the app's working directory.
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "queued-blocker.started") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "queued-probe.started") catch {};
    try h.settleBoot();

    try h.menu("service.queued-deadline");
    try h.settleCounts(1, 2);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"kind\":\"timeout\"") != null);
    // The probe never ran: its deadline expired in the queue.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, "queued-probe.started", .{}));
}

test "a newly queued short deadline wakes the supervisor" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 1 });
    defer d.destroy();
    const marker = try absoluteFixturePath(std.testing.allocator, "queued-wake.started");
    defer std.testing.allocator.free(marker);

    var payload_buffer: [256]u8 = undefined;
    d.request("feeds.parkAt", 1, encodeParseRequest(&payload_buffer, marker));
    var waited_ms: usize = 0;
    while (waited_ms < 30_000) : (waited_ms += 5) {
        std.Io.Dir.cwd().access(std.testing.io, marker, .{}) catch {
            try sleepMs(5);
            continue;
        };
        break;
    }
    try std.testing.expect(waited_ms < 30_000);

    // The only worker stays occupied until cancellation, but queuedProbe's
    // 100 ms budget still expires independently of parkAt's 10-second one.
    d.request("feeds.queuedProbe", 2, "");
    try d.awaitCompletionsWithin(1, 2_000);
    const timed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(timed);
    try std.testing.expectEqual(@as(u64, 2), timed[0].key);
    try std.testing.expect(!timed[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, timed[0].bytes, "\"kind\":\"timeout\"") != null);
}

test "independent keys run in parallel across pool instances and same-key requests serialize" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 4 });
    defer d.destroy();
    var payload_buffer: [64]u8 = undefined;
    const payload = encodeParseRequest(&payload_buffer, "feed");

    // Serial baseline: four 300 ms operations under ONE key run FIFO.
    const serial_begin = monotonicMs();
    for (0..4) |_| d.request("feeds.slow", 7, payload);
    try d.awaitCompletions(4);
    const serial_ms = monotonicMs() - serial_begin;
    const serial = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(serial);
    for (serial) |completion| try std.testing.expect(completion.ok);

    // Parallel: the same four operations under four keys. One retry
    // absorbs a runner whose cores are momentarily saturated by sibling
    // test binaries — a pool that serialized distinct keys fails both
    // attempts deterministically.
    var parallel_ms: u64 = std.math.maxInt(u64);
    for (0..2) |attempt| {
        const parallel_begin = monotonicMs();
        const key_base = 11 + 10 * @as(u64, attempt);
        for (0..4) |index| d.request("feeds.slow", key_base + @as(u64, index), payload);
        try d.awaitCompletions(4);
        parallel_ms = @min(parallel_ms, monotonicMs() - parallel_begin);
        const parallel = d.takeCompletions();
        defer DirectPool(ServiceCarrier).freeCompletions(parallel);
        for (parallel) |completion| try std.testing.expect(completion.ok);
        if (parallel_ms * 10 < serial_ms * 6) break;
    }

    // Four ~300 ms operations: ~1200 ms serialized, ~one op time across
    // four instances.
    try std.testing.expect(serial_ms >= 1100);
    try std.testing.expect(parallel_ms * 10 < serial_ms * 6);
    try std.testing.expectEqual(@as(u64, 0), d.pool.poisonedCount());
}

test "a large send burst cannot hide a runnable independent key" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();
    const marker = try absoluteFixturePath(std.testing.allocator, "send-burst.started");
    defer std.testing.allocator.free(marker);

    // Fire-and-forget work shares key zero. Keep one such operation active,
    // then queue more entries than the old fixed skip buffer could cross.
    var park_buffer: [256]u8 = undefined;
    d.binding.send_fn(d.binding.context, "feeds.parkAt", encodeParseRequest(&park_buffer, marker));
    var waited_ms: usize = 0;
    while (waited_ms < 30_000) : (waited_ms += 5) {
        std.Io.Dir.cwd().access(std.testing.io, marker, .{}) catch {
            try sleepMs(5);
            continue;
        };
        break;
    }
    try std.testing.expect(waited_ms < 30_000);

    var parse_buffer: [64]u8 = undefined;
    const payload = encodeParseRequest(&parse_buffer, "feed");
    for (0..65) |_| d.binding.send_fn(d.binding.context, "feeds.parse", payload);
    d.request("feeds.parse", 2, payload);
    try d.awaitCompletionsWithin(1, 2_000);
    const completion = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(completion);
    try std.testing.expectEqual(@as(u64, 2), completion[0].key);
    try std.testing.expect(completion[0].ok);
}

test "same-key requests run FIFO with no interleaving" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 4 });
    defer d.destroy();
    const log_path = try absoluteFixturePath(std.testing.allocator, "order.log");
    defer std.testing.allocator.free(log_path);

    var payload_buffers: [6][160]u8 = undefined;
    var parse_buffer: [64]u8 = undefined;
    const parse_payload = encodeParseRequest(&parse_buffer, "feed");
    for (0..6) |index| {
        var source_buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buffer, "{s}|{d}", .{ log_path, index });
        const payload = encodeParseRequest(&payload_buffers[index], source);
        d.request("feeds.order", 5, payload);
        // Interleave other-key work so the picker exercises key skipping.
        if (index % 2 == 0) d.request("feeds.parse", 100 + @as(u64, index), parse_payload);
    }
    try d.awaitCompletions(9);
    const completions = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(completions);
    for (completions) |completion| try std.testing.expect(completion.ok);

    const log = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("s0;e0;s1;e1;s2;e2;s3;e3;s4;e4;s5;e5;", log);
}

test "a trapping operation poisons only its instance and routes service_trap" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();

    d.request("feeds.trap", 1, "");
    try d.awaitCompletions(1);
    const trapped = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(trapped);
    try std.testing.expectEqual(@as(u64, 1), trapped[0].key);
    try std.testing.expect(!trapped[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, trapped[0].bytes, "\"kind\":\"service_trap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trapped[0].bytes, "SC4014") != null);
    try std.testing.expectEqual(@as(u64, 1), d.pool.poisonedCount());

    // Other instances keep answering, in parallel, after the poisoning.
    var payload_buffer: [64]u8 = undefined;
    const payload = encodeParseRequest(&payload_buffer, "feed");
    for (0..3) |index| d.request("feeds.slow", 20 + @as(u64, index), payload);
    try d.awaitCompletions(3);
    const after = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(after);
    for (after) |completion| try std.testing.expect(completion.ok);
    try std.testing.expectEqual(@as(u64, 1), d.pool.poisonedCount());
}

test "a cooperative deadline reports timeout and preserves the instance" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();
    const marker = try absoluteFixturePath(std.testing.allocator, "hang-at.started");
    defer std.testing.allocator.free(marker);

    var payload_buffer: [256]u8 = undefined;
    d.request("feeds.hangAt", 3, encodeParseRequest(&payload_buffer, marker));
    try d.awaitCompletions(1);
    const timed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(timed);
    try std.testing.expect(!timed[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, timed[0].bytes, "\"kind\":\"timeout\"") != null);
    try std.testing.expectEqual(@as(u64, 0), d.pool.poisonedCount());

    var parse_buffer: [64]u8 = undefined;
    d.request("feeds.parse", 4, encodeParseRequest(&parse_buffer, "feed"));
    try d.awaitCompletions(1);
    const parsed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(parsed);
    try std.testing.expect(parsed[0].ok);
}

test "an ignored token reserves its key until the abandoned dispatch returns" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();
    const log_path = try absoluteFixturePath(std.testing.allocator, "stubborn-order.log");
    defer std.testing.allocator.free(log_path);
    std.Io.Dir.cwd().deleteFile(std.testing.io, "queued-probe.started") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "queued-probe.started") catch {};

    var stubborn_buffer: [256]u8 = undefined;
    var stubborn_source_buffer: [192]u8 = undefined;
    const stubborn_source = try std.fmt.bufPrint(&stubborn_source_buffer, "{s}|0", .{log_path});
    d.request("feeds.stubbornOrder", 8, encodeParseRequest(&stubborn_buffer, stubborn_source));
    try d.awaitCompletions(1);
    const timed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(timed);
    try std.testing.expect(!timed[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, timed[0].bytes, "\"kind\":\"timeout\"") != null);
    try std.testing.expectEqual(@as(u64, 1), d.pool.poisonedCount());

    // The replacement instance is available, but the predecessor's key stays
    // reserved until its detached dispatch physically stops.
    const still_running = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(still_running);
    try std.testing.expectEqualStrings("s0;", still_running);

    // A short-deadline same-key request expires in the queue rather than
    // overlapping or waiting forever behind the abandoned dispatch.
    d.request("feeds.queuedProbe", 8, "");
    try d.awaitCompletions(1);
    const queued_timeout = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(queued_timeout);
    try std.testing.expect(!queued_timeout[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, queued_timeout[0].bytes, "\"kind\":\"timeout\"") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, "queued-probe.started", .{}));

    var replacement_buffer: [256]u8 = undefined;
    var replacement_source_buffer: [192]u8 = undefined;
    const replacement_source = try std.fmt.bufPrint(&replacement_source_buffer, "{s}|1", .{log_path});
    d.request("feeds.order", 8, encodeParseRequest(&replacement_buffer, replacement_source));
    try d.awaitCompletions(1);
    const parsed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(parsed);
    try std.testing.expect(parsed[0].ok);

    const log = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("s0;e0;s1;e1;", log);
}

test "cancelling an active cooperative request discards its result and keeps the instance" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();
    const marker = try absoluteFixturePath(std.testing.allocator, "park-at.started");
    defer std.testing.allocator.free(marker);

    var payload_buffer: [256]u8 = undefined;
    d.request("feeds.parkAt", 6, encodeParseRequest(&payload_buffer, marker));
    var waited_ms: usize = 0;
    while (waited_ms < 30_000) : (waited_ms += 5) {
        std.Io.Dir.cwd().access(std.testing.io, marker, .{}) catch {
            try sleepMs(5);
            continue;
        };
        break;
    }
    d.cancel(6);
    // A cancelled request is retired without any completion: Effects itself
    // routes `cancelled` to the app.
    try sleepMs(400);
    try d.drain();
    try std.testing.expectEqual(@as(usize, 0), d.completions.items.len);
    try std.testing.expectEqual(@as(u64, 0), d.pool.poisonedCount());

    var parse_buffer: [64]u8 = undefined;
    d.request("feeds.parse", 6, encodeParseRequest(&parse_buffer, "feed"));
    try d.awaitCompletions(1);
    const parsed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(parsed);
    try std.testing.expect(parsed[0].ok);
}

test "cancelling an active request keeps its key serialized through unwind" {
    const d = try DirectPool(ServiceCarrier).create(.{ .max_workers = 2 });
    defer d.destroy();
    const log_path = try absoluteFixturePath(std.testing.allocator, "cancel-order.log");
    defer std.testing.allocator.free(log_path);

    var first_buffer: [256]u8 = undefined;
    var first_source_buffer: [192]u8 = undefined;
    const first_source = try std.fmt.bufPrint(&first_source_buffer, "{s}|0", .{log_path});
    d.request("feeds.cancelOrder", 6, encodeParseRequest(&first_buffer, first_source));
    var waited_ms: usize = 0;
    while (waited_ms < 30_000) : (waited_ms += 2) {
        std.Io.Dir.cwd().access(std.testing.io, log_path, .{}) catch {
            try sleepMs(2);
            continue;
        };
        break;
    }
    try std.testing.expect(waited_ms < 30_000);

    d.cancel(6);
    var second_buffer: [256]u8 = undefined;
    var second_source_buffer: [192]u8 = undefined;
    const second_source = try std.fmt.bufPrint(&second_source_buffer, "{s}|1", .{log_path});
    d.request("feeds.order", 6, encodeParseRequest(&second_buffer, second_source));
    try d.awaitCompletions(1);
    const parsed = d.takeCompletions();
    defer DirectPool(ServiceCarrier).freeCompletions(parsed);
    try std.testing.expect(parsed[0].ok);
    try std.testing.expectEqual(@as(u64, 0), d.pool.poisonedCount());

    const log = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("s0;e0;s1;e1;", log);
}

test "the pool refuses an archive built from a different registry" {
    const SkewedRegistry = struct {
        pub const protocol_version = registry.protocol_version;
        pub const inproc_symbol_prefix = registry.inproc_symbol_prefix;
        pub const contract_fingerprint = [_]u8{0xff} ** registry.contract_fingerprint.len;

        pub fn indexOf(name: []const u8) ?u16 {
            return registry.indexOf(name);
        }

        pub fn operationAt(index: u16) ?registry.Operation {
            return registry.operationAt(index);
        }
    };
    const d = try DirectPool(native_sdk.ServicePool(SkewedRegistry)).create(.{ .max_workers = 1 });
    defer d.destroy();

    var payload_buffer: [64]u8 = undefined;
    d.request("feeds.parse", 91, encodeParseRequest(&payload_buffer, "feed"));
    try d.awaitCompletions(1);
    const refused = d.takeCompletions();
    defer DirectPool(native_sdk.ServicePool(SkewedRegistry)).freeCompletions(refused);
    try std.testing.expectEqual(@as(u64, 91), refused[0].key);
    try std.testing.expect(!refused[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, refused[0].bytes, "service archive rejected") != null);
}

// ----------------------------------------------------------------- replay

const JournalBuffer = struct {
    bytes: [128 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) runtime_ns.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Snapshot = struct {
    successes: @FieldType(core.Model, "successes"),
    failures: @FieldType(core.Model, "failures"),
    failed: bool,
    bytes: [256]u8,
    bytes_len: usize,

    fn take() Snapshot {
        const model = Bridge.model();
        var result: Snapshot = .{
            .successes = model.successes,
            .failures = model.failures,
            .failed = model.failed,
            .bytes = [_]u8{0} ** 256,
            .bytes_len = @min(model.bytes.len, 256),
        };
        @memcpy(result.bytes[0..result.bytes_len], model.bytes[0..result.bytes_len]);
        return result;
    }
};

test "journal replay reproduces in-process service results without initializing the archive" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-services-pool-e2e", .window_width = 320, .window_height = 200 });

    const recorded = recorded: {
        const h = try Harness.create(recorder, .{ .max_workers = 2 });
        defer h.destroy();
        try h.settleBoot();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        try h.menu("service.fail");
        try h.waitPending();
        try h.wake();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
        break :recorded Snapshot.take();
    };

    // Replay parks the re-issued requests in the fake executor and feeds
    // journaled results only: the pool must never spawn a worker thread or
    // enter the archive.
    try resetFixtureDir();
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_root) catch {};
    var replay_pool = ServiceCarrier.init(pool_allocator, std.testing.io, fixture_root, .{ .max_workers = 2 });
    defer replay_pool.deinit();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = native_sdk.geometry.SizeF.init(320, 200),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{
        .host_calls = replay_pool.binding(),
        .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
    }, appOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u64, 2), report.effects_fed);
    try std.testing.expect(!replay_pool.started());
    try std.testing.expectEqualDeep(recorded, Snapshot.take());
}
