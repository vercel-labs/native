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
    size: geometry.SizeF,

    fn start(image_decode: bool) !LiveApp {
        return startSized(image_decode, surface_size);
    }

    /// Start against an explicit surface size — the compact-shell tests
    /// run the same app on a phone-sized surface.
    fn startSized(image_decode: bool, size: geometry.SizeF) !LiveApp {
        // The same boot-time act main performs: install the app icon
        // table before any view builds, so app: markup references
        // resolve here exactly like in the shipped app.
        main.registerIcons();
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = size });
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
            .size = size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .size = size };
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

    /// One raw key_down through the REAL gpu input path — the same event
    /// a physical key press produces (key name plus the inserted text,
    /// when the key types one).
    fn keyDown(self: LiveApp, name: []const u8, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .{ .gpu_surface_input = .{
            .label = main.canvas_label,
            .kind = .key_down,
            .key = name,
            .text = text,
        } });
    }

    /// Resolve a live widget id by kind plus semantics label (falling
    /// back to the widget's text when the label is empty, the way tab
    /// segments carry only text). Ids can change across rebuilds:
    /// re-resolve after each dispatch.
    fn widgetIdByLabel(self: LiveApp, kind: canvas.WidgetKind, label: []const u8) !canvas.ObjectId {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind != kind) continue;
            if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.widget.id;
            if (node.widget.semantics.label.len == 0 and std.mem.eql(u8, node.widget.text, label)) return node.widget.id;
        }
        return error.WidgetNotFound;
    }

    /// Move keyboard focus onto a widget through the automation verb —
    /// what `native automate widget-action <view> <id> focus` does.
    /// This is QUIET focus (the pointer/programmatic contract, no ring):
    /// on a plain list row the runtime treats it as transparent to keys.
    fn focusWidget(self: LiveApp, id: canvas.ObjectId) !void {
        var command_buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ main.canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app_state.app(), line);
    }

    /// Escalate focus to the RING register — the state a Tab landing
    /// produces (focused AND focus-visible). Tests pin ring-vs-quiet
    /// behavior with this instead of scripting a whole Tab walk to the
    /// target, which would re-pin the tab order as a side effect.
    fn focusWidgetRing(self: LiveApp, id: canvas.ObjectId) !void {
        try self.focusWidget(id);
        for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |*view| {
            if (std.mem.eql(u8, view.label, main.canvas_label)) view.canvas_widget_focus_visible_id = id;
        }
    }

    /// The canvas view's focus-visible id (0 = no ring anywhere) — the
    /// assertion surface for "arrows never dress rows in the ring".
    fn focusVisibleId(self: LiveApp) canvas.ObjectId {
        for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |*view| {
            if (std.mem.eql(u8, view.label, main.canvas_label)) return view.canvas_widget_focus_visible_id;
        }
        return 0;
    }

    /// One raw pointer event through the real gpu input path, WITH a
    /// timestamp: the runtime derives multi-click counts from stamped
    /// downs (zero timestamps honestly never chain), so double-click
    /// tests must stamp like a real host does.
    fn pointer(self: LiveApp, kind: native_sdk.platform.GpuSurfaceInputKind, x: f32, y: f32, timestamp_ns: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = main.canvas_label,
            .kind = kind,
            .timestamp_ns = timestamp_ns,
            .x = x,
            .y = y,
        } });
    }

    /// A stamped click (down + up) at a point.
    fn click(self: LiveApp, x: f32, y: f32, timestamp_ns: u64) !void {
        try self.pointer(.pointer_down, x, y, timestamp_ns);
        try self.pointer(.pointer_up, x, y, timestamp_ns + 10 * std.time.ns_per_ms);
    }

    /// A live widget's laid-out frame by kind + label (label falls back
    /// to text, like `widgetIdByLabel`).
    fn widgetFrameByLabel(self: LiveApp, kind: canvas.WidgetKind, label: []const u8) !geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind != kind) continue;
            if (std.mem.eql(u8, node.widget.semantics.label, label) or
                (node.widget.semantics.label.len == 0 and std.mem.eql(u8, node.widget.text, label)))
            {
                return node.frame.normalized();
            }
        }
        return error.WidgetNotFound;
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

    // The manifest duration is the displayed total for the whole
    // playback; the platform's `.loaded` report is an estimate for this
    // catalog (the prepared files ship without a seek header) and only
    // lands in the mirror — the duration rule on `handleAudioEvent`.
    try testing.expectEqual(track.duration_ms, app_state.model.now_duration_ms);
    const decoded_ms: u64 = @as(u64, track.duration_ms) + 240;
    try fx.feedAudioEvent(.loaded, 0, decoded_ms, true);
    try live.wake();
    try testing.expectEqual(track.duration_ms, app_state.model.now_duration_ms);
    try testing.expectEqual(@as(u32, @intCast(decoded_ms)), app_state.model.platform_duration_ms);

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

test "a rail click on the seek bar jumps playback; a drag keeps scrubbing" {
    // Regression: the engine's slider pointer path applied the value as
    // a visual echo but never dispatched `on-change`, so clicking the
    // track-progress rail moved the thumb on screen while `.seeked`
    // never fired — no seekAudio, and the next position tick snapped
    // the bar back. This drives the REAL pointer pipeline: platform
    // pointer input on the rail -> the runtime jumps the thumb to the
    // pressed point -> `on-change` dispatches `.seeked` -> the sync
    // hook mirrors the fraction -> update forwards the target to the
    // player.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const track = model_mod.trackById(1);

    try live.dispatch(.{ .play_track = track.id });
    const duration_ms: u64 = track.duration_ms;
    try fx.feedAudioEvent(.loaded, 0, duration_ms, true);
    try live.wake();

    // The seek slider's laid-out rail, from the runtime's live layout.
    const rail = blk: {
        const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind == .slider) break :blk node.frame.normalized();
        }
        return error.TestUnexpectedResult;
    };
    const rail_y = rail.y + rail.height / 2;

    // Click 4/5 along the rail: playback jumps there in one press.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .pointer_down,
        .x = rail.x + rail.width * 0.8,
        .y = rail_y,
    } });
    try testing.expectApproxEqAbs(@as(f32, 0.8), app_state.model.seek_fraction, 0.001);
    const duration: f32 = @floatFromInt(app_state.model.now_duration_ms);
    try testing.expectApproxEqAbs(app_state.model.seek_fraction * duration, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), fx.audioSnapshot().position_ms);

    // Keep the press and drag back to 2/5: the scrub follows live, the
    // player seeking with every step.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .pointer_drag,
        .x = rail.x + rail.width * 0.4,
        .y = rail_y,
    } });
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = main.canvas_label,
        .kind = .pointer_up,
        .x = rail.x + rail.width * 0.4,
        .y = rail_y,
    } });
    try testing.expectApproxEqAbs(@as(f32, 0.4), app_state.model.seek_fraction, 0.001);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), fx.audioSnapshot().position_ms);

    // The next position tick reports from the seeked position, and the
    // RENDERED slider value (the played/remaining split) agrees with it
    // — seeking never desyncs the visual from the clock.
    const after_seek = fx.audioSnapshot().position_ms + 500;
    try fx.feedAudioEvent(.position, after_seek, duration_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, @intCast(after_seek)), app_state.model.elapsed_ms);
    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var slider_value: ?f32 = null;
    for (layout.nodes) |node| {
        if (node.widget.kind == .slider) slider_value = node.widget.value;
    }
    const expected_fraction = @as(f32, @floatFromInt(after_seek)) / duration;
    try testing.expectApproxEqAbs(expected_fraction, slider_value.?, 0.0001);
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

