//! deck tests: typed dispatch through both windows' trees (the fixed
//! player and the model-declared playlist rack), real playback through
//! the audio effect channel's fake executor (request/feed round trips,
//! the five-key transport, auto-advance, the honest NO MEDIA degrade),
//! the pbcopy spawn, the spectrum's journaled band reports through the
//! analyzer envelope (instant attack, frame-clock decay, freeze on
//! pause, resting comb for idle/stop/no-analysis), marquee determinism
//! on the rendered clock (frame-clock advance while playing, freeze on
//! pause/stop, position ticks as the correcting truth), the
//! skin-native window keys (close /
//! minimize on the chromeless windows, through the window-action
//! effects), the image channel (the JPEG covers' pinned degrade under
//! the strict decoder, codec-less fallback), the playlist window's full
//! round-trip through real dispatch, the one-finish theming contract,
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
    // The stop key's `app:stop` icon resolves through the registered
    // table; installing it here keeps standalone tree builds warning-free
    // (registration is idempotent — one global table).
    main.registerIcons();
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

/// ASCII-uppercase into a caller buffer (test-side mirror of the display's
/// stamping transform).
fn upperBuf(buffer: []u8, source: []const u8) []const u8 {
    for (source, 0..) |byte, index| buffer[index] = std.ascii.toUpper(byte);
    return buffer[0..source.len];
}

/// The composed marquee line for a track, uppercased — the exact string
/// the display rotates, derived from the catalog.
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
        // The app's icon table (the stop key's square) installs exactly
        // the way main does it, so `app:stop` resolves in tests too.
        main.registerIcons();
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

    /// Feed one `.spectrum` band report — the shape a live host's
    /// analysis tap delivers (~25 Hz while audio is audibly playing).
    fn feedSpectrum(self: LiveApp, bands: [native_sdk.platform.audio_spectrum_band_count]u8, position_ms: u64, duration_ms: u64) !void {
        try self.app_state.effects.feedAudioSpectrum(bands, position_ms, duration_ms);
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

    /// One raw key_down through the REAL gpu input path on a chosen
    /// window/view — the same event a physical key press produces (key
    /// name plus the inserted text, when the key types one).
    fn keyDown(self: LiveApp, window_id: u64, canvas_label: []const u8, name: []const u8, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .{ .gpu_surface_input = .{
            .window_id = window_id,
            .label = canvas_label,
            .kind = .key_down,
            .key = name,
            .text = text,
        } });
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

    // The NO MEDIA state machines a different display face (amber marquee stamp
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

    // The playlist rack window, same fixed-hardware contract — and the
    // same no-text-expansion rationale as the player: the rack's
    // captions and per-row readouts (numbers, durations) are machined
    // stampings in fixed column slots, and the dynamic content (titles,
    // artists) elides at its column edge by design.
    const playlist = try buildPlaylistTree(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, playlist.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = playlist_size,
        .default_size = playlist_size,
        .large_size = playlist_size,
        .densities = &.{.compact},
        .text_expansions = &.{1},
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });

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
    // The manifest duration is the displayed total for the whole
    // playback — the same number the ledger renders.
    try testing.expectEqual(first_track.duration_ms, app_state.model.now_duration_ms);
    const request = app_state.effects.pendingAudio().?;
    try testing.expectEqual(@as(u64, first_track.id), request.key);
    try testing.expectEqualStrings(first_track.path, request.path);
    try testing.expect(request.playing);
    try testing.expectEqual(app_state.model.volume_fraction, request.volume);

    // The loaded acknowledgment's duration report is an estimate for
    // this catalog (the prepared files ship without a seek header): it
    // lands in the mirror and the displayed total keeps the manifest
    // value — the duration rule on `handleAudio`.
    const decoded_ms: u64 = @as(u64, first_track.duration_ms) + 1_500;
    try live.feedAudio(.loaded, 0, decoded_ms, true);
    try testing.expectEqual(first_track.duration_ms, app_state.model.now_duration_ms);
    try testing.expectEqual(@as(u32, @intCast(decoded_ms)), app_state.model.platform_duration_ms);

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

    // A rail click on the seek fader is the pointer twin of the
    // increment above: the runtime jumps the thumb to the pressed
    // point, `on_change` dispatches `.seeked`, and the player seeks to
    // the proportional position — the standard scrubber jump, through
    // the REAL pointer pipeline.
    const seek_rail = blk: {
        const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind != .slider) continue;
            if (std.mem.eql(u8, node.widget.semantics.label, "Seek")) break :blk node.frame.normalized();
        }
        return error.WidgetNotFound;
    };
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .pointer_down,
        .x = seek_rail.x + seek_rail.width * 0.75,
        .y = seek_rail.y + seek_rail.height / 2,
    } });
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .pointer_up,
        .x = seek_rail.x + seek_rail.width * 0.75,
        .y = seek_rail.y + seek_rail.height / 2,
    } });
    try testing.expectApproxEqAbs(@as(f32, 0.75), app_state.model.seek_fraction, 0.001);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), app_state.effects.audioSnapshot().position_ms);
    try testing.expectApproxEqAbs(0.75 * duration, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
}

