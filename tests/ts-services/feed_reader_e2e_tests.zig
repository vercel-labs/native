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
    const toggle_request = [_]u8{ 5, 1, 0, 3, 0, 255, 255, 2, 0, 0, 0, 1, 2, 0, 0, 1, 2 };
    var toggle_state: [1]u8 = undefined;
    var accordion_state: [1]u8 = undefined;
    var checkable_state: [1]u8 = undefined;
    var slider_request = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, slider_request[2..6], @bitCast(@as(f32, 0.3)), .little);
    std.mem.writeInt(u32, slider_request[6..10], @bitCast(@as(f32, 0.3)), .little);
    std.mem.writeInt(u32, slider_request[10..14], @bitCast(@as(f32, 0.8)), .little);
    var slider_state: [4]u8 = undefined;
    const split_widget = canvas.Widget{ .kind = .split, .value = 0.3, .interaction_policy = core.nativeSplitPolicy };
    const scroll_widget = canvas.Widget{ .kind = .scroll_view, .interaction_policy = core.nativeScrollPolicy, .runtime_flags = .{ .compiled_scroll_policy = true } };
    for (0..16) |_| {
        try std.testing.expectEqual(@as(f32, 80.5), canvas.widgetCompiledScrollResult(scroll_widget, .{ .operation = 2, .current = 30.5, .previous_source = 30.5, .retained = 80.5 }).?.dx);
        try std.testing.expectEqual(@as(f32, 0.8), canvas.widgetCompiledSplitValue(split_widget, .{ .operation = 2, .value = 0.3, .previous_source = 0.3, .retained = 0.8 }).?);
        try std.testing.expectEqual(@as(usize, 4), core.nativeSliderPolicy(&slider_request, &slider_state));
        try std.testing.expectEqual(@as(usize, 1), core.nativeTogglePolicy(&.{ 10, 5 }, &checkable_state));
        try std.testing.expectEqual(@as(usize, 1), core.nativeAccordionPolicy(&.{ 9, 13 }, &accordion_state));
        try std.testing.expectEqual(@as(usize, 1), core.nativeTogglePolicy(&.{ 9, 4 }, &toggle_state));
        try std.testing.expectEqual(@as(usize, 2), core.nativeTogglePolicy(&toggle_request, &policy_output));
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, &policy_output);
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
        try std.testing.expectEqualSlices(u8, &.{1}, &toggle_state);
        try std.testing.expectEqualSlices(u8, &.{1}, &accordion_state);
        try std.testing.expectEqualSlices(u8, &.{1}, &checkable_state);
        try std.testing.expectEqual(@as(f32, 0.8), @as(f32, @bitCast(std.mem.readInt(u32, &slider_state, .little))));
    }
    try std.testing.expect(std.mem.indexOf(u8, primary, "Service Feed Reader") != null);
    try std.testing.expect(std.mem.indexOf(u8, secondary, "Native SDK Notes") != null);
}

test "compiled scroll offsets preserve exact native f32 clamps and per-axis history" {
    const widget = canvas.Widget{ .kind = .scroll_view, .interaction_policy = core.nativeScrollPolicy, .runtime_flags = .{ .compiled_scroll_policy = true } };
    for ([_]f32{ -30.25, 0, 0.5, 120.75, 9999, std.math.nan(f32), std.math.inf(f32) }) |offset| {
        for ([_]f32{ 0, 1, 150.5, 396, 777.3 }) |viewport| for ([_]f32{ 0, 120, 900.25 }) |content| {
            const state = canvas.ScrollAxisState{ .offset = offset, .viewport_extent = viewport, .content_extent = content };
            try std.testing.expectEqual(state.clamped().offset, canvas.widgetCompiledScrollResult(widget, .{ .operation = 0, .current = offset, .viewport = viewport, .content = content }).?.dx);
            for ([_]f32{ -200.75, 0, 85.25, 9000 }) |delta| {
                var expected = state;
                expected.offset += delta;
                try std.testing.expectEqual(expected.clamped().offset, canvas.widgetCompiledScrollResult(widget, .{ .operation = 1, .current = offset, .viewport = viewport, .content = content, .delta = delta }).?.dx);
            }
        };
    }
    for ([_]f32{ 0.5, 30.5 }) |source| for ([_]?f32{ null, 0.5, 30.5 }) |previous| for ([_]bool{ false, true }) |granted| {
        const expected: f32 = if (previous != null and source == previous.? and granted) -18.5 else source;
        try std.testing.expectEqual(expected, canvas.widgetCompiledScrollResult(widget, .{ .operation = 2, .current = source, .previous_source = previous, .retained = -18.5, .granted = granted }).?.dx);
    };
    for ([_]?f32{ null, 0.5, 30.5 }) |previous| for ([_]?f32{ null, -18.5, 30.5 }) |retained| {
        const clamp = (previous == null or previous.? != 30.5) and (retained == null or retained.? != 30.5);
        try std.testing.expectEqual(if (clamp) @as(f32, 0) else -18.5, canvas.widgetCompiledScrollResult(widget, .{ .operation = 3, .current = -18.5, .delta = 30.5, .previous_source = previous, .retained = retained, .viewport = 150, .content = 450 }).?.dx);
    };
}

