//! The windowed guest-mac host: Native SDK chrome around the live guest
//! display. The display area is a plain `stack` container in the declared
//! shell scene; once the engine configures the VM, its VZVirtualMachineView
//! is adopted into that container through the native-surface channel
//! (`Runtime.adoptViewSurface`) — pointer/keyboard capture inside the guest
//! is the view's own behavior from there.
//!
//! The app self-drives the honest happy path on a poll timer: fetch the
//! restore image if it is not cached, install if the bundle is missing
//! (progress in the statusbar), configure, and wait for Start. Setup
//! Assistant click-through happens right here in the display area — the
//! one manual step.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vm = @import("vm.zig");
const cli = @import("cli.zig");

const tick_timer_id: u64 = 1;
const tick_interval_ns: u64 = 500 * std.time.ns_per_ms;

const window_width: f32 = 1360;
const window_height: f32 = 900;
const toolbar_height: f32 = 52;
const sidebar_width: f32 = 320;
const statusbar_height: f32 = 34;

const start_command = "vm.start";
const stop_command = "vm.stop";
const force_stop_command = "vm.force-stop";

pub const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };

const checklist = [_][]const u8{
    "Provisioning checklist",
    "1. Fetch + install run here automatically.",
    "2. Start, then click through Setup Assistant",
    "    in the display area (the one manual step).",
    "3. In the guest: System Settings > General >",
    "    Sharing > Remote Login: ON.",
    "4. Privacy & Security > Screen Recording:",
    "    allow the test runner / sshd-child.",
    "5. Run tools/guest-mac/provision.sh inside",
    "    the guest (zig toolchain + repo mount).",
    "6. guest-mac ip  ->  ssh <user>@<ip>",
};

fn checklistViews(comptime base: usize) [checklist.len]native_sdk.ShellView {
    var views: [checklist.len]native_sdk.ShellView = undefined;
    for (checklist, 0..) |line, index| {
        views[index] = .{
            .label = std.fmt.comptimePrint("check-{d}", .{index}),
            .kind = .label,
            .parent = "checklist",
            .x = 16,
            .y = @floatFromInt(base + index * 26),
            .width = sidebar_width - 32,
            .height = 20,
            .layer = 21,
            .text = line,
        };
    }
    return views;
}

const chrome_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 18, .y = 16, .width = 180, .height = 20, .layer = 21, .text = "Guest macOS" },
    .{ .label = "start", .kind = .button, .parent = "toolbar", .x = 210, .y = 11, .width = 88, .height = 30, .layer = 21, .text = "Start", .command = start_command, .accessibility_label = "Start the guest VM" },
    .{ .label = "stop", .kind = .button, .parent = "toolbar", .x = 306, .y = 11, .width = 88, .height = 30, .layer = 21, .text = "Stop", .command = stop_command, .accessibility_label = "Gracefully stop the guest VM" },
    .{ .label = "force-stop", .kind = .button, .parent = "toolbar", .x = 402, .y = 11, .width = 110, .height = 30, .layer = 21, .text = "Force Stop", .command = force_stop_command, .accessibility_label = "Force stop the guest VM" },
    .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
    .{ .label = "checklist", .kind = .sidebar, .parent = "body", .width = sidebar_width, .layer = 10, .role = "Provisioning checklist" },
    .{ .label = "guest-display", .kind = .stack, .parent = "body", .fill = true, .layer = 10, .role = "Guest display", .accessibility_label = "Live guest macOS display" },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 760, .height = 18, .layer = 21, .text = "Starting engine..." },
    .{ .label = "busy", .kind = .progress_indicator, .parent = "statusbar", .x = 784, .y = 7, .width = 20, .height = 20, .layer = 21, .visible = false, .accessibility_label = "Working" },
};

pub const shell_views = chrome_views ++ checklistViews(52);
pub const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Guest macOS",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const Phase = enum {
    boot,
    fetching,
    installing,
    configuring,
    ready,
    blocked,
};

