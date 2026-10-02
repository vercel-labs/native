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
    const resizable_widget = canvas.Widget{ .kind = .resizable, .frame = geometry.RectF.init(0, 0, 120, 44), .interaction_policy = core.nativeResizablePolicy };
    const text_widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    for (0..16) |_| {
        try std.testing.expectEqualDeep(canvas.TextInputEvent{ .insert_text = "\n" }, canvas.widgetKeyboardNewlineTextEditEvent(text_widget, .{ .phase = .key_down, .key = "Enter" }).?);
        try std.testing.expectEqual(@as(f32, 150.5), canvas.widgetCompiledResizableWidth(resizable_widget, 0, 120, 30.5).?);
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

test "compiled resizable width policy preserves native f32 minimum and addition" {
    var widget = canvas.Widget{ .kind = .resizable, .interaction_policy = core.nativeResizablePolicy };
    for ([_]f32{ -1, 0, 44, 48, 48.25, 144, 777.3, std.math.nan(f32), std.math.inf(f32) }) |height| {
        widget.frame.height = height;
        for ([_]f32{ -120, 0, 0.25, 48, 120.5, 9999, std.math.nan(f32), std.math.inf(f32) }) |width| {
            const minimum = @max(@as(f32, 48), height);
            try std.testing.expectEqual(@max(minimum, width), canvas.widgetCompiledResizableWidth(widget, 1, width, 0).?);
            for ([_]f32{ -10000, -0.1, 0, 0.1, 30.25, 1000 }) |delta| {
                try std.testing.expectEqual(@max(minimum, width + delta), canvas.widgetCompiledResizableWidth(widget, 0, width, delta).?);
            }
        }
    }
    widget.kind = .panel;
    try std.testing.expect(canvas.widgetCompiledResizableWidth(widget, 0, 120, 30) == null);
}

test "compiled resizable capture and retained rebuilds preserve independent frames" {
    const TestApp = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-resizable-runtime", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const Fixture = struct {
        fn layout(allocator: std.mem.Allocator, width: f32, height: f32, disabled: bool, compiled: bool, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
            const children = [_]canvas.Widget{.{ .id = 3, .kind = .text, .text = "Child", .frame = geometry.RectF.init(22, 24, 40, 20) }};
            const siblings = [_]canvas.Widget{
                .{ .id = 2, .kind = .resizable, .frame = geometry.RectF.init(10, 16, width, height), .children = try allocator.dupe(canvas.Widget, &children), .state = .{ .disabled = disabled }, .interaction_policy = if (compiled) core.nativeResizablePolicy else null },
                .{ .id = 4, .kind = .panel, .frame = geometry.RectF.init(350, 16, 80, 44) },
            };
            return canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = try allocator.dupe(canvas.Widget, &siblings) }, geometry.RectF.init(0, 0, 600, 500), nodes);
        }
    };
    var widths: [2][5]f32 = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, backend| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: TestApp = .{};
        const app = state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 600, 500) });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var nodes: [4]canvas.WidgetLayoutNode = undefined;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 120, 44, false, compiled, &nodes));
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        const child = retained.findById(3).?.frame;
        const neighbor = retained.findById(4).?.frame;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 126, .y = 38 } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_pressed_id);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_drag, .x = 156.5, .y = 38, .delta_x = 30.5 } });
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        widths[backend][0] = retained.findById(2).?.frame.width;
        try std.testing.expectEqual(@as(f32, 150.5), widths[backend][0]);
        try std.testing.expectEqualDeep(child, retained.findById(3).?.frame);
        try std.testing.expectEqualDeep(neighbor, retained.findById(4).?.frame);
        // Source changes during and after capture do not replace retained widths.
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 300, 44, false, compiled, &nodes));
        try std.testing.expectEqual(@as(f32, 150.5), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.frame.width);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_drag, .x = -500, .y = 38, .delta_x = -1000 } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_up, .x = -500, .y = 38 } });
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        widths[backend][1] = retained.findById(2).?.frame.width;
        try std.testing.expectEqual(@as(f32, 48), widths[backend][1]);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 300, 144, false, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        widths[backend][2] = retained.findById(2).?.frame.width;
        try std.testing.expectEqual(@as(f32, 144), widths[backend][2]);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 300, 144, true, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        widths[backend][3] = retained.findById(2).?.frame.width;
        try std.testing.expectEqual(@as(f32, 300), widths[backend][3]);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(2, 30)) == null);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try Fixture.layout(arena.allocator(), 200, 144, false, compiled, &nodes));
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        widths[backend][4] = retained.findById(2).?.frame.width;
        try std.testing.expectEqual(@as(f32, 300), widths[backend][4]);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(2, std.math.nan(f32))) == null);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(2, std.math.inf(f32))) == null);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(2, 0)) == null);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(4, 30)) == null);
        try std.testing.expect((try harness.runtime.views[0].applyCanvasWidgetResizableDelta(999, 30)) == null);
    }
    try std.testing.expectEqualDeep(widths[0], widths[1]);
}

test "compiled text keyboard intent matches native keys modifiers phases and authoritative edits" {
    const keys = [_][]const u8{ "unknown", "Enter", "RETURN", "Backspace", "Delete", "ArrowLeft", "arrowright", "Home", "End", "A" };
    for ([_]canvas.WidgetKind{ .input, .search_field, .textarea }) |kind| {
        for ([_]bool{ false, true }) |submit| {
            const reference = canvas.Widget{ .kind = kind, .submit_on_enter = submit };
            const compiled = canvas.Widget{ .kind = kind, .submit_on_enter = submit, .interaction_policy = core.nativeTextPolicy };
            for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up, .text_input }) |phase| {
                for (0..16) |bits| {
                    for (keys) |key| {
                        for ([_][]const u8{ "", "é\n" }) |text| {
                            const event = canvas.WidgetKeyboardEvent{ .phase = phase, .key = key, .text = text, .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 } };
                            try std.testing.expectEqualDeep(canvas.widgetKeyboardNewlineTextEditEvent(reference, event), canvas.widgetKeyboardNewlineTextEditEvent(compiled, event));
                            try std.testing.expectEqualDeep(canvas.widgetKeyboardTextEditEventForWidget(reference, event), canvas.widgetKeyboardTextEditEventForWidget(compiled, event));
                            try std.testing.expectEqual(canvas.widgetKeyboardTextSubmit(reference, event), canvas.widgetKeyboardTextSubmit(compiled, event));
                        }
                    }
                }
            }
            const stamped = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "Enter", .edit = .{ .insert_text = "trusted\r\n" } };
            try std.testing.expectEqualDeep(canvas.widgetKeyboardTextEditEventForWidget(reference, stamped), canvas.widgetKeyboardTextEditEventForWidget(compiled, stamped));
        }
    }
    // Exercise non-macOS modifier folding through the actual scriptc export.
    var output: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), core.nativeTextPolicy(&.{ 1, 1, 0, 10, 0, 0, 3, 0 }, &output));
    try std.testing.expectEqualDeep([2]u8{ 11, 0 }, output);
    try std.testing.expectEqual(@as(usize, 2), core.nativeTextPolicy(&.{ 1, 1, 0, 8, 0, 0, 3, 0 }, &output));
    try std.testing.expectEqualDeep([2]u8{ 0, 0 }, output);
    try std.testing.expectEqual(@as(usize, 2), core.nativeTextPolicy(&.{ 2, 1, 0, 2, 0, 0, 1, 0 }, &output));
    try std.testing.expectEqualDeep([2]u8{ 15, 0 }, output);
}