test "compiled scroll keyboard and semantic steps preserve every native axis map" {
    for ([_]canvas.ScrollAxes{ .vertical, .horizontal, .both }) |axes| for ([_]bool{ false, true }) |virtualized| {
        for ([_]geometry.SizeF{ .{ .width = 1, .height = 1 }, .{ .width = 333.3, .height = 155.5 } }) |size| {
            const reference = canvas.Widget{ .kind = .scroll_view, .scroll_axes = axes, .layout = .{ .virtualized = virtualized, .padding = geometry.InsetsF.all(0.25) }, .frame = geometry.RectF.init(0, 0, size.width, size.height) };
            var compiled = reference;
            compiled.interaction_policy = core.nativeScrollPolicy;
            compiled.runtime_flags.compiled_scroll_policy = true;
            for ([_]canvas.WidgetSemanticAction{ .increment, .decrement }) |action| {
                try std.testing.expectEqualDeep(canvas.widgetSemanticControlIntentWithActions(reference, action, .{ .increment = true, .decrement = true }), canvas.widgetSemanticControlIntentWithActions(compiled, action, .{ .increment = true, .decrement = true }));
            }
            for ([_][]const u8{ "arrowleft", "arrowright", "arrowup", "arrowdown", "home", "end", "pageup", "pagedown", "space" }) |key| {
                for ([_]canvas.WidgetKeyboardModifiers{ .{}, .{ .shift = true }, .{ .control = true }, .{ .alt = true }, .{ .super = true } }) |modifiers| for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up }) |phase| {
                    const keyboard = canvas.WidgetKeyboardEvent{ .key = key, .modifiers = modifiers, .phase = phase };
                    try std.testing.expectEqualDeep(canvas.widgetKeyboardControlIntent(reference, keyboard), canvas.widgetKeyboardControlIntent(compiled, keyboard));
                };
            }
            compiled.state.disabled = true;
            try std.testing.expect(canvas.widgetKeyboardControlIntent(compiled, .{ .phase = .key_down, .key = "pagedown" }) == null);
        }
    };
}

test "compiled scroll runtime preserves driver overscroll, exact echoes and revoked axes" {
    const Fixture = struct {
        fn layout(allocator: std.mem.Allocator, x: f32, y: f32, axes: canvas.ScrollAxes, native: bool, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            var ui = canvas.Ui(core.Msg).init(allocator);
            var scroll = ui.scroll(.{ .value = y, .value_x = x, .axis = axes }, .{
                ui.column(.{ .width = 720, .height = 600 }, .{ui.text(.{}, "Scroll content")}),
            });
            scroll.widget.runtime_flags.native_scroll = native;
            if (compiled) {
                scroll.widget.interaction_policy = core.nativeScrollPolicy;
                scroll.widget.runtime_flags.compiled_scroll_policy = true;
            }
            const tree = try ui.finalize(scroll);
            return canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 300, 180), nodes);
        }
        fn capture(view: anytype, values: []canvas.ScrollState, frames: []geometry.RectF, stage: usize) void {
            const node = view.widget_layout_nodes[0];
            values[stage] = view.canvasWidgetScrollState(0, node, node.frame);
            frames[stage] = view.widget_layout_nodes[1].frame;
        }
    };
    for ([_]bool{ false, true }) |native| {
        var values: [2][8]canvas.ScrollState = undefined;
        var frames: [2][8]geometry.RectF = undefined;
        for ([_]bool{ false, true }, 0..) |compiled, backend| {
            const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
            defer harness.destroy(std.testing.allocator);
            harness.null_platform.gpu_surfaces = true;
            var state = struct {
                fn app(self: *@This()) native_sdk.App {
                    return .{ .context = self, .name = "scroll-runtime", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
                }
            }{};
            try harness.start(state.app());
            _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 180) });
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var nodes: [4]canvas.WidgetLayoutNode = undefined;
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.5, 0.5, .both, native, compiled, &nodes));
            const view = &harness.runtime.views[0];
            Fixture.capture(view, &values[backend], &frames[backend], 0);
            if (native) _ = try view.applyCanvasWidgetScrollDriverOffset(0, -18.5, 450.5) else _ = try view.applyCanvasWidgetScroll(0, .{ .dx = 30.25, .dy = 40.5 }, .discrete, false);
            Fixture.capture(view, &values[backend], &frames[backend], 1);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.5, 0.5, .both, native, compiled, &nodes));
            Fixture.capture(view, &values[backend], &frames[backend], 2);
            const echo_x = values[backend][2].offset_x;
            const echo_y = values[backend][2].offset_y;
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), echo_x, echo_y, .both, native, compiled, &nodes));
            Fixture.capture(view, &values[backend], &frames[backend], 3);
            try std.testing.expectEqual(echo_x, values[backend][3].offset_x);
            try std.testing.expectEqual(echo_y, values[backend][3].offset_y);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), echo_x, 1000000.5, .both, native, compiled, &nodes));
            Fixture.capture(view, &values[backend], &frames[backend], 4);
            try std.testing.expectEqual(@as(f32, 420), values[backend][4].offset_y);
            try std.testing.expectEqual(echo_x, values[backend][4].offset_x);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), echo_x, 1000000.5, .vertical, native, compiled, &nodes));
            Fixture.capture(view, &values[backend], &frames[backend], 5);
            try std.testing.expectEqual(@as(f32, 0), values[backend][5].offset_x);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), echo_x, 1000000.5, .both, native, compiled, &nodes));
            Fixture.capture(view, &values[backend], &frames[backend], 6);
            try std.testing.expectEqual(@as(f32, 0), values[backend][6].offset_x);
            _ = try view.applyCanvasWidgetScrollKeyboardTarget(0, .start);
            Fixture.capture(view, &values[backend], &frames[backend], 7);
            try std.testing.expectEqual(@as(f32, 0), values[backend][7].offset_y);
        }
        try std.testing.expectEqualDeep(values[0], values[1]);
        try std.testing.expectEqualDeep(frames[0], frames[1]);
    }
}

