//! Independent native callers and compiled cores share only OS/effect capabilities.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("spawn_exact_core");
const testing = std.testing;
const parity = @import("effects_media_parity.zig");
const Host = sdk.TsCoreHost(core);
const NativeMsg = union(enum) {
    first_line: sdk.EffectLine,
    second_line: sdk.EffectLine,
    first_exit: sdk.EffectExit,
    second_exit: sdk.EffectExit,
};
const NativeFx = sdk.Effects(NativeMsg);

const Pair = struct {
    native: NativeFx,
    compiled: Host.Fx,
    reports: std.ArrayList(NativeMsg) = .empty,
    retained: std.heap.ArenaAllocator,

    fn init(fake: bool) Pair {
        var pair: Pair = .{ .native = .init(testing.allocator), .compiled = .init(testing.allocator),
            .retained = .init(testing.allocator) };
        if (fake) {
            pair.native.executor = .fake;
            pair.compiled.executor = .fake;
        }
        Host.init(&pair.compiled);
        return pair;
    }
    fn deinit(self: *Pair) void {
        self.native.deinit();
        self.compiled.deinit();
        self.reports.deinit(testing.allocator);
        self.retained.deinit();
    }
    fn checkRequests(self: *Pair) !void {
        try testing.expectEqual(self.native.pendingSpawnCount(), self.compiled.pendingSpawnCount());
        for (0..self.native.pendingSpawnCount()) |index| {
            const expected = self.native.pendingSpawnAt(index).?;
            const actual = self.compiled.pendingSpawnAt(index).?;
            try testing.expectEqual(expected.key, actual.key);
            try testing.expectEqual(expected.argv.len, actual.argv.len);
            for (expected.argv, actual.argv) |a, b| try testing.expectEqualSlices(u8, a, b);
            try testing.expectEqualSlices(u8, expected.stdin, actual.stdin);
            try testing.expectEqualStrings(@tagName(expected.output), @tagName(actual.output));
            try testing.expectEqual(expected.max_line_bytes, actual.max_line_bytes);
        }
    }
    fn checkReports(self: *Pair) !void {
        const reports = Host.model().reports;
        try testing.expectEqual(self.reports.items.len, reports.len);
        for (self.reports.items, reports) |expected, actual| switch (expected) {
            .first_line, .second_line => |event| {
                try testing.expectEqualStrings("line", @tagName(actual.event));
                const report = actual;
                try testing.expectEqualStrings(if (expected == .first_line) "first" else "second", @tagName(report.route));
                try testing.expectEqual(event.key, try std.fmt.parseInt(u64, report.key, 10));
                try testing.expectEqualSlices(u8, event.line, report.line);
                try testing.expectEqual(event.truncated, report.truncated);
                try testing.expectEqual(parity.number(event.dropped_before), parity.number(report.droppedBefore));
                try testing.expectEqual(@as(f64, 0), parity.number(report.code));
                try testing.expectEqualStrings("exited", @tagName(report.reason));
                try testing.expectEqual(@as(f64, 0), parity.number(report.droppedLines));
                try testing.expectEqual(@as(usize, 0), report.output.len);
                try testing.expectEqual(@as(usize, 0), report.stderrTail.len);
                try testing.expect(!report.outputTruncated and !report.stderrTruncated);
            },
            .first_exit, .second_exit => |event| {
                try testing.expectEqualStrings("exit", @tagName(actual.event));
                const report = actual;
                try testing.expectEqualStrings(if (expected == .first_exit) "first" else "second", @tagName(report.route));
                try testing.expectEqual(event.key, try std.fmt.parseInt(u64, report.key, 10));
                try testing.expectEqual(parity.number(event.code), parity.number(report.code));
                try testing.expectEqualStrings(@tagName(event.reason), @tagName(report.reason));
                try testing.expectEqual(parity.number(event.dropped_lines), parity.number(report.droppedLines));
                try testing.expectEqualSlices(u8, event.output, report.output);
                try testing.expectEqual(event.output_truncated, report.outputTruncated);
                try testing.expectEqualSlices(u8, event.stderr_tail, report.stderrTail);
                try testing.expectEqual(event.stderr_truncated, report.stderrTruncated);
                try testing.expectEqual(@as(usize, 0), report.line.len);
                try testing.expect(!report.truncated);
                try testing.expectEqual(@as(f64, 0), parity.number(report.droppedBefore));
            },
        };
    }
    fn drain(self: *Pair) !void {
        var boundary = self.native.drainBoundary();
        while (self.native.takeMsgWithin(&boundary)) |borrowed| {
            var message = borrowed;
            switch (message) {
                .first_line, .second_line => |*event| event.line = try self.retained.allocator().dupe(u8, event.line),
                .first_exit, .second_exit => |*event| {
                    event.output = try self.retained.allocator().dupe(u8, event.output);
                    event.stderr_tail = try self.retained.allocator().dupe(u8, event.stderr_tail);
                },
            }
            try self.reports.append(testing.allocator, message);
        }
        Host.drain(&self.compiled);
        try self.checkRequests();
        try self.checkReports();
        const saved = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(saved);
        core.rt.frameReset();
        try testing.expectEqualSlices(u8, saved, core.persistenceSnapshot());
        try self.checkReports();
    }
    fn spawn(self: *Pair, key: u64, second: bool, argv: []const []const u8, stdin: []const u8, collect: bool, listen: bool) !void {
        var decimal: [20]u8 = undefined;
        const identity = try std.fmt.bufPrint(&decimal, "{d}", .{key});
        const request: core.Request = .{ .key = identity, .argv = argv, .stdin = stdin, .collect = collect, .listen = listen };
        self.native.spawn(.{ .key = key, .argv = argv, .stdin = if (stdin.len > 0) stdin else null,
            .output = if (collect) .collect else .lines,
            .on_line = if (collect or !listen) null else if (second) NativeFx.lineMsg(.second_line) else NativeFx.lineMsg(.first_line),
            .on_exit = if (second) NativeFx.exitMsg(.second_exit) else NativeFx.exitMsg(.first_exit) });
        Host.dispatch(&self.compiled, if (second) .{ .spawn_second = request } else .{ .spawn_first = request });
        @memset(&decimal, 'x');
        try self.checkRequests();
        try self.checkReports();
    }
    fn cancel(self: *Pair, key: u64) !void {
        var decimal: [20]u8 = undefined;
        const identity = try std.fmt.bufPrint(&decimal, "{d}", .{key});
        self.native.cancel(key);
        Host.dispatch(&self.compiled, .{ .cancel = identity });
        @memset(&decimal, 'x');
        try self.checkRequests();
    }
    fn line(self: *Pair, key: u64, bytes: []const u8, truncated: bool, dropped: u32) !void {
        try self.native.feedLineWithMetadata(key, bytes, truncated, dropped);
        try self.compiled.feedLineWithMetadata(key, bytes, truncated, dropped);
    }
    fn exit(self: *Pair, key: u64, code: i32, reason: sdk.EffectExitReason, output_truncated: bool, stderr_truncated: bool, dropped: u32) !void {
        try self.native.feedExitWithMetadata(key, code, reason, .{ .output_truncated = output_truncated, .stderr_truncated = stderr_truncated, .dropped_lines = dropped });
        try self.compiled.feedExitWithMetadata(key, code, reason, .{ .output_truncated = output_truncated, .stderr_truncated = stderr_truncated, .dropped_lines = dropped });
    }
};