test "compiled pointer selection matches native UTF-8 word and hard-line units" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const texts = [_][]const u8{
        "",                     "hello", "hello  world!!!", "snake_case\t next",
        "café 日本",
        "a\xcc\x81 🙂!",
        "one\r\ntwo\n\nlast\r", "\r\n",  " \t\x0b\x0c\r\n", "\x80x\xff",
        "\xf0\x9f",
    };
    for (texts) |text| {
        for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
            const widget = canvas.Widget{ .kind = kind, .text = text, .interaction_policy = core.nativeTextPolicy };
            for ([_]u8{ 2, 3 }) |count| {
                for (0..text.len + 3) |offset| {
                    const expected: canvas.TextSelection = if (count == 2)
                        canvas.textWordSelectionAtOffset(text, offset)
                    else if (kind == .textarea)
                        canvas.textLineSelectionAtOffset(text, offset)
                    else
                        .{ .anchor = 0, .focus = text.len };
                    const result = canvas.widgetCompiledTextPointerSelection(widget, offset, count, 0, .{}).?;
                    try std.testing.expectEqualDeep(expected, result.selection);
                    try std.testing.expectEqualDeep(expected.range(text.len), result.anchor);
                }
            }
        }
    }
    const widget = canvas.Widget{ .kind = .textarea, .text = "one two three", .interaction_policy = core.nativeTextPolicy };
    const anchor = canvas.TextRange.init(4, 7);
    const before = canvas.widgetCompiledTextPointerSelection(widget, 1, 2, 1, anchor).?;
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 7, .focus = 0 }, before.selection);
    const after = canvas.widgetCompiledTextPointerSelection(widget, 10, 2, 1, anchor).?;
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 4, .focus = 13 }, after.selection);
    const inside = canvas.widgetCompiledTextPointerSelection(widget, 5, 2, 1, anchor).?;
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 4, .focus = 7 }, inside.selection);
    const shifted = canvas.widgetCompiledTextPointerSelection(widget, 1, 2, 2, .{ .start = 5 }).?;
    try std.testing.expectEqualDeep(before, shifted);
    // Full text budget, copied result lifetime, and shared policy/view arenas.
    const large = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    const full = canvas.Widget{ .kind = .textarea, .text = large, .interaction_policy = core.nativeTextPolicy };
    const selected = canvas.widgetCompiledTextPointerSelection(full, large.len, 2, 0, .{}).?;
    const view_bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view_bytes);
    var key_output: [2]u8 = undefined;
    _ = core.nativeTextPolicy(&.{ 1, 1, 0, 0, 1, 0, 5, 0 }, &key_output);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = large.len }, selected.selection);
}

test "compiled editable pointer gestures preserve native selection orientation and isolation" {
    const Fixture = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-text-pointer", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
        fn point(widget: canvas.Widget, target: usize) ?geometry.PointF {
            var y = widget.frame.y + 2;
            while (y < widget.frame.y + widget.frame.height) : (y += 4) {
                var x = widget.frame.x + 1;
                while (x < widget.frame.x + widget.frame.width) : (x += 0.5) {
                    const value = geometry.PointF.init(x, y);
                    if (canvas.textOffsetForWidgetPoint(widget, value, .{})) |offset| {
                        if (offset == target) return value;
                    }
                }
            }
            return null;
        }
    };
    const Step = struct { offset: usize, count: u8 = 2, drag: bool = false, shift: bool = false, expected: canvas.TextSelection };
    const steps = [_]Step{
        .{ .offset = 5, .expected = .{ .anchor = 4, .focus = 9 } },
        .{ .offset = 11, .drag = true, .expected = .{ .anchor = 4, .focus = 15 } },
        .{ .offset = 1, .drag = true, .expected = .{ .anchor = 9, .focus = 0 } },
        .{ .offset = 5, .drag = true, .expected = .{ .anchor = 4, .focus = 9 } },
        .{ .offset = 1, .shift = true, .expected = .{ .anchor = 9, .focus = 0 } },
        .{ .offset = 5, .count = 3, .expected = .{ .anchor = 0, .focus = 15 } },
        .{ .offset = 18, .count = 3, .drag = true, .expected = .{ .anchor = 0, .focus = 26 } },
        .{ .offset = 5, .count = 3, .drag = true, .expected = .{ .anchor = 0, .focus = 15 } },
    };
    var selections: [2][steps.len]canvas.TextSelection = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, backend| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var state: Fixture = .{};
        try harness.start(state.app());
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 600, 300) });
        const fields = [_]canvas.Widget{
            .{ .id = 2, .kind = .textarea, .frame = geometry.RectF.init(12, 16, 260, 120), .text = "one café three\r\nfour last", .interaction_policy = if (compiled) core.nativeTextPolicy else null },
            .{ .id = 3, .kind = .input, .frame = geometry.RectF.init(300, 16, 240, 36), .text = "neighbor", .state = .{ .disabled = true }, .interaction_policy = if (compiled) core.nativeTextPolicy else null },
        };
        var nodes: [3]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &fields }, geometry.RectF.init(0, 0, 600, 300), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        const view = &harness.runtime.views[0];
        for (steps, 0..) |step, index| {
            const widget = (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget;
            _ = try view.applyCanvasWidgetTextPointer(2, Fixture.point(widget, step.offset).?, step.drag, step.shift, step.count);
            const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            selections[backend][index] = retained.findById(2).?.widget.text_selection.?;
            try std.testing.expectEqualDeep(step.expected, selections[backend][index]);
            try std.testing.expectEqual(@as(?canvas.TextSelection, null), retained.findById(3).?.widget.text_selection);
        }
        try std.testing.expect((try view.applyCanvasWidgetTextPointer(3, geometry.PointF.init(320, 30), false, false, 3)) == null);
        const anchor = view.canvas_widget_multi_click_anchor;
        try std.testing.expect((try view.applyCanvasWidgetTextPointer(999, geometry.PointF.init(20, 30), false, false, 2)) == null);
        try std.testing.expectEqualDeep(anchor, view.canvas_widget_multi_click_anchor);
    }
    try std.testing.expectEqualDeep(selections[0], selections[1]);
}

test "compiled text reducer matches native edits capacity refusals composition and affinity" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const texts = [_][]const u8{ "", "abc", "café 日本", "a\r\nb\nc", "\x80x\xff", "\xf0\x9f", " \tfoo_bar!!!", "a\xcc\x81🙂" };
    const edits = [_]canvas.TextInputEvent{
        .{ .insert_text = "" },
        .{ .insert_text = "Z🙂" },
        .{ .insert_text = "\r\n" },
        .{ .insert_text = "\xff" },
        .delete_backward,
        .delete_forward,
        .delete_word_backward,
        .delete_word_forward,
        .delete_to_start,
        .delete_to_line_start,
        .clear,
        .{ .move_caret = .{ .direction = .previous } },
        .{ .move_caret = .{ .direction = .previous, .extend = true } },
        .{ .move_caret = .{ .direction = .next } },
        .{ .move_caret = .{ .direction = .next, .extend = true } },
        .{ .move_caret = .{ .direction = .previous_word } },
        .{ .move_caret = .{ .direction = .previous_word, .extend = true } },
        .{ .move_caret = .{ .direction = .next_word } },
        .{ .move_caret = .{ .direction = .next_word, .extend = true } },
        .{ .move_caret = .{ .direction = .start } },
        .{ .move_caret = .{ .direction = .start, .extend = true } },
        .{ .move_caret = .{ .direction = .end } },
        .{ .move_caret = .{ .direction = .end, .extend = true } },
        .{ .set_selection = .{ .anchor = 1, .focus = 3, .affinity = .downstream } },
        .{ .set_selection = .{ .anchor = 999, .focus = 0, .affinity = .downstream } },
        .{ .set_composition = .{ .text = "" } },
        .{ .set_composition = .{ .text = "日本" } },
        .{ .set_composition = .{ .text = "é", .cursor = 1 } },
        .{ .set_composition = .{ .text = "\r\n", .cursor = 1 } },
        .{ .set_composition = .{ .text = "\xff", .cursor = 999 } },
        .commit_composition,
        .cancel_composition,
    };
    var expected_buffer: [64]u8 = undefined;
    var actual_buffer: [64]u8 = undefined;
    for (texts) |text| {
        const selections = [_]canvas.TextSelection{
            .{},                                                          .{ .anchor = 1, .focus = 1, .affinity = .downstream },
            .{ .anchor = text.len, .focus = 0, .affinity = .downstream }, .{ .anchor = text.len + 2, .focus = text.len + 1, .affinity = .downstream },
            .{ .anchor = 2, .focus = 4, .affinity = .downstream },        .{ .anchor = text.len, .focus = text.len },
        };
        const compositions = [_]?canvas.TextRange{ null, .{ .start = 1, .end = text.len }, .{ .start = text.len + 1, .end = 1 }, .{} };
        for (selections) |selection| {
            for (compositions) |composition| {
                const state = canvas.TextEditState{ .text = text, .selection = selection, .composition = composition };
                for (edits, 0..) |edit, index| {
                    const kind = ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea })[index % 5];
                    const widget = canvas.Widget{ .kind = kind, .interaction_policy = core.nativeTextPolicy };
                    for ([_]usize{ 0, 3, 64 }) |capacity| {
                        const expected = state.apply(edit, expected_buffer[0..capacity]) catch |err| {
                            try std.testing.expectError(err, canvas.widgetCompiledTextEdit(widget, state, edit, actual_buffer[0..capacity]));
                            continue;
                        };
                        const actual = (try canvas.widgetCompiledTextEdit(widget, state, edit, actual_buffer[0..capacity])).?;
                        try std.testing.expectEqualStrings(expected.text, actual.text);
                        try std.testing.expectEqualDeep(expected.selection, actual.selection);
                        try std.testing.expectEqualDeep(expected.composition, actual.composition);
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(?canvas.TextEditState, null), try canvas.widgetCompiledTextEdit(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, .{}, .clear, &actual_buffer));
    try std.testing.expectEqual(@as(?canvas.TextEditState, null), try canvas.widgetCompiledTextEdit(.{ .kind = .input }, .{}, .clear, &actual_buffer));
}

test "compiled text reducer supports the full byte budget and copies results before arena reset" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const source = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(source);
    const replacement = try std.testing.allocator.alloc(u8, source.len);
    defer std.testing.allocator.free(replacement);
    const output = try std.testing.allocator.alloc(u8, source.len);
    defer std.testing.allocator.free(output);
    @memset(source, 'a');
    @memset(replacement, 'b');
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    const state = canvas.TextEditState{ .text = source, .selection = .{ .anchor = 0, .focus = source.len } };
    const replaced = (try canvas.widgetCompiledTextEdit(widget, state, .{ .insert_text = replacement }, output)).?;
    try std.testing.expectEqual(source.len, replaced.selection.focus);
    const view_bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view_bytes);
    const selected = canvas.widgetCompiledTextPointerSelection(.{ .kind = .input, .text = "one two", .interaction_policy = core.nativeTextPolicy }, 1, 2, 0, .{}).?;
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 3 }, selected.selection);
    try std.testing.expectEqualStrings(replacement, replaced.text);
    try std.testing.expect(replaced.text.ptr == output.ptr);
    var empty: [0]u8 = .{};
    const caret = (try canvas.widgetCompiledTextEdit(widget, .{ .text = source, .selection = .{ .anchor = source.len, .focus = source.len } }, .{ .move_caret = .{ .direction = .previous } }, &empty)).?;
    try std.testing.expect(caret.text.ptr == source.ptr);
    try std.testing.expectEqual(source.len - 1, caret.selection.focus);
    try std.testing.expectError(error.TextEditBufferTooSmall, canvas.widgetCompiledTextEdit(widget, .{ .text = source, .selection = .{ .anchor = source.len, .focus = source.len } }, .{ .insert_text = "c" }, output));
}

