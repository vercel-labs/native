//! The mobile execution battery for TypeScript cores and in-process
//! services: the pool fixture's compiled core and service archives link
//! into this STATIC LIBRARY, and the platform toolchain (xcrun clang for
//! the iOS simulator, NDK clang for Android) links a tiny C harness
//! around `nsme_run` — the same link pattern embedding apps use for the
//! embed library, so what executes on the device class is exactly the
//! artifact shape apps ship.
//!
//! Coverage (the minimum executed mobile proof, distilled from the
//! desktop in-process pool battery):
//!
//! - core update round trips: the boot command's real parse lands as a
//!   typed ParseResult Msg, and command-dispatched updates advance the
//!   committed model across multiple Msg arms.
//! - one service request through the pool with a typed result, plus a
//!   kind-tagged typed error.
//! - trap isolation: a trapping operation poisons exactly its instance,
//!   routes `service_trap`, and the pool keeps answering.
//! - record/replay: a journaled session replays to a byte-identical
//!   model snapshot while the replay pool NEVER starts a worker or
//!   enters the archive.
//!
//! `scripts/mobile-e2e.sh` stages, links, and executes this battery on a
//! booted simulator and a headless emulator.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_services_core");
const registry = @import("ts_services_registry");

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;
const ServiceCarrier = native_sdk.ServicePool(registry);
const runtime_ns = native_sdk.runtime;

/// Poisoning deliberately abandons worker/instance allocations, and the
/// battery runs to process exit anyway.
const allocator = std.heap.page_allocator;

var io_state: std.Io.Threaded = undefined;
var io: std.Io = undefined;

var root_buffer: [1024]u8 = undefined;
var fixture_root: []const u8 = ".";

var failed_checks: usize = 0;

/// The C harness entry: `root` is a writable directory (the simulator's
/// TMPDIR, Android's /data/local/tmp) for pool markers and relay files.
/// Returns 0 when every check passed.
export fn nsme_run(root_ptr: [*]const u8, root_len: usize) callconv(.c) c_int {
    const len = @min(root_len, root_buffer.len);
    @memcpy(root_buffer[0..len], root_ptr[0..len]);
    fixture_root = root_buffer[0..len];
    io_state = std.Io.Threaded.init(allocator, .{});
    defer io_state.deinit();
    io = io_state.io();

    check("typed results and updates through the pool", checkTypedResults);
    check("trap isolation poisons one instance", checkTrapIsolation);
    check("replay reproduces results without initializing the archive", checkReplay);

    if (failed_checks == 0) {
        std.debug.print("nsme: all checks passed\n", .{});
        return 0;
    }
    std.debug.print("nsme: {d} check(s) FAILED\n", .{failed_checks});
    return 1;
}

fn check(name: []const u8, run: *const fn () anyerror!void) void {
    std.debug.print("nsme: {s}...\n", .{name});
    run() catch |err| {
        std.debug.print("nsme: FAIL {s}: {t}\n", .{ name, err });
        failed_checks += 1;
        return;
    };
    std.debug.print("nsme: ok {s}\n", .{name});
}

fn expect(condition: bool) !void {
    if (!condition) return error.CheckFailed;
}

fn sleepMs(ms: i64) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake);
}

// ------------------------------------------------------- TsUiApp harness

const canvas_label = "fixture-canvas";
const views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Services Mobile",
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
    return null;
}

fn appOptions() App.Options {
    return .{
        .name = "ts-services-mobile-e2e",
        .scene = scene,
        .canvas_label = canvas_label,
        .view = view,
        .on_command = command,
    };
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    transport: ServiceCarrier,

    fn create(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        self.transport = ServiceCarrier.init(allocator, io, fixture_root, .{ .max_workers = 2 });
        errdefer self.transport.deinit();

        self.harness = try native_sdk.TestHarness().create(allocator, .{
            .size = native_sdk.geometry.SizeF.init(320, 200),
        });
        errdefer self.harness.destroy(allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.runtime.options.session_recorder = recorder;

        // The app struct (and any real model) is multi-MB: construct in
        // place on the heap, exactly as the generated wiring does — the
        // simulator/emulator main thread's stack cannot carry a by-value App.
        self.app_state = try Adapter.create(allocator, .{
            .host_calls = self.transport.binding(),
            .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
        }, appOptions());
        errdefer self.app_state.destroy();
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
        self.app_state.destroy();
        self.harness.destroy(allocator);
        self.transport.deinit();
        allocator.destroy(self);
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
        return error.CheckTimedOut;
    }

    fn settleBoot(self: *Harness) !void {
        try self.waitPending();
        try self.wake();
        try expect(Bridge.model().successes == 1);
        try expect(!Bridge.model().failed);
    }
};

/// Boot parse (a REAL parse through the linked service archive, decoded
/// into the typed `boot_parsed` arm), then two more update round trips
/// across distinct Msg arms: a keyed parse success and a kind-tagged
/// typed failure. The committed model advances after every dispatch.
fn checkTypedResults() !void {
    const h = try Harness.create(null);
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.parse");
    try h.waitPending();
    try h.wake();
    try expect(Bridge.model().successes == 2);
    try expect(!Bridge.model().failed);

    try h.menu("service.fail");
    try h.waitPending();
    try h.wake();
    try expect(Bridge.model().failures == 1);
    try expect(Bridge.model().failed);
    try expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"kind\":\"fixture_failure\"") != null);
    try expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"message\":\"requested failure\"") != null);
    try expect(h.transport.poisonedCount() == 0);
}

