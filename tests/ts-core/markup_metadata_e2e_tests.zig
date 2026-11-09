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
var trace: [64]i64 = undefined;
var trace_len: usize = 0;
const Model = struct {
    code: []const u8 = "const value = 42;\nreturn value;\n",
    diff: []const u8 = "+1-0__2, 2",
    icon: []const u8 = "app:not-registered",
    pub fn first(_: *const Model) f64 {
        trace[trace_len] = 1;
        trace_len += 1;
        return 20;
    }
    pub fn second(_: *const Model) f64 {
        trace[trace_len] = 2;
        trace_len += 1;
        return 30;
    }
};
const Msg = union(enum) { tick, input: c.TextInputEvent };
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
    errdefer std.debug.print("metadata parity failed: channel={d} source={s}\n", .{ mode, source });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |typed| {
        const doc = try document(arena.allocator(), source, typed);
        _ = try compare(doc, .{}, unlimited, unlimited, mode);
    }
}

fn icon(raw: []const u8) !void {
    for ([_][]const u8{ m.icon_name_message, m.button_icon_message, "custom base" }) |base| {
        const a = m.iconValueOf(raw, base);
        const b = View.MetadataTest.iconValue(observed, raw, base);
        try exact(a, b);
        switch (a) {
            .builtin, .app, .binding => |value| {
                const actual = switch (b) {
                    .builtin, .app, .binding => |text| text,
                    else => unreachable,
                };
                try std.testing.expectEqual(@intFromPtr(value.ptr), @intFromPtr(actual.ptr));
            },
            else => {},
        }
    }
}
test "compiled markup metadata retains complete icon grammar and borrowed raw bytes" {
    _ = core.initialModel();
    for (m.known_icon_names) |name| try icon(name);
    for ([_][]const u8{ "", "save", "Save", " save", "save ", "app:", "app:0", "app:a", "app:a-0", "app:a--b", "app:-a", "app:a-", "app:A", "app:a_b", "app:a:b", "other:save", ":", "app:\x00", "app:\xff", "{icon}", "{ icon.name }", "{a == b}", "{icon + 1}", "{}", "{", "{\ticon}", "\xc3\xa9" }) |raw| try icon(raw);
    const alphabet = "{} :.=a0\t";
    var bytes: [3]u8 = undefined;
    for (0..alphabet.len * alphabet.len * alphabet.len) |n| {
        bytes[0] = alphabet[n % alphabet.len];
        bytes[1] = alphabet[(n / alphabet.len) % alphabet.len];
        bytes[2] = alphabet[n / (alphabet.len * alphabet.len)];
        for (1..4) |len| try icon(bytes[0..len]);
    }
}
fn language(raw: []const u8) !void {
    const expected: ?c.code.Language = if (c.code.isLanguageName(raw)) c.code.languageFromName(raw) else null;
    try std.testing.expectEqual(expected, View.MetadataTest.language(observed, raw));
}
test "compiled markup metadata retains every language alias and ASCII trim boundary" {
    _ = core.initialModel();
    const aliases = "plain text zig jsx tsx js mjs javascript ts typescript json jsonc yaml yml sh bash zsh shell py python rs rust c h cc cpp c++ cs csharp java kotlin swift go golang html xml svg css scss less sql md markdown c_like unknown";
    var words = std.mem.splitScalar(u8, aliases, ' ');
    var buf: [100]u8 = undefined;
    while (words.next()) |word| {
        try language(word);
        const upper = std.ascii.allocUpperString(std.testing.allocator, word) catch unreachable;
        defer std.testing.allocator.free(upper);
        try language(upper);
        try language(try std.fmt.bufPrint(&buf, " \t\r\n{s}\n\r\t ", .{upper}));
    }
    for ([_][]const u8{ "", " ", "\x0bzig", "zig\x0c", "zig\x00", "\xff", "\xc5\xbfql", "{zig}", "java script" }) |raw| try language(raw);
}
fn lines(raw: []const u8) !void {
    var a: [c.code.max_diff_lines]usize = @splat(999);
    var b = a;
    const expected = c.code.parseLineNumberSpec(raw, &a);
    const actual = View.MetadataTest.lineNumbers(observed, raw, &b);
    try exact(expected, actual);
    try std.testing.expectEqualSlices(usize, &a, &b);
    if (actual) |value| try std.testing.expectEqual(@intFromPtr(b[0..].ptr), @intFromPtr(value.ptr));
}
test "compiled markup metadata retains exact usize conversion author order and partial line writes" {
    _ = core.initialModel();
    for ([_][]const u8{ "", " \t\r\n", "1", "128", "1-128", "128,1-128", "3,1-4,2", "+1", "0__1-0_2", "1,2,", "1,2,,3", "0", "129", "-0", "-1", "2-1", "1--2", "1-2-3", "1-", "1-\n2", "1\n-2", "1-\t2", "1\r,2", "1_", "_1", "+_1", "+", "++1", "1 2", "0x1", "1,18446744073709551615", "1,18446744073709551616", "1,99999999999999999999999999999", "1,00000000000000000000000000001", "1,\xff", "1,2\x00", "1,\xc2\xa0", "1,2\x0b" }) |raw| try lines(raw);
    const alphabet = "01+_-, \t\n";
    var bytes: [3]u8 = undefined;
    for (0..alphabet.len * alphabet.len * alphabet.len) |n| {
        bytes[0] = alphabet[n % alphabet.len];
        bytes[1] = alphabet[(n / alphabet.len) % alphabet.len];
        bytes[2] = alphabet[n / (alphabet.len * alphabet.len)];
        for (1..4) |len| try lines(bytes[0..len]);
    }
}
test "compiled markup metadata preserves complete builders cached distinctions and failure effects" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column><icon name=\"save\"/><icon name=\"app:not-registered\"/><icon name=\"{icon}\"/><button icon=\"save\" label=\"Save\"/><timeline><timeline-item title=\"Entry\" icon=\"app:wave\"/></timeline><code source=\"{code}\" language=\" TSX \" added-lines=\"+1-0__2\" removed-lines=\"{diff}\" label=\"Code\"/></column>",
        "<icon name=\"app:Bad\"/>",
        "<icon name=\"other:save\"/>",
        "<icon name=\"missing\"/>",
        "<timeline><timeline-item title=\"Entry\" icon=\"app:a--b\"/></timeline>",
        "<code source=\"{code}\" width=\"{first}\" language=\"unknown\" height=\"{second}\" label=\"Code\"/>",
        "<code source=\"{code}\" width=\"{first}\" added-lines=\"1,2,\" height=\"{second}\" label=\"Code\"/>",
        "<code source=\"{code}\" added-lines=\"{diff}\" removed-lines=\"3,2-1\" label=\"Code\"/>",
    }) |source| try check(source, 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "<icon name=\"save\"/>", "<button icon=\"save\" label=\"Save\"/>", "<code source=\"{code}\" language=\"unknown\" added-lines=\"{diff}\" label=\"Code\"/>" }) |source| {
        const doc = try document(arena.allocator(), source, false);
        const attrs = try arena.allocator().dupe(m.MarkupAttr, doc.root.?.attrs);
        const cached = try arena.allocator().create(m.TypedAttrValue);
        cached.* = .{ .literal = "zig" };
        for (attrs) |*attr| if (std.mem.eql(u8, attr.name, "name") or std.mem.eql(u8, attr.name, "icon") or std.mem.eql(u8, attr.name, "language")) {
            attr.typed = cached;
        };
        var altered = doc;
        altered.root.?.attrs = attrs;
        _ = try compare(altered, .{}, unlimited, unlimited, 0);
    }
    for ([_]usize{ 14, 16, 17, 18 }) |mode| try std.testing.expect(operations[mode] > 0);
}
test "compiled markup metadata preserves all builder allocation and resize failures" {
    _ = core.initialModel();
    const source = "<column><icon name=\"app:wave\"/><button label=\"Save\" icon=\"{icon}\"/><timeline><timeline-item title=\"Entry\" icon=\"save\"/></timeline><code source=\"{code}\" language=\"JSX\" added-lines=\"3,1-2\" removed-lines=\"{diff}\" label=\"Code\"/></column>";
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
