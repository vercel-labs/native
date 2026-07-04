//! soundboard tests: typed dispatch through the composed tree (markup +
//! Zig sections), playback simulation through the fake effects executor
//! (timers, the pbcopy spawn), the cover decode -> register -> draw path
//! through the null platform's strict PNG decoder, theming, and engine
//! parity for the markup sections.

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

test "boot registers every bundled cover through the strict decode seam" {
    const live = try LiveApp.start(true);
    defer live.stop();

    // init_fx ran on the installing frame; every registration succeeded.
    try testing.expectEqual(model_mod.albums.len, live.harness.runtime.registeredCanvasImageCount());
    for (live.app_state.model.covers, 1..) |cover, album_id| {
        try testing.expectEqual(@as(canvas.ImageId, @intCast(album_id)), cover);
    }

    // The grid's avatars carry the registered ids into the retained layout.
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var covers_seen: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .avatar and node.widget.image_id != 0) covers_seen += 1;
    }
    try testing.expectEqual(model_mod.albums.len, covers_seen);
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

test "play, pause, and seek drive the progress timer effect" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Play a track: the repeating progress timer is requested.
    try live.dispatch(.{ .play_track = 1 });
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, 1), app_state.model.now);
    const timer = app_state.effects.pendingTimerAt(0).?;
    try testing.expectEqual(model_mod.progress_timer_key, timer.key);
    try testing.expectEqual(@as(u64, model_mod.tick_ms), timer.interval_ms);

    // Each fire advances elapsed time by one tick.
    try app_state.effects.fireTimer(model_mod.progress_timer_key);
    try live.wake();
    try testing.expectEqual(model_mod.tick_ms, app_state.model.elapsed_ms);

    // Pause cancels the timer; firing the cancelled key is an error.
    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.playing);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingTimerCount());
    try testing.expectError(error.EffectNotFound, app_state.effects.fireTimer(model_mod.progress_timer_key));

    // Resume re-registers it (start on an active key replaces in place).
    try live.dispatch(.toggle_play);
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingTimerCount());

    // Seek through the real path: a semantic increment steps the runtime's
    // slider, `on-change` dispatches `.seeked`, and the sync hook mirrors
    // the reconciled value into the model before update reads it.
    const slider = findByKind(app_state.tree.?.root, .slider).?;
    var command_buffer: [96]u8 = undefined;
    const step = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} increment", .{ main.canvas_label, slider.id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), step);
    try testing.expect(app_state.model.seek_fraction > 0);
    const duration: f32 = @floatFromInt(model_mod.trackById(1).duration_ms);
    const expected = app_state.model.seek_fraction * duration;
    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
}

test "track end auto-advances; the play-next queue wins over album order" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.{ .play_track = 1 });
    // Queue a track from another album via the context-menu message.
    try live.dispatch(.{ .queue_track = 43 });
    try testing.expectEqual(@as(usize, 1), app_state.model.queue_len);

    // Run the playing track to its end: the queued track starts.
    const duration = model_mod.trackById(1).duration_ms;
    app_state.model.elapsed_ms = duration - model_mod.tick_ms;
    try app_state.effects.fireTimer(model_mod.progress_timer_key);
    try live.wake();
    try testing.expectEqual(@as(?u8, 43), app_state.model.now);
    try testing.expectEqual(@as(usize, 0), app_state.model.queue_len);
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(u32, 0), app_state.model.elapsed_ms);

    // With an empty queue the album order advances (43 -> 44).
    app_state.model.elapsed_ms = model_mod.trackById(43).duration_ms;
    try app_state.effects.fireTimer(model_mod.progress_timer_key);
    try live.wake();
    try testing.expectEqual(@as(?u8, 44), app_state.model.now);

    // next/prev wrap within the album.
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, 43), app_state.model.now);
    try live.dispatch(.prev_track);
    try testing.expectEqual(@as(?u8, 48), app_state.model.now);
    try live.dispatch(.next_track);
    try testing.expectEqual(@as(?u8, 43), app_state.model.now);
}