// -------------------------------------------------- binding-level checks

const Completion = struct { key: u64, ok: bool, bytes: []u8 };

const DirectPool = struct {
    pool: ServiceCarrier,
    binding: native_sdk.HostCallBinding,
    platform_services: native_sdk.platform.PlatformServices,
    completions: std.ArrayList(Completion) = .empty,

    fn create() !*DirectPool {
        const self = try allocator.create(DirectPool);
        self.* = .{
            .pool = ServiceCarrier.init(allocator, io, fixture_root, .{ .max_workers = 2 }),
            .binding = undefined,
            .platform_services = undefined,
        };
        self.binding = self.pool.binding();
        self.platform_services = .{ .context = self, .wake_fn = wakeNoop };
        (self.binding.bind_services_fn orelse unreachable)(self.binding.context, &self.platform_services);
        return self;
    }

    fn wakeNoop(context: ?*anyopaque) anyerror!void {
        _ = context;
    }

    fn destroy(self: *DirectPool) void {
        self.pool.deinit();
        for (self.completions.items) |completion| allocator.free(completion.bytes);
        self.completions.deinit(allocator);
        allocator.destroy(self);
    }

    fn request(self: *DirectPool, name: []const u8, key: u64, payload: []const u8) void {
        self.binding.request_fn(self.binding.context, name, key, payload);
    }

    fn drain(self: *DirectPool) !void {
        while ((self.binding.poll_fn orelse unreachable)(self.binding.context)) |completion| {
            try self.completions.append(allocator, .{
                .key = completion.key,
                .ok = completion.ok,
                .bytes = try allocator.dupe(u8, completion.bytes),
            });
        }
    }

    fn awaitCompletions(self: *DirectPool, count: usize) !void {
        var waited_ms: usize = 0;
        while (waited_ms < 30_000) : (waited_ms += 2) {
            try self.drain();
            if (self.completions.items.len >= count) return;
            try sleepMs(2);
        }
        return error.CheckTimedOut;
    }

    fn takeCompletions(self: *DirectPool) []Completion {
        return self.completions.toOwnedSlice(allocator) catch @panic("out of memory collecting completions");
    }

    fn freeCompletions(items: []Completion) void {
        for (items) |completion| allocator.free(completion.bytes);
        allocator.free(items);
    }
};

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

/// A trapping operation poisons exactly its instance and routes the
/// structured `service_trap` error; a fresh instance keeps answering.
fn checkTrapIsolation() !void {
    const d = try DirectPool.create();
    defer d.destroy();

    d.request("feeds.trap", 1, "");
    try d.awaitCompletions(1);
    const trapped = d.takeCompletions();
    defer DirectPool.freeCompletions(trapped);
    try expect(trapped[0].key == 1);
    try expect(!trapped[0].ok);
    try expect(std.mem.indexOf(u8, trapped[0].bytes, "\"kind\":\"service_trap\"") != null);
    try expect(d.pool.poisonedCount() == 1);

    var payload_buffer: [64]u8 = undefined;
    d.request("feeds.parse", 2, encodeParseRequest(&payload_buffer, "feed"));
    try d.awaitCompletions(1);
    const parsed = d.takeCompletions();
    defer DirectPool.freeCompletions(parsed);
    try expect(parsed[0].ok);
    try expect(d.pool.poisonedCount() == 1);
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

    fn eql(self: Snapshot, other: Snapshot) bool {
        return self.successes == other.successes and
            self.failures == other.failures and
            self.failed == other.failed and
            self.bytes_len == other.bytes_len and
            std.mem.eql(u8, self.bytes[0..self.bytes_len], other.bytes[0..other.bytes_len]);
    }
};

/// Record a session (boot parse + typed failure), then replay it into a
/// fresh app over a FRESH pool: the journal feeds every service result,
/// the committed model snapshot matches byte for byte, and the replay
/// pool never starts a worker — replay never initializes the archive.
fn checkReplay() !void {
    const buffer = try allocator.create(JournalBuffer);
    defer allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try allocator.create(runtime_ns.SessionRecorder);
    defer allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-services-mobile-e2e", .window_width = 320, .window_height = 200 });

    const recorded = recorded: {
        const h = try Harness.create(recorder);
        defer h.destroy();
        try h.settleBoot();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        try h.menu("service.fail");
        try h.waitPending();
        try h.wake();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        recorder.finish();
        try expect(!recorder.failed);
        break :recorded Snapshot.take();
    };

    var replay_pool = ServiceCarrier.init(allocator, io, fixture_root, .{ .max_workers = 2 });
    defer replay_pool.deinit();
    const harness = try native_sdk.TestHarness().create(allocator, .{
        .size = native_sdk.geometry.SizeF.init(320, 200),
    });
    defer harness.destroy(allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try Adapter.create(allocator, .{
        .host_calls = replay_pool.binding(),
        .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
    }, appOptions());
    defer app_state.destroy();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try expect(report.ok());
    try expect(report.effects_fed == 2);
    try expect(!replay_pool.started());
    try expect(recorded.eql(Snapshot.take()));
}
