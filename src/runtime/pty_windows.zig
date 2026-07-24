//! Windows pseudo-terminal primitive: a ConPTY (`CreatePseudoConsole`)
//! wired to an overlapped named-pipe pair, presenting the SAME transport
//! surface the POSIX half of `pty.zig` presents — `spawn`, the
//! read/write/resize/kill/reap methods, the nudge pair, and `wait` — so
//! the effects io loop drives both backends through one vocabulary and
//! the null platform's scriptable fake stays the one observable
//! contract.
//!
//! Encoding honesty at the ConPTY boundary: the pseudoconsole's pipe
//! contract IS UTF-8 with VT sequences, both directions — conhost
//! decodes input bytes as UTF-8 (VT input sequences included) and emits
//! its output as UTF-8-encoded VT. There is no console-mode call for
//! the toolkit to make: this host process has no console, and the modes
//! that make the child's world VT-native
//! (`ENABLE_VIRTUAL_TERMINAL_PROCESSING` on output,
//! `ENABLE_VIRTUAL_TERMINAL_INPUT` on input) are owned by the
//! pseudoconsole's conhost, which installs them for its clients. The
//! one configuration the toolkit does choose is `CreatePseudoConsole`'s
//! flags = 0: `PSEUDOCONSOLE_INHERIT_CURSOR` would make conhost open by
//! emitting a cursor-position request (DSR) and WAIT for the terminal's
//! answer — a handshake the effects reader deliberately never plays.
//!
//! Two documented behavioral differences from the POSIX backends:
//!
//! - RENDERED STREAM, NOT RAW BYTES. ConPTY output is conhost's VT
//!   rendering of the child's screen (cursor moves, clears, repaints),
//!   not the child's literal write() stream. A terminal emulator
//!   consumes it identically; byte-exact assertions against child
//!   output do not transfer.
//! - EXIT CODES ONLY. Windows has no signals: every ending carries a
//!   process exit code (`Exit.signal` is always 0), so endings POSIX
//!   reports as `.signaled` surface here as `.exited` with the
//!   terminator's chosen code (a crash shows the NTSTATUS, e.g.
//!   0xC0000005, bit-cast to i32). The toolkit's own kill reports
//!   `.cancelled` through the shared io-loop rule either way.
//!
//! EOF is MANUFACTURED here, deliberately: conhost holds the output
//! pipe open past the child's death, so the pipe alone never EOFs. The
//! `wait` loop watches the process handle; once the child has exited
//! and the pipe has gone quiet behind the armed read, it closes the
//! pseudoconsole — conhost flushes its tail, tears down anything still
//! attached (the POSIX group-kill's analog: a descendant that detached
//! from the console escapes, mirroring the setsid escape), and exits,
//! which breaks the pipe and delivers the EOF the io loop's shared
//! reap path expects. Closing only at a QUIET moment matters: older
//! conhosts block `ClosePseudoConsole` while their output pipe is full,
//! and an empty pipe (ours is 128 KiB) cannot be full.
//!
//! Reaping discipline, Windows-shaped: process objects self-release
//! when the last handle closes — there are no zombies to guard against
//! — so the POSIX surrendered-pid table has no work here. What remains
//! is HANDLE discipline (every spawn's process handle, pipe pair, and
//! events close exactly once, at `close`) and exit-code capture
//! (`GetExitCodeProcess` after the process handle signals).

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("pty.zig");
const clock = @import("clock.zig");

const is_windows = builtin.os.tag == .windows;

const Error = pty.Error;
const Exit = pty.Exit;
const SpawnOptions = pty.SpawnOptions;
const EnvVar = pty.EnvVar;
const Ready = pty.Ready;

/// The parent-side pipe buffer, both directions. Generous on purpose:
/// the quiet-moment console close (see the file doc) relies on "empty
/// pipe means conhost is not blocked writing", and a bigger buffer
/// makes the window where conhost could refill it between the peek and
/// the close irrelevant — a just-emptied 128 KiB pipe cannot be full
/// again before `ClosePseudoConsole` returns.
const pipe_buffer_bytes: u32 = 128 * 1024;
/// Matches the io loop's 16 KiB local read chunk: the overlapped read
/// lands here and `read` hands it out in caller-sized bites.
const read_buffer_bytes: usize = 16 * 1024;
/// Matches the flush path's 4 KiB write chunk (one staged overlapped
/// write in flight; a second write while it pends answers WouldBlock,
/// the POSIX EAGAIN shape).
const write_buffer_bytes: usize = 4096;

/// Everything one live ConPTY session owns, heap-allocated because the
/// transport value is COPIED (into the io thread and the slot) and the
/// overlapped state must be shared, not forked. Threading contract:
/// the io thread owns all read/write/wait state; the loop thread
/// touches only `resize` (pseudoconsole handle, under `hpc_lock`),
/// `kill` (process handle, immutable), and — strictly after the io
/// thread has finished — `close`.
///
/// Allocated from `state_allocator` (process-lifetime backing), NEVER
/// the caller's allocator: teardown may ABANDON an io thread past its
/// join deadline, and everything that thread can still reach must
/// outlive the caller's allocator — the effects layer's abandoned-
/// worker invariant, applied to the transport. The block is freed at
/// `close` (which only runs after the io thread finished); an abandon
/// leaks it with the thread, deliberately.
const State = struct {
    /// The pseudoconsole. Guarded by `hpc_lock` against the one real
    /// race: a loop-thread `resize` landing while the io thread closes
    /// the console after child exit (`ClosePseudoConsole` frees the
    /// object; a resize against it would touch freed kernel-side
    /// plumbing).
    hpc: win.HPCON,
    hpc_lock: SpinLock = .{},
    console_closed: bool = false,
    /// The child process handle (identity is stable for the handle's
    /// life — no pid-reuse hazard, unlike POSIX pids).
    process: win.HANDLE,
    /// Parent end of the output pipe (conhost writes, we read).
    out_read: win.HANDLE,
    /// Parent end of the input pipe (we write, conhost reads).
    in_write: win.HANDLE,
    /// Manual-reset events backing the two overlapped channels
    /// (manual-reset, the documented-safe kind for
    /// WaitForMultipleObjects + GetOverlappedResult).
    read_event: win.HANDLE,
    write_event: win.HANDLE,
    read_overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED),
    write_overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED),
    read_buf: [read_buffer_bytes]u8 = undefined,
    read_off: usize = 0,
    read_len: usize = 0,
    read_pending: bool = false,
    read_eof: bool = false,
    read_failed: bool = false,
    write_buf: [write_buffer_bytes]u8 = undefined,
    write_pending: bool = false,
    write_failed: bool = false,
    /// Set by `wait` when the process handle signals; from then on the
    /// wait loop steers toward the console close and the manufactured
    /// EOF instead of re-polling an already-signaled handle.
    child_exited: bool = false,
    /// Monotonic stamp of that observation: the console close waits
    /// out a QUIET GRACE past it, because conhost renders the dead
    /// client's final frame asynchronously — a close racing that
    /// render would cut the session's last output off. Bounded (see
    /// `exit_grace_ns`); 0 means the clock was unavailable and the
    /// grace degrades to the quiet-pipe checks alone.
    child_exited_at_ns: u64 = 0,
    /// Monotonic stamp of the last completed read that carried bytes:
    /// the quiet grace measures from the LATER of exit and last
    /// output, so a conhost still emitting (an attached descendant, a
    /// slow final render) keeps pushing the close out instead of being
    /// cut mid-stream at a fixed offset from the exit.
    last_output_at_ns: u64 = 0,
};

/// Process-lifetime backing for `State` (see its doc): the page
/// allocator is thread-safe, never torn down, and each session's block
/// is a handful of pages.
const state_allocator = std.heap.page_allocator;

