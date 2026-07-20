//! Fetch effect coverage: fake-executor determinism (request capture,
//! synthetic responses, cancel, truncation, rejection taxonomy) and real
//! end-to-end exchanges against a loopback `std.http.Server` fixture
//! spawned inside the test — no external network is ever touched.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const clock_mod = @import("clock.zig");

const canvas_label = "fetch-canvas";

const fetch_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const fetch_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Fetch",
    .width = 400,
    .height = 300,
    .views = &fetch_views,
}};
const fetch_scene: app_manifest.ShellConfig = .{ .windows = &fetch_windows };

const max_recorded_body_bytes = 8192;
const max_recorded_stream_lines = 16;
const max_recorded_stream_line_bytes = 96;

const FetchModel = struct {
    response_count: usize = 0,
    outcome: ?effects_mod.EffectFetchOutcome = null,
    status: u16 = 0,
    truncated: bool = false,
    body_len: usize = 0,
    body_hash: u64 = 0,
    body_storage: [max_recorded_body_bytes]u8 = undefined,
    rejected_count: usize = 0,
    // Stream-mode line recording (`.response = .stream`).
    line_count: usize = 0,
    truncated_lines: usize = 0,
    last_line_len: usize = 0,
    last_line_hash: u64 = 0,
    line_storage: [max_recorded_stream_lines][max_recorded_stream_line_bytes]u8 = undefined,
    line_lens: [max_recorded_stream_lines]usize = [_]usize{0} ** max_recorded_stream_lines,

    /// Copy what we keep: the body slice is drain scratch and dies with
    /// the update call that delivers it.
    fn record(model: *FetchModel, response: effects_mod.EffectResponse) void {
        model.response_count += 1;
        model.outcome = response.outcome;
        model.status = response.status;
        model.truncated = response.truncated;
        model.body_len = response.body.len;
        model.body_hash = std.hash.Wyhash.hash(0, response.body);
        if (response.outcome == .rejected) model.rejected_count += 1;
        const len = @min(response.body.len, max_recorded_body_bytes);
        @memcpy(model.body_storage[0..len], response.body[0..len]);
    }

    fn body(model: *const FetchModel) []const u8 {
        return model.body_storage[0..@min(model.body_len, max_recorded_body_bytes)];
    }

    fn recordLine(model: *FetchModel, line: effects_mod.EffectLine) void {
        if (line.truncated) model.truncated_lines += 1;
        model.last_line_len = line.line.len;
        model.last_line_hash = std.hash.Wyhash.hash(0, line.line);
        if (model.line_count >= max_recorded_stream_lines) return;
        const len = @min(line.line.len, max_recorded_stream_line_bytes);
        @memcpy(model.line_storage[model.line_count][0..len], line.line[0..len]);
        model.line_lens[model.line_count] = len;
        model.line_count += 1;
    }

    fn lineAt(model: *const FetchModel, index: usize) []const u8 {
        return model.line_storage[index][0..model.line_lens[index]];
    }
};

const FetchMsg = union(enum) {
    start,
    stop,
    line: effects_mod.EffectLine,
    response: effects_mod.EffectResponse,
};

const FetchApp = ui_app_model.UiApp(FetchModel, FetchMsg);
const FetchEffects = FetchApp.Effects;

const fetch_key: u64 = 77;

// Set by each test before dispatching `.start`; globals keep the update
// function closure-free.
var test_url: []const u8 = "";
var test_method: std.http.Method = .GET;
var test_headers: []const std.http.Header = &.{};
var test_payload: ?[]const u8 = null;
var test_timeout_ms: u32 = effects_mod.default_effect_fetch_timeout_ms;
var test_response_mode: effects_mod.FetchResponseMode = .buffered;
var test_max_line_bytes: usize = effects_mod.max_effect_line_bytes;
/// The poll idiom (one-shot): when set, the update reacts to a response
/// by immediately fetching the same key again.
var test_refetch_on_response: bool = false;

