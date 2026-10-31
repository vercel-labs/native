const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.recording_policy;
const journal = sdk.runtime.session_journal;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var stages: [13]usize = @splat(0);
var codec_calls: [8][2]usize = @splat(.{ 0, 0 });
pub fn observed(input: []const u8, output: []u8) usize {
    if (input.len == 0) @panic("empty recording test policy request");
    switch (input[0]) {
        24 => {
            if (input.len != 64 or input[1] >= stages.len or output.len != 32) @panic("invalid recording test policy request");
            stages[input[1]] += 1;
        },
        26 => if (input.len != 160 or input[1] > 4 or output.len != 80) @panic("invalid journal test policy request"),
        28 => if (input.len < 64 or input[1] != 1 or input[2] > 12 or output.len != 1136) @panic("invalid blob test policy request"),
        30 => {
            if (input.len < 24 or input[1] != 1 or input[2] > 1 or input[3] == 0 or input[3] > 7 or output.len < 16) @panic("invalid codec test policy request");
            codec_calls[input[3]][input[2]] += 1;
        },
        else => @panic("unexpected recording test policy opcode"),
    }
    return core.nativeEffectPolicy(input, output);
}
const Sink = struct {
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.TestSinkFailure;
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
    fn sink(self: *@This()) sdk.runtime.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }
};
const Pair = struct {
    sinks: [2]Sink = .{ .{}, .{} },
    blobs: [2]sdk.runtime.session_blobs.MemoryBlobStore,
    recorders: []sdk.runtime.SessionRecorder,
    fn create() !*@This() {
        const self = try std.testing.allocator.create(@This());
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .blobs = .{ .init(std.testing.allocator), .init(std.testing.allocator) }, .recorders = try std.testing.allocator.alloc(sdk.runtime.SessionRecorder, 2) };
        for (self.recorders, 0..) |*recorder, i| {
            recorder.* = sdk.runtime.SessionRecorder.init(self.sinks[i].sink());
            recorder.recording_policy = if (i == 0) null else observed;
            self.blobs[i].policy = if (i == 0) null else observed;
            recorder.blob_sink = self.blobs[i].sink();
        }
        return self;
    }
    fn destroy(self: *@This()) void {
        for (&self.sinks) |*sink| sink.bytes.deinit(std.testing.allocator);
        for (&self.blobs) |*store| store.deinit();
        std.testing.allocator.free(self.recorders);
        std.testing.allocator.destroy(self);
    }
    fn same(self: *@This()) !void {
        const left = &self.recorders[0];
        const right = &self.recorders[1];
        inline for (.{ "began", "finished", "failed", "bytes_written", "event_count", "effect_count", "checkpoint_count", "screenshot_count", "window_chrome_count", "window_chrome_source", "credentials_salt", "last_checkpoint_frame", "depth", "suppress_owner_depth", "staged_lens", "staged_suppressed", "staged_chrome_counts" }) |field| try exact(@field(left, field), @field(right, field));
        for (left.staged_lens, 0..) |length, slot| {
            try std.testing.expectEqualSlices(u8, left.staged[slot][0..length], right.staged[slot][0..length]);
            try exact(left.staged_chrome[slot][0..left.staged_chrome_counts[slot]], right.staged_chrome[slot][0..right.staged_chrome_counts[slot]]);
        }
        try exact(self.sinks[0].calls, self.sinks[1].calls);
        try std.testing.expectEqualSlices(u8, self.sinks[0].bytes.items, self.sinks[1].bytes.items);
        try exact(self.blobs[0].count, self.blobs[1].count);
        for (self.blobs[0].entries[0..self.blobs[0].count], self.blobs[1].entries[0..self.blobs[1].count]) |a, b| try exact(a, b);
    }
    fn apply(self: *@This(), comptime name: []const u8, args: anytype) !void {
        for (self.recorders) |*recorder| @call(.auto, @field(sdk.runtime.SessionRecorder, name), .{recorder} ++ args);
        try self.same();
    }
    fn begin(self: *@This()) !void {
        try self.apply("begin", .{sdk.runtime.SessionHeader{ .platform_name = "test", .app_name = "recording", .recorded_at_wall_ms = -17 }});
    }
};
test "compiled session recording preserves nested ordering, suppression, chrome and sealing" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    stages = @splat(0);
    codec_calls = @splat(.{ 0, 0 });
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.begin();
    try pair.begin();
    try pair.apply("stageEvent", .{sdk.platform.Event.frame_requested});
    try pair.apply("recordWindowChrome", .{journal.WindowChromeRecord{ .window_id = 9007199254740993, .chrome = .{ .insets = .{ .left = -0.0 }, .tabs_projected = true } }});
    const action = sdk.platform.Event{ .widget_accessibility_action = .{ .window_id = std.math.maxInt(u64), .label = "canvas", .id = 9007199254740993, .action = .press } };
    try pair.apply("stageEvent", .{action});
    try pair.apply("stageEvent", .{action});
    try pair.apply("stageEvent", .{sdk.platform.Event.wake});
    try pair.apply("recordWindowChrome", .{journal.WindowChromeRecord{ .window_id = std.math.maxInt(u64), .chrome = .{} }});
    try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .line, .key = std.math.maxInt(u64), .payload = "raw\x00\xff" }});
    for (0..3) |_| try pair.apply("commitEvent", .{});
    try std.testing.expectEqual(@as(usize, 1), pair.recorders[1].depth);
    try pair.apply("commitEvent", .{});
    try pair.apply("commitEvent", .{});
    for ([_]u64{ 0, 1, 4294967296, 9007199254740992, 9007199254740993, std.math.maxInt(u64) }) |frame| {
        try std.testing.expectEqual(pair.recorders[0].wantsCheckpoint(frame), pair.recorders[1].wantsCheckpoint(frame));
        try pair.apply("recordCheckpoint", .{ frame, std.math.maxInt(u64) });
        try std.testing.expect(!pair.recorders[1].wantsCheckpoint(frame));
    }
    try pair.apply("recordScreenshot", .{ "canvas", @as(f32, -0.0), std.math.maxInt(u64), @as(u64, 9007199254740993) });
    try pair.apply("finish", .{});
    const saved = try std.testing.allocator.dupe(u8, pair.sinks[1].bytes.items);
    defer std.testing.allocator.free(saved);
    try pair.apply("finish", .{});
    try pair.apply("stageEvent", .{sdk.platform.Event.wake});
    try pair.apply("recordCheckpoint", .{ @as(u64, 1), @as(u64, 1) });
    try std.testing.expectEqualSlices(u8, saved, pair.sinks[1].bytes.items);
    var reader = try journal.Reader.initWithPolicy(saved, observed);
    _ = (try reader.next()).?;
    try std.testing.expect((try reader.next()).? == .effect);
    try std.testing.expectEqual(std.math.maxInt(u64), (try reader.next()).?.window_chrome.window_id);
    try std.testing.expect((try reader.next()).?.event == .widget_accessibility_action);
    try std.testing.expectEqual(@as(u64, 9007199254740993), (try reader.next()).?.window_chrome.window_id);
    try std.testing.expect((try reader.next()).?.event == .frame_requested);
    while (try reader.next()) |_| {}
    for (codec_calls[1..]) |counts| for (counts) |count| try std.testing.expect(count > 0);
    for (stages[0..11]) |count| try std.testing.expect(count > 0);
    try std.testing.expect(stages[12] > 0);
}
test "compiled session recording preserves every effect kind, blob and credential treatment" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.begin();
    const payload = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);
    for (std.enums.values(sdk.runtime.EffectResultKind)) |kind| for ([_]usize{ 0, 1, 65536, 65537 }) |length| {
        for ([_]bool{ false, true }) |secret_get| {
            try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = kind, .key = 9007199254740993, .payload = payload[0..length], .file_event = .chunk, .credentials_operation = if (secret_get) .get else .set, .credentials_outcome = .ok }});
        }
    };
    try pair.apply("finish", .{});
    try std.testing.expect(!pair.recorders[1].failed);
    var reader = try journal.Reader.init(pair.sinks[1].bytes.items);
    var credentials: usize = 0;
    while (try reader.next()) |record| if (record == .effect and record.effect.kind == .credentials) {
        credentials += 1;
        try std.testing.expectEqual(@as(usize, 0), record.effect.payload.len);
        if (record.effect.credentials_operation == .get) try std.testing.expect(!std.mem.allEqual(u8, &record.effect.credentials_digest, 0));
    };
    try std.testing.expectEqual(@as(usize, 8), credentials);
}
test "compiled session recording fails once at every sink boundary and never seals a prefix" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (1..17) |failure| {
        const pair = try Pair.create();
        defer pair.destroy();
        for (&pair.sinks) |*sink| sink.fail_at = failure;
        try pair.begin();
        try pair.apply("stageEvent", .{sdk.platform.Event.wake});
        try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .line, .payload = "effect", .key = 0 }});
        try pair.apply("commitEvent", .{});
        try pair.apply("recordCheckpoint", .{ @as(u64, 7), @as(u64, 9) });
        try pair.apply("recordScreenshot", .{ "canvas", @as(f32, 1), @as(u64, 7), @as(u64, 9) });
        try pair.apply("finish", .{});
        if (pair.recorders[1].failed) {
            const calls = pair.sinks[1].calls;
            try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .line, .key = 0 }});
            try pair.apply("finish", .{});
            try std.testing.expectEqual(calls, pair.sinks[1].calls);
        }
    }
}
test "compiled session recording preserves stack, chrome, record and journal budget failures" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..6) |scenario| {
        const pair = try Pair.create();
        defer pair.destroy();
        try pair.begin();
        switch (scenario) {
            0 => {
                for (0..9) |_| try pair.apply("stageEvent", .{sdk.platform.Event.wake});
            },
            1 => try pair.apply("recordWindowChrome", .{journal.WindowChromeRecord{ .window_id = 1, .chrome = .{} }}),
            2 => {
                try pair.apply("stageEvent", .{sdk.platform.Event.wake});
                for (0..257) |_| try pair.apply("recordWindowChrome", .{journal.WindowChromeRecord{ .window_id = 1, .chrome = .{} }});
            },
            3 => {
                for (pair.recorders) |*recorder| recorder.window_chrome_source = .unavailable;
                try pair.apply("recordWindowChrome", .{journal.WindowChromeRecord{ .window_id = 1, .chrome = .{} }});
            },
            4 => {
                for (pair.recorders) |*recorder| recorder.bytes_written = sdk.runtime.max_session_journal_bytes - 5;
                try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .line, .payload = "too much", .key = 0 }});
            },
            5 => {
                for (pair.recorders) |*recorder| recorder.blob_sink = null;
                try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .image, .payload = "image", .key = 0 }});
            },
            else => unreachable,
        }
        try std.testing.expect(pair.recorders[1].failed);
        try pair.apply("finish", .{});
        try std.testing.expect(!pair.recorders[1].finished);
    }
}
test "compiled session recording owns copied plans and carries complete unsigned counters" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 4294967295, 9007199254740992, std.math.maxInt(u64) - 1 }) |count| {
        const retained = core.rt.frameAlloc(u8, 17);
        @memset(retained, 0x5a);
        const result = p.plan(observed, .count, .{ .a = count }).?;
        try std.testing.expectEqual(count + 1, result.value);
        try std.testing.expect(std.mem.allEqual(u8, retained, 0x5a));
        core.rt.frameReset();
        try std.testing.expectEqual(count + 1, result.value);
    }
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.begin();
    for (pair.recorders) |*recorder| {
        recorder.event_count = 4294967295;
        recorder.effect_count = 9007199254740993;
        recorder.checkpoint_count = std.math.maxInt(u64) - 1;
    }
    try pair.apply("stageEvent", .{sdk.platform.Event.wake});
    try pair.apply("commitEvent", .{});
    try pair.apply("recordEffect", .{sdk.runtime.EffectResultRecord{ .kind = .credentials, .credentials_operation = .get, .credentials_outcome = .ok, .payload = "synthetic secret", .key = 0 }});
    try pair.apply("recordCheckpoint", .{ std.math.maxInt(u64), std.math.maxInt(u64) });
    try pair.apply("finish", .{});
}
