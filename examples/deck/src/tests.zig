//! deck tests: typed dispatch through both windows' trees (the fixed
//! player and the model-declared playlist rack), real playback through
//! the audio effect channel's fake executor (request/feed round trips,
//! auto-advance, the honest NO MEDIA degrade), the pbcopy spawn,
//! spectrum and marquee determinism on the position-event clock, the
//! image channel (strict decode, codec-less fallback, the JPEG covers'
//! pinned degrade, the chrome's draw_image), the playlist window's full
//! round-trip through real dispatch, the dark-only theming contract,
//! markup engine parity, automation click-through on the transport, and
//! layout/widget budgets at the fixed window sizes.
//!
//! Every content-coupled assertion derives from the committed manifest
//! (`music_manifest.zon` through model.zig's comptime tables) — no track
//! id, title, or per-album count is hardcoded, so regenerating the
//! catalog can never silently rot the suite. The suite is hermetic: the
//! gitignored mp3s are never read (the fake executor answers playback),
//! and the null platform's strict decoder pins the JPEG-cover degrade
//! instead of decoding it.

const std = @import("std");
const native_sdk = @import("native_sdk");
const chrome = @import("chrome.zig");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const Ui = view_mod.Ui;
const App = main.DeckApp;

// ------------------------------------------------------------- tree utils

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.rootView(&ui, model), main.tokensFromModel(model));
}

fn buildPlaylistTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.playlistView(&ui, model), main.tokensFromModel(model));
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn countListItems(widget: canvas.Widget) usize {
    var total: usize = 0;
    if (widget.semantics.role == .listitem) total += 1;
    for (widget.children) |child| total += countListItems(child);
    return total;
}

/// Update with a throwaway effects channel for tree-level tests that do
/// not assert on effect requests.
fn apply(model: *Model, msg: Msg) void {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(model, msg, &fx);
}

// ---------------------------------------------------------- catalog utils
// Content-derived oracles: assertions compute their expectations from the
// imported manifest tables, never from remembered literals.

/// The catalog's first track — the deck's "press play from idle" target.
const first_track = &model_mod.tracks[0];

/// An independent copy of the search predicate (title, artist, or album,
/// case-insensitive contains), so narrowing assertions check the model's
/// filter against the catalog rather than against itself... with the
/// arithmetic spelled differently enough to catch a broken slice.
fn countMatches(query: []const u8) usize {
    var count: usize = 0;
    for (&model_mod.tracks) |*track| {
        const album = model_mod.albumById(track.album);
        if (std.ascii.indexOfIgnoreCase(track.title, query) != null or
            std.ascii.indexOfIgnoreCase(album.artist, query) != null or
            std.ascii.indexOfIgnoreCase(album.title, query) != null) count += 1;
    }
    return count;
}

/// ASCII-uppercase into a caller buffer (test-side mirror of the VFD's
/// stamping transform).
fn upperBuf(buffer: []u8, source: []const u8) []const u8 {
    for (source, 0..) |byte, index| buffer[index] = std.ascii.toUpper(byte);
    return buffer[0..source.len];
}

/// The composed marquee line for a track, uppercased — the exact string
/// the VFD rotates, derived from the catalog.
fn marqueeLine(buffer: []u8, track: *const model_mod.Track) []const u8 {
    const album = model_mod.albumById(track.album);
    var compose: [192]u8 = undefined;
    const line = std.fmt.bufPrint(&compose, "{s} /// {s} /// {s}  ", .{
        track.title, album.artist, album.title,
    }) catch unreachable;
    return upperBuf(buffer, line);
}

// -------------------------------------------------------------- app utils

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);
const playlist_size = geometry.SizeF.init(view_mod.playlist_width, view_mod.playlist_height);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,

    fn start(image_decode: bool) !LiveApp {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.image_decode = image_decode;

        const app_state = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = App.init(std.heap.page_allocator, .{}, main.deckOptions());
        app_state.effects.executor = .fake;
        try harness.start(app_state.app());
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = surface_size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state };
    }

    fn stop(self: LiveApp) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: LiveApp, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    fn wake(self: LiveApp) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .wake);
    }

    /// Feed one audio event through the fake executor and drain it into
    /// update — the shape a live platform delivers playback reports in.
    fn feedAudio(self: LiveApp, kind: native_sdk.EffectAudioEventKind, position_ms: u64, duration_ms: u64, playing: bool) !void {
        try self.app_state.effects.feedAudioEvent(kind, position_ms, duration_ms, playing);
        try self.wake();
    }

    fn widgetIdByLabel(self: LiveApp, canvas_label: []const u8, window_id: u64, kind: canvas.WidgetKind, label: []const u8) !canvas.ObjectId {
        const layout = try self.harness.runtime.canvasWidgetLayout(window_id, canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind != kind) continue;
            if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.widget.id;
        }
        return error.WidgetNotFound;
    }

    fn widgetAction(self: LiveApp, canvas_label: []const u8, id: canvas.ObjectId, verb: []const u8) !void {
        var command_buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} {s}", .{ canvas_label, id, verb });
        try self.harness.runtime.dispatchAutomationCommand(self.app_state.app(), line);
    }

    /// The pointer path for widgets that are pressable but not focus
    /// targets (the ledger's panel rows).
    fn widgetClick(self: LiveApp, canvas_label: []const u8, id: canvas.ObjectId) !void {
        var command_buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app_state.app(), line);
    }

    fn playlistWindowInfo(self: LiveApp) ?native_sdk.WindowInfo {
        var buffer: [16]native_sdk.WindowInfo = undefined;
        for (self.harness.runtime.listWindows(&buffer)) |info| {
            if (std.mem.eql(u8, info.label, main.playlist_window_label)) return info;
        }
        return null;
    }

    /// Install the playlist canvas (its first gpu frame): declared
    /// windows render nothing until their surface reports in.
    fn installPlaylistCanvas(self: LiveApp, window_id: u64, frame_index: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .{ .gpu_surface_frame = .{
            .window_id = window_id,
            .label = main.playlist_canvas_label,
            .size = playlist_size,
            .scale_factor = 1,
            .frame_index = frame_index,
            .timestamp_ns = frame_index * 1_000_000,
            .nonblank = true,
        } });
    }
};