fn fetchUpdate(model: *FetchModel, msg: FetchMsg, fx: *FetchEffects) void {
    switch (msg) {
        .start => fx.fetch(.{
            .key = fetch_key,
            .method = test_method,
            .url = test_url,
            .headers = test_headers,
            .body = test_payload,
            .timeout_ms = test_timeout_ms,
            .response = test_response_mode,
            .max_line_bytes = test_max_line_bytes,
            .on_line = FetchEffects.lineMsg(.line),
            .on_response = FetchEffects.responseMsg(.response),
        }),
        .stop => fx.cancel(fetch_key),
        .line => |line| model.recordLine(line),
        .response => |response| {
            model.record(response);
            if (test_refetch_on_response) {
                test_refetch_on_response = false;
                fx.fetch(.{
                    .key = fetch_key,
                    .url = test_url,
                    .on_response = FetchEffects.responseMsg(.response),
                });
            }
        },
    }
}

fn fetchView(ui: *FetchApp.Ui, model: *const FetchModel) FetchApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} responses", .{model.response_count})),
        ui.button(.{ .on_press = .start }, "Fetch"),
        ui.button(.{ .on_press = .stop }, "Cancel"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *FetchApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(FetchApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = FetchApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-fetch",
            .scene = fetch_scene,
            .canvas_label = canvas_label,
            .update_fx = fetchUpdate,
            .view = fetchView,
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

// ------------------------------------------------------------ fake executor

test "fake executor captures fetch requests and feeds synthetic responses" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://api.example.test/sandbox/run";
    test_method = .POST;
    test_headers = &.{.{ .name = "authorization", .value = "Bearer token" }};
    test_payload = "{\"prompt\":\"hi\"}";
    test_timeout_ms = 1234;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // The request was recorded, not executed.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    const request = fx.pendingFetchAt(0).?;
    try std.testing.expectEqual(fetch_key, request.key);
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqualStrings("https://api.example.test/sandbox/run", request.url);
    try std.testing.expectEqual(@as(usize, 1), request.headers.len);
    try std.testing.expectEqualStrings("authorization", request.headers[0].name);
    try std.testing.expectEqualStrings("Bearer token", request.headers[0].value);
    try std.testing.expectEqualStrings("{\"prompt\":\"hi\"}", request.body);
    try std.testing.expectEqual(@as(usize, 1), fx.activeCount());

    // The synthetic response drains through the wake path into update.
    try fx.feedResponse(fetch_key, 200, "{\"ok\":true}");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", h.app_state.model.body());
    try std.testing.expect(!h.app_state.model.truncated);

    // The response is terminal: the slot is free and the key is gone.
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedResponse(fetch_key, 200, "late"));
}

test "binary bodies with zeros and high bits round-trip through the fake executor" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "http://images.example.test/avatar.png";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    var pattern: [1024]u8 = undefined;
    for (&pattern, 0..) |*byte, index| byte.* = @truncate(index *% 7);
    pattern[0] = 0;
    pattern[1] = 0xFF;
    pattern[2] = '\n';
    try fx.feedResponse(fetch_key, 200, &pattern);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 1024), h.app_state.model.body_len);
    try std.testing.expectEqualSlices(u8, &pattern, h.app_state.model.body()[0..1024]);
}

test "fake responses over the body cap arrive truncated and flagged" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "http://api.example.test/huge";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    const big = try std.testing.allocator.alloc(u8, effects_mod.max_effect_body_bytes + 100);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    big[0] = 'A';
    try fx.feedResponse(fetch_key, 200, big);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expect(h.app_state.model.truncated);
    try std.testing.expectEqual(effects_mod.max_effect_body_bytes, h.app_state.model.body_len);
    try std.testing.expectEqual(@as(u8, 'A'), h.app_state.model.body()[0]);
}

test "cancel rewrites a queued fake response to cancelled and stays terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "http://api.example.test/slow";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedResponse(fetch_key, 200, "arrived before the cancel");

    // Cancel BEFORE draining: the queued response must deliver as
    // `.cancelled` with an empty body, exactly once.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.cancelled, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 0), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);

    // Nothing after the terminal Msg; the slot is reusable.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
}

