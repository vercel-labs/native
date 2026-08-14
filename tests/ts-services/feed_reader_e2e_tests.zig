//! End-to-end proof battery for examples/service-feed-reader — the
//! canonical services loop as a real app. The build compiles the example's
//! REAL core (src/core.ts + src/shared.ts) through the external core
//! compiler and its src/services tree as a separate plain-scriptc
//! executable, then drives both through `TsUiApp` with the example's
//! SHIPPING markup (app.native, staged beside this file):
//!
//!   - boot parses the built-in sample through the real service child and
//!     the markup lists the typed records;
//!   - a menu-driven refresh performs a REAL buffered `Cmd.fetch` against a
//!     loopback HTTP fixture, the delivered bytes cross to `feeds.parse`
//!     through the generated typed client, and the parsed feed replaces the
//!     sample in the rendered view;
//!   - a non-200 response and an unparseable body each land in the failed
//!     state — the second one carrying the service's kind-tagged error as
//!     UTF-8 JSON on the err arm;
//!   - the whole loop RECORDS and REPLAYS byte-identically with the service
//!     executable absent and the launch variable unset: the journaled env
//!     delivery, fetch response, and service results feed the replay, and
//!     no child process starts.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_feed_reader_core");
const registry = @import("ts_feed_reader_registry");
const fixture_options = @import("ts_feed_reader_options");

const runtime_ns = native_sdk.runtime;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;
const ServiceTransport = native_sdk.ServiceHost(registry);

const app_markup = @embedFile("app.native");
const CompiledAppView = canvas.CompiledMarkupView(core.Model, core.Msg, app_markup);

const fixture_feed = @embedFile("fixture_feed.xml");

const canvas_label = "feed-canvas";
const app_views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const app_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Service Feed Reader",
    .width = 640,
    .height = 480,
    .views = &app_views,
}};
const app_scene: native_sdk.ShellConfig = .{ .windows = &app_windows };

/// TEST-ONLY command mapper: the journaled menu-command path for the void
/// arms (record/replay needs every input in the journal; the app itself
/// dispatches these from markup presses).
fn testCommand(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "feed.refresh")) return .refresh;
    if (std.mem.eql(u8, name, "feed.sample")) return .load_sample;
    return null;
}

fn appOptions() App.Options {
    return .{
        .name = "feed-reader-e2e",
        .scene = app_scene,
        .canvas_label = canvas_label,
        .view = CompiledAppView.build,
        .on_command = testCommand,
    };
}

const fixture_root = ".zig-cache/tmp/feed-reader-e2e";

fn resetFixtureDir() !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, fixture_root) catch {};
    try cwd.createDirPath(std.testing.io, fixture_root);
}

// --------------------------------------------------------- fixture server

/// A loopback HTTP fixture on its own `Io.Threaded`, accepting on an
/// ephemeral 127.0.0.1 port, one connection at a time. `/feed.xml` answers
/// the staged fixture document, `/plain` answers bytes that are not a
/// feed, and every other path answers 404.
const FeedServer = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    accept_future: std.Io.Future(void),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(allocator: std.mem.Allocator) !*FeedServer {
        const self = try allocator.create(FeedServer);
        errdefer allocator.destroy(self);
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        self.* = .{
            .allocator = allocator,
            .threaded = threaded,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .accept_future = undefined,
        };
        self.accept_future = try std.Io.concurrent(io, serverMain, .{self});
        return self;
    }

    fn stop(self: *FeedServer) void {
        const io = self.threaded.io();
        self.stopping.store(true, .release);
        self.accept_future.cancel(io);
        self.listener.deinit(io);
        self.threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self.threaded);
        allocator.destroy(self);
    }

    fn serverMain(self: *FeedServer) void {
        const io = self.threaded.io();
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch return;
            self.handleConnection(io, stream) catch {};
            stream.close(io);
        }
    }

    fn handleConnection(self: *FeedServer, io: std.Io, stream: std.Io.net.Stream) !void {
        _ = self;
        var recv_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buffer);
        var conn_writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
        var request = try server.receiveHead();
        const target = request.head.target;
        if (std.mem.eql(u8, target, "/feed.xml")) {
            try request.respond(fixture_feed, .{ .keep_alive = false });
        } else if (std.mem.eql(u8, target, "/plain")) {
            try request.respond("this is not a feed document", .{ .keep_alive = false });
        } else {
            try request.respond("missing", .{ .status = .not_found, .keep_alive = false });
        }
    }
};

