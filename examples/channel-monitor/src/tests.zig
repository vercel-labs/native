const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const MonitorApp = native_sdk.UiApp(Model, Msg);

const shell_views = [_]native_sdk.ShellView{
    .{ .label = "monitor-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Channel Monitor",
    .width = 560,
    .height = 420,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

fn monitorOptions() MonitorApp.Options {
    return .{
        .name = "channel-monitor",
        .scene = shell_scene,
        .canvas_label = "monitor-canvas",
        .update_fx = main.update,
        .view = main.view,
    };
}

/// The test source: no thread, no clock — it just captures the handle
/// `update` hands out, so each test posts deterministically itself.
var captured_handle: ?native_sdk.ChannelHandle = null;

fn captureSource(handle: native_sdk.ChannelHandle) void {
    captured_handle = handle;
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *MonitorApp,

    fn create() !Harness {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(560, 420) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try testing.allocator.create(MonitorApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = MonitorApp.init(std.heap.page_allocator, .{}, monitorOptions());
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = "monitor-canvas",
            .size = geometry.SizeF.init(560, 420),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        main.start_source = captureSource;
        captured_handle = null;
        return .{ .harness = harness, .app_state = app_state };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    /// Consume all pending wake requests and deliver a single `.wake`
    /// platform event for the batch.
    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .wake);
    }
};

test "start opens the channel and posted samples land in the list, no timers armed" {
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try testing.expect(h.app_state.model.monitoring);
    const handle = captured_handle orelse return error.TestExpectedHandle;
    // The no-polling proof: nothing ticks for this source — the posts
    // themselves wake the loop.
    try testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingTimerCount());

    try testing.expect(handle.post("sample 1: uptime 0.5s"));
    try testing.expect(handle.post("sample 2: uptime 1.0s"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, 2), h.app_state.model.total_samples);
    try testing.expectEqualStrings("sample 2: uptime 1.0s", h.app_state.model.lineAt(1));
}

test "stop closes the channel: the terminal lands and later posts answer false" {
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const handle = captured_handle orelse return error.TestExpectedHandle;
    try testing.expect(handle.post("sample 1"));
    try h.drainWakes();

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    // The worker's wind-down signal: post answers false the moment the
    // close runs, before the terminal even delivers.
    try testing.expect(!handle.post("sample 2"));
    try h.drainWakes();
    try testing.expect(!h.app_state.model.monitoring);
    try testing.expectEqual(@as(u64, 1), h.app_state.model.total_samples);

    // The key is free again: a fresh start opens a fresh occupancy and
    // the OLD handle stays dead.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const fresh = captured_handle orelse return error.TestExpectedHandle;
    try testing.expect(!handle.post("stale"));
    try testing.expect(fresh.post("sample 1 again"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, 1), h.app_state.model.total_samples);
}

test "a duplicate start while monitoring is a no-op, and a refused open reports rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const handle = captured_handle orelse return error.TestExpectedHandle;
    captured_handle = null;
    // The model guard makes a second Start inert — no second open, no
    // second source.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try testing.expect(captured_handle == null);

    // A genuinely refused open (the key already occupied under the
    // model guard's nose) delivers `.rejected` and the model says so.
    h.app_state.model.monitoring = false;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try testing.expect(h.app_state.model.rejected);
    try testing.expect(!h.app_state.model.monitoring);

    // The original occupancy is untouched throughout.
    try testing.expect(handle.post("still live"));
}
