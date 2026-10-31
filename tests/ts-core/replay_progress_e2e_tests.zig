const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.replay_progress_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const words = [_]u64{ 0, 1, 15, 16, 4294967295, 4294967296, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
var stages: [7]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 25) stages[input[1]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn same(stage: p.Stage, facts: p.Facts) !void {
    const reference = p.plan(null, stage, facts);
    const actual = p.plan(observed, stage, facts);
    try exact(reference, actual);
    core.rt.frameReset();
    try exact(reference, actual);
}
test "compiled replay progress preserves unsigned accounting and all mismatch retention boundaries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 19);
    @memset(borrowed, 0x5a);
    _ = p.plan(observed, .count, .{ .a = 9007199254740993 });
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
    for (words[0 .. words.len - 1]) |count| {
        try same(.count, .{ .a = count });
        for (words[0 .. words.len - 1]) |mismatches| for (words) |expected| for (words) |actual| {
            try same(.compare, .{ .a = count, .b = mismatches, .c = expected, .d = actual });
        };
    }
}
test "compiled replay progress preserves blob refusal precedence and finish classification" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (words) |length| for (words) |limit| {
        for (0..2) |available| try same(.blob_admission, .{ .code = @intCast(available), .a = length, .b = limit });
        try same(.blob_result, .{ .a = length, .b = limit });
    };
    for (0..3) |code| try same(.finish, .{ .code = @intCast(code) });
}
test "compiled replay progress selects first open exact window and raw GPU label across complete tables" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var windows: [sdk.platform.max_windows]p.Slot = undefined;
    for (words) |target| {
        for (&windows) |*slot| slot.* = .{ .open = true, .id = target ^ 1 };
        for ([_]usize{ 0, 7, 15 }) |index| {
            windows[index] = .{ .open = true, .id = target };
            try same(.window, .{ .a = target, .slots = &windows });
            windows[index].open = false;
            try same(.window, .{ .a = target, .slots = &windows });
        }
    }
    const full: [64]u8 = @splat(255);
    const overlong: [65]u8 = @splat(255);
    for ([_][]const u8{ "", "raw\x00\xff\xc3(", &full, &overlong }) |target| {
        var slots: [sdk.platform.max_views]p.Slot = undefined;
        for (&slots) |*slot| slot.* = .{ .open = false, .id = std.math.maxInt(u64), .kind = .gpu_surface, .label = target[0..@min(target.len, 64)] };
        slots[0].open = true;
        for (std.enums.values(sdk.platform.ViewKind)) |kind| {
            slots[0].kind = kind;
            for ([_]usize{ 1, 17, 31 }) |index| {
                slots[index].open = true;
                try same(.view, .{ .label = target, .slots = &slots });
                slots[index].open = false;
            }
        }
    }
    try same(.view, .{ .label = "missing" });
    try same(.window, .{ .a = std.math.maxInt(u64) });
}
const Sink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
};
const Probe = struct {
    feeds: usize = 0,
    arms: usize = 0,
    finishes: usize = 0,
    fail: ?anyerror = null,
    payload: [64]u8 = @splat(0),
    length: usize = 0,
    fn control(context: *anyopaque, command: sdk.runtime.ReplayControl) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (command) {
            .arm => self.arms += 1,
            .feed => |effect| {
                self.feeds += 1;
                self.length = effect.payload.len;
                @memcpy(self.payload[0..self.length], effect.payload);
            },
            .finish => {
                self.finishes += 1;
                if (self.fail) |err| return err;
            },
        }
    }
};
fn expectReport(a: sdk.runtime.ReplayReport, b: sdk.runtime.ReplayReport) !void {
    inline for (.{ "protocol_fingerprint", "events_replayed", "effects_fed", "effects_skipped", "checkpoints_verified", "screenshots_verified", "mismatch_count" }) |field| try exact(@field(a, field), @field(b, field));
    try exact(a.mismatches[0..@min(a.mismatch_count, 16)], b.mismatches[0..@min(b.mismatch_count, 16)]);
    try std.testing.expectEqual(a.ok(), b.ok());
}
test "compiled replay progress consumer preserves complete bounded reports, verification gates and finalization errors" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var sink: Sink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    const recorder = try std.testing.allocator.create(sdk.runtime.SessionRecorder);
    defer std.testing.allocator.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &sink, .write_fn = Sink.write });
    recorder.begin(.{ .platform_name = "test", .app_name = "replay-progress", .window_chrome_source = .unavailable });
    recorder.stageEvent(.wake);
    recorder.commitEvent();
    recorder.recordEffect(.{ .kind = .line, .key = std.math.maxInt(u64), .payload = "raw\x00\xff" });
    recorder.recordEffect(.{ .kind = .timer, .key = 9007199254740993 });
    for (0..40) |i| {
        recorder.recordCheckpoint(9007199254740993 + i, std.math.maxInt(u64));
        recorder.recordScreenshot("missing", 1, if (i % 2 == 0) 0 else std.math.maxInt(u64), 9007199254740993 + i);
    }
    recorder.finish();
    try std.testing.expect(!recorder.failed);
    for ([_]bool{ false, true }) |verify| for ([_]?anyerror{ null, error.ReplayUnsupported, error.EffectNotFound, error.TestFinishFailure }) |failure| {
        var probes: [2]Probe = .{ .{ .fail = failure }, .{ .fail = failure } };
        var reports: [2]sdk.runtime.ReplayReport = undefined;
        for (0..2) |lane| {
            const harness = try sdk.TestHarness().create(std.testing.allocator, .{});
            defer harness.destroy(std.testing.allocator);
            const app: sdk.App = .{ .context = &probes[lane], .name = "replay-progress", .replay_fn = Probe.control, .replay_policy = if (lane == 0) null else observed };
            const result = sdk.runtime.replaySession(&harness.runtime, app, sink.bytes.items, .{ .verify = verify, .require_same_platform = false });
            if (failure != null and failure.? != error.ReplayUnsupported) try std.testing.expectError(error.ReplayEffectDivergence, result) else reports[lane] = try result;
            try std.testing.expect(!harness.runtime.replay_window_chrome_active);
            try std.testing.expectEqual(@as(usize, 0), harness.runtime.replay_window_chrome_count);
            try std.testing.expectEqual(@as(usize, 0), harness.runtime.replay_window_chrome_index);
        }
        try exact(probes[0], probes[1]);
        if (failure == null or failure.? == error.ReplayUnsupported) {
            try expectReport(reports[0], reports[1]);
            try std.testing.expectEqual(@as(u64, 1), reports[1].events_replayed);
            try std.testing.expectEqual(@as(u64, 1), reports[1].effects_fed);
            try std.testing.expectEqual(@as(u64, 1), reports[1].effects_skipped);
            try std.testing.expectEqual(@as(u64, if (verify) 40 else 0), reports[1].checkpoints_verified);
            try std.testing.expectEqual(@as(u64, if (verify) 40 else 0), reports[1].screenshots_verified);
            try std.testing.expectEqual(@as(u64, if (verify) 60 else 0), reports[1].mismatch_count);
        }
    };
}
const BlobProbe = struct {
    bytes: []const u8,
    reads: usize = 0,
    capacity: usize = 0,
    fail: bool = false,
    fn read(context: *anyopaque, _: sdk.runtime.session_blobs.BlobHash, scratch: []u8) sdk.runtime.session_blobs.BlobError![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.reads += 1;
        self.capacity = scratch.len;
        if (self.fail) return error.BlobIoFailed;
        const length = @min(self.bytes.len, scratch.len);
        @memcpy(scratch[0..length], self.bytes[0..length]);
        return scratch[0..length];
    }
};
test "compiled replay progress consumer preserves blob bytes, spare-byte length proofs and native read failures" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var sink: Sink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var store = sdk.runtime.session_blobs.MemoryBlobStore.init(std.testing.allocator);
    defer store.deinit();
    const recorder = try std.testing.allocator.create(sdk.runtime.SessionRecorder);
    defer std.testing.allocator.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &sink, .write_fn = Sink.write });
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "blob-progress", .window_chrome_source = .unavailable });
    recorder.recordEffect(.{ .kind = .file, .key = std.math.maxInt(u64), .file_op = .read_stream, .file_event = .chunk, .payload = "raw\x00\xff" });
    recorder.finish();
    try std.testing.expect(!recorder.failed);
    for (0..5) |scenario| {
        var probes: [2]Probe = .{ .{}, .{} };
        var sources: [2]BlobProbe = .{ .{ .bytes = "" }, .{ .bytes = "" } };
        var reports: [2]sdk.runtime.ReplayReport = undefined;
        for (0..2) |lane| {
            sources[lane].bytes = switch (scenario) {
                0 => "raw\x00\xff",
                1 => "raw\x00\xffx",
                else => "raw",
            };
            sources[lane].fail = scenario == 3;
            const harness = try sdk.TestHarness().create(std.testing.allocator, .{});
            defer harness.destroy(std.testing.allocator);
            const app: sdk.App = .{ .context = &probes[lane], .name = "blob-progress", .replay_fn = Probe.control, .replay_policy = if (lane == 0) null else observed };
            const source: sdk.runtime.session_blobs.SessionBlobSource = .{ .context = &sources[lane], .read_fn = BlobProbe.read };
            const result = sdk.runtime.replaySession(&harness.runtime, app, sink.bytes.items, .{ .verify = false, .require_same_platform = false, .blobs = if (scenario == 4) null else source });
            if (scenario == 0) reports[lane] = try result else try std.testing.expectError(error.ReplayMissingBlob, result);
        }
        try exact(probes[0], probes[1]);
        try exact(sources[0], sources[1]);
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 0 else 1), sources[1].reads);
        if (scenario != 4) try std.testing.expectEqual(@as(usize, 6), sources[1].capacity);
        if (scenario == 0) {
            try expectReport(reports[0], reports[1]);
            try std.testing.expectEqual(@as(usize, 1), probes[1].feeds);
            try std.testing.expectEqualSlices(u8, "raw\x00\xff", probes[1].payload[0..probes[1].length]);
        } else try std.testing.expectEqual(@as(usize, 0), probes[1].feeds);
    }
}
