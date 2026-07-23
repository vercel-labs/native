//! Pty effect coverage: the `fx.ptySpawn` family — lifecycle (spawn,
//! coalesced output, resize, kill, the exactly-one exit), the shared
//! key space with the other keyed families, the scriptable fake pty
//! (the null platform's whole terminal story), the live POSIX
//! transport's coalescing and lossless back-pressure, and the
//! record/replay acceptance story: replay NEVER spawns a process — the
//! journaled output batches (bytes in the session blob store) and the
//! exit record ARE the session, fed byte-identical with no shell
//! present.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const pty_transport = @import("pty.zig");
const session_blobs = @import("session_blobs.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");

const testing = std.testing;

// ---------------------------------------------------- direct-fx tests
//
// The fake pty needs no executor thread or platform: a direct
// `Effects(Msg)` instance plus `takeMsg` drives the whole vocabulary.

const DirectMsg = union(enum) {
    pty: effects_mod.EffectPtyEvent,
};

const DirectFx = effects_mod.Effects(DirectMsg);

fn expectOutput(fx: *DirectFx, key: u64, bytes: []const u8) !void {
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(key, msg.pty.key);
    try testing.expectEqual(effects_mod.EffectPtyEventKind.output, msg.pty.kind);
    try testing.expectEqualStrings(bytes, msg.pty.bytes);
    // A non-exit event carries the -1 code sentinel — the live drain's
    // default. A fed (replay) output batch must match it, or an app that
    // folds the code into its model diverges on replay.
    try testing.expectEqual(effects_mod.effect_error_exit_code, msg.pty.code);
}

fn expectExit(fx: *DirectFx, key: u64, reason: effects_mod.EffectExitReason) !effects_mod.EffectPtyEvent {
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(key, msg.pty.key);
    try testing.expectEqual(effects_mod.EffectPtyEventKind.exit, msg.pty.kind);
    try testing.expectEqual(reason, msg.pty.reason);
    return msg.pty;
}