test "compiled split clamps preserve exact native f32 minimum-width bounds" {
    const widget = canvas.Widget{ .kind = .split, .interaction_policy = core.nativeSplitPolicy };
    for ([_]f32{ -0.1, 0, 0.02, 0.3, 0.95, 1.2, std.math.nan(f32), std.math.inf(f32) }) |value| {
        for ([_]f32{ 0, 1, 200, 396, 777.3 }) |available| {
            for ([_]f32{ 0, 150, 999 }) |first_min| {
                for ([_]f32{ 0, 180, 999 }) |second_min| {
                    try std.testing.expectEqual(canvas.splitEffectiveFraction(value, available, first_min, second_min), canvas.widgetSplitEffectiveFraction(widget, value, available, first_min, second_min, false));
                    if (std.math.isFinite(value)) try std.testing.expectEqual(canvas.splitEffectiveFraction(@max(value, 0.0001), available, first_min, second_min), canvas.widgetSplitEffectiveFraction(widget, value, available, first_min, second_min, true));
                }
            }
        }
    }
    for ([_]f32{ 0.2, 0.5 }) |source| for ([_]?f32{ null, 0.2, 0.5 }) |previous| {
        for ([_]bool{ false, true }) |declared| for ([_]bool{ false, true }) |armed| {
            const expected: f32 = if (previous == null or (source != previous.? and !declared and !armed)) source else 0.7;
            try std.testing.expectEqual(expected, canvas.widgetCompiledSplitValue(widget, .{ .operation = 2, .value = source, .previous_source = previous, .retained = 0.7, .declared_tween = declared, .armed_tween = armed }).?);
        };
    };
}

test "compiled split divider keyboard policy preserves horizontal native intents" {
    for ([_]f32{ -0.1, 0, 0.02, 0.3, 0.4999, 0.95, 1, 1.2 }) |value| {
        const reference = canvas.Widget{ .kind = .split_divider, .value = value };
        var compiled = reference;
        compiled.interaction_policy = core.nativeSplitPolicy;
        for ([_][]const u8{ "arrowleft", "arrowright", "arrowup", "arrowdown", "home", "end", "space", "pageup" }) |key| {
            for ([_]canvas.WidgetKeyboardModifiers{ .{}, .{ .shift = true }, .{ .control = true }, .{ .alt = true }, .{ .super = true } }) |modifiers| {
                for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up }) |phase| {
                    const keyboard = canvas.WidgetKeyboardEvent{ .key = key, .modifiers = modifiers, .phase = phase };
                    try std.testing.expectEqualDeep(canvas.widgetKeyboardControlIntent(reference, keyboard), canvas.widgetKeyboardControlIntent(compiled, keyboard));
                }
            }
        }
        compiled.state.disabled = true;
        try std.testing.expect(canvas.widgetKeyboardControlIntent(compiled, .{ .phase = .key_down, .key = "end" }) == null);
    }
}

