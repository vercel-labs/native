//! Out-of-process TypeScript service carrier (phase 1).
//!
//! One worker thread owns one plain-scriptc child and the framed stdio
//! protocol. HostCallBinding callbacks only copy/enqueue on the loop thread;
//! completions are polled back onto that thread by Effects and therefore keep
//! its journaling/replay boundary unchanged. The child starts lazily on the
//! first real request, so replay never needs or starts it.

const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const platform = @import("../platform/root.zig");

const max_frame_bytes: usize = 16 * 1024 * 1024;
const transport_error = "{\"kind\":\"service_host\",\"message\":\"service host exited or rejected the request\"}";
const timeout_error = "{\"kind\":\"service_timeout\",\"message\":\"service request timed out\"}";

/// A service operation is synchronous inside the child. Bound the whole
/// exchange (lazy spawn + hello + request + response), otherwise one hung
/// operation would strand the service worker and every request behind it.
pub const default_request_timeout_ms: u32 = 30_000;

/// The generated runner and tests share this one authority allowlist. Keeping
/// it beside the carrier prevents a generated-main copy from silently gaining
/// an ambient variable when the runtime policy changes.
pub fn environmentVariableAllowed(name: []const u8) bool {
    return environmentVariableAllowedForOs(name, builtin.os.tag);
}

