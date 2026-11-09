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
/// Counts text slices that alias the model's storage, so borrowed and owned
/// buffers stay distinguishable even when their bytes are equal.
fn borrowed(value: anytype, base: []const u8) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var total: usize = 0;
            inline for (info.fields) |field| total += borrowed(@field(value, field.name), base);
            break :blk total;
        },
        .optional => if (value) |inner| borrowed(inner, base) else 0,
        .@"union" => switch (value) {
            inline else => |inner| borrowed(inner, base),
        },
        .pointer => |info| if (info.size != .slice) 0 else if (info.child == u8) @intFromBool(value.len > 0 and @intFromPtr(value.ptr) >= @intFromPtr(base.ptr) and @intFromPtr(value.ptr) < @intFromPtr(base.ptr) + base.len) else blk: {
            var total: usize = 0;
            for (value) |item| total += borrowed(item, base);
            break :blk total;
        },
        .array => blk: {
            var total: usize = 0;
            for (value) |item| total += borrowed(item, base);
            break :blk total;
        },
        else => 0,
    };
}

var calls: [4096]u64 = undefined;
var call_count: usize = 0;
var specialized: [256]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 112) specialized[input[2]] += 1;
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
fn event(value: u64) void {
    calls[call_count] = value;
    call_count += 1;
}
const storage = "Borrowed Café|# Document\nIssue #12 and [docs](https://example.invalid/docs)\n<details><summary>More</summary>Body</details>\n<details><summary>Less</summary>Tail</details>|const x = 1;\nreturn x;\n// Done|https://example.invalid/issues/|2-3,1|4|Outer|Inner|\x00\xff";
fn part(comptime index: usize) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        var parts = std.mem.splitScalar(u8, storage, '|');
        for (0..index) |_| _ = parts.next();
        break :blk parts.next().?;
    };
}
const Image = struct { source: []const u8, image: u64, width: f32, height: f32 };
const Row = struct { label: []const u8 };
const Model = struct {
    raw: []const u8 = part(0),
    document: []const u8 = part(1),
    program: []const u8 = part(2),
    prefix: []const u8 = part(3),
    lines: []const u8 = part(4),
    removed: []const u8 = part(5),
    number: f64 = 12.5,
    identity: i64 = 9007199254740993,
    step: i64 = 1,
    truth: bool = true,
    flags: []const bool = &.{ false, true },
    pictures: []const Image = &.{.{ .source = part(1)[0..10], .image = 4294967297, .width = 10.25, .height = 20.5 }},
    rows: []const Row = &.{ .{ .label = part(6) }, .{ .label = part(7) } },
    pub fn label(self: *const Model) []const u8 {
        event(1);
        return self.raw;
    }
    pub fn width(self: *const Model) f64 {
        event(2);
        return self.number;
    }
    pub fn height(self: *const Model) f64 {
        event(3);
        return self.number;
    }
    pub fn minimum(self: *const Model) f64 {
        event(4);
        return self.number;
    }
    pub fn grow(self: *const Model) f64 {
        event(5);
        return self.number;
    }
    pub fn key(self: *const Model) i64 {
        event(6);
        return self.identity;
    }
    pub fn global(self: *const Model) i64 {
        event(7);
        return self.identity;
    }
    pub fn body(self: *const Model) []const u8 {
        event(8);
        return self.document;
    }
    pub fn expanded(self: *const Model) []const bool {
        event(9);
        return self.flags;
    }
    pub fn images(self: *const Model) []const Image {
        event(10);
        return self.pictures;
    }
    pub fn base(self: *const Model) []const u8 {
        event(11);
        return self.prefix;
    }
    pub fn code(self: *const Model) []const u8 {
        event(12);
        return self.program;
    }
    pub fn numbers(self: *const Model) bool {
        event(13);
        return self.truth;
    }
    pub fn added(self: *const Model) []const u8 {
        event(14);
        return self.lines;
    }
    pub fn deleted(self: *const Model) []const u8 {
        event(15);
        return self.removed;
    }
    pub fn editable(self: *const Model) bool {
        event(16);
        return self.truth;
    }
    pub fn wrap(self: *const Model) bool {
        event(17);
        return !self.truth;
    }
    pub fn active(self: *const Model) i64 {
        event(18);
        return self.step;
    }
    pub fn title(self: *const Model) []const u8 {
        event(19);
        return self.raw;
    }
    pub fn poison(self: *const Model) []const u8 {
        event(99);
        return self.raw;
    }
};
const Msg = union(enum) { tick, link: []const u8, details: usize, edited: c.TextInputEvent };
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
    errdefer std.debug.print("static content builders source={s} failure={d} resize={d}\n", .{ source, failure, resize });
    try exact(before[0..count], calls[0..call_count]);
    try exact(a, b);
    try exact(borrowed(a, storage), borrowed(b, storage));
    const at = left.finalize(a);
    const bt = right.finalize(b);
    if (at) |tree| {
        const tree_b = try bt;
        try exact(tree, tree_b);
        try exact(borrowed(tree, storage), borrowed(tree_b, storage));
    } else |err| try std.testing.expectError(err, bt);
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

test "static markup content builders bind markdown source before fixed first-occurrence channels" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<markdown issue-link-base=\"{base}\" images=\"{images}\" details-expanded=\"{expanded}\" on-details=\"details\" on-link=\"link\" source=\"{body}\" source=\"{poison}\" issue-link-base=\"{poison}\" images=\"{poison}\"/>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 8, 9, 10, 11 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .prefix = "", .flags = &.{}, .pictures = &.{} }, true);
    try check(source, .{ .document = "", .prefix = part(8) }, true);
    try std.testing.expect(specialized[29] > 0);
    try check("<markdown kind=\"document\" source=\"{body}\"/>", .{}, true);
    try check("<column><markdown source=\"{body}\" images=\"{images}\"/><markdown source=\"{body}\" issue-link-base=\"https://example.invalid/\"/><text>{title}</text></column>", .{}, true);
}

