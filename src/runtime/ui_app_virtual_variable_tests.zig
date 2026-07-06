//! Variable-extent windowed virtual lists, end to end through the app
//! loop: estimate→measure convergence of the scroll geometry, the
//! anchoring invariant under scroll storms (zero visible jumps), the
//! trailing (chat) anchor, and the `on_reach_start` /`on_reach_end`
//! hysteresis pair including the programmatic-jump re-arm nuance.
//!
//! The corpus is wildly variable ON PURPOSE — rows from one line
//! (~18pt) to a hundred lines (~1800pt), heights EXPLICIT so the tests
//! are deterministic across text-metric changes — and the estimate is
//! deliberately rough (rounded to 50pt bands) so the measured
//! corrections do real work.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const clock = @import("clock.zig");

const canvas_label = "transcript-canvas";
const viewport_height: f32 = 600;
const window_width: f32 = 400;

/// Actual row extent by LOGICAL index: 1..100 "lines" at 18pt.
fn actualExtent(logical: u64) f32 {
    const seed = std.hash.Wyhash.hash(0xcaa7_0001, std.mem.asBytes(&logical));
    return 18 * @as(f32, @floatFromInt(1 + seed % 100));
}

/// The app-provided estimate: rough on purpose (50pt bands, floored).
fn estimateExtent(context: ?*const anyopaque, logical: u64) f32 {
    _ = context;
    return @max(50, @round(actualExtent(logical) / 50) * 50 - 25);
}

const prepend_batch: usize = 50;

const TranscriptModel = struct {
    /// Logical index of the first loaded row.
    base: u64 = 1_000,
    /// Rows loaded right now.
    count: usize = 200,
    /// Tail-anchored (the chat contract) or leading (the feed shape).
    trailing: bool = true,
    /// Every reach-start dispatch, capped or not.
    start_fetches: u32 = 0,

    fn lastLogical(model: *const TranscriptModel) u64 {
        return model.base + @as(u64, model.count) - 1;
    }
};

const TranscriptMsg = union(enum) {
    load_older,
    append_one,
};

const TranscriptApp = ui_app_model.UiApp(TranscriptModel, TranscriptMsg);

fn transcriptUpdate(model: *TranscriptModel, msg: TranscriptMsg) void {
    switch (msg) {
        .load_older => {
            model.start_fetches += 1;
            const batch = @min(@as(u64, prepend_batch), model.base);
            model.base -= batch;
            model.count += @intCast(batch);
        },
        .append_one => model.count += 1,
    }
}

fn transcriptOptions(model: *const TranscriptModel) TranscriptApp.Ui.VirtualListOptions {
    return .{
        .id = "transcript",
        .item_count = model.count,
        .index_base = model.base,
        .item_extent = 0,
        .extent_estimate = estimateExtent,
        .overscan = 2,
        .grow = 1,
        .anchor = if (model.trailing) .trailing else .leading,
        // Only the transcript shape binds the history fetch: the
        // leading fixtures ride the corpus without growing it, so the
        // convergence and zero-jump proofs measure a FIXED truth.
        .on_reach_start = if (model.trailing) TranscriptMsg.load_older else null,
    };
}

/// Rows carry EXPLICIT heights derived from their logical identity, so
/// the engine's measure step reads deterministic extents while the
/// estimate stays rough — the convergence machinery is exercised
/// without depending on text metrics.
fn transcriptView(ui: *TranscriptApp.Ui, model: *const TranscriptModel) TranscriptApp.Ui.Node {
    const options = transcriptOptions(model);
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(TranscriptApp.Ui.Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (rows, 0..) |*row, offset| {
        const physical = window.start_index + offset;
        const logical = model.base + @as(u64, physical);
        var node = ui.listItem(.{ .height = actualExtent(logical) }, ui.fmt("Msg {d}", .{logical}));
        node.key = .{ .int = logical };
        row.* = node;
    }
    return ui.virtualList(options, window, .{rows});
}

const transcript_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const transcript_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Transcript",
    .width = window_width,
    .height = viewport_height,
    .views = &transcript_views,
}};
const transcript_scene: app_manifest.ShellConfig = .{ .windows = &transcript_windows };

fn transcriptCommand(name: []const u8) ?TranscriptMsg {
    if (std.mem.eql(u8, name, "transcript.append")) return .append_one;
    return null;
}

