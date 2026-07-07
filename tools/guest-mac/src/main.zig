//! guest-mac — in-repo macOS guest VMs for live-GUI agent work.
//!
//! One binary, two faces:
//! - `guest-mac [--name VM]` (no verb) runs the windowed Native SDK app:
//!   chrome around the live guest display (src/ui.zig).
//! - Headless verbs for agents: `fetch`, `install`, `clone`, `start`,
//!   `stop`, `status`, `ip` (src/cli.zig parses; this file executes).
//!   Every verb addresses a named VM (`--name`, default "default");
//!   bundles live at ~/.native/guest-mac/vms/<name>/. `stop`, `status`,
//!   and `ip` are pure file/signal verbs that work from any process;
//!   `fetch`/`install`/`start` drive the Virtualization engine
//!   (src/vm_host.m) and therefore need this signed binary. `clone` is a
//!   copy-on-write file verb plus one engine-free identity call.
//!
//! See agents.md (in this directory) for the agent workflow — including
//! the two-concurrent-guests cap and the input-lock convention for
//! sharing a guest between agents — and README.md for provisioning.

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

    // One-time layout migration: the pre-multi-VM bundle (vm/) becomes
    // vms/default. Runs before any verb touches paths; a running legacy
    // guest defers it (its owner process holds the old path) and
    // "default" keeps resolving to the legacy dir until it stops.
    if (vm.homeDir()) |home| reportMigration(vm.migrateLegacyForHome(home));

    switch (command.verb) {
        .help => std.debug.print("{s}", .{cli.usage}),
        .app => try runApp(init, command),
        .fetch => try runFetch(command),
        .install => try runInstall(command),
        .clone => try runClone(command),
        .start => try runStart(command),
        .stop => try runStop(command),
        .status => try runStatus(command),
        .ip => try runIp(command),
    }
}

fn reportMigration(result: vm.Migration) void {
    switch (result) {
        .none, .kept_existing => {},
        .migrated => std.debug.print("guest-mac: migrated the legacy VM bundle to ~/.native/guest-mac/vms/default (was ~/.native/guest-mac/vm)\n", .{}),
        .deferred_running => std.debug.print("guest-mac: legacy guest is running — migration to vms/default deferred until it stops ('default' still resolves)\n", .{}),
        .failed => std.debug.print("guest-mac: legacy bundle migration failed — ~/.native/guest-mac/vm left in place ('default' still resolves)\n", .{}),
    }
}

// ---- windowed app -----------------------------------------------------------

fn runApp(init: std.process.Init, command: cli.Command) !void {
    // The launch flag chooses which VM the window drives; an in-app VM
    // switcher is deferred (relaunch with a different --name instead).
    var app = ui.GuestMacApp{ .vm_name = command.name };
    try runner.runWithOptions(app.app(), .{
        .app_name = "guest-mac",
        .window_title = "Guest macOS",
        .bundle_id = "dev.native_sdk.guest_mac",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, ui.window_width, ui.window_height),
        .js_window_api = false,
        .security = .{ .permissions = &ui.app_permissions },
    }, init);
}

// ---- engine-backed verbs -----------------------------------------------------

const EngineSession = struct {
    events: vm.Events = .{},
    paths: vm.Paths = .{},
    engine: vm.Engine = undefined,

    fn open(self: *EngineSession, name: []const u8) !void {
        const home = vm.homeDir() orelse fail("HOME is not set");
        self.paths = vm.resolvePaths(home, name) catch fail("home path too long for the VM bundle location");
        self.events.log_to_stderr = true;
        self.engine = vm.Engine.create(self.paths.bundleDir(), self.paths.cacheDir(), &self.events) catch {
            fail("Virtualization engine unavailable (Apple silicon macOS 13+, signed binary required)");
        };
    }
};

