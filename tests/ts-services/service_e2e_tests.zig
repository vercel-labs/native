//! Phase-1 TypeScript service seam, end to end. The build compiles this test's
//! core as a library-mode archive and its src/services tree as a separate
//! plain-scriptc executable, then injects both generated projections here.
//!
//! The tests drive the production ServiceHost through TsUiApp and Effects:
//! ordinary TS success + kind-tagged throw, an externally killed child with a
//! successful lazy restart, a bounded hung operation, and session replay with
//! a deliberately absent host executable.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("ts_services_core");
const registry = @import("ts_services_registry");
const fixture_options = @import("ts_services_options");

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;
const ServiceTransport = native_sdk.ServiceHost(registry);
const SkewedRegistry = struct {
    pub const protocol_version = registry.protocol_version;
    pub const contract_fingerprint = [_]u8{0xff} ** registry.contract_fingerprint.len;

    pub fn indexOf(name: []const u8) ?u16 {
        return registry.indexOf(name);
    }
};
const runtime_ns = native_sdk.runtime;

const canvas_label = "ts-services-canvas";
const views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Services",
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
    if (std.mem.eql(u8, name, "service.hang")) return .hang;
    if (std.mem.eql(u8, name, "service.replace-hang")) return .replace_hang;
    return null;
}

fn appOptions() App.Options {
    return .{
        .name = "ts-services-e2e",
        .scene = scene,
        .canvas_label = canvas_label,
        .view = view,
        .on_command = command,
    };
}

const fixture_root = ".zig-cache/tmp/ts-services-e2e";
const hang_marker = fixture_root ++ "/hang.started";

fn resetFixtureDir() !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, fixture_root) catch {};
    try cwd.createDirPath(std.testing.io, fixture_root);
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    transport: ServiceTransport,
    executable_path: [:0]u8,

    fn create(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        try resetFixtureDir();
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.executable_path = try std.Io.Dir.cwd().realPathFileAlloc(
            std.testing.io,
            fixture_options.service_executable,
            std.testing.allocator,
        );
        errdefer std.testing.allocator.free(self.executable_path);
        self.transport = ServiceTransport.init(
            std.testing.allocator,
            std.testing.io,
            self.executable_path,
            fixture_root,
            null,
        );
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
        std.testing.allocator.free(self.executable_path);
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
            try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
        }
        self.app_state.effects.deinit();
        return error.TestTimedOut;
    }

    fn waitForHangMarker(self: *Harness) !void {
        _ = self;
        var waited_ms: usize = 0;
        while (waited_ms < 30_000) : (waited_ms += 5) {
            std.Io.Dir.cwd().access(std.testing.io, hang_marker, .{}) catch {
                try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
                continue;
            };
            return;
        }
        return error.TestTimedOut;
    }

    fn settleBoot(self: *Harness) !void {
        try self.waitPending();
        try self.wake();
        try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 1), Bridge.model().successes);
        try std.testing.expect(!Bridge.model().failed);
    }
};

fn killChild(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
    } else {
        std.posix.kill(-id, .KILL) catch std.posix.kill(id, .KILL) catch {};
    }
}

test "service authority environment is an explicit allowlist" {
    try std.testing.expect(native_sdk.serviceEnvironmentVariableAllowed("PATH"));
    try std.testing.expect(native_sdk.serviceEnvironmentVariableAllowed("SSL_CERT_FILE"));
    try std.testing.expect(!native_sdk.serviceEnvironmentVariableAllowed("NATIVE_SDK_CORE_COMPILER"));
    try std.testing.expect(!native_sdk.serviceEnvironmentVariableAllowed("AWS_SECRET_ACCESS_KEY"));
}

test "service host refuses a sibling built from a different registry" {
    try resetFixtureDir();
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_root) catch {};
    const executable_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        fixture_options.service_executable,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(executable_path);
    const SkewedTransport = native_sdk.ServiceHost(SkewedRegistry);
    var transport = SkewedTransport.init(
        std.testing.allocator,
        std.testing.io,
        executable_path,
        fixture_root,
        null,
    );
    defer transport.deinit();
    const binding = transport.binding();
    binding.request_fn(binding.context, "feeds.parse", 91, "feed");

    var waited_ms: usize = 0;
    while (!(binding.pending_fn orelse unreachable)(binding.context)) : (waited_ms += 5) {
        if (waited_ms >= 30_000) return error.TestTimedOut;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    }
    const completion = (binding.poll_fn orelse unreachable)(binding.context) orelse return error.TestExpectedServiceCompletion;
    try std.testing.expectEqual(@as(u64, 91), completion.key);
    try std.testing.expect(!completion.ok);
    try std.testing.expect(std.mem.indexOf(u8, completion.bytes, "service host exited or rejected") != null);
}

test "ordinary TypeScript service success and kind-tagged throw route through Msgs" {
    const h = try Harness.create(null);
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.fail");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
    try std.testing.expect(Bridge.model().failed);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"kind\":\"fixture_failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "\"message\":\"requested failure\"") != null);
}

test "kill during a request fails it and the next request starts a fresh host" {
    const h = try Harness.create(null);
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.hang");
    try h.waitForHangMarker();
    const killed = h.transport.processId() orelse return error.TestExpectedServiceChild;
    killChild(killed);
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "service host exited") != null);

    try h.menu("service.parse");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 2), Bridge.model().successes);
    try std.testing.expect(!Bridge.model().failed);
}

test "cancelling an active request cannot complete a replacement with the same key" {
    const h = try Harness.create(null);
    defer h.destroy();
    try h.settleBoot();

    try h.menu("service.hang");
    try h.waitForHangMarker();
    try h.menu("service.replace-hang");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 2), Bridge.model().successes);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 0), Bridge.model().failures);
    try std.testing.expect(!Bridge.model().failed);
}

test "a hung operation times out, retires the child, and preserves restart" {
    const h = try Harness.create(null);
    defer h.destroy();
    try h.settleBoot();
    h.transport.setRequestTimeoutMs(150);

    try h.menu("service.hang");
    try h.waitForHangMarker();
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().failures), 1), Bridge.model().failures);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().bytes, "service_timeout") != null);

    try h.menu("service.parse");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().successes), 2), Bridge.model().successes);
}

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

test "journal replay reproduces service results without starting a host" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-services-e2e", .window_width = 320, .window_height = 200 });

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
        try std.testing.expect(!recorder.failed);
        break :recorded Snapshot.take();
    };

    // Bind the production carrier to a path that does not exist. Replay must
    // park the re-issued request in the fake executor and feed the journaled
    // result without ever asking ServiceHost to spawn this path.
    var absent_transport = ServiceTransport.init(
        std.testing.allocator,
        std.testing.io,
        ".zig-cache/tmp/ts-services-e2e/deleted-service-host",
        fixture_root,
        null,
    );
    defer absent_transport.deinit();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = native_sdk.geometry.SizeF.init(320, 200),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{
        .host_calls = absent_transport.binding(),
    }, appOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u64, 2), report.effects_fed);
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), absent_transport.processId());
    try std.testing.expectEqualDeep(recorded, Snapshot.take());
}