/// How long past the child's exit — and past the LAST OUTPUT, whichever
/// is later — the console close waits for the output pipe to stay
/// quiet. Not a liveness cost in the common case (the close fires at
/// the first quiet observation past the grace), and bounded either way;
/// the post-close drain still collects anything conhost flushes while
/// tearing down. The residual is stated plainly: a conhost that stays
/// SILENT this long while still holding an unrendered final frame
/// would lose it — the alternative (never closing) strands the session
/// forever, because the pipe never breaks on its own (measured: it
/// stays open indefinitely even after every attached client exited).
const exit_grace_ns: u64 = 100 * std.time.ns_per_ms;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// A live ConPTY session. Same method surface as the POSIX `Pty`;
/// `state` is the shared heap block both copies (io thread, slot)
/// point at, freed by `close`.
pub const Pty = struct {
    state: *State,

    /// Hand out bytes the overlapped read already landed. Returns 0 at
    /// EOF (the manufactured broken-pipe end), WouldBlock while the
    /// armed read is still in flight — the io loop only calls this
    /// after `wait` reported readable, so the common case is a copy.
    pub fn read(self: Pty, buf: []u8) error{ ReadFailed, WouldBlock }!usize {
        const st = self.state;
        if (st.read_len > st.read_off) {
            const take = @min(buf.len, st.read_len - st.read_off);
            @memcpy(buf[0..take], st.read_buf[st.read_off .. st.read_off + take]);
            st.read_off += take;
            return take;
        }
        if (st.read_eof) return 0;
        if (st.read_failed) return error.ReadFailed;
        return error.WouldBlock;
    }

    /// Stage bytes toward the child, one overlapped write in flight.
    /// Accepted bytes are COPIED into the state buffer before the write
    /// arms, so the caller's chunk may be reused immediately; a write
    /// arriving while one pends answers WouldBlock (the POSIX
    /// full-input-buffer EAGAIN) and the caller retries on the next
    /// writable wake.
    pub fn write(self: Pty, bytes: []const u8) error{ WriteFailed, WouldBlock }!usize {
        const st = self.state;
        if (st.write_failed) return error.WriteFailed;
        if (st.write_pending) {
            if (!completeWrite(st)) return error.WouldBlock;
            if (st.write_failed) return error.WriteFailed;
        }
        const take = @min(bytes.len, st.write_buf.len);
        if (take == 0) return 0;
        @memcpy(st.write_buf[0..take], bytes[0..take]);
        _ = win.ResetEvent(st.write_event);
        st.write_overlapped = std.mem.zeroes(win.OVERLAPPED);
        st.write_overlapped.hEvent = st.write_event;
        const ok = win.WriteFile(st.in_write, &st.write_buf, @intCast(take), null, &st.write_overlapped);
        if (ok != 0) return take; // completed synchronously (byte pipes write whole)
        switch (lastError()) {
            win.ERROR_IO_PENDING => {
                st.write_pending = true;
                return take;
            },
            else => {
                st.write_failed = true;
                return error.WriteFailed;
            },
        }
    }

    /// Push a new grid size through `ResizePseudoConsole`; conhost
    /// forwards it to the client as a window-size change (the child
    /// re-queries via the console APIs — Windows' SIGWINCH analog).
    /// Serialized against the io thread's console close: a resize after
    /// the pseudoconsole closed is a silent no-op, exactly like a POSIX
    /// TIOCSWINSZ on a hung-up pty.
    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        const st = self.state;
        const size: win.COORD = .{
            .X = @intCast(@min(@as(u16, if (cols == 0) 1 else cols), 32767)),
            .Y = @intCast(@min(@as(u16, if (rows == 0) 1 else rows), 32767)),
        };
        st.hpc_lock.lock();
        defer st.hpc_lock.unlock();
        if (!st.console_closed) _ = win.ResizePseudoConsole(st.hpc, size);
    }

    /// Terminate the child. Windows has no graceful signal for an
    /// arbitrary console client from outside its console, so both
    /// flavors map to `TerminateProcess` (exit code 1); descendants
    /// still attached to the pseudoconsole fall when the io thread's
    /// reap closes it — the POSIX group-kill's reach, by another
    /// mechanism. `graceful` is accepted for surface parity and
    /// documented as hard here. Safe from any thread (handle identity
    /// is stable; terminating an already-dead process fails
    /// harmlessly).
    pub fn kill(self: Pty, graceful: bool) void {
        _ = graceful;
        _ = win.TerminateProcess(self.state.process, 1);
    }

    /// Reap the child if it has exited: non-blocking process-handle
    /// poll plus exit-code capture. A failed wait or code read reports
    /// the gone-child sentinel (`code -1`), the POSIX ECHILD shape —
    /// never "still running", so the shared kill fences stay exact.
    pub fn reap(self: Pty) ?Exit {
        return switch (win.WaitForSingleObject(self.state.process, 0)) {
            win.WAIT_OBJECT_0 => self.exitCode(),
            win.WAIT_TIMEOUT => null,
            else => .{ .code = -1, .signal = 0 },
        };
    }

    /// Reap the child, blocking until it exits.
    pub fn reapBlocking(self: Pty) Exit {
        if (win.WaitForSingleObject(self.state.process, win.INFINITE) == win.WAIT_OBJECT_0) {
            return self.exitCode();
        }
        return .{ .code = -1, .signal = 0 };
    }

    /// Reap after the output stream ended, never blocking indefinitely
    /// — the shared escalate-then-bound discipline with Windows verbs:
    /// the fast path is the normal case (the manufactured EOF only
    /// arrives after the process handle signaled, so the child is
    /// already reapable); a child still alive is hung up by closing the
    /// pseudoconsole (conhost tears its clients down — the SIGHUP
    /// analog), escalated to `TerminateProcess` within the same bounded
    /// window the POSIX backend uses, and a process the kernel will not
    /// release within the surrender bound is reported ended with the
    /// unknown-code sentinel — its handle still closes at `close`, and
    /// the object self-releases when the process finally dies, so
    /// nothing lingers (no surrendered table on Windows: there is no
    /// zombie to re-poll for).
    pub fn reapEnding(self: Pty) Exit {
        const st = self.state;
        // Every ending tears the console down HERE — on the kill and
        // shutdown paths (where the loop broke before any EOF) this is
        // what fells the descendants still attached to it, at the reap
        // rather than a later retire the host might never drain to. A
        // no-op on the normal path, whose EOF only exists because the
        // console already closed.
        defer drainAndCloseConsole(st);
        if (self.reap()) |exit| return exit;
        // Still running: hang it up like a real terminal closing (the
        // drain keeps the close away from a full pipe).
        drainAndCloseConsole(st);
        const start_ns = clock.monotonicNanoseconds();
        const clock_ok = start_ns != 0;
        var iterations: usize = 0;
        var killed = false;
        while (true) : (iterations += 1) {
            const elapsed_ns = if (clock_ok) clock.monotonicNanoseconds() -% start_ns else iterations * 10 * std.time.ns_per_ms;
            if (elapsed_ns >= 500 * std.time.ns_per_ms) break;
            if (win.WaitForSingleObject(st.process, 10) == win.WAIT_OBJECT_0) return self.exitCode();
            if (!killed and elapsed_ns >= 200 * std.time.ns_per_ms) {
                killed = true;
                _ = win.TerminateProcess(st.process, 1);
            }
        }
        if (!killed) _ = win.TerminateProcess(st.process, 1);
        // The surrender bound: TerminateProcess is asynchronous, and a
        // process wedged in a kernel call dies only when that call
        // returns — the exit event must reach the app regardless.
        if (win.WaitForSingleObject(st.process, 5000) == win.WAIT_OBJECT_0) return self.exitCode();
        return .{ .code = -1, .signal = 0 };
    }

    /// Close every handle the session owns and free the shared state.
    /// The io thread must be done (the retire path's `io_done` proof):
    /// a still-armed overlapped read or write is cancelled and REAPED
    /// here before the buffers it targets are freed — freeing state
    /// under in-flight kernel I/O would hand the kernel a dangling
    /// buffer.
    pub fn close(self: Pty) void {
        const st = self.state;
        if (st.read_pending) {
            _ = win.CancelIoEx(st.out_read, &st.read_overlapped);
            var n: win.DWORD = 0;
            _ = win.GetOverlappedResult(st.out_read, &st.read_overlapped, &n, 1);
            st.read_pending = false;
        }
        if (st.write_pending) {
            _ = win.CancelIoEx(st.in_write, &st.write_overlapped);
            var n: win.DWORD = 0;
            _ = win.GetOverlappedResult(st.in_write, &st.write_overlapped, &n, 1);
            st.write_pending = false;
        }
        closeConsole(st);
        // The close fallback may already have broken the read end (its
        // INVALID sentinel); everything else closes exactly once here.
        if (st.out_read != win.INVALID_HANDLE_VALUE) _ = win.CloseHandle(st.out_read);
        _ = win.CloseHandle(st.in_write);
        _ = win.CloseHandle(st.read_event);
        _ = win.CloseHandle(st.write_event);
        _ = win.CloseHandle(st.process);
        state_allocator.destroy(st);
    }

    /// Windows has no exec self-pipe: `CreateProcessW`'s verdict is
    /// synchronous, so a spawn that returned can never surface a late
    /// exec failure.
    pub fn lateExecFailure(self: Pty) bool {
        _ = self;
        return false;
    }

    fn exitCode(self: Pty) Exit {
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(self.state.process, &code) == 0) {
            return .{ .code = -1, .signal = 0 };
        }
        // The DWORD bit-cast keeps NTSTATUS endings honest (a crash's
        // 0xC0000005 arrives as its negative i32 self, never a
        // truncated small number). Signals do not exist here: 0 always.
        return .{ .code = @bitCast(code), .signal = 0 };
    }
};

/// Initiate the console close, then discard-drain the output pipe
/// (bounded) so a conhost blocked mid-write — its own teardown flush,
/// or a client's CTRL_CLOSE handler emitting past the pipe capacity —
/// always finds a reader and finishes closing. Used on the paths where
/// the io loop stopped reading before any EOF (kill, shutdown,
/// spawn-failure wind-down); the bound keeps a still-writing attached
/// descendant from stranding the reap forever (the detached closer
/// finishes whenever conhost does). Discarding is the shared teardown
/// discipline: these paths already deliver no further output.
/// io-thread only (it owns the read machinery).
fn drainAndCloseConsole(st: *State) void {
    // Drain to a quiet moment FIRST: if the detached closer cannot
    // spawn, `closeConsole`'s inline fallback runs on this reader
    // thread, and it must never meet a full pipe (the documented
    // ClosePseudoConsole wait). With the pipe just emptied, only a
    // writer refilling 128 KiB inside the fallback's window could
    // block it — the OOM-corner residual the closeConsole doc names.
    drainDiscard(st, true);
    closeConsole(st);
    // Then keep draining while conhost tears down — its final flush,
    // or CTRL_CLOSE writers among surviving descendants — until the
    // broken pipe or the bound (the detached closer finishes whenever
    // conhost does).
    drainDiscard(st, false);
    st.read_off = 0;
    st.read_len = 0;
}

