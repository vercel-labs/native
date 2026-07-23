//! POSIX pseudo-terminal primitive: open a pty pair, fork a child with the
//! child end as its controlling terminal, and hand the caller the parent fd
//! to read output from and write input to. macOS and Linux only — every
//! other target compiles to the `error.PtyUnsupported` stubs so the effects
//! layer reports the same loud rejection the null platform's fake pty stands
//! in for under test.
//!
//! (The two ends of a pty pair: the PARENT end is the controlling side the
//! toolkit keeps, and the CHILD end is the process side that becomes the
//! spawned program's controlling terminal — POSIX's own APIs spell these
//! `posix_openpt`/`ptsname`, whose C names we keep at the call site.)
//!
//! This is the one place the toolkit forks a child onto a terminal. It
//! deliberately does NOT use `std.process.spawn`: a pty child needs a
//! controlling terminal (`login_tty` = setsid + TIOCSCTTY + dup of the
//! child end onto fds 0/1/2), which the generic spawn path does not set up.
//! Everything the child touches between fork and exec is async-signal-safe:
//! argv/envp are built in the PARENT (including the `TERM` override and the
//! PATH resolution of argv[0]), so the child calls only `login_tty`,
//! `execve`, and `_exit` — no allocator, no `setenv`, none of the
//! fork-in-a-threaded-process hazards a mid-child `malloc` would invite.

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");

/// Serializes the descriptor-opening half of every pty spawn in the
/// process (spawns can originate from independent runtime instances on
/// different threads): the section from `posix_openpt` through `fork`,
/// and the wake pipe's creation. Darwin ignores O_CLOEXEC on
/// `posix_openpt` (and its pipes need a second syscall for the flag),
/// so a CONCURRENT PTY FORK landing between an open and its fcntl would
/// gift its exec'd child a copy of another spawn's parent-end or pipe
/// descriptor for that child's whole life. Forks the lock cannot cover
/// — job spawns (their process start blocks on its own exec pipe, so
/// holding a UI-shared lock across it would freeze the loop on a
/// wedged mount) and embedder forks on foreign threads — keep the
/// documented residual sub-syscall window: inherited copies die at
/// those children's execs, and a delayed exec-pipe EOF is resolved by
/// the carried reap-time verdict rather than guessed. `ptsname`'s
/// libc-shared static buffer rides the same lock. A tiny spinlock —
/// the guarded section is a handful of bounded syscalls, never the
/// exec-status poll.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};
var pty_spawn_mutex: SpinLock = .{};

/// pty support is a POSIX story: openpty + a controlling terminal.
/// Windows (ConPTY) is staged separately; every non-posix target reports
/// the effect as unsupported rather than pretending. macOS always links
/// libSystem, so the libc externs below always resolve there; Linux
/// builds get the real transport exactly when they link libc (every
/// platform app build does — the GTK host is C — while a libc-free
/// headless build reports unsupported and tests through the fake pty).
/// `openpty`/`login_tty` live in libc proper on the supported Linux
/// floor (glibc 2.34+ merged libutil; musl always shipped them).
pub const supported = switch (builtin.os.tag) {
    .macos => true,
    .linux => builtin.link_libc,
    else => false,
};

/// The value written into the child's `TERM` when the caller does not
/// override it: a widely understood 256-color terminfo name matching the
/// palette the emulator and the example renderer speak.
pub const default_term = "xterm-256color";

/// Longest single command path (argv[0] resolved) plus each argv entry the
/// pty spawn accepts, mirroring the spawn effect's argv budget so the two
/// transports teach one limit.
pub const max_argv = 16;
pub const max_argv_bytes = 4096;
pub const max_env_entries = 256;
pub const max_env_bytes = 64 * 1024;

pub const Error = error{
    PtyUnsupported,
    PtyOpenFailed,
    PtyForkFailed,
    PtyArgvInvalid,
    PtyEnvironTooLarge,
    PtyCommandNotFound,
};

