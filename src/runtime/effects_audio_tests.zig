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
const platform = @import("../platform/root.zig");

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
    last_buffering: bool = false,
    last_bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
    completed_count: usize = 0,
    spectrum_count: usize = 0,

    fn record(model: *AudioModel, event: effects_mod.EffectAudio) void {
        model.event_count += 1;
        model.last_kind = event.kind;
        model.last_key = event.key;
        model.last_position_ms = event.position_ms;
        model.last_duration_ms = event.duration_ms;
        model.last_playing = event.playing;
        model.last_buffering = event.buffering;
        model.last_bands = event.bands;
        if (event.kind == .completed) model.completed_count += 1;
        if (event.kind == .spectrum) model.spectrum_count += 1;
    }
};

const AudioMsg = union(enum) {
    play,
    play_url,
    play_url_only,
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
const track_url = "https://music.example.test/pack/music/exit-signs/cedar-ave.mp3";
const track_cache_path = "/tmp/fake-caches/audio/cedar-ave-cache.mp3";
const track_bytes: u64 = 2_154_887;

fn audioUpdate(model: *AudioModel, msg: AudioMsg, fx: *AudioEffects) void {
    switch (msg) {
        .play => fx.playAudio(.{
            .key = track_key,
            .path = track_path,
            .on_event = AudioEffects.audioMsg(.audio_event),
        }),
        // The full cascade shape: local path first, url fallback with a
        // cache path and the manifest's byte size as the integrity gate.
        .play_url => fx.playAudio(.{
            .key = track_key,
            .path = track_path,
            .url = track_url,
            .cache_path = track_cache_path,
            .expected_bytes = track_bytes,
            .on_event = AudioEffects.audioMsg(.audio_event),
        }),
        // URL-only: no local probe at all.
        .play_url_only => fx.playAudio(.{
            .key = track_key,
            .url = track_url,
            .cache_path = track_cache_path,
            .expected_bytes = track_bytes,
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

    const Config = struct {
        /// false models a host without an audio player (a GTK host
        /// without runtime GStreamer): the services are nulled BEFORE the
        /// platform value is captured, the same shape a real player-less host wires.
        audio_playback: bool = true,
        /// false models a host with a local player but no streaming
        /// path: `audioLoadUrl` is absent and URL playback degrades to
        /// one loud failed Msg.
        audio_streaming: bool = true,
        /// false models a host that plays but cannot analyze its own
        /// playback: `audio_spectrum` reports unsupported and the fake
        /// generator answers null — the honest-absence path consumers
        /// must rest on instead of fabricating bands.
        audio_spectrum: bool = true,
    };

    fn create() !Harness {
        return createConfigured(.{});
    }

    fn createConfigured(config: Config) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.audio_playback = config.audio_playback;
        harness.null_platform.audio_streaming = config.audio_streaming;
        harness.null_platform.audio_spectrum = config.audio_spectrum;
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

test "real spectrum reports round-trip: deterministic fake, honest gating, snapshot evidence" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setAudioDuration("cedar-ave.mp3", 89_160);

    // No spectrum before anything plays: analysis rides playback.
    try std.testing.expect(np.audioSpectrum() == null);

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeAudioLoaded().?);

    // The fake generator is a pure function of (source, position): the
    // same instant answers identical bands — the event-shape pin the
    // journal round-trip and replay determinism rely on.
    const first = np.audioSpectrum().?;
    const again = np.audioSpectrum().?;
    try std.testing.expectEqual(platform.AudioEventKind.spectrum, first.audio.kind);
    try std.testing.expectEqualSlices(u8, &first.audio.bands, &again.audio.bands);
    var nonzero = false;
    for (first.audio.bands) |band| {
        if (band != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);

    // Delivered like every audio event: through the channel into the
    // app's Msg, bands verbatim, plus the snapshot's evidence mirrors.
    try h.harness.runtime.dispatchPlatformEvent(h.app, first);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.spectrum, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
    try std.testing.expectEqualSlices(u8, &first.audio.bands, &h.app_state.model.last_bands);
    var snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(@as(u64, 1), snapshot.spectrum_events);
    try std.testing.expectEqualSlices(u8, &first.audio.bands, snapshot.spectrum_bands);

    // Bands move with the playback position (per-instant determinism,
    // not a frozen frame) ...
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    const later = np.audioSpectrum().?;
    try std.testing.expect(!std.mem.eql(u8, &first.audio.bands, &later.audio.bands));

    // ... and spectrum reports never steer the transport: the position
    // mirror stays where the position ticks put it.
    try h.harness.runtime.dispatchPlatformEvent(h.app, later);
    snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(@as(u64, 500), snapshot.position_ms);
    try std.testing.expectEqual(@as(u64, 2), snapshot.spectrum_events);

    // Pause starves the stream — freeze-on-pause holds with real data.
    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expect(np.audioSpectrum() == null);
    try h.app_state.dispatch(&h.harness.runtime, 1, .unpause);

    // Stop unloads: no more reports, and a straggler after stop is
    // swallowed by the channel like every other audio event.
    const straggler = np.audioSpectrum().?;
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expect(np.audioSpectrum() == null);
    const before = h.app_state.model.event_count;
    try h.harness.runtime.dispatchPlatformEvent(h.app, straggler);
    try std.testing.expectEqual(before, h.app_state.model.event_count);
}

test "occluded-emission rule: spectrum stops while every window is off the glass, resumes current on reveal" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setAudioDuration("cedar-ave.mp3", 89_160);
    // The headless harness models no windows of its own; create the one
    // whose glass the modeled occlusion covers and reveals.
    const window = try h.harness.runtime.createWindow(.{ .label = "glass", .title = "Audio", .source = platform.WebViewSource.html("<p>audio</p>") });
    const window_id = window.id;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeAudioLoaded().?);
    try std.testing.expect(np.audioSpectrum() != null);

    // Fully covered (no minimize verb involved): reports stop, while
    // playback and the position ticks keep flowing untouched — the
    // transport keeps telling the truth, only the display data pauses.
    try np.setWindowOccluded(window_id, true);
    try std.testing.expect(np.audioSpectrum() == null);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    var snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(@as(u64, 500), snapshot.position_ms);
    // The lifetime counter proves the occluded stretch delivered
    // nothing: an occluded journal simply has no spectrum records.
    try std.testing.expectEqual(@as(u64, 0), snapshot.spectrum_events);

    // Reveal: the very next beat has a report, and it describes NOW —
    // the position moved under the occlusion and the bands moved with
    // it, not a replay of the pre-occlusion frame.
    try np.setWindowOccluded(window_id, false);
    const revealed = np.audioSpectrum().?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, revealed);
    snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(@as(u64, 1), snapshot.spectrum_events);
    try std.testing.expectEqualSlices(u8, &revealed.audio.bands, snapshot.spectrum_bands);

    // The minimize verb is the same fact: a minimized-away app emits
    // no spectrum, and focus (the Dock-click restore) brings the
    // reports back with the window.
    try h.harness.runtime.minimizeWindow(window_id);
    try std.testing.expect(np.audioSpectrum() == null);
    try h.harness.runtime.focusWindow(window_id);
    try std.testing.expect(np.audioSpectrum() != null);
}

test "a host that cannot analyze reports audio_spectrum unsupported and never emits bands" {
    var h = try Harness.createConfigured(.{ .audio_spectrum = false });
    defer h.destroy();
    const np = &h.harness.null_platform;
    try std.testing.expect(!h.harness.runtime.supports(.audio_spectrum));
    try std.testing.expect(h.harness.runtime.supports(.audio_playback));
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeAudioLoaded().?);
    // Playback itself is untouched; only analysis is absent — and the
    // snapshot shows the honest zero instead of fabricated bands.
    try std.testing.expect(np.audioSpectrum() == null);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    const snapshot = h.harness.runtime.automationSnapshot("Audio").audio.?;
    try std.testing.expectEqual(@as(u64, 500), snapshot.position_ms);
    try std.testing.expectEqual(@as(u64, 0), snapshot.spectrum_events);
}

