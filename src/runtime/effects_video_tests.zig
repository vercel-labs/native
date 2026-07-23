//! Video-effect coverage: `fx.loadVideo` and the transport commands
//! (`playVideo`/`pauseVideo`/`stopVideo`/`seekVideo`/`setVideoVolume`/
//! `setVideoMuted`/`setVideoLoop`) through the fake executor
//! (deterministic request/feed round trips, rejection classes) and the
//! real executor against the null platform's fake player — the same
//! `PlatformServices` seam AVFoundation serves on macOS. One channel,
//! key-identified events, the media-surface claim released on
//! stop/replace/failure, decoded frames reaching the surface through
//! the platform sink, and a recorded session replaying byte-identical
//! with no producer and no player behind it.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");
const journal = @import("session_journal.zig");

const canvas_label = "video-canvas";

const video_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const video_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Video",
    .width = 400,
    .height = 300,
    .views = &video_views,
}};
const video_scene: app_manifest.ShellConfig = .{ .windows = &video_windows };

const VideoModel = struct {
    event_count: usize = 0,
    chain_next: bool = false,
    probed_active: ?bool = null,
    last_kind: ?effects_mod.EffectVideoEventKind = null,
    last_key: u64 = 0,
    last_position_ms: u64 = 0,
    last_duration_ms: u64 = 0,
    last_playing: bool = false,
    last_buffering: bool = false,
    last_width: u64 = 0,
    last_height: u64 = 0,
    completed_count: usize = 0,

    fn record(model: *VideoModel, event: effects_mod.EffectVideo) void {
        model.event_count += 1;
        model.last_kind = event.kind;
        model.last_key = event.key;
        model.last_position_ms = event.position_ms;
        model.last_duration_ms = event.duration_ms;
        model.last_playing = event.playing;
        model.last_buffering = event.buffering;
        if (event.width > 0) model.last_width = event.width;
        if (event.height > 0) model.last_height = event.height;
        if (event.kind == .completed) model.completed_count += 1;
    }
};

const VideoMsg = union(enum) {
    load,
    arm_chain,
    load_url,
    load_url_only,
    load_no_source,
    load_rejected_burst,
    load_zero_surface,
    load_reserved_surface,
    load_bad_scheme,
    load_paused,
    load_url_paused,
    load_looping,
    load_then_stop,
    load_then_stream,
    load_then_probe,
    play_then_probe,
    load_source_burst,
    play,
    pause,
    stop,
    seek_half,
    quiet,
    mute_on,
    loop_on,
    video_event: effects_mod.EffectVideo,
};

const VideoApp = ui_app_model.UiApp(VideoModel, VideoMsg);
const VideoEffects = VideoApp.Effects;

const clip_key: u64 = 61;
const clip_surface: u64 = 907;
/// Past the shared pending ring's capacity (32), so a burst proves the
/// video stage never evicts a promised terminal.
const rejected_burst_count: usize = 40;
const clip_path = "assets/clips/orchard-flyover.mp4";
const clip_url = "https://media.example.test/clips/orchard-flyover.mp4";

fn videoUpdate(model: *VideoModel, msg: VideoMsg, fx: *VideoEffects) void {
    switch (msg) {
        .load => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .arm_chain => model.chain_next = true,
        // The full cascade shape: local path first, url fallback.
        .load_url => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .url = clip_url,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        // URL-only: no local probe at all.
        .load_url_only => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .url = clip_url,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_no_source => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        // One dispatch, more refusals than the shared pending ring
        // holds: every `.rejected` terminal is a load call's only
        // answer and must survive to the next drain (the non-lossy
        // video stage's contract).
        .load_rejected_burst => for (0..rejected_burst_count) |_| fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_zero_surface => fx.loadVideo(.{
            .key = clip_key,
            .surface = 0,
            .path = clip_path,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_reserved_surface => fx.loadVideo(.{
            .key = clip_key,
            .surface = @import("canvas").media_surface_image_id_bit | 7,
            .path = clip_path,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_bad_scheme => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .url = "file:///etc/passwd",
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_paused => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .autoplay = false,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_url_paused => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .url = clip_url,
            .autoplay = false,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .load_looping => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .loop = true,
            .muted = true,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        // The batch shape: one dispatch loads and immediately stops.
        // On an assets-absent host the load's synchronous `.failed` is
        // staged before the stop runs — the terminal outlives the
        // playback it reports on.
        .load_then_stop => {
            fx.loadVideo(.{
                .key = clip_key,
                .surface = clip_surface,
                .path = clip_path,
                .on_event = VideoEffects.videoMsg(.video_event),
            });
            fx.stopVideo();
        },
        // The snapshot probe: an update that inspects the channel
        // right after its own load. A synchronous refusal resets the
        // channel before loadVideo returns, and the probe must read
        // the same answer live and replayed.
        .load_then_probe => {
            fx.loadVideo(.{
                .key = clip_key,
                .surface = clip_surface,
                .path = clip_path,
                .on_event = VideoEffects.videoMsg(.video_event),
            });
            model.probed_active = fx.videoSnapshot().active;
        },
        // The post-completion resume probe: play against a retired
        // player resets the channel before playVideo returns, and the
        // probe must read the same answer live and replayed.
        .play_then_probe => {
            fx.playVideo();
            model.probed_active = fx.videoSnapshot().active;
        },
        // The replace shape under the same app key: the first load's
        // synchronous `.failed` must keep its own identity while the
        // replacing stream plays on — the key alone cannot tell the
        // two loads apart.
        .load_then_stream => {
            fx.loadVideo(.{
                .key = clip_key,
                .surface = clip_surface,
                .path = clip_path,
                .on_event = VideoEffects.videoMsg(.video_event),
            });
            fx.loadVideo(.{
                .key = clip_key,
                .surface = clip_surface,
                .url = clip_url,
                .on_event = VideoEffects.videoMsg(.video_event),
            });
        },
        // One dispatch, more resolved loads than the replay-side
        // cascade-resolution queue holds inline: loads per dispatch are
        // unbounded by contract, so every recorded resolution must
        // survive to its replayed load.
        .load_source_burst => for (0..effects_mod.max_effect_replay_video_source_entries + 1) |_| fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .url = clip_url,
            .autoplay = false,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .play => fx.playVideo(),
        .pause => fx.pauseVideo(),
        .stop => fx.stopVideo(),
        .seek_half => fx.seekVideo(45_000),
        .quiet => fx.setVideoVolume(0.25),
        .mute_on => fx.setVideoMuted(true),
        .loop_on => fx.setVideoLoop(true),
        .video_event => |event| {
            model.record(event);
            // The playlist shape: the completion handler starts the
            // next clip from inside its own dispatch.
            if (model.chain_next and event.kind == .completed) {
                model.chain_next = false;
                fx.loadVideo(.{
                    .key = clip_key + 1,
                    .surface = clip_surface,
                    .path = clip_path,
                    .on_event = VideoEffects.videoMsg(.video_event),
                });
            }
        },
    }
}

fn videoCommand(name: []const u8) ?VideoMsg {
    if (std.mem.eql(u8, name, "video.load")) return .load;
    if (std.mem.eql(u8, name, "video.arm-chain")) return .arm_chain;
    if (std.mem.eql(u8, name, "video.load-url")) return .load_url;
    if (std.mem.eql(u8, name, "video.load-then-stop")) return .load_then_stop;
    if (std.mem.eql(u8, name, "video.load-then-probe")) return .load_then_probe;
    if (std.mem.eql(u8, name, "video.play-then-probe")) return .play_then_probe;
    if (std.mem.eql(u8, name, "video.load-then-stream")) return .load_then_stream;
    if (std.mem.eql(u8, name, "video.load-source-burst")) return .load_source_burst;
    if (std.mem.eql(u8, name, "video.seek-half")) return .seek_half;
    if (std.mem.eql(u8, name, "video.load-zero-surface")) return .load_zero_surface;
    return null;
}

fn videoView(ui: *VideoApp.Ui, model: *const VideoModel) VideoApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} events", .{model.event_count})),
        ui.mediaSurface(.{ .image = clip_surface, .width = 128, .height = 72 }),
        ui.button(.{ .on_press = .load }, "Load"),
        ui.button(.{ .on_press = .pause }, "Pause"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *VideoApp,
    app: core.App,

    const Config = struct {
        /// false models a staged host without a video decoder (Windows/
        /// Linux today): the services are nulled BEFORE the platform
        /// value is captured, the same shape the real hosts wire.
        video_playback: bool = true,
        /// false models the assets-absent machine: every local load
        /// answers VideoSourceNotFound, sending the cascade to the URL.
        video_local_files: bool = true,
    };

    fn create() !Harness {
        return createConfigured(.{});
    }

    fn createConfigured(config: Config) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = config.video_playback;
        harness.null_platform.video_local_files = config.video_local_files;
        // The harness snapshots the services at create; re-capture so
        // the toggles above null the service fns the runtime hands the
        // effects channel — the same wiring a real decoder-less host
        // ships.
        harness.runtime.options.platform = harness.null_platform.platform();
        const app_state = try std.testing.allocator.create(VideoApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
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

fn dispatchFrame(harness: *core.TestHarness(), app: core.App, frame_index: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

/// A tiny solid RGBA8 frame (2x2) in one color.
fn solidFrame(rgba: [4]u8) [16]u8 {
    var frame: [16]u8 = undefined;
    inline for (0..4) |pixel| @memcpy(frame[pixel * 4 .. pixel * 4 + 4], &rgba);
    return frame;
}

// ------------------------------------------------------------ fake executor

test "fake executor records the load request and feeds events back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Load: the request is recorded whole, not executed — nothing
    // touches the platform player and no surface claim is taken.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    const request = fx.pendingVideo().?;
    try std.testing.expectEqual(clip_key, request.key);
    try std.testing.expectEqual(clip_surface, request.surface);
    try std.testing.expectEqualStrings(clip_path, request.path);
    try std.testing.expect(request.playing);
    try std.testing.expect(!request.looping);
    try std.testing.expect(!request.muted);
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.video_load_count);

    // The loaded acknowledgment carries the real dimensions and
    // duration into update.
    try fx.feedVideoEvent(.loaded, 0, 92_500, true, false, 1280, 720);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(clip_key, h.app_state.model.last_key);
    try std.testing.expectEqual(@as(u64, 92_500), h.app_state.model.last_duration_ms);
    try std.testing.expectEqual(@as(u64, 1280), h.app_state.model.last_width);
    try std.testing.expectEqual(@as(u64, 720), h.app_state.model.last_height);

    // Position ticks advance the mirrors the snapshot reports.
    try fx.feedVideoEvent(.position, 1_500, 92_500, true, false, 0, 0);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 1_500), h.app_state.model.last_position_ms);
    try std.testing.expect(h.app_state.model.last_playing);
    try std.testing.expectEqual(@as(u64, 1_500), fx.videoSnapshot().position_ms);
    // The dimension mirrors persist from the loaded acknowledgment.
    try std.testing.expectEqual(@as(u64, 1280), fx.videoSnapshot().width);

    // Completion fires once, pinned to the duration, playback stopped.
    try fx.feedVideoEvent(.completed, 92_500, 92_500, false, false, 0, 0);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expectEqual(@as(u64, 92_500), h.app_state.model.last_position_ms);
    try std.testing.expect(!h.app_state.model.last_playing);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expect(!fx.videoSnapshot().playing);
}

test "fake transport commands move the mirrors without a platform" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try fx.feedVideoEvent(.loaded, 0, 90_000, true, false, 640, 360);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);

    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expect(!fx.videoSnapshot().playing);
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try std.testing.expect(fx.videoSnapshot().playing);
    try h.app_state.dispatch(&h.harness.runtime, 1, .seek_half);
    try std.testing.expectEqual(@as(u64, 45_000), fx.videoSnapshot().position_ms);
    try h.app_state.dispatch(&h.harness.runtime, 1, .quiet);
    try std.testing.expectEqual(@as(f32, 0.25), fx.videoSnapshot().volume);
    try h.app_state.dispatch(&h.harness.runtime, 1, .mute_on);
    try std.testing.expect(fx.videoSnapshot().muted);
    try h.app_state.dispatch(&h.harness.runtime, 1, .loop_on);
    try std.testing.expect(fx.videoSnapshot().looping);

    // Stop clears the channel; late feeds report EffectNotFound.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expect(fx.pendingVideo() == null);
    try std.testing.expect(!fx.videoSnapshot().active);
    try std.testing.expectError(error.EffectNotFound, fx.feedVideoEvent(.position, 46_000, 90_000, true, false, 0, 0));
}

