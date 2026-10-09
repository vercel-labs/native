const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("markdown_viewer_core");
const decoder = @import("markdown_viewer_decoder");
const reference = @import("markdown-viewer-reference/main.zig");
const parity = @import("effects_media_parity.zig");
const testing = std.testing;
const canvas = sdk.canvas;
const Host = sdk.TsCoreHost(core);

test {
    _ = @import("markdown-viewer-reference/tests.zig");
}

fn imageId(identity: anytype) u64 {
    return @as(u64, @intFromFloat(identity.imageLower)) | (@as(u64, @intFromFloat(identity.imageUpper)) << 32);
}
fn bufferEqual(expected: anytype, actual: anytype) !void {
    try testing.expectEqualStrings(expected.text(), actual.text);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.anchor)), actual.selection.anchor);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.focus)), actual.selection.focus);
    try testing.expectEqual(expected.composition != null, actual.composition != null);
    if (expected.composition) |value| {
        try testing.expectEqual(@as(i64, @intCast(value.start)), actual.composition.?.start);
        try testing.expectEqual(@as(i64, @intCast(value.end)), actual.composition.?.end);
    }
    try testing.expectEqual(expected.truncated, actual.truncated);
}
fn compare(expected: *const reference.Model, actual: *const core.Model) !void {
    try bufferEqual(expected.editor, actual.editor);
    try bufferEqual(expected.path_field, actual.path_field);
    try testing.expectEqualStrings(expected.currentPath(), actual.current_path);
    try testing.expectEqualStrings(expected.pendingPath(), actual.pending_path);
    try testing.expectEqualStrings(expected.recentStorePath(), actual.recent_path);
    try testing.expectEqualStrings(expected.note(), actual.note);
    try testing.expectEqual(expected.recent_count, actual.recents.len);
    for (actual.recents, 0..) |entry, index| try testing.expectEqualStrings(expected.recentAt(index), entry.value);
    for (expected.details_expanded, actual.details_expanded) |a, b| try testing.expectEqual(a, b);
    try testing.expectEqual(@as(i64, expected.active_sample_id), actual.active_sample_id);
    try testing.expectEqual(expected.sample_picker_open, actual.sample_picker_open);
    try testing.expectEqualStrings(@tagName(expected.system_scheme), @tagName(actual.system_scheme));
    inline for (.{ "chrome_leading", "chrome_trailing", "toolbar_height", "doc_scroll" }) |name|
        try testing.expectEqual(@as(f64, @field(expected, name)), @field(actual, name));
    try testing.expectEqual(expected.preview_images.len, actual.preview_images.len);
    for (expected.preview_images, actual.preview_images) |a, b| {
        try testing.expectEqualStrings(a.source_storage[0..a.source_len], b.source);
        try testing.expectEqual(a.id, imageId(b.identity));
        try testing.expectEqual(@as(i64, @intCast(a.width)), b.width);
        try testing.expectEqual(@as(i64, @intCast(a.height)), b.height);
        try testing.expectEqual(a.loaded, b.loaded);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ "document", "path", "docTitle" }) |name|
        try testing.expectEqualStrings(@field(reference.Model, name)(expected), @field(core.Model, name)(actual, alloc));
    try testing.expectEqualStrings(expected.statusLine(alloc), actual.statusLine(alloc));
    try testing.expectEqual(expected.pathEmpty(), actual.pathEmpty());
    try testing.expectEqual(expected.cannotSave(), actual.cannotSave());
    const a_recents = expected.recentDocs(alloc);
    const b_recents = actual.recentDocs(alloc);
    for (a_recents, b_recents) |a, b| {
        try testing.expectEqual(@as(i64, @intCast(a.index)), b.index);
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.path, b.path);
    }
    const a_images = expected.markdownImages(alloc);
    const b_images = actual.markdownImages(alloc);
    try testing.expectEqual(a_images.len, b_images.len);
    for (a_images, b_images) |a, b| {
        try testing.expectEqualStrings(a.source, b.source);
        try testing.expectEqual(a.image, imageId(b.image));
        try testing.expectEqual(@as(i64, @intFromFloat(a.width)), b.width);
        try testing.expectEqual(@as(i64, @intFromFloat(a.height)), b.height);
    }
    var serialized: [6 * 513]u8 = undefined;
    // The actual write payload is compared below; this also pins native
    // serialization independently of the compiled app's effect bridge.
    _ = expected.serializeRecent(&serialized);
    core.rt.frameReset();
}
fn viewParity(expected: *const reference.Model, actual: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = reference.ViewerUi.init(arena.allocator());
    const old = try a.finalize(reference.CompiledViewerView.build(&a, expected));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const new = try b.finalize(if (backend == 0) View.build(&b, actual) else decoder.build(&b, actual));
        core.rt.frameReset();
        try parity.equal(old.root, new.root);
        try testing.expectEqual(old.handlers.len, new.handlers.len);
        for (old.handlers, new.handlers) |before, after| {
            try testing.expectEqual(before.id, after.id);
            const left = old.msgForPointer(before.id, .up);
            const right = new.msgForPointer(after.id, .up);
            try testing.expectEqual(left != null, right != null);
            if (left) |msg| try testing.expectEqualStrings(@tagName(msg), @tagName(right.?));
        }
        var left: [2048]canvas.WidgetLayoutNode = undefined;
        var right: [2048]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 1200, 760), .init(0, 0, 960, 560), .init(0, 0, 1440, 900) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(old.root, frame, &left), try canvas.layoutWidgetTree(new.root, frame, &right));
    }
}
const Pair = struct {
    model: reference.Model,
    native_fx: reference.Effects,
    fx: Host.Fx,
    fn create() !*Pair {
        const self = try testing.allocator.create(Pair);
        errdefer testing.allocator.destroy(self);
        self.model = reference.initialModel();
        self.native_fx = .init(testing.allocator);
        errdefer self.native_fx.deinit();
        self.native_fx.executor = .fake;
        self.fx = .init(testing.allocator);
        errdefer self.fx.deinit();
        self.fx.executor = .fake;
        reference.boot(&self.model, &self.native_fx);
        Host.init(&self.fx);
        const os = @tagName(@import("builtin").os.tag);
        Host.dispatch(&self.fx, .{ .target_os = os });
        try self.check();
        return self;
    }
    fn destroy(self: *Pair) void {
        self.native_fx.deinit();
        self.fx.deinit();
        testing.allocator.destroy(self);
    }
    fn check(self: *Pair) !void {
        try compare(&self.model, Host.model());
        try testing.expectEqual(self.native_fx.pendingFileCount(), self.fx.pendingFileCount());
        for (0..self.fx.pendingFileCount()) |i| {
            const a = self.native_fx.pendingFileAt(i).?;
            const b = self.fx.pendingFileAt(i).?;
            try testing.expectEqual(a.op, b.op);
            try testing.expectEqualStrings(a.path, b.path);
            try testing.expectEqualStrings(a.bytes, b.bytes);
        }
        try testing.expectEqual(self.native_fx.pendingImageLoadCount(), self.fx.pendingImageLoadCount());
        for (0..self.fx.pendingImageLoadCount()) |i| {
            const a = self.native_fx.pendingImageLoadAt(i).?;
            const b = self.fx.pendingImageLoadAt(i).?;
            try testing.expectEqual(a.id, b.id);
            try testing.expectEqualStrings(a.path, b.path);
            try testing.expectEqualStrings(a.url, b.url);
            try testing.expectEqualStrings(a.cache_path, b.cache_path);
            try testing.expectEqual(a.expected_bytes, b.expected_bytes);
        }
        try testing.expectEqual(self.native_fx.pendingSpawnCount(), self.fx.pendingSpawnCount());
        for (0..self.fx.pendingSpawnCount()) |i| {
            const a = self.native_fx.pendingSpawnAt(i).?;
            const b = self.fx.pendingSpawnAt(i).?;
            try testing.expectEqual(a.argv.len, b.argv.len);
            for (a.argv, b.argv) |left, right| try testing.expectEqualStrings(left, right);
            try testing.expectEqualStrings(a.stdin, b.stdin);
            try testing.expectEqual(a.output, b.output);
            try testing.expectEqual(a.max_line_bytes, b.max_line_bytes);
        }
        try viewParity(&self.model, Host.model());
    }
    fn drain(self: *Pair) !void {
        while (self.native_fx.takeMsg()) |msg| reference.update(&self.model, msg, &self.native_fx);
        Host.drain(&self.fx);
        try self.check();
    }
    fn step(self: *Pair, native: reference.Msg, msg: core.Msg) !void {
        reference.update(&self.model, native, &self.native_fx);
        Host.dispatch(&self.fx, msg);
        try self.drain();
    }
    fn file(self: *Pair, outcome: sdk.EffectFileOutcome, bytes: []const u8) !void {
        const a = self.native_fx.pendingFileAt(0).?;
        const b = self.fx.pendingFileAt(0).?;
        try self.native_fx.feedFileResult(a.key, outcome, bytes);
        try self.fx.feedFileResult(b.key, outcome, bytes);
        try self.drain();
    }
};

