//! soundboard tests: typed dispatch through the composed tree (markup +
//! Zig sections), real audio playback driven through the fake effects
//! executor (playback requests, fed audio events, the pbcopy spawn), the
//! cover decode -> register -> draw path through the null platform's
//! strict decoder, theming, and engine parity for the markup sections.
//! Every content assertion derives from the imported music manifest —
//! no literal titles, ids, or counts — so the suite follows the catalog.

const std = @import("std");
const native_sdk = @import("native_sdk");
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
const App = main.SoundboardApp;

// ------------------------------------------------------------- tree utils

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    // Tree tests build views like the live app: with the app icon table
    // installed (registration is idempotent - one static table).
    main.registerIcons();
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.rootView(&ui, model), main.tokensFromModel(model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
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

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
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

// -------------------------------------------------------------- app utils

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,

    fn start(image_decode: bool) !LiveApp {
        // The same boot-time act main performs: install the app icon
        // table before any view builds, so app: markup references
        // resolve here exactly like in the shipped app.
        main.registerIcons();
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.image_decode = image_decode;

        const app_state = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = App.init(std.heap.page_allocator, .{}, main.soundboardOptions());
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
};

// ------------------------------------------------------------------ tests

test "the committed art is JPEG: the strict decoder degrades boot to initials" {
    // The real covers decode live through the platform codec seam
    // (macOS opens JPEG), but the null platform's strict test decoder
    // speaks only the deterministic PNG subset — so under tests boot
    // registers NOTHING and every album keeps its initials fallback.
    // That is the honest codec-less-host state, pinned here with the
    // decoder ON; the next test pins the same degrade with it off.
    const live = try LiveApp.start(true);
    defer live.stop();

    try testing.expectEqual(@as(usize, 0), live.harness.runtime.registeredCanvasImageCount());
    for (live.app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }

    // Boot survived and the grid still renders one avatar per album
    // (initials render at id 0), so a codec gap can never break the UI.
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var avatars: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .avatar) avatars += 1;
    }
    try testing.expect(avatars >= model_mod.albums.len);
}

test "a codec-less platform degrades to initials, never a broken boot" {
    const live = try LiveApp.start(false);
    defer live.stop();

    try testing.expectEqual(@as(usize, 0), live.harness.runtime.registeredCanvasImageCount());
    for (live.app_state.model.covers) |cover| {
        try testing.expectEqual(@as(canvas.ImageId, 0), cover);
    }
    // Avatars still render (initials fallback), so the grid stays whole.
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var avatars: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .avatar) avatars += 1;
    }
    try testing.expect(avatars >= model_mod.albums.len);
}

test "play, pause, and seek drive the real audio effect" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const track = model_mod.trackById(1);

    // Play: the fake executor records the playback request whole — the
    // track id keys it and the path is the comptime-built assets path.
    try live.dispatch(.{ .play_track = track.id });
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, track.id), app_state.model.now);
    const request = fx.pendingAudio().?;
    try testing.expectEqual(@as(u64, track.id), request.key);
    try testing.expectEqualStrings(track.path, request.path);
    try testing.expect(request.playing);

    // The manifest duration displays until the platform's `.loaded`
    // acknowledgment reports the decoded one — the authority once known.
    try testing.expectEqual(track.duration_ms, app_state.model.now_duration_ms);
    const decoded_ms: u64 = @as(u64, track.duration_ms) + 240;
    try fx.feedAudioEvent(.loaded, 0, decoded_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, @intCast(decoded_ms)), app_state.model.now_duration_ms);

    // Position ticks advance the elapsed clock and its rendered label.
    try fx.feedAudioEvent(.position, 61_000, decoded_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, 61_000), app_state.model.elapsed_ms);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("1:01", app_state.model.elapsedLabel(arena_state.allocator()));

    // Pause and resume drive the single player in place — the snapshot
    // mirrors what the platform was told.
    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.playing);
    try testing.expect(!fx.audioSnapshot().playing);
    try live.dispatch(.toggle_play);
    try testing.expect(app_state.model.playing);
    try testing.expect(fx.audioSnapshot().playing);

    // Seek through the real path: a semantic increment steps the
    // runtime's slider, `on-change` dispatches `.seeked`, the sync hook
    // mirrors the reconciled value into the model, and update forwards
    // the target to the player.
    const slider = findByKind(app_state.tree.?.root, .slider).?;
    var command_buffer: [96]u8 = undefined;
    const step = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} increment", .{ main.canvas_label, slider.id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), step);
    try testing.expect(app_state.model.seek_fraction > 0);
    const duration: f32 = @floatFromInt(app_state.model.now_duration_ms);
    const expected = app_state.model.seek_fraction * duration;
    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), fx.audioSnapshot().position_ms);

    // The next position tick reports from the seeked position; the model
    // follows the platform's clock.
    const after_seek = fx.audioSnapshot().position_ms + 500;
    try fx.feedAudioEvent(.position, after_seek, decoded_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, @intCast(after_seek)), app_state.model.elapsed_ms);
}

