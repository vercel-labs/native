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
var operations: [8]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 114) operations[input[2]] += 1;
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
    levels: []const f32 = &.{ 0.25, 0.5 },
    wide_levels: []const f64 = &.{ 0.125, 0.75 },
    labels: []const []const u8 = &.{ "first", "second" },
    expanded: []const bool = &.{true},
    images: []const c.markdown.ResolvedImage = &.{},
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
    pub const declared_rows: []const Row = &.{.{ .id = -1 }};
    pub fn computedRows(model: *const Model) []const Row {
        event(10);
        return model.rows;
    }
    pub fn arenaRows(model: *const Model, arena: std.mem.Allocator) []const Row {
        event(11);
        return arena.dupe(Row, model.rows) catch &.{};
    }
    pub fn computedLevels(model: *const Model) []const f64 {
        event(12);
        return model.wide_levels;
    }

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
    details: usize,
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
test "compiled markup runtime preserves collections keys interpolation and constructor effects" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column><for each=\"rows\" as=\"row\" key=\"id\"><text>{row.derived} {row.name}</text></for><for each=\"declared_rows\" as=\"row\" key=\"id\"><text>{row.id}</text></for></column>",
        "<column><for each=\"computedRows\" as=\"row\" key=\"name\"><text>{row.name}</text></for><for each=\"arenaRows\" as=\"row\" key=\"derived\"><text>{row.id}</text></for></column>",
        "<column><avatar image=\"{image}\" source-height=\"{height}\" source-y=\"{y}\" source-width=\"{width}\" source-x=\"{x}\">A</avatar><text><span weight=\"bold\">Raw {title} {id + 1}</span></text></column>",
        "<column><markdown source=\"{title}\" on-link=\"text\" on-details=\"details\" details-expanded=\"{expanded}\" images=\"{images}\"/><chart x-labels=\"{labels}\"><series values=\"{levels}\"/><series values=\"{computedLevels}\"/></chart></column>",
        "<template name=\"inner\"><column><slot/></column></template><template name=\"outer\"><column><use template=\"inner\"/><slot/></column></template><use template=\"outer\"><text>captured {title}</text></use>",
        "<column><text>borrowed</text><text/><text>{title}{x + y} suffix</text></column>",
    }) |source| try check(source, 0);
    for (operations, 0..) |count, mode| {
        if (count == 0) std.debug.print("runtime program mode {d} was not exercised\n", .{mode});
        try std.testing.expect(count > 0);
    }
}

test "compiled markup runtime preserves rejection order partial options and malformed raw text" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<text>prefix {arenaText} suffix {</text>",                             "<text>{title} {missing}</text>",
        "<text>{x + missing}</text>",                                           "<text>{}</text>",
        "<text>}{title}</text>",                                                "<text>{ title. }</text>",
        "<text>{title}{x+1}{arenaText}</text>",                                 "<column><for each=\"rows\" as=\"row\" key=\"missing\"><text>{row.derived}</text></for></column>",
        "<markdown source=\"{title}\" on-link=\"pick\"/>",                      "<markdown source=\"{title}\" on-details=\"text\"/>",
        "<markdown source=\"{title}\" details-expanded=\"{levels}\"/>",         "<markdown source=\"{title}\" images=\"{levels}\"/>",
        "<chart x-labels=\"{expanded}\"><series values=\"{levels}\"/></chart>", "<chart><series values=\"{labels}\"/></chart>",
        "<code source=\"{title}\" language=\"{yes}\"/>",
    }) |source| try check(source, 0);
    for ([_][]const u8{
        "<avatar source-x=\"{x}\"/>",
        "<avatar image=\"{image}\" source-x=\"{x}\"/>",
        "<button source-x=\"{x}\"/>",
        "<avatar image=\"{image}\" source-height=\"{height}\" source-y=\"{title}\" source-width=\"{width}\" source-x=\"{x}\"/>",
        "<avatar image=\"{image}\" source-height=\"{height}\" source-y=\"{y}\" source-width=\"{width}\" source-x=\"{x}\"/>",
    }) |source| try check(source, 1);
}