test "compiled retained reducer preserves undo redo across shared storage budget refusals" {
    const Fixture = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-text-storage", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
        fn key(harness: *native_sdk.TestHarness(), application: native_sdk.App, name: []const u8, text: []const u8, primary: bool, redo: bool) !void {
            try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = "canvas",
                .kind = .key_down,
                .key = name,
                .text = text,
                .modifiers = .{ .primary = primary, .shift = redo },
            } });
        }
    };
    const filler = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view - 512);
    defer std.testing.allocator.free(filler);
    @memset(filler, 'a');
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.dispatch_error_policy = .degrade;
        var fixture: Fixture = .{};
        const application = fixture.app();
        try harness.start(application);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
        const textarea = canvas.Widget{ .id = 2, .kind = .textarea, .frame = geometry.RectF.init(12, 16, 180, 84), .text = filler, .semantics = .{ .label = "Message" }, .interaction_policy = if (compiled) core.nativeTextPolicy else null };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{textarea} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 100, .y = 30 } });
        try Fixture.key(harness, application, "!", "!", false, false);
        try Fixture.key(harness, application, "z", "", true, false);
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(filler.len, retained.findById(2).?.widget.text.len);
        const blocker = [_]u8{'c'} ** 505;
        const blocking_text = canvas.Widget{ .id = 3, .kind = .text, .frame = geometry.RectF.init(12, 112, 180, 24), .text = &blocker };
        var blocked_nodes: [3]canvas.WidgetLayoutNode = undefined;
        const blocked = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{ textarea, blocking_text } }, geometry.RectF.init(0, 0, 260, 160), &blocked_nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", blocked);
        const errors_before = harness.runtime.dispatchErrors().len;
        try Fixture.key(harness, application, "z", "", true, true);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqualStrings(filler, retained.findById(2).?.widget.text);
        try std.testing.expectEqual(errors_before + 1, harness.runtime.dispatchErrors().len);
        try std.testing.expectEqualStrings("WidgetTextTooLarge", harness.runtime.dispatchErrors()[errors_before].error_name);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        try Fixture.key(harness, application, "z", "", true, true);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        const restored = retained.findById(2).?.widget.text;
        try std.testing.expectEqual(filler.len + 1, restored.len);
        try std.testing.expect(std.mem.indexOfScalar(u8, restored, '!') != null);
        const burst = [_]u8{'b'} ** 510;
        try Fixture.key(harness, application, "b", &burst, false, false);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(filler.len + 1, retained.findById(2).?.widget.text.len);
        try Fixture.key(harness, application, "z", "", true, false);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqualStrings(filler, retained.findById(2).?.widget.text);
        try Fixture.key(harness, application, "z", "", true, true);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqual(filler.len + 1, retained.findById(2).?.widget.text.len);
    }
}

test "compiled text rebuild policy matches native source selection composition and affinity reconciliation" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const Fixture = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-text-reconcile", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const first = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer first.destroy(std.testing.allocator);
    const second = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer second.destroy(std.testing.allocator);
    const harnesses = [_]*native_sdk.TestHarness(){ first, second };
    var fixtures: [2]Fixture = .{ .{}, .{} };
    for (harnesses, 0..) |harness, backend| {
        harness.null_platform.gpu_surfaces = true;
        try harness.start(fixtures[backend].app());
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    }
    const selections = [_]?canvas.TextSelection{
        null,
        .{ .anchor = 0, .focus = 0 },
        .{ .anchor = 1, .focus = 3 },
        .{ .anchor = 1, .focus = 3, .affinity = .downstream },
        .{ .anchor = 8, .focus = 2, .affinity = .downstream },
        .{ .anchor = std.math.maxInt(usize) - 1, .focus = 1 },
        .{ .anchor = std.math.maxInt(usize), .focus = 1, .affinity = .downstream },
    };
    const previous_selections = [_]?canvas.TextSelection{ null, .{ .anchor = 1, .focus = 3 }, .{ .anchor = 1, .focus = 3, .affinity = .downstream } };
    var scenario: canvas.ObjectId = 10;
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        for ([_][]const u8{ "aé\r\n🙂z", "local café\nnext", "replacement" }) |source| {
            for (previous_selections) |previous_selection| {
                for (selections) |source_selection| {
                    for (selections) |retained_selection| {
                        for (0..3) |composition_mode| {
                            var actuals: [2]canvas.Widget = undefined;
                            for (harnesses, 0..) |harness, backend| {
                                const initial = canvas.Widget{ .id = scenario, .kind = kind, .frame = geometry.RectF.init(12, 16, 180, 84), .text = "aé\r\n🙂z", .text_selection = previous_selection };
                                var initial_nodes: [2]canvas.WidgetLayoutNode = undefined;
                                const initial_layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{initial} }, geometry.RectF.init(0, 0, 260, 160), &initial_nodes);
                                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", initial_layout);
                                // Supply retained runtime state independently of the
                                // previous source tree, as local input/IME would do.
                                const retained = &harness.runtime.views[0].widget_layout_nodes[1].widget;
                                retained.text = "local café\nnext";
                                retained.text_selection = retained_selection;
                                retained.text_composition = if (composition_mode == 1) .{ .start = 1, .end = 3 } else null;
                                retained.value = 2;
                                var next = initial;
                                next.text = source;
                                next.text_selection = source_selection;
                                next.text_composition = if (composition_mode == 2) .{ .start = 0, .end = 1 } else null;
                                next.interaction_policy = if (backend == 1) core.nativeTextPolicy else null;
                                var next_nodes: [2]canvas.WidgetLayoutNode = undefined;
                                const next_layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{next} }, geometry.RectF.init(0, 0, 260, 160), &next_nodes);
                                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", next_layout);
                                actuals[backend] = (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(scenario).?.widget;
                            }
                            try std.testing.expectEqualStrings(actuals[0].text, actuals[1].text);
                            try std.testing.expectEqualDeep(actuals[0].text_selection, actuals[1].text_selection);
                            try std.testing.expectEqualDeep(actuals[0].text_composition, actuals[1].text_composition);
                            try std.testing.expectEqual(actuals[0].value, actuals[1].value);
                            try std.testing.expectEqual(actuals[0].value_x, actuals[1].value_x);
                            scenario += 1;
                        }
                    }
                }
            }
        }
    }
}