/// Bounded discard-drain of the output pipe. `stop_on_quiet` stops at
/// the first observation of an idle armed read over an empty pipe;
/// otherwise only EOF, a read failure, or the bound ends it.
fn drainDiscard(st: *State, stop_on_quiet: bool) void {
    const start_ns = clock.monotonicNanoseconds();
    const clock_ok = start_ns != 0;
    var iterations: usize = 0;
    while (!st.read_eof and !st.read_failed) : (iterations += 1) {
        const elapsed_ns = if (clock_ok) clock.monotonicNanoseconds() -% start_ns else iterations * 10 * std.time.ns_per_ms;
        if (elapsed_ns >= 400 * std.time.ns_per_ms) break;
        // Discard whatever the last completion or a sync arm landed.
        st.read_off = 0;
        st.read_len = 0;
        armRead(st);
        if (st.read_len > 0) continue; // sync data: keep draining
        if (!st.read_pending) continue; // spurious: re-arm next round
        if (win.WaitForSingleObject(st.read_event, 10) == win.WAIT_OBJECT_0) {
            completeRead(st);
            continue;
        }
        if (!stop_on_quiet) continue;
        var avail: win.DWORD = 0;
        if (win.PeekNamedPipe(st.out_read, null, 0, null, &avail, null) == 0 or avail == 0) return;
    }
}

/// Close the pseudoconsole exactly once (idempotent, lock-guarded
/// against `resize`). The blocking call itself runs on a DETACHED
/// helper thread: `ClosePseudoConsole` waits for conhost, and conhost
/// may be blocked writing into the output pipe (a client's CTRL_CLOSE
/// handler can emit more than the pipe holds), so the reader thread
/// must stay free to keep draining — closing inline on the reader is
/// the documented ClosePseudoConsole deadlock. The helper captures
/// only the HPCON VALUE (the object the call consumes; `resize` is
/// fenced off by `console_closed` under the lock), never the session
/// state, so it needs no join and cannot dangle.
///
/// If the thread cannot spawn (resource exhaustion), the fallback
/// BREAKS THE OUTPUT PIPE first — cancel and reap the armed read so
/// its buffer is quiescent, mark the manufactured EOF, close the read
/// handle — and only then closes inline: with the pipe broken,
/// conhost's writes fail fast instead of filling it, so the inline
/// call cannot meet the deadlock (the cost is any unflushed tail,
/// which the thread-exhausted process was about to lose anyway).
/// io-thread only (the fallback owns the read machinery).
fn closeConsole(st: *State) void {
    st.hpc_lock.lock();
    defer st.hpc_lock.unlock();
    if (st.console_closed) return;
    st.console_closed = true;
    const thread = std.Thread.spawn(.{}, closeConsoleThreadMain, .{st.hpc}) catch {
        if (st.read_pending) {
            _ = win.CancelIoEx(st.out_read, &st.read_overlapped);
            var n: win.DWORD = 0;
            _ = win.GetOverlappedResult(st.out_read, &st.read_overlapped, &n, 1);
            st.read_pending = false;
        }
        st.read_eof = true;
        _ = win.CloseHandle(st.out_read);
        st.out_read = win.INVALID_HANDLE_VALUE;
        win.ClosePseudoConsole(st.hpc);
        return;
    };
    thread.detach();
}

fn closeConsoleThreadMain(hpc: win.HPCON) void {
    win.ClosePseudoConsole(hpc);
}

/// Reap a completed overlapped write (non-blocking). True when the
/// write is no longer pending (completed or failed — `write_failed`
/// carries which).
fn completeWrite(st: *State) bool {
    var n: win.DWORD = 0;
    if (win.GetOverlappedResult(st.in_write, &st.write_overlapped, &n, 0) != 0) {
        st.write_pending = false;
        return true;
    }
    if (lastError() == win.ERROR_IO_INCOMPLETE) return false;
    st.write_pending = false;
    st.write_failed = true;
    return true;
}

/// Reap a completed overlapped read (non-blocking): data lands in the
/// state buffer, a broken pipe becomes the EOF flag (the POSIX
/// EIO-after-hangup normalization), anything else marks the stream
/// failed.
fn completeRead(st: *State) void {
    var n: win.DWORD = 0;
    if (win.GetOverlappedResult(st.out_read, &st.read_overlapped, &n, 0) != 0) {
        st.read_pending = false;
        st.read_off = 0;
        st.read_len = n;
        if (n > 0) st.last_output_at_ns = clock.monotonicNanoseconds();
        return;
    }
    switch (lastError()) {
        win.ERROR_IO_INCOMPLETE => {},
        win.ERROR_BROKEN_PIPE, win.ERROR_PIPE_NOT_CONNECTED, win.ERROR_HANDLE_EOF => {
            st.read_pending = false;
            st.read_eof = true;
        },
        else => {
            st.read_pending = false;
            st.read_failed = true;
        },
    }
}

/// Arm the overlapped read if nothing is buffered, pending, or
/// terminal. A synchronous completion lands its bytes immediately.
fn armRead(st: *State) void {
    if (st.read_pending or st.read_eof or st.read_failed) return;
    if (st.read_len > st.read_off) return;
    st.read_off = 0;
    st.read_len = 0;
    _ = win.ResetEvent(st.read_event);
    st.read_overlapped = std.mem.zeroes(win.OVERLAPPED);
    st.read_overlapped.hEvent = st.read_event;
    const ok = win.ReadFile(st.out_read, &st.read_buf, @intCast(read_buffer_bytes), null, &st.read_overlapped);
    if (ok != 0) {
        var n: win.DWORD = 0;
        if (win.GetOverlappedResult(st.out_read, &st.read_overlapped, &n, 0) != 0) {
            st.read_off = 0;
            st.read_len = n;
            // Synchronous completions push the exit quiet grace out
            // exactly like event-delivered ones.
            if (n > 0) st.last_output_at_ns = clock.monotonicNanoseconds();
        }
        return;
    }
    switch (lastError()) {
        win.ERROR_IO_PENDING => st.read_pending = true,
        win.ERROR_BROKEN_PIPE, win.ERROR_PIPE_NOT_CONNECTED, win.ERROR_HANDLE_EOF => st.read_eof = true,
        else => st.read_failed = true,
    }
}

/// The quiet-moment console close after child exit (see the file doc):
/// only behind an ARMED, still-silent read (a completed read means data
/// to deliver first; a visible backlog means conhost is mid-burst), so
/// `ClosePseudoConsole` can never meet the full pipe that wedges older
/// conhosts.
fn maybeCloseConsole(st: *State) void {
    if (st.console_closed or !st.read_pending) return;
    // The quiet grace: give conhost its beat to render the dead
    // client's final frame — measured from the LATER of the exit and
    // the last delivered output — before manufacturing EOF.
    const quiet_since = @max(st.child_exited_at_ns, st.last_output_at_ns);
    if (quiet_since != 0) {
        const now = clock.monotonicNanoseconds();
        if (now != 0 and now -% quiet_since < exit_grace_ns) return;
    }
    if (win.WaitForSingleObject(st.read_event, 0) == win.WAIT_OBJECT_0) return;
    var avail: win.DWORD = 0;
    if (win.PeekNamedPipe(st.out_read, null, 0, null, &avail, null) != 0 and avail != 0) return;
    // Re-probe the read event AFTER the peek: a completion landing
    // between the two hands its bytes to the armed read — the pipe
    // peeks empty exactly then — and means conhost just started
    // emitting, so the grace must restart rather than the console
    // close. (The residual sliver between this probe and the close is
    // covered by conhost's flush-on-close plus the post-close drain.)
    if (win.WaitForSingleObject(st.read_event, 0) == win.WAIT_OBJECT_0) return;
    closeConsole(st);
}