test "compiled markup runtime preserves exact identities borrowed text and callback witnesses" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = Model{};
    var ua = Ui.init(arena.allocator());
    var ub = Ui.init(arena.allocator());
    ub.expression_policy = observed;
    var va = try View.init(arena.allocator(), "<text/>");
    var vb = va;
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, -1, 0, 9007199254740993, std.math.maxInt(i64) }) |id| {
        const row = Row{ .id = id };
        const a = try View.RuntimeTest.key(&va, &ua, Row, &row, "id");
        const b = try View.RuntimeTest.key(&vb, &ub, Row, &row, "id");
        try exact(a, b);
        try exact(c.uiKey(@as(u64, @bitCast(id))), b);
    }
    for ([_][]const u8{ "borrowed\x00\xff", "}", "" }) |text| {
        const run = m.MarkupNode{ .kind = .text, .text = text, .line = 3, .column = 5, .src_path = "test.native" };
        const a = try View.RuntimeTest.text(&va, &ua, &model, run);
        const b = try View.RuntimeTest.text(&vb, &ub, &model, run);
        try exact(a, b);
        try exact(@intFromPtr(text.ptr), @intFromPtr(b.ptr));
    }
    for ([_]?m.expr.Policy{ null, observed }) |owner| {
        const callback = View.RuntimeTest.link(owner, "text").?;
        const text: []const u8 = "url\x00\xff";
        try exact(text, callback(text).text);
        try exact(@intFromPtr(text.ptr), @intFromPtr(callback(text).text.ptr));
        try std.testing.expect(View.RuntimeTest.link(owner, "pick") == null);
        try exact(Msg{ .details = 42 }, View.RuntimeTest.details(owner, "details").?(42));
        try exact(Msg{ .pick = 42 }, View.RuntimeTest.details(owner, "pick").?(42));
        try std.testing.expect(View.RuntimeTest.details(owner, "text") == null);
    }
}

test "compiled markup runtime preserves every observed allocation resize and helper retry failure" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "<column><text>prefix {arenaText} {title} {x + y} suffix {</text></column>",
        "<column><for each=\"arenaRows\" as=\"row\" key=\"derived\"><text>{row.name} {row.derived}</text></for><chart x-labels=\"{labels}\"><series values=\"{computedLevels}\"/></chart></column>",
        "<markdown source=\"{title}\" on-link=\"text\" on-details=\"details\" details-expanded=\"{expanded}\" images=\"{images}\"/>",
        "<avatar image=\"{image}\" source-x=\"{x}\" source-y=\"{y}\" source-width=\"{width}\" source-height=\"{height}\">A</avatar>",
    }) |source| for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        const count = try compare(doc, .{}, unlimited, unlimited, 0);
        const resizes = last_resizes;
        for (0..count + 1) |failure| _ = try compare(doc, .{}, failure, unlimited, 0);
        for (0..resizes + 1) |failure| _ = try compare(doc, .{}, unlimited, failure, 0);
    };
}

test "compiled markup classification preserves cached overrides through complete runtime and allocation failures" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try document(arena.allocator(), "<column width=\"999\" label=\"raw\"><button on-press=\"bad:{}\">Go</button><text>{title}</text></column>", false);
    const attrs = try arena.allocator().dupe(m.MarkupAttr, doc.root.?.attrs);
    const width = m.TypedAttrValue{ .literal = "123" };
    const label = m.TypedAttrValue{ .literal = "cached label" };
    attrs[0].typed = &width;
    attrs[1].typed = &label;
    doc.root.?.attrs = attrs;
    const children = try arena.allocator().dupe(m.MarkupNode, doc.root.?.children);
    const events = try arena.allocator().dupe(m.MarkupAttr, children[0].attrs);
    const message = m.TypedAttrValue{ .message = .{ .tag = "pick", .payload = "id" } };
    events[0].typed = &message;
    children[0].attrs = events;
    doc.root.?.children = children;
    const count = try compare(doc, .{}, unlimited, unlimited, 0);
    const resizes = last_resizes;
    for (0..count + 1) |failure| _ = try compare(doc, .{}, failure, unlimited, 0);
    for (0..resizes + 1) |failure| _ = try compare(doc, .{}, unlimited, failure, 0);
}