test "static markup content builders keep markdown template captures and later callbacks" {
    _ = core.initialModel();
    const source = "<template name=\"document\" args=\"base\"><markdown source=\"{body}\" issue-link-base=\"{base}\" details-expanded=\"{expanded}\" on-link=\"link\"/></template><column><use template=\"document\" base=\"{base}\"/><use template=\"document\" base=\"\"/><for each=\"rows\" as=\"row\"><markdown source=\"{row.label}\" issue-link-base=\"{row.label}\"/></for><text>{title}</text></column>";
    for ([_][]const u8{ "", " ", "https://example.invalid/issues/", "\x00\xff" }) |prefix| try check(source, .{ .prefix = prefix }, true);
    try check(source, .{ .rows = &.{} }, true);
}

test "static markup content builders fix code channels and keep stack line storage through publication" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<code global-key=\"{global}\" key=\"{key}\" label=\"{label}\" grow=\"{grow}\" min-width=\"{minimum}\" height=\"{height}\" width=\"{width}\" wrap=\"{wrap}\" on-input=\"edited\" editable=\"{editable}\" removed-lines=\"{deleted}\" added-lines=\"{added}\" line-numbers=\"{numbers}\" language=\"zig\" source=\"{code}\" source=\"{poison}\" added-lines=\"{poison}\" label=\"{poison}\"/>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 12, 13, 14, 15, 16, 17, 2, 3, 4, 5, 1, 6, 7 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .truth = false, .raw = "", .identity = std.math.minInt(i64) }, true);
    try check(source, .{ .program = "", .lines = "", .removed = "" }, true);
    try std.testing.expect(specialized[30] > 0);
    try check("<code source=\"{code}\"/>", .{}, true);
    try check("<code source=\"{code}\" language=\"zig\" line-numbers added-lines=\"1-3,1\" removed-lines=\"2\" editable wrap/>", .{}, true);
}

test "static markup content builders continue code callbacks after invalid line metadata" {
    _ = core.initialModel();
    const source = "<column><code label=\"{label}\" removed-lines=\"{deleted}\" added-lines=\"{added}\" source=\"{code}\" key=\"{key}\"/><text>{title}</text></column>";
    for ([_][]const u8{ "", "1", "128", "1-128", "0", "129", "2-1", "1,,2", "1,2,x", "18446744073709551616", "\xff" }) |lines| {
        try check(source, .{ .lines = lines }, true);
        try check(source, .{ .removed = lines }, false);
    }
    try check(source, .{ .lines = "2", .removed = "2" }, true);
    const template = "<template name=\"code-card\" args=\"lines\"><code source=\"{code}\" added-lines=\"{lines}\" removed-lines=\"{deleted}\"/></template><column><use template=\"code-card\" lines=\"{added}\"/><use template=\"code-card\" lines=\"x\"/><use template=\"code-card\" lines=\"1-2\"/><text>{title}</text></column>";
    try check(template, .{}, true);
    try check(template, .{ .removed = "x" }, true);
}

test "static markup content builders evaluate stepper active and channels before allocating steps" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<stepper label=\"{label}\" global-key=\"{global}\" key=\"{key}\" active=\"{active}\" active=\"{poison}\" label=\"{poison}\"><step>{title}</step><step>Step {title}</step><step kind=\"step\">Fixed</step></stepper>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 18, 6, 7, 1, 19, 19 }), calls[0..call_count]);
    try check(source, .{}, true);
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, -1, 0, 2, 3, 9007199254740993, std.math.maxInt(i64) }) |step| try check(source, .{ .step = step }, true);
    try check(source, .{ .raw = "", .identity = std.math.maxInt(i64) }, true);
    try std.testing.expect(specialized[31] > 0);
    try check("<stepper active=\"{active}\"/>", .{}, true);
    try check("<column><stepper active=\"0\"><step>Only</step></stepper><text>{title}</text></column>", .{}, true);
}

test "static markup content builders interpolate slot steps in their lexical site scope" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<template name=\"steps\" args=\"row\"><stepper active=\"{active}\" label=\"{row}\" key=\"{row}\"><slot/></stepper></template><column><for each=\"rows\" as=\"row\"><use template=\"steps\" row=\"{title}\"><step>{row.label}</step><step>Then {row.label} {title}</step></use></for><use template=\"steps\" row=\"Empty\"/><text>{title}</text></column>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 19, 18, 19, 19, 18, 19, 18, 19 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .rows = &.{} }, true);
    try check(source, .{ .rows = &.{.{ .label = part(8) }}, .raw = "", .step = -1 }, true);
    try std.testing.expect(specialized[31] > 0);
}

test "static markup content builders preserve borrowed sources labels and owned interpolation" {
    _ = core.initialModel();
    const source = "<column><code source=\"{code}\" label=\"{label}\"/><markdown source=\"{body}\" issue-link-base=\"{base}\"/><stepper active=\"{active}\" label=\"{label}\"><step>{title}</step><step>Step {title}</step></stepper></column>";
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
    try std.testing.expect(borrowed(a, storage) > 0);
    try exact(borrowed(a, storage), borrowed(b, storage));
    try std.testing.expect(a.nodes[2].widget.semantics.label.ptr == model.raw.ptr);
    try std.testing.expect(b.nodes[2].widget.semantics.label.ptr == model.raw.ptr);
    try check(source, .{}, true);
}
