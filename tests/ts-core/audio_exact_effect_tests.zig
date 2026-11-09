//! Paired real effect engines with an independent native audio caller.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("audio_exact_core");
const parity = @import("effects_media_parity.zig");
const testing = std.testing;
const Host = sdk.TsCoreHost(core);
const NativeMsg = union(enum) { first: sdk.EffectAudio, second: sdk.EffectAudio };
const NativeFx = sdk.Effects(NativeMsg);

const Pair = struct {
    native: NativeFx,
    compiled: Host.Fx,
    reports: std.ArrayList(NativeMsg) = .empty,

    fn init(fake: bool) Pair {
        var pair: Pair = .{ .native = .init(testing.allocator), .compiled = .init(testing.allocator) };
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
    }
    fn check(self: *Pair) !void {
        try parity.equal(self.native.windowActionState(), self.compiled.windowActionState());
        try parity.equal(self.native.audioSnapshot(), self.compiled.audioSnapshot());
        try parity.equal(self.native.pendingAudio(), self.compiled.pendingAudio());
        try testing.expectEqual(self.native.pendingTimerCount(), self.compiled.pendingTimerCount());
        const model = Host.model();
        try testing.expectEqual(self.reports.items.len, model.reports.len);
        for (self.reports.items, model.reports) |expected, actual| {
            const event = switch (expected) {
                inline else => |event| event,
            };
            try testing.expectEqualStrings(@tagName(std.meta.activeTag(expected)), @tagName(actual.route));
            try testing.expectEqual(event.key, try std.fmt.parseInt(u64, actual.key, 10));
            try testing.expectEqualStrings(@tagName(event.kind), @tagName(actual.state));
            try testing.expectEqual(event.position_ms, try std.fmt.parseInt(u64, actual.positionMs, 10));
            try testing.expectEqual(event.duration_ms, try std.fmt.parseInt(u64, actual.durationMs, 10));
            try testing.expectEqual(event.playing, actual.playing);
            try testing.expectEqual(event.buffering, actual.buffering);
            try testing.expectEqualSlices(u8, &event.bands, actual.bands);
        }
    }
    fn drain(self: *Pair) !void {
        var boundary = self.native.drainBoundary();
        while (self.native.takeMsgWithin(&boundary)) |message| try self.reports.append(testing.allocator, message);
        Host.drain(&self.compiled);
        try self.check();
        const saved = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(saved);
        core.rt.frameReset();
        try testing.expectEqualSlices(u8, saved, core.persistenceSnapshot());
        try self.check();
    }
    fn play(self: *Pair, key: u64, second: bool, path: []const u8, url: []const u8, cache: []const u8, dir: []const u8, size: f64) !void {
        var decimal: [20]u8 = undefined;
        const identity = try std.fmt.bufPrint(&decimal, "{d}", .{key});
        const source: core.Source = .{ .key = identity, .path = path, .url = url, .cachePath = cache, .cacheDir = dir, .expectedBytes = size };
        var buffer: [sdk.max_effect_audio_path_bytes]u8 = undefined;
        const cache_path = if (cache.len > 0 or url.len == 0 or dir.len == 0) cache else sdk.audioCachePath(&buffer, dir, url) catch "";
        self.native.playAudio(.{ .key = key, .path = path, .url = url, .cache_path = cache_path, .expected_bytes = if (size >= 1 and size <= 9007199254740992.0) @intFromFloat(size) else 0, .on_event = if (second) NativeFx.audioMsg(.second) else NativeFx.audioMsg(.first) });
        Host.dispatch(&self.compiled, if (second) .{ .play_second = source } else .{ .play_first = source });
        @memset(&decimal, 'x');
        try self.check();
    }
    fn transport(self: *Pair, control: core.AudioTransport) !void {
        switch (control) {
            .pause => self.native.pauseAudio(),
            .play => self.native.resumeAudio(),
            .stop => self.native.stopAudio(),
            .seek => |position| self.native.seekAudio(try std.fmt.parseInt(u64, position, 10)),
            .volume => |value| self.native.setAudioVolume(@floatCast(value)),
        }
        Host.dispatch(&self.compiled, .{ .transport = control });
        try self.check();
    }
    fn feed(self: *Pair, kind: sdk.EffectAudioEventKind, position: u64, duration: u64, playing: bool, buffering: bool) !void {
        try self.native.feedAudioEventBuffering(kind, position, duration, playing, buffering);
        try self.compiled.feedAudioEventBuffering(kind, position, duration, playing, buffering);
        try self.drain();
    }
};

const WindowCalls = struct {
    calls: std.ArrayList([]const u8) = .empty,

    fn window(context: *anyopaque, label: []const u8) bool {
        const self: *WindowCalls = @ptrCast(@alignCast(context));
        self.calls.append(testing.allocator, testing.allocator.dupe(u8, label) catch unreachable) catch unreachable;
        return std.mem.eql(u8, label, "main") or std.mem.eql(u8, label, "playlist");
    }
    fn dock(_: *anyopaque, _: bool) bool { return false; }
    fn quit(_: *anyopaque) bool { return false; }
    fn binding(self: *WindowCalls) std.meta.Child(@FieldType(Host.Fx, "window_actions")) {
        return .{ .context = self, .close_fn = window, .minimize_fn = window, .show_fn = window,
            .hide_fn = window, .dock_presence_fn = dock, .quit_fn = quit };
    }
    fn deinit(self: *WindowCalls) void {
        for (self.calls.items) |call| testing.allocator.free(call);
        self.calls.deinit(testing.allocator);
    }
};