test "cancelling a fake fetch with no response yet delivers one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "http://api.example.test/never";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.cancelled, h.app_state.model.outcome.?);
    try std.testing.expectError(error.EffectNotFound, fx.feedResponse(fetch_key, 200, "late"));

    // Cancelling the now-unknown key again is a no-op.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
}

test "fake executor records stream fetches and feeds lines then the terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://sandbox.example.test/v2/sandboxes/sessions/abc/cmd";
    test_method = .POST;
    test_headers = &.{};
    test_payload = "{\"cmd\":\"claude -p\"}";
    test_timeout_ms = 600_000;
    test_response_mode = .stream;
    defer test_response_mode = .buffered;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    const request = fx.pendingFetchAt(0).?;
    try std.testing.expectEqual(effects_mod.FetchResponseMode.stream, request.response);
    try std.testing.expectEqualStrings("{\"cmd\":\"claude -p\"}", request.body);

    // Fed lines arrive as on_line Msgs, in order.
    try fx.feedLine(fetch_key, "{\"event\":\"stdout\",\"seq\":1}");
    try fx.feedLine(fetch_key, "{\"event\":\"stdout\",\"seq\":2}");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("{\"event\":\"stdout\",\"seq\":1}", h.app_state.model.lineAt(0));
    try std.testing.expectEqualStrings("{\"event\":\"stdout\",\"seq\":2}", h.app_state.model.lineAt(1));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.response_count);

    // The terminal carries the status and an empty body; the slot
    // retires and the key stops feeding.
    try fx.feedResponse(fetch_key, 200, "");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(fetch_key, "late"));
}

test "feedLine on a buffered fetch reports EffectNotFound" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "http://api.example.test/once";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .buffered;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(fetch_key, "nope"));
    try fx.feedResponse(fetch_key, 200, "done");
    try h.drainWakes();
}

test "cancelling a fake stream fetch discards queued lines and delivers one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://sandbox.example.test/stream";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .stream;
    defer test_response_mode = .buffered;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(fetch_key, "streamed before the cancel");

    // Cancel BEFORE draining: the queued line must never become a Msg.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.cancelled, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(fetch_key, "late"));
}

test "stream fetches honor a raised per-fetch line bound and reject over-ceiling requests" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://sandbox.example.test/stream";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .stream;
    test_max_line_bytes = 16 * 1024;
    defer {
        test_response_mode = .buffered;
        test_max_line_bytes = effects_mod.max_effect_line_bytes;
    }
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 16 * 1024), fx.pendingFetchAt(0).?.max_line_bytes);

    const long_line = try std.testing.allocator.alloc(u8, 6000);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'z');
    try fx.feedLine(fetch_key, long_line);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.truncated_lines);
    try std.testing.expectEqual(@as(usize, 6000), h.app_state.model.last_line_len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, long_line), h.app_state.model.last_line_hash);
    try fx.feedResponse(fetch_key, 200, "");
    try h.drainWakes();

    // Over-ceiling bound: rejected terminal, nothing started.
    test_max_line_bytes = effects_mod.max_effect_line_bytes_ceiling + 1;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.rejected, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
}

const RejectModel = struct {
    rejected: u32 = 0,
    other: u32 = 0,
};

const RejectMsg = union(enum) {
    bad_url,
    bad_scheme,
    long_url,
    many_headers,
    bad_header,
    huge_payload,
    duplicate,
    exhaust,
    response: effects_mod.EffectResponse,
};

const RejectApp = ui_app_model.UiApp(RejectModel, RejectMsg);
const RejectEffects = RejectApp.Effects;

