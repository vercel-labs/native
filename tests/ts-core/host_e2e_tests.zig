//! End-to-end: a GENUINELY TRANSPILED core (tests/ts-core/fixture.ts,
//! emitted by the repo's own transpiler at build time — see the
//! ts-core-e2e wiring in build.zig) driven through the real
//! runtime-core dispatch path: the first-class `TsUiApp(core)` adapter
//! (the committed TS model IS the app model — the view below reads it
//! straight off the UiApp), the null platform's live timer services, a
//! stub `HostCallBinding` standing in for host services, and the
//! session recorder. Timers fire, requests round-trip, replace/cancel
//! keep the wire contract, `Cmd.now` stamps synchronously, a REAL
//! subprocess streams lines into the core (and dies to a mid-stream
//! cancel), audio events flow the soundboard way (the fake channel's
//! scripted feed), and recorded sessions — streams included — replay
//! to identical state without a host call or a process launch.
//!
//! The markup-view / automation / pixel-fingerprint guarantees run in
//! markup_e2e_tests.zig over a second transpiled core.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const fixture = @import("ts_core_fixture");

const runtime_ns = native_sdk.runtime;
const Adapter = native_sdk.TsUiApp(fixture);
/// The same instantiation the adapter drives (comptime memoization):
/// assertions may read the committed model straight off the bridge.
const Bridge = Adapter.Host;

test {
    _ = @import("markup_e2e_tests.zig");
}

const canvas_label = "ts-core-canvas";

const e2e_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const e2e_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Core",
    .width = 400,
    .height = 300,
    .views = &e2e_views,
}};
const e2e_scene: native_sdk.ShellConfig = .{ .windows = &e2e_windows };

const App = Adapter.App;

/// A hand-written builder view over the COMMITTED TS MODEL — the model
/// parameter is the UiApp-held root the adapter refreshes each
/// dispatch, so this view (and the replay fingerprints derived from
/// what it renders) pins the transpiled core's state directly.
fn e2eView(ui: *App.Ui, model: *const fixture.Model) App.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("ticks {d} failures {d}", .{ model.ticks, model.failures })),
        ui.text(.{}, ui.fmt("status {s}", .{model.status})),
    });
}

fn e2eCommand(name: []const u8) ?fixture.Msg {
    if (std.mem.eql(u8, name, "core.toggle")) return .toggle;
    if (std.mem.eql(u8, name, "core.refresh")) return .refresh;
    if (std.mem.eql(u8, name, "core.abort")) return .abort;
    if (std.mem.eql(u8, name, "core.stamp")) return .stamp;
    if (std.mem.eql(u8, name, "core.note")) return .note;
    if (std.mem.eql(u8, name, "core.save")) return .save;
    if (std.mem.eql(u8, name, "core.load")) return .load;
    if (std.mem.eql(u8, name, "core.get")) return .get;
    if (std.mem.eql(u8, name, "core.share")) return .share;
    if (std.mem.eql(u8, name, "core.paste")) return .paste;
    if (std.mem.eql(u8, name, "core.later")) return .later;
    if (std.mem.eql(u8, name, "core.halt")) return .halt;
    if (std.mem.eql(u8, name, "core.run")) return .run;
    if (std.mem.eql(u8, name, "core.hang")) return .hang;
    if (std.mem.eql(u8, name, "core.kill")) return .kill;
    if (std.mem.eql(u8, name, "core.play")) return .play;
    if (std.mem.eql(u8, name, "core.pause")) return .pause_music;
    if (std.mem.eql(u8, name, "core.volume")) return .set_volume;
    if (std.mem.eql(u8, name, "core.stopmusic")) return .stop_music;
    if (std.mem.eql(u8, name, "core.cover")) return .show_cover;
    if (std.mem.eql(u8, name, "core.coveragain")) return .show_cover_again;
    if (std.mem.eql(u8, name, "core.covernext")) return .load_next;
    if (std.mem.eql(u8, name, "core.covertop")) return .load_top;
    if (std.mem.eql(u8, name, "core.coverpast")) return .load_past;
    return null;
}

/// The fixture's literal store path (cwd-relative, under the zig
/// cache like every tmp-dir artifact) and its parent, deleted around
/// tests so every run starts from an absent store.
const store_path = ".zig-cache/tmp/ts-core-e2e/store.bin";
const store_dir = ".zig-cache/tmp/ts-core-e2e";

fn removeStore() void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, store_dir) catch {};
}

fn e2eOptions() App.Options {
    return .{
        .name = "ts-core-e2e",
        .scene = e2e_scene,
        .canvas_label = canvas_label,
        .view = e2eView,
        .on_command = e2eCommand,
    };
}

/// The boot request's engine key: the bridge assigns table slot 0 to
/// the first issued request, deterministically.
const status_request_key: u64 = runtime_ns.ts_core_request_key_base + 0;