test "compiled text rebuild decisions preserve exact offsets across alternating view arenas" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy, .text_selection = .{ .anchor = std.math.maxInt(usize) - 1, .focus = 2 } };
    const state = canvas.TextReconcilePolicyState{
        .source_unchanged = false,
        .source_matches_runtime = true,
        .previous_source_selection = null,
        .retained_selection = .{ .anchor = std.math.maxInt(usize), .focus = 2, .affinity = .downstream },
    };
    const result = canvas.widgetCompiledTextReconcile(widget, state).?;
    try std.testing.expect(result.retain_state);
    try std.testing.expect(!result.retain_text and !result.retain_affinity and !result.retain_selection_composition);
    const view_bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view_bytes);
    const pointer = canvas.widgetCompiledTextPointerSelection(.{ .kind = .input, .text = "one two", .interaction_policy = core.nativeTextPolicy }, 1, 2, 0, .{}).?;
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 3 }, pointer.selection);
    try std.testing.expect(result.retain_state and !result.retain_affinity);
    var echo = widget;
    echo.text_selection = state.retained_selection;
    echo.text_selection.?.affinity = .upstream;
    try std.testing.expect(canvas.widgetCompiledTextReconcile(echo, state).?.retain_affinity);
    try std.testing.expect(canvas.widgetCompiledTextReconcile(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, state) == null);
    try std.testing.expect(canvas.widgetCompiledTextReconcile(.{ .kind = .textarea }, state) == null);
}

test "compiled text reconciliation retains the full budget and respects disabled or fresh entries" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const Fixture = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-text-reconcile-budget", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const source = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(source);
    const local = try std.testing.allocator.alloc(u8, source.len);
    defer std.testing.allocator.free(local);
    @memset(source, 'a');
    @memset(local, 'b');
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var fixture: Fixture = .{};
        try harness.start(fixture.app());
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
        var widget = canvas.Widget{ .id = 2, .kind = .textarea, .frame = geometry.RectF.init(12, 16, 180, 84), .text = source, .interaction_policy = if (compiled) core.nativeTextPolicy else null };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        var layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{widget} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        harness.runtime.views[0].widget_layout_nodes[1].widget.text = local;
        harness.runtime.views[0].widget_layout_nodes[1].widget.text_selection = .{ .anchor = local.len, .focus = local.len };
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqualStrings(local, retained.findById(2).?.widget.text);
        try std.testing.expectEqual(local.len, retained.findById(2).?.widget.text_selection.?.focus);
        widget.state.disabled = true;
        layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{widget} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqualStrings(source, retained.findById(2).?.widget.text);
        try std.testing.expect(retained.findById(2).?.widget.text_selection == null);
        widget.state.disabled = false;
        widget.id = 3;
        layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{widget} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
        try std.testing.expectEqualStrings(source, retained.findById(3).?.widget.text);
        try std.testing.expect(retained.findById(3).?.widget.text_selection == null);
    }
}

test "compiled single-line new input matches native inserts composition cursors and borrowed payloads" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const texts = [_][]const u8{ "", "\r\n\n", "a\r\né\n🙂z", "café 🙂", "\xc3\n\xa9", "\x80\r\xff", "a\tb" };
    const cursors = [_]?usize{ null, 0, 1, 2, 3, 7, 999, std.math.maxInt(usize) };
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        const widget = canvas.Widget{ .kind = kind, .interaction_policy = core.nativeTextPolicy };
        for (texts) |text| {
            var expected_buffer: [64]u8 = undefined;
            const insertion = canvas.sanitizedSingleLineTextInputEvent(kind, .{ .insert_text = text });
            if (insertion) |expected| @memcpy(expected_buffer[0..expected.insert_text.len], expected.insert_text);
            const actual = canvas.sanitizedTextInputEventForWidget(widget, .{ .insert_text = text });
            try std.testing.expectEqual(insertion == null, actual == null);
            if (insertion) |expected| {
                try std.testing.expectEqualStrings(expected_buffer[0..expected.insert_text.len], actual.?.insert_text);
                if (std.mem.indexOfAny(u8, text, "\r\n") == null) try std.testing.expectEqual(text.ptr, actual.?.insert_text.ptr);
            }
            for (cursors) |cursor| {
                const event = canvas.TextInputEvent{ .set_composition = .{ .text = text, .cursor = cursor } };
                const expected = canvas.sanitizedSingleLineTextInputEvent(kind, event).?.set_composition;
                @memcpy(expected_buffer[0..expected.text.len], expected.text);
                const prepared = canvas.sanitizedTextInputEventForWidget(widget, event).?.set_composition;
                try std.testing.expectEqualStrings(expected_buffer[0..expected.text.len], prepared.text);
                try std.testing.expectEqual(expected.cursor, prepared.cursor);
            }
        }
        const selection = canvas.TextInputEvent{ .set_selection = .{ .anchor = 8, .focus = 2, .affinity = .downstream } };
        try std.testing.expectEqualDeep(selection, canvas.sanitizedTextInputEventForWidget(widget, selection).?);
    }
}

test "compiled paste matches native sanitization and UTF-8 prefix boundaries" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const texts = [_][]const u8{ "", "\r\n", "a\nbc", "é\r\n🙂z", "a\x80\x80b", "\xff\xc3\xa9" };
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        for (texts) |text| {
            for (0..12) |available| {
                const sanitized = canvas.sanitizedSingleLineTextInputEvent(kind, .{ .insert_text = text });
                var expected_buffer: [64]u8 = undefined;
                const expected = if (sanitized) |event| event.insert_text else "";
                const length = canvas.snapTextOffset(expected, available);
                @memcpy(expected_buffer[0..length], expected[0..length]);
                const actual = canvas.widgetCompiledTextInput(.{ .kind = kind, .interaction_policy = core.nativeTextPolicy }, text, 2, null, available);
                try std.testing.expectEqualStrings(expected_buffer[0..length], if (actual) |prepared| prepared.text else "");
                try std.testing.expectEqual(expected.len > available, if (actual) |prepared| prepared.truncated else false);
            }
        }
    }
}

test "compiled input preparation preserves full-budget rewritten bytes across view and edit arenas" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const input = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view + 1);
    defer std.testing.allocator.free(input);
    @memset(input, 'a');
    input[7] = '\n';
    input[11] = '\r';
    const widget = canvas.Widget{ .kind = .input, .interaction_policy = core.nativeTextPolicy };
    const text = input[0..canvas.max_widget_text_bytes_per_view];
    const prepared = canvas.sanitizedTextInputEventForWidget(widget, .{ .insert_text = text }).?.insert_text;
    try std.testing.expectEqual(text.len - 2, prepared.len);
    try std.testing.expect(std.mem.indexOfAny(u8, prepared, "\r\n") == null);
    const view_bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view_bytes);
    _ = canvas.widgetCompiledTextPointerSelection(.{ .kind = .textarea, .text = "one two", .interaction_policy = core.nativeTextPolicy }, 1, 2, 0, .{}).?;
    try std.testing.expectEqual(@as(u8, 'a'), prepared[7]);
    try std.testing.expectEqual(@as(u8, 'a'), prepared[prepared.len - 1]);
    const over_budget = canvas.sanitizedTextInputEventForWidget(widget, .{ .insert_text = input }).?.insert_text;
    try std.testing.expectEqual(input.ptr, over_budget.ptr);
    try std.testing.expectEqual(input.len, over_budget.len);
    const borrowed = canvas.widgetCompiledTextInput(widget, "é🙂", 2, null, 3).?;
    try std.testing.expectEqualStrings("é", borrowed.text);
    try std.testing.expect(borrowed.truncated);
    try std.testing.expect(canvas.widgetCompiledTextInput(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, "x", 0, null, 0) == null);
}