test "exact subprocess keys complete loss reports and retained callback bytes match native" {
    var pair = Pair.init(true);
    defer pair.deinit();
    const keys = [_]u64{ 0, 2, 9007199254740993, std.math.maxInt(u64) };
    const reasons = [_]sdk.EffectExitReason{ .exited, .signaled, .cancelled, .rejected, .spawn_failed };
    for (keys, 0..) |key, index| for (reasons, 0..) |reason, reason_index| {
        var arg = [_]u8{ 'a', 0, 255, '\n', 128 };
        var stdin = [_]u8{ 0, 255, 'i', '\r', '\n' };
        try pair.spawn(key, index % 2 == 1, &.{ "program", &arg, "" }, &stdin, false, true);
        @memset(&arg, 42);
        @memset(&stdin, 43);
        core.rt.frameReset();
        try pair.checkRequests();
        var raw = [_]u8{ 0, 255, '\r', '\n', 128, 'x' };
        try pair.line(key, &raw, reason_index % 2 == 0, std.math.maxInt(u32));
        @memset(&raw, 44);
        try pair.exit(key, if (reason_index % 2 == 0) std.math.minInt(i32) else std.math.maxInt(i32), reason, true, false, std.math.maxInt(u32));
        try pair.drain();
        try pair.cancel(700);
        try pair.checkReports();
    };
    try testing.expectEqual(@as(usize, 40), pair.reports.items.len);
}

