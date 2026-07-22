//! External-source channel coverage: the `fx.openChannel` family —
//! lifecycle (open/post/deliver/close), the thread-safe posting handle
//! and its post-close/post-teardown safety, back-pressure drop
//! accounting, the shared key space with the slot-backed families, and
//! the record/replay acceptance story: a session recorded WITH a live
//! posting thread replays fingerprint-identical with no source thread
//! NEEDED — the journaled events are the whole stream. Producers that
//! consult `ChannelHandle.live()` before launching never start under
//! replay (fully offline); producers that launch unconditionally are
//! stopped at their first post. Both shapes are pinned below.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform_mod = @import("../platform/root.zig");
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

test "live() answers the producer-launch question for every handle shape" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The zero handle (and a refused open's dead handle) can accept
    // nothing.
    const zero: effects_mod.ChannelHandle = .{};
    try testing.expect(!zero.live());

    const handle = fx.openChannel(.{ .key = 71, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(handle.live());
    const dup = fx.openChannel(.{ .key = 71, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(!dup.live());

    // Advisory, not a gate: `live()` flips false the moment close runs
    // (posts stop landing before the terminal delivers), and the
    // post's own answer remains authoritative.
    fx.closeChannel(71);
    try testing.expect(!handle.live());
    try testing.expectEqual(PostResult.closed, handle.post("late"));
    while (fx.takeMsg()) |_| {}

    // A reused slot's fresh occupancy: the stale handle stays dead,
    // the fresh one answers for itself.
    const again = fx.openChannel(.{ .key = 71, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(!handle.live());
    try testing.expect(again.live());
    fx.closeChannel(71);
    while (fx.takeMsg()) |_| {}
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

test "under replay openChannel parks the occupancy and hands back an inert handle" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    // The parked occupancy registers exactly as a live open...
    const handle = fx.openChannel(.{ .key = 17, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(fx.channelHandle(17) != null);
    // ...but the handle is INERT: `live()` answers false — the
    // producer-launch check that keeps replay fully offline — and
    // every post answers `.closed` immediately (nothing staged, no
    // drop counted, nothing to journal), so a producer launched
    // unconditionally exits on its first post.
    try testing.expect(!handle.live());
    try testing.expectEqual(PostResult.closed, handle.post("never lands"));
    try testing.expect(!fx.hasPending());
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());

    // closeChannel on the parked occupancy: no live flush, no
    // self-delivered terminal — the slot parks `.closing` until the
    // journaled `.closed` record feeds.
    fx.closeChannel(17);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());

    // The fed events are the ONLY stream: the recorded data and the
    // recorded terminal deliver verbatim (drop counts included), and
    // the fed `.closed` retires the parked occupancy at delivery.
    try fx.feedChannelEvent(17, .data, "recorded sample", 0, 2);
    try fx.feedChannelEvent(17, .closed, "", 0, 2);
    const data = try expectData(&fx, 17, "recorded sample");
    try testing.expectEqual(@as(u32, 2), data.dropped_total);
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(u32, 2), closed.event.dropped_total);
    try testing.expect(fx.channelHandle(17) == null);
}

test "a second rejection record against one park is journal damage, not a second terminal" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    _ = fx.openChannel(.{ .key = 29, .on_event = DirectFx.channelMsg(.event) });
    // The first fed `.rejected` resolves the park's pending-order
    // reservation — one open, one terminal.
    try fx.feedChannelEvent(29, .rejected, "", 0, 0);
    // A SECOND rejection record targeting the same park (a damaged or
    // hand-edited journal — no recorder writes two terminals for one
    // open) must not reuse the vacated reservation and append a
    // duplicate terminal to the one-entry-per-open pending ring.
    try testing.expectError(
        error.ReplayDamagedRecord,
        fx.feedChannelEvent(29, .rejected, "", 0, 0),
    );
    // Exactly one terminal delivers, and it retires the key.
    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, rejected.event.kind);
    try testing.expectEqual(@as(u64, 29), rejected.event.key);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
    try testing.expect(fx.channelHandle(29) == null);
}

test "a data record after the open's rejection terminal is journal damage" {
    // The silent-discard shape: the fed rejection will retire the slot
    // at DELIVERY, so a `.data` fed before that delivery would enqueue,
    // outlive the retire, and then be dropped by the delivery
    // generation gate — an invalid stream that unverified replay would
    // pass. Refused at the feed instead: nothing feeds past a terminal.
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    _ = fx.openChannel(.{ .key = 31, .on_event = DirectFx.channelMsg(.event) });
    try fx.feedChannelEvent(31, .rejected, "", 0, 0);
    try testing.expectError(
        error.ReplayDamagedRecord,
        fx.feedChannelEvent(31, .data, "ghost", 0, 0),
    );
    // Exactly the one terminal delivers, and it retires the key.
    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, rejected.event.kind);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
    try testing.expect(fx.channelHandle(31) == null);
}

test "a data record after the fed closed terminal is journal damage" {
    // The accepted-live stream's twin of the rejection case above: the
    // `.closed` terminal fed, so nothing may target the open again.
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    _ = fx.openChannel(.{ .key = 32, .on_event = DirectFx.channelMsg(.event) });
    try fx.feedChannelEvent(32, .data, "recorded", 0, 0);
    try fx.feedChannelEvent(32, .closed, "", 0, 0);
    try testing.expectError(
        error.ReplayDamagedRecord,
        fx.feedChannelEvent(32, .data, "ghost", 0, 0),
    );
    // The recorded stream still delivers verbatim and retires the key.
    _ = try expectData(&fx, 32, "recorded");
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
    try testing.expect(fx.channelHandle(32) == null);
}

test "a rejection record after the stream proved the open accepted is journal damage" {
    // A refused open delivers nothing before its refusal, so a
    // `.rejected` fed after a `.data` vacated the park is a terminal
    // the recorded open can never have produced — and the refusal must
    // not corrupt the park: the stream's real terminal still lands.
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    _ = fx.openChannel(.{ .key = 33, .on_event = DirectFx.channelMsg(.event) });
    try fx.feedChannelEvent(33, .data, "recorded", 0, 0);
    try testing.expectError(
        error.ReplayDamagedRecord,
        fx.feedChannelEvent(33, .rejected, "", 0, 0),
    );
    try fx.feedChannelEvent(33, .closed, "", 0, 0);
    _ = try expectData(&fx, 33, "recorded");
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
    try testing.expect(fx.channelHandle(33) == null);
}

test "under replay a duplicate open still rejects symmetrically against the parked occupancy" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.armReplay();

    _ = fx.openChannel(.{ .key = 23, .on_event = DirectFx.channelMsg(.event) });
    // The duplicate open is regenerating validation: the replayed
    // dispatch refuses against the parked occupancy exactly as the
    // recording refused against the live one, and delivers its own
    // `.rejected` terminal loop-side (the journaled copy is skipped by
    // the replay pump, not fed).
    const dup = fx.openChannel(.{ .key = 23, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(dup.shared == null);
    try testing.expectEqual(PostResult.closed, dup.post("nope"));
    const rejected = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, rejected.event.kind);
    try testing.expectEqual(@as(u64, 23), rejected.event.key);
    // The parked first occupancy is untouched by the refusal.
    try testing.expect(fx.channelHandle(23) != null);
}

// ------------------------------------------- lock-order invariant gate

/// A test-injected host wake hook standing where a real platform's
/// cross-thread nudge runs (macOS: main-queue dispatch, GTK:
/// `g_idle_add`, Win32: `PostMessage`). It PROBES the poster's lock
/// state: the staging mutex must never be held while the host hook
/// runs — the lock-order invariant documented at `ChannelShared.mutex`.
/// A hook observing the mutex held is the deadlock precursor this gate
/// exists to catch: drain, close, and teardown contend on that mutex,
/// so a wake path that holds it across the host call stalls the loop
/// behind a slow hook and deadlocks outright if the hook ever
/// synchronizes against a loop thread blocked on the same mutex.
const WakeProbe = struct {
    var shared_under_probe: ?*effects_mod.ChannelShared = null;
    var staging_mutex_free_during_wake: ?bool = null;
    var wake_calls: usize = 0;

    fn reset() void {
        shared_under_probe = null;
        staging_mutex_free_during_wake = null;
        wake_calls = 0;
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        wake_calls += 1;
        const shared = shared_under_probe orelse return;
        const free = shared.mutex.inner.tryLock();
        if (free) shared.mutex.inner.unlock();
        staging_mutex_free_during_wake = free;
    }
};

test "the staging mutex is never held across the host wake hook" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeProbe.reset();
    defer WakeProbe.reset();

    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeProbe.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 51, .on_event = DirectFx.channelMsg(.event) });
    WakeProbe.shared_under_probe = handle.shared;

    try testing.expectEqual(PostResult.accepted, handle.post("probe"));
    try testing.expect(WakeProbe.wake_calls >= 1);
    try testing.expectEqual(@as(?bool, true), WakeProbe.staging_mutex_free_during_wake);

    WakeProbe.shared_under_probe = null;
    fx.closeChannel(51);
    _ = try expectData(&fx, 51, "probe");
    _ = fx.takeMsg();
}

// ------------------------------------------------- wake coalescer gates

/// A counting host wake hook for the direct-channel coalescer tests:
/// stands where the null platform's atomic wake counter stands, close
/// enough to the posting seam to observe every individual host call.
const WakeCounter = struct {
    var calls: usize = 0;

    fn reset() void {
        calls = 0;
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        calls += 1;
    }
};

test "a burst of accepted posts latches exactly one host wake" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeCounter.reset();
    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeCounter.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 52, .on_event = DirectFx.channelMsg(.event) });

    // Fill the whole default stage: one wake, not max_effect_channel_pending.
    var index: usize = 0;
    while (index < effects_mod.max_effect_channel_pending) : (index += 1) {
        try testing.expectEqual(PostResult.accepted, handle.post("burst"));
    }
    try testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    // The drain pass unlatches at its boundary and delivers the whole
    // eligible backlog — one wake answered every staged entry.
    var boundary = fx.drainBoundary();
    var delivered: usize = 0;
    while (fx.takeMsgWithin(&boundary)) |msg| {
        try testing.expect(msg == .event);
        delivered += 1;
    }
    try testing.expectEqual(effects_mod.max_effect_channel_pending, delivered);

    // Refill after the drain: the unlatched coalescer wakes exactly
    // once again — the fill/drain/refill cycle costs one wake per
    // drain, never a standing backlog of host-queue entries.
    try testing.expectEqual(PostResult.accepted, handle.post("refill"));
    try testing.expectEqual(PostResult.accepted, handle.post("refill"));
    try testing.expectEqual(@as(usize, 2), WakeCounter.calls);

    fx.closeChannel(52);
    while (fx.takeMsg()) |_| {}
}

test "a post racing the drain lands after the coalescer clear and still wakes" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeCounter.reset();
    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeCounter.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 53, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("before the pass"));
    try testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    // The pass boundary clears the latch BEFORE snapshotting the post
    // order (`drainBoundary`). A post landing after the boundary — the
    // closest deterministic stand-in for one racing the clear/snapshot
    // window, which has no injectable seam between its two lines —
    // must observe the cleared latch and land a FRESH wake, because
    // this pass's snapshot excludes it. Were the clear ordered after
    // the snapshot instead, a racing post would coalesce into a wake
    // this very pass consumes and stall until unrelated traffic.
    var boundary = fx.drainBoundary();
    try testing.expectEqual(PostResult.accepted, handle.post("during the pass"));
    try testing.expectEqual(@as(usize, 2), WakeCounter.calls);

    // The pass delivers only the pre-boundary post...
    const first = fx.takeMsgWithin(&boundary) orelse return error.TestExpectedMsg;
    try testing.expectEqualStrings("before the pass", first.event.bytes);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsgWithin(&boundary));

    // ...and the racing post's fresh wake has a pass of its own.
    var next = fx.drainBoundary();
    const second = fx.takeMsgWithin(&next) orelse return error.TestExpectedMsg;
    try testing.expectEqualStrings("during the pass", second.event.bytes);

    fx.closeChannel(53);
    while (fx.takeMsg()) |_| {}
}

