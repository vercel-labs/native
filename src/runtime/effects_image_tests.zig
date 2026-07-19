//! Image-load effect coverage: `fx.loadImage` through the fake executor
//! (request capture, byte feeds that run the REAL decode+register path,
//! the failure taxonomy, cancel) and the real executor's source cascade
//! — local files via `std.testing.tmpDir`, network sources against a
//! loopback `std.http.Server` fixture spawned inside the test (no
//! external network is ever touched), including the content-addressed
//! cache install and the offline cache hit behind it.

const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const canvas_limits = @import("canvas_limits.zig");

const canvas_label = "image-canvas";

const image_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const image_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Images",
    .width = 400,
    .height = 300,
    .views = &image_views,
}};
const image_scene: app_manifest.ShellConfig = .{ .windows = &image_windows };

/// The burst test's stand-in entry for a non-image terminal in the
/// delivery-order log — outside the burst's 1..=burst_load_count id
/// range, so it can never shadow an image terminal.
const interleave_marker: u64 = 500;

/// Loads issued by the `.burst` arm: past both the pending ring's 32
/// entries and the image stage's inline capacity, so a single dispatch
/// proves the stage spills instead of evicting.
const burst_load_count = 33;

const ImageModel = struct {
    result_count: usize = 0,
    last: ?effects_mod.EffectImageResult = null,
    rejected_count: usize = 0,
    /// Delivery-order log for the burst test: each image terminal
    /// records its echoed id, the interleaved spawn rejection records
    /// `interleave_marker`.
    order: [40]u64 = @splat(0),
    order_len: usize = 0,

    /// `EffectImageResult` is all plain data — storing it whole is the
    /// documented contract (no borrowed slices to copy).
    fn record(model: *ImageModel, result: effects_mod.EffectImageResult) void {
        model.result_count += 1;
        model.last = result;
        if (result.outcome == .rejected) model.rejected_count += 1;
        model.logOrder(result.id);
    }

    fn logOrder(model: *ImageModel, value: u64) void {
        if (model.order_len < model.order.len) {
            model.order[model.order_len] = value;
            model.order_len += 1;
        }
    }
};

const ImageMsg = union(enum) {
    start,
    stop,
    burst,
    result: effects_mod.EffectImageResult,
    spawn_exit: effects_mod.EffectExit,
};

const ImageApp = ui_app_model.UiApp(ImageModel, ImageMsg);
const ImageEffects = ImageApp.Effects;

const image_id: u64 = 42;

// Set by each test before dispatching `.start`; globals keep the update
// function closure-free.
var test_id: u64 = image_id;
var test_path: []const u8 = "";
var test_url: []const u8 = "";
var test_cache_path: []const u8 = "";
var test_expected_bytes: u64 = 0;
var test_timeout_ms: u32 = effects_mod.default_effect_fetch_timeout_ms;

fn imageUpdate(model: *ImageModel, msg: ImageMsg, fx: *ImageEffects) void {
    switch (msg) {
        .start => fx.loadImage(.{
            .id = test_id,
            .path = test_path,
            .url = test_url,
            .cache_path = test_cache_path,
            .expected_bytes = test_expected_bytes,
            .timeout_ms = test_timeout_ms,
            .on_result = ImageEffects.imageMsg(.result),
        }),
        .stop => fx.cancel(test_id),
        .burst => {
            // One dispatch, no drain in between: every load below is
            // refused loop-side (no source at all), each staging its
            // one terminal before any can deliver. A rejected spawn
            // (empty argv) lands between load 5 and load 6 so the
            // delivery order across BOTH pending structures stays
            // pinned, not just the order within the image stage.
            var id: u64 = 1;
            while (id <= 5) : (id += 1) burstLoad(fx, id);
            fx.spawn(.{ .key = interleave_marker, .argv = &.{}, .on_exit = ImageEffects.exitMsg(.spawn_exit) });
            while (id <= burst_load_count) : (id += 1) burstLoad(fx, id);
        },
        .result => |result| model.record(result),
        .spawn_exit => model.logOrder(interleave_marker),
    }
}

/// A load with no source at all: refused before any I/O, delivering
/// exactly one `.rejected` terminal that echoes `id`.
fn burstLoad(fx: *ImageEffects, id: u64) void {
    fx.loadImage(.{
        .id = id,
        .path = "",
        .url = "",
        .cache_path = "",
        .expected_bytes = 0,
        .on_result = ImageEffects.imageMsg(.result),
    });
}