test "a platform without audio playback degrades to one failed event" {
    // Model a player-less host (a GTK host whose runtime-loaded
    // GStreamer is absent): the services are absent and the feature
    // reports false, so playback fails loudly through the Msg loop
    // instead of crashing or silently no-opping.
    var h = try Harness.createConfigured(.{ .audio_playback = false });
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Audio").audio == null);
}

test "a missing local file falls through to the url: stream now, cache next time" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;
    // Model the assets-absent machine: every local load answers
    // AudioSourceNotFound, exactly what sends the cascade to the URL.
    np.audio_local_files = false;
    try np.setAudioDuration("cedar-ave.mp3", 89_160);

    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url);
    // The local path was honestly tried (and missing) before the URL
    // resolved — resolution order is pinned, not assumed.
    try std.testing.expectEqual(@as(usize, 1), np.audio_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.audio_load_url_count);
    try std.testing.expectEqualStrings(track_url, np.audio.path());
    try std.testing.expectEqual(effects_mod.EffectAudioSource.stream, fx.audioSnapshot().source);
    // A fresh stream has no bytes yet: buffering starts true
    // optimistically, and the loaded acknowledgment clears it.
    try std.testing.expect(fx.audioSnapshot().buffering);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeAudioLoaded().?);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expect(!fx.audioSnapshot().buffering);

    // A mid-stream stall rides a position tick with buffering=true; the
    // Msg payload and the snapshot both report it, and the next healthy
    // tick clears it.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.stallAudio().?);
    try std.testing.expect(h.app_state.model.last_buffering);
    try std.testing.expect(fx.audioSnapshot().buffering);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(500).?);
    try std.testing.expect(!h.app_state.model.last_buffering);
    try std.testing.expect(!fx.audioSnapshot().buffering);

    // Completion installs the cache entry (the fake analog of the
    // host's verify-then-rename): the SECOND play of the same URL
    // resolves from cache — local playback, no buffering, no stream.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceAudio(89_160).?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url);
    try std.testing.expectEqual(@as(usize, 2), np.audio_load_url_count);
    try std.testing.expectEqual(effects_mod.EffectAudioSource.cache, fx.audioSnapshot().source);
    try std.testing.expect(!fx.audioSnapshot().buffering);
}