test "a bare-takeMsg drain to empty releases the coalescer: the next accepted post wakes" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeCounter.reset();
    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeCounter.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 65, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("first"));
    try testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    // The public bare-takeMsg drain — no `drainBoundary` anywhere: the
    // caller loops to empty, exactly as documented. The sweep that
    // observes the staged queue empty must release the latch, because
    // no pass boundary ever will on this path.
    while (fx.takeMsg()) |_| {}

    // The stranded-event regression: pre-clear, this accepted post saw
    // the stale latch and never woke — the event sat staged until
    // unrelated traffic. The observation seam is the host wake count
    // (`WakeCounter` stands where the null platform's pendingWakeCount
    // stands): a NEW wake must be issued, and the event must deliver.
    try testing.expectEqual(PostResult.accepted, handle.post("second"));
    try testing.expectEqual(@as(usize, 2), WakeCounter.calls);
    _ = try expectData(&fx, 65, "second");

    fx.closeChannel(65);
    while (fx.takeMsg()) |_| {}
}

const StrandProducer = struct {
    const total: usize = 100;

    fn run(handle: effects_mod.ChannelHandle, stop: *std.atomic.Value(bool)) void {
        var accepted: usize = 0;
        while (accepted < total and !stop.load(.acquire)) {
            switch (handle.post("strand probe")) {
                .accepted => accepted += 1,
                // Transient back-pressure: the documented producer
                // pattern keeps going; the consumer's drain relieves it.
                .dropped_full => std.Thread.yield() catch {},
                else => return,
            }
        }
    }
};

test "an event-driven bare-takeMsg consumer never strands an accepted post" {
    // The race the empty-observation clear must win, run for real: a
    // producer thread posts through the coalescer while an
    // EVENT-DRIVEN consumer drains via bare `takeMsg` — it only
    // drains when the wake count moves, exactly like an embedder
    // servicing wake nudges, so a stranded event (an accepted post
    // whose stale-latch check suppressed the wake AFTER the consumer
    // drained to empty) parks the consumer forever. The clear/post
    // race window (between the sweep's latch clear and its re-check)
    // has no injectable seam, so this pins the invariant
    // probabilistically-but-real, the bind/post handshake test's
    // precedent: completion within the bound IS the assertion.
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    RaceWake.calls.store(0, .seq_cst);
    const services: platform_mod.PlatformServices = .{ .wake_fn = RaceWake.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 66, .on_event = DirectFx.channelMsg(.event) });
    var stop = std.atomic.Value(bool).init(false);
    const producer = try std.Thread.spawn(.{}, StrandProducer.run, .{ handle, &stop });
    defer producer.join();
    defer stop.store(true, .release);

    var received: usize = 0;
    var wakes_seen: usize = 0;
    var waited_ms: usize = 0;
    while (received < StrandProducer.total) {
        const wakes = RaceWake.calls.load(.seq_cst);
        if (wakes > wakes_seen) {
            wakes_seen = wakes;
            while (fx.takeMsg()) |msg| {
                try testing.expect(msg == .event);
                received += 1;
            }
            continue;
        }
        waited_ms += 1;
        if (waited_ms > 30_000) return error.TestStrandedEvent;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    fx.closeChannel(66);
    while (fx.takeMsg()) |_| {}
}

test "a post accepted before services bind is delivered by the bind sweep with no further post" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeCounter.reset();

    // Open-before-bind is supported: the channel is live and posts are
    // ACCEPTED — but no host services exist to wake, and nothing is
    // latched (a latch with no wake behind it would suppress the real
    // wake later).
    const handle = fx.openChannel(.{ .key = 55, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("early sample"));
    try testing.expectEqual(@as(usize, 0), WakeCounter.calls);

    // Binding sweeps: the pre-bind staged post gets its one catch-up
    // host wake at bind time, with NO further post. (Pre-sweep, a
    // one-shot producer stranded here forever: `.accepted` with no
    // wake, and nothing else ever nudging the host.)
    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeCounter.wake };
    fx.bindServices(&services);
    try testing.expectEqual(@as(usize, 1), WakeCounter.calls);

    // The wake's drain pass delivers the pre-bind post.
    var boundary = fx.drainBoundary();
    const msg = fx.takeMsgWithin(&boundary) orelse return error.TestExpectedMsg;
    try testing.expectEqualStrings("early sample", msg.event.bytes);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsgWithin(&boundary));

    // And the post-bind path is the ordinary latched wake.
    try testing.expectEqual(PostResult.accepted, handle.post("late sample"));
    try testing.expectEqual(@as(usize, 2), WakeCounter.calls);
    fx.closeChannel(55);
    while (fx.takeMsg()) |_| {}
}

test "an idle bind sweeps nothing" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    WakeCounter.reset();

    // A channel is open but nothing is staged: binding must NOT wake —
    // the sweep answers staged work, not open occupancies, so an idle
    // app pays no spurious host-queue entry at startup.
    _ = fx.openChannel(.{ .key = 56, .on_event = DirectFx.channelMsg(.event) });
    const services: platform_mod.PlatformServices = .{ .wake_fn = WakeCounter.wake };
    fx.bindServices(&services);
    try testing.expectEqual(@as(usize, 0), WakeCounter.calls);
    fx.closeChannel(56);
    while (fx.takeMsg()) |_| {}
}

/// An atomic wake counter plus a start gate for the concurrent
/// bind/post handshake test below: the wake hook runs on whichever
/// thread posted, so the counter must be an atomic, not `WakeCounter`'s
/// loop-thread-only plain var.
const RaceWake = struct {
    var calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        _ = calls.fetchAdd(1, .seq_cst);
    }
};

const RacePoster = struct {
    fn run(handle: effects_mod.ChannelHandle, start: *std.atomic.Value(bool)) void {
        while (!start.load(.acquire)) std.atomic.spinLoopHint();
        _ = handle.post("racing sample");
    }
};

test "a post racing bindServices is never stranded: one side always wakes" {
    // The bind/post handshake is a store-buffer (Dekker) pairing over
    // two atomics: the binder stores `wake_services` then loads the
    // pending count (`hasPending`), while a poster increments the
    // pending count then loads `wake_services`. Unless all four
    // operations are seq_cst, both sides can read the stale value —
    // the poster sees no services (wakes nobody), the binder sees no
    // pending work (sweeps nothing) — and an ACCEPTED post strands
    // until unrelated traffic. This test is probabilistic-but-real
    // for that race class: it aligns one post against one bind per
    // iteration and asserts the handshake's invariant — at least one
    // side always acts, so a wake is observed and the post drains.
    // A bounded iteration count keeps the suite fast; a regression
    // here may pass on hardware/toolchains where the reorder happens
    // not to bite, but the seq_cst repair is what the memory model
    // itself guarantees.
    var iteration: usize = 0;
    while (iteration < 300) : (iteration += 1) {
        var fx = DirectFx.init(testing.allocator);
        defer fx.deinit();
        fx.executor = .fake;
        RaceWake.calls.store(0, .seq_cst);

        const handle = fx.openChannel(.{ .key = 61, .on_event = DirectFx.channelMsg(.event) });
        const services: platform_mod.PlatformServices = .{ .wake_fn = RaceWake.wake };

        var start = std.atomic.Value(bool).init(false);
        const poster = try std.Thread.spawn(.{}, RacePoster.run, .{ handle, &start });
        start.store(true, .release);
        fx.bindServices(&services);
        poster.join();

        // The post was accepted (open channel, empty stage), so it
        // must never strand: either the poster observed the published
        // services and latched its own wake, or the binder observed
        // the staged post and swept — one host wake either way.
        try testing.expect(RaceWake.calls.load(.seq_cst) >= 1);
        // And the staged work is drainable at that wake.
        _ = try expectData(&fx, 61, "racing sample");
        fx.closeChannel(61);
        while (fx.takeMsg()) |_| {}
    }
}

/// A wake hook that posts back into the channel that woke it — the
/// reentrant shape a well-behaved hook avoids (enqueue-only), turned
/// into a regression gate: pre-split this deadlocked on the staging
/// mutex, and the coalescer's pre-latched flag is what lets the inner
/// post coalesce lock-free and return — without it, the inner post
/// would find the (now free, see `ChannelWake`) wake mutex and
/// re-enter the hook unboundedly.
const ReentrantPoster = struct {
    var handle: ?effects_mod.ChannelHandle = null;
    var inner_result: ?PostResult = null;

    fn reset() void {
        handle = null;
        inner_result = null;
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        const h = handle orelse return;
        if (inner_result != null) return;
        inner_result = h.post("reentrant");
    }
};

test "a wake hook that posts back into the same channel coalesces instead of deadlocking" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    ReentrantPoster.reset();
    defer ReentrantPoster.reset();
    const services: platform_mod.PlatformServices = .{ .wake_fn = ReentrantPoster.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 54, .on_event = DirectFx.channelMsg(.event) });
    ReentrantPoster.handle = handle;

    // The outer post latches the wake, then runs the hook; the hook's
    // inner post stages (the staging mutex is free — the lock-order
    // invariant) and coalesces on the latched flag without touching
    // the wake mutex the outer post still holds.
    try testing.expectEqual(PostResult.accepted, handle.post("outer"));
    try testing.expectEqual(@as(?PostResult, .accepted), ReentrantPoster.inner_result);

    // Both entries ride the one latched wake, in post order.
    ReentrantPoster.handle = null;
    _ = try expectData(&fx, 54, "outer");
    _ = try expectData(&fx, 54, "reentrant");
    fx.closeChannel(54);
    while (fx.takeMsg()) |_| {}
}

/// VIOLATOR-CONTAINMENT PIN, not a supported-usage example. A wake
/// hook that takes the exact locks the LOOP THREAD takes at every pass
/// boundary: `drainBoundary` acquires each channel's wake mutex to
/// clear the coalescer. A hook that synchronizes with the loop this
/// way VIOLATES the wake contract (`PlatformServices.wake_fn` is
/// bounded and enqueue-only), but the contract is unenforceable, so
/// the runtime must survive its own half: the host call runs with the
/// wake mutex FREE, and a violator hangs only in its own stack — never
/// in the runtime's lock graph. When the call ran under the mutex,
/// this hook deadlocked (`drainBoundary` spinning on the wake mutex
/// the post still held); with the in-flight fence it completes. That
/// containment is the behavior pinned here.
const BoundaryTakingWake = struct {
    var fx_under_test: ?*DirectFx = null;
    var shared_under_probe: ?*effects_mod.ChannelShared = null;
    var wake_mutex_free_during_wake: ?bool = null;
    var boundary_taken: bool = false;

    fn reset() void {
        fx_under_test = null;
        shared_under_probe = null;
        wake_mutex_free_during_wake = null;
        boundary_taken = false;
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        // Pin the invariant directly: the wake mutex is free while the
        // hook runs (the disarm fence is the in-flight count, never
        // lock tenure).
        if (shared_under_probe) |shared| {
            const free = shared.wake.mutex.inner.tryLock();
            if (free) shared.wake.mutex.inner.unlock();
            wake_mutex_free_during_wake = free;
        }
        // And prove it end to end: take the loop's own pass boundary —
        // the same wake-mutex acquisition drainBoundary performs —
        // from inside the host call.
        const fx = fx_under_test orelse return;
        if (boundary_taken) return;
        boundary_taken = true;
        _ = fx.drainBoundary();
    }
};

test "violator containment: a wake hook that takes the drain's pass boundary cannot deadlock the runtime's lock graph" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    BoundaryTakingWake.reset();
    defer BoundaryTakingWake.reset();
    const services: platform_mod.PlatformServices = .{ .wake_fn = BoundaryTakingWake.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 57, .on_event = DirectFx.channelMsg(.event) });
    BoundaryTakingWake.fx_under_test = &fx;
    BoundaryTakingWake.shared_under_probe = handle.shared;

    // Deadlocked here pre-fix: the post held the wake mutex through
    // the hook while the hook's drainBoundary spun on the same mutex.
    try testing.expectEqual(PostResult.accepted, handle.post("boundary probe"));
    try testing.expect(BoundaryTakingWake.boundary_taken);
    try testing.expectEqual(@as(?bool, true), BoundaryTakingWake.wake_mutex_free_during_wake);

    // The hook's boundary cleared the coalescer, so the staged entry
    // still delivers and a later post latches a fresh wake of its own.
    BoundaryTakingWake.fx_under_test = null;
    BoundaryTakingWake.shared_under_probe = null;
    _ = try expectData(&fx, 57, "boundary probe");
    fx.closeChannel(57);
    while (fx.takeMsg()) |_| {}
}