/// The subscription timer's platform id: bridge timer slot 0 lands in
/// engine timer slot 0.
const tick_platform_id: u64 = runtime_ns.effect_timer_platform_id_base + 0;

/// The first named engine op (readFile/writeFile/fetch/clipboardRead)
/// takes bridge op slot 0, deterministically in issue order.
const first_effect_key: u64 = runtime_ns.ts_core_effect_key_base + 0;

/// The delay's platform id: with the subscription tick occupying
/// engine timer slot 0 from boot, the first armed delay lands in
/// engine timer slot 1.
const delay_platform_id: u64 = runtime_ns.effect_timer_platform_id_base + 1;

/// The stub host service: records sends and parks requests (name/key)
/// for the test to answer through `feedHostResult` — an async host in
/// miniature.
const HostStub = struct {
    var send_count: usize = 0;
    var last_send_name: [64]u8 = undefined;
    var last_send_name_len: usize = 0;
    var last_send_payload: [64]u8 = undefined;
    var last_send_payload_len: usize = 0;
    var request_count: usize = 0;
    var last_request_name: [64]u8 = undefined;
    var last_request_name_len: usize = 0;
    var last_request_payload: [64]u8 = undefined;
    var last_request_payload_len: usize = 0;
    var last_request_key: u64 = 0;
    var cancel_count: usize = 0;

    fn reset() void {
        send_count = 0;
        request_count = 0;
        cancel_count = 0;
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = context;
        send_count += 1;
        @memcpy(last_send_name[0..name.len], name);
        last_send_name_len = name.len;
        @memcpy(last_send_payload[0..payload.len], payload);
        last_send_payload_len = payload.len;
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = context;
        request_count += 1;
        @memcpy(last_request_name[0..name.len], name);
        last_request_name_len = name.len;
        @memcpy(last_request_payload[0..payload.len], payload);
        last_request_payload_len = payload.len;
        last_request_key = key;
    }

    fn cancelNotice(context: *anyopaque, key: u64) void {
        _ = context;
        _ = key;
        cancel_count += 1;
    }

    fn binding() native_sdk.HostCallBinding {
        return .{
            .context = @ptrCast(&stub_context),
            .send_fn = send,
            .request_fn = request,
            .cancel_fn = cancelNotice,
        };
    }

    var stub_context: u8 = 0;
};

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    clock: native_sdk.TestClock,

    fn create() !*Harness {
        return createFull(null, .real);
    }

    /// A harness whose effects channel runs the fake executor: named
    /// engine ops park in fake slots for `feed*` answers (the fetch
    /// tests — real-mode fetch would reach the network).
    fn createFake() !*Harness {
        return createFull(null, .fake);
    }

    fn createRecorded(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        return createFull(recorder, .real);
    }

    /// `recorder` (if any) attaches BEFORE start so the journal holds
    /// the app_start and installing-frame events — replay re-runs
    /// init_fx (and its boot request) from those.
    fn createFull(recorder: ?*runtime_ns.SessionRecorder, executor: runtime_ns.EffectExecutor) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.clock = .{};
        self.clock.setWallMs(50_000);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = native_sdk.geometry.SizeF.init(400, 300),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.runtime.options.session_recorder = recorder;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{}, e2eOptions());
        // Bind the stub host services, the executor mode, and the
        // deterministic clock BEFORE install: init_fx issues the boot
        // request.
        self.app_state.effects.bindHostCalls(HostStub.binding());
        self.app_state.effects.executor = executor;
        self.app_state.effects.clock = self.clock.clock();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = native_sdk.geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.app_state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    fn fireTick(self: *Harness, timestamp_ns: u64) !bool {
        const event = self.harness.null_platform.fireTimer(tick_platform_id, timestamp_ns) orelse return false;
        try self.harness.runtime.dispatchPlatformEvent(self.app, event);
        return true;
    }

    fn tickArmed(self: *Harness) bool {
        const timer = self.harness.null_platform.startedTimer(tick_platform_id) orelse return false;
        return timer.active;
    }

    fn fireDelay(self: *Harness, timestamp_ns: u64) !bool {
        const event = self.harness.null_platform.fireTimer(delay_platform_id, timestamp_ns) orelse return false;
        try self.harness.runtime.dispatchPlatformEvent(self.app, event);
        return true;
    }

    fn delayArmed(self: *Harness) bool {
        const timer = self.harness.null_platform.startedTimer(delay_platform_id) orelse return false;
        return timer.active;
    }

    /// Wall-clock budget for the real-executor waits below. These
    /// waits prove CORRECTNESS (a real child's lines and exit arrive),
    /// never latency, and they poll — a healthy run returns in
    /// milliseconds no matter how large the bound is. The generosity
    /// is for congested shared CI runners, where scheduling a /bin/sh
    /// child (or reaping a killed one) has been observed to take tens
    /// of seconds under load.
    const wait_budget_ms: usize = 200_000;

    /// Wait for a real-executor worker's terminal to reach the queue
    /// WITHOUT dispatching events — the wait leaves no trace in a
    /// recorded session, so the one `wake` that drains afterwards
    /// keeps journals byte-identical across recordings.
    fn waitPending(self: *Harness) !void {
        const io = std.testing.io;
        var waited_ms: usize = 0;
        while (waited_ms < wait_budget_ms) : (waited_ms += 10) {
            if (self.app_state.effects.hasPending()) return;
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        }
        return self.timedOut();
    }

    /// Wait for every running effect to FINISH (not just for the first
    /// queued entry) — the streaming determinism wait: a spawned
    /// child's lines and exit all sit in the queue before the one
    /// `wake` drains them, so two recordings journal identical event
    /// boundaries regardless of worker timing.
    fn waitIdle(self: *Harness) !void {
        const io = std.testing.io;
        var waited_ms: usize = 0;
        while (waited_ms < wait_budget_ms) : (waited_ms += 10) {
            if (self.app_state.effects.activeCount() == 0 and self.app_state.effects.hasPending()) return;
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        }
        return self.timedOut();
    }

    /// A blown wait budget must fail THIS test only: tear the effects
    /// channel down right here — kill the real children, join every
    /// worker thread — before surfacing the error, so a straggling
    /// child can never bleed into the next test's harness (the
    /// teardown is idempotent; the deferred `destroy` repeats it
    /// inertly).
    fn timedOut(self: *Harness) error{TestTimedOut} {
        self.app_state.effects.deinit();
        return error.TestTimedOut;
    }
};

