//! End-to-end proof battery for examples/soundboard-ts — the launch-gate
//! port: a soundboard-complexity app authored in TypeScript + Native
//! markup with ZERO hand-written Zig. The build transpiles the example's
//! REAL core (examples/soundboard-ts/src/core.ts) and this suite drives
//! it through `TsUiApp` with the example's SHIPPING markup
//! (app.native, staged beside this file), so every pin here is the
//! product path, not a fixture:
//!
//!   - the markup view binds the ported catalog (grid, counts, the
//!     now-playing bar's idle state);
//!   - playback flows end to end: play -> the engine's audio request
//!     (prepared path, hosted URL, manifest byte size) -> loaded ->
//!     position ticks -> the rendered clock -> auto-advance at the
//!     natural end, with the play-next queue winning the advance;
//!   - the duration rule: the platform's estimate never replaces the
//!     manifest total;
//!   - the one-channel stale-event window: position/completed reports
//!     from a replaced playback are dropped by the model guard;
//!   - the rendered-clock subscription arms a REAL platform timer only
//!     while audio moves;
//!   - Copy Title lands on the clipboard channel;
//!   - search drives the full byte-splice text engine from raw platform
//!     text input;
//!   - a recorded session (user input + scripted audio events) replays
//!     byte-identically with zero host calls;
//!   - dispatch stays far under the frame budget at the rendered-clock
//!     cadence (the "on_frame cadence untested" flag, measured).
//!
//! Only this TEST wiring is Zig — the command mapper below exists so the
//! suite can dispatch payload-carrying Msgs through the journaled
//! menu-command path (the app itself dispatches them from markup).

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const core = @import("ts_soundboard_core");

const runtime_ns = native_sdk.runtime;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;

const app_markup = @embedFile("app.native");
const CompiledAppView = canvas.CompiledMarkupView(core.Model, core.Msg, app_markup);

const canvas_label = "soundboard-canvas";

/// The playclock subscription's platform timer id: the bridge's timer
/// slot 0 lands in engine timer slot 0.
const playclock_platform_id: u64 = runtime_ns.effect_timer_platform_id_base + 0;

const app_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const app_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Soundboard TS",
    .width = 1080,
    .height = 720,
    .views = &app_views,
}};
const app_scene: native_sdk.ShellConfig = .{ .windows = &app_windows };

/// TEST-ONLY command mapper: lets the suite dispatch the payload-carrying
/// Msgs the app's markup dispatches from presses and context menus, but
/// through the journaled menu-command path (record/replay needs every
/// input in the journal). "sb.play.12" plays track 12, etc.
fn testCommand(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "sb.toggle")) return .toggle_play;
    if (std.mem.eql(u8, name, "sb.next")) return .next_track;
    if (std.mem.eql(u8, name, "sb.prev")) return .prev_track;
    if (std.mem.eql(u8, name, "sb.songs")) return .show_songs;
    if (std.mem.eql(u8, name, "sb.albums")) return .show_albums;
    if (commandId(name, "sb.play.")) |id| return .{ .play_track = id };
    if (commandId(name, "sb.playalbum.")) |id| return .{ .play_album = id };
    if (commandId(name, "sb.open.")) |id| return .{ .open_album = id };
    if (commandId(name, "sb.queue.")) |id| return .{ .queue_track = id };
    if (commandId(name, "sb.copy.")) |id| return .{ .copy_title = id };
    return null;
}

fn commandId(name: []const u8, prefix: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return std.fmt.parseInt(i64, name[prefix.len..], 10) catch null;
}

fn appOptions() App.Options {
    return .{
        .name = "soundboard-ts-e2e",
        .scene = app_scene,
        .canvas_label = canvas_label,
        // The comptime-compiled engine over the example's shipping markup
        // — the whole view tier of the app under test.
        .view = CompiledAppView.build,
        .on_command = testCommand,
        // The manifest theme channel, mirrored from the example's
        // app.zon exactly as the generated wiring resolves it
        // (manifestThemePack + manifestThemeAccent): the geist pack
        // under the Zig original's pink accent identity.
        .theme = .geist,
        .theme_accent = canvas.Color.rgb8(0xdf, 0x26, 0x70),
    };
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    clock: native_sdk.TestClock,

    fn create() !*Harness {
        return createFull(null, .real);
    }

    /// A harness on the FAKE effects executor: clipboard requests park in
    /// fake slots for assertions instead of reaching platform services.
    fn createFake() !*Harness {
        return createFull(null, .fake);
    }

    fn createRecorded(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        return createFull(recorder, .real);
    }

    fn createFull(recorder: ?*runtime_ns.SessionRecorder, executor: runtime_ns.EffectExecutor) !*Harness {
        return createConfigured(recorder, executor, .{});
    }

    /// A harness with adapter-owned knobs (boot images, env overrides) —
    /// the CoreOptions the generated wiring passes from app.zon assets
    /// and the launch environment.
    fn createConfigured(recorder: ?*runtime_ns.SessionRecorder, executor: runtime_ns.EffectExecutor, core_options: Adapter.CoreOptions) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.clock = .{};
        self.clock.setWallMs(60_000);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = geometry.SizeF.init(1080, 720),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.null_platform.image_decode = true;
        self.harness.runtime.options.session_recorder = recorder;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, core_options, appOptions());
        self.app_state.effects.executor = executor;
        self.app_state.effects.clock = self.clock.clock();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(1080, 720),
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

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    /// Feed one scripted audio event and drain it into the core (the
    /// engine parks events until a dispatchable wake).
    fn audio(self: *Harness, kind: anytype, position_ms: u64, duration_ms: u64, playing: bool) !void {
        try self.app_state.effects.feedAudioEvent(kind, position_ms, duration_ms, playing);
        try self.wake();
    }

    fn audioBuffering(self: *Harness, kind: anytype, position_ms: u64, duration_ms: u64, playing: bool, buffering: bool) !void {
        try self.app_state.effects.feedAudioEventBuffering(kind, position_ms, duration_ms, playing, buffering);
        try self.wake();
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    fn findId(self: *Harness, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findKindText(self.app_state.tree.?.root, kind, text);
    }

    fn findLabel(self: *Harness, label: []const u8) ?canvas.ObjectId {
        return findByLabel(self.app_state.tree.?.root, label);
    }

    /// Click a rendered widget through the automation verb — the same
    /// headless path `native automate` drives.
    fn click(self: *Harness, id: canvas.ObjectId) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn textInput(self: *Harness, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .text_input,
            .text = text,
        } });
    }

    fn keyDown(self: *Harness, key: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .key_down,
            .key = key,
        } });
    }

    fn firePlayclock(self: *Harness, timestamp_ns: u64) !bool {
        const event = self.harness.null_platform.fireTimer(playclock_platform_id, timestamp_ns) orelse return false;
        try self.harness.runtime.dispatchPlatformEvent(self.app, event);
        return true;
    }

    fn playclockArmed(self: *Harness) bool {
        const timer = self.harness.null_platform.startedTimer(playclock_platform_id) orelse return false;
        return timer.active;
    }
};