test "load requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    const rejects = [_]VideoMsg{ .load_no_source, .load_zero_surface, .load_reserved_surface, .load_bad_scheme };
    for (rejects, 1..) |msg, expected| {
        try h.app_state.dispatch(&h.harness.runtime, 1, msg);
        try h.drainWakes();
        try std.testing.expectEqual(expected, h.app_state.model.event_count);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.rejected, h.app_state.model.last_kind.?);
        try std.testing.expectEqual(clip_key, h.app_state.model.last_key);
        try std.testing.expect(fx.pendingVideo() == null);
    }
}

test "a rejection burst past the pending ring's capacity delivers every terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // One update issues more refused loads than the shared pending
    // ring holds. Each `.rejected` is that call's ONLY terminal —
    // none may be evicted on the way to the drain.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load_rejected_burst);
    var drains: usize = 0;
    while (h.app_state.model.event_count < rejected_burst_count) : (drains += 1) {
        if (drains > rejected_burst_count) break;
        try h.drainWakes();
        try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    }
    try std.testing.expectEqual(rejected_burst_count, h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.rejected, h.app_state.model.last_kind.?);
    try std.testing.expect(fx.pendingVideo() == null);
}

// ------------------------------------------------------------ real executor

test "real executor drives the platform player and events round-trip" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

    // Load claims the surface, loads the platform's single player, and
    // autoplay starts it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.video_play_count);
    try std.testing.expectEqualStrings(clip_path, np.video.path());
    try std.testing.expect(np.video.playing);

    // The loaded acknowledgment arrives as a platform event, exactly as
    // a live host would deliver it after the load call returned.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 92_500), h.app_state.model.last_duration_ms);
    try std.testing.expectEqual(@as(u64, 1280), h.app_state.model.last_width);
    try std.testing.expectEqual(@as(u64, 720), h.app_state.model.last_height);

    // Position ticks advance on the test's explicit clock, never on
    // their own.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(500).?);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(500).?);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 1_000), h.app_state.model.last_position_ms);

    // The automation snapshot reports playback honestly.
    const playing_snapshot = h.harness.runtime.automationSnapshot("Video").video.?;
    try std.testing.expectEqual(clip_key, playing_snapshot.key);
    try std.testing.expectEqual(clip_surface, playing_snapshot.surface);
    try std.testing.expect(playing_snapshot.playing);
    try std.testing.expectEqual(@as(u64, 1_000), playing_snapshot.position_ms);
    try std.testing.expectEqual(@as(u64, 92_500), playing_snapshot.duration_ms);
    try std.testing.expectEqual(@as(u64, 1280), playing_snapshot.width);
    try std.testing.expectEqual(@as(u64, 720), playing_snapshot.height);

    // Pause freezes the platform player; ticks stop with it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expectEqual(@as(usize, 1), np.video_pause_count);
    try std.testing.expect(np.advanceVideo(500) == null);
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);

    // Seek moves the platform position; mute and loop reach the player.
    try h.app_state.dispatch(&h.harness.runtime, 1, .seek_half);
    try std.testing.expectEqual(@as(u64, 45_000), np.video.position_ms);
    try h.app_state.dispatch(&h.harness.runtime, 1, .mute_on);
    try std.testing.expect(np.video.muted);
    try h.app_state.dispatch(&h.harness.runtime, 1, .quiet);
    try std.testing.expectEqual(@as(f32, 0.25), np.video.volume);

    // Advancing past the end delivers the one completion, and the
    // platform player retires with it (retire-before-emit, the live
    // hosts' teardown order) — not merely paused.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(60_000).?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expectEqual(@as(u64, 92_500), h.app_state.model.last_position_ms);
    try std.testing.expect(!h.app_state.model.last_playing);
    try std.testing.expect(!np.video.loaded);
    try std.testing.expect(np.advanceVideo(500) == null);

    // Stop unloads; the snapshot goes honestly idle (null, not zeros).
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expectEqual(@as(usize, 1), np.video_stop_count);
    try std.testing.expect(!np.video.loaded);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Video").video == null);
}

test "a looping playback wraps at the end and never completes" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 10_000, 640, 360);

    try h.app_state.dispatch(&h.harness.runtime, 1, .load_looping);
    // The load options reached the platform player.
    try std.testing.expect(np.video.looping);
    try std.testing.expect(np.video.muted);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);

    // Advancing past the end wraps: a position tick, still playing,
    // and no completion — a looping video never ends.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(10_500).?);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u64, 500), h.app_state.model.last_position_ms);
    try std.testing.expect(h.app_state.model.last_playing);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.completed_count);
}

