const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("channel_monitor_core");
const decoder = @import("channel_monitor_decoder");
const reference = @import("channel-monitor-reference/main.zig");
const parity = @import("effects_media_parity.zig");
const Host = sdk.TsCoreHost(core);
const testing = std.testing;
const canvas = sdk.canvas;
const source_name = "native-sdk.process.samples";
const canvas_label = "monitor-canvas";
const shell_views = [_]sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Channel monitor canvas", .accessibility_label = "Channel monitor", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true }};
const shell_windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Native SDK Channel Monitor", .width = 560, .height = 420, .views = &shell_views }};
const shell_scene: sdk.ShellConfig = .{ .windows = &shell_windows };

const Source = struct {
    calls: usize = 0,
    fail: bool = false,
    handle: ?sdk.ChannelHandle = null,
    fn start(context: *anyopaque, name: []const u8, payload: []const u8, handle: sdk.ChannelHandle) !void {
        const self: *Source = @ptrCast(@alignCast(context));
        try testing.expectEqualStrings(source_name, name);
        try testing.expectEqual(@as(usize, 0), payload.len);
        self.calls += 1;
        self.handle = handle;
        if (self.fail) return error.ThreadQuotaExceeded;
    }
};
var native_handle: ?sdk.ChannelHandle = null;
var native_fail = false;
fn startNative(handle: sdk.ChannelHandle) std.Thread.SpawnError!void {
    native_handle = handle;
    if (native_fail) return error.ThreadQuotaExceeded;
}
fn compare(native: *const reference.Model, model: *const core.Model) !void {
    try testing.expectEqual(@as(i64, @intCast(native.visible_count)), model.visible_count);
    try testing.expectEqual(@as(u32, @truncate(native.total_samples)), model.total_samples.lower_word);
    try testing.expectEqual(@as(u32, @intCast(native.total_samples >> 32)), model.total_samples.upper_word);
    try testing.expectEqual(native.dropped_total, model.dropped_total);
    try testing.expectEqual(native.monitoring, model.monitoring);
    try testing.expectEqual(native.rejected, model.rejected);
    try testing.expectEqual(native.source_failed, model.source_failed);
    try testing.expectEqual(@as(usize, 16), model.line_storage.len);
    for (model.line_storage, 0..) |line, index| {
        try testing.expectEqual(@as(i64, @intCast(native.line_lens[index])), line.length);
        try testing.expectEqualSlices(u8, &native.line_storage[index], line.bytes);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(native.statusText(arena.allocator()), model.statusText(arena.allocator()));
}
fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = reference.MonitorUi.init(arena.allocator());
    const expected = try a.finalize(reference.view(&a, native));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const actual = try b.finalize(if (backend == 0) View.build(&b, model) else decoder.build(&b, model));
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |old, new| {
            try testing.expectEqual(old.id, new.id);
            const before = expected.msgForPointer(old.id, .up);
            const after = actual.msgForPointer(new.id, .up);
            try testing.expectEqual(before != null, after != null);
            if (before) |msg| try testing.expectEqualStrings(@tagName(msg), @tagName(after.?));
        }
        var left: [128]canvas.WidgetLayoutNode = undefined;
        var right: [128]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 560, 420), .init(0, 0, 720, 640), .init(0, 0, 400, 320) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
    }
}
fn drainNative(model: *reference.Model, fx: *reference.Effects) void {
    var boundary = fx.drainBoundary();
    while (fx.takeMsgWithin(&boundary)) |msg| reference.update(model, msg, fx);
}