test "Markdown Viewer complete initial state, samples, picker and details match the native reference" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.step(.toggle_sample_picker, .toggle_sample_picker);
    try pair.step(.close_sample_picker, .close_sample_picker);
    for ([_]u32{ 2, 3, 4, 1, 99 }) |id| {
        try pair.step(.{ .load_sample = id }, .{ .load_sample = id });
        try pair.step(.{ .toggle_details = 0 }, .{ .toggle_details = 0 });
        try pair.step(.{ .toggle_details = 15 }, .{ .toggle_details = 15 });
        try pair.step(.{ .toggle_details = 16 }, .{ .toggle_details = 16 });
    }
}

test "Markdown Viewer editor selection composition and exact capacities match the native reference" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    try pair.step(.{ .edit = .{ .insert_text = "Café 日本\r\n🙂" } }, .{ .edit = .{ .insert_text = "Café 日本\r\n🙂" } });
    try pair.step(.{ .edit = .{ .set_selection = .{ .anchor = 2, .focus = 6 } } }, .{ .edit = .{ .set_selection = .{ .anchor = 2, .focus = 6 } } });
    try pair.step(.{ .edit = .{ .set_composition = .{ .text = "かな", .cursor = 3 } } }, .{ .edit = .{ .set_composition = .{ .text = "かな", .cursor = 3 } } });
    try pair.step(.{ .edit = .cancel_composition }, .{ .edit = .cancel_composition });
    try pair.step(.{ .edit = .{ .set_composition = .{ .text = "é", .cursor = null } } }, .{ .edit = .{ .set_composition = .{ .text = "é", .cursor = null } } });
    try pair.step(.{ .edit = .commit_composition }, .{ .edit = .commit_composition });
    const large = try testing.allocator.alloc(u8, 16390);
    defer testing.allocator.free(large);
    @memset(large, 'a');
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    try pair.step(.{ .edit = .{ .insert_text = large } }, .{ .edit = .{ .insert_text = large } });
    try pair.step(.{ .load_sample = 1 }, .{ .load_sample = 1 });
    try testing.expect(pair.model.editor.truncated);
    try pair.step(.{ .edit = .delete_backward }, .{ .edit = .delete_backward });
    try pair.step(.{ .edit_path = .{ .insert_text = large[0..520] } }, .{ .edit_path = .{ .insert_text = large[0..520] } });
    try pair.step(.{ .edit_path = .delete_backward }, .{ .edit_path = .delete_backward });
}