test "copy title spawns pbcopy with the track title on stdin" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.{ .copy_title = 14 });
    const request = app_state.effects.pendingSpawnAt(0).?;
    try testing.expectEqual(model_mod.copy_key, request.key);
    try testing.expectEqual(@as(usize, 1), request.argv.len);
    try testing.expectEqualStrings("/usr/bin/pbcopy", request.argv[0]);
    try testing.expectEqualStrings("Ember Lines", request.stdin);

    try app_state.effects.feedExit(model_mod.copy_key, 0);
    try live.wake();
    try testing.expectEqual(@as(u32, 1), app_state.model.copies_done);
    try testing.expect(!app_state.model.copy_failed);

    // A failing exit is noted, never fatal.
    try live.dispatch(.{ .copy_title = 2 });
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
    // markup-declared on-input handler and mirrors into the model.
    const field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(field.id, .{ .insert_text = "velvet" }).?);
    try testing.expectEqualStrings("velvet", model.search());

    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, "Velvet Static by Ivy Meridian") != null);

    // Songs tab matches titles, artists, and album names.
    apply(&model, .show_songs);
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, model_mod.tracks_per_album), countListItems(tree.root));

    // Clear restores the full library. The clear control is an
    // icon-only button: the "x" rides the button's own icon channel
    // (widget.icon), so there is exactly one widget and one hit target.
    const clear = findByLabel(tree.root, "Clear search").?;
    try testing.expectEqual(canvas.WidgetKind.button, clear.kind);
    try testing.expectEqualStrings("x", clear.icon);
    try testing.expectEqualStrings("", clear.text);
    apply(&model, tree.msgForPointer(clear.id, .up).?);
    try testing.expectEqualStrings("", model.search());
    tree = try buildTree(arena, &model);
    try testing.expectEqual(model_mod.tracks.len, countListItems(tree.root));

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

    // Open the Glass Horizon card from the grid.
    const card = findByLabel(tree.root, "Glass Horizon by Aurora Fields").?;
    apply(&model, tree.msgForPointer(card.id, .up).?);
    try testing.expectEqual(@as(?u8, 2), model.open_album);

    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Album detail") != null);
    try testing.expectEqual(@as(usize, model_mod.tracks_per_album), countListItems(tree.root));

    // Play album starts track 7 (the record's first track). The button
    // carries its play icon inline (widget.icon) beside the label: one
    // widget, one hit target, one tint.
    const play_button = findByLabel(tree.root, "Play album").?;
    try testing.expectEqual(canvas.WidgetKind.button, play_button.kind);
    try testing.expectEqualStrings("play", play_button.icon);
    try testing.expectEqualStrings("Play album", play_button.text);
    apply(&model, tree.msgForPointer(play_button.id, .up).?);
    try testing.expectEqual(@as(?u8, 7), model.now);
    try testing.expect(model.playing);

    // The now-playing bar reflects it: the primary transport button
    // wears the pause icon while playing, prev/next wear the real
    // skip-back/skip-forward glyphs, and the playing track row keeps its
    // decorative play indicator (a bare .icon leaf — never hit-tested).
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "Glass") != null);
    try testing.expectEqualStrings("pause", findByLabel(tree.root, "Play or pause").?.icon);
    try testing.expectEqualStrings("skip-back", findByLabel(tree.root, "Previous track").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(tree.root, "Next track").?.icon);
    try testing.expect(findByText(tree.root, .icon, "play") != null);

    // Pressing a different track row switches to it; pressing the playing
    // row toggles pause.
    const row = findByLabel(tree.root, "Sea of Static").?;
    apply(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?u8, 9), model.now);
    tree = try buildTree(arena, &model);
    const same_row = findByLabel(tree.root, "Sea of Static").?;
    apply(&model, tree.msgForPointer(same_row.id, .up).?);
    try testing.expect(!model.playing);

    // Context-menu items dispatch typed messages: Play Next queues, Copy
    // Title raises the pbcopy effect (asserted in its own test).
    tree = try buildTree(arena, &model);
    const undertow = findByLabel(tree.root, "Undertow").?;
    apply(&model, tree.msgForContextMenu(undertow.id, 0).?); // "Play Next"
    try testing.expectEqual(@as(usize, 1), model.queue_len);
    try testing.expectEqual(@as(u8, 12), model.queue[0]);
    // Indexes past the declared items are inert.
    try testing.expect(tree.msgForContextMenu(undertow.id, 2) == null);

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

