//! Behavioral harness for dual-pomodoro-timer, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig and run through `native test`.
//! Drives update with the deterministic fake effects executor and asserts
//! the same behavioral spec the ts track's harness asserts: a timer armed
//! exactly while running, second-by-second countdown, auto-advance with the
//! completion sound, work-only counting, stale ticks and re-entry guarded,
//! reset semantics.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

const Rig = struct {
    model: main.Model,
    fx: main.Effects,

    fn init() Rig {
        var fx = main.Effects.init(testing.allocator);
        fx.executor = .fake;
        return .{ .model = main.initialModel(), .fx = fx };
    }

    fn deinit(self: *Rig) void {
        self.fx.deinit();
    }

    fn dispatch(self: *Rig, msg: main.Msg) void {
        main.update(&self.model, msg, &self.fx);
    }

    fn drain(self: *Rig) void {
        while (self.fx.takeMsg()) |msg| main.update(&self.model, msg, &self.fx);
    }

    /// Fire the armed timer once and drain the tick through update.
    /// Re-reads the pending timer each call so one-shot re-arm chains
    /// work exactly like a repeating timer.
    fn tick(self: *Rig) !void {
        const timer = self.fx.pendingTimerAt(0) orelse return error.NoTimerArmed;
        try self.fx.fireTimer(timer.key);
        self.drain();
    }

    /// Run a whole session down through its completing tick.
    fn runSession(self: *Rig, seconds: usize) !void {
        var remaining = seconds;
        while (remaining > 0) : (remaining -= 1) {
            try self.tick();
        }
    }
};

test "starts as a paused full focus session with no timer armed" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.phase == .focus);
    try testing.expect(rig.model.remaining_seconds == 1500);
    try testing.expect(!rig.model.running);
    try testing.expect(rig.model.completed_count == 0);
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingTimerCount());
}

test "start arms the 1-second timer; pause and reset take it down" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try testing.expect(rig.model.running);
    const timer = rig.fx.pendingTimerAt(0) orelse return error.NoTimerArmed;
    try testing.expectEqual(@as(u64, 1000), timer.interval_ms);

    rig.dispatch(.pause);
    try testing.expect(!rig.model.running);
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingTimerCount());

    rig.dispatch(.start);
    try testing.expect(rig.fx.pendingTimerCount() != 0);
    rig.dispatch(.reset);
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingTimerCount());
}

test "ticks count down while running; a stale tick while paused changes nothing" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try rig.tick();
    try rig.tick();
    try testing.expect(rig.model.remaining_seconds == 1498);

    rig.dispatch(.pause);
    // A stale fire delivered after pausing: dispatch the tick arm directly.
    rig.dispatch(.{ .tick = .{ .key = 0, .timestamp_ns = 0, .outcome = .fired } });
    try testing.expect(rig.model.remaining_seconds == 1498);

    rig.dispatch(.start);
    try testing.expect(rig.model.remaining_seconds == 1498);
    try rig.tick();
    try testing.expect(rig.model.remaining_seconds == 1497);
}

test "start while running changes nothing" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try rig.tick();
    rig.dispatch(.start);
    try testing.expect(rig.model.remaining_seconds == 1499);
    try testing.expect(rig.model.running);
}

test "a focus session completes into a running rest with the sound and a count" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try rig.runSession(1500);
    try testing.expect(rig.model.phase == .rest);
    try testing.expect(rig.model.remaining_seconds == 300);
    try testing.expect(rig.model.running);
    try testing.expect(rig.model.completed_count == 1);
    const audio = rig.fx.pendingAudio() orelse return error.NoCompletionSound;
    try testing.expectEqualStrings("assets/ding.wav", audio.path);
    // The countdown keeps running: a timer stays armed.
    try testing.expect(rig.fx.pendingTimerCount() != 0);
}

test "a rest completes into a running focus session without counting" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try rig.runSession(1500);
    try rig.runSession(300);
    try testing.expect(rig.model.phase == .focus);
    try testing.expect(rig.model.remaining_seconds == 1500);
    try testing.expect(rig.model.running);
    try testing.expect(rig.model.completed_count == 1);
    try testing.expect(rig.fx.pendingAudio() != null);
}

test "reset returns to a paused full focus session and keeps the count" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.start);
    try rig.runSession(1500);
    try rig.tick();
    rig.dispatch(.reset);
    try testing.expect(rig.model.phase == .focus);
    try testing.expect(rig.model.remaining_seconds == 1500);
    try testing.expect(!rig.model.running);
    try testing.expect(rig.model.completed_count == 1);
}