fn transcriptAppOptions() TranscriptApp.Options {
    return .{
        .name = "ui-app-variable-transcript",
        .scene = transcript_scene,
        .canvas_label = canvas_label,
        .update = transcriptUpdate,
        .view = transcriptView,
        .on_command = transcriptCommand,
    };
}

const transcript_id = canvas.globalWidgetId(.scroll_view, .{ .str = "transcript" });

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *TranscriptApp,
    app: core.App,

    fn create(model: TranscriptModel) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(window_width, viewport_height) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try std.testing.allocator.create(TranscriptApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = TranscriptApp.init(std.heap.page_allocator, model, transcriptAppOptions());
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(window_width, viewport_height),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn wheel(self: *Harness, delta: f32) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-wheel {s} {d} {d}", .{ canvas_label, transcript_id, delta });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn retainedList(self: *Harness) !canvas.WidgetLayoutNode {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        return layout.findById(transcript_id).?;
    }

    fn scrollState(self: *Harness) canvas.ScrollState {
        return self.harness.runtime.views[0].canvasWidgetScrollStateById(transcript_id).?;
    }

    /// Screen-space frame of a row by logical index, from the RETAINED
    /// layout (what the user sees), or null when unmounted.
    fn rowFrame(self: *Harness, logical: u64) !?geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        var list_index: ?usize = null;
        for (layout.nodes, 0..) |node, index| {
            if (node.widget.id == transcript_id) {
                list_index = index;
                break;
            }
        }
        const parent = list_index orelse return null;
        for (layout.nodes) |node| {
            const node_parent = node.parent_index orelse continue;
            if (node_parent != parent) continue;
            const item = node.widget.semantics.list_item_index orelse continue;
            if (self.app_state.model.base + @as(u64, item) == logical) return node.frame;
        }
        return null;
    }

    fn root(self: *Harness) canvas.Widget {
        return self.app_state.tree.?.root;
    }
};

fn findRow(widget: canvas.Widget, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == .list_item and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findRow(child, text)) |id| return id;
    }
    return null;
}

fn trueExtentBetween(first: u64, last: u64) f32 {
    var total: f32 = 0;
    var logical = first;
    while (logical <= last) : (logical += 1) total += actualExtent(logical);
    return total;
}

test "variable rows mount a bounded window; measured corrections converge the scroll geometry to truth" {
    var h = try Harness.create(.{ .trailing = false, .base = 0, .count = 300 });
    defer h.destroy();
    try std.testing.expect(h.app_state.installed);

    // Bounded mount at wildly variable extents: never the 300 rows.
    const list = try h.retainedList();
    try std.testing.expect(list.widget.children.len < 40);
    try std.testing.expect(list.widget.layout.virtual_total_extent > 0);

    // Ride the whole list so every row gets measured.
    const truth = trueExtentBetween(0, 299);
    var guard: usize = 0;
    while (guard < 2_000) : (guard += 1) {
        const state = h.scrollState();
        if (state.offset >= state.maxOffset() - 1) break;
        try h.wheel(viewport_height / 2);
    }
    try std.testing.expect(guard < 2_000);

    // Fully visited: the content extent the scrollbar (and the native
    // driver) reports is the measured truth, not the estimate.
    const state = h.scrollState();
    try std.testing.expectApproxEqAbs(truth, state.content_extent, 2);

    // And a row's identity is the message, not the slot: scroll back to
    // the top and the first row returns under its original id.
    const row_id = findRow(h.root(), "Msg 299").?;
    var back: usize = 0;
    while (back < 2_000) : (back += 1) {
        if (h.scrollState().offset <= 1) break;
        try h.wheel(-viewport_height);
    }
    try std.testing.expect(findRow(h.root(), "Msg 0") != null);
    var forward: usize = 0;
    while (forward < 2_000) : (forward += 1) {
        const s = h.scrollState();
        if (s.offset >= s.maxOffset() - 1) break;
        try h.wheel(viewport_height);
    }
    try std.testing.expectEqual(row_id, findRow(h.root(), "Msg 299").?);
}