/// VIOLATOR-CONTAINMENT PIN, not a supported-usage example. A wake
/// hook that SYNCHRONOUSLY MARSHALS to the loop thread — the
/// dispatch-sync shape (macOS `dispatch_sync` onto the main queue,
/// Win32 `SendMessage`): the hook returns only after the loop thread
/// has serviced the marshaled dispatch. This VIOLATES the wake
/// contract (`PlatformServices.wake_fn` is bounded and enqueue-only —
/// the first-party hosts all enqueue), but the contract is
/// unenforceable, and this is the exact shape that turned the close
/// path's blocking in-flight wait into a deadlock of the runtime's own
/// making: the marshaled dispatch delivers the channel message, the
/// message's handler calls `closeChannel`, and a close that waits for
/// `in_flight == 0` waits on a hook that waits on the loop. The
/// runtime's half of the containment — pinned here — is that the close
/// path REVOKES the binding (non-blocking) and lets the in-flight call
/// finish against the process-lifetime header on its own time; only
/// teardown quiesces, bounded (see `quiesceChannelWake`). The violator
/// hangs nothing but its own posting thread.
const SyncMarshalWake = struct {
    var loop_thread: std.Thread.Id = 0;
    var marshal_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var dispatch_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn reset() void {
        loop_thread = 0;
        marshal_requested.store(false, .seq_cst);
        dispatch_done.store(false, .seq_cst);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        // A wake issued ON the loop thread dispatches inline — the
        // real synchronous-marshal primitives behave the same way
        // (dispatch_sync from the target queue would deadlock, so a
        // real hook checks; `SendMessage` to the calling thread's own
        // window runs the procedure directly). Only a producer-thread
        // wake marshals and blocks.
        if (std.Thread.getCurrentId() == loop_thread) return;
        marshal_requested.store(true, .seq_cst);
        // The synchronous marshal: block until the loop thread reports
        // the dispatched handler ran to completion.
        while (!dispatch_done.load(.seq_cst)) std.atomic.spinLoopHint();
    }
};

const SyncMarshalPoster = struct {
    fn run(handle: effects_mod.ChannelHandle, result: *PostResult) void {
        result.* = handle.post("marshal me");
    }
};

test "violator containment: a synchronous-marshal wake whose dispatched handler closes the channel completes instead of deadlocking" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    SyncMarshalWake.reset();
    defer SyncMarshalWake.reset();
    SyncMarshalWake.loop_thread = std.Thread.getCurrentId();
    const services: platform_mod.PlatformServices = .{ .wake_fn = SyncMarshalWake.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 58, .on_event = DirectFx.channelMsg(.event) });
    var post_result: PostResult = .closed;
    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ handle, &post_result });
    // An error return must still release the marshal and collect the
    // producer, or the blocked thread would hang the suite behind the
    // failure.
    var joined = false;
    errdefer SyncMarshalWake.dispatch_done.store(true, .seq_cst);
    defer if (!joined) producer.join();

    // Wait (bounded — fail loud, never hang the suite) for the
    // producer to reach the inside of `wake_fn`: from here on it is
    // blocked until the loop services its marshal, with the wake's
    // in-flight count held at one.
    var waited_ms: usize = 0;
    while (!SyncMarshalWake.marshal_requested.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedMarshal;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    // Service the marshaled dispatch on the loop thread: deliver the
    // channel message, and — as the app's update — close the channel.
    // Pre-split this deadlocked HERE: `closeChannel`'s disarm spun on
    // `in_flight == 0` while the producer spun inside `wake_fn`
    // waiting for this very dispatch to complete.
    _ = try expectData(&fx, 58, "marshal me");
    fx.closeChannel(58);
    try testing.expectEqual(PostResult.closed, handle.post("after close"));
    SyncMarshalWake.dispatch_done.store(true, .seq_cst);
    producer.join();
    joined = true;
    try testing.expectEqual(PostResult.accepted, post_result);

    // The close delivers its `.closed` terminal exactly once.
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    try testing.expectEqual(@as(?DirectMsg, null), fx.takeMsg());
}

/// A wake hook held OPEN mid-call while the loop closes, drains, and
/// REOPENS the channel — the stale in-flight call the revoke split
/// leaves behind on purpose (a hook that blocks like this violates the
/// enqueue-only wake contract; this pin is the containment's
/// generation-safety half). The gated call FAILS once released, so
/// its post-call failure unlatch runs against a dead generation: the
/// gate in `requestHostWake` must keep it from clearing the fresh
/// occupancy's latched wake, and its decrement must land safely in the
/// process-lifetime header.
const StaleWakeCall = struct {
    var loop_thread: std.Thread.Id = 0;
    var gate_armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn reset() void {
        loop_thread = 0;
        gate_armed.store(false, .seq_cst);
        blocked.store(false, .seq_cst);
        release.store(false, .seq_cst);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        if (std.Thread.getCurrentId() == loop_thread) return;
        if (!gate_armed.swap(false, .seq_cst)) return;
        blocked.store(true, .seq_cst);
        while (!release.load(.seq_cst)) std.atomic.spinLoopHint();
        return error.WakeRefused;
    }
};

test "a stale in-flight wake call outliving close and reopen cannot unlatch the fresh occupancy" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    StaleWakeCall.reset();
    defer StaleWakeCall.reset();
    StaleWakeCall.loop_thread = std.Thread.getCurrentId();
    const services: platform_mod.PlatformServices = .{ .wake_fn = StaleWakeCall.wake };
    fx.bindServices(&services);

    const stale = fx.openChannel(.{ .key = 62, .on_event = DirectFx.channelMsg(.event) });
    StaleWakeCall.gate_armed.store(true, .seq_cst);
    var post_result: PostResult = .closed;
    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ stale, &post_result });
    var joined = false;
    errdefer StaleWakeCall.release.store(true, .seq_cst);
    defer if (!joined) producer.join();

    var waited_ms: usize = 0;
    while (!StaleWakeCall.blocked.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedBlockedWake;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    // Close and fully retire the first occupancy WHILE the stale call
    // is still inside the hook (revoke is non-blocking), then reopen
    // the same key: a fresh generation on the same process-lifetime
    // header.
    fx.closeChannel(62);
    _ = try expectData(&fx, 62, "marshal me");
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);
    const fresh = fx.openChannel(.{ .key = 62, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(fresh.shared != null);

    // The fresh occupancy latches its own wake (the loop-thread call
    // dispatches inline and SUCCEEDS, so the latch stays set).
    try testing.expectEqual(PostResult.accepted, fresh.post("fresh"));
    try testing.expect(fresh.shared.?.wake.pending.load(.seq_cst));

    // Release the stale call: it fails, and its failure unlatch runs
    // with the dead generation — the gate must refuse it. The
    // decrement lands in the process-lifetime header either way.
    StaleWakeCall.release.store(true, .seq_cst);
    producer.join();
    joined = true;
    try testing.expectEqual(PostResult.accepted, post_result);
    try testing.expect(fresh.shared.?.wake.pending.load(.seq_cst));

    // The fresh occupancy's staged post is untouched.
    _ = try expectData(&fx, 62, "fresh");
    fx.closeChannel(62);
    while (fx.takeMsg()) |_| {}
}

/// A wake hook that dawdles inside the call so teardown's quiesce has
/// something real to wait out: enters, sleeps, marks itself returned.
const SlowTeardownWake = struct {
    var loop_thread: std.Thread.Id = 0;
    var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn reset() void {
        loop_thread = 0;
        entered.store(false, .seq_cst);
        returned.store(false, .seq_cst);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        if (std.Thread.getCurrentId() == loop_thread) return;
        entered.store(true, .seq_cst);
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .awake);
        returned.store(true, .seq_cst);
    }
};

test "teardown quiesces an in-flight wake call before the services binding dies" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    SlowTeardownWake.reset();
    defer SlowTeardownWake.reset();
    SlowTeardownWake.loop_thread = std.Thread.getCurrentId();
    const services: platform_mod.PlatformServices = .{ .wake_fn = SlowTeardownWake.wake };
    fx.bindServices(&services);

    const handle = fx.openChannel(.{ .key = 63, .on_event = DirectFx.channelMsg(.event) });
    var post_result: PostResult = .closed;
    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ handle, &post_result });
    defer producer.join();

    var waited_ms: usize = 0;
    while (!SlowTeardownWake.entered.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedWakeEntry;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    // Teardown while the producer is inside `wake_fn`: deinit severs
    // the services binding, so its channel sweep must WAIT for the
    // in-flight call — a revoke-only teardown could tear the platform
    // down under a hook still executing inside it. The quiesce
    // returning cleanly (no abandon counted) proves the wait covered
    // the whole call.
    fx.deinit();
    try testing.expect(SlowTeardownWake.returned.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fx.abandoned_channel_wakes);
}

/// A wake hook stuck PAST teardown's deadline — the shape quiesce
/// cannot wait out (a synchronous marshal against the stopping loop
/// never returns; a wake-contract violation, which is the only way the
/// deadline is ever met), pinned with a test-released gate instead.
const StuckTeardownWake = struct {
    var loop_thread: std.Thread.Id = 0;
    var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn reset() void {
        loop_thread = 0;
        entered.store(false, .seq_cst);
        release.store(false, .seq_cst);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        _ = context;
        if (std.Thread.getCurrentId() == loop_thread) return;
        entered.store(true, .seq_cst);
        while (!release.load(.seq_cst)) std.atomic.spinLoopHint();
    }
};

test "teardown abandons a wake call still stuck at the deadline and the stale call stays safe" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    // A tiny injected budget so the abandon safety net is reached
    // deterministically (the real default is generous; see
    // `default_channel_wake_join_deadline_ms`).
    fx.channel_wake_join_deadline_ms = 50;
    StuckTeardownWake.reset();
    defer StuckTeardownWake.reset();
    StuckTeardownWake.loop_thread = std.Thread.getCurrentId();
    // A real (null) platform behind the services table, with its
    // conforming wake REPLACED by the stuck hook: the abandon-report
    // seam (`note_channel_wake_abandoned_fn`) stays the platform's own,
    // so the test observes the platform half of the abandon — the
    // destroy gate — through the null platform's reference model.
    const null_platform = try testing.allocator.create(platform_mod.NullPlatform);
    defer testing.allocator.destroy(null_platform);
    null_platform.* = platform_mod.NullPlatform.init(.{});
    var host_platform = null_platform.platform();
    host_platform.services.wake_fn = StuckTeardownWake.wake;
    fx.bindServices(&host_platform.services);

    const handle = fx.openChannel(.{ .key = 64, .on_event = DirectFx.channelMsg(.event) });
    var post_result: PostResult = .closed;
    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ handle, &post_result });
    var joined = false;
    errdefer StuckTeardownWake.release.store(true, .seq_cst);
    defer if (!joined) producer.join();

    var waited_ms: usize = 0;
    while (!StuckTeardownWake.entered.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedWakeEntry;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    // Teardown cannot wait this one out — deinit must return within
    // its bounded budget, warn, and count the abandon rather than
    // hang the app's exit forever behind a hook nobody will release.
    fx.deinit();
    try testing.expectEqual(@as(u32, 1), fx.abandoned_channel_wakes);

    // The abandon was reported to the platform, synchronously, while
    // it was alive: the latch is set...
    try testing.expect(null_platform.channel_wake_abandoned.load(.seq_cst));
    // ...and the platform-destroy path is SUPPRESSED — deinit consults
    // the latch, skips destruction, and leaks the host, process-lived,
    // so the stale call still inside `wake_fn` can never execute into
    // freed host state (the real hosts' destroy gate, observed through
    // the null platform's reference model).
    null_platform.deinit();
    try testing.expect(!null_platform.destroyed);

    // The abandoned call unblocks LATER and finishes against the
    // process-lifetime header — a safe decrement, never a
    // use-after-free — and the post it served still answers honestly.
    StuckTeardownWake.release.store(true, .seq_cst);
    producer.join();
    joined = true;
    try testing.expectEqual(PostResult.accepted, post_result);
    try testing.expectEqual(PostResult.closed, handle.post("after teardown"));
}

