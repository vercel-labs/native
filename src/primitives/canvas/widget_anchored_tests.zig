//! Anchored floating surfaces: geometry (placement, flip, alignment,
//! clamping), layout integration (no flow push, leaf-trigger children),
//! the late render z-pass, and hit-test hoisting/clip escape.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;

const Widget = canvas.Widget;
const WidgetLayoutNode = canvas.WidgetLayoutNode;

const window = geometry.RectF.init(0, 0, 400, 300);

fn anchoredFrame(child: Widget, anchor: canvas.WidgetAnchor, anchor_rect: geometry.RectF) geometry.RectF {
    return canvas.anchoredWidgetFrame(child, anchor, anchor_rect, window, .{});
}

test "anchored frame places below the anchor with the default offset" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 140, 90) };
    const frame = anchoredFrame(child, .{}, geometry.RectF.init(20, 20, 120, 28));
    try std.testing.expectEqual(@as(f32, 20), frame.x);
    try std.testing.expectEqual(@as(f32, 52), frame.y); // 20 + 28 + 4
    try std.testing.expectEqual(@as(f32, 140), frame.width);
    try std.testing.expectEqual(@as(f32, 90), frame.height);
}

test "anchored frame flips above when below does not fit and above has more room" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 140, 90) };
    // Anchor near the bottom: below has 300-190-4 = 106... use a lower one.
    const frame = anchoredFrame(child, .{}, geometry.RectF.init(20, 250, 120, 28));
    // below space = 300 - 278 - 4 = 18 < 90; above space = 250 - 4 = 246.
    try std.testing.expectEqual(@as(f32, 250 - 4 - 90), frame.y);
    try std.testing.expectEqual(@as(f32, 90), frame.height);
}

test "anchored frame prefers above and flips below symmetrically" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 140, 90) };
    const above = anchoredFrame(child, .{ .placement = .above }, geometry.RectF.init(20, 200, 120, 28));
    try std.testing.expectEqual(@as(f32, 200 - 4 - 90), above.y);
    // Anchor near the top: above has no room, below does — flip.
    const flipped = anchoredFrame(child, .{ .placement = .above }, geometry.RectF.init(20, 10, 120, 28));
    try std.testing.expectEqual(@as(f32, 10 + 28 + 4), flipped.y);
}

test "anchored frame clamps height to the chosen side's space" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 140, 500) };
    const frame = anchoredFrame(child, .{}, geometry.RectF.init(20, 20, 120, 28));
    // below space = 300 - 48 - 4 = 248.
    try std.testing.expectEqual(@as(f32, 248), frame.height);
    try std.testing.expectEqual(@as(f32, 52), frame.y);
}

test "anchored frame alignment start end and stretch" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 60, 40) };
    const anchor_rect = geometry.RectF.init(100, 20, 120, 28);
    const start = anchoredFrame(child, .{ .alignment = .start }, anchor_rect);
    try std.testing.expectEqual(@as(f32, 100), start.x);
    try std.testing.expectEqual(@as(f32, 60), start.width);
    const end = anchoredFrame(child, .{ .alignment = .end }, anchor_rect);
    try std.testing.expectEqual(@as(f32, 220 - 60), end.x);
    // stretch widens to at least the anchor's width.
    const stretch = anchoredFrame(child, .{ .alignment = .stretch }, anchor_rect);
    try std.testing.expectEqual(@as(f32, 100), stretch.x);
    try std.testing.expectEqual(@as(f32, 120), stretch.width);
}

test "anchored frame clamps into the window horizontally and by offset" {
    const child = Widget{ .kind = .dropdown_menu, .frame = geometry.RectF.init(0, 0, 200, 40) };
    // end-aligned near the left edge would go negative; clamps to 0.
    const frame = anchoredFrame(child, .{ .alignment = .end, .offset = 10 }, geometry.RectF.init(4, 20, 40, 28));
    try std.testing.expectEqual(@as(f32, 0), frame.x);
    try std.testing.expectEqual(@as(f32, 58), frame.y); // 20 + 28 + 10
}

