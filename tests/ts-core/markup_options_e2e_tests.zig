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
    values: []const f32 = &.{ 1, 2, 3 },
    weight: []const u8 = "bold",
    role: []const u8 = "button",
    variant: []const u8 = "primary",
    scale: f64 = 1.5,
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

fn enumCase(comptime T: type, raw: []const u8) !void {
    try std.testing.expectEqual(std.meta.stringToEnum(T, raw), View.OptionTest.enumValue(T, observed, raw));
}
test "compiled markup options select every reflected enum with exact raw bytes" {
    _ = core.initialModel();
    inline for (.{ c.TextSpanWeight, c.TextSpanColor, c.WidgetVariant, c.ChartSeriesColor, c.TextAlign, c.WidgetRole }) |T| {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            try enumCase(T, field.name);
            try enumCase(T, " " ++ field.name);
            try enumCase(T, field.name ++ "\x00");
            const upper = try std.ascii.allocUpperString(std.testing.allocator, field.name);
            defer std.testing.allocator.free(upper);
            try enumCase(T, upper);
        }
        for ([_][]const u8{ "", "unknown", "\xff", "\xc3\xa9", "{weight}", "end ", "\tbold" }) |raw| try enumCase(T, raw);
        var raw: [1]u8 = undefined;
        for (0..256) |byte| {
            raw[0] = @intCast(byte);
            try enumCase(T, &raw);
        }
    }
}
test "compiled markup options admit chart aliases without admitting builder-only bands" {
    _ = core.initialModel();
    for ([_][]const u8{ "line", "area", "bar", "band", "Line", "AREA", " line", "area ", "", "{values}", "line\x00", "\xff" }) |raw| {
        const result = View.OptionTest.seriesKind(observed, raw);
        if (std.mem.eql(u8, raw, "line") or std.mem.eql(u8, raw, "area")) {
            try std.testing.expectEqual(c.ChartSeriesKind.line, result.?.kind);
            try std.testing.expectEqual(std.mem.eql(u8, raw, "area"), result.?.fill);
        } else if (std.mem.eql(u8, raw, "bar")) {
            try std.testing.expectEqual(c.ChartSeriesKind.bar, result.?.kind);
            try std.testing.expect(!result.?.fill);
        } else try std.testing.expect(result == null);
    }
}
fn scaleBits(bits: u32) !void {
    const value: f32 = @bitCast(bits);
    try std.testing.expectEqual(std.math.isFinite(value) and value > 0, View.OptionTest.spanScale(observed, value));
}
test "compiled markup options preserve finite positive scale admission after f32 conversion" {
    _ = core.initialModel();
    for ([_]u32{ 0, 1, 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x7fffffff, 0x80000000, 0x80000001, 0xff7fffff, 0xff800000, 0xff800001, 0xffffffff }) |bits| try scaleBits(bits);
    var random: u32 = 0x726f6c65;
    for (0..4096) |_| {
        random = random *% 1664525 +% 1013904223;
        try scaleBits(random);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try document(arena.allocator(), "<text><span scale=\"{scale}\">Scaled</span></text>", false);
    for ([_]f64{ 0, -0.0, -1, 1e-50, 1e-45, 1.5, 1e39, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |value| _ = try compare(doc, .{ .scale = value }, unlimited, unlimited, 0);
}
test "compiled markup options preserve input channels cached distinctions diagnostics and eager effects" {
    _ = core.initialModel();
    operations = @splat(0);
    for ([_][]const u8{
        "<column role=\"{role}\"><text><span weight=\"{weight}\" foreground=\"success\" scale=\"{scale}\">Styled</span></text><timeline><timeline-item title=\"Ready\" variant=\"{variant}\"/></timeline><chart><series kind=\"area\" values=\"{values}\" color=\"info\"/></chart><bubble><text>Body</text><reactions text-alignment=\"start\">React</reactions></bubble></column>",
        "<text><span weight=\"unknown\" scale=\"{second}\">Styled</span></text>",
        "<text><span foreground=\"{weight}\">Styled</span></text>",
        "<text><span weight=\"{first}\">Styled</span></text>",
        "<text><span scale=\"{first}\" weight=\"unknown\" mono=\"{second}\">Styled</span></text>",
        "<timeline><timeline-item title=\"{first}\" variant=\"unknown\" meta=\"{second}\"/></timeline>",
        "<timeline><timeline-item title=\"Ready\" variant=\"unknown\" meta=\"{second}\"/></timeline>",
        "<timeline><timeline-item title=\"Ready\" variant=\"{first}\"/></timeline>",
        "<chart><series kind=\"band\" values=\"{values}\" label=\"{second}\"/></chart>",
        "<chart><series kind=\"{variant}\" values=\"{values}\"/></chart>",
        "<chart><series values=\"{values}\" color=\"{weight}\"/></chart>",
        "<chart><series values=\"{values}\" color=\"unknown\" label=\"{second}\"/></chart>",
        "<chart><series kind=\"area\" kind=\"bar\" kind=\"line\" values=\"{values}\"/></chart>",
        "<bubble><text>Body</text><reactions text-alignment=\"{weight}\">React</reactions></bubble>",
        "<column width=\"{first}\" role=\"unknown\" height=\"{second}\"/>",
        "<column role=\"{first}\" height=\"{second}\"/>",
    }) |source| try check(source, 0);
    // Raw foreground/alignment and cached literal/expression channels deliberately differ.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "<column role=\"unknown\"/>", "<chart><series kind=\"unknown\" values=\"{values}\" color=\"unknown\"/></chart>", "<text><span weight=\"unknown\" foreground=\"unknown\">x</span></text>" }) |source| {
        var doc = try document(arena.allocator(), source, false);
        const root = &doc.root.?;
        const target = if (root.children.len > 0) @constCast(&root.children[0]) else root;
        const attrs = try arena.allocator().dupe(m.MarkupAttr, target.attrs);
        for (attrs) |*attr| {
            if (std.mem.eql(u8, attr.name, "values")) continue;
            const cached = try arena.allocator().create(m.TypedAttrValue);
            cached.* = .{ .literal = if (std.mem.eql(u8, attr.name, "role")) "button" else if (std.mem.eql(u8, attr.name, "weight")) "bold" else if (std.mem.eql(u8, attr.name, "kind")) "area" else "accent" };
            attr.typed = cached;
        }
        target.attrs = attrs;
        _ = try compare(doc, .{}, unlimited, unlimited, 0);
    }
    for ([_]usize{ 15, 19, 20 }) |mode| try std.testing.expect(operations[mode] > 0);
}
test "compiled markup options preserve every observed builder allocation and resize failure" {
    _ = core.initialModel();
    const source = "<column role=\"{role}\"><text><span weight=\"{weight}\" foreground=\"success\" scale=\"{scale}\">Styled</span></text><timeline><timeline-item title=\"Ready\" variant=\"{variant}\"/></timeline><chart><series kind=\"area\" values=\"{values}\" color=\"info\"/></chart><bubble><text>Body</text><reactions text-alignment=\"end\">React</reactions></bubble></column>";
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