test "a conforming enqueue-only wake at teardown quiesces fast and platform destruction proceeds" {
    // The two-sided contract's healthy half, pinned as the abandon
    // test's non-regression twin: with the platform's OWN wake (the
    // null platform's atomic counter — bounded, enqueue-only, the
    // contract at `PlatformServices.wake_fn`), teardown's quiesce
    // covers every in-flight call without ever nearing the deadline,
    // nothing is abandoned, and the platform destroys normally.
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    const null_platform = try testing.allocator.create(platform_mod.NullPlatform);
    defer testing.allocator.destroy(null_platform);
    null_platform.* = platform_mod.NullPlatform.init(.{});
    const host_platform = null_platform.platform();
    fx.bindServices(&host_platform.services);

    const handle = fx.openChannel(.{ .key = 65, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("healthy"));
    // The conforming wake already returned: it enqueued (the null
    // platform counts) and nothing lingers inside the hook.
    try testing.expect(null_platform.wake_count.load(.acquire) >= 1);

    fx.deinit();
    try testing.expectEqual(@as(u32, 0), fx.abandoned_channel_wakes);

    // No abandon, no latch, no leak: destruction proceeds.
    try testing.expect(!null_platform.channel_wake_abandoned.load(.seq_cst));
    null_platform.deinit();
    try testing.expect(null_platform.destroyed);
    try testing.expectEqual(PostResult.closed, handle.post("after teardown"));
}

/// A wake hook stuck past the deadline whose FIRST context dereference
/// happens only after it is released — which the test arranges to be
/// strictly after teardown completed, the platform destroy path ran,
/// and the stack frame that owned the bound services value unwound.
/// The abandon doctrine's whole claim ("may execute at any later
/// time") is that this dereference reads valid memory; the two earlier
/// abandon tests could not see it because their hooks ignore context
/// and rejoin while every owner is still alive.
const AfterTeardownDerefWake = struct {
    var loop_thread: std.Thread.Id = 0;
    var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    /// What the resumed hook read through its context AFTER teardown:
    /// the leaked platform's latched abandon flag. Valid (leaked)
    /// memory reads true; a freed or reused wrapper could read
    /// anything, so the assertion is on the value, not just on not
    /// crashing.
    var observed_latch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    fn reset() void {
        loop_thread = 0;
        entered.store(false, .seq_cst);
        release.store(false, .seq_cst);
        observed_latch.store(false, .seq_cst);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        if (std.Thread.getCurrentId() == loop_thread) return;
        entered.store(true, .seq_cst);
        while (!release.load(.seq_cst)) std.atomic.spinLoopHint();
        // Resumed after teardown: the one dereference the abandon-leak
        // doctrine exists to keep valid.
        const stale_platform: *platform_mod.NullPlatform = @ptrCast(@alignCast(context.?));
        observed_latch.store(stale_platform.channel_wake_abandoned.load(.seq_cst), .seq_cst);
    }
};

/// The dying-owner scope for the after-teardown test: the `Platform`
/// value whose services table `bindServices` receives lives in THIS
/// frame — standing in for the heap Runtime the real runners bind
/// against, destroyed right after effects teardown — and the frame
/// poisons it (0xAA) before returning, so any pointer into it held
/// past this function reads the pattern, never a valid table. Returns
/// with teardown complete, the abandon counted, and the stale call
/// still parked inside the stuck hook.
fn abandonAgainstDyingOwner(
    fx: *DirectFx,
    null_platform: *platform_mod.NullPlatform,
    post_result: *PostResult,
    handle_out: *effects_mod.ChannelHandle,
    snapshot_out: **const platform_mod.PlatformServices,
) !std.Thread {
    var host_platform = null_platform.platform();
    host_platform.services.wake_fn = AfterTeardownDerefWake.wake;
    fx.bindServices(&host_platform.services);

    const handle = fx.openChannel(.{ .key = 66, .on_event = DirectFx.channelMsg(.event) });
    handle_out.* = handle;
    // The decoupling under test: what the bind generation PUBLISHED to
    // posting threads (lazily, at this first open) is the snapshot,
    // never this frame's value.
    const snapshot = fx.wake_services.load(.seq_cst) orelse return error.TestExpectedSnapshot;
    try testing.expect(snapshot != &host_platform.services);
    snapshot_out.* = snapshot;
    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ handle, post_result });
    errdefer AfterTeardownDerefWake.release.store(true, .seq_cst);
    var waited_ms: usize = 0;
    while (!AfterTeardownDerefWake.entered.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedWakeEntry;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    // Bounded quiesce meets the deadline against the parked hook:
    // ABANDON, latch, warn — teardown completes while the call is
    // still inside `wake_fn`.
    fx.deinit();
    try testing.expectEqual(@as(u32, 1), fx.abandoned_channel_wakes);
    // The frame is about to die; poison the services value it owned so
    // a stale pointer into it reads a deterministic pattern instead of
    // whatever the dead frame happens to leave behind.
    @memset(std.mem.asBytes(&host_platform), 0xAA);
    return producer;
}

test "an abandoned wake call dereferences its context and services snapshot only after teardown and the owning scopes died" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    fx.channel_wake_join_deadline_ms = 50;
    AfterTeardownDerefWake.reset();
    defer AfterTeardownDerefWake.reset();
    AfterTeardownDerefWake.loop_thread = std.Thread.getCurrentId();
    // The wrapper through the runners' own lifetime seam: heap-allocated
    // by `createWithOptions`, retired by `destroy`, the latch-gated free.
    const null_platform = try platform_mod.NullPlatform.createWithOptions(.{}, .system, .{});
    var post_result: PostResult = .closed;
    var handle: effects_mod.ChannelHandle = undefined;
    var snapshot: *const platform_mod.PlatformServices = undefined;
    const producer = try abandonAgainstDyingOwner(&fx, null_platform, &post_result, &handle, &snapshot);
    var joined = false;
    errdefer AfterTeardownDerefWake.release.store(true, .seq_cst);
    defer if (!joined) producer.join();

    // Teardown is complete and the frame that owned the bound services
    // value unwound, poisoned. The runner-shaped destroy runs next:
    // the abandon latched, so deinit skips destruction AND the storage
    // free is skipped — wrapper and host leaked, process-lived. The
    // reads below stay valid BECAUSE of that leak.
    try testing.expect(null_platform.channel_wake_abandoned.load(.seq_cst));
    null_platform.destroy();
    try testing.expect(!null_platform.destroyed);

    // What a poster suspended between capturing the published services
    // pointer and dereferencing it inside `services.wake()` reads NOW,
    // after the owner died: the immortal snapshot with the bound table
    // intact — never the poisoned frame value.
    try testing.expect(snapshot.wake_fn == AfterTeardownDerefWake.wake);
    try testing.expect(snapshot.context == @as(?*anyopaque, null_platform));

    // Release the parked call: it resumes and dereferences its CONTEXT
    // for the first time — strictly after teardown, destroy, and the
    // owner frame's death — and must read the leaked platform's latched
    // flag from valid memory. Its post still answers honestly, and the
    // handle stays a safe `.closed` forever.
    AfterTeardownDerefWake.release.store(true, .seq_cst);
    producer.join();
    joined = true;
    try testing.expect(AfterTeardownDerefWake.observed_latch.load(.seq_cst));
    try testing.expectEqual(PostResult.accepted, post_result);
    try testing.expectEqual(PostResult.closed, handle.post("after the owners died"));
}

/// Records every allocation and free routed through the
/// channel-storage seam, by count and by pointer — the snapshot
/// lifetime tests' observability: laziness (no allocation while no
/// channel opens), the clean-teardown free, and the abandon path's
/// deliberate leak. Forwards everything to the page allocator
/// (`process_allocator`'s backing), so retire/teardown frees stay
/// valid.
const TrackingChannelStorageAllocator = struct {
    backing: std.mem.Allocator = std.heap.page_allocator,
    alloc_count: usize = 0,
    freed_ptrs: [16]usize = @splat(0),
    freed_len: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *TrackingChannelStorageAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn didFree(self: *const TrackingChannelStorageAllocator, ptr: *const anyopaque) bool {
        for (self.freed_ptrs[0..self.freed_len]) |freed| {
            if (freed == @intFromPtr(ptr)) return true;
        }
        return false;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingChannelStorageAllocator = @ptrCast(@alignCast(ptr));
        self.alloc_count += 1;
        return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingChannelStorageAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingChannelStorageAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingChannelStorageAllocator = @ptrCast(@alignCast(ptr));
        if (self.freed_len < self.freed_ptrs.len) {
            self.freed_ptrs[self.freed_len] = @intFromPtr(memory.ptr);
            self.freed_len += 1;
        }
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }
};

test "bindServices with no channels allocates nothing: the services snapshot is lazy" {
    var tracker: TrackingChannelStorageAllocator = .{};
    var services: platform_mod.PlatformServices = .{};
    // Repeated app lifetimes that never open a channel — the test-suite
    // and embed-host cycling shape: bind + teardown, several rounds.
    // The process-lived snapshot must never materialize, so repeated
    // app creation accumulates nothing.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        var fx = DirectFx.init(testing.allocator);
        fx.executor = .fake;
        fx.channel_storage_allocator = tracker.allocator();
        fx.bindServices(&services);
        // The bind recorded the loop-thread services pointer but
        // published no snapshot: no channel wake exists to consume one.
        try testing.expect(fx.services != null);
        try testing.expectEqual(@as(?*const platform_mod.PlatformServices, null), fx.wake_services.load(.seq_cst));
        fx.deinit();
    }
    try testing.expectEqual(@as(usize, 0), tracker.alloc_count);
}

test "a channel that opens and tears down cleanly frees the services snapshot" {
    // The immortality exemption is gone from the healthy path: the
    // snapshot materializes at the first live open (lazily — the bind
    // alone published nothing) and a clean teardown, having quiesced
    // every wake header with zero abandons, proves no poster can still
    // reach it and frees it.
    var tracker: TrackingChannelStorageAllocator = .{};
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    fx.channel_storage_allocator = tracker.allocator();
    const null_platform = try testing.allocator.create(platform_mod.NullPlatform);
    defer testing.allocator.destroy(null_platform);
    null_platform.* = platform_mod.NullPlatform.init(.{});
    const host_platform = null_platform.platform();

    fx.bindServices(&host_platform.services);
    try testing.expectEqual(@as(?*const platform_mod.PlatformServices, null), fx.wake_services.load(.seq_cst));
    const handle = fx.openChannel(.{ .key = 69, .on_event = DirectFx.channelMsg(.event) });
    const snapshot = fx.wake_snapshot orelse return error.TestExpectedSnapshot;
    try testing.expectEqual(@as(?*const platform_mod.PlatformServices, snapshot), fx.wake_services.load(.seq_cst));
    // The snapshot is live plumbing, not bookkeeping: a producer post
    // wakes the host through it.
    try testing.expectEqual(PostResult.accepted, handle.post("healthy"));
    try testing.expect(null_platform.wake_count.load(.acquire) >= 1);
    _ = try expectData(&fx, 69, "healthy");

    fx.deinit();
    try testing.expectEqual(@as(u32, 0), fx.abandoned_channel_wakes);
    try testing.expect(fx.wake_snapshot == null);
    try testing.expect(tracker.didFree(snapshot));
}

/// The rebind coverage's two hooks: the FIRST generation's hook parks
/// until released — so its teardown ABANDONS the in-flight call, which
/// is now the ONE shape that makes a generation's snapshot immortal —
/// and the second is a plain conforming counter.
const RebindWakes = struct {
    var loop_thread: std.Thread.Id = 0;
    var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var second_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    fn reset() void {
        loop_thread = 0;
        entered.store(false, .seq_cst);
        release.store(false, .seq_cst);
        second_count.store(0, .seq_cst);
    }

    fn first(context: ?*anyopaque) anyerror!void {
        _ = context;
        if (std.Thread.getCurrentId() == loop_thread) return;
        entered.store(true, .seq_cst);
        while (!release.load(.seq_cst)) std.atomic.spinLoopHint();
    }

    fn second(context: ?*anyopaque) anyerror!void {
        _ = context;
        _ = second_count.fetchAdd(1, .seq_cst);
    }
};

/// First bind generation in a frame that dies, ending in an ABANDON:
/// bind, open, park a producer's wake call inside the stuck hook, tear
/// down past the deadline (the abandon is what keeps this generation's
/// snapshot immortal), then poison the frame-owned services value
/// before returning the snapshot pointer the stale call still holds.
fn bindFirstGeneration(fx: *DirectFx, post_result: *PostResult) !struct {
    snapshot: *const platform_mod.PlatformServices,
    producer: std.Thread,
} {
    var services: platform_mod.PlatformServices = .{ .wake_fn = RebindWakes.first };
    fx.bindServices(&services);
    const handle = fx.openChannel(.{ .key = 67, .on_event = DirectFx.channelMsg(.event) });
    const snapshot = fx.wake_services.load(.seq_cst) orelse return error.TestExpectedSnapshot;
    try testing.expect(snapshot != &services);

    const producer = try std.Thread.spawn(.{}, SyncMarshalPoster.run, .{ handle, post_result });
    errdefer RebindWakes.release.store(true, .seq_cst);
    var waited_ms: usize = 0;
    while (!RebindWakes.entered.load(.seq_cst)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.TestExpectedWakeEntry;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }

    fx.deinit();
    try testing.expectEqual(@as(u32, 1), fx.abandoned_channel_wakes);
    @memset(std.mem.asBytes(&services), 0xAA);
    return .{ .snapshot = snapshot, .producer = producer };
}

