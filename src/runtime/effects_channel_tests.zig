//! External-source channel coverage: the `fx.openChannel` family —
//! lifecycle (open/post/deliver/close), the thread-safe posting handle
//! and its post-close/post-teardown safety, back-pressure drop
//! accounting, the shared key space with the slot-backed families, and
//! the record/replay acceptance story: a session recorded WITH a live
//! posting thread replays fingerprint-identical OFFLINE with no source
//! thread at all (the journaled events are the whole stream).

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const journal = @import("session_journal.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");

const testing = std.testing;
const PostResult = effects_mod.ChannelHandle.PostResult;

// ------------------------------------------------- direct-channel tests
//
// The channel family needs no executor, worker, or platform: a direct
// `Effects(Msg)` instance plus `takeMsg` drives the whole lifecycle.

const DirectMsg = union(enum) {
    event: effects_mod.EffectChannelEvent,
    response: effects_mod.EffectResponse,
    exit: effects_mod.EffectExit,
};

const DirectFx = effects_mod.Effects(DirectMsg);

fn expectData(fx: *DirectFx, key: u64, bytes: []const u8) !effects_mod.EffectChannelEvent {
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(msg == .event);
    try testing.expectEqual(key, msg.event.key);
    try testing.expectEqual(effects_mod.EffectChannelEventKind.data, msg.event.kind);
    try testing.expectEqualStrings(bytes, msg.event.bytes);
    return msg.event;
}

test "channel lifecycle: open, post, deliver in order, close, reopen" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 7, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(handle.shared != null);

    try testing.expectEqual(PostResult.accepted, handle.post("alpha"));
    try testing.expectEqual(PostResult.accepted, handle.post("beta"));
    try testing.expectEqual(PostResult.accepted, handle.post("gamma"));
    try testing.expect(fx.hasPending());

    _ = try expectData(&fx, 7, "alpha");
    _ = try expectData(&fx, 7, "beta");
    const last = try expectData(&fx, 7, "gamma");
    try testing.expectEqual(@as(u32, 0), last.dropped_pending);
    try testing.expectEqual(@as(u32, 0), last.dropped_total);

    fx.closeChannel(7);
    // Posts stop landing the moment close runs — before the terminal
    // even delivers.
    try testing.expectEqual(PostResult.closed, handle.post("late"));
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(u32, 0), closed.event.dropped_total);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());

    // Delivery of `.closed` retired the key: the same key opens again,
    // and the OLD handle's generation is dead against the reused slot.
    const again = fx.openChannel(.{ .key = 7, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.closed, handle.post("stale generation"));
    try testing.expectEqual(PostResult.accepted, again.post("fresh"));
    _ = try expectData(&fx, 7, "fresh");
    fx.closeChannel(7);
    _ = fx.takeMsg();
}

test "channel posts staged before close flush ahead of the closed terminal" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 3, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("one"));
    try testing.expectEqual(PostResult.accepted, handle.post("two"));
    fx.closeChannel(3);
    _ = try expectData(&fx, 3, "one");
    _ = try expectData(&fx, 3, "two");
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
}

const PosterThread = struct {
    fn run(handle: effects_mod.ChannelHandle, count: usize) void {
        var buffer: [32]u8 = undefined;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const line = std.fmt.bufPrint(&buffer, "sample {d}", .{index}) catch unreachable;
            _ = handle.post(line);
        }
    }
};

test "channel posts from a spawned thread deliver in post order" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 11, .on_event = DirectFx.channelMsg(.event) });
    const thread = try std.Thread.spawn(.{}, PosterThread.run, .{ handle, 10 });
    thread.join();

    var buffer: [32]u8 = undefined;
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        const expected = try std.fmt.bufPrint(&buffer, "sample {d}", .{index});
        _ = try expectData(&fx, 11, expected);
    }
    fx.closeChannel(11);
    _ = fx.takeMsg();
}

