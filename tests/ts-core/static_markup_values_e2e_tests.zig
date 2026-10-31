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

var operations: [256]usize = @splat(0);
var keys: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) operations[input[2]] += 1;
    if (input[0] == 111 and input[2] == 4) keys += 1;
    const count = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return count;
}
var calls: [64]u8 = undefined;
var call_count: usize = 0;
const Choice = enum { first, second };
const Model = struct {
    levels: []const f32 = &.{ 1, 2, 3 },
    integer: i64 = 42,
    number: f64 = -0.0,
    role: []const u8 = "group",
    option: []const u8 = "primary",
    weight: []const u8 = "bold",
    choice: []const u8 = "second",
    text: []const u8 = "Borrowed\x00\xff",
    optional: ?i64 = 1,
    optional_text: ?[]const u8 = "Borrowed",
    pub fn before(_: *const Model) f32 {
        calls[call_count] = 1;
        call_count += 1;
        return 12;
    }
    pub fn after(_: *const Model) f32 {
        calls[call_count] = 2;
        call_count += 1;
        return 18;
    }
};
const Msg = union(enum) { tick, small: i8, unsigned: u8, exact: i64, number: f64, choice: Choice, bytes: []const u8, yes: bool };
const Ui = c.Ui(Msg);
const unlimited = std.math.maxInt(usize);
const Outcome = struct { allocations: usize, resizes: usize, failed: bool };
fn sink(_: *anyopaque, _: u64, _: *const c.ui_provenance.NodeSource, _: []const c.ui_provenance.Key, _: bool) void {}
fn borrowed(a: Ui.Node, b: Ui.Node, model: Model) !void {
    if (a.on_press) |message| {
        if (message == .bytes) {
            try std.testing.expectEqual(@intFromPtr(model.text.ptr), @intFromPtr(message.bytes.ptr));
            try std.testing.expectEqual(@intFromPtr(message.bytes.ptr), @intFromPtr(b.on_press.?.bytes.ptr));
        }
    }
    for (a.nodes, b.nodes) |left, right| try borrowed(left, right, model);
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
    var context: u8 = 0;
    const provenance: c.ui_provenance.Sink = .{ .context = &context, .record_fn = sink };
    left.provenance_sink = provenance;
    right.provenance_sink = provenance;
    call_count = 0;
    const a = View.build(&left, &model);
    const before = calls;
    const count = call_count;
    call_count = 0;
    const b = View.build(&right, &model);
    errdefer std.debug.print("static values source={s} failure={d} resize={d}\n", .{ source, failure, resize });
    try exact(before[0..count], calls[0..call_count]);
    try exact(a, b);
    try borrowed(a, b, model);
    const at = left.finalize(a);
    const bt = right.finalize(b);
    if (at) |tree| try exact(tree, try bt) else |err| try std.testing.expectError(err, bt);
    try exact(left.failed, right.failed);
    try exact(left.video_declaration, right.video_declaration);
    try exact(left.virtualWindows(), right.virtualWindows());
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    return .{ .allocations = fa.alloc_index, .resizes = fa.resize_index, .failed = left.failed };
}
fn check(comptime source: []const u8, model: Model, failed: bool, failures: bool) !void {
    const result = try compare(source, model, unlimited, unlimited);
    try std.testing.expectEqual(failed, result.failed);
    if (failures) {
        for (0..result.allocations + 1) |index| _ = try compare(source, model, index, unlimited);
        for (0..result.resizes + 1) |index| _ = try compare(source, model, unlimited, index);
    }
}
const options = "<column role=\"{role}\" label=\"{text}\" gap=\"{before}\" padding=\"{after}\"><button variant=\"{option}\" tooltip-delay=\"{integer}\" on-press=\"tick\">Value</button><text><span weight=\"{weight}\">Span</span></text><timeline><timeline-item title=\"Item\" variant=\"{option}\"/></timeline><slider label=\"Value\" value=\"{number}\" width=\"{before}\"/></column>";
test "static markup values preserve dynamic options enums and complete failed builds" {
    _ = core.initialModel();
    operations = @splat(0);
    try check(options, .{}, false, true);
    try check(options, .{ .role = "unknown" }, true, true);
    try check(options, .{ .option = "Primary" }, true, false);
    try check(options, .{ .weight = "bold\x00" }, true, false);
    try check(options, .{ .integer = -1 }, true, false);
    try check(options, .{ .integer = 2147483648 }, true, false);
    try std.testing.expect(operations[4] > 0 and operations[15] > 0);
}
test "static markup values preserve exact signed payloads and range failure placeholders" {
    _ = core.initialModel();
    operations = @splat(0);
    const source = "<column><button on-press=\"exact:{integer}\">Exact</button><button on-press=\"small:{integer}\">Small</button><button on-press=\"unsigned:{integer}\">Unsigned</button><button on-press=\"number:{number}\">Number</button><button on-press=\"bytes:{text}\">Bytes</button><button on-press=\"yes:{integer}\">Boolean</button><button on-press=\"choice:{choice}\">Choice</button></column>";
    for ([_]i64{ -9223372036854775808, -9007199254740993, -129, -128, -1, 0, 1, 127, 128, 255, 256, 9007199254740993, 9223372036854775807 }) |integer| {
        try check(source, .{ .integer = integer }, integer < 0 or integer > 127, integer == 0 or integer == -128);
    }
    try check(source, .{ .choice = "unknown" }, true, true);
    try std.testing.expect(operations[5] > 0 and operations[15] > 0);
}
test "static markup values preserve optional values and enum zero placeholders" {
    _ = core.initialModel();
    const source = "<column><button tooltip-delay=\"{optional}\" on-press=\"small:{optional}\">Number</button><button label=\"{optional_text}\" on-press=\"choice:{optional_text}\">Enum</button></column>";
    try check(source, .{ .optional_text = "first" }, false, true);
    try check(source, .{ .optional = null, .optional_text = null }, true, true);
    try check(source, .{ .optional_text = "FIRST" }, true, false);
}
test "static markup values preserve omitted empty and exact integer key identities" {
    _ = core.initialModel();
    keys = 0;
    const source = "<template name=\"keyed\" args=\"token=\"><text key=\"{token}\">Default</text></template><column><use template=\"keyed\"/><text key=\"{text}\" global-key=\"{integer}\">Explicit</text></column>";
    for ([_]i64{ -9223372036854775808, -9007199254740993, 0, 9007199254740993, 9223372036854775807 }) |integer| {
        try check(source, .{ .integer = integer }, false, integer == 0);
        try check(source, .{ .integer = integer, .text = "" }, false, false);
    }
    try std.testing.expect(keys > 0);
}
test "static markup values preserve resource and PTY admission with full integer bytes" {
    _ = core.initialModel();
    operations = @splat(0);
    const source = "<column><avatar image=\"{integer}\">AV</avatar><media-surface surface=\"{integer}\" label=\"Surface\"/><terminal pty=\"{integer}\" label=\"Numeric\"/><terminal pty=\"{text}\" label=\"Named\"/><chart grid-lines=\"{integer}\"><series values=\"{levels}\"/></chart></column>";
    for ([_]i64{ -9223372036854775808, -1, 0, 1, 255, 256, 9223372036854775807 }) |integer| try check(source, .{ .integer = integer }, integer < 0 or integer > 255, integer == 0 or integer == -1);
    try std.testing.expect(operations[1] > 0 and operations[4] > 0);
}

test "static markup values publish successful exact payloads without numeric transport" {
    _ = core.initialModel();
    const source = "<column><button on-press=\"exact:{integer}\">Exact</button><text key=\"{integer}\">Key</text></column>";
    for ([_]i64{ -9223372036854775808, -9007199254740993, 9007199254740993, 9223372036854775807 }) |integer| try check(source, .{ .integer = integer }, false, true);
}