/// A live pty: the parent-end fd plus the child pid. Reads and writes go
/// to `parent`; `pid` is signalled for kill and reaped on exit.
pub const Pty = struct {
    parent: c_int,
    pid: c_int,
    /// The exec self-pipe's read end, kept ONLY when the spawn-time
    /// probe timed out unresolved (an executable on a stalled mount can
    /// block inside `execve` past any reasonable bound). The verdict
    /// still arrives with the child's death — a failing exec writes its
    /// byte before `_exit` — so `lateExecFailure` reads it at reap time
    /// and the exit reports `spawn_failed` instead of masquerading as a
    /// normal end. -1 when the probe resolved at spawn.
    exec_status: c_int = -1,

    /// Read available output bytes into `buf`. Returns 0 at EOF — which the
    /// parent end reports as EIO on Linux once the child exits, normalized
    /// here — and `error.ReadFailed` for anything else.
    pub fn read(self: Pty, buf: []u8) error{ ReadFailed, WouldBlock }!usize {
        while (true) {
            const r = c.read(self.parent, buf.ptr, buf.len);
            if (r >= 0) return @intCast(r);
            switch (errnoValue()) {
                eintr => continue,
                // Non-blocking parent end with nothing ready: not EOF.
                eagain => return error.WouldBlock,
                // EIO from the parent end is the hangup after child exit:
                // the stream is over, not broken.
                eio => return 0,
                else => return error.ReadFailed,
            }
        }
    }

    /// Write input bytes toward the child. Partial writes are possible;
    /// the caller loops. `error.WouldBlock` means the non-blocking parent
    /// end's input buffer is full (the child is not reading) — the caller
    /// leaves the bytes staged and retries on the next writable poll,
    /// never blocking the io thread.
    pub fn write(self: Pty, bytes: []const u8) error{ WriteFailed, WouldBlock }!usize {
        while (true) {
            const r = c.write(self.parent, bytes.ptr, bytes.len);
            if (r >= 0) return @intCast(r);
            switch (errnoValue()) {
                eintr => continue,
                eagain => return error.WouldBlock,
                else => return error.WriteFailed,
            }
        }
    }

    /// Push a new window size to the kernel line discipline so the child
    /// receives SIGWINCH and re-queries via TIOCGWINSZ.
    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        if (!supported) return;
        var ws: Winsize = .{
            .row = if (rows == 0) 1 else rows,
            .col = if (cols == 0) 1 else cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = c.ioctl(self.parent, tiocswinsz, &ws);
    }

    /// Signal the child's process group. `graceful` sends SIGTERM (let the
    /// shell clean up); otherwise SIGKILL. The child was placed in its own
    /// session by `login_tty`, so signalling the negated pid reaches its
    /// FOREGROUND process group — the direct child and everything it kept
    /// in its group. A descendant that moved itself into another process
    /// group (a shell's background job, a daemonizing setsid) is outside
    /// the signal's reach: POSIX has no kill-whole-session primitive, so
    /// such an escapee runs on detached — the spawn family's documented
    /// limit, shared with `reapEnding`'s escalation and the io loop's
    /// kill-then-reap path (which is why a kill never waits for the pty
    /// to reach EOF: an escapee holding the child end open would strand
    /// it forever).
    pub fn kill(self: Pty, graceful: bool) void {
        if (!supported) return;
        const sig: c_int = if (graceful) sigterm else sigkill;
        _ = c.kill(-self.pid, sig);
        _ = c.kill(self.pid, sig);
    }

    /// Reap the child if it has exited. Returns null while it is still
    /// running, or the decoded exit on reap. Non-blocking (WNOHANG).
    /// `ECHILD` — the child was already reaped elsewhere (an embedder
    /// with `SA_NOCLDWAIT`, `SIG_IGN` on SIGCHLD, or its own reaper) —
    /// is reported as a gone child (sentinel exit), NEVER as "still
    /// running": a reaped pid may be reused, so treating it as alive
    /// would let `reapEnding` signal an unrelated process.
    pub fn reap(self: Pty) ?Exit {
        if (!supported) return null;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, wnohang);
        if (r == self.pid) return decodeStatus(status);
        if (r < 0 and errnoValue() == echild) return .{ .code = -1, .signal = 0 };
        return null;
    }

    /// Reap the child, blocking until it exits. Used at teardown after a
    /// kill so no zombie is left behind. EINTR retries — a signal must
    /// not fabricate an exit and leave the real child a zombie.
    pub fn reapBlocking(self: Pty) Exit {
        if (!supported) return .{ .code = -1, .signal = 0 };
        var status: c_int = 0;
        while (true) {
            const r = c.waitpid(self.pid, &status, 0);
            if (r == self.pid) return decodeStatus(status);
            if (r < 0 and errnoValue() == eintr) continue;
            if (r < 0) return .{ .code = -1, .signal = 0 };
        }
    }

    /// Reap after the output stream ended, NEVER blocking indefinitely.
    /// The fast path is the normal case: the child already exited, so a
    /// non-blocking reap returns at once and no signal is sent. If the
    /// child is still alive (it closed its terminal descriptors but kept
    /// running), it is hung up like a real terminal (SIGHUP to the job),
    /// then escalated to SIGKILL within a bounded window, so the exit
    /// always arrives — the fix for a `reapBlocking` that would otherwise
    /// wait forever on such a child while a kill is skipped. The caller
    /// publishes `reaping` before this so no concurrent kill signals the
    /// (soon-freed) pid.
    pub fn reapEnding(self: Pty) Exit {
        if (!supported) return .{ .code = -1, .signal = 0 };
        if (self.reap()) |exit| return exit;
        // Still running: hang it up, then escalate.
        _ = c.kill(-self.pid, sighup);
        _ = c.kill(self.pid, sighup);
        var waited_us: usize = 0;
        while (waited_us < 500_000) : (waited_us += 10_000) {
            _ = c.usleep(10_000);
            if (self.reap()) |exit| return exit;
            if (waited_us == 200_000) {
                _ = c.kill(-self.pid, sigkill);
                _ = c.kill(self.pid, sigkill);
            }
        }
        // SIGKILL cannot be caught — but a child stuck in UNINTERRUPTIBLE
        // kernel I/O (a stalled mount, a wedged device) does not die
        // until the kernel releases it, a wait no signal can shorten.
        // Poll a further bounded window, then surrender the reap: the
        // exit event must reach the app (an io thread wedged here would
        // strand the session with no exit forever), so past the deadline
        // the kill is reported as the ending and the SIGKILL'd child is
        // left for the kernel — it dies (and zombies, since this thread
        // will not wait again) whenever its syscall returns. A bounded,
        // loud-in-effect leak that beats an unbounded hang; nothing
        // signals the pid after this (`reaping` stays published).
        waited_us = 0;
        while (waited_us < 5_000_000) : (waited_us += 20_000) {
            if (self.reap()) |exit| return exit;
            _ = c.usleep(20_000);
        }
        return .{ .code = -1, .signal = sigkill };
    }

    /// Close the parent-end fd (and a still-held exec-status pipe). The
    /// child is expected to be reaped separately.
    pub fn close(self: Pty) void {
        if (!supported) return;
        _ = c.close(self.parent);
        if (self.exec_status >= 0) _ = c.close(self.exec_status);
    }

    /// Whether a LATE exec failure landed on the carried status pipe —
    /// checked at reap time, when the child is dead: a failing exec
    /// wrote its byte before `_exit`, so the byte is either in the pipe
    /// buffer now or the exec succeeded. The read is non-blocking (a
    /// leaked writer in an embedder-forked child can therefore never
    /// wedge the reap), and an empty pipe reads as success.
    pub fn lateExecFailure(self: Pty) bool {
        if (!supported) return false;
        if (self.exec_status < 0) return false;
        var probe: [1]u8 = undefined;
        return c.read(self.exec_status, &probe, 1) > 0;
    }
};