fn environmentVariableAllowedForOs(name: []const u8, os_tag: std.Target.Os.Tag) bool {
    const portable = [_][]const u8{
        "PATH",          "HOME",         "USER",       "TMPDIR",      "TMP",      "TEMP", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
    };
    for (portable) |candidate| {
        if (if (os_tag == .windows) std.ascii.eqlIgnoreCase(name, candidate) else std.mem.eql(u8, name, candidate)) return true;
    }
    if (os_tag == .windows) {
        const windows = [_][]const u8{ "USERPROFILE", "USERNAME", "SystemRoot", "COMSPEC", "PATHEXT" };
        for (windows) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub fn ServiceHost(comptime Registry: type) type {
    return struct {
        const Self = @This();

        const Request = struct {
            key: u64,
            request_id: u32,
            operation: u16,
            payload: []u8,
            answer: bool,
        };
        const Result = struct { key: u64, ok: bool, bytes: []u8 };

        allocator: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        requests: std.ArrayList(Request) = .empty,
        results: std.ArrayList(Result) = .empty,
        last_polled: ?[]u8 = null,
        services: ?platform.PlatformServices = null,
        worker_thread: ?std.Thread = null,
        shutting_down: bool = false,
        next_request_id: u32 = 1,
        active_key: ?u64 = null,
        child_id: ?std.process.Child.Id = null,
        child_reaping: bool = false,
        request_timeout_ms: u32 = default_request_timeout_ms,
        active_request_id: ?u32 = null,
        active_cancelled: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            executable: []const u8,
            cwd: []const u8,
            environ: ?*const std.process.Environ.Map,
        ) Self {
            return .{ .allocator = allocator, .io = io, .executable = executable, .cwd = cwd, .environ = environ };
        }

        pub fn binding(self: *Self) effects.HostCallBinding {
            return .{
                .context = self,
                .send_fn = send,
                .request_fn = request,
                .cancel_fn = cancel,
                .reject_duplicate_keys = true,
                .poll_fn = poll,
                .pending_fn = pending,
                .bind_services_fn = bindServices,
                .shutdown_fn = shutdown,
            };
        }

        /// Configure the carrier while no exchange is active. Primarily
        /// useful to keep deterministic timeout tests fast; production uses
        /// the conservative default above.
        pub fn setRequestTimeoutMs(self: *Self, timeout_ms: u32) void {
            std.debug.assert(timeout_ms > 0);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(self.active_request_id == null);
            self.request_timeout_ms = timeout_ms;
        }

        /// Supervision/diagnostic visibility. The handle is only a snapshot;
        /// callers must tolerate the child exiting immediately after return.
        pub fn processId(self: *Self) ?std.process.Child.Id {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.child_id;
        }

        /// Safe to call after Effects shutdown; repeated shutdown is inert.
        pub fn deinit(self: *Self) void {
            shutdown(self);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.requests.items) |entry| self.allocator.free(entry.payload);
            self.requests.deinit(self.allocator);
            for (self.results.items) |entry| self.allocator.free(entry.bytes);
            self.results.deinit(self.allocator);
            if (self.last_polled) |bytes| self.allocator.free(bytes);
            self.last_polled = null;
        }

        fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const operation = Registry.indexOf(name) orelse return;
            self.enqueue(0, operation, payload, false);
        }

        fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const operation = Registry.indexOf(name) orelse {
                self.stageStatic(key, false, transport_error);
                return;
            };
            self.enqueue(key, operation, payload, true);
        }

        fn cancel(context: *anyopaque, key: u64) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            var index: usize = 0;
            while (index < self.requests.items.len) {
                if (self.requests.items[index].answer and self.requests.items[index].key == key) {
                    const removed = self.requests.orderedRemove(index);
                    self.allocator.free(removed.payload);
                } else index += 1;
            }
            index = 0;
            while (index < self.results.items.len) {
                if (self.results.items[index].key == key) {
                    const removed = self.results.orderedRemove(index);
                    self.allocator.free(removed.bytes);
                } else index += 1;
            }
            const kill = self.active_key != null and self.active_key.? == key;
            if (kill) {
                self.active_cancelled = true;
                self.killPublishedChildLocked();
            }
            self.mutex.unlock(self.io);
        }

        fn bindServices(context: *anyopaque, services: *const platform.PlatformServices) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            self.services = services.*;
            self.mutex.unlock(self.io);
        }

        fn pending(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.results.items.len > 0;
        }

        fn poll(context: *anyopaque) ?effects.HostCallCompletion {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.last_polled) |bytes| self.allocator.free(bytes);
            self.last_polled = null;
            if (self.results.items.len == 0) return null;
            const result = self.results.orderedRemove(0);
            self.last_polled = result.bytes;
            return .{ .key = result.key, .ok = result.ok, .bytes = result.bytes };
        }

        fn shutdown(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down) {
                const thread = self.worker_thread;
                self.mutex.unlock(self.io);
                if (thread) |value| value.join();
                self.mutex.lockUncancelable(self.io);
                self.worker_thread = null;
                self.mutex.unlock(self.io);
                return;
            }
            self.shutting_down = true;
            self.killPublishedChildLocked();
            self.condition.broadcast(self.io);
            const thread = self.worker_thread;
            self.mutex.unlock(self.io);
            if (thread) |value| value.join();
            self.mutex.lockUncancelable(self.io);
            self.worker_thread = null;
            self.services = null;
            self.mutex.unlock(self.io);
        }

        fn enqueue(self: *Self, key: u64, operation: u16, payload: []const u8, answer: bool) void {
            const copy = self.allocator.dupe(u8, payload) catch {
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down) {
                self.mutex.unlock(self.io);
                self.allocator.free(copy);
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            }
            const request_id = self.next_request_id;
            self.next_request_id +%= 1;
            if (self.next_request_id == 0) self.next_request_id = 1;
            self.requests.append(self.allocator, .{
                .key = key,
                .request_id = request_id,
                .operation = operation,
                .payload = copy,
                .answer = answer,
            }) catch {
                self.mutex.unlock(self.io);
                self.allocator.free(copy);
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            };
            if (self.worker_thread == null) {
                self.worker_thread = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
                if (self.worker_thread == null) {
                    const removed = self.requests.pop().?;
                    self.mutex.unlock(self.io);
                    self.allocator.free(removed.payload);
                    if (answer) self.stageStatic(key, false, transport_error);
                    return;
                }
            }
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
        }

        fn stageStatic(self: *Self, key: u64, ok: bool, bytes: []const u8) void {
            const copy = self.allocator.dupe(u8, bytes) catch return;
            self.stageOwned(.{ .key = key, .ok = ok, .bytes = copy });
        }

        fn stageOwned(self: *Self, result: Result) void {
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down) {
                self.mutex.unlock(self.io);
                self.allocator.free(result.bytes);
                return;
            }
            self.results.append(self.allocator, result) catch {
                self.mutex.unlock(self.io);
                self.allocator.free(result.bytes);
                return;
            };
            const services = self.services;
            self.mutex.unlock(self.io);
            if (services) |bound| bound.wake() catch {};
        }

        fn workerMain(self: *Self) void {
            var child: ?std.process.Child = null;
            defer self.retireChild(&child);
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (!self.shutting_down and self.requests.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
                if (self.shutting_down) {
                    self.mutex.unlock(self.io);
                    return;
                }
                const work = self.requests.orderedRemove(0);
                self.active_key = if (work.answer) work.key else null;
                self.active_request_id = work.request_id;
                self.active_cancelled = false;
                self.mutex.unlock(self.io);

                var completion: ?Result = null;
                const response = self.exchange(&child, work) catch |err| response: {
                    if (work.answer) {
                        const bytes = if (err == error.ServiceTimedOut) timeout_error else transport_error;
                        if (self.allocator.dupe(u8, bytes)) |copy| {
                            completion = .{ .key = work.key, .ok = false, .bytes = copy };
                        } else |_| {}
                    }
                    break :response null;
                };
                if (work.answer) {
                    if (response) |result| completion = .{ .key = work.key, .ok = result.ok, .bytes = result.bytes };
                } else if (response) |result| {
                    self.allocator.free(result.bytes);
                }
                self.allocator.free(work.payload);
                self.mutex.lockUncancelable(self.io);
                const cancelled = self.active_request_id == work.request_id and self.active_cancelled;
                self.active_key = null;
                self.active_request_id = null;
                self.active_cancelled = false;
                var services: ?platform.PlatformServices = null;
                if (completion) |result| {
                    if (cancelled or self.shutting_down) {
                        self.allocator.free(result.bytes);
                    } else if (self.results.append(self.allocator, result)) |_| {
                        services = self.services;
                    } else |_| {
                        self.allocator.free(result.bytes);
                    }
                }
                self.mutex.unlock(self.io);
                if (services) |bound| bound.wake() catch {};
                if (response == null) self.retireChild(&child);
            }
        }

        const ExchangeResult = struct { ok: bool, bytes: []u8 };

        const DeadlineWatch = struct {
            host: *Self,
            request_id: u32,
            done: *std.Io.Event,
            timed_out: bool = false,

            fn run(watch: *DeadlineWatch) void {
                const duration: std.Io.Clock.Duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(watch.host.request_timeout_ms),
                    .clock = .awake,
                };
                const deadline = std.Io.Clock.Timestamp.fromNow(watch.host.io, duration);
                while (!watch.done.isSet()) {
                    watch.done.waitTimeout(watch.host.io, .{ .deadline = deadline }) catch |err| switch (err) {
                        error.Canceled => return,
                        error.Timeout => {
                            // Futex waits may wake spuriously. Only the actual
                            // monotonic deadline is authority to kill a child.
                            const now = std.Io.Clock.Timestamp.now(watch.host.io, .awake);
                            if (!std.Io.Clock.Timestamp.compare(now, .gte, deadline)) continue;
                            watch.host.mutex.lockUncancelable(watch.host.io);
                            if (watch.host.active_request_id == watch.request_id and !watch.done.isSet()) {
                                watch.timed_out = true;
                                watch.host.killPublishedChildLocked();
                            }
                            watch.host.mutex.unlock(watch.host.io);
                            return;
                        },
                    };
                }
            }
        };

        fn exchange(self: *Self, child: *?std.process.Child, request_entry: Request) !ExchangeResult {
            var done: std.Io.Event = .unset;
            var watch: DeadlineWatch = .{ .host = self, .request_id = request_entry.request_id, .done = &done };
            const watchdog = try std.Thread.spawn(.{}, DeadlineWatch.run, .{&watch});
            const result = self.exchangeUnbounded(child, request_entry) catch |err| {
                done.set(self.io);
                watchdog.join();
                if (watch.timed_out) return error.ServiceTimedOut;
                return err;
            };
            done.set(self.io);
            watchdog.join();
            if (watch.timed_out) {
                self.allocator.free(result.bytes);
                return error.ServiceTimedOut;
            }
            return result;
        }

        fn exchangeUnbounded(self: *Self, child: *?std.process.Child, request_entry: Request) !ExchangeResult {
            if (child.* == null) try self.startChild(child);
            var frame = try self.allocator.alloc(u8, 10 + request_entry.payload.len);
            defer self.allocator.free(frame);
            putU32(frame, 0, @intCast(6 + request_entry.payload.len));
            putU32(frame, 4, request_entry.request_id);
            putU16(frame, 8, request_entry.operation);
            @memcpy(frame[10..], request_entry.payload);
            const stdin = child.*.?.stdin orelse return error.NoServiceStdin;
            try stdin.writeStreamingAll(self.io, frame);

            var header: [4]u8 = undefined;
            const stdout = child.*.?.stdout orelse return error.NoServiceStdout;
            try readExact(self.io, stdout, &header);
            const length = readU32(&header, 0);
            if (length < 5 or length > max_frame_bytes) return error.BadServiceFrame;
            const body = try self.allocator.alloc(u8, length);
            errdefer self.allocator.free(body);
            try readExact(self.io, stdout, body);
            if (readU32(body, 0) != request_entry.request_id) return error.BadServiceRequestId;
            const status = body[4];
            if (status > 1) return error.BadServiceStatus;
            const bytes = try self.allocator.dupe(u8, body[5..]);
            self.allocator.free(body);
            return .{ .ok = status == 0, .bytes = bytes };
        }

        fn startChild(self: *Self, child: *?std.process.Child) !void {
            const child_cwd: std.process.Child.Cwd = if (self.cwd.len > 0) .{ .path = self.cwd } else .inherit;
            child.* = try std.process.spawn(self.io, .{
                .argv = &.{self.executable},
                .cwd = child_cwd,
                .environ_map = self.environ,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
                .create_no_window = builtin.os.tag == .windows,
                .pgid = if (builtin.os.tag == .windows) null else 0,
            });
            self.mutex.lockUncancelable(self.io);
            self.child_id = child.*.?.id;
            self.child_reaping = false;
            self.mutex.unlock(self.io);
            const stdout = child.*.?.stdout orelse return error.NoServiceStdout;
            var hello: [5]u8 = undefined;
            try readExact(self.io, stdout, &hello);
            if (readU32(&hello, 0) != @as(u32, @intCast(1 + Registry.contract_fingerprint.len)) or
                hello[4] != Registry.protocol_version) return error.ServiceProtocolSkew;
            var fingerprint: [Registry.contract_fingerprint.len]u8 = undefined;
            try readExact(self.io, stdout, &fingerprint);
            if (!std.mem.eql(u8, &fingerprint, &Registry.contract_fingerprint)) return error.ServiceProtocolSkew;
        }

        fn retireChild(self: *Self, child: *?std.process.Child) void {
            if (child.*) |*value| {
                self.mutex.lockUncancelable(self.io);
                self.child_reaping = true;
                self.mutex.unlock(self.io);
                if (value.stdin) |file| file.close(self.io);
                value.stdin = null;
                _ = value.wait(self.io) catch {};
                child.* = null;
                self.mutex.lockUncancelable(self.io);
                self.child_id = null;
                self.child_reaping = false;
                self.mutex.unlock(self.io);
            }
        }

        fn killPublishedChildLocked(self: *Self) void {
            if (self.child_reaping) return;
            const id = self.child_id orelse return;
            if (builtin.os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
            } else {
                std.posix.kill(-id, .KILL) catch std.posix.kill(id, .KILL) catch {};
            }
        }
    };
}