test "compiled clipboard paste uses shared storage freed by selection and composition" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const Fixture = struct {
        truncated: bool = false,
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-paste-capacity", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"), .event_fn = onEvent };
        }
        fn onEvent(context: *anyopaque, _: *native_sdk.Runtime, event: native_sdk.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .canvas_widget_keyboard and event.canvas_widget_keyboard.keyboard.edit_truncated) self.truncated = true;
        }
    };
    const filler = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view - 32);
    defer std.testing.allocator.free(filler);
    @memset(filler, 'a');
    for ([_]canvas.WidgetKind{ .input, .textarea }) |kind| {
        for ([_]bool{ false, true }) |compiled| {
            const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
            defer harness.destroy(std.testing.allocator);
            harness.null_platform.gpu_surfaces = true;
            var fixture: Fixture = .{};
            const application = fixture.app();
            try harness.start(application);
            _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
            const policy: ?*const fn ([]const u8, []u8) usize = if (compiled) core.nativeTextPolicy else null;
            const children = [_]canvas.Widget{
                .{ .id = 2, .kind = kind, .frame = geometry.RectF.init(12, 16, 180, 84), .text = "Keep", .text_selection = .{ .anchor = 0, .focus = 4 }, .interaction_policy = policy },
                .{ .id = 3, .kind = .text, .frame = geometry.RectF.init(12, 112, 180, 24), .text = filler },
            };
            var nodes: [3]canvas.WidgetLayoutNode = undefined;
            const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 260, 160), &nodes);
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
            try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 100, .y = 30 } });
            try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "a", .modifiers = .{ .primary = true } } });
            const before = (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget;
            const replaced = canvas.widgetTextSelectionRange(before).?.byteLen(before.text.len);
            const available = canvas.max_widget_text_bytes_per_view - (harness.runtime.views[0].widget_text_len - replaced);
            try std.testing.expect(available > 4 and available < 64);
            var raw: [192]u8 = undefined;
            var raw_len: usize = 0;
            for (0..available) |_| {
                raw[raw_len] = 'b';
                raw[raw_len + 1] = '\n';
                raw_len += 2;
            }
            try harness.runtime.writeClipboard(raw[0..raw_len]);
            try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "v", .modifiers = .{ .primary = true } } });
            var current = (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget;
            try std.testing.expectEqual(available, current.text.len);
            try std.testing.expectEqual(kind == .textarea, fixture.truncated);
            if (kind == .input) try std.testing.expect(std.mem.indexOfScalar(u8, current.text, '\n') == null);
            // A full view still admits exactly the bytes freed by active
            // preedit, and reports a truncated multibyte suffix loudly.
            harness.runtime.views[0].widget_layout_nodes[1].widget.text_composition = .{ .start = 0, .end = 2 };
            fixture.truncated = false;
            try harness.runtime.writeClipboard("é🙂");
            try harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "v", .modifiers = .{ .primary = true } } });
            current = (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget;
            try std.testing.expectEqual(available, current.text.len);
            try std.testing.expect(std.mem.startsWith(u8, current.text, "é"));
            try std.testing.expect(current.text_composition == null);
            try std.testing.expect(fixture.truncated);
            try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
        }
    }
}

test "compiled history recording matches native retained entries and payloads" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    try harness.start(.{ .context = &context, .name = "compiled-history-deltas", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") });
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    const view = &harness.runtime.views[0];
    const corpus = [_][]const u8{ "", "aéz", "aĩz", "a🙂z", "a\rz", "a\nz", "a\r\nz", "a\x80\xffz" };
    const edits = [_]canvas.TextInputEvent{
        .{ .insert_text = "ê" },
        .{ .insert_text = "ĩ" },
        .{ .insert_text = "\r\n" },
        .delete_backward,
        .delete_forward,
        .clear,
        .{ .set_composition = .{ .text = "" } },
        .{ .set_composition = .{ .text = "日" } },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    var expected_bytes: [32]u8 = undefined;
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        for (corpus) |before| {
            for ([_]canvas.TextSelection{
                .{},                                                                                             .{ .anchor = before.len, .focus = 0 }, .{ .anchor = 1, .focus = 2 },
                .{ .anchor = std.math.maxInt(usize), .focus = std.math.maxInt(usize), .affinity = .downstream },
            }) |selection| {
                for (edits) |edit| {
                    var expected_entry: ?@TypeOf(view.canvas_widget_text_history_entries[0]) = null;
                    var expected_len: usize = 0;
                    for ([_]bool{ false, true }) |compiled| {
                        // Unmount between variants so unchanged authored bytes
                        // cannot retain the prior variant's local edit state.
                        const empty = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack }, geometry.RectF.init(0, 0, 260, 160), &nodes);
                        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty);
                        view.canvas_widget_text_history_next_serial = 1;
                        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{.{
                            .id = 2,
                            .kind = kind,
                            .frame = geometry.RectF.init(12, 16, 180, 84),
                            .text = before,
                            .text_selection = selection,
                            .interaction_policy = if (compiled) core.nativeTextPolicy else null,
                        }} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
                        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
                        _ = try view.applyCanvasWidgetTextEdit(2, edit);
                        try std.testing.expect(view.canvas_widget_text_history_entry_count <= 1);
                        const entry = if (view.canvas_widget_text_history_entry_count == 0) null else view.canvas_widget_text_history_entries[0];
                        const payload = view.canvas_widget_text_history_bytes[0..view.canvas_widget_text_history_byte_count];
                        if (!compiled) {
                            expected_entry = entry;
                            expected_len = payload.len;
                            @memcpy(expected_bytes[0..expected_len], payload);
                        } else {
                            try std.testing.expectEqualDeep(expected_entry, entry);
                            try std.testing.expectEqualSlices(u8, expected_bytes[0..expected_len], payload);
                        }
                    }
                }
            }
        }
    }
}

test "compiled history deltas support two full text budgets and survive arena resets" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const budget = canvas.max_widget_text_bytes_per_view;
    const before = try std.testing.allocator.alloc(u8, budget);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(u8, budget);
    defer std.testing.allocator.free(after);
    @memset(before, 'a');
    @memset(after, 'a');
    @memcpy(before[budget / 2 ..][0..2], "é");
    @memcpy(after[budget / 2 ..][0..2], "ĩ");
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    const source = canvas.TextEditState{ .text = before, .selection = .{} };
    var target = canvas.TextEditState{ .text = after, .selection = .{} };
    const delta = canvas.widgetCompiledTextHistoryDelta(widget, source, target, false).?.delta;
    const bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    _ = canvas.widgetCompiledTextInput(widget, "other\ninput", 0, null, 0);
    try std.testing.expectEqualDeep(canvas.TextHistoryDelta{ .prefix_len = budget / 2, .before_end = budget / 2 + 2, .after_end = budget / 2 + 2 }, delta);
    @memset(after, 'b');
    const entire = canvas.widgetCompiledTextHistoryDelta(widget, source, target, false).?.delta;
    try std.testing.expectEqualDeep(canvas.TextHistoryDelta{ .prefix_len = 0, .before_end = budget, .after_end = budget }, entire);
    target.text = before;
    try std.testing.expect(canvas.widgetCompiledTextHistoryDelta(widget, source, target, false).? == .none);
    try std.testing.expect(canvas.widgetCompiledTextHistoryDelta(widget, source, target, true).? == .none);
    target.composition = .{ .start = budget, .end = budget };
    const empty = canvas.widgetCompiledTextHistoryDelta(widget, .{ .text = before, .selection = .{ .anchor = std.math.maxInt(usize), .focus = std.math.maxInt(usize) } }, target, true).?.delta;
    try std.testing.expectEqualDeep(canvas.TextHistoryDelta{ .prefix_len = budget, .before_end = budget, .after_end = budget }, empty);
    try std.testing.expect(canvas.widgetCompiledTextHistoryDelta(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, source, target, false) == null);
}