// ------------------------------------------------------------------ tests

test "the manifest tables derive cleanly: variable per-album counts, unique ids" {
    // The catalog is the committed manifest; the flat tables must cover
    // it exactly, with contiguous 1-based ids and per-album slices that
    // tile the track table (counts VARY — nothing may assume a stride).
    try testing.expectEqual(model_mod.catalog.albums.len, model_mod.albums.len);
    var total: usize = 0;
    for (model_mod.albums, model_mod.catalog.albums, 0..) |album, source, index| {
        try testing.expectEqual(@as(u8, @intCast(index + 1)), album.id);
        try testing.expectEqualStrings(source.title, album.title);
        try testing.expectEqual(source.tracks.len, model_mod.albumTracks(album.id).len);
        for (model_mod.albumTracks(album.id), source.tracks, 1..) |track, source_track, number| {
            try testing.expectEqual(album.id, track.album);
            try testing.expectEqual(@as(u8, @intCast(number)), track.number);
            try testing.expectEqualStrings(source_track.title, track.title);
            try testing.expectEqual(source_track.duration_ms, track.duration_ms);
            // The playable path points at the soundboard's shared assets
            // and ends with the manifest's own file path.
            try testing.expect(std.mem.startsWith(u8, track.path, model_mod.audio_root));
            try testing.expect(std.mem.endsWith(u8, track.path, source_track.file));
            total += 1;
        }
    }
    try testing.expectEqual(total, model_mod.tracks.len);
    for (model_mod.tracks, 1..) |track, id| {
        try testing.expectEqual(@as(u8, @intCast(id)), track.id);
    }
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    apply(&model, .{ .queue_track = model_mod.albumTracks(2)[0].id });

    // The chassis is machined hardware at a fixed size and a pinned
    // compact density, so the sweep runs exactly the geometry the app
    // ships: one size, one density. No text expansion either: the
    // stampings (VOL, the transport glyphs) are engraved hardware
    // lettering machined into fixed wells, not translatable strings —
    // dynamic content (titles, durations) rides the marquee and readout,
    // which clip to their windows by design.
    const chassis_size = geometry.SizeF.init(main.window_width, main.window_height);
    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = chassis_size,
        .default_size = chassis_size,
        .large_size = chassis_size,
        .densities = &.{.compact},
        .text_expansions = &.{1},
    });

    // The NO MEDIA state machines a different VFD (amber marquee stamp
    // plus the caption-pitch remedy line) — sweep it too, so the honest
    // degrade can never clip its own message.
    var failed = Model{};
    failed.media_failed = true;
    const failed_tree = try buildTree(arena_state.allocator(), &failed);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, failed_tree.root, .{
        .tokens = main.tokensFromModel(&failed),
        .min_size = chassis_size,
        .default_size = chassis_size,
        .large_size = chassis_size,
        .densities = &.{.compact},
        .text_expansions = &.{1},
    });

    // The playlist rack window, same fixed-hardware contract.
    const playlist = try buildPlaylistTree(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, playlist.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = playlist_size,
        .default_size = playlist_size,
        .large_size = playlist_size,
        .densities = &.{.compact},
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    apply(&model, .{ .queue_track = model_mod.albumTracks(2)[0].id });

    // Both windows at their fixed hardware geometry: the chassis and
    // the playlist rack.
    const chassis_size = geometry.SizeF.init(main.window_width, main.window_height);
    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = chassis_size,
        .default_size = chassis_size,
        .large_size = chassis_size,
    });

    const playlist = try buildPlaylistTree(arena_state.allocator(), &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, playlist.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = playlist_size,
        .default_size = playlist_size,
        .large_size = playlist_size,
    });
}

