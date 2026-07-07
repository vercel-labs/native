//! Automation command ARRIVAL watcher: the liveness half of the dropbox
//! protocol. The runtime drains at most one command per `frame_requested`
//! turn, but an idle app has no reason to run a frame — no animation, no
//! input, nothing invalidated — so a queued `widget-click` used to sit in
//! the queue until some unrelated timer happened to produce a frame (or,
//! on hosts without such a timer, forever). This watcher makes a command
//! LANDING wake the loop the same way user input does: a dedicated
//! thread polls the command queue off the loop thread and, while an
//! entry is pending, asks the platform for one coalesced `frame_requested`
//! tick through the platform's thread-safe frame-request entry. The
//! drain on the loop thread stays the ONLY consumer, so command order,
//! the one-command-per-frame cadence, and session-replay determinism
//! (commands nest inside recorded `frame_requested` events) are all
//! exactly what they were — the only change is that the frame arrives
//! now instead of whenever.
//!
//! Cost model: this thread exists only while an automation server is
//! configured (a Debug/dev build flag), so a production build carries
//! zero overhead — no thread, no polls, no wakes. While automation IS
//! on, the poll is a single small-file read every few milliseconds on a
//! background thread; the platform loop itself stays completely idle
//! until a command actually lands.

const std = @import("std");
const server_module = @import("server.zig");

/// How often the watcher thread probes the command queue. Small enough
/// that a driver's command starts dispatching within a frame or two of
/// landing (the CLI itself only polls the ack at 25ms), large enough
/// that the probe — one open/read/close of a tiny file — is noise even
/// on a loaded machine.
pub const poll_interval_ns: u64 = 5 * std.time.ns_per_ms;

/// The platform loop's thread-safe frame-request entry, type-erased so
/// this module never imports the platform layer. Mirrors the shape of
/// `PlatformServices.request_frame_fn`; the runtime builds one from the
/// live services table before spawning the watcher.
pub const FrameRequester = struct {
    context: ?*anyopaque,
    request_fn: *const fn (context: ?*anyopaque) anyerror!void,

    pub fn request(self: FrameRequester) anyerror!void {
        return self.request_fn(self.context);
    }
};

pub const Watcher = struct {
    server: server_module.Server,
    requester: FrameRequester,
    stop_requested: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Spawn the watcher thread. Returns false (watcher inert) when the
    /// thread cannot start; the caller logs and the app still runs — it
    /// merely keeps the old wait-for-any-frame consumption.
    pub fn start(self: *Watcher, server_value: server_module.Server, requester: FrameRequester) bool {
        self.* = .{ .server = server_value, .requester = requester };
        self.thread = std.Thread.spawn(.{}, main, .{self}) catch return false;
        return true;
    }

    /// Stop and join the watcher. Called before the platform is torn
    /// down so the requester's context can never dangle: after join, no
    /// further requests are in flight FROM this thread (a request the
    /// platform already marshalled onto its own loop is the platform's
    /// to guard, exactly like its cross-thread wake).
    pub fn stop(self: *Watcher) void {
        const thread = self.thread orelse return;
        self.stop_requested.store(true, .release);
        thread.join();
        self.thread = null;
    }

    fn main(self: *Watcher) void {
        while (!self.stop_requested.load(.acquire)) {
            // Request a tick on EVERY probe while an entry is pending,
            // not just the first: the request is coalesced platform-side,
            // and one wake per probe also keeps a MULTI-entry queue
            // draining frame after frame until it is empty. Request
            // failures are swallowed — the watcher is
            // best-effort liveness, and the drain still runs on any
            // frame that arrives for another reason.
            if (self.server.hasPendingCommand()) {
                self.requester.request() catch {};
            }
            std.Io.sleep(
                self.server.io,
                std.Io.Duration.fromNanoseconds(poll_interval_ns),
                .awake,
            ) catch return;
        }
    }
};

/// Pid-suffixed dropbox for tests: this module's tests are compiled into
/// more than one test binary, and the aggregate build step runs those
/// binaries in parallel — a fixed path would let two copies of the same
/// test delete each other's slot mid-run.
pub fn testDirectory(buffer: []u8, comptime prefix: []const u8) ![]const u8 {
    const pid: u32 = switch (@import("builtin").os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi, .freestanding, .emscripten => 0,
        else => @intCast(@max(0, std.posix.system.getpid())),
    };
    return std.fmt.bufPrint(buffer, prefix ++ "-{d}", .{pid});
}

test "watcher requests frames while a command is pending" {
    var dir_buffer: [64]u8 = undefined;
    const directory = try testDirectory(&dir_buffer, ".zig-cache/test-automation-watcher");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, directory) catch {};
    try cwd.createDirPath(std.testing.io, directory);
    defer cwd.deleteTree(std.testing.io, directory) catch {};

    const Counter = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn request(context: ?*anyopaque) anyerror!void {
            const counter: *@This() = @ptrCast(@alignCast(context.?));
            _ = counter.count.fetchAdd(1, .release);
        }
    };
    var counter: Counter = .{};

    const server_value = server_module.Server.init(std.testing.io, directory, "Test");
    var watcher: Watcher = undefined;
    try std.testing.expect(watcher.start(server_value, .{
        .context = &counter,
        .request_fn = Counter.request,
    }));
    defer watcher.stop();

    // Idle queue: give the watcher a few polls; no frame requests. A
    // leftover non-queue file (a retired-v5 writer's `command.txt`)
    // stays invisible — the watcher must not wake the loop for traffic
    // this protocol version never consumes.
    var path_buffer: [96]u8 = undefined;
    try cwd.writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command.txt", .{directory}),
        .data = "widget-click canvas 7\n",
    });
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(4 * poll_interval_ns), .awake);
    try std.testing.expectEqual(@as(usize, 0), counter.count.load(.acquire));

    // A landed queue entry turns into frame requests promptly.
    try cwd.writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-1.txt", .{directory}),
        .data = "widget-click canvas 7\n",
    });
    var waited_ns: u64 = 0;
    while (counter.count.load(.acquire) == 0 and waited_ns < std.time.ns_per_s) {
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(poll_interval_ns), .awake);
        waited_ns += poll_interval_ns;
    }
    try std.testing.expect(counter.count.load(.acquire) > 0);

    // Consuming the command (the drain's ack) goes quiet again.
    var buffer: [256]u8 = undefined;
    _ = try server_value.takeCommand(&buffer);
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(2 * poll_interval_ns), .awake);
    const settled = counter.count.load(.acquire);
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(4 * poll_interval_ns), .awake);
    try std.testing.expectEqual(settled, counter.count.load(.acquire));
}
