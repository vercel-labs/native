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
    try std.testing.expect(h.harness.runtime.views[0].canvas_widget_tab_focus_policy == core.nativeTabFocusPolicy);
    try std.testing.expect(h.harness.runtime.views[0].canvas_widget_surface_scope_policy == core.nativeSurfaceScopePolicy);
    try std.testing.expect(h.harness.runtime.views[0].canvas_widget_focus_return_policy == core.nativeFocusReturnPolicy);
    try std.testing.expect(h.harness.runtime.views[0].canvas_widget_tooltip_policy == core.nativeTooltipPolicy);

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

test "compiled code indentation matches native votes caret ties eligibility and full source budget" {
    const sources = [_][]const u8{
        "",                             "plain\n  \n\t\n",
        "    café\r\n",
        "   a\n",
        "\t日本\n\tx\n  y",
        "    a\n        b\n    c",      "  a\n    b\n      c",
        "     a\n       b\n         c", "\tx\n  y",
        " \t mixed\n    spaces",        "\r\n  \r\n\t\r\n",
        "  \x80\xff\n",                 "         nine",
    };
    const event = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "TAB" };
    for (sources) |source| {
        for (0..source.len + 2) |caret| {
            const reference = canvas.Widget{ .kind = .textarea, .runtime_flags = .{ .code_editor = true }, .text = source, .text_selection = .{ .anchor = 0, .focus = caret } };
            var compiled = reference;
            compiled.interaction_policy = core.nativeTextPolicy;
            try std.testing.expectEqualDeep(canvas.widgetCodeTabTextEditEvent(reference, event), canvas.widgetCodeTabTextEditEvent(compiled, event));
        }
    }
    // Exhaust every indent width and mixed voting tie at both local line kinds.
    for (1..13) |a| {
        for (1..13) |b| {
            var source: [64]u8 = undefined;
            @memset(source[0..a], ' ');
            source[a] = 'x';
            source[a + 1] = '\n';
            @memset(source[a + 2 .. a + 2 + b], ' ');
            source[a + 2 + b] = 'y';
            source[a + 3 + b] = '\n';
            source[a + 4 + b] = '\t';
            source[a + 5 + b] = 'z';
            for ([_]usize{ 0, a + 2, a + 4 + b, std.math.maxInt(usize) }) |caret| {
                const reference = canvas.Widget{ .kind = .textarea, .runtime_flags = .{ .code_editor = true }, .text = source[0 .. a + b + 6], .text_selection = .{ .focus = caret } };
                var compiled = reference;
                compiled.interaction_policy = core.nativeTextPolicy;
                try std.testing.expectEqualDeep(canvas.widgetCodeTabTextEditEvent(reference, event), canvas.widgetCodeTabTextEditEvent(compiled, event));
            }
        }
    }
    const compiled = canvas.Widget{ .kind = .textarea, .runtime_flags = .{ .code_editor = true }, .text = "    x", .interaction_policy = core.nativeTextPolicy };
    for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up, .text_input }) |phase| {
        for (0..16) |bits| {
            for ([_]bool{ false, true }) |moved| {
                for ([_][]const u8{ "", "\t" }) |text| {
                    const keyboard = canvas.WidgetKeyboardEvent{ .phase = phase, .key = "tab", .text = text, .focus_moved = moved, .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 } };
                    var reference = compiled;
                    reference.interaction_policy = null;
                    try std.testing.expectEqualDeep(canvas.widgetCodeTabTextEditEvent(reference, keyboard), canvas.widgetCodeTabTextEditEvent(compiled, keyboard));
                }
            }
        }
    }
    var disabled = compiled;
    disabled.state.disabled = true;
    try std.testing.expect(canvas.widgetCodeTabTextEditEvent(disabled, event) == null);
    var ordinary = compiled;
    ordinary.runtime_flags.code_editor = false;
    try std.testing.expect(canvas.widgetCodeTabTextEditEvent(ordinary, event) == null);
    ordinary = compiled;
    ordinary.kind = .input;
    try std.testing.expect(canvas.widgetCodeTabTextEditEvent(ordinary, event) == null);
    const large = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    @memset(large[0..8], ' ');
    var full = compiled;
    full.text = large;
    full.text_selection = .{ .focus = std.math.maxInt(usize) };
    const insertion = canvas.widgetCodeTabTextEditEvent(full, event).?.insert_text;
    try std.testing.expectEqualStrings("        ", insertion);
    const view = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    var output: [2]u8 = undefined;
    _ = core.nativeTextPolicy(&.{ 1, 1, 0, 0, 1, 0, 5, 0 }, &output);
    // Returned edits borrow static native bytes, never a reset compiler arena.
    try std.testing.expectEqualStrings("        ", insertion);
}

test "compiled clipboard ranges match native UTF-8 selection and exact huge offsets" {
    const sources = [_][]const u8{ "", "plain", "aé🙂\r\nz", "a\x80\xffb", "\r\n", "日本\nlast" };
    const kinds = [_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea };
    for (kinds) |kind| {
        for (sources) |source| {
            for (0..source.len + 2) |anchor| {
                for (0..source.len + 2) |focus| {
                    const reference = canvas.Widget{ .kind = kind, .text = source, .text_selection = .{ .anchor = anchor, .focus = focus } };
                    var compiled = reference;
                    compiled.interaction_policy = core.nativeTextPolicy;
                    try std.testing.expectEqualDeep(canvas.widgetTextClipboardState(reference), canvas.widgetTextClipboardState(compiled));
                }
            }
            const offsets = [_]usize{ 0, source.len, 4294967295, 4294967296, 9007199254740991, 9007199254740992, std.math.maxInt(usize) };
            for (offsets) |anchor| {
                for (offsets) |focus| {
                    const reference = canvas.Widget{ .kind = kind, .text = source, .text_selection = .{ .anchor = anchor, .focus = focus } };
                    var compiled = reference;
                    compiled.interaction_policy = core.nativeTextPolicy;
                    try std.testing.expectEqualDeep(canvas.widgetTextClipboardState(reference), canvas.widgetTextClipboardState(compiled));
                }
            }
            const reference = canvas.Widget{ .kind = kind, .text = source };
            var compiled = reference;
            compiled.interaction_policy = core.nativeTextPolicy;
            try std.testing.expectEqualDeep(canvas.widgetTextClipboardState(reference), canvas.widgetTextClipboardState(compiled));
        }
    }
    const large = try std.testing.allocator.alloc(u8, canvas.max_widget_text_bytes_per_view);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    @memcpy(large[0..7], "café\r\n");
    const widget = canvas.Widget{ .kind = .textarea, .text = large, .text_selection = .{ .anchor = std.math.maxInt(usize), .focus = 0 }, .interaction_policy = core.nativeTextPolicy };
    const result = canvas.widgetTextClipboardState(widget);
    try std.testing.expectEqualDeep(canvas.TextRange{ .start = 0, .end = large.len }, result.selection.?);
    try std.testing.expect(result.select_all);
    const view = core.nativeView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    var output: [2]u8 = undefined;
    _ = core.nativeTextPolicy(&.{ 1, 1, 0, 0, 1, 0, 5, 0 }, &output);
    try std.testing.expectEqualDeep(canvas.TextRange{ .start = 0, .end = large.len }, result.selection.?);
    // Unsupported kinds never call a text callback; static text keeps its reference path.
    const button = canvas.Widget{ .kind = .button, .text = "x", .text_selection = .{ .anchor = 0, .focus = 1 }, .interaction_policy = core.nativeTextPolicy };
    try std.testing.expect(canvas.widgetTextClipboardState(button).selection == null);
    try std.testing.expectEqualDeep(canvas.TextRange{ .start = 0, .end = 1 }, canvas.widgetTextClipboardState(.{ .kind = .text, .text = "x", .text_selection = .{ .anchor = 1, .focus = 0 } }).selection.?);
}

test "compiled clipboard keyboard and edit menus preserve source bytes eligibility and failed cuts" {
    const source = "aé🙂\r\nz";
    const kinds = [_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea };
    const cases = [_]struct { text: []const u8, selection: ?canvas.TextSelection, expected: ?[]const u8 }{
        .{ .text = source, .selection = .{ .anchor = 7, .focus = 1 }, .expected = "é🙂" },
        .{ .text = source, .selection = .{ .anchor = std.math.maxInt(usize), .focus = 0 }, .expected = source },
        .{ .text = source, .selection = .{ .anchor = 2, .focus = 1 }, .expected = null },
        .{ .text = source, .selection = null, .expected = null },
        .{ .text = "", .selection = .{ .anchor = 0, .focus = 0 }, .expected = null },
    };
    for (kinds) |kind| {
        for ([_]bool{ false, true }) |compiled| {
            for (cases) |case| {
                const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
                defer harness.destroy(std.testing.allocator);
                harness.null_platform.gpu_surfaces = true;
                var context: u8 = 0;
                const app = native_sdk.App{ .context = &context, .name = "compiled-clipboard-menu", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
                try harness.start(app);
                _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
                const field = canvas.Widget{ .id = 2, .kind = kind, .frame = geometry.RectF.init(12, 16, 180, 84), .text = case.text, .interaction_policy = if (compiled) core.nativeTextPolicy else null };
                var nodes: [2]canvas.WidgetLayoutNode = undefined;
                const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{field} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
                _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
                try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 50, .y = 30 } });
                harness.runtime.views[0].widget_layout_nodes[1].widget.text_selection = case.selection;
                try harness.runtime.writeClipboard("sentinel");
                const before_writes = harness.null_platform.clipboardWriteCount();
                try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "c", .modifiers = .{ .primary = true } } });
                var clipboard: [64]u8 = undefined;
                try std.testing.expectEqualStrings(case.expected orelse "sentinel", try harness.runtime.readClipboard(&clipboard));
                try std.testing.expectEqual(before_writes + @intFromBool(case.expected != null), harness.null_platform.clipboardWriteCount());
                try std.testing.expectEqualStrings(case.text, (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
                const right_click = native_sdk.platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .button = 1, .x = 50, .y = 30 } };
                try harness.runtime.dispatchPlatformEvent(app, right_click);
                const menu = harness.null_platform.contextMenuItems();
                try std.testing.expectEqual(@as(usize, 5), menu.len);
                try std.testing.expectEqual(case.expected != null, menu[0].enabled);
                try std.testing.expectEqual(case.expected != null, menu[1].enabled);
                try std.testing.expect(menu[2].enabled and menu[3].separator);
                try std.testing.expectEqual(case.text.len > 0, menu[4].enabled);
                if (case.expected) |wanted| {
                    // Menu Copy shares the compiled selection planner.
                    try harness.runtime.writeClipboard("menu sentinel");
                    try harness.runtime.dispatchPlatformEvent(app, .{ .context_menu_action = .{ .window_id = 1, .view_label = "canvas", .token = harness.null_platform.context_menu_token, .item_id = 2 } });
                    try std.testing.expectEqualStrings(wanted, try harness.runtime.readClipboard(&clipboard));
                    // Both menu and keyboard Cut must refuse a failed platform write.
                    harness.runtime.options.platform.services.write_clipboard_data_fn = null;
                    harness.runtime.options.platform.services.write_clipboard_fn = null;
                    try harness.runtime.dispatchPlatformEvent(app, right_click);
                    try harness.runtime.dispatchPlatformEvent(app, .{ .context_menu_action = .{ .window_id = 1, .view_label = "canvas", .token = harness.null_platform.context_menu_token, .item_id = 1 } });
                    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "x", .modifiers = .{ .primary = true } } });
                    try std.testing.expectEqualStrings(case.text, (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
                    try std.testing.expectEqualStrings(wanted, try harness.runtime.readClipboard(&clipboard));
                    try std.testing.expectEqual(@as(usize, 0), harness.runtime.views[0].canvas_widget_text_history_entry_count);
                }
                harness.runtime.views[0].widget_layout_nodes[1].widget.state.disabled = true;
                const requests = harness.null_platform.context_menu_request_count;
                try harness.runtime.dispatchPlatformEvent(app, right_click);
                try std.testing.expectEqual(requests, harness.null_platform.context_menu_request_count);
                try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "x", .modifiers = .{ .primary = true } } });
                try std.testing.expectEqualStrings(case.text, (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
                try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
            }
        }
    }
}

test "compiled editor shortcut chords match native phases modifiers and folded primary keys" {
    const kinds = [_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea };
    const keys = [_][]const u8{ "", "c", "C", "x", "X", "v", "V", "z", "Z", "y", "Y", "enter", "copy" };
    for (kinds) |kind| {
        const reference = canvas.Widget{ .kind = kind };
        const compiled = canvas.Widget{ .kind = kind, .interaction_policy = core.nativeTextPolicy };
        for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up, .text_input }) |phase| {
            for (0..16) |bits| {
                for (keys) |key| {
                    const event = canvas.WidgetKeyboardEvent{ .phase = phase, .key = key, .text = "c", .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 } };
                    try std.testing.expectEqual(canvas.widgetKeyboardClipboardAction(event), canvas.widgetKeyboardClipboardActionForWidget(compiled, event));
                    try std.testing.expectEqual(canvas.widgetKeyboardTextHistoryAction(reference, event), canvas.widgetKeyboardTextHistoryAction(compiled, event));
                }
            }
        }
    }
    const Never = struct {
        fn policy(_: []const u8, _: []u8) usize {
            @panic("unsupported widget called editor shortcut policy");
        }
    };
    for ([_]canvas.WidgetKind{ .text, .button, .terminal }) |kind| {
        const unsupported = canvas.Widget{ .kind = kind, .interaction_policy = Never.policy };
        const copy = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "C", .modifiers = .{ .super = true } };
        try std.testing.expectEqual(canvas.WidgetClipboardAction.copy, canvas.widgetKeyboardClipboardActionForWidget(unsupported, copy).?);
        const redo = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "Z", .modifiers = .{ .super = true, .shift = true } };
        try std.testing.expectEqual(canvas.WidgetTextHistoryAction.redo, canvas.widgetKeyboardTextHistoryAction(unsupported, redo).?);
    }
}

test "runtime clipboard and history routing consult the focused compiled editor policy" {
    const Spy = struct {
        var clipboard_calls: usize = 0;
        var history_calls: usize = 0;
        var suppress: bool = true;
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 13) {
                if (request[1] == 0) clipboard_calls += 1 else history_calls += 1;
                if (suppress) {
                    output[0] = 0;
                    return 1;
                }
            }
            return core.nativeTextPolicy(request, output);
        }
    };
    Spy.clipboard_calls = 0;
    Spy.history_calls = 0;
    Spy.suppress = true;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-shortcut-routing", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    const field = canvas.Widget{ .id = 2, .kind = .textarea, .frame = geometry.RectF.init(12, 16, 180, 84), .text = "aé", .interaction_policy = Spy.policy };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{field} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .x = 50, .y = 30 } });
    harness.runtime.views[0].widget_layout_nodes[1].widget.text_selection = .{ .anchor = 0, .focus = 3 };
    try harness.runtime.writeClipboard("sentinel");
    const writes = harness.null_platform.clipboardWriteCount();
    const copy = native_sdk.platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "C", .modifiers = .{ .primary = true } } };
    try harness.runtime.dispatchPlatformEvent(app, copy);
    try std.testing.expectEqual(writes, harness.null_platform.clipboardWriteCount());
    try std.testing.expectEqual(@as(usize, 1), Spy.clipboard_calls);
    Spy.suppress = false;
    try harness.runtime.dispatchPlatformEvent(app, copy);
    var clipboard: [32]u8 = undefined;
    try std.testing.expectEqualStrings("aé", try harness.runtime.readClipboard(&clipboard));
    // Paste creates real native history, then suppressing the planner's chord
    // proves Undo/Redo do not bypass the compiled recognition result.
    try harness.runtime.writeClipboard("🙂");
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "v", .modifiers = .{ .primary = true } } });
    try std.testing.expectEqualStrings("🙂", (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
    const undo = native_sdk.platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "z", .modifiers = .{ .primary = true } } };
    Spy.suppress = true;
    const before_history = Spy.history_calls;
    try harness.runtime.dispatchPlatformEvent(app, undo);
    try std.testing.expect(Spy.history_calls > before_history);
    try std.testing.expectEqualStrings("🙂", (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
    Spy.suppress = false;
    try harness.runtime.dispatchPlatformEvent(app, undo);
    try std.testing.expectEqualStrings("aé", (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "Z", .modifiers = .{ .primary = true, .shift = true } } });
    try std.testing.expectEqualStrings("🙂", (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.text);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

test "compiled editor boundary policy matches native runtime phases and state" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-editor-boundaries", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{.{ .id = 2, .kind = .input, .frame = geometry.RectF.init(12, 16, 180, 84), .text = "aé🙂z" }} }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const view = &harness.runtime.views[0];
    const keys = [_][]const u8{ "", "escape", "ESC", "Escape", "ArrowUp", "arrowdown", "enter" };
    const compositions = [_]?canvas.TextRange{ null, .{ .start = 3, .end = 3 }, .{ .start = 1, .end = 3 } };
    for ([_]canvas.WidgetKind{ .input, .text_field, .search_field, .combobox, .textarea }) |kind| {
        for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up, .text_input }) |phase| {
            for (0..16) |bits| {
                for (keys) |key| {
                    for ([_][]const u8{ "", "日本" }) |payload| {
                        for (compositions) |composition| {
                            for ([_]?bool{ null, false, true }) |expanded| {
                                const event = canvas.WidgetKeyboardEvent{ .phase = phase, .key = key, .text = payload, .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 } };
                                var widget = view.widget_layout_nodes[1].widget;
                                widget.kind = kind;
                                widget.text_selection = .{ .anchor = 7, .focus = 3 };
                                widget.text_composition = composition;
                                widget.state.expanded = expanded;
                                widget.interaction_policy = null;
                                view.widget_layout_nodes[1].widget = widget;
                                const target = canvas.WidgetFocusTarget{ .id = 2, .kind = kind, .bounds = widget.frame, .index = 1, .state = widget.state };
                                const expected_intent = canvas.widgetKeyboardTextBoundaryIntent(widget, event);
                                const expected_edit = view.canvasWidgetKeyboardTextEdit(target, event);
                                widget.interaction_policy = core.nativeTextPolicy;
                                view.widget_layout_nodes[1].widget = widget;
                                try std.testing.expectEqualDeep(expected_intent, canvas.widgetKeyboardTextBoundaryIntent(widget, event));
                                try std.testing.expectEqualDeep(expected_edit, view.canvasWidgetKeyboardTextEdit(target, event));
                            }
                        }
                    }
                }
            }
        }
    }
    const Never = struct {
        fn policy(_: []const u8, _: []u8) usize {
            @panic("ineligible editor called boundary policy");
        }
    };
    const escape = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "escape" };
    for ([_]canvas.WidgetKind{ .text, .button, .terminal }) |kind| {
        try std.testing.expectEqualDeep(canvas.WidgetTextBoundaryIntent.fallback, canvas.widgetKeyboardTextBoundaryIntent(.{ .kind = kind, .interaction_policy = Never.policy }, escape));
    }
    view.widget_layout_nodes[1].widget.kind = .search_field;
    view.widget_layout_nodes[1].widget.state.disabled = true;
    view.widget_layout_nodes[1].widget.interaction_policy = Never.policy;
    try std.testing.expectEqual(@as(?canvas.TextInputEvent, null), view.canvasWidgetKeyboardTextEdit(.{ .id = 2, .kind = .search_field, .bounds = .{}, .index = 1, .state = .{} }, escape));
    try std.testing.expectEqual(@as(?canvas.TextInputEvent, null), view.canvasWidgetKeyboardTextEdit(.{ .id = 999, .kind = .input, .bounds = .{}, .index = 1, .state = .{} }, escape));
}