fn findKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindText(child, kind, text)) |id| return id;
    }
    return null;
}

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.ObjectId {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget.id;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |id| return id;
    }
    return null;
}

// -------------------------------------------------------- markup binding

test "the shipping markup binds the ported catalog: grid, counts, and the idle bar" {
    const h = try Harness.create();
    defer h.destroy();

    // The album grid page with the full committed catalog.
    try std.testing.expect(h.hasText("8 of 8"));
    try std.testing.expect(h.hasText("Exit Signs"));
    try std.testing.expect(h.hasText("Channel Surfing"));
    try std.testing.expect(h.hasText("Harbor Sleep"));
    try std.testing.expect(!h.hasText("Playing"));

    // The idle now-playing bar: prompt title, placeholder clocks.
    try std.testing.expect(h.hasText("Nothing playing"));
    try std.testing.expect(h.hasText("Pick an album or a song to start"));
    try std.testing.expect(h.hasText("-:--"));

    // The Songs page mounts every catalog track as a markup row with the
    // artist-album subtitle (the byte-built em-dash join).
    try h.menu("sb.songs");
    try std.testing.expect(h.hasText("68 of 68"));
    try std.testing.expect(h.hasText("Mile Marker West"));
    try std.testing.expect(h.hasText("Harbor Sleep — Exit Signs"));

    // A markup album tile press opens the detail page: heading, the
    // byte-built meta line, and the record's rows (numbers, durations).
    try h.menu("sb.albums");
    try h.click(h.findLabel("Exit Signs").?);
    try std.testing.expect(h.hasText("Harbor Sleep · 2025 · 8 tracks"));
    try std.testing.expect(h.hasText("Winter Birds"));
    try std.testing.expect(h.hasText("2:44")); // 164832ms, the manifest duration
    try std.testing.expect(h.findId(.button, "Play album") != null);

    // Back to the grid through the markup back button.
    try h.click(h.findId(.button, "Back to albums").?);
    try std.testing.expect(h.hasText("8 of 8"));
}

test "the runtime markup interpreter builds the emitted model exactly like the compiled engine" {
    // The PRODUCT wiring runs app.native through the runtime interpreter
    // (hot reload); this suite compiles it at comptime. Hold the two
    // engines text-identical over the booted model so the product path
    // can never drift from the tested one.
    const h = try Harness.create();
    defer h.destroy();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = h.app_state.model;
    const AppUi = canvas.Ui(core.Msg);
    var interpreter_view = try canvas.MarkupView(core.Model, core.Msg).init(arena, app_markup);
    var interpreter_ui = AppUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = AppUi.init(arena);
    const compiled = try compiled_ui.finalize(CompiledAppView.build(&compiled_ui, &model));

    var interpreted_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer interpreted_texts.deinit(std.testing.allocator);
    var compiled_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer compiled_texts.deinit(std.testing.allocator);
    try collectTexts(interpreted.root, &interpreted_texts, std.testing.allocator);
    try collectTexts(compiled.root, &compiled_texts, std.testing.allocator);
    try std.testing.expectEqualStrings(interpreted_texts.items, compiled_texts.items);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "Nothing playing") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "Exit Signs") != null);
}

fn collectTexts(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, widget.text);
    try out.append(allocator, '\n');
    for (widget.children) |child| {
        try collectTexts(child, out, allocator);
    }
}

// ------------------------------------------------------------- playback