/// How a pty child ended, decoded from `waitpid`'s status word.
pub const Exit = struct {
    /// Exit code for a normal exit; -1 when the child died to a signal.
    code: i32,
    /// Signal number when the child was terminated by a signal; 0 for a
    /// normal exit.
    signal: i32,
};

/// Everything one spawn needs. argv and env come pre-flattened so the
/// child does nothing but exec.
pub const SpawnOptions = struct {
    argv: []const []const u8,
    /// The child's environment. When null the child inherits nothing but
    /// `TERM` (a clean environment, like the fallback spawn environ).
    env: ?[]const EnvVar = null,
    /// Overrides the injected `TERM` value.
    term: []const u8 = default_term,
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Open a pty and fork `argv` onto it. On success the returned `Pty` owns
/// the parent-end fd and the child pid. The child's environment is exactly
/// the caller's `env` (or empty) plus a `TERM` entry — no host variables leak
/// in unless the caller put them in `env`, the same explicit-policy shape
/// the spawn effect's `bindEnviron` draws.
pub fn spawn(gpa: std.mem.Allocator, options: SpawnOptions) Error!Pty {
    if (!supported) return error.PtyUnsupported;
    if (options.argv.len == 0 or options.argv.len > max_argv) return error.PtyArgvInvalid;
    // An argv entry with an embedded NUL would be silently truncated at
    // the C boundary (execve reads to the first NUL) — reject it rather
    // than hand the child a cut argument.
    for (options.argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.PtyArgvInvalid;
    }

    // Resolve argv[0] to an absolute path in the PARENT so the child's
    // only post-fork calls are login_tty/execve/_exit — execve needs a
    // resolved path (it does no PATH search).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = resolveExecutable(options.argv[0], options.env, &path_buf) orelse
        return error.PtyCommandNotFound;

    // Build the NUL-terminated argv/envp arrays the child hands execve.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved_z = arena.dupeZ(u8, resolved) catch return error.PtyEnvironTooLarge;
    const argv_z = buildArgvZ(arena, options.argv) catch return error.PtyEnvironTooLarge;
    const envp_z = buildEnvpZ(arena, options.env, options.term) catch return error.PtyEnvironTooLarge;

    const ws: Winsize = .{
        .row = if (options.rows == 0) 24 else options.rows,
        .col = if (options.cols == 0) 80 else options.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    const pair = try spawnPair(resolved_z, argv_z, envp_z, ws);
    // A failure byte, EOF, or the timeout resolves the probe. A real
    // exec failure writes its byte into the pipe buffer INSTANTLY (the
    // child's write lands before its _exit), so a byte always means
    // failure regardless of who else holds a writer. EOF (every writer
    // closed) is the fast success signal. The timeout resolves NOTHING:
    // an exec can genuinely block past any bound (an executable or
    // shebang interpreter on a stalled mount) and an embedder-forked
    // child holding a leaked writer delays EOF — so an unresolved probe
    // CARRIES the pipe on the transport, where `lateExecFailure` reads
    // the verdict at reap time and a late failure still delivers
    // `spawn_failed`, never a masqueraded normal exit. Polled OUTSIDE
    // the spawn lock, which covers only bounded syscalls.
    switch (execStatus(pair.exec_read)) {
        .failed => {
            _ = c.close(pair.exec_read);
            var status: c_int = 0;
            while (c.waitpid(pair.pid, &status, 0) < 0 and errnoValue() == eintr) {}
            _ = c.close(pair.parent);
            return error.PtyCommandNotFound;
        },
        .succeeded => {
            _ = c.close(pair.exec_read);
            return .{ .parent = pair.parent, .pid = pair.pid };
        },
        .unresolved => {
            // Non-blocking so the reap-time check can never wait on a
            // leaked writer. If the flag cannot be set, the carried
            // check is unsafe — fall back to the probe's old
            // timed-out-means-started answer rather than risk a wedged
            // reap.
            const flags = c.fcntl(pair.exec_read, f_getfl, @as(c_int, 0));
            if (flags < 0 or c.fcntl(pair.exec_read, f_setfl, flags | o_nonblock) < 0) {
                _ = c.close(pair.exec_read);
                return .{ .parent = pair.parent, .pid = pair.pid };
            }
            return .{ .parent = pair.parent, .pid = pair.pid, .exec_status = pair.exec_read };
        },
    }
}

const SpawnedPair = struct {
    parent: c_int,
    pid: c_int,
    exec_read: c_int,
};

/// Open the pty pair, arm the exec self-pipe, and fork — the whole
/// descriptor-opening window — under the process-wide spawn lock (see
/// `pty_spawn_mutex`): with every toolkit fork serialized against every
/// toolkit open-to-CLOEXEC gap, no toolkit child can inherit another
/// spawn's parent end or pipe ends across its exec.
fn spawnPair(
    resolved_z: [:0]const u8,
    argv_z: [:null]const ?[*:0]const u8,
    envp_z: [:null]const ?[*:0]const u8,
    ws: Winsize,
) Error!SpawnedPair {
    pty_spawn_mutex.lock();
    defer pty_spawn_mutex.unlock();

    // Open the pty pair by hand rather than `openpty`, so the CHILD end is
    // opened close-on-exec ATOMICALLY (`open` with O_CLOEXEC). The child
    // end is the descriptor that matters most for the inheritance race:
    // if a concurrent fork on another thread inherited a non-CLOEXEC
    // child end across its exec, it would hold THIS pty open after our
    // child exits, so no EOF and no `.exit` event ever arrives.
    // `posix_openpt` + `grantpt` + `unlockpt` is the portable primitive
    // underneath `openpty`; the parent end's CLOEXEC is applied — and
    // VERIFIED — immediately after (Linux honors O_CLOEXEC on
    // `posix_openpt` directly; Darwin ignores it, which is one of the
    // windows the spawn lock closes against our own forks).
    const parent = c.posix_openpt(o_rdwr | o_noctty | o_cloexec_open);
    if (parent < 0) return error.PtyOpenFailed;
    if (!setCloexec(parent)) {
        _ = c.close(parent);
        return error.PtyOpenFailed;
    }
    // Non-blocking parent end: the sole io thread must never block inside a
    // write when the child stops reading its stdin (a full pty input
    // buffer), which would stall stdout draining and deadlock both
    // sides. Reads and writes handle EAGAIN; the poll loop paces both.
    {
        const flags = c.fcntl(parent, f_getfl, @as(c_int, 0));
        if (flags < 0 or c.fcntl(parent, f_setfl, flags | o_nonblock) < 0) {
            _ = c.close(parent);
            return error.PtyOpenFailed;
        }
    }
    if (c.grantpt(parent) != 0 or c.unlockpt(parent) != 0) {
        _ = c.close(parent);
        return error.PtyOpenFailed;
    }
    // `ptsname` returns libc-managed SHARED storage (not thread-safe):
    // two runtimes spawning ptys on different threads could otherwise
    // race, the second call overwriting the first's child-end name before
    // it opens. The spawn lock serializes the resolve-and-copy so each
    // spawn opens its own child end. (`ptsname_r` is not portably
    // available — macOS lacks it on older SDKs — so a copy under the
    // lock is the portable answer.)
    var name_buf: [128]u8 = undefined;
    const child_name = blk: {
        const shared_name = c.ptsname(parent) orelse {
            _ = c.close(parent);
            return error.PtyOpenFailed;
        };
        const span = std.mem.span(shared_name);
        if (span.len + 1 > name_buf.len) {
            _ = c.close(parent);
            return error.PtyOpenFailed;
        }
        @memcpy(name_buf[0..span.len], span);
        name_buf[span.len] = 0;
        break :blk name_buf[0..span.len :0];
    };
    var child_fd = c.open(child_name.ptr, o_rdwr | o_noctty | o_cloexec_open, @as(c_uint, 0));
    if (child_fd < 0) {
        _ = c.close(parent);
        return error.PtyOpenFailed;
    }
    // Keep the child end off the standard descriptors: `login_tty` dup2's
    // it onto 0/1/2, and dup2 CLEARS close-on-exec on its copies — but a
    // SAME-fd dup2 (the child end already IS fd 0/1/2, which happens when
    // the host started with standard descriptors closed) is a no-op that
    // leaves the CLOEXEC flag set, so the child's stdio would vanish at
    // execve. Relocating to a high fd guarantees the dup2 targets are
    // distinct and their CLOEXEC gets cleared.
    child_fd = relocateAboveStdio(child_fd) orelse {
        _ = c.close(parent);
        return error.PtyOpenFailed;
    };
    // Push the initial window size onto the child end (the child's
    // terminal) before the fork so the child's very first TIOCGWINSZ sees
    // the requested grid. `openpty` applied its `winp` to the child end;
    // match that — setting it on the parent end does not reliably
    // propagate before the child end becomes a controlling terminal.
    _ = c.ioctl(child_fd, tiocswinsz, &ws);

    // The exec self-pipe: close-on-exec on the write end, so a
    // successful `execve` closes it and the parent reads EOF (exec
    // worked). A failed exec writes its errno and the parent reads it,
    // distinguishing "the pty forked but the program could not start"
    // (`error.PtyCommandNotFound`) from a program that ran and exited
    // 127 on its own — a shebang naming a missing interpreter passes
    // the X_OK check yet fails at exec, and must not masquerade as a
    // normal exit.
    // Both ends close-on-exec (atomically on Linux via pipe2): the
    // write end must close on the child's successful exec to signal EOF
    // (and must not leak to a concurrent fork's child, which would
    // delay that EOF), and the read end must not leak either. The
    // exec-status poll's timeout is the net for Darwin's residual
    // sub-syscall window.
    const raw_pipe = makePipe(false) catch {
        _ = c.close(parent);
        _ = c.close(child_fd);
        return error.PtyOpenFailed;
    };
    // The write end must also clear the standard descriptors: `login_tty`
    // dup2's the child end onto 0/1/2 in the child, and if the write end
    // sat on fd 1 or 2 that dup2 would clobber it — the child could then
    // never report an exec failure, so a missing-interpreter exec would
    // masquerade as a normal exit. (This only bites when the host began
    // with standard descriptors closed; the relocation is a no-op
    // otherwise. `relocateAboveStdio` closes the original on both
    // success and failure.)
    const exec_read = relocateAboveStdio(raw_pipe[0]) orelse {
        _ = c.close(parent);
        _ = c.close(child_fd);
        _ = c.close(raw_pipe[1]);
        return error.PtyOpenFailed;
    };
    const exec_write = relocateAboveStdio(raw_pipe[1]) orelse {
        _ = c.close(parent);
        _ = c.close(child_fd);
        _ = c.close(exec_read);
        return error.PtyOpenFailed;
    };
    const exec_pipe = [2]c_int{ exec_read, exec_write };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(parent);
        _ = c.close(child_fd);
        _ = c.close(exec_pipe[0]);
        _ = c.close(exec_pipe[1]);
        return error.PtyForkFailed;
    }
    if (pid == 0) {
        // CHILD. Async-signal-safe only from here.
        _ = c.close(parent);
        _ = c.close(exec_pipe[0]);
        if (c.login_tty(child_fd) != 0) reportExecFailure(exec_pipe[1]);
        _ = c.execve(resolved_z.ptr, argv_z.ptr, envp_z.ptr);
        reportExecFailure(exec_pipe[1]);
    }
    // PARENT.
    _ = c.close(child_fd);
    _ = c.close(exec_pipe[1]);
    return .{ .parent = parent, .pid = pid, .exec_read = exec_pipe[0] };
}

/// CHILD-side exec-failure report: write the errno byte into the self-
/// pipe and exit. Async-signal-safe (`write`/`_exit`). EINTR retries —
/// a signal interrupting the one-byte report must not drop it, or the
/// parent reads a clean EOF and mistakes the failed exec for success.
fn reportExecFailure(write_fd: c_int) noreturn {
    const byte = [_]u8{1};
    while (true) {
        if (c.write(write_fd, &byte, 1) >= 0) break;
        if (errnoValue() == eintr) continue;
        break;
    }
    c._exit(127);
}

fn setCloexec(fd: c_int) bool {
    const flags = c.fcntl(fd, f_getfd, @as(c_int, 0));
    if (flags < 0) return false;
    return c.fcntl(fd, f_setfd, flags | fd_cloexec) >= 0;
}

/// Ensure `fd` is above the standard descriptors (>= 3), close-on-exec.
/// A descriptor already at 3+ is returned unchanged; a low one is
/// duplicated to a high, close-on-exec fd and the original is closed.
/// Returns null on failure, having closed the original either way, so
/// the caller never double-closes it. This keeps `login_tty`'s dup2
/// onto 0/1/2 from being a same-fd no-op that would strand the
/// close-on-exec flag on a descriptor the child must keep.
fn relocateAboveStdio(fd: c_int) ?c_int {
    if (fd >= 3) return fd;
    const high = c.fcntl(fd, f_dupfd_cloexec, @as(c_int, 3));
    _ = c.close(fd);
    if (high < 0) return null;
    return high;
}

const ExecProbe = enum { succeeded, failed, unresolved };

/// Resolve exec status from the self-pipe read end. A failure byte (the
/// child's errno report) means exec FAILED; a clean EOF (every writer
/// closed) means it SUCCEEDED.
///
/// The read BLOCKS — up to a generous bound — so a slow `execve` (an
/// interpreter on a sluggish filesystem or automount) is awaited and its
/// eventual failure byte correctly reported, rather than assumed
/// successful. The bound exists because CLOEXEC does NOT keep an
/// EMBEDDER `fork` on a thread the toolkit does not own from TRANSIENTLY
/// inheriting the write end (`O_CLOEXEC` closes the inherited copy on
/// that child's `exec`, not its `fork`; the toolkit's OWN forks are
/// serialized out by the spawn lock), so EOF can be delayed until such a
/// forker execs. A timeout therefore resolves NOTHING — the exec may
/// still be pending — and reports `unresolved`: the caller carries the
/// pipe on the transport, where the reap-time check converts a late
/// failure byte into the exit's `spawn_failed` instead of guessing.
fn execStatus(fd: c_int) ExecProbe {
    const timeout_ns: u64 = 10 * std.time.ns_per_s;
    // The bound is a DEADLINE, not a per-poll timeout: `poll` restarts
    // with a fresh timeout on every EINTR, so a fixed per-call timeout
    // would let signals arriving less than the bound apart defer the
    // timeout forever, blocking the spawn thread indefinitely. Recompute
    // the remaining time against a monotonic start so the total wait
    // stays capped no matter how many signals interrupt it. A missing
    // monotonic clock (not expected on macOS/Linux) reports unresolved
    // rather than risk an unbounded wait.
    const start = clock.monotonicNanoseconds();
    var fds = [1]Pollfd{.{ .fd = fd, .events = pollin, .revents = 0 }};
    while (true) {
        const now = clock.monotonicNanoseconds();
        // A zero read is the clock's unavailable sentinel (not expected
        // on macOS/Linux); report unresolved rather than risk an
        // unbounded EINTR-retry loop. `-%` keeps a clock that appears
        // to move backwards bounded too (it maps to a huge elapsed).
        const elapsed = now -% start;
        if (now == 0 or elapsed >= timeout_ns) return .unresolved;
        const remaining_ms: c_int = @intCast(@min(
            @as(u64, @intCast(std.math.maxInt(c_int))),
            (timeout_ns - elapsed) / std.time.ns_per_ms,
        ));
        const r = c.poll(&fds, 1, remaining_ms);
        if (r < 0) {
            if (errnoValue() == eintr) continue;
            return .unresolved;
        }
        if (r == 0) return .unresolved; // deadline: verdict still pending
        // Readable or hung up: a byte present is failure; a clean EOF
        // (readable, zero bytes) is success.
        if (fds[0].revents & pollin != 0) {
            var probe: [1]u8 = undefined;
            const n = c.read(fd, &probe, 1);
            if (n > 0) return .failed;
            if (n < 0 and errnoValue() == eintr) continue;
            return .succeeded;
        }
        // POLLHUP/POLLERR with no data: the writer closed on exec.
        return .succeeded;
    }
}

fn decodeStatus(status: c_int) Exit {
    const s: u32 = @bitCast(status);
    // WIFEXITED: low 7 bits (signal) are 0.
    if (s & 0x7f == 0) {
        return .{ .code = @intCast((s >> 8) & 0xff), .signal = 0 };
    }
    // WIFSIGNALED: low 7 bits carry the terminating signal.
    const sig: i32 = @intCast(s & 0x7f);
    return .{ .code = -1, .signal = sig };
}

fn resolveExecutable(arg0: []const u8, env: ?[]const EnvVar, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, arg0, '/') != null) {
        if (!executableAt(buf, arg0)) return null;
        if (arg0.len >= buf.len) return null;
        @memcpy(buf[0..arg0.len], arg0);
        return buf[0..arg0.len];
    }
    const path = lookupEnv(env, "PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |component| {
        // A POSIX empty PATH component names the current directory.
        const dir = if (component.len == 0) "." else component;
        const joined = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, arg0 }) catch continue;
        if (!executableAt(&scratch, joined)) continue;
        return joined;
    }
    return null;
}

