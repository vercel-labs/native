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
const Row = struct { label: []const u8 };
const Model = struct {
    number: f64 = 12.5,
    integer: i64 = 3,
    identity: i64 = 9007199254740993,
    truth: bool = true,
    raw: []const u8 = "Borrowed Café",
    option: []const u8 = "primary",
    levels: []const f32 = &.{ 1.25, -2.5, 0.0 },
    doubles: []const f64 = &.{ 0.125, 3.141592653589793, -1.0 },
    categories: []const []const u8 = &.{ "One", "Two", "Three" },
    rows: []const Row = &.{ .{ .label = "Outer" }, .{ .label = "Inner" } },
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
    pub fn gap(self: *const Model) f64 {
        event(8);
        return self.number;
    }
    pub fn title(self: *const Model) []const u8 {
        event(9);
        return self.raw;
    }
    pub fn description(self: *const Model) []const u8 {
        event(10);
        return self.raw;
    }
    pub fn meta(self: *const Model) []const u8 {
        event(11);
        return self.raw;
    }
    pub fn indicator(self: *const Model) []const u8 {
        event(12);
        return self.raw;
    }
    pub fn icon(_: *const Model) []const u8 {
        event(13);
        return "check";
    }
    pub fn variant(self: *const Model) []const u8 {
        event(14);
        return self.option;
    }
    pub fn connector(self: *const Model) bool {
        event(15);
        return self.truth;
    }
    pub fn selected(self: *const Model) bool {
        event(16);
        return self.truth;
    }
    pub fn payload(self: *const Model) i64 {
        event(17);
        return self.identity;
    }
    pub fn ymin(self: *const Model) f64 {
        event(18);
        return self.number;
    }
    pub fn ymax(self: *const Model) f64 {
        event(19);
        return self.number;
    }
    pub fn grid(self: *const Model) i64 {
        event(20);
        return self.integer;
    }
    pub fn baseline(self: *const Model) bool {
        event(21);
        return self.truth;
    }
    pub fn labels(self: *const Model) []const []const u8 {
        event(22);
        return self.categories;
    }
    pub fn ylabels(self: *const Model) bool {
        event(23);
        return self.truth;
    }
    pub fn hover(self: *const Model) bool {
        event(24);
        return self.truth;
    }
    pub fn stroke(self: *const Model) f64 {
        event(25);
        return self.number;
    }
    pub fn padding(self: *const Model) f64 {
        event(26);
        return self.number;
    }
    pub fn samples(self: *const Model) []const f32 {
        event(27);
        return self.levels;
    }
    pub fn wideSamples(self: *const Model) []const f64 {
        event(28);
        return self.doubles;
    }
    pub fn src(self: *const Model) []const u8 {
        event(29);
        return self.raw;
    }
    pub fn controls(self: *const Model) bool {
        event(30);
        return self.truth;
    }
    pub fn autoplay(self: *const Model) bool {
        event(31);
        return self.truth;
    }
    pub fn looped(self: *const Model) bool {
        event(32);
        return self.truth;
    }
    pub fn muted(self: *const Model) bool {
        event(33);
        return self.truth;
    }
    pub fn poison(self: *const Model) []const u8 {
        event(99);
        return self.raw;
    }
};
const Msg = union(enum) { tick, local, chosen: i64, edited: c.TextInputEvent };
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
    errdefer std.debug.print("static builders source={s} failure={d} resize={d}\n", .{ source, failure, resize });
    try exact(before[0..count], calls[0..call_count]);
    try exact(a, b);
    const at = left.finalize(a);
    const bt = right.finalize(b);
    if (at) |tree| try exact(tree, try bt) else |err| try std.testing.expectError(err, bt);
    try exact(left.failed, right.failed);
    try exact(left.virtualWindows(), right.virtualWindows());
    try exact(left.video_declaration, right.video_declaration);
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