test "playback flows end to end: play, the duration rule, the rendered clock, auto-advance, and the queue" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // A markup row press starts REAL playback: the engine channel holds
    // the request whole — the prepared local path first, the hosted URL
    // fallback, and the manifest's byte size as the cache integrity gate.
    try h.click(h.findLabel("Exit Signs").?);
    try h.click(h.findId(.button, "Play album").?);
    const request = fx.pendingAudio().?;
    try std.testing.expectEqual(runtime_ns.ts_core_audio_key_base, request.key);
    try std.testing.expectEqualStrings("assets/music/exit-signs/mile-marker-west.mp3", request.path);
    try std.testing.expectEqualStrings("https://xksenynjs1imkkii.public.blob.vercel-storage.com/music/exit-signs/mile-marker-west.mp3", request.url);
    try std.testing.expectEqual(@as(u64, 3982923), request.expected_bytes);
    try std.testing.expect(Bridge.model().playing);
    try std.testing.expect(Bridge.model().loadPending);

    // The duration rule: the platform's own estimate (165s) never
    // replaces the manifest total (164832ms renders as 2:44 in the bar
    // AND the track list — the two surfaces agree by construction).
    try h.audio(.loaded, 0, 165_000, true);
    try std.testing.expect(!Bridge.model().loadPending);
    try std.testing.expectEqual(@as(i64, 164_832), Bridge.model().nowDurationMs);
    try std.testing.expectEqual(@as(i64, 165_000), Bridge.model().platformDurationMs);
    try std.testing.expect(h.hasText("2:44"));
    try std.testing.expect(h.hasText("0:00"));

    // Position ticks move the rendered clock; the elapsed label follows.
    try h.audio(.position, 1_500, 165_000, true);
    try std.testing.expectEqual(@as(i64, 1_500), Bridge.model().elapsedMs);
    try std.testing.expect(h.hasText("0:01"));

    // The never-rewind rule: a small backward tick holds flat while the
    // clock is in motion; a past-slack disagreement snaps.
    try h.audio(.position, 1_400, 165_000, true);
    try std.testing.expectEqual(@as(i64, 1_500), Bridge.model().elapsedMs);
    try h.audio(.position, 100, 165_000, true);
    try std.testing.expectEqual(@as(i64, 100), Bridge.model().elapsedMs);

    // The rendered-clock subscription is a REAL platform timer that
    // exists exactly while audio moves; each fire advances one interval.
    try std.testing.expect(h.playclockArmed());
    try std.testing.expect(try h.firePlayclock(2_000_000));
    try std.testing.expectEqual(@as(i64, 350), Bridge.model().elapsedMs);

    // The honest buffering state reads where the artist normally does,
    // and the motion-gated subscription reconciles away.
    try h.audioBuffering(.position, 400, 165_000, true, true);
    try std.testing.expect(Bridge.model().buffering);
    try std.testing.expect(h.hasText("buffering..."));
    try std.testing.expect(!h.playclockArmed());
    try h.audioBuffering(.position, 900, 165_000, true, false);
    try std.testing.expect(!Bridge.model().buffering);
    try std.testing.expect(h.playclockArmed());

    // Queue a track from the songs library (the markup dispatches this
    // from the row's context menu): the badge appears and the natural
    // end advances into the QUEUE, not the album order.
    try h.menu("sb.queue.16");
    try std.testing.expect(h.hasText("1 queued"));
    // The queued track's row wears the Up-next badge (it lives in the
    // songs library - a different album than the open detail page).
    try h.menu("sb.songs");
    try std.testing.expect(h.hasText("Up next"));
    try h.menu("sb.albums");
    try h.audio(.completed, 164_832, 165_000, false);
    const queued_request = fx.pendingAudio().?;
    try std.testing.expectEqualStrings("assets/music/second-nature/velvet-jackpot.mp3", queued_request.path);
    try std.testing.expectEqual(@as(?i64, 16), Bridge.model().now);
    try std.testing.expectEqual(@as(usize, 0), Bridge.model().queue.len);
    try std.testing.expect(!h.hasText("1 queued"));

    // With the queue drained, completion advances through the album in
    // manifest order (Velvet Jackpot -> Second Nature).
    try h.audio(.loaded, 0, 131_000, true);
    try h.audio(.completed, 130_872, 131_000, false);
    try std.testing.expectEqual(@as(?i64, 17), Bridge.model().now);
    try std.testing.expectEqualStrings("assets/music/second-nature/second-nature.mp3", fx.pendingAudio().?.path);

    // Pause parks the transport (optimistic flag, engine verb, timer
    // gone); resume brings all three back.
    try h.audio(.loaded, 0, 80_000, true);
    try h.menu("sb.toggle");
    try std.testing.expect(!Bridge.model().playing);
    try std.testing.expect(!fx.audioSnapshot().playing);
    try std.testing.expect(!h.playclockArmed());
    try h.menu("sb.toggle");
    try std.testing.expect(Bridge.model().playing);
    try std.testing.expect(fx.audioSnapshot().playing);

    // prev within the first 3 seconds goes to the PREVIOUS track;
    // past 3 seconds it restarts the current one through the seek verb.
    try h.audio(.position, 1_000, 80_000, true);
    try h.menu("sb.prev");
    try std.testing.expectEqual(@as(?i64, 16), Bridge.model().now);
    try h.audio(.loaded, 0, 131_000, true);
    try h.audio(.position, 5_000, 131_000, true);
    try h.menu("sb.prev");
    try std.testing.expectEqual(@as(?i64, 16), Bridge.model().now);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().elapsedMs);
    try std.testing.expectEqual(@as(u64, 0), fx.audioSnapshot().position_ms);
}

