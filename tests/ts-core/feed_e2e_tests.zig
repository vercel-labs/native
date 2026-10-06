const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("feed_core");
const decoder = @import("feed_decoder");
const reference = @import("feed_reference.zig");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const testing = std.testing;
const Host = sdk.TsCoreHost(core);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));

fn compare(expected: *const reference.Model, actual: *const core.Model) !void {
    try testing.expectEqual(@as(i64, @intCast(expected.loaded)), actual.loaded);
    try testing.expectEqual(@as(i64, expected.fetches), actual.fetches);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected.liked), actual.liked);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected.boosted), actual.boosted);
    try testing.expectEqual(expected.selected != null, actual.selected != null);
    if (expected.selected) |value| try testing.expectEqual(@as(i64, @intCast(value)), actual.selected.?);
    try testing.expectEqual(@as(f64, expected.chrome_leading), actual.chrome_leading);
    try testing.expectEqual(@as(f64, expected.header_height), actual.header_height);
    try testing.expectEqual(expected.atCorpusEnd(), actual.atCorpusEnd());
}
const Pinned = struct {
    state: canvas.VirtualWindowState,
    fn resolve(context: ?*anyopaque, _: canvas.ObjectId) ?canvas.VirtualWindowState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.state;
    }
};
fn views(native: *const reference.Model, model: *const core.Model, offset: f32, viewport: f32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var source = Pinned{ .state = .{ .offset = offset, .viewport_extent = viewport, .mounted = true } };
    var left = canvas.Ui(reference.Msg).init(alloc);
    left.virtual_window_context = &source;
    left.virtual_window_source = Pinned.resolve;
    const expected = try left.finalize(reference.view(&left, native));
    for (0..3) |backend| {
        var right = canvas.Ui(core.Msg).init(alloc);
        right.virtual_window_context = &source;
        right.virtual_window_source = Pinned.resolve;
        const actual = try right.finalize(if (backend == 0) View.build(&right, model) else if (backend == 1) decoder.build(&right, model) else blk: {
            var interpreted = try canvas.MarkupView(core.Model, core.Msg).init(alloc, @embedFile("app.native"));
            break :blk try interpreted.build(&right, model);
        });
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
        try testing.expectEqualDeep(left.virtualWindows(), right.virtualWindows());
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |a, b| {
            try testing.expectEqual(a.id, b.id);
            try testing.expectEqual(a.event, b.event);
        }
        var a: [1024]canvas.WidgetLayoutNode = undefined;
        var b: [1024]canvas.WidgetLayoutNode = undefined;
        try parity.equal(try canvas.layoutWidgetTree(expected.root, .init(0, 0, 520, viewport), &a), try canvas.layoutWidgetTree(actual.root, .init(0, 0, 520, viewport), &b));
    }
}
fn step(native: *reference.Model, fx: *Host.Fx, before: reference.Msg, after: core.Msg) !void {
    reference.update(native, before);
    Host.dispatch(fx, after);
    try compare(native, Host.model());
}

test "Feed complete model all three view engines and viewport geometry match the native reference" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    var native = reference.Model{};
    try compare(&native, Host.model());
    try views(&native, Host.model(), 0, 760);
    try step(&native, &fx, .{ .toggle_like = 0 }, .{ .toggle_like = 0 });
    try step(&native, &fx, .{ .toggle_boost = 13 }, .{ .toggle_boost = 13 });
    try step(&native, &fx, .{ .select_post = 47 }, .{ .select_post = 47 });
    try views(&native, Host.model(), 1800.5, 480);
    try step(&native, &fx, .{ .select_post = 47 }, .{ .select_post = 47 });
    try step(&native, &fx, .{ .toggle_like = 99999 }, .{ .toggle_like = 99999 });
    try step(&native, &fx, .{ .toggle_boost = 100000 }, .{ .toggle_boost = 100000 });
    try step(&native, &fx, .load_more, .load_more);
    try step(&native, &fx, .{ .chrome_changed = .{ .insets = .{ .top = 60.25, .left = 80.5 } } }, .{ .chrome_changed = .{ .insets = .{ .top = 60.25, .left = 80.5, .right = 0, .bottom = 0 }, .buttons = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .tabsProjected = false } });
    try views(&native, Host.model(), 7000.25, 760);
    try testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    try testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    try testing.expect(fx.takeMsg() == null);
}