test "transport after a non-looping completion refuses like a live host" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 10_000, 640, 360);

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);

    // The natural end retires the platform player before the completion
    // emits, so every later transport call meets the same absent player
    // a live host has after its teardown.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(10_500).?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expect(!np.video.loaded);

    // Seek and pause against the retired player: refused on the
    // platform side (the calls still arrive), position untouched — and
    // the CHANNEL mirror stays at the completion's terminal position
    // too: a refused seek must not scrub the snapshot and the house
    // slider away from the frame actually on the glass.
    try h.app_state.dispatch(&h.harness.runtime, 1, .seek_half);
    try std.testing.expectEqual(@as(usize, 1), np.video_seek_count);
    try std.testing.expectEqual(@as(u64, 0), np.video.position_ms);
    try std.testing.expectEqual(@as(u64, 10_000), h.app_state.effects.videoSnapshot().position_ms);
    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expect(np.advanceVideo(500) == null);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);

    // Play cannot restart a retired player: the platform refuses and
    // the channel degrades to one `.failed` event — the resume path is
    // a fresh load, on every backend.
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(clip_key, h.app_state.model.last_key);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Video").video == null);
}

test "decoded frames reach the claimed surface through the platform sink" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);

    // The platform's decode callback pushes one frame through the sink
    // the load handed over; the compositor's next frame adopts it.
    const teal = solidFrame(.{ 0, 128, 128, 255 });
    try np.pushVideoFrame(2, 2, &teal);
    try dispatchFrame(h.harness, h.app, 2);
    const adopted = h.harness.runtime.adoptedMediaSurfaceTexture(clip_surface).?;
    try std.testing.expectEqual(@as(usize, 2), adopted.width);
    try std.testing.expectEqual(@as(usize, 2), adopted.height);

    // Stop releases the claim. A decode thread still holding the sink
    // (the platform unloads asynchronously) pushes into inert
    // process-lived memory and hears the released claim — while the
    // runtime keeps the last adopted frame (a stopped player keeps its
    // final picture until another producer claims the surface).
    const stale_sink = np.video.sink;
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    const late = solidFrame(.{ 9, 9, 9, 255 });
    try std.testing.expectError(error.MediaSurfaceReleased, stale_sink.push(2, 2, &late));
    try std.testing.expect(h.harness.runtime.adoptedMediaSurfaceTexture(clip_surface) != null);
}

test "a new load replaces the playback whole: player, claim, and key" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    const first_sink_push = solidFrame(.{ 1, 2, 3, 255 });
    try np.pushVideoFrame(2, 2, &first_sink_push);

    // The second load must re-claim the SAME surface — impossible
    // unless the first claim was released — and stop the first
    // platform playback on the way.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load_paused);
    try std.testing.expectEqual(@as(usize, 1), np.video_stop_count);
    try std.testing.expectEqual(@as(usize, 2), np.video_load_count);
    try std.testing.expect(!np.video.playing);
    // The replacement's sink is live; frames flow to the same surface.
    const second_sink_push = solidFrame(.{ 4, 5, 6, 255 });
    try np.pushVideoFrame(2, 2, &second_sink_push);
    // autoplay=false: the load left the player paused; play starts it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .play);
    try std.testing.expect(np.video.playing);
}

test "a surface another producer holds fails the load loudly" {
    var h = try Harness.create();
    defer h.destroy();

    const holder = try h.harness.runtime.acquireMediaSurfaceProducer(clip_surface);
    defer holder.release();

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(clip_key, h.app_state.model.last_key);
    // The platform player was never asked: the claim failed first.
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.video_load_count);
}

test "a platform without video playback degrades to one failed event" {
    // Model a staged host (Windows/Linux today): the services are
    // absent and the feature reports false, so playback fails loudly
    // through the Msg loop instead of crashing or silently no-opping.
    var h = try Harness.createConfigured(.{ .video_playback = false });
    defer h.destroy();
    try std.testing.expect(!h.harness.runtime.supports(.video_playback));

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(clip_key, h.app_state.model.last_key);
    try std.testing.expect(h.harness.runtime.automationSnapshot("Video").video == null);
}

test "a missing local file falls through to the url and streams" {
    var h = try Harness.createConfigured(.{ .video_local_files = false });
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;
    try np.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

    try h.app_state.dispatch(&h.harness.runtime, 1, .load_url);
    // The local path was honestly tried (and missing) before the URL
    // resolved — resolution order is pinned, not assumed.
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_url_count);
    try std.testing.expectEqualStrings(clip_url, np.video.path());
    try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, fx.videoSnapshot().source);
    // A fresh stream has no bytes yet: buffering starts true
    // optimistically, and the loaded acknowledgment clears it.
    try std.testing.expect(fx.videoSnapshot().buffering);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.loaded, h.app_state.model.last_kind.?);
    try std.testing.expect(!fx.videoSnapshot().buffering);

    // A mid-stream stall rides a position tick with buffering=true; the
    // Msg payload and the snapshot both report it, and the next healthy
    // tick clears it.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.stallVideo().?);
    try std.testing.expect(h.app_state.model.last_buffering);
    try std.testing.expect(fx.videoSnapshot().buffering);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(500).?);
    try std.testing.expect(!h.app_state.model.last_buffering);
    try std.testing.expect(!fx.videoSnapshot().buffering);
}

test "url-only playback skips the local probe entirely" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .load_url_only);
    try std.testing.expectEqual(@as(usize, 0), np.video_load_count);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_url_count);
    try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, h.app_state.effects.videoSnapshot().source);
}

test "a platform straggler after stop is swallowed, never misattributed" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    const loaded = np.takeVideoLoaded().?;
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    // The loaded event from before the stop arrives late: no Msg, no
    // model change.
    const before = h.app_state.model.event_count;
    try h.harness.runtime.dispatchPlatformEvent(h.app, loaded);
    try std.testing.expectEqual(before, h.app_state.model.event_count);
}

test "a replaced playback's queued terminal never resets the replacement" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

    // Playback A dies — but its `.failed` event is still queued when
    // the update replaces it with playback B (same source, fresh
    // load): the single player's classic straggler race.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    const stale_failed = np.failVideo().?;
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    const events_before = h.app_state.model.event_count;

    // A's stale terminal arrives: the load token names A, so the
    // channel swallows it — no Msg, no reset, B keeps its claim and
    // its mirrors.
    try h.harness.runtime.dispatchPlatformEvent(h.app, stale_failed);
    try std.testing.expectEqual(events_before, h.app_state.model.event_count);
    const fx = &h.app_state.effects;
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expect(fx.videoSnapshot().playing);
    try std.testing.expectEqual(@as(u64, 92_500), fx.videoSnapshot().duration_ms);
}

test "a paused fresh stream is paused, not buffering; pause ends a stall's wait" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // A stream loaded with autoplay=false: buffering means an
    // un-paused stream waiting for bytes, and a paused load is not
    // waiting for anything — play() is what starts the wait.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load_url_paused);
    try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, fx.videoSnapshot().source);
    try std.testing.expect(!fx.videoSnapshot().playing);
    try std.testing.expect(!fx.videoSnapshot().buffering);

    // An autoplaying stream starts its wait immediately: buffering
    // optimistic until the platform's events take over.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load_url_only);
    try std.testing.expect(fx.videoSnapshot().playing);
    try std.testing.expect(fx.videoSnapshot().buffering);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);

    // Mid-stream stall, then pause: the pause ends the wait by
    // definition, and no conforming host emits a pause acknowledgment
    // to clear the flag - the command mirror does it.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.stallVideo().?);
    try std.testing.expect(fx.videoSnapshot().buffering);
    try h.app_state.dispatch(&h.harness.runtime, 1, .pause);
    try std.testing.expect(!fx.videoSnapshot().playing);
    try std.testing.expect(!fx.videoSnapshot().buffering);
}

test "a looping advance past u64 wraps to the exact residue" {
    var h = try Harness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

    try h.app_state.dispatch(&h.harness.runtime, 1, .load_looping);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(500).?);

    // A hostile or fuzzing delta past u64 must wrap on the true sum,
    // not on a saturated one - the modulo runs in wider arithmetic.
    const huge = std.math.maxInt(u64);
    const expected: u64 = @intCast((@as(u128, 500) + huge) % 92_500);
    const wrapped = np.advanceVideo(huge).?;
    try std.testing.expectEqual(expected, wrapped.video.position_ms);
    try std.testing.expect(wrapped.video.playing);
}

test "quit while playing: the stop hook silences video and releases the claim through the live platform" {
    // The desktop runner's exit ordering, the audio quit test's twin:
    // the platform dies BEFORE the app's deferred deinit runs, so the
    // stop hook must stop playback and release the surface claim
    // through the still-alive services, and the late deinit must
    // answer inert.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(VideoApp);
    errdefer std.testing.allocator.destroy(app_state);
    app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-video-quit",
        .scene = video_scene,
        .canvas_label = canvas_label,
        .update_fx = videoUpdate,
        .view = videoView,
    });
    errdefer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try app_state.dispatch(&harness.runtime, 1, .load);
    try std.testing.expect(app_state.effects.videoSnapshot().active);
    try std.testing.expect(harness.null_platform.video.playing);

    try harness.stop(app);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.video_stop_count);
    try std.testing.expect(!harness.null_platform.video.loaded);
    try std.testing.expect(app_state.effects.services == null);
    try std.testing.expect(!app_state.effects.videoSnapshot().active);
    // The claim went with the stop: the surface is claimable again.
    const reclaim = try harness.runtime.acquireMediaSurfaceProducer(clip_surface);
    reclaim.release();

    harness.destroy(std.testing.allocator);
    app_state.deinit();
    std.testing.allocator.destroy(app_state);
}