test "one audio channel: stale reports from a replaced playback drop by the model guard" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // Track 1 plays and reports; then track 3 replaces it. Until the new
    // playback's `loaded` acknowledgment, position and completed reports
    // can only belong to the replaced track — the guard drops both.
    try h.menu("sb.play.1");
    try h.audio(.loaded, 0, 165_000, true);
    try h.audio(.position, 9_000, 165_000, true);
    try h.menu("sb.play.3");
    try std.testing.expect(Bridge.model().loadPending);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().elapsedMs);

    // A straggler position from the old playback: the rendered clock
    // must not scrub the new track.
    try h.audio(.position, 9_500, 165_000, true);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().elapsedMs);

    // A straggler completion: the player must not double-advance.
    try h.audio(.completed, 164_832, 165_000, false);
    try std.testing.expectEqual(@as(?i64, 3), Bridge.model().now);

    // The new playback's own acknowledgment reopens the stream.
    try h.audio(.loaded, 0, 71_000, true);
    try std.testing.expect(!Bridge.model().loadPending);
    try h.audio(.position, 2_000, 71_000, true);
    try std.testing.expectEqual(@as(i64, 2_000), Bridge.model().elapsedMs);

    // Spectrum frames are consciously ignored (parity with the Zig
    // original — the soundboard's identity is the clean catalog).
    var bands: [32]u8 = undefined;
    for (&bands, 0..) |*b, i| b.* = @intCast(i * 3);
    try fx.feedAudioSpectrum(bands, 3_000, 71_000);
    try h.wake();
    try std.testing.expectEqual(@as(i64, 2_000), Bridge.model().elapsedMs);

    // A failure is never silence: playback clears and the honest stream
    // notice reads where the track title did.
    try h.audio(.failed, 0, 0, false);
    try std.testing.expectEqual(@as(?i64, null), Bridge.model().now);
    try std.testing.expect(Bridge.model().streamFailed);
    try std.testing.expect(h.hasText("stream unavailable"));
    try std.testing.expect(h.hasText("check the connection and try again"));

    // Browsing keeps working, and the next play clears the notice.
    try std.testing.expect(h.hasText("8 of 8"));
    try h.menu("sb.play.1");
    try std.testing.expect(!Bridge.model().streamFailed);
}

// -------------------------------------------------------------- clipboard

test "Copy Title lands on the clipboard" {
    const h = try Harness.createFake();
    defer h.destroy();
    const fx = &h.app_state.effects;

    try h.menu("sb.play.5");
    try h.audio(.loaded, 0, 195_000, true);

    // Copy Title (the markup row's context-menu item) writes the track
    // title to the clipboard channel — fire-and-forget, one request.
    // (The app carries no volume control — parity with the Zig original;
    // the audioSetVolume verb stays proven by the host e2e suite's
    // fixture core.)
    try std.testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());
    try h.menu("sb.copy.5");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    try std.testing.expectEqualStrings("Untitled", fx.pendingClipboardAt(0).?.text);
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().copiesRequested);
}

// --------------------------------------------------------------- search

test "search drives the full text engine from raw platform input and filters both libraries" {
    const h = try Harness.create();
    defer h.destroy();

    // Focus the markup search field and type through the platform's
    // text-input channel — the core's byte-splice engine applies each
    // event at the caret the runtime reports.
    try h.click(h.findId(.search_field, "").?);
    try h.textInput("night");
    try std.testing.expectEqualStrings("night", Bridge.model().search.bytes);
    try std.testing.expect(h.hasText("1 of 8"));
    try std.testing.expect(h.hasText("Night Bloom"));
    try std.testing.expect(!h.hasText("Exit Signs"));

    // The songs library filters on title, artist, AND album title: every
    // Night Bloom track matches through its album.
    try h.menu("sb.songs");
    try std.testing.expect(h.hasText("8 of 68"));
    try std.testing.expect(h.hasText("Japanese Maple"));

    // Word-delete clears the term through the caret-aware path; the
    // catalog returns whole.
    try h.keyDown("backspace");
    try std.testing.expectEqualStrings("nigh", Bridge.model().search.bytes);
    try std.testing.expect(h.hasText("8 of 68"));
    try h.textInput("XYZ");
    try std.testing.expect(h.hasText("0 of 68"));
    try std.testing.expect(h.hasText("No matches for \"nighXYZ\""));
    try std.testing.expect(h.hasText("Try an album, artist, or song title."));

    // Deleting the term restores the catalog whole.
    for (0..7) |_| try h.keyDown("backspace");
    try std.testing.expectEqualStrings("", Bridge.model().search.bytes);
    try std.testing.expect(h.hasText("68 of 68"));
}

test "automation set_text replaces the search term: the select-all sentinel translates into the core's i64 mirror" {
    const h = try Harness.create();
    defer h.destroy();

    // Seed a term through real typing so the replace verb's select-all
    // has bytes to select.
    try h.click(h.findId(.search_field, "").?);
    try h.textInput("night");
    try std.testing.expectEqualStrings("night", Bridge.model().search.bytes);

    // `native automate widget-action <search> set_text` routes focus,
    // cmd/ctrl+A, then the replacement through the REAL input path.
    // Select-all synthesizes `set_selection` carrying the
    // `focus = maxInt(usize)` "to the end" sentinel; this core declares
    // its TextSelection mirror as i64, so the declared-union translation
    // must SATURATE the sentinel — @intCast panicked "integer does not
    // fit in destination type" here, killing every set_text against a
    // TS app on the live-GUI smoke (real typing was fine; this is the
    // headless twin of that crash).
    var buffer: [96]u8 = undefined;
    const command = try std.fmt.bufPrint(&buffer, "widget-action {s} {d} set-text bloom", .{ canvas_label, h.findId(.search_field, "night").? });
    try h.harness.runtime.dispatchAutomationCommand(h.app, command);

    // The core's byte-splice engine heard the whole sequence: the snapped
    // select-all plus the inserted bytes REPLACE the term (append would
    // read "nightbloom" — that would mean the selection mirror was lost).
    try std.testing.expectEqualStrings("bloom", Bridge.model().search.bytes);
    try std.testing.expect(h.hasText("Night Bloom"));
}

// ------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [512 * 1024]u8 = undefined,
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

/// A value snapshot of the committed soundboard model (committed slices
/// live in the core's heap — copy what outlives a session).
const SoundboardSnapshot = struct {
    now: ?i64,
    playing: bool,
    elapsed_ms: i64,
    now_duration_ms: i64,
    queue_len: usize,
    copies_requested: i64,

    fn take() SoundboardSnapshot {
        const m = Bridge.model();
        return .{
            .now = m.now,
            .playing = m.playing,
            .elapsed_ms = m.elapsedMs,
            .now_duration_ms = m.nowDurationMs,
            .queue_len = m.queue.len,
            .copies_requested = m.copiesRequested,
        };
    }
};