/// X_OK access check through libc; `scratch` holds the NUL-terminated copy.
fn executableAt(scratch: []u8, path: []const u8) bool {
    if (path.len + 1 > scratch.len) return false;
    @memcpy(scratch[0..path.len], path);
    scratch[path.len] = 0;
    return c.access(scratch[0..path.len :0].ptr, 1) == 0;
}

fn lookupEnv(env: ?[]const EnvVar, name: []const u8) ?[]const u8 {
    const list = env orelse return null;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn buildArgvZ(arena: std.mem.Allocator, argv: []const []const u8) ![:null]const ?[*:0]const u8 {
    var out = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    // argv[0] the program sees is the caller's original arg0 (the name it
    // expects); execve's separate path argument carries the resolved one.
    for (argv, 0..) |arg, i| out[i] = try arena.dupeZ(u8, arg);
    return out;
}

fn buildEnvpZ(arena: std.mem.Allocator, env: ?[]const EnvVar, term: []const u8) ![:null]const ?[*:0]const u8 {
    const list = env orelse &[_]EnvVar{};
    var has_term = false;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.name, "TERM")) has_term = true;
    }
    const extra: usize = if (has_term) 0 else 1;
    var out = try arena.allocSentinel(?[*:0]const u8, list.len + extra, null);
    for (list, 0..) |entry, i| {
        out[i] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ entry.name, entry.value }, 0);
    }
    if (!has_term) {
        out[list.len] = try std.fmt.allocPrintSentinel(arena, "TERM={s}", .{term}, 0);
    }
    return out;
}