fn restored(native: *const reference.Model) !void {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    const snapshot = try testing.allocator.dupe(u8, core.persistenceSnapshot());
    defer testing.allocator.free(snapshot);
    var at: usize = 4;
    for (0..std.mem.readInt(u32, snapshot[0..4], .little)) |_| {
        const tag = std.mem.readInt(u32, snapshot[at..][0..4], .little);
        const len = std.mem.readInt(u32, snapshot[at + 4 ..][0..4], .little);
        at += 8;
        switch (tag) {
            0 => std.mem.writeInt(i64, snapshot[at..][0..8], @intCast(native.loaded), .little),
            1 => std.mem.writeInt(i64, snapshot[at..][0..8], native.fetches, .little),
            2, 3 => {
                const bytes = if (tag == 2) std.mem.asBytes(&native.liked) else std.mem.asBytes(&native.boosted);
                try testing.expectEqual(bytes.len + 4, len);
                @memcpy(snapshot[at + 4 ..][0..bytes.len], bytes);
            },
            else => {},
        }
        at += len;
    }
    Host.restoreSnapshot(snapshot);
    try compare(native, Host.model());
    const again = try testing.allocator.dupe(u8, core.persistenceSnapshot());
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, snapshot, again);
    const owned = try testing.allocator.dupe(u8, core.modelSnapshot());
    defer testing.allocator.free(owned);
    core.rt.frameReset();
    var expected = native.*;
    // The retained reference uses checked += in safety modes. Compare its
    // transition below overflow; qualify its ReleaseFast wrap separately.
    if (expected.fetches < std.math.maxInt(u32) or @import("builtin").mode == .ReleaseFast) {
        try step(&expected, &fx, .load_more, .load_more);
    } else {
        Host.dispatch(&fx, .load_more);
        try testing.expectEqual(@as(i64, 0), Host.model().fetches);
        try testing.expectEqual(@as(i64, @intCast(if (native.loaded < reference.max_posts) @min(reference.max_posts, native.loaded + reference.fetch_batch) else native.loaded)), Host.model().loaded);
    }
    try testing.expect(owned.len > 25000);
}
test "Feed restored corpus caps counter wrap and complete bitset padding retain canonical snapshot ownership" {
    for ([_]usize{ 0, 99500, 99999, 100000, 100001, 9007199254740991 }) |loaded| {
        var model = reference.Model{ .loaded = loaded, .fetches = std.math.maxInt(u32) };
        std.mem.asBytes(&model.liked)[12503] = 0xa5;
        std.mem.asBytes(&model.boosted)[12503] = 0x5a;
        try restored(&model);
    }
}

test "Feed compiled row queries preserve deterministic corpus text counters and exact upper index bytes" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    Host.init(&fx);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_]usize{ 0, 1, 13, 47, 41777, 99999, 4294967295, 4294967296, 4294967297, 1099511627777, 9007199254740990 }) |index| {
        const rows = Host.model().timelineRows(.{ .start_index = @intCast(index), .end_index = @intCast(index + 1), .first_visible_index = @floatFromInt(index), .last_visible_index = @floatFromInt(index), .item_extent = 0, .item_gap = 1.25, .scroll_offset = 3.5, .layout_offset = 4.25, .content_extent = 500.5, .before_extent = 2.75, .after_extent = 3.125, .anchor_extent = 20.75 }, alloc);
        try testing.expectEqual(@as(usize, 1), rows.len);
        const post = reference.postAt(index);
        try testing.expectEqual(@as(i64, @intCast(index)), rows[0].index);
        try testing.expectEqualStrings(post.author, rows[0].author);
        try testing.expectEqualStrings(post.handle, rows[0].handle);
        try testing.expectEqualStrings(post.initials, rows[0].initials);
        try testing.expectEqualStrings(reference.postBody(alloc, index), rows[0].body);
        try testing.expectEqual(@as(i64, post.likes), rows[0].likes);
        try testing.expectEqual(@as(i64, post.boosts), rows[0].boosts);
        try testing.expectEqual(@as(i64, post.replies), rows[0].replies);
        try testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "Post {d} by {s}", .{ index, post.author }), rows[0].label);
        try testing.expectEqual(reference.postExtentEstimate(null, index), core.Model.virtualExtentEstimate(@ptrFromInt(2), index));
        core.rt.frameReset();
    }
}

fn replay(comptime compiled: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    var journal = parity.JournalBuffer.init();
    defer journal.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    var blobs = sdk.runtime.session_blobs.MemoryBlobStore.init(testing.allocator);
    defer blobs.deinit();
    recorder.* = .init(.{ .context = &journal, .write_fn = parity.JournalBuffer.write });
    recorder.blob_sink = blobs.sink();
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "feed", 520, 760));
    var full: ?[]u8 = null;
    defer if (full) |bytes| testing.allocator.free(bytes);
    var fingerprint: u64 = 0;
    {
        const app = try Adapter.create(testing.allocator, .{}, .{ .name = "feed", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled) decoder.build else View.build });
        defer app.destroy();
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(520, 760) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.start(app.app());
        try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{ .label = reference.canvas_label, .size = .init(520, 760), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        try parity.action(&harness.runtime, app.app(), &app.tree.?.root, reference.canvas_label, "Like post 0", "toggle");
        try parity.action(&harness.runtime, app.app(), &app.tree.?.root, reference.canvas_label, "Boost post 0", "toggle");
        const timeline = parity.find(&app.tree.?.root, "Timeline").?;
        var command: [120]u8 = undefined;
        try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command, "widget-wheel {s} {d} 1800", .{ reference.canvas_label, timeline.id }));
        try harness.runtime.dispatchPlatformEvent(app.app(), .frame_requested);
        full = try std.json.Stringify.valueAlloc(testing.allocator, app.model, .{});
        fingerprint = harness.runtime.sessionStateFingerprint();
        recorder.finish();
        try testing.expect(!recorder.failed);
    }
    const app = try Adapter.create(testing.allocator, .{}, .{ .name = "feed", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled) decoder.build else View.build });
    defer app.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(520, 760) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, app.app(), journal.bytes.written(), .{ .require_same_platform = false, .blobs = blobs.source() });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    const actual = try std.json.Stringify.valueAlloc(testing.allocator, app.model, .{});
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(full.?, actual);
}
test "Feed full committed snapshots scroll and action journals replay on both compiled view backends" {
    try replay(false);
    try replay(true);
}