test "play, pause, seek, and volume drive the audio effect channel" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Play issues one playAudio: key = track id, path into the shared
    // soundboard assets, the fader's volume applied from the first load.
    try live.dispatch(.{ .play_track = first_track.id });
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, first_track.id), app_state.model.now);
    // The manifest duration is the display default until `.loaded`.
    try testing.expectEqual(first_track.duration_ms, app_state.model.now_duration_ms);
    const request = app_state.effects.pendingAudio().?;
    try testing.expectEqual(@as(u64, first_track.id), request.key);
    try testing.expectEqualStrings(first_track.path, request.path);
    try testing.expect(request.playing);
    try testing.expectEqual(app_state.model.volume_fraction, request.volume);

    // The loaded acknowledgment adopts the platform's decoded duration.
    const decoded_ms: u64 = @as(u64, first_track.duration_ms) + 1_500;
    try live.feedAudio(.loaded, 0, decoded_ms, true);
    try testing.expectEqual(@as(u32, @intCast(decoded_ms)), app_state.model.now_duration_ms);

    // Position ticks are the progress clock.
    try live.feedAudio(.position, 1_500, decoded_ms, true);
    try testing.expectEqual(@as(u32, 1_500), app_state.model.elapsed_ms);

    // Pause holds the platform player (position events stop with it);
    // resume continues on the same channel.
    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.playing);
    try testing.expect(!app_state.effects.audioSnapshot().playing);
    try live.dispatch(.toggle_play);
    try testing.expect(app_state.model.playing);
    try testing.expect(app_state.effects.audioSnapshot().playing);

    // Seek through the real path: a semantic increment steps the runtime's
    // slider, `on-change` dispatches `.seeked`, and the sync hook mirrors
    // the reconciled value into the model before update reads it — which
    // then rides through to the platform player. The deck has two
    // sliders — the label disambiguates.
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    try live.widgetAction(main.canvas_label, seek_id, "increment");
    try testing.expect(app_state.model.seek_fraction > 0);
    const duration: f32 = @floatFromInt(app_state.model.now_duration_ms);
    const expected = app_state.model.seek_fraction * duration;
    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), app_state.effects.audioSnapshot().position_ms);

    // The volume fader mirrors through the same sync hook and lands on
    // the channel.
    const volume_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Volume");
    const volume_before = app_state.model.volume_fraction;
    try live.widgetAction(main.canvas_label, volume_id, "increment");
    try testing.expect(app_state.model.volume_fraction > volume_before);
    try testing.expectEqual(app_state.model.volume_fraction, app_state.effects.pendingAudio().?.volume);
}

test "track end auto-advances; the play-next queue wins over album order" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Queue the LAST album's first track while the first album plays —
    // the ids and counts derive from the manifest.
    const last_album = model_mod.albums[model_mod.albums.len - 1];
    const cued = model_mod.albumTracks(last_album.id)[0];
    try live.dispatch(.{ .play_track = first_track.id });
    try live.dispatch(.{ .queue_track = cued.id });
    try testing.expectEqual(@as(usize, 1), app_state.model.queue_len);

    // Natural end: the platform's one completion event; the queued track
    // starts on a fresh playback (the channel key moves with it).
    try live.feedAudio(.completed, first_track.duration_ms, first_track.duration_ms, false);
    try testing.expectEqual(@as(?u8, cued.id), app_state.model.now);
    try testing.expectEqual(@as(usize, 0), app_state.model.queue_len);
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);
    try testing.expectEqual(@as(u64, cued.id), app_state.effects.pendingAudio().?.key);

    // With an empty queue the album order advances.
    const album_tracks = model_mod.albumTracks(cued.album);
    try live.feedAudio(.completed, cued.duration_ms, cued.duration_ms, false);
    try testing.expectEqual(@as(?u8, album_tracks[1].id), app_state.model.now);

    // next/prev wrap within the album — variable per-album length, so
    // the expectations come from the album's own slice.
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, album_tracks[0].id), app_state.model.now);
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, album_tracks[album_tracks.len - 1].id), app_state.model.now);
    try live.dispatch(.next_track);
    try testing.expectEqual(@as(?u8, album_tracks[0].id), app_state.model.now);
}

test "a failed load clears the deck and stamps the NO MEDIA remedy on the VFD" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // The mp3s are gitignored: on a machine that never ran the prepare
    // script the platform reports one `.failed` event. The deck goes
    // honestly idle — no crash, no silence.
    try live.dispatch(.{ .play_track = first_track.id });
    try live.feedAudio(.failed, 0, 0, false);
    try testing.expect(app_state.model.mediaFailed());
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
    try testing.expect(!app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);

    // The VFD wears the degrade in the hardware voice: the amber NO
    // MEDIA stamp on the marquee, and the channel line names the script
    // that prepares the shared library.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try buildTree(arena, &app_state.model);
    const marquee = findByLabel(tree.root, "Marquee").?;
    try testing.expectEqualStrings(model_mod.no_media_marquee, marquee.text);
    const channel = findByLabel(tree.root, "Channel").?;
    try testing.expectEqualStrings(model_mod.no_media_remedy, channel.text);
    try testing.expect(std.mem.indexOf(u8, channel.text, "TOOLS/PREPARE-EXAMPLE-MUSIC.SH") != null);

    // Browsing and queueing never need the audio files: the committed
    // catalog still fills the ledger and the queue still takes cues.
    const playlist = try buildPlaylistTree(arena, &app_state.model);
    try testing.expectEqual(@as(usize, model_mod.tracks.len), countListItems(playlist.root));
    try live.dispatch(.{ .queue_track = first_track.id });
    try testing.expectEqual(@as(usize, 1), app_state.model.queue_len);

    // Pressing play again is the retry: the failed state clears and a
    // fresh playback request goes out.
    try live.dispatch(.{ .play_track = first_track.id });
    try testing.expect(!app_state.model.mediaFailed());
    try testing.expect(app_state.effects.pendingAudio() != null);
}