test "compiled split capture, retained layout and source tweens match native frames" {
    const TestApp = struct {
        resize_count: usize = 0,
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-split-runtime", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }
        fn event(context: *anyopaque, runtime: *runtime_ns.Runtime, value: native_sdk.Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value == .canvas_widget_resize) self.resize_count += 1;
        }
    };
    const Fixture = struct {
        fn layout(allocator: std.mem.Allocator, source: f32, duration: u32, disabled: bool, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            var ui = canvas.Ui(core.Msg).init(allocator);
            var split = ui.split(.{ .value = source, .gap = 9, .disabled = disabled, .resize_duration = duration, .resize_easing = .linear }, .{
                ui.column(.{ .min_width = 60 }, .{ui.text(.{ .wrap = true }, "First pane with text that wraps as its width changes.")}),
                ui.column(.{ .min_width = 90 }, .{ui.text(.{ .wrap = true }, "Second pane with text that stays at its target wrap during a tween.")}),
            });
            if (compiled) split.widget.interaction_policy = core.nativeSplitPolicy;
            const tree = try ui.finalize(split);
            if (compiled) try std.testing.expect(tree.root.children[1].interaction_policy != null);
            return canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 309, 100), nodes);
        }
        fn frame(harness: anytype, app: native_sdk.App, timestamp: u64) !void {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{ .window_id = 1, .label = "canvas", .size = geometry.SizeF.init(309, 100), .timestamp_ns = timestamp } });
        }
    };
    var fractions: [2][5]f32 = undefined;
    var frames: [2][5]geometry.RectF = undefined;
    var notes: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, backend| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 309, 100) });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var nodes: [8]canvas.WidgetLayoutNode = undefined;
        const initial = try Fixture.layout(arena.allocator(), 0.5, 0, false, compiled, &nodes);
        const split_id = initial.nodes[0].widget.id;
        var divider_id: canvas.ObjectId = 0;
        for (initial.nodes) |node| if (node.widget.kind == .split_divider) {
            divider_id = node.widget.id;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", initial);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 154.5, .y = 50 } });
        try std.testing.expectEqual(divider_id, harness.runtime.views[0].canvas_widget_pressed_id);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_drag, .x = 1000, .y = 50 } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_up, .x = 1000, .y = 50 } });
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.5, 0, false, compiled, &nodes));
        var layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(@as(f32, 0.7), layout.findById(split_id).?.widget.value);
        try std.testing.expectEqual(@as(f32, 210), layout.findById(divider_id).?.frame.x);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.3, 0, false, compiled, &nodes));
        layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(@as(f32, 0.3), layout.findById(split_id).?.widget.value);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetSplitFraction(0, std.math.nan(f32))) == null);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.3, 0, true, compiled, &nodes));
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetSplitPointer(divider_id, .{ .x = 200, .y = 50 })) == null);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.3, 160, false, compiled, &nodes));
        _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.6, 160, false, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.3), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(split_id).?.widget.value);
        for ([_]u64{ 0, 40_000_000, 80_000_000, 120_000_000, 200_000_000 }, 0..) |timestamp, sample| {
            try Fixture.frame(harness, app, timestamp);
            layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
            fractions[backend][sample] = layout.findById(split_id).?.widget.value;
            frames[backend][sample] = layout.findById(divider_id).?.frame;
        }
        try std.testing.expectEqual(@as(f32, 0.6), fractions[backend][4]);
        harness.runtime.appearance.reduce_motion = true;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 0.4, 160, false, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.4), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(split_id).?.widget.value);
        notes[backend] = state.resize_count;
    }
    try std.testing.expectEqualSlices(f32, &fractions[0], &fractions[1]);
    try std.testing.expectEqualDeep(frames[0], frames[1]);
    try std.testing.expectEqual(notes[0], notes[1]);
}

test "compiled slider keyboard and accessibility steps preserve native f32 intents" {
    for ([_]f32{ -0.1, 0, 0.02, 0.3, 0.4999, 0.95, 1, 1.2 }) |value| {
        const reference = canvas.Widget{ .kind = .slider, .value = value };
        var compiled = reference;
        compiled.interaction_policy = core.nativeSliderPolicy;
        for ([_][]const u8{ "arrowleft", "arrowright", "arrowup", "arrowdown", "home", "end", "space", "pageup" }) |key| {
            for ([_]canvas.WidgetKeyboardModifiers{ .{}, .{ .shift = true }, .{ .control = true }, .{ .alt = true }, .{ .super = true } }) |modifiers| {
                for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up }) |phase| {
                    const keyboard = canvas.WidgetKeyboardEvent{ .key = key, .modifiers = modifiers, .phase = phase };
                    try std.testing.expectEqualDeep(canvas.widgetKeyboardControlIntent(reference, keyboard), canvas.widgetKeyboardControlIntent(compiled, keyboard));
                }
            }
        }
        for ([_]canvas.WidgetSemanticAction{ .increment, .decrement }) |action| {
            try std.testing.expectEqualDeep(canvas.widgetSemanticControlIntent(reference, action), canvas.widgetSemanticControlIntent(compiled, action));
        }
        try std.testing.expectEqual(std.math.clamp(value, 0, 1), canvas.widgetCompiledSliderValue(compiled, 0, null, 0, false).?);
        compiled.state.disabled = true;
        try std.testing.expect(canvas.widgetKeyboardControlIntent(compiled, .{ .phase = .key_down, .key = "end" }) == null);
        try std.testing.expect(canvas.widgetSemanticControlIntent(compiled, .increment) == null);
    }
}

