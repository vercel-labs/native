//! End-to-end proof battery for examples/service-feed-reader — the
//! canonical services loop as a real app. The build compiles the example's
//! REAL core (src/core.ts + src/shared.ts) through the external core
//! compiler and its src/services tree as a separate plain-scriptc
//! executable, then drives both through `TsUiApp` with the example's
//! SHIPPING markup (app.native, staged beside this file):
//!
//!   - boot parses the built-in sample through the real service child and
//!     the markup lists the typed records;
//!   - editing and submitting the URL performs a REAL buffered `Cmd.fetch` against a
//!     loopback HTTP fixture, the delivered bytes cross to `feeds.parse`
//!     through the generated typed client, and the parsed feed replaces the
//!     sample in the rendered view;
//!   - a non-200 response and an unparseable body each land in the failed
//!     state — the second one carrying the service's kind-tagged error as
//!     UTF-8 JSON on the err arm;
//!   - the whole loop RECORDS and REPLAYS byte-identically with the service
//!     executable absent and the launch variable unset: the journaled env
//!     delivery, fetch response, and service results feed the replay, and
//!     no child process starts. Replay uses the reference view to verify
//!     the compiled TypeScript view's native checkpoints.

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
const window_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "feed.native", .source = @embedFile("windows/feed.native") },
    .{ .path = "components/items.native", .source = @embedFile("windows/components/items.native") },
};
const CompiledWindowView = canvas.CompiledMarkupImports(core.Model, core.Msg, "feed.native", &window_sources);
fn referenceWindowView(ui: *App.Ui, model: *const core.Model, label: []const u8) App.Ui.Node {
    std.debug.assert(std.mem.eql(u8, label, "feed"));
    return CompiledWindowView.build(ui, model);
}
const TsView = @import("ts_compiled_view.zig");

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

fn appOptions(reference: bool) App.Options {
    return .{
        .name = "feed-reader-e2e",
        .scene = app_scene,
        .canvas_label = canvas_label,
        .view = if (reference) CompiledAppView.build else TsView.build,
        .window_view = if (reference) referenceWindowView else TsView.buildWindow,
        .on_command = core.commandMsg,
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
        }, appOptions(false));
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

    fn feedWindow(self: *Harness) !native_sdk.platform.WindowInfo {
        var windows: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
        for (self.harness.runtime.listWindows(&windows)) |window| {
            if (window.open and std.mem.eql(u8, window.label, "feed")) return window;
        }
        return error.WindowNotFound;
    }

    fn openFeedWindow(self: *Harness) !void {
        try self.harness.runtime.dispatchAutomationWidgetAction(self.app, .{
            .view_label = canvas_label,
            .id = self.findKindText(.button, "Open feed window").?,
            .action = .press,
        });
        try self.frameFeedWindow();
    }

    fn frameFeedWindow(self: *Harness) !void {
        const window = try self.feedWindow();
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .window_id = window.id,
            .label = "feed-window-canvas",
            .size = geometry.SizeF.init(window.frame.width, window.frame.height),
            .scale_factor = 1,
            .frame_index = 2,
            .timestamp_ns = 2_000_000,
        } });
    }

    fn closeFeedWindow(self: *Harness) !void {
        const event = self.harness.null_platform.userCloseWindow((try self.feedWindow()).id) orelse return error.WindowNotFound;
        try self.harness.runtime.dispatchPlatformEvent(self.app, event);
        try std.testing.expect(!Bridge.model().feedWindowOpen);
    }

    fn refreshFromInput(self: *Harness) !void {
        try self.refreshFromView(canvas_label);
    }

    fn refreshFromView(self: *Harness, view: []const u8) !void {
        const url = self.env_values[0].value;
        const snapshot = self.harness.runtime.automationSnapshot("feed-reader-e2e");
        const id = for (snapshot.widgets) |widget| {
            if (std.mem.eql(u8, widget.view_label, view) and std.mem.eql(u8, widget.name, "Feed URL")) break widget.id;
        } else return error.WidgetNotFound;
        try self.harness.runtime.dispatchAutomationWidgetAction(self.app, .{
            .view_label = view,
            .id = id,
            .action = .set_text,
            .value = url,
        });
        try std.testing.expectEqualStrings(url, Bridge.model().url);
        try self.harness.runtime.dispatchAutomationWidgetAction(self.app, .{
            .view_label = view,
            .id = id,
            .action = .focus,
        });
        var command_buffer: [128]u8 = undefined;
        try self.harness.runtime.dispatchAutomationCommand(self.app, try std.fmt.bufPrint(&command_buffer, "widget-key {s} enter", .{view}));
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
        .{ "feedWindowOpen", "phase", "totalItems", "urlAnchor", "urlFocus", "urlCompStart", "urlCompEnd", "windows" },
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

    try h.refreshFromInput();
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

    try h.refreshFromInput();
    try h.settle();

    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("the feed answered HTTP 404", Bridge.model().reason);
    try std.testing.expect(h.hasText("the feed answered HTTP 404"));
}