test "the seek bar's rendered value advances with position events" {
    // Regression: the slider reconcile used to retain its runtime value
    // unconditionally, so the model-driven `value="{progressFraction}"`
    // binding froze at 0 after mount - elapsed time ticked, the bar did
    // not. The reconcile now follows the source when it moves.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const track = model_mod.trackById(1);

    try live.dispatch(.{ .play_track = track.id });
    const duration_ms: u64 = track.duration_ms;
    try fx.feedAudioEvent(.loaded, 0, duration_ms, true);
    try live.wake();

    // Four position events through the fake effects executor: elapsed
    // and the RENDERED slider value advance in lockstep.
    const duration: f32 = @floatFromInt(duration_ms);
    for (1..5) |ticks| {
        const position_ms: u64 = @intCast(500 * ticks);
        try fx.feedAudioEvent(.position, position_ms, duration_ms, true);
        try live.wake();
        try testing.expectEqual(@as(u32, @intCast(position_ms)), app_state.model.elapsed_ms);

        const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        var slider_value: ?f32 = null;
        for (layout.nodes) |node| {
            if (node.widget.kind == .slider) slider_value = node.widget.value;
        }
        const expected_fraction = @as(f32, @floatFromInt(position_ms)) / duration;
        try testing.expectApproxEqAbs(expected_fraction, slider_value.?, 0.0001);
    }
}

test "controlled scroll: the album grid keeps its offset through playback rebuilds" {
    // The scroll regions are CONTROLLED: on_scroll stores the applied
    // offset and value echoes it back, so a rebuild mid-scroll (a
    // playback position event) can never restore an unechoed offset -
    // and on macOS an id churn cannot make the native scroll driver snap
    // the OS scroller back to the source offset.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.{ .play_track = 1 });

    // Wheel the album grid down through the real input path.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .scroll,
        .x = main.window_width / 2,
        .y = main.window_height / 2,
        .delta_y = 180,
    } });
    try testing.expect(app_state.model.grid_scroll > 0);
    const scrolled_offset = app_state.model.grid_scroll;

    // A playback position event rebuilds the whole tree; the grid must
    // hold.
    try app_state.effects.feedAudioEvent(.position, 500, 0, true);
    try live.wake();
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var grid_offset: ?f32 = null;
    for (layout.nodes) |node| {
        if (node.widget.kind == .scroll_view) grid_offset = node.widget.value;
    }
    try testing.expectApproxEqAbs(scrolled_offset, grid_offset.?, 0.0001);
    try testing.expectApproxEqAbs(scrolled_offset, app_state.model.grid_scroll, 0.0001);

    // Opening a record resets the DETAIL region to its top while the
    // grid offset stays owned by the model.
    try live.dispatch(.{ .open_album = 2 });
    try testing.expectEqual(@as(f32, 0), app_state.model.detail_scroll);
    try testing.expectApproxEqAbs(scrolled_offset, app_state.model.grid_scroll, 0.0001);
}

