const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.markup_development_policy;
const retained = sdk.runtime.testing.markup_provenance;
const reference = sdk.runtime.testing.markup_provenance_reference;
var calls: [12]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 32) calls[input[2]] += 1;
    const size = core.nativeEffectPolicy(input, output);
    // These tests use an independent native model; only the policy result is
    // copied out of the fixture archive before its transient frame is reset.
    core.rt.frameReset();
    return size;
}
fn compareTables(a: anytype, b: *const retained.ProvenanceTable) !void {
    try exact(a.files_len, b.files_len);
    try exact(a.records_len, b.records_len);
    try exact(a.watching, b.watching);
    try exact(a.dropped, b.dropped);
    for (a.files[0..a.files_len], b.files[0..b.files_len]) |*left, *right| {
        try exact(left.stamped(), right.stamped());
        try exact(left.file(), right.file());
        try exact(left.hash, right.hash);
    }
    for (a.records[0..a.records_len], b.records[0..b.records_len]) |*left, *right| {
        inline for (.{ "id", "file", "start", "end", "line", "column", "chain_len", "chain_truncated", "keys_len", "keys_truncated" }) |field| try exact(@field(left, field), @field(right, field));
        for (left.chain[0..left.chain_len], right.chain[0..right.chain_len]) |l, r| inline for (.{ "file", "start", "end", "line", "column" }) |field| try exact(@field(l, field), @field(r, field));
        try exact(@as([]const u8, left.keys[0..left.keys_len]), right.keys[0..right.keys_len]);
    }
}
fn compareResponses(a: *const reference.ProvenanceTable, b: *const retained.ProvenanceTable, id: u64) !void {
    var l: [8192]u8 = undefined;
    var r: [8192]u8 = undefined;
    var lw = std.Io.Writer.fixed(&l);
    var rw = std.Io.Writer.fixed(&r);
    try a.writeResponse(&lw, "日本\x00\xff", id);
    try b.writeResponse(&rw, "日本\x00\xff", id);
    try exact(lw.buffered(), rw.buffered());
    // Every failed fixed writer retains the same complete prefix and error.
    for (0..lw.buffered().len) |capacity| {
        var la = std.Io.Writer.fixed(l[0..capacity]);
        var ra = std.Io.Writer.fixed(r[0..capacity]);
        const left = a.writeResponse(&la, "日本\x00\xff", id);
        const right = b.writeResponse(&ra, "日本\x00\xff", id);
        if (left) |_| try right else |err| try std.testing.expectError(err, right);
        try exact(la.buffered(), ra.buffered());
    }
}
test "compiled markup development preserves complete retained files records raw keys and exact identities" {
    _ = core.initialModel();
    const a = try std.testing.allocator.create(reference.ProvenanceTable);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(retained.ProvenanceTable);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{ .policy = observed, .allocator = std.testing.allocator };
    const paths = [_][]const u8{ "", "parts.native", "日本\x00\xff", "x" ** 241 };
    for (paths, 0..) |path, i| {
        try a.addFile(path, path, std.math.maxInt(u64) - i);
        try b.addFile(path, path, std.math.maxInt(u64) - i);
    }
    for (paths) |path| try exact(a.fileIndexOf(path), b.fileIndexOf(path));
    a.watching = true;
    b.watching = true;
    var chain: [6]sdk.canvas.ui_provenance.UseSite = undefined;
    for (&chain, 0..) |*site, i| site.* = .{ .src_path = paths[i % paths.len], .span = .{ .start = std.math.maxInt(usize) - i, .end = i }, .line = std.math.maxInt(u32), .column = i };
    var raw: [64]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
    const key_sets = [_][]const sdk.canvas.ui_provenance.Key{
        &.{},                                                          &.{.{ .str = "" }},                          &.{ .{ .str = &raw }, .{ .index = std.math.maxInt(usize) } },
        &.{ .{ .str = "日本\x00\xff" }, .{ .int = std.math.maxInt(u64) }, .{ .index = std.math.maxInt(usize) } },
        &.{ .{ .str = "x" ** 45 }, .{ .int = std.math.maxInt(u64) } }, &.{ .{ .str = "x" ** 47 }, .{ .str = "" } },
    };
    const empty_keys: [60]sdk.canvas.ui_provenance.Key = @splat(.{ .str = "" });
    var id: u64 = 9007199254740993;
    for (0..7) |chain_len| for (key_sets) |keys| for ([_]bool{ false, true }) |truncated| {
        const source: sdk.canvas.ui_provenance.NodeSource = .{ .src_path = paths[chain_len % paths.len], .span = .{ .start = std.math.maxInt(usize), .end = 4294967295 }, .line = 17, .column = 5, .chain = chain[0..chain_len] };
        try a.appendRecord(id, &source, keys, truncated);
        try b.appendRecord(id, &source, keys, truncated);
        id += 1;
    };
    for (0..61) |n| {
        const source: sdk.canvas.ui_provenance.NodeSource = .{ .src_path = "", .span = .{ .start = 1, .end = 9 } };
        try a.appendRecord(id, &source, empty_keys[0..n], false);
        try b.appendRecord(id, &source, empty_keys[0..n], false);
        id += 1;
    }
    try compareTables(a, b);
    for ([_]u64{ 9007199254740993, id - 1, std.math.maxInt(u64), 0 }) |query| {
        try exact(a.find(query) != null, b.find(query) != null);
        try compareResponses(a, b, query);
    }
    a.dropped = 9007199254740993;
    b.dropped = a.dropped;
    try compareResponses(a, b, 1);
}
test "compiled markup development preserves closure and provenance capacity refusal without half application" {
    _ = core.initialModel();
    var a = reference.ClosureFiles{};
    var b = retained.ClosureFiles{ .policy = observed };
    for (0..reference.max_files + 2) |i| {
        a.add("p" ** 242, std.math.maxInt(u64) - i);
        b.add("p" ** 242, std.math.maxInt(u64) - i);
    }
    try exact(a.len, b.len);
    try exact(a.overflow, b.overflow);
    for (a.entries[0..a.len], b.entries[0..b.len]) |left, right| {
        try exact(left.path_len, right.path_len);
        try exact(left.path[0..left.path_len], right.path[0..right.path_len]);
        try exact(left.hash, right.hash);
    }
    const left = try std.testing.allocator.create(reference.ProvenanceTable);
    defer std.testing.allocator.destroy(left);
    const right = try std.testing.allocator.create(retained.ProvenanceTable);
    defer std.testing.allocator.destroy(right);
    left.* = .{};
    right.* = .{ .policy = observed, .allocator = std.testing.allocator };
    for (0..reference.max_files) |i| {
        try left.addFile("p", "d", i);
        try right.addFile("p", "d", i);
    }
    try std.testing.expectError(error.WidgetProvenanceFileLimitReached, left.addFile("x", "x", 0));
    try std.testing.expectError(error.WidgetProvenanceFileLimitReached, right.addFile("x", "x", 0));
    const source: sdk.canvas.ui_provenance.NodeSource = .{ .src_path = "p", .span = .{ .start = 0, .end = 8 } };
    for (0..reference.max_records) |i| {
        try left.appendRecord(i + 1, &source, &.{}, false);
        try right.appendRecord(i + 1, &source, &.{}, false);
    }
    left.sink().record(999999, &source, &.{}, false);
    right.sink().record(999999, &source, &.{}, false);
    try compareTables(left, right);
    try compareResponses(left, right, 999999);
    left.resetRecords();
    right.resetRecords();
    left.resetFiles();
    right.resetFiles();
    try compareTables(left, right);
}
test "compiled markup development programs preserve every root fragment failure and watch combination" {
    _ = core.initialModel();
    for ([_]bool{ false, true }) |root| for ([_]bool{ false, true }) |view| for ([_]bool{ false, true }) |zero| for ([_]bool{ false, true }) |fragments| for ([_]usize{ 0, 1, 16, 17 }) |count| {
        const p = policy.watch(observed, root, view, zero, fragments, count, 16);
        try exact(@as(u32, @intFromBool(root and view and zero)), p[0]);
        try exact(@as(u32, @intFromBool(root or fragments and count != 0)), p[1]);
        try exact(@as(u32, @intCast(if (fragments) @min(count, 16) else 0)), p[2]);
        try exact(@as(u32, @intFromBool(fragments and count > 16)), p[3]);
    };
    for (0..3) |kind| for ([_]bool{ false, true }) |changed| for ([_]bool{ false, true }) |failed| for ([_]bool{ false, true }) |diagnostic| for ([_]bool{ false, true }) |baseline| for ([_]bool{ false, true }) |installed| {
        const p = policy.reload(observed, @intCast(kind), changed, failed, diagnostic, baseline, installed);
        var expected: [12]u8 = @splat(0);
        var at: usize = 0;
        if (changed) {
            if (failed) {
                if (kind != 0) {
                    expected[at] = 1;
                    at += 1;
                }
                if (diagnostic) expected[at] = 2;
            } else if (kind == 2) {
                expected[0] = 1;
                expected[1] = if (baseline) 7 else 3;
                if (baseline) expected[2..5].* = .{ 9, 10, 11 } else expected[2..6].* = .{ 8, 9, 10, 11 };
            } else {
                expected[0..3].* = .{ 3, 4, 5 };
                if (kind == 1 and installed) expected[3] = 6;
            }
        }
        try exact(expected, p);
    };
    for ([_][]const u8{ "", "src", "src/", "日本" }) |prefix| for ([_][]const u8{ "", "src/x", "src", "src-other/x", "日本/x", "日本/\x00\xff" }) |path| {
        const expected = if (prefix.len > 0 and path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/') path[prefix.len + 1 ..] else path;
        try exact(expected, policy.stripPrefix(observed, prefix, path));
    };
}

const Model = struct { count: u32 = 0 };
const Msg = union(enum) { increment, reset };
const App = sdk.UiApp(Model, Msg);
const Harness = sdk.TestHarness();
const watch_root = ".zig-cache/compiled-markup-development";
const root_source = "<import src=\"parts.native\"/><column padding=\"12\" gap=\"8\"><text>Count {count}</text><button on-press=\"increment\">Increment</button><use template=\"actions\"/></column>";
const parts_source = "<template name=\"actions\"><button on-press=\"reset\">Reset</button></template>";
const parts_changed = "<template name=\"actions\"><button on-press=\"reset\">Start over</button></template>";
const sources = [_]sdk.canvas.ui_markup.SourceFile{
    .{ .path = "app.native", .source = root_source },
    .{ .path = "parts.native", .source = parts_source },
};
const View = sdk.canvas.CompiledMarkupImports(Model, Msg, "app.native", &sources);
fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .reset => model.count = 0,
    }
}
const scene: sdk.app_manifest.ShellConfig = .{ .windows = &.{.{ .label = "main", .title = "Markup", .width = 400, .height = 300, .views = &.{.{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }} }} };
fn snapshotExact(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    switch (@typeInfo(@TypeOf(expected))) {
        .@"struct" => |info| inline for (info.fields) |field| snapshotExact(@field(expected, field.name), @field(actual, field.name)) catch |err| {
            std.debug.print("snapshot field {s}\n", .{field.name});
            return err;
        },
        .pointer => |info| if (info.size == .slice) {
            try exact(expected.len, actual.len);
            for (expected, actual) |a, b| try snapshotExact(a, b);
        } else try exact(expected, actual),
        else => try exact(expected, actual),
    }
}
const AppPair = struct {
    harnesses: [2]*Harness,
    apps: [2]*App,
    time: u64 = 1_000_000,
    fn create(options: App.Options) !AppPair {
        const allocator = std.testing.allocator;
        const left = try Harness.create(allocator, .{ .size = .init(400, 300) });
        errdefer left.destroy(allocator);
        const right = try Harness.create(allocator, .{ .size = .init(400, 300) });
        errdefer right.destroy(allocator);
        const a = try allocator.create(App);
        errdefer allocator.destroy(a);
        const b = try allocator.create(App);
        errdefer allocator.destroy(b);
        var pair = AppPair{ .harnesses = .{ left, right }, .apps = .{ a, b } };
        for (pair.harnesses, pair.apps, 0..) |h, app, i| {
            h.null_platform.gpu_surfaces = true;
            var opts = options;
            opts.markup_development_policy = if (i == 1) observed else null;
            opts.expression_policy = if (i == 1) options.expression_policy else null;
            app.* = App.init(std.testing.allocator, .{}, opts);
            try h.start(app.app());
            h.runtime.started_timestamp_ns = 0;
            try h.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(400, 300), .scale_factor = 2, .frame_index = 1, .timestamp_ns = 1_000_000, .nonblank = true } });
        }
        try pair.same();
        return pair;
    }
    fn destroy(self: *AppPair) void {
        for (self.apps, self.harnesses) |app, h| {
            app.deinit();
            std.testing.allocator.destroy(app);
            h.destroy(std.testing.allocator);
        }
    }
    fn same(self: *AppPair) !void {
        try exact(self.apps[0].model, self.apps[1].model);
        inline for (.{ "markup_source_hash", "markup_arena_index", "installed", "markup_diagnostic" }) |field| try exact(@field(self.apps[0], field), @field(self.apps[1], field));
        try exact(self.apps[0].markup_view != null, self.apps[1].markup_view != null);
        try compareTables(&self.apps[0].provenance, &self.apps[1].provenance);
        try exact(self.harnesses[0].null_platform.startedTimer(App.markup_watch_timer_id), self.harnesses[1].null_platform.startedTimer(App.markup_watch_timer_id));
        // Complete snapshots include every widget, layout, action, diagnostic,
        // retained window/view, media field and packet telemetry.
        try snapshotExact(self.harnesses[0].runtime.automationSnapshot("Markup"), self.harnesses[1].runtime.automationSnapshot("Markup"));
        var a: [8192]u8 = undefined;
        var b: [8192]u8 = undefined;
        var left_writer = std.Io.Writer.fixed(&a);
        var right_writer = std.Io.Writer.fixed(&b);
        try self.apps[0].provenance.writeResponse(&left_writer, "canvas", 0);
        try self.apps[1].provenance.writeResponse(&right_writer, "canvas", 0);
        try exact(left_writer.buffered(), right_writer.buffered());
        if (comptime @import("builtin").mode == .Debug) for (self.apps[0].markup_fragment_slots, self.apps[1].markup_fragment_slots) |left, right| {
            try exact(left.hash, right.hash);
            try exact(left.baseline_hash, right.baseline_hash);
            try exact(left.arena_index, right.arena_index);
            try exact(left.document != null, right.document != null);
        };
    }
    fn poll(self: *AppPair) !void {
        self.time += 500_000;
        for (self.apps, self.harnesses) |app, h| try h.runtime.dispatchPlatformEvent(app.app(), h.null_platform.fireTimer(App.markup_watch_timer_id, self.time).?);
        try self.same();
    }
    fn id(self: *AppPair, name: []const u8) !u64 {
        const snapshot = self.harnesses[0].runtime.automationSnapshot("Markup");
        for (snapshot.widgets) |widget| if (std.mem.eql(u8, widget.name, name)) return widget.id;
        return error.WidgetNotFound;
    }
    fn click(self: *AppPair, widget: u64) !void {
        const layout = try self.harnesses[0].runtime.canvasWidgetLayout(1, "canvas");
        const bounds = layout.findById(widget).?.frame;
        self.time += 1000;
        // Supply the same host clock to both real pointer consumers. The
        // automation convenience command samples a different clock per call.
        for (self.apps, self.harnesses) |app, h| for ([_]sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }) |kind| {
            try h.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{ .label = "canvas", .kind = kind, .timestamp_ns = self.time, .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 } });
        };
        try self.same();
    }
};
var runtime_parser_calls: usize = 0;
var runtime_document_calls: usize = 0;
var runtime_canonical_calls: usize = 0;
fn parserObserved(input: []const u8, output: []u8) usize {
    if (input[0] == 106) runtime_parser_calls += 1;
    if (input[0] == 107) runtime_document_calls += 1;
    if (input[0] == 109) runtime_canonical_calls += 1;
    const size = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return size;
}
test "compiled markup parser reaches root activation reload and complete runtime snapshots" {
    _ = core.initialModel();
    const source = "<column><text>{count + 1 ++ ' items'}</text><if test=\"{count >= 0 and true}\"><button on-press=\"increment\">Increment</button></if></column>";
    runtime_parser_calls = 0;
    runtime_document_calls = 0;
    runtime_canonical_calls = 0;
    var pair = try AppPair.create(.{ .name = "Markup", .scene = scene, .canvas_label = "canvas", .update = update, .expression_policy = parserObserved, .markup = .{ .source = source } });
    defer pair.destroy();
    try std.testing.expect(runtime_parser_calls > 0 and runtime_document_calls > 0 and runtime_canonical_calls > 0);
    try pair.click(try pair.id("Increment"));
    const before = runtime_parser_calls;
    const document_before = runtime_document_calls;
    const canonical_before = runtime_canonical_calls;
    const changed = "<column><text>{plural(count, 'item', 'items') ++ pad(count, 3)}</text><button on-press=\"increment\">Increment</button></column>";
    for (pair.apps, pair.harnesses) |app, h| {
        try app.reloadMarkup(changed);
        try app.rebuild(&h.runtime, 1);
    }
    try std.testing.expect(runtime_parser_calls > before and runtime_document_calls > document_before and runtime_canonical_calls > canonical_before);
    try pair.same();
    try pair.click(try pair.id("Increment"));
    for (pair.apps, pair.harnesses) |app, h| {
        try app.reloadMarkup(source);
        try app.rebuild(&h.runtime, 1);
    }
    try pair.same();
}
test "compiled markup development root imports preserve complete snapshots last good recovery and anchors" {
    _ = core.initialModel();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, watch_root);
    defer cwd.deleteTree(io, watch_root) catch {};
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/app.native", .data = root_source });
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_source });
    var pair = try AppPair.create(.{ .name = "Markup", .scene = scene, .canvas_label = "canvas", .update = update, .view = View.build, .expression_policy = parserObserved, .markup = .{ .source = root_source, .sources = &sources, .watch_path = watch_root ++ "/app.native", .io = io } });
    defer pair.destroy();
    try pair.poll();
    try std.testing.expect(pair.apps[1].markup_view == null);
    const increment = try pair.id("Increment");
    try pair.click(increment);
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_changed });
    try pair.poll();
    _ = try pair.id("Start over");
    try std.testing.expectEqual(increment, try pair.id("Increment"));
    const good_hash = pair.apps[1].provenance.files[1].hash;
    const good_arena = pair.apps[1].markup_arena_index;
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = "<template><oops</template>" });
    try pair.poll();
    try std.testing.expect(pair.apps[1].markup_diagnostic != null);
    try std.testing.expectEqual(good_arena, pair.apps[1].markup_arena_index);
    try std.testing.expectEqual(good_hash, pair.apps[1].provenance.files[1].hash);
    _ = try pair.id("Start over");
    try pair.poll(); // Repeated broken saves keep the same diagnostic and tree.
    try cwd.deleteFile(io, watch_root ++ "/parts.native");
    try pair.poll();
    _ = try pair.id("Start over");
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_source });
    try pair.poll();
    try std.testing.expect(pair.apps[1].markup_diagnostic == null);
    try std.testing.expectEqual(@as(u32, 1), pair.apps[1].model.count);
    try std.testing.expectEqual(increment, try pair.id("Increment"));
    _ = try pair.id("Reset");
    for (pair.apps) |app| try std.testing.expectError(error.MarkupSyntax, app.reloadMarkup("<column><oops</column>"));
    try pair.same();
    for (pair.apps) |app| try app.reloadMarkup(root_source);
    try pair.same();
    try std.testing.expect(pair.apps[1].markup_diagnostic == null);
}