test "the transpiled core boots through init_fx: boot request and subscription timer are live" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();

    // The init command reached the stub host service before the first
    // frame, with the bridge's deterministic engine key.
    try std.testing.expectEqual(@as(usize, 1), HostStub.request_count);
    try std.testing.expectEqualStrings("status.read", HostStub.last_request_name[0..HostStub.last_request_name_len]);
    try std.testing.expectEqualStrings("boot", HostStub.last_request_payload[0..HostStub.last_request_payload_len]);
    try std.testing.expectEqual(status_request_key, HostStub.last_request_key);

    // The model-declared subscription armed a REAL platform timer.
    try std.testing.expect(h.tickArmed());

    // The boot model committed — and the UiApp-held root IS the
    // committed value (the adapter's refresh), not a shim.
    try std.testing.expect(Bridge.model().polling);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().ticks);
    try std.testing.expect(h.app_state.model.polling);
    try std.testing.expectEqual(@as(i64, 0), h.app_state.model.ticks);
}

test "requests round-trip, replace, and cancel through the real dispatch path" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // The host answers the boot request; the ok arm lands on the next
    // drain and the bytes commit into the core's model heap — visible
    // through the bridge and the UiApp-held root alike.
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();
    try std.testing.expectEqualStrings("ready", Bridge.model().status);
    try std.testing.expectEqualStrings("ready", h.app_state.model.status);

    // refresh re-issues the same wire key: the stub sees a second
    // request under the SAME engine key (replace, not a new slot).
    try h.menu("core.refresh");
    try std.testing.expectEqual(@as(usize, 2), HostStub.request_count);
    try std.testing.expectEqual(status_request_key, HostStub.last_request_key);
    try std.testing.expectEqualStrings("ready", HostStub.last_request_payload[0..HostStub.last_request_payload_len]);

    // The err route counts a failure.
    try fx.feedHostResult(status_request_key, false, "boom");
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().failures);
    try std.testing.expectEqualStrings("ready", Bridge.model().status);

    // cancel drops the in-flight request silently: the host gets the
    // abort notice, a late answer finds nothing, neither arm runs.
    try h.menu("core.refresh");
    try h.menu("core.abort");
    try std.testing.expectEqual(@as(usize, 1), HostStub.cancel_count);
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(status_request_key, true, "late"));
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().failures);
    try std.testing.expectEqualStrings("ready", Bridge.model().status);
}

test "subscription timers fire through the platform and reconcile on model changes" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();

    // A platform fire dispatches the tick arm with the time in ms.
    try std.testing.expect(try h.fireTick(250_000_000));
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().ticks);
    try std.testing.expectEqual(@as(f64, 250), Bridge.model().lastTickAt);

    // Pausing removes the timer from the platform; a stale fire event
    // dispatches nothing.
    try h.menu("core.toggle");
    try std.testing.expect(!h.tickArmed());
    try std.testing.expect(!try h.fireTick(300_000_000));
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().ticks);

    // Resuming re-arms the same deterministic slot.
    try h.menu("core.toggle");
    try std.testing.expect(h.tickArmed());
    try std.testing.expect(try h.fireTick(400_000_000));
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().ticks);
    try std.testing.expectEqual(@as(f64, 400), Bridge.model().lastTickAt);
}

