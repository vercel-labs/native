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
    start_fetch,
    start_spawn,
    start_audio,
    query_edit: canvas.TextInputEvent,
    name_edit: canvas.TextInputEvent,
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
        ui.button(.{ .on_press = .increment }, "Increment"),
    });
}

fn sessionCommand(name: []const u8) ?SessionMsg {
    if (std.mem.eql(u8, name, "session.increment")) return .increment;
    if (std.mem.eql(u8, name, "session.stamp")) return .stamp;
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