test "a divergent platform duration never moves the deck's total off the manifest" {
    // Regression twin of the soundboard pin (one catalog, one rule):
    // the timecode total used to adopt the platform player's duration
    // report while the ledger rendered the manifest value, so the same
    // track showed two lengths at once. The platform's number is an
    // estimate for this catalog (the prepared files ship without a seek
    // header); the manifest total drives the timecode, the progress
    // fraction, and the seek scale — the duration rule on `handleAudio`.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.{ .play_track = first_track.id });
    const estimate_ms: u64 = @as(u64, first_track.duration_ms) + 104_000;
    try live.feedAudio(.loaded, 0, estimate_ms, true);
    try live.feedAudio(.position, 30_000, estimate_ms, true);

    // The displayed total stays the manifest value; the estimate is
    // observable in the mirror only.
    try testing.expectEqual(first_track.duration_ms, app_state.model.now_duration_ms);
    try testing.expectEqual(@as(u32, @intCast(estimate_ms)), app_state.model.platform_duration_ms);

    // The two surfaces agree: the timecode's total is the exact string
    // the ledger renders for the same track.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = app_state.model.visibleTracks(arena);
    try testing.expectEqual(first_track.id, rows[0].id);
    try testing.expectEqualStrings(rows[0].duration, app_state.model.durationLabel(arena));

    // The progress fraction is elapsed over the MANIFEST total.
    const manifest_total: f32 = @floatFromInt(first_track.duration_ms);
    try testing.expectApproxEqAbs(30_000.0 / manifest_total, app_state.model.progressFraction(), 0.0001);

    // A seek lands on the same scale the display renders.
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    try live.widgetAction(main.canvas_label, seek_id, "increment");
    try testing.expect(app_state.model.seek_fraction > 0);
    const expected_target = app_state.model.seek_fraction * manifest_total;
    try testing.expectApproxEqAbs(expected_target, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), app_state.effects.audioSnapshot().position_ms);

    // Restarting a track resets the mirror with the rest of the
    // playback state.
    try live.dispatch(.{ .play_track = first_track.id + 1 });
    try testing.expectEqual(@as(u32, 0), app_state.model.platform_duration_ms);
    try testing.expectEqual(model_mod.trackById(first_track.id + 1).duration_ms, app_state.model.now_duration_ms);
}

test "track end auto-advances in ledger order; next/prev wrap the flat catalog" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Natural end: the platform's one completion event; the NEXT LEDGER
    // ROW plays on a fresh playback (the channel key moves with it) —
    // the playlist's flat catalog order is the play order.
    try live.dispatch(.{ .play_track = first_track.id });
    try live.feedAudio(.completed, first_track.duration_ms, first_track.duration_ms, false);
    const second = model_mod.trackById(first_track.id + 1);
    try testing.expectEqual(@as(?u8, second.id), app_state.model.now);
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);
    try testing.expectEqual(@as(u64, second.id), app_state.effects.pendingAudio().?.key);

    // The album seam: completing the first album's LAST track flows
    // into the next album's first row — the ledger has no album walls
    // (the flat table tiles the albums in order, so the neighbor ids
    // derive from the album's own slice).
    const first_album_tracks = model_mod.albumTracks(1);
    const last_of_first = first_album_tracks[first_album_tracks.len - 1];
    try live.dispatch(.{ .play_track = last_of_first.id });
    try live.feedAudio(.completed, last_of_first.duration_ms, last_of_first.duration_ms, false);
    try testing.expectEqual(@as(?u8, last_of_first.id + 1), app_state.model.now);
    try testing.expectEqual(@as(u8, 2), model_mod.trackById(last_of_first.id + 1).album);

    // The wrap: the catalog's last row advances back to the first.
    const last_track = &model_mod.tracks[model_mod.tracks.len - 1];
    try live.dispatch(.{ .play_track = last_track.id });
    try live.feedAudio(.completed, last_track.duration_ms, last_track.duration_ms, false);
    try testing.expectEqual(@as(?u8, model_mod.tracks[0].id), app_state.model.now);

    // next/prev walk the same flat order and wrap both ways (prev from
    // a fresh start — under the restart threshold — steps back).
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, last_track.id), app_state.model.now);
    try live.dispatch(.next_track);
    try testing.expectEqual(@as(?u8, model_mod.tracks[0].id), app_state.model.now);
}

test "streaming resolution order drives the display honestly: stream, buffer, cache" {
    // The source cascade against the null platform's fake player with
    // the REAL executor — the deck's version of the soundboard's
    // resolution-order proof, told in the display's voice.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const np = &live.harness.null_platform;
    fx.executor = .real;
    app_state.model.setUrlBase("https://music.example.test/pack");
    app_state.model.setCacheDir("/tmp/fake-caches/deck");
    np.audio_local_files = false;

    // The shared assets are absent, a URL base is configured: the play
    // streams on demand instead of failing.
    try live.dispatch(.{ .play_track = first_track.id });
    try testing.expectEqual(native_sdk.EffectAudioSource.stream, fx.audioSnapshot().source);
    var url_buffer: [512]u8 = undefined;
    const expected_url = try std.fmt.bufPrint(&url_buffer, "https://music.example.test/pack/{s}", .{first_track.file});
    try testing.expectEqualStrings(expected_url, np.audio.path());

    // A stalled stream stamps BUFFERING on the marquee — the honest
    // third state between playing and paused.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.stallAudio().?);
    try testing.expect(app_state.model.buffering);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buffering_tree = try buildTree(arena, &app_state.model);
    const marquee = findByLabel(buffering_tree.root, "Marquee").?;
    try testing.expectEqualStrings(model_mod.buffering_marquee, marquee.text);

    // Bytes flow again; completion installs the fake cache entry, the
    // deck auto-advances (a fresh stream), and replaying the finished
    // track resolves from cache — local playback, no network.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.takeAudioLoaded().?);
    try testing.expect(!app_state.model.buffering);
    const duration = np.audio.duration_ms;
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.advanceAudio(duration).?);
    try testing.expect(app_state.model.now != null);
    try testing.expect(app_state.model.now.? != first_track.id);
    try live.dispatch(.{ .play_track = first_track.id });
    try testing.expectEqual(native_sdk.EffectAudioSource.cache, fx.audioSnapshot().source);
}