test "Cmd.now stamps synchronously and host_bytes reaches the stub service" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();

    // now: the stamped arm ran within the dispatch, with the bound
    // (test) clock's journal-ready reading.
    try h.menu("core.stamp");
    try std.testing.expectEqual(@as(f64, 50_000), Bridge.model().stampMs);

    // host_bytes: fire-and-forget to the named service.
    try h.menu("core.note");
    try std.testing.expectEqual(@as(usize, 1), HostStub.send_count);
    try std.testing.expectEqualStrings("blob.put", HostStub.last_send_name[0..HostStub.last_send_name_len]);
    try std.testing.expectEqualStrings("hi", HostStub.last_send_payload[0..HostStub.last_send_payload_len]);
}

// -------------------------------------------------- named engine ops

test "writeFile and readFile round-trip real disk through the transpiled core" {
    const io = std.testing.io;
    HostStub.reset();
    removeStore();
    defer removeStore();
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // Give the model content to persist.
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // save: the core's write_file record reaches the REAL executor and
    // the bytes land on disk whole; the payload-less ok arm counts.
    try h.menu("core.save");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().saved);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, store_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(on_disk);
    try std.testing.expectEqualStrings("ready", on_disk);

    // Overwrite the model, then load: the read routes the ok arm with
    // the disk bytes and they commit into the model heap.
    try h.menu("core.refresh");
    try fx.feedHostResult(status_request_key, true, "stale");
    try h.wake();
    try std.testing.expectEqualStrings("stale", Bridge.model().status);
    try h.menu("core.load");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqualStrings("ready", Bridge.model().status);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().failures);

    // A missing store routes the err arm with the outcome name.
    removeStore();
    try h.menu("core.load");
    try h.waitPending();
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().failures);
    try std.testing.expectEqualStrings("not_found", Bridge.model().lastErr);
    try std.testing.expectEqualStrings("ready", Bridge.model().status);
}

test "clipboardWrite and clipboardRead ride the platform pasteboard" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // share: fire-and-forget onto the real (null-platform) pasteboard.
    try h.menu("core.share");
    try h.wake();
    try std.testing.expectEqual(@as(usize, 1), h.harness.null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("ready", h.harness.null_platform.lastClipboardData());

    // Change the model, then paste: the read's ok arm restores it.
    try h.menu("core.refresh");
    try fx.feedHostResult(status_request_key, true, "fresh");
    try h.wake();
    try std.testing.expectEqualStrings("fresh", Bridge.model().status);
    try h.menu("core.paste");
    try h.wake();
    try std.testing.expectEqualStrings("ready", Bridge.model().status);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().failures);
}

test "fetch parks on the engine and routes the { status, body } record and err reasons" {
    HostStub.reset();
    const h = try Harness.createFake();
    defer h.destroy();
    const fx = &h.app_state.effects;

    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // The fetch record decodes whole: verb, url, header pair, body
    // (the model's bytes), and the explicit timeout.
    try h.menu("core.get");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0).?;
    try std.testing.expectEqual(first_effect_key, request.key);
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqualStrings("https://status.test/feed", request.url);
    try std.testing.expectEqual(@as(usize, 1), request.headers.len);
    try std.testing.expectEqualStrings("accept", request.headers[0].name);
    try std.testing.expectEqualStrings("text/plain", request.headers[0].value);
    try std.testing.expectEqualStrings("ready", request.body);

    // A non-2xx response is still the ok route: the number field takes
    // the status, the bytes field the body.
    try fx.feedResponse(first_effect_key, 404, "feed data");
    try h.wake();
    try std.testing.expectEqual(@as(f64, 404), Bridge.model().code);
    try std.testing.expectEqualStrings("feed data", Bridge.model().status);

    // A transport failure routes the err arm with the outcome name.
    try h.menu("core.get");
    try fx.feedResponseOutcome(first_effect_key, .timed_out, 0, "");
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().failures);
    try std.testing.expectEqualStrings("timed_out", Bridge.model().lastErr);
    try std.testing.expectEqual(@as(f64, 404), Bridge.model().code);
}