test "copy title spawns pbcopy with the track title on stdin" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    const track = &model_mod.tracks[1];
    try live.dispatch(.{ .copy_title = track.id });
    const request = app_state.effects.pendingSpawnAt(0).?;
    try testing.expectEqual(model_mod.copy_key, request.key);
    try testing.expectEqual(@as(usize, 1), request.argv.len);
    try testing.expectEqualStrings("/usr/bin/pbcopy", request.argv[0]);
    try testing.expectEqualStrings(track.title, request.stdin);

    try app_state.effects.feedExit(model_mod.copy_key, 0);
    try live.wake();
    try testing.expectEqual(@as(u32, 1), app_state.model.copies_done);
    try testing.expect(!app_state.model.copy_failed);

    // A failing exit is noted, never fatal.
    try live.dispatch(.{ .copy_title = model_mod.tracks[2].id });
    try app_state.effects.feedExit(model_mod.copy_key, 1);
    try live.wake();
    try testing.expect(app_state.model.copy_failed);
}

test "the rack is one flat song list; search narrows it through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The library lives in the playlist rack: these trees are the
    // secondary window's view, dispatched through the same typed path.
    // ONE flat list — every catalog track is a ledger row, no album rail.
    var model = Model{};
    var tree = try buildPlaylistTree(arena, &model);
    try testing.expectEqual(@as(usize, model_mod.tracks.len), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, first_track.title) != null);
    try testing.expect(findByLabel(tree.root, "Channel bank") == null);

    // Type into the status-strip search field (the markup-declared
    // on-input handler): matches narrow across title/artist/album, and
    // the expected count comes from the catalog through an independent
    // copy of the predicate.
    const query = "violet";
    const expected = countMatches(query);
    try testing.expect(expected > 0 and expected < model_mod.tracks.len);
    const field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(field.id, .{ .insert_text = query }).?);
    try testing.expectEqualStrings(query, model.search());
    tree = try buildPlaylistTree(arena, &model);
    try testing.expectEqual(expected, countListItems(tree.root));

    // The markup clear button (icon-only) resets the query.
    const clear = findByLabel(tree.root, "Clear search").?;
    try testing.expectEqual(canvas.WidgetKind.button, clear.kind);
    try testing.expectEqualStrings("x", clear.icon);
    apply(&model, tree.msgForPointer(clear.id, .up).?);
    try testing.expectEqualStrings("", model.search());

    // No matches renders the NO SIGNAL plate instead of a list.
    try testing.expectEqual(@as(usize, 0), countMatches("polka"));
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("polka");
    tree = try buildPlaylistTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "No tracks match") != null);
    try testing.expect(findByLabel(tree.root, "Track ledger") == null);
}

test "a full session: load from the playlist ledger, queue via the context menu" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var playlist = try buildPlaylistTree(arena, &model);

    // Press a ledger row (a mid-catalog track, derived): the track loads
    // and plays; the player's VFD lights up (marquee live, pause icon on
    // the play key, RUN lamp).
    const load = &model_mod.albumTracks(3)[0];
    const row = findByLabel(playlist.root, load.title).?;
    apply(&model, playlist.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?u8, load.id), model.now);
    try testing.expect(model.playing);
    var player = try buildTree(arena, &model);
    const marquee = findByLabel(player.root, "Marquee").?;
    var title_upper: [192]u8 = undefined;
    const stamped = upperBuf(&title_upper, load.title);
    try testing.expect(std.mem.startsWith(u8, marquee.text, stamped[0..@min(stamped.len, model_mod.marquee_window)]));
    try testing.expectEqualStrings("pause", findByLabel(player.root, "Play or pause").?.icon);
    try testing.expectEqualStrings("skip-back", findByLabel(player.root, "Previous track").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(player.root, "Next track").?.icon);

    // Pressing the loaded row again toggles pause; the power lamp drops
    // back to standby.
    playlist = try buildPlaylistTree(arena, &model);
    const same_row = findByLabel(playlist.root, load.title).?;
    apply(&model, playlist.msgForPointer(same_row.id, .up).?);
    try testing.expect(!model.playing);
    player = try buildTree(arena, &model);
    try testing.expect(findByText(player.root, .text, "STBY") != null);
    try testing.expectEqualStrings("play", findByLabel(player.root, "Play or pause").?.icon);

    // Context-menu items dispatch typed messages: Play Next queues (the
    // amber Q plate appears in the ledger, the cue strip names the
    // track, the player's queue badge counts it), indexes past the
    // declared items are inert.
    const cued = &model_mod.albumTracks(2)[1];
    playlist = try buildPlaylistTree(arena, &model);
    const cue_row = findByLabel(playlist.root, cued.title).?;
    apply(&model, playlist.msgForContextMenu(cue_row.id, 0).?);
    try testing.expectEqual(@as(usize, 1), model.queue_len);
    try testing.expectEqual(cued.id, model.queue[0]);
    try testing.expect(playlist.msgForContextMenu(cue_row.id, 2) == null);
    playlist = try buildPlaylistTree(arena, &model);
    try testing.expect(findByText(playlist.root, .badge, "Q") != null);
    try testing.expect(findByText(playlist.root, .badge, "QUEUE 1") != null);
    // The cue plate stamps the number and the uppercased title (cut at
    // the plate's fixed budget, like hardware would).
    var plate_upper: [192]u8 = undefined;
    var plate_buffer: [64]u8 = undefined;
    const plate_title = upperBuf(&plate_upper, cued.title[0..@min(cued.title.len, view_mod.cue_title_max)]);
    const plate = try std.fmt.bufPrint(&plate_buffer, "{d:0>2} {s}", .{ cued.id, plate_title });
    try testing.expect(findByText(playlist.root, .badge, plate) != null);
    player = try buildTree(arena, &model);
    try testing.expect(findByText(player.root, .badge, "QUEUE 1") != null);
}

