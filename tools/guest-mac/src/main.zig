//! guest-mac — an in-repo macOS guest VM host for live-GUI agent work.
//!
//! One binary, two faces:
//! - `guest-mac` (no verb) runs the windowed Native SDK app: chrome around
//!   the live guest display (src/ui.zig).
//! - Headless verbs for agents: `fetch`, `install`, `start`, `stop`,
//!   `status`, `ip` (src/cli.zig parses; this file executes). `stop`,
//!   `status`, and `ip` are pure file/signal verbs that work from any
//!   process; `fetch`/`install`/`start` drive the Virtualization engine
//!   (src/vm_host.m) and therefore need this signed binary.
//!
//! See agents.md (in this directory) for the agent workflow and README.md
//! for the provisioning story.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const cli = @import("cli.zig");
const vm = @import("vm.zig");
const ui = @import("ui.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

var signal_flag = std.atomic.Value(u32).init(0);
var stdout_io: ?std.Io = null;

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    _ = signal_flag.fetchAdd(1, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    stdout_io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const command = cli.parse(if (args.len > 1) args[1..] else &.{}) catch {
        std.debug.print("{s}", .{cli.usage});
        std.process.exit(2);
    };

    switch (command.verb) {
        .help => std.debug.print("{s}", .{cli.usage}),
        .app => try runApp(init),
        .fetch => try runFetch(),
        .install => try runInstall(command),
        .start => try runStart(command),
        .stop => try runStop(command),
        .status => try runStatus(),
        .ip => try runIp(command),
    }
}

// ---- windowed app -----------------------------------------------------------

fn runApp(init: std.process.Init) !void {
    var app = ui.GuestMacApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "guest-mac",
        .window_title = "Guest macOS",
        .bundle_id = "dev.native_sdk.guest_mac",
        .icon_path = "assets/icon.icns",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, 1360, 900),
        .js_window_api = false,
        .security = .{ .permissions = &ui.app_permissions },
    }, init);
}

// ---- engine-backed verbs -----------------------------------------------------

const EngineSession = struct {
    events: vm.Events = .{},
    paths: vm.Paths = .{},
    engine: vm.Engine = undefined,

    fn open(self: *EngineSession) !void {
        const home = vm.homeDir() orelse fail("HOME is not set");
        self.paths = try vm.resolvePaths(home);
        self.events.log_to_stderr = true;
        self.engine = vm.Engine.create(self.paths.bundleDir(), self.paths.cacheDir(), &self.events) catch {
            fail("Virtualization engine unavailable (Apple silicon macOS 13+, signed binary required)");
        };
    }
};

fn runFetch() !void {
    var session: EngineSession = .{};
    try session.open();
    try session.engine.fetchRestoreImage();
    var last_percent: u32 = 0;
    while (session.events.ipswPath() == null) {
        if (session.events.failed) fail(session.events.lastMessage());
        vm.pumpMainLoop(0.25);
        const percent: u32 = @intFromFloat(session.events.download_progress * 100);
        if (percent != last_percent and percent % 5 == 0) {
            last_percent = percent;
            std.debug.print("guest-mac: download {d}%\n", .{percent});
        }
    }
    printLine("{s}", .{session.events.ipswPath().?});
}

fn runInstall(command: cli.Command) !void {
    var session: EngineSession = .{};
    try session.open();
    if (session.events.state != .no_bundle) fail("VM bundle already installed — delete the bundle dir to reinstall");

    var ipsw = command.ipsw;
    if (ipsw == null) {
        try session.engine.fetchRestoreImage();
        while (session.events.ipswPath() == null) {
            if (session.events.failed) fail(session.events.lastMessage());
            vm.pumpMainLoop(0.25);
        }
        ipsw = session.events.ipswPath();
    }
    try session.engine.install(ipsw.?, command.cpus, command.memory_gb << 30, command.disk_gb << 30);
    var last_percent: u32 = 0;
    while (session.events.state == .installing or session.events.state == .no_bundle) {
        if (session.events.failed) fail(session.events.lastMessage());
        vm.pumpMainLoop(0.5);
        const percent: u32 = @intFromFloat(session.events.install_progress * 100);
        if (percent != last_percent) {
            last_percent = percent;
            std.debug.print("guest-mac: install {d}%\n", .{percent});
        }
    }
    if (session.events.failed or session.events.state == .err) fail(session.events.lastMessage());
    printLine("installed: {s}", .{session.paths.bundleDir()});
}