test "bytes that are not a feed surface the service's kind-tagged error on the err arm" {
    const h = try Harness.create(null, "/plain");
    defer h.destroy();
    try h.settleBoot();

    try h.refreshFromInput();
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
        try h.openFeedWindow();
        try h.refreshFromView("feed-window-canvas");
        try h.settle();
        try h.frameFeedWindow();
        try std.testing.expectEqualStrings("Native SDK Engineering", Bridge.model().feedTitle);
        const snapshot = h.harness.runtime.automationSnapshot("feed-reader-e2e");
        const has_title = for (snapshot.widgets) |widget| {
            if (std.mem.eql(u8, widget.view_label, "feed-window-canvas") and std.mem.eql(u8, widget.name, "Native SDK Engineering")) break true;
        } else false;
        try std.testing.expect(has_title);
        try h.closeFeedWindow();
        try h.openFeedWindow();
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
    }, appOptions(true));
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

test "compiled primary and window view copies survive alternating scriptc arena resets" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const primary = core.nativeView(allocator);
    const secondary = core.nativeWindowView("feed", allocator);
    const policy_request = [_]u8{ 1, 0, 0, 2, 0, 255, 255, 2, 0, 0, 0, 1, 7 };
    var policy_output: [2]u8 = undefined;
    const tabs_request = [_]u8{ 7, 1, 0, 3, 0, 255, 255, 2, 0, 0, 0, 1, 6, 0, 0, 1, 2 };
    const tree_request = [_]u8{ 5, 1, 0, 3, 0, 255, 255, 2, 0, 0, 0, 0, 0, 1, 5, 1, 0, 0, 0, 1, 1, 2, 0 };
    const list_request = [_]u8{ 5, 1, 0, 3, 0, 255, 255, 2, 0, 0, 0, 1, 7, 0, 0, 1, 3 };
    const menu_request = [_]u8{ 2, 0, 0, 3, 0, 255, 255, 2, 0, 0, 0, 1, 2, 0, 0, 1, 14 };
    const menu_select_request = [_]u8{ 8, 1, 0, 3, 0, 255, 255, 2, 0, 0, 0, 1, 2, 0, 0, 1, 14 };
    var menu_clear: [4]u8 = undefined;
    for (0..16) |_| {
        try std.testing.expectEqual(@as(usize, 4), core.nativeMenuPolicy(&menu_select_request, &menu_clear));
        try std.testing.expectEqual(@as(usize, 2), core.nativeMenuPolicy(&menu_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, &policy_output);
        try std.testing.expectEqual(@as(usize, 2), core.nativeListPolicy(&list_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, &policy_output);
        try std.testing.expectEqual(@as(usize, 2), core.nativeRadioPolicy(&policy_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, &policy_output);
        try std.testing.expectEqual(@as(usize, 2), core.nativeTabsPolicy(&tabs_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, &policy_output);
        try std.testing.expectEqual(@as(usize, 2), core.nativeTreePolicy(&tree_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, &policy_output);
        try std.testing.expectEqualStrings(primary, core.nativeView(allocator));
        try std.testing.expectEqualStrings(secondary, core.nativeWindowView("feed", allocator));
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 1 }, &menu_clear);
    }
    try std.testing.expect(std.mem.indexOf(u8, primary, "Service Feed Reader") != null);
    try std.testing.expect(std.mem.indexOf(u8, secondary, "Native SDK Notes") != null);
}

test "compiled radio group Tab entry falls back when its selection is fixed-clipped" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "gpu-widget-radio-fixed-clip-tab", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var app_state: TestApp = .{};
        const app = app_state.app();
        try harness.start(app);

        _ = try harness.runtime.createView(.{
            .window_id = 1,
            .label = "canvas",
            .kind = .gpu_surface,
            .frame = geometry.RectF.init(0, 0, 220, 80),
        });

        const radios = [_]canvas.Widget{
            .{ .id = 3, .kind = .radio, .frame = geometry.RectF.init(0, 0, 48, 32), .text = "Visible" },
            .{ .id = 4, .kind = .radio, .frame = geometry.RectF.init(0, 0, 48, 32), .text = "Clipped", .state = .{ .selected = true } },
        };
        const children = [_]canvas.Widget{
            .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 40, 32), .text = "Before" },
            .{ .id = 10, .kind = .radio_group, .frame = geometry.RectF.init(52, 0, 48, 32), .layout = .{ .clip_content = true }, .semantics = .{ .label = "View" }, .children = &radios },
            .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(112, 0, 40, 32), .text = "After" },
        };
        var nodes: [6]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 80), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            node.widget.interaction_policy = core.nativeRadioPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

        // The selected radio is the logical entry, but the fixed clip cannot
        // scroll it into view. Tab therefore uses the visible group member
        // and the next Tab still leaves the composite in one step.
        harness.runtime.views[0].canvas_widget_focused_id = 2;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "tab" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_focused_id);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "tab" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 5), harness.runtime.views[0].canvas_widget_focused_id);
    }
}