fn imageView(ui: *ImageApp.Ui, model: *const ImageModel) ImageApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results", .{model.result_count})),
        ui.button(.{ .on_press = .start }, "Load"),
        ui.button(.{ .on_press = .stop }, "Cancel"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *ImageApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        // The deterministic decode seam: the strict PNG subset
        // `canvas.png.writeRgba8` emits decodes without a bundled codec.
        harness.null_platform.image_decode = true;
        const app_state = try std.testing.allocator.create(ImageApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = ImageApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-image",
            .scene = image_scene,
            .canvas_label = canvas_label,
            .update_fx = imageUpdate,
            .view = imageView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        try std.testing.expect(app_state.installed);
        // Test defaults back to the shared globals.
        test_id = image_id;
        test_path = "";
        test_url = "";
        test_cache_path = "";
        test_expected_bytes = 0;
        test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    /// Consume all pending wake requests and deliver a single `.wake`
    /// platform event for the batch.
    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

/// A tiny deterministic RGBA fixture encoded as the strict PNG subset
/// the null platform's decode seam parses.
fn encodePngFixture(buffer: []u8, width: usize, height: usize) []const u8 {
    var pixels: [64 * 64 * 4]u8 = undefined;
    const byte_len = width * height * 4;
    var seed: u8 = 17;
    for (pixels[0..byte_len]) |*byte| {
        byte.* = seed;
        seed = seed *% 29 +% 3;
    }
    var writer = std.Io.Writer.fixed(buffer);
    canvas.png.writeRgba8(&writer, width, height, pixels[0..byte_len]) catch unreachable;
    return writer.buffered();
}

fn waitForResult(h: *Harness, count: usize) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        try h.drainWakes();
        if (h.app_state.model.result_count >= count) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

// ------------------------------------------------------------ fake executor

test "fake executor records the whole load request shape and feeds bytes through the real decode path" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    test_path = "assets/cover.png";
    test_url = "https://cdn.example.com/cover.png";
    test_cache_path = "cache/images/abc.png";
    test_expected_bytes = 512;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingImageLoadCount());
    const request = h.app_state.effects.pendingImageLoadAt(0).?;
    try std.testing.expectEqual(image_id, request.id);
    try std.testing.expectEqualStrings("assets/cover.png", request.path);
    try std.testing.expectEqualStrings("https://cdn.example.com/cover.png", request.url);
    try std.testing.expectEqualStrings("cache/images/abc.png", request.cache_path);
    try std.testing.expectEqual(@as(u64, 512), request.expected_bytes);

    // Feeding encoded bytes exercises decode + register end to end:
    // the Msg carries the decoded dimensions and the pixels are live
    // in the registry under the requested id.
    var encoded_buffer: [2048]u8 = undefined;
    const encoded = encodePngFixture(&encoded_buffer, 3, 2);
    try h.app_state.effects.feedImageBytes(image_id, encoded);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    const result = h.app_state.model.last.?;
    try std.testing.expectEqual(image_id, result.id);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 3), result.width);
    try std.testing.expectEqual(@as(usize, 2), result.height);
    const registered = h.harness.runtime.registeredCanvasImage(image_id).?;
    try std.testing.expectEqual(@as(usize, 3), registered.width);
    try std.testing.expectEqual(@as(usize, 2), registered.height);

    // The slot retired: the same id loads again.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingImageLoadCount());
}

test "undecodable and oversized feeds fail with the registry's own classes" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    test_path = "assets/cover.png";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageBytes(image_id, "not an image");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.decode_failed, h.app_state.model.last.?.outcome);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(image_id) == null);

    // A host without a codec is `.unsupported`, mirroring
    // `error.UnsupportedService` on the direct path.
    h.harness.null_platform.image_decode = false;
    var encoded_buffer: [2048]u8 = undefined;
    const encoded = encodePngFixture(&encoded_buffer, 1, 1);
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageBytes(image_id, encoded);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.unsupported, h.app_state.model.last.?.outcome);
    h.harness.null_platform.image_decode = true;

    // Over the encoded-source bound: `.too_large` without decoding.
    const decodes_before = h.harness.null_platform.image_decode_count;
    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_image_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 7);
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageBytes(image_id, oversized);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.too_large, h.app_state.model.last.?.outcome);
    try std.testing.expectEqual(decodes_before, h.harness.null_platform.image_decode_count);
}

