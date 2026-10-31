const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const r = sdk.runtime.testing.widget_retention_runtime;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls = [_]usize{ 0, 0 };
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 96) calls[input[1]] += 1;
    return core.nativeWindowPolicy(input, output);
}
test "compiled staged rebuild sequence preserves strata node order and copied results" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var program = r.staged_rebuild_policy.Program.init(observed, 5, 2);
    const depths = [_]usize{ 0, 0, 1, 0, 2 };
    for (depths, 0..) |depth, i| program.setNode(i, .{ .widget = .{ .id = if (i == 1) 0 else std.math.maxInt(u64), .kind = .split }, .frame = .{}, .depth = depth }, depth);
    const expected = [_]r.staged_rebuild_policy.Kind{ .split, .split, .restore_scroll, .clamp_scroll, .reveal_tabs, .anchors, .split, .restore_scroll, .clamp_scroll, .reveal_tabs, .anchors, .split, .restore_scroll, .clamp_scroll, .reveal_tabs, .done };
    for (expected, 0..) |kind, i| {
        const step = program.next();
        core.rt.frameReset();
        try std.testing.expectEqual(kind, step.kind);
        if (i == 0) try std.testing.expectEqual(@as(usize, 0), step.index);
        if (i == 1) try std.testing.expectEqual(@as(usize, 3), step.index);
        if (i == 6) try std.testing.expectEqual(@as(usize, 2), step.index);
        if (i == 11) try std.testing.expectEqual(@as(usize, 4), step.index);
    }
    var full = r.staged_rebuild_policy.Program.init(observed, 1024, 0);
    for (0..1024) |i| full.setNode(i, .{ .widget = .{ .id = 1, .kind = .split }, .frame = .{}, .depth = 0 }, 0);
    for (0..1024) |i| {
        const step = full.next();
        try std.testing.expectEqual(i, step.index);
        try std.testing.expectEqual(r.staged_rebuild_policy.Kind.split, step.kind);
    }
}
const Scratch = struct {
    nodes: [128]c.WidgetLayoutNode = undefined,
    controls: [128]r.CanvasWidgetControlReconcileEntry = undefined,
    offsets: [256]r.CanvasWidgetSourceScrollEntry = undefined,
    texts: [128]r.CanvasWidgetTextReconcileEntry = undefined,
    bytes: [4096]u8 = undefined,
};
fn reconcile(s: *Scratch, previous: c.WidgetLayoutTree, next: c.WidgetLayoutTree, source: []const r.CanvasWidgetSourceScrollEntry, armed: []const u64, pressed: u64, tokens: c.DesignTokens) !c.WidgetLayoutTree {
    return r.canvasWidgetLayoutTreeWithRuntimeReconcileState(previous, next, &.{}, &.{}, source, &.{}, &s.nodes, &s.controls, &s.offsets, &s.texts, &s.bytes, tokens, armed, pressed);
}
test "compiled staged rebuild complete split scroll tab and nested anchor geometry matches reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const a = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(b);
    const split_id = 9007199254740993;
    const tab_items = [_]c.Widget{ .{ .id = 201, .kind = .button, .text = "First", .semantics = .{ .role = .tab } }, .{ .id = 202, .kind = .button, .text = "Last", .state = .{ .selected = true }, .semantics = .{ .role = .tab }, .layout = .{ .min_size = .init(240, 0) } } };
    const tall = [_]c.Widget{ .{ .id = 210, .kind = .text, .text = "Wrap and scroll", .layout = .{ .min_size = .init(0, 240) } }, .{ .id = 211, .kind = .row, .children = &tab_items, .layout = .{ .min_size = .init(440, 0) } } };
    const panes = [_]c.Widget{ .{ .id = 100, .kind = .column, .text = "left", .children = &tall }, .{ .id = 101, .kind = .split_divider }, .{ .id = 102, .kind = .scroll_view, .scroll_axes = .both, .value = 19.125, .value_x = 11.25, .children = &tall } };
    for (0..128) |bits| {
        const inner = c.Widget{ .id = std.math.maxInt(u64), .kind = .split, .value = 0.625, .children = &panes, .resize_duration_ms = if (bits & 4 != 0) 180 else 0, .resize_origin = if (bits & 8 != 0) 0.125 else -1 };
        const inner_children = [_]c.Widget{inner};
        const second_anchor = [_]c.Widget{.{ .id = 302, .kind = .panel, .children = &inner_children, .layout = .{ .anchor = .{}, .min_size = .init(180, 110) } }};
        const anchor_children = [_]c.Widget{ inner, .{ .id = 301, .kind = .column, .children = &second_anchor } };
        const roots = [_]c.Widget{
            .{ .id = if (bits & 64 != 0) 0 else split_id, .kind = .split, .value = if (bits & 2 != 0) 0.75 else 0.5, .children = &panes, .resize_duration_ms = inner.resize_duration_ms, .resize_origin = inner.resize_origin, .layout = .{ .min_size = .init(0, 140) } },
            .{ .id = 300, .kind = .panel, .children = &anchor_children, .layout = .{ .anchor = .{}, .min_size = .init(300, 240) } },
        };
        var next_nodes: [128]c.WidgetLayoutNode = undefined;
        const next = try c.layoutWidgetTree(.{ .kind = .column, .children = &roots }, .init(0, 0, 500, 400), &next_nodes);
        var old_nodes: [128]c.WidgetLayoutNode = undefined;
        @memcpy(old_nodes[0..next.nodes.len], next.nodes);
        for (old_nodes[0..next.nodes.len]) |*n| {
            if (n.widget.kind == .split) n.widget.value = 0.3125;
            if (n.widget.kind == .scroll_view) {
                n.widget.value = 31.125;
                n.widget.value_x = 17.25;
            }
            if (n.widget.semantics.role == .tab) n.widget.state.selected = false;
        }
        const previous = c.WidgetLayoutTree{ .nodes = if (bits & 1 != 0) old_nodes[0..next.nodes.len] else &.{} };
        const sources = [_]r.CanvasWidgetSourceScrollEntry{ .{ .id = split_id, .value = 0.5 }, .{ .id = split_id, .value = 0.125 }, .{ .id = std.math.maxInt(u64), .value = 0.625 }, .{ .id = 102, .value = 19.125, .value_x = 11.25 } };
        const armed: []const u64 = if (bits & 16 != 0) &.{ split_id, std.math.maxInt(u64) } else &.{};
        const pressed: u64 = if (bits & 32 != 0) split_id else 0;
        const reference = try reconcile(a, previous, next, &sources, armed, pressed, .{});
        const actual = try reconcile(b, previous, next, &sources, armed, pressed, .{ .staged_rebuild_policy = observed });
        core.rt.frameReset();
        try exact(reference, actual);
    }
    try std.testing.expect(calls[0] > 1500);
    try std.testing.expect(calls[1] > 100);
}
test "compiled staged rebuild value only exact identities source absence and rejection boundary" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const a = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(b);
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| for (0..16) |bits| {
        const current: f32 = if (bits & 1 != 0) -0.0 else 0.75;
        const n = c.WidgetLayoutNode{ .widget = .{ .id = id, .kind = .split, .value = current, .resize_duration_ms = if (bits & 2 != 0) 150 else 0 }, .frame = .init(1, 2, 90, 31), .depth = 0 };
        var old = n;
        old.widget.value = if (bits & 4 != 0) -0.0 else 0.25;
        const source: []const r.CanvasWidgetSourceScrollEntry = if (bits & 8 != 0) &.{.{ .id = id, .value = current }} else &.{};
        const reference = try reconcile(a, .{ .nodes = &.{old} }, .{ .nodes = &.{n} }, source, &.{}, 0, .{});
        const actual = try reconcile(b, .{ .nodes = &.{old} }, .{ .nodes = &.{n} }, source, &.{}, 0, .{ .staged_rebuild_policy = observed });
        core.rt.frameReset();
        try exact(reference, actual);
    };
    const large = [_]c.WidgetLayoutNode{.{ .widget = .{ .kind = .split, .id = 1 }, .frame = .{}, .depth = 0 }};
    try std.testing.expectError(error.WidgetNodeLimitReached, r.canvasWidgetLayoutTreeWithRuntimeReconcileState(.{ .nodes = &.{} }, .{ .nodes = &large }, &.{}, &.{}, &.{}, &.{}, &.{}, &a.controls, &a.offsets, &a.texts, &a.bytes, .{ .staged_rebuild_policy = observed }, &.{}, 0));
}