test "track end auto-advances; the play-next queue wins over album order" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;

    // Play the library's first track; queue the LAST album's first track
    // from another record via the context-menu message (both derived
    // from the imported catalog, never hardcoded ids).
    const first = model_mod.trackById(1);
    const last_album = &model_mod.albums[model_mod.albums.len - 1];
    const last_album_tracks = model_mod.albumTracks(last_album.id);
    const queued = &last_album_tracks[0];
    try live.dispatch(.{ .play_track = first.id });
    try live.dispatch(.{ .queue_track = queued.id });
    try testing.expectEqual(@as(usize, 1), app_state.model.queue_len);

    // Natural end: the platform's one completion starts the queued
    // track, and the NEXT recorded playback request carries its path.
    const first_duration: u64 = first.duration_ms;
    try fx.feedAudioEvent(.completed, first_duration, first_duration, false);
    try live.wake();
    try testing.expectEqual(@as(?u8, queued.id), app_state.model.now);
    try testing.expectEqual(@as(usize, 0), app_state.model.queue_len);
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);
    try testing.expectEqualStrings(queued.path, fx.pendingAudio().?.path);

    // With an empty queue the album order advances to the record's next
    // track and asks the player for its file.
    const queued_duration: u64 = queued.duration_ms;
    try fx.feedAudioEvent(.completed, queued_duration, queued_duration, false);
    try live.wake();
    const second = &last_album_tracks[1];
    try testing.expectEqual(@as(?u8, second.id), app_state.model.now);
    try testing.expectEqualStrings(second.path, fx.pendingAudio().?.path);

    // next/prev wrap within the album — with its REAL track count, which
    // varies per record.
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, queued.id), app_state.model.now);
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, last_album_tracks[last_album_tracks.len - 1].id), app_state.model.now);
    try live.dispatch(.next_track);
    try testing.expectEqual(@as(?u8, queued.id), app_state.model.now);
}

test "a failed load lands the honest assets-not-prepared state" {
    // The audio files are gitignored (the prepare script downloads
    // them). A missing file surfaces as one `.failed` event: playback
    // clears, the now-playing bar tells the user what to run, and the
    // catalog keeps browsing — never a crash, never silence.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;

    try live.dispatch(.{ .play_track = 1 });
    try fx.feedAudioEvent(.failed, 0, 0, false);
    try live.wake();

    // Playback cleared, the notice raised, the audio channel idle.
    try testing.expect(app_state.model.assets_missing);
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
    try testing.expect(!app_state.model.playing);
    try testing.expect(fx.pendingAudio() == null);

    // The now-playing bar renders both lines of the notice verbatim.
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var saw_title = false;
    var saw_hint = false;
    var cards: usize = 0;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, model_mod.assets_missing_title)) saw_title = true;
        if (std.mem.eql(u8, node.widget.text, model_mod.assets_missing_hint)) saw_hint = true;
        if (node.widget.semantics.role == .listitem) cards += 1;
    }
    try testing.expect(saw_title);
    try testing.expect(saw_hint);
    // Browsing survives fully: the grid still lists the whole catalog.
    try testing.expectEqual(model_mod.albums.len, cards);

    // A fresh play attempt clears the notice optimistically — if the
    // assets are still absent, the next `.failed` event raises it again.
    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.assets_missing);
    try testing.expect(fx.pendingAudio() != null);
}

test "copy title spawns pbcopy with the track title on stdin" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Any catalog track works; the third album's opener keeps the
    // assertion clearly derived rather than a literal title.
    const track = &model_mod.albumTracks(model_mod.albums[2].id)[0];
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
    try live.dispatch(.{ .copy_title = model_mod.tracks[1].id });
    try app_state.effects.feedExit(model_mod.copy_key, 1);
    try live.wake();
    try testing.expect(app_state.model.copy_failed);
}

