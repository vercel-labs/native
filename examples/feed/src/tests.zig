const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const FeedUi = main.FeedUi;
const FeedApp = native_sdk.UiApp(Model, Msg);

const timeline_id = canvas.globalWidgetId(.scroll_view, .{ .str = "timeline" });

fn feedOptions() FeedApp.Options {
    return .{
        .name = "feed",
        .scene = main.shell_scene,
        .canvas_label = main.canvas_label,
        .update = main.update,
        .view = main.view,
    };
}

/// ESTIMATED leading edge of post `index` (prefix sum over the same
/// estimate fn the view hands the engine) — how tests aim the pinned
/// window source at a post's neighborhood.
fn estimatedOffsetAt(index: usize) f32 {
    var offset: f32 = 0;
    for (0..index) |i| offset += main.postExtentEstimate(null, @intCast(i));
    return offset;
}

// ------------------------------------------------------------ tree helpers

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

fn subtreeHasText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (subtreeHasText(child, text)) return true;
    }
    return false;
}

/// A pinned window source, standing in for the runtime's retained
/// scroll state in pure-tree tests.
const PinnedSource = struct {
    state: canvas.VirtualWindowState,

    fn resolve(context: ?*anyopaque, id: canvas.ObjectId) ?canvas.VirtualWindowState {
        _ = id;
        const self: *PinnedSource = @ptrCast(@alignCast(context.?));
        return self.state;
    }
};

fn buildTreeAt(arena: std.mem.Allocator, model: *const Model, offset: f32, viewport: f32) !FeedUi.Tree {
    var source = PinnedSource{ .state = .{ .offset = offset, .viewport_extent = viewport, .mounted = true } };
    var ui = FeedUi.init(arena);
    ui.virtual_window_context = @ptrCast(&source);
    ui.virtual_window_source = PinnedSource.resolve;
    return ui.finalize(main.view(&ui, model));
}

// -------------------------------------------------------------- pure model

test "posts derive deterministically from their index" {
    const a = main.postAt(41_777);
    const b = main.postAt(41_777);
    try testing.expectEqualStrings(a.author, b.author);
    try testing.expectEqualStrings(a.subject, b.subject);
    try testing.expectEqual(a.likes, b.likes);
    try testing.expectEqual(a.minutes_ago, b.minutes_ago);

    // Different indices land on different content somewhere in the row.
    const c = main.postAt(41_778);
    const same = std.mem.eql(u8, a.author, c.author) and
        std.mem.eql(u8, a.subject, c.subject) and
        a.likes == c.likes;
    try testing.expect(!same);
}

test "bodies are mixed-height on purpose and the estimate is a pure model fact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The corpus really is mixed: shorts, longer takes (every 13th),
    // and long-form walls (every 47th).
    try testing.expect(main.postBodySentences(1) <= 3);
    try testing.expect(main.postBodySentences(13) >= 6);
    try testing.expect(main.postBodySentences(47) >= 14);

    // postBodyLength prices the body without building it.
    for ([_]usize{ 0, 1, 13, 47, 99_999 }) |index| {
        try testing.expectEqual(main.postBody(arena, index).len, main.postBodyLength(index));
    }

    // Estimates vary by a real factor across the corpus — this is the
    // variable-extent showcase, not a uniform list in disguise.
    var min_estimate: f32 = std.math.floatMax(f32);
    var max_estimate: f32 = 0;
    for (0..200) |i| {
        const estimate = main.postExtentEstimate(null, @intCast(i));
        min_estimate = @min(min_estimate, estimate);
        max_estimate = @max(max_estimate, estimate);
    }
    try testing.expect(max_estimate > min_estimate * 2);
}

test "update appends batches to the corpus cap and keys interaction by post index" {
    var model = Model{};
    try testing.expectEqual(main.initial_batch, model.loaded);

    main.update(&model, .load_more);
    try testing.expectEqual(main.initial_batch + main.fetch_batch, model.loaded);
    try testing.expectEqual(@as(u32, 1), model.fetches);

    // The cap holds: fetch counting continues, loading stops.
    model.loaded = main.max_posts;
    main.update(&model, .load_more);
    try testing.expectEqual(main.max_posts, model.loaded);
    try testing.expectEqual(@as(u32, 2), model.fetches);
    try testing.expect(model.atCorpusEnd());

    // Interaction state is keyed by post INDEX, not by row position.
    main.update(&model, .{ .toggle_like = 99_999 });
    try testing.expect(model.liked.isSet(99_999));
    try testing.expectEqual(main.postAt(99_999).likes + 1, model.likeCount(99_999));
    main.update(&model, .{ .toggle_like = 99_999 });
    try testing.expect(!model.liked.isSet(99_999));

    main.update(&model, .{ .select_post = 7 });
    try testing.expectEqual(@as(?usize, 7), model.selected);
    main.update(&model, .{ .select_post = 7 });
    try testing.expectEqual(@as(?usize, null), model.selected);
}

