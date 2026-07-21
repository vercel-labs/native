const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;

const PostResult = native_sdk.ChannelHandle.PostResult;

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

fn captureSource(handle: native_sdk.ChannelHandle) std.Thread.SpawnError!void {
    captured_handle = handle;
}

/// The failing source: `std.Thread.spawn` cannot be made to fail
/// deterministically, so the startup sequence's failure branch is
/// exercised through the same injected-source seam the other tests
/// use — the exact error a real spawn reports under thread exhaustion.
fn failingSource(handle: native_sdk.ChannelHandle) std.Thread.SpawnError!void {
    _ = handle;
    return error.ThreadQuotaExceeded;
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

    try testing.expectEqual(PostResult.accepted, handle.post("sample 1: uptime 0.5s"));
    try testing.expectEqual(PostResult.accepted, handle.post("sample 2: uptime 1.0s"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, 2), h.app_state.model.total_samples);
    try testing.expectEqualStrings("sample 2: uptime 1.0s", h.app_state.model.lineAt(1));
}

test "stop closes the channel: the terminal lands and later posts answer closed" {
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const handle = captured_handle orelse return error.TestExpectedHandle;
    try testing.expectEqual(PostResult.accepted, handle.post("sample 1"));
    try h.drainWakes();

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    // The worker's wind-down signal: post answers `.closed` the moment
    // the close runs, before the terminal even delivers.
    try testing.expectEqual(PostResult.closed, handle.post("sample 2"));
    try h.drainWakes();
    try testing.expect(!h.app_state.model.monitoring);
    try testing.expectEqual(@as(u64, 1), h.app_state.model.total_samples);

    // The key is free again: a fresh start opens a fresh occupancy and
    // the OLD handle stays dead.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const fresh = captured_handle orelse return error.TestExpectedHandle;
    try testing.expectEqual(PostResult.closed, handle.post("stale"));
    try testing.expectEqual(PostResult.accepted, fresh.post("sample 1 again"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, 1), h.app_state.model.total_samples);
}

test "back-pressure skips samples but never stops the monitor" {
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const handle = captured_handle orelse return error.TestExpectedHandle;

    // Fill the staging FIFO without draining: the next post answers
    // `.dropped_full` — skip-this-sample, NOT the worker's stop signal.
    var buffer: [main.max_line_bytes]u8 = undefined;
    var index: usize = 0;
    while (index < native_sdk.max_effect_channel_pending) : (index += 1) {
        const line = try std.fmt.bufPrint(&buffer, "sample {d}", .{index});
        try testing.expectEqual(PostResult.accepted, handle.post(line));
    }
    try testing.expectEqual(PostResult.dropped_full, handle.post("one too many"));

    // The drain relieves the stage: still monitoring, and the delivered
    // events carried the honest drop count into the status line.
    try h.drainWakes();
    try testing.expect(h.app_state.model.monitoring);
    try testing.expectEqual(@as(u64, native_sdk.max_effect_channel_pending), h.app_state.model.total_samples);
    try testing.expectEqual(@as(u32, 1), h.app_state.model.dropped_total);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("monitoring: 32 samples, 1 dropped", h.app_state.model.statusText(arena_state.allocator()));

    // Sampling continues right through the stall.
    try testing.expectEqual(PostResult.accepted, handle.post("sample after stall"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, native_sdk.max_effect_channel_pending + 1), h.app_state.model.total_samples);
}

test "a failed source start never claims monitoring: the channel closes and the status says so" {
    var h = try Harness.create();
    defer h.destroy();
    main.start_source = failingSource;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    // Honest startup order: "monitoring" is claimed only AFTER the
    // source started — a failed spawn leaves it false, immediately.
    try testing.expect(!h.app_state.model.monitoring);
    try testing.expect(h.app_state.model.source_failed);

    // The failure closed the just-opened occupancy: the `.closed`
    // terminal delivers and the key is free again.
    try h.drainWakes();
    try testing.expect(!h.app_state.model.monitoring);

    // The UI renders the failure, never a silent "idle" (and never a
    // "monitoring" with no producer behind it).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("sampler failed to start", h.app_state.model.statusText(arena_state.allocator()));

    // A retry with a healthy source recovers completely: fresh open,
    // fresh handle, monitoring for real.
    main.start_source = captureSource;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try testing.expect(h.app_state.model.monitoring);
    try testing.expect(!h.app_state.model.source_failed);
    const handle = captured_handle orelse return error.TestExpectedHandle;
    try testing.expectEqual(PostResult.accepted, handle.post("sample 1: recovered"));
    try h.drainWakes();
    try testing.expectEqual(@as(u64, 1), h.app_state.model.total_samples);
}

test "under session replay the start path never launches the sampler: live() gates the spawn" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.armReplay();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    // The replayed open PARKS and its handle answers `live() == false`,
    // so the source seam is never invoked — no thread, no pre-post
    // work: replay stays fully offline. In a real replay the journaled
    // events are the whole stream.
    try testing.expect(captured_handle == null);
    // The dispatch itself behaves exactly as the recording's did — the
    // model claims monitoring off the same code path, because nothing
    // model-visible branches on `live()`.
    try testing.expect(h.app_state.model.monitoring);
    try testing.expect(!h.app_state.model.source_failed);
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
    try testing.expectEqual(PostResult.accepted, handle.post("still live"));
}