test "compiled slider reconcile keeps live capture and clamps pointer updates" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-slider-reconcile", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(source: f32, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            const tree = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{
                .{ .id = 41, .kind = .slider, .frame = geometry.RectF.init(10, 10, 200, 32), .value = source },
                .{ .id = 42, .kind = .slider, .frame = geometry.RectF.init(10, 60, 200, 32), .value = 0.4, .state = .{ .disabled = true } },
            } }, geometry.RectF.init(0, 0, 240, 120), nodes);
            if (compiled) for (nodes[0..tree.nodes.len]) |*node| {
                if (node.widget.kind == .slider) node.widget.interaction_policy = core.nativeSliderPolicy;
            };
            return tree;
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 240, 120) });
        var nodes: [8]canvas.WidgetLayoutNode = undefined;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0.2, compiled, &nodes));
        const view = &harness.runtime.views[0];
        _ = try view.applyCanvasWidgetSliderValue(41, .{ .x = 170, .y = 26 });
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0.2, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.8), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0.5, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.5), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 50, .y = 26 } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 41), view.canvas_widget_pressed_id);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0.7, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.2), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_up, .x = 50, .y = 26 } });
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0.75, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 0.75), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        _ = try view.applyCanvasWidgetSliderValue(41, .{ .x = -40, .y = 26 });
        try std.testing.expectEqual(@as(f32, 0), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        _ = try view.applyCanvasWidgetSliderValue(41, .{ .x = 270, .y = 26 });
        try std.testing.expectEqual(@as(f32, 1), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
        try std.testing.expect((try view.applyCanvasWidgetSliderValue(42, .{ .x = 170, .y = 76 })) == null);
        try std.testing.expectEqual(@as(f32, 0.4), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(42).?.widget.value);
        try std.testing.expect((try view.applyCanvasWidgetSliderValue(41, .{ .x = std.math.nan(f32), .y = 26 })) == null);
        try std.testing.expectEqual(@as(f32, 1), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(41).?.widget.value);
    }
    const widget = canvas.Widget{ .kind = .slider, .value = 0.3, .interaction_policy = core.nativeSliderPolicy };
    try std.testing.expectEqual(@as(f32, 0.8), canvas.widgetCompiledSliderValue(widget, 1, null, 0.8, false).?);
    try std.testing.expectEqual(@as(f32, 1), canvas.widgetCompiledSliderValue(widget, 1, 0.3, 1.2, false).?);
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

test "compiled toggle policy preserves visible focus and nested group boundaries" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-toggle-focus", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 600, 240) });
        const children = [_]canvas.Widget{
            .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 180, 32), .layout = .{ .clip_content = true }, .children = &.{
                .{ .id = 10, .kind = .toggle_group, .frame = geometry.RectF.init(0, 0, 300, 32), .children = &.{
                    .{ .id = 11, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32), .state = .{ .selected = true } },
                    .{ .id = 12, .kind = .toggle_button, .frame = geometry.RectF.init(70, 0, 60, 32), .state = .{ .disabled = true } },
                    .{ .id = 13, .kind = .toggle_button, .frame = geometry.RectF.init(140, 0, 60, 32) },
                    .{ .id = 14, .kind = .toggle_button, .frame = geometry.RectF.init(230, 0, 60, 32) },
                } },
            } },
            .{ .id = 20, .kind = .toggle_group, .frame = geometry.RectF.init(0, 60, 300, 100), .children = &.{
                .{ .id = 21, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32) },
                .{ .id = 22, .kind = .toggle_group, .frame = geometry.RectF.init(70, 0, 140, 32), .children = &.{
                    .{ .id = 23, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32) },
                    .{ .id = 24, .kind = .toggle_button, .frame = geometry.RectF.init(70, 0, 60, 32) },
                } },
                .{ .id = 25, .kind = .toggle_button, .frame = geometry.RectF.init(220, 0, 60, 32) },
            } },
            // Bare toggles have no Home/End group. Button-group edges remain
            // available through the existing native parent-kind contract.
            .{ .id = 30, .kind = .toggle_button, .frame = geometry.RectF.init(350, 0, 60, 32) },
            .{ .id = 40, .kind = .button_group, .frame = geometry.RectF.init(350, 60, 140, 32), .children = &.{
                .{ .id = 41, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32) },
                .{ .id = 42, .kind = .toggle_button, .frame = geometry.RectF.init(70, 0, 60, 32) },
            } },
        };
        var nodes: [32]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 600, 240), &nodes);
        if (compiled) for (nodes[0..layout.nodes.len]) |*node| {
            if (node.widget.kind == .toggle_button or node.widget.kind == .toggle_group) node.widget.interaction_policy = core.nativeTogglePolicy;
        };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        for ([_]struct { start: canvas.ObjectId, key: []const u8, target: canvas.ObjectId }{
            .{ .start = 11, .key = "arrowright", .target = 13 },
            .{ .start = 13, .key = "arrowright", .target = 13 },
            .{ .start = 13, .key = "home", .target = 11 },
            .{ .start = 11, .key = "end", .target = 13 },
            .{ .start = 11, .key = "arrowleft", .target = 11 },
            .{ .start = 21, .key = "arrowright", .target = 25 },
            .{ .start = 25, .key = "home", .target = 21 },
            .{ .start = 23, .key = "end", .target = 24 },
            .{ .start = 24, .key = "arrowright", .target = 24 },
            .{ .start = 24, .key = "home", .target = 23 },
            .{ .start = 30, .key = "end", .target = 30 },
            .{ .start = 41, .key = "end", .target = 42 },
            .{ .start = 42, .key = "home", .target = 41 },
        }) |move| {
            view.canvas_widget_focused_id = move.start;
            view.canvas_widget_focus_visible_id = move.start;
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = move.key } });
            try std.testing.expectEqual(move.target, view.canvas_widget_focused_id);
            const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            try std.testing.expect(retained.findById(11).?.widget.state.selected);
            try std.testing.expect(!retained.findById(13).?.widget.state.selected);
        }
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.toggleCanvasWidgetBooleanControl(12));
        const valued_index = view.canvasWidgetNodeIndexById(30).?;
        view.widget_layout_nodes[valued_index].widget.value = 0.75;
        _ = try view.toggleCanvasWidgetBooleanControl(30);
        try std.testing.expect(!view.widget_layout_nodes[valued_index].widget.state.selected);
        try std.testing.expectEqual(@as(f32, 0), view.widget_layout_nodes[valued_index].widget.value);
        _ = try view.toggleCanvasWidgetBooleanControl(30);
        try std.testing.expect(view.widget_layout_nodes[valued_index].widget.state.selected);
        try std.testing.expectEqual(@as(f32, 1), view.widget_layout_nodes[valued_index].widget.value);
    }
}

