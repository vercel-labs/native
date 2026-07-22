//! POSIX pseudo-terminal primitive: open a pty pair, fork a child with the
//! slave as its controlling terminal, and hand the caller the master fd to
//! read output from and write input to. macOS and Linux only — every other
//! target compiles to the `error.PtyUnsupported` stubs so the effects layer
//! reports the same loud rejection the null platform's fake pty stands in
//! for under test.
//!
//! This is the one place the toolkit forks a child onto a terminal. It
//! deliberately does NOT use `std.process.spawn`: a pty child needs a
//! controlling terminal (`login_tty` = setsid + TIOCSCTTY + dup of the
//! slave onto fds 0/1/2), which the generic spawn path does not set up.
//! Everything the child touches between fork and exec is async-signal-safe:
//! argv/envp are built in the PARENT (including the `TERM` override and the
//! PATH resolution of argv[0]), so the child calls only `login_tty`,
//! `execve`, and `_exit` — no allocator, no `setenv`, none of the
//! fork-in-a-threaded-process hazards a mid-child `malloc` would invite.

const std = @import("std");
const builtin = @import("builtin");

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

/// A live pty: the master fd plus the child pid. Reads and writes go to
/// `master`; `pid` is signalled for kill and reaped on exit.
pub const Pty = struct {
    master: c_int,
    pid: c_int,

    /// Read available output bytes into `buf`. Returns 0 at EOF — which a
    /// pty master reports as EIO on Linux once the child exits, normalized
    /// here — and `error.ReadFailed` for anything else.
    pub fn read(self: Pty, buf: []u8) error{ReadFailed}!usize {
        while (true) {
            const r = c.read(self.master, buf.ptr, buf.len);
            if (r >= 0) return @intCast(r);
            switch (errnoValue()) {
                eintr => continue,
                // EIO from a pty master is the hangup after child exit:
                // the stream is over, not broken.
                eio => return 0,
                else => return error.ReadFailed,
            }
        }
    }

    /// Write input bytes toward the child. Partial writes are possible;
    /// the caller loops.
    pub fn write(self: Pty, bytes: []const u8) error{WriteFailed}!usize {
        while (true) {
            const r = c.write(self.master, bytes.ptr, bytes.len);
            if (r >= 0) return @intCast(r);
            switch (errnoValue()) {
                eintr => continue,
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
        _ = c.ioctl(self.master, tiocswinsz, &ws);
    }

    /// Signal the child's process group. `graceful` sends SIGTERM (let the
    /// shell clean up); otherwise SIGKILL. The child was placed in its own
    /// session by `login_tty`, so signalling the negated pid reaches the
    /// whole job, not just the direct child.
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
    /// always arrives and no zombie is left — the fix for a `reapBlocking`
    /// that would otherwise wait forever on such a child while a kill is
    /// skipped. The caller publishes `reaping` before this so no
    /// concurrent kill signals the (soon-freed) pid.
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
        // SIGKILL cannot be caught; this wait is bounded.
        return self.reapBlocking();
    }

    /// Close the master fd. The child is expected to be reaped separately.
    pub fn close(self: Pty) void {
        if (!supported) return;
        _ = c.close(self.master);
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
/// the master fd and the child pid. The child's environment is exactly the
/// caller's `env` (or empty) plus a `TERM` entry — no host variables leak
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
    // Open the pty pair by hand rather than `openpty`, so the SLAVE is
    // opened close-on-exec ATOMICALLY (`open` with O_CLOEXEC). The slave
    // is the descriptor that matters for the inheritance race the
    // reviewer flagged: if a concurrent fork on another thread inherited
    // a non-CLOEXEC slave across its exec, it would hold THIS pty open
    // after our child exits, so no EOF and no `.exit` event ever
    // arrives. `posix_openpt` + `grantpt` + `unlockpt` is the portable
    // primitive underneath `openpty`; the master's CLOEXEC is applied
    // immediately after (Linux honors O_CLOEXEC on `posix_openpt`
    // directly; Darwin ignores it, leaving only the master a
    // sub-syscall window — benign, since an inherited MASTER does not
    // hold the pty open). pty spawns run on the loop thread, so
    // `ptsname`'s static buffer is not raced.
    const master = c.posix_openpt(o_rdwr | o_noctty | o_cloexec_open);
    if (master < 0) return error.PtyOpenFailed;
    _ = setCloexec(master);
    if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) {
        _ = c.close(master);
        return error.PtyOpenFailed;
    }
    const slave_name = c.ptsname(master) orelse {
        _ = c.close(master);
        return error.PtyOpenFailed;
    };
    var slave = c.open(slave_name, o_rdwr | o_noctty | o_cloexec_open, @as(c_uint, 0));
    if (slave < 0) {
        _ = c.close(master);
        return error.PtyOpenFailed;
    }
    // Keep the slave off the standard descriptors: `login_tty` dup2's it
    // onto 0/1/2, and dup2 CLEARS close-on-exec on its copies — but a
    // SAME-fd dup2 (slave already IS fd 0/1/2, which happens when the
    // host started with standard descriptors closed) is a no-op that
    // leaves the CLOEXEC flag set, so the child's stdio would vanish at
    // execve. Relocating to a high fd (F_DUPFD_CLOEXEC) guarantees the
    // dup2 targets are distinct and their CLOEXEC gets cleared.
    if (slave < 3) {
        const high = c.fcntl(slave, f_dupfd_cloexec, @as(c_int, 3));
        if (high < 0) {
            _ = c.close(slave);
            _ = c.close(master);
            return error.PtyOpenFailed;
        }
        _ = c.close(slave);
        slave = high;
    }
    // Push the initial window size onto the slave (the child's terminal)
    // before the fork so the child's very first TIOCGWINSZ sees the
    // requested grid. `openpty` applied its `winp` to the slave; match
    // that — setting it on the master does not reliably propagate before
    // the slave becomes a controlling terminal.
    _ = c.ioctl(slave, tiocswinsz, &ws);

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
    const exec_pipe = makePipe(false) catch {
        _ = c.close(master);
        _ = c.close(slave);
        return error.PtyOpenFailed;
    };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(master);
        _ = c.close(slave);
        _ = c.close(exec_pipe[0]);
        _ = c.close(exec_pipe[1]);
        return error.PtyForkFailed;
    }
    if (pid == 0) {
        // CHILD. Async-signal-safe only from here.
        _ = c.close(master);
        _ = c.close(exec_pipe[0]);
        if (c.login_tty(slave) != 0) reportExecFailure(exec_pipe[1]);
        _ = c.execve(resolved_z.ptr, argv_z.ptr, envp_z.ptr);
        reportExecFailure(exec_pipe[1]);
    }
    // PARENT.
    _ = c.close(slave);
    _ = c.close(exec_pipe[1]);
    // A failure byte, EOF, or the timeout resolves exec status. A real
    // exec failure writes its byte into the pipe buffer INSTANTLY (the
    // child's write lands before its _exit), so a byte always means
    // failure regardless of who else holds a writer. EOF (every writer
    // closed) is the fast success signal. The timeout is the safety net
    // for the residual CLOEXEC window: if a process spawn on another
    // thread forked in the instant between this pipe's creation and its
    // fcntl and its exec'd child inherited a copy of the write end, EOF
    // is delayed until THAT process exits — but no failure byte arrived,
    // so exec succeeded, and we proceed rather than hang. Bounded at a
    // few seconds, orders of magnitude past a real exec.
    const failed = execFailed(exec_pipe[0]);
    _ = c.close(exec_pipe[0]);
    if (failed) {
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0 and errnoValue() == eintr) {}
        _ = c.close(master);
        return error.PtyCommandNotFound;
    }
    return .{ .master = master, .pid = pid };
}

