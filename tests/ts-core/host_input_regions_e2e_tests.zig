const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.host_input_regions_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [4]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 79) calls[request[2]] += 1;
    return core.nativeSurfaceScopePolicy(request, output);
}
const Harness = sdk.TestHarness();
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        const a = std.testing.allocator;
        var pair = Pair{ .left = try Harness.create(a, .{}), .right = try Harness.create(a, .{}) };
        for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            h.null_platform.gpu_surface_scroll_drivers = true;
            try h.start(.{ .context = h, .name = "host-regions", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(10, 20, 320, 240) });
            if (i == 1) h.runtime.views[0].canvas_widget_surface_scope_policy = observed;
        }
        try pair.same();
        return pair;
    }
    fn destroy(self: *Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
    }
    fn install(self: *Pair, nodes: []const sdk.canvas.WidgetLayoutNode) void {
        for ([_]*Harness{ self.left, self.right }) |h| {
            const view = &h.runtime.views[0];
            @memcpy(view.widget_layout_nodes[0..nodes.len], nodes);
            view.widget_layout_node_count = nodes.len;
        }
    }
    fn sync(self: *Pair) !void {
        for ([_]*Harness{ self.left, self.right }) |h| sdk.runtime.testing.syncHostInputDrivers(&h.runtime, 0);
        try self.same();
        core.rt.frameReset();
    }
    fn same(self: *Pair) !void {
        const l = self.left;
        const r = self.right;
        try exact(l.runtime.automationSnapshot("host-regions"), r.runtime.automationSnapshot("host-regions"));
        try exact(l.null_platform.scrollDrivers(), r.null_platform.scrollDrivers());
        try exact(l.null_platform.scroll_occluders[0..l.null_platform.scroll_occluder_count], r.null_platform.scroll_occluders[0..r.null_platform.scroll_occluder_count]);
        inline for (.{ "scroll_driver_set_count", "scroll_driver_set_offset_count", "scroll_driver_window_id", "scroll_driver_label_len", "window_drag_region_push_count", "window_drag_region_count" }) |name| try exact(@field(l.null_platform, name), @field(r.null_platform, name));
        try exact(l.null_platform.scroll_driver_label_storage[0..l.null_platform.scroll_driver_label_len], r.null_platform.scroll_driver_label_storage[0..r.null_platform.scroll_driver_label_len]);
        try exact(l.null_platform.window_drag_regions[0..l.null_platform.window_drag_region_count], r.null_platform.window_drag_regions[0..r.null_platform.window_drag_region_count]);
        const a = &l.runtime.views[0];
        const b = &r.runtime.views[0];
        try exact(a.widgetLayoutTree().nodes, b.widgetLayoutTree().nodes);
        try exact(a.scroll_driver_ids[0..a.scroll_driver_count], b.scroll_driver_ids[0..b.scroll_driver_count]);
        try exact(a.scroll_driver_offsets[0..a.scroll_driver_count], b.scroll_driver_offsets[0..b.scroll_driver_count]);
        try exact(a.canvas_widget_drag_regions_pushed, b.canvas_widget_drag_regions_pushed);
        try exact(a.canvas_widget_drag_regions[0..a.canvas_widget_drag_region_count], b.canvas_widget_drag_regions[0..b.canvas_widget_drag_region_count]);
    }
};
fn node(id: u64, kind: sdk.canvas.WidgetKind, frame: sdk.geometry.RectF, parent: ?usize, depth: usize) sdk.canvas.WidgetLayoutNode {
    return .{ .widget = .{ .id = id, .kind = kind, .frame = frame }, .frame = frame, .parent_index = parent, .depth = depth };
}
test "compiled host input regions preserve complete driver fields axes padding virtual extents and echo suppression" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    const values = [_]f32{ -24, -0.0, 0, 24, 24.5, 24.500002 };
    for (std.enums.values(sdk.canvas.ScrollAxes)) |axes| for (std.enums.values(sdk.canvas.WidgetOverscroll)) |overscroll| for ([_]bool{ false, true }) |virtualized| for (values) |value| {
        var nodes = [_]sdk.canvas.WidgetLayoutNode{
            node(9007199254740993, .scroll_view, .init(2.000001, 3, 100.00001, 60), null, 0),
            node(std.math.maxInt(u64), .panel, .init(8, 9, 200, 160), 0, 1),
        };
        nodes[0].widget.scroll_axes = axes;
        nodes[0].widget.overscroll = overscroll;
        nodes[0].widget.value = value;
        nodes[0].widget.value_x = value;
        nodes[0].widget.layout.padding = .{ .left = 5, .right = 3, .top = 2, .bottom = 4 };
        nodes[0].widget.layout.virtualized = virtualized;
        nodes[0].widget.layout.virtual_item_count = if (virtualized) 20 else 0;
        nodes[0].widget.layout.virtual_item_extent = 12;
        pair.install(&nodes);
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            const view = &h.runtime.views[0];
            view.widget_tokens.scroll.overscroll = .rubber_band;
            view.scroll_driver_count = 1;
            view.scroll_driver_ids[0] = nodes[0].widget.id;
            view.scroll_driver_offsets[0] = .init(24, 24);
        }
        try pair.sync();
    };
    try std.testing.expect(calls[1] > 0);
}
test "compiled host input regions preserve complete occlusion transformations disclosure and effective paint order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]bool{ false, true }) |hidden| for ([_]bool{ false, true }) |scrim| for ([_]?i32{ null, -10, 10, 100 }) |layer| {
        var nodes = [_]sdk.canvas.WidgetLayoutNode{
            node(1, .scroll_view, .init(0, 0, 200, 60), null, 0),
            node(2, .panel, .init(0, 0, 400, 300), 0, 1),
            node(3, .popover, .init(20, 10, 100, 50), 0, 1),
            node(4, .scroll_view, .init(24, 14, 92, 42), 2, 2),
            node(5, .panel, .init(24, 14, 200, 120), 3, 3),
            node(6, .dialog, .init(0, 0, 250, 100), null, 0),
            node(7, .scroll_view, .init(5, 5, 240, 90), 5, 1),
            node(8, .panel, .init(5, 5, 300, 200), 6, 2),
        };
        nodes[2].widget.layout.anchor = .{ .placement = .below };
        nodes[2].widget.transform = .{ .a = 0.75, .b = -0.25, .c = 0.5, .d = 1, .tx = -24, .ty = 18 };
        nodes[2].widget.semantics.hidden = hidden;
        nodes[2].widget.layer = layer;
        nodes[5].widget.scrim = scrim;
        pair.install(&nodes);
        try pair.sync();
    };
    var nodes = [_]sdk.canvas.WidgetLayoutNode{
        node(1, .scroll_view, .init(0, 0, 100, 60), null, 0),
        node(2, .accordion, .init(0, 0, 100, 24), 0, 1),
        node(3, .popover, .init(0, 0, 100, 80), 1, 2),
        node(4, .scroll_view, .init(0, 0, 100, 60), 2, 3),
    };
    nodes[2].widget.layout.anchor = .{ .placement = .below };
    for ([_]bool{ false, true }) |selected| {
        nodes[1].widget.state.selected = selected;
        pair.install(&nodes);
        try pair.sync();
    }
}
test "compiled host input regions preserve capacity prefixes all stamps parent ids and occluder overflow" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    var nodes: [26]sdk.canvas.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(@as(u64, @intCast(i)) + 1, .scroll_view, .init(0, 0, 100, 60), if (i == 0) null else 0, if (i == 0) 0 else 1);
    nodes[0].widget.layout.padding.top = 70;
    nodes[0].widget.semantics.hidden = true;
    nodes[2].widget.id = nodes[1].widget.id;
    for ([_]usize{ 0, 1, 16, 17, 26 }) |len| {
        pair.install(nodes[0..len]);
        try pair.sync();
    }
    nodes[0].widget.layout.padding = .{};
    nodes[0].widget.semantics.hidden = false;
    for ([_]usize{ 7, 8, 9 }) |occluders| {
        for (nodes[1 .. occluders + 1]) |*n| {
            n.widget.kind = .popover;
            n.widget.layout.anchor = .{ .placement = .below };
            n.parent_index = null;
            n.depth = 0;
        }
        pair.install(nodes[0 .. occluders + 1]);
        try pair.sync();
    }
}
test "compiled host input regions preserve complete drag-region transactions clipping and synchronization" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [35]sdk.canvas.WidgetLayoutNode = undefined;
    nodes[0] = node(1, .panel, .init(0, 0, 100, 60), null, 0);
    nodes[0].widget.window_drag = true;
    for (nodes[1..], 1..) |*n, i| n.* = node(@intCast(i + 1), .button, .init(0, 0, 20, 20), 0, 1);
    for (0..33) |capacity| for ([_]usize{ 0, 1, 15, 16, 31, 32, 33, 35 }) |len| {
        var expected: [32]sdk.platform.WindowDragRegion = undefined;
        const count = sdk.runtime.testing.referenceWindowDragRegions(.{ .nodes = nodes[0..len] }, expected[0..capacity]);
        const program = p.plan(observed, .drag, .{ .nodes = nodes[0..len], .drag_service = true, .drag_capacity = capacity }).?;
        try exact(@as([]const sdk.platform.WindowDragRegion, expected[0..count]), program.regions[0..program.region_count]);
        try std.testing.expectEqual(count != 0, program.detail != 0);
        core.rt.frameReset();
    };
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]usize{ 3, 3, 1, 0, 0 }) |len| {
        pair.install(nodes[0..len]);
        for ([_]*Harness{ pair.left, pair.right }) |h| try sdk.runtime.testing.syncHostInputDragRegions(&h.runtime, 0);
        try pair.same();
    }
    try std.testing.expect(calls[2] > 0);
}
test "compiled host input regions preserve every native press kind and completed drag-header prefixes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes = [_]sdk.canvas.WidgetLayoutNode{
        node(1, .panel, .init(100, 0, -100, 60), null, 0),
        node(std.math.maxInt(u64), .button, .init(0, 0, 20, 20), 0, 1),
        node(3, .panel, .init(0, 60, 100, 60), null, 0),
        node(4, .button, .init(0, 60, 20, 20), 2, 1),
        node(5, .button, .init(20, 60, 20, 20), 2, 1),
    };
    nodes[0].widget.window_drag = true;
    nodes[2].widget.window_drag = true;
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 32 }) |capacity| {
        var expected: [32]sdk.platform.WindowDragRegion = undefined;
        const count = sdk.runtime.testing.referenceWindowDragRegions(.{ .nodes = &nodes }, expected[0..capacity]);
        const program = p.plan(observed, .drag, .{ .nodes = &nodes, .drag_service = true, .drag_capacity = capacity }).?;
        try exact(@as([]const sdk.platform.WindowDragRegion, expected[0..count]), program.regions[0..program.region_count]);
        core.rt.frameReset();
    }
    for (std.enums.values(sdk.canvas.WidgetKind)) |kind| for ([_]bool{ false, true }) |disabled| for ([_]bool{ false, true }) |hidden| {
        nodes[1].widget.kind = kind;
        nodes[1].widget.state.disabled = disabled;
        nodes[1].widget.semantics.hidden = hidden;
        var expected: [32]sdk.platform.WindowDragRegion = undefined;
        const count = sdk.runtime.testing.referenceWindowDragRegions(.{ .nodes = nodes[0..2] }, &expected);
        const program = p.plan(observed, .drag, .{ .nodes = nodes[0..2], .drag_service = true }).?;
        try exact(@as([]const sdk.platform.WindowDragRegion, expected[0..count]), program.regions[0..program.region_count]);
        core.rt.frameReset();
    };
}
fn refuseDrivers(_: ?*anyopaque, _: sdk.platform.WindowId, _: []const u8, _: []const sdk.platform.GpuSurfaceScrollDriver, _: []const sdk.platform.GpuSurfaceScrollOccluder) anyerror!void {
    return error.UnsupportedService;
}
test "compiled host input regions preserve native stamp capability gates and failed-call bookkeeping" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    var nodes: [20]sdk.canvas.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(@intCast(i + 1), .scroll_view, .init(0, 0, 100, 60), null, 0);
    nodes[1].widget.id = 0;
    nodes[2].widget.layout.virtualized = true;
    nodes[3].widget.layout.virtualized = true;
    nodes[3].widget.layout.virtual_item_count = 5;
    nodes[4].widget.runtime_flags.native_scroll = true;
    for ([_]bool{ false, true }) |supported| {
        pair.install(&nodes);
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            h.null_platform.gpu_surface_scroll_drivers = supported;
            const view = &h.runtime.views[0];
            sdk.runtime.testing.stampHostInputRegions(&h.runtime, view.widget_layout_nodes[0..view.widget_layout_node_count], view.canvas_widget_surface_scope_policy);
        }
        try pair.same();
    }
    try pair.sync();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.options.platform.services.set_gpu_surface_scroll_drivers_fn = refuseDrivers;
        h.runtime.views[0].widget_layout_nodes[0].widget.value = 24;
    }
    try pair.sync();
    try std.testing.expect(calls[0] > 0);
}
test "compiled host input regions preserve full native-driver event and presentation state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    const nodes = [_]sdk.canvas.WidgetLayoutNode{
        node(1, .scroll_view, .init(0, 0, 100, 60), null, 0),
        node(2, .panel, .init(0, 0, 100, 300), 0, 1),
    };
    pair.install(&nodes);
    try pair.sync();
    const app = sdk.App{ .context = pair.left, .name = "host-regions", .source = sdk.platform.WebViewSource.html("") };
    for ([_]u64{ 1, 9007199254740993, 1, std.math.maxInt(u64) }) |id| {
        const event = sdk.platform.Event{ .gpu_surface_scroll_driver = .{ .window_id = 1, .label = "canvas", .driver_id = id, .offset_x = -0.0, .offset_y = -24, .timestamp_ns = 1_000_000_000 } };
        try pair.left.runtime.dispatchPlatformEvent(app, event);
        try pair.right.runtime.dispatchPlatformEvent(app, event);
        try pair.same();
        try pair.sync();
    }
    try std.testing.expect(calls[3] > 0);
}