/// Block until the session is readable, writable, or nudged — the
/// POSIX `poll` loop restated over WaitForMultipleObjects. The process
/// handle rides the wait set until the child exits; from then on the
/// loop steers the console close that manufactures EOF. A caller
/// wanting neither direction (a parked reader) waits on the nudge
/// event alone, the shared parked-reader contract.
pub fn wait(transport: Pty, nudge_fd: c_int, want_read: bool, want_write: bool) Ready {
    const st = transport.state;
    const nudge_handle = fdToHandle(nudge_fd);
    while (true) {
        var ready: Ready = .{};
        if (want_write) {
            if (st.write_pending) _ = completeWrite(st);
            if (!st.write_pending) ready.writable = true;
        }
        if (want_read) {
            if (st.read_pending) completeRead(st);
            armRead(st);
            if (st.read_len > st.read_off or st.read_eof or st.read_failed) {
                ready.readable = true;
            } else if (st.child_exited) {
                maybeCloseConsole(st);
            }
        }
        if (ready.readable or ready.writable) {
            // Collect a pending nudge without blocking (the POSIX poll
            // reports all readiness at once; auto-reset consumes it).
            if (win.WaitForSingleObject(nudge_handle, 0) == win.WAIT_OBJECT_0) ready.nudged = true;
            return ready;
        }
        var handles: [4]win.HANDLE = undefined;
        var count: win.DWORD = 1;
        handles[0] = nudge_handle;
        var read_index: win.DWORD = 0;
        var process_index: win.DWORD = 0;
        var write_index: win.DWORD = 0;
        if (want_read and st.read_pending) {
            handles[count] = st.read_event;
            read_index = count;
            count += 1;
        }
        if (want_read and !st.child_exited) {
            handles[count] = st.process;
            process_index = count;
            count += 1;
        }
        if (want_write and st.write_pending) {
            handles[count] = st.write_event;
            write_index = count;
            count += 1;
        }
        // Between the child's exit and the console close the loop polls
        // on a short beat instead of blocking: the quiet grace has no
        // waitable handle of its own, and conhost's final render is
        // what the beat is listening for.
        const timeout: win.DWORD = if (want_read and st.child_exited and !st.console_closed)
            10
        else
            win.INFINITE;
        const r = win.WaitForMultipleObjects(count, &handles, 0, timeout);
        if (r == win.WAIT_TIMEOUT) continue;
        if (r == win.WAIT_FAILED or r >= win.WAIT_OBJECT_0 + count) return .{};
        const index = r - win.WAIT_OBJECT_0;
        if (index == 0) return .{ .nudged = true };
        if (index == process_index) {
            // Already-signaled handles return immediately, so the exit
            // flag must stick before the next iteration rebuilds the
            // wait set without it.
            st.child_exited = true;
            st.child_exited_at_ns = clock.monotonicNanoseconds();
            continue;
        }
        // A read or write completion: fold it in and let the top of
        // the loop report the resulting readiness.
        if (index == read_index) {
            completeRead(st);
            continue;
        }
        if (index == write_index) {
            _ = completeWrite(st);
            continue;
        }
        return .{};
    }
}

