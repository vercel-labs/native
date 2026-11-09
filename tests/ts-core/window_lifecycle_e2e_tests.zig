const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const storage = sdk.runtime.testing.window_storage_methods;
const Harness = sdk.TestHarness();
var modes: [7]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 81) modes[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Call = struct { verb: u8, id: u64, flags: u32, view_count: usize };
const Trace = struct {
    base: sdk.platform.PlatformServices = .{},
    runtime: ?*sdk.Runtime = null,
    calls: [64]Call = undefined,
    count: usize = 0,
    refuse: ?u8 = null,
    failure: anyerror = error.TestWindowFailure,
    echo: bool = false,
    mutate_show: bool = false,
    accessibility: std.ArrayList(u8) = .empty,
    fail_accessibility: bool = false,
    mutate_activity: bool = false,
    fn call(self: *Trace, verb: u8, id: u64) !void {
        const rt = self.runtime.?;
        const index = storage.findWindowIndexById(rt, id) orelse return error.WindowNotFound;
        try std.testing.expect(self.count < self.calls.len);
        self.calls[self.count] = .{ .verb = verb, .id = id, .flags = sdk.runtime.testing.window_lifecycle_policy.flags(rt.windows[index].info), .view_count = rt.view_count };
        self.count += 1;
        if (self.refuse == verb) return self.failure;
        if (self.mutate_show and verb == 2) rt.windows[index].activate_on_show = false;
        if (self.echo) {
            const info = rt.windows[index].info;
            try storage.updateWindowState(rt, .{ .id = id, .label = info.label, .title = info.title, .frame = info.frame, .scale_factor = info.scale_factor, .open = info.open, .hidden = info.hidden, .focused = info.focused });
        }
    }
};
var traces: [2]Trace = .{ .{}, .{} };
fn trace(context: ?*anyopaque) *Trace {
    for (&traces) |*t| if (t.base.context == context) return t;
    unreachable;
}
fn close(context: ?*anyopaque, id: u64) !void {
    const t = trace(context);
    try t.call(0, id);
    try t.base.closeWindow(id);
}
fn hide(context: ?*anyopaque, id: u64) !void {
    const t = trace(context);
    try t.call(1, id);
    try t.base.hideWindow(id);
}
fn show(context: ?*anyopaque, id: u64) !void {
    const t = trace(context);
    try t.call(2, id);
    try t.base.showWindow(id);
}
fn focus(context: ?*anyopaque, id: u64) !void {
    const t = trace(context);
    try t.call(3, id);
    try t.base.focusWindow(id);
}
fn minimize(context: ?*anyopaque, id: u64) !void {
    const t = trace(context);
    try t.call(4, id);
    try t.base.minimizeWindow(id);
}
fn accessibility(context: ?*anyopaque, snapshot: sdk.platform.WidgetAccessibilitySnapshot) !void {
    const t = trace(context);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, snapshot, .{});
    defer std.testing.allocator.free(bytes);
    try t.accessibility.appendSlice(std.testing.allocator, bytes);
    try t.accessibility.append(std.testing.allocator, '\n');
    if (t.mutate_activity) t.runtime.?.app_active = true;
    if (t.fail_accessibility) return if (snapshot.window_id == 1) error.FirstPublicationFailure else error.LaterPublicationFailure;
    try t.base.updateWidgetAccessibility(snapshot);
}
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        var pair = Pair{ .left = try Harness.create(std.testing.allocator, .{}), .right = try Harness.create(std.testing.allocator, .{}) };
        for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(.{ .context = h, .name = "window-lifecycle", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            traces[i] = .{ .base = h.runtime.options.platform.services, .runtime = &h.runtime };
            h.runtime.options.platform.services.close_window_fn = close;
            h.runtime.options.platform.services.hide_window_fn = hide;
            h.runtime.options.platform.services.show_window_fn = show;
            h.runtime.options.platform.services.focus_window_fn = focus;
            h.runtime.options.platform.services.minimize_window_fn = minimize;
            if (i == 1) h.runtime.window_lifecycle_policy = observed;
            _ = try h.runtime.createWindow(.{ .id = 9007199254740993, .label = "panel", .title = "Panel", .default_frame = .init(100, 50, 400, 300), .source = sdk.platform.WebViewSource.html("panel") });
            for ([_]u64{ 1, 9007199254740993 }) |id| {
                _ = try h.runtime.createView(.{ .window_id = id, .label = "action", .kind = .button, .frame = .init(10, 10, 80, 30) });
                _ = try h.runtime.createView(.{ .window_id = id, .label = "canvas", .kind = .gpu_surface, .frame = .init(10, 50, 200, 100) });
            }
        }
        try pair.same();
        return pair;
    }
    fn destroy(self: *Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
        for (&traces) |*t| t.accessibility.deinit(std.testing.allocator);
    }
    fn same(self: *Pair) !void {
        @setEvalBranchQuota(10000);
        try exact(self.left.runtime.automationSnapshot("window-lifecycle"), self.right.runtime.automationSnapshot("window-lifecycle"));
        try std.testing.expectEqual(self.left.runtime.app_active, self.right.runtime.app_active);
        try std.testing.expectEqual(self.left.runtime.invalidated, self.right.runtime.invalidated);
        try std.testing.expectEqual(self.left.runtime.window_count, self.right.runtime.window_count);
        for (self.left.runtime.windows[0..self.left.runtime.window_count], self.right.runtime.windows[0..self.right.runtime.window_count]) |*a, *b| {
            try exact(a.info, b.info);
            try exact(a.main_frame, b.main_frame);
            try exact(a.main_focused, b.main_focused);
            try exact(a.main_frame_set, b.main_frame_set);
            try exact(a.activate_on_show, b.activate_on_show);
        }
        try exact(self.left.null_platform.windows[0..self.left.null_platform.window_count], self.right.null_platform.windows[0..self.right.null_platform.window_count]);
        try exact(self.left.null_platform.views[0..self.left.null_platform.view_count], self.right.null_platform.views[0..self.right.null_platform.view_count]);
        try std.testing.expectEqual(self.left.runtime.view_count, self.right.runtime.view_count);
        for (0..self.left.runtime.view_count) |i| {
            const a = &self.left.runtime.views[i];
            const b = &self.right.runtime.views[i];
            try exact(a.info(), b.info());
            try exact(a.canvasWidgetRenderState(), b.canvasWidgetRenderState());
            inline for (@typeInfo(@TypeOf(a.*)).@"struct".fields) |field| {
                if (comptime std.mem.startsWith(u8, field.name, "canvas_tooltip_")) try exact(@field(a, field.name), @field(b, field.name));
            }
        }
        try exact(traces[0].calls[0..traces[0].count], traces[1].calls[0..traces[1].count]);
        try exact(traces[0].accessibility.items, traces[1].accessibility.items);
        core.rt.frameReset();
    }
    fn invoke(self: *Pair, verb: u8, id: u64) !void {
        const left = invokeOne(&self.left.runtime, verb, id);
        if (left) |_| try invokeOne(&self.right.runtime, verb, id) else |err| try std.testing.expectError(err, invokeOne(&self.right.runtime, verb, id));
        try self.same();
    }
};
fn invokeOne(rt: *sdk.Runtime, verb: u8, id: u64) !void {
    switch (verb) {
        0 => try rt.closeWindow(id),
        1 => try rt.hideWindow(id),
        2 => try rt.showWindow(id),
        3 => try rt.focusWindow(id),
        4 => try rt.minimizeWindow(id),
        else => unreachable,
    }
}
test "compiled window lifecycle retains first error and observes later keyboard callback mutations" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.options.platform.services.update_widget_accessibility_fn = accessibility;
        for (h.runtime.views[0..h.runtime.view_count]) |*v| {
            v.keyboard_active = true;
            v.widget_accessibility_published = false;
        }
    }
    for (&traces) |*t| {
        t.fail_accessibility = true;
        t.mutate_activity = true;
    }
    try std.testing.expectError(error.FirstPublicationFailure, storage.setAppActive(&pair.left.runtime, false));
    try std.testing.expectError(error.FirstPublicationFailure, storage.setAppActive(&pair.right.runtime, false));
    try pair.same();
    try std.testing.expect(traces[1].accessibility.items.len > 0);
    for (pair.right.runtime.views[0..pair.right.runtime.view_count]) |*v| try std.testing.expect(!v.keyboard_active);
    for (&traces) |*t| {
        t.mutate_activity = false;
        t.accessibility.clearRetainingCapacity();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        for (h.runtime.views[0..h.runtime.view_count]) |*v| {
            v.keyboard_active = true;
            v.widget_accessibility_published = false;
        }
    }
    try std.testing.expectError(error.FirstPublicationFailure, storage.setFocusedIndex(&pair.left.runtime, std.math.maxInt(usize)));
    try std.testing.expectError(error.FirstPublicationFailure, storage.setFocusedIndex(&pair.right.runtime, std.math.maxInt(usize)));
    try pair.same();
    for (pair.right.runtime.views[0..pair.right.runtime.view_count]) |*v| try std.testing.expect(!v.keyboard_active);
}
test "compiled window lifecycle preserves complete capability staging and hidden focus order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.invoke(1, 9007199254740993);
    try pair.invoke(3, 9007199254740993);
    try std.testing.expectEqual(@as(u8, 1), traces[1].calls[0].verb);
    try std.testing.expectEqual(@as(u8, 2), traces[1].calls[1].verb);
    try std.testing.expectEqual(@as(u8, 3), traces[1].calls[2].verb);
    try std.testing.expectEqual(@as(u32, 5), traces[1].calls[0].flags);
    try std.testing.expectEqual(@as(u32, 1), traces[1].calls[1].flags);
    try pair.invoke(4, 9007199254740993);
    try pair.invoke(1, 9007199254740993);
    try pair.invoke(2, 9007199254740993);
    try pair.invoke(0, 9007199254740993);
    try std.testing.expectEqual(@as(usize, 2), pair.right.runtime.view_count);
    try std.testing.expectEqual(@as(u32, 0), sdk.runtime.testing.window_lifecycle_policy.flags(pair.right.runtime.windows[1].info));
}
test "compiled window lifecycle preserves refusal rollback and every capability prefix" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u8{ 0, 1, 2, 3, 4 }) |verb| {
        var pair = try Pair.create();
        defer pair.destroy();
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            h.runtime.windows[1].info.hidden = true;
            h.runtime.windows[1].info.focused = true;
        }
        // A hidden focus first shows, then refuses focus; the successful show is retained.
        traces[0].refuse = verb;
        traces[1].refuse = verb;
        try pair.invoke(verb, 9007199254740993);
        try std.testing.expectEqual(@as(usize, 4), pair.right.runtime.view_count);
        if (verb != 3) try std.testing.expect(pair.right.runtime.windows[1].info.hidden);
    }
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.windows[1].info.hidden = true;
    traces[0].refuse = 2;
    traces[1].refuse = 2;
    try pair.invoke(3, 9007199254740993);
    try std.testing.expectEqual(@as(usize, 1), traces[1].count);
}
test "compiled window lifecycle observes synchronous host echoes and postshow callback mutations" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |mutate| {
        var pair = try Pair.create();
        defer pair.destroy();
        traces[0].echo = true;
        traces[1].echo = true;
        traces[0].mutate_show = mutate;
        traces[1].mutate_show = mutate;
        try pair.invoke(1, 9007199254740993);
        try pair.invoke(2, 9007199254740993);
        try std.testing.expectEqual(!mutate, pair.right.runtime.windows[1].info.focused);
        try pair.invoke(3, 1);
        try pair.invoke(0, 9007199254740993);
    }
}
test "compiled window lifecycle preserves passive show and explicit activation" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.windows[1].activate_on_show = false;
        try storage.setFocusedIndex(&h.runtime, 0);
    }
    try pair.same();
    try pair.invoke(1, 9007199254740993);
    try pair.invoke(2, 9007199254740993);
    try std.testing.expect(pair.right.runtime.windows[0].info.focused);
    try pair.invoke(3, 9007199254740993);
    try std.testing.expect(pair.right.runtime.windows[1].info.focused);
}
test "compiled window lifecycle retains exact dead-slot liveness and close retry behavior" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.invoke(0, 9007199254740993);
    const count = traces[1].count;
    for ([_]u8{ 1, 2, 3, 4 }) |verb| try pair.invoke(verb, 9007199254740993);
    try std.testing.expectEqual(count, traces[1].count);
    try pair.invoke(0, 9007199254740993);
    try std.testing.expectEqual(count + 1, traces[1].count);
    for ([_]u64{ 2, 9007199254740992, std.math.maxInt(u64) }) |id| for (0..5) |verb| try pair.invoke(@intCast(verb), id);
}
test "compiled window lifecycle preserves replay-only absent host close exception" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |replay| for ([_]anyerror{ error.WindowNotFound, error.TestWindowFailure }) |err| {
        var pair = try Pair.create();
        defer pair.destroy();
        for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.replay_window_chrome_active = replay;
        for (&traces) |*t| {
            t.refuse = 0;
            t.failure = err;
        }
        try pair.invoke(0, 9007199254740993);
        try std.testing.expectEqual(!(replay and err == error.WindowNotFound), pair.right.runtime.windows[1].info.open);
    };
}
test "compiled window lifecycle preserves full app activation projection and per-window focus memory" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]usize{ 0, 1, std.math.maxInt(usize), 1, 0 }) |index| {
        try storage.setFocusedIndex(&pair.left.runtime, index);
        try storage.setFocusedIndex(&pair.right.runtime, index);
        try pair.same();
        for ([_]bool{ false, false, true, true }) |active| {
            try storage.setAppActive(&pair.left.runtime, active);
            try storage.setAppActive(&pair.right.runtime, active);
            try pair.same();
            for (pair.right.runtime.views[0..pair.right.runtime.view_count]) |*v| try std.testing.expectEqual(active and index < 2 and pair.right.runtime.windows[index].info.id == v.window_id, v.keyboard_active);
        }
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.views[0].window_id = std.math.maxInt(u64);
    try storage.setAppActive(&pair.left.runtime, true);
    try storage.setAppActive(&pair.right.runtime, true);
    try pair.same();
    try std.testing.expect(!pair.right.runtime.views[0].keyboard_active);
}
test "compiled window lifecycle preserves host state frames flags and persistent label ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]bool{ false, true }) |authored| for (0..8) |bits| {
        for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.windows[1].main_frame_set = authored;
        const info = sdk.platform.WindowInfo{ .id = 9007199254740993, .label = "host-label", .title = "host-title", .frame = .init(-0.0, -91, 800.25, -0.0), .scale_factor = 1.25, .open = bits & 1 != 0, .focused = bits & 2 != 0, .hidden = bits & 4 != 0 };
        try storage.applyNativeInfo(&pair.left.runtime, 1, info);
        try storage.applyNativeInfo(&pair.right.runtime, 1, info);
        try pair.same();
        const state = sdk.platform.WindowState{ .id = info.id, .label = info.label, .title = info.title, .frame = info.frame, .scale_factor = info.scale_factor, .open = info.open, .focused = info.focused, .hidden = info.hidden };
        try storage.updateWindowState(&pair.left.runtime, state);
        try storage.updateWindowState(&pair.right.runtime, state);
        try pair.same();
        try exact(storage.runtimeWindowStateForPersistence(&pair.left.runtime, state), storage.runtimeWindowStateForPersistence(&pair.right.runtime, state));
        try std.testing.expectEqualStrings("panel", pair.right.runtime.windows[1].info.label);
    };
    const state = sdk.platform.WindowState{ .id = 0xfedcba9876543210, .label = "adopted", .title = "Adopted", .frame = .init(5, 6, 320, 240), .focused = true };
    try storage.updateWindowState(&pair.left.runtime, state);
    try storage.updateWindowState(&pair.right.runtime, state);
    try pair.same();
}
test "compiled window lifecycle preserves opaque replay labels and successful capability restoration" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.invoke(1, 9007199254740993);
    try pair.invoke(2, 9007199254740993);
    for ([_][]const u8{ "absent", "panel", "main", "a-label-that-is-longer-than-the-maximum-window-label-capacity-and-cannot-match" }) |label| {
        pair.left.runtime.restoreWindowCapabilityResult(label, false);
        pair.right.runtime.restoreWindowCapabilityResult(label, false);
        try pair.same();
    }
    pair.left.runtime.restoreWindowCapabilityResult("panel", true);
    pair.right.runtime.restoreWindowCapabilityResult("panel", true);
    try pair.same();
    pair.left.runtime.restoreWindowCapabilityResult("panel", false);
    pair.right.runtime.restoreWindowCapabilityResult("panel", false);
    try pair.same();
    for (modes) |count| try std.testing.expect(count > 0);
}
