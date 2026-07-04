//! Zig bindings for the guest-mac VM engine (src/vm_host.m, Apple
//! Virtualization.framework behind a C ABI). The `Engine` wrapper owns the
//! host handle and funnels every engine event into an `Events` accumulator
//! the CLI loop and the UI app both poll from the main thread.

const std = @import("std");

pub const State = enum(c_int) {
    no_bundle = 0,
    fetching = 1,
    installing = 2,
    stopped = 3,
    starting = 4,
    running = 5,
    stopping = 6,
    err = 7,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .no_bundle => "no-bundle",
            .fetching => "fetching",
            .installing => "installing",
            .stopped => "stopped",
            .starting => "starting",
            .running => "running",
            .stopping => "stopping",
            .err => "error",
        };
    }
};

pub const EventKind = enum(c_int) {
    state_changed = 0,
    download_progress = 1,
    install_progress = 2,
    log = 3,
    err = 4,
};

const Host = opaque {};
const EventCallback = *const fn (context: ?*anyopaque, event_kind: c_int, state: c_int, progress: f64, message: [*]const u8, message_len: usize) callconv(.c) void;

extern fn guest_mac_vm_create(bundle_dir: [*]const u8, bundle_dir_len: usize, cache_dir: [*]const u8, cache_dir_len: usize) ?*Host;
extern fn guest_mac_vm_destroy(host: *Host) void;
extern fn guest_mac_vm_set_callback(host: *Host, callback: EventCallback, context: ?*anyopaque) void;
extern fn guest_mac_vm_state(host: *Host) c_int;
extern fn guest_mac_vm_fetch_restore_image(host: *Host) c_int;
extern fn guest_mac_vm_install(host: *Host, ipsw_path: [*]const u8, ipsw_path_len: usize, cpus: u32, memory_bytes: u64, disk_bytes: u64) c_int;
extern fn guest_mac_vm_configure(host: *Host, share_dir: [*]const u8, share_dir_len: usize, share_tag: [*]const u8, share_tag_len: usize, cpus: u32, memory_bytes: u64) c_int;
extern fn guest_mac_vm_start(host: *Host) c_int;
extern fn guest_mac_vm_request_stop(host: *Host) c_int;
extern fn guest_mac_vm_force_stop(host: *Host) c_int;
extern fn guest_mac_vm_mac_address(host: *Host, buffer: [*]u8, buffer_len: usize) usize;
extern fn guest_mac_vm_display_view(host: *Host) ?*anyopaque;
extern fn guest_mac_vm_pump_main_loop(seconds: f64) void;

fn stateFromInt(value: c_int) State {
    if (value < 0 or value > @intFromEnum(State.err)) return .err;
    return @enumFromInt(value);
}

pub fn pumpMainLoop(seconds: f64) void {
    guest_mac_vm_pump_main_loop(seconds);
}

/// Accumulated engine events, polled from the main thread (engine
/// callbacks are delivered on the main queue, so no locking).
pub const Events = struct {
    state: State = .no_bundle,
    download_progress: f64 = 0,
    install_progress: f64 = 0,
    /// Last log/state/error message, truncated to the buffer.
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    /// Cache path reported by fetch ("ipsw:<path>" log messages).
    ipsw_path: [512]u8 = @splat(0),
    ipsw_path_len: usize = 0,
    failed: bool = false,
    log_to_stderr: bool = false,

    pub fn lastMessage(self: *const Events) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn ipswPath(self: *const Events) ?[]const u8 {
        if (self.ipsw_path_len == 0) return null;
        return self.ipsw_path[0..self.ipsw_path_len];
    }

    pub fn record(self: *Events, kind: EventKind, state: State, progress: f64, message: []const u8) void {
        self.state = state;
        switch (kind) {
            .download_progress => self.download_progress = progress,
            .install_progress => self.install_progress = progress,
            .state_changed, .log, .err => {
                self.message_len = @min(message.len, self.message.len);
                @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
                if (kind == .err) self.failed = true;
                if (std.mem.startsWith(u8, message, "ipsw:")) {
                    const path = message["ipsw:".len..];
                    self.ipsw_path_len = @min(path.len, self.ipsw_path.len);
                    @memcpy(self.ipsw_path[0..self.ipsw_path_len], path[0..self.ipsw_path_len]);
                }
                if (self.log_to_stderr and message.len > 0) {
                    std.debug.print("guest-mac: {s}\n", .{message});
                }
            },
        }
    }
};

fn eventTrampoline(context: ?*anyopaque, event_kind: c_int, state: c_int, progress: f64, message: [*]const u8, message_len: usize) callconv(.c) void {
    const events: *Events = @ptrCast(@alignCast(context.?));
    if (event_kind < 0 or event_kind > @intFromEnum(EventKind.err)) return;
    if (state < 0 or state > @intFromEnum(State.err)) return;
    const kind: EventKind = @enumFromInt(event_kind);
    const state_value: State = @enumFromInt(state);
    events.record(kind, state_value, progress, message[0..message_len]);
}

