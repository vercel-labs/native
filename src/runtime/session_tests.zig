//! End-to-end session record/replay tests: record a driven UiApp session
//! (input events, effect results, checkpoints) to journal bytes, replay
//! it into a FRESH runtime and app, and verify equivalence — plus the
//! hostile-input side: truncated and tampered journals must fail loudly,
//! and a journal whose effects do not match the app's must name the
//! divergence.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");
const journal = @import("session_journal.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");

const canvas_label = "session-canvas";
const core_adapter_id: u32 = 1;
const core_payload_schema_version: u32 = 1;

const SessionModel = struct {
    count: u32 = 0,
    body: [64]u8 = [_]u8{0} ** 64,
    body_len: usize = 0,
    fetch_status: u16 = 0,
    line_count: u32 = 0,
    exit_code: i32 = -999,
    tick_timestamp_ns: u64 = 0,
    stamp_ms: i64 = 0,
    /// Spectrum band reports fold into a checksum: identical bars on
    /// replay means an identical checksum — the band-byte determinism
    /// pin, without 32 array fields in the equality check.
    spectrum_count: u32 = 0,
    band_checksum: u64 = 0,
    external_count: usize = 0,
    external_adapter_ids: [2]u32 = [_]u32{0} ** 2,
    external_kinds: [2]u32 = [_]u32{0} ** 2,
    external_schema_versions: [2]u32 = [_]u32{0} ** 2,
    external_outcomes: [2]effects_mod.EffectExternalOutcome = [_]effects_mod.EffectExternalOutcome{.ok} ** 2,
    external_first_bytes: [2]u8 = [_]u8{0} ** 2,
    cancel_second_external_after_first: bool = false,

    fn bodyText(self: *const SessionModel) []const u8 {
        return self.body[0..self.body_len];
    }
};

const SessionMsg = union(enum) {
    increment,
    stamp,
    start_fetch,
    start_spawn,
    start_audio,
    start_external,
    start_external_cancel_chain,
    cancel_external,
    fetched: effects_mod.EffectResponse,
    line: effects_mod.EffectLine,
    exited: effects_mod.EffectExit,
    tick: effects_mod.EffectTimer,
    audio_event: effects_mod.EffectAudio,
    external_result: effects_mod.EffectExternalResult,
};

const SessionApp = ui_app_mod.UiApp(SessionModel, SessionMsg);

fn sessionUpdate(model: *SessionModel, msg: SessionMsg, fx: *SessionApp.Effects) void {
    switch (msg) {
        .increment => model.count += 1,
        .stamp => model.stamp_ms = fx.wallMs(),
        .start_fetch => fx.fetch(.{
            .key = 1,
            .url = "http://journal.invalid/data",
            .on_response = SessionApp.Effects.responseMsg(.fetched),
        }),
        .start_spawn => {
            fx.spawn(.{
                .key = 2,
                .argv = &.{ "probe", "--emit" },
                .on_line = SessionApp.Effects.lineMsg(.line),
                .on_exit = SessionApp.Effects.exitMsg(.exited),
            });
            fx.startTimer(.{
                .key = 7,
                .interval_ms = 100,
                .on_fire = SessionApp.Effects.timerMsg(.tick),
            });
        },
        .start_audio => fx.playAudio(.{
            .key = 9,
            .path = "assets/session-track.mp3",
            .on_event = SessionApp.Effects.audioMsg(.audio_event),
        }),
        .start_external => {
            _ = fx.external(.{
                .key = 11,
                .adapter_id = core_adapter_id,
                .kind = 101,
                .schema_version = core_payload_schema_version,
                .payload = "request-a",
                .on_result = SessionApp.Effects.externalMsg(.external_result),
            }) catch unreachable;
            _ = fx.external(.{
                .key = 12,
                .adapter_id = core_adapter_id,
                .kind = 102,
                .schema_version = core_payload_schema_version,
                .payload = "request-b",
                .on_result = SessionApp.Effects.externalMsg(.external_result),
            }) catch unreachable;
        },
        .start_external_cancel_chain => {
            model.cancel_second_external_after_first = true;
            _ = fx.external(.{
                .key = 11,
                .adapter_id = core_adapter_id,
                .kind = 101,
                .schema_version = core_payload_schema_version,
                .payload = "request-a",
                .on_result = SessionApp.Effects.externalMsg(.external_result),
            }) catch unreachable;
            _ = fx.external(.{
                .key = 12,
                .adapter_id = core_adapter_id,
                .kind = 102,
                .schema_version = core_payload_schema_version,
                .payload = "request-b",
                .on_result = SessionApp.Effects.externalMsg(.external_result),
            }) catch unreachable;
        },
        .cancel_external => fx.cancel(11),
        .fetched => |response| {
            model.fetch_status = response.status;
            const len = @min(response.body.len, model.body.len);
            @memcpy(model.body[0..len], response.body[0..len]);
            model.body_len = len;
        },
        .audio_event => |event| if (event.kind == .spectrum) {
            model.spectrum_count += 1;
            var checksum: u64 = 0;
            for (event.bands) |band| checksum = checksum *% 31 +% band;
            model.band_checksum = checksum;
        },
        .external_result => |result| {
            if (model.cancel_second_external_after_first and result.kind == 101) {
                model.cancel_second_external_after_first = false;
                fx.cancel(12);
            }
            if (model.external_count < model.external_kinds.len) {
                model.external_adapter_ids[model.external_count] = result.adapter_id;
                model.external_kinds[model.external_count] = result.kind;
                model.external_schema_versions[model.external_count] = result.schema_version;
                model.external_outcomes[model.external_count] = result.outcome;
                model.external_first_bytes[model.external_count] = if (result.bytes.len > 0) result.bytes[0] else 0;
                model.external_count += 1;
            }
        },
        .line => model.line_count += 1,
        .exited => |exit| model.exit_code = exit.code,
        .tick => |timer| model.tick_timestamp_ns = timer.timestamp_ns,
    }
}

