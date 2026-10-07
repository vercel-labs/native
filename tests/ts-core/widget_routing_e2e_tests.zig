//! Independent native routing compared with the production compiled owner.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const routing = @import("native_sdk").canvas.widget_routing_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
const tree = @import("native_sdk").canvas.WidgetLayoutTree;
fn node(widget: canvas.Widget, frame: sdk.geometry.RectF, parent: ?usize, depth: usize) canvas.WidgetLayoutNode {
    return .{ .widget = widget, .frame = frame, .parent_index = parent, .depth = depth };
}
fn owned(reference: tree) tree {
    var value = reference;
    value.routing_policy = core.nativeWindowPolicy;
    return value;
}
fn routeEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    if (expected) |value| {
        try exact(value, try actual);
    } else |err| try std.testing.expectError(err, actual);
}
fn compare(reference: tree, tokens: canvas.DesignTokens, point: sdk.geometry.PointF) !void {
    const compiled = owned(reference);
    errdefer std.debug.print("routing parity point ({d},{d}) nodes {d}\n", .{ point.x, point.y, reference.nodes.len });
    const a = reference.hitTestWithTokens(point, tokens);
    const b = compiled.hitTestWithTokens(point, tokens);
    core.rt.frameReset();
    try exact(a, b);
    try exact(reference.hitTestHoverWithTokens(point, tokens), compiled.hitTestHoverWithTokens(point, tokens));
    try exact(reference.hoverTargetForHit(a), compiled.hoverTargetForHit(b));
    var hover_a: [32]u64 = undefined;
    var hover_b: [32]u64 = undefined;
    try exact(reference.hoverMsgChainForHit(a, &hover_a), compiled.hoverMsgChainForHit(b, &hover_b));
    for (reference.nodes, 0..) |n, i| {
        try exact(reference.focusTargetById(n.widget.id), compiled.focusTargetById(n.widget.id));
        try exact(reference.focusTargetAtIndex(i), compiled.focusTargetAtIndex(i));
        try exact(reference.logicalFocusTargetAtIndex(i), compiled.logicalFocusTargetAtIndex(i));
        for (std.enums.values(canvas.WidgetFocusDirection)) |direction| try exact(reference.focusTarget(n.widget.id, direction), compiled.focusTarget(n.widget.id, direction));
    }
    for (std.enums.values(canvas.WidgetFocusDirection)) |direction| try exact(reference.focusTarget(null, direction), compiled.focusTarget(null, direction));
    var entries_a: [63]canvas.WidgetEventRouteEntry = undefined;
    var entries_b: [63]canvas.WidgetEventRouteEntry = undefined;
    for (std.enums.values(canvas.WidgetPointerPhase)) |phase| try routeEqual(reference.routePointerEventWithTokens(.{ .phase = phase, .point = point }, tokens, &entries_a), compiled.routePointerEventWithTokens(.{ .phase = phase, .point = point }, tokens, &entries_b));
    try routeEqual(reference.routeFileDropEvent(.{ .point = point, .paths = &.{"raw\xff\x00path"} }, &entries_a), compiled.routeFileDropEvent(.{ .point = point, .paths = &.{"raw\xff\x00path"} }, &entries_b));
    for (reference.nodes) |n| {
        try routeEqual(reference.routeDragEvent(.{ .source_id = n.widget.id, .point = point }, &entries_a), compiled.routeDragEvent(.{ .source_id = n.widget.id, .point = point }, &entries_b));
        try routeEqual(reference.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = n.widget.id }, &entries_a), compiled.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = n.widget.id }, &entries_b));
    }
    core.rt.frameReset();
}
test "compiled widget routing preserves every kind role and authored interaction gate" {
    _ = core.initialModel();
    const frame = sdk.geometry.RectF.init(0, 0, 40, 30);
    for (std.enums.values(canvas.WidgetKind)) |kind| for (0..32) |flags| {
        const widget = canvas.Widget{ .kind = kind, .id = if (flags & 1 != 0) 0 else 0xfedcba9876543210, .state = .{ .disabled = flags & 2 != 0 }, .semantics = .{ .hidden = flags & 4 != 0, .focusable = flags & 8 != 0, .role = if (flags & 16 != 0) .treeitem else .none } };
        var nodes = [_]canvas.WidgetLayoutNode{node(widget, frame, null, 0)};
        try compare(.{ .nodes = &nodes }, .{}, .init(5, 5));
    };
    for (std.enums.values(canvas.WidgetRole)) |role| for (0..16) |flags| {
        var widget = canvas.Widget{ .kind = .row, .id = 1, .semantics = .{ .role = role, .actions = .{ .press = flags & 1 != 0, .toggle = flags & 2 != 0, .drag = flags & 4 != 0, .drop_files = flags & 8 != 0 } } };
        widget.hover_msgs = flags & 1 != 0;
        widget.window_drag = flags & 2 != 0;
        var nodes = [_]canvas.WidgetLayoutNode{node(widget, frame, null, 0)};
        try compare(.{ .nodes = &nodes }, .{}, .init(5, 5));
    };
}
test "compiled widget routing preserves hoisted modal ordering ancestor clips and disclosure settlement" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .scroll_view, .id = 1 }, .init(0, 0, 100, 100), null, 0),
        node(.{ .kind = .accordion, .id = 2 }, .init(0, 0, 100, 100), 0, 1),
        node(.{ .kind = .button, .id = 3 }, .init(110, 110, 40, 30), 1, 2),
        node(.{ .kind = .dialog, .id = 4 }, .init(110, 110, 80, 80), 1, 2),
        node(.{ .kind = .button, .id = 5, .layout = .{ .anchor = .{} } }, .init(110, 110, 40, 30), 3, 3),
        node(.{ .kind = .button, .id = 6, .layout = .{ .anchor = .{} } }, .init(110, 110, 40, 30), null, 0),
    };
    for (0..64) |flags| {
        nodes[0].widget.semantics.hidden = flags & 1 != 0;
        nodes[1].widget.state.selected = flags & 2 != 0;
        nodes[1].frame.height = if (flags & 4 != 0) 150 else 139.5;
        nodes[4].widget.layer = if (flags & 8 != 0) -1 else null;
        nodes[5].widget.layer = if (flags & 16 != 0) 21 else null;
        nodes[4].widget.state.disabled = flags & 32 != 0;
        try compare(.{ .nodes = &nodes }, .{ .layer = .{ .base = -2, .overlay = 10, .modal = 20, .floating = 30 } }, .init(115, 115));
    }
}
test "compiled widget routing preserves nested inverse transforms negative extents and float edges" {
    _ = core.initialModel();
    const transforms = [_]canvas.Affine{ .{}, .translate(40, 20), .scale(2, 0.5), .{ .a = 1, .b = 0.5, .c = 0.25, .d = 1, .tx = -13.75, .ty = 5.25 }, .{ .a = 0.000001 }, .{ .a = 0 }, .{ .tx = -0.0 } };
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row, .id = 1 }, .init(30, 30, -30, -30), null, 0), node(.{ .kind = .button, .id = 2 }, .init(0, 0, 30, 30), 0, 1) };
    for (transforms) |parent| for (transforms) |child| {
        nodes[0].widget.transform = parent;
        nodes[1].widget.transform = child;
        for ([_]f32{ -0.0, 0, 0.000001, 15, 29.999998, 30, 60 }) |x| try compare(.{ .nodes = &nodes }, .{}, .init(x, 15));
    };
}
test "compiled widget routing preserves capture phases eligibility and exact wide identities" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .scroll_view, .id = 1 }, .init(0, 0, 100, 100), null, 0), node(.{ .kind = .button, .id = std.math.maxInt(u64) }, .init(10, 10, 30, 30), 0, 1) };
    var a: [63]canvas.WidgetEventRouteEntry = undefined;
    var b: [63]canvas.WidgetEventRouteEntry = undefined;
    for (0..16) |flags| {
        nodes[0].widget.semantics.hidden = flags & 1 != 0;
        nodes[1].widget.state.disabled = flags & 2 != 0;
        nodes[1].widget.semantics.hidden = flags & 4 != 0;
        nodes[1].frame.x = if (flags & 8 != 0) 200 else 10;
        const reference = tree{ .nodes = &nodes };
        const compiled = owned(reference);
        for (std.enums.values(canvas.WidgetPointerPhase)) |phase| for ([_]?u64{ null, 0, 1, 123, std.math.maxInt(u64) }) |id| {
            for ([_]sdk.geometry.PointF{ .init(15, 15), .init(1000, 1000) }) |point| {
                const event = canvas.WidgetPointerEvent{ .phase = phase, .captured_id = id, .point = point };
                try routeEqual(reference.routePointerEvent(event, &a), compiled.routePointerEvent(event, &b));
            }
        };
    }
    core.rt.frameReset();
}
test "compiled widget routing preserves complete paths and caller prefixes at depth and capacity limits" {
    _ = core.initialModel();
    var nodes: [40]canvas.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(.{ .kind = .button, .id = i + 1, .hover_msgs = true }, .init(0, 0, 30, 30), if (i > 0) i - 1 else null, i);
    var a = [_]canvas.WidgetEventRouteEntry{.{ .phase = .bubble, .node_index = 999, .id = 999, .kind = .chart, .bounds = .init(-0.0, 1, 2, 3) }} ** 64;
    var b = a;
    for ([_]usize{ 1, 2, 31, 32, 33, 40 }) |depth| for ([_]usize{ 0, 1, 2, 3, 31, 62, 63, 64 }) |capacity| {
        const reference = tree{ .nodes = nodes[0..depth] };
        const compiled = owned(reference);
        const before = a;
        const event = canvas.WidgetPointerEvent{ .phase = .down, .point = .init(5, 5) };
        try routeEqual(reference.routePointerEvent(event, a[0..capacity]), compiled.routePointerEvent(event, b[0..capacity]));
        core.rt.frameReset();
        try exact(a, b);
        a = before;
        b = before;
        var left: [40]u64 = undefined;
        var right: [40]u64 = undefined;
        const hit = reference.hitTest(.init(5, 5));
        try exact(reference.hoverMsgChainForHit(hit, left[0..@min(capacity, 40)]), compiled.hoverMsgChainForHit(hit, right[0..@min(capacity, 40)]));
    };
}
test "compiled widget routing preserves spatial scoring ties logical focus and scroll observation" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .scroll_view, .id = 1, .scroll_axes = .both }, .init(0, 0, 100, 100), null, 0),
        node(.{ .kind = .button, .id = 2 }, .init(10, 10, 20, 20), 0, 1),
        node(.{ .kind = .button, .id = 3 }, .init(50, 10, 20, 20), 0, 1),
        node(.{ .kind = .button, .id = 4 }, .init(50, 10, 20, 20), 0, 1),
        node(.{ .kind = .row, .id = 5, .semantics = .{ .role = .treeitem } }, .init(10, 50, 20, 20), 0, 1),
        node(.{ .kind = .button, .id = 6 }, .init(10, 150, 20, 20), 0, 1),
    };
    for ([_]f32{ -0.0, 0, 9.999999, 10, 10.000001, 30, 100, 1000 }) |offset| {
        nodes[2].frame.y = offset;
        try compare(.{ .nodes = &nodes }, .{}, .init(15, 15));
    }
    // Existing portable semantic observations compose with routing without
    // collecting or borrowing the routing request's storage.
    const reference = tree{ .nodes = &nodes };
    var compiled = owned(reference);
    compiled.semantic_policy = core.nativeWindowPolicy;
    for (nodes, 0..) |n, i| {
        try exact(reference.focusTargetById(n.widget.id), compiled.focusTargetById(n.widget.id));
        try exact(reference.logicalFocusTargetAtIndex(i), compiled.logicalFocusTargetAtIndex(i));
    }
    core.rt.frameReset();
}
test "compiled widget routing preserves press hover table-row and window-drag attribution" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{
        node(.{ .kind = .row, .id = 1, .window_drag = true, .hover_msgs = true }, .init(0, 0, 100, 100), null, 0),
        node(.{ .kind = .data_row, .id = 2, .hover_msgs = true }, .init(0, 0, 100, 30), 0, 1),
        node(.{ .kind = .data_cell, .id = 3 }, .init(0, 0, 30, 30), 1, 2),
        node(.{ .kind = .text, .id = 4 }, .init(0, 0, 20, 20), 2, 3),
    };
    for (0..32) |flags| {
        nodes[1].widget.semantics.actions.press = flags & 1 != 0;
        nodes[2].widget.semantics.actions.press = flags & 2 != 0;
        nodes[3].widget.semantics.role = if (flags & 4 != 0) .link else .none;
        nodes[2].widget.state.disabled = flags & 8 != 0;
        nodes[0].widget.semantics.actions.press = flags & 16 != 0;
        try compare(.{ .nodes = &nodes }, .{}, .init(5, 5));
        const reference = tree{ .nodes = &nodes };
        const result = routing.query(owned(reference), core.nativeWindowPolicy, 5, 0, 3, null, .{}, .{}, 0, {});
        const expected = @import("native_sdk").canvas.widgetWindowDragTargetIndexFromNode(reference, 3);
        try exact(expected, result.target);
    }
}
const Adapter = sdk.TsUiApp(core);
test "compiled widget routing preserves complete caller supplied hover hits" {
    _ = core.initialModel();
    var nodes = [_]canvas.WidgetLayoutNode{ node(.{ .kind = .row, .id = 1 }, .init(0, 0, 40, 40), null, 0), node(.{ .kind = .text, .id = 2 }, .init(0, 0, 30, 30), 0, 1) };
    for (0..32) |flags| {
        nodes[0].widget.semantics.actions.press = flags & 1 != 0;
        nodes[0].widget.kind = if (flags & 2 != 0) .data_row else .row;
        const reference = tree{ .nodes = &nodes };
        const compiled = owned(reference);
        var hit = reference.hitTest(.init(5, 5)).?;
        hit.bounds = .init(-0.0, 101.25, -8, 16);
        hit.id = std.math.maxInt(u64);
        hit.depth = 17;
        hit.role = if (flags & 4 != 0) .link else .none;
        hit.state.disabled = flags & 8 != 0;
        hit.kind = if (flags & 16 != 0) .data_cell else .text;
        try exact(reference.hoverTargetForHit(hit), compiled.hoverTargetForHit(hit));
        core.rt.frameReset();
    }
}
fn view(ui: *Adapter.Ui, _: *const core.Model) Adapter.Ui.Node {
    return ui.button(.{ .on_press = .increment_and_persist }, "Route");
}
fn routingTokens(_: *const core.Model) canvas.DesignTokens {
    return .{ .density = .spacious };
}
test "compiled widget routing retains explicit ownership through tokens solved and retained views" {
    const views = [_]sdk.ShellView{.{ .label = "canvas", .kind = .gpu_surface, .fill = true }};
    const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Routing", .width = 400, .height = 300, .views = &views }};
    const scene = sdk.ShellConfig{ .windows = &windows };
    for ([_]bool{ false, true }) |dynamic| {
        const h = try sdk.TestHarness().create(std.testing.allocator, .{});
        defer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        var state = Adapter.init(std.testing.allocator, .{}, .{ .name = "routing-ownership", .scene = scene, .canvas_label = "canvas", .view = view, .tokens = .{ .density = .compact }, .tokens_fn = if (dynamic) routingTokens else null });
        defer state.deinit();
        const app = state.app();
        try h.start(app);
        try h.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(400, 300), .timestamp_ns = 1000000 } });
        for (0..2) |turn| {
            const v = &h.runtime.views[0];
            try std.testing.expectEqual(@as(?routing.Policy, core.nativeWindowPolicy), v.widget_tokens.widget_routing_policy);
            const layout = v.widgetLayoutTree();
            try std.testing.expectEqual(@as(?routing.Policy, core.nativeWindowPolicy), layout.routing_policy);
            var reference = layout;
            reference.routing_policy = null;
            const point = layout.nodes[0].frame.center();
            try exact(reference.hitTest(point), layout.hitTest(point));
            if (turn == 0) try state.dispatch(&h.runtime, state.canvas_window_id, .increment_and_persist);
        }
    }
}