fn rejectFetchUpdate(model: *RejectModel, msg: RejectMsg, fx: *RejectEffects) void {
    const on_response = RejectEffects.responseMsg(.response);
    switch (msg) {
        .bad_url => fx.fetch(.{ .key = 1, .url = "not a url at all", .on_response = on_response }),
        .bad_scheme => fx.fetch(.{ .key = 2, .url = "ftp://example.test/file", .on_response = on_response }),
        .long_url => {
            const long = [_]u8{'a'} ** (effects_mod.max_effect_url_bytes + 1);
            fx.fetch(.{ .key = 3, .url = &long, .on_response = on_response });
        },
        .many_headers => {
            const header: std.http.Header = .{ .name = "x-h", .value = "v" };
            const headers = [_]std.http.Header{header} ** (effects_mod.max_effect_fetch_headers + 1);
            fx.fetch(.{ .key = 4, .url = "http://example.test/", .headers = &headers, .on_response = on_response });
        },
        .bad_header => fx.fetch(.{
            .key = 5,
            .url = "http://example.test/",
            .headers = &.{.{ .name = "evil", .value = "a\r\nx-injected: yes" }},
            .on_response = on_response,
        }),
        .huge_payload => {
            const huge = [_]u8{'p'} ** (effects_mod.max_effect_fetch_payload_bytes + 1);
            fx.fetch(.{ .key = 6, .url = "http://example.test/", .body = &huge, .on_response = on_response });
        },
        .duplicate => {
            fx.fetch(.{ .key = 7, .url = "http://example.test/", .on_response = on_response });
            fx.fetch(.{ .key = 7, .url = "http://example.test/", .on_response = on_response });
        },
        .exhaust => {
            var key: u64 = 100;
            while (key < 100 + effects_mod.max_effects + 1) : (key += 1) {
                fx.fetch(.{ .key = key, .url = "http://example.test/", .on_response = on_response });
            }
        },
        .response => |response| switch (response.outcome) {
            .rejected => model.rejected += 1,
            else => model.other += 1,
        },
    }
}

fn rejectFetchView(ui: *RejectApp.Ui, model: *const RejectModel) RejectApp.Ui.Node {
    return ui.text(.{}, ui.fmt("{d} rejected", .{model.rejected}));
}

test "fetch capacity and validation failures reject loudly, never silently" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(RejectApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RejectApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-fetch-reject",
        .scene = fetch_scene,
        .canvas_label = canvas_label,
        .update_fx = rejectFetchUpdate,
        .view = rejectFetchView,
    });
    defer app_state.deinit();
    app_state.effects.executor = .fake;
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

    // Validation failures: each delivers exactly one `.rejected`
    // response without claiming a slot.
    const validation_cases = [_]RejectMsg{ .bad_url, .bad_scheme, .long_url, .many_headers, .bad_header, .huge_payload };
    for (validation_cases, 1..) |msg, expected| {
        try app_state.dispatch(&harness.runtime, 1, msg);
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try std.testing.expectEqual(@as(u32, @intCast(expected)), app_state.model.rejected);
        try std.testing.expectEqual(@as(usize, 0), app_state.effects.activeCount());
    }

    // Duplicate active key: the second fetch is rejected.
    try app_state.dispatch(&harness.runtime, 1, .duplicate);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 7), app_state.model.rejected);
    try std.testing.expectEqual(@as(usize, 1), app_state.effects.activeCount());
    try app_state.effects.feedResponse(7, 200, "");
    try harness.runtime.dispatchPlatformEvent(app, .wake);

    // One more fetch than there are slots: exactly one rejection.
    try app_state.dispatch(&harness.runtime, 1, .exhaust);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 8), app_state.model.rejected);
    try std.testing.expectEqual(@as(usize, effects_mod.max_effects), app_state.effects.activeCount());
}

// --------------------------------------------------------- fixture server