// ------------------------------------------------------------------- views

test "the view builds only the visible window, with stable row identity across shifts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .loaded = main.max_posts };

    // Scrolled to post 500's estimated edge: the tree holds the window
    // around it — never 100k rows.
    const tree_a = try buildTreeAt(arena, &model, estimatedOffsetAt(500), 700);
    const list_a = findByLabel(tree_a.root, "Timeline").?;
    try testing.expectEqual(timeline_id, list_a.id);
    try testing.expectEqual(@as(usize, main.max_posts), list_a.layout.virtual_item_count);
    try testing.expect(list_a.children.len < 30);
    try testing.expectEqual(@as(usize, 500 - main.post_overscan), list_a.layout.virtual_first_index);
    // The variable contract is stamped: a declared total extent, no
    // uniform stride.
    try testing.expect(list_a.layout.virtual_total_extent > 0);
    try testing.expectEqual(@as(f32, 0), list_a.layout.virtual_item_extent);

    // Two rows down: the overlapping post keeps its structural id.
    const tree_b = try buildTreeAt(arena, &model, estimatedOffsetAt(502), 700);
    const row_a = findByLabel(tree_a.root, "Like post 503").?;
    const row_b = findByLabel(tree_b.root, "Like post 503").?;
    try testing.expectEqual(row_a.id, row_b.id);

    // The status line tells the truth about the window.
    try testing.expect(subtreeHasText(tree_a.root, "100000 loaded"));
}

// ----------------------------------------------------------------- harness

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *FeedApp,
    app: native_sdk.App,

    fn create(model: Model) !Harness {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(main.window_width, main.window_height) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try testing.allocator.create(FeedApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = FeedApp.init(std.heap.page_allocator, model, feedOptions());
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = geometry.SizeF.init(main.window_width, main.window_height),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: *Harness, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    fn wheel(self: *Harness, delta: f32) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-wheel {s} {d} {d}", .{ main.canvas_label, timeline_id, delta });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn clickWidget(self: *Harness, id: u64) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ main.canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn scrollState(self: *Harness) canvas.ScrollState {
        return self.harness.runtime.views[0].canvasWidgetScrollStateById(timeline_id).?;
    }

    fn root(self: *Harness) canvas.Widget {
        return self.app_state.tree.?.root;
    }
};

test "the timeline scrolls through the runtime, re-windows, and keeps liked rows by identity" {
    var h = try Harness.create(.{});
    defer h.destroy();
    try testing.expect(h.app_state.installed);

    // Install: the first window mounts from post 0.
    const list = findByLabel(h.root(), "Timeline").?;
    try testing.expectEqual(@as(usize, 0), list.layout.virtual_first_index);
    try testing.expect(list.children.len < 30);
    try testing.expect(findByLabel(h.root(), "Like post 0") != null);

    // Like post 2, through real dispatch.
    const like_id = findByLabel(h.root(), "Like post 2").?.id;
    try h.clickWidget(like_id);
    try testing.expect(h.app_state.model.liked.isSet(2));

    // Scroll far enough that post 2 unmounts (no on_scroll binding —
    // the scroll observation itself re-derives the view).
    try h.wheel(estimatedOffsetAt(200));
    try testing.expect(findByLabel(h.root(), "Like post 2") == null);
    try testing.expect(h.scrollState().offset > 0);

    // Scroll back to the very top: the row returns under the SAME
    // structural id with its liked state intact — identity is the
    // post, not the slot.
    var guard: usize = 0;
    while (h.scrollState().offset > 0 and guard < 200) : (guard += 1) {
        try h.wheel(-main.window_height * 4);
    }
    const returned = findByLabel(h.root(), "Like post 2").?;
    try testing.expectEqual(like_id, returned.id);
    try testing.expect(returned.state.selected);
    // The derived count grew by the like.
    var count_buffer: [16]u8 = undefined;
    const expected_count = try std.fmt.bufPrint(&count_buffer, "{d}", .{main.postAt(2).likes + 1});
    try testing.expectEqualStrings(expected_count, returned.text);
}

