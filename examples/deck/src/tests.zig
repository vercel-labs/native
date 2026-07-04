//! deck tests: typed dispatch through the composed tree (markup status
//! strip + Zig chrome), playback simulation through the fake effects
//! executor (timers, the pbcopy spawn), spectrum determinism, the
//! dark-only theming contract, markup engine parity, automation
//! click-through on the transport, and layout/widget budgets.

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

// -------------------------------------------------------------- app utils

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,

    fn start() !LiveApp {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

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

    fn widgetIdByLabel(self: LiveApp, kind: canvas.WidgetKind, label: []const u8) !canvas.ObjectId {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind != kind) continue;
            if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.widget.id;
        }
        return error.WidgetNotFound;
    }

    fn widgetAction(self: LiveApp, id: canvas.ObjectId, verb: []const u8) !void {
        var command_buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} {s}", .{ main.canvas_label, id, verb });
        try self.harness.runtime.dispatchAutomationCommand(self.app_state.app(), line);
    }
};

// ------------------------------------------------------------------ tests

test "play, pause, and seek drive the progress timer effect" {
    const live = try LiveApp.start();
    defer live.stop();
    const app_state = live.app_state;

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
    // the reconciled value into the model before update reads it. The
    // deck has two sliders — the label disambiguates.
    const seek_id = try live.widgetIdByLabel(.slider, "Seek");
    try live.widgetAction(seek_id, "increment");
    try testing.expect(app_state.model.seek_fraction > 0);
    const duration: f32 = @floatFromInt(model_mod.trackById(1).duration_ms);
    const expected = app_state.model.seek_fraction * duration;
    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);

    // The volume fader mirrors through the same sync hook.
    const volume_id = try live.widgetIdByLabel(.slider, "Volume");
    const volume_before = app_state.model.volume_fraction;
    try live.widgetAction(volume_id, "increment");
    try testing.expect(app_state.model.volume_fraction > volume_before);
}

test "track end auto-advances; the play-next queue wins over album order" {
    const live = try LiveApp.start();
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.{ .play_track = 1 });
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
    const live = try LiveApp.start();
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

test "the rail and the search both narrow the ledger through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var tree = try buildTree(arena, &model);
    // 9 rail cells (ALL + 8 albums) + 48 ledger rows.
    try testing.expectEqual(@as(usize, model_mod.albums.len + 1 + model_mod.tracks.len), countListItems(tree.root));

    // Select an album channel: the ledger narrows to the record.
    const channel = findByLabel(tree.root, "Glass Horizon").?;
    apply(&model, tree.msgForPointer(channel.id, .up).?);
    try testing.expectEqual(@as(u8, 2), model.selected_album);
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, model_mod.albums.len + 1 + model_mod.tracks_per_album), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, "Sea of Static") != null);

    // Type into the status-strip search field (the markup-declared
    // on-input handler): matches narrow across title/artist/album.
    apply(&model, .{ .select_album = 0 });
    tree = try buildTree(arena, &model);
    const field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(field.id, .{ .insert_text = "velvet" }).?);
    try testing.expectEqualStrings("velvet", model.search());
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, model_mod.albums.len + 1 + model_mod.tracks_per_album), countListItems(tree.root));

    // The markup clear button (icon-only) resets the query.
    const clear = findByLabel(tree.root, "Clear search").?;
    try testing.expectEqual(canvas.WidgetKind.button, clear.kind);
    try testing.expectEqualStrings("x", clear.icon);
    apply(&model, tree.msgForPointer(clear.id, .up).?);
    try testing.expectEqualStrings("", model.search());

    // No matches renders the NO SIGNAL plate instead of a list.
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("polka");
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "No tracks match") != null);
    try testing.expect(findByLabel(tree.root, "Track ledger") == null);
}