const fragment_sources = [_]sdk.canvas.ui_markup.SourceFile{
    .{ .path = "fragment.native", .source = "<import src=\"parts.native\"/><column><use template=\"actions\"/></column>" },
    .{ .path = "parts.native", .source = parts_source },
};
const Fragment = sdk.canvas.CompiledMarkupImports(Model, Msg, "fragment.native", &fragment_sources);
const other_fragment_sources = [_]sdk.canvas.ui_markup.SourceFile{
    .{ .path = "other.native", .source = fragment_sources[0].source },
    .{ .path = "parts.native", .source = parts_source },
};
const OtherFragment = sdk.canvas.CompiledMarkupImports(Model, Msg, "other.native", &other_fragment_sources);
fn fragmentView(ui: *App.Ui, model: *const Model) App.Ui.Node {
    return ui.column(.{ .gap = 8 }, .{ ui.text(.{}, ui.fmt("Count {d}", .{model.count})), Fragment.build(ui, model), OtherFragment.build(ui, model) });
}
test "compiled markup development fragments preserve shared import failure recovery and compiled reversion" {
    if (comptime @import("builtin").mode != .Debug) return error.SkipZigTest;
    _ = core.initialModel();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, watch_root);
    defer cwd.deleteTree(io, watch_root) catch {};
    const fragment_source = fragment_sources[0].source;
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/a.native", .data = fragment_source });
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/b.native", .data = fragment_source });
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_source });
    const fragments = [_]sdk.canvas.MarkupFragment{ Fragment.fragment(watch_root ++ "/a.native"), OtherFragment.fragment(watch_root ++ "/b.native") };
    var pair = try AppPair.create(.{ .name = "Markup", .scene = scene, .canvas_label = "canvas", .update = update, .view = fragmentView, .expression_policy = parserObserved, .fragment_watch = .{ .fragments = &fragments, .io = io } });
    defer pair.destroy();
    try pair.poll();
    try std.testing.expect(pair.apps[1].markup_fragment_slots[0].document == null);
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_changed });
    try pair.poll();
    for (pair.apps[1].markup_fragment_slots[0..2]) |slot| try std.testing.expect(slot.document != null);
    _ = try pair.id("Start over");
    const good_arena = pair.apps[1].markup_fragment_slots[0].arena_index;
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = "<template><oops</template>" });
    try pair.poll();
    try std.testing.expect(pair.apps[1].markup_diagnostic != null);
    try std.testing.expectEqual(good_arena, pair.apps[1].markup_fragment_slots[0].arena_index);
    _ = try pair.id("Start over");
    try pair.poll();
    try cwd.writeFile(io, .{ .sub_path = watch_root ++ "/parts.native", .data = parts_source });
    try pair.poll();
    for (pair.apps[1].markup_fragment_slots[0..2]) |slot| try std.testing.expect(slot.document == null);
    try std.testing.expect(pair.apps[1].markup_diagnostic == null);
    _ = try pair.id("Reset");
    for (calls) |count| try std.testing.expect(count != 0);
}