/// One reference session: journaled user input (menu commands) plus the
/// scripted audio event feed — play, load, ticks, a queue, the
/// completion advance, a clipboard copy.
fn recordSession(buffer: *JournalBuffer) !SoundboardSnapshot {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "soundboard-ts-e2e", .window_width = 1080, .window_height = 720 });

    const h = try Harness.createRecorded(recorder);
    defer h.destroy();

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try h.menu("sb.play.2");
    try h.audio(.loaded, 0, 47_000, true);
    try h.audio(.position, 1_500, 47_000, true);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try h.menu("sb.queue.16");
    try h.audio(.completed, 46_944, 47_000, false);
    try h.audio(.loaded, 0, 131_000, true);
    try h.menu("sb.copy.16");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return SoundboardSnapshot.take();
}

test "a recorded soundboard session replays byte-identically with zero host calls" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordSession(buffer);
    try std.testing.expectEqual(@as(?i64, 16), recorded.now);
    try std.testing.expect(recorded.playing);
    try std.testing.expectEqual(@as(i64, 130_872), recorded.now_duration_ms);
    try std.testing.expectEqual(@as(i64, 1), recorded.copies_requested);

    // Determinism pin: the same driven session records byte-identical
    // journal bytes.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const recorded_again = try recordSession(second);
    try std.testing.expectEqualDeep(recorded, recorded_again);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app: the journaled audio events feed the
    // re-issued (parked) playback in recorded order — no platform player,
    // no network, no host calls.
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(1080, 720),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, appOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.events_replayed > 0);
    // The journaled effect results are exactly the four audio events.
    try std.testing.expectEqual(@as(u64, 4), report.effects_fed);
    try std.testing.expectEqualDeep(recorded, SoundboardSnapshot.take());
}

// ------------------------------------------------------------------ perf

test "dispatch at the rendered-clock cadence stays far under the frame budget" {
    const h = try Harness.create();
    defer h.destroy();

    try h.menu("sb.play.1");
    try h.audio(.loaded, 0, 165_000, true);

    // Whole-pipeline dispatches (update + commit + command walk +
    // subscription reconcile + view rebuild) at the clock cadence — the
    // hot path a per-frame Zig app exercises through on_frame. The
    // position feed is the heavier arm (it re-renders the transport).
    //
    // Each measurement asserts the BEST of a few attempts: on a
    // congested shared runner (CI parallelism, sibling test binaries
    // compiling) contention only ever ADDS time, so a healthy build
    // passes on its first attempt and pays nothing extra, while a
    // genuine dispatch regression is slow on every attempt and still
    // fails. The budgets themselves are unchanged — this absorbs
    // scheduler noise, not slow code. Re-feeding the same event
    // sequence is state-idempotent: every attempt ends on the same
    // committed model, which the assertions between the loops pin.
    const iterations: usize = 400;
    const perf_attempts: usize = 3;
    var per_dispatch_ns: u64 = std.math.maxInt(u64);
    for (0..perf_attempts) |_| {
        const start_ns = runtime_ns.monotonicNanoseconds();
        for (0..iterations) |index| {
            try h.audio(.position, @intCast(1_000 + index * 250), 165_000, true);
        }
        const elapsed_ns = runtime_ns.monotonicNanoseconds() - start_ns;
        per_dispatch_ns = @min(per_dispatch_ns, elapsed_ns / iterations);
        if (per_dispatch_ns < 16_000_000) break;
    }
    try std.testing.expectEqual(@as(i64, 1_000 + 399 * 250), Bridge.model().elapsedMs);

    // The core alone (update + commit + command walk + subscription
    // reconcile), without the runtime pipeline around it - the cost the
    // transpiled tier adds per tick.
    const fx = &h.app_state.effects;
    var per_core_dispatch_ns: u64 = std.math.maxInt(u64);
    for (0..perf_attempts) |_| {
        const core_start_ns = runtime_ns.monotonicNanoseconds();
        for (0..iterations) |index| {
            Bridge.dispatch(fx, .{ .clock_tick = @floatFromInt(60_000 + index * 250) });
        }
        const core_elapsed_ns = runtime_ns.monotonicNanoseconds() - core_start_ns;
        per_core_dispatch_ns = @min(per_core_dispatch_ns, core_elapsed_ns / iterations);
        if (per_core_dispatch_ns < 1_000_000) break;
    }
    h.app_state.model = Bridge.model().*;

    // Every whole-pipeline dispatch (update + commit + effects + the full
    // 68-row markup rebuild) must fit ONE 60Hz frame budget even in a
    // Debug build on loaded CI hardware; the core alone must be
    // microseconds. Measured on an M-class laptop (Debug): ~3.3ms whole
    // pipeline, ~450ns core-only.
    try std.testing.expect(per_dispatch_ns < 16_000_000);
    try std.testing.expect(per_core_dispatch_ns < 1_000_000);
}

// -------------------------------------------- round 7B: parity closure
// The four launch-gate blockers the port named, closed and pinned here:
// scrub-to-seek (the value-payload change event), controlled scroll (the
// declared ScrollState mirror), and the generated-wiring channels the
// app adopted (frame width -> grid columns, the key fallback, cover
// assets, the launch env override).