test "anchored children consume no flow space and float against the parent" {
    const menu_items = [_]Widget{.{ .id = 4, .kind = .menu_item, .text = "One" }};
    const dropdown = Widget{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(0, 0, 140, 90),
        .layout = .{ .anchor = .{} },
        .children = &menu_items,
    };
    const trigger = Widget{ .id = 2, .kind = .select, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Pick" };
    const wrap_children = [_]Widget{ trigger, dropdown };
    const wrap = Widget{ .id = 10, .kind = .stack, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &wrap_children };
    const after = Widget{ .id = 5, .kind = .button, .text = "After" };
    const column_children = [_]Widget{ wrap, after };
    const column = Widget{ .id = 1, .kind = .column, .layout = .{ .gap = 8 }, .children = &column_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(column, window, &nodes);

    const wrap_frame = layout.findById(10).?.frame;
    const dropdown_frame = layout.findById(3).?.frame;
    const after_frame = layout.findById(5).?.frame;
    // The sibling after the trigger stack flows as if the dropdown did
    // not exist: directly below the 28-high stack plus the gap.
    try std.testing.expectEqual(wrap_frame.maxY() + 8, after_frame.y);
    // The dropdown floats below its parent (the trigger stack).
    try std.testing.expectEqual(wrap_frame.maxY() + 4, dropdown_frame.y);
    try std.testing.expectEqual(@as(f32, 90), dropdown_frame.height);
    // Its menu item lays out inside the floating frame.
    const item_frame = layout.findById(4).?.frame;
    try std.testing.expect(item_frame.y >= dropdown_frame.y);
}

test "leaf trigger kinds lay out their anchored children" {
    const menu_items = [_]Widget{.{ .id = 4, .kind = .menu_item, .text = "One" }};
    const dropdown = Widget{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(0, 0, 140, 90),
        .layout = .{ .anchor = .{ .alignment = .stretch } },
        .children = &menu_items,
    };
    const select_children = [_]Widget{dropdown};
    const select = Widget{
        .id = 2,
        .kind = .select,
        .frame = geometry.RectF.init(30, 40, 180, 28),
        .text = "Pick",
        .children = &select_children,
    };
    const root_children = [_]Widget{select};
    const root = Widget{ .id = 1, .kind = .stack, .children = &root_children };
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, window, &nodes);
    const dropdown_node = layout.findById(3) orelse return error.TestUnexpectedResult;
    // Anchored below the select, stretched to its width.
    try std.testing.expectEqual(@as(f32, 40 + 28 + 4), dropdown_node.frame.y);
    try std.testing.expectEqual(@as(f32, 180), dropdown_node.frame.width);
    try std.testing.expect(layout.findById(4) != null);
}

/// The shared fixture for z-order/clip tests: a scroll pane whose content
/// holds the trigger + anchored dropdown, and a LATER sibling panel the
/// dropdown overlaps. In-tree paint order would put the panel above the
/// dropdown and the scroll clip would crop it; hoisting must do neither.
fn buildOverlapFixture(nodes: []WidgetLayoutNode) !canvas.WidgetLayoutTree {
    const menu_items = [_]Widget{.{ .id = 4, .kind = .menu_item, .frame = geometry.RectF.init(0, 0, 0, 24), .text = "One" }};
    const dropdown = Widget{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(0, 0, 140, 120),
        .layout = .{ .anchor = .{} },
        .children = &menu_items,
    };
    const trigger = Widget{ .id = 2, .kind = .select, .frame = geometry.RectF.init(0, 0, 0, 28), .text = "Pick" };
    const wrap_children = [_]Widget{ trigger, dropdown };
    const wrap = Widget{ .id = 10, .kind = .stack, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &wrap_children };
    const scroll_children = [_]Widget{wrap};
    // Short scroll viewport: the dropdown (120 tall, below a 28-high
    // trigger) extends far past its 40-high frame.
    const scroll = Widget{ .id = 20, .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 200, 40), .children = &scroll_children };
    const after = Widget{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 60, 200, 40), .text = "After" };
    const root_children = [_]Widget{ scroll, after };
    const root = Widget{ .id = 1, .kind = .stack, .children = &root_children };
    return canvas.layoutWidgetTree(root, window, nodes);
}

