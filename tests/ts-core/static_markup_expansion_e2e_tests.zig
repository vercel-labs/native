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
var modes: [13]usize = @splat(0);
var phases: [4]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 110) {
        modes[input[2]] += 1;
        if (input[2] == 7) {
            const phase: f64 = @bitCast(std.mem.readInt(u64, input[4..12], .little));
            phases[@intFromFloat(phase)] += 1;
        }
    }
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
fn event(value: u64) void {
    calls[call_count] = value;
    call_count += 1;
}
const Row = struct {
    id: i64,
    title: []const u8,
    visible: bool,
    pub fn identity(self: *const Row) i64 {
        event(if (self.visible) 20 else 21);
        return self.id;
    }
};
const data = [_]Row{
    .{ .id = -9007199254740993, .title = "Borrowed\x00\xff", .visible = true },
    .{ .id = 9007199254740993, .title = "Second", .visible = false },
};
const Model = struct {
    condition: i64 = 1,
    empty: bool = false,
    reversed: bool = false,
    pub fn predicate(self: *const Model) i64 {
        event(1);
        return self.condition;
    }
    pub fn alternative(_: *const Model) bool {
        event(2);
        return true;
    }
    pub fn rows(self: *const Model) []const Row {
        event(3);
        return data[0..if (self.empty) 0 else data.len];
    }
    pub fn others(_: *const Model) []const Row {
        event(4);
        return &.{};
    }
    pub fn label(_: *const Model) []const u8 {
        event(5);
        return "Model";
    }
    pub fn text(_: *const Model) []const u8 {
        event(6);
        return data[0].title;
    }
};
const Msg = union(enum) { tick, selected: i64 };
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
    errdefer std.debug.print("static expansion source={s} failure={d} resize={d}\n", .{ source, failure, resize });
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
test "static markup expansion preserves lazy branches exact truthiness and nested alternatives" {
    _ = core.initialModel();
    modes = @splat(0);
    const source = "<column><if test=\"{predicate}\"><text>{text}</text></if><else><if test=\"{alternative}\"><button on-press=\"tick\">Other</button></if></else><text>Tail</text></column>";
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, -1, 0, 1, 9007199254740993, std.math.maxInt(i64) }) |condition| try check(source, .{ .condition = condition }, true);
    try std.testing.expect(modes[3] > 0);
}
test "static markup expansion preserves empty loop alternatives and post-body exact key inheritance" {
    _ = core.initialModel();
    phases = @splat(0);
    const source = "<column><for each=\"rows\" as=\"r\" key=\"identity\"><if test=\"{r.visible}\"><button on-press=\"selected:{r.id}\">{r.title}</button><text>Inherited</text></if><else><text key=\"local\">Own</text><text global-key=\"global\">Global</text><text>Slot</text></else></for><else><text>{label}</text></else><text>Tail</text></column>";
    try check(source, .{}, true);
    try check(source, .{ .empty = true }, true);
    for ([_]usize{ 1, 2, 3 }) |phase| try std.testing.expect(phases[phase] > 0);
}
test "static markup expansion evaluates item keys after bodies even when no node is emitted" {
    _ = core.initialModel();
    const source = "<column><for each=\"rows\" as=\"r\" key=\"identity\"><if test=\"{predicate}\"><text>{r.title}</text></if></for></column>";
    try check(source, .{ .condition = 0 }, true);
    _ = try compare(source, .{ .condition = 0 }, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 3, 1, 20, 1, 21 }), calls[0..call_count]);
}
test "static markup expansion preserves unkeyed item order and continuation after builder failures" {
    _ = core.initialModel();
    const source = "<column><for each=\"rows\" as=\"r\"><text>{text}</text><button on-press=\"selected:{r.id}\">{r.title}</button></for><else><text>Empty</text></else><text>{label}</text></column>";
    try check(source, .{}, true);
    try check(source, .{ .empty = true }, true);
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 3, 6, 6, 5 }), calls[0..call_count]);
}
const templates = "<template name=\"leaf\" args=\"title id\"><row><button on-press=\"selected:{id}\">{title}</button><slot/></row></template>" ++
    "<template name=\"group\" args=\"rows label=Default\"><column><text>{label}</text><for each=\"rows\" as=\"r\" key=\"identity\"><use template=\"leaf\" title=\"{r.title}\" id=\"{r.id}\"><if test=\"{r.visible}\"><text>{label}</text></if><else><text>Hidden</text></else></use></for><else><text>Group empty</text></else><slot/></column></template>";
test "static markup expansion preserves nested template slice shadowing defaults and consumer slots" {
    _ = core.initialModel();
    const source = templates ++ "<column><for each=\"rows\" as=\"outer\" key=\"identity\"><use template=\"group\" rows=\"{rows}\" label=\"{outer.title}\"><button on-press=\"selected:{outer.id}\">{outer.title}</button></use></for><else><use template=\"group\" rows=\"{others}\"/></else></column>";
    try check(source, .{}, true);
    try check(source, .{ .empty = true }, true);
}
test "static markup expansion preserves nested empty iterables and conditionals without alternatives" {
    _ = core.initialModel();
    const source = "<column><for each=\"rows\" as=\"r\" key=\"identity\"><if test=\"{predicate}\"><for each=\"others\" as=\"inner\"><text>{inner.title}</text></for><else><text>{r.title}</text></else></if></for><if test=\"{predicate}\"><text>{text}</text></if></column>";
    for ([_]i64{ 0, 1 }) |condition| try check(source, .{ .condition = condition }, true);
}