test "url-only playback skips the local probe entirely" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url_only);
    try std.testing.expectEqual(@as(usize, 0), np.audio_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.audio_load_url_count);
    try std.testing.expectEqual(effects_mod.EffectAudioSource.stream, fx.audioSnapshot().source);
}

test "a local decode failure never retries the url: masking the real problem helps nobody" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    // An oversized path is the one synchronous local failure the fake
    // can produce that is NOT AudioSourceNotFound... a present file
    // that fails decode is terminal. The fake models source-missing
    // only, so pin the complement: with local files PRESENT the url is
    // never consulted.
    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url);
    try std.testing.expectEqual(@as(usize, 1), np.audio_load_count);
    try std.testing.expectEqual(@as(usize, 0), np.audio_load_url_count);
    try std.testing.expectEqual(effects_mod.EffectAudioSource.local, h.app_state.effects.audioSnapshot().source);
}

test "a host with a player but no streaming path degrades url playback to one failed msg" {
    var h = try Harness.createConfigured(.{ .audio_streaming = false });
    defer h.destroy();
    h.harness.null_platform.audio_local_files = false;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(track_key, h.app_state.model.last_key);
}

test "a missing local file with no url is still the original failed degrade" {
    var h = try Harness.create();
    defer h.destroy();
    h.harness.null_platform.audio_local_files = false;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioEventKind.failed, h.app_state.model.last_kind.?);
}