fn runStart(command: cli.Command) !void {
    var session: EngineSession = .{};
    try session.open();
    if (session.events.state == .no_bundle) fail("no VM bundle — run `guest-mac install` first");
    if (runningInstancePid(&session.paths)) |pid| {
        var buffer: [96]u8 = undefined;
        fail(std.fmt.bufPrint(&buffer, "guest already running (pid {d})", .{pid}) catch "guest already running");
    }

    var cwd_buffer: [512]u8 = undefined;
    const share_dir = command.share orelse vm.repoRootOrCwd(&cwd_buffer);
    std.debug.print("guest-mac: sharing {s} as virtio-fs tag \"{s}\"\n", .{ share_dir, command.tag });

    try session.engine.configure(share_dir, command.tag, command.cpus, command.memory_gb << 30);
    if (session.events.failed) fail(session.events.lastMessage());
    try session.engine.start();

    installSignalHandlers();
    var stop_requested = false;
    var force_sent = false;
    var ip_reported = false;
    while (true) {
        vm.pumpMainLoop(0.25);
        // Once a stop is in flight, errors are shutdown noise (e.g. a
        // force stop racing the guest's own shutdown) — keep draining
        // until the engine reports stopped.
        if (session.events.failed and !stop_requested) fail(session.events.lastMessage());
        const state = session.events.state;
        if (state == .stopped) break;
        const signals = signal_flag.load(.monotonic);
        if (signals > 0 and !stop_requested) {
            stop_requested = true;
            std.debug.print("guest-mac: stop requested — asking the guest to shut down\n", .{});
            session.engine.requestStop() catch session.engine.forceStop() catch {};
        } else if (signals > 1 and !force_sent) {
            force_sent = true;
            std.debug.print("guest-mac: force stopping\n", .{});
            session.engine.forceStop() catch {};
        }
        if (state == .running and !ip_reported) {
            if (currentGuestIp(session.engine)) |ip| {
                ip_reported = true;
                printLine("running ip={s}", .{ip});
            }
        }
    }
    std.debug.print("guest-mac: guest stopped\n", .{});
}

// ---- pure file/signal verbs ---------------------------------------------------

fn runStop(command: cli.Command) !void {
    const home = vm.homeDir() orelse fail("HOME is not set");
    var paths = try vm.resolvePaths(home);
    const pid = runningInstancePid(&paths) orelse {
        printLine("not running", .{});
        return;
    };
    if (command.force) {
        try std.posix.kill(pid, .KILL);
        printLine("killed pid {d}", .{pid});
        return;
    }
    try std.posix.kill(pid, .TERM);
    // The owning process requests a graceful guest shutdown and exits once
    // the guest is down; wait for that (Setup-Assistant-fresh guests can
    // take a minute).
    var waited: u32 = 0;
    while (waited < 120) : (waited += 1) {
        if (runningInstancePid(&paths) == null) {
            printLine("stopped", .{});
            return;
        }
        vm.pumpMainLoop(1.0);
    }
    fail("guest did not stop within 120s — retry with --force");
}