fn readExact(io: std.Io, file: std.Io.File, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const slices: [1][]u8 = .{bytes[offset..]};
        const count = try file.readStreaming(io, &slices);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn putU16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
}
fn putU32(bytes: []u8, at: usize, value: u32) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
    bytes[at + 2] = @truncate(value >> 16);
    bytes[at + 3] = @truncate(value >> 24);
}
fn readU32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

test "service host binding is lazy and shuts down without spawning" {
    const Registry = struct {
        pub const protocol_version: u8 = 1;
        pub const contract_fingerprint = [_]u8{0} ** 32;
        pub fn indexOf(name: []const u8) ?u16 {
            return if (std.mem.eql(u8, name, "fixture.echo")) 0 else null;
        }
    };
    const Host = ServiceHost(Registry);
    var host = Host.init(std.testing.allocator, std.testing.io, "missing-service-host", "", null);
    defer host.deinit();
    const bound = host.binding();
    try std.testing.expect(bound.poll_fn != null);
    try std.testing.expect(bound.shutdown_fn != null);
    try std.testing.expect(bound.reject_duplicate_keys);
}

test "service environment allowlist exposes authority without SDK internals" {
    try std.testing.expect(environmentVariableAllowed("PATH"));
    try std.testing.expect(environmentVariableAllowed("SSL_CERT_FILE"));
    try std.testing.expect(environmentVariableAllowed("HTTPS_PROXY"));
    try std.testing.expect(!environmentVariableAllowed("NATIVE_SDK_PATH"));
    try std.testing.expect(!environmentVariableAllowed("NATIVE_SDK_CORE_COMPILER"));
    try std.testing.expect(!environmentVariableAllowed("AWS_SECRET_ACCESS_KEY"));
}

test "service environment allowlist honors Windows names and casing" {
    try std.testing.expect(environmentVariableAllowedForOs("Path", .windows));
    try std.testing.expect(environmentVariableAllowedForOs("USERPROFILE", .windows));
    try std.testing.expect(environmentVariableAllowedForOs("username", .windows));
    try std.testing.expect(environmentVariableAllowedForOs("SystemRoot", .windows));
    try std.testing.expect(environmentVariableAllowedForOs("ComSpec", .windows));
    try std.testing.expect(environmentVariableAllowedForOs("PATHEXT", .windows));
    try std.testing.expect(!environmentVariableAllowedForOs("USERPROFILE", .linux));
    try std.testing.expect(!environmentVariableAllowedForOs("NATIVE_SDK_PATH", .windows));
}