test "compiled toggle reconciliation preserves controlled chips and uncontrolled formatting" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-toggle-reconcile", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(selected: ?usize, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            var chips = [_]canvas.Widget{
                .{ .id = 11, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32) },
                .{ .id = 12, .kind = .toggle_button, .frame = geometry.RectF.init(70, 0, 60, 32) },
                .{ .id = 13, .kind = .toggle_button, .frame = geometry.RectF.init(140, 0, 60, 32) },
            };
            // Numeric source selection must use the same canonical register
            // as selected=true, while the retained value is also recognized.
            if (selected) |index| chips[index].value = 0.75;
            const children = [_]canvas.Widget{
                .{ .id = 10, .kind = .toggle_group, .frame = geometry.RectF.init(0, 0, 210, 32), .children = &chips },
                .{ .id = 20, .kind = .toggle_group, .frame = geometry.RectF.init(0, 60, 140, 32), .children = &.{
                    .{ .id = 21, .kind = .toggle_button, .frame = geometry.RectF.init(0, 0, 60, 32) },
                    .{ .id = 22, .kind = .toggle_button, .frame = geometry.RectF.init(70, 0, 60, 32) },
                } },
            };
            const tree = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 300, 160), nodes);
            if (compiled) for (nodes[0..tree.nodes.len]) |*node| {
                if (node.widget.kind == .toggle_button or node.widget.kind == .toggle_group) node.widget.interaction_policy = core.nativeTogglePolicy;
            };
            return tree;
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 160) });
        var nodes: [16]canvas.WidgetLayoutNode = undefined;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(0, compiled, &nodes));
        const view = &harness.runtime.views[0];
        for ([_]canvas.ObjectId{ 13, 21, 22 }) |id| _ = try view.toggleCanvasWidgetBooleanControl(id);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(2, compiled, &nodes));
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(13).?.widget.state.selected);
        for ([_]canvas.ObjectId{ 21, 22 }) |id| try std.testing.expect(retained.findById(id).?.widget.state.selected);
        _ = try view.toggleCanvasWidgetBooleanControl(13);
        _ = try view.toggleCanvasWidgetBooleanControl(22);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(2, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.findById(13).?.widget.state.selected);
        try std.testing.expectEqual(@as(f32, 1), retained.findById(13).?.widget.value);
        try std.testing.expect(retained.findById(21).?.widget.state.selected);
        try std.testing.expect(!retained.findById(22).?.widget.state.selected);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(null, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        for ([_]canvas.ObjectId{ 11, 12, 13 }) |id| {
            try std.testing.expect(!retained.findById(id).?.widget.state.selected);
            try std.testing.expectEqual(@as(f32, 0), retained.findById(id).?.widget.value);
        }
        try std.testing.expect(retained.findById(21).?.widget.state.selected);
        try std.testing.expect(!retained.findById(22).?.widget.state.selected);
    }
}