test "compiled Channel Monitor preserves every stored byte, counter, view and channel lifetime" {
    const saved = reference.start_source;
    defer reference.start_source = saved;
    reference.start_source = startNative;
    native_fail = false;
    native_handle = null;
    var source: Source = .{};
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.channel_sources = .{ .context = &source, .start_fn = Source.start };
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    var native: reference.Model = .{ .line_storage = @splat(@splat(0)) };
    Host.init(&fx);
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    reference.update(&native, .start, &native_fx);
    Host.dispatch(&fx, .start);
    try testing.expectEqual(@as(usize, 1), source.calls);
    try testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    const handle = source.handle.?;
    const old_handle = native_handle.?;
    for (0..40) |index| {
        var raw: [160]u8 = undefined;
        for (&raw, 0..) |*byte, at| byte.* = @truncate(index * 17 + at);
        const length: usize = switch (index % 5) {
            0 => 0,
            1 => 1,
            2 => 95,
            3 => 96,
            else => 160,
        };
        try testing.expectEqual(sdk.ChannelHandle.PostResult.accepted, old_handle.post(raw[0..length]));
        try testing.expectEqual(sdk.ChannelHandle.PostResult.accepted, handle.post(raw[0..length]));
        drainNative(&native, &native_fx);
        Host.drain(&fx);
        @memset(&raw, 0xA5);
        try compare(&native, Host.model());
        try viewParity(&native, Host.model());
    }
    // Full FIFO backpressure leaves the producer alive and carries every drop.
    for (0..sdk.max_effect_channel_pending) |_| {
        try testing.expectEqual(sdk.ChannelHandle.PostResult.accepted, old_handle.post("pending"));
        try testing.expectEqual(sdk.ChannelHandle.PostResult.accepted, handle.post("pending"));
    }
    try testing.expectEqual(sdk.ChannelHandle.PostResult.dropped_full, old_handle.post("overflow"));
    try testing.expectEqual(sdk.ChannelHandle.PostResult.dropped_full, handle.post("overflow"));
    drainNative(&native, &native_fx);
    Host.drain(&fx);
    try compare(&native, Host.model());
    reference.update(&native, .stop, &native_fx);
    Host.dispatch(&fx, .stop);
    drainNative(&native, &native_fx);
    Host.drain(&fx);
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    try testing.expectEqual(sdk.ChannelHandle.PostResult.closed, handle.post("late"));
    reference.update(&native, .start, &native_fx);
    Host.dispatch(&fx, .start);
    try compare(&native, Host.model());
    try testing.expectEqual(@as(usize, 2), source.calls);
    try testing.expectEqual(sdk.ChannelHandle.PostResult.closed, handle.post("stale generation"));
    Host.dispatch(&fx, .start);
    try testing.expectEqual(@as(usize, 2), source.calls);
}

test "compiled source startup fails before monitoring and a refused open never starts the existing producer" {
    const saved = reference.start_source;
    defer reference.start_source = saved;
    reference.start_source = startNative;
    native_fail = true;
    var source: Source = .{ .fail = true };
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.channel_sources = .{ .context = &source, .start_fn = Source.start };
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    var native: reference.Model = .{ .line_storage = @splat(@splat(0)) };
    Host.init(&fx);
    reference.update(&native, .start, &native_fx);
    Host.dispatch(&fx, .start);
    try compare(&native, Host.model());
    try testing.expect(Host.model().source_failed and !Host.model().monitoring);
    try testing.expectEqual(sdk.ChannelHandle.PostResult.closed, source.handle.?.post("late"));
    drainNative(&native, &native_fx);
    Host.drain(&fx);
    try compare(&native, Host.model());
    source.fail = false;
    native_fail = false;
    reference.update(&native, .start, &native_fx);
    Host.dispatch(&fx, .start);
    try compare(&native, Host.model());
    try testing.expectEqual(@as(usize, 2), source.calls);
    // Reset the bridge, retaining an engine-owned channel under key 1.
    // Admission must skip startup, rather than resolving the old handle.
    Host.init(&fx);
    source.calls = 0;
    Host.dispatch(&fx, .start);
    try testing.expectEqual(@as(usize, 0), source.calls);
    Host.drain(&fx);
    try testing.expect(Host.model().rejected and !Host.model().monitoring);
}

const Captured = struct {
    record: ?sdk.runtime.EffectResultRecord = null,
    request: [4356]u8 = undefined,
    failure: [255]u8 = undefined,
    fn note(context: *anyopaque, value: sdk.runtime.EffectResultRecord) void {
        const self: *Captured = @ptrCast(@alignCast(context));
        if (value.kind != .channel_source) return;
        @memcpy(self.request[0..value.payload.len], value.payload);
        @memcpy(self.failure[0..value.stderr_tail.len], value.stderr_tail);
        self.record = value;
        self.record.?.payload = self.request[0..value.payload.len];
        self.record.?.stderr_tail = self.failure[0..value.stderr_tail.len];
    }
};

