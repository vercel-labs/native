//! End-to-end session record/replay tests: record a driven UiApp session
//! (input events, effect results, checkpoints) to journal bytes, replay
//! it into a FRESH runtime and app, and verify equivalence — plus the
//! hostile-input side: truncated and tampered journals must fail loudly,
//! and a journal whose effects do not match the app's must name the
//! divergence.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");
const journal = @import("session_journal.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");

const canvas_label = "session-canvas";

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
    /// The search query's `on_input` mirror, zero-padded so the deep
    /// model equality below stays deterministic. The reference session
    /// types into the field and Escape-clears it: the journal records
    /// only the RAW click/type/Escape platform events, so replay must
    /// re-derive the same clear edit the recording's editor applied.
    query: [32]u8 = [_]u8{0} ** 32,
    query_len: usize = 0,
    query_anchor: usize = 0,
    query_focus: usize = 0,
    query_edits: u32 = 0,
    /// A SECOND editable field's mirror: the direct-verb replay tests
    /// need two editors so a composition targeting one can prove it
    /// does not land on whichever field the session left focused.
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    name_anchor: usize = 0,
    name_focus: usize = 0,
    name_edits: u32 = 0,
    /// The pinch channel's cumulative zoom (the product of 1 + delta
    /// across change events) plus phase counters: the reference session
    /// pinches once raw and once through the automation verb, so replay
    /// re-deriving the identical product pins the journaled scale field.
    zoom: f32 = 1,
    pinch_begins: u32 = 0,
    pinch_ends: u32 = 0,

    fn bodyText(self: *const SessionModel) []const u8 {
        return self.body[0..self.body_len];
    }

    fn queryText(self: *const SessionModel) []const u8 {
        return self.query[0..self.query_len];
    }

    fn nameText(self: *const SessionModel) []const u8 {
        return self.name[0..self.name_len];
    }
};

const SessionMsg = union(enum) {
    increment,
    stamp,
    quit,
    start_fetch,
    start_spawn,
    start_audio,
    query_edit: canvas.TextInputEvent,
    name_edit: canvas.TextInputEvent,
    pinch: platform.PinchEvent,
    fetched: effects_mod.EffectResponse,
    line: effects_mod.EffectLine,
    exited: effects_mod.EffectExit,
    tick: effects_mod.EffectTimer,
    audio_event: effects_mod.EffectAudio,
};

const SessionApp = ui_app_mod.UiApp(SessionModel, SessionMsg);

fn sessionUpdate(model: *SessionModel, msg: SessionMsg, fx: *SessionApp.Effects) void {
    switch (msg) {
        .increment => model.count += 1,
        .stamp => model.stamp_ms = fx.wallMs(),
        .quit => fx.quitApp(),
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
        .query_edit => |edit| applyMirrorEdit(&model.query, &model.query_len, &model.query_anchor, &model.query_focus, &model.query_edits, edit),
        .name_edit => |edit| applyMirrorEdit(&model.name, &model.name_len, &model.name_anchor, &model.name_focus, &model.name_edits, edit),
        .pinch => |pinch| switch (pinch.phase) {
            .begin => model.pinch_begins += 1,
            .change => model.zoom *= (1 + pinch.scale),
            .end => model.pinch_ends += 1,
        },
        .line => model.line_count += 1,
        .exited => |exit| model.exit_code = exit.code,
        .tick => |timer| model.tick_timestamp_ns = timer.timestamp_ns,
    }
}

/// One editable-field mirror step: apply `edit` to the zero-padded
/// text + selection mirror the deep model equality checks compare.
fn applyMirrorEdit(store: *[32]u8, len: *usize, anchor: *usize, focus: *usize, edits: *u32, edit: canvas.TextInputEvent) void {
    var scratch: [32]u8 = undefined;
    const next = (canvas.TextEditState{
        .text = store[0..len.*],
        .selection = .{ .anchor = anchor.*, .focus = focus.* },
    }).apply(edit, &scratch) catch return;
    var out = [_]u8{0} ** 32;
    const out_len = @min(next.text.len, out.len);
    std.mem.copyForwards(u8, out[0..out_len], next.text[0..out_len]);
    store.* = out;
    len.* = out_len;
    anchor.* = next.selection.anchor;
    focus.* = next.selection.focus;
    edits.* += 1;
}

fn sessionView(ui: *SessionApp.Ui, model: *const SessionModel) SessionApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.text(.{}, ui.fmt("Body {s} ({d})", .{ model.bodyText(), model.fetch_status })),
        ui.text(.{}, ui.fmt("Lines {d} Exit {d} Tick {d} Stamp {d}", .{ model.line_count, model.exit_code, model.tick_timestamp_ns, model.stamp_ms })),
        ui.el(.search_field, .{
            .text = model.queryText(),
            .placeholder = "Search",
            .on_input = SessionApp.Ui.inputMsg(.query_edit),
        }, .{}),
        ui.el(.text_field, .{
            .text = model.nameText(),
            .placeholder = "Name",
            .on_input = SessionApp.Ui.inputMsg(.name_edit),
        }, .{}),
        // A static multi-line source the paste replay pin copies from:
        // the journal records only the raw select-all/copy/paste
        // platform events, so the multi-line clipboard bytes and the
        // sanitized single-line insert both re-derive on replay.
        ui.el(.textarea, .{ .text = "line one\nline two" }, .{}),
        ui.text(.{}, ui.fmt("Query {s} ({d}) Name {s} ({d})", .{ model.queryText(), model.query_edits, model.nameText(), model.name_edits })),
        ui.text(.{}, ui.fmt("Zoom {d:.4} ({d}/{d})", .{ model.zoom, model.pinch_begins, model.pinch_ends })),
        ui.button(.{ .on_press = .increment }, "Increment"),
    });
}

