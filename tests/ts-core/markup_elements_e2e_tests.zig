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
var operations: [5]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 111) operations[input[2]] += 1;
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
const Model = struct {
    title: []const u8 = "borrowed\x00\xff",
    id: i64 = -9223372036854775808,
    maximum: i64 = 9223372036854775807,
    image: i64 = 5,
    yes: bool = true,
    fraction: f64 = 0.5,
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        _ = try compare(doc, .{}, unlimited, unlimited, mode);
    }
}
test "compiled markup elements preserve complete ordinary trees metadata text and all owner modes" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column><button label=\"Action\" on-press=\"pick:{id}\" key=\"{id}\" global-key=\"{maximum}\" icon=\"save\" background=\"surface\" radius=\"md\"/><text text=\"attribute\">content {title}</text><avatar image=\"{image}\"/><icon name=\"save\"/><icon name=\"app:custom\"/><text><span>one</span><span color=\"primary\">two</span></text></column>",
        "<column><tabs><button on-press=\"tick\">First</button><button selected=\"true\">Second</button></tabs><list-item><text>child</text></list-item><select>Choose</select></column>",
        "<column on-press=\"tick\"><context-menu><menu-item on-press=\"pick:{id}\">Pick</menu-item></context-menu><bubble><text>{title}</text><reactions text-alignment=\"start\">two</reactions></bubble><split on-resize=\"wide\"><column/><column/></split></column>",
        "<column><image image=\"{image}\" source-height=\"{height}\" source-width=\"{width}\" source-y=\"{y}\" source-x=\"{x}\"/><terminal pty=\"{title}\" scrollback=\"12\"/><slider label=\"Volume\" on-change=\"value\"/><input label=\"Name\" on-input=\"input\"/><scroll on-scroll=\"scroll\" on-reach-start=\"tick\" on-reach-end=\"tick\"><text>body</text></scroll></column>",
        "<template name=\"t\" args=\"key= global=\"><text key=\"{key}\" global-key=\"{global}\">key</text></template><column><use template=\"t\"/><use template=\"t\" key=\"\"/><use template=\"t\" key=\"{id}\" global=\"{maximum}\"/></column>",
    }) |source| try check(source, 0);
    for (operations) |count| try std.testing.expect(count > 0);
}
test "compiled markup elements preserve diagnostic witnesses admission and error precedence" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<step/>",                                                                          "<series/>",                                                            "<context-menu/>",                                 "<input-group-actions/>",                                   "<span/>",                                             "<reactions/>",                                      "<unknown/>",
        "<column><context-menu/><context-menu/></column>",                                  "<column on-press=\"tick\"><context-menu/><context-menu/></column>",    "<bubble><reactions/><reactions/></bubble>",       "<bubble text=\"bad\"><reactions>one</reactions></bubble>", "<column><reactions/></column>",                       "<column on-input=\"missing\" autofocus=\"true\"/>", "<stack gap=\"4\"/>",
        "<button wrap=\"true\"/>",                                                          "<column overflow=\"bad\"/>",                                           "<text overflow=\"bad\">x</text>",                 "<text submit-on-enter=\"true\">x</text>",                  "<button size=\"heading\">x</button>",                 "<text size=\"nope\">x</text>",                      "<split><column/></split>",
        "<split>raw<column/></split>",                                                      "<image/>",                                                             "<image image=\"{image}\"><text>x</text></image>", "<terminal/>",                                              "<terminal pty=\"{image}\"><text>x</text></terminal>", "<button/>",                                         "<button icon=\"save\"/>",
        "<input/>",                                                                         "<column role=\"radiogroup\"/>",                                        "<text role=\"nope\">x</text>",                    "<text role=\"tree\">x</text>",                             "<icon/>",                                             "<icon name=\"save\"><text>x</text></icon>",         "<list-item>mixed<text>x</text></list-item>",
        "<column on-press=\"tick\"><context-menu><text>bad</text></context-menu></column>", "<bubble><reactions text-alignment=\"wrong\">one</reactions></bubble>",
    }) |source| try check(source, 0);
}
test "compiled markup elements preserve ordered duplicate attributes exact conversions and partial options" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<text kind=\"ignored\" text=\"first\" text=\"{title}\" label=\"{title}\" width=\"1\" width=\"{fraction}\" key=\"{id}\" global-key=\"{maximum}\"/>",
        "<image image=\"{image}\" source-height=\"{height}\" source-width=\"{width}\" source-y=\"{y}\" source-x=\"{x}\" label=\"{title}\"/>",
        "<text label=\"first\" unknown=\"x\" label=\"last\"/>",
        "<column source-x=\"{missing}\"/>",
        "<image source-x=\"{missing}\"/>",
        "<image image=\"{image}\" source-x=\"{missing}\"/>",
        "<image image=\"{image}\" source-x=\"{x}\" source-y=\"{missing}\" source-width=\"{width}\" source-height=\"{height}\"/>",
        "<column scrollback=\"1\"/>",
        "<terminal text=\"bad\"/>",
        "<column controls=\"true\"/>",
        "<column autoplay=\"true\"/>",
        "<column loop=\"true\"/>",
        "<column muted=\"true\"/>",
        "<column name=\"save\"/>",
        "<button icon=\"save\" quiet-hover=\"{yes}\"/>",
        "<column icon=\"save\"/>",
        "<dropdown-menu anchor=\"below\" anchor-alignment=\"start\" anchor-offset=\"-0.0\"/>",
        "<dropdown-menu anchor-offset=\"1\"/>",
        "<dropdown-menu anchor=\"below\" anchor-offset=\"bad\"/>",
        "<text background=\"surface\" color=\"primary\" border-color=\"border\" radius=\"md\"/>",
        "<text background=\"{title}\"/>",
        "<text radius=\"bad\"/>",
        "<text background=\"bad\"/>",
        "<text tooltip-delay=\"2147483647\"/>",
        "<text tooltip-delay=\"2147483648\"/>",
        "<text tooltip-delay=\"-1\"/>",
        "<text resize-duration=\"4294967295\"/>",
        "<text resize-duration=\"4294967296\"/>",
        "<text width=\"wrong\"/>",
        "<text key=\"{fraction}\"/>",
        "<text key=\"{yes}\"/>",
        "<image image=\"{id}\"/>",
        "<canvas surface=\"{id}\"/>",
        "<terminal pty=\"{id}\"/>",
        "<terminal pty=\"{title}\"/>",
        "<text focusable=\"nope\"/>",
        "<text role=\"{id}\"/>",
        "<text label=\"{id}\"/>",
    }) |source| try check(source, 1);
}
test "compiled markup elements preserve event constructors fallback and payload evaluation before refusal" {
    _ = core.initialModel();
    for ([_][]const u8{ "press", "double-press", "toggle", "change", "submit", "dismiss", "hold", "hover-enter", "hover-leave", "reach-start", "reach-end", "unknown" }) |name| {
        for ([_][]const u8{ "column", "scroll", "slider", "dialog" }) |element| {
            for ([_][]const u8{ "tick", "pick:{payload}", "missing", "pick", "tick:{payload}" }) |value| {
                const source = try std.fmt.allocPrint(std.testing.allocator, "<{s} on-{s}=\"{s}\"/>", .{ element, name, value });
                defer std.testing.allocator.free(source);
                try check(source, 2);
            }
        }
    }
    for ([_][]const u8{
        "<input on-input=\"input\"/>",               "<input on-input=\"tick\"/>",           "<input on-input=\"input:{id}\"/>",
        "<scroll on-scroll=\"scroll\"/>",            "<scroll on-scroll=\"legacy\"/>",       "<scroll on-scroll=\"tick\"/>",
        "<column on-scroll=\"scroll\"/>",            "<terminal on-terminal=\"terminal\"/>", "<terminal on-terminal=\"tick\"/>",
        "<terminal on-terminal=\"terminal:{id}\"/>", "<column on-terminal=\"terminal\"/>",   "<split on-resize=\"value\"/>",
        "<split on-resize=\"wide\"/>",               "<split on-resize=\"pick\"/>",          "<column on-resize=\"value\"/>",
        "<slider on-change=\"value\"/>",             "<slider on-change=\"wide\"/>",         "<slider on-change=\"tick\"/>",
        "<slider on-change=\"pick:{payload}\"/>",    "<column on-drag=\"drag:{payload}\"/>", "<column on-drag=\"drag\"/>",
        "<column on-drag=\"tick\"/>",                "<column on-drag=\"pick:{payload}\"/>",
    }) |source| try check(source, 2);
}
test "compiled markup elements preserve every allocation resize and partial node failure" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "<column on-press=\"tick\"><context-menu><menu-item>Pick</menu-item></context-menu><bubble><text><span>{title}</span><span>other</span></text><reactions>two {title}</reactions></bubble><tabs><button>First</button><button>Second</button></tabs></column>",
        "<template name=\"t\" args=\"key=\"><text key=\"{key}\" text=\"{title}\"/></template><column><use template=\"t\"/><use template=\"t\" key=\"{id}\"/></column>",
    }) |source| {
        const doc = try document(arena.allocator(), source, true);
        const allocations = try compare(doc, .{}, unlimited, unlimited, 0);
        const resizes = last_resizes;
        for (0..allocations + 1) |failure| _ = try compare(doc, .{}, failure, unlimited, 0);
        for (0..resizes + 1) |resize| {
            const attempts = try compare(doc, .{}, unlimited, resize, 0);
            for (0..attempts + 1) |failure| _ = try compare(doc, .{}, failure, resize, 0);
        }
    }
}