test "runtime stamps compiled Escape and single line navigation before retained edits" {
    const Spy = struct {
        var calls: usize = 0;
        var suppress = true;
        var last_edit: ?canvas.TextInputEvent = null;
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, value: native_sdk.Event) anyerror!void {
            if (value == .canvas_widget_keyboard) last_edit = value.canvas_widget_keyboard.keyboard.edit;
        }
        fn key(harness: anytype, app: native_sdk.App, name: []const u8, text: []const u8, shift: bool) !void {
            last_edit = null;
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = name, .text = text, .modifiers = .{ .shift = shift } } });
        }
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 14) {
                calls += 1;
                if (suppress) {
                    output[0] = 1;
                    output[1] = 0;
                    return 2;
                }
            }
            return core.nativeTextPolicy(request, output);
        }
    };
    Spy.calls = 0;
    Spy.suppress = true;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-boundary-routing", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"), .event_fn = Spy.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 260, 160) });
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{ .{ .id = 2, .kind = .search_field, .frame = geometry.RectF.init(12, 16, 180, 36), .text = "aé🙂z", .interaction_policy = Spy.policy }, .{ .id = 3, .kind = .input, .frame = geometry.RectF.init(12, 60, 180, 36), .text = "Neighbor", .interaction_policy = Spy.policy } } }, geometry.RectF.init(0, 0, 260, 160), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const view = &harness.runtime.views[0];
    view.canvas_widget_focused_id = 2;
    try Spy.key(harness, app, "escape", "", false);
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    try std.testing.expect(Spy.last_edit == null);
    try std.testing.expectEqualStrings("aé🙂z", view.widget_layout_nodes[1].widget.text);
    Spy.suppress = false;
    _ = try view.applyCanvasWidgetTextEdit(2, .{ .set_selection = .{ .anchor = 7, .focus = 3 } });
    try Spy.key(harness, app, "arrowup", "", true);
    try std.testing.expectEqualDeep(canvas.TextInputEvent{ .move_caret = .{ .direction = .start, .extend = true } }, Spy.last_edit.?);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 7, .focus = 0 }, view.widget_layout_nodes[1].widget.text_selection.?);
    _ = try view.applyCanvasWidgetTextEdit(2, .{ .set_selection = .{ .anchor = 3, .focus = 3 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_set_composition, .text = "日本" } });
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), view.canvas_widget_ime_owner_id);
    try Spy.key(harness, app, "ESC", "", false);
    try std.testing.expectEqualDeep(canvas.TextInputEvent.cancel_composition, Spy.last_edit.?);
    try std.testing.expectEqualStrings("aé🙂z", view.widget_layout_nodes[1].widget.text);
    try std.testing.expect(view.widget_layout_nodes[1].widget.text_composition == null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvas_widget_ime_owner_id);
    try std.testing.expect(view.canvas_widget_ime_commit_grace == .none);
    view.canvas_widget_focused_id = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .text_input, .text = "!" } });
    try std.testing.expectEqualStrings("Neighbor!", view.widget_layout_nodes[2].widget.text);
    try std.testing.expectEqualStrings("aé🙂z", view.widget_layout_nodes[1].widget.text);
    view.canvas_widget_focused_id = 2;
    try Spy.key(harness, app, "ESC", "", false);
    try std.testing.expectEqualDeep(canvas.TextInputEvent.clear, Spy.last_edit.?);
    try std.testing.expectEqualStrings("", view.widget_layout_nodes[1].widget.text);
    try Spy.key(harness, app, "ESC", "", false);
    try std.testing.expectEqualDeep(canvas.TextInputEvent.clear, Spy.last_edit.?);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

test "compiled combobox boundaries preserve opening and mounted menu focus precedence" {
    const Fixture = struct {
        var calls: usize = 0;
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 14) calls += 1;
            return core.nativeTextPolicy(request, output);
        }
    };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var context: u8 = 0;
        const app = native_sdk.App{ .context = &context, .name = "compiled-combo-boundaries", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>") };
        try harness.start(app);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 200) });
        const view = &harness.runtime.views[0];
        for (0..3) |mode| {
            const fields = [_]canvas.Widget{
                .{ .id = 2, .kind = .combobox, .frame = geometry.RectF.init(0, 0, 180, 36), .text = "aé🙂z", .text_selection = canvas.TextSelection.collapsed(3), .state = .{ .expanded = mode != 0 }, .command = "choose", .interaction_policy = if (compiled) Fixture.policy else null },
                .{ .id = 3, .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 180, 50), .layout = .{ .anchor = .{ .placement = .below } }, .children = if (mode == 2) &.{.{ .id = 4, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 160, 30), .text = "Choice", .command = "choose" }} else &.{} },
            };
            var nodes: [4]canvas.WidgetLayoutNode = undefined;
            _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .frame = geometry.RectF.init(12, 16, 180, 36), .children = fields[0..if (mode == 0) @as(usize, 1) else 2] }, geometry.RectF.init(0, 0, 300, 200), &nodes));
            view.canvas_widget_focused_id = 2;
            _ = try view.applyCanvasWidgetTextEdit(2, .{ .set_selection = canvas.TextSelection.collapsed(3) });
            Fixture.calls = 0;
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
            const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
            try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(if (mode == 1) 8 else 3), retained.findById(2).?.widget.text_selection.?);
            try std.testing.expectEqual(@as(canvas.ObjectId, if (mode == 2) 4 else 2), view.canvas_widget_focused_id);
            if (compiled) try std.testing.expectEqual(@as(usize, if (mode == 2) 0 else 1), Fixture.calls);
            if (mode == 0) try std.testing.expectEqual(canvas.WidgetControlIntentKind.press, canvas.widgetKeyboardControlIntent(retained.findById(2).?.widget, .{ .phase = .key_down, .key = "arrowdown" }).?.kind);
        }
        try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
    }
}

test "compiled keyboard controls match native kind role and stamped focus precedence" {
    const policies = [_]*const fn ([]const u8, []u8) usize{
        core.nativeTextPolicy,   core.nativeRadioPolicy,     core.nativeTabsPolicy,
        core.nativeTreePolicy,   core.nativeListPolicy,      core.nativeMenuPolicy,
        core.nativeTogglePolicy, core.nativeAccordionPolicy, core.nativeSliderPolicy,
        core.nativeSplitPolicy,  core.nativeResizablePolicy, core.nativeScrollPolicy,
    };
    const keys = [_][]const u8{ "", "Enter", "SPACE", "return", "esc", "ArrowUp", "arrowdown", "arrowleft", "ArrowRight", "Home", "END", "tab" };
    // All kind declarations catch composed-control fallback and exclusions.
    for (std.enums.values(canvas.WidgetKind)) |kind| {
        for (0..128) |flags| {
            for ([_]?bool{ null, false, true }) |expanded| {
                for (keys) |key| {
                    var widget = canvas.Widget{ .kind = kind, .value = 0.5 };
                    widget.semantics.role = if (flags & 1 != 0) .treeitem else .none;
                    widget.command = if (flags & 8 != 0) "activate" else "";
                    widget.semantics.focusable = flags & 16 != 0;
                    widget.semantics.actions.press = flags & 32 != 0;
                    widget.layout.virtualized = flags & 64 != 0;
                    widget.state.expanded = expanded;
                    const event = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = key, .focus_moved = flags & 2 != 0, .radio_group_selection = flags & 4 != 0, .modifiers = .{ .shift = true } };
                    const expected = canvas.widgetKeyboardControlIntent(widget, event);
                    // Shared activation and complete step planning both work
                    // through every specialized callback.
                    widget.interaction_policy = policies[(flags + @intFromEnum(kind)) % policies.len];
                    try std.testing.expectEqualDeep(expected, canvas.widgetKeyboardControlIntent(widget, event));
                }
            }
        }
    }
    const Never = struct {
        fn policy(_: []const u8, _: []u8) usize {
            @panic("ineligible keyboard control called compiled policy");
        }
    };
    for ([_]canvas.WidgetKeyboardPhase{ .key_down, .key_up, .text_input }) |phase| {
        for (0..16) |bits| {
            for ([_]bool{ false, true }) |disabled| {
                if (phase == .key_down and bits & 14 == 0 and !disabled) continue;
                const event = canvas.WidgetKeyboardEvent{ .phase = phase, .key = "enter", .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 } };
                try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetKeyboardControlIntent(.{ .kind = .button, .state = .{ .disabled = disabled }, .interaction_policy = Never.policy }, event));
            }
        }
    }
    // Control results remain values after view and other policy arena resets.
    const retained = canvas.widgetKeyboardControlIntent(.{ .kind = .button, .interaction_policy = core.nativeTextPolicy }, .{ .phase = .key_down, .key = "space" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = core.initialModel();
    _ = core.nativeView(arena.allocator());
    var output: [2]u8 = undefined;
    _ = core.nativeTreePolicy(&.{ 15, 0, 6, 1, 1 }, &output);
    try std.testing.expectEqualDeep(@as(?canvas.WidgetControlIntent, .{ .kind = .press, .actions = .{ .press = true } }), retained);
}

test "runtime grants stamped radio navigation and toggle activation to compiled controls" {
    const Spy = struct {
        var calls: usize = 0;
        var suppress = true;
        var radio_stamp = false;
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, value: native_sdk.Event) anyerror!void {
            if (value == .canvas_widget_keyboard) radio_stamp = value.canvas_widget_keyboard.keyboard.radio_group_selection;
        }
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 15) {
                calls += 1;
                if (suppress) {
                    output[0] = 0;
                    output[1] = 0;
                    return 2;
                }
            }
            return core.nativeTogglePolicy(request, output);
        }
    };
    Spy.calls = 0;
    Spy.suppress = true;
    Spy.radio_stamp = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-keyboard-controls", .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"), .event_fn = Spy.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 300, 200) });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{
        .{ .id = 2, .kind = .checkbox, .frame = geometry.RectF.init(12, 12, 180, 36), .interaction_policy = Spy.policy },
        .{ .id = 3, .kind = .radio_group, .frame = geometry.RectF.init(12, 60, 200, 100), .interaction_policy = core.nativeRadioPolicy, .children = &.{
            .{ .id = 4, .kind = .radio, .frame = geometry.RectF.init(0, 0, 180, 36), .interaction_policy = core.nativeRadioPolicy, .state = .{ .selected = true }, .value = 1 },
            .{ .id = 5, .kind = .radio, .frame = geometry.RectF.init(0, 45, 180, 36), .interaction_policy = core.nativeRadioPolicy },
        } },
    } }, geometry.RectF.init(0, 0, 300, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const view = &harness.runtime.views[0];
    view.canvas_widget_focused_id = 2;
    const activation = native_sdk.platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "space", .modifiers = .{ .shift = true } } };
    try harness.runtime.dispatchPlatformEvent(app, activation);
    try std.testing.expect(Spy.calls > 0);
    try std.testing.expect(!(try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.state.selected);
    Spy.suppress = false;
    try harness.runtime.dispatchPlatformEvent(app, activation);
    try std.testing.expect((try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.state.selected);
    view.canvas_widget_focused_id = 4;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "arrowdown" } });
    try std.testing.expect(Spy.radio_stamp);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), view.canvas_widget_focused_id);
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.findById(4).?.widget.state.selected);
    try std.testing.expect(retained.findById(5).?.widget.state.selected);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

test "compiled semantic controls match native grants kind and tree role precedence" {
    const policies = [_]*const fn ([]const u8, []u8) usize{
        core.nativeTextPolicy,   core.nativeRadioPolicy,     core.nativeTabsPolicy,
        core.nativeTreePolicy,   core.nativeListPolicy,      core.nativeMenuPolicy,
        core.nativeTogglePolicy, core.nativeAccordionPolicy, core.nativeSliderPolicy,
        core.nativeSplitPolicy,  core.nativeResizablePolicy, core.nativeScrollPolicy,
    };
    for (std.enums.values(canvas.WidgetKind)) |kind| {
        for ([_]bool{ false, true }) |tree_row| {
            for (0..32) |bits| {
                const actions = canvas.WidgetActions{ .press = bits & 1 != 0, .toggle = bits & 2 != 0, .select = bits & 4 != 0, .increment = bits & 8 != 0, .decrement = bits & 16 != 0, .focus = true, .dismiss = true };
                for (std.enums.values(canvas.WidgetSemanticAction)) |action| {
                    for ([_]bool{ false, true }) |command| {
                        var widget = canvas.Widget{ .kind = kind, .value = 0.5, .frame = geometry.RectF.init(0, 0, 160, 100), .command = if (command) "activate" else "", .semantics = .{ .role = if (tree_row) .treeitem else .none } };
                        const expected = canvas.widgetSemanticControlIntentWithActions(widget, action, actions);
                        const defaults = canvas.widgetSemanticControlIntent(widget, action);
                        widget.interaction_policy = policies[(bits + @intFromEnum(kind)) % policies.len];
                        try std.testing.expectEqualDeep(expected, canvas.widgetSemanticControlIntentWithActions(widget, action, actions));
                        try std.testing.expectEqualDeep(defaults, canvas.widgetSemanticControlIntent(widget, action));
                    }
                }
            }
        }
    }
    const Never = struct {
        fn policy(_: []const u8, _: []u8) usize {
            @panic("ineligible semantic control called compiled policy");
        }
    };
    for (std.enums.values(canvas.WidgetSemanticAction)) |action| {
        for ([_]bool{ false, true }) |disabled| {
            for ([_]bool{ false, true }) |hidden| {
                if (!disabled and !hidden) continue;
                try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetSemanticControlIntentWithActions(.{ .kind = .button, .state = .{ .disabled = disabled }, .semantics = .{ .hidden = hidden }, .interaction_policy = Never.policy }, action, .{ .press = true, .toggle = true, .select = true, .increment = true, .decrement = true }));
            }
        }
    }
    const retained = canvas.widgetSemanticControlIntent(.{ .kind = .menu_item, .interaction_policy = core.nativeMenuPolicy }, .press);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = core.initialModel();
    _ = core.nativeView(arena.allocator());
    var output: [2]u8 = undefined;
    _ = core.nativeTreePolicy(&.{ 16, 1, 0, 5, 1 }, &output);
    try std.testing.expectEqualDeep(@as(?canvas.WidgetControlIntent, .{ .kind = .select, .actions = .{ .press = true, .select = true } }), retained);
}

test "compiled semantic policy owns pointer handler choice and preserves radio change delivery" {
    const Msg = union(enum) { press, toggle, change };
    const Ui = canvas.Ui(Msg);
    const Spy = struct {
        var calls: usize = 0;
        var suppress = false;
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 16) {
                calls += 1;
                if (suppress) {
                    output[0] = 0;
                    output[1] = 0;
                    return 2;
                }
            }
            return core.nativeTextPolicy(request, output);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    var button = ui.button(.{ .on_press = .press }, "Run");
    button.widget.interaction_policy = Spy.policy;
    var check = ui.el(.checkbox, .{ .text = "Option", .on_toggle = .toggle }, .{});
    check.widget.interaction_policy = Spy.policy;
    var radio = ui.el(.radio, .{ .text = "Choice", .on_press = .press, .on_toggle = .toggle, .on_change = .change }, .{});
    radio.widget.interaction_policy = Spy.policy;
    var row = ui.button(.{ .on_press = .press, .on_toggle = .toggle, .semantics = .{ .role = .treeitem } }, "Row");
    row.widget.interaction_policy = Spy.policy;
    const tree = try ui.finalize(ui.column(.{}, .{ button, check, radio, row }));
    const button_id = tree.root.children[0].id;
    const check_id = tree.root.children[1].id;
    const radio_id = tree.root.children[2].id;
    const row_id = tree.root.children[3].id;
    Spy.calls = 0;
    Spy.suppress = true;
    for ([_]canvas.ObjectId{ button_id, check_id, radio_id, row_id }) |id| {
        try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(id, .up));
    }
    try std.testing.expect(Spy.calls > 0);
    Spy.calls = 0;
    Spy.suppress = false;
    try std.testing.expectEqualDeep(@as(?Msg, .press), tree.msgForPointer(button_id, .up));
    try std.testing.expectEqualDeep(@as(?Msg, .toggle), tree.msgForPointer(check_id, .up));
    try std.testing.expectEqualDeep(@as(?Msg, .press), tree.msgForPointer(row_id, .up));
    try std.testing.expectEqualDeep(@as(?Msg, .change), tree.msgForPointerEvent(radio_id, .{ .phase = .up, .point = .{}, .radio_selection_changed = true }));
    try std.testing.expectEqualDeep(@as(?Msg, .toggle), tree.msgForPointerEvent(radio_id, .{ .phase = .up, .point = .{}, .radio_selection_changed = false }));
    const before = Spy.calls;
    try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(button_id, .down));
    try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(999999, .up));
    try std.testing.expectEqual(before, Spy.calls);
}

test "compiled semantic derivation matches every kind flag and authored action mask" {
    const policies = [_]*const fn ([]const u8, []u8) usize{
        core.nativeTextPolicy,   core.nativeRadioPolicy,     core.nativeTabsPolicy,
        core.nativeTreePolicy,   core.nativeListPolicy,      core.nativeMenuPolicy,
        core.nativeTogglePolicy, core.nativeAccordionPolicy, core.nativeSliderPolicy,
        core.nativeSplitPolicy,  core.nativeResizablePolicy, core.nativeScrollPolicy,
    };
    for (std.enums.values(canvas.WidgetKind)) |kind| {
        for (0..32) |flags| {
            var reference = canvas.Widget{
                .id = 1,
                .kind = kind,
                .state = .{ .disabled = flags & 1 != 0, .read_only = flags & 2 != 0 },
                .semantics = .{ .role = if (flags & 4 != 0) .treeitem else .none, .focusable = flags & 8 != 0 },
                .command = if (flags & 16 != 0) "activate" else "",
            };
            var compiled = reference;
            compiled.interaction_policy = policies[(flags + canvas.widgetKindCode(kind)) % policies.len];
            // With authored actions empty and read-only off, the reference's
            // merged actions expose its defaults. Inspect the copied wire
            // defaults separately because read-only only masks the merged set.
            var default_reference = reference;
            default_reference.state.read_only = false;
            const defaults = canvas.semanticActions(default_reference);
            var expected_bits: u16 = 0;
            inline for (@typeInfo(canvas.WidgetActions).@"struct".fields, 0..) |field, bit| {
                if (@field(defaults, field.name)) expected_bits |= @as(u16, 1) << bit;
            }
            var output: [5]u8 = undefined;
            _ = compiled.interaction_policy.?(&.{ 17, @intCast(canvas.widgetKindCode(kind)), 0, @intCast(flags), 0, 0 }, &output);
            try std.testing.expectEqual(expected_bits, std.mem.readInt(u16, output[2..4], .little));
            default_reference.semantics.focusable = false;
            try std.testing.expectEqual(canvas.widgetIsFocusable(default_reference), output[4] == 1);
            try std.testing.expectEqual(canvas.widgetIsFocusable(reference), canvas.widgetIsFocusable(compiled));
            for (0..2048) |mask| {
                const actions = canvas.WidgetActions{
                    .focus = mask & 1 != 0,
                    .press = mask & 2 != 0,
                    .toggle = mask & 4 != 0,
                    .increment = mask & 8 != 0,
                    .decrement = mask & 16 != 0,
                    .set_text = mask & 32 != 0,
                    .set_selection = mask & 64 != 0,
                    .select = mask & 128 != 0,
                    .drag = mask & 256 != 0,
                    .drop_files = mask & 512 != 0,
                    .dismiss = mask & 1024 != 0,
                };
                reference.semantics.actions = actions;
                compiled.semantics.actions = actions;
                compiled.interaction_policy = policies[(mask + flags + canvas.widgetKindCode(kind)) % policies.len];
                try std.testing.expectEqualDeep(canvas.semanticActions(reference), canvas.semanticActions(compiled));
            }
        }
        // Other roles carry no tree-specific defaults, even on composed rows.
        for (std.enums.values(canvas.WidgetRole)) |role| {
            const reference = canvas.Widget{ .kind = kind, .semantics = .{ .role = role } };
            var compiled = reference;
            compiled.interaction_policy = core.nativeTextPolicy;
            try std.testing.expectEqualDeep(canvas.semanticActions(reference), canvas.semanticActions(compiled));
        }
    }
    const Never = struct {
        fn policy(_: []const u8, _: []u8) usize {
            @panic("disabled semantic derivation called compiled policy");
        }
    };
    const disabled = canvas.Widget{ .kind = .button, .state = .{ .disabled = true }, .interaction_policy = Never.policy };
    try std.testing.expect(canvas.semanticActions(disabled).isEmpty());
    try std.testing.expect(!canvas.widgetIsFocusable(disabled));

    const retained = canvas.semanticActions(.{ .kind = .combobox, .state = .{ .read_only = true }, .interaction_policy = core.nativeTextPolicy });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = core.initialModel();
    _ = core.nativeView(arena.allocator());
    var output: [5]u8 = undefined;
    _ = core.nativeScrollPolicy(&.{ 17, 58, 0, 0, 0, 0 }, &output);
    try std.testing.expectEqualDeep(canvas.WidgetActions{ .focus = true, .press = true, .set_selection = true }, retained);
}