fn sessionView(ui: *SessionApp.Ui, model: *const SessionModel) SessionApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.text(.{}, ui.fmt("Body {s} ({d})", .{ model.bodyText(), model.fetch_status })),
        ui.text(.{}, ui.fmt("Lines {d} Exit {d} Tick {d} Stamp {d}", .{ model.line_count, model.exit_code, model.tick_timestamp_ns, model.stamp_ms })),
        ui.text(.{}, ui.fmt("External {d} {d}:{d} {d}:{d}", .{ model.external_count, model.external_kinds[0], model.external_first_bytes[0], model.external_kinds[1], model.external_first_bytes[1] })),
        ui.button(.{ .on_press = .increment }, "Increment"),
    });
}

fn sessionCommand(name: []const u8) ?SessionMsg {
    if (std.mem.eql(u8, name, "session.increment")) return .increment;
    if (std.mem.eql(u8, name, "session.stamp")) return .stamp;
    if (std.mem.eql(u8, name, "session.fetch")) return .start_fetch;
    if (std.mem.eql(u8, name, "session.spawn")) return .start_spawn;
    if (std.mem.eql(u8, name, "session.audio")) return .start_audio;
    if (std.mem.eql(u8, name, "session.external")) return .start_external;
    if (std.mem.eql(u8, name, "session.external-cancel-chain")) return .start_external_cancel_chain;
    if (std.mem.eql(u8, name, "session.external-cancel")) return .cancel_external;
    return null;
}

const session_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const session_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Session",
    .width = 400,
    .height = 300,
    .views = &session_views,
}};
const session_scene: app_manifest.ShellConfig = .{ .windows = &session_windows };

fn sessionOptions() SessionApp.Options {
    return .{
        .name = "session-demo",
        .scene = session_scene,
        .canvas_label = canvas_label,
        .update_fx = sessionUpdate,
        .view = sessionView,
        .on_command = sessionCommand,
    };
}

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

const RecordedSession = struct {
    model: SessionModel,
    fingerprint: u64,
};