fn sessionCommand(name: []const u8) ?SessionMsg {
    if (std.mem.eql(u8, name, "session.increment")) return .increment;
    if (std.mem.eql(u8, name, "session.stamp")) return .stamp;
    if (std.mem.eql(u8, name, "session.quit")) return .quit;
    if (std.mem.eql(u8, name, "session.fetch")) return .start_fetch;
    if (std.mem.eql(u8, name, "session.spawn")) return .start_spawn;
    if (std.mem.eql(u8, name, "session.audio")) return .start_audio;
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

fn sessionPinch(pinch: platform.PinchEvent) ?SessionMsg {
    return .{ .pinch = pinch };
}

fn sessionOptions() SessionApp.Options {
    return .{
        .name = "session-demo",
        .scene = session_scene,
        .canvas_label = canvas_label,
        .update_fx = sessionUpdate,
        .view = sessionView,
        .on_command = sessionCommand,
        .on_pinch = sessionPinch,
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

    // The world answers: one stdout line, a clean exit, and the fetch
    // response. Draining happens on the wake dispatch, which journals
    // each result right before its Msg runs through update.
    try app_state.effects.feedLine(2, "probe-line-1");
    try app_state.effects.feedExit(2, 0);
    try app_state.effects.feedResponse(1, 200, "hello-from-the-network");
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

    // An Escape-clear in the search field is DERIVED input state: the
    // journal records only the raw click/type/Escape platform events,
    // and replay must re-derive the same clear edit the recording's
    // editor applied — model mirror, retained editor, and fingerprint
    // all landing identically.
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    var search_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.kind == .search_field) search_frame = node.frame;
    }
    const field_frame = search_frame.?;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = field_frame.x + field_frame.width * 0.5,
        .y = field_frame.y + field_frame.height * 0.5,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = "glass",
    } });
    try std.testing.expectEqualStrings("glass", app_state.model.queryText());
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqualStrings("", app_state.model.queryText());
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // A recorded MULTI-LINE PASTE replays to the identical sanitized
    // value: copy the textarea's two lines (select-all + copy — raw
    // journaled inputs that rebuild the clipboard on replay), then paste
    // into the single-line search field. Sanitization is deterministic
    // derivation at the apply seam, so the replayed editor, the model
    // mirror, and the fingerprint all land on the same stripped bytes.
    var textarea_frame: ?geometry.RectF = null;
    for ((try harness.runtime.canvasWidgetLayout(1, canvas_label)).nodes) |node| {
        if (node.widget.kind == .textarea) textarea_frame = node.frame;
    }
    const source_frame = textarea_frame.?;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = source_frame.x + source_frame.width * 0.5,
        .y = source_frame.y + source_frame.height * 0.5,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "a",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "c",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = field_frame.x + field_frame.width * 0.5,
        .y = field_frame.y + field_frame.height * 0.5,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "v",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try std.testing.expectEqualStrings("line oneline two", app_state.model.queryText());

    // A trackpad pinch, twice over: the raw journaled phase stream (the
    // macOS host shape — begin, two deltas, end; the +25% then -25%
    // deltas compound as a PRODUCT, 1.25 * 0.75 = 0.9375, never a sum's
    // 1.0), then the automation verb's synthesized gesture, which
    // journals the same leaf gpu_surface_input events. Replay must
    // re-derive the identical cumulative zoom from the journaled scale
    // fields alone. Every value here is binary-exact in f32, so the
    // model equality below is exact, not approximate.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_begin,
        .x = 200,
        .y = 150,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_change,
        .x = 200,
        .y = 150,
        .scale = 0.25,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_change,
        .x = 200,
        .y = 150,
        .scale = -0.25,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_end,
        .x = 200,
        .y = 150,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    var pinch_buffer: [64]u8 = undefined;
    const pinch_command = try std.fmt.bufPrint(&pinch_buffer, "widget-pinch {s} 1.5 120 80", .{canvas_label});
    try harness.runtime.dispatchAutomationCommand(app, pinch_command);
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
    // The typed insert, the DERIVED Escape-clear, and the sanitized
    // multi-line paste all reached the model's `on_input` mirror — the
    // paste landing STRIPPED of its line breaks (single-line rule).
    try std.testing.expectEqual(@as(u32, 3), recorded.model.query_edits);
    try std.testing.expectEqualStrings("line oneline two", recorded.model.queryText());
    // Both pinch gestures reached the model: the raw stream's product
    // (1.25 * 0.75 = 0.9375) times the verb's exact 1.5.
    try std.testing.expectEqual(@as(u32, 2), recorded.model.pinch_begins);
    try std.testing.expectEqual(@as(u32, 2), recorded.model.pinch_ends);
    try std.testing.expectEqual(@as(f32, 1.40625), recorded.model.zoom);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expect(replayed.report.events_replayed > 0);
    try std.testing.expectEqual(@as(u64, 5), replayed.report.effects_fed);
    try std.testing.expect(replayed.report.checkpoints_verified > 0);
    try std.testing.expectEqualDeep(recorded.model, replayed.model);
    try std.testing.expectEqual(recorded.fingerprint, replayed.fingerprint);
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