test "search filters albums and songs through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var tree = try buildTree(arena, &model);
    try testing.expectEqual(model_mod.albums.len, countListItems(tree.root));

    // Type into the search field: the edit event dispatches through the
    // markup-declared on-input handler and mirrors into the model. The
    // query matches exactly one album title in the catalog (and no
    // artist), so the grid narrows to that record.
    const album = &model_mod.albums[model_mod.albums.len - 1];
    const field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(field.id, .{ .insert_text = "channel" }).?);
    try testing.expectEqualStrings("channel", model.search());

    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countListItems(tree.root));
    const card_label = try std.fmt.allocPrint(arena, "{s} by {s}", .{ album.title, album.artist });
    try testing.expect(findByLabel(tree.root, card_label) != null);

    // Songs tab matches titles, artists, and album names: an album-title
    // match carries every track of that record, however many it has.
    apply(&model, .show_songs);
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, album.track_count), countListItems(tree.root));

    // Clear restores the full library. The search field carries the
    // BUILT-IN trailing clear affordance (no external button): the
    // press stamps a `.clear` edit that reaches the model through the
    // same on-input channel every keystroke uses.
    const searching_field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(searching_field.id, .clear).?);
    try testing.expectEqualStrings("", model.search());
    tree = try buildTree(arena, &model);
    try testing.expectEqual(model_mod.tracks.len, countListItems(tree.root));
    // Nothing else in the header claims the clear: the external button
    // is gone.
    try testing.expect(findByLabel(tree.root, "Clear search") == null);

    // No matches renders the empty state instead of a list.
    apply(&model, .show_albums);
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("polka");
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 0), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, "No albums match") != null);
}

test "a full session: open an album, play it, and use the context menus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var tree = try buildTree(arena, &model);

    // Open the second album's card from the grid (everything below is
    // derived from the catalog: ids, counts, titles).
    const album = &model_mod.albums[1];
    const album_tracks = model_mod.albumTracks(album.id);
    const card_label = try std.fmt.allocPrint(arena, "{s} by {s}", .{ album.title, album.artist });
    const card = findByLabel(tree.root, card_label).?;
    apply(&model, tree.msgForPointer(card.id, .up).?);
    try testing.expectEqual(@as(?u8, album.id), model.open_album);

    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Album detail") != null);
    try testing.expectEqual(@as(usize, album.track_count), countListItems(tree.root));

    // Play album starts the record's first track. The button carries its
    // play icon inline (widget.icon) beside the label: one widget, one
    // hit target, one tint.
    const play_button = findByLabel(tree.root, "Play album").?;
    try testing.expectEqual(canvas.WidgetKind.button, play_button.kind);
    try testing.expectEqualStrings("play", play_button.icon);
    try testing.expectEqualStrings("Play album", play_button.text);
    apply(&model, tree.msgForPointer(play_button.id, .up).?);
    try testing.expectEqual(@as(?u8, album_tracks[0].id), model.now);
    try testing.expect(model.playing);

    // The now-playing bar reflects it: the primary transport button
    // wears the pause icon while playing, prev/next wear the real
    // skip-back/skip-forward glyphs, and the playing track row keeps its
    // decorative play indicator (a bare .icon leaf — never hit-tested).
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, album_tracks[0].title) != null);
    try testing.expectEqualStrings("pause", findByLabel(tree.root, "Play or pause").?.icon);
    try testing.expectEqualStrings("skip-back", findByLabel(tree.root, "Previous track").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(tree.root, "Next track").?.icon);
    try testing.expect(findByText(tree.root, .icon, "play") != null);

    // Pressing a different track row switches to it; pressing the playing
    // row toggles pause.
    const other = &album_tracks[2];
    const row = findByLabel(tree.root, other.title).?;
    apply(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?u8, other.id), model.now);
    tree = try buildTree(arena, &model);
    const same_row = findByLabel(tree.root, other.title).?;
    apply(&model, tree.msgForPointer(same_row.id, .up).?);
    try testing.expect(!model.playing);

    // Context-menu items dispatch typed messages: Play Next queues, Copy
    // Title raises the pbcopy effect (asserted in its own test).
    tree = try buildTree(arena, &model);
    const queue_target = &album_tracks[album_tracks.len - 1];
    const target_row = findByLabel(tree.root, queue_target.title).?;
    apply(&model, tree.msgForContextMenu(target_row.id, 0).?); // "Play Next"
    try testing.expectEqual(@as(usize, 1), model.queue_len);
    try testing.expectEqual(queue_target.id, model.queue[0]);
    // Indexes past the declared items are inert.
    try testing.expect(tree.msgForContextMenu(target_row.id, 2) == null);

    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .badge, "Up next") != null);

    // Back returns to the grid; the playing album is badged there. Back
    // is a chevron-left icon+label button (inline icon, one hit target).
    apply(&model, .toggle_play);
    const back = findByLabel(tree.root, "Back to albums").?;
    try testing.expectEqual(canvas.WidgetKind.button, back.kind);
    apply(&model, tree.msgForPointer(back.id, .up).?);
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Album grid") != null);
    try testing.expect(findByText(tree.root, .badge, "Playing") != null);
}

