//! Audio-effect coverage: `fx.playAudio` and the transport commands
//! (`pauseAudio`/`resumeAudio`/`stopAudio`/`seekAudio`/`setAudioVolume`)
//! through the fake executor (deterministic request/feed round trips,
//! rejection) and the real executor against the null platform's fake
//! player — the same `PlatformServices` seam AVAudioPlayer serves on
//! macOS. One channel, key-identified events, explicit failure kinds,
//! and honest automation-snapshot state.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");

const canvas_label = "audio-canvas";

const audio_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const audio_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Audio",
    .width = 400,
    .height = 300,
    .views = &audio_views,
}};
const audio_scene: app_manifest.ShellConfig = .{ .windows = &audio_windows };

const AudioModel = struct {
    event_count: usize = 0,
    last_kind: ?effects_mod.EffectAudioEventKind = null,
    last_key: u64 = 0,
    last_position_ms: u64 = 0,
    last_duration_ms: u64 = 0,
    last_playing: bool = false,
    completed_count: usize = 0,

    fn record(model: *AudioModel, event: effects_mod.EffectAudio) void {
        model.event_count += 1;
        model.last_kind = event.kind;
        model.last_key = event.key;
        model.last_position_ms = event.position_ms;
        model.last_duration_ms = event.duration_ms;
        model.last_playing = event.playing;
        if (event.kind == .completed) model.completed_count += 1;
    }
};

const AudioMsg = union(enum) {
    play,
    play_empty_path,
    pause,
    unpause,
    stop,
    seek_half,
    quiet,
    audio_event: effects_mod.EffectAudio,
};

const AudioApp = ui_app_model.UiApp(AudioModel, AudioMsg);
const AudioEffects = AudioApp.Effects;

const track_key: u64 = 41;
const track_path = "assets/music/exit-signs/cedar-ave.mp3";

fn audioUpdate(model: *AudioModel, msg: AudioMsg, fx: *AudioEffects) void {
    switch (msg) {
        .play => fx.playAudio(.{
            .key = track_key,
            .path = track_path,
            .on_event = AudioEffects.audioMsg(.audio_event),
        }),
        .play_empty_path => fx.playAudio(.{
            .key = track_key,
            .path = "",
            .on_event = AudioEffects.audioMsg(.audio_event),
        }),
        .pause => fx.pauseAudio(),
        .unpause => fx.resumeAudio(),
        .stop => fx.stopAudio(),
        .seek_half => fx.seekAudio(60_000),
        .quiet => fx.setAudioVolume(0.25),
        .audio_event => |event| model.record(event),
    }
}

fn audioView(ui: *AudioApp.Ui, model: *const AudioModel) AudioApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} events", .{model.event_count})),
        ui.button(.{ .on_press = .play }, "Play"),
        ui.button(.{ .on_press = .pause }, "Pause"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *AudioApp,
    app: core.App,

    fn create() !Harness {
        return createConfigured(true);
    }

    /// `audio_playback = false` models a host without an audio player
    /// (GTK/Win32 today): the services are nulled BEFORE the platform
    /// value is captured, the same shape a real player-less host wires.
    fn createConfigured(audio_playback: bool) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.audio_playback = audio_playback;
        // The harness snapshots the services at create; re-capture so
        // the audio toggle above nulls the service fns the runtime
        // hands the effects channel — the same wiring a real
        // player-less host ships.
        harness.runtime.options.platform = harness.null_platform.platform();
        const app_state = try std.testing.allocator.create(AudioApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = AudioApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-audio",
            .scene = audio_scene,
            .canvas_label = canvas_label,
            .update_fx = audioUpdate,
            .view = audioView,
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

    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

// ------------------------------------------------------------ fake executor

test "fake executor records the playback request and feeds events back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Play: the request is recorded whole, not executed — nothing
    // touches the platform player.
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    const request = fx.pendingAudio().?;
    try std.testing.expectEqual(track_key, request.key);
    try std.testing.expectEqualStrings(track_path, request.path);
    try std.testing.expect(request.playing);
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.audio_load_count);

    // The loaded acknowledgment carries the real duration into update.
    try fx.feedAudioEvent(.loaded, 0, 89_160, true);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
    try std.testing.expectEqual(@as(u64, 89_160), h.app_state.model.last_duration_ms);

    // Position ticks advance the mirrors the snapshot reports.
    try fx.feedAudioEvent(.position, 1_500, 89_160, true);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.position, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 1_500), h.app_state.model.last_position_ms);
    try std.testing.expect(h.app_state.model.last_playing);
    try std.testing.expectEqual(@as(u64, 1_500), fx.audioSnapshot().position_ms);

    // Completion fires once, pinned to the duration, playback stopped.
    try fx.feedAudioEvent(.completed, 89_160, 89_160, false);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expectEqual(@as(u64, 89_160), h.app_state.model.last_position_ms);
    try std.testing.expect(!h.app_state.model.last_playing);
    try std.testing.expect(fx.audioSnapshot().active);
    try std.testing.expect(!fx.audioSnapshot().playing);
}