test "accessibility actions journal once and replay without double-dispatch" {
    // A journaled `widget_accessibility_action` re-runs its verb on
    // replay, and the verb synthesizes REAL platform events (press its
    // Enter key, set_text a select-all plus a text input). If those
    // children also landed in the journal, replay would dispatch them
    // twice — the stray child arrives first, against the focus the
    // PREVIOUS action left behind, so a repeated press increments an
    // extra time and a repeated set_text edits the field extra times.
    // The recorder journals outer-wins: exactly one record per action,
    // and live/replay model counters match exactly.
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
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    var button_id: canvas.ObjectId = 0;
    var field_id: canvas.ObjectId = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .button) button_id = node.widget.id;
        if (node.widget.kind == .search_field) field_id = node.widget.id;
    }
    try std.testing.expect(button_id != 0);
    try std.testing.expect(field_id != 0);

    // Two AX presses: the second is the doubling witness — with the
    // synthesized Enter also journaled, replay delivers it against the
    // already-focused button and the count lands at 3, not 2.
    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = canvas_label,
        .id = button_id,
        .action = .press,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = canvas_label,
        .id = button_id,
        .action = .press,
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.model.count);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Two AX set_texts: the second one's stray select-all + text input
    // would hit the focused field on replay and inflate `query_edits`.
    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = canvas_label,
        .id = field_id,
        .action = .set_text,
        .text = "glass",
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = canvas_label,
        .id = field_id,
        .action = .set_text,
        .text = "brass",
    } });
    try std.testing.expectEqualStrings("brass", app_state.model.queryText());
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    const edits_after_set_text = app_state.model.query_edits;

    // An IME composition through the DIRECT verb surface (the embed
    // host's `widgetAction` path): no platform event arrives, so the
    // dispatch stages its own synthetic `widget_accessibility_action`
    // record — outer-wins exactly like the platform path — and the
    // synthesized ime children stay out of the journal. Replay re-runs
    // the verb, focus included.
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, canvas_label, .{
        .id = field_id,
        .action = .set_composition,
        .text = "ne",
    });
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, canvas_label, .{
        .id = field_id,
        .action = .commit_composition,
    });
    try std.testing.expectEqualStrings("brassne", app_state.model.queryText());
    // Both composition edits reached the model's `on_input` mirror.
    try std.testing.expect(app_state.model.query_edits > edits_after_set_text);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    const recorded_model = app_state.model;
    const recorded_fingerprint = harness.runtime.sessionStateFingerprint();

    // The journal carries one record per AX action — platform events
    // AND direct verb calls — and none of their synthesized key/text/ime
    // children.
    var reader = try journal.Reader.init(buffer.journalBytes());
    var action_records: usize = 0;
    while (try reader.next()) |record| {
        if (record != .event) continue;
        switch (record.event) {
            .widget_accessibility_action => action_records += 1,
            .gpu_surface_input => |input| switch (input.kind) {
                .ime_set_composition, .ime_commit_composition, .ime_cancel_composition, .key_down, .text_input => return error.SynthesizedChildJournaled,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), action_records);

    // Replay into a fresh app: every counter must match exactly — a
    // double-dispatched child shows up as +1 on `count` or extra
    // `query_edits`.
    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqual(@as(u32, 2), replayed.model.count);
    try std.testing.expectEqual(recorded_model.query_edits, replayed.model.query_edits);
    try std.testing.expectEqualDeep(recorded_model, replayed.model);
    try std.testing.expectEqual(recorded_fingerprint, replayed.fingerprint);
}

/// Shared scaffold for the direct-verb replay tests: recorder, harness,
/// started app, one presented frame, and the two editors' widget ids.
const DirectVerbSession = struct {
    recorder: *session_record.SessionRecorder,
    harness: *core.TestHarness(),
    app_state: *SessionApp,
    app: core.App,
    search_id: canvas.ObjectId,
    name_id: canvas.ObjectId,

    fn start(gpa: std.mem.Allocator, buffer: *JournalBuffer) !DirectVerbSession {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        errdefer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(SessionApp);
        errdefer gpa.destroy(app_state);
        app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
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

        const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
        var search_id: canvas.ObjectId = 0;
        var name_id: canvas.ObjectId = 0;
        for (layout.nodes) |node| {
            if (node.widget.kind == .search_field) search_id = node.widget.id;
            if (node.widget.kind == .text_field) name_id = node.widget.id;
        }
        try std.testing.expect(search_id != 0);
        try std.testing.expect(name_id != 0);

        return .{
            .recorder = recorder,
            .harness = harness,
            .app_state = app_state,
            .app = app,
            .search_id = search_id,
            .name_id = name_id,
        };
    }

    fn destroy(self: *const DirectVerbSession, gpa: std.mem.Allocator) void {
        self.app_state.deinit();
        gpa.destroy(self.app_state);
        self.harness.destroy(gpa);
        std.heap.page_allocator.destroy(self.recorder);
    }
};

