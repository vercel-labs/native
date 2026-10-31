const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const m = sdk.canvas.ui_markup;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var policy_calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 108) policy_calls += 1;
    return core.nativeWindowPolicy(input, output);
}
const Loader = struct {
    files: []const m.SourceFile,
    allocate_path: bool = false,
    calls: std.ArrayListUnmanaged([]const u8) = .empty,
    fn loader(self: *Loader) m.ImportLoader {
        return .{ .context = self, .load = load };
    }
    fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *Loader = @ptrCast(@alignCast(@constCast(context)));
        self.calls.append(std.testing.allocator, std.testing.allocator.dupe(u8, path) catch unreachable) catch unreachable;
        const stored = if (self.allocate_path) arena.dupe(u8, path) catch return null else path;
        for (self.files) |file| if (std.mem.eql(u8, file.path, stored)) return file.source;
        return null;
    }
    fn deinit(self: *Loader) void {
        for (self.calls.items) |path| std.testing.allocator.free(path);
        self.calls.deinit(std.testing.allocator);
    }
};
fn aliases(a: m.MarkupNode, b: m.MarkupNode) anyerror!void {
    try exact(@intFromPtr(a.name.ptr), @intFromPtr(b.name.ptr));
    try exact(@intFromPtr(a.text.ptr), @intFromPtr(b.text.ptr));
    for (a.attrs, b.attrs) |left, right| {
        try exact(@intFromPtr(left.name.ptr), @intFromPtr(right.name.ptr));
        try exact(@intFromPtr(left.value.ptr), @intFromPtr(right.value.ptr));
    }
    for (a.children, b.children) |left, right| try aliases(left, right);
}
fn compare(root: []const u8, name: []const u8, source: []const u8, files: []const m.SourceFile, failure: usize, resize_failure: usize, allocate_path: bool) !usize {
    defer core.rt.frameReset();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    var la: Loader = .{ .files = files, .allocate_path = allocate_path };
    defer la.deinit();
    var lb: Loader = .{ .files = files, .allocate_path = allocate_path };
    defer lb.deinit();
    var da: m.MarkupErrorInfo = .{ .line = 7, .column = 9, .message = "previous", .path = "prior.native" };
    var db = da;
    const a = m.resolveImportsFromRoot(fa.allocator(), root, name, source, la.loader(), &da);
    const before = policy_calls;
    const b = m.resolveImportsFromRootWithPolicy(observed, fb.allocator(), root, name, source, lb.loader(), &db);
    if (a) |document| {
        const other = try b;
        try exact(document, other);
        for (document.templates, other.templates) |left, right| try aliases(left, right);
        if (document.root) |node| try aliases(node, other.root.?);
        try std.testing.expect(policy_calls > before);
    } else |err| try std.testing.expectError(err, b);
    try exact(da, db);
    try exact(la.calls.items, lb.calls.items);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    try exact(fa.allocated_bytes, fb.allocated_bytes);
    try exact(fa.freed_bytes, fb.freed_bytes);
    try exact(fa.has_induced_failure, fb.has_induced_failure);
    return fa.alloc_index;
}
fn check(root: []const u8, name: []const u8, source: []const u8, files: []const m.SourceFile) !void {
    _ = try compare(root, name, source, files, std.math.maxInt(usize), std.math.maxInt(usize), false);
}
const graph = [_]m.SourceFile{
    .{ .path = "src/a.native", .source = "<import src=\"shared.native\"/><template name=\"a\"><text>A <span>B</span> C</text></template>" },
    .{ .path = "src/b.native", .source = "<import src=\"shared.native\"/><template name=\"b\"><row><text>B</text></row></template>" },
    .{ .path = "src/shared.native", .source = "<template name=\"shared\"><row><text>Shared</text></row></template>" },
};
const root_source = "<import src=\"a.native\"/><import src=\"b.native\"/><import src=\"a.native\"/><template name=\"local\"><text>L</text></template><row><use template=\"local\"/></row>";
test "compiled markup imports preserve full diamond closures loader order and borrowed ownership" {
    _ = core.initialModel();
    policy_calls = 0;
    try check("src", "src/app.native", root_source, &graph);
    try check("", "", "<row><text>Anonymous</text></row>", &.{});
    try check("", "app.native", "<template name=\"alone\"><text>Component</text></template>", &.{});
    try std.testing.expect(policy_calls > 0);
}
test "compiled markup imports preserve cycle missing child duplicate template and parser diagnostics" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<import src=\"app.native\"/>",                                "<import src=\"a.native\"/>", "<import src=\"missing.native\"/>",
        "<template name=\"shared\"><text>Duplicate</text></template>", "<row/>",                     "<template><bad</template>",
    }) |broken| {
        var files = graph;
        files[2].source = broken;
        try check("src", "src/app.native", root_source, &files);
    }
    for ([_][]const u8{
        "<import/>",                                         "<import bad=\"x\"/>",                     "<import src=\"\"/>",                 "<import src=\"a.native\" src=\"bad.txt\"/>",
        "<import src=\"a.native\" src=\"missing.native\"/>", "<import bad><text>Child</text></import>", "<import src=\"/absolute.native\"/>", "<import src=\"c:\\x.native\"/>",
        "<import src=\"a\\x.native\"/>",                     "<import src=\"../escape.native\"/>",      "<import src=\"./a.native\"/>",       "<import src=\"sub/../a.native\"/>",
    }) |prefix| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "<row/>" });
        defer std.testing.allocator.free(source);
        try check("src", "src/app.native", source, &graph);
    }
}
test "compiled markup imports preserve every arena failure before loader and diagnostic publication" {
    _ = core.initialModel();
    for ([_][]const u8{ graph[2].source, "<import src=\"app.native\"/>", "<import src=\"missing.native\"/>", "<template name=\"a\"><text>Duplicate</text></template>" }) |shared| {
        var files = graph;
        files[2].source = shared;
        for ([_]bool{ false, true }) |allocate| for ([_]usize{ 0, std.math.maxInt(usize) }) |resize| {
            const attempts = try compare("src", "src/app.native", root_source, &files, std.math.maxInt(usize), resize, allocate);
            for (0..attempts + 1) |failure| _ = try compare("src", "src/app.native", root_source, &files, failure, resize, allocate);
        };
    }
}
test "compiled markup imports preserve absolute UNC explicit root and raw byte path behavior" {
    _ = core.initialModel();
    for ([_][]const u8{ "src", "/app/src", "//server/share/src", "a", "" }) |root| {
        const name = try std.mem.concat(std.testing.allocator, u8, &.{ root, "/components/card.native" });
        defer std.testing.allocator.free(name);
        const path = try std.mem.concat(std.testing.allocator, u8, &.{ root, "/shared/base.native" });
        defer std.testing.allocator.free(path);
        const files = [_]m.SourceFile{.{ .path = path, .source = "<template name=\"base\"><text>Base</text></template>" }};
        try check(root, name, "<import src=\"../shared/base.native\"/><row/>", &files);
        try check(root, name, "<import src=\"../../escape.native\"/><row/>", &files);
    }
    var bytes: [64]u8 = undefined;
    for (0..256) |byte| {
        const prefix = "<import src=\"";
        const suffix = ".native\"/><row/>";
        @memcpy(bytes[0..prefix.len], prefix);
        bytes[prefix.len] = @intCast(byte);
        @memcpy(bytes[prefix.len + 1 ..][0..suffix.len], suffix);
        try check("src", "src/app.native", bytes[0 .. prefix.len + 1 + suffix.len], &.{});
    }
}
test "compiled markup imports preserve depth file and merged template limits" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayListUnmanaged(m.SourceFile) = .empty;
    var root: std.ArrayListUnmanaged(u8) = .empty;
    for (0..33) |i| {
        const path = try std.fmt.allocPrint(a, "p{d}.native", .{i});
        try files.append(a, .{ .path = path, .source = try std.fmt.allocPrint(a, "<template name=\"t{d}\"><text>T</text></template>", .{i}) });
        try root.appendSlice(a, try std.fmt.allocPrint(a, "<import src=\"{s}\"/>", .{path}));
        if (i >= 30) try check("", "app.native", root.items, files.items);
    }
    files.clearRetainingCapacity();
    for (0..8) |i| try files.append(a, .{ .path = try std.fmt.allocPrint(a, "p{d}.native", .{i}), .source = if (i == 7) "<template name=\"end\"><text>End</text></template>" else try std.fmt.allocPrint(a, "<import src=\"p{d}.native\"/>", .{i + 1}) });
    try check("", "app.native", "<import src=\"p0.native\"/><row/>", files.items);
    root.clearRetainingCapacity();
    for (0..256) |i| try root.appendSlice(a, try std.fmt.allocPrint(a, "<template name=\"t{d}\"><text>T</text></template>", .{i}));
    const component = [_]m.SourceFile{.{ .path = "parts.native", .source = root.items }};
    try check("", "app.native", "<import src=\"parts.native\"/><template name=\"t0\"><text>Duplicate at limit</text></template><row/>", &component);
}