/// One spawn: resolve argv[0] through the caller's PATH policy, build
/// the UTF-16 command line and environment block, open the overlapped
/// pipe pair, create the pseudoconsole, and launch the child attached
/// to it. Synchronous verdicts throughout — `CreateProcessW` is the
/// exec, so there is no self-pipe and no late-failure carry.
pub fn spawn(gpa: std.mem.Allocator, options: SpawnOptions) Error!Pty {
    if (comptime !is_windows) return error.PtyUnsupported;
    if (options.argv.len == 0 or options.argv.len > pty.max_argv) return error.PtyArgvInvalid;
    for (options.argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.PtyArgvInvalid;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = resolveExecutable(arena, options.argv[0], options.env) orelse
        return error.PtyCommandNotFound;
    const is_batch = endsWithIgnoreCase(resolved, ".cmd") or endsWithIgnoreCase(resolved, ".bat");
    var interpreter: []const u8 = resolved;
    if (is_batch) {
        // A batch target's command line is REPARSED by cmd.exe with
        // its own metacharacter grammar, which no quoting scheme can
        // neutralize losslessly (`%` expands inside and outside quotes,
        // `^` escapes outside them, `!` follows the child's own
        // delayed-expansion setting) — `safe&whoami` as one argument
        // would splice a second command, and a `%X%` in the SCRIPT
        // PATH itself would expand before cmd resolves it. Bytes the
        // cmd grammar can reinterpret refuse the spawn whole (the
        // argv-NUL teaching applied, and the mainstream standard-
        // library answer to batch argument injection): mutating them
        // would run a different command line than the caller declared.
        // The restriction is part of the documented Windows semantics.
        if (std.mem.indexOfAny(u8, resolved, batch_hostile_bytes) != null) return error.PtyArgvInvalid;
        for (options.argv[1..]) |arg| {
            if (std.mem.indexOfAny(u8, arg, batch_hostile_bytes) != null) return error.PtyArgvInvalid;
        }
        // The command processor is EXPLICIT — resolved through the same
        // caller-env PATH policy as any spawn — and invoked with /d, so
        // a machine's AutoRun registry entries cannot splice commands
        // around (or in place of) the requested script the way they
        // would under CreateProcess's implicit batch rewrite.
        interpreter = resolveExecutable(arena, "cmd.exe", options.env) orelse
            return error.PtyCommandNotFound;
    }
    const command_line_w = buildCommandLineW(arena, interpreter, resolved, options.argv, is_batch) catch |err| switch (err) {
        error.InvalidWtf8 => return error.PtyArgvInvalid,
        error.OutOfMemory => return error.PtyEnvironTooLarge,
    };
    // The application name always rides its own argument (never the
    // command line's MAX_PATH-bound module token, so a long-path .exe
    // still starts; cmd itself imposes the MAX_PATH bound on scripts):
    // the resolved executable directly, or the explicit interpreter
    // for a batch target.
    const app_name_w: [*:0]const u16 = app: {
        const len = std.unicode.calcWtf16LeLen(interpreter) catch return error.PtyArgvInvalid;
        const wide = arena.allocSentinel(u16, len, 0) catch return error.PtyEnvironTooLarge;
        _ = std.unicode.wtf8ToWtf16Le(wide, interpreter) catch return error.PtyArgvInvalid;
        break :app wide.ptr;
    };
    const env_block_w = buildEnvironmentBlockW(arena, options.env, options.term) catch |err| switch (err) {
        error.InvalidWtf8 => return error.PtyEnvironTooLarge,
        error.OutOfMemory => return error.PtyEnvironTooLarge,
    };

    // The pipe pair. Parent ends are overlapped named-pipe servers (the
    // one Windows pipe flavor that can join an event wait); the conhost
    // ends are plain synchronous clients, non-inheritable —
    // CreatePseudoConsole duplicates them into conhost, so nothing here
    // rides handle inheritance and the POSIX CLOEXEC choreography has
    // no analog to need.
    const out_pipe = createOverlappedPipe(.inbound) catch return error.PtyOpenFailed;
    const in_pipe = createOverlappedPipe(.outbound) catch {
        _ = win.CloseHandle(out_pipe.server);
        _ = win.CloseHandle(out_pipe.client);
        return error.PtyOpenFailed;
    };

    const size: win.COORD = .{
        .X = @intCast(@min(@as(u16, if (options.cols == 0) 80 else options.cols), 32767)),
        .Y = @intCast(@min(@as(u16, if (options.rows == 0) 24 else options.rows), 32767)),
    };
    var hpc: win.HPCON = undefined;
    // flags = 0 on purpose: no PSEUDOCONSOLE_INHERIT_CURSOR (see the
    // file doc — inheriting would make conhost await a DSR answer).
    const hr = win.CreatePseudoConsole(size, in_pipe.client, out_pipe.client, 0, &hpc);
    // The conhost ends are duplicated by CreatePseudoConsole; the
    // originals close now either way.
    _ = win.CloseHandle(in_pipe.client);
    _ = win.CloseHandle(out_pipe.client);
    if (hr < 0) {
        _ = win.CloseHandle(out_pipe.server);
        _ = win.CloseHandle(in_pipe.server);
        return error.PtyOpenFailed;
    }

    // Attribute list carrying exactly the pseudoconsole attribute.
    var attr_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = arena.alignedAlloc(u8, .of(usize), attr_size) catch {
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyEnvironTooLarge;
    };
    if (win.InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0) {
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyOpenFailed;
    }
    defer win.DeleteProcThreadAttributeList(attr_buf.ptr);
    if (win.UpdateProcThreadAttribute(
        attr_buf.ptr,
        0,
        win.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpc,
        @sizeOf(win.HPCON),
        null,
        null,
    ) == 0) {
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyOpenFailed;
    }

    var siex = std.mem.zeroes(win.STARTUPINFOEXW);
    siex.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
    siex.lpAttributeList = attr_buf.ptr;
    // STARTF_USESTDHANDLES with NULL handles, deliberately: without
    // it, CreateProcess DUPLICATES the parent's std handles into a
    // console child whenever they do not reference a console (a parent
    // under sshd or CI holds pipes there), and the child's stdio then
    // bypasses the pseudoconsole entirely — output lands on the
    // parent's pipes, not in this transport. Explicit null std handles
    // block that duplication, and console initialization in the child
    // binds the empty slots to its console: the pseudoconsole. (The
    // same choice every ConPTY-hosting terminal makes.)
    siex.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES;
    var pi = std.mem.zeroes(win.PROCESS_INFORMATION);
    // bInheritHandles = FALSE: the child's stdio comes from the
    // pseudoconsole, not from inherited handles — the recommended
    // ConPTY shape, and the reason no parent-side descriptor can leak
    // into the child at all.
    if (win.CreateProcessW(
        app_name_w,
        command_line_w.ptr,
        null,
        null,
        0,
        win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_UNICODE_ENVIRONMENT,
        env_block_w.ptr,
        null,
        &siex.StartupInfo,
        &pi,
    ) == 0) {
        const code = lastError();
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return switch (code) {
            win.ERROR_FILE_NOT_FOUND,
            win.ERROR_PATH_NOT_FOUND,
            win.ERROR_ACCESS_DENIED,
            win.ERROR_BAD_EXE_FORMAT,
            win.ERROR_INVALID_NAME,
            win.ERROR_DIRECTORY,
            => error.PtyCommandNotFound,
            else => error.PtyForkFailed,
        };
    }
    _ = win.CloseHandle(pi.hThread);

    const read_event = win.CreateEventW(null, 1, 0, null) orelse {
        _ = win.TerminateProcess(pi.hProcess, 1);
        _ = win.CloseHandle(pi.hProcess);
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyOpenFailed;
    };
    const write_event = win.CreateEventW(null, 1, 0, null) orelse {
        _ = win.CloseHandle(read_event);
        _ = win.TerminateProcess(pi.hProcess, 1);
        _ = win.CloseHandle(pi.hProcess);
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyOpenFailed;
    };
    const state = state_allocator.create(State) catch {
        _ = win.CloseHandle(read_event);
        _ = win.CloseHandle(write_event);
        _ = win.TerminateProcess(pi.hProcess, 1);
        _ = win.CloseHandle(pi.hProcess);
        failSpawnCleanup(hpc, out_pipe.server, in_pipe.server);
        return error.PtyEnvironTooLarge;
    };
    state.* = .{
        .hpc = hpc,
        .process = pi.hProcess,
        .out_read = out_pipe.server,
        .in_write = in_pipe.server,
        .read_event = read_event,
        .write_event = write_event,
    };
    return .{ .state = state };
}

/// Spawn-failure cleanup. The pipe ends close BEFORE the
/// pseudoconsole, deliberately: a fast child (already terminated by
/// the failing branch) may have filled the output pipe, and a conhost
/// blocked mid-write would block `ClosePseudoConsole` behind it —
/// breaking the pipe first turns those writes into immediate failures.
/// The close itself still rides a detached helper: conhost's own
/// client shutdown can take its OS-bounded beat (a terminated-but-
/// wedged child), and a spawn failure must deliver its verdict to the
/// loop thread now, not after that beat. Inline on helper-spawn
/// failure — with the pipes already broken, the inline call waits only
/// on that same OS-bounded shutdown, never a full pipe.
fn failSpawnCleanup(hpc: win.HPCON, out_server: win.HANDLE, in_server: win.HANDLE) void {
    _ = win.CloseHandle(out_server);
    _ = win.CloseHandle(in_server);
    const thread = std.Thread.spawn(.{}, closeConsoleThreadMain, .{hpc}) catch {
        win.ClosePseudoConsole(hpc);
        return;
    };
    thread.detach();
}

/// Windows process objects self-release; there is no zombie table to
/// re-poll (see the file doc). Kept for seam parity.
pub fn reapSurrendered() void {}

/// The io thread's nudge, event-shaped: one auto-reset event stands in
/// for the POSIX self-pipe (SetEvent coalesces exactly like a full
/// pipe's dropped byte; the wait's wake consumes it, so `drainNudges`
/// has nothing to drain). Two distinct handles to the one object are
/// returned so the caller's [read end, write end] close discipline
/// stays symmetrical.
pub fn pipePair() Error![2]c_int {
    if (comptime !is_windows) return error.PtyUnsupported;
    const event = win.CreateEventW(null, 0, 0, null) orelse return error.PtyOpenFailed;
    const me = win.GetCurrentProcess();
    var dup: win.HANDLE = undefined;
    if (win.DuplicateHandle(me, event, me, &dup, 0, 0, win.DUPLICATE_SAME_ACCESS) == 0) {
        _ = win.CloseHandle(event);
        return error.PtyOpenFailed;
    }
    return .{ handleToFd(dup), handleToFd(event) };
}

pub fn nudge(fd: c_int) void {
    if (fd == -1) return;
    _ = win.SetEvent(fdToHandle(fd));
}

pub fn drainNudges(fd: c_int) void {
    // Auto-reset: the wait that reported the nudge already consumed it.
    _ = fd;
}

pub fn closeFd(fd: c_int) void {
    if (fd == -1 or fd == 0) return;
    _ = win.CloseHandle(fdToHandle(fd));
}

/// Snapshot the LIVE process environment into the transport's env-list
/// shape — the Windows half of the effects layer's inherit-the-host
/// policy (`GetEnvironmentStringsW` is the atomic snapshot; reading the
/// PEB block raw would race concurrent SetEnvironmentVariable calls).
/// WTF-16 entries decode to WTF-8 into `bytes`; `TERM` is skipped (the
/// transport injects its own, and Windows env names are
/// case-insensitive, so the skip is too). The hidden `=X:=...`
/// per-drive-directory entries CreateProcess plumbs around ride along
/// verbatim (name `=X:`, and they sort ahead of every letter, the
/// block position Windows expects) so a child's drive-relative path
/// state matches its parent's. Over-bound environments return null —
/// the same loud whole-or-nothing refusal the POSIX flatten teaches.
pub fn captureGlobalEnviron(buffer: []EnvVar, bytes: []u8) ?[]const EnvVar {
    if (comptime !is_windows) return null;
    const block = win.GetEnvironmentStringsW() orelse return null;
    defer _ = win.FreeEnvironmentStringsW(block);
    var count: usize = 0;
    var used: usize = 0;
    var index: usize = 0;
    while (block[index] != 0) {
        const start = index;
        while (block[index] != 0) : (index += 1) {}
        const entry_w = block[start..index];
        index += 1; // past the terminator, onto the next entry
        // Decode into the byte pool (WTF-16 -> WTF-8 is at most 3 bytes
        // per code unit; check before converting so a long tail entry
        // cannot overrun).
        if (used + entry_w.len * 3 > bytes.len) {
            if (used + std.unicode.calcWtf8Len(entry_w) > bytes.len) return null;
        }
        const len = std.unicode.wtf16LeToWtf8(bytes[used..], entry_w);
        const entry = bytes[used .. used + len];
        // A leading '=' names the hidden per-drive-directory entries
        // ("=C:=C:\dir"): their name is everything through the drive
        // ("=C:"), so the split looks past the first byte for them.
        const search_from: usize = if (entry.len > 0 and entry[0] == '=') 1 else 0;
        const eq = search_from + (std.mem.indexOfScalar(u8, entry[search_from..], '=') orelse continue);
        const name = entry[0..eq];
        if (asciiEqlIgnoreCase(name, "TERM")) continue;
        if (count == buffer.len) return null;
        if (used + len > pty.max_env_bytes) return null;
        buffer[count] = .{ .name = name, .value = entry[eq + 1 ..] };
        count += 1;
        used += len;
    }
    return buffer[0..count];
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// Resolve argv[0] to an executable path, the POSIX resolver's policy
/// with Windows spelling: a name carrying any path separator (or a
/// drive) is probed as given; a bare name walks the CALLER-SUPPLIED
/// env's PATH (`;`-separated, quoted components unwrapped) — never the
/// process's own PATH, and never the current directory (the classic
/// Windows CWD-first search is a planted-binary hazard; an app that
/// wants it says `.\name`). Each candidate is tried as spelled and
/// with the conventional executable extensions appended — the PATHEXT
/// idea reduced to the four kinds `CreateProcessW` itself can start.
fn resolveExecutable(arena: std.mem.Allocator, arg0: []const u8, env: ?[]const EnvVar) ?[]const u8 {
    const has_separator = std.mem.indexOfAny(u8, arg0, "/\\") != null or
        (arg0.len >= 2 and arg0[1] == ':');
    if (has_separator) {
        return probeWithExtensions(arena, "", arg0);
    }
    // Sized for two Windows-directory roots (MAX_PATH each, 3-byte
    // WTF-8 worst case) plus the joining literal.
    var fallback_path_buf: [2 * 260 * 3 + 16]u8 = undefined;
    const path = lookupEnvIgnoreCase(env, "PATH") orelse systemPathFallback(env, &fallback_path_buf);
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |raw_component| {
        // Quoted PATH components are a Windows convention; the quotes
        // are wrapper, not path. Empty components are SKIPPED, never
        // "the current directory" (the deliberate no-CWD policy above).
        const component = std.mem.trim(u8, raw_component, "\"");
        if (component.len == 0) continue;
        if (probeWithExtensions(arena, component, arg0)) |found| return found;
    }
    return null;
}

/// The PATH stand-in when the caller's env carries none: the system
/// directories under the real Windows root — the env's own
/// `SystemRoot`/`windir` first, then the OS's answer
/// (`GetWindowsDirectoryW`, so an install under D:\Windows still
/// resolves bare names), and the conventional literal only when both
/// fail.
fn systemPathFallback(env: ?[]const EnvVar, buf: []u8) []const u8 {
    // The Windows directory is bounded at MAX_PATH (260) UTF-16 units;
    // WTF-8 needs at most 3 bytes per unit.
    var os_root_buf: [260 * 3]u8 = undefined;
    const root = root: {
        if (lookupEnvIgnoreCase(env, "SystemRoot")) |value| break :root value;
        if (lookupEnvIgnoreCase(env, "windir")) |value| break :root value;
        if (comptime is_windows) {
            var wide: [260]u16 = undefined;
            const len = win.GetWindowsDirectoryW(&wide, @intCast(wide.len));
            if (len > 0 and len < wide.len) {
                const decoded_len = std.unicode.wtf16LeToWtf8(&os_root_buf, wide[0..len]);
                break :root os_root_buf[0..decoded_len];
            }
        }
        break :root "C:\\Windows";
    };
    return std.fmt.bufPrint(buf, "{s}\\System32;{s}", .{ root, root }) catch "C:\\Windows\\System32;C:\\Windows";
}

/// The executable-extension allowlist for EXTENSION-LESS names: the
/// runnable suffixes first (`.exe`, `.cmd`, `.bat`, `.com` — the
/// shapes the spawn can start; `.cmd`/`.bat` route through the
/// explicit `cmd.exe /d /s /c` form), the bare spelling LAST — so a
/// same-named plain file next to a real `tool.exe` or `tool.cmd`
/// cannot mask them (the CreateProcess/PATHEXT ordering, where an
/// extension-less name means its runnable suffixes before itself).
const executable_extensions = [_][]const u8{ ".exe", ".cmd", ".bat", ".com", "" };

fn probeWithExtensions(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    // A name that already carries an extension is probed AS SPELLED
    // only: appending further suffixes would let a co-located
    // `tool.cmd.exe` answer for a missing `tool.cmd` — the
    // CreateProcess convention (.exe joins extension-less names only),
    // kept for the whole allowlist.
    const extensions: []const []const u8 = if (hasExtension(name)) &.{""} else &executable_extensions;
    for (extensions) |ext| {
        const candidate = if (dir.len == 0)
            std.fmt.allocPrint(arena, "{s}{s}", .{ name, ext }) catch return null
        else
            std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, ext }) catch return null;
        if (executableAt(arena, candidate)) return candidate;
    }
    return null;
}

