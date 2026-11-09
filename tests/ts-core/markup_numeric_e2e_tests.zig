const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const m = c.ui_markup;
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

var operations: [256]usize = @splat(0);
var channels: [3]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) {
        operations[input[2]] += 1;
        if (input[2] == 21) {
            const channel: usize = @intFromFloat(@as(f64, @bitCast(std.mem.readInt(u64, input[4..12], .little))));
            channels[channel] += 1;
        }
    }
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
var trace: [2048]i64 = undefined;
var trace_len: usize = 0;
fn event(value: i64) void {
    trace[trace_len] = value;
    trace_len += 1;
}
const Row = struct { id: i64, title: []const u8 };
const Model = struct {
    count: i64 = 2,
    base: i64 = 0,
    overscan: i64 = 0,
    active: i64 = 1,
    grid: i64 = 3,
    extent: f64 = 24,
    gap: f64 = 1,
    fallback: f64 = 80,
    truth: bool = true,
    samples: []const f32 = &.{ 1, 3, 2 },
    rows_data: []const Row = &.{ .{ .id = -9223372036854775808, .title = "First" }, .{ .id = 9223372036854775807, .title = "Second" } },
    pub fn first(_: *const Model) i64 {
        event(1);
        return 2;
    }
    pub fn second(_: *const Model) f64 {
        event(2);
        return 12;
    }
    pub fn rows(self: *const Model, range: c.VirtualListRange) []const Row {
        event(3);
        event(@intCast(range.start_index));
        event(@intCast(range.end_index));
        return self.rows_data[@min(range.start_index, self.rows_data.len)..@min(range.end_index, self.rows_data.len)];
    }
    pub fn virtualExtentHelper(name: []const u8) ?u32 {
        event(4);
        return if (std.mem.eql(u8, name, "estimate")) 0 else null;
    }
    pub fn virtualExtentEstimate(_: ?*const anyopaque, _: u64) f32 {
        event(5);
        return 24;
    }
};
const Msg = union(enum) { tick, input: c.TextInputEvent };
const Ui = c.Ui(Msg);
const View = c.MarkupView(Model, Msg);
const unlimited = std.math.maxInt(usize);
var last_resizes: usize = 0;
fn compare(doc: m.MarkupDocument, model: Model, failure: usize, resize: usize) !usize {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var ui_a = Ui.init(fa.allocator());
    var ui_b = Ui.init(fb.allocator());
    ui_b.expression_policy = observed;
    var a = View.fromDocument(doc);
    var b = View.fromDocument(doc);
    trace_len = 0;
    const left = View.ConstructionTest.run(&a, &ui_a, &model, 0, 0, 0, null);
    const before = trace;
    const length = trace_len;
    trace_len = 0;
    const right = View.ConstructionTest.run(&b, &ui_b, &model, 0, 0, 0, null);
    try exact(before[0..length], trace[0..trace_len]);
    try exact(left.failure, right.failure);
    try exact(left.node, right.node);
    try exact(left.scope.entries, right.scope.entries);
    try exact(left.scope.len, right.scope.len);
    try exact(left.scope.floor, right.scope.floor);
    try exact(left.scope.use_depth, right.scope.use_depth);
    try exact(left.scope.template_ctx, right.scope.template_ctx);
    try exact(left.scope.source_chain, right.scope.source_chain);
    if (left.node) |node| {
        const lt = ui_a.finalize(node);
        const rt = ui_b.finalize(right.node.?);
        if (lt) |tree| try exact(tree, try rt) else |err| try std.testing.expectError(err, rt);
    }
    try exact(ui_a.virtualWindows(), ui_b.virtualWindows());
    try exact(a.diagnostic, b.diagnostic);
    try exact(ui_a.failed, ui_b.failed);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    last_resizes = fa.resize_index;
    return fa.alloc_index;
}
fn document(arena: std.mem.Allocator, source: []const u8, typed: bool) !m.MarkupDocument {
    var parser = m.Parser.init(arena, source);
    const doc = try parser.parse();
    return if (typed) m.canonicalize(arena, doc) else doc;
}
fn check(source: []const u8, model: Model, failures: bool) !void {
    errdefer std.debug.print("numeric option parity failed: {s}\n", .{source});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        const count = try compare(doc, model, unlimited, unlimited);
        const resizes = last_resizes;
        if (failures) {
            for (0..count + 1) |index| _ = try compare(doc, model, index, unlimited);
            for (0..resizes + 1) |index| _ = try compare(doc, model, unlimited, index);
        }
    }
}
fn integer(value: i64) !void {
    for (0..3) |channel| {
        const row = View.NumericTest.integerOption(observed, @intCast(channel), .{ .integer = value }, 255);
        const accepted = switch (channel) {
            0 => value >= 0 and value <= 9007199254740991,
            1 => true,
            else => value >= 0 and value <= 255,
        };
        try std.testing.expectEqual(@as(u8, if (accepted) (if (channel == 1 and value < 0) 2 else 1) else 255), row.action);
        if (!accepted) try std.testing.expectEqual(@as(u8, if (channel == 0) 49 else 54), row.code);
    }
}
test "compiled markup numeric preserves exact signed i64 bounds kinds and stepper clamping" {
    _ = core.initialModel();
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, -1, 0, 1, 254, 255, 256, 4294967295, 4294967296, 9007199254740991, 9007199254740992, 9007199254740993, std.math.maxInt(i64) }) |value| try integer(value);
    for (0..257) |value| try integer(@intCast(value));
    var bits: u64 = 0x6e756d6572696373;
    for (0..4096) |_| {
        bits = bits *% 6364136223846793005 +% 1442695040888963407;
        try integer(@bitCast(bits));
    }
    for ([_]m.expr.Value{ .{ .float = 1 }, .{ .float = std.math.nan(f64) }, .{ .boolean = true }, .{ .string = "2" } }) |value| {
        for ([_]u8{ 0, 1, 2 }) |channel| {
            const row = View.NumericTest.integerOption(observed, channel, value, 255);
            try std.testing.expectEqual(@as(u8, 255), row.action);
            try std.testing.expectEqual(@as(u8, switch (channel) {
                0 => 50,
                1 => 52,
                else => 53,
            }), row.code);
        }
    }
}
fn extent(bits: u32) !void {
    const value: f32 = @bitCast(bits);
    try std.testing.expectEqual(std.math.isFinite(value) and value >= 0, View.NumericTest.virtualExtent(observed, value));
    if (std.math.isFinite(value) and value >= 0) for ([_]bool{ false, true }) |estimator| {
        const failure = View.NumericTest.virtualExtentRequired(observed, value, estimator);
        try std.testing.expectEqual(!estimator and value == 0, failure != null);
    };
}
test "compiled markup numeric preserves f32 extent zeros subnormals infinities NaNs defaults and raw anchors" {
    _ = core.initialModel();
    for ([_]u32{ 0, 1, 0x7fffff, 0x800000, 0x3f800000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x80000000, 0x80000001, 0xff7fffff, 0xff800000, 0xffffffff }) |bits| try extent(bits);
    var bits: u32 = 0x65787465;
    for (0..4096) |_| {
        bits = bits *% 1664525 +% 1013904223;
        try extent(bits);
    }
    const Anchor = enum(u8) { trailing = 7, leading = 42 };
    for ([_][]const u8{ "", "leading", "trailing", "Trailing", "trailing ", "trailing\x00", "\xff", "{truth}" }) |raw| {
        try std.testing.expectEqual(if (std.mem.eql(u8, raw, "trailing")) Anchor.trailing else Anchor.leading, View.NumericTest.virtualAnchor(Anchor, observed, raw));
    }
    for ([_][]const u8{ "item-count", "overscan", "index-base", "item-extent", "gap", "viewport-fallback" }, 0..) |name, index| {
        for ([_]bool{ false, true }) |present| {
            const row = View.NumericTest.virtualAttribute(observed, if (index < 3) 0 else 1, name, present);
            try std.testing.expectEqual(@as(u8, if (present) 1 else 0), row.action);
            if (!present) try std.testing.expectEqual(@as(usize, if (index == 1) 4 else 0), row.fields[0]);
        }
    }
    for ([_]usize{ 0, 1, 2, 4294967296, 9007199254740990, 9007199254740991 }) |base| for ([_]usize{ 0, 1, 2, 4294967296, 9007199254740991 }) |count| {
        try std.testing.expectEqual(@as(u128, base) + count > 9007199254740991, View.NumericTest.virtualRange(observed, base, count) != null);
    };
}
const rows = "<virtual-list window=\"window\" each=\"rows\" as=\"row\" height=\"80\" label=\"Rows\"><text key=\"{row.id}\">{row.title}</text></virtual-list>";
const window = "<virtual-window id=\"rows\" as=\"window\" item-count=\"{count}\" item-extent=\"{extent}\" gap=\"{gap}\" overscan=\"{overscan}\" viewport-fallback=\"{fallback}\" index-base=\"{base}\" anchor=\"trailing\">" ++ rows ++ "</virtual-window>";
const controls = "<column><stepper active=\"{active}\"><step>Build</step><step>Verify</step></stepper><chart grid-lines=\"{grid}\"><series values=\"{samples}\"/></chart></column>";
test "compiled markup numeric preserves complete virtual windows controls and every observed allocation and resize failure" {
    _ = core.initialModel();
    operations = @splat(0);
    channels = @splat(0);
    try check(window, .{}, true);
    try check(controls, .{}, true);
    try check("<virtual-window id=\"defaults\" as=\"window\" extent-estimate=\"estimate\">" ++ rows ++ "</virtual-window>", .{}, true);
    try check("<virtual-window id=\"fixed\" as=\"window\" item-count=\"{first}\" item-extent=\"{second}\" viewport-fallback=\"80\">" ++ rows ++ "</virtual-window>", .{}, true);
    for ([_]usize{ 21, 22, 23, 24, 25, 26 }) |mode| try std.testing.expect(operations[mode] > 0);
    for (channels) |count| try std.testing.expect(count > 0);
}
test "compiled markup numeric preserves converted boundaries diagnostics and eager failure effects" {
    _ = core.initialModel();
    for ([_]Model{ .{ .count = -1 }, .{ .count = 9007199254740992 }, .{ .count = std.math.maxInt(i64) }, .{ .base = 9007199254740990 }, .{ .base = -1 }, .{ .overscan = -1 }, .{ .extent = -0.0 }, .{ .extent = 1e-50 }, .{ .extent = 1e-45 }, .{ .extent = 1e39 }, .{ .extent = std.math.nan(f64) }, .{ .gap = -1 }, .{ .fallback = std.math.inf(f64) } }) |model| try check(window, model, false);
    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, 255, 256, 9007199254740993, std.math.maxInt(i64) }) |value| try check(controls, .{ .active = value, .grid = value }, false);
    for ([_][]const u8{
        "<stepper active=\"{first}\" active=\"{truth}\"><step>{second}</step></stepper>",
        "<stepper active=\"{truth}\"><step>{second}</step></stepper>",
        "<chart grid-lines=\"{second}\" width=\"{first}\"><series values=\"{samples}\"/></chart>",
        "<chart grid-lines=\"-1\" width=\"{second}\"><series values=\"{samples}\"/></chart>",
        "<virtual-window id=\"bad-count\" as=\"window\" item-count=\"{truth}\" item-extent=\"{second}\"><text>{first}</text></virtual-window>",
        "<virtual-window id=\"bad-extent\" as=\"window\" item-count=\"{first}\" item-extent=\"-1\" gap=\"{second}\"><text>{first}</text></virtual-window>",
        "<virtual-window id=\"range\" as=\"window\" item-count=\"9007199254740991\" item-extent=\"{second}\" index-base=\"1\" extent-estimate=\"estimate\"><text>{first}</text></virtual-window>",
        "<virtual-window id=\"zero\" as=\"window\" item-count=\"{first}\"><text>{second}</text></virtual-window>",
        "<virtual-window id=\"estimate\" as=\"window\" extent-estimate=\"missing\"><text>{first}</text></virtual-window>",
        "<virtual-window id=\"duplicate\" as=\"window\" item-count=\"{first}\" item-count=\"{truth}\" item-extent=\"{second}\" anchor=\"unknown\">" ++ rows ++ "</virtual-window>",
    }) |source| try check(source, .{}, true);
}
test "compiled markup numeric retains unclassified count inputs and typed extent cache distinctions" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "item-count", "item-extent", "overscan", "index-base" }) |name| {
        var doc = try document(arena.allocator(), window, false);
        const attrs = try arena.allocator().dupe(m.MarkupAttr, doc.root.?.attrs);
        for (attrs) |*attr| if (std.mem.eql(u8, attr.name, name)) {
            const cached = try arena.allocator().create(m.TypedAttrValue);
            cached.* = .{ .literal = "different cached value" };
            attr.typed = cached;
        };
        doc.root.?.attrs = attrs;
        _ = try compare(doc, .{}, unlimited, unlimited);
    }
}