test "a divergent platform duration never moves the displayed total off the manifest" {
    // Regression: the transport bar used to adopt the platform player's
    // duration report as its total while the track lists rendered the
    // manifest value, so the same track showed two different lengths at
    // once. The platform's number is an ESTIMATE for this catalog (the
    // prepared files ship without a seek header, so a decoder can only
    // extrapolate from bitrate — a progressive stream's early guess has
    // measured minutes wrong, and even local playback reads seconds
    // long). The duration rule on `handleAudioEvent`: the manifest total
    // drives every display and the seek scale; the platform's report is
    // mirrored, never displayed while the manifest has a value.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const track = model_mod.trackById(1);

    try live.dispatch(.{ .play_track = track.id });

    // A wildly high estimate — the mid-stream guess class of error.
    const estimate_ms: u64 = @as(u64, track.duration_ms) + 104_000;
    try fx.feedAudioEvent(.loaded, 0, estimate_ms, true);
    try live.wake();
    try fx.feedAudioEvent(.position, 30_000, estimate_ms, true);
    try live.wake();

    // The displayed total stays the manifest value through the load and
    // every tick; the estimate is observable in the mirror only.
    try testing.expectEqual(track.duration_ms, app_state.model.now_duration_ms);
    try testing.expectEqual(@as(u32, @intCast(estimate_ms)), app_state.model.platform_duration_ms);

    // The two surfaces agree: the transport's total label is the exact
    // string the track list renders for the same track.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = app_state.model.albumTrackRows(arena, track.album);
    try testing.expectEqual(track.id, rows[0].id);
    try testing.expectEqualStrings(rows[0].duration, app_state.model.durationLabel(arena));

    // The scrubber fraction is elapsed over the MANIFEST total — sane,
    // not shrunk by the inflated estimate.
    const manifest_total: f32 = @floatFromInt(track.duration_ms);
    const expected_fraction = 30_000.0 / manifest_total;
    try testing.expectApproxEqAbs(expected_fraction, app_state.model.progressFraction(), 0.0001);

    // A seek lands where the user pointed on the displayed timeline:
    // the platform target is fraction times the manifest total, the
    // same scale the scrubber renders.
    const slider = findByKind(app_state.tree.?.root, .slider).?;
    var command_buffer: [96]u8 = undefined;
    const step = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} increment", .{ main.canvas_label, slider.id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), step);
    try testing.expect(app_state.model.seek_fraction > 0);
    const expected_target = app_state.model.seek_fraction * manifest_total;
    try testing.expectApproxEqAbs(expected_target, @as(f32, @floatFromInt(app_state.model.elapsed_ms)), 1);
    try testing.expectEqual(@as(u64, app_state.model.elapsed_ms), fx.audioSnapshot().position_ms);

    // Restarting a track resets the mirror with the rest of the
    // playback state.
    try live.dispatch(.{ .play_track = track.id + 1 });
    try testing.expectEqual(@as(u32, 0), app_state.model.platform_duration_ms);
    try testing.expectEqual(model_mod.trackById(track.id + 1).duration_ms, app_state.model.now_duration_ms);
}

test "space is the app-wide transport key; ring focus outranks it, quiet rows do not" {
    // The media-app convention, pinned end-to-end through the raw key
    // path (the exact gpu input events a physical spacebar produces).
    // The precedence rule under test, in order:
    //   1. a RING-focused interactive widget consumes space for its OWN
    //      activation (a tabbed-to track row selects, a header segment
    //      switches) — and Enter on a ring-focused row is the row's
    //      primary action: it plays;
    //   2. a QUIETLY focused plain list row (the state a click leaves
    //      behind) is transparent: space stays the transport toggle —
    //      clicking around a music library must never re-aim the
    //      spacebar;
    //   3. a focused editable field keeps typing — structural, by
    //      widget kind, so any future text field inherits it;
    //   4. otherwise — nothing focused, a slider, a bare scroll region —
    //      space falls through to the app-level transport toggle.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    // (4) From idle with NOTHING focused: space starts the catalog's
    // first track through the fallback — no widget was involved.
    try live.keyDown("space", " ");
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, model_mod.tracks[0].id), app_state.model.now);

    // ... and the next bare space pauses in place.
    try live.keyDown("space", " ");
    try testing.expect(!app_state.model.playing);

    // (2) QUIET focus on a DIFFERENT track row (what clicking it leaves
    // behind): space is still the transport — it RESUMES the loaded
    // track instead of playing the focused row, and the selection does
    // not move either.
    try live.dispatch(.show_songs);
    const other = &model_mod.tracks[2];
    try live.focusWidget(try live.widgetIdByLabel(.list_item, other.title));
    try live.keyDown("space", " ");
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, model_mod.tracks[0].id), app_state.model.now);

    // (1) RING focus on that row (the Tab contract): space activates
    // the row — it SELECTS, playback untouched — and Enter plays it.
    try live.focusWidgetRing(try live.widgetIdByLabel(.list_item, other.title));
    try live.keyDown("space", " ");
    try testing.expectEqual(@as(?u8, other.id), app_state.model.selected);
    try testing.expectEqual(@as(?u8, model_mod.tracks[0].id), app_state.model.now);
    try live.keyDown("enter", "");
    try testing.expectEqual(@as(?u8, other.id), app_state.model.now);
    try testing.expect(app_state.model.playing);

    // (1) Focus the header's Albums segment (a button-group button):
    // buttons keep their activation even under quiet focus — space
    // switches the tab and the transport does not move.
    try live.focusWidget(try live.widgetIdByLabel(.button, "Albums"));
    try live.keyDown("space", " ");
    try testing.expectEqual(model_mod.Tab.albums, app_state.model.tab);
    try testing.expect(app_state.model.playing);

    // (3) Focus the search field: a space keystroke is TYPING — the
    // character lands in the query and playback is untouched. The
    // exception is structural (widget kind), so it needs no per-field
    // wiring in the app.
    try live.focusWidget(try live.widgetIdByLabel(.search_field, "Search library"));
    try live.keyDown("space", " ");
    try testing.expectEqualStrings(" ", app_state.model.search());
    try testing.expect(app_state.model.playing);
    try testing.expectEqual(@as(?u8, other.id), app_state.model.now);
    try live.dispatch(.{ .search_edit = .clear });

    // (4) Focus the seek slider: space is not one of the slider's keys
    // (arrows step, home/end jump), so it falls through and pauses.
    try live.focusWidget(try live.widgetIdByLabel(.slider, "Seek"));
    try live.keyDown("space", " ");
    try testing.expect(!app_state.model.playing);

    // (4) Focus the album grid's scroll region: space is not a scroll
    // key either (arrows and page keys are), so it resumes from there
    // too — "anywhere" includes plain content focus.
    try live.focusWidget(try live.widgetIdByLabel(.scroll_view, "Album grid"));
    try live.keyDown("space", " ");
    try testing.expect(app_state.model.playing);
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
    // The audio files are gitignored (the prepare script produces
    // them). With no URL base a missing file surfaces as one `.failed`
    // event: playback clears, the now-playing bar tells the user what
    // to run, and the catalog keeps browsing — never a crash, never
    // silence.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;

    // The committed manifest ships a hosted streaming default, so the
    // assets notice is reachable only with the URL base cleared — the
    // state NATIVE_SDK_MUSIC_URL_BASE set empty produces at launch.
    app_state.model.setUrlBase("");

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

test "streaming is the committed default; the launch override replaces it" {
    // The committed manifest ships a hosted .url_base, so a fresh clone
    // streams the catalog with zero setup: a bare model boots with the
    // manifest value installed. setUrlBase — main's launch path for
    // NATIVE_SDK_MUSIC_URL_BASE — replaces it wholesale (trailing slash
    // trimmed so URL assembly stays uniform), and the empty override is
    // the one honest way to a local-only, notice-bearing state.
    var model = Model{};
    try testing.expect(model_mod.manifest_url_base.len > 0);
    try testing.expectEqualStrings(model_mod.manifest_url_base, model.urlBase());
    try testing.expect(model.streamingConfigured());
    model.setUrlBase("http://127.0.0.1:8000/pack/");
    try testing.expectEqualStrings("http://127.0.0.1:8000/pack", model.urlBase());
    model.setUrlBase("");
    try testing.expect(!model.streamingConfigured());
}

