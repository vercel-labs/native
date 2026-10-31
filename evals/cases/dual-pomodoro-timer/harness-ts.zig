//! Behavioral harness for dual-pomodoro-timer, ts track. The grader copies
//! this next to the transpiled core.zig, the rt kernel, and cmdview.zig,
//! then runs `zig test harness.zig`. Asserts the shared behavioral spec:
//! the timer subscription exists exactly while running, ticks count down
//! and auto-advance with the completion sound, work-only counting, stale
//! ticks and re-entry guarded, reset semantics.

const std = @import("std");
const core = @import("core.zig");
const cmdview = @import("cmdview.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_buf: [4096]u8 = undefined;

fn fresh() void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
}

fn dispatch(msg: core.Msg) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(g_buf[0..r.cmd.len], r.cmd);
    rt.frameReset();
    return g_buf[0..r.cmd.len];
}

/// The declared timer subscription on the current model, or null.
fn declaredTimer() ?@FieldType(cmdview.SubOp, "timer") {
    const subs = core.subscriptions(g_model);
    const timer = cmdview.findTimer(subs);
    rt.frameReset();
    return timer;
}

fn tick() []const u8 {
    return dispatch(.{ .tick = 0 });
}

/// Run a whole session down to its completing tick; returns that tick's cmd.
fn runSession(seconds: usize) []const u8 {
    var remaining = seconds;
    while (remaining > 1) : (remaining -= 1) {
        _ = tick();
    }
    return tick();
}

test "starts as a paused full focus session with no timer declared" {
    fresh();
    try std.testing.expect(g_model.phase == .focus);
    try std.testing.expect(g_model.remaining_seconds == 1500);
    try std.testing.expect(!g_model.running);
    try std.testing.expect(g_model.completed_count == 0);
    try std.testing.expect(declaredTimer() == null);
}

test "start declares the 1-second timer; pause and reset take it down" {
    fresh();
    _ = dispatch(.start);
    try std.testing.expect(g_model.running);
    const timer = declaredTimer() orelse return error.NoTimerDeclared;
    try std.testing.expectEqual(@as(f64, 1000), timer.every_ms);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).tick), timer.msg_tag);

    _ = dispatch(.pause);
    try std.testing.expect(!g_model.running);
    try std.testing.expect(declaredTimer() == null);

    _ = dispatch(.start);
    try std.testing.expect(declaredTimer() != null);
    _ = dispatch(.reset);
    try std.testing.expect(declaredTimer() == null);
}

test "ticks count down while running; stale ticks while paused change nothing" {
    fresh();
    _ = dispatch(.start);
    _ = tick();
    _ = tick();
    try std.testing.expect(g_model.remaining_seconds == 1498);

    _ = dispatch(.pause);
    _ = tick();
    try std.testing.expect(g_model.remaining_seconds == 1498);

    _ = dispatch(.start);
    try std.testing.expect(g_model.remaining_seconds == 1498);
    _ = tick();
    try std.testing.expect(g_model.remaining_seconds == 1497);
}

test "start while running changes nothing" {
    fresh();
    _ = dispatch(.start);
    _ = tick();
    _ = dispatch(.start);
    try std.testing.expect(g_model.remaining_seconds == 1499);
    try std.testing.expect(g_model.running);
}

test "a focus session completes into a running rest with the sound and a count" {
    fresh();
    _ = dispatch(.start);
    const completing = runSession(1500);
    try std.testing.expect(g_model.phase == .rest);
    try std.testing.expect(g_model.remaining_seconds == 300);
    try std.testing.expect(g_model.running);
    try std.testing.expect(g_model.completed_count == 1);
    const play = cmdview.findOp(completing, .audio_play) orelse return error.NoCompletionSound;
    try std.testing.expectEqualStrings("assets/ding.wav", play.path);
    // The countdown keeps running: the timer stays declared.
    try std.testing.expect(declaredTimer() != null);
}

test "a rest completes into a running focus session without counting" {
    fresh();
    _ = dispatch(.start);
    _ = runSession(1500);
    const completing = runSession(300);
    try std.testing.expect(g_model.phase == .focus);
    try std.testing.expect(g_model.remaining_seconds == 1500);
    try std.testing.expect(g_model.running);
    try std.testing.expect(g_model.completed_count == 1);
    try std.testing.expect(cmdview.findOp(completing, .audio_play) != null);
}

test "reset returns to a paused full focus session and keeps the count" {
    fresh();
    _ = dispatch(.start);
    _ = runSession(1500);
    _ = tick();
    _ = dispatch(.reset);
    try std.testing.expect(g_model.phase == .focus);
    try std.testing.expect(g_model.remaining_seconds == 1500);
    try std.testing.expect(!g_model.running);
    try std.testing.expect(g_model.completed_count == 1);
}