/// The kernel's window-size word (struct winsize): identical layout on
/// Linux and Darwin.
const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

// TIOCSWINSZ differs by platform (the BSD `_IOW('t',103,winsize)` encoding
// on Darwin, a fixed constant on Linux). Stated per-os because std.c
// exposes only the GET variant on Darwin.
const tiocswinsz: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    .macos => 0x80087467,
    else => 0,
};

// WNOHANG is 1 on both Linux and Darwin.
const wnohang: c_int = 1;
// F_GETFL/F_SETFL and O_NONBLOCK per platform (fcntl.h).
const f_getfl: c_int = 3;
const f_setfl: c_int = 4;
const f_getfd: c_int = 1;
const f_setfd: c_int = 2;
const fd_cloexec: c_int = 1;
const o_nonblock: c_int = switch (builtin.os.tag) {
    .linux => 0x800,
    .macos => 0x4,
    else => 0,
};
// pipe2 flag values (Linux): O_CLOEXEC and O_NONBLOCK as c_uint.
const o_cloexec: c_uint = 0x80000;
const o_nonblock_flag: c_uint = 0x800;

// open(2) flags for the pty pair, per platform.
const o_rdwr: c_int = 0x2;
const o_noctty: c_int = switch (builtin.os.tag) {
    .linux => 0x100,
    .macos => 0x20000,
    else => 0,
};
// O_CLOEXEC on the parent end (posix_openpt, honored on Linux, ignored on
// Darwin) and on the child end (open, honored on both — the atomic close
// of the inheritance race).
const o_cloexec_open: c_int = switch (builtin.os.tag) {
    .linux => 0x80000,
    .macos => 0x1000000,
    else => 0,
};
const sigterm: c_int = 15;
const sigkill: c_int = 9;
const sighup: c_int = 1;
const eintr: c_int = 4;
const eio: c_int = 5;
const echild: c_int = 10;
// EAGAIN (== EWOULDBLOCK on both platforms): no progress on a
// non-blocking fd right now.
const eagain: c_int = switch (builtin.os.tag) {
    .linux => 11,
    .macos => 35,
    else => 11,
};
// F_DUPFD_CLOEXEC differs by platform.
const f_dupfd_cloexec: c_int = switch (builtin.os.tag) {
    .linux => 1030,
    .macos => 67,
    else => 0,
};