test "a rebind publishes a fresh snapshot and an abandoned generation's snapshot stays intact for stale calls" {
    // The one supported rebind shape: `bindServices` after `deinit`
    // cleared the first binding (mid-life binds are first-bind-sticks
    // no-ops). Immutable-per-bind is the whole race story — the rebind
    // never writes the old snapshot, it atomically swaps in a fresh
    // allocation, so there is no tear window: a stale call that
    // captured the old pointer before the swap keeps reading the OLD
    // table intact, for as long as it can exist — which, past the
    // abandon that generation ended in, is forever — while new posts
    // route through the new one. Both snapshots stay valid side by
    // side while the second generation's channels are live, and the
    // final CLEAN teardown frees exactly the generation it quiesced.
    var tracker: TrackingChannelStorageAllocator = .{};
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    fx.channel_wake_join_deadline_ms = 50;
    RebindWakes.reset();
    defer RebindWakes.reset();
    RebindWakes.loop_thread = std.Thread.getCurrentId();
    fx.channel_storage_allocator = tracker.allocator();

    var post_result: PostResult = .closed;
    const first = try bindFirstGeneration(&fx, &post_result);
    var joined = false;
    errdefer RebindWakes.release.store(true, .seq_cst);
    defer if (!joined) first.producer.join();
    // The abandoned generation's snapshot was NOT freed at its own
    // teardown: the stale call parked inside the first hook still
    // holds it.
    try testing.expect(!tracker.didFree(first.snapshot));

    // REBIND: a second generation against the same Effects value, its
    // services owned by this (still living) frame. The bind itself
    // publishes nothing (no channel is open); the snapshot
    // materializes at the generation's first live open.
    var second_services: platform_mod.PlatformServices = .{ .wake_fn = RebindWakes.second };
    fx.bindServices(&second_services);
    try testing.expectEqual(@as(?*const platform_mod.PlatformServices, null), fx.wake_services.load(.seq_cst));
    const handle = fx.openChannel(.{ .key = 68, .on_event = DirectFx.channelMsg(.event) });
    const second_snapshot = fx.wake_services.load(.seq_cst) orelse return error.TestExpectedSnapshot;
    try testing.expect(second_snapshot != first.snapshot);
    try testing.expect(second_snapshot != &second_services);

    // BOTH snapshots valid side by side: the swap wrote nothing into
    // the first generation — the stale call's pointer reads the FIRST
    // table intact (its own hook, not the poison pattern its dead
    // owner left and not the second generation's hook) — while the
    // live channel's posts route through the second.
    try testing.expect(first.snapshot.wake_fn == RebindWakes.first);
    try testing.expect(second_snapshot.wake_fn == RebindWakes.second);
    try testing.expectEqual(PostResult.accepted, handle.post("second generation"));
    try testing.expect(RebindWakes.second_count.load(.seq_cst) >= 1);
    _ = try expectData(&fx, 68, "second generation");

    // Release the parked call: it finishes against the process-lived
    // pieces of its own generation, and its post answers honestly.
    RebindWakes.release.store(true, .seq_cst);
    first.producer.join();
    joined = true;
    try testing.expectEqual(PostResult.accepted, post_result);

    // The final teardown is CLEAN (no new abandon), so it frees
    // exactly the generation it quiesced: the second snapshot — never
    // the abandoned first, whose immortality outlives every later
    // lifetime of this Effects.
    fx.deinit();
    try testing.expectEqual(@as(u32, 1), fx.abandoned_channel_wakes);
    try testing.expect(tracker.didFree(second_snapshot));
    try testing.expect(!tracker.didFree(first.snapshot));
    try testing.expect(first.snapshot.wake_fn == RebindWakes.first);
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
    /// Rolling order-sensitive digest of every REJECTED key — the
    /// mixed-authority test's order pin: engine-staged and
    /// caller-staged (`stageLoopMsg`) rejections must deliver in
    /// staging order, and a replay that reorders them diverges here.
    rejected_key_digest: u64 = 0,
    last_line: [48]u8 = @splat(' '),
    last_line_len: usize = 0,

    fn record(model: *ChannelSessionModel, event: effects_mod.EffectChannelEvent) void {
        switch (event.kind) {
            .data => model.data_events += 1,
            .closed => model.closed_events += 1,
            .rejected => {
                model.rejected_events += 1;
                model.rejected_key_digest = std.hash.Wyhash.hash(model.rejected_key_digest, std.mem.asBytes(&event.key));
            },
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
    /// One dispatch mixing both rejection authorities: a caller-staged
    /// rejection (`stageLoopMsg`, the TS bridge's synchronous-refusal
    /// seam), an engine-staged rejection (a duplicate open the engine
    /// refuses loop-side), and a second caller-staged one — three
    /// refusals whose delivery must hold staging order across layers.
    open_mixed,
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
        // Both rejection authorities in one dispatch, interleaved:
        // caller-staged (77), engine-staged (the dup of 41),
        // caller-staged (88). All three stamp the shared pending seq
        // at refusal time, so delivery — and the model's rejected-key
        // digest — pins 77, 41, 88 on record and replay alike. The
        // caller-staged Msgs are never journaled (`stageLoopMsg`'s
        // regenerating contract); the engine's dup rejection journals
        // marked regenerable and is skipped at replay.
        .open_mixed => {
            fx.stageLoopMsg(.{ .event = .{ .key = 77, .kind = .rejected } });
            _ = fx.openChannel(.{
                .key = session_channel_key,
                .on_event = ChannelSessionApp.Effects.channelMsg(.event),
            });
            fx.stageLoopMsg(.{ .event = .{ .key = 88, .kind = .rejected } });
        },
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
    if (std.mem.eql(u8, name, "channel.open-mixed")) return .open_mixed;
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

/// Record the mixed-authority rejection session: one live channel, one
/// accepted post, then one dispatch that interleaves caller-staged
/// rejections (`stageLoopMsg`) around an engine-staged one, and the
/// close terminal.
fn recordMixedRejectionSession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedChannelSession {
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
    try testing.expectEqual(PostResult.accepted, handle.post("reading 1: 42 units"));
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.data_events);

    // The mixed dispatch: three rejections, two authorities, one
    // staging order (77 caller, 41 engine, 88 caller).
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.open-mixed", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 3), app_state.model.rejected_events);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.close", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.closed_events);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "mixed caller- and engine-staged rejections deliver in staging order and replay identically with neither journaled as executor truth" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordMixedRejectionSession(gpa, buffer);
    // The order pin: rejected keys hashed in delivery order must be
    // exactly the staging order 77 (caller), 41 (engine), 88 (caller).
    var expected_digest: u64 = 0;
    for ([_]u64{ 77, session_channel_key, 88 }) |key| {
        expected_digest = std.hash.Wyhash.hash(expected_digest, std.mem.asBytes(&key));
    }
    try testing.expectEqual(expected_digest, recorded.model.rejected_key_digest);

    // Replay into a fresh app: the journal is the whole world.
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
    // The journal carries NEITHER rejection authority as executor
    // truth: the one data event and the closed terminal FEED; the
    // engine's dup rejection journals marked regenerable and is
    // SKIPPED (the replayed open re-derives it); the two caller-staged
    // rejections were never journaled at all — nothing to feed,
    // nothing to skip, regenerated by the replayed dispatch itself.
    try testing.expectEqual(@as(u64, 2), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    // The identical model INCLUDES the rejected-key digest: the
    // replayed Msg order matches the recorded order across both
    // authorities.
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
    try testing.expect(app_state.effects.channelHandle(session_channel_key) == null);
}

// ------------------- replay acceptance: the open-and-spawn pattern
//
// The channel-monitor example's documented shape: ONE update handler
// both opens the channel and spawns the worker thread that posts into
// it. A replayed session re-executes that update, and BOTH producer
// disciplines must replay the identical stream from one recording:
// the example's `handle.live()` gate skips the spawn entirely (the
// parked handle answers false — replay fully offline), and an
// unconditional launch really starts but exits on its FIRST post
// against the inert handle. The fed journal events are the only event
// stream either way; a live re-run source would interleave with them
// and diverge the fingerprint.

const monitor_channel_key: u64 = 61;

var monitor_thread: ?std.Thread = null;
var monitor_posts_made: u32 = 0;
var monitor_first_post_closed: bool = false;
var monitor_spawns: u32 = 0;
/// The producer discipline under test: true mirrors the example's
/// `live()` gate; false is the unconditional launcher the inert
/// handle must stop at its first post.
var monitor_consults_live = true;

/// The worker the update handler spawns — the example's sampling loop,
/// bounded at three samples so record-side staging is deterministic.
/// A closed answer ends the loop immediately (the well-behaved
/// producer contract).
const MonitorWorker = struct {
    fn run(handle: effects_mod.ChannelHandle) void {
        var buffer: [32]u8 = undefined;
        var index: u32 = 0;
        while (index < 3) : (index += 1) {
            const line = std.fmt.bufPrint(&buffer, "sample {d}", .{index}) catch unreachable;
            const result = handle.post(line);
            monitor_posts_made += 1;
            switch (result) {
                // Drops are transient: skip the sample, keep sampling.
                .accepted, .dropped_full, .dropped_oversized => {},
                // The occupancy is over: exit the loop for good.
                .closed => {
                    monitor_first_post_closed = (index == 0);
                    return;
                },
            }
        }
    }
};

fn monitorUpdate(model: *ChannelSessionModel, msg: ChannelSessionMsg, fx: *ChannelSessionApp.Effects) void {
    switch (msg) {
        // The open-and-spawn pattern under test: BOTH sides re-run this
        // dispatch. The join inside the handler is the test's
        // determinism pin (the example joins later, at close) — it
        // pins exactly when the worker's posts have all been answered,
        // on the recording and the replay alike.
        .open => {
            const handle = fx.openChannel(.{
                .key = monitor_channel_key,
                .on_event = ChannelSessionApp.Effects.channelMsg(.event),
            });
            // The example's launch discipline (when consulted): spawn
            // only for a live handle. The model never reads `live()`,
            // so the Msg stream — and the model — stay identical
            // across both disciplines and both sides of the journal.
            if (!monitor_consults_live or handle.live()) {
                monitor_spawns += 1;
                monitor_thread = std.Thread.spawn(.{}, MonitorWorker.run, .{handle}) catch null;
                if (monitor_thread) |thread| {
                    thread.join();
                    monitor_thread = null;
                }
            }
        },
        .open_dup => _ = fx.openChannel(.{
            .key = monitor_channel_key,
            .on_event = ChannelSessionApp.Effects.channelMsg(.event),
        }),
        // The session-app msg set is shared; the monitor session never
        // dispatches the mixed-authority probe.
        .open_mixed => {},
        .close => fx.closeChannel(monitor_channel_key),
        .event => |event| model.record(event),
    }
}

fn monitorCommand(name: []const u8) ?ChannelSessionMsg {
    if (std.mem.eql(u8, name, "monitor.open")) return .open;
    if (std.mem.eql(u8, name, "monitor.close")) return .close;
    return null;
}

fn monitorOptions() ChannelSessionApp.Options {
    return .{
        .name = "channel-monitor-session",
        .scene = channel_session_scene,
        .canvas_label = channel_canvas_label,
        .update_fx = monitorUpdate,
        .view = channelSessionView,
        .on_command = monitorCommand,
    };
}

fn recordMonitorSession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedChannelSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "channel-monitor-session", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, monitorOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = channel_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Open-and-spawn: the worker posts its three samples and exits
    // (joined inside the dispatch), then the drain delivers them.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "monitor.open", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 3), app_state.model.data_events);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "monitor.close", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.closed_events);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

fn resetMonitorGlobals() void {
    monitor_thread = null;
    monitor_posts_made = 0;
    monitor_first_post_closed = false;
    monitor_spawns = 0;
}

test "replaying an open-and-spawn session with the live() gate never creates the sampler thread" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    resetMonitorGlobals();
    monitor_consults_live = true;
    defer monitor_consults_live = true;
    const recorded = try recordMonitorSession(gpa, buffer);
    try testing.expectEqual(@as(u32, 3), recorded.model.data_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.closed_events);
    // The recording side is live: `live()` answered true, the worker
    // spawned and posted its three samples.
    try testing.expectEqual(@as(u32, 1), monitor_spawns);
    try testing.expectEqual(@as(u32, 3), monitor_posts_made);

    // Replay re-executes the SAME open-and-spawn update, but the
    // example's `live()` gate sees the parked handle answer false: the
    // sampler thread is NEVER created — no spawn, no pre-post work,
    // replay fully offline — and the fed events replay the recorded
    // stream byte-identical.
    resetMonitorGlobals();
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, monitorOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try testing.expectEqual(@as(u32, 0), monitor_spawns);
    try testing.expectEqual(@as(u32, 0), monitor_posts_made);
    try testing.expect(monitor_thread == null);
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // Three fed data events plus the fed closed terminal — and NOTHING
    // else: the never-launched worker contributed no events and no
    // journal records.
    try testing.expectEqual(@as(u64, 4), report.effects_fed);
    try testing.expectEqual(@as(u64, 0), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
    // The fed closed terminal retired the parked occupancy.
    try testing.expect(app_state.effects.channelHandle(monitor_channel_key) == null);
}

test "replaying the same session with an unconditional launcher stops the re-run worker at its first post" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    resetMonitorGlobals();
    monitor_consults_live = true;
    defer monitor_consults_live = true;
    const recorded = try recordMonitorSession(gpa, buffer);
    try testing.expectEqual(@as(u32, 3), monitor_posts_made);

    // The safety net behind the honesty teaching: a producer that
    // launches WITHOUT consulting `live()` really starts under replay
    // — app code is app code — but the parked channel's inert handle
    // answers closed on its first post, the worker exits (joined
    // before the report below), nothing is staged or journaled, and
    // the SAME journal replays the identical stream.
    resetMonitorGlobals();
    monitor_consults_live = false;
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(ChannelSessionApp);
    defer gpa.destroy(app_state);
    app_state.* = ChannelSessionApp.init(std.heap.page_allocator, .{}, monitorOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try testing.expect(monitor_thread == null);
    // The worker spawned and exited on its FIRST post: the inert
    // handle answered closed immediately.
    try testing.expectEqual(@as(u32, 1), monitor_spawns);
    try testing.expectEqual(@as(u32, 1), monitor_posts_made);
    try testing.expect(monitor_first_post_closed);
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    try testing.expectEqual(@as(u64, 4), report.effects_fed);
    try testing.expectEqual(@as(u64, 0), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

// --------------------------------------------- wake back-pressure gate

test "rejected posts never wake the host: the pending-wake count stays flat under a refusal storm" {
    const gpa = testing.allocator;
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;

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

    // Accepted posts wake, COALESCED: the first accepted post latches
    // exactly one host wake and the rest of the burst rides it — one
    // wake drains the whole eligible backlog, so a fill/drain/refill
    // producer can never park a backlog of redundant host-queue
    // entries behind the one drain that answers them all.
    const before_accepted = harness.null_platform.pendingWakeCount();
    try testing.expectEqual(PostResult.accepted, handle.post("kept 1"));
    try testing.expectEqual(before_accepted + 1, harness.null_platform.pendingWakeCount());
    try testing.expectEqual(PostResult.accepted, handle.post("kept 2"));
    try testing.expectEqual(before_accepted + 1, harness.null_platform.pendingWakeCount());

    // The stage is full (max_pending = 2). A refused post stages
    // nothing, so it must NOT wake: the staged entries' own accepted
    // posts already woke the loop, and the drop counters ride the next
    // delivered event with no extra nudge. A producer that keeps going
    // after `.dropped_full` — the documented pattern — must never grow
    // the host loop's queue.
    const before_refused = harness.null_platform.pendingWakeCount();
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        try testing.expectEqual(PostResult.dropped_full, handle.post("refused"));
    }
    const oversized = [_]u8{'x'} ** (effects_mod.max_effect_channel_bytes + 1);
    try testing.expectEqual(PostResult.dropped_oversized, handle.post(&oversized));
    try testing.expectEqual(before_refused, harness.null_platform.pendingWakeCount());

    // Drain: the staged entries deliver and the first delivered event
    // carries every counted drop.
    while (harness.null_platform.takeWake()) |event| {
        try harness.runtime.dispatchPlatformEvent(app, event);
    }
    try testing.expectEqual(@as(u32, 2), app_state.model.data_events);
    try testing.expectEqual(@as(u32, 65), app_state.model.dropped_total_last);

    // Delivery latency: the drain unlatched the coalescer, so an
    // accepted post after the idle period wakes immediately — one
    // wake per drain, never fewer (the stall the latch must not
    // introduce) and never a backlog.
    const before_relieved = harness.null_platform.pendingWakeCount();
    try testing.expectEqual(PostResult.accepted, handle.post("kept 3"));
    try testing.expectEqual(before_relieved + 1, harness.null_platform.pendingWakeCount());

    // A post against a closed channel is a pure no-op: nothing staged,
    // nothing counted, no wake.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "channel.close", .window_id = 1 } });
    const before_closed = harness.null_platform.pendingWakeCount();
    try testing.expectEqual(PostResult.closed, handle.post("after close"));
    try testing.expectEqual(before_closed, harness.null_platform.pendingWakeCount());
}

// -------------------- generation width: permanent-closed is absolute

test "channel generations are u64 from the channel-owned counter" {
    // Type pins: the posting handle and the process-lifetime header
    // carry the channel family's u64 generation — never the shared u32
    // effect counter, whose wrap would bound the permanent-`.closed`
    // guarantee at 2^32 occupancies.
    try testing.expectEqual(u64, @FieldType(effects_mod.ChannelHandle, "generation"));
    try testing.expectEqual(u64, @FieldType(effects_mod.ChannelShared, "generation"));

    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The counter is channel-owned and monotonic: seed it past
    // anything a u32 can hold and the next occupancy continues from
    // there — the shared effect counter never touches it.
    fx.channel_generation = @as(u64, std.math.maxInt(u32)) + 41;
    const handle = fx.openChannel(.{ .key = 61, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 42, handle.generation);
    try testing.expectEqual(PostResult.accepted, handle.post("wide"));
    _ = try expectData(&fx, 61, "wide");
    fx.closeChannel(61);
    _ = fx.takeMsg();
}

test "a stale handle stays closed across a u32 wrap's worth of occupancy turnovers" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // First occupancy: the stale handle a long-lived producer thread
    // might still hold centuries of churn later.
    const stale = fx.openChannel(.{ .key = 62, .on_event = DirectFx.channelMsg(.event) });
    fx.closeChannel(62);
    const closed = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectChannelEventKind.closed, closed.event.kind);

    // Simulate 2^32 turnovers of the old u32 counter's worth: seed the
    // channel counter so the reused slot's next generation TRUNCATES
    // to the stale handle's value in u32 arithmetic — exactly the wrap
    // that would have resurrected the stale handle against the reused
    // slot's header.
    fx.channel_generation = stale.generation + (@as(u64, 1) << 32) - 1;
    const fresh = fx.openChannel(.{ .key = 62, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(stale.generation + (@as(u64, 1) << 32), fresh.generation);
    // The u32 collision is real...
    try testing.expectEqual(@as(u32, @truncate(stale.generation)), @as(u32, @truncate(fresh.generation)));
    // ...and harmless at u64: the stale handle still answers `.closed`
    // — nothing staged, nothing counted — while the fresh occupancy
    // posts normally into its own stream.
    try testing.expectEqual(PostResult.closed, stale.post("resurrected?"));
    try testing.expectEqual(PostResult.accepted, fresh.post("fresh stream"));
    const delivered = try expectData(&fx, 62, "fresh stream");
    try testing.expectEqual(@as(u32, 0), delivered.dropped_total);
    fx.closeChannel(62);
    _ = fx.takeMsg();
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

test "a channel .data record stamped with rejected provenance refuses replay as damage" {
    // The recorder stamps `.rejected` provenance only on regenerating
    // admission refusals, whose event kind is always `.rejected`. A
    // `.data` record wearing that stamp would be silently skipped by
    // the regeneration filter — with verification disabled, replay
    // would succeed with a different Msg stream — so the mismatch is
    // damage, refused before the skip decision.
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .payload = "reading 1: 42 units",
        .channel_kind = .data,
        .exit_reason = .rejected,
    });
    try testing.expectError(error.ReplayDamagedRecord, result);
}

test "a channel .closed record stamped with rejected provenance refuses replay as damage" {
    // The `.data` mismatch's terminal twin: a skipped `.closed` would
    // leave the replayed channel parked forever with its key occupied.
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .channel_kind = .closed,
        .exit_reason = .rejected,
    });
    try testing.expectError(error.ReplayDamagedRecord, result);
}

test "a channel record with provenance outside the recorder's range refuses replay as damage" {
    // Channel records journal from exactly two sites, and neither can
    // write any exit reason but `.exited` or `.rejected`; a decoded
    // `.cancelled` (a valid enum member for SPAWN records) on a
    // channel record is hand-editing.
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .payload = "reading 1: 42 units",
        .channel_kind = .data,
        .exit_reason = .cancelled,
    });
    try testing.expectError(error.ReplayDamagedRecord, result);
}