// ------------------------------------------- declarative <video> element

const canvas = @import("canvas");

const DeclModel = struct {
    show: bool = true,
    second: bool = false,
    malformed: bool = false,
    muted: bool = false,
    loop: bool = false,
};

const DeclMsg = union(enum) { toggle_show, use_second, use_malformed, toggle_muted, toggle_loop, hijack_key, noop };

const DeclApp = ui_app_model.UiApp(DeclModel, DeclMsg);
const DeclEffects = DeclApp.Effects;

fn declUpdate(model: *DeclModel, msg: DeclMsg, fx: *DeclEffects) void {
    switch (msg) {
        // A manual load deliberately carrying the reconciler's derived
        // key for "assets/clips/one.mp4": the key is a pure function of
        // the source string, so a collision is expressible — ownership
        // must ride the load token.
        .hijack_key => fx.loadVideo(.{
            .key = std.hash.Wyhash.hash(0x76696465, "assets/clips/one.mp4") | 1,
            .surface = canvas.video_playback_surface_id,
            .path = "assets/clips/one.mp4",
        }),
        .toggle_show => model.show = !model.show,
        .use_second => model.second = true,
        .use_malformed => model.malformed = true,
        .toggle_muted => model.muted = !model.muted,
        .toggle_loop => model.loop = !model.loop,
        .noop => {},
    }
}

/// `declView` without the video element: the recording twin for the
/// zero-record divergence pin below — a session recorded with this
/// view journals NO effect records at all.
fn declViewNone(ui: *DeclApp.Ui, model: *const DeclModel) DeclApp.Ui.Node {
    _ = model;
    return ui.column(.{ .padding = 8 }, .{ui.text(.{}, "no video")});
}

/// A view declaring the playback through `ui.video` (what `<video
/// src=... controls/>` lowers to in both markup engines): presence IS
/// playback, and the transport chrome is runtime-consumed.
fn declView(ui: *DeclApp.Ui, model: *const DeclModel) DeclApp.Ui.Node {
    if (!model.show) {
        return ui.column(.{ .padding = 8 }, .{ui.text(.{}, "no video")});
    }
    return ui.column(.{ .padding = 8 }, .{
        ui.video(.{
            // The malformed arm is a URL the video loader's scheme
            // gate refuses (`std.Uri.parse` fails on it).
            .src = if (model.malformed) "https://[" else if (model.second) "assets/clips/two.mp4" else "assets/clips/one.mp4",
            .controls = true,
            .muted = model.muted,
            .loop = model.loop,
            .width = 320,
            .height = 220,
            .label = "Clip",
        }),
    });
}

const DeclHarness = struct {
    harness: *core.TestHarness(),
    app_state: *DeclApp,
    app: core.App,

    fn create() !DeclHarness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        try harness.null_platform.setVideoMeta("one.mp4", 90_000, 640, 360);
        try harness.null_platform.setVideoMeta("two.mp4", 60_000, 640, 360);
        const app_state = try std.testing.allocator.create(DeclApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = DeclApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video-decl",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = declUpdate,
            .view = declView,
        });
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try std.testing.expect(app_state.installed);
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *DeclHarness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    /// The laid-out frame of the first chrome control carrying `verb`,
    /// straight from the runtime's retained layout.
    fn controlFrame(self: *DeclHarness, verb: canvas.VideoControlVerb) !geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.video_control == verb) return node.frame.normalized();
        }
        return error.TestUnexpectedResult;
    }

    fn clickAt(self: *DeclHarness, x: f32, y: f32) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_down,
            .x = x,
            .y = y,
        } });
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_up,
            .x = x,
            .y = y,
        } });
    }
};

test "a declared <video src> loads on first rebuild, reloads on src change, and stops on removal" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // The installing rebuild reconciled the declaration into the
    // channel: one load of the declared path onto the framework-owned
    // playback surface, autoplay honored. The captured declaration is
    // COPIED out of the build arena (a later failed rebuild resets the
    // arena; the reconcile can run from a window close before the next
    // success), so its src must alias the app-owned buffer.
    try std.testing.expectEqual(
        @intFromPtr(&h.app_state.video_build_src_buffer),
        @intFromPtr(h.app_state.video_build_declaration.?.src.ptr),
    );
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);
    try std.testing.expectEqualStrings("assets/clips/one.mp4", np.video.path());
    try std.testing.expect(np.video.playing);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expectEqual(canvas.video_playback_surface_id, fx.videoSnapshot().surface);

    // A rebuild with the unchanged declaration never reloads — an
    // unchanged src must not restart the playback.
    try h.app_state.dispatch(&h.harness.runtime, 1, .noop);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);

    // Same-src flag deltas apply in place AND republish the runtime
    // mirror in the same reconcile: an automation snapshot taken right
    // after the flip must already report the new value.
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_muted);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);
    try std.testing.expect(np.video.muted);
    try std.testing.expect(fx.videoSnapshot().muted);
    try std.testing.expect(h.harness.runtime.video_muted);
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_loop);
    try std.testing.expect(np.video.looping);
    try std.testing.expect(h.harness.runtime.video_looping);
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_muted);
    try std.testing.expect(!h.harness.runtime.video_muted);

    // A changed src replaces the playback whole (loadVideo's replace
    // semantics: the first playback stops on the way).
    try h.app_state.dispatch(&h.harness.runtime, 1, .use_second);
    try std.testing.expectEqual(@as(usize, 2), np.video_load_count);
    try std.testing.expectEqualStrings("assets/clips/two.mp4", np.video.path());
    try std.testing.expectEqual(@as(usize, 1), np.video_stop_count);

    // The element leaving the view ends the playback: declarative
    // ownership stops what it declared.
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_show);
    try std.testing.expectEqual(@as(usize, 2), np.video_stop_count);
    try std.testing.expect(!np.video.loaded);
    try std.testing.expect(!fx.videoSnapshot().active);

    // Redeclaring it loads afresh.
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_show);
    try std.testing.expectEqual(@as(usize, 3), np.video_load_count);
    try std.testing.expect(np.video.loaded);
}

test "the reconciler never stops a manual playback sharing its derived key" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // An update replaces the declared playback with its OWN load that
    // happens to carry the reconciler's derived key. Ownership is the
    // load token, not the key: removing the declaration must leave the
    // manual playback running.
    try h.app_state.dispatch(&h.harness.runtime, 1, .hijack_key);
    try std.testing.expect(fx.videoSnapshot().active);
    const stops_before = np.video_stop_count;
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_show);
    try std.testing.expectEqual(stops_before, np.video_stop_count);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expect(np.video.loaded);
}

test "a refused declaration never takes ownership from the playback still running" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // A is playing from the installing rebuild's declaration.
    try std.testing.expect(np.video.playing);
    try std.testing.expectEqualStrings("assets/clips/one.mp4", np.video.path());

    // The declaration changes to a source the loader's own gates
    // refuse: the reconciler must not commit it — A keeps playing and
    // remains the tracked owner.
    try h.app_state.dispatch(&h.harness.runtime, 1, .use_malformed);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expectEqualStrings("assets/clips/one.mp4", np.video.path());
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);

    // Removing the element stops the playback the reconciler actually
    // owns — a committed refused src would hash the wrong key here and
    // leave A running forever.
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_show);
    try std.testing.expect(!np.video.loaded);
    try std.testing.expect(!fx.videoSnapshot().active);
}

test "the house chrome toggle pauses and resumes the platform player without an app Msg" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // The loaded acknowledgment reaches the channel with no app
    // handler bound: the runtime-owned arm publishes and rebuilds, so
    // the chrome renders enabled against the live duration.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try std.testing.expectEqual(@as(u64, 90_000), fx.videoSnapshot().duration_ms);

    // A release on the play/pause control drives the channel directly.
    const toggle_frame = try h.controlFrame(.toggle);
    try h.clickAt(toggle_frame.x + toggle_frame.width / 2, toggle_frame.y + toggle_frame.height / 2);
    try std.testing.expectEqual(@as(usize, 1), np.video_pause_count);
    try std.testing.expect(!fx.videoSnapshot().playing);

    // The rebuild that followed re-rendered the chrome from the moved
    // mirrors: the glyph is back to play.
    const paused_frame = try h.controlFrame(.toggle);
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.video_control == .toggle) {
            try std.testing.expectEqualStrings("play", node.widget.icon);
        }
    }

    // Pressing again resumes (autoplay's start was the first play).
    try h.clickAt(paused_frame.x + paused_frame.width / 2, paused_frame.y + paused_frame.height / 2);
    try std.testing.expectEqual(@as(usize, 2), np.video_play_count);
    try std.testing.expect(fx.videoSnapshot().playing);
}