test "compiled composition history handles bounds full budgets and arena ownership" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    var state = canvas.TextCompositionHistoryState{
        .prefix_len = 1,
        .removed_len = 6,
        .before_text_len = 8,
        .after_text_len = 15,
        .capacity = 32,
        .active = true,
        .before_matches = false,
    };
    const plan = canvas.widgetCompiledTextCompositionHistory(widget, state).?;
    const bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    _ = canvas.widgetCompiledTextInput(widget, "other\ninput", 0, null, 0);
    try std.testing.expectEqualDeep(canvas.TextCompositionHistoryResult{ .action = .retain, .after_end = 14, .inserted_len = 13 }, plan);
    state.after_text_len = 8;
    state.before_matches = true;
    try std.testing.expectEqual(.retain, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.active = false;
    try std.testing.expectEqual(.remove, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.before_matches = false;
    try std.testing.expectEqual(.commit, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.after_text_len = 2;
    try std.testing.expectEqualDeep(canvas.TextCompositionHistoryResult{ .action = .commit, .after_end = 1 }, canvas.widgetCompiledTextCompositionHistory(widget, state).?);
    state.after_text_len = 1;
    try std.testing.expectEqual(.discard, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.after_text_len = 15;
    state.capacity = 18;
    try std.testing.expectEqual(.discard, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.capacity = 19;
    try std.testing.expectEqual(.commit, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.removed_len = 8;
    try std.testing.expectEqual(.discard, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state.prefix_len = std.math.maxInt(u32);
    try std.testing.expectEqual(.discard, canvas.widgetCompiledTextCompositionHistory(widget, state).?.action);
    state = .{ .prefix_len = 0, .removed_len = 0, .before_text_len = 0, .after_text_len = canvas.max_widget_text_bytes_per_view, .capacity = canvas.max_widget_text_bytes_per_view, .active = true, .before_matches = false };
    try std.testing.expectEqualDeep(canvas.TextCompositionHistoryResult{ .action = .retain, .after_end = canvas.max_widget_text_bytes_per_view, .inserted_len = canvas.max_widget_text_bytes_per_view }, canvas.widgetCompiledTextCompositionHistory(widget, state).?);
    try std.testing.expect(canvas.widgetCompiledTextCompositionHistory(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, state) == null);
}

test "compiled composition updates preserve removed bytes redo and neighboring pool entries" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-composition-history", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 400, 300) });
    const view = &harness.runtime.views[0];
    const history_pool = view.canvas_widget_text_history_bytes;
    defer view.canvas_widget_text_history_bytes = history_pool;
    // Force actual eviction and movement using a small shared pool, without
    // changing the editors' text capacity or the number of entry slots.
    view.canvas_widget_text_history_bytes = history_pool[0..40];
    const Entry = @TypeOf(view.canvas_widget_text_history_entries[0]);
    const HistorySnapshot = struct {
        entries: [16]Entry = @splat(.{}),
        count: usize = 0,
        payload: [40]u8 = @splat(0),
        payload_len: usize = 0,
        text: [3][128]u8 = @splat(@splat(0)),
        lengths: [3]usize = @splat(0),
        selection: [3]canvas.TextSelection = @splat(.{}),
        composition: [3]?canvas.TextRange = @splat(null),
        next_serial: u64 = 0,
    };
    const Battery = struct {
        expected: [64]HistorySnapshot = undefined,
        step: usize = 0,
        compiled: bool = false,
        fn save(self: *@This(), v: anytype) !void {
            var snapshot: HistorySnapshot = .{ .count = v.canvas_widget_text_history_entry_count, .next_serial = v.canvas_widget_text_history_next_serial, .payload_len = v.canvas_widget_text_history_byte_count };
            @memcpy(snapshot.entries[0..snapshot.count], v.canvas_widget_text_history_entries[0..snapshot.count]);
            @memcpy(snapshot.payload[0..v.canvas_widget_text_history_byte_count], v.canvas_widget_text_history_bytes[0..v.canvas_widget_text_history_byte_count]);
            for (v.widget_layout_nodes[1..4], 0..) |node, i| {
                const widget = node.widget;
                @memcpy(snapshot.text[i][0..widget.text.len], widget.text);
                snapshot.lengths[i] = widget.text.len;
                snapshot.selection[i] = widget.text_selection orelse .{};
                snapshot.composition[i] = widget.text_composition;
            }
            if (self.compiled) try std.testing.expectEqualDeep(self.expected[self.step], snapshot) else self.expected[self.step] = snapshot;
            self.step += 1;
        }
        fn edit(self: *@This(), v: anytype, id: canvas.ObjectId, event: canvas.TextInputEvent) !void {
            _ = try v.applyCanvasWidgetTextEdit(id, event);
            try self.save(v);
        }
        fn shortcut(self: *@This(), test_harness: anytype, application: native_sdk.App, id: canvas.ObjectId, redo: bool) !void {
            test_harness.runtime.views[0].canvas_widget_focused_id = id;
            try test_harness.runtime.dispatchPlatformEvent(application, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "z", .modifiers = .{ .primary = true, .shift = redo } } });
            try self.save(&test_harness.runtime.views[0]);
        }
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        // Each ending must resolve the original transaction after multiple
        // resizes: explicit commit, no-op completion, cancel, pointer commit.
        for (0..5) |ending| {
            var battery: Battery = .{};
            for ([_]bool{ false, true }) |compiled| {
                const empty = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack }, geometry.RectF.init(0, 0, 400, 300), &nodes);
                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty);
                view.canvas_widget_text_history_next_serial = 1;
                var children: [3]canvas.Widget = undefined;
                for (&children, 0..) |*child, i| child.* = .{
                    .id = @intCast(2 + i),
                    .kind = kind,
                    .frame = geometry.RectF.init(12, 16 + @as(f32, @floatFromInt(i)) * 88, 180, 84),
                    .text = if (i == 0) "Lé🙂R" else "Neighbor",
                    .text_selection = canvas.TextSelection.collapsed(8),
                    .interaction_policy = if (compiled) core.nativeTextPolicy else null,
                };
                const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 400, 300), &nodes);
                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
                battery.compiled = compiled;
                battery.step = 0;
                try battery.edit(view, 4, .{ .insert_text = "123456789012" });
                try battery.edit(view, 2, .{ .set_selection = .{ .anchor = 7, .focus = 1, .affinity = .downstream } });
                try battery.edit(view, 2, .{ .insert_text = "é" });
                try battery.shortcut(harness, app, 2, false);
                try std.testing.expectEqualStrings("Lé🙂R", view.widget_layout_nodes[1].widget.text);
                try battery.edit(view, 3, .{ .insert_text = "old" });
                try battery.shortcut(harness, app, 3, false);
                try battery.edit(view, 2, .{ .set_composition = .{ .text = "x" } });
                // This later entry has to shift on every composition resize.
                try battery.edit(view, 3, .{ .insert_text = "N" });
                for ([_][]const u8{ "日本🙂previewlong", "", "é🙂", "ĩ🙂" }) |preview| {
                    try battery.edit(view, 2, .{ .set_composition = .{ .text = preview, .cursor = 0 } });
                    var saw_provisional = false;
                    for (view.canvas_widget_text_history_entries[0..view.canvas_widget_text_history_entry_count]) |entry| {
                        if (!entry.provisional_composition) continue;
                        saw_provisional = true;
                        try std.testing.expectEqualStrings("é🙂", view.canvas_widget_text_history_bytes[entry.byte_start..][0..entry.removed_len]);
                    }
                    try std.testing.expect(saw_provisional);
                }
                // The oldest widget's edit was evicted to fit the long
                // preview; target Redo and the later neighbor still fit.
                for (view.canvas_widget_text_history_entries[0..view.canvas_widget_text_history_entry_count]) |entry| try std.testing.expect(entry.target_id != 4);
                switch (ending) {
                    0 => try battery.edit(view, 2, .commit_composition),
                    1 => {
                        try battery.edit(view, 2, .{ .set_composition = .{ .text = "é🙂" } });
                        try battery.edit(view, 2, .commit_composition);
                    },
                    2 => try battery.edit(view, 2, .cancel_composition),
                    3 => {
                        _ = try view.applyCanvasWidgetTextPointer(2, .{ .x = 40, .y = 30 }, false, false, 1);
                        try battery.save(view);
                    },
                    else => {
                        // An oversized entry retires only the provisional
                        // transaction; neighboring payloads remain usable.
                        try battery.edit(view, 2, .{ .set_composition = .{ .text = "01234567890123456789012345678901234567890" } });
                        try std.testing.expectEqual(@as(usize, 2), view.canvas_widget_text_history_entry_count);
                        try battery.edit(view, 2, .commit_composition);
                    },
                }
                for (view.canvas_widget_text_history_entries[0..view.canvas_widget_text_history_entry_count]) |entry| try std.testing.expect(!entry.provisional_composition);
                if (ending == 1) {
                    try battery.shortcut(harness, app, 2, true);
                    try std.testing.expectEqualStrings("LéR", view.widget_layout_nodes[1].widget.text);
                } else if (ending != 4) {
                    try battery.shortcut(harness, app, 2, true);
                    try std.testing.expectEqualStrings(if (ending == 2) "LR" else "Lĩ🙂R", view.widget_layout_nodes[1].widget.text);
                    try battery.shortcut(harness, app, 2, false);
                    try std.testing.expectEqualStrings("Lé🙂R", view.widget_layout_nodes[1].widget.text);
                    try std.testing.expectEqual(@as(usize, 7), view.widget_layout_nodes[1].widget.text_selection.?.anchor);
                    try std.testing.expectEqual(@as(usize, 1), view.widget_layout_nodes[1].widget.text_selection.?.focus);
                }
                try battery.shortcut(harness, app, 3, false);
                try std.testing.expectEqualStrings("Neighbor", view.widget_layout_nodes[2].widget.text);
                try battery.shortcut(harness, app, 3, true);
                try std.testing.expectEqualStrings("NeighborN", view.widget_layout_nodes[2].widget.text);
                try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
            }
        }
    }
}