test "a full registry fails the load with registry_full, never silence" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    var encoded_buffer: [2048]u8 = undefined;
    const encoded = encodePngFixture(&encoded_buffer, 1, 1);
    var id: u64 = 1000;
    while (id < 1000 + canvas_limits.max_registered_canvas_images) : (id += 1) {
        _ = try h.harness.runtime.registerCanvasImageBytes(id, encoded);
    }

    test_path = "assets/one-too-many.png";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageBytes(image_id, encoded);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.registry_full, h.app_state.model.last.?.outcome);
}

test "recorded terminals feed verbatim: the failure classes and a loaded record's re-registration" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    test_path = "assets/cover.png";
    const classes = [_]effects_mod.EffectImageOutcome{ .not_found, .io_failed, .connect_failed, .tls_failed, .protocol_failed, .timed_out, .decode_failed };
    for (classes, 1..) |class, count| {
        try h.app_state.dispatch(&h.harness.runtime, 1, .start);
        try h.app_state.effects.feedImageResult(image_id, class, 0, 0, 0, "");
        try h.drainWakes();
        try std.testing.expectEqual(count, h.app_state.model.result_count);
        try std.testing.expectEqual(class, h.app_state.model.last.?.outcome);
    }

    // An `.http_status` record carries its status through.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageResult(image_id, .http_status, 0, 0, 404, "");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.http_status, h.app_state.model.last.?.outcome);
    try std.testing.expectEqual(@as(u16, 404), h.app_state.model.last.?.status);

    // A recorded `.loaded` delivers the journaled dimensions verbatim
    // AND re-registers the recorded bytes for presentation.
    var encoded_buffer: [2048]u8 = undefined;
    const encoded = encodePngFixture(&encoded_buffer, 3, 2);
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageResult(image_id, .loaded, 3, 2, 200, encoded);
    try h.drainWakes();
    const result = h.app_state.model.last.?;
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 3), result.width);
    try std.testing.expectEqual(@as(usize, 2), result.height);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(image_id) != null);

    // A recorded `.loaded` whose bytes the replay host cannot decode
    // still delivers the recorded Msg — the divergence is loud on
    // stderr and presentation-only, never a different Msg stream.
    test_id = image_id + 1;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.effects.feedImageResult(image_id + 1, .loaded, 8, 8, 0, "jpeg bytes this host cannot decode");
    try h.drainWakes();
    const undecodable = h.app_state.model.last.?;
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, undecodable.outcome);
    try std.testing.expectEqual(@as(usize, 8), undecodable.width);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(image_id + 1) == null);
}

test "load requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    // No source at all.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);

    // Id 0 is the no-image sentinel; the media-surface namespace is
    // reserved — both mirror `registerCanvasImage`'s refusals.
    test_path = "assets/cover.png";
    test_id = 0;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.rejected_count);
    test_id = canvas.media_surface_image_id_bit | 7;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 3), h.app_state.model.rejected_count);
    test_id = image_id;

    // A non-http(s) url.
    test_path = "";
    test_url = "file:///etc/passwd";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 4), h.app_state.model.rejected_count);

    // An over-bound path.
    var long_path: [effects_mod.max_effect_image_path_bytes + 1]u8 = undefined;
    @memset(&long_path, 'a');
    test_url = "";
    test_path = &long_path;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 5), h.app_state.model.rejected_count);

    // A duplicate active key.
    test_path = "assets/cover.png";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 6), h.app_state.model.rejected_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingImageLoadCount());
}

test "a burst of validation rejections past the pending ring delivers every terminal, in order" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    // 33 sourceless loads plus one rejected spawn in ONE dispatch:
    // more loop-side terminals than the 32-entry pending ring holds.
    // Image results carry no drop counter, so ring overflow would have
    // to evict one silently — breaking the exactly-one-terminal-per-
    // load contract — which is why image terminals stage in the
    // non-lossy side stage instead of the ring.
    try h.app_state.dispatch(&h.harness.runtime, 1, .burst);
    try h.drainWakes();

    // Every load's terminal arrived: exactly one each, all rejected.
    try std.testing.expectEqual(@as(usize, burst_load_count), h.app_state.model.result_count);
    try std.testing.expectEqual(@as(usize, burst_load_count), h.app_state.model.rejected_count);

    // Delivery preserved enqueue order across BOTH pending structures:
    // loads 1..5, the spawn rejection, then loads 6..33.
    try std.testing.expectEqual(@as(usize, burst_load_count + 1), h.app_state.model.order_len);
    var expected_id: u64 = 1;
    for (h.app_state.model.order[0..h.app_state.model.order_len], 0..) |value, position| {
        if (position == 5) {
            try std.testing.expectEqual(interleave_marker, value);
            continue;
        }
        try std.testing.expectEqual(expected_id, value);
        expected_id += 1;
    }
}