/// Existence-and-not-a-directory probe (Windows has no X_OK; being a
/// readable file is the closest honest analog, and `CreateProcessW`
/// delivers the final verdict synchronously either way). The wide
/// copy sizes to the CANDIDATE — a PATH component can outgrow any
/// fixed stack buffer (`\\?\` prefixed directories), and the arena
/// already owns the spawn's transient conversions.
fn executableAt(arena: std.mem.Allocator, path: []const u8) bool {
    if (comptime !is_windows) return false;
    const len = std.unicode.calcWtf16LeLen(path) catch return false;
    const wide = arena.allocSentinel(u16, len, 0) catch return false;
    _ = std.unicode.wtf8ToWtf16Le(wide, path) catch return false;
    const attrs = win.GetFileAttributesW(wide.ptr);
    if (attrs == win.INVALID_FILE_ATTRIBUTES) return false;
    return attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// Whether the LAST PATH COMPONENT carries an extension (a leading dot
/// alone names a hidden-style file, not an extension).
fn hasExtension(name: []const u8) bool {
    const base_start = if (std.mem.lastIndexOfAny(u8, name, "/\\:")) |index| index + 1 else 0;
    const base = name[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    return dot != 0;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return asciiEqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn lookupEnvIgnoreCase(env: ?[]const EnvVar, name: []const u8) ?[]const u8 {
    const list = env orelse return null;
    for (list) |entry| {
        if (asciiEqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

/// Bytes cmd.exe's reparse can reinterpret inside a batch command
/// line: command splicers, redirections, escapes, variable expansion,
/// quotes (cmd's quote rules differ from the CRT's), and line breaks.
const batch_hostile_bytes = "&|<>^%!\"\r\n";

/// Build the mutable UTF-16 command line `CreateProcessW` parses.
///
/// Direct executables: the first token is the CALLER's argv[0]
/// spelling (the module comes from `lpApplicationName`, so a multicall
/// binary observes the name it was invoked by — POSIX argv[0] parity),
/// and arguments use the standard CommandLineToArgvW-inverse quoting,
/// so a conforming child recovers each byte-exactly.
///
/// Batch targets: `"<cmd.exe>" /d /s /c ""<script>" "arg"..."` — the
/// explicit, AutoRun-disabled interpreter form (/s pins the standard
/// quote treatment; the outer quote pair is what /s strips). Every
/// argument is ALWAYS quoted — a bare `foo)` token could close a block
/// in cmd's reparse, and quotes make delimiters and grouping bytes
/// literal — with NO backslash doubling: cmd reads backslashes
/// literally, so the CRT's trailing-run doubling would hand a script
/// `\\` where the caller said `\`. (The bytes quoting cannot make
/// literal were refused at admission.)
fn buildCommandLineW(
    arena: std.mem.Allocator,
    interpreter: []const u8,
    resolved: []const u8,
    argv: []const []const u8,
    is_batch: bool,
) (error{ InvalidWtf8, OutOfMemory })![:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    try line.append(arena, '"');
    try line.appendSlice(arena, if (is_batch) interpreter else argv[0]);
    try line.append(arena, '"');
    if (is_batch) {
        try line.appendSlice(arena, " /d /s /c \"\"");
        try line.appendSlice(arena, resolved);
        try line.append(arena, '"');
    }
    for (argv[1..]) |arg| {
        try line.append(arena, ' ');
        if (is_batch) {
            try line.append(arena, '"');
            try line.appendSlice(arena, arg);
            try line.append(arena, '"');
            continue;
        }
        try appendQuotedArg(arena, &line, arg);
    }
    if (is_batch) try line.append(arena, '"');
    const wide_len = std.unicode.calcWtf16LeLen(line.items) catch return error.InvalidWtf8;
    const wide = try arena.allocSentinel(u16, wide_len, 0);
    _ = try std.unicode.wtf8ToWtf16Le(wide, line.items);
    return wide;
}

/// The CommandLineToArgvW inverse: quote when the argument is empty or
/// carries a space, tab, or quote; inside quotes, N backslashes before
/// a quote double to 2N (+1 with the escaped quote), and a trailing
/// run doubles before the closing quote.
fn appendQuotedArg(arena: std.mem.Allocator, line: *std.ArrayList(u8), arg: []const u8) error{OutOfMemory}!void {
    const needs_quotes = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
    if (!needs_quotes) {
        try line.appendSlice(arena, arg);
        return;
    }
    try line.append(arena, '"');
    var backslashes: usize = 0;
    for (arg) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        if (byte == '"') {
            try line.appendNTimes(arena, '\\', backslashes * 2 + 1);
            try line.append(arena, '"');
        } else {
            try line.appendNTimes(arena, '\\', backslashes);
            try line.append(arena, byte);
        }
        backslashes = 0;
    }
    try line.appendNTimes(arena, '\\', backslashes * 2);
    try line.append(arena, '"');
}

/// Build the UTF-16 `name=value\0...\0\0` environment block: the
/// caller's env (or nothing) plus the injected/replacing `TERM` — the
/// exact POSIX `buildEnvpZ` policy — sorted with the case-insensitive
/// ordinal order the CreateProcessW documentation requires of Unicode
/// blocks. `TERM` matching is case-insensitive here because Windows
/// environment names are.
fn buildEnvironmentBlockW(
    arena: std.mem.Allocator,
    env: ?[]const EnvVar,
    term: []const u8,
) (error{ InvalidWtf8, OutOfMemory })![:0]u16 {
    const list = env orelse &[_]EnvVar{};
    if (list.len > pty.max_env_entries) return error.OutOfMemory;
    var entries: [pty.max_env_entries + 1]EnvVar = undefined;
    var count: usize = 0;
    var total_bytes: usize = 0;
    var has_term = false;
    for (list) |entry| {
        // NUL-bearing names or values would silently terminate the
        // block early at the UTF-16 boundary: reject via the
        // whole-or-nothing env error, the argv-NUL teaching applied.
        if (std.mem.indexOfScalar(u8, entry.name, 0) != null or
            std.mem.indexOfScalar(u8, entry.value, 0) != null)
        {
            return error.InvalidWtf8;
        }
        if (asciiEqlIgnoreCase(entry.name, "TERM")) {
            // The requested TERM REPLACES an inherited one, the shared
            // rule: the spawn declared what terminal the child is
            // attached to.
            entries[count] = .{ .name = "TERM", .value = term };
            has_term = true;
        } else {
            entries[count] = entry;
        }
        total_bytes += entry.name.len + entry.value.len;
        if (total_bytes > pty.max_env_bytes) return error.OutOfMemory;
        count += 1;
    }
    if (!has_term) {
        entries[count] = .{ .name = "TERM", .value = term };
        count += 1;
    }
    std.mem.sort(EnvVar, entries[0..count], {}, envNameLessThan);

    var flat: std.ArrayList(u8) = .empty;
    for (entries[0..count]) |entry| {
        try flat.appendSlice(arena, entry.name);
        try flat.append(arena, '=');
        try flat.appendSlice(arena, entry.value);
        try flat.append(arena, 0);
    }
    // An empty environment still needs one terminating NUL entry ahead
    // of the block terminator.
    if (count == 0) try flat.append(arena, 0);
    const wide_len = std.unicode.calcWtf16LeLen(flat.items) catch return error.InvalidWtf8;
    const wide = try arena.allocSentinel(u16, wide_len, 0);
    _ = try std.unicode.wtf8ToWtf16Le(wide, flat.items);
    return wide;
}

/// The environment-block contract's order: name comparison is
/// case-insensitive in the order the OS itself compares environment
/// names — UTF-16 CODE UNITS (a supplementary-plane name sorts by its
/// surrogate halves, BELOW the private-use BMP range, exactly as
/// `RtlCompareUnicodeString` would), each unit folded through the OS's
/// own BMP uppercase table (`toUpperWtf16`, the same fold std's
/// Windows env-name hashing uses) — never WTF-8 bytes or code points.
/// A name that is not valid WTF-8 falls back to byte order; the block
/// build refuses such an environment moments later with the
/// whole-or-nothing env error, so the fallback never reaches a child.
fn envNameLessThan(_: void, a: EnvVar, b: EnvVar) bool {
    const view_a = std.unicode.Wtf8View.init(a.name) catch return std.mem.lessThan(u8, a.name, b.name);
    const view_b = std.unicode.Wtf8View.init(b.name) catch return std.mem.lessThan(u8, a.name, b.name);
    var it_a: Wtf16UnitIterator = .{ .inner = view_a.iterator() };
    var it_b: Wtf16UnitIterator = .{ .inner = view_b.iterator() };
    while (true) {
        const unit_a = it_a.next() orelse return it_b.next() != null;
        const unit_b = it_b.next() orelse return false;
        const upper_a = std.os.windows.toUpperWtf16(unit_a);
        const upper_b = std.os.windows.toUpperWtf16(unit_b);
        if (upper_a != upper_b) return upper_a < upper_b;
    }
}

/// WTF-8 code points re-emitted as WTF-16 code units (supplementary
/// planes as their surrogate pair; WTF-8's unpaired surrogates pass
/// through as themselves).
const Wtf16UnitIterator = struct {
    inner: std.unicode.Wtf8Iterator,
    pending_low: ?u16 = null,

    fn next(self: *Wtf16UnitIterator) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        const cp = self.inner.nextCodepoint() orelse return null;
        if (cp < 0x10000) return @intCast(cp);
        const offset = cp - 0x10000;
        self.pending_low = @intCast(0xDC00 + (offset & 0x3FF));
        return @intCast(0xD800 + (offset >> 10));
    }
};

/// Monotonic counter distinguishing concurrent spawns' pipe names
/// (pipe names are a global namespace; the pid alone is not unique
/// across two runtime instances' simultaneous spawns in one process).
var pipe_counter = std.atomic.Value(u64).init(0);

const PipeDirection = enum { inbound, outbound };

const PipeEnds = struct {
    server: win.HANDLE,
    client: win.HANDLE,
};

/// One overlapped byte pipe: the parent keeps the overlapped server
/// end; the synchronous client end goes to `CreatePseudoConsole`.
/// FIRST_PIPE_INSTANCE + REJECT_REMOTE_CLIENTS keep the name squat
/// window honest: a squatter holding the name fails the create rather
/// than intercepting the console stream.
fn createOverlappedPipe(direction: PipeDirection) error{PipeFailed}!PipeEnds {
    if (comptime !is_windows) return error.PipeFailed;
    const serial = pipe_counter.fetchAdd(1, .monotonic);
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\native-sdk-conpty-{d}-{d}", .{
        win.GetCurrentProcessId(),
        serial,
    }) catch return error.PipeFailed;
    var name_w: [160]u16 = undefined;
    const name_len = std.unicode.wtf8ToWtf16Le(name_w[0 .. name_w.len - 1], name) catch return error.PipeFailed;
    name_w[name_len] = 0;
    const name_z = name_w[0..name_len :0];

    const open_mode: win.DWORD = win.FILE_FLAG_OVERLAPPED | win.FILE_FLAG_FIRST_PIPE_INSTANCE |
        (if (direction == .inbound) win.PIPE_ACCESS_INBOUND else win.PIPE_ACCESS_OUTBOUND);
    const server = win.CreateNamedPipeW(
        name_z.ptr,
        open_mode,
        win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        pipe_buffer_bytes,
        pipe_buffer_bytes,
        0,
        null,
    );
    if (server == win.INVALID_HANDLE_VALUE) return error.PipeFailed;
    const client_access: win.DWORD = if (direction == .inbound) win.GENERIC_WRITE else win.GENERIC_READ;
    const client = win.CreateFileW(
        name_z.ptr,
        client_access,
        0,
        null,
        win.OPEN_EXISTING,
        0,
        null,
    );
    if (client == win.INVALID_HANDLE_VALUE) {
        _ = win.CloseHandle(server);
        return error.PipeFailed;
    }
    return .{ .server = server, .client = client };
}

/// Kernel handles are 32-bit significant by contract (the WOW64
/// interoperability guarantee: only the low 32 bits carry identity,
/// sign-extended to 64) — so a HANDLE rides the seam's c_int the way a
/// POSIX fd does, and -1 stays the shared closed sentinel
/// (INVALID_HANDLE_VALUE maps to -1 and is never a live event).
fn handleToFd(handle: win.HANDLE) c_int {
    return @bitCast(@as(u32, @truncate(@intFromPtr(handle))));
}

fn fdToHandle(fd: c_int) win.HANDLE {
    const wide: isize = fd; // sign-extend, the documented widening
    return @ptrFromInt(@as(usize, @bitCast(wide)));
}

fn lastError() u32 {
    return @intFromEnum(std.os.windows.GetLastError());
}

/// Self-contained Win32 surface, the file's `extern "c"` analog: only
/// what the transport calls, declared here so the runtime keeps zero
/// dependence on the platform layer's bindings. Everything below is a
/// documented kernel32 export on the supported Windows floor (ConPTY:
/// Windows 10 1809+).
const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const HPCON = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const HRESULT = i32;
    const COORD = extern struct { X: i16, Y: i16 };
    const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: DWORD = 0,
        OffsetHigh: DWORD = 0,
        hEvent: ?HANDLE = null,
    };
    const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
    const STARTUPINFOW = std.os.windows.STARTUPINFOW;
    const STARTUPINFOEXW = extern struct {
        StartupInfo: STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };
    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: DWORD,
        dwThreadId: DWORD,
    };

    const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
    const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;
    const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
    const GENERIC_READ: DWORD = 0x8000_0000;
    const GENERIC_WRITE: DWORD = 0x4000_0000;
    const OPEN_EXISTING: DWORD = 3;
    const PIPE_ACCESS_INBOUND: DWORD = 0x1;
    const PIPE_ACCESS_OUTBOUND: DWORD = 0x2;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x0008_0000;
    const FILE_FLAG_OVERLAPPED: DWORD = 0x4000_0000;
    const PIPE_TYPE_BYTE: DWORD = 0x0;
    const PIPE_READMODE_BYTE: DWORD = 0x0;
    const PIPE_WAIT: DWORD = 0x0;
    const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x8;
    const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
    const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x0000_0400;
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;
    const DUPLICATE_SAME_ACCESS: DWORD = 0x2;
    const STARTF_USESTDHANDLES: DWORD = 0x100;
    const INFINITE: DWORD = 0xFFFF_FFFF;
    const WAIT_OBJECT_0: DWORD = 0;
    const WAIT_TIMEOUT: DWORD = 0x102;
    const WAIT_FAILED: DWORD = 0xFFFF_FFFF;
    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const ERROR_PATH_NOT_FOUND: u32 = 3;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_HANDLE_EOF: u32 = 38;
    const ERROR_BROKEN_PIPE: u32 = 109;
    const ERROR_INVALID_NAME: u32 = 123;
    const ERROR_BAD_EXE_FORMAT: u32 = 193;
    const ERROR_PIPE_NOT_CONNECTED: u32 = 233;
    const ERROR_DIRECTORY: u32 = 267;
    const ERROR_IO_INCOMPLETE: u32 = 996;
    const ERROR_IO_PENDING: u32 = 997;

    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: DWORD,
        dwPipeMode: DWORD,
        nMaxInstances: DWORD,
        nOutBufferSize: DWORD,
        nInBufferSize: DWORD,
        nDefaultTimeOut: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*SECURITY_ATTRIBUTES,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn WaitForMultipleObjects(
        nCount: DWORD,
        lpHandles: [*]const HANDLE,
        bWaitAll: BOOL,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: HANDLE,
        lpBuffer: ?[*]u8,
        nBufferSize: DWORD,
        lpBytesRead: ?*DWORD,
        lpTotalBytesAvail: ?*DWORD,
        lpBytesLeftThisMessage: ?*DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*:0]u16,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?[*:0]const u16,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn InitializeProcThreadAttributeList(
        lpAttributeList: ?*anyopaque,
        dwAttributeCount: DWORD,
        dwFlags: DWORD,
        lpSize: *usize,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(
        lpAttributeList: *anyopaque,
        dwFlags: DWORD,
        Attribute: usize,
        lpValue: ?*anyopaque,
        cbSize: usize,
        lpPreviousValue: ?*anyopaque,
        lpReturnSize: ?*usize,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreatePseudoConsole(
        size: COORD,
        hInput: HANDLE,
        hOutput: HANDLE,
        dwFlags: DWORD,
        phPC: *HPCON,
    ) callconv(.winapi) HRESULT;
    extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
    extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) DWORD;
    extern "kernel32" fn GetWindowsDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
    extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]u16) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn DuplicateHandle(
        hSourceProcessHandle: HANDLE,
        hSourceHandle: HANDLE,
        hTargetProcessHandle: HANDLE,
        lpTargetHandle: *HANDLE,
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwOptions: DWORD,
    ) callconv(.winapi) BOOL;
};

