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
var forms: [14]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 113) {
        operations[input[2]] += 1;
        if (input[2] == 27) {
            const channel: usize = @intFromFloat(@as(f64, @bitCast(std.mem.readInt(u64, input[4..12], .little))));
            forms[channel] += 1;
        }
    }
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
var trace: [2048]i64 = undefined;
var trace_len: usize = 0;
fn event(value: i64) void {
    trace[trace_len] = value;
    trace_len += 1;
}
const Row = struct { id: i64, title: []const u8 };
const Model = struct {
    body: []const u8 = "# Title\n\nText [link](https://example.com)\n\n<details><summary>Summary</summary>Body</details>\n\n![alt](sample)",
    code: []const u8 = "const value = 42;\nreturn value;\n",
    diff: []const u8 = "1-2",
    flags: []const bool = &.{ true, false },
    images: []const c.markdown.ResolvedImage = &.{.{ .source = "sample", .image = 18446744073709551615, .width = 20, .height = 10 }},
    levels: []const f32 = &.{ 1, 3, 2 },
    labels: []const []const u8 = &.{ "One", "Two", "Three" },
    rows_data: []const Row = &.{ .{ .id = -9223372036854775808, .title = "First" }, .{ .id = 9223372036854775807, .title = "Second" } },
    title: []const u8 = "Borrowed\x00\xff",
    yes: bool = true,
    scale: f64 = 0.5,
    pub fn first(_: *const Model) f64 {
        event(1);
        return 1.5;
    }
    pub fn second(_: *const Model) f64 {
        event(2);
        return 2.5;
    }
    pub fn count(_: *const Model) i64 {
        event(3);
        return 2;
    }
    pub fn source(self: *const Model) []const u8 {
        event(4);
        return self.body;
    }
};
const Msg = union(enum) { tick, pick: i64, input: c.TextInputEvent, link: []const u8, details: usize };
const Ui = c.Ui(Msg);
const View = c.MarkupView(Model, Msg);
const unlimited = std.math.maxInt(usize);
var last_resizes: usize = 0;
fn compare(doc: m.MarkupDocument, model: Model, failure: usize, resize: usize) !usize {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize });
    var ui_a = Ui.init(fa.allocator());
    var ui_b = Ui.init(fb.allocator());
    ui_b.expression_policy = observed;
    var a = View.fromDocument(doc);
    var b = View.fromDocument(doc);
    trace_len = 0;
    const left = View.ConstructionTest.run(&a, &ui_a, &model, 0, 0, 0, null);
    const before = trace;
    const length = trace_len;
    trace_len = 0;
    const right = View.ConstructionTest.run(&b, &ui_b, &model, 0, 0, 0, null);
    try exact(before[0..length], trace[0..trace_len]);
    try exact(left.failure, right.failure);
    try exact(left.node, right.node);
    try exact(left.scope.entries, right.scope.entries);
    try exact(left.scope.len, right.scope.len);
    try exact(left.scope.floor, right.scope.floor);
    try exact(left.scope.use_depth, right.scope.use_depth);
    try exact(left.scope.template_ctx, right.scope.template_ctx);
    try exact(left.scope.source_chain, right.scope.source_chain);
    if (left.node) |node| {
        const lt = ui_a.finalize(node);
        const rt = ui_b.finalize(right.node.?);
        if (lt) |tree| try exact(tree, try rt) else |err| try std.testing.expectError(err, rt);
    }
    try exact(ui_a.video_declaration, ui_b.video_declaration);
    try exact(ui_a.virtualWindows(), ui_b.virtualWindows());
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
fn check(source: []const u8, model: Model, failures: bool) !void {
    errdefer std.debug.print("specialized admission parity failed: {s}\n", .{source});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        const count = try compare(doc, model, unlimited, unlimited);
        const resizes = last_resizes;
        if (failures) {
            for (0..count + 1) |index| _ = try compare(doc, model, index, unlimited);
            for (0..resizes + 1) |index| _ = try compare(doc, model, unlimited, index);
        }
    }
}
test "compiled markup admission preserves all specialized channels complete trees and failure effects" {
    _ = core.initialModel();
    operations = @splat(0);
    forms = @splat(0);
    for ([_][]const u8{
        "<markdown source=\"{source}\" on-link=\"link\" on-details=\"details\" details-expanded=\"{flags}\" images=\"{images}\" issue-link-base=\"https://example.com/issues/\"/>",
        "<code source=\"{source}\" language=\"typescript\" line-numbers editable on-input=\"input:{title}\" added-lines=\"1\" removed-lines=\"{diff}\" wrap=\"{yes}\" width=\"{first}\"/>",
        "<chart x-labels=\"{labels}\"><series kind=\"area\" kind=\"line\" values=\"{levels}\" color=\"accent\"/></chart>",
        "<video controls autoplay loop=\"false\" muted=\"{yes}\" width=\"{first}\"/>",
        "<text><span scale=\"{first}\">{title}</span><span scale=\"{count}\">Integer</span></text>",
        "<template name=\"steps\" args=\"title\"><stepper active=\"1\"><slot/></stepper></template><column><for each=\"rows_data\" as=\"row\"><use template=\"steps\" title=\"Shadow\"><step>{row.title}</step><step>{title}</step></use></for></column>",
    }) |source| try check(source, .{}, true);
    for (operations[27..31]) |count| try std.testing.expect(count > 0);
    for (forms) |count| try std.testing.expect(count > 0);
}
test "compiled markup admission preserves every specialized form diagnostic and eager failure order" {
    _ = core.initialModel();
    const cases = [_]struct { before: []const u8, name: []const u8, after: []const u8 }{
        .{ .before = "<markdown ", .name = "source", .after = "/>" },
        .{ .before = "<markdown source=\"{source}\" ", .name = "on-link", .after = "/>" },
        .{ .before = "<markdown source=\"{source}\" ", .name = "on-details", .after = "/>" },
        .{ .before = "<markdown source=\"{source}\" ", .name = "details-expanded", .after = "/>" },
        .{ .before = "<markdown source=\"{source}\" ", .name = "images", .after = "/>" },
        .{ .before = "<markdown source=\"{source}\" ", .name = "issue-link-base", .after = "/>" },
        .{ .before = "<code width=\"{first}\" ", .name = "source", .after = "/>" },
        .{ .before = "<code source=\"{source}\" ", .name = "language", .after = "/>" },
        .{ .before = "<code source=\"{source}\" ", .name = "on-input", .after = "/>" },
        .{ .before = "<chart width=\"{first}\" ", .name = "x-labels", .after = "><series values=\"{levels}\"/></chart>" },
        .{ .before = "<chart><series values=\"{levels}\" ", .name = "kind", .after = "/></chart>" },
        .{ .before = "<chart><series label=\"{source}\" ", .name = "values", .after = "/></chart>" },
        .{ .before = "<chart><series values=\"{levels}\" ", .name = "color", .after = "/></chart>" },
        .{ .before = "<code source=\"{source}\" ", .name = "added-lines", .after = "/>" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| for ([_][]const u8{ "literal", "{source}", "{first == second}", "{first + second}", "{}", "link:{title}" }) |raw| {
        const source = try std.fmt.allocPrint(arena.allocator(), "{s}{s}=\"{s}\"{s}", .{ case.before, case.name, raw, case.after });
        try check(source, .{}, true);
    };
    for ([_][]const u8{
        "<markdown source=\"{source}\" source=\"{count}\" images=\"{missing}\"/>",
        "<markdown source=\"{source}\" issue-link-base=\"https://example.com/\" issue-link-base=\"\"/>",
        "<markdown source=\"{source}\" on-link=\"link:{title}\"/>",
        "<code source=\"{source}\" on-input=\"tick\" width=\"{second}\"/>",
        "<code source=\"{source}\" added-lines=\"{count}\" wrap=\"{second}\"/>",
        "<video controls=\"{first}\" controls=\"{missing}\" width=\"{second}\"/>",
        "<column><video src=\"synthetic.mp4\" controls/><code source=\"{count}\"/></column>",
        "<text><span scale=\"{yes}\">{source}</span></text>",
        "<text><span scale=\"{source}\">{second}</span></text>",
        "<stepper active=\"{count}\"><slot/></stepper>",
        "<stepper active=\"{count}\"><slot/><step>{second}</step></stepper>",
        "<template name=\"steps\"><stepper active=\"{count}\"><slot/></stepper></template><use template=\"steps\"><step>{source}</step><step>{missing}</step></use>",
        "<template name=\"inner\"><stepper active=\"{count}\"><slot/></stepper></template><template name=\"outer\"><column><use template=\"inner\"/><slot/></column></template><use template=\"outer\"><step>{second}</step></use>",
    }) |source| try check(source, .{}, true);
}
test "compiled markup admission preserves raw presence and metadata versus contradictory typed caches" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cached = [_]m.TypedAttrValue{ .{ .literal = "typescript" }, .{ .binding = "source" }, .{ .equals = .{ .left = "first", .right = "second" } }, .{ .expression = .{ .inner = "first + second" } }, .{ .message = .{ .tag = "input", .payload = "title" } }, .invalid };
    for ([_][]const u8{
        "<code source=\"{source}\" line-numbers editable wrap/>",
        "<code source=\"{source}\" line-numbers=\"{first}\" editable=\"{second}\" wrap=\"{yes}\"/>",
        "<code source=\"{source}\" added-lines=\"1\" removed-lines=\"{diff}\"/>",
        "<video controls autoplay loop muted/>",
        "<video controls=\"{first}\" autoplay=\"{second}\" loop=\"{yes}\" muted=\"false\"/>",
        "<markdown source=\"{source}\" on-link=\"link\" on-details=\"details\" details-expanded=\"{flags}\" images=\"{images}\" issue-link-base=\"\"/>",
    }) |source| for (cached) |value| {
        const doc = try document(arena.allocator(), source, false);
        for (0..doc.root.?.attrs.len) |index| {
            const attrs = try arena.allocator().dupe(m.MarkupAttr, doc.root.?.attrs);
            const cache = try arena.allocator().create(m.TypedAttrValue);
            cache.* = value;
            attrs[index].typed = cache;
            var changed = doc;
            changed.root.?.attrs = attrs;
            const allocations = try compare(changed, .{}, unlimited, unlimited);
            const resizes = last_resizes;
            for (0..allocations + 1) |failure| _ = try compare(changed, .{}, failure, unlimited);
            for (0..resizes + 1) |failure| _ = try compare(changed, .{}, unlimited, failure);
        }
    };
}
