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
        } else if (info.size == .one and (@typeInfo(info.child) == .@"struct" or @typeInfo(info.child) == .@"union")) try exact(a.*, b.*) else try std.testing.expectEqual(a, b),
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
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) operations[input[2]] += 1;
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
var trace: [1024]i64 = undefined;
var trace_len: usize = 0;
fn event(n: i64) void {
    trace[trace_len] = n;
    trace_len += 1;
}
const Row = struct {
    id: i64 = 9007199254740993,
    name: []const u8 = "row\x00\xff",
    pub fn derived(row: *const Row) i64 {
        event(6);
        return row.id;
    }
};
const Model = struct {
    rows: []const Row = &.{.{}},
    shared: *const Row = &.{},
    absent: ?bool = null,
    small: i64 = 255,
    negative: i64 = -1,
    arg: bool = false,
    title: []const u8 = "borrowed\x00\xff",
    id: i64 = -9223372036854775808,
    maximum: i64 = 9223372036854775807,
    image: i64 = 5,
    yes: bool = true,
    fraction: f64 = 0.5,
    pub fn arenaText(_: *const Model, arena: std.mem.Allocator) []const u8 {
        event(8);
        return arena.dupe(u8, "arena") catch "oom";
    }
    pub fn unsupported(_: *const Model) []const Row {
        event(9);
        return &.{};
    }

    pub fn x(_: *const Model) f64 {
        event(1);
        return 1;
    }
    pub fn y(_: *const Model) f64 {
        event(2);
        return 2;
    }
    pub fn width(_: *const Model) f64 {
        event(3);
        return 3;
    }
    pub fn height(_: *const Model) f64 {
        event(4);
        return 4;
    }
    pub fn payload(model: *const Model) i64 {
        event(5);
        return model.id;
    }
};
const Msg = union(enum) {
    tick: void,
    small: u8,
    signed: i8,
    flag: bool,
    @"align": enum { start, end },
    pick: i64,
    text: []const u8,
    input: c.TextInputEvent,
    scroll: c.ScrollState,
    terminal: c.TerminalState,
    value: f32,
    wide: f64,
    drag: struct { sourceId: i64, phase: u8, x: f64, y: f64, viewWidth: f64, viewHeight: f64 },
    legacy: struct { offset: f32, content: f32, viewport: f32 },
};
const View = c.MarkupView(Model, Msg);
const Ui = c.Ui(Msg);
const unlimited = std.math.maxInt(usize);
var last_resizes: usize = 0;
fn sink(_: *anyopaque, _: u64, _: *const c.ui_provenance.NodeSource, _: []const c.ui_provenance.Key, _: bool) void {}
fn compare(doc: m.MarkupDocument, model: Model, failure: usize, resize: usize, mode: u8) !usize {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var ui_a = Ui.init(fa.allocator());
    var ui_b = Ui.init(fb.allocator());
    ui_b.expression_policy = observed;
    var context: u8 = 0;
    const provenance: c.ui_provenance.Sink = .{ .context = &context, .record_fn = sink };
    ui_a.provenance_sink = provenance;
    ui_b.provenance_sink = provenance;
    var a = View.fromDocument(doc);
    var b = View.fromDocument(doc);
    trace_len = 0;
    if (mode == 0) {
        const left = a.build(&ui_a, &model);
        const before = trace;
        const length = trace_len;
        trace_len = 0;
        const right = b.build(&ui_b, &model);
        try exact(before[0..length], trace[0..trace_len]);
        if (left) |node| {
            const actual = try right;
            try exact(node, actual);
            const ltree = ui_a.finalize(node);
            const rtree = ui_b.finalize(actual);
            if (ltree) |tree| try exact(tree, try rtree) else |err| try std.testing.expectError(err, rtree);
        } else |err| try std.testing.expectError(err, right);
    } else {
        const left = View.ElementTest.run(&a, &ui_a, &model, doc.root.?, mode == 2);
        const before = trace;
        const length = trace_len;
        trace_len = 0;
        const right = View.ElementTest.run(&b, &ui_b, &model, doc.root.?, mode == 2);
        try exact(before[0..length], trace[0..trace_len]);
        try exact(left, right);
        // These channels must keep their original borrowed storage.
        try exact(@intFromPtr(left.options.semantics.label.ptr), @intFromPtr(right.options.semantics.label.ptr));
        try exact(@intFromPtr(left.options.pty_name.ptr), @intFromPtr(right.options.pty_name.ptr));
    }
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
fn check(source: []const u8, mode: u8) !void {
    errdefer std.debug.print("value parity failed: channel={d} source={s}\n", .{ mode, source });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        _ = try compare(doc, .{}, unlimited, unlimited, mode);
    }
}
test "compiled markup values preserve complete native types borrowed paths and callback witnesses" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column><text>{shared.name} {shared.id} {absent} {arenaText}</text><for each=\"rows\" as=\"row\"><text>{row.derived} {row.name}</text></for></column>",
        "<column><button label=\"Action\" on-press=\"pick:{maximum}\" icon=\"save\" quiet-hover=\"{yes}\"/><avatar image=\"{image}\"/><media-surface surface=\"{image}\"/><terminal pty=\"{title}\" label=\"Terminal\"/></column>",
        "<column><text>width {x + width} {yes == yes}</text><slider label=\"Volume\" on-change=\"wide\" value=\"{fraction}\"/><split on-resize=\"value\"><column/><column/></split></column>",
        "<stack><button label=\"Anchor\"/><tooltip anchor=\"below\" anchor-alignment=\"end\" anchor-offset=\"2\">Hint</tooltip></stack>",
    }) |source| try check(source, 0);
    for ([_][]const u8{
        "<button on-press=\"small:{small}\"/>",                                        "<button on-press=\"signed:{negative}\"/>",
        "<button on-press=\"flag:{absent}\"/>",                                        "<button on-press=\"align:{title}\"/>",
        "<button icon=\"{title}\" quiet-hover=\"{fraction}\" tooltip-delay=\"255\"/>", "<button on-press=\"pick:{shared.id}\"/>",
        "<scroll on-scroll=\"scroll\"/>",                                              "<input on-input=\"input\"/>",
        "<terminal on-terminal=\"terminal\"/>",                                        "<split on-resize=\"wide\"/>",
        "<slider on-change=\"value\"/>",                                               "<button on-drag=\"drag:{maximum}\"/>",
    }) |source| try check(source, 1);
    for (operations[0..16], 0..) |count, mode| {
        if (count == 0) std.debug.print("value program mode {d} was not exercised\n", .{mode});
        try std.testing.expect(count > 0);
    }
}