fn runFetch(command: cli.Command) !void {
    // The IPSW cache is shared across VMs; the name only anchors the
    // engine's bundle dir (created if missing, otherwise untouched).
    var session: EngineSession = .{};
    try session.open(command.name);
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
    try session.open(command.name);
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
    try session.open(command.name);
    if (session.events.state == .no_bundle) fail("no VM bundle — run `guest-mac install` first");
    if (vm.livePidForBundle(session.paths.bundleDir())) |pid| {
        var buffer: [96]u8 = undefined;
        fail(std.fmt.bufPrint(&buffer, "guest already running (pid {d})", .{pid}) catch "guest already running");
    }
    enforceRunningCap(command.name);

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

/// The two-guest cap: Apple's macOS license terms permit two macOS
/// guests running concurrently per host. Counts every OTHER VM with a
/// live owner pid and refuses to boot a third, naming the running VMs.
fn enforceRunningCap(starting: []const u8) void {
    const home = vm.homeDir() orelse return;
    var vms_buffer: [512]u8 = undefined;
    var legacy_buffer: [512]u8 = undefined;
    const vms_dir = std.fmt.bufPrint(&vms_buffer, "{s}/{s}", .{ home, vm.vms_dir_suffix }) catch return;
    const legacy_dir = std.fmt.bufPrint(&legacy_buffer, "{s}/{s}", .{ home, vm.legacy_bundle_dir_suffix }) catch return;
    var running: [vm.max_tracked_vms]vm.RunningVm = undefined;
    const count = vm.listRunningVms(vms_dir, legacy_dir, &running);
    if (vm.countOtherRunning(running[0..count], starting) < cli.max_running_vms) return;

    var message: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message);
    writer.print("two macOS guests are already running — Apple's macOS license permits {d} concurrent guests per host:", .{cli.max_running_vms}) catch {};
    for (running[0..count]) |entry| {
        if (std.mem.eql(u8, entry.name(), starting)) continue;
        writer.print(" {s} (pid {d})", .{ entry.name(), entry.pid }) catch {};
    }
    writer.print(". Stop one first: guest-mac stop --name <vm>", .{}) catch {};
    fail(writer.buffered());
}

// ---- clone --------------------------------------------------------------------

const cloned_files = [_][]const u8{ "Disk.img", "AuxiliaryStorage", "HardwareModel" };