test "keyboard activation of the house chrome toggle drives the channel like the pointer" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try std.testing.expect(fx.videoSnapshot().playing);

    // Target the toggle control exactly as the runtime's focus routing
    // would: the control advertises Play/Pause to focus and
    // accessibility, so Enter/Space must act, never be consumed
    // silently.
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    var target: ?canvas.WidgetFocusTarget = null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.video_control == .toggle) {
            target = .{
                .id = node.widget.id,
                .kind = node.widget.kind,
                .bounds = node.frame,
                .index = index,
                .state = node.widget.state,
            };
        }
    }
    try h.harness.runtime.dispatchEvent(h.app, .{ .canvas_widget_keyboard = .{
        .window_id = 1,
        .view_label = canvas_label,
        .keyboard = .{ .phase = .key_down, .focused_id = target.?.id, .key = "enter" },
        .target = target,
    } });
    try std.testing.expectEqual(@as(usize, 1), np.video_pause_count);
    try std.testing.expect(!fx.videoSnapshot().playing);

    // Space resumes, and the chrome re-rendered from the moved mirrors.
    try h.harness.runtime.dispatchEvent(h.app, .{ .canvas_widget_keyboard = .{
        .window_id = 1,
        .view_label = canvas_label,
        .keyboard = .{ .phase = .key_down, .focused_id = target.?.id, .key = "space" },
        .target = target,
    } });
    try std.testing.expectEqual(@as(usize, 2), np.video_play_count);
    try std.testing.expect(fx.videoSnapshot().playing);
}

test "the house chrome toggle restarts a finished playback from the start" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;
    const fx = &h.app_state.effects;

    // Run the declared playback to its natural end: the player
    // retires, the completion latches, and the scrub goes dead while
    // Play stays live.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(95_000).?);
    try std.testing.expect(fx.videoSnapshot().completed);
    try std.testing.expect(!np.video.loaded);
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.video_control == .scrub) try std.testing.expect(node.widget.state.disabled);
        if (node.widget.video_control == .toggle) try std.testing.expect(!node.widget.state.disabled);
    }

    // Play on the finished playback: a fresh load of the same source,
    // not a failed event.
    const loads_before = np.video_load_count;
    const toggle = try h.controlFrame(.toggle);
    try h.clickAt(toggle.center().x, toggle.center().y);
    try std.testing.expectEqual(loads_before + 1, np.video_load_count);
    try std.testing.expect(np.video.loaded);
    try std.testing.expect(np.video.playing);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expect(!fx.videoSnapshot().completed);
    try std.testing.expect(fx.videoSnapshot().playing);

    // The restart minted a fresh load identity and declarative
    // ownership re-captured it: flag deltas still apply, and removing
    // the element still stops the playback the reconciler restarted.
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_muted);
    try std.testing.expect(np.video.muted);
    try std.testing.expect(fx.videoSnapshot().muted);
    try h.app_state.dispatch(&h.harness.runtime, 1, .toggle_show);
    try std.testing.expect(!fx.videoSnapshot().active);
    try std.testing.expect(!np.video.loaded);
}

test "the house chrome slider seeks proportionally into the playback" {
    var h = try DeclHarness.create();
    defer h.destroy();
    const np = &h.harness.null_platform;

    // The duration arrives with the loaded acknowledgment; the seek
    // maps the slider fraction onto it.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.takeVideoLoaded().?);

    // A rail click at three quarters seeks to three quarters of the
    // 90s duration — the proportional mapping, not the raw fraction.
    const rail = try h.controlFrame(.scrub);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = rail.x + rail.width * 0.75,
        .y = rail.y + rail.height / 2,
    } });
    try std.testing.expectEqual(@as(usize, 1), np.video_seek_count);
    try std.testing.expectApproxEqAbs(@as(f64, 67_500), @as(f64, @floatFromInt(np.video.position_ms)), 2_000);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = rail.x + rail.width * 0.75,
        .y = rail.y + rail.height / 2,
    } });
}

// ------------------------------------------------------- record / replay

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

test "a recorded video session replays byte-identical with no producer and no player" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: a real playback on the null platform's player, decoded
    // frames pushed through the sink between presents, per-frame
    // fingerprint checkpoints.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        var frame_index: u64 = 2;
        var shade: u8 = 20;
        while (frame_index < 6) : (frame_index += 1) {
            const frame = solidFrame(.{ shade, 0, shade, 255 });
            try np.pushVideoFrame(2, 2, &frame);
            shade +%= 40;
            try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
            try dispatchFrame(harness, app, frame_index);
            try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        }
        try std.testing.expect(app_state.model.event_count > 0);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(clip_surface) != null);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay into a fresh runtime and app with NO producer attached and
    // NO platform player behind the events (video_playback=false): the
    // journaled effect records are the whole Msg source, every
    // checkpoint verifies, and the final fingerprint matches — texture
    // contents were never part of the session's identity.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.events_replayed > 0);
        try std.testing.expect(report.checkpoints_verified > 0);
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(clip_surface) == null);
        try std.testing.expectEqual(@as(usize, 0), harness.null_platform.video_load_count);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a handler-less house-chrome session replays with live mirrors and identical fingerprints" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: the declarative shape — presence loads the playback, no
    // app Msg handler anywhere, so the only video effect record is the
    // Msg-less `.video_load` cascade resolution; the journaled
    // platform `.video` events are the transport's record. The
    // chrome's time readouts render from the channel mirrors, so they
    // are part of every frame's fingerprint.
    var recorded_position: u64 = 0;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video-decl", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("one.mp4", 90_000, 640, 360);
        try harness.null_platform.setVideoMeta("two.mp4", 60_000, 640, 360);

        const app_state = try gpa.create(DeclApp);
        defer gpa.destroy(app_state);
        app_state.* = DeclApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video-decl",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = declUpdate,
            .view = declView,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        var frame_index: u64 = 2;
        while (frame_index < 6) : (frame_index += 1) {
            try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
            try dispatchFrame(harness, app, frame_index);
            try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        }
        try std.testing.expectEqual(@as(u64, 2_000), app_state.effects.videoSnapshot().position_ms);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_position = app_state.effects.videoSnapshot().position_ms;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay on a decoder-less host: the reconciler regenerates the
    // load (fake, parked), the fed `.video_load` record steers the
    // source mirror, and the replayed platform events steer the rest —
    // the chrome repaints identically, checkpoint by checkpoint, with
    // no Msg-bearing effect records anywhere.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(DeclApp);
        defer gpa.destroy(app_state);
        app_state.* = DeclApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video-decl",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = declUpdate,
            .view = declView,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.checkpoints_verified > 0);
        try std.testing.expectEqual(@as(u64, 1), report.effects_fed);
        try std.testing.expectEqual(recorded_position, app_state.effects.videoSnapshot().position_ms);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a recorded mid-playback failure replays its Msg and fingerprints identically" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: a real playback that dies mid-stream. The app HAS a
    // handler bound, so the `.failed` delivery journals an effect
    // record — and the platform `.failed` event that steered the
    // mirrors journals right behind it. Replay must deliver that Msg:
    // the platform event's mirror apply resets the channel first, so
    // a delivery resolved against the live channel at drain time
    // would find nothing and silently drop what the recording
    // dispatched.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        // The stream dies: one `.failed`, channel gone.
        try harness.runtime.dispatchPlatformEvent(app, np.failVideo().?);
        try dispatchFrame(harness, app, 3);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try std.testing.expect(!app_state.effects.videoSnapshot().active);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the journaled `.failed` effect record must reach
    // `update` even though the replayed platform event resets the
    // channel before the drain delivers it.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a batched load and stop replays the recorded synchronous terminal" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record on an assets-absent host: `Cmd.batch([videoLoad, videoStop])`
    // in one dispatch. The load's synchronous `.failed` stages inside
    // that dispatch and drains at the next wake — AFTER the stop has
    // retired the playback it reports on — so its record must route by
    // the load's identity at replay, where the fake load succeeds and
    // the stop (not a failure) is what retires the channel.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_local_files = false;
        harness.runtime.options.platform = harness.null_platform.platform();
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-then-stop", .window_id = 1, .view_label = canvas_label } });
        while (np.takeWake()) |_| {}
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try std.testing.expectEqual(clip_key, app_state.model.last_key);
        try std.testing.expect(!app_state.effects.videoSnapshot().active);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the fed `.failed` record finds its load already
    // retired by the replayed stop and still delivers the recorded Msg
    // with the recorded identity — never `EffectNotFound`, never a
    // binding to whatever the channel holds at feed time.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try std.testing.expectEqual(clip_key, app_state.model.last_key);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a replaced load's terminal keeps its own identity under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record on an assets-absent host: one dispatch loads a local clip
    // (synchronous `.failed`, staged) and immediately replaces it with
    // a URL stream UNDER THE SAME APP KEY. The staged terminal belongs
    // to the first load; at replay the fake first load succeeds and is
    // replaced in place, so only the journaled load identity — not the
    // key, which both loads share — can route the record to it. A feed
    // bound to the channel at feed time would reset the stream the
    // recording kept playing.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_local_files = false;
        harness.runtime.options.platform = harness.null_platform.platform();
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-then-stream", .window_id = 1, .view_label = canvas_label } });
        while (np.takeWake()) |_| {}
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        // Both deliveries arrived — the first load's failure, then the
        // stream's acknowledgment and tick — and the stream plays on.
        try std.testing.expect(app_state.model.event_count >= 3);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, app_state.model.last_kind.?);
        try std.testing.expect(app_state.effects.videoSnapshot().active);
        try std.testing.expect(app_state.effects.videoSnapshot().playing);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the first load's `.failed` routes to the retired
    // first load and the stream's records to the live channel — same
    // Msg stream, same mirrors, stream still active at the end.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expect(app_state.effects.videoSnapshot().active);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

