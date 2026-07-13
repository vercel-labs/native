//! Host-request coverage: `fx.hostRequest`/`fx.hostSend` — the generic
//! named host call behind transpiled cores' command wire — through the
//! fake executor (deterministic request/feed round trips, replace and
//! silent-cancel key discipline, rejection passthrough) and the real
//! executor against a stub `HostCallBinding`. Plus the record/replay
//! pin: a session driving requests and fx timers through a full UiApp
//! journals `.host` results and replays to identical state without a
//! host call.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");

const canvas_label = "host-canvas";

const host_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const host_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Host",
    .width = 400,
    .height = 300,
    .views = &host_views,
}};
const host_scene: app_manifest.ShellConfig = .{ .windows = &host_windows };

const max_recorded_bytes = 96;

const HostModel = struct {
    result_count: u32 = 0,
    ok_count: u32 = 0,
    err_count: u32 = 0,
    last_key: u64 = 0,
    tick_count: u32 = 0,
    tick_timestamp_ns: u64 = 0,
    // Payload proof: the result slice is drain scratch, so the model
    // copies a bounded prefix of what it keeps.
    bytes_len: usize = 0,
    bytes_prefix: [max_recorded_bytes]u8 = [_]u8{0} ** max_recorded_bytes,
    bytes_prefix_len: usize = 0,

    fn record(model: *HostModel, result: effects_mod.EffectHostResult) void {
        model.result_count += 1;
        if (result.ok) model.ok_count += 1 else model.err_count += 1;
        model.last_key = result.key;
        model.bytes_len = result.bytes.len;
        model.bytes_prefix_len = @min(result.bytes.len, max_recorded_bytes);
        @memcpy(model.bytes_prefix[0..model.bytes_prefix_len], result.bytes[0..model.bytes_prefix_len]);
    }

    fn bytesPrefix(model: *const HostModel) []const u8 {
        return model.bytes_prefix[0..model.bytes_prefix_len];
    }
};

const HostMsg = union(enum) {
    ask,
    ask_other,
    ask_oversized,
    ask_colliding,
    replace,
    drop,
    send,
    start_timer,
    hold_file,
    host_result: effects_mod.EffectHostResult,
    file_result: effects_mod.EffectFileResult,
    tick: effects_mod.EffectTimer,
};

const HostApp = ui_app_mod.UiApp(HostModel, HostMsg);
const HostEffects = HostApp.Effects;

const ask_key: u64 = 77;
const other_key: u64 = 78;
const timer_key: u64 = 9;

// Set by tests before dispatching `.ask`/`.replace`.
var test_payload: []const u8 = "";

fn hostUpdate(model: *HostModel, msg: HostMsg, fx: *HostEffects) void {
    switch (msg) {
        .ask => fx.hostRequest(.{
            .key = ask_key,
            .name = "svc.echo",
            .payload = test_payload,
            .on_result = HostEffects.hostMsg(.host_result),
        }),
        .ask_other => fx.hostRequest(.{
            .key = other_key,
            .name = "svc.other",
            .on_result = HostEffects.hostMsg(.host_result),
        }),
        .ask_oversized => fx.hostRequest(.{
            .key = ask_key,
            .name = "svc.echo",
            .payload = oversized_payload,
            .on_result = HostEffects.hostMsg(.host_result),
        }),
        // A host key colliding with a running FILE effect's key: the
        // request must reject, not replace a foreign effect.
        .ask_colliding => fx.hostRequest(.{
            .key = 500,
            .name = "svc.echo",
            .on_result = HostEffects.hostMsg(.host_result),
        }),
        .replace => fx.hostRequest(.{
            .key = ask_key,
            .name = "svc.echo",
            .payload = test_payload,
            .on_result = HostEffects.hostMsg(.host_result),
        }),
        .drop => fx.cancelHostRequest(ask_key),
        .send => fx.hostSend("svc.beep", "ping"),
        .start_timer => fx.startTimer(.{
            .key = timer_key,
            .interval_ms = 100,
            .on_fire = HostEffects.timerMsg(.tick),
        }),
        .hold_file => fx.readFile(.{
            .key = 500,
            .path = "/tmp/host-collision-probe",
            .on_result = HostEffects.fileMsg(.file_result),
        }),
        .host_result => |result| model.record(result),
        .file_result => {},
        .tick => |timer| {
            model.tick_count += 1;
            model.tick_timestamp_ns = timer.timestamp_ns;
        },
    }
}

var oversized_payload: []const u8 = "";

fn hostView(ui: *HostApp.Ui, model: *const HostModel) HostApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results", .{model.result_count})),
        ui.button(.{ .on_press = .ask }, "Ask"),
    });
}

fn hostCommand(name: []const u8) ?HostMsg {
    if (std.mem.eql(u8, name, "host.ask")) return .ask;
    if (std.mem.eql(u8, name, "host.oversized")) return .ask_oversized;
    if (std.mem.eql(u8, name, "host.timer")) return .start_timer;
    return null;
}