fn runStatus() !void {
    const home = vm.homeDir() orelse fail("HOME is not set");
    var paths = try vm.resolvePaths(home);

    var disk_path_buffer: [600]u8 = undefined;
    const disk_path = try std.fmt.bufPrint(&disk_path_buffer, "{s}/Disk.img", .{paths.bundleDir()});
    const installed = vm.fileExists(disk_path);
    printLine("bundle: {s} ({s})", .{ if (installed) "installed" else "missing", paths.bundleDir() });

    if (runningInstancePid(&paths)) |pid| {
        var state_path_buffer: [600]u8 = undefined;
        var content_buffer: [1024]u8 = undefined;
        const state_path = try paths.stateFilePath(&state_path_buffer);
        const parsed = cli.parseStateFile(vm.readFileInto(state_path, &content_buffer) orelse "");
        printLine("state: {s} (pid {d})", .{ parsed.state, pid });
    } else {
        printLine("state: stopped", .{});
    }
}

fn runIp(command: cli.Command) !void {
    const home = vm.homeDir() orelse fail("HOME is not set");
    var paths = try vm.resolvePaths(home);
    var config_path_buffer: [600]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buffer, "{s}/config.json", .{paths.bundleDir()});
    var config_buffer: [4096]u8 = undefined;
    const config = vm.readFileInto(config_path, &config_buffer) orelse fail("no VM bundle config — install first");
    const mac = cli.macFromConfig(config) orelse fail("bundle config has no MAC address");

    var waited: u32 = 0;
    while (true) {
        var leases_buffer: [64 * 1024]u8 = undefined;
        if (vm.readFileInto(vm.dhcpd_leases_path, &leases_buffer)) |leases| {
            if (cli.leaseIpForMac(leases, mac)) |ip| {
                printLine("{s}", .{ip});
                return;
            }
        }
        if (waited >= command.wait_seconds) break;
        waited += 1;
        vm.pumpMainLoop(1.0);
    }
    fail("no DHCP lease for the guest yet (is it running? try --wait 120)");
}

// ---- helpers ------------------------------------------------------------------

fn runningInstancePid(paths: *const vm.Paths) ?i32 {
    var path_buffer: [600]u8 = undefined;
    const state_path = paths.stateFilePath(&path_buffer) catch return null;
    var content_buffer: [1024]u8 = undefined;
    const content = vm.readFileInto(state_path, &content_buffer) orelse return null;
    const parsed = cli.parseStateFile(content);
    if (parsed.pid <= 0) return null;
    if (std.mem.eql(u8, parsed.state, "stopped") or std.mem.eql(u8, parsed.state, "error")) return null;
    if (!vm.processAlive(parsed.pid)) return null;
    return parsed.pid;
}

fn currentGuestIp(engine: vm.Engine) ?[]const u8 {
    var mac_buffer: [32]u8 = undefined;
    const mac = engine.macAddress(&mac_buffer) orelse return null;
    var leases_buffer: [64 * 1024]u8 = undefined;
    const leases = vm.readFileInto(vm.dhcpd_leases_path, &leases_buffer) orelse return null;
    const ip = cli.leaseIpForMac(leases, mac) orelse return null;
    // Static buffer so the slice survives the call — one caller at a time.
    const holder = struct {
        var storage: [64]u8 = undefined;
    };
    const len = @min(ip.len, holder.storage.len);
    @memcpy(holder.storage[0..len], ip[0..len]);
    return holder.storage[0..len];
}

/// Walk up from the cwd to the repo root — the directory an agent almost
/// always means by "the repo" — so `guest-mac start` shares the right root
fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
}

fn printLine(comptime format: []const u8, args: anytype) void {
    // Payload output (paths, IPs, states) belongs on stdout for scripts;
    // progress/log chatter goes to stderr via std.debug.print.
    const io = stdout_io orelse return;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer.interface.print(format ++ "\n", args) catch return;
    writer.interface.flush() catch {};
}

fn fail(message: []const u8) noreturn {
    std.debug.print("guest-mac: {s}\n", .{message});
    std.process.exit(1);
}

test {
    _ = @import("cli.zig");
    _ = @import("vm.zig");
    _ = @import("ui.zig");
}