test "compiled accordion reconciliation preserves source flips and retained expansion" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-accordion-reconcile", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(source: bool, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            const tree = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .column, .children = &.{
                .{ .id = 11, .kind = .accordion, .frame = geometry.RectF.init(0, 0, 200, 32), .value = if (source) 0.75 else 0 },
                .{ .id = 12, .kind = .accordion, .frame = geometry.RectF.init(0, 40, 200, 32) },
                .{ .id = 13, .kind = .accordion, .frame = geometry.RectF.init(0, 80, 200, 32), .state = .{ .disabled = true } },
            } }, geometry.RectF.init(0, 0, 300, 160), nodes);
            if (compiled) for (nodes[0..tree.nodes.len]) |*node| {
                if (node.widget.kind == .accordion) node.widget.interaction_policy = core.nativeAccordionPolicy;
            };
            return tree;
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        try harness.start(state.app());
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 160) });
        var nodes: [8]canvas.WidgetLayoutNode = undefined;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(false, compiled, &nodes));
        const view = &harness.runtime.views[0];
        _ = try view.toggleCanvasWidgetBooleanControl(12);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(true, compiled, &nodes));
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(12).?.widget.state.selected);
        try std.testing.expectEqual(@as(f32, 1), retained.findById(11).?.widget.value);
        _ = try view.toggleCanvasWidgetBooleanControl(11);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(true, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        // An unchanged true source preserves a user collapse; unlike
        // a toggle chip, an accordion does not reassert source selection.
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expectEqual(@as(f32, 0), retained.findById(11).?.widget.value);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(false, compiled, &nodes));
        _ = try view.toggleCanvasWidgetBooleanControl(11);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(false, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(12).?.widget.state.selected);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(true, compiled, &nodes));
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(false, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expect(retained.findById(12).?.widget.state.selected);
        // Missing source history is not a source flip.
        view.widget_source_control_count = 0;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(true, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(!retained.findById(11).?.widget.state.selected);
        try std.testing.expectEqual(@as(?geometry.RectF, null), try view.toggleCanvasWidgetBooleanControl(13));
    }
}

test "compiled accordion toggle retains disclosure animation and concealed input" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-accordion-disclosure", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(arena: std.mem.Allocator, open: bool, compiled: bool) !canvas.WidgetLayoutTree {
            const Ui = canvas.Ui(union(enum) { toggle, press });
            var ui = Ui.init(arena);
            const tree = try ui.finalize(ui.column(.{ .width = 300 }, .{
                ui.el(.accordion, .{ .key = .{ .int = 1 }, .text = "Section", .selected = open, .on_toggle = .toggle }, .{
                    ui.column(.{ .padding = 8 }, .{
                        ui.text(.{}, "Revealed content"),
                        ui.button(.{ .on_press = .press }, "Inside"),
                    }),
                }),
                ui.button(.{ .on_press = .press }, "Below"),
            }));
            const nodes = try arena.alloc(canvas.WidgetLayoutNode, 16);
            const result = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 300, 240), nodes);
            if (compiled) for (nodes[0..result.nodes.len]) |*node| {
                if (node.widget.kind == .accordion) node.widget.interaction_policy = core.nativeAccordionPolicy;
            };
            return result;
        }
        fn find(layout_tree: canvas.WidgetLayoutTree, text: []const u8) canvas.WidgetLayoutNode {
            for (layout_tree.nodes) |node| if (std.mem.eql(u8, node.widget.text, text)) return node;
            unreachable;
        }
        fn frame(harness: anytype, app: native_sdk.App, ns: u64) !void {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
                .window_id = 1,
                .label = "canvas",
                .size = geometry.SizeF.init(300, 240),
                .timestamp_ns = ns,
            } });
        }
    };
    var heights: [2][5]f32 = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, backend| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 240) });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), false, compiled));
        const view = &harness.runtime.views[0];
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        const header = Fixture.find(retained, "Section");
        const inside = Fixture.find(retained, "Inside");
        const below = Fixture.find(retained, "Below");
        const closed = header.frame.height;
        try std.testing.expectEqual(@as(?canvas.WidgetFocusTarget, null), retained.focusTargetById(inside.widget.id));
        _ = try view.toggleCanvasWidgetBooleanControl(header.widget.id);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), true, compiled));
        try std.testing.expect(view.canvasWidgetDisclosureTweenActive());
        try std.testing.expectEqual(closed, Fixture.find(try harness.runtime.canvasWidgetLayout(1, "canvas"), "Section").frame.height);
        for ([_]u64{ 1_000_000_000, 1_050_000_000, 1_100_000_000, 1_300_000_000, 1_500_000_000 }, 0..) |ns, i| {
            try Fixture.frame(harness, app, ns);
            retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            heights[backend][i] = Fixture.find(retained, "Section").frame.height;
            if (i < 3) try std.testing.expectEqual(@as(?canvas.WidgetFocusTarget, null), retained.focusTargetById(inside.widget.id));
        }
        try std.testing.expect(heights[backend][1] > closed);
        try std.testing.expect(heights[backend][1] < heights[backend][4]);
        try std.testing.expect(!view.canvasWidgetDisclosureTweenActive());
        try std.testing.expect(retained.focusTargetById(inside.widget.id) != null);
        _ = try view.toggleCanvasWidgetBooleanControl(header.widget.id);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), false, compiled));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(@as(?canvas.WidgetFocusTarget, null), retained.focusTargetById(inside.widget.id));
        view.canvas_widget_focused_id = header.widget.id;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "tab" } });
        try std.testing.expectEqual(below.widget.id, view.canvas_widget_focused_id);
        harness.runtime.appearance.reduce_motion = true;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), true, compiled));
        try std.testing.expect(!view.canvasWidgetDisclosureTweenActive());
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.focusTargetById(inside.widget.id) != null);
    }
    try std.testing.expectEqualSlices(f32, &heights[0], &heights[1]);
}