fn hostOptions() HostApp.Options {
    return .{
        .name = "effects-host",
        .scene = host_scene,
        .canvas_label = canvas_label,
        .update_fx = hostUpdate,
        .view = hostView,
        .on_command = hostCommand,
    };
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *HostApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(HostApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = HostApp.init(std.heap.page_allocator, .{}, hostOptions());
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(app_state.installed);
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

// ------------------------------------------------------------ fake executor

test "fake executor parks host requests and feeds results back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_payload = "lookup-me";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0).?;
    try std.testing.expectEqual(ask_key, request.key);
    try std.testing.expectEqualStrings("svc.echo", request.name);
    try std.testing.expectEqualStrings("lookup-me", request.payload);

    // The ok route delivers the result bytes.
    try fx.feedHostResult(ask_key, true, "the-answer");
    try h.wake();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.ok_count);
    try std.testing.expectEqual(ask_key, h.app_state.model.last_key);
    try std.testing.expectEqualStrings("the-answer", h.app_state.model.bytesPrefix());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());

    // The err route passes through as fed, and the key is terminal.
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try fx.feedHostResult(ask_key, false, "not found");
    try h.wake();
    try std.testing.expectEqual(@as(u32, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.err_count);
    try std.testing.expectEqualStrings("not found", h.app_state.model.bytesPrefix());
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(ask_key, true, ""));
}

test "re-issuing a live host key replaces the pending request and drops the undelivered result" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_payload = "first";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    // Replace while in flight: still exactly one pending, new payload.
    test_payload = "second";
    try h.app_state.dispatch(&h.harness.runtime, 1, .replace);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    try std.testing.expectEqualStrings("second", fx.pendingHostAt(0).?.payload);

    // Replace after the answer was fed but before it drained: the
    // queued result dies with the old occupancy.
    try fx.feedHostResult(ask_key, true, "stale-answer");
    test_payload = "third";
    try h.app_state.dispatch(&h.harness.runtime, 1, .replace);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.result_count);

    // Only the live occupancy's answer delivers.
    try fx.feedHostResult(ask_key, true, "fresh-answer");
    try h.wake();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.result_count);
    try std.testing.expectEqualStrings("fresh-answer", h.app_state.model.bytesPrefix());
}

test "cancelHostRequest drops silently, and the generic cancel routes to it" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Silent drop: no terminal of any kind, and the key is gone.
    test_payload = "pending";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try h.app_state.dispatch(&h.harness.runtime, 1, .drop);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());
    try h.wake();
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.result_count);
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(ask_key, true, ""));

    // A cancel landing after the answer (fed, undrained) still drops.
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try fx.feedHostResult(ask_key, true, "raced");
    try h.app_state.dispatch(&h.harness.runtime, 1, .drop);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.result_count);

    // The generic `cancel` keeps the host contract for host keys:
    // silent, no `.cancelled` terminal.
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    fx.cancel(ask_key);
    try h.wake();
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.result_count);
}

test "host requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Over-bound payload.
    const big = try std.testing.allocator.alloc(u8, effects_mod.max_effect_host_payload_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'p');
    oversized_payload = big;
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask_oversized);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.err_count);
    try std.testing.expectEqualStrings("rejected", h.app_state.model.bytesPrefix());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());

    // A key held by a running effect of another kind rejects instead
    // of replacing the foreign effect.
    try h.app_state.dispatch(&h.harness.runtime, 1, .hold_file);
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask_colliding);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 2), h.app_state.model.err_count);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());

    // A result over the budget delivers the err route with a teaching
    // message, never a cut payload passing for the whole one.
    test_payload = "";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    const huge = try std.testing.allocator.alloc(u8, effects_mod.max_effect_host_result_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'r');
    try fx.feedHostResult(ask_key, true, huge);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 3), h.app_state.model.err_count);
    try std.testing.expectEqualStrings("host result over budget", h.app_state.model.bytesPrefix());
}

test "host journal records carry the route in code and mark rejections regenerable" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    const Capture = struct {
        var records: [8]effects_mod.EffectResultRecord = undefined;
        var payloads: [8][64]u8 = undefined;
        var count: usize = 0;
        fn note(context: *anyopaque, record: effects_mod.EffectResultRecord) void {
            _ = context;
            records[count] = record;
            const len = @min(record.payload.len, 64);
            @memcpy(payloads[count][0..len], record.payload[0..len]);
            records[count].payload = payloads[count][0..len];
            count += 1;
        }
    };
    Capture.count = 0;
    var context: u8 = 0;
    fx.bindJournal(.{ .context = &context, .record_fn = Capture.note });

    test_payload = "";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try fx.feedHostResult(ask_key, true, "yes");
    try h.wake();
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try fx.feedHostResult(ask_key, false, "no");
    try h.wake();
    const big = try std.testing.allocator.alloc(u8, effects_mod.max_effect_host_payload_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'p');
    oversized_payload = big;
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask_oversized);
    try h.wake();

    try std.testing.expectEqual(@as(usize, 3), Capture.count);
    // ok: kind .host, code 0, delivered as .exited (feedable).
    try std.testing.expectEqual(effects_mod.EffectResultKind.host, Capture.records[0].kind);
    try std.testing.expectEqual(@as(i32, 0), Capture.records[0].code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, Capture.records[0].exit_reason);
    try std.testing.expectEqualStrings("yes", Capture.records[0].payload);
    // err: code 1, still feedable.
    try std.testing.expectEqual(@as(i32, 1), Capture.records[1].code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, Capture.records[1].exit_reason);
    try std.testing.expectEqualStrings("no", Capture.records[1].payload);
    // rejection: code 1 AND marked regenerable — replay never feeds it.
    try std.testing.expectEqual(@as(i32, 1), Capture.records[2].code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.rejected, Capture.records[2].exit_reason);
}