test "fake pty lifecycle: spawn parks the request, feeds deliver, exit retires the key" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{
        .key = 9,
        .argv = &.{ "sh", "-l" },
        .cols = 120,
        .rows = 40,
        .on_event = DirectFx.ptyMsg(.pty),
    });
    try testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
    const request = fx.pendingPtyAt(0) orelse return error.TestExpectedRequest;
    try testing.expectEqual(@as(u64, 9), request.key);
    try testing.expectEqual(@as(usize, 2), request.argv.len);
    try testing.expectEqualStrings("sh", request.argv[0]);
    try testing.expectEqualStrings("-l", request.argv[1]);
    try testing.expectEqual(@as(u16, 120), request.cols);
    try testing.expectEqual(@as(u16, 40), request.rows);
    try testing.expectEqualStrings(pty_transport.default_term, request.term);

    try fx.feedPtyOutput(9, "$ ");
    try fx.feedPtyOutput(9, "hello\r\n");
    try fx.feedPtyExit(9, 0, 0, .exited, 0);
    try expectOutput(&fx, 9, "$ ");
    try expectOutput(&fx, 9, "hello\r\n");
    const exit = try expectExit(&fx, 9, .exited);
    try testing.expectEqual(@as(i32, 0), exit.code);
    try testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());

    // The exit delivery freed the key: a fresh spawn under it is
    // accepted (the families' shared instant).
    fx.ptySpawn(.{ .key = 9, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    try testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
}

test "pty admission: every refused spawn delivers exactly one rejected exit" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Empty argv.
    fx.ptySpawn(.{ .key = 1, .argv = &.{}, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 1, .rejected);

    // argv over the entry budget.
    var too_many: [effects_mod.max_effect_argv + 1][]const u8 = undefined;
    for (&too_many) |*arg| arg.* = "x";
    fx.ptySpawn(.{ .key = 2, .argv = &too_many, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 2, .rejected);

    // argv over the byte budget.
    const big = "y" ** (effects_mod.max_effect_argv_bytes + 1);
    fx.ptySpawn(.{ .key = 3, .argv = &.{big}, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 3, .rejected);

    // A zero dimension.
    fx.ptySpawn(.{ .key = 4, .argv = &.{"sh"}, .cols = 0, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 4, .rejected);

    // TERM over its bound.
    const long_term = "t" ** (effects_mod.max_effect_pty_term_bytes + 1);
    fx.ptySpawn(.{ .key = 5, .argv = &.{"sh"}, .term = long_term, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 5, .rejected);

    // A duplicate active key.
    fx.ptySpawn(.{ .key = 6, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    fx.ptySpawn(.{ .key = 6, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 6, .rejected);

    // Table exhaustion: the table already holds key 6; filling the
    // remaining slots leaves the next spawn refused.
    var key: u64 = 7;
    while (key < 7 + effects_mod.max_effect_ptys - 1) : (key += 1) {
        fx.ptySpawn(.{ .key = key, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    }
    fx.ptySpawn(.{ .key = 99, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 99, .rejected);
    try testing.expectEqual(@as(usize, effects_mod.max_effect_ptys), fx.pendingPtyCount());
}

test "fake pty write capture, resize mirror, and kill mirror" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{ .key = 11, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    try testing.expect(fx.ptyWrite(11, "ls -la"));
    try testing.expect(fx.ptyWrite(11, "\r"));
    try testing.expectEqualStrings("ls -la\r", fx.ptyWrittenBytes(11));

    // Over-bound single write: refused whole (returns false), never a cut.
    const oversized = "z" ** (effects_mod.max_effect_pty_write_bytes + 1);
    try testing.expect(!fx.ptyWrite(11, oversized));
    try testing.expectEqualStrings("ls -la\r", fx.ptyWrittenBytes(11));

    fx.ptyResize(11, 200, 60);
    const size = fx.ptySize(11) orelse return error.TestExpectedSize;
    try testing.expectEqual(@as(u16, 200), size.cols);
    try testing.expectEqual(@as(u16, 60), size.rows);

    try testing.expect(!fx.ptyKillRequested(11));
    fx.ptyKill(11);
    try testing.expect(fx.ptyKillRequested(11));
    // The scripted ending after a kill: a kill is a cancellation, not a
    // signaled death, so the live transport reports reason `.cancelled`
    // with no signal and the -1 code. Feeding a stray signal 9 proves
    // the feed boundary clamps the tuple to that contract rather than
    // journaling an event replay's damage gate would later refuse. The
    // delivered drop count is the fed count plus the refusal the fake
    // itself counted for the oversized write above — the counted-refusal
    // contract, without the script re-deriving the tally.
    try fx.feedPtyExit(11, 7, 9, .cancelled, 0);
    const exit = try expectExit(&fx, 11, .cancelled);
    try testing.expectEqual(@as(i32, 0), exit.signal);
    try testing.expectEqual(effects_mod.effect_error_exit_code, exit.code);
    try testing.expectEqual(@as(u32, 1), exit.dropped_writes);
}

test "a signaled exit carries its signal; a signaled feed with no signal is refused" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The contract is a biconditional: `.signaled` REQUIRES a nonzero
    // signal (and a signal is meaningful ONLY on `.signaled`). A feed
    // that names `.signaled` with signal 0 could never come from the live
    // transport and would journal a record replay's damage gate refuses —
    // so the feed boundary refuses it loudly, before it can be recorded.
    fx.ptySpawn(.{ .key = 51, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    try testing.expectError(error.ReplayDamagedRecord, fx.feedPtyExit(51, -1, 0, .signaled, 0));
    // The slot is untouched by the refusal: a well-formed signaled exit
    // then delivers, carrying its signal and the -1 code sentinel.
    try fx.feedPtyExit(51, -1, 9, .signaled, 0);
    const exit = try expectExit(&fx, 51, .signaled);
    try testing.expectEqual(@as(i32, 9), exit.signal);
    try testing.expectEqual(effects_mod.effect_error_exit_code, exit.code);
}

test "replay-mode ptyWrite returns the journaled verdicts, never a recomputed guess" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.armReplay();

    // The replayed spawn parks; the parked occupancy holds the key.
    fx.ptySpawn(.{ .key = 81, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });

    // The journal recorded refuse-then-accept (a full FIFO that later
    // drained). The replayed writes must return exactly that — the
    // fake has no child, so recomputing admission locally would answer
    // `true` for the first write and diverge any model that retained
    // the refused bytes.
    try fx.pushReplayPtyWriteVerdict(false);
    try fx.pushReplayPtyWriteVerdict(true);
    try testing.expect(!fx.ptyWrite(81, "retained bytes"));
    try testing.expect(fx.ptyWrite(81, "delivered bytes"));

    // Boundary alignment: an empty payload consumes no verdict (both
    // sides return true before the admission decision), and a write
    // past the recorded count answers optimistically with a divergence
    // warning rather than trapping.
    try fx.pushReplayPtyWriteVerdict(false);
    try testing.expect(fx.ptyWrite(81, ""));
    try testing.expect(!fx.ptyWrite(81, "consumes the queued refusal"));
    try testing.expect(fx.ptyWrite(81, "past the recording"));
}

test "settle refuses replay write-count divergence in both directions" {
    // Leftover verdicts: the replayed updates wrote FEWER times than
    // the recording. No checkpoint necessarily moves (nothing consumed
    // the verdict), so only the end-of-journal settle makes it loud.
    {
        var fx = DirectFx.init(testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        try fx.pushReplayPtyWriteVerdict(true);
        try testing.expectError(error.ReplayDivergence, fx.settleReplayFeeds());
    }
    // Underflow: the replayed updates wrote MORE times than the
    // recording. The extra write answered optimistically (a
    // fire-and-forget caller ignores it, changing no state), so again
    // only settle catches it.
    {
        var fx = DirectFx.init(testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        fx.ptySpawn(.{ .key = 82, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
        try testing.expect(fx.ptyWrite(82, "past the recording"));
        try testing.expectError(error.ReplayDivergence, fx.settleReplayFeeds());
    }
    // Exact consumption settles clean.
    {
        var fx = DirectFx.init(testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        fx.ptySpawn(.{ .key = 83, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
        try fx.pushReplayPtyWriteVerdict(false);
        try testing.expect(!fx.ptyWrite(83, "recorded"));
        try fx.settleReplayFeeds();
    }
}

test "staged-Msg keys stay valid across a large batch (no fixed-ring clobber)" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    // A single Cmd.batch can stage far more keyed rejections than any
    // fixed ring holds; each must keep its OWN key until delivery. Stage
    // many distinct keys WITHOUT draining (the stage never empties, so no
    // reclaim happens between them) and capture each returned durable
    // slice.
    const count = 40;
    var slices: [count][]const u8 = undefined;
    var scratch: [count][8]u8 = undefined;
    for (0..count) |i| {
        const key = std.fmt.bufPrint(&scratch[i], "k{d}", .{i}) catch unreachable;
        slices[i] = fx.stageLoopKey(key);
        fx.stageLoopMsg(.{ .pty = .{ .key = 0, .kind = .exit, .reason = .rejected } });
    }
    // Every captured slice still reads its ORIGINAL key — none clobbered
    // by a later one, though the backing array grew several times past
    // its initial capacity.
    for (0..count) |i| {
        var expect: [8]u8 = undefined;
        const want = std.fmt.bufPrint(&expect, "k{d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(want, slices[i]);
    }
}

test "a fake pty refuses a second feed after its exit is queued" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{ .key = 71, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    try fx.feedPtyExit(71, 0, 0, .exited, 0);
    // One terminal per spawn: a feed before the exit drains is refused
    // loudly, never enqueued and silently dropped.
    try testing.expectError(error.ReplayDamagedRecord, fx.feedPtyOutput(71, "late"));
    try testing.expectError(error.ReplayDamagedRecord, fx.feedPtyExit(71, 0, 0, .exited, 0));
    _ = try expectExit(&fx, 71, .exited);
}

test "a fed output batch over the chunk bound is refused, never truncated" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{ .key = 72, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    var over: [effects_mod.max_effect_pty_chunk_bytes + 1]u8 = undefined;
    @memset(&over, 'x');
    try testing.expectError(error.PtyChunkTooLarge, fx.feedPtyOutput(72, &over));
}

test "a fed output batch past the inline entry bound rides a heap payload intact" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{ .key = 21, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    var big: [effects_mod.max_effect_line_bytes + 128]u8 = undefined;
    for (&big, 0..) |*byte, index| byte.* = @intCast('a' + (index % 26));
    try fx.feedPtyOutput(21, &big);
    const msg = fx.takeMsg() orelse return error.TestExpectedMsg;
    try testing.expectEqual(effects_mod.EffectPtyEventKind.output, msg.pty.kind);
    try testing.expectEqualSlices(u8, &big, msg.pty.bytes);
}

test "pty keys share the keyed families' space" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.ptySpawn(.{ .key = 31, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    // A channel open under the pty's key is refused (and vice versa —
    // one key space across every keyed family).
    const handle = fx.openChannel(.{ .key = 31, .on_event = undefined });
    try testing.expect(handle.shared == null);
}

test "replay never spawns: an armed channel parks the spawn and feeds deliver the session" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.armReplay();

    fx.ptySpawn(.{ .key = 41, .argv = &.{ "sh", "-c", "echo hi" }, .on_event = DirectFx.ptyMsg(.pty) });
    // Parked as a fake: no process, no io thread — the journal is the
    // whole world.
    try testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
    try fx.feedPtyOutput(41, "hi\r\n");
    try fx.feedPtyExit(41, 0, 0, .exited, 0);
    try expectOutput(&fx, 41, "hi\r\n");
    _ = try expectExit(&fx, 41, .exited);
    try testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());

    // A fed start failure retires a park at the spawn's dispatch
    // position (the reserved pending-order stamp).
    fx.ptySpawn(.{ .key = 42, .argv = &.{"missing-binary"}, .on_event = DirectFx.ptyMsg(.pty) });
    try fx.feedPtyExit(42, effects_mod.effect_error_exit_code, 0, .spawn_failed, 0);
    _ = try expectExit(&fx, 42, .spawn_failed);
    try testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());

    // Nothing feeds past a terminal: one exit per spawn.
    fx.ptySpawn(.{ .key = 43, .argv = &.{"sh"}, .on_event = DirectFx.ptyMsg(.pty) });
    try fx.feedPtyExit(43, 0, 0, .exited, 0);
    try testing.expectError(error.ReplayDamagedRecord, fx.feedPtyOutput(43, "late"));
}

// ---------------------------------------------------- live posix tests
//
// The real transport, driven end to end through the effects channel.
// Skipped where the toolkit has no pty (Windows, libc-free builds) —
// the fake pty above is that platform's whole story.

fn drainUntilExit(fx: *DirectFx, budget_ms: u64) !struct {
    output: std.ArrayList(u8),
    records: usize,
    exit: effects_mod.EffectPtyEvent,
} {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(testing.allocator);
    var records: usize = 0;
    var waited: u64 = 0;
    while (waited < budget_ms) {
        while (fx.takeMsg()) |msg| {
            switch (msg.pty.kind) {
                .output => {
                    records += 1;
                    try output.appendSlice(testing.allocator, msg.pty.bytes);
                },
                .exit => return .{ .output = output, .records = records, .exit = msg.pty },
                // Journal-only write verdicts never deliver as events.
                .write => unreachable,
            }
        }
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake);
        waited += 2;
    }
    return error.TestPtyTimeout;
}

test "live pty end to end: output, coalescing, and the exit code" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    fx.ptySpawn(.{
        .key = 51,
        // 200 one-byte writes; the staging ring coalesces whatever
        // lands between drains, so waiting for the child first proves
        // the batch arrives as a handful of records, never 200.
        .argv = &.{ "/bin/sh", "-c", "i=0; while [ $i -lt 200 ]; do printf x; i=$((i+1)); done; exit 4" },
        .on_event = DirectFx.ptyMsg(.pty),
    });
    // Let the child finish before the first drain — every byte then
    // sits in one staged backlog.
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(300), .awake);
    var result = try drainUntilExit(&fx, 5_000);
    defer result.output.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 200), result.output.items.len);
    try testing.expect(result.records <= 3);
    try testing.expectEqual(@as(i32, 4), result.exit.code);
    try testing.expectEqual(effects_mod.EffectExitReason.exited, result.exit.reason);
}

test "live pty back-pressure is lossless past the staging ring" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    // One megabyte — four times the staging ring. The reader parks when
    // the ring fills and resumes as the drain frees room; every byte
    // arrives, each record within the chunk bound.
    const total: usize = 1024 * 1024;
    fx.ptySpawn(.{
        .key = 52,
        .argv = &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=4096 count=256 2>/dev/null | tr '\\0' 'a'" },
        .on_event = DirectFx.ptyMsg(.pty),
    });
    var result = try drainUntilExit(&fx, 30_000);
    defer result.output.deinit(testing.allocator);
    try testing.expectEqual(total, result.output.items.len);
    for (result.output.items) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
    try testing.expectEqual(effects_mod.EffectExitReason.exited, result.exit.reason);
}

test "live pty write and kill: input reaches the child, the exit reports cancelled" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    fx.ptySpawn(.{
        .key = 53,
        .argv = &.{"/bin/cat"},
        .on_event = DirectFx.ptyMsg(.pty),
    });
    try testing.expect(fx.ptyWrite(53, "ping\r"));
    // The line discipline echoes the input and cat writes it back;
    // either way "ping" must appear in the stream.
    var seen = false;
    var waited: u64 = 0;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(testing.allocator);
    while (!seen and waited < 5_000) {
        while (fx.takeMsg()) |msg| {
            if (msg.pty.kind == .output) try collected.appendSlice(testing.allocator, msg.pty.bytes);
        }
        seen = std.mem.indexOf(u8, collected.items, "ping") != null;
        if (!seen) {
            try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake);
            waited += 2;
        }
    }
    try testing.expect(seen);

    fx.ptyKill(53);
    var result = try drainUntilExit(&fx, 5_000);
    defer result.output.deinit(testing.allocator);
    try testing.expectEqual(effects_mod.EffectExitReason.cancelled, result.exit.reason);
    // A cancelled end carries the -1 sentinel, never a stale child code.
    try testing.expectEqual(effects_mod.effect_error_exit_code, result.exit.code);
}

test "a write refused after the exit is staged still counts into dropped_writes" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    // A child that exits immediately and prints nothing: the io thread
    // stages the exit; the loop has not delivered it yet.
    fx.ptySpawn(.{
        .key = 57,
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .on_event = DirectFx.ptyMsg(.pty),
    });
    var waited: u64 = 0;
    while (fx.pty_pending_count.load(.seq_cst) == 0 and waited < 5_000) {
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake);
        waited += 2;
    }
    try testing.expect(fx.pty_pending_count.load(.seq_cst) > 0);

    // The staged-exit window: the write is refused (no io thread will
    // flush it) but COUNTED — the exit event reads the drop count at
    // delivery, which has not happened yet, so no refusal is silent.
    try testing.expect(!fx.ptyWrite(57, "late"));
    const exit = try expectExit(&fx, 57, .exited);
    try testing.expectEqual(@as(i32, 0), exit.code);
    try testing.expectEqual(@as(u32, 1), exit.dropped_writes);
}

test "a fed output batch over the chunk bound and NUL-bearing term/argv are refused" {
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // TERM with an embedded NUL: refused (a truncated TERM would reach
    // the child as a different value than requested).
    fx.ptySpawn(.{ .key = 81, .argv = &.{"sh"}, .term = "xterm\x00evil", .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 81, .rejected);
    // argv with an embedded NUL: refused (fake and real agree).
    fx.ptySpawn(.{ .key = 82, .argv = &.{ "sh", "a\x00b" }, .on_event = DirectFx.ptyMsg(.pty) });
    _ = try expectExit(&fx, 82, .rejected);
}

test "live pty resize lands as the child's window size" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    defer fx.deinit();

    fx.ptySpawn(.{
        .key = 54,
        // Report the size the kernel line discipline hands back after
        // the spawn declared 91x33 — proof the initial TIOCSWINSZ took.
        .argv = &.{ "/bin/sh", "-c", "stty size" },
        .cols = 91,
        .rows = 33,
        .on_event = DirectFx.ptyMsg(.pty),
    });
    var result = try drainUntilExit(&fx, 5_000);
    defer result.output.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.output.items, "33 91") != null);
}

test "teardown with a live pty returns promptly and reaps the child" {
    if (comptime !pty_transport.supported) return;
    var fx = DirectFx.init(testing.allocator);
    fx.ptySpawn(.{
        .key = 55,
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .on_event = DirectFx.ptyMsg(.pty),
    });
    // Give the transport a moment to start, then tear the channel down
    // mid-session: the group kill converges the io thread and deinit
    // returns without waiting out the sleep.
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(50), .awake);
    fx.deinit();
}

// ---------------------------------------- record/replay acceptance

const pty_canvas_label = "pty-session-canvas";

const PtySessionModel = struct {
    output_events: u32 = 0,
    exit_events: u32 = 0,
    rejected_events: u32 = 0,
    last_code: i32 = 0,
    /// Rolling order-sensitive digest of every delivered byte — a
    /// replay that reorders, drops, or alters one byte diverges here
    /// (and in the fingerprint checkpoints that pin it).
    output_digest: u64 = 0,
    output_bytes: u64 = 0,
    /// `ptyWrite` admission verdicts folded into MODEL STATE — the
    /// retain-refused-bytes pattern a real terminal uses. Replay must
    /// reproduce the recorded verdicts exactly or these counters (and
    /// the fingerprint checkpoints rendering them) diverge.
    write_accepts: u32 = 0,
    write_refusals: u32 = 0,

    fn record(model: *PtySessionModel, event: effects_mod.EffectPtyEvent) void {
        switch (event.kind) {
            .output => {
                model.output_events += 1;
                model.output_digest = std.hash.Wyhash.hash(model.output_digest, event.bytes);
                model.output_bytes += event.bytes.len;
            },
            .exit => {
                if (event.reason == .rejected) {
                    model.rejected_events += 1;
                } else {
                    model.exit_events += 1;
                }
                model.last_code = event.code;
            },
            // Journal-only write verdicts never deliver as events.
            .write => unreachable,
        }
    }

    fn recordWriteVerdict(model: *PtySessionModel, accepted: bool) void {
        if (accepted) model.write_accepts += 1 else model.write_refusals += 1;
    }
};

const PtySessionMsg = union(enum) {
    spawn,
    spawn_dup,
    type_command,
    type_oversized,
    event: effects_mod.EffectPtyEvent,
};

const PtySessionApp = ui_app_mod.UiApp(PtySessionModel, PtySessionMsg);

const session_pty_key: u64 = 61;

fn ptySessionUpdate(model: *PtySessionModel, msg: PtySessionMsg, fx: *PtySessionApp.Effects) void {
    switch (msg) {
        .spawn => fx.ptySpawn(.{
            .key = session_pty_key,
            .argv = &.{ "sh", "-i" },
            .cols = 100,
            .rows = 30,
            .on_event = PtySessionApp.Effects.ptyMsg(.event),
        }),
        // The duplicate spawn: refused loop-side on BOTH sides — the
        // journaled `.rejected` exit regenerates at replay.
        .spawn_dup => fx.ptySpawn(.{
            .key = session_pty_key,
            .argv = &.{"sh"},
            .on_event = PtySessionApp.Effects.ptyMsg(.event),
        }),
        // Journaled as a command dispatch; the write's BYTES are inert
        // under replay (the recorded output already carries their
        // consequences), but its admission VERDICT is executor truth the
        // journal feeds — the model folds it in so replay must take the
        // identical accept/refuse path.
        .type_command => model.recordWriteVerdict(fx.ptyWrite(session_pty_key, "ls\r")),
        // Over the per-write bound: refused live (the all-or-nothing
        // admission), and the journaled refusal must return under
        // replay too — a recomputed optimistic `true` would diverge the
        // model and the fingerprint.
        .type_oversized => model.recordWriteVerdict(fx.ptyWrite(
            session_pty_key,
            &(comptime [_]u8{'z'} ** (effects_mod.max_effect_pty_write_bytes + 1)),
        )),
        .event => |event| model.record(event),
    }
}

fn ptySessionView(ui: *PtySessionApp.Ui, model: *const PtySessionModel) PtySessionApp.Ui.Node {
    // The semantic tree carries every pty-derived model fact, so the
    // fingerprint checkpoints PIN the stream — batch bytes, order,
    // and the exit taxonomy alike.
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} batches / {d} bytes", .{ model.output_events, model.output_bytes })),
        ui.text(.{}, ui.fmt("digest {x}", .{model.output_digest})),
        ui.text(.{}, ui.fmt("{d} exits ({d}) {d} rejected", .{ model.exit_events, model.last_code, model.rejected_events })),
        ui.text(.{}, ui.fmt("{d} writes ok / {d} refused", .{ model.write_accepts, model.write_refusals })),
    });
}