pub const GuestMacApp = struct {
    events: vm.Events = .{},
    engine: ?vm.Engine = null,
    paths: vm.Paths = .{},
    phase: Phase = .boot,
    display_adopted: bool = false,
    install_kicked: bool = false,
    ip_buffer: [64]u8 = @splat(0),
    ip_len: usize = 0,
    ip_poll_countdown: u32 = 0,
    last_status: [256]u8 = @splat(0),
    last_status_len: usize = 0,
    busy_visible: bool = false,

    pub fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "guest-mac",
            .scene_fn = scene,
            .start_fn = start,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        _ = context;
        try runtime.startTimer(tick_timer_id, tick_interval_ns, true);
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, start_command)) {
                    self.startGuest(runtime);
                } else if (std.mem.eql(u8, command.name, stop_command)) {
                    if (self.engine) |engine| engine.requestStop() catch self.note(runtime, "stop request failed (guest not running?)");
                } else if (std.mem.eql(u8, command.name, force_stop_command)) {
                    if (self.engine) |engine| engine.forceStop() catch self.note(runtime, "force stop failed (guest not running?)");
                }
            },
            .timer => |timer| {
                if (timer.id == tick_timer_id) self.tick(runtime);
            },
            else => {},
        }
    }

    fn tick(self: *@This(), runtime: *native_sdk.Runtime) void {
        if (self.phase == .blocked) return;
        if (self.engine == null) self.bootstrap(runtime);
        const engine = self.engine orelse return;
        self.advance(runtime, engine);
        self.adoptDisplayIfReady(runtime, engine);
        self.pollGuestIp(engine);
        self.refreshStatus(runtime);
    }

    fn bootstrap(self: *@This(), runtime: *native_sdk.Runtime) void {
        const home = vm.homeDir() orelse {
            self.block(runtime, "HOME is not set — cannot locate the VM bundle");
            return;
        };
        self.paths = vm.resolvePaths(home) catch {
            self.block(runtime, "home path too long for the VM bundle location");
            return;
        };
        if (self.otherInstancePid()) |pid| {
            var buffer: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "guest already running headless (pid {d}) — `guest-mac stop` first", .{pid}) catch "guest already running headless";
            self.block(runtime, text);
            return;
        }
        self.engine = vm.Engine.create(self.paths.bundleDir(), self.paths.cacheDir(), &self.events) catch {
            self.block(runtime, "Virtualization engine unavailable (Apple silicon macOS 13+ required)");
            return;
        };
    }

    /// The self-driving happy path: no bundle -> fetch -> install ->
    /// configure -> ready(stopped). Every step is engine-async; this just
    /// notices completion on the poll tick and kicks the next step.
    fn advance(self: *@This(), runtime: *native_sdk.Runtime, engine: vm.Engine) void {
        _ = runtime;
        if (self.events.failed) return;
        switch (self.phase) {
            .boot => {
                if (self.events.state == .no_bundle) {
                    engine.fetchRestoreImage() catch return;
                    self.phase = .fetching;
                } else {
                    // Bundle already installed: configure straight away.
                    self.phase = .configuring;
                }
            },
            .fetching => {
                if (self.events.ipswPath()) |path| {
                    if (self.events.state == .no_bundle and !self.install_kicked) {
                        self.install_kicked = true;
                        engine.install(path, cli.default_cpus, cli.default_memory_gb << 30, cli.default_disk_gb << 30) catch return;
                        self.phase = .installing;
                    } else if (self.events.state == .stopped) {
                        self.phase = .configuring;
                    }
                }
            },
            .installing => {
                if (self.events.state == .stopped) self.phase = .configuring;
            },
            .configuring => {
                var cwd_buffer: [512]u8 = undefined;
                const share_dir = vm.currentDir(&cwd_buffer) orelse "";
                engine.configure(share_dir, cli.default_share_tag, cli.default_cpus, cli.default_memory_gb << 30) catch return;
                self.phase = .ready;
            },
            .ready, .blocked => {},
        }
    }

    fn adoptDisplayIfReady(self: *@This(), runtime: *native_sdk.Runtime, engine: vm.Engine) void {
        if (self.display_adopted) return;
        const view = engine.displayView() orelse return;
        runtime.adoptViewSurface(1, "guest-display", view) catch return;
        self.display_adopted = true;
    }

    fn startGuest(self: *@This(), runtime: *native_sdk.Runtime) void {
        const engine = self.engine orelse return;
        if (self.phase != .ready or (self.events.state != .stopped and self.events.state != .no_bundle)) {
            self.note(runtime, "guest is not ready to start yet");
            return;
        }
        engine.start() catch self.note(runtime, "start failed — see state");
    }

    fn pollGuestIp(self: *@This(), engine: vm.Engine) void {
        if (self.events.state != .running) {
            self.ip_len = 0;
            return;
        }
        if (self.ip_len > 0) return;
        if (self.ip_poll_countdown > 0) {
            self.ip_poll_countdown -= 1;
            return;
        }
        self.ip_poll_countdown = 4; // every ~2s on the 500ms tick
        var mac_buffer: [32]u8 = undefined;
        const mac = engine.macAddress(&mac_buffer) orelse return;
        var leases_buffer: [64 * 1024]u8 = undefined;
        const leases = vm.readFileInto(vm.dhcpd_leases_path, &leases_buffer) orelse return;
        const ip = cli.leaseIpForMac(leases, mac) orelse return;
        self.ip_len = @min(ip.len, self.ip_buffer.len);
        @memcpy(self.ip_buffer[0..self.ip_len], ip[0..self.ip_len]);
    }

    fn refreshStatus(self: *@This(), runtime: *native_sdk.Runtime) void {
        var buffer: [256]u8 = undefined;
        const status = self.statusText(&buffer);
        if (!std.mem.eql(u8, status, self.last_status[0..self.last_status_len])) {
            self.last_status_len = @min(status.len, self.last_status.len);
            @memcpy(self.last_status[0..self.last_status_len], status[0..self.last_status_len]);
            _ = runtime.updateView(1, "status-label", .{ .text = status }) catch {};
        }
        const busy = self.events.state == .fetching or self.events.state == .installing or self.events.state == .starting or self.events.state == .stopping;
        if (busy != self.busy_visible) {
            self.busy_visible = busy;
            _ = runtime.updateView(1, "busy", .{ .visible = busy }) catch {};
        }
    }

    fn statusText(self: *@This(), buffer: []u8) []const u8 {
        if (self.events.failed) {
            return std.fmt.bufPrint(buffer, "error: {s}", .{self.events.lastMessage()}) catch "error";
        }
        return switch (self.events.state) {
            .no_bundle => "no VM bundle yet",
            .fetching => if (self.events.download_progress > 0)
                std.fmt.bufPrint(buffer, "fetching restore image... {d}%", .{@as(u32, @intFromFloat(self.events.download_progress * 100))}) catch "fetching restore image..."
            else
                "fetching restore image...",
            .installing => std.fmt.bufPrint(buffer, "installing macOS... {d}%", .{@as(u32, @intFromFloat(self.events.install_progress * 100))}) catch "installing macOS...",
            .stopped => if (self.phase == .ready) "stopped — press Start (first boot: click through Setup Assistant here)" else "stopped",
            .starting => "booting...",
            .running => if (self.ip_len > 0)
                std.fmt.bufPrint(buffer, "running — ip {s} (ssh in, or use the display)", .{self.ip_buffer[0..self.ip_len]}) catch "running"
            else
                "running — waiting for DHCP lease...",
            .stopping => "stopping...",
            .err => "error",
        };
    }

    fn note(self: *@This(), runtime: *native_sdk.Runtime, text: []const u8) void {
        _ = self;
        _ = runtime.updateView(1, "status-label", .{ .text = text }) catch {};
    }

    fn block(self: *@This(), runtime: *native_sdk.Runtime, text: []const u8) void {
        self.phase = .blocked;
        self.note(runtime, text);
    }

    fn otherInstancePid(self: *@This()) ?i32 {
        var path_buffer: [600]u8 = undefined;
        const state_path = self.paths.stateFilePath(&path_buffer) catch return null;
        var content_buffer: [1024]u8 = undefined;
        const content = vm.readFileInto(state_path, &content_buffer) orelse return null;
        const parsed = cli.parseStateFile(content);
        if (parsed.pid <= 0 or parsed.pid == @as(i32, @intCast(std.c.getpid()))) return null;
        if (std.mem.eql(u8, parsed.state, "stopped") or std.mem.eql(u8, parsed.state, "error")) return null;
        if (!vm.processAlive(parsed.pid)) return null;
        return parsed.pid;
    }
};