test "scrub-to-seek: the slider's value event seeks the engine and jumps the clock" {
    const h = try Harness.create();
    defer h.destroy();

    try h.menu("sb.play.1");
    try h.audio(.loaded, 0, 165_000, true);
    try std.testing.expectEqual(@as(i64, 164_832), Bridge.model().nowDurationMs);

    // Step the seek slider through the automation increment verb — the
    // keyboard set_value intent resolving through markup's on-change
    // VALUE constructor (the applied f32 0.05 widening into the core's
    // one-number float arm).
    const slider = h.findLabel("Seek").?;
    var buffer: [96]u8 = undefined;
    const command = try std.fmt.bufPrint(&buffer, "widget-action {s} {d} increment", .{ canvas_label, slider });
    try h.harness.runtime.dispatchAutomationCommand(h.app, command);

    // fraction 0.05 -> permille 50 of the manifest total's thousandth
    // (164ms): the whole-integer target of the core's two-domain split.
    try std.testing.expectEqual(@as(i64, 8_200), Bridge.model().elapsedMs);
    // And the engine's single player actually sought there (the audio_ctl
    // seek verb, key-gated to the open stream).
    try std.testing.expectEqual(@as(u64, 8_200), h.app_state.effects.audio.position_ms);
    // The rendered clock renders the jump.
    try std.testing.expect(h.hasText("0:08"));
}

test "controlled scroll: the offset echoes into the model and album open resets it" {
    const h = try Harness.create();
    defer h.destroy();

    // Wheel the album grid: the runtime applies the offset, and the
    // declared ScrollState mirror arm echoes the applied value into the
    // committed model (never fighting the reconcile rule).
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 540,
        .y = 300,
        .delta_y = 240,
    } });
    try std.testing.expect(Bridge.model().libraryScrollTop > 0);

    // Opening an album is a page change: the model resets the offset (the
    // port's named consequence — the detail page opens at its top).
    try h.click(h.findLabel("Exit Signs").?);
    try std.testing.expectEqual(@as(f64, 0), Bridge.model().libraryScrollTop);
}

test "the frame channel adapts the album grid to the canvas width" {
    const h = try Harness.create();
    defer h.destroy();

    // The installing frame is excluded by the UiApp contract; the first
    // presented frame delivers 1080 and the Zig original's width rule
    // answers four columns.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(1080, 720),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try std.testing.expectEqual(@as(i64, 1080), Bridge.model().canvasWidth);
    try std.testing.expectEqual(@as(usize, 4), findGrid(h.app_state.tree.?.root).?.layout.columns);

    // A live resize re-derives: 1400pt fits five 232pt tiles.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(1400, 720),
        .scale_factor = 1,
        .frame_index = 3,
        .timestamp_ns = 3_000_000,
    } });
    try std.testing.expectEqual(@as(i64, 1400), Bridge.model().canvasWidth);
    try std.testing.expectEqual(@as(usize, 5), findGrid(h.app_state.tree.?.root).?.layout.columns);
}

test "a search narrowed below the column count keeps natural tile size" {
    const h = try Harness.create();
    defer h.destroy();

    // Establish the presented 1080pt frame: the width rule answers four
    // columns and a 249pt evenly-grown tile.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(1080, 720),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    const full_tile = core.gridTileWidth(Bridge.model());

    // Search down to ONE matching album: the grid narrows to one shown
    // column and its exact one-tile width, so the lone cover keeps the
    // fit's natural tile size (never ballooning across the freed row).
    try h.click(h.findId(.search_field, "").?);
    try h.textInput("night");
    try std.testing.expect(h.hasText("1 of 8"));
    const grid = findGrid(h.app_state.tree.?.root).?;
    try std.testing.expectEqual(@as(usize, 1), grid.layout.columns);
    try std.testing.expectApproxEqAbs(full_tile, @as(f64, grid.layout.max_size.width), 0.5);

    // The laid-out tile takes exactly that width.
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    var tiles: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind != .list_item or node.widget.semantics.role != .listitem) continue;
        tiles += 1;
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(full_tile)), node.frame.width, 0.5);
    }
    try std.testing.expectEqual(@as(usize, 1), tiles);
}

test "the key fallback drives the transport: space toggles, arrows change tracks" {
    const h = try Harness.create();
    defer h.destroy();

    // Nothing focused: space falls through the widget precedence rule to
    // the core's keyMsg (delivered lowercased) and starts playback.
    try h.keyDown("Space");
    try h.audio(.loaded, 0, 0, true);
    try std.testing.expect(Bridge.model().playing);
    try std.testing.expectEqual(@as(?i64, 1), Bridge.model().now);

    // Right arrow advances within the album; space pauses.
    try h.keyDown("ArrowRight");
    try std.testing.expectEqual(@as(?i64, 2), Bridge.model().now);
    try h.keyDown("Space");
    try std.testing.expect(!Bridge.model().playing);
}

test "cover assets register at install and bind the grid avatars by album id" {
    // PNG twins through the adapter's boot-image channel (the committed
    // art is JPEG for real hosts' codecs; the null platform's strict
    // decoder takes the engine's own PNG output — same register path the
    // generated wiring drives from app.zon).
    const rgba = [_]u8{ 200, 40, 40, 255 } ** 4;
    var encoded: [256]u8 = undefined;
    var png_writer = std.Io.Writer.fixed(&encoded);
    try canvas.png.writeRgba8(&png_writer, 2, 2, &rgba);
    const boot_images = [_]Adapter.BootImage{.{ .id = 1, .bytes = png_writer.buffered() }};
    const h = try Harness.createConfigured(null, .real, .{ .boot_images = &boot_images });
    defer h.destroy();

    // Registered on the installing frame, before the first view build.
    try std.testing.expectEqual(@as(usize, 1), h.harness.runtime.canvas_image_count);
    // The grid avatar binds the album id as its ImageId (unregistered ids
    // keep the initials fallback, so the other seven tiles degrade
    // honestly).
    var covers: usize = 0;
    countAvatarImageIds(h.app_state.tree.?.root, 1, &covers);
    try std.testing.expectEqual(@as(usize, 1), covers);
}

