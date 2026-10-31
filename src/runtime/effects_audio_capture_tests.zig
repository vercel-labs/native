//! Microphone/system capture coverage over the fake executor. The native
//! hosts have platform compile/smoke coverage; these tests pin the shared
//! typed stream, canonical PCM shape, bounded back-pressure, and lifecycle.

const std = @import("std");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");

const testing = std.testing;

const Msg = union(enum) {
    capture: effects_mod.EffectAudioCaptureEvent,
    channel: effects_mod.EffectChannelEvent,
};

const Fx = effects_mod.Effects(Msg);

fn takeCapture(fx: *Fx, kind: effects_mod.EffectAudioCaptureEventKind) !effects_mod.EffectAudioCaptureEvent {
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(msg == .capture);
    try testing.expectEqual(kind, msg.capture.kind);
    return msg.capture;
}

test "audio capture fake lifecycle delivers canonical PCM and a stopped terminal" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.startAudioCapture(.{
        .key = 71,
        .source = .microphone,
        .sample_rate = 16_000,
        .channels = 1,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    const started = try takeCapture(&fx, .started);
    try testing.expectEqual(@as(u64, 71), started.key);
    try testing.expectEqual(platform.AudioCaptureSource.microphone, started.source);
    try testing.expectEqual(@as(u32, 16_000), started.sample_rate);
    try testing.expectEqual(@as(u8, 1), started.channels);

    const pcm = [_]u8{ 0x01, 0x00, 0xff, 0x7f, 0x00, 0x80 };
    try fx.feedAudioCapture(71, 12_345_678, &pcm);
    const data = try takeCapture(&fx, .data);
    try testing.expectEqual(@as(u64, 12), data.timestamp_ms);
    try testing.expectEqual(@as(u32, 3), data.frames);
    try testing.expectEqualSlices(u8, &pcm, data.pcm_s16le);

    fx.stopAudioCapture(71);
    const stopped = try takeCapture(&fx, .stopped);
    try testing.expectEqual(@as(u64, 71), stopped.key);
    try testing.expectEqual(@as(?Msg, null), fx.takeMsg());
    try testing.expectError(error.EffectNotFound, fx.feedAudioCapture(71, 0, &pcm));
}

test "microphone and system capture run concurrently and source replacement is ordered" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.startAudioCapture(.{ .key = 1, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    fx.startAudioCapture(.{ .key = 2, .source = .system, .channels = 2, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(platform.AudioCaptureSource.microphone, (try takeCapture(&fx, .started)).source);
    try testing.expectEqual(platform.AudioCaptureSource.system, (try takeCapture(&fx, .started)).source);

    // Starting another microphone capture closes key 1 before key 3 starts.
    fx.startAudioCapture(.{ .key = 3, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(@as(u64, 1), (try takeCapture(&fx, .stopped)).key);
    try testing.expectEqual(@as(u64, 3), (try takeCapture(&fx, .started)).key);

    fx.stopAudioCapture(2);
    fx.stopAudioCapture(3);
    _ = try takeCapture(&fx, .stopped);
    _ = try takeCapture(&fx, .stopped);
}

test "audio capture refuses a key owned by the other source without corrupting it" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.startAudioCapture(.{ .key = 33, .source = .system, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(platform.AudioCaptureSource.system, (try takeCapture(&fx, .started)).source);

    fx.startAudioCapture(.{ .key = 33, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(@as(u64, 33), (try takeCapture(&fx, .rejected)).key);

    const pcm = [_]u8{ 1, 0 };
    try fx.feedAudioCapture(33, 1_000_000, &pcm);
    try testing.expectEqual(platform.AudioCaptureSource.system, (try takeCapture(&fx, .data)).source);
    fx.stopAudioCapture(33);
    _ = try takeCapture(&fx, .stopped);
}

test "a refused same-source replacement leaves the current capture running" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.startAudioCapture(.{ .key = 35, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    _ = try takeCapture(&fx, .started);

    const occupied = fx.openChannel(.{ .key = 36, .on_event = Fx.channelMsg(.channel) });
    try testing.expect(occupied.live());

    // The replacement cannot claim key 36. Refusing it must not stop key 35.
    fx.startAudioCapture(.{ .key = 36, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(@as(u64, 36), (try takeCapture(&fx, .rejected)).key);

    const pcm = [_]u8{ 1, 0 };
    try fx.feedAudioCapture(35, 1_000_000, &pcm);
    try testing.expectEqual(@as(u64, 35), (try takeCapture(&fx, .data)).key);
    try testing.expect(occupied.live());

    // A same-key duplicate is a refusal too, never an implicit stop.
    fx.startAudioCapture(.{ .key = 35, .source = .microphone, .on_event = Fx.audioCaptureMsg(.capture) });
    try testing.expectEqual(@as(u64, 35), (try takeCapture(&fx, .rejected)).key);
    try fx.feedAudioCapture(35, 2_000_000, &pcm);
    try testing.expectEqual(@as(u64, 35), (try takeCapture(&fx, .data)).key);

    fx.stopAudioCapture(35);
    _ = try takeCapture(&fx, .stopped);
    fx.closeChannel(36);
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(closed == .channel);
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.channel.kind);
}

test "stopping an unknown audio key leaves an ordinary channel open" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 34, .on_event = Fx.channelMsg(.channel) });
    try testing.expect(handle.live());

    fx.stopAudioCapture(34);
    try testing.expect(handle.live());
    try testing.expectEqual(effects_mod.ChannelHandle.PostResult.accepted, handle.post("still open"));

    const data = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(data == .channel);
    try testing.expectEqual(effects_mod.EffectChannelEventKind.data, data.channel.kind);
    try testing.expectEqualStrings("still open", data.channel.bytes);

    fx.closeChannel(34);
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(closed == .channel);
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.channel.kind);
}

test "audio capture validates format and reports bounded queue drops" {
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.startAudioCapture(.{
        .key = 8,
        .source = .system,
        .sample_rate = 44_100,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    try testing.expectEqual(@as(u64, 8), (try takeCapture(&fx, .rejected)).key);

    fx.startAudioCapture(.{
        .key = 9,
        .source = .system,
        .max_pending = 1,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    _ = try takeCapture(&fx, .started);
    const frame = [_]u8{ 0, 0 };
    try fx.feedAudioCapture(9, 1_000_000, &frame);
    try testing.expectError(error.EffectQueueFull, fx.feedAudioCapture(9, 2_000_000, &frame));
    const with_drop = try takeCapture(&fx, .data);
    try testing.expectEqual(@as(u32, 1), with_drop.dropped_pending);
    try testing.expectEqual(@as(u32, 1), with_drop.dropped_total);
    try fx.feedAudioCapture(9, 3_000_000, &frame);
    const after_drop = try takeCapture(&fx, .data);
    try testing.expectEqual(@as(u32, 0), after_drop.dropped_pending);
    try testing.expectEqual(@as(u32, 1), after_drop.dropped_total);
    fx.stopAudioCapture(9);
    _ = try takeCapture(&fx, .stopped);
}

test "audio capture real-executor path binds and quiesces platform services" {
    var host = platform.NullPlatform.init(.{});
    defer host.deinit();
    var host_platform = host.platform();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host_platform.services);

    fx.startAudioCapture(.{
        .key = 44,
        .source = .system,
        .sample_rate = 24_000,
        .channels = 2,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    try testing.expectEqual(platform.AudioCaptureSource.system, (try takeCapture(&fx, .started)).source);
    try testing.expect(host.audio_captures[@intFromEnum(platform.AudioCaptureSource.system)].active);

    const pcm = [_]u8{ 1, 0, 2, 0 };
    try testing.expectEqual(platform.AudioCapturePushResult.accepted, host.pushAudioCapture(.system, 5_000_000, &pcm));
    const data = try takeCapture(&fx, .data);
    try testing.expectEqual(@as(u32, 1), data.frames);
    try testing.expectEqual(@as(u64, 5), data.timestamp_ms);

    fx.stopAudioCapture(44);
    _ = try takeCapture(&fx, .stopped);
    const capture = &host.audio_captures[@intFromEnum(platform.AudioCaptureSource.system)];
    try testing.expect(!capture.active);
    try testing.expectEqual(@as(usize, 1), capture.stop_count);
}

test "audio capture teardown quiesces every platform source exactly once" {
    var host = platform.NullPlatform.init(.{});
    defer host.deinit();
    var host_platform = host.platform();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host_platform.services);

    fx.startAudioCapture(.{
        .key = 51,
        .source = .microphone,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    fx.startAudioCapture(.{
        .key = 52,
        .source = .system,
        .on_event = Fx.audioCaptureMsg(.capture),
    });
    try testing.expect(host.audio_captures[@intFromEnum(platform.AudioCaptureSource.microphone)].active);
    try testing.expect(host.audio_captures[@intFromEnum(platform.AudioCaptureSource.system)].active);

    fx.deinit();
    for (&host.audio_captures) |*capture| {
        try testing.expect(!capture.active);
        try testing.expectEqual(@as(usize, 1), capture.stop_count);
    }

    // Effects teardown is idempotent: the post-platform owner defer must
    // never call back into services or stop either source a second time.
    fx.deinit();
    for (&host.audio_captures) |*capture| {
        try testing.expectEqual(@as(usize, 1), capture.stop_count);
    }
}