fn errnoValue() c_int {
    return switch (builtin.os.tag) {
        .macos => c.__error().*,
        .linux => c.__errno_location().*,
        else => 0,
    };
}

/// libc externs for the fork/exec/pty path. Resolved through the C library
/// the platform layer already links; `openpty`/`login_tty` live in libutil
/// on Linux (linked by the platform build) and in libSystem on macOS.
const c = struct {
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn login_tty(fd: c_int) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn execve(
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn usleep(usec: c_uint) c_int;
    // ioctl is variadic in C; declaring it variadic here matches the
    // platform ABI for the winsize pointer argument (a fixed-arg
    // declaration mis-passes it on arm64, silently dropping the size).
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn pipe2(fds: *[2]c_int, flags: c_uint) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn poll(fds: [*]Pollfd, nfds: c_uint, timeout: c_int) c_int;
    extern "c" fn __error() *c_int; // Darwin errno
    extern "c" fn __errno_location() *c_int; // Linux errno
};

/// A nudge pipe for the io thread: [read end, write end]. BOTH ends are
/// non-blocking (the write side so a burst of loop-thread nudges against
/// a full pipe can never block the UI loop — a full pipe already means a
/// wake is pending; the read side so the eager drain never parks the io
/// thread) and BOTH ends are close-on-exec: a pty child inherits every
/// parent fd across fork, and without CLOEXEC a daemonized descendant
/// would keep these descriptors — and the pipe itself — alive past the
/// runtime closing its copies. The child needs neither end.
pub fn pipePair() Error![2]c_int {
    if (comptime !supported) return error.PtyUnsupported;
    // Under the spawn lock: Darwin's pipe-then-fcntl flag gap is a
    // descriptor-inheritance window exactly like the spawn's own, so no
    // PTY fork can inherit a not-yet-CLOEXEC wake pipe across its exec.
    // Forks the lock does not cover (job spawns, whose process start
    // blocks on its own exec pipe and must never hold a lock the UI
    // loop takes; embedder forks on foreign threads) are the bounded
    // residual: inherited copies die at those children's execs, and the
    // one lasting effect — a delayed exec-pipe EOF — is resolved by the
    // carried reap-time verdict.
    pty_spawn_mutex.lock();
    defer pty_spawn_mutex.unlock();
    return makePipe(true);
}

/// Create a pipe with both ends close-on-exec (and, when `nonblock`,
/// non-blocking). On Linux the flags are set ATOMICALLY at creation via
/// `pipe2`, closing the concurrent-fork inheritance window entirely; on
/// Darwin (no `pipe2`) the flags are applied with `fcntl` immediately
/// after, and the exec self-pipe's poll timeout is the net for the
/// residual sub-syscall window. A failed setup closes both ends and
/// aborts. CLOEXEC is load-bearing (an inherited exec-pipe writer would
/// delay EOF; an inherited wake pipe would leak); non-blocking is
/// load-bearing on the wake pipe (a full pipe must never block the UI
/// thread inside `nudge`).
fn makePipe(nonblock: bool) Error![2]c_int {
    var fds: [2]c_int = undefined;
    if (comptime builtin.os.tag == .linux) {
        var flags: c_uint = o_cloexec;
        if (nonblock) flags |= o_nonblock_flag;
        if (c.pipe2(&fds, flags) != 0) return error.PtyOpenFailed;
        return fds;
    }
    if (c.pipe(&fds) != 0) return error.PtyOpenFailed;
    for (fds) |fd| {
        if (nonblock) {
            const flags = c.fcntl(fd, f_getfl, @as(c_int, 0));
            if (flags < 0 or c.fcntl(fd, f_setfl, flags | o_nonblock) < 0) {
                _ = c.close(fds[0]);
                _ = c.close(fds[1]);
                return error.PtyOpenFailed;
            }
        }
        if (!setCloexec(fd)) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return error.PtyOpenFailed;
        }
    }
    return fds;
}

