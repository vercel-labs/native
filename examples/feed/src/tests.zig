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
        .tokens_fn = main.feedTokens,
        .on_appearance = main.onAppearance,
        .view = main.view,
    };
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
    var source = PinnedSource{ .state = .{ .offset = offset, .viewport_extent = viewport } };
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

    // Scrolled to post 500 (offset 500 x 84): the tree holds the window
    // around it — never 100k rows.
    const tree_a = try buildTreeAt(arena, &model, 500 * main.post_row_extent, 700);
    const list_a = findByLabel(tree_a.root, "Timeline").?;
    try testing.expectEqual(timeline_id, list_a.id);
    try testing.expectEqual(@as(usize, main.max_posts), list_a.layout.virtual_item_count);
    try testing.expect(list_a.children.len < 30);
    try testing.expectEqual(@as(usize, 500 - main.post_overscan), list_a.layout.virtual_first_index);

    // Two rows apart: the overlapping post keeps its structural id.
    const tree_b = try buildTreeAt(arena, &model, 502 * main.post_row_extent, 700);
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

    fn retainedOffset(self: *Harness) !f32 {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        return layout.findById(timeline_id).?.widget.value;
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
    try h.wheel(200 * main.post_row_extent);
    try testing.expectEqual(@as(f32, 200 * main.post_row_extent), try h.retainedOffset());
    try testing.expect(findByLabel(h.root(), "Like post 2") == null);
    try testing.expect(findByLabel(h.root(), "Like post 200") != null);

    // Scroll back: the row returns under the SAME structural id with
    // its liked state intact — identity is the post, not the slot.
    try h.wheel(-200 * main.post_row_extent);
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

    // Ride to the end of the initial 500 posts. The viewport is the
    // window height minus header/status chrome, so aim past the max
    // offset — the engine clamps (rubber-band aside) and the observation
    // carries the honest extents.
    try testing.expectEqual(@as(u32, 0), h.app_state.model.fetches);
    const content: f32 = @as(f32, @floatFromInt(main.initial_batch)) * main.post_row_extent;
    try h.wheel(content); // overshoots; clamps near max
    try testing.expectEqual(@as(u32, 1), h.app_state.model.fetches);
    try testing.expectEqual(main.initial_batch + main.fetch_batch, h.app_state.model.loaded);

    // The appended batch grew the extent, pulling the offset out of the
    // band: the next nudge re-arms instead of re-firing.
    try h.wheel(24);
    try testing.expectEqual(@as(u32, 1), h.app_state.model.fetches);

    // The next approach fires again.
    try h.wheel(@as(f32, @floatFromInt(main.fetch_batch)) * main.post_row_extent);
    try testing.expectEqual(@as(u32, 2), h.app_state.model.fetches);
    try testing.expectEqual(main.initial_batch + 2 * main.fetch_batch, h.app_state.model.loaded);
}

test "widget_nodes stays viewport-sized at the full 100k corpus while the scrollbar spans it" {
    var h = try Harness.create(.{ .loaded = main.max_posts });
    defer h.destroy();

    // Snapshot telemetry: the retained node count is the WINDOW, deep
    // under the 1024 budget, while the scroll semantics report the whole
    // 100k-post extent (8.4M points) — the scrollbar tells the truth.
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
        try testing.expectEqual(@as(f32, @floatFromInt(main.max_posts)) * main.post_row_extent, widget.scroll.content_extent);
    }
    try testing.expect(found_scroll);

    // Jump deep into the corpus: still the same bounded window.
    try h.wheel(90_000 * main.post_row_extent);
    try testing.expect(findByLabel(h.root(), "Like post 90000") != null);
    const layout = try h.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
    try testing.expect(layout.nodes.len < 320);
}
