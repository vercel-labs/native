//! Tier-2 record-store effect coverage: the public Zig surface remains inert
//! command data until Effects performs it, and every SQLite answer returns as
//! the same routed/journaled host-result message family used by TS cores.

const std = @import("std");
const effects_mod = @import("effects.zig");
const record_store = @import("record_store.zig");

const Msg = union(enum) { result: effects_mod.EffectHostResult };
const Fx = effects_mod.Effects(Msg);

fn takeResult(fx: *Fx) !effects_mod.EffectHostResult {
    for (0..100_000) |_| {
        if (fx.takeMsg()) |msg| return msg.result;
        std.Thread.yield() catch {};
    }
    return error.TestExpectedMsg;
}

test "record-store effects round-trip CRUD and preserve empty versus missing" {
    var store = try record_store.Store.openMemory(std.testing.allocator);
    defer store.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRecordStore(store.binding());

    fx.storeSet(.{ .key = 1, .record_key = "doc/1", .bytes = "", .on_result = Fx.hostMsg(.result) });
    const set = try takeResult(&fx);
    try std.testing.expect(set.ok);
    try std.testing.expectEqual(@as(usize, 0), set.bytes.len);

    fx.storeGet(.{ .key = 2, .record_key = "doc/1", .on_result = Fx.hostMsg(.result) });
    const hit = try takeResult(&fx);
    try std.testing.expect(hit.ok);
    try std.testing.expectEqualSlices(u8, &.{1}, hit.bytes);

    fx.storeDelete(.{ .key = 3, .record_key = "doc/1", .on_result = Fx.hostMsg(.result) });
    try std.testing.expect((try takeResult(&fx)).ok);
    fx.storeGet(.{ .key = 4, .record_key = "doc/1", .on_result = Fx.hostMsg(.result) });
    const miss = try takeResult(&fx);
    try std.testing.expect(miss.ok);
    try std.testing.expectEqualSlices(u8, &.{0}, miss.bytes);
}

test "record-store effects apply setMany atomically and page prefix scans" {
    var store = try record_store.Store.openMemory(std.testing.allocator);
    defer store.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRecordStore(store.binding());

    const entries = [_]Fx.StoreEntry{
        .{ .key = "chat/1", .bytes = "one" },
        .{ .key = "chat/2", .bytes = "two" },
        .{ .key = "other/1", .bytes = "skip" },
    };
    fx.storeSetMany(.{ .key = 10, .entries = &entries, .on_result = Fx.hostMsg(.result) });
    try std.testing.expect((try takeResult(&fx)).ok);

    fx.storeScan(.{ .key = 11, .prefix = "chat/", .limit = 1, .on_result = Fx.hostMsg(.result) });
    const page = try takeResult(&fx);
    try std.testing.expect(page.ok);
    var cursor: usize = 0;
    try std.testing.expectEqual(@as(u32, 1), readU32(page.bytes, &cursor));
    try std.testing.expectEqualStrings("chat/1", readField(page.bytes, &cursor));
    try std.testing.expectEqualStrings("one", readField(page.bytes, &cursor));
    try std.testing.expectEqualStrings("chat/1", readField(page.bytes, &cursor));
    try std.testing.expectEqual(page.bytes.len, cursor);
}

test "a synchronous get in the same command walk observes the preceding write" {
    var store = try record_store.Store.openMemory(std.testing.allocator);
    defer store.deinit();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindRecordStore(store.binding());

    fx.storeSet(.{ .key = 12, .record_key = "ordered/key", .bytes = "visible", .on_result = Fx.hostMsg(.result) });
    fx.storeGet(.{ .key = 13, .record_key = "ordered/key", .on_result = Fx.hostMsg(.result) });

    const first = try takeResult(&fx);
    const second = try takeResult(&fx);
    try std.testing.expect(first.ok);
    try std.testing.expect(second.ok);
    const read = if (first.key == 13) first else second;
    try std.testing.expect(read.ok);
    try std.testing.expectEqualSlices(u8, "visible", read.bytes[1..]);
}

