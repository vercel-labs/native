//! Headless coverage for the player: the custom screen's command
//! stream through the fake executor's synthetic events, the automation
//! path driving the real widgets, and the declarative screen loading
//! the committed source through the null platform's fake decoder. No
//! media is touched — transport events are executor truth, exactly
//! what a live host would deliver.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const PlayerApp = native_sdk.UiApp(Model, Msg);

const shell_views = [_]native_sdk.ShellView{
    .{ .label = "player-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Video Player",
    .width = 760,
    .height = 560,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const clip_path = "clips/orchard-flyover.mp4";
const clip_url = "https://media.example.test/clips/orchard-flyover.mp4";

const Live = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *PlayerApp,

    fn start(initial: Model) !Live {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(760, 560) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try testing.allocator.create(PlayerApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = PlayerApp.init(std.heap.page_allocator, initial, .{
            .name = "video-player",
            .scene = shell_scene,
            .canvas_label = "player-canvas",
            .update_fx = main.update,
            .view = main.view,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = "player-canvas",
            .size = geometry.SizeF.init(760, 560),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state };
    }

    fn stop(self: *Live) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: *Live, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    fn wake(self: *Live) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .wake);
    }
};

fn openedModel(source: []const u8, screen: main.Screen) Model {
    var model = Model{ .screen = screen };
    model.setOpened(source);
    model.source_field.set(source);
    return model;
}

test "the custom screen issues the documented command stream and mirrors events" {
    var live = try Live.start(openedModel(clip_path, .player));
    defer live.stop();
    const fx = &live.app_state.effects;
    fx.executor = .fake;

    // Entering the custom screen loads the committed source on the
    // app's own surface — the whole request is captured, not executed.
    try live.dispatch(.show_custom);
    const request = fx.pendingVideo().?;
    try testing.expectEqual(main.custom_key, request.key);
    try testing.expectEqual(main.custom_surface, request.surface);
    try testing.expectEqualStrings(clip_path, request.path);
    try testing.expectEqualStrings("", request.url);

    // Synthetic transport events are the model's only truth source.
    try fx.feedVideoEvent(.loaded, 0, 92_500, true, false, 1280, 720);
    try live.wake();
    try testing.expectEqual(native_sdk.EffectVideoEventKind.loaded, live.app_state.model.status.?);
    try testing.expectEqual(@as(u64, 92_500), live.app_state.model.duration_ms);
    try testing.expectEqual(@as(u64, 1280), live.app_state.model.width);
    try testing.expect(live.app_state.model.playing);

    try fx.feedVideoEvent(.position, 61_000, 92_500, true, false, 0, 0);
    try live.wake();
    try testing.expectEqual(@as(u64, 61_000), live.app_state.model.position_ms);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("1:01", main.formatClock(arena_state.allocator(), live.app_state.model.position_ms));

    // Transport verbs drive the single channel; the snapshot mirrors
    // what the player was told.
    try live.dispatch(.toggle_play);
    try testing.expect(!fx.videoSnapshot().playing);
    try live.dispatch(.toggle_play);
    try testing.expect(fx.videoSnapshot().playing);
    try live.dispatch(.forward);
    try testing.expectEqual(@as(u64, 71_000), fx.videoSnapshot().position_ms);
    try live.dispatch(.back);
    try testing.expectEqual(@as(u64, 51_000), fx.videoSnapshot().position_ms);
    try live.dispatch(.{ .scrubbed = 0.5 });
    try testing.expectEqual(@as(u64, 46_250), fx.videoSnapshot().position_ms);
    try live.dispatch(.{ .set_volume = 0.4 });
    try testing.expectEqual(@as(f32, 0.4), fx.videoSnapshot().volume);
    try live.dispatch(.toggle_mute);
    try testing.expect(fx.videoSnapshot().muted);
    try live.dispatch(.toggle_loop);
    try testing.expect(fx.videoSnapshot().looping);

    // Completion pins the clock to the end and stops the transport.
    try fx.feedVideoEvent(.completed, 92_500, 92_500, false, false, 0, 0);
    try live.wake();
    try testing.expectEqual(native_sdk.EffectVideoEventKind.completed, live.app_state.model.status.?);
    try testing.expect(!live.app_state.model.playing);
}

test "url sources load as streams; a failed decode reports honestly" {
    var live = try Live.start(openedModel(clip_url, .player));
    defer live.stop();
    const fx = &live.app_state.effects;
    fx.executor = .fake;

    try live.dispatch(.show_custom);
    const request = fx.pendingVideo().?;
    try testing.expectEqualStrings("", request.path);
    try testing.expectEqualStrings(clip_url, request.url);

    try fx.feedVideoEvent(.failed, 0, 0, false, false, 0, 0);
    try live.wake();
    try testing.expectEqual(native_sdk.EffectVideoEventKind.failed, live.app_state.model.status.?);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(std.mem.indexOf(u8, live.app_state.model.statusText(arena_state.allocator()), "failed") != null);
}

test "committing an empty source stops the playback with the status line" {
    var live = try Live.start(openedModel(clip_path, .player));
    defer live.stop();
    const fx = &live.app_state.effects;
    fx.executor = .fake;

    try live.dispatch(.show_custom);
    try fx.feedVideoEvent(.loaded, 0, 92_500, true, false, 1280, 720);
    try live.wake();
    try testing.expect(fx.videoSnapshot().active);
    try testing.expect(live.app_state.model.playing);

    // Clearing the field and committing must stop the playback with
    // the words: a status line saying "no source" over a still-rolling
    // player would be a lie.
    live.app_state.model.source_field.set("");
    try live.dispatch(.open);
    try testing.expect(!fx.videoSnapshot().active);
    try testing.expect(!live.app_state.model.playing);
    try testing.expectEqual(@as(u64, 0), live.app_state.model.duration_ms);
    try expectStatusBar(live.app_state.tree.?.root, "no source - pass a file path or http(s) url, or type one above");
}

test "automation drives the custom transport bar through the real widgets" {
    var live = try Live.start(openedModel(clip_path, .player));
    defer live.stop();
    const fx = &live.app_state.effects;
    fx.executor = .fake;

    try live.dispatch(.show_custom);
    try fx.feedVideoEvent(.loaded, 0, 100_000, true, false, 640, 360);
    try live.wake();

    // The seek slider is a real widget: a semantic increment steps it,
    // on_value delivers the fraction, and update forwards the target
    // into the channel — the whole path a pointer drag takes.
    const slider = findByLabel(live.app_state.tree.?.root, .slider, "Seek").?;
    var command_buffer: [96]u8 = undefined;
    const step = try std.fmt.bufPrint(&command_buffer, "widget-action player-canvas {d} increment", .{slider.id});
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), step);
    try testing.expect(fx.videoSnapshot().position_ms > 0);
    try testing.expectEqual(live.app_state.model.position_ms, fx.videoSnapshot().position_ms);

    // The play/pause button pauses through its press action.
    const toggle = findByLabel(live.app_state.tree.?.root, .button, "Pause").?;
    const press = try std.fmt.bufPrint(&command_buffer, "widget-action player-canvas {d} press", .{toggle.id});
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), press);
    try testing.expect(!fx.videoSnapshot().playing);
}

