//! Behavioral harness for dual-feed-table, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig and run through `native test`.
//! Drives update with the deterministic fake effects executor and asserts
//! the same behavioral spec the ts track's harness asserts.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

const feed_body =
    "[\n" ++
    "  {\"name\":\"canvas\",\"downloads\":4210,\"size_kb\":88},\n" ++
    "  { \"name\": \"runtime\", \"downloads\": 1730, \"size_kb\": 412 },\n" ++
    "  {\"name\":\"tooling\",\"downloads\":9020,\"size_kb\":260}\n" ++
    "]\n";

const Rig = struct {
    model: main.Model,
    fx: main.Effects,
    arena_state: std.heap.ArenaAllocator,

    fn init() Rig {
        var fx = main.Effects.init(testing.allocator);
        fx.executor = .fake;
        return .{
            .model = main.initialModel(),
            .fx = fx,
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Rig) void {
        self.arena_state.deinit();
        self.fx.deinit();
    }

    fn dispatch(self: *Rig, msg: main.Msg) void {
        main.update(&self.model, msg, &self.fx);
    }

    fn drain(self: *Rig) void {
        while (self.fx.takeMsg()) |msg| main.update(&self.model, msg, &self.fx);
    }

    fn rows(self: *Rig) []const main.Release {
        return self.model.visibleRows(self.arena_state.allocator());
    }

    /// Refresh, assert exactly one live fetch, and return it.
    fn refreshedFetch(self: *Rig) !main.Effects.FetchRequest {
        self.dispatch(.refresh);
        const request = self.fx.pendingFetchAt(0) orelse return error.NoFetchIssued;
        try testing.expectEqual(@as(usize, 1), self.fx.pendingFetchCount());
        return request;
    }

    fn loadFeed(self: *Rig) !void {
        const request = try self.refreshedFetch();
        try self.fx.feedResponse(request.key, 200, feed_body);
        self.drain();
    }
};

test "starts idle with no rows" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.phase == .idle);
    try testing.expectEqual(@as(usize, 0), rig.rows().len);
}

test "refresh issues one buffered GET to the pinned URL" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedFetch();
    try testing.expectEqual(std.http.Method.GET, request.method);
    try testing.expectEqualStrings("https://feeds.native-sdk.dev/releases.json", request.url);
    try testing.expectEqual(native_sdk.FetchResponseMode.buffered, request.response);
    try testing.expect(rig.model.phase == .loading);
}

test "refresh while loading issues nothing" {
    var rig = Rig.init();
    defer rig.deinit();
    _ = try rig.refreshedFetch();
    rig.dispatch(.refresh);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingFetchCount());
    try testing.expect(rig.model.phase == .loading);
}

test "a 200 body parses and sorts by downloads descending by default" {
    var rig = Rig.init();
    defer rig.deinit();
    try rig.loadFeed();
    try testing.expect(rig.model.phase == .loaded);
    try testing.expect(rig.model.sort_key == .downloads);
    const rows = rig.rows();
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("tooling", rows[0].name);
    try testing.expect(rows[0].downloads == 9020);
    try testing.expect(rows[0].size_kb == 260);
    try testing.expectEqualStrings("canvas", rows[1].name);
    try testing.expect(rows[1].downloads == 4210);
    try testing.expect(rows[1].size_kb == 88);
    try testing.expectEqualStrings("runtime", rows[2].name);
    try testing.expect(rows[2].downloads == 1730);
    try testing.expect(rows[2].size_kb == 412);
}

test "set_sort reorders by name and back by downloads" {
    var rig = Rig.init();
    defer rig.deinit();
    try rig.loadFeed();
    rig.dispatch(.{ .set_sort = .name });
    var rows = rig.rows();
    try testing.expectEqualStrings("canvas", rows[0].name);
    try testing.expectEqualStrings("runtime", rows[1].name);
    try testing.expectEqualStrings("tooling", rows[2].name);
    rig.dispatch(.{ .set_sort = .downloads });
    rows = rig.rows();
    try testing.expectEqualStrings("tooling", rows[0].name);
}

test "a non-200 response is failed and keeps the previous rows" {
    var rig = Rig.init();
    defer rig.deinit();
    try rig.loadFeed();
    const request = try rig.refreshedFetch();
    try rig.fx.feedResponse(request.key, 500, "oops");
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
    try testing.expectEqual(@as(usize, 3), rig.rows().len);
}

test "a transport failure is failed and keeps the previous rows" {
    var rig = Rig.init();
    defer rig.deinit();
    try rig.loadFeed();
    const request = try rig.refreshedFetch();
    try rig.fx.feedResponseOutcome(request.key, .timed_out, 0, "");
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
    try testing.expectEqual(@as(usize, 3), rig.rows().len);
}

test "an empty array is a loaded state with zero rows" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedFetch();
    try rig.fx.feedResponse(request.key, 200, "[]");
    rig.drain();
    try testing.expect(rig.model.phase == .loaded);
    try testing.expectEqual(@as(usize, 0), rig.rows().len);
}

test "a malformed 200 body is failed, never a partial table" {
    var rig = Rig.init();
    defer rig.deinit();
    try rig.loadFeed();
    const request = try rig.refreshedFetch();
    try rig.fx.feedResponse(request.key, 200, "[{\"name\":\"x\",\"downloads\":1");
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
    try testing.expectEqual(@as(usize, 3), rig.rows().len);
}