test "scroll storm: corrections never move visible content (zero-jump invariant, both directions plus deep jumps)" {
    var h = try Harness.create(.{ .trailing = false, .base = 0, .count = 500 });
    defer h.destroy();

    // A deterministic storm: half-viewport steps down, viewport jumps,
    // reversals, and deep programmatic-sized jumps. At every step the
    // row that was visible before the wheel must land exactly
    // wheel-delta higher (within a point — the correction epsilon),
    // whatever estimate corrections the step's rebuild applied.
    var seed = std.Random.DefaultPrng.init(0xfeedface);
    const random = seed.random();
    var step: usize = 0;
    const storm_begin_ns = clock.monotonicNanoseconds();
    var checked: usize = 0;
    while (step < 400) : (step += 1) {
        const state = h.scrollState();
        const choice = random.uintLessThan(u8, 10);
        const delta: f32 = switch (choice) {
            0, 1, 2, 3 => viewport_height / 2,
            4, 5 => -viewport_height / 2,
            6 => viewport_height * 4,
            7 => -viewport_height * 4,
            8 => state.maxOffset() * 0.5 - state.offset,
            else => -state.offset,
        };

        // Anchor probe: the first mounted visible row before the step.
        const list = try h.retainedList();
        var probe_logical: ?u64 = null;
        var probe_frame: geometry.RectF = undefined;
        const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
        var list_index: usize = 0;
        for (layout.nodes, 0..) |node, index| {
            if (node.widget.id == transcript_id) list_index = index;
        }
        for (layout.nodes) |node| {
            const parent = node.parent_index orelse continue;
            if (parent != list_index) continue;
            const item = node.widget.semantics.list_item_index orelse continue;
            const frame = node.frame.normalized();
            // A row overlapping the middle of the viewport.
            if (frame.y <= list.frame.y + viewport_height / 2 and frame.maxY() >= list.frame.y + viewport_height / 2) {
                probe_logical = h.app_state.model.base + @as(u64, item);
                probe_frame = frame;
                break;
            }
        }

        try h.wheel(delta);

        // The invariant protects what the user SEES: after a wheel
        // that lands comfortably inside the scroll range, a row still
        // (partly) visible must sit exactly wheel-delta from where it
        // was. Corrections shift the OFFSET and the geometry together
        // (the offset absorbs them), so the offset may move by more or
        // less than the wheel — the pixels never do. Edge-clamped
        // steps are skipped: there the applied wheel is not the asked
        // wheel by design.
        const interior = state.offset + delta >= viewport_height and
            state.offset + delta <= state.maxOffset() - 2 * viewport_height and
            state.offset >= viewport_height and
            state.offset <= state.maxOffset() - 2 * viewport_height;
        if (interior) {
            if (probe_logical) |logical| {
                if (try h.rowFrame(logical)) |after_raw| {
                    const after = after_raw.normalized();
                    if (after.maxY() > list.frame.y and after.y < list.frame.y + viewport_height) {
                        try std.testing.expectApproxEqAbs(probe_frame.y - delta, after.y, 1.0);
                        checked += 1;
                    }
                }
            }
        }
    }
    const total_ns = clock.monotonicNanoseconds() - storm_begin_ns;
    // Coverage: the probe actually verified a healthy share of the
    // steps (the rest are edge-clamped or deep jumps whose probe left
    // the viewport).
    try std.testing.expect(checked > 100);
    // Generous ceiling (debug build, whole event->rebuild->layout->
    // measure->install pipeline per step): catches complexity
    // regressions, not machine noise.
    try std.testing.expect(total_ns / 400 < 50 * std.time.ns_per_ms);
}

test "trailing anchor: opens at the bottom, sticks through appends, never yanks a scrolled-away viewport" {
    var h = try Harness.create(.{ .trailing = true, .base = 1_000, .count = 200 });
    defer h.destroy();

    // First build: pinned to the bottom, last message visible.
    var state = h.scrollState();
    try std.testing.expectApproxEqAbs(state.maxOffset(), state.offset, 1);
    try std.testing.expect(findRow(h.root(), "Msg 1199") != null);

    // Appending while at the bottom keeps the pin: the new last message
    // is visible without any user scroll.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .menu_command = .{ .name = "transcript.append", .window_id = 1 } });
    state = h.scrollState();
    try std.testing.expectApproxEqAbs(state.maxOffset(), state.offset, 1);
    try std.testing.expect(findRow(h.root(), "Msg 1200") != null);

    // Scroll well away from the bottom and hold position on a row.
    try h.wheel(-viewport_height * 6);
    const anchored_logical: u64 = blk: {
        const list = try h.retainedList();
        break :blk h.app_state.model.base + @as(u64, list.widget.layout.virtual_first_index + 2);
    };
    const before = (try h.rowFrame(anchored_logical)).?;

    // An append must NOT yank the viewport: same row, same pixels.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .menu_command = .{ .name = "transcript.append", .window_id = 1 } });
    const after = (try h.rowFrame(anchored_logical)).?;
    try std.testing.expectApproxEqAbs(before.normalized().y, after.normalized().y, 1.0);
    const scrolled_state = h.scrollState();
    try std.testing.expect(scrolled_state.offset < scrolled_state.maxOffset() - viewport_height);
}

