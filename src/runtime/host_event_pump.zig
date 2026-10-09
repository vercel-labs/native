//! Native callbacks can reenter the runtime while a window or modal service
//! is still executing. Own those event bytes and deliver them after the
//! triggering dispatch commits, preserving causal journal order.
const std = @import("std");
const platform = @import("../platform/root.zig");

pub const HostEventPump = struct {
    const capacity = 4096;
    const Pending = struct { event: platform.Event, arena: std.heap.ArenaAllocator, bytes: usize };
    const max_bytes = 4 * 1024 * 1024;
    allocator: std.mem.Allocator,
    active: bool = false,
    pending: std.ArrayList(Pending) = .empty,
    head: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    pending_error: ?anyerror = null,

    pub fn deinit(self: *HostEventPump) void {
        while (self.count > 0) {
            var pending = self.take();
            pending.arena.deinit();
        }
        self.pending.deinit(self.allocator);
        self.pending = .empty;
    }

    fn take(self: *HostEventPump) Pending {
        const value = self.pending.items[self.head];
        self.head += 1;
        self.count -= 1;
        self.bytes -= value.bytes;
        if (self.count == 0) {
            self.pending.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= capacity and self.head >= self.count) {
            std.mem.copyForwards(Pending, self.pending.items[0..self.count], self.pending.items[self.head..][0..self.count]);
            self.pending.items.len = self.count;
            self.head = 0;
        }
        return value;
    }

    fn enqueue(self: *HostEventPump, event: platform.Event) !void {
        if (self.count == capacity or @sizeOf(Pending) > max_bytes - self.bytes) return error.HostEventQueueFull;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        var remaining = max_bytes - self.bytes - @sizeOf(Pending);
        const owned = try copyBorrowed(arena.allocator(), event, &remaining);
        const bytes = max_bytes - self.bytes - remaining;
        try self.pending.append(self.allocator, .{ .event = owned, .arena = arena, .bytes = bytes });
        self.count += 1;
        self.bytes += bytes;
    }

    // Copy every borrowed slice recursively; retain scalar telemetry and
    // native handles verbatim. Journal codecs deliberately omit host frame
    // telemetry and therefore cannot serve as this live ownership boundary.
    fn copyBorrowed(allocator: std.mem.Allocator, value: anytype, remaining: *usize) anyerror!@TypeOf(value) {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .pointer => |pointer| if (pointer.size == .slice) blk: {
                const bytes = std.math.mul(usize, value.len, @sizeOf(pointer.child)) catch return error.HostEventQueueFull;
                if (bytes > remaining.*) return error.HostEventQueueFull;
                remaining.* -= bytes;
                const owned = try allocator.alloc(pointer.child, value.len);
                for (value, owned) |item, *out| out.* = try copyBorrowed(allocator, item, remaining);
                break :blk owned;
            } else value,
            .optional => if (value) |item| try copyBorrowed(allocator, item, remaining) else null,
            .@"struct" => |info| blk: {
                var owned = value;
                inline for (info.fields) |field| {
                    if (!field.is_comptime) @field(owned, field.name) = try copyBorrowed(allocator, @field(value, field.name), remaining);
                }
                break :blk owned;
            },
            .@"union" => switch (value) {
                inline else => |item, tag| @unionInit(T, @tagName(tag), try copyBorrowed(allocator, item, remaining)),
            },
            .array => blk: {
                var owned = value;
                for (value, &owned) |item, *out| out.* = try copyBorrowed(allocator, item, remaining);
                break :blk owned;
            },
            else => value,
        };
    }

    pub fn dispatch(self: *HostEventPump, context: *anyopaque, handler: platform.EventHandler, event: platform.Event) anyerror!void {
        if (self.active) return self.enqueue(event) catch |err| {
            self.pending_error = err;
            return err;
        };
        self.active = true;
        defer {
            self.active = false;
            self.pending_error = null;
        }
        errdefer self.deinit();
        try handler(context, event);
        if (self.pending_error) |err| return err;
        var delivered: usize = 0;
        while (self.count > 0) {
            if (delivered == capacity) return error.HostEventTurnLimit;
            delivered += 1;
            var pending = self.take();
            defer pending.arena.deinit();
            try handler(context, pending.event);
            if (self.pending_error) |err| return err;
        }
    }
};