test "resolution order is honest: local file, then cache, then stream" {
    // The full source cascade against the null platform's fake player —
    // the same PlatformServices seam AVAudioPlayer/AVPlayer serve on
    // macOS — with the REAL effects executor, so the effects layer's
    // resolution (not a test stub) decides where the bytes come from.
    const live = try LiveApp.start(false);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const np = &live.harness.null_platform;
    fx.executor = .real;
    app_state.model.setUrlBase("https://music.example.test/pack/");
    app_state.model.setCacheDir("/tmp/fake-caches/soundboard");
    // 1. The prepared local file wins when it exists (the fake's
    //    default): no URL is ever consulted.
    try live.dispatch(.{ .play_track = 1 });
    try testing.expectEqual(native_sdk.EffectAudioSource.local, fx.audioSnapshot().source);
    try testing.expectEqual(@as(usize, 0), np.audio_load_url_count);

    // 2. Local assets absent: the same gesture streams on demand (a
    //    DIFFERENT track — playing the loaded one again is the
    //    play/pause toggle). The URL is the base + the manifest's
    //    relative file, and the effects channel reports the stream
    //    honestly (buffering until bytes).
    const track = model_mod.trackById(2);
    np.audio_local_files = false;
    try live.dispatch(.{ .play_track = track.id });
    try testing.expectEqual(native_sdk.EffectAudioSource.stream, fx.audioSnapshot().source);
    try testing.expect(fx.audioSnapshot().buffering);
    var url_buffer: [512]u8 = undefined;
    const expected_url = try std.fmt.bufPrint(&url_buffer, "https://music.example.test/pack/{s}", .{track.file});
    try testing.expectEqualStrings(expected_url, np.audio.path());

    // The now-playing bar shows the honest buffering state (distinct
    // from playing) once an event reports it.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.stallAudio().?);
    try testing.expect(app_state.model.buffering);
    const buffering_layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var saw_buffering = false;
    for (buffering_layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, model_mod.buffering_hint)) saw_buffering = true;
    }
    try testing.expect(saw_buffering);

    // The loaded acknowledgment clears the stall; playback proceeds.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.takeAudioLoaded().?);
    try testing.expect(!app_state.model.buffering);

    // 3. Completion installs the cache entry (the fake analog of the
    //    host's verify-then-rename). The completion auto-advances to
    //    the album's next track (a fresh stream); playing the FINISHED
    //    track again then resolves from cache — local playback, no
    //    stream, no buffering.
    const duration = np.audio.duration_ms;
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.advanceAudio(duration).?);
    try testing.expect(app_state.model.now != null);
    try testing.expect(app_state.model.now.? != track.id);
    try live.dispatch(.{ .play_track = track.id });
    try testing.expectEqual(native_sdk.EffectAudioSource.cache, fx.audioSnapshot().source);
    try testing.expect(!fx.audioSnapshot().buffering);
}

test "offline with a cold cache lands the honest stream-failed state" {
    const live = try LiveApp.start(false);
    defer live.stop();
    const app_state = live.app_state;
    const np = &live.harness.null_platform;
    app_state.effects.executor = .real;
    app_state.model.setUrlBase("https://music.example.test/pack");
    app_state.model.setCacheDir("/tmp/fake-caches/soundboard");
    np.audio_local_files = false;

    try live.dispatch(.{ .play_track = 1 });
    // The stream dies (offline, dead host, mid-flight drop): one
    // `.failed` event, and the notice names the NETWORK, not the
    // prepare script — with a URL base configured the assets hint
    // would be a lie.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), np.failAudio().?);
    try testing.expect(app_state.model.stream_failed);
    try testing.expect(!app_state.model.assets_missing);
    try testing.expectEqual(@as(?u8, null), app_state.model.now);

    const layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var saw_title = false;
    var saw_hint = false;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, model_mod.stream_failed_title)) saw_title = true;
        if (std.mem.eql(u8, node.widget.text, model_mod.stream_failed_hint)) saw_hint = true;
    }
    try testing.expect(saw_title);
    try testing.expect(saw_hint);

    // A fresh play clears the notice optimistically, exactly like the
    // assets notice.
    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.stream_failed);
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
    // skip-back/skip-forward glyphs, and the playing track row carries
    // its decorative STATE icon — the pause glyph while audio moves (a
    // bare .icon leaf — never hit-tested).
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, album_tracks[0].title) != null);
    try testing.expectEqualStrings("pause", findByLabel(tree.root, "Play or pause").?.icon);
    try testing.expectEqualStrings("skip-back", findByLabel(tree.root, "Previous track").?.icon);
    try testing.expectEqualStrings("skip-forward", findByLabel(tree.root, "Next track").?.icon);
    try testing.expect(findByText(tree.root, .icon, "pause") != null);

    // A single press on a different track row SELECTS it — playback
    // stays where it was; the double click (click count 2 on the
    // release) is what plays the row.
    const other = &album_tracks[2];
    const row = findByLabel(tree.root, other.title).?;
    apply(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?u8, other.id), model.selected);
    try testing.expectEqual(@as(?u8, album_tracks[0].id), model.now);
    apply(&model, tree.msgForPointerClick(row.id, .up, 2).?);
    try testing.expectEqual(@as(?u8, other.id), model.now);
    try testing.expect(model.playing);

    // Double-clicking the PLAYING row toggles pause in place.
    tree = try buildTree(arena, &model);
    const same_row = findByLabel(tree.root, other.title).?;
    apply(&model, tree.msgForPointerClick(same_row.id, .up, 2).?);
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

    // Default: light system appearance = the pack's light register with
    // the app's pink accent layered on (theme.zig exports the resolved
    // palettes, so these assertions follow the one source of truth).
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);

    // The accent override actually landed: the filled-primary pair, the
    // focus ring, and the slider's filled range all carry the same pink
    // step in BOTH schemes — the scrubber is the one slot the pack
    // states its own hue for, so it is pinned separately from `accent`.
    const pink = canvas.Color.rgb8(223, 38, 112);
    for ([_]canvas.ColorTokens{ theme.light_colors, theme.dark_colors }) |colors| {
        try testing.expectEqualDeep(pink, colors.accent);
        try testing.expectEqualDeep(canvas.Color.rgb8(255, 255, 255), colors.accent_text);
        try testing.expectEqualDeep(pink, colors.focus_ring);
    }
    for ([_]native_sdk.ColorScheme{ .light, .dark }) |scheme| {
        try testing.expectEqualDeep(pink, theme.tokens(scheme, false, false).controls.slider.active_background.?);
    }

    // The OS flips to dark; the app follows it - there is no in-window
    // theme control by design.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&app_state.model).colors);
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // And back to light.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // High contrast falls back to the pack's own loud register with no
    // brand layer (accessibility beats brand): white on the pink fill
    // sits near 4.5:1, under the loud-contrast bar, so the accent
    // honestly bows out — pinned by resolving the same pack register
    // the theme skips its overrides for.
    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    const pack_hc_dark = canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = .dark, .contrast = .high }).colors;
    try testing.expectEqualDeep(pack_hc_dark, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

test "the Albums/Songs switcher is a flush button group with one active segment" {
    // The header authors the switcher as `<button-group>` + `<button
    // selected=...>`: attached segments (the group's default gap of 0
    // collapses them into one bar with shared seams), each segment an
    // ordinary button, with the exclusive choice carried by the
    // `selected` bindings — exactly one segment is active at a time and
    // clicking the other one moves it.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    const Switcher = struct {
        fn segmentId(layout: canvas.WidgetLayoutTree, label: []const u8) ?canvas.ObjectId {
            for (layout.nodes) |node| {
                if (node.widget.kind != .button) continue;
                if (std.mem.eql(u8, node.widget.text, label)) return node.widget.id;
            }
            return null;
        }

        /// Exactly one BUTTON-GROUP segment is selected, and it is the
        /// named one. Scoped to buttons whose parent is the group so a
        /// future selected button elsewhere cannot satisfy the pin.
        fn expectExactlyOneActive(layout: canvas.WidgetLayoutTree, label: []const u8) !void {
            var active: usize = 0;
            var active_matches = false;
            for (layout.nodes) |node| {
                if (node.widget.kind != .button) continue;
                const parent_index = node.parent_index orelse continue;
                if (layout.nodes[parent_index].widget.kind != .button_group) continue;
                if (!node.widget.state.selected) continue;
                active += 1;
                if (std.mem.eql(u8, node.widget.text, label)) active_matches = true;
            }
            try testing.expectEqual(@as(usize, 1), active);
            try testing.expect(active_matches);
        }

        fn groupCount(layout: canvas.WidgetLayoutTree) usize {
            var groups: usize = 0;
            for (layout.nodes) |node| {
                if (node.widget.kind == .button_group) groups += 1;
            }
            return groups;
        }
    };

    // Default tab is Albums: the group exists, exactly one active
    // segment, and nothing lowers to the old tabs strip anymore.
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expectEqual(@as(usize, 1), Switcher.groupCount(layout));
    try Switcher.expectExactlyOneActive(layout, "Albums");
    for (layout.nodes) |node| {
        try testing.expect(node.widget.kind != .segmented_control);
        try testing.expect(node.widget.kind != .tabs);
    }

    // Click Songs through the real widget path: the model switches and
    // exactly one segment stays active.
    var command_buffer: [96]u8 = undefined;
    const songs_id = Switcher.segmentId(layout, "Songs").?;
    const click_songs = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, songs_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), click_songs);
    try testing.expectEqual(model_mod.Tab.songs, app_state.model.tab);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try Switcher.expectExactlyOneActive(layout, "Songs");

    // And back to Albums.
    const albums_id = Switcher.segmentId(layout, "Albums").?;
    const click_albums = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, albums_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), click_albums);
    try testing.expectEqual(model_mod.Tab.albums, app_state.model.tab);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try Switcher.expectExactlyOneActive(layout, "Albums");
}