test "compiled markup elements retain all schema routes and reflected option admission" {
    _ = core.initialModel();
    for (m.schema.elements) |entry| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<{s}/>", .{entry.name});
        defer std.testing.allocator.free(source);
        try check(source, 0);
    }
    for (m.schema.option_field_pairs) |entry| {
        for ([_][]const u8{ "0", "-1", "{maximum}", "{fraction}", "{title}", "{yes}" }) |value| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "<text {s}=\"{s}\"/>", .{ entry.markup, value });
            defer std.testing.allocator.free(source);
            try check(source, 1);
        }
    }
}
test "compiled markup elements preserve raw bytes borrowed text and exact key identity boundaries" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try document(arena.allocator(), "<text key=\"{id}\" global-key=\"{maximum}\" text=\"{title}\" label=\"{title}\"/>", true);
    var raw: [256]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..257) |length| _ = try compare(doc, .{ .title = raw[0..length] }, unlimited, unlimited, 1);
    for ([_]i64{ std.math.minInt(i64), -9007199254740993, -1, 0, 9007199254740993, std.math.maxInt(i64) }) |value| {
        _ = try compare(doc, .{ .id = value, .maximum = value }, unlimited, unlimited, 0);
    }
}
test "compiled markup elements distinguish cached attributes from raw literal admission" {
    _ = core.initialModel();
    const attributes = [_]m.MarkupAttr{
        .{ .name = "background", .value = "{title}", .line = 41, .column = 7, .typed = &.{ .literal = "surface" } },
        .{ .name = "background", .value = "surface", .line = 41, .column = 7, .typed = &.{ .binding = "title" } },
        .{ .name = "overflow", .value = "bad", .line = 41, .column = 7, .typed = &.{ .literal = "clip" } },
        .{ .name = "size", .value = "heading", .line = 41, .column = 7, .typed = &.{ .literal = "md" } },
        .{ .name = "on-press", .value = "tick", .line = 41, .column = 7, .typed = &@as(m.TypedAttrValue, .invalid) },
    };
    for (attributes) |attribute| {
        const doc: m.MarkupDocument = .{ .root = .{ .kind = .element, .name = "text", .attrs = &.{attribute}, .src_path = "raw\x00\xff", .line = 41, .column = 7 } };
        _ = try compare(doc, .{}, unlimited, unlimited, 0);
        _ = try compare(doc, .{}, unlimited, unlimited, 1);
    }
}