test "static markup builders fix input group channels before textarea and optional actions" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<input-group global-key=\"{global}\" key=\"{key}\" grow=\"{grow}\" min-width=\"{minimum}\" height=\"{height}\" width=\"{width}\" label=\"{label}\" label=\"{poison}\"><textarea label=\"Draft\" text=\"{title}\" on-input=\"edited\"/><input-group-actions global-key=\"{global}\" key=\"{key}\" gap=\"{gap}\"><button on-press=\"chosen:{payload}\">{description}</button></input-group-actions></input-group>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 1, 2, 3, 4, 5, 6, 7, 9, 8, 6, 7, 17, 10 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .truth = false, .raw = "", .identity = std.math.minInt(i64) }, true);
    try std.testing.expect(specialized[22] > 0 and specialized[23] > 0);
    try check("<input-group><textarea label=\"Draft\" text=\"{title}\"/></input-group>", .{}, true);
    try check("<input-group><textarea label=\"Draft\"/><input-group-actions/></input-group>", .{}, true);
}

test "static markup builders preserve timeline channel order empty children and nested expansion" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<timeline label=\"{label}\" global-key=\"{global}\" key=\"{key}\" grow=\"{grow}\" gap=\"{gap}\" gap=\"0\"><timeline-item global-key=\"{global}\" key=\"{key}\" on-press=\"chosen:{payload}\" selected=\"{selected}\" connector=\"{connector}\" variant=\"{variant}\" icon=\"{icon}\" indicator=\"{indicator}\" meta=\"{meta}\" description=\"{description}\" title=\"{title}\" title=\"{poison}\"/></timeline>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 8, 5, 6, 7, 1, 9, 10, 11, 12, 13, 14, 15, 16, 17, 6, 7 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .truth = false, .raw = "\x00\xff", .identity = std.math.maxInt(i64) }, true);
    try std.testing.expect(specialized[24] > 0 and specialized[25] > 0);
    try check("<timeline/>", .{}, true);
    try check("<timeline><column><timeline-item title=\"{title}\"/></column></timeline>", .{}, true);
}

test "static markup builders retain invalid variant effects and exact forwarded handler payloads" {
    _ = core.initialModel();
    const source = "<template name=\"item\"><timeline-item key=\"{key}\" on-press=\"local\" selected=\"{selected}\" variant=\"{variant}\" title=\"{title}\"/></template><column><timeline><use template=\"item\" on-press=\"chosen:{payload}\"/><use template=\"item\"/><timeline-item title=\"{title}\"/></timeline><text>{description}</text></column>";
    for ([_][]const u8{ "primary", "secondary", "ghost", "", "Primary", "invalid", "\x00\xff" }) |option| try check(source, .{ .option = option }, true);
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, 0, 9007199254740993, std.math.maxInt(i64) }) |identity| try check(source, .{ .identity = identity }, true);
}

test "static markup builders allocate chart series before fixed per-series channels" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<chart label=\"{label}\" global-key=\"{global}\" key=\"{key}\" padding=\"{padding}\" grow=\"{grow}\" height=\"{height}\" width=\"{width}\" stroke-width=\"{stroke}\" hover-details=\"{hover}\" y-labels=\"{ylabels}\" x-labels=\"{labels}\" baseline=\"{baseline}\" grid-lines=\"{grid}\" y-max=\"{ymax}\" y-min=\"{ymin}\" y-min=\"0\"><series label=\"{title}\" color=\"accent\" values=\"{samples}\" kind=\"area\" values=\"{wideSamples}\"/><series label=\"{description}\" values=\"{wideSamples}\" kind=\"bar\"/><series values=\"{samples}\"/></chart>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 18, 19, 20, 21, 22, 23, 24, 25, 2, 3, 5, 26, 6, 7, 1, 27, 9, 28, 10, 27 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .levels = &.{}, .doubles = &.{}, .categories = &.{}, .raw = "", .truth = false }, true);
    try std.testing.expect(specialized[26] > 0 and specialized[27] > 0);
}