test "compiled markup imports preserve path capacity segment boundaries and deep dedupe precedence" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 199, 200, 201 }) |length| {
        const path = try a.alloc(u8, length);
        @memset(path, 'a');
        @memcpy(path[length - 7 ..], ".native");
        const source = try std.fmt.allocPrint(a, "<import src=\"{s}\"/><row/>", .{path});
        try check("", "app.native", source, &.{});
        try check("src", "src/app.native", source, &.{});
    }
    var name: std.ArrayListUnmanaged(u8) = .empty;
    for (0..25) |i| {
        try name.appendSlice(a, "p/");
        if (i < 21) continue;
        const importer = try std.mem.concat(a, u8, &.{ name.items, "app.native" });
        for ([_][]const u8{ "card.native", "./card.native", "../card.native", "sub/../card.native" }) |src| {
            try check("", importer, try std.fmt.allocPrint(a, "<import src=\"{s}\"/><row/>", .{src}), &.{});
        }
    }
    for ([_][]const u8{ "src/./sub/../app.native", "/app.native", "//app.native" }) |importer| {
        try check("", importer, "<import src=\"a//.//../card.native\"/><row/>", &.{});
    }
    var files: std.ArrayListUnmanaged(m.SourceFile) = .empty;
    try files.append(a, .{ .path = "shared.native", .source = "<template><text>Unnamed</text></template>" });
    for (0..7) |i| try files.append(a, .{
        .path = try std.fmt.allocPrint(a, "p{d}.native", .{i}),
        .source = if (i == 6) "<import src=\"shared.native\"/>" else try std.fmt.allocPrint(a, "<import src=\"p{d}.native\"/>", .{i + 1}),
    });
    const source = "<import src=\"shared.native\"/><import src=\"p0.native\"/><row/>";
    try check("", "app.native", source, files.items);
    files.items[7].source = "<import src=\"app.native\"/>";
    try check("", "app.native", source, files.items);
    files.items[7].source = "<import src=\"missing.native\"/>";
    try check("", "app.native", source, files.items);
}