test "a duplicate occupied key rejects the new open with one terminal" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first = fx.openChannel(.{ .key = 5, .on_event = DirectFx.channelMsg(.event) });
    const dup = fx.openChannel(.{ .key = 5, .on_event = DirectFx.channelMsg(.event) });
    // The refused open's handle is dead — never-fails-from-the-caller's
    // view means the terminal is the report, not an error code.
    try testing.expect(dup.shared == null);
    try testing.expectEqual(PostResult.closed, dup.post("nope"));

    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, rejected.event.kind);
    try testing.expectEqual(@as(u64, 5), rejected.event.key);

    // The first occupancy is untouched.
    try testing.expectEqual(PostResult.accepted, first.post("still live"));
    _ = try expectData(&fx, 5, "still live");
    fx.closeChannel(5);
    _ = fx.takeMsg();
}

test "a full channel table rejects the next open" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var index: u64 = 0;
    while (index < effects_mod.max_effect_channels) : (index += 1) {
        const handle = fx.openChannel(.{ .key = 100 + index, .on_event = DirectFx.channelMsg(.event) });
        try testing.expect(handle.shared != null);
    }
    const overflow = fx.openChannel(.{ .key = 999, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(overflow.shared == null);
    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, rejected.event.kind);
    try testing.expectEqual(@as(u64, 999), rejected.event.key);
}

test "back-pressure: a full staging FIFO refuses posts and the next event carries the counts" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 9, .on_event = DirectFx.channelMsg(.event), .max_pending = 2 });
    try testing.expectEqual(PostResult.accepted, handle.post("kept 1"));
    try testing.expectEqual(PostResult.accepted, handle.post("kept 2"));
    // The stage is full: refused posts answer `.dropped_full` and
    // count — the staged entries are NEVER evicted for the newcomer.
    try testing.expectEqual(PostResult.dropped_full, handle.post("dropped 1"));
    try testing.expectEqual(PostResult.dropped_full, handle.post("dropped 2"));

    const first = try expectData(&fx, 9, "kept 1");
    try testing.expectEqual(@as(u32, 2), first.dropped_pending);
    try testing.expectEqual(@as(u32, 2), first.dropped_total);
    const second = try expectData(&fx, 9, "kept 2");
    // `dropped_pending` reset with the first report; the total is the
    // occupancy's honest cumulative count.
    try testing.expectEqual(@as(u32, 0), second.dropped_pending);
    try testing.expectEqual(@as(u32, 2), second.dropped_total);

    // Room again: posts land, one more refusal counts, and the NEXT
    // delivered event carries it; the `.closed` terminal reports the
    // final cumulative total.
    try testing.expectEqual(PostResult.accepted, handle.post("kept 3"));
    try testing.expectEqual(PostResult.accepted, handle.post("kept 4"));
    try testing.expectEqual(PostResult.dropped_full, handle.post("dropped 3"));
    fx.closeChannel(9);
    const third = try expectData(&fx, 9, "kept 3");
    try testing.expectEqual(@as(u32, 1), third.dropped_pending);
    try testing.expectEqual(@as(u32, 3), third.dropped_total);
    _ = try expectData(&fx, 9, "kept 4");
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(u32, 0), closed.event.dropped_pending);
    try testing.expectEqual(@as(u32, 3), closed.event.dropped_total);
}

test "an oversized post answers dropped_oversized and counts as a drop" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 4, .on_event = DirectFx.channelMsg(.event) });
    const oversized = [_]u8{'x'} ** (effects_mod.max_effect_channel_bytes + 1);
    try testing.expectEqual(PostResult.dropped_oversized, handle.post(&oversized));
    const at_bound = [_]u8{'y'} ** effects_mod.max_effect_channel_bytes;
    try testing.expectEqual(PostResult.accepted, handle.post(&at_bound));

    const event = try expectData(&fx, 4, &at_bound);
    try testing.expectEqual(@as(u32, 1), event.dropped_pending);
    try testing.expectEqual(@as(u32, 1), event.dropped_total);
    fx.closeChannel(4);
    _ = fx.takeMsg();
}

