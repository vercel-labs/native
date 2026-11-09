const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const p = sdk.runtime.testing.virtual_window_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls = [_]usize{0} ** 5;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 97) calls[input[1]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn node(id: u64, parent: ?usize) c.WidgetLayoutNode {
    return .{ .widget = .{ .id = id, .kind = .list_item, .text = "row\x00\xff", .semantics = .{ .list_item_index = 0 } }, .frame = .init(0, 0, 100, 24), .depth = 0, .parent_index = parent };
}
fn comparePlan(records: []const c.VirtualWindowRecord, nodes: []const c.WidgetLayoutNode) !void {
    const plan = p.Layout.init(observed, records, nodes);
    core.rt.frameReset();
    for (records, 0..) |record, i| {
        const actual = plan.list(i);
        var selected: ?usize = null;
        for (nodes, 0..) |n, j| if (n.widget.id == record.id) {
            selected = j;
            break;
        };
        try std.testing.expectEqual(selected, actual.node);
        var measure = false;
        var coverage: @TypeOf(actual.coverage) = .skip;
        if (selected) |slot| {
            const content = nodes[slot].frame.inset(nodes[slot].widget.layout.padding).normalized();
            if (!content.isEmpty()) {
                if (record.id != 0) coverage = if (!record.variable) .fixed else if (record.item_count != 0) .variable else .skip;
                measure = record.variable and record.item_count != 0;
            }
        }
        try std.testing.expectEqual(coverage, actual.coverage);
        try std.testing.expectEqual(measure, actual.measure);
        var count: usize = 0;
        if (measure) for (nodes, 0..) |n, j| {
            if (n.parent_index == null or n.parent_index.? != selected.? or n.widget.layout.anchor != null or n.widget.semantics.list_item_index == null) continue;
            try std.testing.expectEqual(j, p.row(actual.rows, count));
            count += 1;
        };
        try std.testing.expectEqual(count * 4, actual.rows.len);
    }
}
test "compiled virtual window complete selection exact identities rows and copied ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const ids = [_]u64{ 0, 1, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
    for (ids) |id| for (0..128) |bits| {
        var nodes = [_]c.WidgetLayoutNode{ node(id, null), node(2, 0), node(3, 1), node(4, 0), node(id, null) };
        if (bits & 1 != 0) nodes[0].frame.height = 0;
        if (bits & 2 != 0) nodes[1].widget.layout.anchor = .{};
        if (bits & 4 != 0) nodes[3].widget.semantics.list_item_index = null;
        if (bits & 8 != 0) nodes[3].parent_index = null;
        const records = [_]c.VirtualWindowRecord{ .{ .id = id, .item_count = if (bits & 16 != 0) 0 else std.math.maxInt(usize), .variable = bits & 32 != 0 }, .{ .id = id, .item_count = 99, .variable = bits & 64 != 0 }, .{ .id = 7, .variable = true, .item_count = 10 } };
        const before = nodes;
        try comparePlan(&records, &nodes);
        try exact(before, nodes);
        for (ids) |query| {
            var found = false;
            if (query != 0) for (records) |record| if (record.id == query) {
                found = true;
                break;
            };
            try std.testing.expectEqual(found, p.contains(observed, query, &records));
        }
    };
    var nodes: [1024]c.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(if (i == 0) std.math.maxInt(u64) else i, if (i == 0) null else 0);
    const records = [_]c.VirtualWindowRecord{.{ .id = std.math.maxInt(u64), .item_count = 2000, .variable = true }} ** 8;
    try comparePlan(&records, &nodes);
    try comparePlan(&.{}, &.{});
    try std.testing.expect(calls[0] >= 642 and calls[1] == 3200);
}
test "compiled virtual window retry budget correction threshold and exact fixed coverage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..3) |pass| for ([_]bool{ false, true }) |corrected| for ([_]?bool{ null, false, true }) |covered| {
        const expected: p.Retry = if (pass >= 2) .stop else if (corrected) .rebuild else if (covered == null) .probe else if (covered.?) .rebuild else .stop;
        try std.testing.expectEqual(expected, p.retry(observed, pass, corrected, covered));
    };
    for ([_]f32{ -std.math.inf(f32), -0.50000006, -0.5, -0.0, 0, 0.5, 0.50000006, std.math.inf(f32), std.math.nan(f32) }) |delta|
        try std.testing.expectEqual(@abs(delta) > 0.5, p.corrected(observed, &.{ 0, delta, 0.5 }));
    try std.testing.expect(!p.corrected(observed, &.{}));
    for ([_]usize{ 0, 1, 20, 9007199254740993 }) |count| for ([_]usize{ 0, 2, 20 }) |overscan| for ([_]f32{ -1, 0, 17.25, 100, 10000, std.math.inf(f32), std.math.nan(f32) }) |offset| {
        const record: c.VirtualWindowRecord = .{ .id = 1, .item_count = count, .item_extent = 24, .gap = 3, .overscan = overscan, .start_index = 2, .end_index = 8 };
        var n = node(1, null);
        n.widget.value = offset;
        n.frame.height = 101;
        n.widget.layout.padding = .all(2);
        const range = c.virtualListRange(.{ .item_count = count, .item_extent = 24, .item_gap = 3, .overscan = overscan, .scroll_offset = offset, .viewport_extent = 97 });
        try std.testing.expectEqual(range.start_index < record.start_index or range.end_index > record.end_index, p.fixedUndercovered(observed, record, n));
    };
    try std.testing.expect(calls[2] == 18 and calls[3] == 10 and calls[4] == 84);
}