test "compiled startup replay consumes exact immediate facts without launching sources" {
    inline for (.{ false, true }) |failed| {
        var capture: Captured = .{};
        var source: Source = .{ .fail = failed };
        var fx = Host.Fx.init(testing.allocator);
        defer fx.deinit();
        fx.channel_sources = .{ .context = &source, .start_fn = Source.start };
        fx.bindJournal(.{ .context = &capture, .record_fn = Captured.note });
        Host.init(&fx);
        Host.dispatch(&fx, .start);
        const settled = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(settled);
        try testing.expectEqual(@as(usize, 1), source.calls);
        var replay = Host.Fx.init(testing.allocator);
        defer replay.deinit();
        replay.armReplay();
        replay.channel_sources = .{ .context = &source, .start_fn = Source.start };
        try replay.pushReplayChannelSource(capture.record.?);
        // The fact owns its bytes independently of the journal decode buffer.
        @memset(&capture.request, 0xA5);
        @memset(&capture.failure, 0xA5);
        Host.init(&replay);
        Host.dispatch(&replay, .start);
        try testing.expectEqual(@as(usize, 1), source.calls);
        try testing.expectEqualSlices(u8, settled, core.persistenceSnapshot());
        try replay.finishReplay();
    }
}

test "source replay rejects missing, extra, mismatched and noncanonical facts" {
    var capture: Captured = .{};
    var source: Source = .{};
    var live = Host.Fx.init(testing.allocator);
    defer live.deinit();
    live.channel_sources = .{ .context = &source, .start_fn = Source.start };
    live.bindJournal(.{ .context = &capture, .record_fn = Captured.note });
    Host.init(&live);
    Host.dispatch(&live, .start);
    const record = capture.record.?;
    for (0..7) |scenario| {
        var replay = Host.Fx.init(testing.allocator);
        defer replay.deinit();
        replay.armReplay();
        if (scenario != 0) {
            var altered = record;
            if (scenario == 2) altered.key += 1;
            var request: [4356]u8 = undefined;
            @memcpy(request[0..record.payload.len], record.payload);
            if (scenario == 4) {
                request[1] = 'x';
                altered.payload = request[0..record.payload.len];
            }
            if (scenario == 5) {
                const name_len: usize = request[0];
                std.mem.writeInt(u32, request[1 + name_len ..][0..4], 1, .little);
                request[record.payload.len] = 0xFF;
                altered.payload = request[0 .. record.payload.len + 1];
            }
            if (scenario == 6) altered.code = 0; // skipped contradicts admission
            try replay.pushReplayChannelSource(altered);
        }
        Host.init(&replay);
        if (scenario != 1) Host.dispatch(&replay, .start);
        if (scenario == 3) try replay.finishReplay() else try testing.expectError(error.ReplayChannelSourceDivergence, replay.finishReplay());
    }
    var replay = Host.Fx.init(testing.allocator);
    defer replay.deinit();
    replay.armReplay();
    var malformed = record;
    malformed.truncated = true;
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
    malformed = record;
    malformed.code = 3;
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
    malformed = record;
    malformed.stderr_tail = "unexpected";
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
    var request: [4356]u8 = undefined;
    @memcpy(request[0..record.payload.len], record.payload);
    malformed = record;
    malformed.payload = request[0..record.payload.len];
    request[0] = 0;
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
    request[0] = record.payload[0];
    request[1] = 0xFF;
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
    malformed = record;
    malformed.payload = record.payload[0 .. record.payload.len - 1];
    try testing.expectError(error.ReplayDamagedRecord, replay.pushReplayChannelSource(malformed));
}