test "compiled semantic derivation drives accessibility focus drag and pointer consumers" {
    const Msg = union(enum) { press, toggle };
    const Ui = canvas.Ui(Msg);
    const Spy = struct {
        var calls: usize = 0;
        var suppress = false;
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 17) {
                calls += 1;
                if (suppress) {
                    @memset(output[0..5], 0);
                    return 5;
                }
            }
            return core.nativeTextPolicy(request, output);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    var button = ui.button(.{ .on_press = .press }, "Run");
    button.widget.interaction_policy = Spy.policy;
    const tree = try ui.finalize(ui.column(.{}, .{button}));
    const id = tree.root.children[0].id;
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 300, 200), &nodes);
    var records: [2]canvas.WidgetSemanticsNode = undefined;
    Spy.calls = 0;
    Spy.suppress = true;
    const suppressed = try layout.collectSemantics(&records);
    const button_index = for (suppressed, 0..) |record, index| {
        if (record.id == id) break index;
    } else return error.ExpectedButtonSemantics;
    try std.testing.expect(suppressed[button_index].actions.isEmpty());
    try std.testing.expect(!suppressed[button_index].focusable);
    try std.testing.expect(!canvas.widgetIsFocusable(layout.findById(id).?.widget));
    try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(id, .up));
    var drag_nodes: [1]canvas.WidgetLayoutNode = undefined;
    const drag_layout = try canvas.layoutWidgetTree(.{ .id = 3, .kind = .resizable, .interaction_policy = Spy.policy }, geometry.RectF.init(0, 0, 200, 100), &drag_nodes);
    var route_entries: [3]canvas.WidgetEventRouteEntry = undefined;
    try std.testing.expect((try drag_layout.routeDragEvent(.{ .source_id = 3, .point = .{} }, &route_entries)).target == null);
    try std.testing.expect(Spy.calls > 0);
    Spy.suppress = false;
    const enabled = try layout.collectSemantics(&records);
    try std.testing.expectEqual(id, enabled[button_index].id);
    try std.testing.expect(enabled[button_index].actions.press);
    try std.testing.expect(enabled[button_index].focusable);
    try std.testing.expect(canvas.widgetIsFocusable(layout.findById(id).?.widget));
    try std.testing.expectEqualDeep(@as(?Msg, .press), tree.msgForPointer(id, .up));
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), (try drag_layout.routeDragEvent(.{ .source_id = 3, .point = .{} }, &route_entries)).target.?.id);
}

test "shared step planning preserves complete f32 intents and public scroll helper behavior" {
    const policies = [_]*const fn ([]const u8, []u8) usize{
        core.nativeTextPolicy,   core.nativeRadioPolicy, core.nativeTabsPolicy,      core.nativeTreePolicy,
        core.nativeListPolicy,   core.nativeMenuPolicy,  core.nativeTogglePolicy,    core.nativeAccordionPolicy,
        core.nativeSliderPolicy, core.nativeSplitPolicy, core.nativeResizablePolicy, core.nativeScrollPolicy,
    };
    for ([_]canvas.WidgetKind{ .slider, .split_divider, .grid, .scroll_view, .list, .data_grid, .table, .stack }) |kind| {
        for ([_]f32{ -0.1, 0, 0.00001, 0.3, 0.4999, 0.95, 1, 1.2 }) |value| {
            for ([_]canvas.ScrollAxes{ .vertical, .horizontal, .both }) |axes| for ([_]bool{ false, true }) |virtualized| {
                for ([_]geometry.SizeF{ .{}, .{ .width = 333.3, .height = 155.5 }, .{ .width = 1, .height = 1 } }) |size| {
                    const children = [_]canvas.Widget{.{ .kind = .stack, .frame = geometry.RectF.init(0, 0, 900, 0.1) }};
                    const reference = canvas.Widget{ .kind = kind, .value = value, .scroll_axes = axes, .layout = .{ .virtualized = virtualized, .padding = geometry.InsetsF.all(0.25) }, .frame = geometry.RectF.init(0, 0, size.width, size.height), .children = &children };
                    var compiled = reference;
                    for ([_][]const u8{ "ArrowLeft", "ARROWRIGHT", "arrowup", "arrowdown", "Home", "end", "pageup", "PageDown", "space", "return", "" }, 0..) |key, key_index| {
                        for ([_]bool{ false, true }) |shift| {
                            compiled.interaction_policy = policies[(key_index + @intFromEnum(kind)) % policies.len];
                            const event = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = key, .modifiers = .{ .shift = shift } };
                            try std.testing.expectEqualDeep(canvas.widgetKeyboardControlIntent(reference, event), canvas.widgetKeyboardControlIntent(compiled, event));
                            try std.testing.expectEqualDeep(canvas.widgetScrollKeyboardIntent(reference, event), canvas.widgetScrollKeyboardIntent(compiled, event));
                            try std.testing.expectEqualDeep(canvas.widgetScrollKeyboardDelta(reference, event), canvas.widgetScrollKeyboardDelta(compiled, event));
                        }
                    }
                    for ([_]canvas.WidgetSemanticAction{ .increment, .decrement }) |action| {
                        for (policies) |policy| {
                            compiled.interaction_policy = policy;
                            try std.testing.expectEqualDeep(canvas.widgetSemanticControlIntentWithActions(reference, action, .{ .increment = true, .decrement = true }), canvas.widgetSemanticControlIntentWithActions(compiled, action, .{ .increment = true, .decrement = true }));
                        }
                    }
                }
            };
        }
    }
    // Public delta helpers historically ignore disabled state; intent helpers
    // suppress it. Arena resets must not change a previously returned intent.
    const disabled = canvas.Widget{ .kind = .scroll_view, .state = .{ .disabled = true }, .interaction_policy = core.nativeTextPolicy };
    const event = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowdown" };
    try std.testing.expectEqualDeep(@as(?geometry.OffsetF, geometry.OffsetF.init(0, 24)), canvas.widgetScrollKeyboardDelta(disabled, event));
    try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetScrollKeyboardIntent(disabled, event));
    // Numeric helpers and scroll Home/End need no normalized geometry.
    const invalid_frame = geometry.RectF.init(0, 0, -2, 1);
    for ([_]canvas.WidgetKind{ .slider, .split_divider, .scroll_view }) |kind| {
        const reference = canvas.Widget{ .kind = kind, .value = 0.3, .frame = invalid_frame };
        var compiled = reference;
        compiled.interaction_policy = core.nativeTextPolicy;
        try std.testing.expectEqualDeep(canvas.widgetKeyboardControlIntent(reference, .{ .phase = .key_down, .key = "end" }), canvas.widgetKeyboardControlIntent(compiled, .{ .phase = .key_down, .key = "end" }));
    }
    const retained = canvas.widgetKeyboardControlIntent(.{ .kind = .slider, .value = 0.3, .interaction_policy = core.nativeMenuPolicy }, .{ .phase = .key_down, .key = "arrowright" }).?;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = core.initialModel();
    _ = core.nativeView(arena.allocator());
    _ = canvas.widgetScrollKeyboardIntent(.{ .kind = .scroll_view, .interaction_policy = core.nativeTreePolicy }, event);
    try std.testing.expectEqualDeep(canvas.WidgetControlIntent{ .kind = .set_value, .actions = .{ .increment = true }, .value = @as(f32, 0.3) + @as(f32, 0.05) }, retained);
}

test "complete step consumers honor the compiled result instead of falling back to native planning" {
    const Spy = struct {
        var calls: usize = 0;
        var suppress = true;
        fn policy(request: []const u8, output: []u8) usize {
            if (request[0] == 18) {
                calls += 1;
                if (suppress) {
                    @memset(output[0..16], 0);
                    return 16;
                }
            }
            return core.nativeTextPolicy(request, output);
        }
    };
    Spy.calls = 0;
    Spy.suppress = true;
    const slider = canvas.Widget{ .kind = .slider, .value = 0.3, .interaction_policy = Spy.policy };
    const scroll = canvas.Widget{ .kind = .scroll_view, .interaction_policy = Spy.policy };
    const right = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright" };
    try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetKeyboardControlIntent(slider, right));
    try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetScrollKeyboardIntent(scroll, right));
    try std.testing.expectEqual(@as(?geometry.OffsetF, null), canvas.widgetScrollKeyboardDelta(scroll, right));
    try std.testing.expectEqual(@as(?canvas.WidgetControlIntent, null), canvas.widgetSemanticControlIntentWithActions(slider, .increment, .{ .increment = true }));
    try std.testing.expectEqual(@as(usize, 4), Spy.calls);
    Spy.suppress = false;
    try std.testing.expectEqual(@as(f32, 0.3) + @as(f32, 0.05), canvas.widgetKeyboardControlIntent(slider, right).?.value.?);
    try std.testing.expectEqualDeep(geometry.OffsetF.init(0, 24), canvas.widgetScrollKeyboardDelta(scroll, right).?);
}

