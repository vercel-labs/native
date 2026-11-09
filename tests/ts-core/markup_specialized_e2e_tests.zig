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
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 112) operations[input[2]] += 1;
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
var trace: [2048]i64 = undefined;
var trace_len: usize = 0;
fn event(n: i64) void {
    trace[trace_len] = n;
    trace_len += 1;
}
const Row = struct { id: i64, title: []const u8 };
const Model = struct {
    title: []const u8 = "Borrowed\x00\xff",
    body: []const u8 = "# Title\n\nText [link](https://example.com)\n\n<details><summary>Summary</summary>Body</details>\n\n![alt](sample)",
    code: []const u8 = "const value = 42;\nreturn value;\n",
    diff: []const u8 = "1-2",
    flags: []const bool = &.{ true, false },
    images: []const c.markdown.ResolvedImage = &.{.{ .source = "sample", .image = 18446744073709551615, .width = 20, .height = 10 }},
    levels: []const f32 = &.{ 1, 3, 2 },
    doubles: []const f64 = &.{ 0.25, 3.5, 1.125 },
    labels: []const []const u8 = &.{ "One", "Two", "Three" },
    rows_data: []const Row = &.{ .{ .id = -9223372036854775808, .title = "First" }, .{ .id = 9223372036854775807, .title = "Second" } },
    active: i64 = -1,
    id: i64 = 9223372036854775807,
    yes: bool = true,
    fraction: f64 = 0.5,
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
    pub fn rows(self: *const Model, range: c.VirtualListRange) []const Row {
        event(4);
        event(@intCast(range.start_index));
        event(@intCast(range.end_index));
        event(@intFromFloat(range.item_extent * 10));
        event(@intFromFloat(range.item_gap * 10));
        event(@intFromFloat(range.scroll_offset * 10));
        event(@intFromFloat(range.layout_offset * 10));
        event(@intFromFloat(range.content_extent * 10));
        event(@intFromFloat(range.before_extent * 10));
        event(@intFromFloat(range.after_extent * 10));
        event(@intFromFloat(range.anchor_extent * 10));
        return self.rows_data[range.start_index..range.end_index];
    }
    pub fn short(self: *const Model, _: c.VirtualListRange) []const Row {
        event(5);
        return self.rows_data[0..0];
    }
    pub fn virtualExtentHelper(name: []const u8) ?u32 {
        event(6);
        return if (std.mem.eql(u8, name, "estimate")) 0 else null;
    }
    pub fn virtualExtentEstimate(_: ?*const anyopaque, _: u64) f32 {
        event(7);
        return 10.5;
    }
};
const Msg = union(enum) { tick, pick: i64, input: c.TextInputEvent, link: []const u8, details: usize };
const Ui = c.Ui(Msg);
const View = c.MarkupView(Model, Msg);
const unlimited = std.math.maxInt(usize);
var last_resizes: usize = 0;
fn compare(doc: m.MarkupDocument, mode: u8, failure: usize, resize: usize) !usize {
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
    const model: Model = .{};
    trace_len = 0;
    const left = View.SpecializedTest.run(&a, &ui_a, &model, mode);
    const before = trace;
    const length = trace_len;
    trace_len = 0;
    const right = View.SpecializedTest.run(&b, &ui_b, &model, mode);
    try exact(before[0..length], trace[0..trace_len]);
    try exact(left, right);
    if (left.node) |node| {
        const ltree = ui_a.finalize(node);
        const rtree = ui_b.finalize(right.node.?);
        if (ltree) |tree| try exact(tree, try rtree) else |err| try std.testing.expectError(err, rtree);
    }
    if (left.series) |series| {
        if (series.values.ptr == model.levels.ptr) try std.testing.expectEqual(@intFromPtr(series.values.ptr), @intFromPtr(right.series.?.values.ptr));
        if (series.label.ptr == model.title.ptr) try std.testing.expectEqual(@intFromPtr(series.label.ptr), @intFromPtr(right.series.?.label.ptr));
    }
    if (left.span) |span| if (span.text.ptr == model.title.ptr) {
        try std.testing.expectEqual(@intFromPtr(span.text.ptr), @intFromPtr(right.span.?.text.ptr));
    };
    try exact(ui_a.video_declaration, ui_b.video_declaration);
    try exact(ui_a.virtualWindows(), ui_b.virtualWindows());
    try exact(a.diagnostic, b.diagnostic);
    try exact(ui_a.failed, ui_b.failed);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    last_resizes = fa.resize_index;
    return fa.alloc_index;
}
fn check(source: []const u8, mode: u8, failures: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        var parser = m.Parser.init(arena.allocator(), source);
        const raw = try parser.parse();
        const doc = if (typed) try m.canonicalize(arena.allocator(), raw) else raw;
        const allocations = try compare(doc, mode, unlimited, unlimited);
        const resizes = last_resizes;
        if (failures) {
            for (0..allocations + 1) |i| _ = try compare(doc, mode, i, unlimited);
            for (0..resizes + 1) |i| _ = try compare(doc, mode, unlimited, i);
        }
    }
}
const corpus = [_][]const u8{
    "<markdown source=\"{body}\" on-link=\"link\" on-details=\"details\" details-expanded=\"{flags}\" images=\"{images}\" issue-link-base=\"https://example.com/issues/\"/>",
    "<code source=\"{code}\" language=\"typescript\" line-numbers editable on-input=\"input\" added-lines=\"1\" added-lines=\"{diff}\" removed-lines=\"2\" wrap=\"{yes}\" width=\"{first}\" height=\"{second}\" min-width=\"10\" grow=\"1\" key=\"{id}\" global-key=\"code\" label=\"Editor\"/>",
    "<stepper active=\"{active}\" key=\"steps\" global-key=\"{id}\" label=\"Stages\"><step>Start {title}</step><step>Finish</step></stepper>",
    "<input-group label=\"Composer\" width=\"{first}\" height=\"{second}\" min-width=\"10\" grow=\"1\" key=\"{id}\" global-key=\"composer\"><textarea label=\"Message\" text=\"{title}\" on-input=\"input\"/><input-group-actions gap=\"{first}\" key=\"actions\" global-key=\"{id}\"><if test=\"{yes}\"><button on-press=\"tick\">Send</button></if></input-group-actions></input-group>",
    "<timeline gap=\"{first}\" grow=\"{second}\" key=\"{id}\" global-key=\"ledger\" label=\"Ledger\"><for each=\"rows_data\" as=\"row\"><timeline-item title=\"{row.title}\" description=\"Description\" meta=\"Meta\" indicator=\"!\" icon=\"save\" variant=\"primary\" connector=\"{yes}\" selected=\"false\" on-press=\"pick:{row.id}\" key=\"{row.id}\" global-key=\"record\"/></for></timeline>",
    "<chart y-min=\"{first}\" y-max=\"{second}\" grid-lines=\"255\" baseline=\"{yes}\" x-labels=\"{labels}\" y-labels=\"false\" hover-details=\"true\" stroke-width=\"1.5\" width=\"400\" height=\"200\" grow=\"1\" padding=\"4\" key=\"{id}\" global-key=\"plot\" label=\"Plot\"><series kind=\"area\" kind=\"line\" values=\"{levels}\" color=\"accent\" label=\"{title}\"/><series kind=\"bar\" values=\"{doubles}\" color=\"primary\" label=\"Second\"/></chart>",
    "<video src=\"sample.mp4\" controls autoplay loop=\"false\" muted=\"{yes}\" width=\"{first}\" height=\"{second}\" grow=\"1\" label=\"Media\" key=\"{id}\" global-key=\"video\"/>",
    "<text>Leading <span weight=\"bold\" scale=\"{first}\" mono=\"{yes}\" italic=\"false\" underline=\"{yes}\" foreground=\"primary\">{title}</span> trailing</text>",
    "<virtual-window id=\"rows\" as=\"window\" item-count=\"{count}\" item-extent=\"10.5\" gap=\"{first}\" overscan=\"0\" viewport-fallback=\"100\" index-base=\"0\" anchor=\"trailing\"><virtual-list window=\"window\" each=\"rows\" as=\"row\" width=\"100\" height=\"100\" min-width=\"10\" grow=\"1\" padding=\"2\" background=\"surface\" label=\"Rows\"><text key=\"{row.id}\">{row.title}</text></virtual-list></virtual-window>",
    "<virtual-window id=\"variable\" as=\"window\" item-count=\"2\" extent-estimate=\"estimate\" viewport-fallback=\"100\"><virtual-list window=\"window\" each=\"rows\" as=\"row\"><text key=\"{row.id}\">{row.title}</text></virtual-list></virtual-window>",
    "<template name=\"steps\" args=\"active\"><stepper active=\"{active}\"><slot/></stepper></template><column><for each=\"rows_data\" as=\"row\"><use template=\"steps\" active=\"1\"><step>{row.title}</step><step>{title}</step></use></for></column>",
    "<template name=\"record\"><timeline-item title=\"Record\" on-press=\"tick\"/></template><use template=\"record\" on-press=\"pick:{id}\"/>",
};
test "compiled markup specialized preserves all fourteen builders complete trees handlers declarations and allocation failures" {
    _ = core.initialModel();
    operations = @splat(0);
    for (corpus) |source| try check(source, 0, true);
    for (operations[0..20]) |count| try std.testing.expect(count > 0);
}
test "compiled markup specialized preserves borrowed series buffers raw spans and consumed publication before later errors" {
    _ = core.initialModel();
    try check("<series kind=\"area\" kind=\"line\" values=\"{levels}\" label=\"{title}\"/>", 2, true);
    try check("<series values=\"{doubles}\"/>", 2, true);
    try check("<span>{title}</span>", 1, true);
    try check("<text wrap=\"true\"><span>text</span></text>", 3, true);
    for ([_][]const u8{ "<virtual-list window=\"window\"/>", "<virtual-list window=\"window\" each=\"rows\"/>", "<virtual-list window=\"window\" each=\"rows\" as=\"row\"/>", "<virtual-list window=\"window\" each=\"rows\" as=\"row\"><text>unkeyed</text></virtual-list>" }) |source| try check(source, 4, true);
}

