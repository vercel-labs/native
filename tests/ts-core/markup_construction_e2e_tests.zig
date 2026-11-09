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
var operations: [13]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 110) operations[input[2]] += 1;
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
var trace: [256]i64 = undefined;
var trace_len: usize = 0;
fn event(value: i64) void {
    if (trace_len >= trace.len) @panic("trace capacity");
    trace[trace_len] = value;
    trace_len += 1;
}
const Item = struct {
    id: i64,
    pub fn label(item: *const Item) []const u8 {
        event(item.id);
        return "borrowed\x00\xff";
    }
    pub fn identity(item: *const Item) i64 {
        event(-item.id);
        return item.id;
    }
};
const Model = struct {
    rows: []const Item = &.{ .{ .id = 1 }, .{ .id = 2 } },
    title: []const u8 = "model\x00\xff",
    show: bool = true,
    pub fn computed(model: *const Model, arena: std.mem.Allocator) []const Item {
        event(100);
        const out = arena.dupe(Item, model.rows) catch return &.{};
        return out;
    }
    pub fn condition(model: *const Model) bool {
        event(200);
        return model.show;
    }
};
const Msg = union(enum) { pick: i64, tick: void };
const View = c.MarkupView(Model, Msg);
const Ui = c.Ui(Msg);
fn sink(_: *anyopaque, _: u64, _: *const c.ui_provenance.NodeSource, _: []const c.ui_provenance.Key, _: bool) void {}
fn aliases(a: anytype, b: @TypeOf(a)) !void {
    try exact(@intFromPtr(a.name.ptr), @intFromPtr(b.name.ptr));
    if (a.payload == .value and a.payload.value == .string) try exact(@intFromPtr(a.payload.value.string.ptr), @intFromPtr(b.payload.value.string.ptr));
}
fn compare(document: m.MarkupDocument, model: Model, failure: usize, resize: usize, provenance: bool, seed: ?[4]usize) !usize {
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
    if (provenance) {
        const s: c.ui_provenance.Sink = .{ .context = &context, .record_fn = sink };
        ui_a.provenance_sink = s;
        ui_b.provenance_sink = s;
    }
    var a = View.fromDocument(document);
    var b = View.fromDocument(document);
    trace_len = 0;
    if (seed) |state| {
        const left = View.ConstructionTest.run(&a, &ui_a, &model, state[0], state[1], state[2], if (state[3] == 0) null else state[3] - 1);
        const before = trace;
        const before_len = trace_len;
        trace_len = 0;
        const right = View.ConstructionTest.run(&b, &ui_b, &model, state[0], state[1], state[2], if (state[3] == 0) null else state[3] - 1);
        try exact(before[0..before_len], trace[0..trace_len]);
        try exact(left.failure, right.failure);
        try exact(left.node, right.node);
        inline for (.{ "len", "floor", "use_depth", "template_ctx", "source_chain", "entries" }) |field| try exact(@field(left.scope, field), @field(right.scope, field));
        for (left.scope.entries, right.scope.entries) |l, r| try aliases(l, r);
    } else {
        const left = a.build(&ui_a, &model);
        const before = trace;
        const before_len = trace_len;
        trace_len = 0;
        const right = b.build(&ui_b, &model);
        try exact(before[0..before_len], trace[0..trace_len]);
        if (left) |node| {
            const actual = try right;
            try exact(node, actual);
            // Finalization also verifies complete identities, handler tables and provenance.
            const ltree = ui_a.finalize(node);
            const rtree = ui_b.finalize(actual);
            if (ltree) |tree| try exact(tree, try rtree) else |err| try std.testing.expectError(err, rtree);
        } else |err| try std.testing.expectError(err, right);
    }
    try exact(a.diagnostic, b.diagnostic);
    try exact(ui_a.failed, ui_b.failed);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    return fa.alloc_index;
}
fn parseDocument(arena: std.mem.Allocator, source: []const u8) !m.MarkupDocument {
    var parser = m.Parser.init(arena, source);
    return m.canonicalize(arena, try parser.parse());
}
fn check(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parseDocument(arena.allocator(), source);
    for ([_]bool{ false, true }) |provenance| {
        for ([_]Model{ .{}, .{ .rows = &.{}, .show = false } }) |model| _ = try compare(doc, model, std.math.maxInt(usize), std.math.maxInt(usize), provenance, null);
    }
}
test "compiled markup construction preserves full templates slots defaults loops and callback order" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column><for each=\"rows\" as=\"r\" key=\"identity\"><text>{r.label}</text><if test=\"{condition}\"><button on-press=\"pick:{r.id}\">{title}</button></if><else><text>hidden</text></else><text key=\"explicit\">last</text></for><else><text>empty</text></else></column>",
        "<template name=\"t\" args=\"heading=flat data\"><column><text>{heading}</text><for each=\"data\" as=\"r\" key=\"identity\"><text>{r.label}</text><slot/></for></column></template><column><for each=\"rows\" as=\"outer\"><use template=\"t\" data=\"{computed}\"><text>{outer.id} {title}</text></use></for></column>",
        "<template name=\"a\" args=\"x=default\"><column><text>{x}</text><slot/><text>{x}</text></column></template><template name=\"b\" args=\"x\"><column><use template=\"a\" x=\"{x}\"><text>{x}</text></use><slot/></column></template><column><use template=\"b\" x=\"{title}\"><text>{title}</text></use><use template=\"a\"/></column>",
        "<template name=\"t\" args=\"title rows=scalar\"><column><text>{title}</text><for each=\"rows\" as=\"r\"><text>{r.id}</text></for><else><text>empty</text></else></column></template><column><use template=\"t\" title=\"{title}\"/></column>",
        "<template name=\"t\" args=\"title x\"><text>{title} {x}</text></template><column><use template=\"t\" title=\"changed\" x=\"{title}\" on-press=\"tick\"/></column>",
        "<column><for each=\"computed\" as=\"r\"><if test=\"{false}\"><text>{r.label}</text></if></for><else><text>resolved empty</text></else></column>",
    }) |source| try check(source);
    try check("<template name=\"empty\" args=\"x=\"><column><text>{x}</text><slot/></column></template><column><use template=\"empty\"/></column>");
    for (operations) |count| try std.testing.expect(count > 0);
}
test "compiled markup construction preserves complete failure diagnostics and precedence" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<template name=\"t\"><row/></template>",                                                                              "<import src=\"missing.native\"/><row/>",
        "<column><else/></column>",                                                                                            "<column><if/><else/></column>",
        "<column><slot x=\"a\"><row/></slot></column>",                                                                        "<column><slot><row/></slot></column>",
        "<column><slot/></column>",                                                                                            "<column><for/></column>",
        "<column><for each=\"rows\"/></column>",                                                                               "<column><for each=\"rows\" as=\"r\"/></column>",
        "<column><for each=\"missing\" as=\"r\"><text>x</text></for><else><text>fallback</text></else></column>",              "<column><use/></column>",
        "<column><use template=\"missing\"/></column>",                                                                        "<template name=\"t\"><row/></template><column><use template=\"t\"><text>bad</text></use></column>",
        "<template name=\"t\"><row><slot/><slot/></row></template><column><use template=\"t\"/></column>",                     "<template name=\"t\" args=\"x\"><text>{x}</text></template><column><use template=\"t\" unknown=\"y\"/></column>",
        "<template name=\"t\" args=\"x\"><text>{x}</text></template><column><use template=\"t\" on-click=\"tick\"/></column>", "<template name=\"t\" args=\"x='{'\"><text>{x}</text></template><column><use template=\"t\"/></column>",
        "<template name=\"t\" args=\"x='a\"><text>{x}</text></template><column><use template=\"t\"/></column>",                "<template name=\"t\" args=\"x\"><text>{x}</text></template><column><use template=\"t\"/></column>",
        "<template name=\"t\"><column><use template=\"t\"/></column></template><column><use template=\"t\"/></column>",
    }) |source| try check(source);
    for (std.enums.values(m.MarkupNodeKind)) |kind| {
        if (kind == .element or kind == .use_block) continue;
        _ = try compare(.{ .root = .{ .kind = kind, .line = 19, .column = 7, .src_path = "raw\x00\xff" } }, .{}, std.math.maxInt(usize), std.math.maxInt(usize), false, null);
    }
}
test "compiled markup construction preserves every scope and expansion boundary including failed provenance activation" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][]const u8{
        "<template name=\"t\" args=\"x=default y=1\"><column><text>{x}</text><slot/></column></template><use template=\"t\"/>",
        "<template name=\"t\" args=\"x\"><column><text>{x}</text></column></template><use template=\"t\" x=\"{title}\"/>",
        "<column><for each=\"rows\" as=\"r\"><text>{r.id}</text></for></column>",
    };
    for (sources) |source| {
        const doc = try parseDocument(arena.allocator(), source);
        for (0..17) |length| for ([_]usize{ 0, length }) |floor| for ([_]usize{ 0, 127, 128 }) |depth| {
            for ([_]bool{ false, true }) |provenance| _ = try compare(doc, .{}, std.math.maxInt(usize), std.math.maxInt(usize), provenance, .{ length, floor, depth, 0 });
        };
        for ([_]usize{ 0, 1, 2 }) |context| _ = try compare(doc, .{}, std.math.maxInt(usize), std.math.maxInt(usize), true, .{ 0, 0, 0, context });
        for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |resize| {
            const attempts = try compare(doc, .{}, std.math.maxInt(usize), resize, true, .{ 0, 0, 0, 0 });
            for (0..attempts + 1) |failure| _ = try compare(doc, .{}, failure, resize, true, .{ 0, 0, 0, 0 });
        }
    }
}
test "compiled markup construction preserves all arena failures resizes raw bytes aliases and complete emitted siblings" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parseDocument(arena.allocator(), "<template name=\"t\" args=\"data heading={bad}\"><column><text>{heading}</text><slot/><for each=\"data\" as=\"r\" key=\"identity\"><text>{r.label}</text><text global-key=\"global\">last</text></for></column></template><column><for each=\"computed\" as=\"outer\" key=\"identity\"><use template=\"t\" data=\"{rows}\" heading=\"{title}\"><text>{outer.label}</text></use><text>{outer.label}</text></for></column>");
    for ([_]bool{ false, true }) |provenance| for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |resize| {
        const attempts = try compare(doc, .{}, std.math.maxInt(usize), resize, provenance, null);
        for (0..attempts + 1) |failure| _ = try compare(doc, .{}, failure, resize, provenance, null);
    };
    var raw: [256]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
    const bytes_doc = try parseDocument(arena.allocator(), "<template name=\"t\" args=\"x\"><text>{x}</text></template><column><use template=\"t\" x=\"{title}\"/></column>");
    for (0..257) |length| _ = try compare(bytes_doc, .{ .title = raw[0..length] }, std.math.maxInt(usize), std.math.maxInt(usize), true, null);
}

test "compiled markup construction preserves real nested scope overflow and empty keyed bodies" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..18) |depth| {
        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        try bytes.appendSlice(arena.allocator(), "<column>");
        for (0..depth) |_| try bytes.appendSlice(arena.allocator(), "<for each=\"rows\" as=\"r\" key=\"identity\">");
        try bytes.appendSlice(arena.allocator(), "<if test=\"{false}\"><text>{r.label}</text></if>");
        for (0..depth) |_| try bytes.appendSlice(arena.allocator(), "</for>");
        try bytes.appendSlice(arena.allocator(), "</column>");
        const doc = try parseDocument(arena.allocator(), bytes.items);
        // A singleton avoids exponential output while exercising every frame.
        for ([_]bool{ false, true }) |provenance| _ = try compare(doc, .{ .rows = &.{.{ .id = 1 }} }, std.math.maxInt(usize), std.math.maxInt(usize), provenance, null);
    }
}