test "compiled history timelines copy full-budget boundary indices before arena reset" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    var entries: [canvas.max_text_history_timeline_entries]canvas.TextHistoryTimelineEntry = @splat(.{});
    entries[20] = .{ .target_matches = true, .kind_matches = true, .after_matches = true };
    entries[60] = .{ .target_matches = true, .kind_matches = true, .applied = false, .before_matches = true };
    entries[90] = .{ .target_matches = true, .kind_matches = true, .applied = false };
    entries[127] = .{ .target_matches = true, .kind_matches = true, .after_matches = true };
    const plan = canvas.widgetCompiledTextHistoryTimeline(widget, &entries).?;
    const bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    _ = canvas.widgetCompiledTextInput(widget, "other\ninput", 0, null, 0);
    const empty = canvas.widgetCompiledTextHistoryTimeline(widget, &.{}).?;
    try std.testing.expectEqualDeep(canvas.TextHistoryTimelineResult{ .matches_state = true, .can_undo = false, .can_redo = false, .undo_index = null, .redo_index = null }, empty);
    try std.testing.expectEqualDeep(canvas.TextHistoryTimelineResult{ .matches_state = true, .can_undo = true, .can_redo = true, .undo_index = 127, .redo_index = 60 }, plan);
    entries[127].after_matches = false;
    const stale = canvas.widgetCompiledTextHistoryTimeline(widget, &entries).?;
    try std.testing.expect(!stale.matches_state and !stale.can_undo and stale.can_redo);
    entries[127].after_matches = true;
    entries[40] = .{ .target_matches = true, .kind_matches = false };
    const wrong_kind = canvas.widgetCompiledTextHistoryTimeline(widget, &entries).?;
    try std.testing.expect(!wrong_kind.matches_state and wrong_kind.can_undo and wrong_kind.can_redo);
    entries[40].kind_matches = true;
    entries[40].provisional = true;
    try std.testing.expect(!canvas.widgetCompiledTextHistoryTimeline(widget, &entries).?.matches_state);
    try std.testing.expect(canvas.widgetCompiledTextHistoryTimeline(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, &entries) == null);
}

test "compiled timeline lookup availability and stale recording match native exact witnesses" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    try harness.start(.{ .context = &context, .name = "compiled-timeline", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") });
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    const view = &harness.runtime.views[0];
    const Entry = @TypeOf(view.canvas_widget_text_history_entries[0]);
    const target_id = std.math.maxInt(canvas.ObjectId) - 17;
    const neighbor_id = target_id ^ (@as(canvas.ObjectId, 1) << 32);
    const hash_a = comptime std.hash.Wyhash.hash(0, "a");
    const hash_b = comptime std.hash.Wyhash.hash(0, "b");
    // Same low halves must never alias through JS numbers: native compares
    // identities and hashes before packing one-byte policy witnesses.
    const alien_hash = hash_b ^ (@as(u64, 1) << 32);
    const Pattern = struct { target: bool = true, kind: bool = true, applied: bool = true, provisional: bool = false, before_hash: u64 = hash_a, after_hash: u64 = hash_b };
    const patterns = [_][]const Pattern{
        &.{},
        &.{.{ .target = false, .kind = false, .provisional = true }},
        &.{ .{}, .{ .applied = false } },
        &.{ .{}, .{ .target = false }, .{ .after_hash = alien_hash }, .{ .applied = false } },
        &.{ .{ .applied = false, .before_hash = alien_hash }, .{ .applied = false } },
        &.{ .{}, .{ .kind = false }, .{ .applied = false } },
        &.{ .{}, .{ .provisional = true }, .{ .applied = false } },
        &.{ .{ .target = false }, .{}, .{ .target = false, .applied = false }, .{ .applied = false }, .{ .applied = false, .before_hash = alien_hash } },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        for (patterns) |pattern| {
            for ([_][]const u8{ "a", "b", "stale" }) |text| {
                for (0..5) |mode| {
                    var expected_availability: @TypeOf(view.canvasWidgetTextHistoryAvailability(target_id)) = .{};
                    var expected_shortcut: ?@TypeOf(view.canvasWidgetTextHistoryShortcut(.{ .id = target_id, .kind = kind, .bounds = .{}, .index = 1, .state = .{} }, .{ .phase = .key_down, .key = "z", .modifiers = .{ .super = true } }).?) = null;
                    var expected_entries: [16]Entry = undefined;
                    var expected_count: usize = 0;
                    var expected_payload: [32]u8 = undefined;
                    var expected_payload_len: usize = 0;
                    // Borrowed replay insert bytes must be copied before the
                    // next variant compacts or overwrites the native pool.
                    var expected_insert: [8]u8 = undefined;
                    for ([_]bool{ false, true }) |compiled| {
                        const empty = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack }, geometry.RectF.init(0, 0, 260, 160), &nodes);
                        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty);
                        const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{.{ .id = target_id, .kind = kind, .frame = geometry.RectF.init(12, 16, 180, 84), .text = text, .text_selection = canvas.TextSelection.collapsed(text.len), .interaction_policy = if (compiled) core.nativeTextPolicy else null }} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
                        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
                        view.canvas_widget_focused_id = target_id;
                        view.canvas_widget_text_history_next_serial = 99;
                        view.canvas_widget_text_history_entry_count = pattern.len;
                        view.canvas_widget_text_history_byte_count = pattern.len * 2;
                        for (pattern, 0..) |p, i| {
                            @memcpy(view.canvas_widget_text_history_bytes[i * 2 ..][0..2], "ab");
                            view.canvas_widget_text_history_entries[i] = .{
                                .serial = std.math.maxInt(u64) - i,
                                .target_id = if (p.target) target_id else neighbor_id,
                                .target_kind = if (p.kind) kind else .button,
                                .byte_start = i * 2,
                                .removed_len = 1,
                                .inserted_len = 1,
                                .before_text_len = 1,
                                .after_text_len = 1,
                                .before_hash = p.before_hash,
                                .after_hash = p.after_hash,
                                .before_selection = canvas.TextSelection.collapsed(1),
                                .after_selection = canvas.TextSelection.collapsed(1),
                                .applied = p.applied,
                                .provisional_composition = p.provisional,
                            };
                        }
                        if (mode == 3) view.widget_layout_nodes[1].widget.state.disabled = true;
                        if (mode == 4) view.widget_layout_nodes[1].widget.text_composition = .{ .start = 0, .end = 1 };
                        const availability = view.canvasWidgetTextHistoryAvailability(target_id);
                        const shortcut = if (mode < 2) view.canvasWidgetTextHistoryShortcut(.{ .id = target_id, .kind = kind, .bounds = .{}, .index = 1, .state = .{} }, .{ .phase = .key_down, .key = "z", .modifiers = .{ .super = true, .shift = mode == 1 } }) else null;
                        if (mode == 2) _ = try view.applyCanvasWidgetTextEdit(target_id, .{ .insert_text = "!" });
                        const count = view.canvas_widget_text_history_entry_count;
                        const payload = view.canvas_widget_text_history_bytes[0..view.canvas_widget_text_history_byte_count];
                        if (!compiled) {
                            expected_availability = availability;
                            expected_shortcut = shortcut;
                            if (expected_shortcut) |*s| if (s.edit == .insert_text) {
                                const inserted = s.edit.insert_text;
                                @memcpy(expected_insert[0..inserted.len], inserted);
                                s.edit.insert_text = expected_insert[0..inserted.len];
                            };
                            expected_count = count;
                            @memcpy(expected_entries[0..count], view.canvas_widget_text_history_entries[0..count]);
                            expected_payload_len = payload.len;
                            @memcpy(expected_payload[0..payload.len], payload);
                        } else {
                            try std.testing.expectEqualDeep(expected_availability, availability);
                            try std.testing.expectEqualDeep(expected_shortcut, shortcut);
                            try std.testing.expectEqual(expected_count, count);
                            try std.testing.expectEqualDeep(expected_entries[0..count], view.canvas_widget_text_history_entries[0..count]);
                            try std.testing.expectEqualSlices(u8, expected_payload[0..expected_payload_len], payload);
                        }
                    }
                }
            }
        }
    }
}

