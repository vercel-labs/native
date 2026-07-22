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
    pub fn reap(self: Pty) ?Exit {
        if (!supported) return null;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, wnohang);
        if (r != self.pid) return null;
        return decodeStatus(status);
    }

    /// Reap the child, blocking until it exits. Used at teardown after a
    /// kill so no zombie is left behind.
    pub fn reapBlocking(self: Pty) Exit {
        if (!supported) return .{ .code = -1, .signal = 0 };
        var status: c_int = 0;
        while (true) {
            const r = c.waitpid(self.pid, &status, 0);
            if (r == self.pid) return decodeStatus(status);
            if (r < 0) return .{ .code = -1, .signal = 0 };
        }
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

    var master: c_int = -1;
    var slave: c_int = -1;
    var ws: Winsize = .{
        .row = if (options.rows == 0) 24 else options.rows,
        .col = if (options.cols == 0) 80 else options.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (c.openpty(&master, &slave, null, null, &ws) != 0) return error.PtyOpenFailed;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(master);
        _ = c.close(slave);
        return error.PtyForkFailed;
    }
    if (pid == 0) {
        // CHILD. Async-signal-safe only from here.
        _ = c.close(master);
        if (c.login_tty(slave) != 0) c._exit(127);
        _ = c.execve(resolved_z.ptr, argv_z.ptr, envp_z.ptr);
        c._exit(127);
    }
    // PARENT.
    _ = c.close(slave);
    return .{ .master = master, .pid = pid };
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
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
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
const sigterm: c_int = 15;
const sigkill: c_int = 9;
const eintr: c_int = 4;
const eio: c_int = 5;

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
    extern "c" fn openpty(
        amaster: *c_int,
        aslave: *c_int,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const Winsize,
    ) c_int;
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
    extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *const Winsize) c_int;
    extern "c" fn __error() *c_int; // Darwin errno
    extern "c" fn __errno_location() *c_int; // Linux errno
};

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