test "compiled timer plans preserve native slot order exact f64 changes and copied cycle ownership" {
    const names = [_][]const u8{ "", "pulse", "caf\xc3\xa9", "\x00\xff" };
    const intervals = [_]f64{ 1, 1.4999999999999998, 1.5, 2.4999999999999996, 500.5, 31_535_999_999.5, 31_536_000_000 };
    var request: [512]u8 = undefined;
    var output: [14]u8 = undefined;
    var comparisons: usize = 0;
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed_command = core.bootCommand();
    const command_copy = try std.testing.allocator.dupe(u8, borrowed_command);
    defer std.testing.allocator.free(command_copy);
    const declaration = [_]u8{ 1, 0xff, 0xff, 0, 0 };
    var first_cancel: [2]u8 = undefined;
    try std.testing.expectEqual(first_cancel.len, core.nativeTimerPolicy(&declaration, &first_cancel));
    try std.testing.expectEqualSlices(u8, command_copy, borrowed_command);
    core.rt.frameReset();
    for (0..17) |occupied| {
        for (names) |name| {
            for (intervals) |every| {
                for ([_]u8{ 0, 127, 255 }) |tag| {
                    var matching: ?usize = null;
                    var previous: f64 = 0;
                    request[0] = 0;
                    std.mem.writeInt(u16, request[1..3], 0x5555, .little);
                    request[3] = @intCast(name.len);
                    @memcpy(request[4..][0..name.len], name);
                    var at: usize = 4 + name.len;
                    std.mem.writeInt(u64, request[at..][0..8], @bitCast(every), .little);
                    request[at + 8] = tag;
                    at += 9;
                    for (0..16) |index| {
                        const used = index < occupied;
                        const stored = if (used) names[index % names.len] else "";
                        const interval = if (used) intervals[index % intervals.len] else 0;
                        request[at] = @intFromBool(used);
                        request[at + 1] = @intCast(stored.len);
                        at += 2;
                        @memcpy(request[at..][0..stored.len], stored);
                        at += stored.len;
                        std.mem.writeInt(u64, request[at..][0..8], @bitCast(interval), .little);
                        at += 8;
                        if (used and std.mem.eql(u8, stored, name)) {
                            matching = index;
                            previous = interval;
                        }
                    }
                    const slot = matching orelse occupied;
                    @memset(&output, 0xa5);
                    try std.testing.expectEqual(output.len, core.nativeTimerPolicy(request[0..at], &output));
                    const frozen = output;
                    const retirement = [_]u8{ 1, 0xff, 0xff, 0x55, 0x55 };
                    var cancelled: [2]u8 = undefined;
                    try std.testing.expectEqual(cancelled.len, core.nativeTimerPolicy(&retirement, &cancelled));
                    core.rt.frameReset();
                    try std.testing.expectEqualSlices(u8, &frozen, &output);
                    try std.testing.expectEqual(@as(u16, 0xaaaa), std.mem.readInt(u16, &cancelled, .little));
                    try std.testing.expectEqual(@as(u8, @intCast(slot)), output[0]);
                    try std.testing.expectEqual(@intFromBool(matching == null or previous != every), output[1]);
                    try std.testing.expectEqual(tag, output[2]);
                    try std.testing.expectEqual(@as(u8, 0), output[3]);
                    const rounded: f64 = @bitCast(std.mem.readInt(u64, output[4..12], .little));
                    try std.testing.expectEqual(@round(every), rounded);
                    try std.testing.expectEqual(@as(u16, 0x5555) | (@as(u16, 1) << @intCast(slot)), std.mem.readInt(u16, output[12..14], .little));
                    comparisons += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1428), comparisons);
}

test "compiled delay plans preserve first match empty keys rounding routes and cycle ownership" {
    const names = [_][]const u8{ "", "reminder", "caf\xc3\xa9", "\x00\xff" };
    const intervals = [_]f64{ 1, 1.4999999999999998, 1.5, 2.4999999999999996, 700.5, 31_535_999_999.5, 31_536_000_000 };
    var request: [512]u8 = undefined;
    var comparisons: usize = 0;
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed_command = core.bootCommand();
    const command_copy = try std.testing.allocator.dupe(u8, borrowed_command);
    defer std.testing.allocator.free(command_copy);
    // A live policy allocates without revoking an outstanding command borrow.
    const first = [_]u8{ 4, 0, 1, 0 } ++ ([_]u8{255} ** 16);
    var first_result: [2]u8 = undefined;
    try std.testing.expectEqual(first_result.len, core.nativeTimerPolicy(&first, &first_result));
    try std.testing.expectEqualSlices(u8, command_copy, borrowed_command);
    core.rt.frameReset();
    for (0..17) |occupied| {
        for (names) |name| {
            for (intervals) |after| {
                for ([_]u8{ 0, 127, 255 }) |tag| {
                    var matching: ?usize = null;
                    request[0] = 2;
                    request[1] = @intCast(name.len);
                    @memcpy(request[2..][0..name.len], name);
                    var at: usize = 2 + name.len;
                    std.mem.writeInt(u64, request[at..][0..8], @bitCast(after), .little);
                    request[at + 8] = tag;
                    request[at + 9] = 0; // No incumbent file stream.
                    at += 10;
                    const table_start = at;
                    for (0..16) |index| {
                        const used = index < occupied;
                        const stored = if (used) names[index % names.len] else "";
                        request[at] = @intFromBool(used);
                        request[at + 1] = @intCast(stored.len);
                        at += 2;
                        @memcpy(request[at..][0..stored.len], stored);
                        at += stored.len;
                        request[at] = @intCast(index * 17);
                        at += 1;
                        if (used and matching == null and std.mem.eql(u8, stored, name)) matching = index;
                    }
                    const slot = if (name.len > 0) matching orelse occupied else occupied;
                    // Empty keys with a full table deliberately trap; Node
                    // exercises that refusal instead of aborting this process.
                    if (slot >= 16) continue;
                    var output: [10]u8 = undefined;
                    try std.testing.expectEqual(output.len, core.nativeTimerPolicy(request[0..at], &output));
                    const frozen = output;
                    // Lookup uses the same owned facts, including empty keys.
                    std.mem.copyForwards(u8, request[2 + name.len ..], request[table_start..at]);
                    request[0] = 3;
                    var lookup: [1]u8 = undefined;
                    try std.testing.expectEqual(lookup.len, core.nativeTimerPolicy(request[0 .. at - 10], &lookup));
                    try std.testing.expectEqual(if (matching) |i| @as(u8, @intCast(i)) else @as(u8, 255), lookup[0]);
                    const fire = [_]u8{ 4, @intCast(slot), 0xff, 0xff } ++ ([_]u8{tag} ** 16);
                    var route: [2]u8 = undefined;
                    try std.testing.expectEqual(route.len, core.nativeTimerPolicy(&fire, &route));
                    core.rt.frameReset();
                    try std.testing.expectEqualSlices(u8, &frozen, &output);
                    try std.testing.expectEqual(@as(u8, @intCast(slot)), output[0]);
                    try std.testing.expectEqual(tag, output[1]);
                    try std.testing.expectEqual(@round(after), @as(f64, @bitCast(std.mem.readInt(u64, output[2..10], .little))));
                    try std.testing.expectEqualSlices(u8, &.{ @intCast(slot), tag }, &route);
                    comparisons += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1407), comparisons);
    // First-free holes exercise every slot independently of retained keys.
    for (0..16) |hole| {
        request[0] = 2;
        request[1] = 0;
        std.mem.writeInt(u64, request[2..10], @bitCast(@as(f64, 1)), .little);
        request[10] = 255;
        request[11] = 0;
        for (0..16) |index| {
            request[12 + index * 3] = @intFromBool(index != hole);
            request[13 + index * 3] = 0;
            request[14 + index * 3] = 0;
        }
        var output: [10]u8 = undefined;
        try std.testing.expectEqual(output.len, core.nativeTimerPolicy(request[0..60], &output));
        try std.testing.expectEqual(@as(u8, @intCast(hole)), output[0]);
        core.rt.frameReset();
    }
}

test "compiled delay admission drops an incumbent stream even with a full table" {
    var request = [_]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 1 } ++ ([_]u8{ 1, 0, 0 } ** 16);
    std.mem.writeInt(u64, request[2..10], @bitCast(@as(f64, 700.5)), .little);
    var output: [10]u8 = undefined;
    try std.testing.expectEqual(output.len, core.nativeTimerPolicy(&request, &output));
    try std.testing.expectEqual(@as(u8, 255), output[0]);
    core.rt.frameReset();
}

test "compiled database plans preserve first matching keys exact fingerprints retention and ABI ownership" {
    const longest = [_]u8{255} ** 255;
    const names = [_][]const u8{ "query", "caf\xc3\xa9", "\x00\xff", &longest, "absent" };
    var request: [4608]u8 = undefined;
    var lookup: [4608]u8 = undefined;
    var retention: [4608]u8 = undefined;
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed_command = core.bootCommand();
    try std.testing.expect(borrowed_command.len > 0);
    const command_copy = try std.testing.allocator.dupe(u8, borrowed_command);
    defer std.testing.allocator.free(command_copy);
    @memset(request[0..181], 0);
    request[0] = 1;
    var kept: [2]u8 = undefined;
    try std.testing.expectEqual(kept.len, core.nativeDbPolicy(request[0..181], &kept));
    try std.testing.expectEqualSlices(u8, command_copy, borrowed_command);
    core.rt.frameReset();
    var comparisons: usize = 0;
    for (0..17) |occupied| for (names) |name| {
        var matching: ?usize = null;
        var at: usize = 15 + name.len;
        const table_start = at;
        for (0..16) |index| {
            const used = index < occupied;
            const stored = if (used) names[index % 4] else "";
            request[at] = @intFromBool(used);
            request[at + 1] = 1;
            request[at + 2] = @intCast(stored.len);
            @memcpy(request[at + 3 ..][0..stored.len], stored);
            std.mem.writeInt(u64, request[at + 3 + stored.len ..][0..8], 0xffff_ffff_ffff_fff0 + @as(u64, @intCast(index)), .little);
            at += 11 + stored.len;
            if (used and matching == null and std.mem.eql(u8, stored, name)) matching = index;
        }
        lookup[0] = 0;
        lookup[1] = @intCast(name.len);
        @memcpy(lookup[2..][0..name.len], name);
        @memcpy(lookup[2 + name.len ..][0 .. at - table_start], request[table_start..at]);
        var found: [1]u8 = undefined;
        try std.testing.expectEqual(found.len, core.nativeDbPolicy(lookup[0 .. at - 13], &found));
        try std.testing.expectEqual(if (matching) |index| @as(u8, @intCast(index)) else @as(u8, 255), found[0]);
        retention[0] = 1;
        std.mem.writeInt(u32, retention[1..5], @intCast(1 + name.len), .little);
        retention[5] = @intCast(name.len);
        @memcpy(retention[6..][0..name.len], name);
        @memcpy(retention[6 + name.len ..][0 .. at - table_start], request[table_start..at]);
        try std.testing.expectEqual(kept.len, core.nativeDbPolicy(retention[0 .. at - 9], &kept));
        try std.testing.expectEqual(if (matching) |index| @as(u16, 1) << @intCast(index) else @as(u16, 0), std.mem.readInt(u16, &kept, .little));
        const slot = matching orelse occupied;
        if (slot >= 16) {
            core.rt.frameReset();
            continue;
        }
        for (0..9) |variant| {
            request[0] = 2;
            const seen: u16 = 0x8000 & ~(@as(u16, 1) << @intCast(slot));
            std.mem.writeInt(u16, request[1..3], seen, .little);
            request[3] = @intCast(name.len);
            @memcpy(request[4..][0..name.len], name);
            std.mem.writeInt(u64, request[4 + name.len ..][0..8], 0xffff_ffff_ffff_fff0 + @as(u64, @intCast(matching orelse 0)), .little);
            if (variant > 0) request[4 + name.len + variant - 1] ^= 1;
            @memcpy(request[12 + name.len ..][0..3], &@as([3]u8, .{ 7, 127, 255 }));
            var result: [8]u8 = undefined;
            try std.testing.expectEqual(result.len, core.nativeDbPolicy(request[0..at], &result));
            const frozen = result;
            try std.testing.expectEqual(found.len, core.nativeDbPolicy(lookup[0 .. at - 13], &found));
            core.rt.frameReset();
            try std.testing.expectEqualSlices(u8, &frozen, &result);
            const changed = matching == null or variant > 0;
            try std.testing.expectEqualSlices(u8, &.{ @intCast(slot), @intFromBool(changed), @intFromBool(matching != null and changed), 7, 127, 255 }, result[0..6]);
            try std.testing.expectEqual(seen | (@as(u16, 1) << @intCast(slot)), std.mem.readInt(u16, result[6..8], .little));
            comparisons += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 756), comparisons);
    // Every first-free hole is selected even when all other slots are used.
    for (0..16) |hole| {
        @memset(request[0..192], 0);
        request[0] = 2;
        request[3] = 1;
        request[4] = 'x';
        for (0..16) |slot| request[16 + slot * 11] = @intFromBool(slot != hole);
        var result: [8]u8 = undefined;
        try std.testing.expectEqual(result.len, core.nativeDbPolicy(request[0..192], &result));
        try std.testing.expectEqual(@as(u8, @intCast(hole)), result[0]);
        core.rt.frameReset();
    }
}

test "compiled named effect plans preserve drop occupancy slot order routes and copied cycle ownership" {
    const longest = [_]u8{255} ** 255;
    const names = [_][]const u8{ "", "read", "caf\xc3\xa9", "\x00\xff", &longest, "absent" };
    var request: [4608]u8 = undefined;
    var lookup: [4608]u8 = undefined;
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    try std.testing.expect(borrowed.len > 0);
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    @memset(request[0..85], 0);
    request[3] = 127;
    request[4] = 255;
    var plan: [5]u8 = undefined;
    try std.testing.expectEqual(plan.len, core.nativeEffectPolicy(request[0..85], &plan));
    const frozen_plan = plan;
    var stream_plan: [5]u8 = undefined;
    try std.testing.expectEqual(stream_plan.len, core.nativeStreamPolicy(&.{ 2, 1, 0, 0, 0, 127 }, &stream_plan));
    const frozen_stream = stream_plan;
    var window_plan: [2]u8 = undefined;
    try std.testing.expectEqual(window_plan.len, core.nativeWindowPolicy(&.{ 0, 0, 0 }, &window_plan));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, &window_plan);
    try std.testing.expectEqual(plan.len, core.nativeEffectPolicy(request[0..85], &plan));
    try std.testing.expectEqualSlices(u8, &frozen_plan, &plan);
    try std.testing.expectEqualSlices(u8, &frozen_stream, &stream_plan);
    try std.testing.expectEqualSlices(u8, copy, borrowed);
    core.rt.frameReset();
    var comparisons: usize = 0;
    for (0..17) |occupied| for (0..4) |drops| for (names) |name| {
        request[0] = 0;
        request[1] = @intCast(name.len);
        @memcpy(request[2..][0..name.len], name);
        const start = 5 + name.len;
        var at = start;
        var matching: u8 = 255;
        for (0..16) |slot| {
            const used = slot < occupied;
            const dropped = (slot + drops) % 3 == 0;
            const stored = names[slot % 5];
            request[at] = @intFromBool(used);
            request[at + 1] = @intFromBool(dropped);
            request[at + 2] = @intCast(stored.len);
            @memcpy(request[at + 3 ..][0..stored.len], stored);
            at += 3 + stored.len;
            request[at] = @intCast(slot * 16);
            request[at + 1] = @intCast(255 - slot * 16);
            at += 2;
            if (used and !dropped and matching == 255 and std.mem.eql(u8, stored, name)) matching = @intCast(slot);
        }
        lookup[0] = 1;
        lookup[1] = @intCast(name.len);
        @memcpy(lookup[2..][0..name.len], name);
        @memcpy(lookup[2 + name.len ..][0 .. at - start], request[start..at]);
        var found: [1]u8 = undefined;
        try std.testing.expectEqual(found.len, core.nativeEffectPolicy(lookup[0 .. at - 3], &found));
        try std.testing.expectEqual(matching, found[0]);
        for ([_]bool{ false, true }) |blocked| {
            request[2 + name.len] = @intFromBool(blocked);
            request[3 + name.len] = 127;
            request[4 + name.len] = 255;
            try std.testing.expectEqual(plan.len, core.nativeEffectPolicy(request[0..at], &plan));
            const frozen = plan;
            try std.testing.expectEqual(found.len, core.nativeEffectPolicy(lookup[0 .. at - 3], &found));
            core.rt.frameReset();
            try std.testing.expectEqualSlices(u8, &frozen, &plan);
            const free: u8 = if (blocked or occupied == 16) 255 else @intCast(occupied);
            const drop: u8 = if (blocked or name.len == 0) 255 else matching;
            try std.testing.expectEqualSlices(u8, &.{ @intFromBool(!blocked), free, drop, 127, 255 }, &plan);
            comparisons += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 816), comparisons);
    for (0..16) |hole| {
        @memset(request[0..85], 0);
        for (0..16) |slot| request[5 + slot * 5] = @intFromBool(slot != hole);
        try std.testing.expectEqual(plan.len, core.nativeEffectPolicy(request[0..85], &plan));
        try std.testing.expectEqual(@as(u8, @intCast(hole)), plan[1]);
        core.rt.frameReset();
    }
    var completion: [69]u8 = undefined;
    completion[0] = 2;
    for (0..16) |slot| {
        completion[5 + slot * 4] = 1;
        completion[6 + slot * 4] = 0;
        completion[7 + slot * 4] = @intCast(slot * 16);
        completion[8 + slot * 4] = @intCast(255 - slot * 16);
    }
    var routes: usize = 0;
    for (0..16) |slot| for (0..4) |kind| for ([_]bool{ false, true }) |ok| for ([_]bool{ false, true }) |cut| for ([_]bool{ false, true }) |dropped| {
        completion[1] = @intCast(slot);
        completion[2] = @intCast(kind);
        completion[3] = @intFromBool(ok);
        completion[4] = @intFromBool(cut);
        completion[6 + slot * 4] = @intFromBool(dropped);
        var result: [4]u8 = undefined;
        try std.testing.expectEqual(result.len, core.nativeEffectPolicy(&completion, &result));
        const frozen = result;
        try std.testing.expectEqual(plan.len, core.nativeEffectPolicy(request[0..85], &plan));
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &frozen, &result);
        const success = ok and !(kind == 3 and cut);
        try std.testing.expectEqualSlices(u8, &.{ @intCast(slot), @intCast(if (dropped or !success) 255 - slot * 16 else slot * 16), @intCast(if (dropped) 0 else if (success) kind + 1 else 5), @as(u8, if (dropped or success) 0 else if (ok and kind == 3 and cut) 2 else 1) }, &result);
        routes += 1;
    };
    try std.testing.expectEqual(@as(usize, 512), routes);
}

test "compiled stream plans preserve admission routes loss and dispatch arena ownership" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    try std.testing.expect(borrowed.len > 0);
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    var result: [5]u8 = undefined;
    try std.testing.expectEqual(result.len, core.nativeStreamPolicy(&.{ 2, 1, 0, 0, 0, 127 }, &result));
    try std.testing.expectEqualSlices(u8, copy, borrowed);
    core.rt.frameReset();
    var comparisons: usize = 0;
    for ([_]u8{ 0, 127, 255 }) |tag| for ([_]u8{ 0, 1 }) |a| for ([_]u8{ 0, 1 }) |b| for ([_]u8{ 0, 1 }) |c| for ([_]u8{ 0, 1 }) |d| {
        try std.testing.expectEqual(result.len, core.nativeStreamPolicy(&.{ 2, a, b, c, d, tag }, &result));
        const line = result;
        const damage = b == 1 or (a == 1 and (c == 1 or d == 1));
        try std.testing.expectEqualSlices(u8, &.{ tag, 0, @intFromBool(damage), 0, 0 }, &line);
        const spawn_success = b == 1 and (a == 0 or c == 0);
        try std.testing.expectEqual(result.len, core.nativeStreamPolicy(&.{ 3, a, b, c, tag, 255 - tag }, &result));
        const spawn_shape: u8 = if (spawn_success) (if (a == 1) 2 else 1) else 0;
        try std.testing.expectEqualSlices(u8, &.{ if (spawn_success) tag else 255 - tag, spawn_shape, 0, 1, @intFromBool(!spawn_success and b == 1) }, &result);
        try std.testing.expectEqual(result.len, core.nativeStreamPolicy(&.{ 4, a, b, c, d, tag, 255 - tag }, &result));
        const fetch_damage = a == 1 or b == 1 or c == 1;
        const fetch_success = d == 1 and !fetch_damage;
        try std.testing.expectEqualSlices(u8, &.{ if (fetch_success) tag else 255 - tag, @intFromBool(fetch_success), @intFromBool(fetch_damage), 1, @intFromBool(d == 1 and fetch_damage) }, &result);
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &.{ tag, 0, @intFromBool(damage), 0, 0 }, &line);
        comparisons += 3;
    };
    const long_key = [_]u8{255} ** 255;
    const names = [_][]const u8{ "", "source", "caf\xc3\xa9", "\x00\xff", &long_key };
    var request: [4400]u8 = undefined;
    for (0..17) |occupied| for (names) |name| for ([_]u8{ 0, 1 }) |fetch| for ([_]u8{ 0, 1 }) |file| for ([_]u8{ 0, 1 }) |effect| {
        request[0..5].* = .{ 0, fetch, file, effect, @intCast(name.len) };
        @memcpy(request[5..][0..name.len], name);
        var at: usize = 5 + name.len;
        var matching: ?usize = null;
        for (0..16) |slot| {
            const used = slot < occupied;
            const stored = names[slot % names.len];
            request[at] = @intFromBool(used);
            request[at + 1] = @intCast(stored.len);
            at += 2;
            @memcpy(request[at..][0..stored.len], stored);
            at += stored.len;
            if (used and matching == null and std.mem.eql(u8, stored, name)) matching = slot;
        }
        var admission: [1]u8 = undefined;
        try std.testing.expectEqual(admission.len, core.nativeStreamPolicy(request[0..at], &admission));
        const blocked = name.len > 0 and (matching != null or file == 1 or (fetch == 1 and effect == 1));
        const expected: u8 = if (blocked or occupied == 16) 255 else @intCast(occupied);
        try std.testing.expectEqual(expected, admission[0]);
        // The borrowed request remains usable after a second policy call.
        std.mem.copyForwards(u8, request[2..], request[5..at]);
        request[0..2].* = .{ 1, @intCast(name.len) };
        var lookup: [1]u8 = undefined;
        try std.testing.expectEqual(lookup.len, core.nativeStreamPolicy(request[0 .. at - 3], &lookup));
        try std.testing.expectEqual(if (matching) |slot| @as(u8, @intCast(slot)) else @as(u8, 255), lookup[0]);
        core.rt.frameReset();
        try std.testing.expectEqual(expected, admission[0]);
        comparisons += 2;
    };
    for (0..16) |hole| {
        @memset(request[0..38], 0);
        request[4] = 1;
        request[5] = 'x';
        for (0..16) |slot| request[6 + slot * 2] = @intFromBool(slot != hole);
        var admission: [1]u8 = undefined;
        try std.testing.expectEqual(admission.len, core.nativeStreamPolicy(request[0..38], &admission));
        try std.testing.expectEqual(@as(u8, @intCast(hole)), admission[0]);
        core.rt.frameReset();
        comparisons += 1;
    }
    try std.testing.expectEqual(@as(usize, 1520), comparisons);
}

fn writeWindowPolicyTestLabel(writer: *std.Io.Writer, label: []const u8) !void {
    try writer.writeInt(u32, @intCast(label.len), .little);
    try writer.writeAll(label);
}

test "compiled window decisions preserve labels admission order retirement and ABI ownership" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed_command = core.bootCommand();
    const command_copy = try std.testing.allocator.dupe(u8, borrowed_command);
    defer std.testing.allocator.free(command_copy);
    const names = [_][]const u8{ "", "new", "other", "caf\xc3\xa9", "\x00\xff", &([_]u8{255} ** 64), &([_]u8{255} ** 65) };
    const canvases = [_][]const u8{ "", "main", "fresh", "occupied", "\x00\xff", &([_]u8{255} ** 64), &([_]u8{255} ** 65) };
    var comparisons: usize = 0;
    for (0..5) |count| {
        for (names) |name| for (canvases) |candidate_canvas| {
            var buffer: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try writer.writeByte(1);
            try writeWindowPolicyTestLabel(&writer, "main");
            try writeWindowPolicyTestLabel(&writer, name);
            try writeWindowPolicyTestLabel(&writer, candidate_canvas);
            try writer.writeByte(@intCast(count));
            var matching: ?u8 = null;
            for (0..count) |index| {
                const stored = names[1 + index % 4];
                try writeWindowPolicyTestLabel(&writer, stored);
                try writeWindowPolicyTestLabel(&writer, "occupied");
                if (matching == null and std.mem.eql(u8, name, stored)) matching = @intCast(index);
            }
            const action: u8 = if (matching != null) 1 else if (count == 4) 2 else if (name.len == 0 or name.len > 64 or candidate_canvas.len == 0 or candidate_canvas.len > 64) 3 else if (std.mem.eql(u8, candidate_canvas, "main") or (count > 0 and std.mem.eql(u8, candidate_canvas, "occupied"))) 4 else 0;
            var result: [2]u8 = undefined;
            try std.testing.expectEqual(result.len, core.nativeWindowPolicy(writer.buffered(), &result));
            try std.testing.expectEqualSlices(u8, &.{ action, matching orelse 255 }, &result);
            try std.testing.expectEqualSlices(u8, command_copy, borrowed_command);
            const frozen = result;
            const retirement: [3]u8 = .{ 0, 0, 0 };
            var other: [2]u8 = undefined;
            try std.testing.expectEqual(other.len, core.nativeWindowPolicy(&retirement, &other));
            try std.testing.expectEqualSlices(u8, &frozen, &result);
            comparisons += 1;
        };
    }
    core.rt.frameReset();
    try std.testing.expectEqual(@as(usize, 245), comparisons);
    for (0..16) |mask| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeByte(0);
        try writer.writeByte(@intCast(@popCount(mask)));
        for (0..4) |index| if (mask & (@as(usize, 1) << @intCast(index)) != 0) {
            try writeWindowPolicyTestLabel(&writer, names[index + 1]);
        };
        try writer.writeByte(4);
        var stale: u8 = 255;
        for (0..4) |index| {
            try writeWindowPolicyTestLabel(&writer, names[index + 1]);
            try writeWindowPolicyTestLabel(&writer, "occupied");
            if (stale == 255 and mask & (@as(usize, 1) << @intCast(index)) == 0) stale = @intCast(index);
        }
        var result: [2]u8 = undefined;
        try std.testing.expectEqual(result.len, core.nativeWindowPolicy(writer.buffered(), &result));
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &.{ 0, stale }, &result);
    }
}

test "compiled theme policy preserves exact accent bytes and dispatch ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const command = core.bootCommand();
    const owned = try std.testing.allocator.dupe(u8, command);
    defer std.testing.allocator.free(owned);
    const base = [_]u8{ 0, '#', '1', '2', 'a', 'B', 'c', 'F' };
    for (1..8) |position| for (0..256) |byte| {
        var request = base;
        request[position] = @intCast(byte);
        var result: [4]u8 = undefined;
        try std.testing.expectEqual(result.len, core.nativeThemePolicy(&request, &result));
        const parsed = if (request[1] == '#') std.fmt.parseInt(u24, request[2..8], 16) catch null else null;
        // parseInt accepts signs and underscores: explicit character checks
        // retain the native adapter's narrower exactly-six-digit contract.
        var valid = request[1] == '#';
        for (request[2..8]) |digit| valid = valid and ((digit >= '0' and digit <= '9') or (digit >= 'a' and digit <= 'f') or (digit >= 'A' and digit <= 'F'));
        if (valid) {
            const rgb = parsed.?;
            try std.testing.expectEqualSlices(u8, &.{ 1, @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) }, &result);
        } else try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &result);
        // Theme calls may run while commands/helper bytes are still borrowed.
        try std.testing.expectEqualSlices(u8, owned, command);
    };
    var result: [4]u8 = undefined;
    try std.testing.expectEqual(result.len, core.nativeThemePolicy(&base, &result));
    const frozen = result;
    var other: [4]u8 = undefined;
    try std.testing.expectEqual(other.len, core.nativeThemePolicy(&.{ 0, '#', 'f', 'f', '0', '0', '0', '0' }, &other));
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &frozen, &result);
}

const ThemeFixtureModel = struct { count: u32 = 0 };
const ThemeFixtureMsg = enum { tap };
const ThemeFixture = native_sdk.UiApp(ThemeFixtureModel, ThemeFixtureMsg);
const ThemeFixtureFunctions = struct {
    fn update(_: *ThemeFixtureModel, _: ThemeFixtureMsg) void {}
    fn view(ui: *ThemeFixture.Ui, _: *const ThemeFixtureModel) ThemeFixture.Ui.Node {
        return ui.text(.{}, "Theme");
    }
    fn custom(_: *const ThemeFixtureModel) canvas.DesignTokens {
        return canvas.DesignTokens.theme(.{ .color_scheme = .light, .pack = .house });
    }
};