test "Markdown Viewer open save duplicate requests and shared pending paths preserve native races" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.step(.{ .edit_path = .{ .insert_text = " /viewer-test/first.md " } }, .{ .edit_path = .{ .insert_text = " /viewer-test/first.md " } });
    try pair.step(.open_doc, .open_doc);
    try pair.step(.open_doc, .open_doc); // rejected duplicate leaves the incumbent running
    try testing.expectEqual(@as(usize, 1), pair.native_fx.pendingFileCount());
    try pair.file(.ok, "# Opened\n\nExact bytes\x00\xff");
    try pair.step(.save_doc, .save_doc);
    try pair.file(.ok, "");
    try pair.step(.{ .edit_path = .clear }, .{ .edit_path = .clear });
    try pair.step(.{ .edit_path = .{ .insert_text = "/viewer-test/second.md" } }, .{ .edit_path = .{ .insert_text = "/viewer-test/second.md" } });
    try pair.step(.save_as, .save_as);
    try pair.step(.{ .edit_path = .clear }, .{ .edit_path = .clear });
    try pair.step(.{ .edit_path = .{ .insert_text = "/viewer-test/third.md" } }, .{ .edit_path = .{ .insert_text = "/viewer-test/third.md" } });
    try pair.step(.open_doc, .open_doc);
    try pair.file(.ok, ""); // saving the second path adopts the shared third path
    try pair.file(.ok, "# Third");
    try testing.expectEqualStrings("/viewer-test/third.md", pair.model.currentPath());
    try pair.step(.{ .toggle_details = 3 }, .{ .toggle_details = 3 });
    try pair.step(.open_doc, .open_doc);
    try pair.file(.truncated, "cut\x00\xff");
    try testing.expect(pair.model.details_expanded[3]);
    for ([_]sdk.EffectFileOutcome{ .not_found, .io_failed, .rejected, .cancelled, .disk_full }) |outcome| {
        try pair.step(.open_doc, .open_doc);
        try pair.file(outcome, "");
        try pair.step(.save_doc, .save_doc);
        try pair.file(outcome, "");
    }
}