/// Overwrite the `video_kind` byte of the first journaled `.video`
/// record, in place — `patchFirstVideoLoadKind`'s delivery-record twin.
fn patchFirstVideoKind(bytes: []u8, kind: effects_mod.EffectVideoEventKind) bool {
    var pos: usize = journal.preamble_len;
    while (bytes.len - pos >= 5) {
        const record_kind = bytes[pos];
        const len = std.mem.readInt(u32, bytes[pos + 1 ..][0..4], .little);
        const payload = bytes[pos + 5 .. pos + 5 + len];
        pos += 5 + len;
        if (record_kind != @intFromEnum(journal.RecordKind.effect)) continue;
        const record = journal.decodeEffect(payload) catch continue;
        if (record.kind != .video) continue;
        payload[payload.len - 44] = @intFromEnum(kind);
        return true;
    }
    return false;
}

/// Overwrite the `video_kind` byte of the first journaled `.video_load`
/// record, in place. Per `journal.encodeEffect` the video fields are
/// the LAST 44 bytes of the effect payload and `video_kind` is the
/// first of them. Framing and every other field stay valid: only
/// replay's outcome gate can catch the value. Returns whether a record
/// was damaged.
fn patchFirstVideoLoadKind(bytes: []u8, kind: effects_mod.EffectVideoEventKind) bool {
    var pos: usize = journal.preamble_len;
    while (bytes.len - pos >= 5) {
        const record_kind = bytes[pos];
        const len = std.mem.readInt(u32, bytes[pos + 1 ..][0..4], .little);
        const payload = bytes[pos + 5 .. pos + 5 + len];
        pos += 5 + len;
        if (record_kind != @intFromEnum(journal.RecordKind.effect)) continue;
        const record = journal.decodeEffect(payload) catch continue;
        if (record.kind != .video_load) continue;
        payload[payload.len - 44] = @intFromEnum(kind);
        return true;
    }
    return false;
}

test "a delivered record with altered scalars refuses replay as divergence" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record one delivered acknowledgment, then alter its position
    // around the intact identity: the recorder journals every delivery
    // verbatim from the platform event that produced it, so the
    // pairing must refuse the mismatch instead of handing the app a
    // Msg the mirrors contradict.
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.advanceVideo(500).?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
    }

    try std.testing.expect(patchFirstVideoPosition(buffer.bytes[0..buffer.len], 7_777));

    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = false,
            .require_same_platform = false,
        });
        try std.testing.expectError(error.ReplayEffectDivergence, result);
    }
}

test "an impossible journaled source shape fails the replayed load" {
    // A URL-only request can never resolve .local: the consume refuses
    // and latches the divergence the finish check reports.
    var fx = VideoEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.armReplay();
    fx.pushReplayVideoSource(clip_key, 1, .local, false);
    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .url = clip_url,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    try std.testing.expectError(error.ReplayVideoDivergence, fx.finishReplay());
}

test "a delivered record re-stamped as a rejection refuses replay as damage" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record one delivered acknowledgment, then re-stamp its record as
    // .rejected while its minted token stays: the recorder stamps token
    // 0 exactly on loop-side rejections, so this shape can only be a
    // hand-edited journal — and skipping it as a regeneration would
    // silently omit the recorded delivery.
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.takeVideoLoaded().?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
    }

    try std.testing.expect(patchFirstVideoKind(buffer.bytes[0..buffer.len], .rejected));

    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = false,
            .require_same_platform = false,
        });
        try std.testing.expectError(error.ReplayDamagedRecord, result);
    }
}

test "a video load record claiming a non-outcome kind refuses replay as damage" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record one resolved load, then hand-damage its `.video_load`
    // record's outcome: the recorder writes .loaded or .failed and
    // nothing else, so a .position there is damage, never a shape to
    // interpret.
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.takeVideoLoaded().?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
    }

    try std.testing.expect(patchFirstVideoLoadKind(buffer.bytes[0..buffer.len], .position));

    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = false,
            .require_same_platform = false,
        });
        try std.testing.expectError(error.ReplayDamagedRecord, result);
    }
}

/// Overwrite the `video_position_ms` field of the first journaled
/// video effect record, in place. Per `journal.encodeEffect` the video
/// fields are the LAST 44 bytes of the effect payload — video_kind
/// (1), position (8), duration (8), playing (1), buffering (1), width
/// (8), height (8), token (8), source (1) — so the position lives 43
/// bytes from the end.
/// Framing and every other field stay valid: only replay's damage gate
/// can catch the value. Returns whether a record was damaged.
fn patchFirstVideoPosition(bytes: []u8, position: u64) bool {
    var pos: usize = journal.preamble_len;
    while (bytes.len - pos >= 5) {
        const kind = bytes[pos];
        const len = std.mem.readInt(u32, bytes[pos + 1 ..][0..4], .little);
        const payload = bytes[pos + 5 .. pos + 5 + len];
        pos += 5 + len;
        if (kind != @intFromEnum(journal.RecordKind.effect)) continue;
        const record = journal.decodeEffect(payload) catch continue;
        if (record.kind != .video) continue;
        std.mem.writeInt(u64, payload[payload.len - 43 ..][0..8], position, .little);
        return true;
    }
    return false;
}

test "a video record claiming a past-2^53 scalar refuses replay as damage" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record a real playback session (the byte-identical test's shape,
    // shortened), then hand-damage the first video record's position
    // to a value no recorder ever writes.
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
    }

    try std.testing.expect(patchFirstVideoPosition(buffer.bytes[0..buffer.len], @as(u64, 1) << 53));

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.video_playback = false;
    harness.runtime.options.platform = harness.null_platform.platform();
    const app_state = try gpa.create(VideoApp);
    defer gpa.destroy(app_state);
    app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-video",
        .scene = video_scene,
        .canvas_label = canvas_label,
        .update_fx = videoUpdate,
        .view = videoView,
        .on_command = videoCommand,
    });
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = false,
    });
    try std.testing.expectError(error.ReplayDamagedRecord, result);
}

// --------------------------------------- multi-window declarations

const PromoModel = struct { show_a: bool = true };

const PromoMsg = union(enum) { noop };

const PromoApp = ui_app_model.UiApp(PromoModel, PromoMsg);

fn promoUpdate(model: *PromoModel, msg: PromoMsg) void {
    _ = model;
    switch (msg) {
        .noop => {},
    }
}

fn promoView(ui: *PromoApp.Ui, model: *const PromoModel) PromoApp.Ui.Node {
    _ = model;
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, "main"),
    });
}

fn promoWindows(model: *const PromoModel, scratch: *PromoApp.WindowsScratch) []const PromoApp.WindowDescriptor {
    var count: usize = 0;
    if (model.show_a) {
        scratch.windows[count] = .{
            .label = "win-a",
            .canvas_label = "win-a-canvas",
            .title = "A",
            .width = 320,
            .height = 240,
        };
        count += 1;
    }
    scratch.windows[count] = .{
        .label = "win-b",
        .canvas_label = "win-b-canvas",
        .title = "B",
        .width = 320,
        .height = 240,
    };
    count += 1;
    return scratch.windows[0..count];
}

fn promoWindowView(ui: *PromoApp.Ui, model: *const PromoModel, window_label: []const u8) PromoApp.Ui.Node {
    _ = model;
    const src = if (std.mem.eql(u8, window_label, "win-a")) "assets/clips/a.mp4" else "assets/clips/b.mp4";
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.video(.{ .src = src, .width = 128, .height = 72 }),
    });
}