test "the system appearance drives the custom tokens live" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Default: light system appearance = custom light palette.
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);

    // The OS flips to dark; the app follows it - there is no in-window
    // theme control by design.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&app_state.model).colors);
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // And back to light.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // High contrast falls back to the framework palette (accessibility
    // beats brand).
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastDark(), (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

test "the Albums/Songs tabs render as segmented triggers with one active" {
    // The header authors the strip as `<tabs>` + `<button selected=...>`;
    // the markup engines lower those buttons to `segmented_control`
    // widgets, so the active tab lifts to the surface per the house
    // treatment instead of vanishing into the strip's wash.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    const Tabs = struct {
        fn triggerId(layout: canvas.WidgetLayoutTree, label: []const u8) ?canvas.ObjectId {
            for (layout.nodes) |node| {
                if (node.widget.kind != .segmented_control) continue;
                if (std.mem.eql(u8, node.widget.text, label)) return node.widget.id;
            }
            return null;
        }

        fn expectExactlyOneActive(layout: canvas.WidgetLayoutTree, label: []const u8) !void {
            var active: usize = 0;
            var active_matches = false;
            for (layout.nodes) |node| {
                if (node.widget.kind != .segmented_control) continue;
                if (!node.widget.state.selected) continue;
                active += 1;
                if (std.mem.eql(u8, node.widget.text, label)) active_matches = true;
            }
            try testing.expectEqual(@as(usize, 1), active);
            try testing.expect(active_matches);
        }
    };

    // Default tab is Albums: exactly one active trigger.
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try Tabs.expectExactlyOneActive(layout, "Albums");

    // Click Songs through the real widget path: the model switches and
    // exactly one trigger stays active.
    var command_buffer: [96]u8 = undefined;
    const songs_id = Tabs.triggerId(layout, "Songs").?;
    const click_songs = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, songs_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), click_songs);
    try testing.expectEqual(model_mod.Tab.songs, app_state.model.tab);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try Tabs.expectExactlyOneActive(layout, "Songs");

    // And back to Albums.
    const albums_id = Tabs.triggerId(layout, "Albums").?;
    const click_albums = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, albums_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), click_albums);
    try testing.expectEqual(model_mod.Tab.albums, app_state.model.tab);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try Tabs.expectExactlyOneActive(layout, "Albums");
}

test "the track-change animation window opens on play and closes after" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var animations: [8]canvas.CanvasRenderAnimation = undefined;

    // Nothing playing yet: no animations.
    var tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 0), main.animations(&model, &tree, 0, &animations));

    // A track change opens the window: title + cover (fill and image).
    apply(&model, .{ .play_track = 5 });
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 3), main.animations(&model, &tree, 0, &animations));

    // 400 ms of playback later, a rebuild does not restart the motion —
    // the playback clock (position events) is the motion clock.
    model.elapsed_ms = 400;
    try testing.expectEqual(@as(usize, 0), main.animations(&model, &tree, 0, &animations));
}