test "streaming is the committed default; the launch override replaces it" {
    // The deck's manifest copy ships the same hosted .url_base as the
    // soundboard's, so a fresh clone streams with zero setup: a bare
    // model boots with the manifest value installed. setUrlBase —
    // main's launch path for NATIVE_SDK_MUSIC_URL_BASE — replaces it
    // wholesale (trailing slash trimmed), and the empty override is the
    // one honest way to the local-only NO MEDIA state.
    var model = Model{};
    try testing.expect(model_mod.manifest_url_base.len > 0);
    try testing.expectEqualStrings(model_mod.manifest_url_base, model.urlBase());
    try testing.expect(model.streamingConfigured());
    model.setUrlBase("http://127.0.0.1:8000/pack/");
    try testing.expectEqualStrings("http://127.0.0.1:8000/pack", model.urlBase());
    model.setUrlBase("");
    try testing.expect(!model.streamingConfigured());
}

test "a dead stream stamps STREAM LOST, not the prepare-script remedy" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const np = &live.harness.null_platform;
    app_state.effects.executor = .real;
    app_state.model.setUrlBase("https://music.example.test/pack");
    app_state.model.setCacheDir("/tmp/fake-caches/deck");
    np.audio_local_files = false;

    try live.dispatch(.{ .play_track = first_track.id });
    // Offline with a cold cache: the stream dies with one `.failed`
    // event. With a URL base configured the prepare-script remedy
    // would be a lie — the display names the network instead.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.failAudio().?);
    try testing.expect(app_state.model.stream_failed);
    try testing.expect(!app_state.model.media_failed);
    try testing.expect(app_state.model.mediaFailed());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try buildTree(arena, &app_state.model);
    const marquee = findByLabel(tree.root, "Marquee").?;
    try testing.expectEqualStrings(model_mod.stream_failed_marquee, marquee.text);
    const channel = findByLabel(tree.root, "Channel").?;
    try testing.expectEqualStrings(model_mod.stream_failed_remedy, channel.text);

    // Pressing play again is the retry, exactly like NO MEDIA.
    try live.dispatch(.{ .play_track = first_track.id });
    try testing.expect(!app_state.model.mediaFailed());
}

test "a failed load clears the deck and stamps the NO MEDIA remedy on the display" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // The committed manifest ships a hosted streaming default, so the
    // NO MEDIA state is reachable only with the URL base cleared — the
    // state NATIVE_SDK_MUSIC_URL_BASE set empty produces at launch.
    app_state.model.setUrlBase("");

    // The mp3s are gitignored: on a machine with no prepared audio and
    // streaming disabled the platform reports one `.failed` event. The
    // deck goes honestly idle — no crash, no silence.
    try live.dispatch(.{ .play_track = first_track.id });
    try live.feedAudio(.failed, 0, 0, false);
    try testing.expect(app_state.model.mediaFailed());
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
    try testing.expect(!app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);

    // The display wears the degrade in the hardware voice: the amber NO
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

    // Browsing and searching never need the audio files: the committed
    // catalog still fills the ledger.
    const playlist = try buildPlaylistTree(arena, &app_state.model);
    try testing.expectEqual(@as(usize, model_mod.tracks.len), countListItems(playlist.root));

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

test "a full session: load from the playlist ledger, copy via the context menu" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var playlist = try buildPlaylistTree(arena, &model);

    // Press a ledger row (a mid-catalog track, derived): the track loads
    // and plays; the player's display lights up (marquee live, RUN lamp)
    // and the five transport keys wear their hardware glyphs — the stop
    // square is the app-registered icon.
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
    try testing.expect(findByText(player.root, .text, "RUN") != null);
    try testing.expectEqualStrings("skip-back", findByLabel(player.root, "Previous track").?.icon);
    try testing.expectEqualStrings("play", findByLabel(player.root, "Play").?.icon);
    try testing.expectEqualStrings("pause", findByLabel(player.root, "Pause").?.icon);
    try testing.expectEqualStrings("app:stop", findByLabel(player.root, "Stop").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(player.root, "Next track").?.icon);

    // The deck strip stamps the loaded record beside the sleeve — the
    // uppercased title in the silkscreen ink (the ledger above is the
    // play order, so the strip states only what the deck holds now).
    playlist = try buildPlaylistTree(arena, &model);
    var stamp_upper: [192]u8 = undefined;
    try testing.expect(findByText(playlist.root, .text, upperBuf(&stamp_upper, load.title)) != null);

    // Pressing the loaded row again toggles pause; the power lamp drops
    // back to standby.
    const same_row = findByLabel(playlist.root, load.title).?;
    apply(&model, playlist.msgForPointer(same_row.id, .up).?);
    try testing.expect(!model.playing);
    player = try buildTree(arena, &model);
    try testing.expect(findByText(player.root, .text, "STBY") != null);

    // The per-row context menu carries ONE item — Copy Title dispatches
    // the typed copy Msg — and indexes past the declared items are
    // inert.
    const copied = &model_mod.albumTracks(2)[1];
    playlist = try buildPlaylistTree(arena, &model);
    const copy_row = findByLabel(playlist.root, copied.title).?;
    try testing.expectEqual(Msg{ .copy_title = copied.id }, playlist.msgForContextMenu(copy_row.id, 0).?);
    try testing.expect(playlist.msgForContextMenu(copy_row.id, 1) == null);
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