/// The direct-verb journal must carry the AX action records and NONE of
/// their synthesized children — a child record is exactly the stray
/// input that replays against the wrong focus.
fn expectActionOnlyJournal(journal_bytes: []const u8, expected_actions: usize) !void {
    var reader = try journal.Reader.init(journal_bytes);
    var action_records: usize = 0;
    while (try reader.next()) |record| {
        if (record != .event) continue;
        switch (record.event) {
            .widget_accessibility_action => action_records += 1,
            .gpu_surface_input => |input| switch (input.kind) {
                .ime_set_composition, .ime_commit_composition, .ime_cancel_composition, .key_down, .text_input => return error.SynthesizedChildJournaled,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expectEqual(expected_actions, action_records);
}

test "a direct-verb composition first in a session replays onto its target editor" {
    // The P1 this pins: a direct-verb call (embed `widgetAction`,
    // automation `widget_action`) journaled only its synthesized ime
    // children — untargeted inputs routed by focus — while the verb's
    // own focus write never reached the journal. A composition as the
    // FIRST action of a session therefore replayed against a fresh
    // runtime with NO focused editor and the text vanished (the old
    // test passed only because earlier journaled AX records happened to
    // re-focus the same field). The synthetic outer record replays the
    // verb, which re-runs the focus.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const session = try DirectVerbSession.start(gpa, buffer);
    defer session.destroy(gpa);

    _ = try session.harness.runtime.dispatchCanvasWidgetAccessibilityAction(session.app, 1, canvas_label, .{
        .id = session.search_id,
        .action = .set_composition,
        .text = "ne",
    });
    _ = try session.harness.runtime.dispatchCanvasWidgetAccessibilityAction(session.app, 1, canvas_label, .{
        .id = session.search_id,
        .action = .commit_composition,
    });
    try std.testing.expectEqualStrings("ne", session.app_state.model.queryText());
    try session.harness.runtime.dispatchPlatformEvent(session.app, .frame_requested);

    session.recorder.finish();
    try std.testing.expect(!session.recorder.failed);
    try expectActionOnlyJournal(buffer.journalBytes(), 2);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqualStrings("ne", replayed.model.queryText());
    try std.testing.expectEqualDeep(session.app_state.model, replayed.model);
    try std.testing.expectEqual(session.harness.runtime.sessionStateFingerprint(), replayed.fingerprint);
}

test "a direct-verb composition targets its editor while another field holds focus" {
    // Focus field B (a real journaled click), then compose into field A
    // through the direct verb surface. Live, the verb re-focuses A; a
    // replay that only saw the ime children would deliver them to B —
    // the field the session left focused — writing the text into the
    // wrong editor. The outer record re-runs the verb against A.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const session = try DirectVerbSession.start(gpa, buffer);
    defer session.destroy(gpa);

    const layout = try session.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const search_frame = layout.findById(session.search_id).?.frame;
    try session.harness.runtime.dispatchPlatformEvent(session.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = search_frame.x + search_frame.width * 0.5,
        .y = search_frame.y + search_frame.height * 0.5,
    } });
    try session.harness.runtime.dispatchPlatformEvent(session.app, .frame_requested);

    _ = try session.harness.runtime.dispatchCanvasWidgetAccessibilityAction(session.app, 1, canvas_label, .{
        .id = session.name_id,
        .action = .set_composition,
        .text = "ada",
    });
    _ = try session.harness.runtime.dispatchCanvasWidgetAccessibilityAction(session.app, 1, canvas_label, .{
        .id = session.name_id,
        .action = .commit_composition,
    });
    try std.testing.expectEqualStrings("ada", session.app_state.model.nameText());
    try std.testing.expectEqualStrings("", session.app_state.model.queryText());
    try session.harness.runtime.dispatchPlatformEvent(session.app, .frame_requested);

    session.recorder.finish();
    try std.testing.expect(!session.recorder.failed);
    try expectActionOnlyJournal(buffer.journalBytes(), 2);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    // The composition landed on A, and B stayed clean — the wrong-focus
    // failure writes "ada" into `query` instead.
    try std.testing.expectEqualStrings("ada", replayed.model.nameText());
    try std.testing.expectEqualStrings("", replayed.model.queryText());
    try std.testing.expectEqualDeep(session.app_state.model, replayed.model);
    try std.testing.expectEqual(session.harness.runtime.sessionStateFingerprint(), replayed.fingerprint);
}

test "a direct-surface set_text first in a session replays onto its target editor" {
    // Same hole, set_text shape: the direct verb journaled a select-all
    // key plus a text input — both routed by focus — so first-in-session
    // they replayed into nothing. One outer record, replayed through the
    // verb, re-runs focus + select-all + insert exactly as live.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const session = try DirectVerbSession.start(gpa, buffer);
    defer session.destroy(gpa);

    _ = try session.harness.runtime.dispatchCanvasWidgetAccessibilityAction(session.app, 1, canvas_label, .{
        .id = session.search_id,
        .action = .set_text,
        .text = "glass",
    });
    try std.testing.expectEqualStrings("glass", session.app_state.model.queryText());
    try session.harness.runtime.dispatchPlatformEvent(session.app, .frame_requested);

    session.recorder.finish();
    try std.testing.expect(!session.recorder.failed);
    try expectActionOnlyJournal(buffer.journalBytes(), 1);

    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqualStrings("glass", replayed.model.queryText());
    try std.testing.expectEqualDeep(session.app_state.model, replayed.model);
    try std.testing.expectEqual(session.harness.runtime.sessionStateFingerprint(), replayed.fingerprint);
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

test "a menu-bar lifecycle session (policy hide, Dock reopen, quit) records and replays its window states" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    // Record: the host reports a .hide-policy window's whole lifecycle
    // as ordinary frame events — the hide (open stays true, hidden
    // flips), the Dock reopen's re-show, a second hide, and the tray
    // Quit's app_shutdown. The verbs themselves never journal; these
    // journaled platform events ARE the record.
    {
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

        const player_frame = geometry.RectF.init(0, 0, 400, 300);
        try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
            .id = 2,
            .label = "player",
            .title = "Player",
            .frame = player_frame,
            .open = true,
            .focused = true,
        } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
            .id = 2,
            .label = "player",
            .title = "Player",
            .frame = player_frame,
            .open = true,
            .focused = false,
            .hidden = true,
        } });
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
            .id = 2,
            .label = "player",
            .title = "Player",
            .frame = player_frame,
            .open = true,
            .focused = true,
            .hidden = false,
        } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
            .id = 2,
            .label = "player",
            .title = "Player",
            .frame = player_frame,
            .open = true,
            .focused = false,
            .hidden = true,
        } });
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        var recording_windows: [platform.max_windows]platform.WindowInfo = undefined;
        for (harness.runtime.listWindows(&recording_windows)) |info| {
            if (info.id == 2) try std.testing.expect(info.hidden);
        }
        // The quit verb's consequence: the host emits app_shutdown —
        // dispatching it runs the exactly-once stop hook AND seals the
        // recording's journal, exactly like a real quit.
        try harness.runtime.dispatchPlatformEvent(app, .app_shutdown);
        try std.testing.expect(recorder.finished);
        try std.testing.expect(!recorder.failed);
    }

    // Replay into a fresh app: every window state lands identically —
    // ending hidden, exactly as recorded — and the sealed journal
    // replays clean through the shutdown.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(SessionApp);
    defer gpa.destroy(app_state);
    app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
    defer app_state.deinit();
    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    var replayed_windows: [platform.max_windows]platform.WindowInfo = undefined;
    var found = false;
    for (harness.runtime.listWindows(&replayed_windows)) |info| {
        if (info.id != 2) continue;
        found = true;
        try std.testing.expect(info.open);
        try std.testing.expect(info.hidden);
    }
    try std.testing.expect(found);
}