pub fn closeFd(fd: c_int) void {
    if (comptime !supported) return;
    if (fd >= 0) _ = c.close(fd);
}

/// Write one byte into the nudge pipe. EINTR retries — losing the only
/// wake would strand staged outbound bytes; a full pipe (EAGAIN) is a
/// nudge already coalesced and returns.
pub fn nudge(fd: c_int) void {
    if (comptime !supported) return;
    const byte = [_]u8{1};
    while (true) {
        if (c.write(fd, &byte, 1) >= 0) return;
        if (errnoValue() == eintr) continue;
        return;
    }
}

/// Drain whatever accumulated in the nudge pipe.
pub fn drainNudges(fd: c_int) void {
    if (comptime !supported) return;
    var buf: [64]u8 = undefined;
    _ = c.read(fd, &buf, buf.len);
}

/// What one poll round observed.
pub const Ready = struct {
    readable: bool = false,
    writable: bool = false,
    hangup: bool = false,
    nudged: bool = false,
};

/// Block until the parent end is readable (`want_read`), writable
/// (`want_write`), hung up, or the nudge pipe fires. A caller wanting
/// NEITHER parent-end direction (a parked reader with nothing to write)
/// waits on the nudge pipe alone — POLLHUP is unmaskable, so keeping
/// the parent end in the set would turn a hangup racing a full staging
/// ring into a busy loop.
pub fn wait(parent: c_int, nudge_fd: c_int, want_read: bool, want_write: bool) Ready {
    if (comptime !supported) return .{};
    const parent_events: c_short = (if (want_read) pollin else 0) | (if (want_write) pollout else 0);
    var fds = [2]Pollfd{
        .{ .fd = nudge_fd, .events = pollin, .revents = 0 },
        .{ .fd = parent, .events = parent_events, .revents = 0 },
    };
    const nfds: c_uint = if (parent_events == 0) 1 else 2;
    const r = c.poll(&fds, nfds, -1);
    if (r < 0) return .{};
    return .{
        .readable = nfds == 2 and fds[1].revents & pollin != 0,
        .writable = nfds == 2 and fds[1].revents & pollout != 0,
        .hangup = nfds == 2 and fds[1].revents & (pollhup | pollerr) != 0,
        .nudged = fds[0].revents & pollin != 0,
    };
}