test "a delay arms a real platform timer, fires once, re-arms on re-issue, and cancels" {
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();

    // later: one-shot platform timer in the delay slot (the tick
    // subscription holds engine timer slot 0 from boot).
    try h.menu("core.later");
    try std.testing.expect(h.delayArmed());
    const timer = h.harness.null_platform.startedTimer(delay_platform_id).?;
    try std.testing.expectEqual(@as(u64, 150 * std.time.ns_per_ms), timer.interval_ns);
    try std.testing.expect(!timer.repeats);

    // The fire dispatches the named arm with the time in fractional ms
    // and the slot retires (one-shots self-stop).
    try std.testing.expect(try h.fireDelay(500_000_000));
    try std.testing.expectEqual(@as(f64, 500), Bridge.model().firedAt);

    // Re-issuing a live delay key re-arms the SAME slot; halt cancels
    // it silently — a later stale fire event dispatches nothing.
    try h.menu("core.later");
    try h.menu("core.later");
    try std.testing.expect(h.delayArmed());
    try h.menu("core.halt");
    try std.testing.expect(!h.delayArmed());
    try std.testing.expect(!try h.fireDelay(900_000_000));
    try std.testing.expectEqual(@as(f64, 500), Bridge.model().firedAt);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().failures);
}

// ------------------------------------------------------------- streams

/// The first spawn stream's engine key: bridge stream slot 0,
/// deterministic in issue order like every bridge table.
const job_spawn_key: u64 = runtime_ns.ts_core_spawn_key_base + 0;

test "a spawn stream runs a real subprocess: lines route in order and the exit code lands" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();

    // Retire the boot request first: the idle wait below watches the
    // engine's ACTIVE slots, and an unanswered host request would hold
    // one forever.
    try h.app_state.effects.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // A real /bin/sh child prints two lines and exits 0. Waiting for
    // the channel to go idle parks the whole stream (both lines, then
    // the exit) in the queue before one deterministic drain.
    try h.menu("core.run");
    try h.waitIdle();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().lines), 2), Bridge.model().lines);
    try std.testing.expectEqualStrings("two", Bridge.model().lastLine);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().exitCode), 0), Bridge.model().exitCode);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().failures);

    // The exit retired the stream: the wire key is free for a rerun.
    try h.menu("core.run");
    try h.waitIdle();
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().lines), 4), Bridge.model().lines);
}

test "cancelling a spawn mid-stream ends the real child and routes the err arm" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    HostStub.reset();
    const h = try Harness.create();
    defer h.destroy();
    try h.app_state.effects.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // The child would sleep 30s; the wire cancel ends it now and the
    // engine's `.cancelled` exit routes the err arm — never silent.
    try h.menu("core.hang");
    try h.menu("core.kill");
    try h.waitIdle();
    try h.wake();
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().failures);
    try std.testing.expectEqualStrings("cancelled", Bridge.model().lastErr);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().lines), 0), Bridge.model().lines);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().exitCode), -1), Bridge.model().exitCode);
}

test "audio playback streams events into the transpiled core through the fake channel" {
    HostStub.reset();
    const h = try Harness.createFake();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // play opens the stream: the engine channel records the request
    // whole under the bridge's audio key.
    try h.menu("core.play");
    const request = fx.pendingAudio().?;
    try std.testing.expectEqual(runtime_ns.ts_core_audio_key_base, request.key);
    try std.testing.expectEqualStrings("music/track.mp3", request.path);

    // The scripted event feed (the same drive soundboard's tests use)
    // routes the six-field arm: loaded, position ticks, spectrum bands.
    try fx.feedAudioEvent(.loaded, 0, 183_000, true);
    try h.wake();
    try std.testing.expect(Bridge.model().audioState == .loaded);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().durMs), 183_000), Bridge.model().durMs);
    try std.testing.expect(Bridge.model().playing);

    try fx.feedAudioEvent(.position, 1_500, 183_000, true);
    try h.wake();
    try std.testing.expect(Bridge.model().audioState == .position);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().posMs), 1_500), Bridge.model().posMs);

    var bands: [32]u8 = undefined;
    for (&bands, 0..) |*b, i| b.* = @intCast(i * 7);
    try fx.feedAudioSpectrum(bands, 2_000, 183_000);
    try h.wake();
    try std.testing.expect(Bridge.model().audioState == .spectrum);
    try std.testing.expectEqualSlices(u8, &bands, Bridge.model().bands);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().audioEvents), 3), Bridge.model().audioEvents);

    // Control verbs drive the channel in place; stop closes the stream
    // — a later feed finds no playback to receive it.
    try h.menu("core.pause");
    try std.testing.expect(!fx.audioSnapshot().playing);
    try h.menu("core.volume");
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), fx.pendingAudio().?.volume, 0.001);
    try h.menu("core.stopmusic");
    try std.testing.expect(!fx.audioSnapshot().active);
    try std.testing.expectError(error.EffectNotFound, fx.feedAudioEvent(.position, 3_000, 183_000, true));
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().audioEvents), 3), Bridge.model().audioEvents);
}

