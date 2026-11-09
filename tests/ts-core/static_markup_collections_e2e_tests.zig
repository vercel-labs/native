const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
fn exact(a: anytype, b: @TypeOf(a)) anyerror!void {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| try exact(@field(a, field.name), @field(b, field.name)),
        .optional => {
            try std.testing.expectEqual(a != null, b != null);
            if (a) |value| try exact(value, b.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(a.len, b.len);
            for (a, b) |l, r| try exact(l, r);
        } else if (info.size == .one and (@typeInfo(info.child) == .@"struct" or @typeInfo(info.child) == .@"union" or info.child == bool)) try exact(a.*, b.*) else try std.testing.expectEqual(a, b),
        .array => for (a, b) |l, r| try exact(l, r),
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
            switch (a) {
                inline else => |value, tag| try exact(value, @field(b, @tagName(tag))),
            }
        },
        else => try @import("surface_layout_e2e_tests.zig").expectComplete(a, b),
    }
}

var values: [256]usize = @splat(0);
var specialized: [256]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) values[input[2]] += 1;
    if (input[0] == 112) specialized[input[2]] += 1;
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
var events: [4096]u64 = undefined;
var event_count: usize = 0;
fn event(value: u64) void {
    events[event_count] = value;
    event_count += 1;
}
const Row = struct { id: i64, title: []const u8 };
const rows_data = [_]Row{ .{ .id = -9007199254740993, .title = "Borrowed\x00\xff" }, .{ .id = 9007199254740993, .title = "Second" } };
const Model = struct {
    count: i64 = 2,
    base: i64 = 0,
    overscan: i64 = 0,
    active: i64 = 1,
    extent: f64 = 24,
    gap: f64 = 0,
    fallback: f64 = 48,
    wrong_count: bool = false,
    pub fn itemCount(self: *const Model) i64 {
        event(1);
        return self.count;
    }
    pub fn itemExtent(self: *const Model) f64 {
        event(2);
        return self.extent;
    }
    pub fn itemGap(self: *const Model) f64 {
        event(3);
        return self.gap;
    }
    pub fn itemOverscan(self: *const Model) i64 {
        event(4);
        return self.overscan;
    }
    pub fn itemFallback(self: *const Model) f64 {
        event(5);
        return self.fallback;
    }
    pub fn itemBase(self: *const Model) i64 {
        event(6);
        return self.base;
    }
    pub fn rows(self: *const Model, range: c.VirtualListRange) []const Row {
        event(7);
        event(range.start_index);
        event(range.end_index);
        return rows_data[0..if (self.wrong_count) 1 else @min(rows_data.len, range.itemCount())];
    }
    pub fn virtualExtentHelper(name: []const u8) ?u32 {
        return if (std.mem.eql(u8, name, "estimate")) 0 else null;
    }
    pub fn virtualExtentEstimate(_: ?*const anyopaque, index: u64) f32 {
        event(8);
        event(index);
        return 24;
    }
};
const Msg = union(enum) { tick, selected: i64 };
const Ui = c.Ui(Msg);
const unlimited = std.math.maxInt(usize);
const Outcome = struct { allocations: usize, resizes: usize, failed: bool, callbacks: usize, windows: usize };
fn sink(_: *anyopaque, _: u64, _: *const c.ui_provenance.NodeSource, _: []const c.ui_provenance.Key, _: bool) void {}
fn aliases(a: Ui.Node, b: Ui.Node) anyerror!void {
    if (a.on_press) |message| {
        if (message == .selected) try std.testing.expectEqual(message.selected, b.on_press.?.selected);
    }
    for (a.nodes, b.nodes) |left, right| try aliases(left, right);
}
fn compare(comptime source: []const u8, model: Model, failure: usize, resize: usize, prime: u8) !Outcome {
    const View = c.CompiledMarkupView(Model, Msg, source);
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var left = Ui.init(fa.allocator());
    var right = Ui.init(fb.allocator());
    right.expression_policy = observed;
    if (prime > 0) {
        const count: usize = if (prime == 1) 1 else c.max_virtual_windows;
        for (0..count) |index| {
            const identity: []const u8 = if (index == 0) "window" else "prior";
            const options: Ui.VirtualListOptions = .{ .id = identity, .item_count = 0, .item_extent = 24 };
            _ = left.virtualList(options, .{}, .{});
            _ = right.virtualList(options, .{}, .{});
        }
    }
    var context: u8 = 0;
    const provenance: c.ui_provenance.Sink = .{ .context = &context, .record_fn = sink };
    left.provenance_sink = provenance;
    right.provenance_sink = provenance;
    event_count = 0;
    const a = View.build(&left, &model);
    const before = events;
    const count = event_count;
    event_count = 0;
    const b = View.build(&right, &model);
    errdefer std.debug.print("static collections source={s} failure={d} resize={d} prime={d}\n", .{ source, failure, resize, prime });
    try exact(before[0..count], events[0..event_count]);
    try exact(a, b);
    try aliases(a, b);
    const at = left.finalize(a);
    const bt = right.finalize(b);
    if (at) |tree| try exact(tree, try bt) else |err| try std.testing.expectError(err, bt);
    try exact(left.failed, right.failed);
    try exact(left.virtualWindows(), right.virtualWindows());
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    return .{ .allocations = fa.alloc_index, .resizes = fa.resize_index, .failed = left.failed, .callbacks = count, .windows = left.virtualWindows().len };
}
fn check(comptime source: []const u8, model: Model, failed: bool, faults: bool) !void {
    const result = try compare(source, model, unlimited, unlimited, 0);
    try std.testing.expectEqual(failed, result.failed);
    if (faults) {
        for (0..result.allocations + 1) |index| _ = try compare(source, model, index, unlimited, 0);
        for (0..result.resizes + 1) |index| _ = try compare(source, model, unlimited, index, 0);
    }
}
const prefix = "<virtual-window id=\"window\" as=\"window\" item-count=\"{itemCount}\" item-extent=\"{itemExtent}\" gap=\"{itemGap}\" overscan=\"{itemOverscan}\" viewport-fallback=\"{itemFallback}\" index-base=\"{itemBase}\">";
const list = "<virtual-list window=\"window\" each=\"rows\" as=\"row\" label=\"Rows\" height=\"48\"><button key=\"{row.id}\" on-press=\"selected:{row.id}\">{row.title}</button></virtual-list>";
const window = prefix ++ list ++ "</virtual-window>";
test "static markup collections preserve successful rows exact keys callbacks and allocation failures" {
    _ = core.initialModel();
    values = @splat(0);
    specialized = @splat(0);
    try check(window, .{}, false, true);
    const result = try compare(window, .{}, unlimited, unlimited, 0);
    try std.testing.expectEqual(@as(usize, 1), result.windows);
    try std.testing.expect(result.callbacks >= 9);
    for ([_]usize{ 21, 22, 24, 25, 26 }) |mode| try std.testing.expect(values[mode] > 0);
    for ([_]usize{ 15, 17, 18, 19, 20 }) |mode| try std.testing.expect(specialized[mode] > 0);
}
test "static markup collections preserve safe count bounds and eager evaluation after invalid values" {
    _ = core.initialModel();
    for ([_]i64{ -9223372036854775808, -1, 0, 1, 2, 9007199254740991, 9007199254740992, 9007199254740993, 9223372036854775807 }) |count| {
        _ = try compare(window, .{ .count = count }, unlimited, unlimited, 0);
        if (count < 0 or count > 9007199254740991) try check(window, .{ .count = count }, true, false);
    }
    try check(window, .{ .overscan = -1 }, true, true);
    try check(window, .{ .base = 9007199254740990 }, true, true);
    try check(window, .{ .base = 9007199254740989 }, false, false);
}
test "static markup collections preserve float bit admission and extent estimator precedence" {
    _ = core.initialModel();
    for ([_]f64{ -std.math.inf(f64), -1, -0.0, 0, std.math.floatTrueMin(f64), 24, std.math.inf(f64), std.math.nan(f64) }) |extent| {
        _ = try compare(window, .{ .extent = extent }, unlimited, unlimited, 0);
        _ = try compare(window, .{ .gap = extent }, unlimited, unlimited, 0);
        _ = try compare(window, .{ .fallback = extent }, unlimited, unlimited, 0);
    }
    const estimated = "<virtual-window id=\"window\" as=\"window\" item-count=\"{count}\" extent-estimate=\"estimate\" viewport-fallback=\"48\">" ++ list ++ "</virtual-window>";
    try check(estimated, .{ .extent = 0 }, false, true);
    try check(window, .{ .extent = -0.0 }, true, true);
}
test "static markup collections preserve missing defaults duplicate and capacity failure order" {
    _ = core.initialModel();
    const defaults = "<virtual-window id=\"window\" as=\"window\" item-extent=\"24\">" ++ list ++ "</virtual-window>";
    try check(defaults, .{}, false, true);
    for ([_]u8{ 1, 2 }) |prime| {
        const result = try compare(window, .{}, unlimited, unlimited, prime);
        try std.testing.expect(result.failed);
        try std.testing.expectEqual(@as(usize, 0), result.callbacks);
    }
}
test "static markup collections preserve consumption query mismatch keyed row and template failures" {
    _ = core.initialModel();
    try check(prefix ++ "<column><text>Unused</text></column></virtual-window>", .{}, true, true);
    try check(prefix ++ "<column>" ++ list ++ list ++ "</column></virtual-window>", .{}, true, true);
    try check(window, .{ .wrong_count = true }, true, true);
    try check(prefix ++ "<virtual-list window=\"window\" each=\"rows\" as=\"row\"><text>{row.title}</text></virtual-list></virtual-window>", .{}, true, true);
    const template = "<template name=\"row-view\" args=\"key title\"><button global-key=\"{key}\" on-press=\"tick\">{title}</button></template>" ++ prefix ++ "<virtual-list window=\"window\" each=\"rows\" as=\"row\"><use template=\"row-view\" key=\"{row.id}\" title=\"{row.title}\"/></virtual-list></virtual-window>";
    try check(template, .{}, false, true);
}
test "static markup collections preserve exact positive and clamped negative stepper indices" {
    _ = core.initialModel();
    values = @splat(0);
    const source = "<stepper active=\"{active}\" key=\"{active}\" label=\"Steps\"><step>One</step><step>Two</step></stepper>";
    for ([_]i64{ -9223372036854775808, -9007199254740993, -1, 0, 1, 2, 9007199254740993, 9223372036854775807 }) |active| try check(source, .{ .active = active }, false, true);
    try check("<template name=\"steps\" args=\"active\"><stepper active=\"{active}\"><slot/></stepper></template><use template=\"steps\" active=\"{active}\"><step>One</step><step>Two</step></use>", .{ .active = -1 }, false, true);
    try std.testing.expect(values[21] > 0);
}
