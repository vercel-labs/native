const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const m = sdk.canvas.ui_markup;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 107) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn aliases(a: m.MarkupNode, b: m.MarkupNode) anyerror!void {
    try exact(@intFromPtr(a.name.ptr), @intFromPtr(b.name.ptr));
    try exact(@intFromPtr(a.text.ptr), @intFromPtr(b.text.ptr));
    for (a.attrs, b.attrs) |left, right| {
        try exact(@intFromPtr(left.name.ptr), @intFromPtr(right.name.ptr));
        try exact(@intFromPtr(left.value.ptr), @intFromPtr(right.value.ptr));
    }
    for (a.children, b.children) |left, right| try aliases(left, right);
}
fn documents(a: m.MarkupDocument, b: m.MarkupDocument) !void {
    try exact(a, b);
    for (a.imports, b.imports) |left, right| try aliases(left, right);
    for (a.templates, b.templates) |left, right| try aliases(left, right);
    if (a.root) |root| try aliases(root, b.root.?);
}
fn compare(source: []const u8, index: usize, line: usize, column: usize, failure: usize, resize_failure: usize) !void {
    defer core.rt.frameReset();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    var a = m.Parser.init(fa.allocator(), source);
    a.index = index;
    a.line = line;
    a.column = column;
    a.diagnostic = .{ .line = 7, .column = 9, .message = "previous", .path = "prior.native" };
    var b = a;
    b.arena = fb.allocator();
    const left = a.parse();
    const right = b.parseWithPolicy(observed);
    if (left) |document| try documents(document, try right) else |err| try std.testing.expectError(err, right);
    try exact(a.index, b.index);
    try exact(a.line, b.line);
    try exact(a.column, b.column);
    try exact(a.diagnostic, b.diagnostic);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    try exact(fa.allocated_bytes, fb.allocated_bytes);
    try exact(fa.freed_bytes, fb.freed_bytes);
    try exact(fa.has_induced_failure, fb.has_induced_failure);
}
fn check(source: []const u8) !void {
    try compare(source, 0, 1, 1, std.math.maxInt(usize), std.math.maxInt(usize));
}
test "compiled markup document preserves complete trees byte spans diagnostics and borrowed aliases" {
    _ = core.initialModel();
    const corpus = [_][]const u8{
        "",                                                                                       " \t\r\n",                                          "<!-- empty -->",                                         "<!--",                                                           "<row/>",                    "<row /> <!--",                "<row></row>",                "<text>  hi  </text>",
        "<row a b=\"\" c=\"\x00\xff\r\t\" a=\"repeat\"/>",                                        "<row a=\"x\"b=\"y\"/>",                            "<0_-/> id",                                              "<Row/>",                                                         "text",                      "<",                           "</row>",                     "<row",
        "<row a",                                                                                 "<row a=",                                          "<row a=x/>",                                             "<row a='x'/>",                                                   "<row a=\"x",                "<row a=\"x\ny\"/>",           "<row / >",
        "<row><text>  \n \t Café \xff\x00 \r\n</text></row>",
        "<row><text>x</row>",                                                                     "<row><text/>",                                     "<row></row",                                             "<row></ row>",                                                   "<row></ROW>",               "<row></col>",                 "<row><!--",                  "<row> <!--x--> \n<text/> <!--y--> </row>",
        "<row/><text/>",                                                                          "<text>A <span>B</span> C<span>D</span>.</text>",   "<text> <span>A</span><!-- x --> <span>B</span> </text>", "<text><span>A</span><!-- x --><span>B</span></text>",            "<text>A<!-- x -->B</text>", "<text>A <!-- x --> B</text>", "<import src=\"p.native\"/>", "<template name=\"x\"><text>x</text></template>",
        "<import src=\"p.native\"/><template name=\"x\"><slot/></template><use template=\"x\"/>", "<template name=\"x\"/><import src=\"p.native\"/>", "<template name=\"x\"/><import src=\"p.native\"/><",      "<row><for/><if/><else/><template/><use/><import/><slot/></row>",
    };
    calls = 0;
    for (corpus) |source| try check(source);
    try std.testing.expect(calls == corpus.len * 2);
    try compare("skip<row a=\"x\"/>", 4, 8, 13, std.math.maxInt(usize), std.math.maxInt(usize));
    try compare("<row/>", 6, 2, 7, std.math.maxInt(usize), std.math.maxInt(usize));
}
test "compiled markup document preserves every allocation failure before syntax and separator publication" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<import src=\"p\"/><template name=\"t\"/><row a=\"1\"><text a b c d e f g h i j k l>A <span>B</span> C <span>D</span></text><row><row/></row></row>",
        "<import src=\"p\"/><template name=\"t\"/><row a=\"1\"><text>A <span>B</span> C</text><row><bad a=\"x\" b=\"unterminated",
    }) |source| for (0..32) |failure| for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |resize_failure| {
        try compare(source, 0, 1, 1, failure, resize_failure);
    };
}
test "compiled markup document preserves all byte classes and malformed document corpus" {
    _ = core.initialModel();
    var buffer: [192]u8 = undefined;
    for (0..256) |byte| {
        for ([_][]const u8{ "<r a=\"{c}\"/>", "<text>{c}</text>", "<r{c}/>", "<r><!--{c}--></r>" }) |format| {
            // Runtime format is intentionally assembled without a formatter
            // interpreting malformed source bytes.
            const at = std.mem.indexOf(u8, format, "{c}").?;
            @memcpy(buffer[0..at], format[0..at]);
            buffer[at] = @intCast(byte);
            @memcpy(buffer[at + 1 ..][0 .. format.len - at - 3], format[at + 3 ..]);
            try check(buffer[0 .. format.len - 2]);
        }
    }
    const alphabet = "abc012_-<>/!=\"' \t\r\n\x00\xff";
    var bits: u32 = 0x5ab74c93;
    for (0..2048) |i| {
        const len = i % buffer.len;
        for (buffer[0..len]) |*byte| {
            bits = bits *% 1664525 +% 1013904223;
            byte.* = alphabet[bits % alphabet.len];
        }
        try check(buffer[0..len]);
    }
}
test "compiled markup document preserves template limits repeated attributes and large source" {
    _ = core.initialModel();
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..257) |i| {
        try source.appendSlice(std.testing.allocator, "<template name=\"t\"/>");
        if (i >= 254) try check(source.items);
    }
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "<row");
    for (0..1024) |_| try source.appendSlice(std.testing.allocator, " a=\"same\"");
    try source.appendSlice(std.testing.allocator, "/>");
    try check(source.items);
    source.clearRetainingCapacity();
    try source.appendSlice(std.testing.allocator, "<text>\n");
    try source.appendNTimes(std.testing.allocator, 'x', 65537);
    try source.appendSlice(std.testing.allocator, " <span>y</span> z</text>");
    try check(source.items);
    source.clearRetainingCapacity();
    for (0..128) |_| try source.appendSlice(std.testing.allocator, "<row>");
    for (0..128) |_| try source.appendSlice(std.testing.allocator, "</row>");
    try check(source.items);
}
test "compiled markup document owns imported parsing and preserves closure errors and source paths" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const files = [_]m.SourceFile{
        .{ .path = "app.native", .source = "<import src=\"parts.native\"/><row><use template=\"part\"/></row>" },
        .{ .path = "parts.native", .source = "<import src=\"shared.native\"/><template name=\"part\"><text>A <span>B</span> C</text></template>" },
        .{ .path = "shared.native", .source = "<template name=\"shared\"><text>shared</text></template>" },
    };
    for ([_]?[]const u8{ null, "<template><bad</template>", "<import src=\"app.native\"/>", "<row/>" }) |broken| {
        var set = files;
        if (broken) |source| set[2].source = source;
        var loader: m.SourceSetLoader = .{ .set = &set };
        var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer aa.deinit();
        var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer ab.deinit();
        var da: m.MarkupErrorInfo = .{};
        var db = da;
        const a = m.resolveImports(aa.allocator(), "app.native", set[0].source, loader.loader(), &da);
        const before = calls;
        const b = m.resolveImportsWithPolicy(observed, ab.allocator(), "app.native", set[0].source, loader.loader(), &db);
        try std.testing.expect(calls > before);
        if (a) |document| try documents(document, try b) else |err| try std.testing.expectError(err, b);
        try exact(da, db);
        core.rt.frameReset();
    }
}