// ------------------------------------------------------------------ tests

/// The io loop's poll discipline condensed for in-file tests, the
/// POSIX `testReadAll`'s Windows twin: a real nudge pair joins the
/// wait so the loop shape matches the effects thread exactly.
fn testReadAll(p: Pty, nudge_fd: c_int, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const ready = wait(p, nudge_fd, true, false);
        if (!ready.readable) continue;
        const n = p.read(buf[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.ReadFailed => return total,
        };
        if (n == 0) return total;
        total += n;
    }
    return total;
}

/// cmd.exe needs SystemRoot to start (it resolves its own DLL world
/// through it), so the clean-environment tests carry the one variable
/// the OS itself requires — the POSIX tests' /bin/sh needed nothing,
/// but the policy under test (nothing leaks in but what the caller
/// listed, plus TERM) is identical.
const system_root_env: EnvVar = .{ .name = "SystemRoot", .value = "C:\\Windows" };

test "windows spawn rejects an empty argv and a missing command" {
    if (comptime !is_windows) return;
    try std.testing.expectError(error.PtyArgvInvalid, spawn(std.testing.allocator, .{ .argv = &.{} }));
    try std.testing.expectError(error.PtyCommandNotFound, spawn(std.testing.allocator, .{
        .argv = &.{"never-a-command-native-sdk"},
    }));
    try std.testing.expectError(error.PtyCommandNotFound, spawn(std.testing.allocator, .{
        .argv = &.{"C:\\nonexistent\\never-a-command.exe"},
    }));
}