test "compiled Channel Monitor retains exact u64 and u32 boundaries through canonical restoration" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    for ([_]u64{ 0xFFFF_FFFF, 0x1_FFFF_FFFF_FFFFFF, 0x8000_0000_0000_0000, std.math.maxInt(u64) - 1 }) |count| {
        Host.init(&fx);
        const snapshot = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(snapshot);
        var at: usize = 4;
        var restored_count = false;
        for (0..std.mem.readInt(u32, snapshot[0..4], .little)) |_| {
            const tag = std.mem.readInt(u32, snapshot[at..][0..4], .little);
            const len = std.mem.readInt(u32, snapshot[at + 4 ..][0..4], .little);
            at += 8;
            // Model declaration order: line_storage, visible_count,
            // total_samples, dropped_total, monitoring, rejected, source_failed.
            if (tag == 2) {
                try testing.expectEqual(@as(u32, 16), len);
                std.mem.writeInt(i64, snapshot[at..][0..8], @intCast(count >> 32), .little);
                std.mem.writeInt(i64, snapshot[at + 8 ..][0..8], @intCast(count & 0xFFFFFFFF), .little);
                restored_count = true;
            }
            if (tag == 4) snapshot[at] = 1;
            at += len;
        }
        try testing.expect(restored_count);
        const model = core.restoreModel(snapshot);
        var native: reference.Model = .{ .line_storage = @splat(@splat(0)), .total_samples = count, .monitoring = true };
        var native_fx = reference.Effects.init(testing.allocator);
        defer native_fx.deinit();
        reference.update(&native, .{ .sample = .{ .key = 1, .kind = .data, .bytes = "boundary", .dropped_total = std.math.maxInt(u32), .dropped_pending = std.math.maxInt(u32) } }, &native_fx);
        const result = core.update(model, .{ .sample = .{ .key = 1, .state = .data, .bytes = "boundary", .droppedTotal = std.math.maxInt(u32), .droppedPending = std.math.maxInt(u32) } });
        try compare(&native, result.model);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "{d} samples · 4294967295 dropped", .{count + 1}), result.model.totals(arena.allocator()));
        try viewParity(&native, result.model);
        core.rt.frameReset();
    }
}

fn monitorReplay(comptime compiled_view: bool, failed: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = .init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "channel-monitor", 560, 420));
    var source: Source = .{ .fail = failed };
    var fingerprint: u64 = 0;
    var full_model: ?[]u8 = null;
    var persistence: ?[]u8 = null;
    defer if (full_model) |bytes| testing.allocator.free(bytes);
    defer if (persistence) |bytes| testing.allocator.free(bytes);
    {
        const state = try Adapter.create(testing.allocator, .{}, .{ .name = "channel-monitor", .scene = shell_scene, .canvas_label = canvas_label, .view = if (compiled_view) decoder.build else View.build });
        defer state.destroy();
        state.effects.executor = .fake;
        state.effects.channel_sources = .{ .context = &source, .start_fn = Source.start };
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(560, 420) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = canvas_label, .size = .init(560, 420), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, canvas_label, "Start monitor", "press");
        try testing.expectEqual(@as(usize, 1), source.calls);
        try testing.expectEqual(failed, state.model.source_failed);
        // Startup truth settles in the issuing update tail. The ordinary
        // close terminal retains the next-drain boundary.
        if (failed) {
            try testing.expect(!state.model.monitoring);
            try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
            source.fail = false;
            try parity.action(&harness.runtime, state.app(), &state.tree.?.root, canvas_label, "Start monitor", "press");
        }
        for (0..36) |i| {
            var line: [160]u8 = undefined;
            for (&line, 0..) |*byte, at| byte.* = @truncate(i * 17 + at);
            try testing.expectEqual(sdk.ChannelHandle.PostResult.accepted, source.handle.?.post(line[0..if (i % 2 == 0) 160 else 1]));
            @memset(&line, 0xA5);
            try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        }
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, canvas_label, "Stop", "press");
        try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        try testing.expect(!state.model.monitoring);
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
        fingerprint = harness.runtime.sessionStateFingerprint();
        full_model = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
        persistence = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        recorder.finish();
        try testing.expect(!recorder.failed);
        try testing.expect(recorder.effect_count >= 38);
    }
    const calls = source.calls;
    const state = try Adapter.create(testing.allocator, .{}, .{ .name = "channel-monitor", .scene = shell_scene, .canvas_label = canvas_label, .view = if (compiled_view) decoder.build else View.build });
    defer state.destroy();
    state.effects.channel_sources = .{ .context = &source, .start_fn = Source.start };
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(560, 420) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    try testing.expectEqual(calls, source.calls);
    const replayed = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
    defer testing.allocator.free(replayed);
    try testing.expectEqualStrings(full_model.?, replayed);
    try testing.expectEqualSlices(u8, persistence.?, core.persistenceSnapshot());
}

test "complete Channel Monitor startup, bytes, effects and checkpoints replay on both view backends" {
    try monitorReplay(false, false);
    try monitorReplay(true, false);
    try monitorReplay(false, true);
    try monitorReplay(true, true);
}

test "compiled Channel Monitor view validates copied raw key ownership and ambiguous encodings" {
    try decoder.testByteKeyRecords();
}

test {
    _ = @import("channel-monitor-reference/tests.zig");
}