test "an executor-truth channel rejection record still feeds and retires the parked open" {
    // The reverse direction's positive pin: `.rejected` kind with
    // `.exited` provenance is exactly what the recorder writes for an
    // open that could not stage its channel (executor truth) — it must
    // FEED, never refuse and never skip. The damage journal's one
    // `app_start` event opens nothing, so the fed record simply finds
    // no park — the gate letting it THROUGH to the feed (EffectNotFound
    // surfacing as the divergence report, not ReplayDamagedRecord) is
    // the pin.
    const result = replayChannelDamageRecord(.{
        .kind = .channel,
        .key = session_channel_key,
        .channel_kind = .rejected,
        .exit_reason = .exited,
    });
    try testing.expectError(error.ReplayEffectDivergence, result);
}

// ------------------- table capacity: the start-failure reservation

/// Fails exactly the next channel-storage allocation and delegates
/// everything else to the page allocator — `process_allocator`'s
/// backing, which keeps retire/teardown's `process_allocator` frees
/// valid for every allocation that succeeds. The seam
/// (`channel_storage_allocator`) is consulted only by `openChannel`'s
/// posting-header, staging-FIFO, and services-snapshot creates, so
/// failing the next call through it is exactly one open's (or one
/// publication's) start failure — the surgical one-shot the image
/// tests get from their buffer-size-matched wrapper
/// (`ImageBufferFailingAllocator` in the session tests).
const ChannelStorageFailingAllocator = struct {
    backing: std.mem.Allocator = std.heap.page_allocator,
    armed: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *ChannelStorageFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ChannelStorageFailingAllocator = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ChannelStorageFailingAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ChannelStorageFailingAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ChannelStorageFailingAllocator = @ptrCast(@alignCast(ptr));
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }
};

fn expectRejected(fx: *DirectFx, key: u64) !void {
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expect(msg == .event);
    try testing.expectEqual(key, msg.event.key);
    try testing.expectEqual(effects_mod.EffectChannelEventKind.rejected, msg.event.kind);
}