test "image loads route their one terminal into the transpiled core through the fake channel" {
    HostStub.reset();
    const h = try Harness.createFake();
    defer h.destroy();
    // The deterministic decode seam: the strict PNG subset decodes
    // without a bundled codec.
    h.harness.null_platform.image_decode = true;
    const fx = &h.app_state.effects;
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // The load parks the whole request shape under the app's own id —
    // the engine key IS the ImageId, no bridge namespace.
    try h.menu("core.cover");
    const request = fx.pendingImageLoadAt(0).?;
    try std.testing.expectEqual(@as(u64, 21), request.id);
    try std.testing.expectEqualStrings("art/cover.png", request.path);
    try std.testing.expectEqualStrings("https://cdn.test/cover.png", request.url);

    // A duplicate LIVE id rejects the new load (the spawn discipline):
    // the event arm carries state "rejected" and the in-flight load
    // stays parked.
    try h.menu("core.coveragain");
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 1), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .rejected);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingImageLoadCount());

    // Feeding encoded bytes runs the REAL decode+register path: the
    // four-field arm carries the decoded dimensions, the model adopts
    // the id, and the pixels are live in the runtime registry.
    var pixels: [4 * 3 * 4]u8 = undefined;
    var seed: u8 = 11;
    for (&pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 37 +% 5;
    }
    var encoded_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try native_sdk.canvas.png.writeRgba8(&writer, 4, 3, &pixels);
    try fx.feedImageBytes(21, writer.buffered());
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 2), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .loaded);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().cover), 21), Bridge.model().cover);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().coverW), 4), Bridge.model().coverW);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().coverH), 3), Bridge.model().coverH);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(21) != null);

    // The entry retired with its terminal: the id is free again, and a
    // failure class routes the same arm honestly.
    try h.menu("core.coveragain");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingImageLoadCount());
    try fx.feedImageResult(21, .decode_failed, 0, 0, 0, "");
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 3), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .decode_failed);
    // The model kept the previously adopted id (store-on-success).
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().cover), 21), Bridge.model().cover);
}

test "a seventeenth in-flight image load rejects instead of crashing" {
    HostStub.reset();
    const h = try Harness.createFake();
    defer h.destroy();
    // The deterministic decode seam: the strict PNG subset decodes
    // without a bundled codec.
    h.harness.null_platform.image_decode = true;
    const fx = &h.app_state.effects;
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // Sixteen dynamic model-owned ids fill the bridge's image table
    // (and the engine's matching slot budget) without a single result.
    var issued: usize = 0;
    while (issued < 16) : (issued += 1) {
        try h.menu("core.covernext");
    }
    try std.testing.expectEqual(@as(usize, 16), fx.pendingImageLoadCount());
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 0), Bridge.model().imageResults);

    // The 17th finds no free entry: the exactly-one-result contract
    // answers state "rejected" through the event arm — the engine's own
    // slot-exhaustion vocabulary, never a crash.
    try h.menu("core.covernext");
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 1), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .rejected);

    // The sixteen live loads are untouched by the refusal...
    try std.testing.expectEqual(@as(usize, 16), fx.pendingImageLoadCount());
    // ...and still healthy: the first runs the real decode+register
    // path to its loaded terminal, retiring only its own entry.
    const first = fx.pendingImageLoadAt(0).?;
    var pixels: [2 * 2 * 4]u8 = undefined;
    var seed: u8 = 3;
    for (&pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 29 +% 11;
    }
    var encoded_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try native_sdk.canvas.png.writeRgba8(&writer, 2, 2, &pixels);
    try fx.feedImageBytes(first.id, writer.buffered());
    try h.wake();
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 2), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .loaded);
    try std.testing.expect(h.harness.runtime.registeredCanvasImage(first.id) != null);
    try std.testing.expectEqual(@as(usize, 15), fx.pendingImageLoadCount());
}

test "the image id wire bound is exclusive at 2^53 for dynamic values" {
    HostStub.reset();
    const h = try Harness.createFake();
    defer h.destroy();
    const fx = &h.app_state.effects;
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();

    // 2^53 - 1 (the model-owned top id) is the last integer every tier
    // carries exactly: the load parks with the id intact.
    try h.menu("core.covertop");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingImageLoadCount());
    try std.testing.expectEqual(@as(u64, 9007199254740991), fx.pendingImageLoadAt(0).?.id);
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 0), Bridge.model().imageResults);

    // 2^53 aliases 2^53 + 1 in f64 — the first id the wire cannot carry
    // exactly. The bridge answers "rejected" (the runtime twin of the
    // emitter's NS1030 literal gate) and the parked load stays live.
    try h.menu("core.coverpast");
    try std.testing.expectEqual(@as(@TypeOf(Bridge.model().imageResults), 1), Bridge.model().imageResults);
    try std.testing.expect(Bridge.model().imageState == .rejected);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingImageLoadCount());
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