test "a full session: load from the ledger, queue via the context menu" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var tree = try buildTree(arena, &model);

    // Press a ledger row: the track loads and plays; the VFD lights up.
    const row = findByLabel(tree.root, "Glass").?;
    apply(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?u8, 7), model.now);
    try testing.expect(model.playing);
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "GLASS") != null);
    try testing.expectEqualStrings("pause", findByLabel(tree.root, "Play or pause").?.icon);
    try testing.expectEqualStrings("skip-back", findByLabel(tree.root, "Previous track").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(tree.root, "Next track").?.icon);

    // Pressing the loaded row again toggles pause; the power lamp drops
    // back to standby.
    const same_row = findByLabel(tree.root, "Glass").?;
    apply(&model, tree.msgForPointer(same_row.id, .up).?);
    try testing.expect(!model.playing);
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "STBY") != null);
    try testing.expectEqualStrings("play", findByLabel(tree.root, "Play or pause").?.icon);

    // Context-menu items dispatch typed messages: Play Next queues (the
    // amber Q plate appears), indexes past the declared items are inert.
    const undertow = findByLabel(tree.root, "Undertow").?;
    apply(&model, tree.msgForContextMenu(undertow.id, 0).?);
    try testing.expectEqual(@as(usize, 1), model.queue_len);
    try testing.expectEqual(@as(u8, 12), model.queue[0]);
    try testing.expect(tree.msgForContextMenu(undertow.id, 2) == null);
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .badge, "Q") != null);
    try testing.expect(findByText(tree.root, .badge, "QUEUE 1") != null);

    // The PERF face shows the queue as cue plates.
    apply(&model, .show_performance);
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Performance face") != null);
    try testing.expect(findByLabel(tree.root, "Track ledger") == null);
    try testing.expect(findByText(tree.root, .badge, "12 UNDERTOW") != null);
    apply(&model, .show_library);
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Track ledger") != null);
}

test "shortcut commands map to transport and face messages" {
    // The command table is the keyboard map (app.zon holds the same ids).
    try testing.expectEqual(Msg.toggle_play, main.command(main.cmd_play_pause).?);
    try testing.expectEqual(Msg.next_track, main.command(main.cmd_next).?);
    try testing.expectEqual(Msg.prev_track, main.command(main.cmd_prev).?);
    try testing.expectEqual(Msg.toggle_face, main.command(main.cmd_toggle_face).?);
    try testing.expectEqual(Msg.clear_search, main.command(main.cmd_dismiss).?);
    try testing.expect(main.command("deck.unknown") == null);

    // toggle_face flips LIB <-> PERF both ways; escape clears the query.
    var model = Model{};
    apply(&model, main.command(main.cmd_toggle_face).?);
    try testing.expectEqual(model_mod.View.performance, model.view);
    apply(&model, main.command(main.cmd_toggle_face).?);
    try testing.expectEqual(model_mod.View.library, model.view);
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("aurora");
    apply(&model, main.command(main.cmd_dismiss).?);
    try testing.expectEqualStrings("", model.search());
}

test "the spectrum is a deterministic function of the playback clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Idle: the powered-on noise floor, not a dead widget.
    var model = Model{};
    const idle_levels = model.spectrumLevels(arena);
    try testing.expectEqual(@as(usize, model_mod.spectrum_bands), idle_levels.len);
    for (idle_levels) |level| try testing.expect(level <= 0.05);

    // Same state -> identical bars (pure over track id + elapsed ms).
    apply(&model, .{ .play_track = 7 });
    model.elapsed_ms = 4200;
    const first = model.spectrumLevels(arena);
    const second = model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, first, second);
    for (first) |level| {
        try testing.expect(level >= 0);
        try testing.expect(level <= 1);
    }

    // Pause freezes the bars because the clock stops; a tick moves them.
    apply(&model, .toggle_play);
    const paused = model.spectrumLevels(arena);
    try testing.expectEqualSlices(f32, first, paused);
    model.elapsed_ms += model_mod.tick_ms;
    const advanced = model.spectrumLevels(arena);
    try testing.expect(!std.mem.eql(f32, first, advanced));

    // A different track reshapes the comb (per-track seed).
    var other = Model{};
    apply(&other, .{ .play_track = 20 });
    other.elapsed_ms = 4200;
    try testing.expect(!std.mem.eql(f32, first, other.spectrumLevels(arena)));

    // The tree carries the levels as ONE chart widget: phosphor bar bands
    // plus the paper-white peak trace, over an honest 0..1 domain.
    const tree = try buildTree(arena, &model);
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