/// A loopback HTTP fixture: `std.http.Server` on its own `Io.Threaded`,
/// accepting on an ephemeral 127.0.0.1 port, one connection at a time.
/// The accept loop runs as a cancelable task so `stop` can interrupt a
/// blocked accept, read, or the deliberate `/hang` sleep.
const Fixture = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    accept_future: std.Io.Future(void),
    /// Set by `stop` BEFORE it cancels the accept task. Io cancellation
    /// signals only the next cancelation point once, so a handler that
    /// consumes it (the `/hang` sleep) would otherwise loop back into a
    /// forever-blocking `accept` and deadlock `stop`'s await.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set once a request head has been received; the raw head bytes
    /// let tests assert what the client actually sent on the wire.
    saw_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    head_storage: [4096]u8 = undefined,
    head_len: usize = 0,

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
        self.allocator.destroy(self.threaded);
        allocator.destroy(self);
    }

    fn url(self: *const Fixture, buffer: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    fn headContains(self: *const Fixture, needle: []const u8) bool {
        if (!self.saw_request.load(.acquire)) return false;
        return std.mem.indexOf(u8, self.head_storage[0..self.head_len], needle) != null;
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

        const head_len = @min(request.head_buffer.len, self.head_storage.len);
        @memcpy(self.head_storage[0..head_len], request.head_buffer[0..head_len]);
        self.head_len = head_len;
        self.saw_request.store(true, .release);

        const target = request.head.target;
        if (std.mem.eql(u8, target, "/hello")) {
            try request.respond("hello from the fixture", .{ .keep_alive = false });
        } else if (std.mem.eql(u8, target, "/teapot")) {
            try request.respond("short and stout", .{ .status = .teapot, .keep_alive = false });
        } else if (std.mem.eql(u8, target, "/echo")) {
            var body_buffer: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&recv_buffer);
            const body_len = try body_reader.readSliceShort(&body_buffer);
            try request.respond(body_buffer[0..body_len], .{ .keep_alive = false });
        } else if (std.mem.eql(u8, target, "/binary")) {
            var pattern: [4096]u8 = undefined;
            fillBinaryPattern(&pattern);
            try request.respond(&pattern, .{
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }},
            });
        } else if (std.mem.eql(u8, target, "/big")) {
            const big = try self.allocator.alloc(u8, effects_mod.max_effect_body_bytes + 4096);
            defer self.allocator.free(big);
            for (big, 0..) |*byte, index| byte.* = @truncate(index);
            try request.respond(big, .{ .keep_alive = false });
        } else if (std.mem.eql(u8, target, "/hang")) {
            // Never respond; the sleep ends when `stop` cancels the
            // accept task (this is the timeout/cancel fixture).
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(120_000), .awake) catch return;
        } else if (std.mem.eql(u8, target, "/ndjson")) {
            // A slow NDJSON stream: each event flushed on its own, with
            // real time between them (the sandbox-exec shape).
            var stream_buffer: [512]u8 = undefined;
            var response = try request.respondStreaming(&stream_buffer, .{ .respond_options = .{ .keep_alive = false } });
            const lines = [_][]const u8{
                "{\"event\":\"start\",\"seq\":1}\n",
                "{\"event\":\"stdout\",\"seq\":2,\"data\":\"hello\"}\n",
                "{\"event\":\"exit\",\"seq\":3,\"code\":0}\n",
            };
            for (lines) |line| {
                try response.writer.writeAll(line);
                try response.writer.flush();
                try response.flush();
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            }
            try response.end();
        } else if (std.mem.eql(u8, target, "/ndjson-big")) {
            // One event far beyond the default 4 KiB line cap.
            var stream_buffer: [512]u8 = undefined;
            var response = try request.respondStreaming(&stream_buffer, .{ .respond_options = .{ .keep_alive = false } });
            const big_line = try self.allocator.alloc(u8, 6001);
            defer self.allocator.free(big_line);
            @memset(big_line, 'e');
            big_line[6000] = '\n';
            try response.writer.writeAll(big_line);
            try response.end();
        } else if (std.mem.eql(u8, target, "/ndjson-hang")) {
            // Two events, then the connection stays open forever — the
            // cancel-mid-stream fixture.
            var stream_buffer: [512]u8 = undefined;
            var response = try request.respondStreaming(&stream_buffer, .{ .respond_options = .{ .keep_alive = false } });
            try response.writer.writeAll("{\"event\":\"start\"}\n{\"event\":\"running\"}\n");
            try response.writer.flush();
            try response.flush();
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(120_000), .awake) catch return;
        } else {
            try request.respond("nope", .{ .status = .not_found, .keep_alive = false });
        }
    }
};