test "compiled radio navigation skips fixed-clipped candidates" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "gpu-widget-radio-fixed-clip-navigation", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var app_state: TestApp = .{};
        const app = app_state.app();
        try harness.start(app);

        _ = try harness.runtime.createView(.{
            .window_id = 1,
            .label = "canvas",
            .kind = .gpu_surface,
            .frame = geometry.RectF.init(0, 0, 280, 80),
        });

        const radios = [_]canvas.Widget{
            .{ .id = 3, .kind = .radio, .frame = geometry.RectF.init(0, 0, 28, 32), .text = "Hidden first" },
            .{ .id = 4, .kind = .radio, .frame = geometry.RectF.init(0, 0, 28, 32), .text = "Visible one", .state = .{ .selected = true } },
            .{ .id = 5, .kind = .radio, .frame = geometry.RectF.init(0, 0, 28, 32), .text = "Hidden middle" },
            .{ .id = 6, .kind = .radio, .frame = geometry.RectF.init(0, 0, 28, 32), .text = "Visible two" },
            .{ .id = 7, .kind = .radio, .frame = geometry.RectF.init(0, 0, 28, 32), .text = "Hidden last" },
        };
        const children = [_]canvas.Widget{
            .{ .id = 10, .kind = .radio_group, .frame = geometry.RectF.init(20, 0, 160, 32), .layout = .{ .clip_content = true, .gap = 4 }, .semantics = .{ .label = "View" }, .children = &radios },
        };
        var nodes: [7]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 280, 80), &nodes);
        for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.id == 3 or node.widget.id == 5 or node.widget.id == 7) {
                node.frame.x = 220;
            }
        }
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            node.widget.interaction_policy = core.nativeRadioPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

        // Logical order remains 3,4,5,6,7 so scroll viewports can reveal
        // candidates. Fixed clipping cannot reveal 3/5/7; traversal must
        // continue until the next visible member accepts focus.
        harness.runtime.views[0].canvas_widget_focused_id = 4;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 6), harness.runtime.views[0].canvas_widget_focused_id);
        const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(4).?.widget.state.selected);
        try std.testing.expect(retained.findById(6).?.widget.state.selected);

        harness.runtime.views[0].canvas_widget_focused_id = 4;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "end" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 6), harness.runtime.views[0].canvas_widget_focused_id);

        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "home" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 4), harness.runtime.views[0].canvas_widget_focused_id);

        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowleft" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 6), harness.runtime.views[0].canvas_widget_focused_id);
    }
}