test "a closed window's declared video promotes the next window's declaration at once" {
    const gpa = std.testing.allocator;
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const np = &harness.null_platform;
    try np.setVideoMeta("a.mp4", 30_000, 640, 360);
    try np.setVideoMeta("b.mp4", 45_000, 640, 360);

    const app_state = try gpa.create(PromoApp);
    defer gpa.destroy(app_state);
    app_state.* = PromoApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-video-promo",
        .scene = video_scene,
        .canvas_label = canvas_label,
        .update = promoUpdate,
        .view = promoView,
        .windows_fn = promoWindows,
        .window_view = promoWindowView,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try dispatchFrame(harness, app, 1);

    // Both windows exist; install their canvases so the slot builds
    // run and record their declarations.
    var window_a: u64 = 0;
    var window_b: u64 = 0;
    {
        var buffer: [platform.max_windows]platform.WindowInfo = undefined;
        for (harness.runtime.listWindows(&buffer)) |info| {
            if (std.mem.eql(u8, info.label, "win-a")) window_a = info.id;
            if (std.mem.eql(u8, info.label, "win-b")) window_b = info.id;
        }
    }
    try std.testing.expect(window_a != 0 and window_b != 0);
    inline for (.{ .{ "win-a-canvas", 0 }, .{ "win-b-canvas", 1 } }) |entry| {
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .window_id = if (entry[1] == 0) window_a else window_b,
            .label = entry[0],
            .size = geometry.SizeF.init(320, 240),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 2_000_000,
            .nonblank = true,
        } });
    }
    try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "noop", .window_id = 1, .view_label = canvas_label } });

    // The first declaring window owns the single player.
    try std.testing.expect(std.mem.endsWith(u8, np.video.path(), "a.mp4"));

    // The user closes window A: no on_close Msg, no rebuild — the
    // retained declaration from window B must promote on the spot,
    // not wait for an unrelated rebuild.
    const close_event = np.userCloseWindow(window_a).?;
    try harness.runtime.dispatchPlatformEvent(app, close_event);
    try std.testing.expect(std.mem.endsWith(u8, np.video.path(), "b.mp4"));
    try std.testing.expect(np.video.playing);
}

test "a completion handler's chained load replays in recorded order" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record the playlist shape: clip A completes, its handler loads
    // clip B from inside the completion dispatch, and B's `.loaded`
    // acknowledgment is the very next platform event — no frame
    // between. Replay must run the completion Msg DURING the replayed
    // completed event, or B's loaded event would be swallowed against
    // A's token and the whole tail would diverge.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 3_000, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.arm-chain", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        // Run A to its natural end: the completion Msg loads B inside
        // its own dispatch, and B's loaded ack replays as the very
        // next event.
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(3_000).?);
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(@as(usize, 1), app_state.model.completed_count);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.loaded, app_state.model.last_kind.?);
        try std.testing.expectEqual(clip_key + 1, app_state.model.last_key);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expectEqual(@as(usize, 1), app_state.model.completed_count);
        try std.testing.expectEqual(clip_key + 1, app_state.model.last_key);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
        // Retired identities release as the replay advances — at most
        // the final clip's park (whose closing pass the session's end
        // cut off) may remain; a playlist never accumulates one entry
        // per clip (the drain-boundary sweep's contract, pinned
        // directly in "retired video identities release once their
        // delivery window closes").
        try std.testing.expect(app_state.effects.retired_video_len <= 1);
    }
}

test "an undelivered fed video result fails the finish check" {
    // A fed record is one recorded delivery, and the event that
    // consumed it live follows it in every honest journal — so a fed
    // entry still staged at the journal's end is truncation or
    // hand-editing, never success.
    var fx = VideoEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.armReplay();
    fx.pushReplayVideoSource(clip_key, 1, .local, false);
    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    try fx.feedVideoRecord(clip_key, 1, .position, 500, 92_500, true, false, 0, 0);
    try std.testing.expectError(error.ReplayVideoDivergence, fx.finishReplay());

    // Delivered, the finish is silent again.
    var boundary = fx.drainBoundary();
    const msg = fx.takeMsgWithin(&boundary) orelse return error.TestExpectedMsg;
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, msg.video_event.kind);
    try fx.finishReplay();
}

test "retired video identities release at the next drain-pass boundary" {
    // Bare channel, replay-armed: replaced and stopped loads park their
    // identities; a park a journaled record references is consumed by
    // the feed itself, and a never-referenced leftover releases at the
    // first pass boundary after parking (its record, had one existed,
    // would have fed before that pass's event dispatched) — the sweep
    // that keeps a long replayed playlist from accumulating an entry
    // per clip.
    var fx = VideoEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.armReplay();

    fx.pushReplayVideoSource(clip_key, 1, .local, false);
    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    fx.pushReplayVideoSource(clip_key + 1, 2, .local, false);
    fx.loadVideo(.{
        .key = clip_key + 1,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    try std.testing.expectEqual(@as(usize, 1), fx.retired_video_len);

    // A journaled record for the replaced load consumes the park (the
    // deterministic token sequence: the first load minted token 1).
    try fx.feedVideoRecord(clip_key, 1, .failed, 0, 0, false, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), fx.retired_video_len);

    // A stopped load with no record behind it releases at the next
    // boundary instead of lingering for the session.
    fx.stopVideo();
    try std.testing.expectEqual(@as(usize, 1), fx.retired_video_len);
    _ = fx.drainBoundary();
    try std.testing.expectEqual(@as(usize, 0), fx.retired_video_len);
}

test "the cascade's resolved source replays without the recording host's files" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record on an assets-absent host: a load carrying both a local
    // path and a url falls through to the url and streams — a
    // resolution only the recording host's filesystem could make. The
    // journaled `.video_load` record carries it, so replay's fake load
    // (which cannot probe for the file) still mirrors `.stream` with
    // the optimistic buffering flag instead of reporting the requested
    // shape as `.local`.
    var recorded_model: VideoModel = undefined;
    var recorded_source: effects_mod.EffectVideoSource = .local;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_local_files = false;
        harness.runtime.options.platform = harness.null_platform.platform();
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-url", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.takeVideoLoaded().?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(@as(usize, 1), harness.null_platform.video_load_url_count);
        try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, app_state.effects.videoSnapshot().source);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_source = app_state.effects.videoSnapshot().source;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: same source mirror, same everything.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expectEqual(recorded_source, app_state.effects.videoSnapshot().source);
        try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, app_state.effects.videoSnapshot().source);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "replayed video records must name the load at their position" {
    // The reminted token sequence pairs records with replayed loads by
    // POSITION; the journaled key is the cross-check that the load at
    // that position is the load the recording issued. A mismatch — a
    // hand-edited journal or a timeline that diverged before the feed
    // — refuses instead of delivering through the wrong playback.
    var fx = VideoEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.armReplay();

    fx.pushReplayVideoSource(clip_key, 1, .local, false);
    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    fx.pushReplayVideoSource(clip_key + 1, 2, .local, false);
    fx.loadVideo(.{
        .key = clip_key + 1,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });

    // Wrong key against the retired first load (token 1).
    try std.testing.expectError(error.EffectNotFound, fx.feedVideoRecord(clip_key + 5, 1, .failed, 0, 0, false, false, 0, 0));
    // Wrong key against the live load (token 2).
    try std.testing.expectError(error.EffectNotFound, fx.feedVideoRecord(clip_key + 5, 2, .position, 0, 0, true, false, 0, 0));
    // The honest pairing still delivers.
    try fx.feedVideoRecord(clip_key + 1, 2, .position, 500, 92_500, true, false, 0, 0);
}

test "unclaimed or misclaimed cascade resolutions fail the finish check" {
    // A structurally valid journal whose `.video_load` records the
    // replayed timeline never consumed — or consumed under a different
    // key — is divergence, not success (`finishReplay`, run by the
    // replayer at the journal's end).
    {
        var fx = VideoEffects.init(std.testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        fx.pushReplayVideoSource(clip_key, 999, .stream, false);
        try std.testing.expectError(error.ReplayVideoDivergence, fx.finishReplay());
    }
    {
        var fx = VideoEffects.init(std.testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        // The record names key clip_key+7 at position (token) 1, but
        // the replayed dispatch loads clip_key: the consume latches the
        // divergence the void-returning loadVideo cannot raise.
        fx.pushReplayVideoSource(clip_key + 7, 1, .stream, false);
        fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .on_event = VideoEffects.videoMsg(.video_event),
        });
        try std.testing.expectError(error.ReplayVideoDivergence, fx.finishReplay());
    }
    {
        // The clean shape: consumed by the load it named, finish is
        // silent.
        var fx = VideoEffects.init(std.testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        fx.pushReplayVideoSource(clip_key, 1, .stream, false);
        fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .url = clip_url,
            .on_event = VideoEffects.videoMsg(.video_event),
        });
        try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, fx.videoSnapshot().source);
        try fx.finishReplay();

        // An EXTRA load the recording never issued — no record at its
        // position — is divergence too: every non-rejected recorded
        // load journals one, so absence proves the timelines differ.
        fx.loadVideo(.{
            .key = clip_key + 1,
            .surface = clip_surface,
            .url = clip_url,
            .on_event = VideoEffects.videoMsg(.video_event),
        });
        try std.testing.expectError(error.ReplayVideoDivergence, fx.finishReplay());
    }
}