// ----------------------------------------------------------------- harness

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    transport: ServiceTransport,
    executable_path: [:0]u8,
    server: *FeedServer,
    url_buffer: [96]u8 = undefined,
    env_values: [1]Adapter.EnvValue = undefined,

    /// A live app over the REAL service transport and a loopback feed
    /// server; `path` is the route the launch env points the feed URL at.
    fn create(recorder: ?*runtime_ns.SessionRecorder, path: []const u8) !*Harness {
        try resetFixtureDir();
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.server = try FeedServer.start(std.testing.allocator);
        errdefer self.server.stop();
        const url = try std.fmt.bufPrint(&self.url_buffer, "http://127.0.0.1:{d}{s}", .{ self.server.port, path });
        self.env_values = .{.{ .msg = "url_set", .value = url }};

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
            .size = geometry.SizeF.init(640, 480),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.runtime.options.session_recorder = recorder;

        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{
            .env_values = &self.env_values,
            .host_calls = self.transport.binding(),
            .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
        }, appOptions());
        errdefer self.app_state.deinit();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(640, 480),
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
        self.server.stop();
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
        return error.TestTimedOut;
    }

    /// Pump effect results until the model leaves the loading phase.
    fn settle(self: *Harness) !void {
        var rounds: usize = 0;
        while (Bridge.model().phase == .loading) : (rounds += 1) {
            if (rounds > 64) return error.TestTimedOut;
            try self.waitPending();
            try self.wake();
        }
    }

    fn settleBoot(self: *Harness) !void {
        try self.settle();
        try std.testing.expect(Bridge.model().phase == .ready);
        try std.testing.expectEqualStrings("Native SDK Notes", Bridge.model().feedTitle);
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    fn findLabel(self: *Harness, label: []const u8) ?canvas.ObjectId {
        return findLabelIn(self.app_state.tree.?.root, label);
    }

    fn findKindText(self: *Harness, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findKindTextIn(self.app_state.tree.?.root, kind, text);
    }
};

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

fn findLabelIn(widget: canvas.Widget, label: []const u8) ?canvas.ObjectId {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget.id;
    for (widget.children) |child| {
        if (findLabelIn(child, label)) |id| return id;
    }
    return null;
}

fn findKindTextIn(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindTextIn(child, kind, text)) |id| return id;
    }
    return null;
}

fn expectFeedViewportAboveActions(h: *Harness) !void {
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const feed = layout.findById(h.findLabel("Feed items").?).?.frame.normalized();
    const actions = layout.findById(h.findKindText(.button, "Fetch feed").?).?.frame.normalized();
    try std.testing.expect(feed.maxY() <= actions.y);
}

// ------------------------------------------------------------- the loop

test "the service facade preserves the core's unbound view declarations" {
    try std.testing.expectEqualDeep(
        .{ "phase", "totalItems" },
        core.Model.view_unbound,
    );
    try std.testing.expectEqualDeep(
        .{ "fetched", "fetch_failed", "parsed", "parse_failed", "url_set" },
        core.Msg.view_unbound,
    );
}

test "boot parses the built-in sample through the real service child and the markup lists it" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();

    const model = Bridge.model();
    try std.testing.expectEqual(@as(usize, 3), model.items.len);
    try std.testing.expectEqual(@as(@FieldType(core.Model, "totalItems"), 3), model.totalItems);
    try std.testing.expectEqualStrings("The core stays deterministic", model.items[0].title);
    // CDATA unwrapped and entities decoded inside the service.
    try std.testing.expectEqualStrings("Services own the messy parsing", model.items[1].title);
    try std.testing.expectEqualStrings("Recorded sessions replay offline & byte-identically", model.items[2].title);
    try std.testing.expect(h.hasText("Native SDK Notes"));
    try std.testing.expect(h.hasText("Services own the messy parsing"));
    try std.testing.expect(h.hasText("3 of 3 items"));
}