test "fake transport commands move the mirrors without a platform" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try fx.feedAudioEvent(.loaded, 0, 120_000, true);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);

    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expect(!fx.audioSnapshot().playing);
    try h.app_state.dispatch(&h.harness.runtime, 1, .unpause);
    try std.testing.expect(fx.audioSnapshot().playing);
    try h.app_state.dispatch(&h.harness.runtime, 1, .seek_half);
    try std.testing.expectEqual(@as(u64, 60_000), fx.audioSnapshot().position_ms);
    try h.app_state.dispatch(&h.harness.runtime, 1, .quiet);
    try std.testing.expectEqual(@as(f32, 0.25), fx.pendingAudio().?.volume);

    // Stop clears the channel; late feeds report EffectNotFound.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expect(fx.pendingAudio() == null);
    try std.testing.expect(!fx.audioSnapshot().active);
    try std.testing.expectError(error.EffectNotFound, fx.feedAudioEvent(.position, 61_000, 120_000, true));
}

test "playback requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play_empty_path);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.rejected, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
    try std.testing.expect(fx.pendingAudio() == null);
}

// ------------------------------------------------------------ real executor

test "real executor drives the platform player and events round-trip" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setAudioDuration("cedar-ave.mp3", 89_160);

    // Play loads and starts the platform's single player.
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try std.testing.expectEqual(@as(usize, 1), np.audio_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.audio_play_count);
    try std.testing.expectEqualStrings(track_path, np.audio.path());
    try std.testing.expect(np.audio.playing);

    // The loaded acknowledgment arrives as a platform event, exactly as
    // a live host would deliver it after the load call returned.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeAudioLoaded().?);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 89_160), h.app_state.model.last_duration_ms);

    // Position ticks advance on the test's explicit clock, never on
    // their own.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.position, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 1_000), h.app_state.model.last_position_ms);

    // The automation snapshot reports playback honestly.
    const playing_snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(track_key, playing_snapshot.key);
    try std.testing.expect(playing_snapshot.playing);
    try std.testing.expectEqual(@as(u64, 1_000), playing_snapshot.position_ms);
    try std.testing.expectEqual(@as(u64, 89_160), playing_snapshot.duration_ms);

    // Pause freezes the platform player; ticks stop with it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expectEqual(@as(usize, 1), np.audio_pause_count);
    try std.testing.expect(np.advanceAudio(500) == null);
    try h.app_state.dispatch(&h.harness.runtime, 1, .unpause);

    // Seek moves the platform position; the next tick reports from it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .seek_half);
    try std.testing.expectEqual(@as(u64, 60_000), np.audio.position_ms);

    // Advancing past the end delivers the one completion.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(40_000).?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expectEqual(@as(u64, 89_160), h.app_state.model.last_position_ms);
    try std.testing.expect(!h.app_state.model.last_playing);
    try std.testing.expect(np.advanceAudio(500) == null);

    // Volume rides through to the platform player.
    try h.app_state.dispatch(&h.harness.runtime, 1, .quiet);
    try std.testing.expectEqual(@as(f32, 0.25), np.audio.volume);

    // Stop unloads; the snapshot goes honestly idle (null, not zeros).
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expectEqual(@as(usize, 1), np.audio_stop_count);
    try std.testing.expect(!np.audio.loaded);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Audio").audio == null);
}

test "a platform without audio playback degrades to one failed event" {
    // Model GTK/Win32 today: the services are absent and the feature
    // reports false, so playback fails loudly through the Msg loop
    // instead of crashing or silently no-opping.
    var h = try Harness.createConfigured(false);
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Audio").audio == null);
}

test "a platform straggler after stop is swallowed, never misattributed" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    const loaded = np.takeAudioLoaded().?;
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    // The loaded event from before the stop arrives late: no Msg, no
    // model change.
    const before = h.app_state.model.event_count;
    try h.harness.runtime.dispatchPlatformEvent(h.app, loaded);
    try std.testing.expectEqual(before, h.app_state.model.event_count);
}