test "teardown closes every channel and post-after-teardown answers closed" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 12, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("staged but never delivered"));
    fx.deinit();
    // The handle resolves through the process-lifetime header, so a
    // source thread that outlives the runtime posts into a closed
    // channel — `.closed`, never a use-after-free.
    try testing.expectEqual(PostResult.closed, handle.post("after teardown"));
}

test "channel keys and slot-family keys share one key space" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // An open channel blocks a same-key fetch...
    const handle = fx.openChannel(.{ .key = 21, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(handle.shared != null);
    fx.fetch(.{ .key = 21, .url = "http://example.test/x", .on_response = DirectFx.responseMsg(.response) });
    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(rejected == .response);
    try testing.expectEqual(effects_mod.EffectFetchOutcome.rejected, rejected.response.outcome);
    try testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());

    // ...through the whole `.closing` window: the key frees only when
    // `.closed` delivers.
    fx.closeChannel(21);
    fx.fetch(.{ .key = 21, .url = "http://example.test/x", .on_response = DirectFx.responseMsg(.response) });
    const still_rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectFetchOutcome.rejected, still_rejected.response.outcome);
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    fx.fetch(.{ .key = 21, .url = "http://example.test/x", .on_response = DirectFx.responseMsg(.response) });
    try testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());

    // And the reverse: a parked same-key effect blocks the channel.
    fx.spawn(.{ .key = 33, .argv = &.{"probe"}, .on_exit = DirectFx.exitMsg(.exit) });
    const blocked = fx.openChannel(.{ .key = 33, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(blocked.shared == null);
    const channel_rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, channel_rejected.event.kind);
    try testing.expectEqual(@as(u64, 33), channel_rejected.event.key);
}

test "channelHandle resolves the open occupancy and nothing else" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expect(fx.channelHandle(6) == null);
    _ = fx.openChannel(.{ .key = 6, .on_event = DirectFx.channelMsg(.event) });
    const resolved = fx.channelHandle(6) orelse return error.TestExpectedHandle;
    try testing.expectEqual(PostResult.accepted, resolved.post("via accessor"));
    fx.closeChannel(6);
    // `.closing` accepts no posts, so the accessor stops resolving.
    try testing.expect(fx.channelHandle(6) == null);
    _ = try expectData(&fx, 6, "via accessor");
    _ = fx.takeMsg();
}

// ---------------------------------------------- record/replay acceptance

const channel_canvas_label = "channel-session-canvas";

const ChannelSessionModel = struct {
    data_events: u32 = 0,
    closed_events: u32 = 0,
    rejected_events: u32 = 0,
    dropped_pending_last: u32 = 0,
    dropped_total_last: u32 = 0,
    /// Rolling order-sensitive digest of every delivered payload — a
    /// replay that reorders or alters one byte diverges here (and in
    /// the fingerprints that pin it).
    payload_digest: u64 = 0,
    last_line: [48]u8 = @splat(' '),
    last_line_len: usize = 0,

    fn record(model: *ChannelSessionModel, event: effects_mod.EffectChannelEvent) void {
        switch (event.kind) {
            .data => model.data_events += 1,
            .closed => model.closed_events += 1,
            .rejected => model.rejected_events += 1,
        }
        model.dropped_pending_last = event.dropped_pending;
        model.dropped_total_last = event.dropped_total;
        model.payload_digest = std.hash.Wyhash.hash(model.payload_digest, event.bytes);
        const len = @min(event.bytes.len, model.last_line.len);
        @memcpy(model.last_line[0..len], event.bytes[0..len]);
        model.last_line_len = len;
    }

    fn lastLine(model: *const ChannelSessionModel) []const u8 {
        return model.last_line[0..model.last_line_len];
    }
};

const ChannelSessionMsg = union(enum) {
    open,
    open_dup,
    close,
    event: effects_mod.EffectChannelEvent,
};