test "a load burst past the resolution queue's inline capacity replays whole" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record on an assets-absent host: one dispatch resolves more
    // loads than the replay-side cascade-resolution queue holds
    // inline (each falls through to the url). All the records land
    // before the dispatch's event, so replay queues every one of them
    // first — the queue must spill, never refuse.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_local_files = false;
        harness.runtime.options.platform = harness.null_platform.platform();
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-source-burst", .window_id = 1, .view_label = canvas_label } });
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(effects_mod.max_effect_replay_video_source_entries + 1, harness.null_platform.video_load_url_count);
        try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, app_state.effects.videoSnapshot().source);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: no false divergence at the inline capacity, and
    // the surviving load's resolved source lands.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(effects_mod.EffectVideoSource.stream, app_state.effects.videoSnapshot().source);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a zero-record recording still fails replay when the timeline loads video" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record a session that journals NO effect records at all: no
    // video element anywhere, just frames.
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video-decl", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(DeclApp);
        defer gpa.destroy(app_state);
        app_state.* = DeclApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video-decl",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = declUpdate,
            .view = declViewNone,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        recorder.finish();
        try std.testing.expect(!recorder.failed);
    }

    // Replay into a build whose view DOES declare a video: the
    // reconciler issues a load the recording never journaled. Zero
    // records were fed, so only the unconditional end-of-journal
    // consistency check can catch the divergence — and it must.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(DeclApp);
        defer gpa.destroy(app_state);
        app_state.* = DeclApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video-decl",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = declUpdate,
            .view = declView,
        });
        defer app_state.deinit();

        const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = false,
            .require_same_platform = false,
        });
        try std.testing.expectError(error.ReplayEffectDivergence, result);
    }
}

test "a post-completion seek keeps the terminal position under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: the playback completes naturally (the host retires the
    // player, retire-before-emit), then a later dispatch scrubs. The
    // retired player refuses the seek, so the mirrors keep the
    // terminal position.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(93_000).?);
        try std.testing.expectEqual(@as(usize, 1), app_state.model.completed_count);
        // The scrub after the natural end: refused by the retired
        // player, position pinned at the duration.
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.seek-half", .window_id = 1, .view_label = canvas_label } });
        try std.testing.expectEqual(@as(u64, 92_500), app_state.effects.videoSnapshot().position_ms);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the fake channel refuses the same seek — the
    // completion latched the retire — so the mirrors and the chrome
    // land exactly where the recording left them.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(@as(u64, 92_500), app_state.effects.videoSnapshot().position_ms);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a regenerated rejection never reorders a paired delivery under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: playback A is live and handled; a dispatch stages a
    // loop-side rejection (an invalid load, which leaves A untouched);
    // A's next position event arrives BEFORE the wake that drains the
    // rejection. Live order: loaded, position (synchronous at its
    // event), rejected (at the wake).
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-zero-surface", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(500).?);
        // The position delivered synchronously at its own event, ahead
        // of the staged rejection still awaiting its wake.
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.position, app_state.model.last_kind.?);
        while (np.takeWake()) |_| {}
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.rejected, app_state.model.last_kind.?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the regenerated rejection stages ahead of the
    // fed position record, but the position must still pair with its
    // platform event and dispatch synchronously — same Msg order, same
    // model, same fingerprints.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.rejected, app_state.model.last_kind.?);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a synchronous load failure resets the snapshot identically under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record on an assets-absent host: the update loads and probes the
    // snapshot in the same dispatch. The refusal reset the channel
    // before loadVideo returned, so the probe reads inactive.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_local_files = false;
        harness.runtime.options.platform = harness.null_platform.platform();
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load-then-probe", .window_id = 1, .view_label = canvas_label } });
        try std.testing.expectEqual(@as(?bool, false), app_state.model.probed_active);
        while (harness.null_platform.takeWake()) |_| {}
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the journaled load resolution carries the
    // refusal, so the fake load resets at the same instant and the
    // replayed probe reads the same inactive snapshot.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(@as(?bool, false), app_state.model.probed_active);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "stopping a stream cancels only its own staged answers" {
    // Two loads share one public key (the TS tier routes every load of
    // one event arm through the same tag-derived key); the replaced
    // first load still owes its staged terminal when the second is
    // stopped. The cancel is token-scoped: B's stop never silences A.
    var fx = VideoEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .path = clip_path,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    // A's terminal stages (token 1)...
    try fx.feedVideoEvent(.failed, 0, 0, false, false, 0, 0);
    // ...then B replaces under the same key (token 2), stages its own
    // tick, and is stopped: only B's answers cancel.
    fx.loadVideo(.{
        .key = clip_key,
        .surface = clip_surface,
        .url = clip_url,
        .on_event = VideoEffects.videoMsg(.video_event),
    });
    try fx.feedVideoEvent(.position, 500, 92_500, true, false, 0, 0);
    fx.stopVideoCancel();

    var boundary = fx.drainBoundary();
    const msg = fx.takeMsgWithin(&boundary) orelse return error.TestExpectedMsg;
    try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, msg.video_event.kind);
    try std.testing.expectEqual(clip_key, msg.video_event.key);
    try std.testing.expect(fx.takeMsgWithin(&boundary) == null);
}

test "a post-completion play resets the snapshot identically under replay" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: the playback completes naturally (the host retires the
    // player), then an update calls play and probes the snapshot in
    // the same dispatch. The refusal reset the channel before
    // playVideo returned, so the probe reads inactive, and the
    // `.failed` terminal delivers at the next wake.
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", 10_000, 640, 360);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try harness.runtime.dispatchPlatformEvent(app, np.advanceVideo(10_500).?);
        try std.testing.expectEqual(@as(usize, 1), app_state.model.completed_count);
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.play-then-probe", .window_id = 1, .view_label = canvas_label } });
        try std.testing.expectEqual(@as(?bool, false), app_state.model.probed_active);
        while (np.takeWake()) |_| {}
        try harness.runtime.dispatchPlatformEvent(app, .wake);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the fake channel latched the completion, so the
    // replayed play resets at the same instant and the probe reads the
    // same inactive snapshot; the journaled terminal delivers itself.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(@as(?bool, false), app_state.model.probed_active);
        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.failed, app_state.model.last_kind.?);
        try std.testing.expect(!app_state.effects.videoSnapshot().active);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

test "a past-window host readout clamps at delivery and replays clamped" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record against a host reporting a duration past the exact-integer
    // delivery window (the platform seam accepts any u64): the channel
    // clamps at delivery, so the Msg, the mirrors, and the journaled
    // record all carry the window's ceiling — an honest recording, not
    // damage.
    const past_window: u64 = effects_mod.max_effect_video_scalar_exclusive * 2;
    const clamped: u64 = effects_mod.max_effect_video_scalar_exclusive - 1;
    var recorded_model: VideoModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "effects-video", .window_width = 400, .window_height = 300 });

        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.null_platform.setVideoMeta("orchard-flyover.mp4", past_window, 1280, 720);

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try dispatchFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const np = &harness.null_platform;
        try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = "video.load", .window_id = 1, .view_label = canvas_label } });
        try harness.runtime.dispatchPlatformEvent(app, np.takeVideoLoaded().?);
        try dispatchFrame(harness, app, 2);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        try std.testing.expectEqual(effects_mod.EffectVideoEventKind.loaded, app_state.model.last_kind.?);
        try std.testing.expectEqual(clamped, app_state.model.last_duration_ms);
        try std.testing.expectEqual(clamped, app_state.effects.videoSnapshot().duration_ms);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay offline: the record carries the clamped value, so the
    // damage gate (which refuses scalars at or past the window) admits
    // the honest recording, and the replayed platform event clamps
    // identically on its way into the mirrors.
    {
        const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.video_playback = false;
        harness.runtime.options.platform = harness.null_platform.platform();

        const app_state = try gpa.create(VideoApp);
        defer gpa.destroy(app_state);
        app_state.* = VideoApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-video",
            .scene = video_scene,
            .canvas_label = canvas_label,
            .update_fx = videoUpdate,
            .view = videoView,
            .on_command = videoCommand,
        });
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.effects_fed > 0);
        try std.testing.expectEqual(clamped, app_state.model.last_duration_ms);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}