/// CHILD-side exec-failure report: write the errno byte into the self-
/// pipe and exit. Async-signal-safe — a single `write` and `_exit`.
fn reportExecFailure(write_fd: c_int) noreturn {
    const byte = [_]u8{1};
    _ = c.write(write_fd, &byte, 1);
    c._exit(127);
}

fn setCloexec(fd: c_int) bool {
    const flags = c.fcntl(fd, f_getfd, @as(c_int, 0));
    if (flags < 0) return false;
    return c.fcntl(fd, f_setfd, flags | fd_cloexec) >= 0;
}

/// Resolve exec status from the self-pipe read end without ever
/// blocking indefinitely: poll for a failure byte, EOF, or a timeout.
/// A byte (the child's errno report) means exec FAILED. EOF (every
/// writer closed via CLOEXEC on a successful exec) means it SUCCEEDED.
/// The timeout also means success — it can only be reached when a
/// concurrent fork's child inherited a copy of the write end in the
/// CLOEXEC-setup window (delaying EOF), and no failure byte arrived, so
/// our own exec succeeded. Bounded so that residual race can never hang
/// the spawning thread.
fn execFailed(fd: c_int) bool {
    const timeout_ms: c_int = 5000;
    var fds = [1]Pollfd{.{ .fd = fd, .events = pollin, .revents = 0 }};
    while (true) {
        const r = c.poll(&fds, 1, timeout_ms);
        if (r < 0) {
            if (errnoValue() == eintr) continue;
            return false;
        }
        if (r == 0) return false; // timeout: exec succeeded (see above)
        // Readable or hung up: a byte present is failure; a clean EOF
        // (readable, zero bytes) is success.
        if (fds[0].revents & pollin != 0) {
            var probe: [1]u8 = undefined;
            const n = c.read(fd, &probe, 1);
            if (n > 0) return true;
            if (n < 0 and errnoValue() == eintr) continue;
            return false;
        }
        // POLLHUP/POLLERR with no data: the writer closed on exec.
        return false;
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
// O_CLOEXEC on the master (posix_openpt, honored on Linux, ignored on
// Darwin) and on the slave (open, honored on both — the atomic close of
// the inheritance race).
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

/// Block until the master is readable (`want_read`), writable
/// (`want_write`), hung up, or the nudge pipe fires. A caller wanting
/// NEITHER master direction (a parked reader with nothing to write)
/// waits on the nudge pipe alone — POLLHUP is unmaskable, so keeping
/// the master in the set would turn a hangup racing a full staging
/// ring into a busy loop.
pub fn wait(master: c_int, nudge_fd: c_int, want_read: bool, want_write: bool) Ready {
    if (comptime !supported) return .{};
    const master_events: c_short = (if (want_read) pollin else 0) | (if (want_write) pollout else 0);
    var fds = [2]Pollfd{
        .{ .fd = nudge_fd, .events = pollin, .revents = 0 },
        .{ .fd = master, .events = master_events, .revents = 0 },
    };
    const nfds: c_uint = if (master_events == 0) 1 else 2;
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
    var total: usize = 0;
    while (total < buf.len) {
        const n = p.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
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
    var total: usize = 0;
    while (total < buf.len) {
        const n = p.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = p.reapBlocking();
    const out = buf[0..total];
    // TERM injected, MARKER passed through, HOME absent (clean env).
    try std.testing.expect(std.mem.indexOf(u8, out, default_term ++ "|pty-proof|") != null);
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