test "refresh fetches the fixture feed and the service returns typed records" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();

    try h.menu("feed.refresh");
    try h.settle();

    const model = Bridge.model();
    try std.testing.expect(model.phase == .ready);
    try std.testing.expectEqualStrings("Native SDK Engineering", model.feedTitle);
    // Seven items discovered, the duplicate link dropped by the service's
    // Map, and the six-item cap fills the scroll viewport.
    try std.testing.expectEqual(@as(usize, 6), model.items.len);
    try std.testing.expectEqual(@as(@FieldType(core.Model, "totalItems"), 7), model.totalItems);
    try std.testing.expectEqualStrings("Records & replay for services", model.items[0].title);
    try std.testing.expectEqualStrings("Typed clients from one contract", model.items[1].title);
    try std.testing.expectEqualStrings("Streaming chunks <in order>", model.items[2].title);
    try std.testing.expectEqualStrings("Typed records reach the view", model.items[5].title);
    try std.testing.expectEqualStrings("https://example.com/blog/typed-clients", model.items[1].link);
    try std.testing.expect(h.hasText("Native SDK Engineering"));
    try std.testing.expect(h.hasText("6 of 7 items"));
    try expectFeedViewportAboveActions(h);

    // The declared minimum window remains honest: the results shrink into
    // the scroll viewport instead of escaping the card into the actions.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(460, 320),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try expectFeedViewportAboveActions(h);
}

test "a non-200 response lands in the failed state with its status" {
    const h = try Harness.create(null, "/missing");
    defer h.destroy();
    try h.settleBoot();

    try h.menu("feed.refresh");
    try h.settle();

    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("the feed answered HTTP 404", Bridge.model().reason);
    try std.testing.expect(h.hasText("the feed answered HTTP 404"));
}

test "bytes that are not a feed surface the service's kind-tagged error on the err arm" {
    const h = try Harness.create(null, "/plain");
    defer h.destroy();
    try h.settleBoot();

    try h.menu("feed.refresh");
    try h.settle();

    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expect(std.mem.indexOf(u8, Bridge.model().reason, "\"kind\":\"unrecognized_feed\"") != null);
    try std.testing.expect(h.hasText("unrecognized_feed"));
}

// -------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [256 * 1024]u8 = undefined,
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

/// A value snapshot of the committed model (committed slices live in the
/// core's heap — copy what outlives a session).
const Snapshot = struct {
    phase: @FieldType(core.Model, "phase"),
    items_len: usize,
    total_items: @FieldType(core.Model, "totalItems"),
    feed_title: [128]u8,
    feed_title_len: usize,
    last_link: [128]u8,
    last_link_len: usize,

    fn take() Snapshot {
        const model = Bridge.model();
        var self: Snapshot = .{
            .phase = model.phase,
            .items_len = model.items.len,
            .total_items = model.totalItems,
            .feed_title = [_]u8{0} ** 128,
            .feed_title_len = @min(model.feedTitle.len, 128),
            .last_link = [_]u8{0} ** 128,
            .last_link_len = 0,
        };
        @memcpy(self.feed_title[0..self.feed_title_len], model.feedTitle[0..self.feed_title_len]);
        if (model.items.len > 0) {
            const link = model.items[model.items.len - 1].link;
            self.last_link_len = @min(link.len, 128);
            @memcpy(self.last_link[0..self.last_link_len], link[0..self.last_link_len]);
        }
        return self;
    }
};

test "the recorded loop replays byte-identically without the service or the network" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "feed-reader-e2e", .window_width = 640, .window_height = 480 });

    // One reference session: the boot sample parse through the real child,
    // then a real loopback fetch handed to the same service operation.
    const recorded = recorded: {
        const h = try Harness.create(recorder, "/feed.xml");
        defer h.destroy();
        try h.settleBoot();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        try h.menu("feed.refresh");
        try h.settle();
        try std.testing.expectEqualStrings("Native SDK Engineering", Bridge.model().feedTitle);
        try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
        break :recorded Snapshot.take();
    };

    // Bind the production carrier to a path that does not exist and launch
    // with the env variable UNSET: replay parks the re-issued requests and
    // feeds the journaled env delivery, fetch response, and service results
    // without spawning anything or opening a socket.
    try resetFixtureDir();
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_root) catch {};
    var absent_transport = ServiceTransport.init(
        std.testing.allocator,
        std.testing.io,
        fixture_root ++ "/deleted-service-host",
        fixture_root,
        null,
    );
    defer absent_transport.deinit();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(640, 480),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{
        .host_calls = absent_transport.binding(),
        .service_results = .{ .index_fn = registry.indexOf, .streaming_fn = registry.isStreaming, .decode_fn = registry.resultDecoder(core) },
    }, appOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    // The env delivery, the boot parse result, the fetch response, and the
    // network parse result.
    try std.testing.expectEqual(@as(u64, 4), report.effects_fed);
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), absent_transport.processId());
    try std.testing.expectEqualDeep(recorded, Snapshot.take());
}
