//! Behavioral harness for dual-feed-table, ts track. The grader copies this
//! next to the transpiled core.zig, the rt kernel, and cmdview.zig, then
//! runs `zig test harness.zig`. Asserts the shared behavioral spec: one GET
//! to the pinned URL per Refresh, guarded re-entry, parsing, both sort
//! orders, and the honest failure/empty states.

const std = @import("std");
const core = @import("core.zig");
const cmdview = @import("cmdview.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_buf: [8192]u8 = undefined;

const feed_body =
    "[\n" ++
    "  {\"name\":\"canvas\",\"downloads\":4210,\"size_kb\":88},\n" ++
    "  { \"name\": \"runtime\", \"downloads\": 1730, \"size_kb\": 412 },\n" ++
    "  {\"name\":\"tooling\",\"downloads\":9020,\"size_kb\":260}\n" ++
    "]\n";

fn fresh() void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
}

fn dispatch(msg: core.Msg) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(g_buf[0..r.cmd.len], r.cmd);
    rt.frameReset();
    return g_buf[0..r.cmd.len];
}

fn loadFeed() void {
    _ = dispatch(.refresh);
    _ = dispatch(.{ .feed_loaded = .{ .status = 200, .body = feed_body } });
}

test "starts idle with no rows" {
    fresh();
    try std.testing.expect(g_model.phase == .idle);
    try std.testing.expectEqual(@as(usize, 0), core.visibleRows(g_model).len);
}

test "refresh issues one buffered GET to the pinned URL" {
    fresh();
    const cmd = dispatch(.refresh);
    const fetch = cmdview.findOp(cmd, .fetch) orelse return error.NoFetchIssued;
    try std.testing.expectEqual(@as(u8, 0), fetch.method); // GET
    try std.testing.expectEqualStrings("https://feeds.native-sdk.dev/releases.json", fetch.url);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).feed_loaded), fetch.ok_tag);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).feed_failed), fetch.err_tag);
    try std.testing.expect(g_model.phase == .loading);
}

test "refresh while loading issues nothing" {
    fresh();
    _ = dispatch(.refresh);
    const second = dispatch(.refresh);
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(second, .fetch));
    try std.testing.expect(g_model.phase == .loading);
}

test "a 200 body parses and sorts by downloads descending by default" {
    fresh();
    loadFeed();
    try std.testing.expect(g_model.phase == .loaded);
    try std.testing.expect(g_model.sort_key == .downloads);
    const rows = core.visibleRows(g_model);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("tooling", rows[0].name);
    try std.testing.expect(rows[0].downloads == 9020);
    try std.testing.expect(rows[0].size_kb == 260);
    try std.testing.expectEqualStrings("canvas", rows[1].name);
    try std.testing.expect(rows[1].downloads == 4210);
    try std.testing.expect(rows[1].size_kb == 88);
    try std.testing.expectEqualStrings("runtime", rows[2].name);
    try std.testing.expect(rows[2].downloads == 1730);
    try std.testing.expect(rows[2].size_kb == 412);
}

test "set_sort reorders by name and back by downloads" {
    fresh();
    loadFeed();
    _ = dispatch(.{ .set_sort = .name });
    var rows = core.visibleRows(g_model);
    try std.testing.expectEqualStrings("canvas", rows[0].name);
    try std.testing.expectEqualStrings("runtime", rows[1].name);
    try std.testing.expectEqualStrings("tooling", rows[2].name);
    _ = dispatch(.{ .set_sort = .downloads });
    rows = core.visibleRows(g_model);
    try std.testing.expectEqualStrings("tooling", rows[0].name);
}

test "a non-200 response is failed and keeps the previous rows" {
    fresh();
    loadFeed();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .feed_loaded = .{ .status = 500, .body = "oops" } });
    try std.testing.expect(g_model.phase == .failed);
    try std.testing.expectEqual(@as(usize, 3), core.visibleRows(g_model).len);
}

test "a transport failure is failed and keeps the previous rows" {
    fresh();
    loadFeed();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .feed_failed = "timed_out" });
    try std.testing.expect(g_model.phase == .failed);
    try std.testing.expectEqual(@as(usize, 3), core.visibleRows(g_model).len);
}

test "an empty array is a loaded state with zero rows" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .feed_loaded = .{ .status = 200, .body = "[]" } });
    try std.testing.expect(g_model.phase == .loaded);
    try std.testing.expectEqual(@as(usize, 0), core.visibleRows(g_model).len);
}

test "a malformed 200 body is failed, never a partial table" {
    fresh();
    loadFeed();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .feed_loaded = .{ .status = 200, .body = "[{\"name\":\"x\",\"downloads\":1" } });
    try std.testing.expect(g_model.phase == .failed);
    try std.testing.expectEqual(@as(usize, 3), core.visibleRows(g_model).len);
}