test "cancelling a fake image load delivers one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    test_path = "assets/cover.png";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.cancelled, h.app_state.model.last.?.outcome);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingImageLoadCount());
    // Terminal means terminal: a straggler feed reports EffectNotFound.
    try std.testing.expectError(error.EffectNotFound, h.app_state.effects.feedImageBytes(image_id, "late"));
}

// ------------------------------------------------------------ real executor

test "real executor loads a local file through decode and registration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var h = try Harness.create();
    defer h.destroy();

    var encoded_buffer: [4096]u8 = undefined;
    const encoded = encodePngFixture(&encoded_buffer, 4, 3);
    try tmp.dir.writeFile(io, .{ .sub_path = "cover.png", .data = encoded });

    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cover.png", .{tmp.sub_path[0..]});
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 1);
    const result = h.app_state.model.last.?;
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 4), result.width);
    try std.testing.expectEqual(@as(usize, 3), result.height);
    const registered = h.harness.runtime.registeredCanvasImage(image_id).?;
    try std.testing.expectEqual(@as(usize, 4), registered.width);
    try std.testing.expectEqual(@as(usize, 3), registered.height);
}

test "real executor reports a missing local file with no url as not_found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Harness.create();
    defer h.destroy();

    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/absent.png", .{tmp.sub_path[0..]});
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.not_found, h.app_state.model.last.?.outcome);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(image_id) == null);
}

test "real executor reports connection refused as connect_failed" {
    var h = try Harness.create();
    defer h.destroy();

    // Bind an ephemeral port, then close it: nothing listens there.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
    const dead_port = listener.socket.address.getPort();
    listener.deinit(io);

    var url_buffer: [128]u8 = undefined;
    test_url = std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/cover.png", .{dead_port}) catch unreachable;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.connect_failed, h.app_state.model.last.?.outcome);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(image_id) == null);
}

// A loopback HTTP fixture serving image routes (the fetch test
// fixture's shape, image-flavored).
const Fixture = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    accept_future: std.Io.Future(void),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    request_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    png_storage: [4096]u8 = undefined,
    png_len: usize = 0,

    fn start(allocator: std.mem.Allocator) !*Fixture {
        const self = try allocator.create(Fixture);
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
        self.png_len = encodePngFixture(&self.png_storage, 4, 3).len;
        self.accept_future = try std.Io.concurrent(io, serverMain, .{self});
        return self;
    }

    fn stop(self: *Fixture) void {
        const io = self.threaded.io();
        self.stopping.store(true, .release);
        self.accept_future.cancel(io);
        self.listener.deinit(io);
        self.threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self.threaded);
        allocator.destroy(self);
    }

    fn url(self: *const Fixture, buffer: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    fn serverMain(self: *Fixture) void {
        const io = self.threaded.io();
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch return;
            self.handleConnection(io, stream) catch {};
            stream.close(io);
        }
    }

    fn handleConnection(self: *Fixture, io: std.Io, stream: std.Io.net.Stream) !void {
        var recv_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buffer);
        var conn_writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
        var request = try server.receiveHead();
        _ = self.request_count.fetchAdd(1, .monotonic);
        const target = request.head.target;
        if (std.mem.eql(u8, target, "/cover.png")) {
            try request.respond(self.png_storage[0..self.png_len], .{
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "image/png" }},
            });
        } else if (std.mem.eql(u8, target, "/broken.png")) {
            try request.respond("these bytes are no image", .{ .keep_alive = false });
        } else {
            try request.respond("nope", .{ .status = .not_found, .keep_alive = false });
        }
    }
};