test "the player screen declares the committed source and the null decoder loads it" {
    // Start on the custom screen (no declaration, nothing loads) so the
    // fake decoder's metadata is registered before the declarative
    // screen's first load.
    var live = try Live.start(openedModel(clip_path, .custom));
    defer live.stop();
    const np = &live.harness.null_platform;
    try np.setVideoMeta("orchard-flyover.mp4", 92_500, 1280, 720);
    try testing.expectEqual(@as(usize, 0), np.video_load_count);

    // The declarative screen: the <video>-equivalent builder call
    // carries the committed source, so the rebuild that shows it
    // reconciles the source into the single player through the real
    // executor.
    try live.dispatch(.show_player);
    try testing.expectEqual(@as(usize, 1), np.video_load_count);
    try testing.expectEqualStrings(clip_path, np.video.path());
    try testing.expect(np.video.playing);

    // The loaded acknowledgment reaches the automation snapshot even
    // though the declarative screen wires no app Msg — house chrome
    // state is runtime truth.
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), np.takeVideoLoaded().?);
    const snapshot = live.harness.runtime.automationSnapshot("Video Player").video.?;
    try testing.expectEqual(@as(u64, 92_500), snapshot.duration_ms);
    try testing.expectEqual(@as(u64, 1280), snapshot.width);

    // The screen's status line never pretends to track the transport
    // it does not own: it teaches where the state lives, through load,
    // playback, and completion alike — never a stuck "loading".
    try expectStatusBar(live.app_state.tree.?.root, "house chrome drives the playback - transport state lives in the runtime, not the model");
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), np.advanceVideo(500).?);
    try expectStatusBar(live.app_state.tree.?.root, "house chrome drives the playback - transport state lives in the runtime, not the model");
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), np.advanceVideo(100_000).?);
    try expectStatusBar(live.app_state.tree.?.root, "house chrome drives the playback - transport state lives in the runtime, not the model");
}