test "the launch env override rides the envMsgs channel: local-only failures report the assets notice" {
    // An EMPTY NATIVE_SDK_MUSIC_URL_BASE turns streaming off — the Zig
    // original's launch split, delivered here as one journaled Msg.
    const env_values = [_]Adapter.EnvValue{.{ .msg = "url_base_set", .value = "" }};
    const h = try Harness.createConfigured(null, .real, .{ .env_values = &env_values });
    defer h.destroy();

    try h.menu("sb.play.1");
    // The issued play carries NO stream URL (local-only).
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.audio.url_len);
    try h.audio(.failed, 0, 0, false);
    try std.testing.expect(h.hasText("music assets not prepared"));
    try std.testing.expect(!h.hasText("stream unavailable"));
}

test "a non-empty env base replaces the stream host wholesale" {
    const env_values = [_]Adapter.EnvValue{.{ .msg = "url_base_set", .value = "https://mirror.test/" }};
    const h = try Harness.createConfigured(null, .real, .{ .env_values = &env_values });
    defer h.destroy();

    try h.menu("sb.play.1");
    // Trailing slashes trim; the track path's "assets" prefix drops.
    try std.testing.expectEqualStrings(
        "https://mirror.test/music/exit-signs/mile-marker-west.mp3",
        h.app_state.effects.audio.url_buffer[0..h.app_state.effects.audio.url_len],
    );
    // A failure with the stream configured stays the stream notice.
    try h.audio(.failed, 0, 0, false);
    try std.testing.expect(h.hasText("stream unavailable"));
}

test "album tiles are quiet on hover (the original's quiet-tile treatment)" {
    const h = try Harness.create();
    defer h.destroy();

    // Every grid tile carries the quiet-surface knob: no hover wash on
    // image-forward cover art, while press/selection fills, the focus
    // ring, and hit testing keep their own channels. Track rows keep
    // their washes (the wash IS the affordance on acting controls).
    const grid = findGrid(h.app_state.tree.?.root).?;
    try std.testing.expect(grid.children.len > 0);
    for (grid.children) |tile| {
        try std.testing.expectEqual(canvas.WidgetKind.list_item, tile.kind);
        try std.testing.expect(tile.style.quiet_hover);
    }
    try h.menu("sb.songs");
    var row_count: usize = 0;
    countLoudListItems(h.app_state.tree.?.root, &row_count);
    try std.testing.expect(row_count >= 60);
}

fn countLoudListItems(widget: canvas.Widget, count: *usize) void {
    if (widget.kind == .list_item and !widget.style.quiet_hover) count.* += 1;
    for (widget.children) |child| {
        countLoudListItems(child, count);
    }
}

fn findGrid(widget: canvas.Widget) ?canvas.Widget {
    if (widget.kind == .grid) return widget;
    for (widget.children) |child| {
        if (findGrid(child)) |found| return found;
    }
    return null;
}

fn countAvatarImageIds(widget: canvas.Widget, id: canvas.ImageId, count: *usize) void {
    if (widget.kind == .avatar and widget.image_id == id) count.* += 1;
    for (widget.children) |child| {
        countAvatarImageIds(child, id, count);
    }
}

// --------------------------------------------------- transport bar layout

fn transportBarFrame(h: *Harness) ?geometry.RectF {
    const layout = h.harness.runtime.canvasWidgetLayout(1, canvas_label) catch return null;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Now playing bar")) return node.frame;
    }
    return null;
}

fn expectBarFlushAtBottom(h: *Harness, canvas_height: f32) !void {
    const frame = transportBarFrame(h) orelse return error.TransportBarMissing;
    try std.testing.expectEqual(@as(f32, 76), frame.height);
    try std.testing.expectApproxEqAbs(canvas_height - 76, frame.y, 0.01);
}

test "the transport bar stays flush at the bottom across a rebuild storm" {
    const h = try Harness.create();
    defer h.destroy();

    // Playing state: the rebuild storm below is the live app's worst
    // case — clock ticks and position events rebuild every 250ms.
    try h.menu("sb.playalbum.2");
    try h.audio(.loaded, 0, 0, true);
    try expectBarFlushAtBottom(h, 720);

    // The regression this pins (the runtime's presented-size adoption):
    // during a live resize the presented FRAMES carry the drawable's new
    // size before the window-manager resize event lands. Every
    // dispatch-driven rebuild inside that gap used to lay out at the
    // stale bounds, painting the transport bar below the shrunk
    // window's bottom edge (cut off) until the resize event arrived.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(900, 600),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try expectBarFlushAtBottom(h, 600);

    // A storm of dispatch-driven rebuilds in the gap (no resize event
    // yet): clock ticks, a position correction, page changes, search
    // keystrokes, a queue change — the bar must hold the new bottom
    // through every one.
    _ = try h.firePlayclock(3_000_000_000);
    try expectBarFlushAtBottom(h, 600);
    try h.audio(.position, 1500, 0, true);
    try expectBarFlushAtBottom(h, 600);
    try h.menu("sb.open.2");
    try expectBarFlushAtBottom(h, 600);
    try h.menu("sb.albums");
    try expectBarFlushAtBottom(h, 600);
    try h.menu("sb.songs");
    try expectBarFlushAtBottom(h, 600);
    try h.menu("sb.queue.9");
    try expectBarFlushAtBottom(h, 600);
    try h.click(h.findLabel("Search library").?);
    try h.textInput("g");
    try expectBarFlushAtBottom(h, 600);

    // The late resize event is a no-reflow confirmation.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = canvas_label,
        .frame = geometry.RectF.init(0, 0, 900, 600),
        .scale_factor = 1,
    } });
    try expectBarFlushAtBottom(h, 600);

    // Growing back mid-playback holds the same law from the other side.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(1080, 720),
        .scale_factor = 1,
        .frame_index = 3,
        .timestamp_ns = 3_000_000,
    } });
    try expectBarFlushAtBottom(h, 720);
    _ = try h.firePlayclock(4_000_000_000);
    try expectBarFlushAtBottom(h, 720);
}