test "native callbacks retain borrowed payloads and drain after their cause" {
    const Probe = struct {
        pump: HostEventPump = .{ .allocator = std.testing.allocator },
        order: [3]u8 = undefined,
        count: usize = 0,
        fn receive(context: *anyopaque, event: platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .app_start => {
                    var label = "child".*;
                    try self.pump.dispatch(self, receive, .{ .menu_command = .{ .name = &label } });
                    @memset(&label, 'x');
                    try std.testing.expectEqual(@as(usize, 0), self.count);
                    self.order[self.count] = 1;
                },
                .menu_command => |command| {
                    try std.testing.expectEqualStrings("child", command.name);
                    self.order[self.count] = 2;
                    try self.pump.dispatch(self, receive, .wake);
                },
                .wake => self.order[self.count] = 3,
                else => unreachable,
            }
            self.count += 1;
        }
    };
    var probe: Probe = .{};
    defer probe.pump.deinit();
    try probe.pump.dispatch(&probe, Probe.receive, .app_start);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &probe.order);
    try std.testing.expectEqual(@as(usize, 0), probe.pump.bytes);
}

test "native callback failure releases queued ownership and allows the next turn" {
    const Probe = struct {
        pump: HostEventPump = .{ .allocator = std.testing.allocator },
        fn receive(context: *anyopaque, event: platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .app_start) {
                try self.pump.dispatch(self, receive, .wake);
                return error.HandlerFailure;
            }
        }
    };
    var probe: Probe = .{};
    defer probe.pump.deinit();
    try std.testing.expectError(error.HandlerFailure, probe.pump.dispatch(&probe, Probe.receive, .app_start));
    try std.testing.expectEqual(@as(usize, 0), probe.pump.bytes);
    try std.testing.expect(!probe.pump.active);
    try probe.pump.dispatch(&probe, Probe.receive, .wake);
}

test "native callbacks preserve complete frame telemetry and nested path bytes" {
    const Probe = struct {
        pump: HostEventPump = .{ .allocator = std.testing.allocator },
        expected: platform.GpuSurfaceFrameEvent = .{
            .label = "canvas",
            .size = .init(200, 100),
            .window_id = 9,
            .timestamp_ns = 9007199254740993,
            .frame_index = 42,
            .packet_decode_ns = 17,
            .packet_draw_ns = 23,
            .canvas_revision = 19,
            .canvas_frame_resource_retain_count = 11,
            .nonblank = true,
        },
        received: u8 = 0,
        fn receive(context: *anyopaque, event: platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .app_start => {
                    var label = "canvas".*;
                    var frame = self.expected;
                    frame.label = &label;
                    try self.pump.dispatch(self, receive, .{ .gpu_surface_frame = frame });
                    var path = "日本/file.ts".*;
                    var paths = [_][]const u8{&path};
                    try self.pump.dispatch(self, receive, .{ .files_dropped = .{ .window_id = 9, .paths = &paths } });
                    @memset(&label, 'x');
                    @memset(&path, 'x');
                    paths[0] = "changed";
                },
                .gpu_surface_frame => |frame| {
                    try std.testing.expectEqualDeep(self.expected, frame);
                    self.received += 1;
                },
                .files_dropped => |drop| {
                    try std.testing.expectEqual(@as(u64, 9), drop.window_id);
                    try std.testing.expectEqual(@as(usize, 1), drop.paths.len);
                    try std.testing.expectEqualStrings("日本/file.ts", drop.paths[0]);
                    self.received += 1;
                },
                else => unreachable,
            }
        }
    };
    var probe: Probe = .{};
    defer probe.pump.deinit();
    try probe.pump.dispatch(&probe, Probe.receive, .app_start);
    try std.testing.expectEqual(@as(u8, 2), probe.received);
}

test "native callback overflow fails the turn even if the host ignores its error" {
    const Probe = struct {
        pump: HostEventPump = .{ .allocator = std.testing.allocator },
        fn receive(context: *anyopaque, event: platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .app_start) for (0..HostEventPump.capacity + 1) |_| {
                self.pump.dispatch(self, receive, .wake) catch {};
            };
        }
    };
    var probe: Probe = .{};
    defer probe.pump.deinit();
    try std.testing.expectError(error.HostEventQueueFull, probe.pump.dispatch(&probe, Probe.receive, .app_start));
    try std.testing.expectEqual(@as(usize, 0), probe.pump.count);
    try probe.pump.dispatch(&probe, Probe.receive, .wake);
}