test "markup engine parity: header and now-playing build identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .play_track = 3 });
    apply(&model, .{ .queue_track = 4 });

    inline for (.{
        .{ view_mod.header_markup, view_mod.CompiledHeaderView },
        .{ view_mod.nowplaying_markup, view_mod.CompiledNowPlayingView },
    }) |case| {
        var interpreter = try canvas.MarkupView(Model, Msg).init(arena, case[0]);
        var compiled_ui = Ui.init(arena);
        const compiled = try compiled_ui.finalize(case[1].build(&compiled_ui, &model));
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
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

test "the album detail heading moved to markup unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .open_album = 2 });
    const album = model_mod.albumById(2);

    // The markup fragment (a <text> with one bold 1.9x-scaled <span>)
    // builds the exact widget the builder paragraph produced: same kind,
    // same text, same span list — weight AND scale — and the same
    // accessible label, so the detail page renders pixel-identical.
    var markup_ui = Ui.init(arena);
    const markup_node = view_mod.AlbumTitleView.build(&markup_ui, &model);

    var hand_ui = Ui.init(arena);
    const hand_node = hand_ui.paragraph(.{ .semantics = .{ .label = album.title } }, &.{
        .{ .text = album.title, .weight = .bold, .scale = 1.9 },
    });

    try testing.expectEqual(canvas.WidgetKind.text, markup_node.widget.kind);
    try testing.expectEqualStrings(hand_node.widget.text, markup_node.widget.text);
    try testing.expectEqualStrings(album.title, markup_node.widget.text);
    try testing.expect(canvas.text_spans.textSpansEqual(hand_node.widget.spans, markup_node.widget.spans));
    try testing.expectEqual(canvas.TextSpanWeight.bold, markup_node.widget.spans[0].weight);
    try testing.expectEqual(@as(f32, 1.9), markup_node.widget.spans[0].scale);
    try testing.expectEqualStrings(hand_node.widget.semantics.label, markup_node.widget.semantics.label);
    // One text run for assistive tech: spans stay visual, scaled or not.
    try testing.expectEqual(@as(usize, 0), markup_node.nodes.len);
}

test "app icons and bound icons flow from markup into the live layout and snapshot" {
    const live = try LiveApp.start(true);
    defer live.stop();

    try live.dispatch(.{ .play_track = 7 });
    try presentShotFrame(live, 2);

    // The retained layout carries both open icon forms: the app:
    // namespace reference verbatim on the waveform mark, and the bound
    // play/pause icon as the value the model produced while playing.
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var saw_waveform = false;
    var play_pause_icon: []const u8 = "";
    for (layout.nodes) |node| {
        if (node.widget.kind == .icon and std.mem.eql(u8, node.widget.icon, "app:waveform")) saw_waveform = true;
        if (std.mem.eql(u8, node.widget.semantics.label, "Play or pause")) play_pause_icon = node.widget.icon;
    }
    try testing.expect(saw_waveform);
    try testing.expectEqualStrings("pause", play_pause_icon);

    // Both names resolve to REAL parsed icons at draw time - never the
    // missing-icon fallback: the namespace reaches the registered table,
    // and the bound value lands on a built-in.
    try testing.expectEqual(@as(?*const canvas.icons.Icon, main.app_icons[0].icon), canvas.icons.resolve("app:waveform"));
    try testing.expectEqual(canvas.icons.find("pause").?, canvas.icons.resolveOrMissing(play_pause_icon).?);

    // The automation snapshot sees the transport button the bound icon
    // rides on (the accessibility surface stays intact).
    const snapshot = live.harness.runtime.automationSnapshot("Soundboard");
    var saw_transport = false;
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.name, "Play or pause")) saw_transport = true;
    }
    try testing.expect(saw_transport);

    // Data-driven for real: pausing swaps the SAME button's glyph
    // through the binding - no if/else arms, no key juggling.
    try live.dispatch(.toggle_play);
    try presentShotFrame(live, 3);
    const paused_layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    for (paused_layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Play or pause")) {
            try testing.expectEqualStrings("play", node.widget.icon);
        }
    }
}

