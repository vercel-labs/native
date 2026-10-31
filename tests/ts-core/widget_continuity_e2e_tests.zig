const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const r = sdk.runtime.testing.widget_retention_runtime;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls = [_]usize{ 0, 0 };
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 95) calls[input[1]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn node(kind: c.WidgetKind, id: u64) c.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .text = "unchanged\x00\xff", .value = 12.125, .value_x = -0.0 }, .frame = .init(1, 2, 90, 31), .depth = 0 };
}
fn semantic(id: u64) c.WidgetSemanticsNode {
    return .{ .id = id, .role = .listitem, .label = "source\x00\xff", .bounds = .init(1, 2, 90, 31), .state = .{ .disabled = true }, .value = -0.0, .text_value = "source text bytes", .list = .{ .present = true, .item_index = 0xfffffffe, .item_count = 0xffffffff }, .scroll = .{ .present = true, .offset = 19.125, .viewport_extent = 31.25, .content_extent = 16777216 }, .focusable = true, .actions = .{ .increment = true, .decrement = true }, .grid_row_index = std.math.maxInt(usize), .text_selection = .{ .start = 1, .end = 3 } };
}
fn compare(nodes: []const c.WidgetLayoutNode, previous: []const r.CanvasWidgetScrollReconcileEntry, sources: []const c.WidgetSemanticsNode) !void {
    var index = r.CanvasWidgetSemanticsIndex{};
    index.build(sources);
    const plan = r.continuity_policy.layout(observed, nodes, previous, &index).?;
    core.rt.frameReset();
    for (nodes, 0..) |n, i| {
        try exact(r.canvasWidgetLayoutNodeWithSourceSemantics(n, &index), r.canvasWidgetLayoutNodeWithPlannedSourceSemantics(n, &index, plan.actions[i]));
        try exact(r.canvasWidgetScrollStateForLayoutNode(n, previous), r.canvasWidgetScrollStateWithPlan(n, previous, plan.actions[i]));
    }
}
test "compiled widget continuity all kinds axes keyed first matches source overlays and scalar edges" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| {
        for (std.enums.values(c.WidgetKind)) |kind| for (std.enums.values(c.ScrollAxes)) |axes| for (0..8) |bits| {
            var n = node(kind, id);
            n.widget.scroll_axes = axes;
            n.widget.layout.virtualized = bits & 1 != 0;
            n.widget.layout.virtual_item_count = if (bits & 2 != 0) 100 else 0;
            var source = semantic(id);
            source.list.present = bits & 4 != 0;
            const prior = [_]r.CanvasWidgetScrollReconcileEntry{
                .{ .id = id, .state = .{ .offset_y = n.widget.value, .offset_x = n.widget.value_x, .velocity_y = -23.125, .velocity_x = std.math.inf(f32), .content_extent_y = 800 } },
                .{ .id = id, .state = .{ .offset_y = 31, .offset_x = 42, .velocity_y = 999, .velocity_x = 888 } },
            };
            try compare(&.{n}, &prior, &.{ source, semantic(id) });
        };
    }
    for ([_]f32{ -0.0, 0.0, 0.0000001, -33.125, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |value| {
        var n = node(.scroll_view, 1);
        n.widget.scroll_axes = .both;
        n.widget.value = value;
        n.widget.value_x = value;
        for ([_]f32{ value, 0, 12.125 }) |old| try compare(&.{n}, &.{.{ .id = 1, .state = .{ .offset_y = old, .offset_x = value, .velocity_y = value, .velocity_x = -0.0 } }}, &.{});
    }
    try std.testing.expect(calls[0] > 4500);
}
test "compiled widget continuity complete scroll semantics preserve unrelated fields and first source" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| for (0..4) |bits| {
        var source = semantic(id);
        source.scroll.present = bits & 1 != 0;
        source.list.present = bits & 2 != 0;
        source.value = if (bits & 2 != 0) null else std.math.nan(f32);
        var index = r.CanvasWidgetSemanticsIndex{};
        index.build(&.{ source, semantic(id) });
        var expected = [_]c.WidgetSemanticsNode{ semantic(id), semantic(7) };
        expected[0].label = "retained label";
        expected[0].text_value = "retained text";
        expected[0].grid_row_index = 17;
        expected[0].bounds = .init(-1, -2, 71, 82);
        var actual = expected;
        r.applyCanvasWidgetSourceScrollSemantics(&expected, &index);
        r.applyCanvasWidgetSourceScrollSemanticsWithPolicy(observed, &actual, &index);
        core.rt.frameReset();
        try exact(expected, actual);
    };
    try std.testing.expect(calls[1] >= 12);
}
test "compiled widget continuity empty and full budget owned plans" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [1024]c.WidgetLayoutNode = undefined;
    var sources: [1024]c.WidgetSemanticsNode = undefined;
    for (&nodes, &sources, 0..) |*n, *s, i| {
        n.* = node(.scroll_view, 9007199254740993 + i);
        s.* = semantic(n.widget.id);
    }
    try compare(&nodes, &.{}, &sources);
    try compare(&.{}, &.{}, &.{});
    var index = r.CanvasWidgetSemanticsIndex{};
    index.build(&sources);
    const plan = r.continuity_policy.semanticsPlan(observed, &sources, &index).?;
    core.rt.frameReset();
    for (plan.actions) |action| try std.testing.expectEqual(@as(u8, 2), action);
}
test "compiled widget continuity retained adoption source jumps axis revocation and failed rebuilds" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Harness = sdk.TestHarness();
    const left = try Harness.create(std.testing.allocator, .{});
    defer left.destroy(std.testing.allocator);
    const right = try Harness.create(std.testing.allocator, .{});
    defer right.destroy(std.testing.allocator);
    for ([_]*Harness{ left, right }, 0..) |h, i| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = h, .name = "continuity", .source = sdk.platform.WebViewSource.html("") });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 300, 200) });
        if (i == 1) h.runtime.views[0].widget_tokens.widget_continuity_policy = observed;
    }
    var nodes = [_]c.WidgetLayoutNode{ node(.scroll_view, 1), node(.text, 2) };
    nodes[0].widget.scroll_axes = .both;
    nodes[0].frame = .init(0, 0, 100, 100);
    nodes[1].depth = 1;
    nodes[1].parent_index = 0;
    nodes[1].frame = .init(10, 300, 400, 100);
    const tree = c.WidgetLayoutTree{ .nodes = &nodes, .root_bounds = .init(0, 0, 300, 200) };
    for (0..5) |step| {
        if (step == 1) nodes[0].widget.value += 1;
        if (step == 2) nodes[0].widget.scroll_axes = .vertical;
        if (step == 3) nodes[0].widget.scroll_axes = .both;
        for ([_]*Harness{ left, right }) |h| {
            const view = &h.runtime.views[0];
            try view.copyWidgetLayoutTree(tree, &h.runtime.canvas_widget_copy_scratch);
            if (step == 0) {
                view.widget_scroll_states[0].velocity_y = -23.125;
                view.widget_scroll_states[0].velocity_x = 31.25;
            }
        }
        core.rt.frameReset();
        const a = &left.runtime.views[0];
        const b = &right.runtime.views[0];
        try exact(a.widgetLayoutTree().nodes, b.widgetLayoutTree().nodes);
        try exact(@as([]const c.ScrollState, a.widget_scroll_states[0..2]), @as([]const c.ScrollState, b.widget_scroll_states[0..2]));
        try exact(a.widget_semantics_nodes[0..a.widget_semantics_node_count], b.widget_semantics_nodes[0..b.widget_semantics_node_count]);
    }
    const overflow = try std.testing.allocator.alloc(u8, c.max_widget_text_bytes_per_view + 1);
    defer std.testing.allocator.free(overflow);
    @memset(overflow, 'x');
    nodes[1].widget.text = overflow;
    for ([_]*Harness{ left, right }) |h| {
        const view = &h.runtime.views[0];
        const adoptions = view.canvas_widget_layout_adoptions;
        const before = view.widget_scroll_states[0];
        try std.testing.expectError(error.WidgetTextTooLarge, view.copyWidgetLayoutTree(tree, &h.runtime.canvas_widget_copy_scratch));
        try std.testing.expectEqual(adoptions, view.canvas_widget_layout_adoptions);
        try exact(before, view.widget_scroll_states[0]);
        try std.testing.expectEqualStrings("unchanged\x00\xff", view.widget_layout_nodes[1].widget.text);
    }
}