test "theme preference and system appearance derive the custom tokens" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // Default: auto + light system appearance = custom light palette.
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);

    // The OS flips to dark; auto follows it.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&app_state.model).colors);
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // An explicit light preference overrides the dark system scheme.
    try live.dispatch(.{ .set_theme = .light });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // High contrast falls back to the framework palette (accessibility
    // beats brand).
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    try live.dispatch(.{ .set_theme = .auto });
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastDark(), (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

test "theme chips are a model-driven exclusive group across rebuilds" {
    // Friction #81: the header's theme chips are real toggle-buttons
    // whose selected= comes from the model. Pressing chips through the
    // real widget path must always leave exactly the model's selection
    // active — never every chip ever pressed.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    const ThemeChips = struct {
        fn chipId(layout: canvas.WidgetLayoutTree, label: []const u8) ?canvas.ObjectId {
            for (layout.nodes) |node| {
                if (node.widget.kind != .toggle_button) continue;
                if (std.mem.eql(u8, node.widget.text, label)) return node.widget.id;
            }
            return null;
        }

        fn expectExactlyOneActive(layout: canvas.WidgetLayoutTree, label: []const u8) !void {
            var active: usize = 0;
            var active_matches = false;
            for (layout.nodes) |node| {
                if (node.widget.kind != .toggle_button) continue;
                if (!node.widget.state.selected) continue;
                active += 1;
                if (std.mem.eql(u8, node.widget.text, label)) active_matches = true;
            }
            try testing.expectEqual(@as(usize, 1), active);
            try testing.expect(active_matches);
        }
    };

    // Default preference is auto: exactly one chip active.
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try ThemeChips.expectExactlyOneActive(layout, "auto");

    // Press "dark" through the real widget path (runtime toggle +
    // dispatched Msg + rebuild): exactly one active chip.
    var command_buffer: [96]u8 = undefined;
    const dark_id = ThemeChips.chipId(layout, "dark").?;
    const press_dark = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} toggle", .{ main.canvas_label, dark_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), press_dark);
    try testing.expectEqual(model_mod.ThemePref.dark, app_state.model.theme_pref);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try ThemeChips.expectExactlyOneActive(layout, "dark");

    // Then "light": the previously active chip deactivates.
    const light_id = ThemeChips.chipId(layout, "light").?;
    const press_light = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} toggle", .{ main.canvas_label, light_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), press_light);
    try testing.expectEqual(model_mod.ThemePref.light, app_state.model.theme_pref);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try ThemeChips.expectExactlyOneActive(layout, "light");

    // Pressing the ACTIVE chip keeps the model's selection: the
    // runtime toggle is overridden by the model-driven rebuild.
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), press_light);
    try testing.expectEqual(model_mod.ThemePref.light, app_state.model.theme_pref);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try ThemeChips.expectExactlyOneActive(layout, "light");

    // An unrelated rebuild (search edit) never resurrects old chips.
    apply(&app_state.model, .{ .play_track = 1 });
    try live.dispatch(.toggle_play);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try ThemeChips.expectExactlyOneActive(layout, "light");
}

test "the track-change animation window opens on play and closes after" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var test_clock = native_sdk.TestClock{};
    test_clock.advanceMs(10_000);
    var model = Model{ .clock = test_clock.clock() };
    var animations: [8]canvas.CanvasRenderAnimation = undefined;

    // Nothing playing yet: no animations.
    var tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 0), main.animations(&model, &tree, 0, &animations));

    // A track change opens the window: title + cover (fill and image).
    apply(&model, .{ .play_track = 5 });
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 3), main.animations(&model, &tree, 0, &animations));

    // A progress-tick rebuild 400 ms later does not restart the motion.
    test_clock.advanceMs(400);
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
        try testing.expect(layout.nodes.len < 512); // half the 1024 budget
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
    if (std.c.getenv("ICON_BATCH_SHOTS") == null) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // Album detail, playing: Play album / Back inline-icon buttons plus
    // the skip-back / pause / skip-forward transport.
    try live.dispatch(.{ .open_album = 2 });
    try live.dispatch(.{ .play_track = 7 });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/icon-batch-shots/soundboard-detail-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    // Searching: the icon-only clear button in the header.
    try live.dispatch(.close_album);
    var model = &live.app_state.model;
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("velvet");
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
    if (std.c.getenv("HOMEPAGE_SHOTS") == null) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // The hero state: album grid, covers decoded, a track playing so the
    // now-playing bar and transport are on screen.
    try live.dispatch(.{ .play_track = 7 });
    try live.dispatch(.{ .set_theme = .light });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/soundboard-light-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    // Same state, dark scheme: the dispatch re-emits the display list
    // with the re-derived tokens, so no present is needed in between.
    try live.dispatch(.{ .set_theme = .dark });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/soundboard-dark-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");
}