const ChannelSessionApp = ui_app_mod.UiApp(ChannelSessionModel, ChannelSessionMsg);

const session_channel_key: u64 = 41;

/// The handle the recording side hands its posting thread. Replay
/// re-runs the same `openChannel` dispatch (the handle just goes
/// unused — no source thread exists there).
var session_handle: ?effects_mod.ChannelHandle = null;

fn channelSessionUpdate(model: *ChannelSessionModel, msg: ChannelSessionMsg, fx: *ChannelSessionApp.Effects) void {
    switch (msg) {
        .open => session_handle = fx.openChannel(.{
            .key = session_channel_key,
            .on_event = ChannelSessionApp.Effects.channelMsg(.event),
            .max_pending = 2,
        }),
        // The duplicate open: refused loop-side on BOTH sides — the
        // journaled `.rejected` regenerates at replay.
        .open_dup => _ = fx.openChannel(.{
            .key = session_channel_key,
            .on_event = ChannelSessionApp.Effects.channelMsg(.event),
        }),
        .close => fx.closeChannel(session_channel_key),
        .event => |event| model.record(event),
    }
}

fn channelSessionView(ui: *ChannelSessionApp.Ui, model: *const ChannelSessionModel) ChannelSessionApp.Ui.Node {
    // The semantic tree carries every channel-derived model fact, so
    // the fingerprint checkpoints PIN the event stream — kinds, order,
    // payload bytes, and drop accounting alike.
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} data, {d} closed, {d} rejected", .{ model.data_events, model.closed_events, model.rejected_events })),
        ui.text(.{}, ui.fmt("drops {d}/{d}", .{ model.dropped_pending_last, model.dropped_total_last })),
        ui.text(.{}, ui.fmt("digest {x} last {s}", .{ model.payload_digest, model.lastLine() })),
    });
}

fn channelSessionCommand(name: []const u8) ?ChannelSessionMsg {
    if (std.mem.eql(u8, name, "channel.open")) return .open;
    if (std.mem.eql(u8, name, "channel.open-dup")) return .open_dup;
    if (std.mem.eql(u8, name, "channel.close")) return .close;
    return null;
}

const channel_session_views = [_]app_manifest.ShellView{
    .{ .label = channel_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const channel_session_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Channel Session",
    .width = 400,
    .height = 300,
    .views = &channel_session_views,
}};
const channel_session_scene: app_manifest.ShellConfig = .{ .windows = &channel_session_windows };

fn channelSessionOptions() ChannelSessionApp.Options {
    return .{
        .name = "channel-session-demo",
        .scene = channel_session_scene,
        .canvas_label = channel_canvas_label,
        .update_fx = channelSessionUpdate,
        .view = channelSessionView,
        .on_command = channelSessionCommand,
    };
}