test "compiled radio-group arrow navigation reveals selects and focuses an offscreen nested radio" {
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const TestApp = struct {
            fn app(self: *@This()) native_sdk.App {
                return .{ .context = self, .name = "compiled-radio-reveal", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
            }
        };
        var app_state: TestApp = .{};
        const app = app_state.app();
        try harness.start(app);

        _ = try harness.runtime.createView(.{
            .window_id = 1,
            .label = "canvas",
            .kind = .gpu_surface,
            .frame = geometry.RectF.init(0, 0, 240, 64),
        });

        const radios = [_]canvas.Widget{
            .{ .id = 31, .kind = .radio, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "One", .state = .{ .selected = true } },
            .{ .id = 32, .kind = .radio, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Two" },
            .{ .id = 33, .kind = .radio, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Three" },
            .{ .id = 34, .kind = .radio, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Four" },
        };
        const nested = [_]canvas.Widget{.{
            .kind = .column,
            .layout = .{ .gap = 2 },
            .children = &radios,
        }};
        const group = canvas.Widget{
            .id = 30,
            .kind = .radio_group,
            .frame = geometry.RectF.init(0, 0, 0, 118),
            .children = &nested,
        };
        const root = canvas.Widget{ .id = 20, .kind = .scroll_view, .children = &.{group} };
        var nodes: [10]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 64), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            node.widget.interaction_policy = core.nativeRadioPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        view.canvas_widget_focused_id = 31;

        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });

        try std.testing.expectEqual(@as(canvas.ObjectId, 34), view.canvas_widget_focused_id);
        const scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
        const viewport = scrolled.findById(20).?.frame.normalized();
        const focused = scrolled.findById(34).?.frame.normalized();
        try std.testing.expect(focused.y >= viewport.y);
        try std.testing.expect(focused.maxY() <= viewport.maxY());
        try std.testing.expect(!scrolled.findById(31).?.widget.state.selected);
        try std.testing.expect(scrolled.findById(34).?.widget.state.selected);
    }
}

test "compiled bare radio selection clears only direct siblings" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-bare-radios", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 400, 200) });
        const children = [_]canvas.Widget{
            .{ .id = 2, .kind = .radio, .text = "One", .state = .{ .selected = true } },
            .{ .id = 3, .kind = .radio, .text = "Two" },
            .{ .id = 4, .kind = .radio_group, .children = &.{.{ .id = 5, .kind = .radio, .text = "Nested", .state = .{ .selected = true } }} },
            .{ .id = 6, .kind = .row, .children = &.{.{ .id = 7, .kind = .radio, .text = "Other parent", .state = .{ .selected = true } }} },
        };
        var nodes: [7]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .column, .children = &children }, geometry.RectF.init(0, 0, 400, 200), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            node.widget.interaction_policy = core.nativeRadioPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        _ = try harness.runtime.views[0].setCanvasWidgetSelected(3, true);
        const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(2).?.widget.state.selected);
        try std.testing.expect(retained.findById(3).?.widget.state.selected);
        try std.testing.expect(retained.findById(5).?.widget.state.selected);
        try std.testing.expect(retained.findById(7).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try harness.runtime.views[0].setCanvasWidgetSelected(3, true));
    }
}

test "compiled tabs skip clipped triggers preserve boundary focus and isolate selection" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-tabs-policy", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 400, 200) });
        const children = [_]canvas.Widget{
            .{ .id = 10, .kind = .tabs, .frame = geometry.RectF.init(0, 0, 180, 32), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 11, .kind = .segmented_control, .text = "Clipped first", .frame = geometry.RectF.init(0, 0, 40, 32) },
                .{ .id = 12, .kind = .segmented_control, .text = "One", .frame = geometry.RectF.init(0, 0, 40, 32), .state = .{ .selected = true } },
                .{ .id = 13, .kind = .segmented_control, .text = "Disabled", .frame = geometry.RectF.init(0, 0, 40, 32), .state = .{ .disabled = true } },
                .{ .id = 14, .kind = .segmented_control, .text = "Two", .frame = geometry.RectF.init(0, 0, 40, 32) },
                .{ .id = 15, .kind = .segmented_control, .text = "Clipped last", .frame = geometry.RectF.init(0, 0, 40, 32) },
            } },
            .{ .id = 20, .kind = .tabs, .frame = geometry.RectF.init(0, 50, 100, 32), .children = &.{
                .{ .id = 21, .kind = .segmented_control, .text = "Other strip", .state = .{ .selected = true } },
            } },
            .{ .id = 30, .kind = .row, .frame = geometry.RectF.init(0, 100, 100, 32), .children = &.{
                .{ .id = 31, .kind = .segmented_control, .text = "Standalone", .state = .{ .selected = true } },
            } },
        };
        var nodes: [12]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 400, 200), &nodes);
        for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.id == 11 or node.widget.id == 15) node.frame.x = 300;
            if (compiled and (node.widget.kind == .tabs or node.widget.kind == .segmented_control)) node.widget.interaction_policy = core.nativeTabsPolicy;
        }
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        view.canvas_widget_focused_id = 12;
        // Tabs follow visible authored order, unlike radio scroll-reveal
        // traversal. Navigation moves focus without activating a panel.
        for ([_]struct { key: []const u8, id: canvas.ObjectId }{
            .{ .key = "arrowright", .id = 14 },
            .{ .key = "arrowright", .id = 14 },
            .{ .key = "home", .id = 12 },
            .{ .key = "arrowleft", .id = 12 },
            .{ .key = "end", .id = 14 },
        }) |step| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = step.key } });
            try std.testing.expectEqual(step.id, view.canvas_widget_focused_id);
            const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            try std.testing.expect(retained.findById(12).?.widget.state.selected);
            try std.testing.expect(!retained.findById(14).?.widget.state.selected);
        }
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "enter" } });
        const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(12).?.widget.state.selected);
        try std.testing.expect(retained.findById(14).?.widget.state.selected);
        try std.testing.expect(retained.findById(21).?.widget.state.selected);
        try std.testing.expect(retained.findById(31).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.setCanvasWidgetSelected(14, true));
    }
}