test "a recorded quit journals the requesting command before the shutdown that seals it" {
    // The quit verb is requested MID DISPATCH: the command's update
    // returns fx.quitApp() while the command event still sits on the
    // recorder's staging stack. Hosts must therefore QUEUE the stop so
    // app_shutdown emits on the NEXT loop turn — a synchronous emit
    // nests the shutdown dispatch inside the command's, the nested
    // commit + finish() seals the journal, the outer commit no-ops,
    // and the journal loses the very command (and model mutation) that
    // quit the app. This test drives the whole verb chain through the
    // modeled host's queued seam and pins the contract: BOTH records
    // land, command first, and the session replays
    // fingerprint-identical.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    var recorded_model: SessionModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        const app_state = try gpa.create(SessionApp);
        defer gpa.destroy(app_state);
        // The REAL executor: fx.quitApp() must reach the platform's
        // quit seam (the fake executor stops at the mirror count).
        app_state.* = SessionApp.init(std.heap.page_allocator, .{}, sessionOptions());
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.increment", .window_id = 1 } });
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        // The tray-Quit shape: the command's update returns the quit
        // verb, which reaches the modeled host DURING this dispatch.
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "session.quit", .window_id = 1 } });
        try std.testing.expectEqual(@as(u32, 1), harness.null_platform.quit_request_count);
        // The quit dispatch alone must NOT have sealed the journal:
        // the host queued the stop instead of emitting synchronously.
        try std.testing.expect(!recorder.finished);

        // The queued stop's loop turn: drain the deferred shutdown and
        // dispatch it — exactly once — which seals the journal.
        const shutdown_event = harness.null_platform.takeQueuedQuit() orelse return error.TestUnexpectedResult;
        try harness.runtime.dispatchPlatformEvent(app, shutdown_event);
        try std.testing.expect(harness.null_platform.takeQueuedQuit() == null);
        try std.testing.expect(recorder.finished);
        try std.testing.expect(!recorder.failed);

        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
        try std.testing.expectEqual(@as(u32, 1), recorded_model.count);
    }

    // The journal contains BOTH the quitting command and the shutdown,
    // in that order — the assertion a synchronous (nested) emit fails.
    {
        var reader = try journal.Reader.init(buffer.journalBytes());
        var saw_quit_command = false;
        var saw_shutdown = false;
        while (try reader.next()) |record| {
            if (record != .event) continue;
            switch (record.event) {
                .menu_command => |command| {
                    if (std.mem.eql(u8, command.name, "session.quit")) saw_quit_command = true;
                },
                .app_shutdown => {
                    try std.testing.expect(saw_quit_command);
                    saw_shutdown = true;
                },
                else => {},
            }
        }
        try std.testing.expect(saw_quit_command);
        try std.testing.expect(saw_shutdown);
    }

    // And the sealed session replays fingerprint-identical into a
    // fresh app — the quitting command's model mutation included.
    const replayed = try replayIntoFreshApp(gpa, buffer.journalBytes(), true);
    try std.testing.expect(replayed.report.ok());
    try std.testing.expectEqual(@as(u32, 1), replayed.model.count);
    try std.testing.expectEqualDeep(recorded_model, replayed.model);
    try std.testing.expectEqual(recorded_fingerprint, replayed.fingerprint);
}

/// The quit-from-start boot: the app's `init_fx` returns the quit verb
/// during the installing canvas frame — the dispatch the macOS hosts
/// deliver synchronously BEFORE [NSApp run] exists.
fn sessionQuitOnBoot(model: *SessionModel, fx: *SessionApp.Effects) void {
    _ = model;
    fx.quitApp();
}

fn quitOnBootOptions() SessionApp.Options {
    var options = sessionOptions();
    options.init_fx = sessionQuitOnBoot;
    return options;
}

test "a quit from the app's boot dispatch journals the start turn before the shutdown that seals it" {
    // A VALID quit can arrive before the host's run loop exists:
    // App.start's update — `init_fx`, and a TS core's boot command with
    // it — runs inside the FIRST canvas frame dispatch, which the macOS
    // hosts deliver synchronously before [NSApp run]. Pre-run there is
    // no queue turn to defer to, so a host that falls back to an INLINE
    // shutdown emit nests the shutdown dispatch inside the very boot
    // dispatch that requested it — the recorder seals the journal
    // before the boot turn commits, the start of the session is lost,
    // and replay refuses the recording. The contract this test pins
    // through the modeled host's pending-then-drain seam (quitApp only
    // ARMS quit_pending; takeQueuedQuit hands the deferred shutdown to
    // dispatch as its own top-level turn — exactly the hosts' pre-run
    // pendingPreRunStop drain): the requesting boot turn seals nothing,
    // the journal carries the start event AND the shutdown in that
    // order, and the session replays fingerprint-identical.
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "session-demo", .window_width = 400, .window_height = 300 });

    var recorded_model: SessionModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        const app_state = try gpa.create(SessionApp);
        defer gpa.destroy(app_state);
        // The REAL executor: the boot fx.quitApp() must reach the
        // platform's quit seam.
        app_state.* = SessionApp.init(std.heap.page_allocator, .{}, quitOnBootOptions());
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);

        // The installing canvas frame — the pre-run synchronous
        // dispatch. init_fx runs inside it and returns the quit verb.
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expectEqual(@as(u32, 1), harness.null_platform.quit_request_count);
        // The boot dispatch that carried the quit has returned, and the
        // journal is NOT sealed: the quit is parked, never emitted
        // inline inside its own requesting dispatch.
        try std.testing.expect(!recorder.finished);

        // The drain turn — the hosts' post-dispatch top-level
        // emitShutdown + stop — seals the journal exactly once.
        const shutdown_event = harness.null_platform.takeQueuedQuit() orelse return error.TestUnexpectedResult;
        try harness.runtime.dispatchPlatformEvent(app, shutdown_event);
        try std.testing.expect(harness.null_platform.takeQueuedQuit() == null);
        try std.testing.expect(recorder.finished);
        try std.testing.expect(!recorder.failed);

        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // The journal contains BOTH the start event and the shutdown, in
    // that order — the assertion an inline (nested) pre-run emit fails:
    // nesting seals the journal before the boot turn commits, so the
    // start of the session never lands.
    {
        var reader = try journal.Reader.init(buffer.journalBytes());
        var saw_start = false;
        var saw_shutdown = false;
        while (try reader.next()) |record| {
            if (record != .event) continue;
            switch (record.event) {
                .app_start => saw_start = true,
                .app_shutdown => {
                    try std.testing.expect(saw_start);
                    saw_shutdown = true;
                },
                else => {},
            }
        }
        try std.testing.expect(saw_start);
        try std.testing.expect(saw_shutdown);
    }

    // And the sealed boot-quit session replays fingerprint-identical
    // into a fresh app whose init_fx quits again on replay.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try gpa.create(SessionApp);
        defer gpa.destroy(app_state);
        app_state.* = SessionApp.init(std.heap.page_allocator, .{}, quitOnBootOptions());
        defer app_state.deinit();
        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