test "every view lays out within the canvas and the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = 1 });

    const cases = [_]struct { tab: model_mod.Tab, open: ?u8 }{
        .{ .tab = .albums, .open = null },
        .{ .tab = .albums, .open = 2 },
        .{ .tab = .songs, .open = null },
    };
    for (cases) |case| {
        model.tab = case.tab;
        model.open_album = case.open;
        const tree = try buildTree(arena_state.allocator(), &model);
        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
        try testing.expect(layout.nodes.len > 0);
        // The all-songs list mounts every catalog track as a row, so the
        // peak scales with the manifest; keep a hard headroom line well
        // under the 1024 per-view budget so growth is a conscious act.
        try testing.expect(layout.nodes.len < 768);
        _ = arena_state.reset(.retain_capacity);
    }
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = 1 });

    const cases = [_]struct { tab: model_mod.Tab, open: ?u8 }{
        .{ .tab = .albums, .open = null },
        .{ .tab = .albums, .open = 2 },
        .{ .tab = .songs, .open = null },
    };
    for (cases) |case| {
        model.tab = case.tab;
        model.open_album = case.open;
        const tree = try buildTree(arena_state.allocator(), &model);
        try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = main.tokensFromModel(&model),
            .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = surface_size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = 1 });

    // The same view states the layout sweep audits: both tabs and the
    // open-album drilldown, so every control the app can show is judged
    // by the label assistive tech would announce.
    const cases = [_]struct { tab: model_mod.Tab, open: ?u8 }{
        .{ .tab = .albums, .open = null },
        .{ .tab = .albums, .open = 2 },
        .{ .tab = .songs, .open = null },
    };
    for (cases) |case| {
        model.tab = case.tab;
        model.open_album = case.open;
        const tree = try buildTree(arena_state.allocator(), &model);
        try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = main.tokensFromModel(&model),
            .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = surface_size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

// Env-gated screenshot renderer (skipped by default, never in CI): renders
// the app OFFSCREEN through the deterministic reference renderer via the
// automation screenshot artifact — no live window. PNGs land in
// /tmp/icon-batch-shots/soundboard-*-artifacts/. To use:
//
//   ICON_BATCH_SHOTS=1 zig build test
test "render icon-batch screenshots (env-gated)" {
    if (!envGateSet("ICON_BATCH_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // Album detail, playing: Play album / Back inline-icon buttons plus
    // the skip-back / pause / skip-forward transport.
    try live.dispatch(.{ .open_album = 2 });
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/icon-batch-shots/soundboard-detail-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    // Searching: the icon-only clear button in the header.
    try live.dispatch(.close_album);
    var model = &live.app_state.model;
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("glass");
    try live.dispatch(.toggle_play);
    try presentShotFrame(live, 3);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/icon-batch-shots/soundboard-search-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");
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

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): renders the docs-homepage showcase state OFFSCREEN through the
// deterministic reference renderer — the album grid with a track playing,
// once per color scheme, same state in both. PNGs land in
// /tmp/homepage-shots/soundboard-{light,dark}-artifacts/. To use:
//
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // The hero state: album grid, a track playing so the now-playing bar
    // and transport are on screen - a minute in, so the seek bar carries
    // real progress. The app follows the system appearance, so each
    // scheme arrives as a platform event.
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    live.app_state.model.elapsed_ms = 67_500;
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/soundboard-light-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    // Same state, dark scheme: the dispatch re-emits the display list
    // with the re-derived tokens, so no present is needed in between.
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/soundboard-dark-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = model_mod.Model{};
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The tall hidden-inset band arrives through on_chrome: the header
    // pads past the traffic lights and matches the band's height so its
    // centered controls share the lights' centerline.
    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, msg, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, tall, &fx);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Fullscreen zeroes the chrome: the pad collapses and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, cleared, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}