test "shortcut commands map to transport and playlist messages" {
    // The command table is the keyboard map (app.zon holds the same ids).
    try testing.expectEqual(Msg.toggle_play, main.command(main.cmd_play_pause).?);
    try testing.expectEqual(Msg.next_track, main.command(main.cmd_next).?);
    try testing.expectEqual(Msg.prev_track, main.command(main.cmd_prev).?);
    try testing.expectEqual(Msg.toggle_playlist, main.command(main.cmd_playlist).?);
    try testing.expectEqual(Msg.clear_search, main.command(main.cmd_dismiss).?);
    try testing.expect(main.command("deck.unknown") == null);

    // primary+L racks the playlist in and out; escape clears the query.
    var model = Model{};
    apply(&model, main.command(main.cmd_playlist).?);
    try testing.expect(model.playlist_open);
    apply(&model, main.command(main.cmd_playlist).?);
    try testing.expect(!model.playlist_open);
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("harbor");
    apply(&model, main.command(main.cmd_dismiss).?);
    try testing.expectEqualStrings("", model.search());
}

test "the playlist window round-trips through real dispatch" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    try testing.expect(live.playlistWindowInfo() == null);

    // Open through the REAL press path: the PL key via the automation
    // widget verb. The windows_fn reconcile creates the window.
    const pl_id = try live.widgetIdByLabel(main.canvas_label, 1, .toggle_button, "Playlist window");
    try live.widgetAction(main.canvas_label, pl_id, "toggle");
    try testing.expect(app_state.model.playlist_open);
    const info = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    try testing.expect(info.open);
    try testing.expectEqualStrings("Deck Playlist", info.title);

    // The playlist canvas installs on its own first frame; the ledger
    // then answers automation verbs addressed at its canvas label —
    // loading a track from the rack drives the player (one model).
    try live.installPlaylistCanvas(info.id, 2);
    const row_id = try live.widgetIdByLabel(main.playlist_canvas_label, info.id, .panel, first_track.title);
    try live.widgetClick(main.playlist_canvas_label, row_id);
    try testing.expectEqual(@as(?u8, first_track.id), app_state.model.now);
    try testing.expect(app_state.model.playing);

    // Close by Msg (the PL key again): the model stops declaring the
    // window and the reconcile closes it — no user-close Msg fires.
    const pl_again = try live.widgetIdByLabel(main.canvas_label, 1, .toggle_button, "Playlist window");
    try live.widgetAction(main.canvas_label, pl_again, "toggle");
    try testing.expect(!app_state.model.playlist_open);
    const closed = live.playlistWindowInfo();
    try testing.expect(closed == null or !closed.?.open);

    // Reopen (same label), then close as the USER (the fake host tears
    // the window down like the real delegates do and reports it gone):
    // the open=false event dispatches `.playlist_closed` and the model
    // clears its flag — the window stays closed.
    try live.dispatch(.toggle_playlist);
    try testing.expect(app_state.model.playlist_open);
    const reopened = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    const close_event = live.harness.null_platform.userCloseWindow(reopened.id).?;
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), close_event);
    try testing.expect(!app_state.model.playlist_open);
    const user_closed = live.playlistWindowInfo();
    try testing.expect(user_closed == null or !user_closed.?.open);
}