test "windows live conpty round trip: output, exit code, no signal channel" {
    if (comptime !is_windows) return;
    const p = try spawn(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "echo pty-win-live-marker& exit 7" },
        .env = &.{system_root_env},
        .cols = 60,
        .rows = 16,
    });
    defer p.close();
    try std.testing.expect(!p.lateExecFailure());
    const nudge_pair = try pipePair();
    defer closeFd(nudge_pair[0]);
    defer closeFd(nudge_pair[1]);
    var buf: [64 * 1024]u8 = undefined;
    const total = testReadAll(p, nudge_pair[0], &buf);
    // ConPTY output is conhost's VT rendering, so the marker rides
    // among escape sequences: containment is the honest assertion.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "pty-win-live-marker") != null);
    const exit = p.reapBlocking();
    try std.testing.expectEqual(@as(i32, 7), exit.code);
    try std.testing.expectEqual(@as(i32, 0), exit.signal);
}

test "windows kill reports an exit code, never a signal" {
    if (comptime !is_windows) return;
    // A bare interactive cmd stays alive until killed.
    const p = try spawn(std.testing.allocator, .{
        .argv = &.{"cmd.exe"},
        .env = &.{system_root_env},
    });
    defer p.close();
    p.resize(100, 30);
    p.kill(false);
    const exit = p.reapBlocking();
    // TerminateProcess carries exit code 1; Windows has no signal
    // channel, so `signal` is always 0 — the documented mapping.
    try std.testing.expectEqual(@as(i32, 1), exit.code);
    try std.testing.expectEqual(@as(i32, 0), exit.signal);
}

test "windows child environment is exactly env plus TERM" {
    if (comptime !is_windows) return;
    const p = try spawn(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "echo %PTY_MARKER%_%TERM%_%PTY_ABSENT%" },
        .env = &.{ system_root_env, .{ .name = "PTY_MARKER", .value = "pty-proof" } },
    });
    defer p.close();
    const nudge_pair = try pipePair();
    defer closeFd(nudge_pair[0]);
    defer closeFd(nudge_pair[1]);
    var buf: [64 * 1024]u8 = undefined;
    const total = testReadAll(p, nudge_pair[0], &buf);
    _ = p.reapBlocking();
    const out = buf[0..total];
    // MARKER passed through, TERM injected; an absent variable stays
    // an unexpanded literal in cmd — the clean-environment proof.
    try std.testing.expect(std.mem.indexOf(u8, out, "pty-proof_" ++ pty.default_term ++ "_%PTY_ABSENT%") != null);

    // An inherited TERM is replaced, never preserved (case-insensitive,
    // the Windows env-name rule).
    const q = try spawn(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "echo term=%TERM%=" },
        .env = &.{ system_root_env, .{ .name = "Term", .value = "dumb" } },
        .term = "xterm-256color",
    });
    defer q.close();
    const q_nudge = try pipePair();
    defer closeFd(q_nudge[0]);
    defer closeFd(q_nudge[1]);
    var term_buf: [64 * 1024]u8 = undefined;
    const term_total = testReadAll(q, q_nudge[0], &term_buf);
    _ = q.reapBlocking();
    try std.testing.expect(std.mem.indexOf(u8, term_buf[0..term_total], "term=xterm-256color=") != null);
    try std.testing.expect(std.mem.indexOf(u8, term_buf[0..term_total], "dumb") == null);
}

test "windows utf-8 honesty: non-ascii argv survives the utf-16 boundary and returns as utf-8" {
    if (comptime !is_windows) return;
    const p = try spawn(std.testing.allocator, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "echo pty-你好-héllo" },
        .env = &.{system_root_env},
    });
    defer p.close();
    const nudge_pair = try pipePair();
    defer closeFd(nudge_pair[0]);
    defer closeFd(nudge_pair[1]);
    var buf: [64 * 1024]u8 = undefined;
    const total = testReadAll(p, nudge_pair[0], &buf);
    _ = p.reapBlocking();
    // The argument crossed WTF-8 -> UTF-16 into cmd, conhost rendered
    // it, and ConPTY delivered it back as UTF-8 bytes.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "pty-你好-héllo") != null);
}

test "windows initial grid size reaches the child console" {
    if (comptime !is_windows) return;
    const p = try spawn(std.testing.allocator, .{
        // Full path: the test env carries no PATH for cmd to search.
        .argv = &.{ "cmd.exe", "/d", "/c", "C:\\Windows\\System32\\mode.com con" },
        .env = &.{system_root_env},
        .cols = 97,
        .rows = 41,
    });
    defer p.close();
    const nudge_pair = try pipePair();
    defer closeFd(nudge_pair[0]);
    defer closeFd(nudge_pair[1]);
    var buf: [64 * 1024]u8 = undefined;
    const total = testReadAll(p, nudge_pair[0], &buf);
    _ = p.reapBlocking();
    // `mode con` reports the console geometry; the labels are
    // localized, the numbers are not.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "97") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "41") != null);
}

test "windows env-block order folds case beyond ascii" {
    // é (U+00E9) uppercases to É (U+00C9), which orders BEFORE Ê
    // (U+00CA); raw WTF-8 bytes would order them the other way.
    const e_acute: EnvVar = .{ .name = "é", .value = "1" };
    const e_circ: EnvVar = .{ .name = "Ê", .value = "2" };
    try std.testing.expect(envNameLessThan({}, e_acute, e_circ));
    try std.testing.expect(!envNameLessThan({}, e_circ, e_acute));
    // The ASCII fold still holds, and a name that is a strict prefix
    // of another orders first.
    try std.testing.expect(envNameLessThan({}, .{ .name = "path", .value = "" }, .{ .name = "PATHEXT", .value = "" }));
    try std.testing.expect(!envNameLessThan({}, .{ .name = "TERM", .value = "" }, .{ .name = "term", .value = "" }));
    // UTF-16 code-unit order, the OS's own: a supplementary-plane name
    // (U+10000, surrogate halves 0xD800/0xDC00) sorts BELOW a
    // private-use BMP name (U+E000) even though its code point is
    // larger.
    try std.testing.expect(envNameLessThan({}, .{ .name = "\u{10000}", .value = "" }, .{ .name = "\u{E000}", .value = "" }));
    try std.testing.expect(!envNameLessThan({}, .{ .name = "\u{E000}", .value = "" }, .{ .name = "\u{10000}", .value = "" }));
}

test "windows executable probing appends extensions only to extension-less names" {
    try std.testing.expect(hasExtension("tool.cmd"));
    try std.testing.expect(hasExtension("C:\\dir.d\\tool.exe"));
    try std.testing.expect(!hasExtension("cmd"));
    try std.testing.expect(!hasExtension("C:\\dir.d\\tool"));
    try std.testing.expect(!hasExtension(".hidden"));
}

test "windows command-line quoting round-trips the argv inverse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var line: std.ArrayList(u8) = .empty;
    try appendQuotedArg(arena, &line, "plain");
    try line.append(arena, ' ');
    try appendQuotedArg(arena, &line, "has space");
    try line.append(arena, ' ');
    try appendQuotedArg(arena, &line, "quote\"inside");
    try line.append(arena, ' ');
    try appendQuotedArg(arena, &line, "trail\\");
    try line.append(arena, ' ');
    try appendQuotedArg(arena, &line, "back\\slash here\\");
    try line.append(arena, ' ');
    try appendQuotedArg(arena, &line, "");
    // A lone backslash needs no quoting (CommandLineToArgvW reads
    // backslashes literally outside a quote context); a quoted
    // trailing run doubles ahead of the closing quote.
    try std.testing.expectEqualStrings(
        "plain \"has space\" \"quote\\\"inside\" trail\\ \"back\\slash here\\\\\" \"\"",
        line.items,
    );
}