/// APFS copy-on-write clone of a stopped guest. The disk, auxiliary
/// storage, and hardware model travel; the machine identifier and MAC
/// address are FRESH — the unique identity that makes the host's DHCP
/// server give the clone its own IP. Everything provisioned inside the
/// guest (user, keys, sudoers, tools) rides along on the disk.
fn runClone(command: cli.Command) !void {
    const src_name = command.clone_src.?;
    const dst_name = command.clone_dst.?;
    const home = vm.homeDir() orelse fail("HOME is not set");
    const src_paths = vm.resolvePaths(home, src_name) catch fail("home path too long for the VM bundle location");
    const dst_paths = vm.resolvePaths(home, dst_name) catch fail("home path too long for the VM bundle location");

    var probe_buffer: [600]u8 = undefined;
    const src_disk = try std.fmt.bufPrint(&probe_buffer, "{s}/Disk.img", .{src_paths.bundleDir()});
    if (!vm.fileExists(src_disk)) {
        var buffer: [640]u8 = undefined;
        fail(std.fmt.bufPrint(&buffer, "no VM bundle named \"{s}\" ({s})", .{ src_name, src_paths.bundleDir() }) catch "source VM bundle missing");
    }
    if (vm.livePidForBundle(src_paths.bundleDir())) |pid| {
        var buffer: [160]u8 = undefined;
        fail(std.fmt.bufPrint(&buffer, "\"{s}\" is running (pid {d}) — stop it before cloning (a live disk image would clone torn)", .{ src_name, pid }) catch "source VM is running");
    }
    if (vm.fileExists(dst_paths.bundleDir())) {
        var buffer: [160]u8 = undefined;
        fail(std.fmt.bufPrint(&buffer, "VM \"{s}\" already exists — pick a new name or delete its bundle dir", .{dst_name}) catch "destination VM already exists");
    }

    var vms_buffer: [512]u8 = undefined;
    const vms_dir = try std.fmt.bufPrint(&vms_buffer, "{s}/{s}", .{ home, vm.vms_dir_suffix });
    if (!vm.makeDir(vms_dir) or !vm.makeDir(dst_paths.bundleDir())) fail("could not create the destination bundle directory");

    for (cloned_files) |file_name| {
        var src_buffer: [600]u8 = undefined;
        var dst_buffer: [600]u8 = undefined;
        const src_file = try std.fmt.bufPrint(&src_buffer, "{s}/{s}", .{ src_paths.bundleDir(), file_name });
        const dst_file = try std.fmt.bufPrint(&dst_buffer, "{s}/{s}", .{ dst_paths.bundleDir(), file_name });
        const method = vm.cloneOrCopyFile(src_file, dst_file) catch {
            var buffer: [640]u8 = undefined;
            fail(std.fmt.bufPrint(&buffer, "cloning {s} failed", .{src_file}) catch "cloning a bundle file failed");
        };
        if (method == .copied) std.debug.print("guest-mac: {s} full-copied (filesystem cannot clone; expect real disk usage)\n", .{file_name});
    }

    // Fresh identity: a new machine identifier file...
    var identifier_buffer: [600]u8 = undefined;
    const identifier_path = try std.fmt.bufPrint(&identifier_buffer, "{s}/MachineIdentifier", .{dst_paths.bundleDir()});
    if (!vm.writeFreshMachineIdentifier(identifier_path)) fail("could not write a fresh machine identifier");

    // ...and a new MAC in config.json (cpus carry over from the source;
    // memory defaults to the two-guests-coexist size unless overridden).
    var src_config_buffer: [4096]u8 = undefined;
    var config_path_buffer: [600]u8 = undefined;
    const src_config_path = try std.fmt.bufPrint(&config_path_buffer, "{s}/config.json", .{src_paths.bundleDir()});
    const src_config = vm.readFileInto(src_config_path, &src_config_buffer) orelse fail("source bundle has no config.json");
    const cpus = cli.cpusFromConfig(src_config) orelse cli.default_cpus;
    var prng = std.Random.DefaultPrng.init(vm.randomSeed());
    var mac_buffer: [cli.mac_string_len]u8 = undefined;
    const mac = cli.randomLocallyAdministeredMac(prng.random(), &mac_buffer);
    var rendered_buffer: [512]u8 = undefined;
    const rendered = try cli.renderConfig(&rendered_buffer, mac, cpus, command.memory_gb << 30);
    const dst_config_path = try std.fmt.bufPrint(&config_path_buffer, "{s}/config.json", .{dst_paths.bundleDir()});
    if (!vm.writeFile(dst_config_path, rendered)) fail("could not write the clone's config.json");

    printLine("cloned {s} -> {s} (fresh machine identifier, mac {s})", .{ src_name, dst_name, mac });
}

// ---- pure file/signal verbs ---------------------------------------------------

fn runStop(command: cli.Command) !void {
    const home = vm.homeDir() orelse fail("HOME is not set");
    const paths = try vm.resolvePaths(home, command.name);
    const pid = vm.livePidForBundle(paths.bundleDir()) orelse {
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
        if (vm.livePidForBundle(paths.bundleDir()) == null) {
            printLine("stopped", .{});
            return;
        }
        vm.pumpMainLoop(1.0);
    }
    fail("guest did not stop within 120s — retry with --force");
}

fn runStatus(command: cli.Command) !void {
    const home = vm.homeDir() orelse fail("HOME is not set");
    const paths = try vm.resolvePaths(home, command.name);

    var disk_path_buffer: [600]u8 = undefined;
    const disk_path = try std.fmt.bufPrint(&disk_path_buffer, "{s}/Disk.img", .{paths.bundleDir()});
    const installed = vm.fileExists(disk_path);
    printLine("vm: {s}", .{command.name});
    printLine("bundle: {s} ({s})", .{ if (installed) "installed" else "missing", paths.bundleDir() });

    if (vm.livePidForBundle(paths.bundleDir())) |pid| {
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
    const paths = try vm.resolvePaths(home, command.name);
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