test "on_reach_start fires once per approach, the prepend keeps the viewport anchored, and the batch re-arms" {
    var h = try Harness.create(.{ .trailing = true, .base = 1_000, .count = 200 });
    defer h.destroy();
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.start_fetches);

    // Ride toward the top. The approach-start band is one viewport, so
    // step upward until the fetch fires — exactly once.
    var guard: usize = 0;
    while (h.app_state.model.start_fetches == 0 and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height / 2);
    }
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.start_fetches);
    try std.testing.expectEqual(@as(u64, 950), h.app_state.model.base);
    try std.testing.expectEqual(@as(usize, 250), h.app_state.model.count);

    // The anchoring contract of the prepend: the offset GREW by the
    // prepended extent (we are no longer near the start), so the next
    // scroll re-arms rather than re-firing, and the rows the user was
    // reading kept their identity.
    const state = h.scrollState();
    try std.testing.expect(state.offset > state.viewport_extent * ui_app_model.reach_start_rearm_ratio);
    try h.wheel(-24);
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.start_fetches);

    // The next full approach fires again.
    guard = 0;
    while (h.app_state.model.start_fetches == 1 and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height / 2);
    }
    try std.testing.expectEqual(@as(u32, 2), h.app_state.model.start_fetches);
}

test "reach-start hysteresis: riding an exhausted top never storms, and jumps re-arm like reach-end" {
    // Base 0: `load_older` has nothing left to prepend, so the offset
    // stays in the band — the fired flag must hold the line.
    var h = try Harness.create(.{ .trailing = true, .base = prepend_batch, .count = 200 });
    defer h.destroy();

    var guard: usize = 0;
    while (h.app_state.model.start_fetches == 0 and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height / 2);
    }
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.start_fetches);
    try std.testing.expectEqual(@as(u64, 0), h.app_state.model.base);

    // Ride the top: scroll to offset 0 and jiggle — no storm. (The
    // second batch's prepend re-armed and re-fired once on approach;
    // after base 0 the extent stops growing.)
    guard = 0;
    while (h.scrollState().offset > 0 and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height);
    }
    const fetches_at_top = h.app_state.model.start_fetches;
    try h.wheel(-24);
    try h.wheel(24);
    try h.wheel(-24);
    try std.testing.expectEqual(fetches_at_top, h.app_state.model.start_fetches);

    // The programmatic-jump nuance, mirrored from reach-end: hysteresis
    // state moves only on scroll observations. A deep jump away and a
    // jump back into the band fires exactly once more — the outbound
    // observation re-armed, the inbound one fired.
    const state = h.scrollState();
    try h.wheel(state.maxOffset()); // deep jump out (re-arms)
    try h.wheel(-h.scrollState().offset); // jump back to the top (fires)
    try std.testing.expectEqual(fetches_at_top + 1, h.app_state.model.start_fetches);
    try h.wheel(-24);
    try std.testing.expectEqual(fetches_at_top + 1, h.app_state.model.start_fetches);
}

test "prepends keep row identity: the same logical message keeps its widget id across a history load" {
    var h = try Harness.create(.{ .trailing = true, .base = 1_000, .count = 200 });
    defer h.destroy();

    // Scroll up until msg 1005 mounts.
    var guard: usize = 0;
    while (findRow(h.root(), "Msg 1005") == null and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height / 2);
    }
    const id_before = findRow(h.root(), "Msg 1005").?;
    const fetches_before = h.app_state.model.start_fetches;

    // Trigger at least one more prepend (approach the start).
    guard = 0;
    while (h.app_state.model.start_fetches == fetches_before and guard < 2_000) : (guard += 1) {
        try h.wheel(-viewport_height / 2);
    }
    try std.testing.expect(h.app_state.model.base < 1_000);

    // The same logical message, still mounted or remounted, keeps its
    // structural id: identity rides the logical key, never the slot.
    guard = 0;
    while (findRow(h.root(), "Msg 1005") == null and guard < 2_000) : (guard += 1) {
        try h.wheel(viewport_height / 2);
    }
    try std.testing.expectEqual(id_before, findRow(h.root(), "Msg 1005").?);
}