test "guest-mac scene declares chrome around the guest display container" {
    var display: ?native_sdk.ShellView = null;
    var status: ?native_sdk.ShellView = null;
    var buttons: usize = 0;
    for (shell_views) |view| {
        if (std.mem.eql(u8, view.label, "guest-display")) display = view;
        if (std.mem.eql(u8, view.label, "status-label")) status = view;
        if (view.kind == .button) buttons += 1;
    }
    try std.testing.expect(display.?.kind == .stack);
    try std.testing.expect(display.?.fill);
    try std.testing.expectEqualStrings("body", display.?.parent.?);
    try std.testing.expect(status.?.kind == .label);
    try std.testing.expectEqual(@as(usize, 3), buttons);
    // The scene declares no webview anywhere: the window stays fully
    // native, so no implicit main webview is created.
    for (shell_views) |view| try std.testing.expect(view.kind != .webview);
}

test "status text tracks engine state" {
    var app_state: GuestMacApp = .{};
    var buffer: [256]u8 = undefined;
    app_state.events.state = .installing;
    app_state.events.install_progress = 0.42;
    try std.testing.expectEqualStrings("installing macOS... 42%", app_state.statusText(&buffer));
    app_state.events.state = .running;
    const ip = "192.168.64.9";
    @memcpy(app_state.ip_buffer[0..ip.len], ip);
    app_state.ip_len = ip.len;
    try std.testing.expectEqualStrings("running — ip 192.168.64.9 (ssh in, or use the display)", app_state.statusText(&buffer));
    app_state.events.failed = true;
    app_state.events.record(.err, .err, 0, "boom");
    try std.testing.expectEqualStrings("error: boom", app_state.statusText(&buffer));
}