test "compiled theme policy matches every complete native token register" {
    defer core.rt.frameReset();
    const compiled = try std.testing.allocator.create(ThemeFixture);
    defer std.testing.allocator.destroy(compiled);
    const reference = try std.testing.allocator.create(ThemeFixture);
    defer std.testing.allocator.destroy(reference);
    var options = ThemeFixture.Options{ .name = "theme-fixture", .scene = .{}, .canvas_label = "canvas", .view = ThemeFixtureFunctions.view, .update = ThemeFixtureFunctions.update };
    reference.* = ThemeFixture.init(std.heap.page_allocator, .{}, options);
    defer reference.deinit();
    options.theme_policy = core.nativeThemePolicy;
    compiled.* = ThemeFixture.init(std.heap.page_allocator, .{}, options);
    defer compiled.deinit();
    var comparisons: usize = 0;
    for (0..3) |model_pack| for (0..2) |fallback_pack| for (0..3) |scheme| for (0..2) |os| for (0..2) |contrast| for (0..2) |motion| for (0..2) |model_accent| for (0..2) |manifest_accent| {
        const state: ThemeFixture.ThemeState = .{
            .pack = switch (model_pack) {
                0 => null,
                1 => .house,
                else => .geist,
            },
            .color_scheme = switch (scheme) {
                0 => .system,
                1 => .light,
                else => .dark,
            },
            .accent = if (model_accent == 1) canvas.Color.rgb8(0, 120, 111) else null,
        };
        const appearance: native_sdk.platform.Appearance = .{ .color_scheme = if (os == 0) .light else .dark, .high_contrast = contrast == 1, .reduce_motion = motion == 1 };
        for ([_]*ThemeFixture{ reference, compiled }) |app| {
            app.theme_state = state;
            app.theme_state_known = true;
            app.options.theme = if (fallback_pack == 0) .house else .geist;
            app.options.theme_accent = if (manifest_accent == 1) canvas.Color.rgba8(88, 101, 242, 127) else null;
            app.system_appearance = appearance;
            app.pixel_snap_scale = 2;
        }
        try std.testing.expectEqualDeep(reference.effectiveTokens(), compiled.effectiveTokens());
        core.rt.frameReset();
        comparisons += 1;
    };
    try std.testing.expectEqual(@as(usize, 576), comparisons);
    for (0..2) |function| for (0..2) |fixed| for (0..2) |helper| for (0..3) |scheme| {
        const follows = function == 0 and fixed == 0 and (helper == 0 or scheme == 0);
        var result: [4]u8 = undefined;
        try std.testing.expectEqual(result.len, core.nativeThemePolicy(&.{ 2, @intCast(function), @intCast(fixed), @intCast(helper), @intCast(scheme) }, &result));
        try std.testing.expectEqualSlices(u8, &.{ if (function == 1) 1 else if (fixed == 1) 2 else 0, @intFromBool(follows), @intFromBool(function == 1 or helper == 1 or follows), 0 }, &result);
        for ([_]*ThemeFixture{ reference, compiled }) |app| {
            app.options.tokens_fn = if (function == 1) ThemeFixtureFunctions.custom else null;
            app.options.tokens = if (fixed == 1) canvas.DesignTokens.theme(.{ .color_scheme = .dark }) else null;
        }
        try std.testing.expectEqualDeep(reference.effectiveTokens(), compiled.effectiveTokens());
        core.rt.frameReset();
    };
}

fn statusPolicyRequest(buffer: []u8, ids: []const u32, index: ?usize, used: u8, full_count: ?u8) []const u8 {
    buffer[0] = @intFromBool(index != null);
    buffer[1] = if (index) |i| @intCast(i) else 255;
    buffer[2] = @intCast(ids.len);
    buffer[3] = full_count orelse @as(u8, @intCast(@popCount(used)));
    var at: usize = 4;
    for (ids) |id| {
        std.mem.writeInt(u32, buffer[at..][0..4], id, .little);
        at += 4;
    }
    for (0..8) |slot| {
        buffer[at] = @intFromBool(used & (@as(u8, 1) << @intCast(slot)) != 0);
        std.mem.writeInt(u32, buffer[at + 1 ..][0..4], @intCast(slot + 1), .little);
        at += 5;
    }
    return buffer[0..at];
}

test "compiled hold planning preserves every gesture state and borrowed cycle data" {
    defer core.rt.frameReset();
    const callbacks = [_]*const fn ([]const u8, []u8) usize{
        core.nativeTextPolicy,   core.nativeRadioPolicy,     core.nativeTabsPolicy,
        core.nativeTreePolicy,   core.nativeListPolicy,      core.nativeMenuPolicy,
        core.nativeTogglePolicy, core.nativeAccordionPolicy, core.nativeSliderPolicy,
        core.nativeSplitPolicy,  core.nativeScrollPolicy,    core.nativeResizablePolicy,
    };
    for (callbacks) |policy| for (0..4) |operation| for (0..16) |facts| {
        const armed = facts & 1 != 0;
        const fired = facts & 2 != 0;
        const expected: u8 = if (operation == 2)
            (if (armed and !fired and facts & 8 != 0) @as(u8, 16) else 0)
        else
            2 | @as(u8, @intFromBool(armed and !fired)) |
                (if (operation == 0 and facts & 4 != 0) @as(u8, 4) else 0) |
                (if (operation == 1 and fired) @as(u8, 8) else 0);
        const request = [_]u8{ 19, @intCast(operation), @intCast(facts) };
        var output: [1]u8 = undefined;
        try std.testing.expectEqual(output.len, policy(&request, &output));
        try std.testing.expectEqual(expected, output[0]);
    };
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    for (0..4) |operation| for (0..16) |facts| {
        var output: [1]u8 = undefined;
        const request = [_]u8{ 19, @intCast(operation), @intCast(facts) };
        try std.testing.expectEqual(output.len, core.nativePressHoldPolicy(&request, &output));
        try std.testing.expectEqualSlices(u8, copy, borrowed);
    };
    var result: [1]u8 = undefined;
    try std.testing.expectEqual(result.len, core.nativePressHoldPolicy(&.{ 19, 2, 9 }, &result));
    core.rt.frameReset();
    _ = core.initialModel();
    try std.testing.expectEqual(@as(u8, 16), result[0]);
}

const HoldConsumerModel = struct { presses: u32 = 0, holds: u32 = 0, drags: u32 = 0 };
const HoldConsumerMsg = union(enum) {
    pressed,
    held,
    dragged: struct { sourceId: u64 = 1, phase: u32 = 0, x: f32 = 0, y: f32 = 0, viewWidth: f32 = 0, viewHeight: f32 = 0 },
};
const HoldConsumer = native_sdk.UiApp(HoldConsumerModel, HoldConsumerMsg);
const HoldConsumerFunctions = struct {
    fn update(model: *HoldConsumerModel, msg: HoldConsumerMsg) void {
        switch (msg) {
            .pressed => model.presses += 1,
            .held => model.holds += 1,
            .dragged => |drag| if (drag.phase == 0) {
                model.drags += 1;
            },
        }
    }
    fn view(ui: *HoldConsumer.Ui, _: *const HoldConsumerModel) HoldConsumer.Ui.Node {
        return ui.button(.{ .on_press = .pressed, .on_hold = .held, .on_drag = .{ .dragged = .{} }, .height = 60 }, "Hold");
    }
    fn suppress(_: []const u8, output: []u8) usize {
        output[0] = 0;
        return 1;
    }
};
const HoldTimerCapabilities = struct {
    var original: native_sdk.platform.PlatformServices = undefined;
    var fail_start = false;
    var fail_cancel = false;
    var calls = [_]usize{0} ** 2;
    fn start(_: ?*anyopaque, id: u64, interval: u64, repeats: bool) anyerror!void {
        calls[0] += 1;
        if (fail_start) return error.StartFailed;
        try original.startTimer(id, interval, repeats);
    }
    fn cancel(_: ?*anyopaque, id: u64) anyerror!void {
        calls[1] += 1;
        if (fail_cancel) return error.CancelFailed;
        try original.cancelTimer(id);
    }
};

test "compiled hold decisions own runtime gestures and preserve failed timer behavior" {
    var reference: [4]usize = undefined;
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(640, 480) });
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        HoldTimerCapabilities.original = harness.runtime.options.platform.services;
        HoldTimerCapabilities.fail_start = false;
        HoldTimerCapabilities.fail_cancel = false;
        HoldTimerCapabilities.calls = @splat(0);
        harness.runtime.options.platform.services.start_timer_fn = HoldTimerCapabilities.start;
        harness.runtime.options.platform.services.cancel_timer_fn = HoldTimerCapabilities.cancel;
        const state = try HoldConsumer.create(std.heap.page_allocator, .{
            .name = "hold-consumer",
            .scene = app_scene,
            .canvas_label = canvas_label,
            .view = HoldConsumerFunctions.view,
            .update = HoldConsumerFunctions.update,
            .press_hold_policy = if (compiled) core.nativePressHoldPolicy else null,
        });
        defer state.destroy();
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(640, 480),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        const id = state.tree.?.root.id;
        const point = (try harness.runtime.canvasWidgetLayout(1, canvas_label)).findById(id).?.frame.normalized().center();
        var command_buffer: [128]u8 = undefined;
        const hold_command = try std.fmt.bufPrint(&command_buffer, "widget-hold {s} {d}", .{ canvas_label, id });
        try harness.runtime.dispatchAutomationCommand(state.app(), hold_command);
        try std.testing.expectEqual(@as(u32, 1), state.model.holds);
        try std.testing.expectEqual(@as(u32, 0), state.model.presses);
        // Failed starts still retain the native reference's armed gesture.
        // Failed cancels still clear it, so a late timer cannot fire a Msg.
        HoldTimerCapabilities.fail_start = true;
        HoldTimerCapabilities.fail_cancel = true;
        for ([_]native_sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }) |kind|
            try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = canvas_label,
                .kind = kind,
                .x = point.x,
                .y = point.y,
            } });
        try std.testing.expectEqual(@as(canvas.ObjectId, 0), state.hold_armed_id);
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .timer = .{ .id = HoldConsumer.press_hold_timer_id, .timestamp_ns = 400_000_000 } });
        try std.testing.expectEqual(@as(u32, 1), state.model.holds);
        try std.testing.expectEqual(@as(u32, 1), state.model.presses);
        const observed = [_]usize{ state.model.presses, state.model.holds, HoldTimerCapabilities.calls[0], HoldTimerCapabilities.calls[1] };
        if (compiled) try std.testing.expectEqualSlices(usize, &reference, &observed) else reference = observed;
        HoldTimerCapabilities.fail_start = false;
        HoldTimerCapabilities.fail_cancel = false;
        for ([_]native_sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_drag }) |kind|
            try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = canvas_label,
                .kind = kind,
                .x = point.x + (if (kind == .pointer_drag) @as(f32, 40) else 0),
                .y = point.y,
            } });
        try std.testing.expectEqual(@as(u32, 1), state.model.drags);
        try std.testing.expectEqual(@as(canvas.ObjectId, 0), state.hold_armed_id);
        try std.testing.expect(harness.null_platform.fireTimer(HoldConsumer.press_hold_timer_id, 500_000_000) == null);
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_up,
            .x = point.x + 40,
            .y = point.y,
        } });
        try std.testing.expectEqual(@as(u32, 1), state.model.holds);
        try std.testing.expectEqual(@as(u32, 1), state.model.presses);
        // The consumer must honor policy output rather than re-derive arming.
        state.options.press_hold_policy = HoldConsumerFunctions.suppress;
        try harness.runtime.dispatchAutomationCommand(state.app(), hold_command);
        try std.testing.expectEqual(@as(u32, 1), state.model.holds);
        try std.testing.expectEqual(@as(u32, 2), state.model.presses);
    }
}

test "compiled status policy preserves admission retirement exact hash bytes and cycle ownership" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    var buffer: [76]u8 = undefined;
    var output: [2]u8 = undefined;
    const ids = [_]u32{ 0, 1, 0xffff_ffff, 1, 0x8000_0000, 6, 7, 8 };
    for (0..256) |mask| {
        const used: u8 = @intCast(mask);
        var expected_retired: u8 = 0;
        for (0..8) |slot| {
            var declared = false;
            for (ids) |id| if (id == slot + 1) {
                declared = true;
            };
            if (used & (@as(u8, 1) << @intCast(slot)) != 0 and !declared) expected_retired |= @as(u8, 1) << @intCast(slot);
        }
        try std.testing.expectEqual(output.len, core.nativeStatusPolicy(statusPolicyRequest(&buffer, &ids, null, used, null), &output));
        try std.testing.expectEqualSlices(u8, &.{ expected_retired, 255 }, &output);
        for (ids, 0..) |id, index| {
            var invalid = id == 0;
            for (ids[0..index]) |earlier| if (earlier == id) {
                invalid = true;
            };
            var matching: ?u8 = null;
            var free: ?u8 = null;
            for (0..8) |slot| {
                const active = used & (@as(u8, 1) << @intCast(slot)) != 0;
                if (active and id == slot + 1 and matching == null) matching = @intCast(slot);
                if (!active and free == null) free = @intCast(slot);
            }
            const expected: [2]u8 = if (invalid) .{ 0, 255 } else if (matching) |slot| .{ 3, slot } else if (free) |slot| .{ 2, slot } else .{ 1, 255 };
            try std.testing.expectEqual(output.len, core.nativeStatusPolicy(statusPolicyRequest(&buffer, &ids, index, used, null), &output));
            try std.testing.expectEqualSlices(u8, &expected, &output);
        }
    }
    // Every hole and the independent native count guard; lookup comes first.
    for (0..8) |hole| {
        const used = @as(u8, 255) & ~(@as(u8, 1) << @intCast(hole));
        try std.testing.expectEqual(output.len, core.nativeStatusPolicy(statusPolicyRequest(&buffer, &.{99}, 0, used, null), &output));
        try std.testing.expectEqualSlices(u8, &.{ 2, @intCast(hole) }, &output);
        try std.testing.expectEqual(output.len, core.nativeStatusPolicy(statusPolicyRequest(&buffer, &.{99}, 0, used, 8), &output));
        try std.testing.expectEqualSlices(u8, &.{ 1, 255 }, &output);
        const matched: u32 = if (hole == 0) 2 else 1;
        try std.testing.expectEqual(output.len, core.nativeStatusPolicy(statusPolicyRequest(&buffer, &.{matched}, 0, used, 8), &output));
        try std.testing.expectEqualSlices(u8, &.{ 3, @intCast(matched - 1) }, &output);
    }
    var patch: [49]u8 = undefined;
    patch[0] = 2;
    for (0..24) |byte| {
        patch[1 + byte] = @intCast(255 - byte);
        patch[25 + byte] = patch[1 + byte];
    }
    for (0..8) |mask| for (0..8) |byte| {
        var request = patch;
        for (0..3) |field| if (mask & (@as(usize, 1) << @intCast(field)) != 0) {
            request[1 + field * 8 + byte] ^= 1;
        };
        try std.testing.expectEqual(output.len, core.nativeStatusPolicy(&request, &output));
        try std.testing.expectEqualSlices(u8, &.{ @intCast(mask), 255 }, &output);
        try std.testing.expectEqualSlices(u8, copy, borrowed);
    };
    const frozen = output;
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &frozen, &output);
}

const StatusParityModel = struct { revision: u32 = 0, present: bool = true };
const StatusParityMsg = union(enum) { bump, remove, restore };
const StatusParityApp = native_sdk.UiApp(StatusParityModel, StatusParityMsg);
fn statusParityUpdate(model: *StatusParityModel, msg: StatusParityMsg) void {
    switch (msg) {
        .bump => model.revision += 1,
        .remove => model.present = false,
        .restore => model.present = true,
    }
}
fn statusParityView(ui: *StatusParityApp.Ui, model: *const StatusParityModel) StatusParityApp.Ui.Node {
    return ui.text(.{}, ui.fmt("Version {d}", .{model.revision}));
}
fn statusParityItems(model: *const StatusParityModel, scratch: *StatusParityApp.StatusItemsScratch) []const StatusParityApp.StatusItemDescriptor {
    if (!model.present) return &.{};
    const title = std.fmt.bufPrint(&scratch.title_buffers[0], "Version {d}", .{model.revision}) catch unreachable;
    scratch.items[0] = .{ .id = 1, .label = title, .command = "app.bump" };
    scratch.status_items[0] = .{ .id = 0xffff_ffff, .state = .{ .title = title, .tooltip = title, .items = scratch.items[0..1] } };
    return scratch.status_items[0..1];
}
const StatusParityService = struct {
    var original: native_sdk.platform.PlatformServices = undefined;
    var counts = [_]usize{0} ** 5;
    var create_fails: bool = false;
    var remove_fails: bool = false;
    var patch_fails: bool = false;
    fn create(_: ?*anyopaque, id: u32, options: native_sdk.platform.TrayOptions) anyerror!void {
        counts[0] += 1;
        if (create_fails) return error.CreateFailed;
        try original.createStatusItem(id, options);
    }
    fn remove(_: ?*anyopaque, id: u32) anyerror!void {
        counts[1] += 1;
        if (remove_fails) return error.RemoveFailed;
        try original.removeStatusItem(id);
    }
    fn shell(_: ?*anyopaque, id: u32, options: native_sdk.platform.TrayShell) anyerror!void {
        counts[2] += 1;
        if (patch_fails) return error.UnsupportedService;
        try original.updateStatusItemShell(id, options);
    }
    fn presentation(_: ?*anyopaque, id: u32, options: native_sdk.platform.TrayPresentation) anyerror!void {
        counts[3] += 1;
        if (patch_fails) return error.UnsupportedService;
        try original.updateStatusItemPresentation(id, options);
    }
    fn menu(_: ?*anyopaque, id: u32, items: []const native_sdk.platform.TrayMenuItem) anyerror!void {
        counts[4] += 1;
        if (patch_fails) return error.UpdateFailed;
        try original.updateStatusItemMenu(id, items);
    }
};

test "compiled status reconciliation matches native OS failure ordering and retained ownership" {
    var reference: [5]usize = undefined;
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(640, 480) });
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        StatusParityService.original = harness.runtime.options.platform.services;
        StatusParityService.counts = @splat(0);
        StatusParityService.create_fails = true;
        StatusParityService.remove_fails = false;
        StatusParityService.patch_fails = false;
        harness.runtime.options.platform.services.create_tray_fn = StatusParityService.create;
        harness.runtime.options.platform.services.remove_tray_fn = StatusParityService.remove;
        harness.runtime.options.platform.services.update_tray_shell_fn = StatusParityService.shell;
        harness.runtime.options.platform.services.update_tray_presentation_fn = StatusParityService.presentation;
        harness.runtime.options.platform.services.update_tray_menu_fn = StatusParityService.menu;
        const state = try std.testing.allocator.create(StatusParityApp);
        defer std.testing.allocator.destroy(state);
        state.* = StatusParityApp.init(std.heap.page_allocator, .{}, .{
            .name = "status-parity",
            .scene = app_scene,
            .canvas_label = canvas_label,
            .view = statusParityView,
            .update = statusParityUpdate,
            .status_items_fn = statusParityItems,
            .status_policy = if (compiled) core.nativeStatusPolicy else null,
        });
        defer state.deinit();
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(640, 480),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        try std.testing.expectEqual(@as(usize, 0), state.applied_status_item_count);
        StatusParityService.create_fails = false;
        try state.dispatch(&harness.runtime, 1, .bump);
        try std.testing.expectEqual(@as(usize, 1), state.applied_status_item_count);
        try std.testing.expectEqualStrings("Version 1", harness.null_platform.statusItemTitle(0xffff_ffff));
        StatusParityService.patch_fails = true;
        try state.dispatch(&harness.runtime, 1, .bump);
        try std.testing.expect(state.applied_status_items[0].shell_unsupported and state.applied_status_items[0].presentation_unsupported);
        try state.dispatch(&harness.runtime, 1, .bump);
        try std.testing.expectEqual(@as(usize, 1), StatusParityService.counts[2]);
        try std.testing.expectEqual(@as(usize, 1), StatusParityService.counts[3]);
        try std.testing.expectEqual(@as(usize, 2), StatusParityService.counts[4]);
        // Hashes advance even when OS patches fail. An unchanged rebuild
        // must not retry the same menu; sticky capabilities stay suppressed.
        try state.dispatch(&harness.runtime, 1, .restore);
        try std.testing.expectEqual(@as(usize, 2), StatusParityService.counts[4]);
        try std.testing.expectEqualStrings("Version 1", harness.null_platform.statusItemMenu(0xffff_ffff)[0].label);
        StatusParityService.remove_fails = true;
        try state.dispatch(&harness.runtime, 1, .remove);
        try std.testing.expectEqual(@as(usize, 1), state.applied_status_item_count);
        StatusParityService.remove_fails = false;
        try state.dispatch(&harness.runtime, 1, .bump);
        try std.testing.expectEqual(@as(usize, 0), state.applied_status_item_count);
        StatusParityService.patch_fails = false;
        try state.dispatch(&harness.runtime, 1, .restore);
        try std.testing.expectEqualStrings("Version 4", harness.null_platform.statusItemTitle(0xffff_ffff));
        try std.testing.expectEqualStrings("Version 4", harness.null_platform.statusItemMenu(0xffff_ffff)[0].label);
        try std.testing.expect(!state.applied_status_items[0].shell_unsupported and !state.applied_status_items[0].presentation_unsupported);
        if (compiled) try std.testing.expectEqualSlices(usize, &reference, &StatusParityService.counts) else reference = StatusParityService.counts;
    }
}

