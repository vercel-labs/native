const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.journal_policy;
const j = sdk.runtime.session_journal;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const words = [_]u64{ 0, 1, 4294967295, 4294967296, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
var stages: [5]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 26) stages[input[1]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn same(stage: p.Stage, facts: p.Facts) !void {
    const expected = p.plan(null, stage, facts);
    const actual = p.plan(observed, stage, facts);
    try exact(expected, actual);
    core.rt.frameReset();
    try exact(expected, actual);
}
test "compiled journal preamble and framing preserve exact copied bytes and budgets" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 19);
    @memset(borrowed, 0x5a);
    _ = p.plan(observed, .preamble, .{ .fingerprint = 9007199254740993 });
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
    for (words) |fingerprint| {
        try same(.preamble, .{ .fingerprint = fingerprint });
        var preamble: [16]u8 = undefined;
        preamble[0..8].* = "NSDKSJNL".*;
        std.mem.writeInt(u64, preamble[8..], fingerprint, .little);
        for (0..17) |length| try same(.init, .{ .a = length, .fingerprint = fingerprint, .sample = preamble[0..length] });
        preamble[8] ^= 1;
        try same(.init, .{ .a = 16, .fingerprint = fingerprint, .sample = &preamble });
        preamble[0] = 0;
        try same(.init, .{ .a = 16, .fingerprint = fingerprint, .sample = &preamble });
    }
    for (std.enums.values(j.RecordKind)) |kind| for ([_]u64{ 0, 1, j.max_session_record_bytes - 1, j.max_session_record_bytes, j.max_session_record_bytes + 1, 4294967296, std.math.maxInt(u64) }) |length| {
        for (words) |capacity| try same(.frame, .{ .kind = @intFromEnum(kind), .a = length, .b = capacity, .limit = j.max_session_record_bytes });
        if (length <= j.max_session_record_bytes) {
            try same(.frame, .{ .kind = @intFromEnum(kind), .a = length, .b = length + 4, .limit = j.max_session_record_bytes });
            try same(.frame, .{ .kind = @intFromEnum(kind), .a = length, .b = length + 5, .limit = j.max_session_record_bytes });
        }
    };
}
test "compiled journal admission retains complete refusal precedence and reader position" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..256) |kind| for ([_]u32{ 0, 1, j.max_session_record_bytes, j.max_session_record_bytes + 1, std.math.maxInt(u32) }) |length| {
        var sample: [5]u8 = undefined;
        sample[0] = @intCast(kind);
        std.mem.writeInt(u32, sample[1..], length, .little);
        for ([_]u64{ 0, 1, 4, 5, 6, j.max_session_record_bytes + 5, 4294967300 }) |remaining| for (0..4) |flags| {
            try same(.next, .{ .a = 16 + remaining, .b = 16, .header = flags & 1 != 0, .ended = flags & 2 != 0, .sample = &sample, .limit = j.max_session_record_bytes });
        };
    };
}
test "compiled journal exact counters and seals retain every unsigned word" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (words[0 .. words.len - 1]) |pos| for (1..8) |kind| for (words[0 .. words.len - 1]) |count| {
        const sample = [_]u8{ @intCast(kind), 3, 0, 0, 0 };
        try same(.next, .{ .a = pos + 8, .b = pos, .header = kind != 1, .counts = @splat(count), .sample = &sample, .limit = j.max_session_record_bytes });
    };
    for (words) |count| for (words) |recorded| for (0..5) |field| {
        var sealed: [5]u64 = @splat(count);
        sealed[field] = recorded;
        try same(.seal, .{ .counts = @splat(count), .sealed = sealed });
    };
}
const Sink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
};
fn compareReaders(bytes: []const u8) !void {
    const native = j.Reader.init(bytes);
    const compiled = j.Reader.initWithPolicy(bytes, observed);
    if (native) |reader| {
        var expected = reader;
        var actual = try compiled;
        expected.storage.drop_paths = @splat("");
        actual.storage.drop_paths = @splat("");
        for (0..64) |_| {
            const a = expected.next();
            const b = actual.next();
            try std.testing.expectEqual(expected.pos, actual.pos);
            inline for (.{ "header", "end", "event_count", "effect_count", "checkpoint_count", "screenshot_count", "window_chrome_count", "storage" }) |field|
                try exact(@field(expected, field), @field(actual, field));
            if (a) |record| {
                try exact(record, try b);
                core.rt.frameReset();
                try exact(record, try b);
                if (record == null) return;
            } else |err| {
                try std.testing.expectError(err, b);
                return;
            }
        }
        return error.ReaderDidNotTerminate;
    } else |err| try std.testing.expectError(err, compiled);
}
fn writeJournal(sink: *Sink, policy: p.Policy) !void {
    const recorder = try std.testing.allocator.create(sdk.runtime.SessionRecorder);
    defer std.testing.allocator.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = sink, .write_fn = Sink.write });
    recorder.recording_policy = policy;
    recorder.begin(.{ .platform_name = "test", .app_name = "journal", .window_chrome_source = .native_queries });
    recorder.stageEvent(.wake);
    recorder.recordWindowChrome(.{ .window_id = std.math.maxInt(u64), .chrome = .{ .insets = .{ .left = 1.75 } } });
    recorder.commitEvent();
    recorder.recordEffect(.{ .kind = .line, .key = 9007199254740993, .payload = "raw\x00\xff" });
    recorder.recordCheckpoint(9007199254740993, std.math.maxInt(u64));
    recorder.recordScreenshot("raw\x00\xff", 1.75, std.math.maxInt(u64), 9007199254740993);
    recorder.finish();
    try std.testing.expect(!recorder.failed);
}
test "compiled journal consumers preserve whole wire bytes every truncation and bit corruption" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var native: Sink = .{};
    defer native.bytes.deinit(std.testing.allocator);
    var compiled: Sink = .{};
    defer compiled.bytes.deinit(std.testing.allocator);
    try writeJournal(&native, null);
    try writeJournal(&compiled, observed);
    try std.testing.expectEqualSlices(u8, native.bytes.items, compiled.bytes.items);
    try compareReaders(native.bytes.items);
    for (0..native.bytes.items.len) |length| try compareReaders(native.bytes.items[0..length]);
    for (native.bytes.items, 0..) |*byte, i| for (0..8) |bit| {
        byte.* ^= @as(u8, 1) << @intCast(bit);
        try compareReaders(native.bytes.items);
        byte.* ^= @as(u8, 1) << @intCast(bit);
        _ = i;
    };
    for (stages) |count| try std.testing.expect(count != 0);
}
test "compiled journal decode failures preserve admitted position counts and header ordering" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [21]u8 = undefined;
    _ = j.writePreambleWithPolicy(observed, &bytes);
    for (std.enums.values(j.RecordKind)) |kind| {
        _ = try j.frameRecordWithPolicy(observed, kind, "", bytes[16..]);
        var reader = try j.Reader.initWithPolicy(&bytes, observed);
        try std.testing.expectError(if (kind == .header) error.JournalCorrupt else error.JournalMissingHeader, reader.next());
        try std.testing.expectEqual(@as(usize, 21), reader.pos);
        reader.pos = 16;
        reader.header = .{ .platform_name = "test", .app_name = "journal" };
        try std.testing.expectError(error.JournalCorrupt, reader.next());
        try std.testing.expectEqual(@as(usize, 21), reader.pos);
        try std.testing.expectEqual(@as(u64, @intFromBool(kind == .event)), reader.event_count);
        try std.testing.expectEqual(@as(u64, @intFromBool(kind == .effect)), reader.effect_count);
        try std.testing.expectEqual(@as(u64, @intFromBool(kind == .checkpoint)), reader.checkpoint_count);
        try std.testing.expectEqual(@as(u64, @intFromBool(kind == .screenshot)), reader.screenshot_count);
        try std.testing.expectEqual(@as(u64, @intFromBool(kind == .window_chrome)), reader.window_chrome_count);
        try std.testing.expect(reader.end == null);
    }
}