test "single click selects, double click plays — through the real pointer path" {
    // The full gesture pipeline with STAMPED timestamps (the runtime
    // derives click counts from them; zero timestamps never chain):
    // click one = selection only, the rapid second click = playback,
    // and a slow third click re-selects without ever toggling playback.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.show_songs);
    const track = &model_mod.tracks[1];
    const frame = try live.widgetFrameByLabel(.list_item, track.title);
    const x = frame.x + frame.width / 2;
    const y = frame.y + frame.height / 2;

    // Click one: the row is selected, nothing plays.
    try live.click(x, y, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, track.id), app_state.model.selected);
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
    try testing.expect(!app_state.model.playing);

    // The rapid second click (within the 500 ms chain window, same
    // point) carries click count 2 on its release: the row PLAYS.
    try live.click(x, y, 250 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, track.id), app_state.model.now);
    try testing.expect(app_state.model.playing);

    // A SLOW third click (past the chain window) is a fresh single
    // click: it re-selects the row and playback does not toggle.
    try live.click(x, y, 2_000 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, track.id), app_state.model.selected);
    try testing.expect(app_state.model.playing);
}

test "arrows move the selection without playback or a focus ring; enter plays it" {
    // The selection-color-not-outline contract: after clicking a row
    // (which leaves QUIET focus on it), Up/Down walk the app's
    // selection — the accent row — while the runtime's focus ring stays
    // dark (focus-visible id 0; outlines belong to Tab), playback never
    // moves, and Enter plays whatever is selected.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try live.dispatch(.show_songs);
    const first = &model_mod.tracks[0];
    const frame = try live.widgetFrameByLabel(.list_item, first.title);
    try live.click(frame.x + frame.width / 2, frame.y + frame.height / 2, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, first.id), app_state.model.selected);
    try testing.expect(!app_state.model.playing);

    // Down walks to the next library track; no ring, no playback.
    try live.keyDown("arrowdown", "");
    try testing.expectEqual(@as(?u8, model_mod.tracks[1].id), app_state.model.selected);
    try testing.expect(!app_state.model.playing);
    try testing.expectEqual(@as(canvas.ObjectId, 0), live.focusVisibleId());

    // Up walks back; another Up at the top edge CLAMPS (no wrap).
    try live.keyDown("arrowup", "");
    try testing.expectEqual(@as(?u8, first.id), app_state.model.selected);
    try live.keyDown("arrowup", "");
    try testing.expectEqual(@as(?u8, first.id), app_state.model.selected);
    try testing.expectEqual(@as(canvas.ObjectId, 0), live.focusVisibleId());

    // Enter plays the selection.
    try live.keyDown("enter", "");
    try testing.expectEqual(@as(?u8, first.id), app_state.model.now);
    try testing.expect(app_state.model.playing);

    // The selection domain follows the view: on the album detail page
    // the arrows walk THAT record's tracks (dispatch-level — the same
    // messages the key fallback emits).
    const album = &model_mod.albums[1];
    try live.dispatch(.{ .open_album = album.id });
    try live.dispatch(.{ .select_track = model_mod.albumTracks(album.id)[0].id });
    try live.dispatch(.select_next);
    try testing.expectEqual(@as(?u8, model_mod.albumTracks(album.id)[1].id), app_state.model.selected);

    // On the album GRID (no track list on screen) arrows move nothing.
    try live.dispatch(.close_album);
    const before = app_state.model.selected;
    try live.dispatch(.select_next);
    try testing.expectEqual(before, app_state.model.selected);
}

test "the selected row wears the inverted accent register; tiles hover quiet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.tab = .songs;
    const selected = &model_mod.tracks[2];
    const unselected = &model_mod.tracks[0];
    apply(&model, .{ .select_track = selected.id });

    // The selected row: accent fill under the accent's knockout ink —
    // the per-widget style tokens resolve against the live theme, so the
    // assertion reads the same resolved colors the renderer will.
    // Deliberately re-pinned from the background token to `accent_text`:
    // background is only white in the light scheme (near-black in dark,
    // where it vanished into the accent fill), while `accent_text` is
    // the ink the theme pairs with the accent in BOTH schemes — the same
    // white the filled Play Album button wears.
    const tree = try buildTree(arena, &model);
    const row = findByLabel(tree.root, selected.title).?;
    try testing.expect(row.state.selected);
    try testing.expectEqualDeep(theme.light_colors.accent, row.style.background.?);
    const title = findByText(row, .text, selected.title).?;
    try testing.expectEqualDeep(theme.light_colors.accent_text, title.style.foreground.?);
    // The dark palette resolves the SAME knockout ink for this theme, so
    // the inverted row reads identically in both schemes.
    try testing.expectEqualDeep(theme.dark_colors.accent_text, title.style.foreground.?);

    // Unselected rows keep the composite's own state washes (no
    // override) and their ordinary ink.
    const other_row = findByLabel(tree.root, unselected.title).?;
    try testing.expect(!other_row.state.selected);
    try testing.expect(other_row.style.background == null);

    // Album tiles opt out of the HOVER wash through the toolkit's
    // quiet-surface style knob — hovering cover art changes nothing
    // visually (the pointer cursor is the affordance) — and carry no
    // background override at all, so the pressed wash and any themed
    // base fill keep their own channels.
    model.tab = .albums;
    const grid_tree = try buildTree(arena, &model);
    const album = &model_mod.albums[0];
    const tile_label = try std.fmt.allocPrint(arena, "{s} by {s}", .{ album.title, album.artist });
    const tile = findByLabel(grid_tree.root, tile_label).?;
    try testing.expect(tile.style.quiet_hover);
    try testing.expect(tile.style.background == null);
}

test "the transport buttons share one quiet register" {
    // Item: the play button must not carry the filled accent — all
    // three transport controls read as peers (sm ghost), with the
    // play/pause identity carried by the bound icon alone.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    const tree = try buildTree(arena_state.allocator(), &model);
    for ([_][]const u8{ "Previous track", "Play or pause", "Next track" }) |label| {
        const button = findByLabel(tree.root, label).?;
        try testing.expectEqual(canvas.WidgetKind.button, button.kind);
        try testing.expectEqual(canvas.WidgetVariant.ghost, button.variant);
        try testing.expectEqual(canvas.WidgetSize.sm, button.size);
    }
}

test "the waveform mark trails the now-playing title" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    apply(&model, .{ .play_track = 1 });
    const tree = try buildTree(arena_state.allocator(), &model);

    // Find the row that carries the title text and assert the icon
    // sits AFTER it in flow order — the wave reads as a listening
    // indicator trailing the name, not a leading bullet.
    const holder = findParentOfLabel(tree.root, "Now playing title").?;
    var title_index: ?usize = null;
    var icon_index: ?usize = null;
    for (holder.children, 0..) |child, index| {
        if (std.mem.eql(u8, child.semantics.label, "Now playing title")) title_index = index;
        if (child.kind == .icon and std.mem.eql(u8, child.icon, "app:waveform")) icon_index = index;
    }
    try testing.expect(title_index != null);
    try testing.expect(icon_index != null);
    try testing.expect(icon_index.? > title_index.?);
}

test "the loaded row's state icon names the play state" {
    // Item: the playing track's row shows the PAUSE glyph while audio
    // moves and the PLAY glyph while it is paused (the icon names the
    // state, like the transport button), and only the loaded row
    // carries an indicator at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.tab = .songs;
    apply(&model, .{ .play_track = 1 });
    var tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .icon, "pause") != null);
    try testing.expect(findByText(tree.root, .icon, "play") == null);

    apply(&model, .toggle_play);
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .icon, "play") != null);
    try testing.expect(findByText(tree.root, .icon, "pause") == null);
}