test "compiled Tab traversal matches complete native retained targets" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "compiled-tab-focus", .source = native_sdk.WebViewSource.html("<h1>Focus</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    const identity_base: canvas.ObjectId = 0xfedc_ba98_7654_3200;
    var comparisons: usize = 0;
    for (0..128) |variant| {
        const inner_children = [_]canvas.Widget{
            .{ .id = identity_base + 6, .kind = .radio, .frame = geometry.RectF.init(8, 8, 100, 28), .value = if (variant & 1 != 0) 1 else 0, .state = .{ .disabled = variant & 2 != 0 } },
            .{ .id = identity_base + 7, .kind = .radio, .frame = geometry.RectF.init(8, 40, 100, 28), .value = if (variant & 1 == 0) 1 else 0 },
        };
        const group_children = [_]canvas.Widget{
            .{ .id = identity_base + 3, .kind = .radio, .frame = geometry.RectF.init(8, 8, 100, 28), .value = if (variant & 4 != 0) 1 else 0, .state = .{ .disabled = variant & 8 != 0 } },
            .{ .id = identity_base + 4, .kind = .button, .frame = geometry.RectF.init(120, 8, 100, 28), .semantics = .{ .hidden = variant & 16 != 0 } },
            .{ .id = identity_base + 5, .kind = .radio_group, .frame = geometry.RectF.init(8, 50, 220, 90), .children = &inner_children },
            .{ .id = identity_base + 8, .kind = .radio, .frame = geometry.RectF.init(if (variant & 32 != 0) @as(f32, 500) else 8, 150, 100, 28), .value = if (variant & 4 == 0) 1 else 0 },
        };
        const children = [_]canvas.Widget{
            .{ .id = identity_base + 1, .kind = .button, .frame = geometry.RectF.init(8, 8, 100, 28) },
            .{ .id = identity_base + 2, .kind = .radio_group, .frame = geometry.RectF.init(8, 50, 250, 210), .layout = .{ .clip_content = variant & 32 != 0 }, .children = &group_children },
            .{ .id = identity_base + 9, .kind = .button, .frame = geometry.RectF.init(8, 280, 100, 28), .state = .{ .disabled = variant & 64 != 0 } },
        };
        var nodes: [10]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = identity_base, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 640, 480), &nodes);
        if (variant & 32 != 0) {
            try std.testing.expect(layout.logicalFocusTargetAtIndex(8) != null);
            try std.testing.expect(layout.focusTargetById(identity_base + 8) == null);
        }
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        for (0..12) |current| {
            const id: ?canvas.ObjectId = if (current == 11) null else identity_base + current;
            for ([_]canvas.WidgetFocusDirection{ .forward, .backward }) |direction| {
                view.canvas_widget_tab_focus_policy = null;
                const expected = view.canvasWidgetRovingTabTarget(id, direction);
                view.canvas_widget_tab_focus_policy = core.nativeTabFocusPolicy;
                const actual = view.canvasWidgetRovingTabTarget(id, direction);
                try std.testing.expectEqualDeep(expected, actual);
                comparisons += 1;
            }
        }
    }
    // Interactive-surface wraps include the current target. With a single
    // radio composite, exhaustion returns its entry instead of escaping.
    for (0..4) |variant| {
        const radios = [_]canvas.Widget{
            .{ .id = identity_base + 3, .kind = .radio, .frame = geometry.RectF.init(8, 8, 100, 28) },
            .{ .id = identity_base + 4, .kind = .radio, .frame = geometry.RectF.init(8, 40, 100, 28), .value = 1 },
        };
        const group = [_]canvas.Widget{.{ .id = identity_base + 2, .kind = .radio_group, .frame = geometry.RectF.init(8, 8, 220, 110), .children = &radios }};
        const body = [_]canvas.Widget{
            .{ .id = identity_base + 1, .kind = if (variant & 1 != 0) .popover else .dropdown_menu, .frame = geometry.RectF.init(16, 16, 300, 200), .children = &group },
            .{ .id = identity_base + 5, .kind = .button, .frame = geometry.RectF.init(350, 20, 100, 28), .semantics = .{ .hidden = variant & 2 != 0 } },
        };
        var nodes: [6]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = identity_base, .kind = .stack, .children = &body }, geometry.RectF.init(0, 0, 640, 480), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        for (0..7) |current| for ([_]canvas.WidgetFocusDirection{ .forward, .backward }) |direction| {
            const id: ?canvas.ObjectId = if (current == 6) null else identity_base + current;
            view.canvas_widget_tab_focus_policy = null;
            const expected = view.canvasWidgetRovingTabTarget(id, direction);
            view.canvas_widget_tab_focus_policy = core.nativeTabFocusPolicy;
            try std.testing.expectEqualDeep(expected, view.canvasWidgetRovingTabTarget(id, direction));
            comparisons += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 3128), comparisons);
    // Removing the first view compacts the second retained view. Its
    // callback and complete copied targets must survive that ownership move.
    const expected = view.canvasWidgetRovingTabTarget(null, .forward);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.setCanvasWidgetLayout(1, "second", view.widgetLayoutTree());
    harness.runtime.views[1].canvas_widget_tab_focus_policy = core.nativeTabFocusPolicy;
    try harness.runtime.closeView(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expect(harness.runtime.views[0].canvas_widget_tab_focus_policy == core.nativeTabFocusPolicy);
    try std.testing.expectEqualDeep(expected, harness.runtime.views[0].canvasWidgetRovingTabTarget(null, .forward));
}

test "compiled focus return matches native anchors and nearest old-tree ancestry" {
    const Reference = struct {
        fn anchor(layout: canvas.WidgetLayoutTree, surface: usize) ?usize {
            if (surface >= layout.nodes.len or !canvas.widgetIsAnchored(layout.nodes[surface].widget)) return null;
            const parent = layout.nodes[surface].parent_index orelse return null;
            if (layout.focusTargetById(layout.nodes[parent].widget.id) != null) return parent;
            for (layout.nodes, 0..) |node, index| {
                if (node.parent_index == parent and index != surface and layout.focusTargetById(node.widget.id) != null) return index;
            }
            return null;
        }
        fn focused(layout: canvas.WidgetLayoutTree, subject: usize) ?usize {
            var current = layout.nodes[subject].parent_index;
            while (current) |index| {
                const widget = layout.nodes[index].widget;
                if (canvas.widgetIsAnchored(widget) and canvas.widgetKindDismissibleSurface(widget.kind)) return anchor(layout, index);
                current = layout.nodes[index].parent_index;
            }
            return null;
        }
    };
    const kinds = [_]canvas.WidgetKind{ .stack, .button, .popover, .dropdown_menu, .tooltip, .dialog, .menu_item };
    var comparisons: usize = 0;
    for (0..64) |variant| {
        core.rt.frameReset();
        var nodes: [32]canvas.WidgetLayoutNode = undefined;
        for (&nodes, 0..) |*node, index| {
            const parent: ?usize = if (index == 0) null else (variant * 5 + index * 3) % index;
            const frame = geometry.RectF.init(if ((index + variant) % 7 == 0) 900 else 0, 0, 100, 28);
            node.* = .{ .widget = .{
                .id = 0xfedc_ba98_7654_3200 + index,
                .kind = kinds[(variant + index * 3) % kinds.len],
                .frame = frame,
                .state = .{ .disabled = (variant + index) % 5 == 0 },
                .semantics = .{ .hidden = (variant + index) % 11 == 0, .focusable = (variant + index) % 3 == 0 },
                .layout = .{ .anchor = if ((variant + index) % 3 == 0) null else .{ .placement = .below } },
            }, .frame = frame, .parent_index = parent, .depth = if (parent) |p| nodes[p].depth + 1 else 0 };
        }
        const layout = canvas.WidgetLayoutTree{ .nodes = &nodes, .root_bounds = geometry.RectF.init(0, 0, 640, 480) };
        var request: [6 + nodes.len * 3]u8 = undefined;
        request[0] = 22;
        std.mem.writeInt(u16, request[2..4], nodes.len, .little);
        for (nodes, 0..) |node, index| {
            const at = 6 + index * 3;
            request[at] = @as(u8, @intFromBool(layout.focusTargetById(node.widget.id) != null)) |
                (@as(u8, @intFromBool(canvas.widgetIsAnchored(node.widget))) << 1) |
                (@as(u8, @intFromBool(canvas.widgetKindDismissibleSurface(node.widget.kind))) << 2);
            std.mem.writeInt(u16, request[at + 1 ..][0..2], if (node.parent_index) |p| @intCast(p) else std.math.maxInt(u16), .little);
        }
        for (0..nodes.len) |subject| {
            std.mem.writeInt(u16, request[4..6], @intCast(subject), .little);
            for (0..2) |mode| {
                request[1] = @intCast(mode);
                const expected = if (mode == 0) Reference.anchor(layout, subject) else Reference.focused(layout, subject);
                var output: [2]u8 = undefined;
                try std.testing.expectEqual(output.len, core.nativeFocusReturnPolicy(&request, &output));
                try std.testing.expectEqual(if (expected) |index| @as(u16, @intCast(index)) else std.math.maxInt(u16), std.mem.readInt(u16, &output, .little));
                comparisons += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4096), comparisons);
}

test "compiled focus return preserves retained dismissal, unmount and compaction" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const CountPolicy = struct {
        var calls: usize = 0;
        var mode: u8 = 255;
        fn run(request: []const u8, output: []u8) usize {
            calls += 1;
            mode = request[1];
            return core.nativeFocusReturnPolicy(request, output);
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "focus-return-parity", .source = native_sdk.WebViewSource.html("<h1>Focus</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    const item_id: canvas.ObjectId = 0xffff_ffff_ffff_ff04;
    for (0..32) |variant| {
        core.rt.frameReset();
        const content = [_]canvas.Widget{.{ .id = item_id, .kind = .menu_item, .frame = geometry.RectF.init(8, 8, 100, 28) }};
        const children = [_]canvas.Widget{
            .{ .id = 0xffff_ffff_ffff_ff02, .kind = .button, .frame = geometry.RectF.init(8, 8, 100, 28), .state = .{ .disabled = variant & 1 != 0 } },
            .{ .id = 0xffff_ffff_ffff_ff03, .kind = .dropdown_menu, .layout = .{ .anchor = .{ .placement = .below } }, .frame = geometry.RectF.init(8, 40, 220, 100), .children = &content },
            .{ .id = 0xffff_ffff_ffff_ff05, .kind = .button, .frame = geometry.RectF.init(300, 8, 100, 28), .semantics = .{ .hidden = variant & 4 != 0 }, .state = .{ .disabled = variant & 8 != 0 } },
        };
        const body = [_]canvas.Widget{.{ .id = 0xffff_ffff_ffff_ff01, .kind = .stack, .frame = geometry.RectF.init(0, 0, 640, 480), .semantics = .{ .focusable = variant & 2 != 0, .hidden = variant & 16 != 0 }, .children = &children }};
        var nodes: [6]canvas.WidgetLayoutNode = undefined;
        const root = canvas.Widget{ .id = 0xffff_ffff_ffff_ff00, .kind = .stack, .children = &body };
        const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 640, 480), &nodes);
        view.canvas_widget_focused_id = 0;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        for (0..7) |surface| {
            view.canvas_widget_focus_return_policy = null;
            const expected = view.canvasWidgetAnchorTriggerFocusId(surface);
            view.canvas_widget_focus_return_policy = CountPolicy.run;
            try std.testing.expectEqual(expected, view.canvasWidgetAnchorTriggerFocusId(surface));
        }
        // Raw retained queries preserve first-match ID facts even when
        // an alias is present. Adoption independently rejects duplicates.
        const alias_index = view.canvasWidgetNodeIndexById(children[2].id).?;
        view.widget_layout_nodes[alias_index].widget.id = children[0].id;
        for (0..7) |surface| {
            view.canvas_widget_focus_return_policy = null;
            const expected = view.canvasWidgetAnchorTriggerFocusId(surface);
            view.canvas_widget_focus_return_policy = CountPolicy.run;
            try std.testing.expectEqual(expected, view.canvasWidgetAnchorTriggerFocusId(surface));
        }
        view.widget_layout_nodes[alias_index].widget.id = children[2].id;
        view.canvas_widget_focus_return_policy = null;
        const surface_index = view.canvasWidgetNodeIndexById(children[1].id).?;
        const expected = view.canvasWidgetAnchorTriggerFocusId(surface_index) orelse 0;
        // Explicit dismissal uses the copied return index, preserving full IDs.
        view.canvas_widget_focus_return_policy = CountPolicy.run;
        view.canvas_widget_focused_id = item_id;
        view.canvas_widget_focus_visible_id = item_id;
        CountPolicy.calls = 0;
        const visible = !view.widget_layout_nodes[surface_index].widget.semantics.hidden;
        _ = try view.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        const dismissed_focus = if (visible) expected else item_id;
        try std.testing.expectEqual(dismissed_focus, view.canvas_widget_focused_id);
        try std.testing.expectEqual(dismissed_focus, view.canvas_widget_focus_visible_id);
        try std.testing.expect(!view.canvas_widget_focus_visible_keyboard);
        try std.testing.expectEqual(@as(usize, @intFromBool(visible)), CountPolicy.calls);
        if (visible) try std.testing.expectEqual(@as(u8, 0), CountPolicy.mode);
        // Unmount capture walks the old tree before adoption, then revalidates.
        view.canvas_widget_focused_id = 0;
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        view.canvas_widget_focused_id = item_id;
        view.canvas_widget_focus_visible_id = item_id;
        CountPolicy.calls = 0;
        const remaining = [_]canvas.Widget{ children[0], children[2] };
        const closed_body = [_]canvas.Widget{.{ .id = body[0].id, .kind = .stack, .frame = body[0].frame, .semantics = body[0].semantics, .children = &remaining }};
        const closed_layout = try canvas.layoutWidgetTree(.{ .id = root.id, .kind = .stack, .children = &closed_body }, layout.root_bounds.?, &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", closed_layout);
        try std.testing.expectEqual(expected, view.canvas_widget_focused_id);
        try std.testing.expectEqual(expected, view.canvas_widget_focus_visible_id);
        try std.testing.expect(!view.canvas_widget_focus_visible_keyboard);
        try std.testing.expectEqual(@as(usize, 1), CountPolicy.calls);
        try std.testing.expectEqual(@as(u8, 1), CountPolicy.mode);
    }
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.setCanvasWidgetLayout(1, "second", view.widgetLayoutTree());
    harness.runtime.views[1].canvas_widget_focus_return_policy = core.nativeFocusReturnPolicy;
    try harness.runtime.closeView(1, "canvas");
    try std.testing.expect(harness.runtime.views[0].canvas_widget_focus_return_policy == core.nativeFocusReturnPolicy);
}

test "compiled focus return accepts full capacity and preserves borrowed cycle bytes" {
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    const capacity = native_sdk.runtime.max_canvas_widget_nodes_per_view;
    var request: [6 + capacity * 3]u8 = undefined;
    request[0] = 22;
    request[1] = 1;
    std.mem.writeInt(u16, request[2..4], capacity, .little);
    std.mem.writeInt(u16, request[4..6], capacity - 1, .little);
    for (0..capacity) |index| {
        const at = 6 + index * 3;
        request[at] = if (index == 0) 1 else 6;
        std.mem.writeInt(u16, request[at + 1 ..][0..2], if (index == 0) std.math.maxInt(u16) else @intCast(index - 1), .little);
    }
    var output: [2]u8 = undefined;
    try std.testing.expectEqual(output.len, core.nativeFocusReturnPolicy(&request, &output));
    try std.testing.expectEqual(std.math.maxInt(u16), std.mem.readInt(u16, &output, .little));
    std.mem.writeInt(u16, request[4..6], 2, .little);
    for (0..16) |_| {
        try std.testing.expectEqual(output.len, core.nativeFocusReturnPolicy(&request, &output));
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, &output, .little));
        try std.testing.expectEqualSlices(u8, copy, borrowed);
    }
    core.rt.frameReset();
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, &output, .little));
    try std.testing.expectEqual(output.len, core.nativeFocusReturnPolicy(&.{ 22, 0, 0, 0, 255, 255 }, &output));
    try std.testing.expectEqual(std.math.maxInt(u16), std.mem.readInt(u16, &output, .little));
    core.rt.frameReset();
}