test "real executor fetches a url source, installs the cache, and hits it offline next time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);

    var cache_dir_buffer: [256]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buffer, ".zig-cache/tmp/{s}/caches", .{tmp.sub_path[0..]});
    var url_buffer: [128]u8 = undefined;
    var cache_buffer: [512]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/cover.png");
    test_cache_path = try effects_mod.imageCachePath(&cache_buffer, cache_dir, test_url);
    test_expected_bytes = @intCast(fixture.png_len);

    // Missing local path falls through to the url (the audio cascade).
    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/absent.png", .{tmp.sub_path[0..]});
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 1);
    var result = h.app_state.model.last.?;
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 4), result.width);
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expect(fixture.request_count.load(.acquire) >= 1);

    // The verified download was installed under the content address,
    // whole, with no .partial debris beside it.
    const cached = try std.Io.Dir.cwd().readFileAlloc(io, test_cache_path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualSlices(u8, fixture.png_storage[0..fixture.png_len], cached);

    // Stop the server: the second load must resolve from the cache —
    // no network, same result.
    fixture.stop();
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 2);
    result = h.app_state.model.last.?;
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 4), result.width);
    try std.testing.expectEqual(@as(usize, 3), result.height);
}

test "cache install temp names are writer-unique" {
    // Two operations toward the SAME cache path (two ids loading one
    // URL) must never share a temp: a shared name lets one writer
    // truncate the other's bytes mid-write, or rename a half-written
    // file into the cache name.
    var first_buffer: [512]u8 = undefined;
    var second_buffer: [512]u8 = undefined;
    const cache_path = "/tmp/caches/images/abc123.png";
    const first = try effects_mod.imageCachePartialPath(&first_buffer, cache_path, 7, 0xaaaa);
    const second = try effects_mod.imageCachePartialPath(&second_buffer, cache_path, 8, 0xaaaa);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    // Both stay recognizable install debris beside their cache path.
    try std.testing.expect(std.mem.startsWith(u8, first, cache_path));
    try std.testing.expect(std.mem.endsWith(u8, first, ".partial"));
    try std.testing.expect(std.mem.startsWith(u8, second, cache_path));
    try std.testing.expect(std.mem.endsWith(u8, second, ".partial"));

    // The generation alone is only channel-local: two channels in one
    // process (or two processes sharing the platform cache directory)
    // can install at the SAME generation concurrently. The random
    // writer token keeps their temps distinct — a name built from the
    // generation alone would collide here and recreate the
    // truncate/rename race.
    const third = try effects_mod.imageCachePartialPath(&second_buffer, cache_path, 7, 0xbbbb);
    try std.testing.expect(!std.mem.eql(u8, first, third));

    try std.testing.expectError(error.InvalidImageOptions, effects_mod.imageCachePartialPath(&first_buffer, "", 7, 0xaaaa));
}

test "concurrent loads of one url both complete with an intact cache and no temp debris" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var cache_dir_buffer: [256]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buffer, ".zig-cache/tmp/{s}/caches", .{tmp.sub_path[0..]});
    var url_buffer: [128]u8 = undefined;
    var cache_buffer: [512]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/cover.png");
    test_cache_path = try effects_mod.imageCachePath(&cache_buffer, cache_dir, test_url);
    test_expected_bytes = @intCast(fixture.png_len);

    // Two ids over the SAME url, in flight together: each install
    // writes its own operation-unique temp toward the shared cache
    // path, so whichever rename lands last publishes a WHOLE file.
    test_id = 91;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    test_id = 92;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 2);

    // Both loads decoded and registered — neither terminal was lost or
    // degraded by the other's install.
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(91) != null);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(92) != null);

    // The cache entry is whole (never a torn write published by an
    // early rename), and no install temp survives beside it.
    const cached = try std.Io.Dir.cwd().readFileAlloc(io, test_cache_path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualSlices(u8, fixture.png_storage[0..fixture.png_len], cached);

    var images_dir_buffer: [512]u8 = undefined;
    const images_dir = try std.fmt.bufPrint(&images_dir_buffer, "{s}/images", .{cache_dir});
    var dir = try std.Io.Dir.cwd().openDir(io, images_dir, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var file_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "real executor reports non-2xx statuses and undecodable bodies honestly" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/missing.png");
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.http_status, h.app_state.model.last.?.outcome);
    try std.testing.expectEqual(@as(u16, 404), h.app_state.model.last.?.status);

    test_url = fixture.url(&url_buffer, "/broken.png");
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResult(&h, 2);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.decode_failed, h.app_state.model.last.?.outcome);
}

