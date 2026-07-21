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
    load_url,
    load_url_only,
    load_no_source,
    load_zero_surface,
    load_reserved_surface,
    load_bad_scheme,
    load_paused,
    load_looping,
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
        .load_looping => fx.loadVideo(.{
            .key = clip_key,
            .surface = clip_surface,
            .path = clip_path,
            .loop = true,
            .muted = true,
            .on_event = VideoEffects.videoMsg(.video_event),
        }),
        .play => fx.playVideo(),
        .pause => fx.pauseVideo(),
        .stop => fx.stopVideo(),
        .seek_half => fx.seekVideo(45_000),
        .quiet => fx.setVideoVolume(0.25),
        .mute_on => fx.setVideoMuted(true),
        .loop_on => fx.setVideoLoop(true),
        .video_event => |event| model.record(event),
    }
}

fn videoCommand(name: []const u8) ?VideoMsg {
    if (std.mem.eql(u8, name, "video.load")) return .load;
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

    // Advancing past the end delivers the one completion.
    try h.harness.runtime.dispatchPlatformEvent(h.app, np.advanceVideo(60_000).?);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.completed_count);
    try std.testing.expectEqual(@as(u64, 92_500), h.app_state.model.last_position_ms);
    try std.testing.expect(!h.app_state.model.last_playing);
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
};

const DeclMsg = union(enum) { toggle_show, use_second, noop };

const DeclApp = ui_app_model.UiApp(DeclModel, DeclMsg);
const DeclEffects = DeclApp.Effects;

fn declUpdate(model: *DeclModel, msg: DeclMsg, fx: *DeclEffects) void {
    _ = fx;
    switch (msg) {
        .toggle_show => model.show = !model.show,
        .use_second => model.second = true,
        .noop => {},
    }
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
            .src = if (model.second) "assets/clips/two.mp4" else "assets/clips/one.mp4",
            .controls = true,
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
    // playback surface, autoplay honored.
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);
    try std.testing.expectEqualStrings("assets/clips/one.mp4", np.video.path());
    try std.testing.expect(np.video.playing);
    try std.testing.expect(fx.videoSnapshot().active);
    try std.testing.expectEqual(canvas.video_playback_surface_id, fx.videoSnapshot().surface);

    // A rebuild with the unchanged declaration never reloads — an
    // unchanged src must not restart the playback.
    try h.app_state.dispatch(&h.harness.runtime, 1, .noop);
    try std.testing.expectEqual(@as(usize, 1), np.video_load_count);

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
    // app Msg handler anywhere, so NO video effect records exist; the
    // journaled platform `.video` events are the transport's only
    // record. The chrome's time readouts render from the channel
    // mirrors, so they are part of every frame's fingerprint.
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
    // load (fake, parked), and the replayed platform events steer the
    // mirrors — the chrome repaints identically, checkpoint by
    // checkpoint, with zero fed effect records.
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
        try std.testing.expectEqual(@as(u64, 0), report.effects_fed);
        try std.testing.expectEqual(recorded_position, app_state.effects.videoSnapshot().position_ms);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}