test "Markdown Viewer remote image discovery exact hashes retention eviction and every terminal match native" {
    const pair = try Pair.create();
    defer pair.destroy();
    const sources = [_][]const u8{
        "https://images.test/é.png",
        "HTTP://images.test/a.png",
        "https://images.test/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz.png",
    };
    for (sources) |source| {
        var buffer: [256]u8 = undefined;
        const document = try std.fmt.bufPrint(&buffer, "![alt]({s})\n\n![again]({s})", .{ source, source });
        try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
        try pair.step(.{ .edit = .{ .insert_text = document } }, .{ .edit = .{ .insert_text = document } });
        const id = pair.model.preview_images[0].id;
        try testing.expect(id > 9007199254740991);
        try testing.expectEqual(@as(usize, 1), pair.fx.pendingImageLoadCount());
        try pair.native_fx.feedImageResult(id, .loaded, 9, 7, 200, "");
        try pair.fx.feedImageResult(id, .loaded, 9, 7, 200, "");
        try pair.drain();
        try pair.step(.{ .edit = .{ .insert_text = "\nretained" } }, .{ .edit = .{ .insert_text = "\nretained" } });
        try testing.expectEqual(@as(usize, 0), pair.fx.pendingImageLoadCount());
    }
    inline for (std.meta.fields(sdk.EffectImageOutcome)) |field| {
        if (comptime std.mem.eql(u8, field.name, "loaded")) continue;
        try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
        try pair.step(.{ .edit = .{ .insert_text = "![alt](https://images.test/failure.png)" } }, .{ .edit = .{ .insert_text = "![alt](https://images.test/failure.png)" } });
        const id = pair.model.preview_images[0].id;
        try pair.native_fx.feedImageResult(id, @field(sdk.EffectImageOutcome, field.name), 0, 0, 503, "");
        try pair.fx.feedImageResult(id, @field(sdk.EffectImageOutcome, field.name), 0, 0, 503, "");
        try pair.drain();
    }
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    try pair.step(.{ .edit = .{ .insert_text = "<img src='file:///local.png'> ![a](data:image/png;base64,x) ![b](https://images.test/pending.png)" } }, .{ .edit = .{ .insert_text = "<img src='file:///local.png'> ![a](data:image/png;base64,x) ![b](https://images.test/pending.png)" } });
    try pair.step(.{ .load_sample = 1 }, .{ .load_sample = 1 });
    try testing.expectEqual(@as(usize, 0), pair.fx.pendingImageLoadCount());
}

