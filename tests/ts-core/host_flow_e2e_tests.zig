const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const p = sdk.runtime.host_flow_policy;
const Pump = sdk.runtime.testing.host_event_pump.HostEventPump;
const ReferencePump = sdk.runtime.testing.host_event_pump_reference.HostEventPump;
const Reference = sdk.runtime.testing.host_flow_reference.RuntimeFlow(sdk.Runtime);
const Harness = sdk.TestHarness();
var stages: [12]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 31) stages[input[2]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn PumpProbe(comptime T: type) type {
    return struct {
        pump: T,
        mode: u8 = 0,
        count: usize = 0,
        order: [8]u8 = @splat(0),
        expected_frame: sdk.platform.GpuSurfaceFrameEvent = .{ .label = "日本\x00\xff", .size = .init(-0.0, 800.25), .window_id = 9007199254740993, .frame_index = std.math.maxInt(u64), .packet_decode_ns = 9007199254740993, .packet_draw_ns = std.math.maxInt(u64), .occluded = true, .canvas_revision = std.math.maxInt(u64), .canvas_frame_requires_render = true, .canvas_frame_resource_evict_count = 19 },
        fn receive(context: *anyopaque, event: sdk.platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.count < self.order.len) self.order[self.count] = p.eventKind(event);
            self.count += 1;
            if (event == .app_start) switch (self.mode) {
                0 => {
                    try self.pump.dispatch(self, receive, .frame_requested);
                    try self.pump.dispatch(self, receive, .frame_requested);
                    try self.pump.dispatch(self, receive, .wake);
                    try self.pump.dispatch(self, receive, .frame_requested);
                    var label = "日本\x00\xff".*;
                    var frame = self.expected_frame;
                    frame.label = &label;
                    try self.pump.dispatch(self, receive, .{ .gpu_surface_frame = frame });
                    var path = "日本/file\x00\xff".*;
                    var paths = [_][]const u8{ &path, "" };
                    try self.pump.dispatch(self, receive, .{ .files_dropped = .{ .window_id = std.math.maxInt(u64), .paths = &paths } });
                    @memset(&label, 'x');
                    @memset(&path, 'x');
                    paths[0] = "changed";
                },
                1, 2 => {
                    for (0..4095) |_| try self.pump.dispatch(self, receive, .wake);
                    try self.pump.dispatch(self, receive, .frame_requested);
                    try self.pump.dispatch(self, receive, .frame_requested);
                    self.pump.dispatch(self, receive, .wake) catch {};
                    if (self.mode == 2) return error.HandlerWins;
                },
                3 => try self.pump.dispatch(self, receive, .wake),
                4 => for (0..4096) |_| {
                    try self.pump.dispatch(self, receive, .wake);
                },
                else => unreachable,
            } else switch (self.mode) {
                0 => switch (event) {
                    .gpu_surface_frame => |frame| try exact(self.expected_frame, frame),
                    .files_dropped => |drop| try exact(sdk.platform.FileDropEvent{ .window_id = std.math.maxInt(u64), .paths = &.{ "日本/file\x00\xff", "" } }, drop),
                    else => {},
                },
                3, 4 => try self.pump.dispatch(self, receive, .wake),
                else => {},
            }
        }
    };
}
test "compiled host flow preserves pump reentrancy all GPU telemetry borrowed ownership and failure recovery" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..5) |mode| {
        var left: PumpProbe(ReferencePump) = .{ .pump = .{ .allocator = std.testing.allocator }, .mode = @intCast(mode) };
        defer left.pump.deinit();
        var right: PumpProbe(Pump) = .{ .pump = .{ .allocator = std.testing.allocator, .policy = observed }, .mode = @intCast(mode) };
        defer right.pump.deinit();
        const a = left.pump.dispatch(&left, @TypeOf(left).receive, .app_start);
        const b = right.pump.dispatch(&right, @TypeOf(right).receive, .app_start);
        if (a) |_| try b else |err| try std.testing.expectError(err, b);
        try exact(left.count, right.count);
        try exact(left.order, right.order);
        inline for (.{ "active", "count", "head", "bytes", "pending_error" }) |field| try exact(@field(left.pump, field), @field(right.pump, field));
        try exact(left.pump.pending.capacity, right.pump.pending.capacity);
        left.mode = 1;
        right.mode = 1;
        try left.pump.dispatch(&left, @TypeOf(left).receive, .wake);
        try right.pump.dispatch(&right, @TypeOf(right).receive, .wake);
        try exact(left.count, right.count);
    }
}
fn allocationProbe(comptime T: type, allocator: std.mem.Allocator) !void {
    var probe: PumpProbe(T) = .{ .pump = .{ .allocator = allocator } };
    if (T == Pump) probe.pump.policy = observed;
    defer probe.pump.deinit();
    try probe.pump.dispatch(&probe, @TypeOf(probe).receive, .app_start);
}
fn referenceAllocation(allocator: std.mem.Allocator) !void {
    try allocationProbe(ReferencePump, allocator);
}
fn compiledAllocation(allocator: std.mem.Allocator) !void {
    try allocationProbe(Pump, allocator);
}
test "compiled host flow releases recursive event ownership at every allocation failure" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceAllocation, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compiledAllocation, .{});
}
fn byteProbe(comptime T: type, delta: i32) !void {
    const Probe = struct {
        pump: T,
        bytes: []const u8,
        delivered: bool = false,
        fn receive(context: *anyopaque, event: sdk.platform.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .app_start) try self.pump.dispatch(self, receive, .{ .bridge_message = .{ .bytes = self.bytes, .origin = "", .webview_label = "" } }) else {
                try std.testing.expectEqualSlices(u8, self.bytes, event.bridge_message.bytes);
                self.delivered = true;
            }
        }
    };
    const Pending = @typeInfo(@TypeOf(@as(T, undefined).pending.items)).pointer.child;
    const length: usize = @intCast(@as(i64, 4194304 - @sizeOf(Pending)) + delta);
    const bytes = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xff);
    var probe: Probe = .{ .pump = .{ .allocator = std.testing.allocator }, .bytes = bytes };
    if (T == Pump) probe.pump.policy = observed;
    defer probe.pump.deinit();
    const result = probe.pump.dispatch(&probe, Probe.receive, .app_start);
    if (delta > 0) try std.testing.expectError(error.HostEventQueueFull, result) else {
        try result;
        try std.testing.expect(probe.delivered);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.pump.bytes);
}
test "compiled host flow admits exact owned-byte boundary including pending storage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]i32{ -1, 0, 1 }) |delta| {
        try byteProbe(ReferencePump, delta);
        try byteProbe(Pump, delta);
    }
}
const AppState = struct {
    calls: std.ArrayList(u8) = .empty,
    fail: bool = false,
    nested: bool = false,
    compiled: bool = false,
    stops: usize = 0,
    fn app(self: *@This(), compiled: bool) sdk.App {
        self.compiled = compiled;
        return .{ .context = self, .name = "host-flow", .source = sdk.platform.WebViewSource.html(""), .event_fn = event, .stop_fn = stop, .host_flow_policy = if (compiled) observed else null };
    }
    fn event(context: *anyopaque, rt: *sdk.Runtime, value: sdk.Event) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
        defer std.testing.allocator.free(bytes);
        try self.calls.appendSlice(std.testing.allocator, bytes);
        try self.calls.appendSlice(std.testing.allocator, &.{ @intFromBool(rt.app_active), '\n' });
        if (self.nested) {
            self.nested = false;
            try rt.dispatchPlatformEvent(self.app(self.compiled), .{ .timer = .{ .id = 9007199254740993, .timestamp_ns = std.math.maxInt(u64) } });
        }
        if (self.fail) return error.TestHandlerFailure;
    }
    fn stop(context: *anyopaque, _: *sdk.Runtime) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.stops += 1;
        if (self.fail) return error.TestStopFailure;
    }
};
const Pair = struct {
    h: [2]*Harness,
    states: [2]AppState = .{ .{}, .{} },
    fn create() !*@This() {
        const self = try std.testing.allocator.create(@This());
        self.* = .{ .h = .{ try Harness.create(std.testing.allocator, .{}), try Harness.create(std.testing.allocator, .{}) } };
        for (self.h) |h| {
            h.runtime.started_timestamp_ns = 0;
            h.runtime.dispatch_error_policy = .degrade;
        }
        return self;
    }
    fn destroy(self: *@This()) void {
        for (self.h) |h| h.destroy(std.testing.allocator);
        for (&self.states) |*state| state.calls.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }
    fn same(self: *@This()) !void {
        const a = &self.h[0].runtime;
        const b = &self.h[1].runtime;
        inline for (.{ "app_active", "appearance", "surface", "invalidated", "frame_index", "command_count", "dirty_region_count", "app_stop_delivered", "dispatch_error_total", "window_count", "view_count", "next_window_id" }) |field| try exact(@field(a, field), @field(b, field));
        for (a.windows[0..a.window_count], b.windows[0..b.window_count]) |left, right| try exact(left.info, right.info);
        var sa = a.automationSnapshot("host-flow");
        var sb = b.automationSnapshot("host-flow");
        var ea: [sdk.runtime.max_dispatch_errors]sdk.runtime.DispatchError = undefined;
        var eb: [sdk.runtime.max_dispatch_errors]sdk.runtime.DispatchError = undefined;
        for (sa.errors, 0..) |value, i| {
            ea[i] = value;
            ea[i].timestamp_ns = 0;
            @memset(ea[i].event_storage[ea[i].event_len..], 0);
            @memset(ea[i].detail_storage[ea[i].detail_len..], 0);
        }
        for (sb.errors, 0..) |value, i| {
            eb[i] = value;
            eb[i].timestamp_ns = 0;
            @memset(eb[i].event_storage[eb[i].event_len..], 0);
            @memset(eb[i].detail_storage[eb[i].detail_len..], 0);
        }
        sa.errors = ea[0..sa.errors.len];
        sb.errors = eb[0..sb.errors.len];
        try exact(sa, sb);
        try exact(self.states[0].calls.items, self.states[1].calls.items);
        try exact(self.states[0].stops, self.states[1].stops);
    }
    fn platformEvent(self: *@This(), value: sdk.platform.Event) !void {
        const a = Reference.dispatchPlatformEvent(&self.h[0].runtime, self.states[0].app(false), value);
        const b = self.h[1].runtime.dispatchPlatformEvent(self.states[1].app(true), value);
        if (a) |_| try b else |err| try std.testing.expectError(err, b);
        try self.same();
    }
    fn appEvent(self: *@This(), value: sdk.Event) !void {
        const a = Reference.dispatchEvent(&self.h[0].runtime, self.states[0].app(false), value);
        const b = self.h[1].runtime.dispatchEvent(self.states[1].app(true), value);
        if (a) |_| try b else |err| try std.testing.expectError(err, b);
        try self.same();
    }
};
test "compiled host flow matches every platform and app event complete state errors and callback order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.platformEvent(.app_start);
    inline for (@typeInfo(sdk.platform.Event).@"union".fields) |field| if (!std.mem.eql(u8, field.name, "app_start") and !std.mem.eql(u8, field.name, "app_shutdown")) {
        try pair.platformEvent(@unionInit(sdk.platform.Event, field.name, std.mem.zeroes(field.type)));
    };
    inline for (@typeInfo(sdk.Event).@"union".fields) |field| {
        try pair.appEvent(@unionInit(sdk.Event, field.name, std.mem.zeroes(field.type)));
    }
    for ([_]bool{ false, true }) |fail| {
        for (pair.h) |h| h.runtime.dispatch_error_policy = .propagate;
        for (&pair.states) |*state| state.fail = fail;
        try pair.platformEvent(.{ .shortcut = .{ .id = "app.command", .key = "p", .window_id = std.math.maxInt(u64) } });
        try pair.appEvent(.{ .command = .{ .name = "app.command" } });
        try pair.platformEvent(.app_deactivated);
    }
    for (&pair.states) |*state| state.fail = false;
    try pair.platformEvent(.app_shutdown);
}
fn refuseSecurity(_: ?*anyopaque, _: sdk.security.Policy) !void {
    return error.TestConfigureFailure;
}
test "compiled host flow preserves run cleanup stop-once and configuration-failure boundary" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |refuse| {
        const pair = try Pair.create();
        defer pair.destroy();
        for (pair.h) |h| if (refuse) {
            h.runtime.options.platform.services.configure_security_policy_fn = refuseSecurity;
        };
        const a = Reference.run(&pair.h[0].runtime, pair.states[0].app(false));
        const b = pair.h[1].runtime.run(pair.states[1].app(true));
        if (a) |_| try b else |err| try std.testing.expectError(err, b);
        try pair.same();
        try std.testing.expectEqual(@as(usize, if (refuse) 0 else 1), pair.states[1].stops);
    }
}
test "compiled host flow validates response ownership extents and typed action compatibility" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..29) |kind| {
        const facts = p.Facts{ .kind = @intCast(kind) };
        const plan = p.plan(observed, .platform_event, facts);
        try std.testing.expect(p.validResult(.platform_event, facts, &plan));
        for (0..64) |length| try std.testing.expect(!p.validResult(.platform_event, facts, plan[0..length]));
        var bad = plan;
        bad[63] = 1;
        try std.testing.expect(!p.validResult(.platform_event, facts, &bad));
        bad = @splat(0);
        bad[0] = @intFromEnum(p.Action.command_native_command);
        try std.testing.expectEqual(kind == 13, p.validResult(.platform_event, facts, &bad));
    }
    const before = p.plan(observed, .cleanup, .{ .b = 1 });
    const saved = before;
    _ = p.plan(observed, .run, .{});
    core.rt.frameReset();
    try exact(saved, before);
    for (stages) |count| try std.testing.expect(count > 0);
}

const JournalSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.TestJournalFailure;
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
};
test "compiled host flow preserves complete nested journal bytes error commits and shutdown seals" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]usize{ 2, 3, 4, 8, std.math.maxInt(usize) }) |fail_at| {
        const pair = try Pair.create();
        defer pair.destroy();
        var sinks: [2]JournalSink = .{ .{ .fail_at = fail_at }, .{ .fail_at = fail_at } };
        defer for (&sinks) |*sink| sink.bytes.deinit(std.testing.allocator);
        const recorders = try std.testing.allocator.alloc(sdk.runtime.SessionRecorder, 2);
        defer std.testing.allocator.free(recorders);
        for (recorders, 0..) |*recorder, i| {
            recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &sinks[i], .write_fn = JournalSink.write });
            recorder.begin(.{ .platform_name = "test", .app_name = "host-flow", .recorded_at_wall_ms = -17 });
            pair.h[i].runtime.options.session_recorder = recorder;
            pair.states[i].nested = true;
        }
        try pair.platformEvent(.app_start);
        for (pair.h) |h| h.runtime.dispatch_error_policy = .propagate;
        for (&pair.states) |*state| state.fail = true;
        try pair.platformEvent(.{ .timer = .{ .id = std.math.maxInt(u64) } });
        try pair.platformEvent(.app_shutdown);
        try exact(sinks[0].calls, sinks[1].calls);
        try exact(sinks[0].bytes.items, sinks[1].bytes.items);
        inline for (.{ "finished", "failed", "depth", "event_count", "checkpoint_count", "bytes_written" }) |field| try exact(@field(recorders[0], field), @field(recorders[1], field));
    }
}
test "compiled host flow close edge uses runtime-owned label and does not repeat closure" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.platformEvent(.app_start);
    const close = sdk.platform.WindowState{ .id = 1, .label = "untrusted-host-label", .title = "Closed", .frame = .init(-0.0, 11.25, 640, 360), .open = false };
    try pair.platformEvent(.{ .window_frame_changed = close });
    const count = pair.states[1].calls.items.len;
    try std.testing.expect(std.mem.indexOf(u8, pair.states[1].calls.items, "window_closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, pair.states[1].calls.items, "untrusted-host-label") == null);
    try pair.platformEvent(.{ .window_frame_changed = close });
    try std.testing.expectEqual(count, pair.states[1].calls.items.len);
}
fn failMenus(_: ?*anyopaque, _: []const sdk.platform.Menu) !void {
    return error.TestMenuFailure;
}
fn failShortcuts(_: ?*anyopaque, _: []const sdk.platform.Shortcut) !void {
    return error.TestShortcutFailure;
}
fn failRun(_: *anyopaque, _: sdk.platform.EventHandler, _: *anyopaque) !void {
    return error.TestRunFailure;
}
fn startThenShutdown(_: *anyopaque, handler: sdk.platform.EventHandler, context: *anyopaque) !void {
    try handler(context, .app_start);
    try handler(context, .app_shutdown);
}
test "compiled host flow keeps configuration refusals before stop and marks throwing stop exactly once" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..5) |mode| {
        const pair = try Pair.create();
        defer pair.destroy();
        for (pair.h, 0..) |h, i| {
            switch (mode) {
                0 => h.runtime.options.platform.services.configure_menus_fn = failMenus,
                1 => h.runtime.options.platform.services.configure_shortcuts_fn = failShortcuts,
                2 => h.runtime.options.platform.run_fn = failRun,
                3, 4 => {
                    h.runtime.options.platform.run_fn = startThenShutdown;
                    pair.states[i].fail = true;
                },
                else => unreachable,
            }
            h.runtime.dispatch_error_policy = if (mode == 4) .propagate else .degrade;
        }
        const a = Reference.run(&pair.h[0].runtime, pair.states[0].app(false));
        const b = pair.h[1].runtime.run(pair.states[1].app(true));
        if (a) |_| try b else |err| try std.testing.expectError(err, b);
        try pair.same();
        try std.testing.expectEqual(@as(usize, if (mode < 2) 0 else 1), pair.states[1].stops);
    }
}