test "the scrubber interpolates between position ticks and never rewinds" {
    // The smooth-progress contract: while PLAYING, presented frames
    // advance the rendered clock between the player's 500 ms ticks;
    // tick corrections never rewind it mid-motion (small overruns hold
    // flat, only a past-slack desync snaps); paused frames are inert
    // (`on_frame` returns null — the idle law); and a resume across a
    // long gap steps gently (the frame-interval clamp), never lurches.
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;
    const fx = &app_state.effects;
    const model = &app_state.model;

    // One warm-up frame: the INSTALLING first frame never reaches
    // `on_frame`, so the surface width mirrors into the model here —
    // otherwise the first playing frame would spend itself on
    // `canvas_resized` instead of the clock.
    try presentFrameAt(live, 2, 1_500 * std.time.ns_per_ms);
    try testing.expectEqual(surface_size.width, model.canvas_width);

    try live.dispatch(.{ .play_track = 1 });
    const duration_ms: u64 = model_mod.trackById(1).duration_ms;
    try fx.feedAudioEvent(.loaded, 0, duration_ms, true);
    try live.wake();
    try fx.feedAudioEvent(.position, 500, duration_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, 500), model.elapsed_ms);

    // Frames at ~60 Hz advance the rendered clock monotonically.
    const frame_step_ns: u64 = 16_666_667;
    var timestamp: u64 = 2_000 * std.time.ns_per_ms;
    var previous = model.elapsed_ms;
    for (0..6) |index| {
        try presentFrameAt(live, 10 + index, timestamp);
        try testing.expect(model.elapsed_ms > previous);
        previous = model.elapsed_ms;
        timestamp += frame_step_ns;
    }

    // A tick slightly BEHIND the rendered clock (interpolation ran a
    // hair ahead) holds flat — the bar never visibly rewinds.
    const ahead = model.elapsed_ms;
    try fx.feedAudioEvent(.position, 500, duration_ms, true);
    try live.wake();
    try testing.expectEqual(ahead, model.elapsed_ms);

    // A forward tick applies immediately.
    try fx.feedAudioEvent(.position, 5_000, duration_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, 5_000), model.elapsed_ms);

    // A tick past the slack is a real desync (an external seek): snap.
    try fx.feedAudioEvent(.position, 100, duration_ms, true);
    try live.wake();
    try testing.expectEqual(@as(u32, 100), model.elapsed_ms);

    // PAUSE: the frame hook goes silent (null — no dispatch, so the
    // frame channel starves: the idle law) and the clock freezes
    // exactly, frame after frame.
    try live.dispatch(.toggle_play);
    try testing.expect(main.onFrame(model, .{ .size = surface_size, .timestamp_ns = timestamp }) == null);
    var frozen: [3]u32 = undefined;
    for (0..3) |index| {
        timestamp += frame_step_ns;
        try presentFrameAt(live, 20 + index, timestamp);
        frozen[index] = model.elapsed_ms;
    }
    try testing.expectEqualSlices(u32, &.{ 100, 100, 100 }, &frozen);

    // RESUME across the gap: the first frame's delta is clamped to a
    // few display intervals, so the clock steps gently instead of
    // swallowing the pause as playtime.
    try live.dispatch(.toggle_play);
    try testing.expect(main.onFrame(model, .{ .size = surface_size, .timestamp_ns = timestamp }) != null);
    timestamp += 3_000 * std.time.ns_per_ms; // a long stale gap
    try presentFrameAt(live, 30, timestamp);
    try testing.expect(model.elapsed_ms > 100);
    try testing.expect(model.elapsed_ms <= 100 + 67);
}

/// One presented frame with an explicit timestamp — the interpolation
/// tests' clock hand.
fn presentFrameAt(live: LiveApp, frame_index: u64, timestamp_ns: u64) !void {
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = live.size,
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = timestamp_ns,
        .nonblank = true,
    } });
}

/// The widget whose direct children include one labeled `label`.
fn findParentOfLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    for (widget.children) |child| {
        if (std.mem.eql(u8, child.semantics.label, label)) return widget;
        if (findParentOfLabel(child, label)) |found| return found;
    }
    return null;
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
        .size = live.size,
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

// Env-gated selection-round screenshot renderer (skipped by default,
// never in CI): renders the SONGS list with the selection and playback
// registers separated — one track playing (its state icon showing),
// a DIFFERENT track selected (the inverted accent row) — plus the
// button-group header and the quiet transport, once per color scheme.
// PNGs land in /tmp/selection-shots/soundboard-{light,dark}-artifacts/.
// To use:
//
//   SELECTION_SHOTS=1 zig build test
test "render selection screenshots (env-gated)" {
    if (!envGateSet("SELECTION_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // Playing one track a minute in, with ANOTHER track selected: the
    // playing row carries the pause state icon while the selected row
    // wears the accent fill — the two registers must read as different
    // things in one frame.
    try live.dispatch(.show_songs);
    try live.dispatch(.{ .play_track = model_mod.tracks[0].id });
    live.app_state.model.elapsed_ms = 67_500;
    try live.dispatch(.{ .select_track = model_mod.tracks[2].id });
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try presentShotFrame(live, 2);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/selection-shots/soundboard-light-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/selection-shots/soundboard-dark-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");
}

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): renders the docs-homepage showcase state OFFSCREEN through the
// deterministic reference renderer — the album grid with a track playing,
// once per color scheme, same state in both. PNGs land in
// /tmp/homepage-shots/soundboard-{light,dark}-artifacts/. To use
// (the magick loop prepares RGBA twins of the committed covers once —
// see the cover registration below for why):
//
//   mkdir -p /tmp/soundboard-art
//   for f in examples/soundboard/src/art/*.jpg; do
//     magick "$f" -depth 8 rgba:/tmp/soundboard-art/"$(basename "${f%.jpg}")".rgba
//   done
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start(true);
    defer live.stop();

    // The docs site overlays CSS stoplights on the capture, inside the
    // header's own chrome gap. Reserve that gap for real: the standard
    // macOS tall hidden-inset geometry (the same numbers the
    // chrome-geometry test pins) arrives through the app's chrome
    // channel, so the header pads exactly where the site's dots land.
    try live.dispatch(main.onChrome(.{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = geometry.RectF.init(20, 19, 52, 14),
    }).?);

    // Real covers for the hero. The committed art is JPEG, which the
    // null platform's strict PNG-subset decoder honestly refuses (the
    // degrade the cover tests pin), so the capture feeds RGBA twins of
    // the SAME committed files — prepared by the magick loop in the
    // header comment — back through the engine's own PNG writer and the
    // register channel `main.boot` uses: real art on the real
    // decode->register path, no side door into the registry.
    var art_arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer art_arena_state.deinit();
    const art_arena = art_arena_state.allocator();
    for (model_mod.albums, 0..) |album, index| {
        const art = album.art orelse continue;
        var path_buffer: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/tmp/soundboard-art/{s}.rgba", .{std.fs.path.stem(art)});
        const rgba = try readPreparedFile(io, art_arena, path);
        const side = std.math.sqrt(rgba.len / 4);
        try testing.expectEqual(side * side * 4, rgba.len);
        const encoded = try art_arena.alloc(u8, try canvas.png.encodedRgba8ByteLen(side, side));
        var png_writer = std.Io.Writer.fixed(encoded);
        try canvas.png.writeRgba8(&png_writer, side, side, rgba);
        _ = try live.app_state.effects.registerImageBytes(album.id, png_writer.buffered());
        live.app_state.model.covers[index] = album.id;
    }

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

// ------------------------------------------------------- adaptive grid

/// Per-row tile counts of the retained album grid: the frames of every
/// listitem-role tile, bucketed by row y. Returns the count of rows
/// written and fills `first_x` with the leading tile's x per row (the
/// tail-row left-align check).
fn gridRowCounts(layout: canvas.WidgetLayoutTree, counts: []usize, first_x: []f32) usize {
    var rows: usize = 0;
    var current_y: f32 = -1;
    for (layout.nodes) |node| {
        if (node.widget.semantics.role != .listitem) continue;
        if (node.widget.kind != .list_item) continue;
        if (rows == 0 or node.frame.y != current_y) {
            if (rows == counts.len) return rows;
            current_y = node.frame.y;
            counts[rows] = 0;
            first_x[rows] = node.frame.x;
            rows += 1;
        }
        counts[rows - 1] += 1;
        first_x[rows - 1] = @min(first_x[rows - 1], node.frame.x);
    }
    return rows;
}

/// Drive one full live resize: the window-manager resize event (the
/// runtime re-lays-out at the new bounds), then the frame it presents
/// at the new size (whose `on_frame` hook mirrors the width into the
/// model and rebuilds with the re-derived column count).
fn resizeTo(live: LiveApp, width: f32, height: f32, frame_index: u64) !void {
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .gpu_surface_resized = .{
        .label = main.canvas_label,
        .window_id = 1,
        .frame = geometry.RectF.init(0, 0, width, height),
        .scale_factor = 1,
    } });
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(width, height),
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