// ------------------------------------------------------------ real executor

test "real-mode host calls ride the binding and answer through the feed" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    const Stub = struct {
        var bound: ?*HostEffects = null;
        var send_count: usize = 0;
        var cancel_count: usize = 0;
        var last_cancelled: u64 = 0;
        fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
            _ = context;
            _ = name;
            _ = payload;
            send_count += 1;
        }
        fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            _ = context;
            _ = payload;
            if (std.mem.eql(u8, name, "svc.echo")) {
                bound.?.feedHostResult(key, true, "echoed") catch unreachable;
            }
            // svc.other never answers — it stays in flight for the
            // cancel below.
        }
        fn cancelNotice(context: *anyopaque, key: u64) void {
            _ = context;
            cancel_count += 1;
            last_cancelled = key;
        }
    };
    Stub.bound = fx;
    Stub.send_count = 0;
    Stub.cancel_count = 0;
    var context: u8 = 0;
    fx.bindHostCalls(.{
        .context = &context,
        .send_fn = Stub.send,
        .request_fn = Stub.request,
        .cancel_fn = Stub.cancelNotice,
    });

    // Sends reach the binding directly.
    try h.app_state.dispatch(&h.harness.runtime, 1, .send);
    try std.testing.expectEqual(@as(usize, 1), Stub.send_count);

    // A request round-trips: binding answers synchronously, the drain
    // delivers on the next wake.
    test_payload = "hello";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.ok_count);
    try std.testing.expectEqualStrings("echoed", h.app_state.model.bytesPrefix());

    // Cancelling an unanswered request notifies the host, silently.
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask_other);
    fx.cancelHostRequest(other_key);
    try h.wake();
    try std.testing.expectEqual(@as(usize, 1), Stub.cancel_count);
    try std.testing.expectEqual(other_key, Stub.last_cancelled);
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.result_count);
}

test "real-mode requests without bound host services reject through the err route" {
    var h = try Harness.create();
    defer h.destroy();

    test_payload = "";
    try h.app_state.dispatch(&h.harness.runtime, 1, .ask);
    try h.wake();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.err_count);
    try std.testing.expectEqualStrings("rejected", h.app_state.model.bytesPrefix());
}

// -------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [256 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) session_record.RecorderSink {
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

/// Record the reference host session: a request answered ok, one
/// answered err, a rejected over-budget request (regenerates on
/// replay), and an fx-timer fire via its platform timer event.
fn recordHostSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, big: []const u8) !HostModel {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "effects-host", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(HostApp);
    defer gpa.destroy(app_state);
    app_state.* = HostApp.init(std.heap.page_allocator, .{}, hostOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Request answered ok.
    test_payload = "recorded";
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "host.ask", .window_id = 1 } });
    try app_state.effects.feedHostResult(ask_key, true, "journal-me");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Request answered err.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "host.ask", .window_id = 1 } });
    try app_state.effects.feedHostResult(ask_key, false, "declined");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // A rejection: journaled as regenerable, never fed on replay.
    oversized_payload = big;
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "host.oversized", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // An fx timer armed and fired through its platform timer id — a
    // journaled platform event, like every timer fire.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "host.timer", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .timer = .{
        .id = effects_mod.effect_timer_platform_id_base,
        .timestamp_ns = 55_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return app_state.model;
}

test "a recorded session with host requests and fx timers replays identically" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const big = try gpa.alloc(u8, effects_mod.max_effect_host_payload_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'p');

    const recorded = try recordHostSession(gpa, buffer, big);
    try std.testing.expectEqual(@as(u32, 3), recorded.result_count);
    try std.testing.expectEqual(@as(u32, 1), recorded.ok_count);
    try std.testing.expectEqual(@as(u32, 2), recorded.err_count);
    try std.testing.expectEqual(@as(u32, 1), recorded.tick_count);
    try std.testing.expectEqual(@as(u64, 55_000_000), recorded.tick_timestamp_ns);
    try std.testing.expectEqualStrings("rejected", recorded.bytesPrefix());

    // Determinism pin: recording the same driven session twice yields
    // byte-identical journals.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    _ = try recordHostSession(gpa, second, big);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app: the journaled .host results feed the
    // stub executor (the rejection regenerates instead), no host runs.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(HostApp);
    defer gpa.destroy(app_state);
    app_state.* = HostApp.init(std.heap.page_allocator, .{}, hostOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    // The ok and err answers fed; the rejection did not.
    try std.testing.expectEqual(@as(u64, 2), report.effects_fed);
    try std.testing.expectEqualDeep(recorded, app_state.model);
}