test "compiled tree policy preserves logical scroll reveal hierarchy and independent selection" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-tree-policy", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 400, 250) });
        const children = [_]canvas.Widget{
            .{ .id = 20, .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 180, 70), .layout = .{ .clip_content = true }, .semantics = .{ .role = .tree }, .children = &.{
                .{ .id = 31, .kind = .panel, .frame = geometry.RectF.init(0, 0, 150, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 1, .state = .{ .selected = true, .expanded = true } },
                .{ .id = 32, .kind = .panel, .frame = geometry.RectF.init(0, 30, 150, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 2 },
                .{ .id = 33, .kind = .panel, .frame = geometry.RectF.init(0, 60, 150, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 2, .state = .{ .disabled = true } },
                .{ .id = 34, .kind = .panel, .frame = geometry.RectF.init(0, 150, 150, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 1 },
            } },
            .{ .id = 40, .kind = .tree, .frame = geometry.RectF.init(200, 100, 150, 100), .children = &.{
                .{ .id = 41, .kind = .panel, .frame = geometry.RectF.init(0, 0, 150, 60), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .state = .{ .selected = true, .expanded = true }, .children = &.{
                    .{ .id = 42, .kind = .panel, .frame = geometry.RectF.init(0, 30, 150, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } } },
                } },
            } },
        };
        var nodes: [9]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 400, 250), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.kind == .tree or node.widget.semantics.role == .tree or node.widget.semantics.role == .treeitem) node.widget.interaction_policy = core.nativeTreePolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        view.canvas_widget_focused_id = 31;
        for ([_]struct { key: []const u8, id: canvas.ObjectId }{
            .{ .key = "arrowright", .id = 32 },
            .{ .key = "arrowleft", .id = 31 },
            .{ .key = "end", .id = 34 },
            .{ .key = "arrowdown", .id = 34 },
            .{ .key = "arrowup", .id = 32 },
            .{ .key = "home", .id = 31 },
        }) |move| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = move.key } });
            try std.testing.expectEqual(move.id, view.canvas_widget_focused_id);
        }
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "end" } });
        const scrolled = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(scrolled.findById(20).?.widget.value > 0);
        const viewport = scrolled.findById(20).?.frame.normalized();
        const focused = scrolled.findById(34).?.frame.normalized();
        try std.testing.expect(focused.y >= viewport.y and focused.maxY() <= viewport.maxY());
        try std.testing.expect(scrolled.findById(34).?.widget.state.selected);
        try std.testing.expect(!scrolled.findById(31).?.widget.state.selected);
        try std.testing.expect(scrolled.findById(41).?.widget.state.selected);
        view.canvas_widget_focused_id = 41;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowright" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 42), view.canvas_widget_focused_id);
        const nested = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(nested.findById(42).?.widget.state.selected);
        try std.testing.expect(!nested.findById(41).?.widget.state.selected);
        try std.testing.expect(nested.findById(34).?.widget.state.selected);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowleft" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 41), view.canvas_widget_focused_id);
    }
}