test "the album grid re-chunks its rows live as the window resizes" {
    const live = try LiveApp.start(true);
    defer live.stop();
    var counts: [8]usize = undefined;
    var first_x: [8]f32 = undefined;

    // The launch surface (1080 wide) fits four min-width tiles per row,
    // and the whole catalog chunks accordingly. Row counts and the
    // expected rows both derive from the manifest, never hardcoded.
    try resizeTo(live, main.window_width, main.window_height, 2);
    try testing.expectEqual(main.window_width, live.app_state.model.canvas_width);
    var fit = view_mod.gridFit(main.window_width);
    try testing.expectEqual(@as(usize, 4), fit.columns);
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    var rows = gridRowCounts(layout, &counts, &first_x);
    try expectChunking(rows, counts[0..rows], first_x[0..rows], fit.columns);

    // Widen the window: six tiles fit, the same catalog re-chunks into
    // fewer, longer rows, and the tail row (8 albums into rows of 6
    // leaves a short one) starts at the same leading edge as a full row.
    try resizeTo(live, 1520, 800, 3);
    try testing.expectEqual(@as(f32, 1520), live.app_state.model.canvas_width);
    fit = view_mod.gridFit(1520);
    try testing.expectEqual(@as(usize, 6), fit.columns);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    rows = gridRowCounts(layout, &counts, &first_x);
    try expectChunking(rows, counts[0..rows], first_x[0..rows], fit.columns);

    // And back down to the window's min floor: four per row again — the
    // path is live in both directions, not a one-shot at boot.
    try resizeTo(live, main.window_min_width, main.window_height, 4);
    fit = view_mod.gridFit(main.window_min_width);
    try testing.expectEqual(@as(usize, 4), fit.columns);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    rows = gridRowCounts(layout, &counts, &first_x);
    try expectChunking(rows, counts[0..rows], first_x[0..rows], fit.columns);
}

/// Assert one chunking: full rows of `columns` tiles, the catalog's
/// remainder in a final short row, and EVERY row starting at the same
/// leading x (the tail left-aligns instead of centering or stretching).
fn expectChunking(rows: usize, counts: []const usize, first_x: []const f32, columns: usize) !void {
    const albums = model_mod.albums.len;
    try testing.expectEqual((albums + columns - 1) / columns, rows);
    for (counts, 0..) |count, row| {
        const expected = if (row + 1 < rows or albums % columns == 0) columns else albums % columns;
        try testing.expectEqual(expected, count);
    }
    for (first_x) |x| {
        try testing.expectEqual(first_x[0], x);
    }
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
    try testing.expectEqual(@as(f32, 0), model.chrome_trailing);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, tall, &fx);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Windows delivers the min/max/close cluster on the TRAILING edge
    // instead: the leading pad collapses and the trailing one takes it.
    const windows_chrome = main.onChrome(.{
        .insets = .{ .top = 32, .right = 139 },
        .buttons = native_sdk.geometry.RectF.init(917, 0, 139, 32),
    }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, windows_chrome, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(@as(f32, 139), model.chrome_trailing);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // Linux (GTK client-side decorations) delivers the tall header-bar
    // band at exactly the 52 floor with the window-control cluster on
    // whichever edge the user's decoration layout picked — trailing
    // under the stock layout. The header keeps its natural height and
    // pads the trailing edge clear of the controls column.
    const gtk_chrome = main.onChrome(.{
        .insets = .{ .top = 52, .right = 114 },
        .buttons = native_sdk.geometry.RectF.init(962, 8, 100, 36),
    }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, gtk_chrome, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(@as(f32, 114), model.chrome_trailing);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);

    // Fullscreen zeroes the chrome: the pads collapse and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, cleared, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(@as(f32, 0), model.chrome_trailing);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);

    // The channel's top and bottom bands also land raw in the model —
    // the compact shell's safe-area pads (Dynamic Island / home
    // indicator on phones) — without the desktop header floor applied.
    const phone = main.onChrome(.{ .insets = .{ .top = 59, .bottom = 34 } }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, phone, &fx);
    try testing.expectEqual(@as(f32, 59), model.chrome_top);
    try testing.expectEqual(@as(f32, 34), model.chrome_bottom);
}

// ---------------------------------------------------------- compact shell

/// A mainstream phone-portrait surface (points), the compact suite's
/// stand-in for the full-screen mobile host.
const phone_size = geometry.SizeF.init(393, 852);

/// Whether any widget in the live layout carries this semantics label.
fn layoutHasLabel(layout: canvas.WidgetLayoutTree, label: []const u8) bool {
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return true;
    }
    return false;
}

test "the form-factor rule: compact strictly below the desktop floor" {
    // One strict comparison, no hysteresis: the boundary is the desktop
    // shell's proven min content width. AT the floor the desktop shell
    // holds (the layout audit proves that width); strictly below it —
    // widths no desktop window can reach, only phone-class surfaces —
    // the compact shell takes over.
    var model = Model{};
    try testing.expectEqual(model_mod.FormFactor.regular, model.formFactor());
    model.canvas_width = model_mod.min_canvas_width;
    try testing.expectEqual(model_mod.FormFactor.regular, model.formFactor());
    model.canvas_width = model_mod.min_canvas_width - 1;
    try testing.expectEqual(model_mod.FormFactor.compact, model.formFactor());
    model.canvas_width = phone_size.width;
    try testing.expectEqual(model_mod.FormFactor.compact, model.formFactor());
}

test "the host-reported form factor owns the shell switch when present" {
    // The window-chrome channel's size-class report wins over the width
    // derivation: a host that says compact gets the compact shell on
    // any width, and one that says regular gets the desktop shell even
    // on a phone-narrow surface. The width rule below stays exactly as
    // pinned above for hosts that never report.
    var model = Model{};
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 47, .bottom = 34 }, .form_factor = .compact } });
    model.canvas_width = main.window_width;
    try testing.expectEqual(model_mod.FormFactor.compact, model.formFactor());

    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 24, .bottom = 20 }, .form_factor = .regular } });
    model.canvas_width = phone_size.width;
    try testing.expectEqual(model_mod.FormFactor.regular, model.formFactor());

    // The report is sticky: a later chrome delivery that carries no
    // size class (an ordinary inset change) keeps the last host truth.
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 24, .bottom = 0 } } });
    try testing.expectEqual(model_mod.FormFactor.regular, model.formFactor());
}

/// Whether any widget in a laid-out tree is a button showing this text
/// (the compact switcher's Albums/Songs buttons carry text, not
/// semantics labels).
fn layoutHasButtonText(layout: canvas.WidgetLayoutTree, text: []const u8) bool {
    for (layout.nodes) |node| {
        if (node.widget.kind == .button and std.mem.eql(u8, node.widget.text, text)) return true;
    }
    return false;
}

test "the compact switcher yields to the projected native tab bar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Without a projecting host the compact header keeps its in-canvas
    // Albums/Songs switcher — the declaration is inert and the app is
    // whole on its own.
    var model = Model{};
    model.canvas_width = phone_size.width;
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    var tree = try buildTree(arena, &model);
    var layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, phone_size.width, phone_size.height), &nodes);
    try testing.expect(layoutHasButtonText(layout, "Albums"));
    try testing.expect(layoutHasButtonText(layout, "Songs"));

    // The chrome channel says a REAL native bar owns the tab affordance:
    // the in-canvas switcher yields (one switcher on screen, the
    // system's) while search keeps its full-width row.
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 47, .bottom = 83 }, .form_factor = .compact, .tabs_projected = true } });
    tree = try buildTree(arena, &model);
    layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, phone_size.width, phone_size.height), &nodes);
    try testing.expect(!layoutHasButtonText(layout, "Albums"));
    try testing.expect(!layoutHasButtonText(layout, "Songs"));
    var saw_search = false;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Search library")) saw_search = true;
    }
    try testing.expect(saw_search);

    // Navigation still flows through the same Msgs the bar's commands
    // map to — the projected bar and the canvas switcher are the same
    // journal entries.
    apply(&model, .show_songs);
    try testing.expectEqual(model_mod.Tab.songs, model.tab);

    // And the bar going away (the report clearing) restores the
    // in-canvas switcher: the yield is exactly as durable as the bar.
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 47, .bottom = 34 }, .form_factor = .compact, .tabs_projected = false } });
    apply(&model, .show_albums);
    tree = try buildTree(arena, &model);
    layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, phone_size.width, phone_size.height), &nodes);
    try testing.expect(layoutHasButtonText(layout, "Albums"));
}