test "Markdown Viewer browser outcomes including empty URLs preserve native commands" {
    const pair = try Pair.create();
    defer pair.destroy();
    for ([_][]const u8{ "", "https://native-sdk.dev/a?q=é" }) |url| {
        try pair.step(.{ .open_url = url }, .{ .open_url = url });
        const a = pair.native_fx.pendingSpawnAt(0).?;
        const b = pair.fx.pendingSpawnAt(0).?;
        try pair.native_fx.feedExit(a.key, 0);
        try pair.fx.feedExit(b.key, 0);
        try pair.drain();
        try pair.step(.{ .open_url = url }, .{ .open_url = url });
        const c = pair.native_fx.pendingSpawnAt(0).?;
        const d = pair.fx.pendingSpawnAt(0).?;
        try pair.native_fx.feedExit(c.key, 7);
        try pair.fx.feedExit(d.key, 7);
        try pair.drain();
    }
}

test "Markdown Viewer restores duplicate bounded recents and persists exact bytes after every adoption" {
    const pair = try Pair.create();
    defer pair.destroy();
    pair.model.setRecentStorePath("/viewer-test/data/recent.txt");
    reference.boot(&pair.model, &pair.native_fx);
    Host.dispatch(&pair.fx, .{ .app_data = "/viewer-test/data" });
    try pair.check();
    var paths: [4096]u8 = undefined;
    const too_long = [_]u8{'x'} ** 513;
    const input = try std.fmt.bufPrint(&paths, " \t\r\n/first.md\n/first.md\n{s}\n\t/second.md\r\n/third.md\n/fourth.md\n/fifth.md\n/sixth.md\n", .{too_long});
    try pair.file(.ok, input);
    try testing.expectEqual(@as(usize, 6), pair.model.recent_count);
    try pair.step(.{ .open_recent = 0 }, .{ .open_recent = 0 });
    try pair.file(.ok, "# First\n");
    var buffer: [3078]u8 = undefined;
    try testing.expectEqualStrings(pair.model.serializeRecent(&buffer), pair.fx.pendingFileAt(0).?.bytes);
    try pair.file(.ok, "");
    for (0..7) |index| {
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "/viewer-test/saved-{d}.md", .{index});
        try pair.step(.{ .edit_path = .clear }, .{ .edit_path = .clear });
        try pair.step(.{ .edit_path = .{ .insert_text = path } }, .{ .edit_path = .{ .insert_text = path } });
        try pair.step(.save_as, .save_as);
        try pair.file(.ok, "");
        try testing.expectEqualStrings(pair.model.serializeRecent(&buffer), pair.fx.pendingFileAt(0).?.bytes);
        try pair.file(.disk_full, ""); // Persistence failure does not undo the document adoption.
    }
    try pair.step(.{ .open_recent = 6 }, .{ .open_recent = 6 });
    try testing.expectEqual(@as(usize, 0), pair.fx.pendingFileCount());
}