test "an alloc-failed open reserves table capacity until its rejection drains" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    fx.channel_storage_allocator = failing.allocator();

    // Six live occupancies (6 of the 8 slots).
    var index: u64 = 0;
    while (index < 6) : (index += 1) {
        const handle = fx.openChannel(.{ .key = 200 + index, .on_event = DirectFx.channelMsg(.event) });
        try testing.expect(handle.shared != null);
    }

    // The alloc-failed open claims no slot, but its staged
    // executor-truth `.rejected` reserves one slot of capacity —
    // replay parks this open in a REAL slot until the terminal feeds.
    failing.armed = true;
    const failed = fx.openChannel(.{ .key = 300, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(failed.shared == null);
    try testing.expect(!failing.armed);

    // 6 slots + 1 reservation = 7: a different key still fits...
    const seventh = fx.openChannel(.{ .key = 301, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(seventh.shared != null);
    // ...but 7 slots + 1 reservation = 8: the next open answers
    // table-full while the reservation's terminal is pending.
    const overflow = fx.openChannel(.{ .key = 302, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(overflow.shared == null);

    // Deliver the alloc-failed open's terminal: the reservation drains
    // with it...
    try expectRejected(&fx, 300);
    // ...and the key that just answered table-full claims the real 8th
    // slot — even though its own table-full refusal is still staged
    // (regenerating refusals never reserve).
    const eighth = fx.openChannel(.{ .key = 302, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(eighth.shared != null);
    // The earlier table-full refusal's terminal still delivers exactly
    // once.
    try expectRejected(&fx, 302);
}

test "an open that cannot allocate the services snapshot refuses as executor truth" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    fx.channel_storage_allocator = failing.allocator();
    const null_platform = try testing.allocator.create(platform_mod.NullPlatform);
    defer testing.allocator.destroy(null_platform);
    null_platform.* = platform_mod.NullPlatform.init(.{});
    const host_platform = null_platform.platform();
    fx.bindServices(&host_platform.services);

    // The snapshot allocation fails at the open's pre-flight: NO
    // handle exists — a live channel here could accept posts that
    // never wake the host (producer wakes stay disarmed until another
    // publication), so the open refuses up front, the same
    // executor-truth class as a header/staging start failure.
    failing.armed = true;
    const dead = fx.openChannel(.{ .key = 90, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(dead.shared == null);
    try testing.expect(!failing.armed);
    try testing.expectEqual(PostResult.closed, dead.post("never lands"));
    try expectRejected(&fx, 90);

    // Storage recovered: the key retired with the rejection, the next
    // open publishes the snapshot and its posts wake the host.
    const handle = fx.openChannel(.{ .key = 90, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(handle.shared != null);
    try testing.expect(fx.wake_services.load(.seq_cst) != null);
    try testing.expectEqual(PostResult.accepted, handle.post("healed"));
    try testing.expect(null_platform.wake_count.load(.acquire) >= 1);
    _ = try expectData(&fx, 90, "healed");
    fx.closeChannel(90);
    while (fx.takeMsg()) |_| {}
}

test "a failed bind-site snapshot publication heals at the next pass boundary" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    fx.channel_storage_allocator = failing.allocator();
    const null_platform = try testing.allocator.create(platform_mod.NullPlatform);
    defer testing.allocator.destroy(null_platform);
    null_platform.* = platform_mod.NullPlatform.init(.{});
    const host_platform = null_platform.platform();

    // Open BEFORE bind: the one shape that can be live through a
    // failed publication (the open-site pre-flight is a no-op while no
    // services are bound, and `openChannel` cannot refuse what was
    // committed before the bind existed).
    const handle = fx.openChannel(.{ .key = 91, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(handle.shared != null);

    // The bind-time publication fails: producer wakes stay disarmed...
    failing.armed = true;
    fx.bindServices(&host_platform.services);
    try testing.expect(fx.wake_services.load(.seq_cst) == null);
    // ...so a post in that window is accepted but latches no host wake.
    try testing.expectEqual(PostResult.accepted, handle.post("stranded?"));
    try testing.expectEqual(@as(usize, 0), null_platform.wake_count.load(.acquire));

    // The next pass boundary heals: the retried publication lands and
    // its Dekker sweep un-strands the accepted post with a host wake.
    var boundary = fx.drainBoundary();
    try testing.expect(fx.wake_services.load(.seq_cst) != null);
    try testing.expect(null_platform.wake_count.load(.acquire) >= 1);
    const msg = fx.takeMsgWithin(&boundary) orelse return error.TestExpectedMsg;
    try testing.expectEqualStrings("stranded?", msg.event.bytes);
    fx.closeChannel(91);
    while (fx.takeMsg()) |_| {}
}

test "regenerating channel refusals do not reserve table capacity" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Seven live occupancies.
    var index: u64 = 0;
    while (index < 7) : (index += 1) {
        const handle = fx.openChannel(.{ .key = 400 + index, .on_event = DirectFx.channelMsg(.event) });
        try testing.expect(handle.shared != null);
    }

    // Three duplicate-key refusals stage regenerating `.rejected`
    // terminals. They must NOT reserve: replay re-derives each from
    // the parked occupancy with no slot held on either side, so the
    // 8th slot stays claimable while all three are pending.
    index = 0;
    while (index < 3) : (index += 1) {
        const dup = fx.openChannel(.{ .key = 400, .on_event = DirectFx.channelMsg(.event) });
        try testing.expect(dup.shared == null);
    }
    const eighth = fx.openChannel(.{ .key = 500, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(eighth.shared != null);

    // The table is honestly full: N table-full refusals (regenerating
    // too — replay's parked table re-derives them) while full...
    index = 0;
    while (index < 3) : (index += 1) {
        const over = fx.openChannel(.{ .key = 600 + index, .on_event = DirectFx.channelMsg(.event) });
        try testing.expect(over.shared == null);
    }

    // ...leave the accounting unchanged: close ONE occupancy, drain
    // every staged refusal and the closed terminal, and exactly one
    // slot's worth of capacity is back — not one slot minus phantom
    // reservations.
    fx.closeChannel(400);
    var rejected_count: u32 = 0;
    var closed_count: u32 = 0;
    while (fx.takeMsg()) |msg| {
        switch (msg.event.kind) {
            .rejected => rejected_count += 1,
            .closed => closed_count += 1,
            .data => return error.TestUnexpectedData,
        }
    }
    try testing.expectEqual(@as(u32, 6), rejected_count);
    try testing.expectEqual(@as(u32, 1), closed_count);
    const refill = fx.openChannel(.{ .key = 700, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(refill.shared != null);
    const full_again = fx.openChannel(.{ .key = 701, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(full_again.shared == null);
    _ = fx.takeMsg();
}

test "teardown with a reservation pending closes cleanly and discards the stage" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    fx.channel_storage_allocator = failing.allocator();

    const live = fx.openChannel(.{ .key = 30, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(live.shared != null);
    failing.armed = true;
    const failed = fx.openChannel(.{ .key = 31, .on_event = DirectFx.channelMsg(.event) });
    try testing.expect(failed.shared == null);
    try testing.expect(fx.hasPending());

    // Teardown with the reservation's terminal still staged: the sweep
    // closes the live channel and discards the stage — reservation
    // aboard — with nothing left to deliver or leak.
    fx.deinit();
    try testing.expect(!fx.hasPending());
    try testing.expectEqual(PostResult.closed, live.post("after teardown"));
    // Idempotent repeat (the teardown ordering contract).
    fx.deinit();
}

// The record/replay boundary: live capacity accounting must agree with
// replay's parked table at every position. Replay parks EVERY open in
// a real slot until its journaled terminal feeds — including an
// alloc-failed open, whose replay twin never touches the allocator —
// so a live table that forgets the alloc-failed open's reservation
// accepts a 9th open replay answers with a table-full reject, and the
// 9th open's journaled executor-truth terminals have no parked request
// to feed (`ReplayEffectDivergence`).

const capacity_key_base: u64 = 70;

const CapacityMsg = union(enum) {
    open: u64,
    close: u64,
    event: effects_mod.EffectChannelEvent,
};

const CapacityApp = ui_app_mod.UiApp(ChannelSessionModel, CapacityMsg);

fn capacityUpdate(model: *ChannelSessionModel, msg: CapacityMsg, fx: *CapacityApp.Effects) void {
    switch (msg) {
        .open => |key| _ = fx.openChannel(.{ .key = key, .on_event = CapacityApp.Effects.channelMsg(.event) }),
        .close => |key| fx.closeChannel(key),
        .event => |event| model.record(event),
    }
}

fn capacityView(ui: *CapacityApp.Ui, model: *const ChannelSessionModel) CapacityApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} data, {d} closed, {d} rejected", .{ model.data_events, model.closed_events, model.rejected_events })),
        ui.text(.{}, ui.fmt("digest {x} last {s}", .{ model.payload_digest, model.lastLine() })),
    });
}

/// "cap.open-N" / "cap.close-N" for a single digit N: key
/// `capacity_key_base + N`.
fn capacityCommand(name: []const u8) ?CapacityMsg {
    const open_prefix = "cap.open-";
    const close_prefix = "cap.close-";
    if (std.mem.startsWith(u8, name, open_prefix) and name.len == open_prefix.len + 1) {
        return .{ .open = capacity_key_base + (name[open_prefix.len] - '0') };
    }
    if (std.mem.startsWith(u8, name, close_prefix) and name.len == close_prefix.len + 1) {
        return .{ .close = capacity_key_base + (name[close_prefix.len] - '0') };
    }
    return null;
}

fn capacityOptions() CapacityApp.Options {
    return .{
        .name = "channel-capacity-demo",
        .scene = channel_session_scene,
        .canvas_label = channel_canvas_label,
        .update_fx = capacityUpdate,
        .view = capacityView,
        .on_command = capacityCommand,
    };
}

fn capacityCommandName(buffer: []u8, comptime verb: []const u8, index: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "cap." ++ verb ++ "-{d}", .{index}) catch unreachable;
}

/// Record the table-limit boundary reference session: seven live opens,
/// one alloc-failed open (a staged executor-truth rejection reserving
/// the 8th slot), and — inside the staged window, before any drain —
/// the open that would be the table's 9th counting the reservation. It
/// must answer table-full LIVE, because replay's parked table is full
/// at that position: seven parked opens plus the parked alloc-failed
/// one.
fn recordCapacitySession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedChannelSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "channel-capacity-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(CapacityApp);
    defer gpa.destroy(app_state);
    app_state.* = CapacityApp.init(std.heap.page_allocator, .{}, capacityOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    app_state.effects.channel_storage_allocator = failing.allocator();
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = channel_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    var name_buffer: [16]u8 = undefined;
    var index: u64 = 0;
    while (index < 7) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = capacityCommandName(&name_buffer, "open", index), .window_id = 1 } });
    }
    // The alloc-failed open: one staged executor-truth `.rejected`.
    failing.armed = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = capacityCommandName(&name_buffer, "open", 7), .window_id = 1 } });
    try testing.expect(!failing.armed);
    // Inside the staged window — no wake between — the would-be 9th.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = capacityCommandName(&name_buffer, "open", 8), .window_id = 1 } });
    // Closing the refused key is a no-op on both sides. (Under the
    // pre-reservation accounting the 9th open claimed a real slot
    // here, this close staged a `.closed` terminal, and the journaled
    // executor-truth terminals had no replay twin to feed.)
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = capacityCommandName(&name_buffer, "close", 8), .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    // Close the seven live channels: seven executor-truth `.closed`
    // terminals that feed at replay.
    index = 0;
    while (index < 7) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = capacityCommandName(&name_buffer, "close", index), .window_id = 1 } });
    }
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

// ---------------- replay ordering: mixed rejection provenance
//
// One staged window can hold BOTH rejection provenances: an
// alloc-failed open's executor-truth `.rejected` (journals `.exited`
// and FEEDS at replay) followed by a regenerating refusal (occupied
// key, full table — re-derived at the replayed dispatch). Live
// delivers them through the pending stage's FIFO in dispatch order.
// Replay must deliver the same order even though the executor-truth
// terminal arrives through the feed, not the re-run dispatch — the
// parked open reserves its ordering slot at dispatch and the fed
// refusal reclaims it.

const mixed_key_base: u64 = 810;
const mixed_fail_key: u64 = mixed_key_base + 7;
const mixed_full_key: u64 = mixed_key_base + 8;
const mixed_chain_key: u64 = mixed_key_base + 9;

/// When set, a delivered `.rejected` for `mixed_full_key` opens the
/// chain channel from inside the handler — the state-divergence probe:
/// live, the executor-truth rejection has already drained (its
/// reservation released, and under replay its parked slot retired)
/// when this handler runs, so the chain open is ACCEPTED on both
/// sides; a replay that inverts the two rejections runs this handler
/// while the alloc-failed open still parks a slot, and the chain open
/// answers table-full instead — a Msg stream and a journal the
/// recording never produced.
var mixed_chain_enabled = false;

const MixedRejectionModel = struct {
    data_events: u32 = 0,
    closed_events: u32 = 0,
    rejected_events: u32 = 0,
    /// Order-sensitive digest folding every delivered event's key and
    /// kind: two rejections delivered in swapped order diverge here
    /// even though every per-kind count agrees.
    order_digest: u64 = 0,

    fn record(model: *MixedRejectionModel, event: effects_mod.EffectChannelEvent) void {
        switch (event.kind) {
            .data => model.data_events += 1,
            .closed => model.closed_events += 1,
            .rejected => model.rejected_events += 1,
        }
        var fold: [9]u8 = undefined;
        std.mem.writeInt(u64, fold[0..8], event.key, .little);
        fold[8] = @intFromEnum(event.kind);
        model.order_digest = std.hash.Wyhash.hash(model.order_digest, &fold);
    }
};

const MixedMsg = union(enum) {
    open: u64,
    close: u64,
    event: effects_mod.EffectChannelEvent,
};

const MixedApp = ui_app_mod.UiApp(MixedRejectionModel, MixedMsg);

fn mixedUpdate(model: *MixedRejectionModel, msg: MixedMsg, fx: *MixedApp.Effects) void {
    switch (msg) {
        .open => |key| _ = fx.openChannel(.{ .key = key, .on_event = MixedApp.Effects.channelMsg(.event) }),
        .close => |key| fx.closeChannel(key),
        .event => |event| {
            model.record(event);
            if (mixed_chain_enabled and event.kind == .rejected and event.key == mixed_full_key) {
                _ = fx.openChannel(.{ .key = mixed_chain_key, .on_event = MixedApp.Effects.channelMsg(.event) });
            }
        },
    }
}

fn mixedView(ui: *MixedApp.Ui, model: *const MixedRejectionModel) MixedApp.Ui.Node {
    // The order digest rides the semantic tree so the fingerprint
    // checkpoints pin DELIVERY ORDER, not just per-kind counts.
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} data, {d} closed, {d} rejected", .{ model.data_events, model.closed_events, model.rejected_events })),
        ui.text(.{}, ui.fmt("order {x}", .{model.order_digest})),
    });
}