test "the JPEG covers degrade under the strict decoder; the art surfaces stay plates" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // init_fx ran on the installing frame. The album covers are the only
    // images this app registers, and they are committed JPEG — live
    // macOS decodes them through the platform codec, but the null
    // platform's strict test decoder refuses them, so every cover slot
    // stays 0 and the registry stays empty. This test pins the DEGRADE,
    // not a successful decode.
    try testing.expectEqual(@as(usize, 0), live.harness.runtime.registeredCanvasImageCount());
    for (app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }

    // The skin is pure vector by design: the chrome pass carries no
    // draw_image at all — fills, lines, gradients, and paths are the
    // whole texture story.
    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try chrome.build(&app_state.model, &builder, surface_size, main.tokensFromModel(&app_state.model));
    for (builder.displayList().commands) |command| {
        try testing.expect(std.meta.activeTag(command) != .draw_image);
    }

    // With no decoded cover, both art surfaces degrade to engraved
    // plates — the player's art bay and the rack's sleeve pane, idle
    // and loaded alike.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var player = try buildTree(arena_state.allocator(), &app_state.model);
    try testing.expectEqual(canvas.WidgetKind.panel, findByLabel(player.root, "Art bay").?.kind);
    var tree = try buildPlaylistTree(arena_state.allocator(), &app_state.model);
    const idle_sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.panel, idle_sleeve.kind);
    try live.dispatch(.{ .play_track = first_track.id });
    player = try buildTree(arena_state.allocator(), &app_state.model);
    try testing.expectEqual(canvas.WidgetKind.panel, findByLabel(player.root, "Art bay").?.kind);
    tree = try buildPlaylistTree(arena_state.allocator(), &app_state.model);
    const loaded_sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.panel, loaded_sleeve.kind);
}

test "the art bay and sleeve wear the registered cover once a decode succeeds" {
    // The live path in miniature: hand the model a registered cover id
    // (what boot does on a platform with a JPEG codec) and both art
    // surfaces become image leaves bound to the loaded album's cover.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    const album_index: usize = first_track.album - 1;
    model.covers[album_index] = main.coverImageId(first_track.album);
    const player = try buildTree(arena_state.allocator(), &model);
    const art = findByLabel(player.root, "Art bay").?;
    try testing.expectEqual(canvas.WidgetKind.image, art.kind);
    try testing.expectEqual(main.coverImageId(first_track.album), art.image_id);
    const tree = try buildPlaylistTree(arena_state.allocator(), &model);
    const sleeve = findByLabel(tree.root, "Sleeve").?;
    try testing.expectEqual(canvas.WidgetKind.image, sleeve.kind);
    try testing.expectEqual(main.coverImageId(first_track.album), sleeve.image_id);
}

test "a codec-less platform keeps the fascia whole, never broken" {
    const live = try LiveApp.start(false);
    defer live.stop();
    const app_state = live.app_state;

    try testing.expectEqual(@as(usize, 0), live.harness.runtime.registeredCanvasImageCount());
    for (app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }

    // Fixed-count contract holds with nothing decoded.
    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try chrome.build(&app_state.model, &builder, surface_size, main.tokensFromModel(&app_state.model));
    try testing.expectEqual(chrome.prefix_commands + chrome.suffix_commands, builder.displayList().commands.len);
}

test "the spectrum draws the journaled band reports through the analyzer envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Idle: the powered-on noise floor, not a dead widget.
    var idle_model = Model{};
    const idle_levels = idle_model.spectrumLevels(arena);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), idle_levels.len);
    for (idle_levels, 0..) |level, band| {
        try testing.expectEqual(Model.restingLevel(band), level);
    }

    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const track = model_mod.albumTracks(2)[0];
    try live.dispatch(.{ .play_track = track.id });

    // Playing but NO analysis yet (a host without `audio_spectrum`
    // never gets past this state): the glass keeps the resting comb —
    // honest absence, never fake dancing.
    try live.feedAudio(.position, 4_200, track.duration_ms, true);
    for (app_state.model.spectrumLevels(arena), 0..) |level, band| {
        try testing.expectEqual(Model.restingLevel(band), level);
    }

    // The first band report flips the glass live, attacking instantly:
    // the displayed level IS the report (byte / 255), and repeated
    // reads of the same model state paint the same bars.
    var bands: [model_mod.spectrum_bands]u8 = @splat(0);
    bands[0] = 255;
    bands[5] = 128;
    try live.feedSpectrum(bands, 4_240, track.duration_ms);
    const first = app_state.model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, first, app_state.model.spectrumLevels(arena));
    try testing.expectEqual(@as(f32, 1.0), first[0]);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), first[5], 0.001);
    try testing.expectEqual(@as(f32, 0), first[8]);

    // Ballistics: a report that drops a band does NOT slam it down —
    // the frame clock decays it linearly toward the new target
    // (`band_decay_per_second`), while a rising band attacked already.
    var quieter: [model_mod.spectrum_bands]u8 = @splat(0);
    quieter[5] = 128; // held
    try live.feedSpectrum(quieter, 4_280, track.duration_ms); // band 0 target -> 0
    try testing.expectEqual(@as(f32, 1.0), app_state.model.band_levels[0]);
    // One 16 ms presented frame: fall = 3.0 * 0.016 = 0.048.
    try live.dispatch(.{ .frame_clock = .{ .timestamp_ns = 2_000_000, .interval_ns = 16_000_000 } });
    try live.dispatch(.{ .frame_clock = .{ .timestamp_ns = 18_000_000, .interval_ns = 16_000_000 } });
    const decayed = app_state.model.bandLevel(0);
    try testing.expect(decayed < 1.0);
    try testing.expect(decayed > 0.9);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), app_state.model.bandLevel(5), 0.001);

    // Pause freezes the bars: the frame channel starves (see the
    // frame-clock test) and the band reports stop with the audio, so
    // the last-drawn glass holds — real data, frozen honestly.
    try live.dispatch(.toggle_play);
    const paused = app_state.model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, paused, app_state.model.spectrumLevels(arena));
    try testing.expectEqual(decayed, app_state.model.bandLevel(0));

    // Resume; the next report moves them again (attack is instant).
    try live.dispatch(.toggle_play);
    const louder: [model_mod.spectrum_bands]u8 = @splat(64);
    try live.feedSpectrum(louder, 4_800, track.duration_ms);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), app_state.model.bandLevel(8), 0.001);

    // STOP clears the analyzer back to the resting comb (stop-vs-pause:
    // pause freezes, stop rests), and a NEW track resets it too — the
    // old bars describe audio that is no longer playing.
    try live.dispatch(.stop);
    for (app_state.model.spectrumLevels(arena), 0..) |level, band| {
        try testing.expectEqual(Model.restingLevel(band), level);
    }

    // The tree carries the levels as ONE chart widget with ONE series:
    // phosphor bars alone (no line riding their caps), over an honest
    // 0..1 domain.
    const tree = try buildTree(arena, &app_state.model);
    const chart = findByLabel(tree.root, "Spectrum analyzer").?;
    try testing.expectEqual(canvas.WidgetKind.chart, chart.kind);
    try testing.expectEqual(@as(usize, 1), chart.chart.series.len);
    try testing.expectEqual(canvas.ChartSeriesKind.bar, chart.chart.series[0].kind);
    try testing.expectEqual(canvas.ChartSeriesColor.accent, chart.chart.series[0].color);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), chart.chart.series[0].values.len);
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
    // same uppercase stamping the display applies.
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