fn fillBinaryPattern(buffer: []u8) void {
    for (buffer, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    buffer[0] = 0;
    buffer[1] = 0xFF;
    buffer[2] = '\n';
    buffer[3] = 0x80;
}

fn waitForResponse(h: *Harness) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        try h.drainWakes();
        if (h.app_state.model.response_count > 0) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

fn waitForStreamLines(h: *Harness, count: usize) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        try h.drainWakes();
        if (h.app_state.model.line_count >= count) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

test "real stream fetch frames a slow NDJSON body into line msgs with a terminal status" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/ndjson");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .stream;
    defer test_response_mode = .buffered;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);
    try std.testing.expectEqual(@as(usize, 3), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("{\"event\":\"start\",\"seq\":1}", h.app_state.model.lineAt(0));
    try std.testing.expectEqualStrings("{\"event\":\"stdout\",\"seq\":2,\"data\":\"hello\"}", h.app_state.model.lineAt(1));
    try std.testing.expectEqualStrings("{\"event\":\"exit\",\"seq\":3,\"code\":0}", h.app_state.model.lineAt(2));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.truncated_lines);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real stream fetch delivers an event beyond the default line cap intact with a raised bound" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/ndjson-big");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .stream;
    test_max_line_bytes = 16 * 1024;
    defer {
        test_response_mode = .buffered;
        test_max_line_bytes = effects_mod.max_effect_line_bytes;
    }
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.truncated_lines);
    const expected = try std.testing.allocator.alloc(u8, 6000);
    defer std.testing.allocator.free(expected);
    @memset(expected, 'e');
    try std.testing.expectEqual(@as(usize, 6000), h.app_state.model.last_line_len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, expected), h.app_state.model.last_line_hash);
}

test "real stream fetch cancels mid-stream with exactly one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/ndjson-hang");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .stream;
    defer test_response_mode = .buffered;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // Lines flow while the connection stays open...
    try waitForStreamLines(&h, 2);
    try std.testing.expectEqualStrings("{\"event\":\"start\"}", h.app_state.model.lineAt(0));
    try std.testing.expectEqualStrings("{\"event\":\"running\"}", h.app_state.model.lineAt(1));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.response_count);

    // ...and cancel ends the stream with exactly one cancelled terminal.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try waitForResponse(&h);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.cancelled, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);

    // Nothing for that fetch after the terminal Msg.
    const lines_after_cancel = h.app_state.model.line_count;
    const io = std.testing.io;
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try h.drainWakes();
    try std.testing.expectEqual(lines_after_cancel, h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real fetch delivers a 200 response body from the fixture server" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/hello");
    test_method = .GET;
    test_headers = &.{.{ .name = "x-zero-probe", .value = "42" }};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expectEqualStrings("hello from the fixture", h.app_state.model.body());
    try std.testing.expect(!h.app_state.model.truncated);
    // The custom header went out on the wire.
    try std.testing.expect(fixture.headContains("x-zero-probe: 42"));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real fetch reports non-2xx statuses as delivered responses" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/teapot");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 418), h.app_state.model.status);
    try std.testing.expectEqualStrings("short and stout", h.app_state.model.body());
}

test "real fetch round-trips a POST payload through the echo route" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/echo");
    test_method = .POST;
    test_headers = &.{};
    test_payload = "the payload rides in the fetch buffer";
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expectEqualStrings("the payload rides in the fetch buffer", h.app_state.model.body());
}

test "real fetch preserves binary bodies byte for byte" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/binary");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    var expected: [4096]u8 = undefined;
    fillBinaryPattern(&expected);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 4096), h.app_state.model.body_len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, &expected), h.app_state.model.body_hash);
    try std.testing.expectEqualSlices(u8, &expected, h.app_state.model.body()[0..4096]);
}