test "compiled markup values retain rejection order exact boundaries partial options and eager helper effects" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<text>{arenaText == title}</text>",                      "<text>{unsupported}</text>",
        "<text>{shared.missing}</text>",                          "<text>{shared.name.missing}</text>",
        "<text>{missing == arenaText}</text>",                    "<text>{arenaText + missing}</text>",
        "<for each=\"rows\" as=\"row\"><text>{row}</text></for>", "<for each=\"rows\" as=\"row\"><text>{row.missing}</text></for>",
    }) |source| try check(source, 0);
    for ([_][]const u8{
        "<button width=\"{x}\" image=\"{payload}\"/>",
        "<avatar image=\"{negative}\"/>",
        "<avatar image=\"text\"/>",
        "<media-surface surface=\"{title}\"/>",
        "<terminal pty=\"{negative}\"/>",
        "<column quiet-hover=\"{payload}\"/>",
        "<text icon=\"bad\"/>",
        "<button icon=\"nonexistent-icon\"/>",
        "<button width=\"{x}\" tooltip-delay=\"2147483648\"/>",
        "<button width=\"{title}\"/>",
        "<button tooltip-delay=\"-1\"/>",
        "<button on-press=\"unknown:{missing}\"/>",
        "<button on-press=\"tick:{payload}\"/>",
        "<button on-press=\"pick\"/>",
        "<button on-press=\"small:{maximum}\"/>",
        "<button on-press=\"signed:{small}\"/>",
        "<button on-press=\"text:{fraction}\"/>",
        "<button on-drag=\"pick:{payload}\"/>",
        "<button on-drag=\"missing\"/>",
        "<button on-scroll=\"scroll\"/>",
        "<scroll on-scroll=\"legacy\"/>",
        "<input on-input=\"pick\"/>",
        "<split on-resize=\"pick\"/>",
        "<tooltip anchor-alignment=\"bad\"/>",
        "<tooltip anchor-offset=\"bad\"/>",
        "<tooltip anchor=\"bad\"/>",
        "<tooltip anchor=\"below\" anchor-offset=\"bad\"/>",
    }) |source| try check(source, 1);
}