fn firstCommandIndexForWidget(list: canvas.DisplayList, widget_id: canvas.ObjectId) ?usize {
    for (list.commands, 0..) |command, index| {
        const id = command.objectId() orelse continue;
        // Widget part ids pack `widget_id * 16 + slot`.
        if (id / 16 == widget_id) return index;
    }
    return null;
}

test "anchored surfaces render in a late z-pass above later siblings and outside ancestor clips" {
    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try buildOverlapFixture(&nodes);

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const list = builder.displayList();

    const dropdown_index = firstCommandIndexForWidget(list, 3) orelse return error.TestUnexpectedResult;
    const item_index = firstCommandIndexForWidget(list, 4) orelse return error.TestUnexpectedResult;
    const after_index = firstCommandIndexForWidget(list, 5) orelse return error.TestUnexpectedResult;
    // The dropdown paints AFTER the later sibling (topmost), and so do
    // its items.
    try std.testing.expect(dropdown_index > after_index);
    try std.testing.expect(item_index > after_index);
    // The scroll clip closes BEFORE the dropdown paints: no clip command
    // is open at the dropdown's position (its commands sit outside every
    // push/pop pair).
    var open_clips: isize = 0;
    for (list.commands[0..dropdown_index]) |command| {
        switch (command) {
            .push_clip => open_clips += 1,
            .pop_clip => open_clips -= 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(isize, 0), open_clips);
}

test "anchored surfaces hit-test topmost and escape ancestor clips" {
    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try buildOverlapFixture(&nodes);

    const dropdown_frame = layout.findById(3).?.frame;
    // The dropdown starts below the trigger (y = 32) and extends past the
    // scroll viewport (40) over the later button (y = 60..100).
    try std.testing.expect(dropdown_frame.maxY() > 60);
    const inside_overlay = geometry.PointF.init(dropdown_frame.x + 8, 70);
    const hit = layout.hitTest(inside_overlay) orelse return error.TestUnexpectedResult;
    // The overlay wins over the button it overlaps, and the point is
    // OUTSIDE the scroll ancestor's 40-high frame — the clip escape.
    try std.testing.expect(hit.id == 3 or hit.id == 4);
    // Next to the overlay the button hits as usual.
    const beside = geometry.PointF.init(dropdown_frame.maxX() + 20, 70);
    try std.testing.expectEqual(@as(canvas.ObjectId, 5), layout.hitTest(beside).?.id);
    // Focus targets inside the overlay stay live outside the scroll
    // ancestor's bounds.
    try std.testing.expect(layout.focusTargetById(4) != null);
}

test "hidden ancestors hide their anchored surfaces" {
    const dropdown = Widget{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(0, 0, 140, 90),
        .layout = .{ .anchor = .{} },
    };
    const wrap_children = [_]Widget{dropdown};
    const wrap = Widget{
        .id = 10,
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 120, 28),
        .semantics = .{ .hidden = true },
        .children = &wrap_children,
    };
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(wrap, window, &nodes);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    try std.testing.expectEqual(@as(?usize, null), firstCommandIndexForWidget(builder.displayList(), 3));
    try std.testing.expect(layout.hitTest(geometry.PointF.init(30, 60)) == null);
}

test "anchored children do not grow their parent's intrinsic size" {
    const dropdown = Widget{
        .id = 3,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(0, 0, 300, 200),
        .layout = .{ .anchor = .{} },
    };
    const label = Widget{ .id = 2, .kind = .text, .text = "Pick" };
    const with_children = [_]Widget{ label, dropdown };
    const without_children = [_]Widget{label};
    const with = Widget{ .kind = .stack, .children = &with_children };
    const without = Widget{ .kind = .stack, .children = &without_children };
    const with_size = canvas.intrinsicWidgetSize(with, .{});
    const without_size = canvas.intrinsicWidgetSize(without, .{});
    try std.testing.expectEqual(without_size.width, with_size.width);
    try std.testing.expectEqual(without_size.height, with_size.height);
}