/// A value snapshot of the bridge's committed model (the committed
/// slices live in the core's heap, which record and replay share —
/// copy what outlives a session).
const CoreSnapshot = struct {
    polling: bool,
    ticks: i64,
    lastTickAt: f64,
    stampMs: f64,
    failures: i64,
    saved: i64,
    code: f64,
    firedAt: f64,
    status: [32]u8,
    statusLen: usize,
    lastErr: [32]u8,
    lastErrLen: usize,

    fn take() CoreSnapshot {
        const m = Bridge.model();
        var snapshot: CoreSnapshot = .{
            .polling = m.polling,
            .ticks = m.ticks,
            .lastTickAt = m.lastTickAt,
            .stampMs = m.stampMs,
            .failures = m.failures,
            .saved = m.saved,
            .code = m.code,
            .firedAt = m.firedAt,
            .status = [_]u8{0} ** 32,
            .statusLen = @min(m.status.len, 32),
            .lastErr = [_]u8{0} ** 32,
            .lastErrLen = @min(m.lastErr.len, 32),
        };
        @memcpy(snapshot.status[0..snapshot.statusLen], m.status[0..snapshot.statusLen]);
        @memcpy(snapshot.lastErr[0..snapshot.lastErrLen], m.lastErr[0..snapshot.lastErrLen]);
        return snapshot;
    }
};

/// Record the reference session: boot answered ok, a refresh answered
/// err, two timer fires, a synchronous stamp, a host_bytes send, a
/// real-disk write/read round trip, a pasteboard write/read, and a
/// one-shot delay fire. Real-executor waits poll WITHOUT dispatching
/// events (Harness.waitPending), so two recordings stay byte-identical.
fn recordSession(buffer: *JournalBuffer) !CoreSnapshot {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-core-e2e", .window_width = 400, .window_height = 300 });

    HostStub.reset();
    removeStore();
    const h = try Harness.createRecorded(recorder);
    defer h.destroy();
    const fx = &h.app_state.effects;

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    try h.menu("core.refresh");
    try fx.feedHostResult(status_request_key, false, "declined");
    try h.wake();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    _ = try h.fireTick(250_000_000);
    _ = try h.fireTick(350_000_000);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    try h.menu("core.stamp");
    try h.menu("core.note");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // Named ops: write the model bytes to real disk, read them back,
    // share and paste through the pasteboard, then fire a delay.
    try h.menu("core.save");
    try h.waitPending();
    try h.wake();
    try h.menu("core.load");
    try h.waitPending();
    try h.wake();
    try h.menu("core.share");
    try h.menu("core.paste");
    try h.wake();
    try h.menu("core.later");
    _ = try h.fireDelay(450_000_000);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return CoreSnapshot.take();
}

test "a recorded transpiled-core session replays byte-identically with no host calls" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordSession(buffer);
    try std.testing.expectEqual(@as(i64, 2), recorded.ticks);
    try std.testing.expectEqual(@as(f64, 50_000), recorded.stampMs);
    try std.testing.expectEqual(@as(i64, 1), recorded.failures);
    try std.testing.expectEqualStrings("ready", recorded.status[0..recorded.statusLen]);
    try std.testing.expectEqual(@as(i64, 1), recorded.saved);
    try std.testing.expectEqual(@as(f64, 450), recorded.firedAt);

    // Determinism pin: the same driven session records byte-identical
    // journal bytes.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const recorded_again = try recordSession(second);
    try std.testing.expectEqualDeep(recorded, recorded_again);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app: journaled `.host`/`.file`/`.clipboard`
    // results and the journaled clock feed the stub executor; the
    // platform timer events (subscription ticks AND the delay fire)
    // replay from the event log; the host binding is NEVER called.
    // Deleting the store first proves the replayed file ops touch no
    // disk — their results come from the journal alone.
    removeStore();
    HostStub.reset();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = native_sdk.geometry.SizeF.init(400, 300),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, e2eOptions());
    defer app_state.deinit();
    app_state.effects.bindHostCalls(HostStub.binding());

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    // Fed from the journal: the ok and err host answers, the clock
    // read, the file write and read terminals, and the clipboard read
    // (the fire-and-forget clipboard write routes to nobody, so it is
    // never journaled; timer fires ride the event log). Nothing
    // touched the stub host — and the deleted store proves nothing
    // touched the disk.
    try std.testing.expectEqual(@as(u64, 6), report.effects_fed);
    try std.testing.expectEqual(@as(usize, 0), HostStub.request_count);
    try std.testing.expectEqual(@as(usize, 0), HostStub.send_count);
    try std.testing.expectEqualDeep(recorded, CoreSnapshot.take());
}