test "reach-end fires once per approach and appends the next batch" {
    var h = try Harness.create(.{});
    defer h.destroy();

    // Ride to the end of the initial 500 posts: the approach-end signal
    // fires ONCE (hysteresis) and update appends a batch.
    try testing.expectEqual(@as(u32, 0), h.app_state.model.fetches);
    var guard: usize = 0;
    while (h.app_state.model.fetches == 0 and guard < 2_000) : (guard += 1) {
        try h.wheel(main.window_height);
    }
    try testing.expectEqual(@as(u32, 1), h.app_state.model.fetches);
    try testing.expectEqual(main.initial_batch + main.fetch_batch, h.app_state.model.loaded);

    // The appended batch grew the extent, pulling the offset out of the
    // band: the next nudge re-arms instead of re-firing.
    try h.wheel(24);
    try testing.expectEqual(@as(u32, 1), h.app_state.model.fetches);

    // The next approach fires again.
    guard = 0;
    while (h.app_state.model.fetches == 1 and guard < 2_000) : (guard += 1) {
        try h.wheel(main.window_height);
    }
    try testing.expectEqual(@as(u32, 2), h.app_state.model.fetches);
    try testing.expectEqual(main.initial_batch + 2 * main.fetch_batch, h.app_state.model.loaded);
}

test "scroll storm: measured corrections never move the rows the user is reading" {
    var h = try Harness.create(.{ .loaded = 5_000 });
    defer h.destroy();

    // Mixed steps and deep jumps across a corpus whose estimates are
    // rough on purpose: at every step, a row still visible after the
    // wheel must land exactly wheel-delta from where it was. The
    // engine's anchored corrections may reprice everything OFF screen
    // (that is the honest scrollbar-drift contract) — visible content
    // never jumps.
    var seed = std.Random.DefaultPrng.init(0x5eed_feed);
    const random = seed.random();
    var checked: usize = 0;
    var step: usize = 0;
    while (step < 150) : (step += 1) {
        const before_state = h.scrollState();
        const delta: f32 = switch (random.uintLessThan(u8, 8)) {
            0, 1, 2 => main.window_height / 2,
            3, 4 => -main.window_height / 2,
            5 => main.window_height * 6,
            6 => -main.window_height * 6,
            else => before_state.maxOffset() * 0.5 - before_state.offset,
        };

        // Probe: the first row overlapping mid-viewport, by frame.
        const layout = try h.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        var list_index: usize = 0;
        for (layout.nodes, 0..) |node, index| {
            if (node.widget.id == timeline_id) list_index = index;
        }
        const list_frame = layout.nodes[list_index].frame.normalized();
        var probe_index: ?u32 = null;
        var probe_y: f32 = 0;
        for (layout.nodes) |node| {
            const parent = node.parent_index orelse continue;
            if (parent != list_index) continue;
            const item = node.widget.semantics.list_item_index orelse continue;
            const frame = node.frame.normalized();
            if (frame.y <= list_frame.y + main.window_height / 2 and frame.maxY() >= list_frame.y + main.window_height / 2) {
                probe_index = item;
                probe_y = frame.y;
                break;
            }
        }

        try h.wheel(delta);

        // The invariant protects what the user SEES: after a wheel
        // landing comfortably inside the scroll range, a row still
        // (partly) visible must sit exactly wheel-delta from where it
        // was — the offset absorbs any measured correction; the pixels
        // never move by anything but the wheel. Edge-clamped steps are
        // skipped (the applied wheel is not the asked wheel there by
        // design).
        const interior = before_state.offset + delta >= main.window_height and
            before_state.offset + delta <= before_state.maxOffset() - 2 * main.window_height and
            before_state.offset >= main.window_height and
            before_state.offset <= before_state.maxOffset() - 2 * main.window_height;
        if (interior) {
            if (probe_index) |item| {
                const after_layout = try h.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
                var after_list: usize = 0;
                for (after_layout.nodes, 0..) |node, index| {
                    if (node.widget.id == timeline_id) after_list = index;
                }
                for (after_layout.nodes) |node| {
                    const parent = node.parent_index orelse continue;
                    if (parent != after_list) continue;
                    const after_item = node.widget.semantics.list_item_index orelse continue;
                    if (after_item != item) continue;
                    const frame = node.frame.normalized();
                    if (frame.maxY() > list_frame.y and frame.y < list_frame.y + main.window_height) {
                        try testing.expectApproxEqAbs(probe_y - delta, frame.y, 1.0);
                        checked += 1;
                    }
                    break;
                }
            }
        }
    }
    try testing.expect(checked > 40);
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .loaded = main.max_posts };
    // The windowed virtual timeline builds per viewport, so each swept
    // size audits a tree built at exactly that viewport (mid-corpus, so
    // real rows — including a long-form wall — are in the window).
    const sizes = [_]geometry.SizeF{
        geometry.SizeF.init(main.window_min_width, main.window_min_height),
        geometry.SizeF.init(main.window_width, main.window_height),
        geometry.SizeF.init(main.window_width * 1.5, main.window_height * 1.5),
    };
    for (sizes) |size| {
        // Deep in the corpus: six-digit post indexes put the widest
        // realistic numbers in the rows and the status strip.
        const tree = try buildTreeAt(arena_state.allocator(), &model, estimatedOffsetAt(99_900), size.height);
        try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = canvas.DesignTokens.theme(.{}),
            .min_size = size,
            .default_size = size,
            .large_size = size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .loaded = main.max_posts };
    // Same windowed-virtual discipline as the layout sweep: each swept
    // size audits a tree built at exactly that viewport, deep in the
    // corpus so the labels are the real six-digit ones.
    const sizes = [_]geometry.SizeF{
        geometry.SizeF.init(main.window_min_width, main.window_min_height),
        geometry.SizeF.init(main.window_width, main.window_height),
        geometry.SizeF.init(main.window_width * 1.5, main.window_height * 1.5),
    };
    for (sizes) |size| {
        const tree = try buildTreeAt(arena_state.allocator(), &model, estimatedOffsetAt(99_900), size.height);
        try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = canvas.DesignTokens.theme(.{}),
            .min_size = size,
            .default_size = size,
            .large_size = size,
        });
        _ = arena_state.reset(.retain_capacity);
    }
}