test "the status line reports transport only where the app owns the events" {
    var live = try Live.start(openedModel(clip_path, .player));
    defer live.stop();
    const fx = &live.app_state.effects;
    fx.executor = .fake;

    // The custom screen owns its events, so its status line follows
    // them: loading until the acknowledgment, then the honest
    // dimensions and transport, then completion.
    try live.dispatch(.show_custom);
    try expectStatusBar(live.app_state.tree.?.root, "loading");
    try fx.feedVideoEvent(.loaded, 0, 92_500, true, false, 1280, 720);
    try live.wake();
    try expectStatusBar(live.app_state.tree.?.root, "1280x720 · playing");
    try live.dispatch(.toggle_play);
    try fx.feedVideoEvent(.position, 1_000, 92_500, false, false, 0, 0);
    try live.wake();
    try expectStatusBar(live.app_state.tree.?.root, "1280x720 · paused");
    try fx.feedVideoEvent(.completed, 92_500, 92_500, false, false, 0, 0);
    try live.wake();
    try expectStatusBar(live.app_state.tree.?.root, "finished");
}

test "the view lays out through the canvas engine on both screens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = openedModel(clip_path, .custom);
    model.status = .loaded;
    model.playing = true;
    model.duration_ms = 92_500;
    var ui = main.PlayerUi.init(arena);
    const tree = try ui.finalize(main.view(&ui, &model));

    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 760, 560), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(findByLabel(tree.root, .slider, "Seek") != null);
    try testing.expect(findByLabel(tree.root, .slider, "Volume") != null);
    try testing.expect(findByLabel(tree.root, .button, "Pause") != null);
    try testing.expect(findByKind(tree.root, .media_surface) != null);

    var player_ui = main.PlayerUi.init(arena);
    var player_model = openedModel(clip_path, .player);
    const player_tree = try player_ui.finalize(main.view(&player_ui, &player_model));
    var player_nodes: [512]canvas.WidgetLayoutNode = undefined;
    const player_layout = try canvas.layoutWidgetTree(player_tree.root, geometry.RectF.init(0, 0, 760, 560), &player_nodes);
    try testing.expect(player_layout.nodes.len > 0);
    try testing.expect(findByKind(player_tree.root, .media_surface) != null);
}

fn expectStatusBar(root: canvas.Widget, expected: []const u8) !void {
    const bar = findByKind(root, .status_bar) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expected, bar.text);
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, kind, label)) |found| return found;
    }
    return null;
}