test "the declared mobile tab set projects the model and maps taps back" {
    // The declaration: exactly the Albums/Songs pair, icons from the
    // app's registered vocabulary plus a built-in, no primary action
    // (the mini player owns the transport — a floating play control
    // would project playback twice).
    const options = main.mobileOptions();
    const chrome = options.scene.chrome;
    try testing.expectEqual(@as(usize, 2), chrome.tabs.len);
    try testing.expectEqualStrings("tabs.albums", chrome.tabs[0].id);
    try testing.expectEqualStrings("app:albums", chrome.tabs[0].icon);
    try testing.expectEqualStrings("tabs.songs", chrome.tabs[1].id);
    try testing.expectEqualStrings("music", chrome.tabs[1].icon);
    try testing.expect(chrome.primary_action == null);
    try native_sdk.app_manifest.validateShellChrome(chrome);

    // Round trip: the model's selection derives each declared id, and
    // the declared ids map back onto the exact Msgs the in-canvas
    // switcher dispatches — one journal, two entry points.
    var model = Model{};
    try testing.expectEqualStrings("tabs.albums", main.selectedTab(&model));
    apply(&model, main.onCommand("tabs.songs").?);
    try testing.expectEqual(model_mod.Tab.songs, model.tab);
    try testing.expectEqualStrings("tabs.songs", main.selectedTab(&model));
    apply(&model, main.onCommand("tabs.albums").?);
    try testing.expectEqual(model_mod.Tab.albums, model.tab);
    try testing.expect(main.onCommand("tabs.unknown") == null);
}

test "the navigation projection follows the visible page stack" {
    // The declaration: the depth derivation and the back command ride
    // the mobile options together (a gesture that could dispatch
    // nothing must never arm).
    const options = main.mobileOptions();
    try testing.expect(options.navigation_depth_fn != null);
    try testing.expectEqualStrings("nav.back", options.navigation_back_command);

    // Depth follows the VISIBLE page: the grid is the root, an open
    // album is one push in — but only while the Albums tab shows it.
    var model = Model{};
    try testing.expectEqual(@as(usize, 0), main.navigationDepth(&model));
    apply(&model, .{ .open_album = 3 });
    try testing.expectEqual(@as(usize, 1), main.navigationDepth(&model));

    // A tab switch with the detail open is LATERAL: depth drops with
    // the selected tab (the host reconciles without a transition), and
    // switching back restores it — `open_album` never moved.
    apply(&model, main.onCommand("tabs.songs").?);
    try testing.expectEqual(@as(usize, 0), main.navigationDepth(&model));
    try testing.expectEqual(@as(?u8, 3), model.open_album);
    apply(&model, main.onCommand("tabs.albums").?);
    try testing.expectEqual(@as(usize, 1), main.navigationDepth(&model));

    // The completed edge-swipe dispatches the declared back command,
    // which maps onto the exact Msg the in-canvas back button sends —
    // one journal, two entry points, depth answers 0 either way.
    const back = main.onCommand("nav.back") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Msg.close_album, back);
    apply(&model, back);
    try testing.expectEqual(@as(?u8, null), model.open_album);
    try testing.expectEqual(@as(usize, 0), main.navigationDepth(&model));

    // Replay determinism: the same journal into two fresh models lands
    // identical depth readouts at every step — the projection is a pure
    // derivation, so a journal replayed without a host is identical.
    const journal = [_]Msg{
        .{ .open_album = 2 }, .show_songs, .show_albums, .close_album,
        .{ .open_album = 5 }, .close_album,
    };
    var first = Model{};
    var second = Model{};
    var depths_first: [journal.len]usize = undefined;
    var depths_second: [journal.len]usize = undefined;
    for (journal, 0..) |msg, index| {
        apply(&first, msg);
        depths_first[index] = main.navigationDepth(&first);
    }
    for (journal, 0..) |msg, index| {
        apply(&second, msg);
        depths_second[index] = main.navigationDepth(&second);
    }
    try testing.expectEqualSlices(usize, &depths_first, &depths_second);
    try testing.expectEqual(first.tab, second.tab);
    try testing.expectEqual(first.open_album, second.open_album);
}

test "the mobile entry is independent of the desktop window constants" {
    // The mobile scene is the canonical full-screen surface: no desktop
    // width, min-size floor, or titlebar constrains the phone.
    const options = main.mobileOptions();
    try testing.expectEqualStrings(native_sdk.embed.mobile_gpu_surface_label, options.canvas_label);
    const window = options.scene.windows[0];
    try testing.expectEqual(@as(f32, 0), window.min_width);
    try testing.expectEqual(@as(f32, 0), window.min_height);
    try testing.expectEqual(.standard, window.titlebar);

    // The mobile boot model seeds a phone-portrait canvas width, so the
    // installing frame already composes the compact shell — never one
    // desktop-shaped frame flashed onto a 390pt surface.
    const model = main.initModel();
    try testing.expectEqual(model_mod.FormFactor.compact, model.formFactor());

    // The streaming track cache is wired at the mobile boot exactly like
    // the desktop launch: `initModel` resolves the platform cache
    // directory once (env-driven through libc — the embed entry has no
    // `std.process.Init`), so `fx.playAudio` carries a real cache_path
    // on phones and a streamed track downloads once, not on every play.
    // A libc-less test build has no environment to read; there the boot
    // honestly leaves the cache disabled and this pins that instead.
    if (comptime @import("builtin").link_libc) {
        try testing.expect(model.cacheDir().len > 0);
    } else {
        try testing.expectEqual(@as(usize, 0), model.cacheDir().len);
    }
}

test "the shell switches at the boundary width through the live resize path" {
    const live = try LiveApp.start(true);
    defer live.stop();

    // The launch surface is desktop-shaped: the markup header (window
    // drag band, chrome spacers) is on screen and no compact chrome is.
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Soundboard header"));
    try testing.expect(!layoutHasLabel(layout, "Compact header"));
    try testing.expect(layoutHasLabel(layout, "Now playing bar"));

    // Resize below the boundary: the same app recomposes as the compact
    // shell — stacked touch header, no desktop bars, and no window-drag
    // region anywhere (phones own their chrome).
    try resizeTo(live, phone_size.width, phone_size.height, 2);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Compact header"));
    try testing.expect(!layoutHasLabel(layout, "Soundboard header"));
    try testing.expect(!layoutHasLabel(layout, "Now playing bar"));
    for (layout.nodes) |node| {
        try testing.expect(!node.widget.window_drag);
    }
    // Search stays reachable in the compact shell (full-width row).
    try testing.expect(layoutHasLabel(layout, "Search library"));

    // And back above the boundary: the desktop shell returns — the
    // switch is live in both directions, driven only by the width Msg.
    try resizeTo(live, main.window_width, main.window_height, 3);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Soundboard header"));
    try testing.expect(!layoutHasLabel(layout, "Compact header"));
}

test "the mini bar stays visible through playback, pause, and the honest notice" {
    const live = try LiveApp.startSized(true, phone_size);
    defer live.stop();
    const app_state = live.app_state;
    try resizeTo(live, phone_size.width, phone_size.height, 2);

    // Idle: no mini bar — nothing is loaded and no notice needs a home.
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(!layoutHasLabel(layout, "Now playing mini bar"));

    // Play: the bar appears with the cover thumb, the track's title, and
    // the pause glyph (the icon names the state).
    const track = model_mod.trackById(1);
    try live.dispatch(.{ .play_track = track.id });
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Now playing mini bar"));
    try testing.expect(layoutHasLabel(layout, "Now playing cover"));
    var saw_title = false;
    var play_pause_icon: []const u8 = "";
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, track.title)) saw_title = true;
        if (std.mem.eql(u8, node.widget.semantics.label, "Play or pause")) play_pause_icon = node.widget.icon;
    }
    try testing.expect(saw_title);
    try testing.expectEqualStrings("pause", play_pause_icon);

    // Pause IN the bar (the real widget path): the bar must not vanish —
    // a paused track is still loaded — and the glyph flips to play.
    const toggle_id = try live.widgetIdByLabel(.button, "Play or pause");
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, toggle_id });
    try live.harness.runtime.dispatchAutomationCommand(app_state.app(), click);
    try testing.expect(!app_state.model.playing);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Now playing mini bar"));
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Play or pause")) {
            try testing.expectEqualStrings("play", node.widget.icon);
        }
    }

    // A failed load clears playback but raises the notice — the bar
    // stays up to carry it (with no transport rail, it is the compact
    // shell's only status surface). The URL base is cleared first: the
    // committed manifest ships a hosted streaming default, and the
    // assets notice exists only for the streaming-disabled state.
    app_state.model.setUrlBase("");
    try live.dispatch(.toggle_play);
    try app_state.effects.feedAudioEvent(.failed, 0, 0, false);
    try live.wake();
    try testing.expect(app_state.model.assets_missing);
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Now playing mini bar"));
    var saw_notice = false;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, model_mod.assets_missing_title)) saw_notice = true;
    }
    try testing.expect(saw_notice);
}