const Pollfd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

// POLLIN/POLLOUT/POLLERR/POLLHUP share values on Linux and Darwin.
const pollin: c_short = 0x1;
const pollout: c_short = 0x4;
const pollerr: c_short = 0x8;
const pollhup: c_short = 0x10;

// ------------------------------------------------------------------ tests

/// Read the child's whole output, polling the non-blocking parent end to
/// EOF — the effects io loop's poll discipline, condensed for the
/// in-file tests (which have no effects channel).
fn testReadAll(p: Pty, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const ready = wait(p.parent, p.parent, true, false);
        if (p.read(buf[total..])) |n| {
            if (n == 0) return total; // EOF
            total += n;
        } else |err| switch (err) {
            error.WouldBlock => {
                if (ready.hangup) return total;
            },
            error.ReadFailed => return total,
        }
    }
    return total;
}

test "spawn rejects an empty argv and a missing command" {
    if (comptime !supported) return;
    try std.testing.expectError(error.PtyArgvInvalid, spawn(std.testing.allocator, .{ .argv = &.{} }));
    try std.testing.expectError(error.PtyCommandNotFound, spawn(std.testing.allocator, .{
        .argv = &.{"/nonexistent/never-a-command"},
    }));
}

test "live pty round trip: output, exit code, controlling terminal" {
    if (comptime !supported) return;
    const p = try spawn(std.testing.allocator, .{
        // `test -t 0` proves fd 0 is a real terminal — the controlling-tty
        // wiring, not just a pipe with a fancy name.
        .argv = &.{ "/bin/sh", "-c", "test -t 0 && printf hello; exit 7" },
        .cols = 40,
        .rows = 10,
    });
    defer p.close();
    var buf: [256]u8 = undefined;
    const total = testReadAll(p, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "hello") != null);
    const exit = p.reapBlocking();
    try std.testing.expectEqual(@as(i32, 7), exit.code);
    try std.testing.expectEqual(@as(i32, 0), exit.signal);
}

test "kill reports the terminating signal" {
    if (comptime !supported) return;
    const p = try spawn(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } });
    defer p.close();
    p.resize(100, 30);
    p.kill(false);
    const exit = p.reapBlocking();
    try std.testing.expectEqual(@as(i32, -1), exit.code);
    try std.testing.expectEqual(@as(i32, 9), exit.signal);
}

test "the child environment is exactly env plus TERM" {
    if (comptime !supported) return;
    const p = try spawn(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s|%s|%s' \"$TERM\" \"$MARKER\" \"$HOME\"" },
        .env = &.{.{ .name = "MARKER", .value = "pty-proof" }},
    });
    defer p.close();
    var buf: [256]u8 = undefined;
    const total = testReadAll(p, &buf);
    _ = p.reapBlocking();
    const out = buf[0..total];
    // TERM injected, MARKER passed through, HOME absent (clean env).
    try std.testing.expect(std.mem.indexOf(u8, out, default_term ++ "|pty-proof|") != null);
}

test "a late exec-failure byte on the carried status pipe converts at reap time" {
    if (comptime !supported) return;
    // The unresolved-probe carry: a failure byte written after the
    // probe's deadline is read — non-blocking — at reap time.
    const with_byte = try makePipe(true);
    const byte = [_]u8{1};
    _ = c.write(with_byte[1], &byte, 1);
    const failed_pty: Pty = .{ .parent = -1, .pid = -1, .exec_status = with_byte[0] };
    try std.testing.expect(failed_pty.lateExecFailure());
    _ = c.close(with_byte[0]);
    _ = c.close(with_byte[1]);

    // No byte before the child died means the exec succeeded: an empty
    // (or closed) pipe reads as success and never blocks.
    const without_byte = try makePipe(true);
    _ = c.close(without_byte[1]);
    const started_pty: Pty = .{ .parent = -1, .pid = -1, .exec_status = without_byte[0] };
    try std.testing.expect(!started_pty.lateExecFailure());
    _ = c.close(without_byte[0]);

    // A spawn whose probe resolved carries no pipe: never a late report.
    const resolved_pty: Pty = .{ .parent = -1, .pid = -1 };
    try std.testing.expect(!resolved_pty.lateExecFailure());
}

test "an exec failure is reported, not masqueraded as a normal exit" {
    if (comptime !supported) return;
    // A directory passes the X_OK (searchable) check but execve refuses
    // it — the exec self-pipe turns that into PtyCommandNotFound rather
    // than a forked child that exits 127 on its own.
    try std.testing.expectError(error.PtyCommandNotFound, spawn(std.testing.allocator, .{ .argv = &.{"/"} }));
}

test "embedded NUL in argv is rejected, never truncated" {
    if (comptime !supported) return;
    try std.testing.expectError(error.PtyArgvInvalid, spawn(std.testing.allocator, .{ .argv = &.{ "/bin/echo", "abc\x00def" } }));
}