test "widget_nodes stays viewport-sized at the full 100k corpus while the scrollbar spans it" {
    var h = try Harness.create(.{ .loaded = main.max_posts });
    defer h.destroy();

    // Snapshot telemetry: the retained node count is the WINDOW, deep
    // under the 1024 budget, while the scroll semantics report the
    // estimate-priced full corpus (converging toward measured truth as
    // rows are visited) — the scrollbar tells the truth it has.
    const snapshot = h.harness.runtime.automationSnapshot("Feed");
    var found_view = false;
    for (snapshot.views) |view| {
        if (!std.mem.eql(u8, view.label, main.canvas_label)) continue;
        found_view = true;
        try testing.expect(view.widget_node_count > 0);
        try testing.expect(view.widget_node_count < 320);
    }
    try testing.expect(found_view);

    var found_scroll = false;
    for (snapshot.widgets) |widget| {
        if (widget.id != timeline_id) continue;
        found_scroll = true;
        try testing.expect(widget.scroll.present);
        // 100k mixed-height posts: even the roughest honest pricing
        // puts the timeline in the millions of points.
        try testing.expect(widget.scroll.content_extent > @as(f32, @floatFromInt(main.max_posts)) * main.post_chrome_extent);
    }
    try testing.expect(found_scroll);

    // Jump deep into the corpus: still the same bounded window, still
    // six-digit posts on screen.
    try h.wheel(estimatedOffsetAt(90_000));
    const layout = try h.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layout.nodes.len < 320);
    const list = findByLabel(h.root(), "Timeline").?;
    try testing.expect(list.layout.virtual_first_index > 80_000);
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var model = main.Model{};
    try testing.expectEqual(main.header_natural_height, model.header_height);

    // The tall hidden-inset band arrives through on_chrome: the header
    // pads past the traffic lights and matches the band's height so its
    // centered controls share the lights' centerline.
    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    main.update(&model, msg);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(main.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    main.update(&model, tall);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Fullscreen zeroes the chrome: the pad collapses and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    main.update(&model, cleared);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(main.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): the docs-homepage showcase state — the timeline a few posts in,
// so variable-height rows fill the fold and the header's load counter
// shows — once per color scheme, same state in both. PNGs land in
// /tmp/homepage-shots/feed-{light,dark}-artifacts/. To use:
//
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    var h = try Harness.create(.{});
    defer h.destroy();

    // The docs site overlays CSS stoplights on the capture, inside the
    // header's own chrome gap. Reserve that gap for real: the standard
    // macOS tall hidden-inset geometry (the same numbers the
    // chrome-geometry test pins) arrives through the app's chrome
    // channel, so the header pads exactly where the site's dots land.
    try h.dispatch(main.onChrome(.{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    }).?);

    // A few posts in: wrapped multi-line bodies above and below the
    // fold. The extra nudge past the post boundary lands the band edge
    // inside a body, not across an author line (eyeballed).
    try h.wheel(estimatedOffsetAt(5) + 100);

    // The app follows the system appearance: drive the platform event
    // once per scheme, the same channel the OS uses. The dispatch
    // re-emits the display list with the re-derived tokens, so no
    // present is needed in between.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/feed-light-artifacts", "Feed");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot feed-canvas 2");

    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/feed-dark-artifacts", "Feed");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot feed-canvas 2");
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}