test "boot registers the textures; the JPEG covers degrade under the strict decoder" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // init_fx ran on the installing frame; both strict-subset PNG
    // textures decoded and registered. The album covers are committed
    // JPEG — live macOS decodes them through the platform codec, but the
    // null platform's strict test decoder refuses them, so every cover
    // slot stays 0 and the count holds at the two textures. This test
    // pins the DEGRADE, not a successful decode.
    try testing.expectEqual(@as(usize, 2), live.harness.runtime.registeredCanvasImageCount());
    try testing.expectEqual(main.plate_texture_id, app_state.model.texture_plate);
    try testing.expectEqual(main.weave_texture_id, app_state.model.texture_weave);
    for (app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }

    // The chrome pass carries the plate texture as an onscreen
    // draw_image (offscreen while unregistered or in high contrast).
    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try chrome.build(&app_state.model, &builder, surface_size, main.tokensFromModel(&app_state.model));
    var plate_draws: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_image => |draw| {
                try testing.expectEqual(main.plate_texture_id, draw.image_id);
                try testing.expect(draw.dst.x < main.window_width);
                plate_draws += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), plate_draws);

    // The playlist rack's backdrop is an image leaf wearing the weave,
    // and the sleeve pane — with no decoded cover — degrades to its
    // engraved vector plate, idle and loaded alike.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tree = try buildPlaylistTree(arena_state.allocator(), &app_state.model);
    const backdrop = findByLabel(tree.root, "Weave backdrop").?;
    try testing.expectEqual(canvas.WidgetKind.image, backdrop.kind);
    try testing.expectEqual(main.weave_texture_id, backdrop.image_id);
    const idle_sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.panel, idle_sleeve.kind);
    try live.dispatch(.{ .play_track = first_track.id });
    tree = try buildPlaylistTree(arena_state.allocator(), &app_state.model);
    const loaded_sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.panel, loaded_sleeve.kind);
}

test "the sleeve pane wears the registered cover once a decode succeeds" {
    // The live path in miniature: hand the model a registered cover id
    // (what boot does on a platform with a JPEG codec) and the sleeve
    // becomes an image leaf bound to the loaded album's cover.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    const album_index: usize = first_track.album - 1;
    model.covers[album_index] = main.coverImageId(first_track.album);
    const tree = try buildPlaylistTree(arena_state.allocator(), &model);
    const sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.image, sleeve.kind);
    try testing.expectEqual(main.coverImageId(first_track.album), sleeve.image_id);
}

test "a codec-less platform keeps the chrome pure vector, never broken" {
    const live = try LiveApp.start(false);
    defer live.stop();
    const app_state = live.app_state;

    try testing.expectEqual(@as(usize, 0), live.harness.runtime.registeredCanvasImageCount());
    try testing.expectEqual(@as(canvas.ImageId, 0), app_state.model.texture_plate);
    try testing.expectEqual(@as(canvas.ImageId, 0), app_state.model.texture_weave);
    for (app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }

    // Fixed-count contract: the texture command still exists, offscreen.
    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try chrome.build(&app_state.model, &builder, surface_size, main.tokensFromModel(&app_state.model));
    try testing.expectEqual(chrome.prefix_commands + chrome.suffix_commands, builder.displayList().commands.len);
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_image => |draw| try testing.expect(draw.dst.x >= main.window_width),
            else => {},
        }
    }
}

test "the spectrum is a deterministic function of the playback clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Idle: the powered-on noise floor, not a dead widget.
    var idle_model = Model{};
    const idle_levels = idle_model.spectrumLevels(arena);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), idle_levels.len);
    for (idle_levels) |level| try testing.expect(level <= 0.05);

    // Live: fed position events are the only thing that advances the
    // clock, and the same (track id, elapsed ms) always yields the same
    // bars.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const track = model_mod.albumTracks(2)[0];
    try live.dispatch(.{ .play_track = track.id });
    try live.feedAudio(.position, 4_200, track.duration_ms, true);
    try testing.expectEqual(@as(u32, 4_200), app_state.model.elapsed_ms);
    const first = app_state.model.spectrumLevels(arena);
    const second = app_state.model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, first, second);
    for (first) |level| {
        try testing.expect(level >= 0);
        try testing.expect(level <= 1);
    }

    // Pause freezes the bars: position events stop, the clock holds.
    try live.dispatch(.toggle_play);
    const paused = app_state.model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, first, paused);

    // Resume; the next position tick moves them.
    try live.dispatch(.toggle_play);
    try live.feedAudio(.position, 4_700, track.duration_ms, true);
    const advanced = app_state.model.spectrumLevels(arena);
    try testing.expect(!std.mem.eql(f32, first, advanced));

    // A different track reshapes the comb (per-track seed) — pure model,
    // same clock value.
    var other = Model{};
    apply(&other, .{ .play_track = model_mod.albumTracks(4)[0].id });
    other.elapsed_ms = 4_200;
    try testing.expect(!std.mem.eql(f32, first, other.spectrumLevels(arena)));

    // The tree carries the levels as ONE chart widget: phosphor bar bands
    // plus the paper-white peak trace, over an honest 0..1 domain.
    const tree = try buildTree(arena, &app_state.model);
    const chart = findByLabel(tree.root, "Spectrum analyzer").?;
    try testing.expectEqual(canvas.WidgetKind.chart, chart.kind);
    try testing.expectEqual(@as(usize, 2), chart.chart.series.len);
    try testing.expectEqual(canvas.ChartSeriesKind.bar, chart.chart.series[0].kind);
    try testing.expectEqual(canvas.ChartSeriesColor.accent, chart.chart.series[0].color);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), chart.chart.series[0].values.len);
    try testing.expectEqual(canvas.ChartSeriesKind.line, chart.chart.series[1].kind);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), chart.chart.series[1].values.len);
    try testing.expectEqual(@as(?f32, 0), chart.chart.y_min);
    try testing.expectEqual(@as(?f32, 1), chart.chart.y_max);
}

