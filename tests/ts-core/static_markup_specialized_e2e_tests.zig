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

var calls: [4096]u64 = undefined;
var call_count: usize = 0;
var modes: [256]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) modes[input[2]] += 1;
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
fn event(value: u64) void {
    calls[call_count] = value;
    call_count += 1;
}
const Model = struct {
    lines: []const u8 = "2-3,1,2",
    removed: []const u8 = "3",
    prefix: []const u8 = "https://example.invalid/issues/",
    chosen: i64 = -9007199254740993,
    pub fn code(_: *const Model) []const u8 {
        event(1);
        return "const x = 1;\nreturn x;\n// Done";
    }
    pub fn added(self: *const Model) []const u8 {
        event(2);
        return self.lines;
    }
    pub fn deleted(self: *const Model) []const u8 {
        event(3);
        return self.removed;
    }
    pub fn body(_: *const Model) []const u8 {
        event(4);
        return "# Document\nIssue #12\n<details><summary>More</summary>Body</details>";
    }
    pub fn base(self: *const Model) []const u8 {
        event(5);
        return self.prefix;
    }
    pub fn title(_: *const Model) []const u8 {
        event(6);
        return "Borrowed title";
    }
};
const Msg = union(enum) { tick, local, selected: i64, link: []const u8, details: usize };
const Ui = c.Ui(Msg);
const unlimited = std.math.maxInt(usize);
const Outcome = struct { allocations: usize, resizes: usize, calls: usize };
fn aliases(a: Ui.Node, b: Ui.Node) anyerror!void {
    if (a.on_press) |message| if (message == .selected) try std.testing.expectEqual(message.selected, b.on_press.?.selected);
    for (a.nodes, b.nodes) |left, right| try aliases(left, right);
}
fn compare(comptime source: []const u8, model: Model, failure: usize, resize: usize) !Outcome {
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
    call_count = 0;
    const a = View.build(&left, &model);
    const before = calls;
    const count = call_count;
    call_count = 0;
    const b = View.build(&right, &model);
    errdefer std.debug.print("static specialized source={s} failure={d} resize={d}\n", .{ source, failure, resize });
    try exact(before[0..count], calls[0..call_count]);
    try exact(a, b);
    try aliases(a, b);
    const at = left.finalize(a);
    const bt = right.finalize(b);
    if (at) |tree| try exact(tree, try bt) else |err| try std.testing.expectError(err, bt);
    try exact(left.failed, right.failed);
    try exact(left.virtualWindows(), right.virtualWindows());
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    return .{ .allocations = fa.alloc_index, .resizes = fa.resize_index, .calls = count };
}
fn check(comptime source: []const u8, model: Model, faults: bool) !void {
    const result = try compare(source, model, unlimited, unlimited);
    if (faults) {
        for (0..result.allocations + 1) |index| _ = try compare(source, model, index, unlimited);
        for (0..result.resizes + 1) |index| _ = try compare(source, model, unlimited, index);
    }
}
test "static markup specialized code retains all line grammar boundaries and complete failure effects" {
    _ = core.initialModel();
    modes = @splat(0);
    const source = "<column><code source=\"{code}\" added-lines=\"{added}\" removed-lines=\"{deleted}\" language=\"zig\" label=\"Source\"/><text>{title}</text></column>";
    for ([_][]const u8{ "", " \t\r\n", "1", "128", "1-128", "128,1,128,2-4", "+1 - 0__2,2", "1_2", "1,", ",1", "1,,2", "0", "129", "2-1", "-1", "1-2-3", "1-", "1 - \n2", "18446744073709551616", "1,2,x", "1,2,3-0", "\xff", "1\x00" }) |lines| {
        try check(source, .{ .lines = lines }, false);
        try check(source, .{ .removed = lines }, false);
    }
    try check(source, .{}, true);
    try check(source, .{ .lines = "1,2,x", .removed = "3-1" }, true);
    try std.testing.expect(modes[17] > 0 and modes[18] > 0);
}
test "static markup specialized literal and template code preserve callback order after invalid metadata" {
    _ = core.initialModel();
    const source = "<template name=\"code-card\" args=\"lines removed\"><code source=\"{code}\" added-lines=\"{lines}\" removed-lines=\"{removed}\"/></template><column><use template=\"code-card\" lines=\"{added}\" removed=\"{deleted}\"/><code source=\"{code}\" added-lines=\"1-3,1\" removed-lines=\"2\"/></column>";
    try check(source, .{}, true);
    try check(source, .{ .lines = "0" }, true);
}
test "static markup specialized markdown preserves nonempty issue bases and borrowed callbacks" {
    _ = core.initialModel();
    modes = @splat(0);
    const source = "<column><markdown source=\"{body}\" issue-link-base=\"{base}\" on-link=\"link\" on-details=\"details\"/><text>{title}</text></column>";
    for ([_][]const u8{ "", " ", "https://example.invalid/issues/", "ghissue://", "\x00\xff" }) |prefix| try check(source, .{ .prefix = prefix }, true);
    try std.testing.expect(modes[28] > 0);
}
test "static markup specialized markdown template captures retain source and issue callback order" {
    _ = core.initialModel();
    const source = "<template name=\"document\" args=\"base\"><markdown source=\"{body}\" issue-link-base=\"{base}\" on-link=\"link\"/></template><column><use template=\"document\" base=\"{base}\"/><markdown source=\"{body}\" issue-link-base=\"https://example.invalid/\"/></column>";
    try check(source, .{}, true);
    try check(source, .{ .prefix = "" }, true);
}
test "static markup specialized root press publication preserves timeline affordances and exact payloads" {
    _ = core.initialModel();
    modes = @splat(0);
    const source = "<template name=\"item\"><timeline-item title=\"{title}\" on-press=\"local\"/></template><template name=\"button-card\"><button on-press=\"local\">{title}</button></template><column><timeline><use template=\"item\" on-press=\"selected:{chosen}\"/><use template=\"item\"/><timeline-item title=\"{title}\"/></timeline><use template=\"button-card\" on-press=\"selected:{chosen}\"/><use template=\"button-card\"/></column>";
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, 0, 9007199254740993, std.math.maxInt(i64) }) |chosen| try check(source, .{ .chosen = chosen }, true);
    try std.testing.expect(modes[33] > 0 and modes[36] > 0);
}
test "static markup specialized tab conversion preserves toggle contracts nested children and handlers" {
    _ = core.initialModel();
    modes = @splat(0);
    const source = "<template name=\"trigger\"><button on-press=\"local\">{title}</button></template><column><tabs><button on-press=\"tick\">First</button><toggle-button on-toggle=\"tick\">Toggle</toggle-button><text>Caption</text><use template=\"trigger\" on-press=\"selected:{chosen}\"/><column><button on-press=\"local\">Nested</button></column></tabs><tabs/></column>";
    try check(source, .{}, true);
    try std.testing.expect(modes[34] > 0);
}