test "compact navigation: tap opens the record, back returns, one tap plays" {
    const live = try LiveApp.startSized(true, phone_size);
    defer live.stop();
    const app_state = live.app_state;
    try resizeTo(live, phone_size.width, phone_size.height, 2);

    // Tap the first album tile (a real stamped touch press): the record
    // opens as a full-surface page — model-driven navigation.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const album = &model_mod.albums[0];
    const tile_label = try std.fmt.allocPrint(arena_state.allocator(), "{s} by {s}", .{ album.title, album.artist });
    const tile = try live.widgetFrameByLabel(.list_item, tile_label);
    try live.click(tile.x + tile.width / 2, tile.y + tile.height / 2, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, album.id), app_state.model.open_album);
    var layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Album detail"));

    // ONE tap on a track row PLAYS it — the touch convention (no
    // double-tap gesture, no hover, no selection-first step)...
    const first_track = &model_mod.albumTracks(album.id)[0];
    const row = try live.widgetFrameByLabel(.list_item, first_track.title);
    try live.click(row.x + row.width / 2, row.y + row.height / 2, 2_000 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, first_track.id), app_state.model.now);
    try testing.expect(app_state.model.playing);

    // ... and the compact rows mount NO context menus: right-click is
    // pointer vocabulary and the phone hosts model no long-press.
    const row_id = try live.widgetIdByLabel(.list_item, first_track.title);
    try testing.expect(app_state.tree.?.msgForContextMenu(row_id, 0) == null);

    // Back is the same model state the desktop back drives: the grid
    // returns (with the mini bar still up — playback survives paging).
    const back = try live.widgetFrameByLabel(.button, "Back to albums");
    try live.click(back.x + back.width / 2, back.y + back.height / 2, 4_000 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u8, null), app_state.model.open_album);
    layout = try live.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layoutHasLabel(layout, "Album grid"));
    try testing.expect(layoutHasLabel(layout, "Now playing mini bar"));
}

test "safe-area insets pad the compact shell top and bottom" {
    const live = try LiveApp.startSized(true, phone_size);
    defer live.stop();
    try resizeTo(live, phone_size.width, phone_size.height, 2);

    // The phone bands arrive through the same window-chrome channel the
    // desktop titlebar uses (the iOS host republishes safe areas there).
    const chrome = main.onChrome(.{ .insets = .{ .top = 59, .bottom = 34 } }) orelse return error.TestUnexpectedResult;
    try live.dispatch(chrome);
    try live.dispatch(.{ .play_track = 1 });

    // The header clears the Dynamic Island band; the mini bar sits
    // above the home-indicator band — content under neither.
    const header = try live.widgetFrameByLabel(.column, "Compact header");
    try testing.expect(header.y >= 59);
    const bar = try live.widgetFrameByLabel(.column, "Now playing mini bar");
    try testing.expect(bar.y + bar.height <= phone_size.height - 34);
}

test "compact touch targets clear the 44pt floor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.canvas_width = phone_size.width;
    apply(&model, .{ .play_track = 1 });

    // Every page the compact shell can show, with the mini bar mounted:
    // every pressable control — buttons, the search field, list rows —
    // lays out at least 44pt tall (whole album tiles tower past it).
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
        // Layout with the app's REAL tokens: the touch floor is a claim
        // about the shipped control metrics, not the default pack's.
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, phone_size.width, phone_size.height), main.tokensFromModel(&model), &nodes);
        var interactive: usize = 0;
        for (layout.nodes) |node| {
            switch (node.widget.kind) {
                .button, .search_field, .list_item => {
                    interactive += 1;
                    try testing.expect(node.frame.normalized().height >= 44);
                },
                else => {},
            }
        }
        try testing.expect(interactive > 0);
        _ = arena_state.reset(.retain_capacity);
    }
}

test "one Msg journal drives both shells deterministically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One journal, crossing the form-factor boundary in both directions
    // mid-stream. Every entry is an ordinary Msg — the shell is a pure
    // derivation of the model, so identical journals into identical
    // initial models must land identical shells and identical trees at
    // every step, with no clock, host, or ordering dependence anywhere.
    const album = &model_mod.albums[1];
    const journal = [_]Msg{
        .{ .canvas_resized = phone_size.width },
        .{ .chrome_changed = .{ .insets = .{ .top = 59, .bottom = 34 } } },
        .{ .open_album = album.id },
        .{ .play_track = model_mod.albumTracks(album.id)[0].id },
        .{ .canvas_resized = 1520 },
        .close_album,
        .show_songs,
        .{ .canvas_resized = model_mod.compact_seed_canvas_width },
        // The host-reported channel mid-journal: the size class takes
        // the switch over from the width, the projected-tabs flag
        // reshapes the compact header, and a later width Msg no longer
        // moves the shell — all of it plain Msg data, so determinism
        // holds through the host reports too.
        .{ .chrome_changed = .{ .insets = .{ .top = 47, .bottom = 34 }, .form_factor = .regular } },
        .{ .chrome_changed = .{ .insets = .{ .top = 47, .bottom = 83 }, .form_factor = .compact, .tabs_projected = true } },
        .{ .canvas_resized = 1520 },
    };
    const expected_form = [journal.len]model_mod.FormFactor{
        .compact, .compact, .compact, .compact,
        .regular, .regular, .regular, .compact,
        .regular, .compact,  .compact,
    };

    var first = Model{};
    var second = Model{};
    for (journal, expected_form) |msg, form| {
        apply(&first, msg);
        apply(&second, msg);
        try testing.expectEqual(form, first.formFactor());
        try testing.expectEqual(form, second.formFactor());

        const first_tree = try buildTree(arena, &first);
        const second_tree = try buildTree(arena, &second);
        var first_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer first_ids.deinit(testing.allocator);
        var second_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer second_ids.deinit(testing.allocator);
        try collectIds(first_tree.root, &first_ids, testing.allocator);
        try collectIds(second_tree.root, &second_ids, testing.allocator);
        try testing.expectEqualSlices(canvas.ObjectId, first_ids.items, second_ids.items);
        _ = arena_state.reset(.retain_capacity);
    }
}

test "every compact view lays out within the phone canvas and the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.canvas_width = phone_size.width;
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
        const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, phone_size.width, phone_size.height), &nodes);
        try testing.expect(layout.nodes.len > 0);
        try testing.expect(layout.nodes.len < 768);
        _ = arena_state.reset(.retain_capacity);
    }
}

/// The compact sweep floor: the narrowest mainstream phone (320pt
/// portrait). The compact grid tree derives its columns from THIS width
/// so a swept-wider surface can only underfill, mirroring how the
/// desktop suite seeds its trees at the desktop floor.
const compact_min_size = geometry.SizeF.init(320, 568);

test "compact layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.canvas_width = compact_min_size.width;
    apply(&model, .{ .play_track = 1 });
    // Sweep with the phone bands applied: the safe-area spacers are part
    // of the composition the audit must prove clean.
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 59, .bottom = 34 } } });

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
            .min_size = compact_min_size,
            .default_size = phone_size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

test "compact a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.canvas_width = compact_min_size.width;
    apply(&model, .{ .play_track = 1 });
    apply(&model, .{ .chrome_changed = .{ .insets = .{ .top = 59, .bottom = 34 } } });

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
            .min_size = compact_min_size,
            .default_size = phone_size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

// Env-gated compact-shell screenshot renderer (skipped by default, never
// in CI): renders the COMPACT shell OFFSCREEN on a phone-sized surface
// through the deterministic reference renderer — the album grid with the
// mini bar up, and the album detail page, once per color scheme. PNGs
// land in /tmp/compact-shots/soundboard-compact-*-artifacts/. To use:
//
//   COMPACT_SHOTS=1 zig build test
test "render compact-shell screenshots (env-gated)" {
    if (!envGateSet("COMPACT_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.startSized(true, phone_size);
    defer live.stop();
    try resizeTo(live, phone_size.width, phone_size.height, 2);
    try live.dispatch(main.onChrome(.{ .insets = .{ .top = 59, .bottom = 34 } }).?);

    // Grid with the mini player up, a minute into a track.
    try live.dispatch(.{ .play_track = model_mod.albumTracks(2)[0].id });
    live.app_state.model.elapsed_ms = 67_500;
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try presentShotFrame(live, 3);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/compact-shots/soundboard-compact-grid-light-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/compact-shots/soundboard-compact-grid-dark-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    // The full-surface album detail page, both schemes.
    try live.dispatch(.{ .open_album = 2 });
    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try presentShotFrame(live, 4);
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/compact-shots/soundboard-compact-detail-light-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");

    try live.harness.runtime.dispatchPlatformEvent(live.app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/compact-shots/soundboard-compact-detail-dark-artifacts", "Soundboard");
    try live.harness.runtime.dispatchAutomationCommand(live.app_state.app(), "screenshot soundboard-canvas 2");
}