test "compiled surface plans match native walks over exact retained paint facts" {
    const Reference = struct {
        fn inScope(kind: canvas.WidgetKind, scope: u8) bool {
            if (!canvas.widgetKindDismissibleSurface(kind)) return false;
            return scope == 0 or (scope == 1 and kind != .tooltip) or (scope == 2 and (kind == .menu_surface or kind == .dropdown_menu));
        }
        fn child(layout: canvas.WidgetLayoutTree, anchor: usize, scope: u8) ?usize {
            var winner: ?usize = null;
            for (layout.nodes, 0..) |node, index| {
                if (node.parent_index != anchor or !canvas.widgetIsAnchored(node.widget) or node.widget.semantics.hidden or !inScope(node.widget.kind, scope)) continue;
                if (winner == null or canvas.widgetPaintOrderLess(
                    canvas.widgetLayoutWindowSurfaceOrder(layout, winner.?, .{}),
                    canvas.widgetLayoutWindowSurfaceOrder(layout, index, .{}),
                )) winner = index;
            }
            return winner;
        }
        fn target(layout: canvas.WidgetLayoutTree, index: usize, scope: u8) ?usize {
            var cursor: ?usize = index;
            while (cursor) |at| {
                const widget = layout.nodes[at].widget;
                if (canvas.widgetKindDismissibleSurface(widget.kind) and !widget.semantics.hidden)
                    return if (inScope(widget.kind, scope)) at else null;
                if (child(layout, at, scope)) |found| return found;
                cursor = layout.nodes[at].parent_index;
            }
            return null;
        }
        fn topmost(layout: canvas.WidgetLayoutTree, scope: u8) ?usize {
            var winner: ?usize = null;
            for (layout.nodes, 0..) |node, index| {
                if (!canvas.widgetIsAnchored(node.widget) or !inScope(node.widget.kind, scope)) continue;
                var cursor: ?usize = index;
                var hidden = false;
                while (cursor) |at| {
                    if (layout.nodes[at].widget.semantics.hidden) {
                        hidden = true;
                        break;
                    }
                    cursor = layout.nodes[at].parent_index;
                }
                if (hidden) continue;
                if (winner == null or canvas.widgetPaintOrderLess(
                    canvas.widgetLayoutWindowSurfaceOrder(layout, winner.?, .{}),
                    canvas.widgetLayoutWindowSurfaceOrder(layout, index, .{}),
                )) winner = index;
            }
            return winner;
        }
        fn owned(layout: canvas.WidgetLayoutTree, index: usize) ?usize {
            if (child(layout, index, 2)) |found| return found;
            const parent = layout.nodes[index].parent_index orelse return null;
            const found = child(layout, parent, 2) orelse return null;
            return if (found == index) null else found;
        }
        fn expectIndex(expected: ?usize, bytes: []const u8, at: usize) !void {
            const value = std.mem.readInt(u16, bytes[at..][0..2], .little);
            try std.testing.expectEqual(if (expected) |index| @as(u16, @intCast(index)) else std.math.maxInt(u16), value);
        }
    };
    const kinds = [_]canvas.WidgetKind{ .stack, .button, .popover, .menu_surface, .dropdown_menu, .tooltip, .dialog, .drawer, .sheet };
    const layers = [_]?i32{ null, 0, -1, 1, std.math.minInt(i32), std.math.maxInt(i32) };
    var comparisons: usize = 0;
    for (0..96) |variant| {
        core.rt.frameReset();
        var nodes: [32]canvas.WidgetLayoutNode = undefined;
        for (&nodes, 0..) |*node, index| {
            const parent: ?usize = if (index == 0) null else (variant * 5 + index * 3) % index;
            const frame = geometry.RectF.init(0, 0, 100, 28);
            node.* = .{ .widget = .{
                .id = 0xfedc_ba98_7654_3200 + index,
                .kind = kinds[(variant + index * 7) % kinds.len],
                .frame = frame,
                .layer = layers[(variant * 3 + index) % layers.len],
                .semantics = .{ .hidden = (variant + index) % 7 == 0 },
                .layout = .{ .anchor = if ((variant + index) % 3 == 0) null else .{ .placement = .below } },
            }, .frame = frame, .parent_index = parent, .depth = if (parent) |p| nodes[p].depth + 1 else 0 };
        }
        const layout = canvas.WidgetLayoutTree{ .nodes = &nodes, .root_bounds = geometry.RectF.init(0, 0, 640, 480) };
        for (0..3) |scope| {
            var request: [4 + nodes.len * 7]u8 = undefined;
            request[0] = 21;
            request[1] = @intCast(scope);
            std.mem.writeInt(u16, request[2..4], nodes.len, .little);
            for (nodes, 0..) |node, index| {
                const at = 4 + index * 7;
                const kind: u8 = if (!canvas.widgetKindDismissibleSurface(node.widget.kind)) 0 else switch (node.widget.kind) {
                    .tooltip => 3,
                    .menu_surface, .dropdown_menu => 2,
                    else => 1,
                };
                request[at] = kind | (@as(u8, @intFromBool(node.widget.semantics.hidden)) << 2) | (@as(u8, @intFromBool(canvas.widgetIsAnchored(node.widget))) << 3);
                std.mem.writeInt(u16, request[at + 1 ..][0..2], if (node.parent_index) |p| @intCast(p) else std.math.maxInt(u16), .little);
                std.mem.writeInt(i32, request[at + 3 ..][0..4], canvas.widgetLayoutWindowSurfaceOrder(layout, index, .{}).layer, .little);
            }
            var output: [2 + nodes.len * 6]u8 = undefined;
            try std.testing.expectEqual(output.len, core.nativeSurfaceScopePolicy(&request, &output));
            try Reference.expectIndex(Reference.topmost(layout, @intCast(scope)), &output, 0);
            comparisons += 1;
            for (0..nodes.len) |index| {
                try Reference.expectIndex(Reference.child(layout, index, @intCast(scope)), &output, 2 + index * 6);
                try Reference.expectIndex(Reference.target(layout, index, @intCast(scope)), &output, 2 + index * 6 + 2);
                try Reference.expectIndex(if (scope == 2) Reference.owned(layout, index) else null, &output, 2 + index * 6 + 4);
                comparisons += 3;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 27936), comparisons);
}

test "compiled surface callbacks preserve retained consumers, compaction and single Tab batch" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const CountPolicy = struct {
        var calls: usize = 0;
        fn run(request: []const u8, output: []u8) usize {
            calls += 1;
            return core.nativeSurfaceScopePolicy(request, output);
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "surface-policy-parity", .source = native_sdk.WebViewSource.html("<h1>Surfaces</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    for (0..32) |variant| {
        core.rt.frameReset();
        const content = [_]canvas.Widget{
            .{ .id = 0xffff_ffff_ffff_ff03, .kind = .button, .frame = geometry.RectF.init(8, 8, 100, 28) },
            .{ .id = 0xffff_ffff_ffff_ff04, .kind = .button, .frame = geometry.RectF.init(8, 48, 100, 28), .state = .{ .disabled = variant & 1 != 0 } },
        };
        const body = [_]canvas.Widget{
            .{ .id = 0xffff_ffff_ffff_ff01, .kind = .button, .frame = geometry.RectF.init(8, 8, 100, 28) },
            .{ .id = 0xffff_ffff_ffff_ff02, .kind = if (variant & 2 != 0) .popover else .dropdown_menu, .layout = .{ .anchor = .{ .placement = .below } }, .frame = geometry.RectF.init(16, 16, 220, 180), .children = &content },
            .{ .id = 0xffff_ffff_ffff_ff05, .kind = .tooltip, .layout = .{ .anchor = .{ .placement = .below } }, .frame = geometry.RectF.init(16, 16, 100, 28), .layer = if (variant & 4 != 0) -100 else 500 },
            .{ .id = 0xffff_ffff_ffff_ff06, .kind = .button, .frame = geometry.RectF.init(400, 20, 100, 28) },
        };
        var nodes: [7]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .id = 0xffff_ffff_ffff_ff00, .kind = .stack, .children = &body, .semantics = .{ .hidden = variant & 8 != 0 } }, geometry.RectF.init(0, 0, 640, 480), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        // Visibility stamping is a native tooltip capability. Compare
        // these exact retained facts, including a visible tooltip sibling.
        view.widget_layout_nodes[5].widget.semantics.hidden = variant & 16 != 0;
        for (0..8) |index| {
            view.canvas_widget_surface_scope_policy = null;
            const child = view.canvasWidgetAnchoredDismissibleChildIndex(index);
            const target = view.canvasWidgetDismissibleSurfaceIndexForTarget(index);
            const owned = view.canvasWidgetOwnedMenuSurfaceIndex(index);
            const topmost = view.canvasWidgetTopmostAnchoredDismissibleIndex();
            view.canvas_widget_surface_scope_policy = CountPolicy.run;
            try std.testing.expectEqual(child, view.canvasWidgetAnchoredDismissibleChildIndex(index));
            try std.testing.expectEqual(target, view.canvasWidgetDismissibleSurfaceIndexForTarget(index));
            try std.testing.expectEqual(owned, view.canvasWidgetOwnedMenuSurfaceIndex(index));
            try std.testing.expectEqual(topmost, view.canvasWidgetTopmostAnchoredDismissibleIndex());
            const id: ?canvas.ObjectId = if (index == 7) null else 0xffff_ffff_ffff_ff00 + index;
            for ([_]canvas.WidgetFocusDirection{ .forward, .backward }) |direction| {
                view.canvas_widget_surface_scope_policy = null;
                view.canvas_widget_tab_focus_policy = null;
                const expected = view.canvasWidgetRovingTabTarget(id, direction);
                view.canvas_widget_surface_scope_policy = CountPolicy.run;
                view.canvas_widget_tab_focus_policy = core.nativeTabFocusPolicy;
                CountPolicy.calls = 0;
                try std.testing.expectEqualDeep(expected, view.canvasWidgetRovingTabTarget(id, direction));
                try std.testing.expectEqual(@as(usize, 1), CountPolicy.calls);
            }
        }
    }
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.setCanvasWidgetLayout(1, "second", view.widgetLayoutTree());
    harness.runtime.views[1].canvas_widget_surface_scope_policy = core.nativeSurfaceScopePolicy;
    const expected = harness.runtime.views[1].canvasWidgetTopmostAnchoredDismissibleIndex();
    try harness.runtime.closeView(1, "canvas");
    try std.testing.expect(harness.runtime.views[0].canvas_widget_surface_scope_policy == core.nativeSurfaceScopePolicy);
    try std.testing.expectEqual(expected, harness.runtime.views[0].canvasWidgetTopmostAnchoredDismissibleIndex());
}

test "compiled surface plans accept the complete retained capacity and empty trees" {
    const capacity = native_sdk.runtime.max_canvas_widget_nodes_per_view;
    var request: [4 + capacity * 7]u8 = undefined;
    request[0] = 21;
    request[1] = 2;
    std.mem.writeInt(u16, request[2..4], capacity, .little);
    for (0..capacity) |index| {
        const at = 4 + index * 7;
        request[at] = if (index == 0) 0 else 10;
        std.mem.writeInt(u16, request[at + 1 ..][0..2], if (index == 0) std.math.maxInt(u16) else @intCast(index - 1), .little);
        std.mem.writeInt(i32, request[at + 3 ..][0..4], @intCast(index), .little);
    }
    var output: [2 + capacity * 6]u8 = undefined;
    try std.testing.expectEqual(output.len, core.nativeSurfaceScopePolicy(&request, &output));
    try std.testing.expectEqual(@as(u16, capacity - 1), std.mem.readInt(u16, output[0..2], .little));
    for (0..capacity) |index| {
        const at = 2 + index * 6;
        const child: u16 = if (index + 1 < capacity) @intCast(index + 1) else std.math.maxInt(u16);
        try std.testing.expectEqual(child, std.mem.readInt(u16, output[at..][0..2], .little));
        try std.testing.expectEqual(if (index == 0) @as(u16, 1) else @as(u16, @intCast(index)), std.mem.readInt(u16, output[at + 2 ..][0..2], .little));
        try std.testing.expectEqual(child, std.mem.readInt(u16, output[at + 4 ..][0..2], .little));
    }
    core.rt.frameReset();
    var empty: [2]u8 = undefined;
    try std.testing.expectEqual(empty.len, core.nativeSurfaceScopePolicy(&.{ 21, 0, 0, 0 }, &empty));
    try std.testing.expectEqual(std.math.maxInt(u16), std.mem.readInt(u16, &empty, .little));
    core.rt.frameReset();
}

test "compiled surface plans preserve borrowed cycle commands and copied results" {
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    const request = [_]u8{ 21, 2, 2, 0, 0, 255, 255, 0, 0, 0, 0, 10, 0, 0, 255, 255, 255, 127 };
    var output: [14]u8 = undefined;
    for (0..16) |_| {
        try std.testing.expectEqual(output.len, core.nativeSurfaceScopePolicy(&request, &output));
        try std.testing.expectEqualSlices(u8, copy, borrowed);
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, output[0..2], .little));
    }
    core.rt.frameReset();
    _ = core.initialModel();
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, output[0..2], .little));
}

test "compiled Tab plans preserve dispatch arena ownership and copied results" {
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    var output: [2]u8 = undefined;
    const request = [_]u8{ 20, 0, 1, 0, 255, 255, 3, 0, 0, 255, 255, 255, 255 };
    for (0..16) |_| {
        try std.testing.expectEqual(output.len, core.nativeTabFocusPolicy(&request, &output));
        try std.testing.expectEqualSlices(u8, copy, borrowed);
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, &output, .little));
    }
    core.rt.frameReset();
    _ = core.initialModel();
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, &output, .little));
}

test "compiled tooltip ownership and live binding match native retained facts" {
    const Reference = struct {
        fn child(nodes: []const canvas.WidgetLayoutNode, owner: usize) ?usize {
            var found: ?usize = null;
            for (nodes, 0..) |node, index| if (node.parent_index == owner and node.widget.kind == .tooltip and canvas.widgetIsAnchored(node.widget)) {
                found = index;
            };
            return found;
        }
        fn owned(nodes: []const canvas.WidgetLayoutNode, owner: usize) ?usize {
            if (child(nodes, owner)) |index| return index;
            return if (nodes[owner].parent_index) |parent| child(nodes, parent) else null;
        }
    };
    const kinds = [_]canvas.WidgetKind{ .stack, .button, .tooltip, .popover, .text_field };
    var comparisons: usize = 0;
    for (0..64) |variant| {
        var nodes: [32]canvas.WidgetLayoutNode = undefined;
        for (&nodes, 0..) |*node, index| {
            const parent: ?usize = if (index == 0) null else (variant * 5 + index * 3) % index;
            const frame = geometry.RectF.init(if ((variant + index) % 7 == 0) 900 else 0, 0, 100, 28);
            node.* = .{ .widget = .{
                .id = 0xfedc_ba98_7654_3200 + index,
                .kind = kinds[(variant + index * 3) % kinds.len],
                .frame = frame,
                .state = .{ .disabled = (variant + index) % 5 == 0 },
                .semantics = .{ .hidden = (variant + index) % 11 == 0, .focusable = (variant + index) % 3 == 0 },
                .layout = .{ .anchor = if ((variant + index) % 3 == 0) null else .{ .placement = .below } },
            }, .frame = frame, .parent_index = parent, .depth = if (parent) |p| nodes[p].depth + 1 else 0 };
        }
        var request: [9 + nodes.len * 3]u8 = undefined;
        request[0] = 23;
        std.mem.writeInt(u16, request[2..4], nodes.len, .little);
        for (nodes, 0..) |node, index| {
            const at = 9 + index * 3;
            request[at] = @intFromBool(node.widget.kind == .tooltip and canvas.widgetIsAnchored(node.widget));
            std.mem.writeInt(u16, request[at + 1 ..][0..2], if (node.parent_index) |p| @intCast(p) else 65535, .little);
        }
        for (0..nodes.len) |owner| {
            core.rt.frameReset();
            std.mem.writeInt(u16, request[4..6], @intCast(owner), .little);
            const owned = Reference.owned(&nodes, owner);
            const eligible: u8 = @intCast((variant + owner) % 4);
            for (0..3) |mode| {
                request[1] = @intCast(mode);
                request[8] = eligible;
                const tooltip: usize = if (mode == 2) (owner + variant) % nodes.len else owned orelse 0;
                std.mem.writeInt(u16, request[6..8], @intCast(tooltip), .little);
                const live = nodes[tooltip].widget.kind == .tooltip and canvas.widgetIsAnchored(nodes[tooltip].widget) and owned == tooltip and
                    (eligible & (if (mode == 1) @as(u8, 1) else 2)) != 0;
                const expected: u16 = if (mode == 0) (if (owned) |index| @intCast(index) else 65535) else if (live) @intCast(tooltip) else 65535;
                var output: [2]u8 = undefined;
                try std.testing.expectEqual(output.len, core.nativeTooltipPolicy(&request, &output));
                try std.testing.expectEqual(expected, std.mem.readInt(u16, &output, .little));
                comparisons += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 6144), comparisons);
    core.rt.frameReset();
}

test "compiled tooltip binding preserves prospective pruning and full-width alias ownership" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const State = struct {
        armed: canvas.ObjectId,
        armed_owner: canvas.ObjectId,
        deadline: u64,
        shown: canvas.ObjectId,
        shown_owner: canvas.ObjectId,
        from_focus: bool,
        warm: u64,
        transit: u64,
        fn read(v: anytype) @This() {
            return .{ .armed = v.canvas_tooltip_armed_id, .armed_owner = v.canvas_tooltip_armed_owner_id, .deadline = v.canvas_tooltip_deadline_ns, .shown = v.canvas_tooltip_shown_id, .shown_owner = v.canvas_tooltip_shown_owner_id, .from_focus = v.canvas_tooltip_shown_from_focus, .warm = v.canvas_tooltip_warm_until_ns, .transit = v.canvas_tooltip_transit_deadline_ns };
        }
        fn write(s: @This(), v: anytype) void {
            v.canvas_tooltip_armed_id = s.armed;
            v.canvas_tooltip_armed_owner_id = s.armed_owner;
            v.canvas_tooltip_deadline_ns = s.deadline;
            v.canvas_tooltip_shown_id = s.shown;
            v.canvas_tooltip_shown_owner_id = s.shown_owner;
            v.canvas_tooltip_shown_from_focus = s.from_focus;
            v.canvas_tooltip_warm_until_ns = s.warm;
            v.canvas_tooltip_transit_deadline_ns = s.transit;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "tooltip-parity", .source = native_sdk.WebViewSource.html("<h1>Tooltip</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    var comparisons: usize = 0;
    for (0..64) |variant| {
        core.rt.frameReset();
        var nodes: [16]canvas.WidgetLayoutNode = undefined;
        for (&nodes, 0..) |*node, index| {
            const parent: ?usize = if (index == 0) null else (index + variant * 7) % index;
            const frame = geometry.RectF.init(if ((index + variant) % 9 == 0) 900 else 0, 0, 100, 28);
            node.* = .{ .widget = .{
                .id = if (variant & 1 != 0) (if (index == 0) 0 else 0xffff_ffff_ffff_ff00 + index % 4) else 0xffff_ffff_ffff_ff00 + index,
                .kind = if ((index + variant) % 3 == 0) .tooltip else .button,
                .frame = frame,
                .state = .{ .disabled = (index + variant) % 5 == 0 },
                .semantics = .{ .hidden = (index + variant) % 7 == 0 },
                .layout = .{ .anchor = if ((index + variant) % 4 == 0) null else .{ .placement = .above } },
            }, .frame = frame, .parent_index = parent, .depth = if (parent) |p| nodes[p].depth + 1 else 0 };
        }
        @memcpy(view.widget_layout_nodes[0..nodes.len], &nodes);
        view.widget_layout_node_count = nodes.len;
        view.widget_layout_root_bounds = geometry.RectF.init(0, 0, 640, 480);
        const layout = view.widgetLayoutTree();
        for (0..nodes.len) |owner| {
            view.canvas_widget_tooltip_policy = null;
            const expected = view.canvasWidgetOwnedTooltipIndex(owner);
            const expected_id = view.canvasWidgetOwnedTooltipIdForOwner(nodes[owner].widget.id);
            view.canvas_widget_tooltip_policy = core.nativeTooltipPolicy;
            try std.testing.expectEqual(expected, view.canvasWidgetOwnedTooltipIndex(owner));
            try std.testing.expectEqual(expected_id, view.canvasWidgetOwnedTooltipIdForOwner(nodes[owner].widget.id));
            comparisons += 2;
            const seed = State{ .armed = if (expected) |t| nodes[t].widget.id else 0xffff_ffff_ffff_ffff, .armed_owner = nodes[owner].widget.id, .deadline = 100, .shown = nodes[(owner + variant) % nodes.len].widget.id, .shown_owner = nodes[owner].widget.id, .from_focus = variant & 2 != 0, .warm = 200, .transit = 300 };
            seed.write(view);
            view.canvas_widget_tooltip_policy = null;
            const surviving = view.canvasTooltipShownIdSurvivingLayout(layout);
            try std.testing.expectEqualDeep(seed, State.read(view)); // Prospective verdict is read-only.
            view.pruneCanvasTooltipIntentForLayout(layout);
            const pruned = State.read(view);
            seed.write(view);
            view.canvas_widget_tooltip_policy = core.nativeTooltipPolicy;
            try std.testing.expectEqual(surviving, view.canvasTooltipShownIdSurvivingLayout(layout));
            try std.testing.expectEqualDeep(seed, State.read(view));
            view.pruneCanvasTooltipIntentForLayout(layout);
            try std.testing.expectEqualDeep(pruned, State.read(view));
            comparisons += 2;
        }
    }
    try std.testing.expectEqual(@as(usize, 4096), comparisons);
    view.widget_layout_node_count = 0;
    view.canvas_widget_tooltip_policy = core.nativeTooltipPolicy;
    try std.testing.expectEqual(@as(?usize, null), view.canvasWidgetOwnedTooltipIndex(0));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvasWidgetOwnedTooltipIdForOwner(0));
    core.rt.frameReset();
}

test "compiled tooltip policy copies maximum-capacity results without resetting borrowed frames" {
    core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    const capacity = runtime_ns.max_canvas_widget_nodes_per_view;
    var request: [9 + capacity * 3]u8 = undefined;
    request[0..9].* = .{ 23, 0, 0, 4, 1, 0, 255, 255, 0 };
    for (0..capacity) |index| {
        const at = 9 + index * 3;
        request[at] = @intFromBool(index == capacity - 1);
        std.mem.writeInt(u16, request[at + 1 ..][0..2], if (index == 0) 65535 else 0, .little);
    }
    var output: [2]u8 = undefined;
    for (0..16) |_| {
        try std.testing.expectEqual(output.len, core.nativeTooltipPolicy(&request, &output));
        try std.testing.expectEqual(@as(u16, capacity - 1), std.mem.readInt(u16, &output, .little));
        try std.testing.expectEqualSlices(u8, copy, borrowed);
    }
    core.rt.frameReset();
    try std.testing.expectEqual(@as(u16, capacity - 1), std.mem.readInt(u16, &output, .little));
    try std.testing.expectEqual(output.len, core.nativeTooltipPolicy(&.{ 23, 0, 0, 0, 255, 255, 255, 255, 0 }, &output));
    try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, &output, .little));
    core.rt.frameReset();
}