/// "mixr.open-N" / "mixr.close-N" for a single digit N: key
/// `mixed_key_base + N`.
fn mixedCommand(name: []const u8) ?MixedMsg {
    const open_prefix = "mixr.open-";
    const close_prefix = "mixr.close-";
    if (std.mem.startsWith(u8, name, open_prefix) and name.len == open_prefix.len + 1) {
        return .{ .open = mixed_key_base + (name[open_prefix.len] - '0') };
    }
    if (std.mem.startsWith(u8, name, close_prefix) and name.len == close_prefix.len + 1) {
        return .{ .close = mixed_key_base + (name[close_prefix.len] - '0') };
    }
    return null;
}

fn mixedOptions() MixedApp.Options {
    return .{
        .name = "channel-mixed-rejections",
        .scene = channel_session_scene,
        .canvas_label = channel_canvas_label,
        .update_fx = mixedUpdate,
        .view = mixedView,
        .on_command = mixedCommand,
    };
}

const RecordedMixedSession = struct {
    model: MixedRejectionModel,
    fingerprint: u64,
};

fn mixedHarnessStart(harness: *core.TestHarness(), app: core.App) !void {
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = channel_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
}

/// Record the mixed-provenance reference session: seven live opens,
/// one alloc-failed open (executor truth, feeds at replay), and —
/// inside the same staged window — one table-full open (regenerating,
/// re-derived at replay). Live delivers the two rejections in
/// dispatch order: alloc-failed first, table-full second.
fn recordMixedSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, chain: bool) !RecordedMixedSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "channel-mixed-rejections", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(MixedApp);
    defer gpa.destroy(app_state);
    app_state.* = MixedApp.init(std.heap.page_allocator, .{}, mixedOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    app_state.effects.channel_storage_allocator = failing.allocator();
    const app = app_state.app();

    try mixedHarnessStart(harness, app);

    var name_buffer: [16]u8 = undefined;
    var index: u64 = 0;
    while (index < 7) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", index), .window_id = 1 } });
    }
    // The alloc-failed open: executor truth, staged at dispatch.
    failing.armed = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", 7), .window_id = 1 } });
    try testing.expect(!failing.armed);
    // The table-full open, in the same staged window: 7 slots + 1
    // reservation exhaust the table, so this refusal is regenerating.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", 8), .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 2), app_state.model.rejected_events);

    // Close the live channels (and the chain channel when the second
    // rejection's handler opened it).
    index = 0;
    while (index < 7) : (index += 1) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "close", index), .window_id = 1 } });
    }
    if (chain) {
        try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "close", 9), .window_id = 1 } });
    }
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

fn mixedCommandName(buffer: []u8, comptime verb: []const u8, index: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "mixr." ++ verb ++ "-{d}", .{index}) catch unreachable;
}

fn replayMixedSession(gpa: std.mem.Allocator, buffer: *JournalBuffer, app_state: *MixedApp, harness: *core.TestHarness()) !session_replay.ReplayReport {
    harness.null_platform.gpu_surfaces = true;
    app_state.* = MixedApp.init(std.heap.page_allocator, .{}, mixedOptions());
    _ = gpa;
    return session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
}

test "mixed executor-truth and regenerating channel rejections replay in live delivery order" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    mixed_chain_enabled = false;

    const recorded = try recordMixedSession(gpa, buffer, false);
    // Live delivery order pinned independently: the alloc-failed open's
    // rejection first (staged at its dispatch), the table-full open's
    // second — the pending stage's FIFO.
    var expected: MixedRejectionModel = .{};
    expected.record(.{ .key = mixed_fail_key, .kind = .rejected });
    expected.record(.{ .key = mixed_full_key, .kind = .rejected });
    var close_index: u64 = 0;
    while (close_index < 7) : (close_index += 1) {
        expected.record(.{ .key = mixed_key_base + close_index, .kind = .closed });
    }
    try testing.expectEqual(expected.order_digest, recorded.model.order_digest);
    try testing.expectEqual(@as(u32, 7), recorded.model.closed_events);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    const app_state = try gpa.create(MixedApp);
    defer gpa.destroy(app_state);
    const report = try replayMixedSession(gpa, buffer, app_state, harness);
    defer app_state.deinit();
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // The alloc-failed rejection and seven closed terminals feed; the
    // table-full rejection regenerates.
    try testing.expectEqual(@as(u64, 8), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

/// The valid reversed mixed ordering. A table-full refusal cannot
/// precede an executor-truth one inside a single staged window — the
/// table's idle-minus-reservations margin only ever shrinks as the
/// window's opens claim slots and executor-truth refusals add
/// reservations, and an alloc-fail needs the margin positive while
/// table-full needs it non-positive — so the regenerating-first shape
/// uses the OTHER regenerating refusal, the duplicate key.
fn recordReversedMixedSession(gpa: std.mem.Allocator, buffer: *JournalBuffer) !RecordedMixedSession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "channel-mixed-rejections", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(MixedApp);
    defer gpa.destroy(app_state);
    app_state.* = MixedApp.init(std.heap.page_allocator, .{}, mixedOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    var failing: ChannelStorageFailingAllocator = .{};
    app_state.effects.channel_storage_allocator = failing.allocator();
    const app = app_state.app();

    try mixedHarnessStart(harness, app);

    var name_buffer: [16]u8 = undefined;
    // One live open, then its duplicate: the regenerating refusal
    // stages FIRST.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", 0), .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", 0), .window_id = 1 } });
    // Then the alloc-failed open: executor truth stages SECOND.
    failing.armed = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "open", 7), .window_id = 1 } });
    try testing.expect(!failing.armed);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 2), app_state.model.rejected_events);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = mixedCommandName(&name_buffer, "close", 0), .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a regenerating rejection recorded ahead of an executor-truth one keeps its lead at replay" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    mixed_chain_enabled = false;

    const recorded = try recordReversedMixedSession(gpa, buffer);
    var expected: MixedRejectionModel = .{};
    expected.record(.{ .key = mixed_key_base, .kind = .rejected });
    expected.record(.{ .key = mixed_fail_key, .kind = .rejected });
    expected.record(.{ .key = mixed_key_base, .kind = .closed });
    try testing.expectEqual(expected.order_digest, recorded.model.order_digest);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    const app_state = try gpa.create(MixedApp);
    defer gpa.destroy(app_state);
    const report = try replayMixedSession(gpa, buffer, app_state, harness);
    defer app_state.deinit();
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // The alloc-failed rejection and one closed terminal feed; the
    // duplicate-key rejection regenerates.
    try testing.expectEqual(@as(u64, 2), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

test "a mixed session whose second rejection handler opens a third channel replays without table divergence" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    mixed_chain_enabled = true;
    defer mixed_chain_enabled = false;

    // Live: the table-full rejection's handler runs AFTER the
    // alloc-failed rejection drained (its reservation released), so the
    // chain open claims the freed capacity and is accepted.
    const recorded = try recordMixedSession(gpa, buffer, true);
    try testing.expectEqual(@as(u32, 2), recorded.model.rejected_events);
    try testing.expectEqual(@as(u32, 8), recorded.model.closed_events);

    // Replay must run the same handler against the same table state:
    // the fed executor-truth rejection retires its parked slot BEFORE
    // the regenerated table-full rejection delivers, so the chain open
    // parks in the freed slot and its journaled `.closed` has a twin
    // to feed. An inverted replay opens the chain channel against a
    // full parked table and diverges.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    const app_state = try gpa.create(MixedApp);
    defer gpa.destroy(app_state);
    const report = try replayMixedSession(gpa, buffer, app_state, harness);
    defer app_state.deinit();
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // The alloc-failed rejection and eight closed terminals feed; the
    // table-full rejection regenerates.
    try testing.expectEqual(@as(u64, 9), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

test "live table capacity counts the alloc-failed open's reservation so replay agrees at the boundary" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    const recorded = try recordCapacitySession(gpa, buffer);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(CapacityApp);
    defer gpa.destroy(app_state);
    app_state.* = CapacityApp.init(std.heap.page_allocator, .{}, capacityOptions());
    defer app_state.deinit();

    // Replay must agree at every position: the alloc-failed open's
    // `.rejected` feeds and retires its parked slot, the 9th open's
    // table-full refusal regenerates against the parked table, and the
    // seven `.closed` terminals feed.
    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    try testing.expectEqual(@as(u64, 8), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());

    // The recorded shape itself: the alloc-failed open's rejection and
    // the boundary open's LIVE table-full rejection, seven closes, no
    // data — the 9th never opened on either side.
    try testing.expectEqual(@as(u32, 2), recorded.model.rejected_events);
    try testing.expectEqual(@as(u32, 7), recorded.model.closed_events);
    try testing.expectEqual(@as(u32, 0), recorded.model.data_events);
}

// ------------------------------------------------ live-feed restriction

test "feeding a terminal into a live channel answers ChannelLiveFeed instead of racing the producer" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Pre-restriction this interleaving destroyed a staged post and
    // stranded its pending count forever: feed a terminal into the
    // LIVE channel, land an accepted post AFTER the drain snapshot but
    // BEFORE the queued terminal processes — the pass skips the post
    // (stamped past the boundary), the terminal's delivery retires the
    // slot and destroys the staging FIFO with the post inside, and
    // `hasPending` reads true forever. The feed seam now refuses the
    // live target outright.
    const handle = fx.openChannel(.{ .key = 23, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectError(error.ChannelLiveFeed, fx.feedChannelEvent(23, .closed, "", 0, 0));
    try testing.expectError(error.ChannelLiveFeed, fx.feedChannelEvent(23, .rejected, "", 0, 0));

    // The occupancy is untouched by the refusal: posts still land and
    // the ordinary lifecycle completes with an honest pending count.
    try testing.expectEqual(PostResult.accepted, handle.post("still live"));
    _ = try expectData(&fx, 23, "still live");

    // A `.closing` occupancy is equally live — its armed close marker
    // is counted, so a fed terminal would strand that count too.
    try testing.expectEqual(PostResult.accepted, handle.post("flush me"));
    fx.closeChannel(23);
    try testing.expectError(error.ChannelLiveFeed, fx.feedChannelEvent(23, .closed, "", 0, 0));
    while (fx.takeMsg()) |_| {}
    try testing.expect(!fx.hasPending());
}

test "teardown with staged entries reconciles the pending count: hasPending never permanently lies" {
    var fx = DirectFx.init(testing.allocator);
    fx.executor = .fake;

    const handle = fx.openChannel(.{ .key = 29, .on_event = DirectFx.channelMsg(.event) });
    try testing.expectEqual(PostResult.accepted, handle.post("staged at teardown"));
    try testing.expectEqual(PostResult.accepted, handle.post("also staged"));
    fx.closeChannel(29);
    try testing.expect(fx.hasPending());

    // Teardown discards the staged backlog AND the close marker (the
    // families' no-Msg teardown discipline) — the count reconciles to
    // zero with them, so a caller polling `hasPending` after teardown
    // reads idle, never a permanent busy signal.
    fx.deinit();
    try testing.expect(!fx.hasPending());
    try testing.expectEqual(PostResult.closed, handle.post("after teardown"));
}