test "compiled checkable policy preserves retained state against source changes" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-checkable-reconcile", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(kind: canvas.WidgetKind, source: bool, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            const tree = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .column, .children = &.{
                .{ .id = 11, .kind = kind, .frame = geometry.RectF.init(0, 0, 200, 32), .value = if (source) 0.75 else 0 },
                .{ .id = 12, .kind = kind, .frame = geometry.RectF.init(0, 40, 200, 32), .value = 0.75 },
                .{ .id = 13, .kind = kind, .frame = geometry.RectF.init(0, 80, 200, 32), .value = 0.75, .state = .{ .disabled = true } },
            } }, geometry.RectF.init(0, 0, 300, 160), nodes);
            if (compiled) for (nodes[0..tree.nodes.len]) |*node| {
                if (node.widget.kind == kind) node.widget.interaction_policy = core.nativeTogglePolicy;
            };
            return tree;
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        for ([_]canvas.WidgetKind{ .checkbox, .switch_control, .toggle }) |kind| {
            const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
            defer harness.destroy(std.testing.allocator);
            harness.null_platform.gpu_surfaces = true;
            var state: TestApp = .{};
            try harness.start(state.app());
            _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 160) });
            var nodes: [8]canvas.WidgetLayoutNode = undefined;
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(kind, false, compiled, &nodes));
            const view = &harness.runtime.views[0];
            _ = try view.toggleCanvasWidgetBooleanControl(11);
            _ = try view.toggleCanvasWidgetBooleanControl(12);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(kind, true, compiled, &nodes));
            var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            try std.testing.expect(retained.findById(11).?.widget.state.selected);
            try std.testing.expectEqual(@as(f32, 1), retained.findById(11).?.widget.value);
            // A numeric true source cannot reassert a user-cleared control.
            try std.testing.expect(!retained.findById(12).?.widget.state.selected);
            try std.testing.expectEqual(@as(f32, 0), retained.findById(12).?.widget.value);
            _ = try view.toggleCanvasWidgetBooleanControl(11);
            _ = try view.toggleCanvasWidgetBooleanControl(12);
            for ([_]bool{ true, false, true, false }) |source| {
                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(kind, source, compiled, &nodes));
                retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
                try std.testing.expect(!retained.findById(11).?.widget.state.selected);
                try std.testing.expect(retained.findById(12).?.widget.state.selected);
                try std.testing.expectEqual(@as(f32, 0), retained.findById(11).?.widget.value);
                try std.testing.expectEqual(@as(f32, 1), retained.findById(12).?.widget.value);
            }
            try std.testing.expectEqual(@as(?geometry.RectF, null), try view.toggleCanvasWidgetBooleanControl(13));
        }
    }
}

test "compiled switch activation retains native knob animation and reversal" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-switch-animation", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    var samples: [2][3]f32 = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, backend| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 220, 100) });
        const controls = [_]canvas.Widget{.{
            .id = 4,
            .kind = .switch_control,
            .frame = geometry.RectF.init(10, 20, 112, 32),
            .text = "Live",
            .interaction_policy = if (compiled) core.nativeTogglePolicy else null,
        }};
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 220, 100), &nodes));
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        for ([_]native_sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }, 0..) |kind, i| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = kind, .timestamp_ns = 100 + i * 10, .x = 66, .y = 36 } });
        }
        const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expect(retained.findById(4).?.widget.state.selected);
        const travel = canvas.toggleWidgetKnobTravel(retained.findById(4).?.widget, harness.runtime.views[0].widget_tokens);
        const animations = try harness.runtime.canvasRenderAnimations(1, "canvas");
        try std.testing.expectEqual(@as(usize, 1), animations.len);
        try std.testing.expectEqual(canvas.toggleWidgetKnobCommandId(4), animations[0].id);
        try std.testing.expectEqual(@as(u64, 110), animations[0].start_ns);
        try std.testing.expectEqual(harness.runtime.views[0].widget_tokens.motion.durationMs(.fast), animations[0].duration_ms);
        samples[backend][0] = animations[0].from_transform.?.tx;
        try std.testing.expectApproxEqAbs(-travel, samples[backend][0], 0.001);
        var overrides: [1]canvas.CanvasRenderOverride = undefined;
        const sampled = try canvas.sampleCanvasRenderAnimations(animations, 110 + 60_000_000, &overrides);
        try std.testing.expectEqual(@as(usize, 1), sampled.len);
        samples[backend][1] = sampled[0].transform.?.tx;
        try std.testing.expect(samples[backend][1] > -travel and samples[backend][1] < 0);
        for ([_]native_sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }, 0..) |kind, i| {
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = kind, .timestamp_ns = 200 + i * 10, .x = 66, .y = 36 } });
        }
        const reverse = try harness.runtime.canvasRenderAnimations(1, "canvas");
        try std.testing.expectEqual(@as(usize, 1), reverse.len);
        samples[backend][2] = reverse[0].from_transform.?.tx;
        try std.testing.expectApproxEqAbs(travel, samples[backend][2], 0.001);
        try std.testing.expect(!((try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(4).?.widget.state.selected));
    }
    try std.testing.expectEqualSlices(f32, &samples[0], &samples[1]);
}
