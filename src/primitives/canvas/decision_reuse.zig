//! Shared pieces for reusing exact compiled-policy decisions.
//!
//! Compiled policies answer from their request bytes alone, and layout asks
//! the same questions on every frame. Callers keep earlier answers and reuse
//! one only after the stored request equals the new request byte for byte.
//! The hash below only picks a slot; equality always decides reuse.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn memcmp(a: *const anyopaque, b: *const anyopaque, len: usize) c_int;

/// Byte equality that stays cheap in Debug hosts: libc's comparison is
/// optimized regardless of the caller's build mode.
pub fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    if (comptime builtin.link_libc) return memcmp(a.ptr, b.ptr, a.len) == 0;
    return std.mem.eql(u8, a, b);
}

/// A slot index over a short prefix of the bytes plus their length. Requests
/// that share the prefix share a slot; reuse still requires full equality.
pub fn slotHash(seed: u64, bytes: []const u8, prefix: usize) u64 {
    var hash: u64 = 0xcbf29ce484222325 ^ seed ^ (@as(u64, bytes.len) << 32);
    for (bytes[0..@min(prefix, bytes.len)]) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash ^ (hash >> 29);
}

pub const Policy = *const fn ([]const u8, []u8) usize;

/// Only registered policies are reused. A host registers a policy when it
/// answers from its request bytes alone, as a compiled TypeScript core's
/// window policy does. Any other callback (a custom policy, a recording test
/// double) is called every time, exactly as before.
var pure_policies: [8]std.atomic.Value(usize) = @splat(.init(0));

pub fn registerPurePolicy(policy: Policy) void {
    const address = @intFromPtr(policy);
    for (&pure_policies) |*slot| {
        if (slot.load(.acquire) == address) return;
        if (slot.cmpxchgStrong(0, address, .acq_rel, .acquire) == null) return;
    }
}

pub fn isPure(policy: Policy) bool {
    const address = @intFromPtr(policy);
    for (&pure_policies) |*slot| {
        const value = slot.load(.acquire);
        if (value == address) return true;
        if (value == 0) return false;
    }
    return false;
}

/// A per-thread table of exact decisions for requests of at most
/// `max_request` bytes whose result is `result_len` bytes. Each slot keeps one
/// request and its result; a collision replaces the slot. Allocated on first
/// use, so threads that never ask pay nothing.
pub fn Table(comptime slot_count: usize, comptime max_request: usize, comptime result_len: usize) type {
    return struct {
        const Entry = struct {
            policy: ?Policy = null,
            len: usize = 0,
            request: [max_request]u8 = undefined,
            result: [result_len]u8 = undefined,
        };
        threadlocal var entries: ?*[slot_count]Entry = null;

        /// The same contract as calling `policy(request, result)` directly.
        pub fn decide(policy: Policy, request: []const u8, result: *[result_len]u8) usize {
            if (request.len > max_request or !isPure(policy)) return policy(request, result);
            const table = entries orelse allocate() orelse return policy(request, result);
            const entry = &table[@intCast(slotHash(@intFromPtr(policy), request, 256) % slot_count)];
            const owned = if (entry.policy) |owner| owner == policy else false;
            if (owned and entry.len == request.len and bytesEqual(entry.request[0..request.len], request)) {
                result.* = entry.result;
                return result_len;
            }
            const len = policy(request, result);
            if (len == result_len) {
                entry.policy = policy;
                entry.len = request.len;
                @memcpy(entry.request[0..request.len], request);
                entry.result = result.*;
            }
            return len;
        }

        fn allocate() ?*[slot_count]Entry {
            const table = std.heap.smp_allocator.create([slot_count]Entry) catch return null;
            table.* = @splat(.{});
            entries = table;
            return table;
        }
    };
}

var table_test_calls: usize = 0;
fn tableTestPolicy(request: []const u8, result: []u8) usize {
    table_test_calls += 1;
    @memset(result, request[request.len - 1]);
    return result.len;
}

test "decision tables reuse only identical requests of registered policies" {
    const T = Table(8, 4, 2);
    var unregistered: [2]u8 = undefined;
    table_test_calls = 0;
    _ = T.decide(tableTestPolicy, &.{ 1, 2 }, &unregistered);
    _ = T.decide(tableTestPolicy, &.{ 1, 2 }, &unregistered);
    try std.testing.expectEqual(@as(usize, 2), table_test_calls);
    registerPurePolicy(tableTestPolicy);
    var result: [2]u8 = undefined;
    table_test_calls = 0;
    try std.testing.expectEqual(@as(usize, 2), T.decide(tableTestPolicy, &.{ 1, 2 }, &result));
    try std.testing.expectEqualSlices(u8, &.{ 2, 2 }, &result);
    result = .{ 0, 0 };
    try std.testing.expectEqual(@as(usize, 2), T.decide(tableTestPolicy, &.{ 1, 2 }, &result));
    try std.testing.expectEqualSlices(u8, &.{ 2, 2 }, &result);
    try std.testing.expectEqual(@as(usize, 1), table_test_calls);
    _ = T.decide(tableTestPolicy, &.{ 1, 3 }, &result);
    try std.testing.expectEqualSlices(u8, &.{ 3, 3 }, &result);
    _ = T.decide(tableTestPolicy, &.{ 1, 2, 3, 4, 5 }, &result);
    _ = T.decide(tableTestPolicy, &.{ 1, 2, 3, 4, 5 }, &result);
    try std.testing.expectEqual(@as(usize, 4), table_test_calls);
}

test "bytesEqual compares every byte and the length" {
    try std.testing.expect(bytesEqual("", ""));
    try std.testing.expect(bytesEqual("abc", "abc"));
    try std.testing.expect(!bytesEqual("abc", "abd"));
    try std.testing.expect(!bytesEqual("abc", "ab"));
}