// --------------------------------------------- image loads and the blob store

const session_blobs = @import("session_blobs.zig");

const image_canvas_label = "image-session-canvas";

const ImageSessionModel = struct {
    results: u32 = 0,
    loaded: u32 = 0,
    failed: u32 = 0,
    rejected: u32 = 0,
    last_width: usize = 0,
    last_height: usize = 0,
    last_outcome_name: [24]u8 = @splat(' '),
    last_outcome_len: usize = 0,
    /// Chatty-subprocess line counter, plus its value at the moment
    /// each image terminal lands: the pair makes delivery ORDER a
    /// model fact — a replay that reorders an image terminal around
    /// the recorded lines diverges here, not just in pixel state.
    lines_seen: u32 = 0,
    lines_before_image: u32 = 0,

    fn outcomeName(self: *const ImageSessionModel) []const u8 {
        return self.last_outcome_name[0..self.last_outcome_len];
    }
};

const ImageSessionMsg = union(enum) {
    load_cover,
    load_cover_again,
    load_broken,
    load_invalid,
    load_hostless,
    start_chatty,
    line: effects_mod.EffectLine,
    image: effects_mod.EffectImageResult,
};

const ImageSessionApp = ui_app_mod.UiApp(ImageSessionModel, ImageSessionMsg);

fn imageSessionUpdate(model: *ImageSessionModel, msg: ImageSessionMsg, fx: *ImageSessionApp.Effects) void {
    switch (msg) {
        .load_cover => fx.loadImage(.{ .id = 21, .path = "art/cover.png", .on_result = ImageSessionApp.Effects.imageMsg(.image) }),
        // A second id over the SAME bytes: the journal's blob store
        // must hold ONE blob for both records.
        .load_cover_again => fx.loadImage(.{ .id = 22, .path = "art/cover.png", .on_result = ImageSessionApp.Effects.imageMsg(.image) }),
        .load_broken => fx.loadImage(.{ .id = 23, .path = "art/broken.png", .on_result = ImageSessionApp.Effects.imageMsg(.image) }),
        // Id 0 is refused loop-side: a `.rejected` record that must
        // REGENERATE under replay rather than feed.
        .load_invalid => fx.loadImage(.{ .id = 0, .path = "art/cover.png", .on_result = ImageSessionApp.Effects.imageMsg(.image) }),
        // A URL that PASSES loop-side validation ("http:hostless"
        // parses with an http scheme) and is refused INSIDE the worker
        // (`std.http` cannot build a request without a host — no
        // network is ever touched): a `.rejected` terminal that is
        // worker truth, so its journaled record must FEED under replay
        // rather than be mistaken for regenerable validation.
        .load_hostless => fx.loadImage(.{ .id = 24, .url = "http:hostless", .on_result = ImageSessionApp.Effects.imageMsg(.image) }),
        // The chatty subprocess whose line results share the
        // completion queue with the image terminal.
        .start_chatty => fx.spawn(.{
            .key = 31,
            .argv = &.{ "chatty", "--emit" },
            .on_line = ImageSessionApp.Effects.lineMsg(.line),
        }),
        .line => model.lines_seen += 1,
        .image => |result| {
            model.lines_before_image = model.lines_seen;
            model.results += 1;
            switch (result.outcome) {
                .loaded => model.loaded += 1,
                .rejected => model.rejected += 1,
                else => model.failed += 1,
            }
            model.last_width = result.width;
            model.last_height = result.height;
            const name = @tagName(result.outcome);
            const len = @min(name.len, model.last_outcome_name.len);
            @memcpy(model.last_outcome_name[0..len], name[0..len]);
            model.last_outcome_len = len;
        },
    }
}

fn imageSessionView(ui: *ImageSessionApp.Ui, model: *const ImageSessionModel) ImageSessionApp.Ui.Node {
    // The semantic tree carries the image-derived model state, so the
    // fingerprint checkpoints PIN the Msg stream: a replay that
    // delivered different outcomes or dimensions mismatches here.
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results, {d} loaded, {d} failed, {d} rejected", .{ model.results, model.loaded, model.failed, model.rejected })),
        ui.text(.{}, ui.fmt("last {s} {d}x{d}", .{ model.outcomeName(), model.last_width, model.last_height })),
        ui.text(.{}, ui.fmt("{d} lines, {d} before image", .{ model.lines_seen, model.lines_before_image })),
    });
}