test "compiled tooltip pruning stays transactional on rejected adoption and follows view compaction" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "tooltip-adoption", .source = native_sdk.WebViewSource.html("<h1>Tooltip</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    view.canvas_widget_tooltip_policy = core.nativeTooltipPolicy;
    const owner_id: canvas.ObjectId = 0xffff_ffff_ffff_ff02;
    const tooltip_id: canvas.ObjectId = 0xffff_ffff_ffff_ff03;
    const children = [_]canvas.Widget{
        .{ .id = owner_id, .kind = .button, .text = "Run", .frame = geometry.RectF.init(40, 60, 96, 32) },
        .{ .id = tooltip_id, .kind = .tooltip, .text = "Run café", .layout = .{ .anchor = .{ .placement = .above } } },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 0xffff_ffff_ffff_ff01, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 640, 480), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    view.canvas_tooltip_shown_id = tooltip_id;
    view.canvas_tooltip_shown_owner_id = owner_id;
    view.canvas_tooltip_shown_from_focus = true;
    view.applyCanvasTooltipVisibility();
    const index = view.canvasWidgetOwnedTooltipIndex(1).?;
    try std.testing.expect(!view.widget_layout_nodes[index].widget.semantics.hidden);
    // Seventeen anchored surfaces exceed the retained per-view budget of sixteen.
    var overflow: [17]canvas.Widget = undefined;
    for (&overflow, 0..) |*widget, i| widget.* = .{ .id = 100 + i, .kind = .tooltip, .text = "Overflow", .layout = .{ .anchor = .{ .placement = .above } } };
    var overflow_nodes: [overflow.len + 1]canvas.WidgetLayoutNode = undefined;
    const rejected = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &overflow }, geometry.RectF.init(0, 0, 640, 480), &overflow_nodes);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvasTooltipShownIdSurvivingLayout(rejected));
    try std.testing.expectError(error.WidgetAnchoredSurfaceLimitReached, harness.runtime.setCanvasWidgetLayout(1, "canvas", rejected));
    try std.testing.expectEqual(tooltip_id, view.canvas_tooltip_shown_id);
    try std.testing.expectEqual(owner_id, view.canvas_tooltip_shown_owner_id);
    try std.testing.expect(!view.widget_layout_nodes[index].widget.semantics.hidden);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.setCanvasWidgetLayout(1, "second", view.widgetLayoutTree());
    harness.runtime.views[1].canvas_widget_tooltip_policy = core.nativeTooltipPolicy;
    try harness.runtime.closeView(1, "canvas");
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    const moved = &harness.runtime.views[0];
    try std.testing.expect(moved.canvas_widget_tooltip_policy == core.nativeTooltipPolicy);
    try std.testing.expectEqual(tooltip_id, moved.canvasWidgetOwnedTooltipIdForOwner(owner_id));
    moved.canvas_tooltip_shown_id = tooltip_id;
    moved.canvas_tooltip_shown_owner_id = owner_id;
    moved.pruneCanvasTooltipIntent();
    try std.testing.expectEqual(tooltip_id, moved.canvas_tooltip_shown_id);
    core.rt.frameReset();
}

test "compiled tooltip intent matches native event seams and all retained registers" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const State = struct {
        armed: canvas.ObjectId,
        armed_owner: canvas.ObjectId,
        deadline: u64,
        shown: canvas.ObjectId,
        shown_owner: canvas.ObjectId,
        from_focus: bool,
        warm: u64,
        transit: u64,
        focus: canvas.ObjectId,
        keyboard: bool,
        revision: u64,
        fn read(v: anytype) @This() {
            return .{ .armed = v.canvas_tooltip_armed_id, .armed_owner = v.canvas_tooltip_armed_owner_id, .deadline = v.canvas_tooltip_deadline_ns, .shown = v.canvas_tooltip_shown_id, .shown_owner = v.canvas_tooltip_shown_owner_id, .from_focus = v.canvas_tooltip_shown_from_focus, .warm = v.canvas_tooltip_warm_until_ns, .transit = v.canvas_tooltip_transit_deadline_ns, .focus = v.canvas_widget_focus_visible_id, .keyboard = v.canvas_widget_focus_visible_keyboard, .revision = v.widget_revision };
        }
        fn write(s: @This(), v: anytype) void {
            v.canvas_tooltip_armed_id = s.armed;
            v.canvas_tooltip_armed_owner_id = s.armed_owner;
            v.canvas_tooltip_deadline_ns = s.deadline;
            v.canvas_tooltip_shown_id = s.shown;
            v.canvas_tooltip_shown_owner_id = s.shown_owner;
            v.canvas_tooltip_shown_from_focus = s.from_focus;
            v.canvas_tooltip_warm_until_ns = s.warm;
            v.canvas_tooltip_transit_deadline_ns = s.transit;
            v.canvas_widget_focus_visible_id = s.focus;
            v.canvas_widget_focus_visible_keyboard = s.keyboard;
            v.widget_revision = s.revision;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "tooltip-intent", .source = native_sdk.WebViewSource.html("<h1>Tooltip</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    const owner: canvas.ObjectId = 0xffff_ffff_ffff_ff02;
    const other_owner: canvas.ObjectId = 0xffff_ffff_ffff_ff04;
    const hint: canvas.ObjectId = 0xffff_ffff_ffff_ff03;
    const plain_id: canvas.ObjectId = 0xffff_ffff_ffff_ff06;
    const other_hint: canvas.ObjectId = 0xffff_ffff_ffff_ff05;
    const hints = [_]canvas.Widget{.{ .id = hint, .kind = .tooltip, .text = "Hint", .layout = .{ .anchor = .{ .placement = .above } } }};
    const other_hints = [_]canvas.Widget{.{ .id = other_hint, .kind = .tooltip, .text = "Other", .layout = .{ .anchor = .{ .placement = .above } } }};
    const children = [_]canvas.Widget{
        .{ .id = owner, .kind = .button, .text = "Run", .children = &hints },
        .{ .id = other_owner, .kind = .button, .text = "Other", .children = &other_hints },
        .{ .id = plain_id, .kind = .button, .text = "Plain" },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 640, 480), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.createWindow(.{ .label = "other-window" });
    var comparisons: usize = 0;
    for (0..216) |variant| {
        const shown = variant % 3;
        const armed = variant / 3 % 3;
        const seed = State{ .armed = if (armed == 0) 0 else if (armed == 1) hint else other_hint, .armed_owner = if (armed == 2) other_owner else owner, .deadline = 0xffff_ffff_ffff_ffef, .shown = if (shown == 0) 0 else if (shown == 1) hint else other_hint, .shown_owner = if (shown == 2) other_owner else owner, .from_focus = variant / 9 % 2 != 0, .warm = 0xffff_ffff_ffff_ffed, .transit = 0xffff_ffff_ffff_ffeb, .focus = if (variant / 18 % 2 == 0) owner else other_owner, .keyboard = variant / 36 % 2 != 0, .revision = 100 };
        harness.runtime.app_active = variant / 72 != 1;
        harness.runtime.windows[0].info.focused = variant / 72 != 2;
        for (0..15) |cause| {
            var expected: State = undefined;
            var expected_nodes: [6]canvas.WidgetLayoutNode = undefined;
            var expected_semantics: [6]canvas.WidgetSemanticsNode = undefined;
            var expected_semantics_count: usize = 0;
            for (0..2) |backend| {
                core.rt.frameReset();
                @memcpy(view.widget_layout_nodes[0..nodes.len], &nodes);
                seed.write(view);
                harness.runtime.app_active = variant / 72 != 1;
                harness.runtime.windows[0].info.focused = variant / 72 != 2;
                harness.runtime.windows[1].info.focused = false;
                view.focused = true;
                harness.runtime.views[1].focused = false;
                view.canvas_widget_focused_id = if (cause == 0) plain_id else if (cause == 1) owner else if (cause == 2) other_owner else if (cause == 4 or (cause >= 11 and cause <= 13)) owner else seed.focus;
                view.canvas_last_pointer_position = null;
                view.canvas_widget_hovered_id = 0;
                view.canvas_widget_pressed_id = 0;
                if (cause == 13) view.widget_layout_nodes[1].widget.kind = .text_field;
                // Direct surface dismissal also accepts a visible static
                // zero-ID tooltip; zero equality still clears stale slots.
                if (cause == 14) {
                    view.widget_layout_nodes[2].widget.id = 0;
                    view.widget_layout_nodes[2].widget.layout.anchor = null;
                }
                view.applyCanvasTooltipVisibility();
                try view.refreshCanvasWidgetSemantics();
                view.canvas_widget_tooltip_policy = if (backend == 0) null else core.nativeTooltipPolicy;
                switch (cause) {
                    0, 1, 2 => try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = .key_down, .key = "tab" } }),
                    3 => try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = .pointer_down, .button = 1, .x = 600, .y = 450 } }),
                    4, 11, 12, 13 => try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = if (cause == 11) .key_up else .key_down, .key = "space", .modifiers = .{ .control = cause == 12 } } }),
                    5 => {
                        _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{ .id = plain_id, .action = .focus });
                    },
                    6 => try harness.runtime.dispatchPlatformEvent(app, .{ .view_focused = .{ .window_id = 1, .label = "second" } }),
                    7 => try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = .pointer_cancel } }),
                    8, 14 => {
                        _ = try view.dismissCanvasWidgetSurfaceAtIndex(2);
                    },
                    9 => try harness.runtime.dispatchPlatformEvent(app, .{ .window_focused = 2 }),
                    10 => try harness.runtime.dispatchPlatformEvent(app, .app_deactivated),
                    else => unreachable,
                }
                if (backend == 0) {
                    expected = State.read(view);
                    @memcpy(&expected_nodes, view.widgetLayoutTree().nodes);
                    expected_semantics_count = view.widgetSemantics().len;
                    @memcpy(expected_semantics[0..expected_semantics_count], view.widgetSemantics());
                } else {
                    try std.testing.expectEqualDeep(expected, State.read(view));
                    try std.testing.expectEqualDeep(expected_nodes, view.widget_layout_nodes[0..nodes.len].*);
                    try std.testing.expectEqual(expected_semantics_count, view.widgetSemantics().len);
                    try std.testing.expectEqualDeep(expected_semantics[0..expected_semantics_count], view.widgetSemantics());
                    comparisons += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3240), comparisons);
    core.rt.frameReset();
}

test "compiled tooltip intent preserves borrowed cycle bytes across repeated transitions" {
    core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    for (0..7) |cause| {
        for (0..128) |facts| {
            var output: [1]u8 = undefined;
            try std.testing.expectEqual(output.len, core.nativeTooltipPolicy(&.{ 24, @intCast(cause), @intCast(facts) }, &output));
            try std.testing.expect(output[0] <= 127);
            try std.testing.expectEqualSlices(u8, copy, borrowed);
        }
    }
    core.rt.frameReset();
}

test "compiled tooltip pointer and frame intent matches complete native retained state" {
    const NoEvents = struct {
        fn event(_: *anyopaque, _: *runtime_ns.Runtime, _: native_sdk.Event) anyerror!void {}
    };
    const State = struct {
        armed: canvas.ObjectId,
        armed_owner: canvas.ObjectId,
        deadline: u64,
        shown: canvas.ObjectId,
        shown_owner: canvas.ObjectId,
        from_focus: bool,
        warm: u64,
        transit: u64,
        focus: canvas.ObjectId,
        keyboard: bool,
        revision: u64,
        apex: geometry.PointF,
        fn read(v: anytype) @This() {
            return .{ .armed = v.canvas_tooltip_armed_id, .armed_owner = v.canvas_tooltip_armed_owner_id, .deadline = v.canvas_tooltip_deadline_ns, .shown = v.canvas_tooltip_shown_id, .shown_owner = v.canvas_tooltip_shown_owner_id, .from_focus = v.canvas_tooltip_shown_from_focus, .warm = v.canvas_tooltip_warm_until_ns, .transit = v.canvas_tooltip_transit_deadline_ns, .focus = v.canvas_widget_focus_visible_id, .keyboard = v.canvas_widget_focus_visible_keyboard, .revision = v.widget_revision, .apex = v.canvas_tooltip_pointer_from };
        }
        fn write(s: @This(), v: anytype) void {
            v.canvas_tooltip_armed_id = s.armed;
            v.canvas_tooltip_armed_owner_id = s.armed_owner;
            v.canvas_tooltip_deadline_ns = s.deadline;
            v.canvas_tooltip_shown_id = s.shown;
            v.canvas_tooltip_shown_owner_id = s.shown_owner;
            v.canvas_tooltip_shown_from_focus = s.from_focus;
            v.canvas_tooltip_warm_until_ns = s.warm;
            v.canvas_tooltip_transit_deadline_ns = s.transit;
            v.canvas_widget_focus_visible_id = s.focus;
            v.canvas_widget_focus_visible_keyboard = s.keyboard;
            v.widget_revision = s.revision;
            v.canvas_tooltip_pointer_from = s.apex;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "tooltip-intent", .source = native_sdk.WebViewSource.html("<h1>Tooltip</h1>"), .event_fn = NoEvents.event };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    const view = &harness.runtime.views[0];
    const owner: canvas.ObjectId = 0xffff_ffff_ffff_ff02;
    const other_owner: canvas.ObjectId = 0xffff_ffff_ffff_ff04;
    const hint: canvas.ObjectId = 0xffff_ffff_ffff_ff03;
    const plain_id: canvas.ObjectId = 0xffff_ffff_ffff_ff06;
    const other_hint: canvas.ObjectId = 0xffff_ffff_ffff_ff05;
    const hints = [_]canvas.Widget{.{ .id = hint, .kind = .tooltip, .text = "Hint", .layout = .{ .anchor = .{ .placement = .above } } }};
    const other_hints = [_]canvas.Widget{.{ .id = other_hint, .kind = .tooltip, .text = "Other", .layout = .{ .anchor = .{ .placement = .above } } }};
    const children = [_]canvas.Widget{
        .{ .id = owner, .kind = .button, .text = "Run", .children = &hints },
        .{ .id = other_owner, .kind = .button, .text = "Other", .children = &other_hints },
        .{ .id = plain_id, .kind = .button, .text = "Plain" },
    };
    var nodes: [6]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 640, 480), &nodes);
    // Explicit frames expose the gap, content, both owners and collinear motion.
    nodes[1].frame = geometry.RectF.init(50, 100, 80, 30);
    nodes[2].frame = geometry.RectF.init(50, 60, 90, 32);
    nodes[3].frame = geometry.RectF.init(180, 100, 80, 30);
    nodes[4].frame = geometry.RectF.init(180, 60, 90, 32);
    nodes[5].frame = geometry.RectF.init(340, 100, 80, 30);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 640, 480) });
    _ = try harness.runtime.createWindow(.{ .label = "other-window" });
    var comparisons: usize = 0;
    // Clocks deliberately exceed the exact JS integer range.
    const now: u64 = 0x8000_0000_0000_0000;
    const points = [_]geometry.PointF{ .{ .x = 90, .y = 115 }, .{ .x = 95, .y = 75 }, .{ .x = 90, .y = 96 }, .{ .x = 0, .y = 60 }, .{ .x = 215, .y = 115 }, .{ .x = 10, .y = 10 }, .{ .x = 380, .y = 115 } };
    for (0..432) |variant| {
        const shown = variant % 3;
        const armed = variant / 3 % 3;
        const seed = State{ .armed = if (armed == 0) 0 else if (armed == 1) hint else other_hint, .armed_owner = if (armed == 2) other_owner else owner, .deadline = now + if (variant / 36 % 2 == 0) @as(u64, 1) else 0, .shown = if (shown == 0) 0 else if (shown == 1) hint else other_hint, .shown_owner = if (shown == 2) other_owner else owner, .from_focus = variant / 9 % 2 != 0, .warm = now + if (variant / 18 % 2 == 0) @as(u64, 1) else 0, .transit = now + if (variant / 36 % 2 == 0) @as(u64, 1) else 0, .focus = if (variant / 18 % 2 == 0) owner else other_owner, .keyboard = variant / 36 % 2 != 0, .revision = 100, .apex = .{ .x = 90, .y = 115 } };
        harness.runtime.app_active = variant / 72 % 3 != 1;
        harness.runtime.windows[0].info.focused = variant / 72 % 3 != 2;
        for (0..13) |cause| {
            var expected: State = undefined;
            var expected_nodes: [6]canvas.WidgetLayoutNode = undefined;
            var expected_semantics: [6]canvas.WidgetSemanticsNode = undefined;
            var expected_semantics_count: usize = 0;
            for (0..2) |backend| {
                core.rt.frameReset();
                @memcpy(view.widget_layout_nodes[0..nodes.len], &nodes);
                seed.write(view);
                harness.runtime.app_active = variant / 72 % 3 != 1;
                harness.runtime.windows[0].info.focused = variant / 72 % 3 != 2;
                harness.runtime.windows[1].info.focused = false;
                view.focused = true;
                harness.runtime.views[1].focused = false;
                view.canvas_widget_focused_id = seed.focus;
                view.canvas_last_pointer_position = null;
                view.canvas_widget_hovered_id = 0;
                view.canvas_widget_pressed_id = 0;
                view.gpu_input_timestamp_ns = now;
                view.gpu_timestamp_ns = 0;
                view.widget_tokens.metrics.tooltip_warm_window_ms = if (variant / 216 == 0) 400 else 0;
                // All declared delays, including immediate and the i32 maximum.
                view.widget_layout_nodes[2].widget.tooltip_delay_ms = if (variant % 4 == 0) 0 else if (variant % 4 == 1) -1 else if (variant % 4 == 2) 10 else 2147483647;
                view.applyCanvasTooltipVisibility();
                try view.refreshCanvasWidgetSemantics();
                view.canvas_widget_tooltip_policy = if (backend == 0) null else core.nativeTooltipPolicy;
                if (cause < points.len) {
                    const point = points[cause];
                    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = .pointer_move, .timestamp_ns = now, .x = point.x, .y = point.y } });
                } else if (cause < 10) {
                    // Exact boundaries, before expiry and after both deadlines.
                    try harness.runtime.advanceCanvasTooltipIntentForFrame(0, now - 1 + (cause - 7));
                } else if (cause == 10) {
                    view.canvas_widget_hovered_id = owner;
                    view.canvas_last_pointer_position = points[1];
                    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
                } else {
                    // Replayable consecutive moves through the gap and content.
                    for ([_]usize{ 0, 2, 1, 2, 0, 4, 5 }) |i| {
                        const point = points[i];
                        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .label = "canvas", .kind = .pointer_move, .timestamp_ns = now, .x = point.x, .y = point.y } });
                        if (cause == 12) try harness.runtime.advanceCanvasTooltipIntentForFrame(0, now + 500 * std.time.ns_per_ms);
                    }
                }
                if (backend == 0) {
                    expected = State.read(view);
                    @memcpy(&expected_nodes, view.widgetLayoutTree().nodes);
                    expected_semantics_count = view.widgetSemantics().len;
                    @memcpy(expected_semantics[0..expected_semantics_count], view.widgetSemantics());
                } else {
                    try std.testing.expectEqualDeep(expected, State.read(view));
                    try std.testing.expectEqualDeep(expected_nodes, view.widget_layout_nodes[0..nodes.len].*);
                    try std.testing.expectEqual(expected_semantics_count, view.widgetSemantics().len);
                    try std.testing.expectEqualDeep(expected_semantics[0..expected_semantics_count], view.widgetSemantics());
                    comparisons += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 5616), comparisons);
    core.rt.frameReset();
}

test "compiled tooltip pointer calls preserve borrowed cycle bytes across every native fact shape" {
    core.rt.frameReset();
    _ = core.initialModel();
    const borrowed = core.bootCommand();
    const copy = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(copy);
    var calls: usize = 0;
    for ([_]usize{ 4096, 32, 16, 4, 16 }, 0..) |count, cause| {
        for (0..count) |facts| {
            var output: [1]u8 = undefined;
            const request = [4]u8{ 25, @intCast(cause), @truncate(facts), @truncate(facts >> 8) };
            try std.testing.expectEqual(output.len, core.nativeTooltipPolicy(&request, &output));
            try std.testing.expect(output[0] <= 15);
            try std.testing.expectEqualSlices(u8, copy, borrowed);
            calls += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4164), calls);
    core.rt.frameReset();
}