pub const Engine = struct {
    host: *Host,
    events: *Events,

    pub fn create(bundle_dir: []const u8, cache_dir: []const u8, events: *Events) !Engine {
        const host = guest_mac_vm_create(bundle_dir.ptr, bundle_dir.len, cache_dir.ptr, cache_dir.len) orelse return error.EngineUnavailable;
        guest_mac_vm_set_callback(host, eventTrampoline, events);
        events.state = stateFromInt(guest_mac_vm_state(host));
        return .{ .host = host, .events = events };
    }

    pub fn destroy(self: Engine) void {
        guest_mac_vm_destroy(self.host);
    }

    pub fn state(self: Engine) State {
        return stateFromInt(guest_mac_vm_state(self.host));
    }

    pub fn fetchRestoreImage(self: Engine) !void {
        if (guest_mac_vm_fetch_restore_image(self.host) == 0) return error.FetchFailed;
    }

    pub fn install(self: Engine, ipsw_path: []const u8, cpus: u32, memory_bytes: u64, disk_bytes: u64) !void {
        if (guest_mac_vm_install(self.host, ipsw_path.ptr, ipsw_path.len, cpus, memory_bytes, disk_bytes) == 0) return error.InstallFailed;
    }

    pub fn configure(self: Engine, share_dir: []const u8, share_tag: []const u8, cpus: u32, memory_bytes: u64) !void {
        if (guest_mac_vm_configure(self.host, share_dir.ptr, share_dir.len, share_tag.ptr, share_tag.len, cpus, memory_bytes) == 0) return error.ConfigureFailed;
    }

    pub fn start(self: Engine) !void {
        if (guest_mac_vm_start(self.host) == 0) return error.StartFailed;
    }

    pub fn requestStop(self: Engine) !void {
        if (guest_mac_vm_request_stop(self.host) == 0) return error.StopFailed;
    }

    pub fn forceStop(self: Engine) !void {
        if (guest_mac_vm_force_stop(self.host) == 0) return error.StopFailed;
    }

    pub fn macAddress(self: Engine, buffer: []u8) ?[]const u8 {
        const len = guest_mac_vm_mac_address(self.host, buffer.ptr, buffer.len);
        if (len == 0) return null;
        return buffer[0..len];
    }

    /// The engine's VZVirtualMachineView (an NSView*), ready for
    /// `Runtime.adoptViewSurface`. Null before `configure`.
    pub fn displayView(self: Engine) ?*anyopaque {
        return guest_mac_vm_display_view(self.host);
    }
};

// ---- host helpers (libc-backed; this tool always links libc) -----------------

pub fn homeDir() ?[]const u8 {
    const value = std.c.getenv("HOME") orelse return null;
    const text = std.mem.span(value);
    return if (text.len == 0) null else text;
}

pub fn currentDir(buffer: []u8) ?[]const u8 {
    const ptr = std.c.getcwd(buffer.ptr, buffer.len) orelse return null;
    return std.mem.span(@as([*:0]u8, @ptrCast(ptr)));
}

fn pathZ(buffer: *[1024]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len == 0 or path.len >= buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

pub fn fileExists(path: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const path_z = pathZ(&buffer, path) orelse return false;
    return std.c.access(path_z, 0) == 0;
}

pub fn readFileInto(path: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [1024]u8 = undefined;
    const path_z = pathZ(&path_buffer, path) orelse return null;
    const fd = std.c.open(path_z, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var total: usize = 0;
    while (total < buffer.len) {
        const amount = std.c.read(fd, buffer.ptr + total, buffer.len - total);
        if (amount <= 0) break;
        total += @intCast(amount);
    }
    return buffer[0..total];
}

pub fn processAlive(pid: i32) bool {
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

// ---- default locations -------------------------------------------------------

// Durable state lives under ~/.native — one predictable home for toolkit
// state (VM bundles survive reinstalls); re-downloadable caches stay in the
// platform cache dir.
pub const bundle_dir_suffix = ".native/guest-mac/vm";
pub const cache_dir_suffix = "Library/Caches/native-sdk/guest-mac";
pub const dhcpd_leases_path = "/var/db/dhcpd_leases";

pub const Paths = struct {
    bundle_dir: [512]u8 = @splat(0),
    bundle_dir_len: usize = 0,
    cache_dir: [512]u8 = @splat(0),
    cache_dir_len: usize = 0,

    pub fn bundleDir(self: *const Paths) []const u8 {
        return self.bundle_dir[0..self.bundle_dir_len];
    }

    pub fn cacheDir(self: *const Paths) []const u8 {
        return self.cache_dir[0..self.cache_dir_len];
    }

    pub fn stateFilePath(self: *const Paths, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/state.json", .{self.bundleDir()});
    }
};

pub fn resolvePaths(home: []const u8) !Paths {
    var paths: Paths = .{};
    const bundle = try std.fmt.bufPrint(&paths.bundle_dir, "{s}/{s}", .{ home, bundle_dir_suffix });
    paths.bundle_dir_len = bundle.len;
    const cache = try std.fmt.bufPrint(&paths.cache_dir, "{s}/{s}", .{ home, cache_dir_suffix });
    paths.cache_dir_len = cache.len;
    return paths;
}

test "paths resolve under the caller's home" {
    const paths = try resolvePaths("/Users/dev");
    try std.testing.expectEqualStrings("/Users/dev/.native/guest-mac/vm", paths.bundleDir());
    try std.testing.expectEqualStrings("/Users/dev/Library/Caches/native-sdk/guest-mac", paths.cacheDir());
    var buffer: [600]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/dev/.native/guest-mac/vm/state.json", try paths.stateFilePath(&buffer));
}

test "events accumulator tracks progress, messages, and the fetched ipsw path" {
    var events: Events = .{};
    events.record(.state_changed, .fetching, 0, "resolving latest supported restore image");
    try std.testing.expectEqual(State.fetching, events.state);
    events.record(.download_progress, .fetching, 0.5, "");
    try std.testing.expectEqual(@as(f64, 0.5), events.download_progress);
    events.record(.log, .no_bundle, 1, "ipsw:/tmp/cache/restore.ipsw");
    try std.testing.expectEqualStrings("/tmp/cache/restore.ipsw", events.ipswPath().?);
    try std.testing.expect(!events.failed);
    events.record(.err, .err, 0, "boom");
    try std.testing.expect(events.failed);
    try std.testing.expectEqualStrings("boom", events.lastMessage());
}
