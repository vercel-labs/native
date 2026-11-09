const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const g = sdk.geometry;
const testing = sdk.runtime.testing;
const methods = testing.scroll_mutation_methods;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls = [_]usize{0} ** 7;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 101) calls[input[1]] += 1;
    const size = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return size;
}
fn node(kind: c.WidgetKind, id: u64, depth: usize, parent: ?usize) c.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten", .value = 23.125, .value_x = 17.25, .frame = .init(1, 2, 99, 79), .text_selection = .{ .anchor = 1, .focus = 3 } }, .frame = .init(0, if (depth == 0) 0 else 200, 100, 80), .depth = depth, .parent_index = parent };
}
const Observation = struct {
    kind: u8,
    nodes: [4]c.WidgetLayoutNode,
    states: [4]c.ScrollState,
    revision: u64,
    events: [2]u64,
    event_count: usize,
    semantic_refreshes: usize,
};
// Instrumented capabilities exercise the unmodified native method bodies and
// compiled interpreter with the same storage, numeric inputs and failure seam.
const View = struct {
    const M = methods.RuntimeViewCanvasWidgetScroll(@This());
    pub const applyCanvasWidgetScrollAxis = M.applyCanvasWidgetScrollAxis;
    widget_layout_nodes: [4]c.WidgetLayoutNode,
    widget_layout_node_count: usize = 4,
    widget_scroll_states: [4]c.ScrollState = @splat(.{ .offset_y = 23.125, .offset_x = 17.25, .velocity_y = -31.125, .velocity_x = 21.25, .viewport_extent_y = 80, .viewport_extent_x = 100, .content_extent_y = 700, .content_extent_x = 800 }),
    widget_tokens: c.DesignTokens = .{},
    widget_revision: u64 = 9007199254740993,
    widget_scroll_event_ids: [2]u64 = .{ 0, 0 },
    widget_scroll_event_count: usize = 0,
    semantic_refreshes: usize = 0,
    fail_semantics: bool = false,
    hidden_damage: bool = false,
    observations: [32]Observation = undefined,
    observation_count: usize = 0,
    fn init() View {
        return .{ .widget_layout_nodes = .{ node(.scroll_view, 9007199254740993, 0, null), node(.text, 2, 1, 0), node(.scroll_view, std.math.maxInt(u64), 0, null), node(.text, 4, 1, 2) } };
    }
    fn note(self: *@This(), kind: u8) void {
        self.observations[self.observation_count] = .{ .kind = kind, .nodes = self.widget_layout_nodes, .states = self.widget_scroll_states, .revision = self.widget_revision, .events = self.widget_scroll_event_ids, .event_count = self.widget_scroll_event_count, .semantic_refreshes = self.semantic_refreshes };
        self.observation_count += 1;
    }
    pub fn canvasWidgetScrollState(self: *const @This(), index: usize, n: c.WidgetLayoutNode, viewport: g.RectF) c.ScrollState {
        return M.canvasWidgetScrollState(self, index, n, viewport);
    }
    pub fn canvasWidgetScrollContentExtent(_: *const @This(), _: usize, _: g.RectF) f32 {
        return 700.125;
    }
    pub fn canvasWidgetScrollContentExtentX(_: *const @This(), _: usize, _: g.RectF) f32 {
        return 800.25;
    }
    pub fn translateCanvasWidgetScrollDescendants(self: *@This(), index: usize, offset: g.OffsetF) void {
        self.note(1);
        testing.widget_retention_runtime.translateCanvasWidgetLayoutScrollDescendants(self.widget_layout_nodes[0..self.widget_layout_node_count], index, offset);
    }
    pub fn noteCanvasWidgetScrollEvent(self: *@This(), id: u64) void {
        self.note(2);
        M.noteCanvasWidgetScrollEvent(self, id);
    }
    pub fn refreshCanvasWidgetSemantics(self: *@This()) anyerror!void {
        self.note(3);
        if (self.fail_semantics) return error.InjectedSemanticsFailure;
        self.semantic_refreshes += 1;
    }
    pub fn canvasWidgetDirtyBounds(self: *const @This(), _: usize, bounds: g.RectF) ?g.RectF {
        @constCast(self).note(4);
        return if (self.hidden_damage) null else bounds;
    }
    fn compare(self: *const View, actual: *const View) !void {
        try exact(self.widget_layout_nodes, actual.widget_layout_nodes);
        try exact(self.widget_scroll_states, actual.widget_scroll_states);
        try exact(self.widget_revision, actual.widget_revision);
        try exact(self.widget_scroll_event_ids, actual.widget_scroll_event_ids);
        try exact(self.widget_scroll_event_count, actual.widget_scroll_event_count);
        try exact(self.semantic_refreshes, actual.semantic_refreshes);
        try exact(self.observations[0..self.observation_count], actual.observations[0..actual.observation_count]);
    }
};
test "compiled scroll mutation axis textarea and admission preserve complete state and callback order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]c.WidgetKind{ .scroll_view, .textarea, .panel }) |kind| for (std.enums.values(c.ScrollAxes)) |axes| for (0..32) |bits| {
        inline for (std.enums.values(c.ScrollAxis)) |axis| for (std.enums.values(methods.CanvasWidgetScrollSource)) |source| for ([_]f32{ -1000, -23.125, -0.0, 0, 19.75, 10000 }) |delta| {
            var a = View.init();
            a.widget_layout_nodes[0].widget.kind = kind;
            a.widget_layout_nodes[0].widget.scroll_axes = axes;
            a.widget_layout_nodes[0].widget.layout.virtualized = bits & 1 != 0;
            a.widget_layout_nodes[0].widget.layout.virtual_item_count = if (bits & 2 != 0) 100 else 0;
            a.widget_layout_nodes[0].widget.runtime_flags.native_scroll = bits & 4 != 0;
            a.widget_layout_nodes[0].widget.runtime_flags.code_editor = bits & 8 != 0;
            a.widget_layout_nodes[0].widget.text_no_wrap = bits & 8 != 0;
            a.widget_layout_nodes[0].widget.overscroll = .rubber_band;
            if (bits & 16 != 0) a.widget_layout_nodes[0].frame.height = 0;
            var b = a;
            b.widget_tokens.scroll_mutation_policy = observed;
            try exact(try View.M.applyCanvasWidgetScrollAxis(&a, 0, axis, delta, source, bits & 2 != 0), try View.M.applyCanvasWidgetScrollAxis(&b, 0, axis, delta, source, bits & 2 != 0));
            try a.compare(&b);
        };
    };
    try std.testing.expect(calls[0] > 10000 and calls[1] > 1000);
}
test "compiled scroll mutation driver and keyboard honor axes exact offsets and unchanged writes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (std.enums.values(c.ScrollAxes)) |axes| for (0..8) |bits| for ([_]f32{ -std.math.inf(f32), -100, -0.0, 0, 23.125, 16777216, std.math.inf(f32), std.math.nan(f32) }) |value| {
        var original = View.init();
        original.widget_layout_nodes[0].widget.scroll_axes = axes;
        original.widget_layout_nodes[0].widget.layout.virtualized = bits & 1 != 0;
        original.widget_layout_nodes[0].widget.layout.virtual_item_count = if (bits & 2 != 0) 100 else 0;
        if (bits & 4 != 0) original.widget_layout_nodes[0].frame.width = 0;
        for (0..3) |operation| {
            var a = original;
            var b = original;
            b.widget_tokens.scroll_mutation_policy = observed;
            const left = if (operation == 0) try View.M.applyCanvasWidgetScrollDriverOffset(&a, 0, value, value) else try View.M.applyCanvasWidgetScrollKeyboardTarget(&a, 0, if (operation == 1) .start else .end);
            const right = if (operation == 0) try View.M.applyCanvasWidgetScrollDriverOffset(&b, 0, value, value) else try View.M.applyCanvasWidgetScrollKeyboardTarget(&b, 0, if (operation == 1) .start else .end);
            try exact(left, right);
            try a.compare(&b);
        }
    };
    var a = View.init();
    var b = a;
    b.widget_tokens.scroll_mutation_policy = observed;
    try exact(try View.M.applyCanvasWidgetScrollDriverOffset(&a, 0, 17.25, 23.125), try View.M.applyCanvasWidgetScrollDriverOffset(&b, 0, 17.25, 23.125));
    try a.compare(&b);
    try std.testing.expectEqual(@as(f32, 0), b.widget_scroll_states[0].velocity_y);
    try std.testing.expectEqual(@as(usize, 0), b.observation_count);
}
test "compiled scroll mutation kinetic batches preserve clipped damage stopped axes and single publication" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (std.enums.values(c.ScrollAxes)) |axes| for (0..32) |bits| for ([_]f32{ -16, -0.0, 0, 16.667, 1000 }) |dt| {
        var a = View.init();
        a.widget_layout_nodes[0].widget.scroll_axes = axes;
        a.widget_layout_nodes[2].widget.scroll_axes = axes;
        a.widget_layout_nodes[0].widget.runtime_flags.native_scroll = bits & 1 != 0;
        a.widget_layout_nodes[2].widget.layout.virtualized = bits & 2 != 0;
        a.widget_layout_nodes[0].widget.overscroll = if (bits & 4 != 0) .rubber_band else .none;
        if (bits & 8 != 0) a.widget_layout_nodes[0].frame.height = 0;
        a.hidden_damage = bits & 16 != 0;
        var b = a;
        b.widget_tokens.scroll_mutation_policy = observed;
        try exact(try View.M.stepCanvasWidgetKineticScroll(&a, dt), try View.M.stepCanvasWidgetKineticScroll(&b, dt));
        try a.compare(&b);
        try std.testing.expect(b.semantic_refreshes <= 1);
    };
    var a = View.init();
    a.hidden_damage = true;
    var b = a;
    b.widget_tokens.scroll_mutation_policy = observed;
    try exact(try View.M.stepCanvasWidgetKineticScroll(&a, 16), try View.M.stepCanvasWidgetKineticScroll(&b, 16));
    try a.compare(&b);
    try std.testing.expectEqual(@as(usize, 1), b.semantic_refreshes);
}
test "compiled scroll mutation failure boundaries retain geometry events and revision precedence" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..5) |operation| {
        var a = View.init();
        a.fail_semantics = true;
        if (operation == 4) a.widget_layout_nodes[0].widget.kind = .textarea;
        var b = a;
        b.widget_tokens.scroll_mutation_policy = observed;
        const left = switch (operation) {
            0 => View.M.applyCanvasWidgetScrollAxis(&a, 0, .vertical, 31, .wheel, true),
            1 => View.M.applyCanvasWidgetScrollDriverOffset(&a, 0, 31, 42),
            2 => View.M.applyCanvasWidgetScrollKeyboardTarget(&a, 0, .end),
            3 => View.M.stepCanvasWidgetKineticScroll(&a, 16),
            else => View.M.applyCanvasWidgetTextareaScroll(&a, 0, 31, .discrete),
        };
        const right = switch (operation) {
            0 => View.M.applyCanvasWidgetScrollAxis(&b, 0, .vertical, 31, .wheel, true),
            1 => View.M.applyCanvasWidgetScrollDriverOffset(&b, 0, 31, 42),
            2 => View.M.applyCanvasWidgetScrollKeyboardTarget(&b, 0, .end),
            3 => View.M.stepCanvasWidgetKineticScroll(&b, 16),
            else => View.M.applyCanvasWidgetTextareaScroll(&b, 0, 31, .discrete),
        };
        try std.testing.expectError(error.InjectedSemanticsFailure, left);
        try std.testing.expectError(error.InjectedSemanticsFailure, right);
        try a.compare(&b);
        try std.testing.expectEqual(@as(u64, 9007199254740993), b.widget_revision);
    }
}
test "compiled scroll mutation empty invalid and special numeric inputs preserve complete records" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]f32{ -std.math.inf(f32), -0.0, 0, 0.0000001, 16777216, std.math.inf(f32), std.math.nan(f32) }) |value| {
        var original = View.init();
        original.widget_layout_nodes[0].widget.value = value;
        original.widget_layout_nodes[0].widget.value_x = value;
        original.widget_scroll_states[0].velocity_y = value;
        original.widget_scroll_states[0].velocity_x = value;
        for (0..4) |operation| {
            var a = original;
            var b = original;
            b.widget_tokens.scroll_mutation_policy = observed;
            const left = switch (operation) {
                0 => try View.M.applyCanvasWidgetScroll(&a, 0, .{ .dx = value, .dy = value }, .detented_wheel, true),
                1 => try View.M.stepCanvasWidgetKineticScroll(&a, value),
                2 => try View.M.applyCanvasWidgetScrollKeyboardTarget(&a, 99, .end),
                else => try View.M.applyCanvasWidgetTextareaScroll(&a, 99, value, .discrete),
            };
            const right = switch (operation) {
                0 => try View.M.applyCanvasWidgetScroll(&b, 0, .{ .dx = value, .dy = value }, .detented_wheel, true),
                1 => try View.M.stepCanvasWidgetKineticScroll(&b, value),
                2 => try View.M.applyCanvasWidgetScrollKeyboardTarget(&b, 99, .end),
                else => try View.M.applyCanvasWidgetTextareaScroll(&b, 99, value, .discrete),
            };
            try exact(left, right);
            try a.compare(&b);
        }
    }
    var a = View.init();
    a.widget_layout_node_count = 0;
    var b = a;
    b.widget_tokens.scroll_mutation_policy = observed;
    try exact(try View.M.stepCanvasWidgetKineticScroll(&a, 16), try View.M.stepCanvasWidgetKineticScroll(&b, 16));
    try a.compare(&b);
}
test "compiled scroll mutation event saturation zero identities and copied programs retain ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 9007199254740993, std.math.maxInt(u64) }) |id| for (0..3) |count| {
        var a = View.init();
        a.widget_scroll_event_ids = .{ 9007199254740993, std.math.maxInt(u64) };
        a.widget_scroll_event_count = count;
        a.widget_layout_nodes[0].widget.id = id;
        var b = a;
        b.widget_tokens.scroll_mutation_policy = observed;
        try exact(try View.M.applyCanvasWidgetScrollAxis(&a, 0, .vertical, 31, .discrete, false), try View.M.applyCanvasWidgetScrollAxis(&b, 0, .vertical, 31, .discrete, false));
        try a.compare(&b);
    };
    const p = testing.scroll_mutation_policy;
    const program = p.plan(observed, .axis, 2, 0, true, 1 | 2 | 16 | 256 | 512);
    core.rt.frameReset();
    _ = p.plan(observed, .finish, 0, 0, false, 512);
    try std.testing.expectEqual(@as(usize, 6), program.count);
    const expected = [_]p.Kind{ .write_axis, .translate_axis, .event, .semantics, .revision, .dirty };
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, program.instruction(i));
}
test "compiled scroll mutation kinetic selection batches full budgets and owns copied masks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [1024]c.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(if (i == 512) .scroll_view else .text, i + 1, 0, null);
    const before = calls[4];
    const selection = testing.scroll_mutation_policy.kineticSelection(observed, &nodes);
    core.rt.frameReset();
    nodes[512].widget.runtime_flags.native_scroll = true;
    const revoked = testing.scroll_mutation_policy.kineticSelection(observed, &nodes);
    for (selection.include, revoked.include, 0..) |include, excluded, i| {
        try std.testing.expectEqual(i == 512, include);
        try std.testing.expect(!excluded);
    }
    try std.testing.expectEqual(before, calls[4]);
}
test "compiled scroll mutation actual runtime retains complete semantics events and descendant frames" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const H = sdk.TestHarness();
    const a = try H.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try H.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*H{ a, b }, 0..) |h, i| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = h, .name = "scroll-mutation", .source = sdk.platform.WebViewSource.html("") });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 300, 200) });
        const v = &h.runtime.views[0];
        var nodes = View.init().widget_layout_nodes;
        nodes[0].widget.scroll_axes = .both;
        nodes[2].widget.scroll_axes = .horizontal;
        @memcpy(v.widget_layout_nodes[0..nodes.len], &nodes);
        v.widget_layout_node_count = nodes.len;
        @memcpy(v.widget_scroll_states[0..nodes.len], &View.init().widget_scroll_states);
        if (i == 1) v.widget_tokens.scroll_mutation_policy = observed;
        try v.refreshCanvasWidgetSemantics();
    }
    const x = &a.runtime.views[0];
    const y = &b.runtime.views[0];
    for (0..6) |step| {
        const left = switch (step) {
            0 => try x.applyCanvasWidgetScroll(0, .{ .dx = 13, .dy = 31 }, .wheel, false),
            1 => try x.stepCanvasWidgetKineticScroll(16),
            2 => try x.applyCanvasWidgetScrollDriverOffset(0, 17, 29),
            3 => try x.applyCanvasWidgetScrollKeyboardTarget(0, .end),
            4 => try x.applyCanvasWidgetScroll(0, .{}, .detented_wheel, false),
            else => try x.applyCanvasWidgetScrollKeyboardTarget(0, .start),
        };
        const right = switch (step) {
            0 => try y.applyCanvasWidgetScroll(0, .{ .dx = 13, .dy = 31 }, .wheel, false),
            1 => try y.stepCanvasWidgetKineticScroll(16),
            2 => try y.applyCanvasWidgetScrollDriverOffset(0, 17, 29),
            3 => try y.applyCanvasWidgetScrollKeyboardTarget(0, .end),
            4 => try y.applyCanvasWidgetScroll(0, .{}, .detented_wheel, false),
            else => try y.applyCanvasWidgetScrollKeyboardTarget(0, .start),
        };
        try exact(left, right);
        try exact(x.widgetLayoutTree().nodes, y.widgetLayoutTree().nodes);
        try exact(x.widget_semantics_nodes[0..x.widget_semantics_node_count], y.widget_semantics_nodes[0..y.widget_semantics_node_count]);
        try exact(x.widget_scroll_states[0..4].*, y.widget_scroll_states[0..4].*);
        try exact(x.widget_scroll_event_ids[0..x.widget_scroll_event_count], y.widget_scroll_event_ids[0..y.widget_scroll_event_count]);
        try exact(x.widget_revision, y.widget_revision);
    }
}
