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
var specialized: [256]usize = @splat(0);
var values: [256]usize = @splat(0);
var runtime: [256]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 112) specialized[input[2]] += 1;
    if (input[0] == 113) values[input[2]] += 1;
    if (input[0] == 114) runtime[input[2]] += 1;
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
fn event(value: u64) void {
    calls[call_count] = value;
    call_count += 1;
}
const Row = struct { label: []const u8 };
const Model = struct {
    multiplier: f32 = 1.25,
    scale_integer: i64 = 2,
    weight_name: []const u8 = "bold",
    integer: i64 = 42,
    truth: bool = true,
    text: []const u8 = "Café",
    rows: []const Row = &.{ .{ .label = "Outer" }, .{ .label = "Inner" } },
    pub fn weight(self: *const Model) []const u8 {
        event(1);
        return self.weight_name;
    }
    pub fn size(self: *const Model) f32 {
        event(2);
        return self.multiplier;
    }
    pub fn mono(self: *const Model) i64 {
        event(3);
        return self.integer;
    }
    pub fn italic(self: *const Model) ?[]const u8 {
        event(4);
        return if (self.truth) self.text else null;
    }
    pub fn under(self: *const Model) bool {
        event(5);
        return self.truth;
    }
    pub fn chunk(self: *const Model) []const u8 {
        event(6);
        return self.text;
    }
    pub fn amount(self: *const Model) i64 {
        event(7);
        return self.integer;
    }
    pub fn integerSize(self: *const Model) i64 {
        event(2);
        return self.scale_integer;
    }
};
const Msg = union(enum) { tick, reset };
const Ui = c.Ui(Msg);
const unlimited = std.math.maxInt(usize);
const Outcome = struct { allocations: usize, resizes: usize, calls: usize };
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
    errdefer std.debug.print("static typography source={s} failure={d} resize={d}\n", .{ source, failure, resize });
    try exact(before[0..count], calls[0..call_count]);
    try exact(a, b);
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

test "static markup typography fixes channel order independently of attribute order" {
    _ = core.initialModel();
    specialized = @splat(0);
    values = @splat(0);
    runtime = @splat(0);
    const source = "<text><span foreground=\"accent\" underline=\"{under}\" italic=\"{italic}\" mono=\"{mono}\" scale=\"{size}\" weight=\"{weight}\">{chunk}/{amount}</span></text>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 1, 2, 3, 4, 5, 6, 7 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .truth = false, .integer = 0, .text = "" }, true);
    try std.testing.expect(specialized[12] > 0 and specialized[21] > 0 and values[20] > 0 and runtime[6] > 0);
}

test "static markup typography preserves exact bound f32 scale admission and later callbacks" {
    _ = core.initialModel();
    const source = "<text><span underline=\"{under}\" scale=\"{size}\" weight=\"{weight}\">{chunk}/{amount}</span></text>";
    for ([_]u32{ 0, 0x80000000, 1, 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff, 0x80000001, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fffffff, 0xffc00000 }) |bits| {
        try check(source, .{ .multiplier = @bitCast(bits) }, false);
    }
    try check(source, .{ .multiplier = @bitCast(@as(u32, 1)) }, true);
    try check(source, .{ .multiplier = std.math.nan(f32) }, true);
    try check(source, .{ .multiplier = -0.0 }, true);
    const integers = "<text><span scale=\"{integerSize}\">{chunk}/{amount}</span></text>";
    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, 9007199254740993, std.math.maxInt(i64) }) |integer| try check(integers, .{ .scale_integer = integer }, true);
}

test "static markup typography preserves invalid enum partial effects and evaluation order" {
    _ = core.initialModel();
    const source = "<column><text>Before <span italic=\"{italic}\" weight=\"{weight}\" scale=\"{size}\">{chunk}</span> after {amount}</text><text>{chunk}</text></column>";
    for ([_][]const u8{ "regular", "medium", "bold", "", "Bold", "invalid", "\x00\xff" }) |weight| try check(source, .{ .weight_name = weight }, true);
}

test "static markup typography interpolates complete mixed scalar runs and empty append boundaries" {
    _ = core.initialModel();
    inline for ([_][]const u8{
        "<text>{chunk}</text>",
        "<text>{chunk}{chunk}{chunk}</text>",
        "<text>{amount}</text>",
        "<text>prefix {chunk} / {amount} suffix</text>",
        "<text>{truth} / {multiplier} / {amount + 2}</text>",
        "<text>{chunk} <span>{amount}</span>{chunk}</text>",
        "<text><span>{chunk}</span><span>{chunk}</span></text>",
        "<button on-press=\"tick\">{chunk} / {amount}</button>",
    }) |source| {
        try check(source, .{}, true);
        try check(source, .{ .truth = false, .integer = -12, .text = "" }, true);
    }
    const exact_integer = "<text><span>{amount}</span></text>";
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, 9007199254740993, std.math.maxInt(i64) }) |integer| try check(exact_integer, .{ .integer = integer }, true);
}

test "static markup typography keeps unformatted plain text borrowed" {
    _ = core.initialModel();
    const source = "<text>Borrowed UTF-8 Café</text>";
    const View = c.CompiledMarkupView(Model, Msg, source);
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var left = Ui.init(aa.allocator());
    var right = Ui.init(ab.allocator());
    right.expression_policy = observed;
    const model: Model = .{};
    const a = View.build(&left, &model);
    const b = View.build(&right, &model);
    try exact(a, b);
    try std.testing.expect(a.widget.text.ptr == b.widget.text.ptr);
    try check(source, .{}, true);
}

test "static markup typography retains nested template captures and loop lexical shadows" {
    _ = core.initialModel();
    const source = "<template name=\"run\" args=\"value\"><text>Before <span underline=\"{under}\" weight=\"{weight}\" scale=\"{size}\">{value}/{chunk}</span> after {amount}</text></template><template name=\"wrapper\" args=\"value\"><column><use template=\"run\" value=\"{value}\"/><slot/></column></template><column><for each=\"rows\" as=\"row\"><use template=\"wrapper\" value=\"{row.label}\"><use template=\"run\" value=\"{row.label}\"/></use></for></column>";
    try check(source, .{}, true);
    try check(source, .{ .rows = &.{}, .text = "" }, true);
    try check(source, .{ .rows = &.{.{ .label = "\x00\xff" }}, .truth = false }, true);
}

test "static markup typography leaves literal style admission at compile time" {
    _ = core.initialModel();
    values = @splat(0);
    const source = "<text>Plain <span weight=\"bold\" scale=\"1.5\" mono=\"true\" italic=\"false\" underline=\"true\" foreground=\"accent\">Literal</span> tail</text>";
    try check(source, .{}, true);
    try std.testing.expectEqual(@as(usize, 0), values[20]);
}

test "static markup typography preserves full wide paragraph construction before layout limits" {
    _ = core.initialModel();
    const source = comptime blk: {
        var text: []const u8 = "<text>";
        for (0..40) |_| text = text ++ "<span>{chunk}</span>";
        break :blk text ++ "</text>";
    };
    _ = try compare(source, .{}, unlimited, unlimited);
    try std.testing.expectEqual(@as(usize, 40), call_count);
    try check(source, .{}, true);
}