test "Markdown Viewer complete appearance chrome scroll and token register match the native reference" {
    const pair = try Pair.create();
    defer pair.destroy();
    for ([_]canvas.ColorScheme{ .dark, .light }) |scheme| {
        try pair.step(.{ .system_scheme = scheme }, .{ .appearance = .{ .colorScheme = @enumFromInt(@intFromEnum(scheme)), .reduceMotion = true, .highContrast = true } });
        const chrome: sdk.WindowChrome = .{ .insets = .{ .left = 81.125, .right = 17.5, .top = 63.75, .bottom = 2 }, .tabs_projected = true };
        try pair.step(.{ .chrome_changed = chrome }, .{ .chrome_changed = .{ .insets = .{ .left = chrome.insets.left, .right = chrome.insets.right, .top = chrome.insets.top, .bottom = chrome.insets.bottom }, .buttons = .{ .x = 3, .y = 4, .width = 40, .height = 20 }, .tabsProjected = true } });
        const scroll: canvas.ScrollState = .{ .offset_y = 159.625, .offset_x = 7.25, .velocity_y = -80, .velocity_x = 3, .viewport_extent_x = 500, .viewport_extent_y = 600, .content_extent_x = 700, .content_extent_y = 1800 };
        try pair.step(.{ .doc_scrolled = scroll }, .{ .doc_scrolled = .{ .offsetY = scroll.offset_y, .offsetX = scroll.offset_x, .velocityY = scroll.velocity_y, .velocityX = scroll.velocity_x, .viewportExtentX = scroll.viewport_extent_x, .viewportExtentY = scroll.viewport_extent_y, .contentExtentX = scroll.content_extent_x, .contentExtentY = scroll.content_extent_y } });
        try pair.step(.{ .chrome_changed = .{} }, .{ .chrome_changed = .{ .insets = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 }, .buttons = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .tabsProjected = false } });
    }
}

fn themeView(ui: *canvas.Ui(core.Msg), model: *const core.Model) canvas.Ui(core.Msg).Node {
    return decoder.build(ui, model);
}
test "Markdown Viewer owns the complete custom register across accessibility and frame expiry" {
    const Adapter = sdk.TsUiApp(core);
    const app = try Adapter.create(testing.allocator, .{}, .{ .name = "markdown-viewer", .scene = .{}, .canvas_label = "viewer-canvas", .view = themeView });
    defer app.destroy();
    var model = reference.initialModel();
    for ([_]canvas.ColorScheme{ .light, .dark }) |scheme| {
        model.system_scheme = scheme;
        app.model = core.commitModelRoot(core.update(&app.model, .{ .appearance = .{ .colorScheme = @enumFromInt(@intFromEnum(scheme)), .reduceMotion = false, .highContrast = false } }).model).*;
        core.rt.frameReset();
        for (0..4) |flags| {
            app.system_appearance.high_contrast = flags & 1 != 0;
            app.system_appearance.reduce_motion = flags & 2 != 0;
            const actual = app.effectiveTokens();
            core.rt.frameReset();
            try parity.equal(reference.viewerTokens(&model), actual);
        }
    }
}

test "Markdown Viewer discovery limit precedes filtering and compiled Wyhash matches boundary lengths" {
    const pair = try Pair.create();
    defer pair.destroy();
    const lengths = [_]usize{ 8, 9, 12, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 95, 96, 97, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2047, 2048 };
    for (lengths) |length| {
        var bytes: [2056]u8 = undefined;
        @memset(&bytes, 'x');
        @memcpy(bytes[0..7], "http://");
        var doc: [2100]u8 = undefined;
        const text = try std.fmt.bufPrint(&doc, "![remote]({s})", .{bytes[0..length]});
        try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
        try pair.step(.{ .edit = .{ .insert_text = text } }, .{ .edit = .{ .insert_text = text } });
        try testing.expectEqual(@as(usize, 1), pair.fx.pendingImageLoadCount());
    }
    var document: std.Io.Writer.Allocating = .init(testing.allocator);
    defer document.deinit();
    for (0..14) |index| try document.writer.print("![image](https://images.test/{d}.png)\n\n", .{index});
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    try pair.step(.{ .edit = .{ .insert_text = document.written() } }, .{ .edit = .{ .insert_text = document.written() } });
    try testing.expectEqual(@as(usize, 12), pair.fx.pendingImageLoadCount());
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    document.clearRetainingCapacity();
    for (0..12) |index| try document.writer.print("![local](local-{d}.png)\n\n", .{index});
    try document.writer.writeAll("![later](https://images.test/later.png)");
    try pair.step(.{ .edit = .{ .insert_text = document.written() } }, .{ .edit = .{ .insert_text = document.written() } });
    try testing.expectEqual(@as(usize, 0), pair.fx.pendingImageLoadCount());
}