/// Record the reference session into `buffer`: install, two increments,
/// a fetch and a spawn with results fed through the fake executor, an
/// fx-timer fire via its platform timer event, and per-frame
/// checkpoints. Returns the final model and fingerprint for the replay
/// side to match. `web_layer` mirrors the build's inference: the
/// reference session is a pure canvas app, so it must record (and
/// replay, below) identically in a native-only build.
fn recordReferenceSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, web_layer: bool) !RecordedSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.web_layer = web_layer;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();
    // Deterministic recording under test: the fake executor stands in
    // for the world; feeds below play the world's answers. Real
    // recordings use the real executor — the journal shape is identical.
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

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.increment", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.increment", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.fetch", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.spawn", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.external", .window_id = 1 } });

    const first_external = app_state.effects.pendingExternalAt(0).?;
    const second_external = app_state.effects.pendingExternalAt(1).?;
    try std.testing.expectEqual(@as(u32, 101), first_external.kind);
    try std.testing.expectEqual(@as(u32, 102), second_external.kind);

    // The world answers: one stdout line, a clean exit, and the fetch
    // response. Draining happens on the wake dispatch, which journals
    // each result right before its Msg runs through update.
    try app_state.effects.feedLine(2, "probe-line-1");
    try app_state.effects.feedExit(2, 0);
    try app_state.effects.feedResponse(1, 200, "hello-from-the-network");
    // Complete in reverse request order. The journal must preserve both
    // the issue identities and this result order without live work.
    try app_state.effects.feedExternalResult(second_external.request_id, .failure, "B-result");
    try app_state.effects.feedExternalResult(first_external.request_id, .success, "A-result");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // The fx timer (key 7, slot 0) fires through its reserved platform
    // timer id — a journaled platform event, like every timer fire.
    try harness.runtime.dispatchPlatformEvent(app, .{ .timer = .{
        .id = effects_mod.effect_timer_platform_id_base,
        .timestamp_ns = 42_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // A journaled wall-clock read: the recorded value replays verbatim.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.stamp", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Real spectrum analysis, journaled at the boundary: playback starts
    // and the world answers one `.spectrum` band report — honest
    // non-determinism recorded at the edge, so replay repaints the same
    // bars (the model folds them into a checksum the equality pins).
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.audio", .window_id = 1 } });
    var bands: [platform.audio_spectrum_band_count]u8 = undefined;
    for (&bands, 0..) |*band, index| band.* = @intCast((index * 13 + 5) % 256);
    try app_state.effects.feedAudioSpectrum(bands, 1_000, 30_000);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);

    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

fn replayIntoFreshApp(gpa: std.mem.Allocator, journal_bytes: []const u8, web_layer: bool) !struct {
    report: session_replay.ReplayReport,
    model: SessionModel,
    fingerprint: u64,
} {
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.web_layer = web_layer;

    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), journal_bytes, .{
        .verify = true,
        .require_same_platform = false,
    });
    return .{
        .report = report,
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

fn recordExternalOnlySession(gpa: std.mem.Allocator, buffer: *JournalBuffer, executor: effects_mod.EffectExecutor, cancel_first: bool) !RecordedSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();
    app_state.effects.executor = executor;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.external", .window_id = 1 } });
    if (cancel_first) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.external-cancel", .window_id = 1 } });
        const remaining = app_state.effects.pendingExternalAt(0).?;
        try std.testing.expectEqual(@as(u64, 12), remaining.key);
        try app_state.effects.feedExternalResult(remaining.request_id, .success, "remaining");
    }
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try std.testing.expectEqual(@as(usize, 0), app_state.effects.activeCount());

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a recorded session replays to identical model state and fingerprints" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordReferenceSession(gpa, buffer, true);

    // The recording captured real state.
    try std.testing.expectEqual(@as(u32, 2), recorded.model.count);
    try std.testing.expectEqualStrings("hello-from-the-network", recorded.model.bodyText());
    try std.testing.expectEqual(@as(u16, 200), recorded.model.fetch_status);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.line_count);
    try std.testing.expectEqual(@as(i32, 0), recorded.model.exit_code);
    try std.testing.expectEqual(@as(u64, 42_000_000), recorded.model.tick_timestamp_ns);
    try std.testing.expect(recorded.model.stamp_ms != 0);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.spectrum_count);
    try std.testing.expect(recorded.model.band_checksum != 0);
    try std.testing.expectEqual(@as(usize, 2), recorded.model.external_count);
    try std.testing.expectEqual(core_adapter_id, recorded.model.external_adapter_ids[0]);
    try std.testing.expectEqual(@as(u32, 102), recorded.model.external_kinds[0]);
    try std.testing.expectEqual(core_payload_schema_version, recorded.model.external_schema_versions[0]);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.failed, recorded.model.external_outcomes[0]);
    try std.testing.expectEqual(@as(u8, 'B'), recorded.model.external_first_bytes[0]);
    try std.testing.expectEqual(@as(u32, 101), recorded.model.external_kinds[1]);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.ok, recorded.model.external_outcomes[1]);
    try std.testing.expectEqual(@as(u8, 'A'), recorded.model.external_first_bytes[1]);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expect(replayed.report.events_replayed > 0);
    try std.testing.expectEqual(@as(u64, 7), replayed.report.effects_fed);
    try std.testing.expect(replayed.report.checkpoints_verified > 0);
    try std.testing.expectEqualDeep(recorded.model, replayed.model);
    try std.testing.expectEqual(recorded.fingerprint, replayed.fingerprint);
}

test "adapter-unavailable accepted terminals retire and replay without a live adapter" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordExternalOnlySession(gpa, buffer, .real, false);
    try std.testing.expectEqual(@as(usize, 2), recorded.model.external_count);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.adapter_unavailable, recorded.model.external_outcomes[0]);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.adapter_unavailable, recorded.model.external_outcomes[1]);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqual(@as(u64, 2), replayed.report.effects_fed);
    try std.testing.expectEqualDeep(recorded.model, replayed.model);
    try std.testing.expectEqual(recorded.fingerprint, replayed.fingerprint);
}