fn ptySessionCommand(name: []const u8) ?PtySessionMsg {
    if (std.mem.eql(u8, name, "pty.spawn")) return .spawn;
    if (std.mem.eql(u8, name, "pty.spawn-dup")) return .spawn_dup;
    if (std.mem.eql(u8, name, "pty.type")) return .type_command;
    if (std.mem.eql(u8, name, "pty.type-oversized")) return .type_oversized;
    return null;
}

const pty_session_views = [_]app_manifest.ShellView{
    .{ .label = pty_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const pty_session_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Pty Session",
    .width = 400,
    .height = 300,
    .views = &pty_session_views,
}};
const pty_session_scene: app_manifest.ShellConfig = .{ .windows = &pty_session_windows };

fn ptySessionOptions() PtySessionApp.Options {
    return .{
        .name = "pty-session-demo",
        .scene = pty_session_scene,
        .canvas_label = pty_canvas_label,
        .update_fx = ptySessionUpdate,
        .view = ptySessionView,
        .on_command = ptySessionCommand,
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

const RecordedPtySession = struct {
    model: PtySessionModel,
    fingerprint: u64,
};

/// Record the pty reference session against the scriptable fake pty
/// (the CI-deterministic shell): spawn, a prompt batch, a typed
/// command whose echo and listing arrive as one coalesced batch, a
/// duplicate spawn's regenerating rejection, and the exit terminal —
/// checkpoints after every wake.
fn recordPtySession(gpa: std.mem.Allocator, buffer: *JournalBuffer, store: *session_blobs.MemoryBlobStore) !RecordedPtySession {
    const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = session_record.SessionRecorder.init(buffer.sink());
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "pty-session-demo", .window_width = 400, .window_height = 300 });

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const app_state = try gpa.create(PtySessionApp);
    defer gpa.destroy(app_state);
    app_state.* = PtySessionApp.init(std.heap.page_allocator, .{}, ptySessionOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app = app_state.app();

    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = pty_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "pty.spawn", .window_id = 1 } });
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());

    // The scripted shell prompt.
    try app_state.effects.feedPtyOutput(session_pty_key, "sh-5.2$ ");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.output_events);

    // The app types; the scripted shell answers with echo + listing in
    // one coalesced batch (what the live ring would deliver). The
    // write's admission verdict journals and lands in the model.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "pty.type", .window_id = 1 } });
    try testing.expectEqualStrings("ls\r", app_state.effects.ptyWrittenBytes(session_pty_key));
    try testing.expectEqual(@as(u32, 1), app_state.model.write_accepts);
    try app_state.effects.feedPtyOutput(session_pty_key, "ls\r\nREADME.md\r\nsrc\r\nsh-5.2$ ");
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 2), app_state.model.output_events);

    // An over-bound write: refused live (all-or-nothing), the verdict
    // journaled — replay must take the identical refusal path.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "pty.type-oversized", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.write_refusals);

    // The duplicate spawn: one regenerating `.rejected` exit.
    try harness.runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "pty.spawn-dup", .window_id = 1 } });
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.rejected_events);

    // The session ends.
    try app_state.effects.feedPtyExit(session_pty_key, 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
    try testing.expectEqual(@as(u32, 1), app_state.model.exit_events);

    recorder.finish();
    try testing.expect(!recorder.failed);
    return .{
        .model = app_state.model,
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
}

test "a recorded pty session replays fingerprint-identical offline with no shell present" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();

    const recorded = try recordPtySession(gpa, buffer, &store);
    try testing.expectEqual(@as(u32, 2), recorded.model.output_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.exit_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.rejected_events);
    try testing.expectEqual(@as(u32, 1), recorded.model.write_accepts);
    try testing.expectEqual(@as(u32, 1), recorded.model.write_refusals);

    // The output bytes live in the blob store, not the journal — the
    // dynamic-image pipeline (two batches, two blobs).
    try testing.expect(store.count >= 2);

    // Replay into a fresh app: no process spawns (the armed channel
    // parks every ptySpawn), the blob store supplies the recorded
    // bytes, and every fed event arrives at its recorded position.
    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(PtySessionApp);
    defer gpa.destroy(app_state);
    app_state.* = PtySessionApp.init(std.heap.page_allocator, .{}, ptySessionOptions());
    defer app_state.deinit();

    const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
        .blobs = store.source(),
    });
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // Two output batches, two write-admission verdicts, and the exit
    // FEED; the duplicate spawn's rejection regenerates from the
    // replayed dispatch and its record is skipped.
    try testing.expectEqual(@as(u64, 5), report.effects_fed);
    try testing.expectEqual(@as(u64, 1), report.effects_skipped);
    // THE verdict pin: the replayed writes took the recorded
    // accept/refuse paths (one of each), never a recomputed guess —
    // model equality covers the counters, the fingerprint the pixels.
    try testing.expectEqual(@as(u32, 1), app_state.model.write_accepts);
    try testing.expectEqual(@as(u32, 1), app_state.model.write_refusals);
    try testing.expectEqualDeep(recorded.model, app_state.model);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
    // Nothing is left occupied: the fed exit retired the parked spawn.
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingPtyCount());
}

test "replay without the blob store refuses a pty output record loudly" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();
    _ = try recordPtySession(gpa, buffer, &store);

    const harness = try core.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try gpa.create(PtySessionApp);
    defer gpa.destroy(app_state);
    app_state.* = PtySessionApp.init(std.heap.page_allocator, .{}, ptySessionOptions());
    defer app_state.deinit();

    const result = session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = false,
        .require_same_platform = false,
    });
    try testing.expectError(error.ReplayMissingBlob, result);
}