test "compiled markup values retain initialized lexical payloads floors diagnostics and borrowed aliases" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = Model{};
    for ([_]bool{ false, true }) |owner| {
        var ui = Ui.init(arena.allocator());
        if (owner) ui.expression_policy = observed;
        for (0..5) |mode| for ([_][]const u8{ "arg", "arg.x", "missing", "shared.name", "arenaText" }) |path| {
            var view = try View.init(arena.allocator(), "<text/>");
            const result = View.ValueTest.run(&view, &ui, &model, path, false, @intCast(mode));
            if (mode == 1 and std.mem.eql(u8, path, "arg")) try std.testing.expect(result.value.?.boolean);
        };
    }
    for (0..5) |mode| for ([_][]const u8{ "arg", "arg.x", "missing", "shared.name", "arenaText" }) |path| {
        var ua = Ui.init(arena.allocator());
        var ub = Ui.init(arena.allocator());
        ub.expression_policy = observed;
        var va = try View.init(arena.allocator(), "<text/>");
        var vb = va;
        trace_len = 0;
        const a = View.ValueTest.run(&va, &ua, &model, path, false, @intCast(mode));
        const before = trace;
        const count = trace_len;
        trace_len = 0;
        const b = View.ValueTest.run(&vb, &ub, &model, path, false, @intCast(mode));
        try exact(a, b);
        try exact(va.diagnostic, vb.diagnostic);
        try exact(before[0..count], trace[0..trace_len]);
        if (a.value) |value| if (value == .string) try exact(@intFromPtr(value.string.ptr), @intFromPtr(b.value.?.string.ptr));
    };
}

test "compiled markup values preserve every observed build allocation and resize failure" {
    _ = core.initialModel();
    const source = "<column><text>{arenaText} {shared.name}</text><button label=\"{title}\" width=\"{x + width}\" on-press=\"pick:{maximum}\"/><for each=\"rows\" as=\"row\"><text>{row.derived}</text></for></column>";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        const count = try compare(doc, .{}, unlimited, unlimited, 0);
        const resizes = last_resizes;
        for (0..count + 1) |index| _ = try compare(doc, .{}, index, unlimited, 0);
        for (0..resizes + 1) |index| _ = try compare(doc, .{}, unlimited, index, 0);
    }
}

test "compiled markup values construct successful exact payloads and callable handlers" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = Model{};
    for ([_]bool{ false, true }) |owner| {
        var ui = Ui.init(arena.allocator());
        if (owner) ui.expression_policy = observed;
        for ([_][]const u8{
            "<button on-press=\"pick:{maximum}\"/>",
            "<button on-press=\"text:{title}\"/>",
            "<button on-drag=\"drag:{id}\"/>",
            "<split on-resize=\"wide\"/>",
            "<slider on-change=\"value\"/>",
        }, 0..) |source, index| {
            var view = try View.init(arena.allocator(), source);
            const result = View.ElementTest.run(&view, &ui, &model, view.document.root.?, true);
            try std.testing.expect(result.failure == null);
            switch (index) {
                0 => try std.testing.expectEqual(model.maximum, result.options.on_press.?.pick),
                1 => {
                    try std.testing.expectEqualSlices(u8, model.title, result.options.on_press.?.text);
                    try std.testing.expectEqual(@intFromPtr(model.title.ptr), @intFromPtr(result.options.on_press.?.text.ptr));
                },
                2 => try exact(Msg{ .drag = .{ .sourceId = model.id, .phase = 0, .x = 0, .y = 0, .viewWidth = 0, .viewHeight = 0 } }, result.options.on_drag.?),
                3 => try std.testing.expectEqual(@as(f64, 0.75), result.options.on_resize.?(@as(f32, 0.75)).wide),
                4 => try std.testing.expectEqual(@as(f32, 0.25), result.options.on_value.?(@as(f32, 0.25)).value),
                else => unreachable,
            }
        }
    }
}