test "duplicate and undelivered keys retain the original route and refusal owns its terminal" {
    var pair = Pair.init(true);
    defer pair.deinit();
    const key = std.math.maxInt(u64);
    try pair.spawn(key, false, &.{"first"}, "", false, true);
    try pair.spawn(key, true, &.{"refused"}, "", false, true);
    try pair.line(key, "original", false, 0);
    try pair.drain();
    try testing.expect(pair.reports.items[0] == .second_exit);
    try testing.expect(pair.reports.items[1] == .first_line);
    try pair.exit(key, 0, .exited, false, false, 0);
    try pair.spawn(key, true, &.{"undelivered"}, "", false, true);
    try pair.drain();
    try pair.spawn(key, true, &.{"reused"}, "", false, true);
    try pair.line(key, "new route", false, 0);
    try pair.exit(key, 7, .exited, false, false, 0);
    try pair.drain();
    try testing.expect(pair.reports.items[pair.reports.items.len - 1] == .second_exit);
    try testing.expectEqual(@as(usize, 6), pair.reports.items.len);
}

test "native admission rejects empty and over-bound requests without replacing routes" {
    var pair = Pair.init(true);
    defer pair.deinit();
    try pair.spawn(2, false, &.{"original"}, "", false, true);
    try pair.spawn(2, true, &.{}, "", false, true);
    const too_many = [_][]const u8{"arg"} ** (sdk.max_effect_argv + 1);
    try pair.spawn(2, true, &too_many, "", false, true);
    const long = try testing.allocator.alloc(u8, sdk.max_effect_stdin_bytes + 1);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    try pair.spawn(2, true, &.{long[0 .. sdk.max_effect_argv_bytes + 1]}, "", false, true);
    try pair.spawn(2, true, &.{"stdin"}, long, false, true);
    for (0..sdk.max_effects - 1) |i| try pair.spawn(100 + i, i % 2 == 0, &.{"fill"}, "", false, false);
    try pair.spawn(700, true, &.{"full"}, "", false, true);
    try pair.line(2, "still original", false, 0);
    try pair.drain();
    try testing.expectEqual(@as(usize, 6), pair.reports.items.len);
    for (pair.reports.items[0..5]) |report| {
        try testing.expect(report == .second_exit);
        try testing.expectEqual(sdk.EffectExitReason.rejected, report.second_exit.reason);
    }
    try pair.cancel(2);
    for (0..sdk.max_effects - 1) |i| try pair.cancel(100 + i);
    try pair.drain();
    try testing.expectEqual(@as(usize, 22), pair.reports.items.len);
}

test "collect terminals preserve full output tail truncation and no line delivery" {
    var pair = Pair.init(true);
    defer pair.deinit();
    try pair.spawn(9007199254740993, true, &.{"collect"}, "", true, true);
    const bytes = try testing.allocator.alloc(u8, sdk.max_effect_collect_bytes + 1);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @intCast(i % 256);
    try pair.native.feedLine(9007199254740993, bytes);
    try pair.compiled.feedLine(9007199254740993, bytes);
    try pair.native.feedStderr(9007199254740993, bytes);
    try pair.compiled.feedStderr(9007199254740993, bytes);
    @memset(bytes, 77);
    try pair.exit(9007199254740993, -9, .signaled, false, false, 9);
    try pair.drain();
    try testing.expectEqual(@as(usize, 1), pair.reports.items.len);
    const terminal = pair.reports.items[0].second_exit;
    try testing.expect(terminal.output_truncated and terminal.stderr_truncated);
    try testing.expectEqual(sdk.max_effect_collect_bytes, terminal.output.len);
    try testing.expectEqual(sdk.max_effect_stderr_tail_bytes, terminal.stderr_tail.len);
    try pair.spawn(2, false, &.{"no listener"}, "", false, false);
    try pair.line(2, "unobserved", true, 4);
    try pair.exit(2, 0, .exited, false, false, 4);
    try pair.drain();
    try testing.expectEqual(@as(usize, 2), pair.reports.items.len);
}