test "the marquee is a deterministic scroller on the playback clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Idle: the no-signal readout, static.
    var model = Model{};
    try testing.expectEqualStrings("NO SIGNAL", model.marqueeText(arena));

    // Loaded: a fixed window of the rotating TITLE /// ARTIST /// ALBUM
    // line — pure over (track id, elapsed ms), like the spectrum. The
    // expected text derives from the catalog's first album through the
    // same uppercase stamping the VFD applies.
    var line_buffer: [192]u8 = undefined;
    const full = marqueeLine(&line_buffer, first_track);
    try testing.expect(full.len > model_mod.marquee_window);
    apply(&model, .{ .play_track = first_track.id });
    const at_zero = model.marqueeText(arena);
    try testing.expectEqual(@as(usize, model_mod.marquee_window), at_zero.len);
    try testing.expectEqualStrings(full[0..model_mod.marquee_window], at_zero);
    try testing.expectEqualStrings(at_zero, model.marqueeText(arena));

    // One marquee step rotates by exactly one character.
    model.elapsed_ms = model_mod.marquee_step_ms;
    const at_one = model.marqueeText(arena);
    try testing.expect(!std.mem.eql(u8, at_zero, at_one));
    try testing.expectEqualStrings(at_zero[1..], at_one[0 .. at_one.len - 1]);

    // Pause freezes the scroll (the position events stop, so the clock
    // stops with them).
    apply(&model, .toggle_play);
    try testing.expectEqualStrings(at_one, model.marqueeText(arena));

    // The rotation wraps: a full line length of steps returns home.
    model.elapsed_ms = @intCast(model_mod.marquee_step_ms * full.len);
    try testing.expectEqualStrings(at_zero, model.marqueeText(arena));
}

test "the skin is dark-only; high contrast abandons it for the framework palette" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Default appearance (light OS scheme): still the chassis palette —
    // hardware has no light mode.
    try testing.expectEqualDeep(theme.chassis_colors, main.tokensFromModel(&app_state.model).colors);
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.chassis_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.chassis_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // The skin's control plating is live (squared slider, plate buttons).
    const tokens = try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label);
    try testing.expectEqual(@as(?f32, 1), tokens.controls.slider.radius);
    try testing.expectEqual(@as(f32, 2), tokens.radius.md);
    try testing.expectEqual(canvas.Density.compact, tokens.density);

    // High contrast: accessibility beats brand — framework palette and
    // stock control chrome.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light, .high_contrast = true } });
    const hc = try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label);
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastDark(), hc.colors);
    try testing.expectEqual(@as(?f32, null), hc.controls.slider.radius);
}

test "markup engine parity: the status strip builds identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .play_track = model_mod.tracks[2].id });
    apply(&model, .{ .queue_track = model_mod.tracks[3].id });
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("light");

    var interpreter = try canvas.MarkupView(Model, Msg).init(arena, view_mod.statusbar_markup);
    var compiled_ui = Ui.init(arena);
    const compiled = try compiled_ui.finalize(view_mod.CompiledStatusBarView.build(&compiled_ui, &model));
    var interpreted_ui = Ui.init(arena);
    const interpreted = try interpreted_ui.finalize(try interpreter.build(&interpreted_ui, &model));

    var compiled_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer compiled_ids.deinit(testing.allocator);
    var interpreted_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer interpreted_ids.deinit(testing.allocator);
    try collectIds(compiled.root, &compiled_ids, testing.allocator);
    try collectIds(interpreted.root, &interpreted_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, interpreted_ids.items, compiled_ids.items);
    try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

test "automation click-through: the transport drives the deck" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Press play through the real automation path: focus + key dispatch
    // through the widget route, exactly what `native automate` does.
    // From idle, the transport loads the catalog's first track.
    const play_id = try live.widgetIdByLabel(main.canvas_label, 1, .button, "Play or pause");
    try live.widgetAction(main.canvas_label, play_id, "press");
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, first_track.id), app_state.model.now);

    // Next/prev through the same path (ids can change across rebuilds:
    // re-resolve after each dispatch); the expected neighbors come from
    // the first album's own slice.
    const album_tracks = model_mod.albumTracks(first_track.album);
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Next track"), "press");
    try testing.expectEqual(@as(?u8, album_tracks[1].id), app_state.model.now);
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Previous track"), "press");
    try testing.expectEqual(@as(?u8, album_tracks[0].id), app_state.model.now);

    // Pause through the play key again.
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Play or pause"), "press");
    try testing.expect(!app_state.model.playing);
}