test "compiled close and minimize preserve complete native window requests and binding order" {
    for ([_]bool{ true, false }) |fake| {
        var pair = Pair.init(fake);
        defer pair.deinit();
        var native_calls: WindowCalls = .{};
        defer native_calls.deinit();
        var compiled_calls: WindowCalls = .{};
        defer compiled_calls.deinit();
        pair.native.bindWindowActions(native_calls.binding());
        pair.compiled.bindWindowActions(compiled_calls.binding());
        const labels = [_][]const u8{ "main", "playlist", "unknown", "", "音楽" };
        for (0..3) |_| {
            for (labels) |label| pair.native.closeWindow(label);
            Host.dispatch(&pair.compiled, .close_windows);
            try pair.check();
            for (labels) |label| pair.native.minimizeWindow(label);
            Host.dispatch(&pair.compiled, .minimize_windows);
            try pair.drain();
        }
        try testing.expectEqual(@as(u32, 15), pair.compiled.windowActionState().close_count);
        try testing.expectEqual(@as(u32, 15), pair.compiled.windowActionState().minimize_count);
        try testing.expectEqual(@as(usize, if (fake) 0 else 30), compiled_calls.calls.items.len);
        try parity.equal(native_calls.calls.items, compiled_calls.calls.items);
        try testing.expectEqual(@as(usize, 0), pair.compiled.pendingHostCount());
    }
}

test "exact audio preserves complete native requests reports and retained model ownership" {
    var pair = Pair.init(true);
    defer pair.deinit();
    const keys = [_]u64{ 0, 1, 68, 9007199254740991, 9007199254740993, std.math.maxInt(u64) };
    const sizes = [_]f64{ 0, 4096, 4096.75, 9007199254740992, -1 };
    for (keys, 0..) |key, index| for (sizes) |size| {
        try pair.play(key, index % 2 != 0, "music/track.mp3", "https://cdn.test/track.mp3", "", "cache", size);
        try pair.feed(.loaded, 0, 183_000, true, index % 2 == 0);
        try pair.feed(.position, 9007199254740993, std.math.maxInt(u64), false, true);
        var bands: [32]u8 = undefined;
        for (&bands, 0..) |*value, band| value.* = @intCast((band * 37 + index) % 256);
        try pair.native.feedAudioSpectrum(bands, 12_345, 183_000);
        try pair.compiled.feedAudioSpectrum(bands, 12_345, 183_000);
        try pair.drain();
        try pair.feed(.completed, 183_000, 183_000, false, false);
        try pair.feed(.failed, 17, 183_000, true, true);
    };
    try testing.expectEqual(@as(usize, 150), pair.reports.items.len);
}

test "rejected loads and deferred failures keep their original key route and prior player" {
    var pair = Pair.init(true);
    defer pair.deinit();
    try pair.transport(.{ .volume = 0.375 });
    try pair.play(std.math.maxInt(u64), false, "first.mp3", "", "", "", 0);
    const long = try testing.allocator.alloc(u8, sdk.max_effect_audio_path_bytes + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try pair.play(9007199254740993, true, "", "", "", "", 0);
    try pair.play(2, true, long, "", "", "", 0);
    try pair.play(3, false, "ok.mp3", long, "", "", 0);
    try pair.play(4, true, "ok.mp3", "", long, "", 0);
    try testing.expectEqual(std.math.maxInt(u64), pair.compiled.audioSnapshot().key);
    try pair.play(68, true, "next.mp3", "", "", "", 0);
    try pair.drain();
    try testing.expectEqual(@as(usize, 4), pair.reports.items.len);
    try pair.transport(.pause);
    try pair.transport(.play);
    try pair.transport(.{ .seek = "18446744073709551615" });
    try pair.transport(.{ .volume = -0.125 });
    try pair.transport(.{ .volume = 1.25 });
    try pair.transport(.stop);
    try pair.transport(.{ .volume = 0.625 });
    try pair.play(0, false, "last.mp3", "", "cache/explicit", "ignored", 0);
    try pair.drain();
}

test "unavailable native playback retains deferred failure routing across replacement" {
    var pair = Pair.init(false);
    defer pair.deinit();
    try pair.play(9007199254740993, false, "first.mp3", "", "", "", 0);
    try pair.play(std.math.maxInt(u64), true, "second.mp3", "", "", "", 0);
    try pair.drain();
    try testing.expectEqual(@as(usize, 2), pair.reports.items.len);
}

test "exact audio effect replay consumes complete recorded payloads without divergence" {
    var pair = Pair.init(true);
    defer pair.deinit();
    pair.native.armReplay();
    pair.compiled.armReplay();
    try pair.play(std.math.maxInt(u64), false, "track.mp3", "", "", "", 0);
    const event: sdk.EffectAudio = .{ .key = std.math.maxInt(u64), .kind = .spectrum, .position_ms = 9007199254740993, .duration_ms = std.math.maxInt(u64), .playing = true, .buffering = true, .bands = @splat(203) };
    try pair.native.feedAudioRecord(event);
    try pair.compiled.feedAudioRecord(event);
    try pair.drain();
    try pair.native.finishReplay();
    try pair.compiled.finishReplay();
    try testing.expectError(error.EffectNotFound, pair.compiled.feedAudioRecord(.{ .key = 1, .kind = .loaded }));
    try pair.play(68, true, "next.mp3", "", "", "", 0);
    try pair.feed(.loaded, 0, 183_000, true, false);
    try pair.transport(.stop);
    try pair.native.finishReplay();
    try pair.compiled.finishReplay();
}