test "the skin has one finish; high contrast abandons it for the framework palette" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Default appearance (light OS scheme): the enamel palette — and
    // the SAME palette under a dark OS scheme, because hardware has
    // exactly one finish.
    try testing.expectEqualDeep(theme.chassis_colors, main.tokensFromModel(&app_state.model).colors);
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.chassis_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.chassis_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // The skin's control plating is live (squared fader caps, soft
    // hardware radii, compact density).
    const tokens = try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label);
    try testing.expectEqual(@as(?f32, 1), tokens.controls.slider.radius);
    try testing.expectEqual(@as(f32, 3), tokens.radius.md);
    try testing.expectEqual(canvas.Density.compact, tokens.density);

    // High contrast: accessibility beats brand — framework palette and
    // stock control chrome (the light register, matching the enamel's
    // light base).
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light, .high_contrast = true } });
    const hc = try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label);
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastLight(), hc.colors);
    try testing.expectEqual(@as(?f32, null), hc.controls.slider.radius);
}

test "markup engine parity: the status strip builds identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .play_track = model_mod.tracks[2].id });
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

    // Press PLAY through the real automation path: focus + key dispatch
    // through the widget route, exactly what `native automate` does.
    // From idle, the transport loads the catalog's first track.
    const play_id = try live.widgetIdByLabel(main.canvas_label, 1, .button, "Play");
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

    // PAUSE holds the deck in place; PLAY resumes it (the dedicated
    // keys are one-verb hardware, not toggles).
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Pause"), "press");
    try testing.expect(!app_state.model.playing);
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Play"), "press");
    try testing.expect(app_state.model.playing);

    // STOP halts playback AND rewinds the head, keeping the record
    // loaded — the classic stop-vs-pause distinction, through the real
    // press path and out to the platform player.
    try live.feedAudio(.position, 4_000, first_track.duration_ms, true);
    try testing.expect(app_state.model.elapsed_ms > 0);
    try live.widgetAction(main.canvas_label, try live.widgetIdByLabel(main.canvas_label, 1, .button, "Stop"), "press");
    try testing.expect(!app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);
    try testing.expectEqual(@as(?u8, album_tracks[0].id), app_state.model.now);
    try testing.expect(!app_state.effects.audioSnapshot().playing);
    try testing.expectEqual(@as(u64, 0), app_state.effects.audioSnapshot().position_ms);
}

test "space is the app-wide transport key; focused widgets outrank it" {
    // The media-app convention through the raw key path (the exact gpu
    // input a physical spacebar produces), both windows. Precedence:
    //   1. a focused interactive widget consumes space for its OWN
    //      activation (a focused transport key presses itself);
    //   2. a focused editable field keeps typing — structural, by
    //      widget kind (the playlist's search field, unnamed here);
    //   3. otherwise space falls through to the app-level toggle —
    //      `primary+P` stays the works-while-typing chord.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // (3) From idle with NOTHING focused: space starts the catalog's
    // first track through the fallback, then pauses it in place.
    try live.keyDown(1, main.canvas_label, "space", " ");
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, first_track.id), app_state.model.now);
    try live.keyDown(1, main.canvas_label, "space", " ");
    try testing.expect(!app_state.model.playing);

    // (1) Focus the Next-track key: space presses THAT key — the deck
    // advances instead of resuming, so the widget outranked the toggle.
    const album_tracks = model_mod.albumTracks(first_track.album);
    const next_id = try live.widgetIdByLabel(main.canvas_label, 1, .button, "Next track");
    try live.widgetAction(main.canvas_label, next_id, "focus");
    try live.keyDown(1, main.canvas_label, "space", " ");
    try testing.expectEqual(@as(?u8, album_tracks[1].id), app_state.model.now);

    // (2) Open the playlist rack and focus its search field: a space
    // keystroke is TYPING — the character lands in the query and the
    // transport does not move. Structural by widget kind: no per-field
    // wiring exists in the app for this.
    try live.dispatch(.toggle_playlist);
    const info = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    try live.installPlaylistCanvas(info.id, 2);
    const playing_before = app_state.model.playing;
    const field_id = try live.widgetIdByLabel(main.playlist_canvas_label, info.id, .search_field, "Search library");
    try live.widgetAction(main.playlist_canvas_label, field_id, "focus");
    try live.keyDown(info.id, main.playlist_canvas_label, "space", " ");
    try testing.expectEqualStrings(" ", app_state.model.search());
    try testing.expectEqual(playing_before, app_state.model.playing);
    try testing.expectEqual(@as(?u8, album_tracks[1].id), app_state.model.now);
}