test "record-store effects reject bounds and absent capability loudly" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.storeGet(.{ .key = 20, .record_key = "missing", .on_result = Fx.hostMsg(.result) });
    const absent = try takeResult(&fx);
    try std.testing.expect(!absent.ok);
    try std.testing.expectEqualStrings("rejected", absent.bytes);

    var oversized_key: [record_store.max_key_bytes + 1]u8 = undefined;
    @memset(&oversized_key, 'k');
    fx.storeGet(.{ .key = 21, .record_key = &oversized_key, .on_result = Fx.hostMsg(.result) });
    const bounded = try takeResult(&fx);
    try std.testing.expect(!bounded.ok);
    try std.testing.expectEqualStrings("bad_key", bounded.bytes);
}

test "record-store requests have capacity independent of generic effects" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    for (0..effects_mod.max_effects) |index| {
        fx.hostRequest(.{
            .key = 100 + index,
            .name = "fixture.request",
            .on_result = Fx.hostMsg(.result),
        });
    }
    for (0..effects_mod.max_store_effects) |index| {
        fx.storeGet(.{
            .key = 1_000 + index,
            .record_key = "fixture/key",
            .on_result = Fx.hostMsg(.result),
        });
    }
    try std.testing.expectEqual(
        effects_mod.max_effects + effects_mod.max_store_effects,
        fx.pendingHostCount(),
    );

    fx.storeGet(.{
        .key = 2_000,
        .record_key = "fixture/overflow",
        .on_result = Fx.hostMsg(.result),
    });
    const refused = try takeResult(&fx);
    try std.testing.expect(!refused.ok);
    try std.testing.expectEqualStrings("rejected", refused.bytes);
}

test "record-store keys replace on reissue and cancel silently" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.storeGet(.{ .key = 30, .record_key = "old/key", .on_result = Fx.hostMsg(.result) });
    fx.storeGet(.{ .key = 30, .record_key = "new/key", .on_result = Fx.hostMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const replacement = fx.pendingHostAt(0).?;
    try std.testing.expectEqualStrings("core.store.get", replacement.name);
    var payload_at: usize = 4;
    try std.testing.expectEqualStrings("new/key", readField(replacement.payload, &payload_at));
    try std.testing.expectEqual(replacement.payload.len, payload_at);
    try fx.feedHostResult(30, true, &.{ 1, 'n', 'e', 'w' });
    const result = try takeResult(&fx);
    try std.testing.expectEqual(@as(u64, 30), result.key);
    try std.testing.expectEqualSlices(u8, &.{ 1, 'n', 'e', 'w' }, result.bytes);

    fx.storeScan(.{ .key = 31, .prefix = "chat/", .on_result = Fx.hostMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    fx.cancel(31);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingHostCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedHostResult(31, true, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expect(fx.takeMsg() == null);
}

test "draining a store terminal retires a producer preempted after enqueue" {
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const key = 32;
    fx.storeGet(.{ .key = key, .record_key = "doc/32", .on_result = Fx.hostMsg(.result) });
    try fx.feedHostResult(key, true, &.{0});

    // Reconstruct the real write worker's preemption window exactly:
    // `storeWorkerMain` publishes the terminal entry, then stores
    // `.draining`. A consumer can acquire the queue between those two
    // operations and observe the queued result while the slot still says
    // `.running`. The fake feed stores first, so rewind just that state.
    for (&fx.slots) |*slot| {
        if (slot.kind == .store and slot.key == key) slot.state.store(.running, .release);
    }

    const result = try takeResult(&fx);
    try std.testing.expect(result.ok);
    try std.testing.expectEqualSlices(u8, &.{0}, result.bytes);

    // Delivery is the key-freeing instant. The drain must publish the
    // terminal state itself rather than depending on the preempted worker
    // to resume before update handles the result.
    for (&fx.slots) |*slot| {
        if (slot.kind != .store or slot.key != key) continue;
        try std.testing.expectEqual(.draining, slot.state.load(.acquire));
        try std.testing.expect(slot.fetch_buffer == null);
        return;
    }
    return error.TestExpectedStoreSlot;
}

fn readU32(bytes: []const u8, cursor: *usize) u32 {
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn readField(bytes: []const u8, cursor: *usize) []const u8 {
    const len: usize = @intCast(readU32(bytes, cursor));
    const field = bytes[cursor.*..][0..len];
    cursor.* += len;
    return field;
}