const JournalBuffer = struct {
    bytes: [256 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) session_record.RecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

const RecordedChannelSession = struct {
    model: ChannelSessionModel,
    fingerprint: u64,
};

/// One posting burst from a REAL source thread: three lines, joined
/// before the drain so the recorded drop accounting (max_pending = 2:
/// two staged, one honestly refused) is deterministic.
const SessionPoster = struct {
    fn run(handle: effects_mod.ChannelHandle) void {
        _ = handle.post("reading 1: 42 units");
        _ = handle.post("reading 2: 43 units");
        _ = handle.post("reading 3: 44 units");
    }
};

/// Record the channel reference session: open, a real posting thread's
/// burst (with one honest drop), a duplicate open's regenerating
/// rejection, and the close terminal — checkpoints after every wake.
fn recordChannelSession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedChannelSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "channel-session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, channelSessionOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();
    session_handle = null;

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = channel_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.open", .window_id = 1 } });
    const handle = session_handle orelse return error.TestExpectedHandle;

    // The live source: a real thread, joined before any drain so the
    // burst's drop is deterministic (two staged, the third refused by
    // the max_pending bound).
    const poster = try std.Thread.spawn(.{}, SessionPoster.run, .{handle});
    poster.join();
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 2), app_state.model.data_events);
    try testing.expectEqual(@as(u32, 1), app_state.model.dropped_total_last);

    // The duplicate open: one regenerating `.rejected` terminal.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.open-dup", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.rejected_events);

    // One more accepted post after the drain relieved the stage.
    try testing.expectEqual(PostResult.accepted, handle.post("reading 4: 45 units"));
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.close", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.closed_events);
    try testing.expectEqual(PostResult.closed, handle.post("after close"));

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a recorded channel session replays fingerprint-identical offline with no source thread" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordChannelSession(gpa, buffer);
    try testing.expectEqual(@as(u32, 3), recorded.model.data_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.closed_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.rejected_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.dropped_total_last);

    // Replay into a fresh app: the journal is the WHOLE world — no
    // thread posts, no handle is touched, and every fed event arrives
    // verbatim at its recorded position.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, channelSessionOptions());
    defer app_state.deinit();
    session_handle = null;

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // Three data events and the closed terminal FEED (executor truth);
    // the duplicate open's rejection regenerates from the replayed
    // dispatch and its record is skipped.
    try testing.expectEqual(@as(u64, 4), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
    // Replay opened (and close-parked) the channel through the same
    // dispatches; the fed `.closed` retired it — nothing is left open.
    try testing.expect(app_state.effects.channelHandle(session_channel_key) == null);
}

// ------------------------------------------------- replay damage gates

/// Frame a minimal journal around one hand-built channel effect record:
/// header, one `app_start` event (so the effect has a preceding
/// dispatch), the record, and a matching end record.
fn buildChannelDamageJournal(buffer: []u8, record: effects_mod.EffectResultRecord) ![]const u8 {
    var len: usize = 0;
    len += journal.writePreamble(buffer).len;
    var payload: [2 * effects_mod.max_effect_channel_bytes]u8 = undefined;
    var frame: [2 * effects_mod.max_effect_channel_bytes + 64]u8 = undefined;

    const header_payload = try journal.encodeHeader(.{ .platform_name = "test", .app_name = "damage" }, &payload);
    var framed = try journal.frameRecord(.header, header_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const event_payload = try journal.encodeEvent(.app_start, &payload);
    framed = try journal.frameRecord(.event, event_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const effect_payload = try journal.encodeEffect(record, &payload);
    framed = try journal.frameRecord(.effect, effect_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const end_payload = try journal.encodeEnd(.{ .event_count = 1, .effect_count = 1, .checkpoint_count = 0, .screenshot_count = 0 }, &payload);
    framed = try journal.frameRecord(.end, end_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;
    return buffer[0..len];
}

fn replayChannelDamageRecord(record: effects_mod.EffectResultRecord) !session_replay.ReplayReport {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.alloc(u8, 64 * 1024);
    defer std.heap.page_allocator.free(buffer);
    const journal_bytes = try buildChannelDamageJournal(buffer, record);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, channelSessionOptions());
    defer app_state.deinit();
    session_handle = null;

    return session_replay.replaySession(&harness.runtime, app_state.app(), journal_bytes, .{
        .verify = false,
        .require_same_platform = false,
    });
}

test "a channel record with bytes over the post bound refuses replay as damage" {
    // A recorded post can never exceed max_effect_channel_bytes — the
    // handle refuses the bound before staging — so the gate must fire
    // before the fed bytes could reach a fixed-size feed buffer.
    const oversized = [_]u8{'z'} ** (effects_mod.max_effect_channel_bytes + 1);
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .payload = &oversized,
        .channel_kind = .data,
    });
    try testing.expectError(error.ReplayDamagedRecord, result);
}

test "a channel terminal claiming payload bytes refuses replay as damage" {
    // `.closed` and `.rejected` are payload-free by construction; a
    // record that decodes fine but claims otherwise is hand-edited.
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .payload = "not a data event",
        .channel_kind = .closed,
    });
    try testing.expectError(error.ReplayDamagedRecord, result);
}
