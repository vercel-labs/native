//! Dev-session process ownership. `native dev` runs an app (and possibly
//! a frontend dev server) under child processes that spawn children of
//! their own — `zig build run` owns the app binary, a dev-server command
//! spawns the real server. Killing only the direct child leaves those
//! grandchildren running, and an orphaned automation-enabled app keeps
//! publishing snapshots into the project's dropbox where it impersonates
//! the next build.
//!
//! The fix: each owned child spawns into its own POSIX process group
//! (`SpawnOptions.pgid = 0`), and the whole group is signalled when the
//! session ends — on the normal exit path AND on SIGINT/SIGTERM/SIGHUP
//! delivered to the CLI itself. Windows has no process groups here; the
//! helpers become no-ops and only direct children are killed.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const max_groups = 4;
var group_pids = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(0)} ** max_groups;
var signals_installed = false;

/// Value for `std.process.SpawnOptions.pgid`: 0 places the child in a
/// fresh process group whose id is the child's pid.
pub fn spawnPgid() ?std.posix.pid_t {
    return if (supported) 0 else null;
}

/// Track a spawned child as an owned process group and install the
/// exit-signal hooks (once) that kill every owned group.
pub fn own(pid: i32) void {
    if (!supported) return;
    installSignalHandlers();
    for (&group_pids) |*slot| {
        if (slot.cmpxchgStrong(0, pid, .seq_cst, .seq_cst) == null) return;
    }
}

/// TERM one owned group and stop tracking it. Used after the child's
/// wait() returns, sweeping any grandchildren it leaked; a group that
/// already fully exited makes the kill a harmless no-op.
pub fn releaseAndKill(pid: i32) void {
    if (!supported) return;
    for (&group_pids) |*slot| {
        _ = slot.cmpxchgStrong(pid, 0, .seq_cst, .seq_cst);
    }
    killGroup(pid);
}

fn killGroup(pid: i32) void {
    if (!supported) return;
    if (pid <= 0) return;
    std.posix.kill(-pid, .TERM) catch {};
}

fn killAllOwned() void {
    for (&group_pids) |*slot| {
        const pid = slot.load(.seq_cst);
        if (pid > 0) killGroup(pid);
    }
}

fn installSignalHandlers() void {
    if (signals_installed) return;
    signals_installed = true;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleExitSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.HUP, &action, null);
}

/// Async-signal-safe: kill(2) and _exit(2) only. Children sit in their
/// own process groups, so the terminal's Ctrl-C SIGINT reaches only this
/// CLI — forwarding to the groups is what shuts the app down.
fn handleExitSignal(sig: std.posix.SIG) callconv(.c) void {
    killAllOwned();
    // Conventional 128+signal exit code.
    std.process.exit(128 +| @as(u8, @truncate(@intFromEnum(sig))));
}

test "spawnPgid requests a fresh group on posix" {
    if (supported) {
        try std.testing.expectEqual(@as(?std.posix.pid_t, 0), spawnPgid());
    } else {
        try std.testing.expectEqual(@as(?std.posix.pid_t, null), spawnPgid());
    }
}

test "own and releaseAndKill track slots without leaking entries" {
    if (!supported) return;
    // Use pids that cannot exist so the sweep kill is a no-op error.
    own(1 << 22);
    releaseAndKill(1 << 22);
    for (&group_pids) |*slot| {
        try std.testing.expectEqual(@as(i32, 0), slot.load(.seq_cst));
    }
}