test "the chrome pass holds its exact command counts across model states" {
    // The chrome contract requires exactly prefix+suffix commands per
    // build; state-dependent marks (lit segments, lit ladder cells, the
    // knob dot's sweep) move offscreen instead of dropping out. Rebuild
    // across the states that steer the pass: idle, playing mid-song at
    // both volume extremes, the NO MEDIA degrade, and high contrast.
    var states = [_]Model{ .{}, .{}, .{}, .{}, .{} };
    states[1].now = model_mod.albumTracks(2)[0].id;
    states[1].playing = true;
    states[1].elapsed_ms = 84_500;
    states[1].now_duration_ms = model_mod.albumTracks(2)[0].duration_ms;
    states[1].volume_fraction = 0;
    states[2].now = model_mod.albumTracks(2)[0].id;
    states[2].playing = true;
    states[2].elapsed_ms = 12_250;
    states[2].now_duration_ms = model_mod.albumTracks(2)[0].duration_ms;
    states[2].volume_fraction = 1;
    states[3].media_failed = true;
    states[4].appearance = .{ .high_contrast = true };

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
        // The ruled ledger stacks a divider column onto every row but
        // the first (two extra nodes per row), so the full-catalog tree
        // sits higher than the plate-per-row round did — still inside
        // the 1024 per-view budget with real headroom.
        try testing.expect(layout.nodes.len < 960);
        _ = arena_state.reset(.retain_capacity);
    }
}

test "the frame clock advances the display only while audio moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The idle law, at the hook: idle, paused, and buffering decks emit
    // NO frame Msg, so the frame channel starves and an idle deck
    // presents zero frames.
    var model = Model{};
    const frame = native_sdk.platform.GpuFrame{ .timestamp_ns = 1_000_000_000, .frame_interval_ns = std.time.ns_per_s / 60 };
    try testing.expectEqual(@as(?Msg, null), main.onFrame(&model, frame));
    apply(&model, .{ .play_track = first_track.id });
    apply(&model, .transport_pause);
    try testing.expectEqual(@as(?Msg, null), main.onFrame(&model, frame));
    apply(&model, .transport_play);
    model.buffering = true;
    try testing.expectEqual(@as(?Msg, null), main.onFrame(&model, frame));
    model.buffering = false;

    // Playing: each presented frame advances the rendered clock by the
    // real frame delta (the first frame seeds the base at one interval).
    const emitted = main.onFrame(&model, frame) orelse return error.TestUnexpectedResult;
    apply(&model, emitted);
    try testing.expectEqual(@as(u32, 16), model.elapsed_ms);
    apply(&model, .{ .frame_clock = .{ .timestamp_ns = frame.timestamp_ns + 500 * std.time.ns_per_ms, .interval_ns = frame.frame_interval_ns } });
    // A stale gap (occlusion, resume) is clamped to a few intervals —
    // the readouts step gently, they never lurch.
    try testing.expectEqual(@as(u32, 16 + 66), model.elapsed_ms);

    // The marquee rides the same clock: half a second of frames
    // rotates it exactly one character.
    var stepper = Model{};
    apply(&stepper, .{ .play_track = first_track.id });
    const at_zero = try arena.dupe(u8, stepper.marqueeText(arena));
    var ts: u64 = 1_000_000_000;
    apply(&stepper, .{ .frame_clock = .{ .timestamp_ns = ts, .interval_ns = std.time.ns_per_s / 60 } });
    stepper.elapsed_ms = 0; // re-zero after the seeding frame; deltas advance from here
    // 35 whole-ms frame deltas (~16 ms each) cross one 500 ms marquee
    // step without reaching two.
    for (0..35) |_| {
        ts += std.time.ns_per_s / 60;
        apply(&stepper, .{ .frame_clock = .{ .timestamp_ns = ts, .interval_ns = std.time.ns_per_s / 60 } });
    }
    try testing.expect(stepper.elapsed_ms >= model_mod.marquee_step_ms);
    try testing.expect(stepper.elapsed_ms < model_mod.marquee_step_ms * 2);
    const at_one = stepper.marqueeText(arena);
    try testing.expectEqualStrings(at_zero[1..], at_one[0 .. at_one.len - 1]);

    // A replayed journal straddling a pause boundary stays exact: the
    // model re-checks motion, so a frame Msg on a paused deck moves
    // nothing even if one slipped through.
    apply(&stepper, .transport_pause);
    const held = stepper.elapsed_ms;
    apply(&stepper, .{ .frame_clock = .{ .timestamp_ns = ts + std.time.ns_per_s, .interval_ns = std.time.ns_per_s / 60 } });
    try testing.expectEqual(held, stepper.elapsed_ms);

    // Position ticks are the correcting truth: forward corrections
    // apply; a small backward disagreement (frames ran a few ms ahead)
    // holds flat so the readouts never visibly rewind; a past-slack
    // disagreement is a real desync and snaps.
    apply(&stepper, .transport_play);
    stepper.elapsed_ms = 10_000;
    apply(&stepper, .{ .audio_event = .{ .key = first_track.id, .kind = .position, .position_ms = 10_400, .duration_ms = 0, .playing = true, .buffering = false } });
    try testing.expectEqual(@as(u32, 10_400), stepper.elapsed_ms);
    apply(&stepper, .{ .audio_event = .{ .key = first_track.id, .kind = .position, .position_ms = 10_200, .duration_ms = 0, .playing = true, .buffering = false } });
    try testing.expectEqual(@as(u32, 10_400), stepper.elapsed_ms);
    apply(&stepper, .{ .audio_event = .{ .key = first_track.id, .kind = .position, .position_ms = 9_000, .duration_ms = 0, .playing = true, .buffering = false } });
    try testing.expectEqual(@as(u32, 9_000), stepper.elapsed_ms);

    // STOP zeroes the clock and freezes it (the hook returns null, and
    // a stray frame Msg re-checks): halt-and-rewind stays deterministic.
    apply(&stepper, .stop);
    try testing.expectEqual(@as(u32, 0), stepper.elapsed_ms);
    try testing.expectEqual(@as(?Msg, null), main.onFrame(&stepper, frame));
}