fn imageSessionCommand(name: []const u8) ?ImageSessionMsg {
    if (std.mem.eql(u8, name, "image.cover")) return .load_cover;
    if (std.mem.eql(u8, name, "image.again")) return .load_cover_again;
    if (std.mem.eql(u8, name, "image.broken")) return .load_broken;
    if (std.mem.eql(u8, name, "image.invalid")) return .load_invalid;
    if (std.mem.eql(u8, name, "image.hostless")) return .load_hostless;
    if (std.mem.eql(u8, name, "image.chatty")) return .start_chatty;
    return null;
}

const image_session_views = [_]app_manifest.ShellView{
    .{ .label = image_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const image_session_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Image Session",
    .width = 400,
    .height = 300,
    .views = &image_session_views,
}};
const image_session_scene: app_manifest.ShellConfig = .{ .windows = &image_session_windows };

fn imageSessionOptions() ImageSessionApp.Options {
    return .{
        .name = "image-session-demo",
        .scene = image_session_scene,
        .canvas_label = image_canvas_label,
        .update_fx = imageSessionUpdate,
        .view = imageSessionView,
        .on_command = imageSessionCommand,
    };
}

fn imageSessionPng(buffer: []u8) []const u8 {
    var pixels: [6 * 5 * 4]u8 = undefined;
    var seed: u8 = 23;
    for (&pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 31 +% 7;
    }
    var writer = std.Io.Writer.fixed(buffer);
    canvas.png.writeRgba8(&writer, 6, 5, &pixels) catch unreachable;
    return writer.buffered();
}

const RecordedImageSession = struct {
    model: ImageSessionModel,
    fingerprint: u64,
};

/// Record the image reference session: two loads of the same bytes
/// (one blob, two records), one decode failure (its bytes journal
/// too), and one loop-side rejection (regenerates at replay).
fn recordImageSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, store: *session_blobs.MemoryBlobStore) !RecordedImageSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "image-session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = image_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    var png_buffer: [4096]u8 = undefined;
    const png = imageSessionPng(&png_buffer);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.cover", .window_id = 1 } });
    try app_state.effects.feedImageBytes(21, png);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.again", .window_id = 1 } });
    try app_state.effects.feedImageBytes(22, png);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.broken", .window_id = 1 } });
    try app_state.effects.feedImageBytes(23, "these bytes are no image");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.invalid", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Both decoded loads are live in the recording runtime.
    try std.testing.expect(harness.runtime.registeredCanvasImage(21) != null);
    try std.testing.expect(harness.runtime.registeredCanvasImage(22) != null);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "image loads record into the blob store (deduplicated) and replay byte-identical, offline" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();

    const recorded = try recordImageSession(gpa, buffer, &store);
    try std.testing.expectEqual(@as(u32, 4), recorded.model.results);
    try std.testing.expectEqual(@as(u32, 2), recorded.model.loaded);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.failed);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.rejected);

    // Same bytes twice = ONE blob; the broken bytes are a second.
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqual(@as(usize, 1), store.dedup_hits);

    // Replay into a fresh app: the journal plus the blob store are the
    // WHOLE world — no files are read (the fake paths never existed),
    // no network is touched, and every fingerprint checkpoint matches.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    // NO manual decoder enablement here: the replay side installs its
    // decode seam through the SAME call `runSessionReplay` makes, in
    // the arm this codec-less test tier reaches (the strict test-PNG
    // fallback). Replay tests once flipped `image_decode` by hand while
    // the production runner installed no decoder at all — this test
    // holds the runner's construction path itself to the re-register
    // proof below.
    platform.installHeadlessImageCodec("null", &harness.null_platform, &harness.runtime.options.platform.services);
    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
        .blobs = store.source(),
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.checkpoints_verified > 0);
    // Two loaded terminals and the decode failure feed; the rejection
    // regenerates from the same loop-side validation.
    try std.testing.expectEqual(@as(u64, 3), report.effects_fed);
    try std.testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try std.testing.expectEqualDeep(recorded.model, app_state.model);
    try std.testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());

    // The replayed runtime re-registered the recorded bytes: the
    // pixels are drawable offline, straight from the blob store.
    const replay_registered = harness.runtime.registeredCanvasImage(21).?;
    try std.testing.expectEqual(@as(usize, 6), replay_registered.width);
    try std.testing.expectEqual(@as(usize, 5), replay_registered.height);
    try std.testing.expect(harness.runtime.registeredCanvasImage(22) != null);
    try std.testing.expect(harness.runtime.registeredCanvasImage(23) == null);
}