test "compiled markup specialized preserves native negative corpus diagnostic order and allocation failures" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<column>\n  <markdown on-link=\"open_url\" />\n</column>",
        "<column>\n  <markdown source=\"# hi\" />\n</column>",
        "<column>\n  <markdown source=\"{opened_count}\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" on-link=\"refresh\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" on-link=\"open_url:{body}\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" on-details=\"refresh\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" details-expanded=\"{body}\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" gap=\"8\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\">text</markdown>\n</column>",
        "<column>\n  <markdown source=\"# literal\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" on-details=\"toggle:{body}\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" details-expanded=\"literal\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" padding=\"8\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\"><text>x</text></markdown>\n</column>",
        "<code language=\"zig\" />",
        "<code source=\"literal\" />",
        "<code source=\"{count}\" />",
        "<code source=\"{snippet}\" language=\"brainwave\" />",
        "<code source=\"{snippet}\" added-lines=\"0\" />",
        "<code source=\"{snippet}\" removed-lines=\"4-2\" />",
        "<code source=\"{snippet}\" removed-lines=\"{count}\" />",
        "<code source=\"{snippet}\" padding=\"8\" />",
        "<code source=\"{snippet}\">text</code>",
        "<row>\n  <video src=\"a.mp4\"><text>Caption</text></video>\n</row>",
        "<row>\n  <video src=\"a.mp4\" gap=\"4\"/>\n</row>",
        "<row>\n  <video src=\"{count}\"/>\n</row>",
        "<column>\n  <chart>\n    <series values=\"{names}\" />\n  </chart>\n</column>",
        "<column>\n  <chart>\n    <series values=\"{limit}\" />\n  </chart>\n</column>",
        "<column>\n  <chart>\n    <series kind=\"bar\" />\n  </chart>\n</column>",
        "<column>\n  <chart>\n    <series kind=\"band\" values=\"{latency}\" />\n  </chart>\n</column>",
        "<column>\n  <chart gap=\"8\">\n    <series values=\"{latency}\" />\n  </chart>\n</column>",
        "<column>\n  <chart on-press=\"refresh\">\n    <series values=\"{latency}\" />\n  </chart>\n</column>",
        "<column>\n  <chart />\n</column>",
        "<column>\n  <chart>\n    <text>x</text>\n  </chart>\n</column>",
        "<column>\n  <chart>\n    <series values=\"{latency}\" fill=\"true\" />\n  </chart>\n</column>",
        "<column>\n  <chart>\n    <series values=\"{latency}\" color=\"magenta\" />\n  </chart>\n</column>",
        "<column>\n  <input-group label=\"Composer\">\n    <input-group-actions>\n      <button icon=\"send\" label=\"Send\" on-press=\"send\"></button>\n    </input-group-actions>\n  </input-group>\n</column>",
        "<column>\n  <input-group label=\"Composer\" />\n</column>",
        "<column>\n  <input-group>\n    <textarea label=\"A\" placeholder=\"a\" />\n    <textarea label=\"B\" placeholder=\"b\" />\n  </input-group>\n</column>",
        "<column>\n  <input-group>\n    <textarea label=\"A\" placeholder=\"a\" />\n    <text>hint</text>\n  </input-group>\n</column>",
        "<column>\n  <input-group gap=\"8\">\n    <textarea label=\"A\" placeholder=\"a\" />\n  </input-group>\n</column>",
        "<column>\n  <input-group>\n    <textarea label=\"A\" placeholder=\"a\" />\n    <input-group-actions padding=\"4\">\n      <button icon=\"send\" label=\"Send\" on-press=\"send\"></button>\n    </input-group-actions>\n  </input-group>\n</column>",
        "<column>\n  <input-group-actions>\n    <button icon=\"send\" label=\"Send\" on-press=\"send\"></button>\n  </input-group-actions>\n</column>",
        "<column>\n  <span>alone</span>\n</column>",
        "<column>\n  <badge><span>styled</span></badge>\n</column>",
        "<column>\n  <list-item label=\"Row\"><span>styled</span></list-item>\n</column>",
        "<text><span size=\"sm\">x</span></text>",
        "<text><span on-press=\"noop\">x</span></text>",
        "<text><span weight=\"heavy\">x</span></text>",
        "<text><span scale=\"0\">x</span> y</text>",
        "<text><span scale=\"-1.5\">x</span> y</text>",
        "<text><span scale=\"huge\">x</span> y</text>",
        "<text><span><span>x</span></span></text>",
        "<text><span weight=\"bold\"/> x</text>",
        "<text><span foreground=\"reddish\">x</span></text>",
        "<text><span>a</span><if test=\"{fixed_width}\"><text>b</text></if></text>",
        "<text wrap=\"true\"><span>x</span> y</text>",
        "<text overflow=\"clip\"><span>x</span> y</text>",
    }) |source| try check(source, 0, true);
}
test "compiled markup specialized keeps late failures after callbacks child work and restored scopes" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<input-group width=\"{first}\"><textarea label=\"Entry\" text=\"{second}\"/><column/></input-group>",
        "<chart width=\"{first}\"><series values=\"{doubles}\"/><text>bad</text></chart>",
        "<chart width=\"{first}\" on-press=\"tick\"/>",
        "<code width=\"{first}\" source=\"{code}\" added-lines=\"1\" added-lines=\"bad\"/>",
        "<code width=\"{first}\"><text>bad</text></code>",
        "<stepper active=\"{active}\"><step>{first}</step><step bad=\"1\">bad</step></stepper>",
        "<template name=\"steps\" args=\"active\"><stepper active=\"{active}\"><slot/></stepper></template><column><for each=\"rows_data\" as=\"row\"><use template=\"steps\" active=\"1\"><step>{row.title}</step><step>{missing}</step></use></for></column>",
        "<virtual-window id=\"rows\" as=\"window\" item-count=\"{count}\" item-extent=\"{first}\" gap=\"{second}\" viewport-fallback=\"100\"><virtual-list window=\"window\" each=\"short\" as=\"row\"><text key=\"{row.id}\">{row.title}</text></virtual-list></virtual-window>",
        "<virtual-window id=\"rows\" as=\"window\" item-count=\"{count}\" item-extent=\"{first}\" gap=\"{second}\" viewport-fallback=\"100\"><column><virtual-list window=\"window\" each=\"rows\" as=\"row\"><text key=\"{row.id}\">{row.title}</text></virtual-list><virtual-list window=\"window\"/></column></virtual-window>",
        "<virtual-window id=\"rows\" as=\"window\" item-count=\"9007199254740991\" item-extent=\"{first}\" index-base=\"1\" extent-estimate=\"estimate\"><text>range</text></virtual-window>",
        "<virtual-window id=\"rows\" as=\"window\" item-count=\"{count}\" item-extent=\"{first}\"><virtual-window id=\"nested\" as=\"nested\"><column/></virtual-window></virtual-window>",
        "<text>leading {first}<span scale=\"0\">bad</span></text>",
        "<chart grid-lines=\"256\"><series values=\"{levels}\"/></chart>",
        "<chart grid-lines=\"-1\"><series values=\"{levels}\"/></chart>",
        "<chart grid-lines=\"0.5\"><series values=\"{levels}\"/></chart>",
        "<video controls=\"{first}\" src=\"{title}\" controls=\"false\"/>",
    }) |source| try check(source, 0, true);
}