test "imageCachePath keys by url hash under images/ and keeps the extension" {
    var buffer: [512]u8 = undefined;
    const path = try effects_mod.imageCachePath(&buffer, "/tmp/caches", "https://cdn.example.com/art/cover.png?sig=abc");
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/caches/images/"));
    // The query-string suffix never smuggles into the file name; the
    // dot-extension survives only when plausible.
    try std.testing.expect(std.mem.indexOfAny(u8, path, "?#&") == null);

    const clean = try effects_mod.imageCachePath(&buffer, "/tmp/caches", "https://cdn.example.com/art/cover.png");
    try std.testing.expect(std.mem.endsWith(u8, clean, ".png"));
    var second_buffer: [512]u8 = undefined;
    const again = try effects_mod.imageCachePath(&second_buffer, "/tmp/caches", "https://cdn.example.com/art/cover.png");
    try std.testing.expectEqualStrings(clean, again);
    // A different url gets a different address, and the audio cache
    // lives in its own segment.
    const other = try effects_mod.imageCachePath(&second_buffer, "/tmp/caches", "https://cdn.example.com/art/other.png");
    try std.testing.expect(!std.mem.eql(u8, clean, other));
    try std.testing.expectError(error.InvalidImageOptions, effects_mod.imageCachePath(&buffer, "", "https://x.example/a.png"));
}

// -------------------------------------------------- export surface pin

/// The public SDK root, exactly as an external Zig app imports it: an
/// app writing an `Effects.imageMsg` Msg arm (and reasoning about the
/// image bounds) needs these names on the public root, not
/// module-internal paths — the media-surface export pin's convention.
const sdk = @import("../root.zig");

test "the image effect surface is exported through the public root" {
    // The payload/outcome types on the SDK root and the runtime root
    // ARE the effects module's, so an external Msg arm and an internal
    // drain speak one type.
    comptime std.debug.assert(sdk.EffectImageResult == effects_mod.EffectImageResult);
    comptime std.debug.assert(sdk.EffectImageOutcome == effects_mod.EffectImageOutcome);
    comptime std.debug.assert(sdk.runtime.EffectImageResult == sdk.EffectImageResult);
    comptime std.debug.assert(sdk.runtime.EffectImageOutcome == sdk.EffectImageOutcome);
    // The bounds an app sizes buffers and teaching against, exported on
    // both roots beside the audio limits they mirror.
    comptime std.debug.assert(sdk.max_effect_image_path_bytes == effects_mod.max_effect_image_path_bytes);
    comptime std.debug.assert(sdk.max_effect_image_bytes == effects_mod.max_effect_image_bytes);
    comptime std.debug.assert(sdk.effect_image_blob_hash_len == effects_mod.effect_image_blob_hash_len);
    comptime std.debug.assert(sdk.runtime.max_effect_image_path_bytes == effects_mod.max_effect_image_path_bytes);
    comptime std.debug.assert(sdk.runtime.max_effect_image_bytes == effects_mod.max_effect_image_bytes);
    comptime std.debug.assert(sdk.runtime.effect_image_blob_hash_len == effects_mod.effect_image_blob_hash_len);

    // Compile-shaped and driven: the exact Msg arm an external app
    // writes over the public constructor and payload type.
    const AppMsg = union(enum) { cover_loaded: sdk.EffectImageResult };
    const make = sdk.Effects(AppMsg).imageMsg(.cover_loaded);
    const msg = make(.{ .id = 7, .outcome = .loaded, .width = 2, .height = 3, .status = 200 });
    try std.testing.expectEqual(@as(u64, 7), msg.cover_loaded.id);
    try std.testing.expectEqual(sdk.EffectImageOutcome.loaded, msg.cover_loaded.outcome);

    // The cache-path convention is callable through the public root
    // (and both roots resolve to one function), sized by the exported
    // path bound.
    var buffer: [sdk.max_effect_image_path_bytes]u8 = undefined;
    const path = try sdk.imageCachePath(&buffer, "/tmp/caches", "https://cdn.example.com/art/cover.png");
    var runtime_buffer: [sdk.runtime.max_effect_image_path_bytes]u8 = undefined;
    const runtime_path = try sdk.runtime.imageCachePath(&runtime_buffer, "/tmp/caches", "https://cdn.example.com/art/cover.png");
    try std.testing.expectEqualStrings(path, runtime_path);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/caches/images/"));
}