/// Record the queue-saturation reference session: a chatty spawn and
/// an image load whose results journal as ONE unbroken run — 64 line
/// records (the completion queue's whole capacity) followed by the
/// loaded image terminal. Results journal in delivery order, so a
/// LIVE recording reaches this shape whenever workers refill the
/// queue while the loop drains one pass. The fake executor feeds from
/// the loop thread and cannot overfill a single pass, so the first 32
/// lines drain through a wake whose EVENT record is withheld (the
/// runtime's recorder hook is cleared for exactly that dispatch; the
/// drained results still journal through the channel's bound journal)
/// — splicing two drain passes into the one run a live recorder
/// writes. Replay must then fit 65 consecutive feeds through the
/// 64-entry queue without losing the image bytes or reordering the
/// image terminal around the lines.
fn recordSaturatedImageSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, store: *session_blobs.MemoryBlobStore) !RecordedImageSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "image-session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = image_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.chatty", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.cover", .window_id = 1 } });

    var line_buffer: [16]u8 = undefined;
    var index: u32 = 0;
    while (index < 32) : (index += 1) {
        try app_state.effects.feedLine(31, try std.fmt.bufPrint(&line_buffer, "line-{d}", .{index}));
    }
    // The spliced drain: results journal, the wake event does not.
    harness.runtime.options.session_recorder = null;
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    harness.runtime.options.session_recorder = recorder;

    while (index < 64) : (index += 1) {
        try app_state.effects.feedLine(31, try std.fmt.bufPrint(&line_buffer, "line-{d}", .{index}));
    }
    var png_buffer: [4096]u8 = undefined;
    try app_state.effects.feedImageBytes(21, imageSessionPng(&png_buffer));
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // The recording itself saw every line BEFORE the image terminal,
    // with the decoded pixels registered.
    try std.testing.expectEqual(@as(u32, 64), app_state.model.lines_seen);
    try std.testing.expectEqual(@as(u32, 64), app_state.model.lines_before_image);
    try std.testing.expect(harness.runtime.registeredCanvasImage(21) != null);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a drain pass larger than the completion queue replays in order with the image bytes intact" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();

    const recorded = try recordSaturatedImageSession(gpa, buffer, &store);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    platform.installHeadlessImageCodec("null", &harness.null_platform, &harness.runtime.options.platform.services);
    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
        .blobs = store.source(),
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.checkpoints_verified > 0);
    // Every one of the run's 65 records fed — 64 lines plus the image
    // terminal — with nothing skipped and nothing dropped.
    try std.testing.expectEqual(@as(u64, 65), report.effects_fed);
    try std.testing.expectEqual(@as(u64, 0), report.effects_skipped);
    // Delivery ORDER survived saturation: the image terminal applied
    // after all 64 recorded lines, exactly as recorded.
    try std.testing.expectEqual(@as(u32, 64), app_state.model.lines_before_image);
    try std.testing.expectEqualDeep(recorded.model, app_state.model);
    try std.testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
    // The recorded bytes survived saturation: the replayed runtime
    // re-registered the journaled pixels, drawable offline.
    const replay_registered = harness.runtime.registeredCanvasImage(21) orelse return error.TestExpectedRegisteredImage;
    try std.testing.expectEqual(@as(usize, 6), replay_registered.width);
    try std.testing.expectEqual(@as(usize, 5), replay_registered.height);
}

/// Record a session whose single image load passes every loop-side
/// check and is refused by the REAL executor's worker: "http:hostless"
/// parses with an http scheme (the loop's whole validation) but has no
/// host, so building the request fails inside the worker before any
/// connection is attempted — a `.rejected` terminal with worker
/// provenance. The recording therefore holds a rejected image record
/// that the replayed `loadImage` can NOT regenerate (the fake executor
/// parks the request), which replay must feed from the journal.
fn recordWorkerRejectedImageSession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedImageSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "image-session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = image_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "image.hostless", .window_id = 1 } });
    // The real worker delivers asynchronously: pump its wake nudges
    // into `.wake` dispatches (each journals like any platform event)
    // until the terminal Msg lands.
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (app_state.model.results < 1) : (waited_ms += 10) {
        if (waited_ms >= 20_000) return error.TestTimedOut;
        var nudged = false;
        while (harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try harness.runtime.dispatchPlatformEvent(app, .wake);
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a worker-refused image load journals as executor truth and feeds under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordWorkerRejectedImageSession(gpa, buffer);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.results);
    try std.testing.expectEqual(@as(u32, 1), recorded.model.rejected);

    // Replay offline into a fresh app: the journaled rejected terminal
    // is worker truth — the fake executor parks the replayed request,
    // so the record must FEED (never skip) for the Msg to be delivered
    // at all. No blob store is needed: a rejection carries no bytes.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.checkpoints_verified > 0);
    try std.testing.expectEqual(@as(u64, 1), report.effects_fed);
    try std.testing.expectEqual(@as(u64, 0), report.effects_skipped);
    try std.testing.expectEqualDeep(recorded.model, app_state.model);
    try std.testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

test "a journal referencing blobs refuses to replay without its blob store" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();
    _ = try recordImageSession(gpa, buffer, &store);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = true;
    const app_state = try gpa.create(ImageSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ImageSessionApp.init(std.heap.page_allocator, .{}, imageSessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = false,
    });
    try std.testing.expectError(error.ReplayMissingBlob, result);
}

test "recording an image result without a blob store fails the journal loudly" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "image-session-demo" });
    recorder.recordEffect(.{ .kind = .image, .key = 21, .payload = "encoded bytes", .image_outcome = .loaded });
    try std.testing.expect(recorder.failed);
    _ = gpa;
}

test "image effect records round-trip the blob address through the journal codec" {
    var buffer: [4096]u8 = undefined;
    var hash: [effects_mod.effect_image_blob_hash_len]u8 = undefined;
    for (&hash, 0..) |*byte, index| byte.* = @intCast(index * 3 + 1);
    const encoded = try journal.encodeEffect(.{
        .kind = .image,
        .key = 21,
        .status = 200,
        .image_outcome = .loaded,
        .image_width = 640,
        .image_height = 480,
        .image_blob_hash = hash,
        .image_blob_len = 12_345,
    }, &buffer);
    const decoded = try journal.decodeEffect(encoded);
    try std.testing.expectEqual(effects_mod.EffectResultKind.image, decoded.kind);
    try std.testing.expectEqual(@as(u64, 21), decoded.key);
    try std.testing.expectEqual(@as(u16, 200), decoded.status);
    try std.testing.expectEqual(effects_mod.EffectImageOutcome.loaded, decoded.image_outcome);
    try std.testing.expectEqual(@as(u64, 640), decoded.image_width);
    try std.testing.expectEqual(@as(u64, 480), decoded.image_height);
    try std.testing.expectEqualSlices(u8, &hash, &decoded.image_blob_hash);
    try std.testing.expectEqual(@as(u64, 12_345), decoded.image_blob_len);
}