test "compiled markup specialized restores complete initialized lexical entries after slotted and virtual failures" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model: Model = .{};
    for ([_][]const u8{
        "<template name=\"steps\"><stepper active=\"1\"><slot/></stepper></template><column><for each=\"rows_data\" as=\"row\"><use template=\"steps\"><step>{row.title}</step><step>{missing}</step></use></for></column>",
        "<virtual-window id=\"rows\" as=\"window\" item-count=\"2\" item-extent=\"10\" viewport-fallback=\"100\"><virtual-list window=\"window\" each=\"rows\" as=\"row\"><text key=\"{row.id}\">{missing}</text></virtual-list></virtual-window>",
        "<virtual-window id=\"rows\" as=\"window\"><column/></virtual-window>",
    }) |source| {
        var parser = m.Parser.init(arena.allocator(), source);
        const doc = try parser.parse();
        for ([_]usize{ 0, 15, 16 }) |length| {
            var ui_a = Ui.init(arena.allocator());
            var ui_b = Ui.init(arena.allocator());
            ui_b.expression_policy = observed;
            var a = View.fromDocument(doc);
            var b = View.fromDocument(doc);
            trace_len = 0;
            const left = View.ConstructionTest.run(&a, &ui_a, &model, length, 0, 0, null);
            const before = trace;
            const count = trace_len;
            trace_len = 0;
            const right = View.ConstructionTest.run(&b, &ui_b, &model, length, 0, 0, null);
            try exact(before[0..count], trace[0..trace_len]);
            try exact(left.node, right.node);
            try exact(left.failure, right.failure);
            try exact(left.scope.entries, right.scope.entries);
            try exact(left.scope.len, right.scope.len);
            try exact(left.scope.floor, right.scope.floor);
            try exact(left.scope.use_depth, right.scope.use_depth);
            try exact(left.scope.template_ctx, right.scope.template_ctx);
            try exact(left.scope.source_chain, right.scope.source_chain);
            try exact(a.diagnostic, b.diagnostic);
        }
    }
}