test "the skin-native window keys are real: chromeless windows, real verbs" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // The MAIN window declares the chromeless style (the fully-skinned
    // opt-in: no OS titleband, no system buttons — the cap band's keys
    // are the window controls). The harness creates its surface window
    // directly, so the config-level pin is the honest assertion here;
    // the style's platform seam is pinned by the SDK's shell-layout
    // suite, and the PLAYLIST window below exercises the descriptor
    // path end to end.
    try testing.expect(main.shell_scene.windows[0].titlebar == .chromeless);

    // The cap band carries working close and minimize keys with proper
    // names, reachable through the real automation path.
    const min_id = try live.widgetIdByLabel(main.canvas_label, 1, .button, "Minimize window");
    try live.widgetAction(main.canvas_label, min_id, "press");
    var actions = app_state.effects.windowActionState();
    try testing.expectEqual(@as(u32, 1), actions.minimize_count);
    try testing.expectEqualStrings(model_mod.main_window_label, actions.lastLabel());

    // The player's close key requests the REAL window close (the fake
    // executor records the request instead of performing it — the suite
    // must outlive the press).
    const close_id = try live.widgetIdByLabel(main.canvas_label, 1, .button, "Close window");
    try live.widgetAction(main.canvas_label, close_id, "press");
    actions = app_state.effects.windowActionState();
    try testing.expectEqual(@as(u32, 1), actions.close_count);
    try testing.expectEqualStrings(model_mod.main_window_label, actions.lastLabel());

    // The playlist rack: chromeless too (the descriptor path reaches
    // the platform create seam), with its own key pair.
    try live.dispatch(.toggle_playlist);
    const info = live.playlistWindowInfo() orelse return error.TestUnexpectedResult;
    try live.installPlaylistCanvas(info.id, 2);
    for (live.harness.null_platform.windows[0..live.harness.null_platform.window_count], 0..) |window, index| {
        if (window.id != info.id) continue;
        try testing.expectEqual(native_sdk.WindowTitlebarStyle.chromeless, live.harness.null_platform.window_titlebar[index]);
    }

    // Its minimize key rides the effect with the playlist's label...
    const rack_min = try live.widgetIdByLabel(main.playlist_canvas_label, info.id, .button, "Minimize window");
    try live.widgetAction(main.playlist_canvas_label, rack_min, "press");
    actions = app_state.effects.windowActionState();
    try testing.expectEqual(@as(u32, 2), actions.minimize_count);
    try testing.expectEqualStrings(main.playlist_window_label, actions.lastLabel());

    // ...and its close key racks the unit back in DECLARATIVELY — the
    // model stops declaring the window and the reconcile closes it for
    // real, without touching the close effect (count unchanged).
    const rack_close = try live.widgetIdByLabel(main.playlist_canvas_label, info.id, .button, "Close window");
    try live.widgetAction(main.playlist_canvas_label, rack_close, "press");
    try testing.expect(!app_state.model.playlist_open);
    const closed = live.playlistWindowInfo();
    try testing.expect(closed == null or !closed.?.open);
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().close_count);
}

test "the primary face is the registered pixel font, on its design grid" {
    // The registration table carries the committed face at the app id
    // the theme's typography slots point at — one face, both slots, so
    // every span on the fascia prints in the pixel face.
    try testing.expectEqual(@as(usize, 1), main.app_fonts.len);
    try testing.expectEqual(theme.primary_font_id, main.app_fonts[0].id);
    try testing.expect(main.app_fonts[0].ttf.len > 0);
    const tokens = main.tokensFromModel(&Model{});
    try testing.expectEqual(theme.primary_font_id, tokens.typography.font_id);
    try testing.expectEqual(theme.primary_font_id, tokens.typography.mono_font_id);
    // Sizes sit on the face's design grid (38/1000 em): the body at the
    // half grid, the marquee scale doubling to the full grid — the
    // crispness contract the shots verify visually.
    try testing.expectApproxEqAbs(theme.pixel_grid_em / 2, tokens.typography.body_size, 0.0001);

    // The face parses under the same bounded TrueType parser the
    // runtime registration uses, and covers the fascia's ASCII text.
    const face = try canvas.font_ttf.Face.parse(main.app_fonts[0].ttf);
    for (" ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:/.-%\"") |byte| {
        try testing.expect(face.glyphIndex(byte) != 0);
    }

    // High contrast abandons the pixel face with the rest of the skin:
    // the toolkit's stock faces are the accessible register.
    var hc = Model{};
    hc.appearance = .{ .high_contrast = true };
    const hc_tokens = main.tokensFromModel(&hc);
    try testing.expect(hc_tokens.typography.font_id != theme.primary_font_id);
}