test "real fetch truncates bodies over the cap and says so" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/big");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 200), h.app_state.model.status);
    try std.testing.expect(h.app_state.model.truncated);
    try std.testing.expectEqual(effects_mod.max_effect_body_bytes, h.app_state.model.body_len);
}

test "real fetch reports connection refused as connect_failed" {
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
    test_url = std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/", .{dead_port}) catch unreachable;
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.connect_failed, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 0), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);
}

test "a fetch whose exchange cannot start cancellably is rejected, never run inline" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    // Pin the no-capacity path through the injectable seam (the real
    // trigger — the executor refusing `std.Io.concurrent` — needs
    // resource exhaustion). If a regression ran the exchange inline
    // instead, this loopback connect would fail fast as
    // `.connect_failed` and the assert below would catch the lie.
    fx.fetch_concurrent_start = false;

    var url_buffer: [128]u8 = undefined;
    test_url = std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:9/", .{}) catch unreachable;
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    // Exactly one honest `.rejected` terminal — the fetch never
    // started — counted through the rejection seam.
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.rejected, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);
    try std.testing.expectEqual(@as(u16, 0), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);
    try std.testing.expectEqual(@as(u32, 1), fx.fetch_start_rejections.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());

    // Teardown returns promptly: no uncancelable inline exchange is
    // left for the unconditional fetch join to wait on.
    const start_ns = clock_mod.monotonicNanoseconds();
    fx.deinit();
    const elapsed_ms = (clock_mod.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;
    try std.testing.expect(elapsed_ms < 10_000);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }
}

test "real fetch times out against a hanging route" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/hang");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = 250;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.timed_out, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(u16, 0), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real fetch cancels mid-flight with exactly one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fixture = try Fixture.start(std.testing.allocator);
    defer fixture.stop();

    var url_buffer: [128]u8 = undefined;
    test_url = fixture.url(&url_buffer, "/hang");
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // Let the exchange get in flight, then cancel it.
    const io = std.testing.io;
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try waitForResponse(&h);

    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.cancelled, h.app_state.model.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.body_len);

    // Nothing for that fetch after the terminal Msg.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "a fetch response still undelivered occupies its key against a second fetch; delivery frees it" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://api.example.com/v1/data";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .buffered;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());

    // The fed response queues the terminal and parks the slot in
    // `.draining` — posted but undelivered. A second fetch of the same
    // key inside that window must reject: under session replay the
    // first request is still a parked `.running` fake here (its
    // journaled response feeds at the recorded delivery position), so
    // a live accept would journal a Msg stream replay rejects.
    try fx.feedResponse(fetch_key, 200, "first");
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());

    // Delivery order: the staged rejection first (loop-side pending),
    // then the queued response.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);
    try std.testing.expectEqual(effects_mod.EffectFetchOutcome.ok, h.app_state.model.outcome.?);

    // The window ends at delivery: the same key fetches again.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try fx.feedResponse(fetch_key, 201, "second");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 3), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(u16, 201), h.app_state.model.status);
}

test "an update that refetches the same key from its own response parks instead of rejecting" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_url = "https://api.example.com/v1/poll";
    test_method = .GET;
    test_headers = &.{};
    test_payload = null;
    test_timeout_ms = effects_mod.default_effect_fetch_timeout_ms;
    test_response_mode = .buffered;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    test_refetch_on_response = true;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedResponse(fetch_key, 200, "first");

    // The drain retires the slot BEFORE the terminal Msg reaches
    // update, so the handler's refetch of its own key is a fresh
    // accepted fetch — the poll idiom must not regress.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.rejected_count);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());

    // The refetched occupancy is fully live: its own terminal delivers.
    try fx.feedResponse(fetch_key, 201, "second");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.response_count);
    try std.testing.expectEqual(@as(u16, 201), h.app_state.model.status);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.rejected_count);
}