test "static markup builders keep invalid grid conversion and later series callbacks" {
    _ = core.initialModel();
    const source = "<column><chart label=\"{label}\" grid-lines=\"{grid}\"><series label=\"{title}\" values=\"{samples}\"/></chart><text>{description}</text></column>";
    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, 255, 256, 9007199254740993, std.math.maxInt(i64) }) |integer| try check(source, .{ .integer = integer }, true);
}

test "static markup builders preserve exact f32 chart inputs and f64 narrowing" {
    _ = core.initialModel();
    const source = "<chart><series values=\"{samples}\"/><series values=\"{wideSamples}\"/></chart>";
    for ([_]u32{ 0, 0x80000000, 1, 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff, 0x80000001, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fffffff, 0xffc00000 }) |bits| {
        const samples = [_]f32{ @bitCast(bits), 1.25 };
        const wide = [_]f64{ @as(f64, @floatCast(samples[0])), 3.141592653589793 };
        try check(source, .{ .levels = &samples, .doubles = &wide }, false);
    }
    try check(source, .{ .levels = &.{ -0.0, std.math.inf(f32), std.math.nan(f32) }, .doubles = &.{ -0.0, std.math.inf(f64), std.math.nan(f64) } }, true);
}

test "static markup builders publish video flags and declarations in fixed order" {
    _ = core.initialModel();
    specialized = @splat(0);
    const source = "<video global-key=\"{global}\" key=\"{key}\" label=\"{label}\" grow=\"{grow}\" height=\"{height}\" width=\"{width}\" muted=\"{muted}\" loop=\"{looped}\" autoplay=\"{autoplay}\" controls=\"{controls}\" src=\"{src}\" src=\"{poison}\"/>";
    _ = try compare(source, .{}, unlimited, unlimited);
    try exact(@as([]const u64, &.{ 29, 30, 31, 32, 33, 2, 3, 5, 1, 6, 7 }), calls[0..call_count]);
    try check(source, .{}, true);
    try check(source, .{ .raw = "\x00\xff", .truth = false }, true);
    try check("<video controls autoplay loop muted src=\"clip.mp4\"/>", .{}, true);
    try check("<column><video src=\"first.mp4\"/><video src=\"{src}\" controls=\"false\" autoplay=\"true\" loop=\"false\" muted=\"true\"/><video/></column>", .{}, true);
    try std.testing.expect(specialized[28] > 0);
}

test "static markup builders retain template slots loop shadows and empty expansions" {
    _ = core.initialModel();
    const source = "<template name=\"item\" args=\"value\"><timeline-item description=\"{description}\" title=\"{value}\"/></template><template name=\"wrapper\" args=\"value\"><timeline><use template=\"item\" value=\"{value}\"/><slot/></timeline></template><column><for each=\"rows\" as=\"row\"><use template=\"wrapper\" value=\"{row.label}\"><use template=\"item\" value=\"{row.label}\"/></use></for></column>";
    try check(source, .{}, true);
    try check(source, .{ .rows = &.{} }, true);
    try check(source, .{ .rows = &.{.{ .label = "\x00\xff" }}, .raw = "" }, true);
}

test "static markup builders preserve borrowed text and owned video source storage" {
    _ = core.initialModel();
    const source = "<column><timeline-item title=\"{title}\" description=\"{description}\"/><chart x-labels=\"{labels}\"><series values=\"{samples}\" label=\"{title}\"/></chart><video src=\"{src}\"/></column>";
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
    try std.testing.expect(a.nodes[0].widget.semantics.label.ptr == model.raw.ptr);
    try std.testing.expect(b.nodes[0].widget.semantics.label.ptr == model.raw.ptr);
    try std.testing.expect(a.nodes[1].widget.chart.series[0].label.ptr == model.raw.ptr);
    try std.testing.expect(b.nodes[1].widget.chart.series[0].label.ptr == model.raw.ptr);
    try exact(left.video_declaration, right.video_declaration);
    try std.testing.expect(left.video_declaration.?.src.ptr != model.raw.ptr);
    try std.testing.expect(right.video_declaration.?.src.ptr != model.raw.ptr);
    try check(source, .{}, true);
}