const Model = struct { base: u64 = 1000, count: usize = 100, variable: bool = true, trailing: bool = false };
const Msg = union(enum) { append, prepend, trim, toggle };
const App = sdk.UiApp(Model, Msg);
fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .append => model.count += 7,
        .prepend => {
            model.base -= 5;
            model.count += 5;
        },
        .trim => {
            model.base += 3;
            model.count -= 3;
        },
        .toggle => model.trailing = !model.trailing,
    }
}
fn estimate(_: ?*const anyopaque, _: u64) f32 {
    return 35;
}
fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
    const options: App.Ui.VirtualListOptions = .{ .id = "rows", .item_count = model.count, .item_extent = 28, .gap = 3, .index_base = model.base, .extent_estimate = if (model.variable) estimate else null, .overscan = 2, .anchor = if (model.trailing) .trailing else .leading, .grow = 1 };
    const range = ui.virtualWindow(options);
    const rows = ui.arena.alloc(App.Ui.Node, range.itemCount()) catch @panic("test row allocation failed");
    for (rows, 0..) |*row, i| {
        const logical = model.base + range.start_index + i;
        row.* = ui.listItem(.{ .key = .{ .int = logical }, .height = if (model.variable) @floatFromInt(20 + logical % 5 * 13) else 28 }, ui.fmt("Row {d}", .{logical}));
    }
    return ui.column(.{ .gap = 8 }, .{ ui.text(.{}, "Virtual window coordination"), ui.virtualList(options, range, .{rows}) });
}
const scene: sdk.app_manifest.ShellConfig = .{ .windows = &.{.{ .label = "main", .title = "Virtual windows", .width = 400, .height = 300, .views = &.{.{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }} }} };
const Pair = struct {
    h: *sdk.TestHarness(),
    app: *App,
    fn create(compiled: bool, model: Model) !Pair {
        const h = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(400, 300) });
        errdefer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        const a = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(a);
        a.* = App.init(std.heap.page_allocator, model, .{ .name = "virtual-window-test", .scene = scene, .canvas_label = "canvas", .view = view, .update = update, .virtual_window_policy = if (compiled) observed else null });
        try h.start(a.app());
        try h.runtime.dispatchPlatformEvent(a.app(), .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(400, 300), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1000000, .nonblank = true } });
        return .{ .h = h, .app = a };
    }
    fn destroy(self: Pair) void {
        self.app.deinit();
        std.testing.allocator.destroy(self.app);
        self.h.destroy(std.testing.allocator);
    }
    fn wheel(self: Pair, delta: f32) !void {
        var bytes: [96]u8 = undefined;
        try self.h.runtime.dispatchAutomationCommand(self.app.app(), try std.fmt.bufPrint(&bytes, "widget-wheel canvas {d} {d}", .{ c.globalWidgetId(.scroll_view, .{ .str = "rows" }), delta }));
    }
};
fn compareRuntime(a: Pair, b: Pair) !void {
    core.rt.frameReset();
    try exact(a.app.model, b.app.model);
    try exact(a.app.tree.?.root, b.app.tree.?.root);
    try exact(try a.h.runtime.canvasWidgetLayout(1, "canvas"), try b.h.runtime.canvasWidgetLayout(1, "canvas"));
    try exact(a.app.virtual_windows[0..a.app.virtual_window_count], b.app.virtual_windows[0..b.app.virtual_window_count]);
    // Compare every initialized retained field; unused cache capacity is
    // undefined storage, not part of the table's observable state.
    for (&a.app.virtual_extent_tables, &b.app.virtual_extent_tables) |*left, *right| {
        inline for (@typeInfo(c.VirtualExtentTable).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "chunk_prefix")) {
                if (left.id != 0) try exact(left.chunk_prefix[0 .. left.chunk_count + 1], right.chunk_prefix[0 .. right.chunk_count + 1]);
            } else if (comptime std.mem.eql(u8, field.name, "measured_index")) {
                try exact(left.measured_index[0..left.measured_count], right.measured_index[0..right.measured_count]);
            } else if (comptime std.mem.eql(u8, field.name, "measured_delta")) {
                try exact(left.measured_delta[0..left.measured_count], right.measured_delta[0..right.measured_count]);
            } else if (comptime std.mem.eql(u8, field.name, "measured_prefix")) {
                if (!left.measured_prefix_dirty) try exact(left.measured_prefix[0..left.measured_count], right.measured_prefix[0..right.measured_count]);
            } else try exact(@field(left.*, field.name), @field(right.*, field.name));
        }
    }
}
test "compiled virtual window runtime preserves complete fixed variable prepend trim resize and anchor states" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |variable| for ([_]bool{ false, true }) |trailing| {
        const a = try Pair.create(false, .{ .variable = variable, .trailing = trailing });
        defer a.destroy();
        const b = try Pair.create(true, .{ .variable = variable, .trailing = trailing });
        defer b.destroy();
        try compareRuntime(a, b);
        for ([_]f32{ 150, 400, -100, -500 }) |delta| {
            try a.wheel(delta);
            try b.wheel(delta);
            try compareRuntime(a, b);
        }
        for ([_]f32{ 180, 600, 300 }) |height| {
            const event: sdk.platform.Event = .{ .gpu_surface_resized = .{ .label = "canvas", .window_id = 1, .frame = .init(0, 0, 400, height), .scale_factor = 1 } };
            try a.h.runtime.dispatchPlatformEvent(a.app.app(), event);
            try b.h.runtime.dispatchPlatformEvent(b.app.app(), event);
            try compareRuntime(a, b);
        }
        for ([_]Msg{ .append, .prepend, .trim, .toggle, .append }) |msg| {
            try a.app.dispatch(&a.h.runtime, 1, msg);
            try b.app.dispatch(&b.h.runtime, 1, msg);
            try compareRuntime(a, b);
        }
    };
}