test "SDK cancellation records and replays before a later adapter success" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordExternalOnlySession(gpa, buffer, .fake, true);
    try std.testing.expectEqual(@as(usize, 2), recorded.model.external_count);
    try std.testing.expectEqual(@as(u32, 101), recorded.model.external_kinds[0]);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, recorded.model.external_outcomes[0]);
    try std.testing.expectEqual(@as(u32, 102), recorded.model.external_kinds[1]);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.ok, recorded.model.external_outcomes[1]);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqual(@as(u64, 2), replayed.report.effects_fed);
    try std.testing.expectEqualDeep(recorded.model, replayed.model);
    try std.testing.expectEqual(recorded.fingerprint, replayed.fingerprint);
}

test "external cancellation issued by a result waits for the next replay wake" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
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
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.external-cancel-chain", .window_id = 1 } });
    const first = app_state.effects.pendingExternalAt(0).?;
    try app_state.effects.feedExternalResult(first.request_id, .success, "first");
    try std.testing.expect(harness.null_platform.takeWake() != null);
    try std.testing.expect(harness.null_platform.takeWake() == null);

    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(usize, 1), app_state.model.external_count);
    try std.testing.expect(harness.null_platform.takeWake() != null);
    try std.testing.expect(harness.null_platform.takeWake() == null);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(usize, 2), app_state.model.external_count);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, app_state.model.external_outcomes[1]);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    recorder.finish();
    try std.testing.expect(!recorder.failed);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqualDeep(app_state.model, replayed.model);
}

test "a native-only session records and replays like a web-layer one" {
    // The whole reference session is canvas-only, so a native-only
    // runtime (web_layer = false, the app-runner inference for an
    // app.zon with no web declaration) must journal and replay it
    // byte-for-byte equivalently: same final model, same fingerprint,
    // same checkpoint verification. Record/replay is part of the
    // native-only contract, not a web-layer feature.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordReferenceSession(gpa, buffer, false);
    try std.testing.expectEqual(@as(u32, 2), recorded.model.count);
    try std.testing.expectEqualStrings("hello-from-the-network", recorded.model.bodyText());

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), false);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expect(replayed.report.events_replayed > 0);
    try std.testing.expect(replayed.report.checkpoints_verified > 0);
    try std.testing.expectEqualDeep(recorded.model, replayed.model);
    try std.testing.expectEqual(recorded.fingerprint, replayed.fingerprint);
}

test "a truncated journal is refused loudly" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    _ = try recordReferenceSession(gpa, buffer, true);
    const whole = buffer.journalBytes();

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), whole[0 .. whole.len - 10], .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expectError(error.JournalTruncated, result);
}

test "a tampered effect payload fails verification loudly" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    _ = try recordReferenceSession(gpa, buffer, true);

    // Flip one byte inside the journaled fetch body: framing stays
    // valid, so the tamper is only detectable semantically — the
    // fingerprint checkpoint after the wake must mismatch.
    const bytes = buffer.bytes[0..buffer.len];
    const at = std.mem.indexOf(u8, bytes, "hello-from-the-network") orelse unreachable;
    bytes[at] ^= 0x20;

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(!replayed.report.ok());
    try std.testing.expect(replayed.report.mismatch_count >= 1);
    try std.testing.expectEqual(session_replay.ReplayMismatchKind.fingerprint, replayed.report.mismatches[0].kind);
}

test "tampered external request identity fails replay before model fingerprint verification" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    _ = try recordReferenceSession(gpa, buffer, true);

    var request_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("request-a", &request_hash, .{});
    const bytes = buffer.bytes[0..buffer.len];
    const at = std.mem.indexOf(u8, bytes, &request_hash) orelse unreachable;
    bytes[at] ^= 0x80;

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = false,
    });
    try std.testing.expectError(error.ReplayEffectDivergence, result);
}

test "journaled effects that no replayed request matches name the divergence" {
    const gpa = std.testing.allocator;
    var buffer = JournalBuffer{};
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo" });
    recorder.stageEvent(.app_start);
    recorder.commitEvent();
    // A result for an effect the app never spawns.
    recorder.recordEffect(.{ .kind = .line, .key = 99, .payload = "ghost" });
    recorder.stageEvent(.wake);
    recorder.commitEvent();
    recorder.finish();

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = false,
    });
    try std.testing.expectError(error.ReplayEffectDivergence, result);
}

test "cross-platform journals are refused at the v1 bar" {
    const gpa = std.testing.allocator;
    var buffer = JournalBuffer{};
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "somewhere-else", .app_name = "session-demo" });
    recorder.stageEvent(.app_start);
    recorder.commitEvent();
    recorder.finish();

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = true,
    });
    try std.testing.expectError(error.ReplayPlatformMismatch, result);
}