test "the ledger rules between rows: dividers, not boxes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .play_track = first_track.id });
    const tree = try buildPlaylistTree(arena, &model);

    // Every row is a bare glass plate: no fill of its own (the loaded
    // row's wash is the one exception) and no border stroke — the
    // theme's default panel paints nothing.
    const first_row = findByLabel(tree.root, model_mod.tracks[0].title).?;
    try testing.expectEqual(canvas.WidgetKind.panel, first_row.kind);
    const tokens = main.tokensFromModel(&model);
    try testing.expectEqual(@as(u8, 0), tokens.controls.panel.background.?.a);
    try testing.expectEqual(@as(u8, 0), tokens.controls.panel.border.?.a);

    // Rules run BETWEEN rows: every visible row but the first stacks a
    // 1px hairline above its plate, so N rows carry N-1 dividers.
    const rows = model.visibleTracks(arena);
    try testing.expect(rows.len > 1);
    try testing.expect(rows[0].first);
    for (rows[1..]) |row| try testing.expect(!row.first);
    const ledger = findByLabel(tree.root, "Tracks").?;
    var dividers: usize = 0;
    for (ledger.children) |child| {
        // A non-first row is a column of [hairline, plate].
        if (child.kind == .column and child.children.len == 2 and child.children[0].kind == .panel) dividers += 1;
    }
    try testing.expectEqual(rows.len - 1, dividers);

    // The ledger insets from the bay's x edges: rows (and the rules,
    // children of the same padded column) start `ledger_inset_x` from
    // the glass edge and stop the same distance short of the right —
    // the bay panel spans the full window width, so the frame math
    // reads straight off the layout table.
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const laid = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, view_mod.playlist_width, view_mod.playlist_height), &nodes);
    var found_row = false;
    for (laid.nodes) |node| {
        if (node.widget.kind != .panel) continue;
        if (!std.mem.eql(u8, node.widget.semantics.label, model_mod.tracks[0].title)) continue;
        found_row = true;
        try testing.expectEqual(view_mod.layout.ledger_inset_x, node.frame.x);
        try testing.expectEqual(view_mod.playlist_width - view_mod.layout.ledger_inset_x, node.frame.x + node.frame.width);
    }
    try testing.expect(found_row);
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

    // Chromeless window: no OS chrome inset exists — the cap band's
    // window keys are layout-table constants, so the shots need no
    // inset dispatch.

    // Idle player: STBY lamp, dashed segments, noise-floor spectrum.
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-idle-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // Playing mid-song. The mid-song position comes from
    // REAL seek steps on the fader (the widget keyboard path), so the
    // fader and the display's timecode agree. The transport then PAUSES
    // for the two scheme captures: while playing every presented frame
    // advances the rendered clock (the frame-clock channel), so two
    // captures a frame apart would legitimately differ by clock motion
    // — pausing freezes the glass, and any byte difference left between
    // the schemes would be a finish difference.
    // Shot under a LIGHT OS scheme and again under DARK: the skin has
    // one finish, so the two captures must be byte-identical — diff the
    // artifacts for the honest proof.
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    for (0..8) |_| try live.widgetAction(main.canvas_label, seek_id, "increment");
    try live.dispatch(.transport_pause);
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try presentShotFrame(live, 3);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-playing-light-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try presentShotFrame(live, 4);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-playing-dark-artifacts", "Deck");
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
// mid-song and the analyzer glass lit by a fed band report, then the
// playlist rack racked in through
// the real PL toggle. Deck has ONE finish by design (the OS scheme
// changes nothing), so unlike the other homepage shots there is exactly
// one capture per window. PNGs land in
// /tmp/homepage-shots/deck-dark-artifacts/ and
// /tmp/homepage-shots/deck-playlist-dark-artifacts/. To use
// (the magick loop prepares RGBA twins of the committed covers once —
// see the cover registration below for why):
//
//   mkdir -p /tmp/deck-art
//   for f in examples/deck/src/art/*.jpg; do
//     magick "$f" -depth 8 rgba:/tmp/deck-art/"$(basename "${f%.jpg}")".rgba
//   done
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // Real art in the display bay. The committed covers are JPEG, which
    // the null platform's strict PNG-subset decoder honestly refuses
    // (the degrade the cover tests pin), so the capture feeds RGBA
    // twins of the SAME committed files — prepared by the magick loop
    // in the header comment — back through the engine's own PNG writer
    // and the register channel `main.boot` uses: real art on the real
    // decode->register path, no side door into the registry.
    var art_arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer art_arena_state.deinit();
    const art_arena = art_arena_state.allocator();
    for (model_mod.albums, 0..) |album, index| {
        const art = album.art orelse continue;
        var path_buffer: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/tmp/deck-art/{s}.rgba", .{std.fs.path.stem(art)});
        const rgba = try readPreparedFile(io, art_arena, path);
        const side = std.math.sqrt(rgba.len / 4);
        try testing.expectEqual(side * side * 4, rgba.len);
        const encoded = try art_arena.alloc(u8, try canvas.png.encodedRgba8ByteLen(side, side));
        var png_writer = std.Io.Writer.fixed(encoded);
        try canvas.png.writeRgba8(&png_writer, side, side, rgba);
        _ = try live.app_state.effects.registerImageBytes(main.coverImageId(album.id), png_writer.buffered());
        live.app_state.model.covers[index] = main.coverImageId(album.id);
    }

    // The hero state: a track playing mid-song, the full ledger
    // selected. The mid-song position comes from REAL seek steps on the
    // fader (the widget keyboard path), so the fader and the display's
    // timecode agree.
    const track = model_mod.albumTracks(2)[0];
    try live.dispatch(.{ .play_track = track.id });
    const seek_id = try live.widgetIdByLabel(main.canvas_label, 1, .slider, "Seek");
    for (0..8) |_| try live.widgetAction(main.canvas_label, seek_id, "increment");

    // Light the analyzer glass through the same journaled channel a
    // live host's analysis tap uses: one 32-band report with a
    // low-heavy musical contour (bass energy tapering into highs, a
    // few mid peaks), positioned at the model's own seeked clock so
    // the glass, the fader, and the timecode all agree. Attack is
    // instant, so the shot frame paints exactly these bars.
    const contour = [model_mod.spectrum_bands]u8{
        212, 236, 204, 178, 158, 186, 148, 132, 156, 124, 110, 138,
        104, 92,  118, 86,  98,  72,  90,  62,  78,  56,  70,  48,
        62,  42,  54,  36,  46,  30,  38,  24,
    };
    try live.feedSpectrum(contour, live.app_state.model.elapsed_ms, track.duration_ms);
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

/// Read one prepared capture input (see the homepage-shots header
/// comment) fully into `arena` — loud on a missing or short file, so a
/// mis-prepared /tmp fails the gated run instead of silently degrading.
fn readPreparedFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(arena, .limited(8 * 1024 * 1024));
}