test "the skin is dark-only; high contrast abandons it for the framework palette" {
    const live = try LiveApp.start();
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
    apply(&model, .{ .play_track = 3 });
    apply(&model, .{ .queue_track = 4 });
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
    const live = try LiveApp.start();
    defer live.stop();
    const app_state = live.app_state;

    // Press play through the real automation path: focus + key dispatch
    // through the widget route, exactly what `native automate` does.
    const play_id = try live.widgetIdByLabel(.button, "Play or pause");
    try live.widgetAction(play_id, "press");
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, 1), app_state.model.now);

    // Next/prev through the same path (ids can change across rebuilds:
    // re-resolve after each dispatch).
    try live.widgetAction(try live.widgetIdByLabel(.button, "Next track"), "press");
    try testing.expectEqual(@as(?u8, 2), app_state.model.now);
    try live.widgetAction(try live.widgetIdByLabel(.button, "Previous track"), "press");
    try testing.expectEqual(@as(?u8, 1), app_state.model.now);

    // Pause through the play key again.
    try live.widgetAction(try live.widgetIdByLabel(.button, "Play or pause"), "press");
    try testing.expect(!app_state.model.playing);

    // The status strip's PERF chip switches faces through the toggle path.
    const perf_id = try live.widgetIdByLabel(.toggle_button, "Performance face");
    try live.widgetAction(perf_id, "toggle");
    try testing.expectEqual(model_mod.View.performance, app_state.model.view);
    const lib_id = try live.widgetIdByLabel(.toggle_button, "Library face");
    try live.widgetAction(lib_id, "toggle");
    try testing.expectEqual(model_mod.View.library, app_state.model.view);
}

test "the chrome pass holds its exact command counts across model states" {
    // The chrome contract requires exactly prefix+suffix commands per
    // build; state-dependent marks move offscreen instead of dropping
    // out. Rebuild across the states that steer the pass: idle, playing
    // mid-song, PERF face, and high contrast.
    var states = [_]Model{ .{}, .{}, .{}, .{} };
    states[1].now = 7;
    states[1].playing = true;
    states[1].elapsed_ms = 84_500;
    states[2].now = 43;
    states[2].view = .performance;
    states[3].appearance = .{ .high_contrast = true };

    for (&states) |*model| {
        var commands: [1024]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try chrome.build(model, &builder, geometry.SizeF.init(main.window_width, main.window_height), main.tokensFromModel(model));
        try testing.expectEqual(chrome.prefix_commands + chrome.suffix_commands, builder.displayList().commands.len);
    }
}

test "every face lays out within the canvas and the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = 1 });
    apply(&model, .{ .queue_track = 43 });

    const cases = [_]struct { view: model_mod.View, album: u8 }{
        .{ .view = .library, .album = 0 },
        .{ .view = .library, .album = 2 },
        .{ .view = .performance, .album = 0 },
    };
    for (cases) |case| {
        model.view = case.view;
        model.selected_album = case.album;
        const tree = try buildTree(arena_state.allocator(), &model);
        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
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
    if (std.c.getenv("DECK_SHOTS") == null) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start();
    defer live.stop();

    // Hero: the full ledger, a track playing mid-song, one queued cue.
    // The mid-song position comes from REAL seek steps on the fader
    // (the widget keyboard path), so the fader, the VFD progress strip,
    // and the timecode all agree.
    try live.dispatch(.{ .play_track = 7 });
    try live.dispatch(.{ .queue_track = 12 });
    const seek_id = try live.widgetIdByLabel(.slider, "Seek");
    for (0..8) |_| try live.widgetAction(seek_id, "increment");
    try live.dispatch(.{ .select_album = 0 });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-library-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // A search narrowing the ledger (the dispatch after the buffer write
    // forces the rebuild the direct model mutation skipped).
    live.app_state.model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("light");
    try live.dispatch(.show_library);
    try presentShotFrame(live, 3);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-search-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");

    // PERF face: the analyzer fills the deck.
    live.app_state.model.search_buffer = .{};
    try live.dispatch(.show_performance);
    try presentShotFrame(live, 4);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/deck-shots/deck-perf-artifacts", "Deck");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot deck-canvas 2");
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