test "compiled tree flat hierarchy preserves disabled child boundaries and maximum levels" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-tree-boundaries", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const rows = [_]canvas.Widget{
            .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 100, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 1, .state = .{ .expanded = true } },
            .{ .id = 3, .kind = .panel, .frame = geometry.RectF.init(0, 30, 100, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 2, .state = .{ .disabled = true } },
            .{ .id = 4, .kind = .panel, .frame = geometry.RectF.init(0, 60, 100, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 2 },
            .{ .id = 5, .kind = .panel, .frame = geometry.RectF.init(0, 90, 100, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 65535, .state = .{ .expanded = true } },
            .{ .id = 6, .kind = .panel, .frame = geometry.RectF.init(0, 120, 100, 24), .semantics = .{ .role = .treeitem, .actions = .{ .press = true } }, .tree_level = 65535 },
        };
        var nodes: [6]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .tree, .children = &rows }, geometry.RectF.init(0, 0, 200, 160), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            node.widget.interaction_policy = core.nativeTreePolicy;
        };
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 200, 160) });
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        // Right names the first logical child; a disabled first child does
        // not make a later sibling its replacement. Down skips disabled rows.
        for ([_]struct { from: canvas.ObjectId, key: []const u8, to: canvas.ObjectId }{
            .{ .from = 2, .key = "arrowright", .to = 2 },
            .{ .from = 2, .key = "arrowdown", .to = 4 },
            .{ .from = 4, .key = "arrowleft", .to = 2 },
            .{ .from = 5, .key = "arrowright", .to = 5 },
            .{ .from = 6, .key = "arrowleft", .to = 6 },
        }) |move| {
            view.canvas_widget_focused_id = move.from;
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = move.key } });
            try std.testing.expectEqual(move.to, view.canvas_widget_focused_id);
        }
    }
}

test "compiled list policy preserves visible edges logical reveal and sibling selection" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-list-policy", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 500, 300) });
        const children = [_]canvas.Widget{
            .{ .id = 2, .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 180, 70), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 10, .kind = .list, .frame = geometry.RectF.init(0, 0, 180, 210), .children = &.{
                    .{ .id = 11, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                    .{ .id = 12, .kind = .list_item, .frame = geometry.RectF.init(0, 30, 150, 24), .state = .{ .disabled = true } },
                    .{ .id = 13, .kind = .list_item, .frame = geometry.RectF.init(0, 60, 150, 24) },
                    .{ .id = 14, .kind = .list_item, .frame = geometry.RectF.init(0, 150, 150, 24) },
                    .{ .id = 15, .kind = .column, .frame = geometry.RectF.init(0, 180, 150, 24), .children = &.{
                        .{ .id = 16, .kind = .list, .frame = geometry.RectF.init(0, 0, 150, 24), .children = &.{
                            .{ .id = 17, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 70, 24), .state = .{ .selected = true } },
                            .{ .id = 18, .kind = .list_item, .frame = geometry.RectF.init(75, 0, 70, 24) },
                        } },
                    } },
                } },
            } },
            // Bare items still clear direct siblings and use visible Home/End.
            .{ .id = 20, .kind = .column, .frame = geometry.RectF.init(210, 0, 150, 70), .children = &.{
                .{ .id = 21, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                .{ .id = 22, .kind = .list_item, .frame = geometry.RectF.init(0, 30, 150, 24) },
            } },
            // Fixed clipping excludes a row from visible Home/End edges.
            .{ .id = 30, .kind = .panel, .frame = geometry.RectF.init(210, 100, 150, 20), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 31, .kind = .list, .frame = geometry.RectF.init(0, 0, 150, 120), .children = &.{
                    .{ .id = 32, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                    .{ .id = 33, .kind = .list_item, .frame = geometry.RectF.init(0, 80, 150, 24) },
                } },
            } },
        };
        var nodes: [24]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 500, 300), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.kind == .list or node.widget.kind == .list_item) node.widget.interaction_policy = core.nativeListPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        view.canvas_widget_focused_id = 11;
        view.canvas_widget_focus_visible_id = 11;
        // End stops at the partially visible third row, rather than the last logical row.
        for ([_]struct { key: []const u8, id: canvas.ObjectId }{
            .{ .key = "end", .id = 13 },
            .{ .key = "arrowdown", .id = 14 },
            .{ .key = "arrowdown", .id = 14 },
            .{ .key = "arrowup", .id = 13 },
            .{ .key = "arrowup", .id = 11 },
            .{ .key = "arrowup", .id = 11 },
        }) |move| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = move.key } });
            try std.testing.expectEqual(move.id, view.canvas_widget_focused_id);
            if (move.id == 14) {
                const revealed = try harness.runtime.canvasWidgetLayout(1, "canvas");
                const viewport = revealed.findById(2).?.frame.normalized();
                const focused = revealed.findById(14).?.frame.normalized();
                try std.testing.expect(revealed.findById(2).?.widget.value > 0);
                try std.testing.expect(focused.y >= viewport.y and focused.maxY() <= viewport.maxY());
            }
        }
        // Arrow movement did not select; Enter applies the sibling clear mask.
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.findById(11).?.widget.state.selected);
        for (0..2) |_| try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 14), view.canvas_widget_focused_id);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "enter" } });
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(14).?.widget.state.selected);
        try std.testing.expect(retained.findById(17).?.widget.state.selected);
        try std.testing.expect(retained.findById(21).?.widget.state.selected);
        _ = try view.setCanvasWidgetSelected(18, true);
        _ = try view.setCanvasWidgetSelected(22, true);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(17).?.widget.state.selected);
        try std.testing.expect(retained.findById(18).?.widget.state.selected);
        try std.testing.expect(!retained.findById(21).?.widget.state.selected);
        try std.testing.expect(retained.findById(22).?.widget.state.selected);
        try std.testing.expect(retained.findById(14).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.setCanvasWidgetSelected(22, true));
        view.canvas_widget_focused_id = 21;
        view.canvas_widget_focus_visible_id = 21;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "end" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 22), view.canvas_widget_focused_id);
        view.canvas_widget_focused_id = 32;
        view.canvas_widget_focus_visible_id = 32;
        for ([_][]const u8{ "end", "home" }) |key| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = key } });
            try std.testing.expectEqual(@as(canvas.ObjectId, 32), view.canvas_widget_focused_id);
        }
        // A fully fixed-clipped logical target cannot be scrolled into view.
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 32), view.canvas_widget_focused_id);
    }
}