/// A value snapshot of the stream-facing model fields (see CoreSnapshot
/// for the lifetime rule).
const StreamSnapshot = struct {
    lines: i64,
    exitCode: i64,
    failures: i64,
    audioState: fixture.AudioState,
    posMs: i64,
    durMs: i64,
    playing: bool,
    audioEvents: i64,
    lastLine: [32]u8,
    lastLineLen: usize,
    lastErr: [32]u8,
    lastErrLen: usize,

    fn take() StreamSnapshot {
        const m = Bridge.model();
        var snapshot: StreamSnapshot = .{
            .lines = @intFromFloat(asF64(m.lines)),
            .exitCode = @intFromFloat(asF64(m.exitCode)),
            .failures = m.failures,
            .audioState = m.audioState,
            .posMs = @intFromFloat(asF64(m.posMs)),
            .durMs = @intFromFloat(asF64(m.durMs)),
            .playing = m.playing,
            .audioEvents = @intFromFloat(asF64(m.audioEvents)),
            .lastLine = [_]u8{0} ** 32,
            .lastLineLen = @min(m.lastLine.len, 32),
            .lastErr = [_]u8{0} ** 32,
            .lastErrLen = @min(m.lastErr.len, 32),
        };
        @memcpy(snapshot.lastLine[0..snapshot.lastLineLen], m.lastLine[0..snapshot.lastLineLen]);
        @memcpy(snapshot.lastErr[0..snapshot.lastErrLen], m.lastErr[0..snapshot.lastErrLen]);
        return snapshot;
    }

    /// The emitted number fields class i64 or f64 per the subset's
    /// inference; normalize through f64 so the snapshot never chases
    /// the classing.
    fn asF64(value: anytype) f64 {
        return if (@TypeOf(value) == f64) value else @floatFromInt(value);
    }
};

/// Record the stream session: a REAL subprocess whose lines and exit
/// journal in order, a mid-stream cancel, and an audio stream driven by
/// a scripted event feed — everything a streaming effect can journal.
fn recordStreamSession(buffer: *JournalBuffer) !StreamSnapshot {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-core-e2e", .window_width = 400, .window_height = 300 });

    HostStub.reset();
    const h = try Harness.createRecorded(recorder);
    defer h.destroy();
    const fx = &h.app_state.effects;

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try fx.feedHostResult(status_request_key, true, "ready");
    try h.wake();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // The real child: both lines and the exit drain in ONE wake (the
    // idle wait), so the journal's event boundaries are deterministic.
    try h.menu("core.run");
    try h.waitIdle();
    try h.wake();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // Cancel mid-stream: the journaled terminal is the `.cancelled`
    // exit the err arm consumed.
    try h.menu("core.hang");
    try h.menu("core.kill");
    try h.waitIdle();
    try h.wake();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // The audio stream: a real playAudio against the null platform's
    // hermetic player, events scripted through the feed.
    try h.menu("core.play");
    try fx.feedAudioEvent(.loaded, 0, 183_000, true);
    try fx.feedAudioEvent(.position, 1_500, 183_000, true);
    var bands: [32]u8 = undefined;
    for (&bands, 0..) |*b, i| b.* = @intCast(i * 7);
    try fx.feedAudioSpectrum(bands, 2_000, 183_000);
    try h.wake();
    try h.menu("core.stopmusic");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return StreamSnapshot.take();
}

test "a recorded stream session replays byte-identically with no process launches or host calls" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordStreamSession(buffer);
    try std.testing.expectEqual(@as(i64, 2), recorded.lines);
    try std.testing.expectEqualStrings("two", recorded.lastLine[0..recorded.lastLineLen]);
    try std.testing.expectEqual(@as(i64, 0), recorded.exitCode);
    try std.testing.expectEqual(@as(i64, 1), recorded.failures);
    try std.testing.expectEqualStrings("cancelled", recorded.lastErr[0..recorded.lastErrLen]);
    try std.testing.expectEqual(fixture.AudioState.spectrum, recorded.audioState);
    try std.testing.expectEqual(@as(i64, 3), recorded.audioEvents);

    // Replay into a fresh app: the spawn re-issues onto the FAKE
    // executor (no /bin/sh runs), the journaled lines, exits — the
    // cancelled one included — and audio events feed the parked
    // requests in recorded order, and the host binding is never
    // called.
    HostStub.reset();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = native_sdk.geometry.SizeF.init(400, 300),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, e2eOptions());
    defer app_state.deinit();
    app_state.effects.bindHostCalls(HostStub.binding());

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    // Fed from the journal: the boot host answer (1), the run stream's
    // two lines and exit (3), the cancelled stream's exit (1), and the
    // three audio events (3).
    try std.testing.expectEqual(@as(u64, 8), report.effects_fed);
    try std.testing.expectEqual(@as(usize, 0), HostStub.request_count);
    try std.testing.expectEqual(@as(usize, 0), HostStub.send_count);
    try std.testing.expectEqualDeep(recorded, StreamSnapshot.take());
}