test "exact cancellation filters old generations and retains routes across native key reuse" {
    var pair = Pair.init(true);
    defer pair.deinit();
    try pair.spawn(2, false, &.{"running"}, "", false, true);
    try pair.line(2, "discarded", false, 0);
    try pair.cancel(2);
    // Native fake cancellation releases its slot before the loop terminal
    // drains; the old callback must survive this accepted replacement.
    try pair.spawn(2, true, &.{"replacement"}, "", false, true);
    try pair.line(2, "new generation", false, 0);
    try pair.drain();
    try testing.expectEqual(@as(usize, 2), pair.reports.items.len);
    try testing.expectEqual(sdk.EffectExitReason.cancelled, pair.reports.items[0].first_exit.reason);
    try testing.expect(pair.reports.items[1] == .second_line);
    try pair.exit(2, 0, .exited, false, false, 0);
    // A posted ordinary exit keeps the native key occupied until delivery.
    try pair.spawn(2, false, &.{"undelivered"}, "", false, true);
    try pair.drain();
    try testing.expectEqual(@as(usize, 4), pair.reports.items.len);
    try pair.spawn(2, false, &.{"reused"}, "", false, true);
    try pair.line(2, "kept", false, 0);
    try pair.exit(2, 0, .exited, false, false, 0);
    try pair.drain();
    try pair.cancel(std.math.maxInt(u64));
    try pair.drain();
    try testing.expectEqual(@as(usize, 6), pair.reports.items.len);
}

test "recorded exact spawn cancellation consumes the recorded terminal once" {
    var pair = Pair.init(true);
    defer pair.deinit();
    pair.native.armReplay();
    pair.compiled.armReplay();
    try pair.spawn(std.math.maxInt(u64), false, &.{"recorded"}, "", false, true);
    try pair.line(std.math.maxInt(u64), "recorded line", true, 12);
    try pair.drain();
    try pair.cancel(std.math.maxInt(u64));
    try pair.drain();
    try testing.expectEqual(@as(usize, 1), pair.reports.items.len);
    try pair.exit(std.math.maxInt(u64), -1, .cancelled, true, true, 12);
    try pair.drain();
    try pair.native.finishReplay();
    try pair.compiled.finishReplay();
    try testing.expectEqual(@as(usize, 2), pair.reports.items.len);
    try testing.expectError(error.EffectNotFound, pair.compiled.feedExit(std.math.maxInt(u64), 0));
}

test "real subprocess executor delivers owned collect output stdin and stderr" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var pair = Pair.init(false);
    defer pair.deinit();
    try pair.spawn(2, false, &.{ "/bin/sh", "-c", "cat; printf 'tail' >&2; exit 7" }, "owned stdin\n", true, false);
    for (0..500) |_| {
        // Independent OS completions may arrive in different polling turns.
        var boundary = pair.native.drainBoundary();
        while (pair.native.takeMsgWithin(&boundary)) |message| {
            var retained = message;
            retained.first_exit.output = try pair.retained.allocator().dupe(u8, message.first_exit.output);
            retained.first_exit.stderr_tail = try pair.retained.allocator().dupe(u8, message.first_exit.stderr_tail);
            try pair.reports.append(testing.allocator, retained);
        }
        Host.drain(&pair.compiled);
        if (pair.reports.items.len == 1 and Host.model().reports.len == 1) break;
        try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    try pair.checkReports();
    try testing.expectEqual(@as(usize, 1), pair.reports.items.len);
    const terminal = pair.reports.items[0].first_exit;
    try testing.expectEqual(@as(i32, 7), terminal.code);
    try testing.expectEqual(sdk.EffectExitReason.exited, terminal.reason);
    try testing.expectEqualSlices(u8, "owned stdin\n", terminal.output);
    try testing.expectEqualSlices(u8, "tail", terminal.stderr_tail);
    core.rt.frameReset();
    try pair.checkReports();
}