test "compiled menu policy preserves visible entry traversal committed choice and isolation" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-menu-policy", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 600, 320) });
        const children = [_]canvas.Widget{
            .{ .id = 2, .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 180, 70), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 10, .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 180, 210), .children = &.{
                    .{ .id = 11, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                    .{ .id = 12, .kind = .menu_item, .frame = geometry.RectF.init(0, 30, 150, 24), .state = .{ .disabled = true } },
                    .{ .id = 13, .kind = .menu_item, .frame = geometry.RectF.init(0, 60, 150, 24) },
                    .{ .id = 14, .kind = .menu_item, .frame = geometry.RectF.init(0, 150, 150, 24) },
                } },
            } },
            .{ .id = 20, .kind = .dropdown_menu, .frame = geometry.RectF.init(210, 0, 150, 70), .children = &.{
                .{ .id = 21, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                .{ .id = 22, .kind = .menu_item, .frame = geometry.RectF.init(0, 30, 150, 24) },
            } },
            // A plain action group must not acquire a committed selection.
            .{ .id = 25, .kind = .menu_surface, .frame = geometry.RectF.init(400, 0, 150, 70), .children = &.{
                .{ .id = 26, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24) },
                .{ .id = 27, .kind = .menu_item, .frame = geometry.RectF.init(0, 30, 150, 24) },
            } },
            // Fixed clipping excludes the selected row from visible entry.
            .{ .id = 30, .kind = .panel, .frame = geometry.RectF.init(210, 100, 150, 20), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 31, .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 150, 120), .children = &.{
                    .{ .id = 32, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24) },
                    .{ .id = 33, .kind = .menu_item, .frame = geometry.RectF.init(0, 80, 150, 24), .state = .{ .selected = true } },
                } },
            } },
            // Entry scans descendants, including list rows and nested menus;
            // committed selection still clears only direct menu siblings.
            .{ .id = 40, .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 130, 180, 120), .children = &.{
                .{ .id = 41, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                .{ .id = 42, .kind = .column, .frame = geometry.RectF.init(0, 30, 150, 90), .children = &.{
                    .{ .id = 43, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 150, 24) },
                    .{ .id = 44, .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 30, 150, 60), .children = &.{
                        .{ .id = 45, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 150, 24), .state = .{ .selected = true } },
                        .{ .id = 46, .kind = .menu_item, .frame = geometry.RectF.init(0, 30, 150, 24) },
                    } },
                } },
            } },
        };
        var nodes: [32]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 600, 320), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.kind == .dropdown_menu or node.widget.kind == .menu_surface or node.widget.kind == .menu_item) node.widget.interaction_policy = core.nativeMenuPolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        const menu_index = view.canvasWidgetNodeIndexById(10).?;
        const fixed_index = view.canvasWidgetNodeIndexById(31).?;
        try std.testing.expectEqual(@as(?canvas.ObjectId, 11), view.canvasWidgetMenuSurfaceEntryId(menu_index, false));
        try std.testing.expectEqual(@as(?canvas.ObjectId, 11), view.canvasWidgetMenuSurfaceEntryId(menu_index, true));
        try std.testing.expectEqual(@as(?canvas.ObjectId, 32), view.canvasWidgetMenuSurfaceEntryId(fixed_index, true));
        const selected_index = view.canvasWidgetNodeIndexById(11).?;
        view.widget_layout_nodes[selected_index].widget.state.disabled = true;
        try std.testing.expectEqual(@as(?canvas.ObjectId, 13), view.canvasWidgetMenuSurfaceEntryId(menu_index, false));
        view.widget_layout_nodes[selected_index].widget.state.disabled = false;
        view.canvas_widget_focused_id = 11;
        view.canvas_widget_focus_visible_id = 11;
        // Menu arrows and Home/End stay on visible rows, including a
        // partially clipped row; they do not reveal the offscreen id 14.
        for ([_]struct { key: []const u8, id: canvas.ObjectId }{
            .{ .key = "end", .id = 13 },
            .{ .key = "arrowdown", .id = 13 },
            .{ .key = "arrowdown", .id = 13 },
            .{ .key = "arrowup", .id = 11 },
            .{ .key = "arrowup", .id = 11 },
        }) |move| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = move.key } });
            try std.testing.expectEqual(move.id, view.canvas_widget_focused_id);
        }
        _ = try view.setCanvasWidgetSelected(14, true);
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(14).?.widget.state.selected);
        try std.testing.expect(retained.findById(21).?.widget.state.selected);
        try std.testing.expect(retained.findById(41).?.widget.state.selected);
        try std.testing.expect(retained.findById(45).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.setCanvasWidgetSelected(14, true));
        _ = try view.setCanvasWidgetSelected(22, true);
        _ = try view.setCanvasWidgetSelected(46, true);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(21).?.widget.state.selected);
        try std.testing.expect(retained.findById(22).?.widget.state.selected);
        try std.testing.expect(!retained.findById(45).?.widget.state.selected);
        try std.testing.expect(retained.findById(46).?.widget.state.selected);
        try std.testing.expect(retained.findById(41).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.setCanvasWidgetSelected(26, true));
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.setCanvasWidgetSelected(27, true));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(26).?.widget.state.selected);
        try std.testing.expect(!retained.findById(27).?.widget.state.selected);
        const actions_index = view.canvasWidgetNodeIndexById(25).?;
        try std.testing.expectEqual(@as(?canvas.ObjectId, 26), view.canvasWidgetMenuSurfaceEntryId(actions_index, false));
        try std.testing.expectEqual(@as(?canvas.ObjectId, 27), view.canvasWidgetMenuSurfaceEntryId(actions_index, true));
        view.canvas_widget_focused_id = 32;
        view.canvas_widget_focus_visible_id = 32;
        for ([_][]const u8{ "home", "end", "arrowdown" }) |key| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = key } });
            try std.testing.expectEqual(@as(canvas.ObjectId, 32), view.canvas_widget_focused_id);
        }
        // Entry considers state.selected, while committed-choice clearing
        // also considers a nonzero control value, matching the native seam.
        const nested_index = view.canvasWidgetNodeIndexById(40).?;
        _ = try view.setCanvasWidgetSelected(41, false);
        try std.testing.expectEqual(@as(?canvas.ObjectId, 46), view.canvasWidgetMenuSurfaceEntryId(nested_index, false));
        _ = try view.setCanvasWidgetSelected(46, false);
        const list_index = view.canvasWidgetNodeIndexById(43).?;
        view.widget_layout_nodes[list_index].widget.state.selected = true;
        try std.testing.expectEqual(@as(?canvas.ObjectId, 43), view.canvasWidgetMenuSurfaceEntryId(nested_index, true));
        view.widget_layout_nodes[list_index].widget.state.selected = false;
        const valued_index = view.canvasWidgetNodeIndexById(41).?;
        view.widget_layout_nodes[valued_index].widget.value = 1;
        try std.testing.expectEqual(@as(?canvas.ObjectId, 46), view.canvasWidgetMenuSurfaceEntryId(nested_index, true));
        try std.testing.expect((try view.setCanvasWidgetSelected(41, true)) != null);
    }
}