test "fake executor records the whole url request shape" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .play_url);
    const request = fx.pendingAudio().?;
    try std.testing.expectEqualStrings(track_path, request.path);
    try std.testing.expectEqualStrings(track_url, request.url);
    try std.testing.expectEqualStrings(track_cache_path, request.cache_path);
    try std.testing.expectEqual(track_bytes, request.expected_bytes);
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.audio_load_url_count);
}

test "audioCachePath keys by url hash under audio/ and keeps the extension" {
    var buffer: [512]u8 = undefined;
    const first = try effects_mod.audioCachePath(&buffer, "/tmp/caches/app", track_url);
    try std.testing.expect(std.mem.startsWith(u8, first, "/tmp/caches/app/audio/"));
    try std.testing.expect(std.mem.endsWith(u8, first, ".mp3"));

    // Same url, same path — the cache is content-addressed by source.
    var second_buffer: [512]u8 = undefined;
    const second = try effects_mod.audioCachePath(&second_buffer, "/tmp/caches/app", track_url);
    try std.testing.expectEqualStrings(first, second);

    // Different url, different path.
    var third_buffer: [512]u8 = undefined;
    const third = try effects_mod.audioCachePath(&third_buffer, "/tmp/caches/app", "https://music.example.test/pack/music/exit-signs/harvest-lot.mp3");
    try std.testing.expect(!std.mem.eql(u8, first, third));

    // URL machinery never smuggles into the file name: a query-string
    // "extension" is dropped, not embedded.
    var fourth_buffer: [512]u8 = undefined;
    const fourth = try effectsCachePathNoExt(&fourth_buffer);
    try std.testing.expect(std.mem.indexOfAny(u8, std.fs.path.basename(fourth), "?#&") == null);
}

fn effectsCachePathNoExt(buffer: []u8) ![]const u8 {
    return effects_mod.audioCachePath(buffer, "/tmp/caches/app", "https://music.example.test/stream?id=42");
}

test "quit while playing: the stop hook silences audio on the live platform, and app deinit after platform teardown answers inert" {
    // The desktop runner's exit ordering, replayed exactly: main defers
    // app deinit FIRST and calls the runner, whose own defers destroy
    // the platform host and free the runtime — so on quit the platform
    // dies BEFORE the app's deinit runs. The runtime therefore delivers
    // the app's stop hook before its loop returns; the hook must stop a
    // live playback through the still-alive services and sever the
    // effects channel's binding, so the late deinit never reaches into
    // freed platform memory (the quit-while-audio-plays crash this
    // pins: deinit used to call audioStop through the dead host).
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(AudioApp);
    errdefer std.testing.allocator.destroy(app_state);
    app_state.* = AudioApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-audio-quit",
        .scene = audio_scene,
        .canvas_label = canvas_label,
        .update_fx = audioUpdate,
        .view = audioView,
    });
    errdefer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // A track is playing on the platform's player when the quit lands.
    try app_state.dispatch(&harness.runtime, 1, .play);
    try std.testing.expect(app_state.effects.audioSnapshot().active);
    try std.testing.expect(harness.null_platform.audio.playing);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.audio_stop_count);

    // The platform loop's final event: app_shutdown delivers the stop
    // hook. It silences the player through the LIVE services and severs
    // the channel's binding.
    try harness.stop(app);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.audio_stop_count);
    try std.testing.expect(!harness.null_platform.audio.loaded);
    try std.testing.expect(app_state.effects.services == null);
    try std.testing.expect(!app_state.effects.audioSnapshot().active);

    // The runner's defers: platform host and runtime memory are gone
    // now. (The harness allocation holds both; freeing it makes any
    // late service call a real use-after-free, exactly like main.)
    harness.destroy(std.testing.allocator);

    // Main's deferred deinit runs last. It must free app-side memory
    // only — no audioStop, no timer cancels, no worker wakes against
    // the dead platform.
    app_state.deinit();
    std.testing.allocator.destroy(app_state);
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
