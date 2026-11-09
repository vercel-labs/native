const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const r = sdk.runtime.testing.widget_retention_runtime;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 94) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn node(kind: c.WidgetKind, id: u64, depth: usize, parent: ?usize, x: f32, y: f32) c.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .text = "unchanged\x00\xff", .value = 10.125, .value_x = 7.25, .text_selection = .{ .anchor = 1, .focus = 3 }, .frame = .init(99, 98, 97, 96) }, .frame = .init(x, y, 40.125, 30.25), .depth = depth, .parent_index = parent };
}
fn compare(nodes: []const c.WidgetLayoutNode) !void {
    const viewport = sdk.geometry.RectF.init(-3.125, 5.25, 100.125, 70.25);
    var expected: [1024]c.WidgetLayoutNode = undefined;
    var actual: [1024]c.WidgetLayoutNode = undefined;
    for (nodes, 0..) |_, root| {
        const extents = r.canvasWidgetLayoutScrollExtentsWithPolicy(observed, nodes, root, viewport);
        try exact(r.canvasWidgetLayoutScrollContentExtent(nodes, root, viewport), extents.dy);
        try exact(r.canvasWidgetLayoutScrollContentExtentX(nodes, root, viewport), extents.dx);
        @memcpy(expected[0..nodes.len], nodes);
        @memcpy(actual[0..nodes.len], nodes);
        r.translateCanvasWidgetLayoutScrollDescendants(expected[0..nodes.len], root, .{ .dx = -13.125, .dy = 31.25 });
        // Reset before applying the copied result to prove arena independence.
        const plan = r.scroll_tree_policy.build(observed, nodes, .{ .operation = 1, .target = root }).?;
        core.rt.frameReset();
        plan.translate(actual[0..nodes.len], .{ .dx = -13.125, .dy = 31.25 });
        try exact(expected[0..nodes.len], actual[0..nodes.len]);
    }
}
test "compiled scroll tree complete extents and translation preserve subtree exclusions" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const kinds = [_]c.WidgetKind{ .panel, .scroll_view, .dialog, .dropdown_menu, .accordion, .text };
    for (kinds) |kind| for (0..32) |bits| {
        var nodes = [_]c.WidgetLayoutNode{
            node(.scroll_view, 9007199254740993, 0, null, 0, 0),
            node(kind, std.math.maxInt(u64), 1, 0, 40.125, 50.25),
            node(.text, 0, 2, 1, 400.125, 500.25),
            node(.panel, 3, 1, 0, 140.25, 210.125),
            node(.dropdown_menu, 4, 2, 3, 180.125, 250.25),
            node(.text, 5, 3, 4, 700.25, 800.125),
            node(.panel, 6, 0, null, 1200, 1300),
        };
        nodes[1].widget.layout.anchor = if (bits & 1 != 0) .{} else null;
        nodes[1].widget.layout.clip_content = bits & 2 != 0;
        nodes[1].widget.layout.virtualized = bits & 4 != 0;
        nodes[1].widget.layout.virtual_item_count = if (bits & 8 != 0) 100 else 0;
        nodes[1].widget.layout.virtual_item_extent = 33.125;
        nodes[1].widget.state.selected = bits & 16 != 0;
        nodes[1].widget.value = if (bits & 16 != 0) 1 else 0;
        nodes[4].widget.layout.anchor = .{};
        try compare(&nodes);
    };
    try std.testing.expect(calls > 2000);
}
test "compiled scroll tree sequential tab reveals retain first exact identity and anchored strata" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..64) |bits| {
        var original = [_]c.WidgetLayoutNode{
            node(.scroll_view, 1, 0, null, 0, 0),              node(.panel, 2, 1, 0, 0, 0),
            node(.button, 9007199254740993, 2, 1, 200.125, 0), node(.button, std.math.maxInt(u64), 2, 1, -80.25, 0),
            node(.scroll_view, 5, 1, 0, 0, 50),                node(.button, 0, 2, 4, 180.125, 50),
        };
        original[0].widget.scroll_axes = .horizontal;
        original[0].frame.width = 100;
        if (bits & 16 != 0) original[0].frame.height = 0;
        if (bits & 32 != 0) {
            original[2].frame.width = -40.125;
            original[2].frame.height = -30.25;
        }
        original[4].widget.scroll_axes = if (bits & 1 != 0) .horizontal else .vertical;
        original[4].widget.layout.virtualized = bits & 2 != 0;
        original[4].widget.layout.anchor = if (bits & 4 != 0) .{} else null;
        for ([_]usize{ 2, 3, 5 }) |i| {
            original[i].widget.semantics.role = .tab;
            original[i].widget.state.selected = true;
        }
        var previous = [_]c.WidgetLayoutNode{ original[2], original[2], original[3] };
        previous[0].widget.state.selected = bits & 8 != 0;
        for ([_]?usize{ null, 0, 1 }) |depth| {
            var expected = original;
            var actual = original;
            const old = c.WidgetLayoutTree{ .nodes = &previous };
            r.revealNewlySelectedTabs(old, &expected, depth, null);
            r.revealNewlySelectedTabsWithPolicy(observed, old, &actual, depth, null);
            core.rt.frameReset();
            try exact(expected, actual);
        }
    }
}
test "compiled scroll tree full node budget empty and scalar geometry edges" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [1024]c.WidgetLayoutNode = undefined;
    nodes[0] = node(.scroll_view, 1, 0, null, 0, 0);
    for (nodes[1..], 1..) |*n, i| n.* = node(.text, i + 1, 1, 0, @floatFromInt(i), @floatFromInt(i * 2));
    const extents = r.canvasWidgetLayoutScrollExtentsWithPolicy(observed, &nodes, 0, .init(0, 0, 100, 100));
    try exact(r.canvasWidgetLayoutScrollContentExtent(&nodes, 0, .init(0, 0, 100, 100)), extents.dy);
    try exact(r.canvasWidgetLayoutScrollContentExtentX(&nodes, 0, .init(0, 0, 100, 100)), extents.dx);
    for ([_]f32{ -0.0, -33.125, 0.0000001, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |value| {
        nodes[1].frame = .init(value, value, value, value);
        nodes[0].widget.value = value;
        nodes[0].widget.value_x = value;
        try compare(nodes[0..2]);
    }
    try exact(@as(f32, 0), r.canvasWidgetLayoutScrollExtentsWithPolicy(observed, &.{}, 0, .{}).dx);
    var empty: [0]c.WidgetLayoutNode = .{};
    r.revealNewlySelectedTabsWithPolicy(observed, .{ .nodes = &.{} }, &empty, null, null);
}
test "compiled scroll tree live consumers and engine clamps preserve complete frames and physics" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Harness = sdk.TestHarness();
    const left = try Harness.create(std.testing.allocator, .{});
    defer left.destroy(std.testing.allocator);
    const right = try Harness.create(std.testing.allocator, .{});
    defer right.destroy(std.testing.allocator);
    for ([_]*Harness{ left, right }, 0..) |h, i| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = h, .name = "scroll-tree", .source = sdk.platform.WebViewSource.html("") });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 300, 200) });
        if (i == 1) h.runtime.views[0].widget_tokens.scroll_tree_policy = observed;
    }
    for (std.enums.values(c.ScrollAxes)) |axes| for ([_]bool{ false, true }) |native_scroll| {
        var original = [_]c.WidgetLayoutNode{ node(.scroll_view, 1, 0, null, 0, 0), node(.panel, 2, 1, 0, 400, 500), node(.dropdown_menu, 3, 1, 0, 800, 900), node(.text, 4, 2, 2, 1200, 1300) };
        original[0].widget.scroll_axes = axes;
        original[0].widget.value = 10000;
        original[0].widget.value_x = 10000;
        original[0].widget.runtime_flags.native_scroll = native_scroll;
        original[2].widget.layout.anchor = .{};
        for ([_]*Harness{ left, right }) |h| {
            const view = &h.runtime.views[0];
            @memcpy(view.widget_layout_nodes[0..original.len], &original);
            view.widget_layout_node_count = original.len;
            for (view.widget_scroll_states[0..original.len]) |*state| state.* = .{ .offset_y = 10000, .offset_x = 10000, .velocity_y = -23.125, .velocity_x = 31.25 };
            try r.clampCanvasWidgetLayoutScrollOffsetsAfterReconcile(view.widget_layout_nodes[0..original.len], view.widget_scroll_states[0..original.len], null, view.widget_tokens);
        }
        const a = &left.runtime.views[0];
        const b = &right.runtime.views[0];
        try exact(a.widgetLayoutTree().nodes, b.widgetLayoutTree().nodes);
        try exact(@as([]const c.ScrollState, a.widget_scroll_states[0..original.len]), @as([]const c.ScrollState, b.widget_scroll_states[0..original.len]));
        try exact(a.canvasWidgetScrollContentExtent(0, .init(0, 0, 100, 100)), b.canvasWidgetScrollContentExtent(0, .init(0, 0, 100, 100)));
        try exact(a.canvasWidgetScrollContentExtentX(0, .init(0, 0, 100, 100)), b.canvasWidgetScrollContentExtentX(0, .init(0, 0, 100, 100)));
        a.translateCanvasWidgetScrollDescendants(0, .{ .dx = -21, .dy = 31 });
        b.translateCanvasWidgetScrollDescendants(0, .{ .dx = -21, .dy = 31 });
        core.rt.frameReset();
        try exact(a.widgetLayoutTree().nodes, b.widgetLayoutTree().nodes);
    };
}