test "the chrome pass holds its exact command counts across model states" {
    // The chrome contract requires exactly prefix+suffix commands per
    // build; state-dependent marks move offscreen instead of dropping
    // out. Rebuild across the states that steer the pass: idle (no
    // textures yet), playing mid-song with textures registered, the NO
    // MEDIA degrade, and high contrast.
    var states = [_]Model{ .{}, .{}, .{}, .{} };
    states[1].now = model_mod.albumTracks(2)[0].id;
    states[1].playing = true;
    states[1].elapsed_ms = 84_500;
    states[1].now_duration_ms = model_mod.albumTracks(2)[0].duration_ms;
    states[1].texture_plate = main.plate_texture_id;
    states[1].texture_weave = main.weave_texture_id;
    states[2].media_failed = true;
    states[2].texture_plate = main.plate_texture_id;
    states[3].appearance = .{ .high_contrast = true };
    states[3].texture_plate = main.plate_texture_id;

    for (&states) |*model| {
        var commands: [1024]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try chrome.build(model, &builder, surface_size, main.tokensFromModel(model));
        try testing.expectEqual(chrome.prefix_commands + chrome.suffix_commands, builder.displayList().commands.len);
    }
}

test "both windows lay out within their fixed canvases and the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    apply(&model, .{ .queue_track = model_mod.albumTracks(2)[0].id });
    model.playlist_open = true;

    // The player: a dense fixed 460x180 chassis.
    {
        const tree = try buildTree(arena_state.allocator(), &model);
        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
        try testing.expect(layout.nodes.len > 0);
        try testing.expect(layout.nodes.len < 128); // just the player
        _ = arena_state.reset(.retain_capacity);
    }

    // The playlist rack: the full flat ledger (every catalog track) and
    // a narrowed one, at 460x440.
    const queries = [_][]const u8{ "", "violet" };
    for (queries) |query| {
        model.search_buffer = canvas.TextBuffer(model_mod.max_search).init(query);
        const tree = try buildPlaylistTree(arena_state.allocator(), &model);
        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, view_mod.playlist_width, view_mod.playlist_height), &nodes);
        try testing.expect(layout.nodes.len > 0);
        try testing.expect(layout.nodes.len < 768); // three quarters of the 1024 budget
        _ = arena_state.reset(.retain_capacity);
    }
}

// Env-gated screenshot renderer (skipped by default, never in CI): renders
// the deck OFFSCREEN through the deterministic reference renderer via the
// automation screenshot artifact — no live window. PNGs land in
// /tmp/deck-shots/deck-*-artifacts/. To use:
//
//   DECK_SHOTS=1 zig build test
test "render deck screenshots (env-gated)" {
    if (!envGateSet("DECK_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // The live macOS chrome inset (traffic lights on the gold band):
    // the offscreen renderer has no host to deliver it, so the shots
    // dispatch the same Msg `on_chrome` would.
    try live.dispatch(.{ .set_chrome_leading = 70 });

    // Idle player: STBY lamp, dashed segments, noise-floor spectrum.
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-idle-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // Playing mid-song, one queued cue. The mid-song position comes from
    // REAL seek steps on the fader (the widget keyboard path), so the
    // fader, the VFD progress strip, and the timecode all agree.
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    try live.dispatch(.{ .queue_track = model_mod.albumTracks(2)[3].id });
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    for (0..8) |_| try live.widgetAction(main.canvas_label, seek_id, "increment");
    try presentShotFrame(live, 3);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-playing-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // The playlist rack, racked in through the real toggle.
    try live.dispatch(.toggle_playlist);
    const info = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    try live.installPlaylistCanvas(info.id, 4);
    try presentShotFrame(live, 5);
    try live.installPlaylistCanvas(info.id, 6);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-playlist-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot playlist-canvas 2");
}

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): renders the docs-homepage showcase state OFFSCREEN through the
// deterministic reference renderer — the chassis with a track playing
// mid-song and one queued cue, then the playlist rack racked in through
// the real PL toggle. Deck is dark-only by design, so unlike the other
// homepage shots there is exactly one capture per window. PNGs land in
// /tmp/homepage-shots/deck-dark-artifacts/ and
// /tmp/homepage-shots/deck-playlist-dark-artifacts/. To use:
//
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // The hero state: a track playing mid-song, one queued cue, the full
    // ledger selected. The mid-song position comes from REAL seek steps
    // on the fader (the widget keyboard path), so the fader, the VFD
    // progress strip, and the timecode all agree.
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    try live.dispatch(.{ .queue_track = model_mod.albumTracks(2)[3].id });
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    for (0..8) |_| try live.widgetAction(main.canvas_label, seek_id, "increment");
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/deck-dark-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // The playlist rack in the same state, racked in through the real
    // toggle — the homepage shows it stacked under the chassis as the
    // expanded state.
    try live.dispatch(.toggle_playlist);
    const info = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    try live.installPlaylistCanvas(info.id, 3);
    try presentShotFrame(live, 4);
    try live.installPlaylistCanvas(info.id, 5);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/deck-playlist-dark-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot playlist-canvas 2");
}

fn presentShotFrame(live: LiveApp, frame_index: u64) !void {
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = surface_size,
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}