test "compiled history replay matches native shortcut continuation and completion decisions" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const Fixture = struct {
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "compiled-history", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var fixture: Fixture = .{};
    try harness.start(fixture.app());
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{.{ .id = 2, .kind = .textarea, .frame = geometry.RectF.init(12, 16, 180, 84), .text = "az" }} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const view = &harness.runtime.views[0];
    const Pair = struct { removed: []const u8, inserted: []const u8 };
    const pairs = [_]Pair{
        .{ .removed = "", .inserted = "é" },
        .{ .removed = "é", .inserted = "" },
        .{ .removed = "", .inserted = "🙂" },
        .{ .removed = "🙂", .inserted = "" },
        .{ .removed = "", .inserted = "\r\n" },
        .{ .removed = "\r\n", .inserted = "" },
        .{ .removed = "old", .inserted = "日本" },
        .{ .removed = "\x80\x80", .inserted = "\xff" },
        .{ .removed = "", .inserted = "" },
        .{ .removed = "a", .inserted = "b" },
    };
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        const target = canvas.WidgetFocusTarget{ .id = 2, .kind = kind, .bounds = geometry.RectF.init(12, 16, 180, 84), .index = 1, .state = .{} };
        for (pairs) |pair| {
            var before_buffer: [32]u8 = undefined;
            var after_buffer: [32]u8 = undefined;
            const before = try std.fmt.bufPrint(&before_buffer, "a{s}z", .{pair.removed});
            const after = try std.fmt.bufPrint(&after_buffer, "a{s}z", .{pair.inserted});
            const selections = [_]canvas.TextSelection{
                .{ .anchor = 1, .focus = 1 },                                         .{ .anchor = 1 + pair.removed.len, .focus = 1 + pair.removed.len },
                .{ .anchor = 1 + pair.inserted.len, .focus = 1 + pair.inserted.len }, .{ .anchor = 1, .focus = 1 + pair.inserted.len },
                .{ .anchor = 1 + pair.removed.len, .focus = 1 },                      .{ .anchor = 1, .focus = 1, .affinity = .downstream },
            };
            for (selections[0..4], 0..) |before_selection, selection_index| {
                const after_selection = selections[(selection_index + 2) % selections.len];
                for (selections) |current_selection| {
                    for ([_][]const u8{ before, after, "stale" }) |text| {
                        for ([_]bool{ false, true }) |redo| {
                            for (0..3) |mode| {
                                var expected: ?canvas.TextInputEvent = null;
                                var expected_count: usize = 0;
                                var expected_applied = false;
                                for ([_]bool{ false, true }) |compiled| {
                                    view.widget_layout_nodes[1].widget.kind = kind;
                                    view.widget_layout_nodes[1].widget.interaction_policy = if (compiled) core.nativeTextPolicy else null;
                                    view.widget_layout_nodes[1].widget.text = text;
                                    view.widget_layout_nodes[1].widget.text_selection = current_selection;
                                    view.canvas_widget_focused_id = 2;
                                    view.canvas_widget_text_history_entry_count = 1;
                                    view.canvas_widget_text_history_byte_count = pair.removed.len + pair.inserted.len;
                                    @memcpy(view.canvas_widget_text_history_bytes[0..pair.removed.len], pair.removed);
                                    @memcpy(view.canvas_widget_text_history_bytes[pair.removed.len..][0..pair.inserted.len], pair.inserted);
                                    view.canvas_widget_text_history_entries[0] = .{
                                        .serial = std.math.maxInt(u64) - 1,
                                        .target_id = 2,
                                        .target_kind = kind,
                                        .removed_len = pair.removed.len,
                                        .inserted_len = pair.inserted.len,
                                        .prefix_len = 1,
                                        .before_text_len = before.len,
                                        .after_text_len = after.len,
                                        .before_hash = std.hash.Wyhash.hash(0, before),
                                        .after_hash = std.hash.Wyhash.hash(0, after),
                                        .before_selection = before_selection,
                                        .after_selection = after_selection,
                                        .applied = !redo,
                                    };
                                    const serial = view.canvas_widget_text_history_entries[0].serial;
                                    const edit = switch (mode) {
                                        0 => if (view.canvasWidgetTextHistoryShortcut(target, .{ .phase = .key_down, .key = "Z", .modifiers = .{ .super = true, .shift = redo } })) |shortcut| shortcut.edit else null,
                                        1 => view.canvasWidgetTextHistoryReplayNext(target, serial, redo),
                                        else => blk: {
                                            view.commitCanvasWidgetTextHistoryReplayIfComplete(target, serial, redo);
                                            break :blk @as(?canvas.TextInputEvent, null);
                                        },
                                    };
                                    const count = view.canvas_widget_text_history_entry_count;
                                    const applied = if (count == 0) false else view.canvas_widget_text_history_entries[0].applied;
                                    if (!compiled) {
                                        expected = edit;
                                        expected_count = count;
                                        expected_applied = applied;
                                    } else {
                                        try std.testing.expectEqualDeep(expected, edit);
                                        try std.testing.expectEqual(expected_count, count);
                                        try std.testing.expectEqual(expected_applied, applied);
                                        if (edit) |event| if (event == .insert_text and event.insert_text.len > 0) {
                                            const start: usize = if (redo) pair.removed.len else 0;
                                            try std.testing.expectEqual(view.canvas_widget_text_history_bytes[start..].ptr, event.insert_text.ptr);
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "compiled history replay borrows full-budget payloads and copies exact selection results" {
    const h = try Harness.create(null, "/feed.xml");
    defer h.destroy();
    try h.settleBoot();
    const large = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    const widget = canvas.Widget{ .kind = .textarea, .interaction_policy = core.nativeTextPolicy };
    var state = canvas.TextHistoryReplayState{
        .mode = .start,
        .redo = false,
        .before_matches = false,
        .after_matches = true,
        .selection = .{},
        .before_selection = .{},
        .after_selection = .{},
        .prefix = 0,
        .removed = large,
        .inserted = "",
    };
    const borrowed = canvas.widgetCompiledTextHistoryReplay(widget, state).?.edit.insert_text;
    try std.testing.expectEqual(large.ptr, borrowed.ptr);
    state.mode = .next;
    state.before_matches = true;
    state.before_selection = .{ .anchor = std.math.maxInt(usize) - 1, .focus = std.math.maxInt(usize), .affinity = .downstream };
    const selected = canvas.widgetCompiledTextHistoryReplay(widget, state).?.edit.set_selection;
    const bytes = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    _ = canvas.widgetCompiledTextInput(widget, "new\ninput", 0, null, 0);
    try std.testing.expectEqualDeep(state.before_selection, selected);
    try std.testing.expectEqual(large.ptr, borrowed.ptr);
    try std.testing.expectEqualSlices(u8, large, borrowed);
    state.mode = .commit;
    state.selection = state.before_selection;
    try std.testing.expect(canvas.widgetCompiledTextHistoryReplay(widget, state).? == .complete);
    state.selection.affinity = .upstream;
    try std.testing.expect(canvas.widgetCompiledTextHistoryReplay(widget, state).? == .none);
    try std.testing.expect(canvas.widgetCompiledTextHistoryReplay(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, state) == null);
}