// ------------------------------------------------------------ theme accent

test "the manifest accent layers the original's pink over the pack (high contrast skips it)" {
    const h = try Harness.create();
    defer h.destroy();

    // The resolved rebuild tokens carry the accent identity bundle: the
    // pink accent under white knockout ink, the focus ring moved with
    // the identity, and the seek slider's filled range restated — the
    // Zig original's tokens_fn, reached through app.zon's theme_accent.
    const pink = canvas.Color.rgb8(0xdf, 0x26, 0x70);
    const tokens = h.app_state.effectiveTokens();
    try std.testing.expectEqual(pink, tokens.colors.accent);
    try std.testing.expectEqual(canvas.Color.rgb8(255, 255, 255), tokens.colors.accent_text);
    try std.testing.expectEqual(pink, tokens.colors.focus_ring);
    try std.testing.expectEqual(pink, tokens.controls.slider.active_background);

    // High contrast takes the pack's own loud register with no brand
    // layer (accessibility beats brand — the original's rule).
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{
        .color_scheme = .light,
        .high_contrast = true,
    } });
    const loud = h.app_state.effectiveTokens();
    try std.testing.expect(!std.meta.eql(pink, loud.colors.accent));
}

// --------------------------------------------------- parity captures

// Env-gated parity capture (skipped by default, never in CI): renders
// the port OFFSCREEN through the deterministic reference renderer via
// the automation screenshot artifact — the side-by-side proof against
// the Zig original's identical states. PNGs land in
// /tmp/parity-shots/ts-{grid,detail,songs}-{0,1}-artifacts/. To use
// (the magick loop prepares RGBA twins of the committed covers once,
// the homepage-shots recipe):
//
//   mkdir -p /tmp/soundboard-art
//   for f in examples/soundboard/src/art/*.jpg; do
//     magick "$f" -depth 8 rgba:/tmp/soundboard-art/"$(basename "${f%.jpg}")".rgba
//   done
//   PARITY_SHOTS=1 zig build test-ts-core-e2e
test "render parity screenshots (env-gated)" {
    if (!envGateSet("PARITY_SHOTS")) return error.SkipZigTest;
    const io = std.testing.io;

    const sizes = [_]geometry.SizeF{ geometry.SizeF.init(1080, 720), geometry.SizeF.init(1400, 800) };
    const cover_stems = [_][]const u8{
        "exit-signs",      "blue-season", "second-nature",  "no-good-way-out",
        "glass-flowers",   "night-bloom", "motion-picture", "channel-surfing",
    };
    for (sizes, 0..) |size, size_index| {
        const h = try Harness.create();
        defer h.destroy();

        // The standard macOS tall hidden-inset chrome geometry: the
        // resize re-query dispatches it through the core's chromeMsg.
        h.harness.null_platform.window_chrome = .{
            .insets = .{ .top = 52, .left = 78 },
            .buttons = geometry.RectF.init(20, 19, 52, 14),
        };
        try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_resized = .{
            .window_id = 1,
            .label = canvas_label,
            .frame = geometry.RectF.init(0, 0, size.width, size.height),
            .scale_factor = 1,
        } });

        // Real covers on the real decode->register path: RGBA twins of
        // the committed JPEG art through the engine's own PNG writer
        // (the null platform's strict decoder refuses JPEG honestly).
        var art_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer art_arena_state.deinit();
        const art_arena = art_arena_state.allocator();
        for (cover_stems, 1..) |stem, album_id| {
            var path_buffer: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "/tmp/soundboard-art/{s}.rgba", .{stem});
            const rgba = std.Io.Dir.cwd().readFileAlloc(io, path, art_arena, .limited(8 * 1024 * 1024)) catch continue;
            const side = std.math.sqrt(rgba.len / 4);
            const encoded = try art_arena.alloc(u8, try canvas.png.encodedRgba8ByteLen(side, side));
            var png_writer = std.Io.Writer.fixed(encoded);
            try canvas.png.writeRgba8(&png_writer, side, side, rgba);
            _ = try h.app_state.effects.registerImageBytes(album_id, png_writer.buffered());
        }

        // The shared reference state (identical on the Zig original's
        // side): Summer Rental (track 9, album 2) playing at 24636ms of
        // its 98544ms manifest total — exactly 0.25 on both progress
        // derivations — under the light scheme.
        try h.menu("sb.play.9");
        try h.audio(.loaded, 0, 0, true);
        try h.audio(.position, 24_636, 0, true);
        try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .light } });

        try presentParityFrame(h, size, 2);
        try parityShot(h, io, "ts-grid", size_index);

        try h.menu("sb.open.2");
        try presentParityFrame(h, size, 3);
        try parityShot(h, io, "ts-detail", size_index);

        try h.menu("sb.albums");
        try h.menu("sb.songs");
        try presentParityFrame(h, size, 4);
        try parityShot(h, io, "ts-songs", size_index);
    }
}

/// Env-gated dump switch (the original suite's helper): `std.c.getenv`
/// needs libc, which this test build links on macOS; when absent the
/// gate reads unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}

fn presentParityFrame(h: *Harness, size: geometry.SizeF, frame_index: u64) !void {
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = size,
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

fn parityShot(h: *Harness, io: std.Io, comptime name: []const u8, size_index: usize) !void {
    var dir_buffer: [96]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, "/tmp/parity-shots/{s}-{d}-artifacts", .{ name, size_index });
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, dir, "SoundboardTS");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot soundboard-canvas 2");
}
