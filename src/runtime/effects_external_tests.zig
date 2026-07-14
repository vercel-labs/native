const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_mod = @import("ui_app.zig");
const effects_mod = @import("effects.zig");

const canvas_label = "external-effects-canvas";
const external_key: u64 = 10;
const stream_key: u64 = 500;
const max_results = 64;
const kept_result_bytes = 16;

const external_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const external_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "External effects",
    .width = 400,
    .height = 300,
    .views = &external_views,
}};
const external_scene: app_manifest.ShellConfig = .{ .windows = &external_windows };

const ExternalModel = struct {
    result_count: usize = 0,
    request_ids: [max_results]u64 = [_]u64{0} ** max_results,
    keys: [max_results]u64 = [_]u64{0} ** max_results,
    kinds: [max_results]u32 = [_]u32{0} ** max_results,
    outcomes: [max_results]effects_mod.EffectExternalOutcome = [_]effects_mod.EffectExternalOutcome{.ok} ** max_results,
    byte_lens: [max_results]usize = [_]usize{0} ** max_results,
    bytes: [max_results][kept_result_bytes]u8 = undefined,
    bytes_lens: [max_results]usize = [_]usize{0} ** max_results,
    update_thread: std.Thread.Id = 0,

    fn record(self: *ExternalModel, result: effects_mod.EffectExternalResult) void {
        if (self.result_count >= max_results) return;
        const index = self.result_count;
        self.request_ids[index] = result.request_id;
        self.keys[index] = result.key;
        self.kinds[index] = result.kind;
        self.outcomes[index] = result.outcome;
        self.byte_lens[index] = result.bytes.len;
        const len = @min(result.bytes.len, kept_result_bytes);
        @memcpy(self.bytes[index][0..len], result.bytes[0..len]);
        self.bytes_lens[index] = len;
        self.result_count += 1;
        self.update_thread = std.Thread.getCurrentId();
    }

    fn resultBytes(self: *const ExternalModel, index: usize) []const u8 {
        return self.bytes[index][0..self.bytes_lens[index]];
    }
};

const ExternalMsg = union(enum) {
    issue_one,
    issue_pair,
    issue_with_stream,
    cancel_one,
    result: effects_mod.EffectExternalResult,
    line: effects_mod.EffectLine,
    exited: effects_mod.EffectExit,
};

const ExternalApp = ui_app_mod.UiApp(ExternalModel, ExternalMsg);
const ExternalEffects = ExternalApp.Effects;
const oversized_request = [_]u8{'x'} ** (effects_mod.max_effect_external_request_bytes + 1);

fn issueExternal(fx: *ExternalEffects, key: u64, kind: u32, payload: []const u8) u64 {
    return fx.external(.{
        .key = key,
        .kind = kind,
        .payload = payload,
        .on_result = ExternalEffects.externalMsg(.result),
    }) catch unreachable;
}

fn externalUpdate(model: *ExternalModel, msg: ExternalMsg, fx: *ExternalEffects) void {
    switch (msg) {
        .issue_one => _ = issueExternal(fx, external_key, 1, "alpha"),
        .issue_pair => {
            _ = issueExternal(fx, external_key, 1, "alpha");
            _ = issueExternal(fx, external_key + 10, 2, "beta");
        },
        .issue_with_stream => {
            fx.spawn(.{
                .key = stream_key,
                .argv = &.{"fake-stream"},
                .on_line = ExternalEffects.lineMsg(.line),
                .on_exit = ExternalEffects.exitMsg(.exited),
            });
            _ = issueExternal(fx, external_key, 4, "queue-pressure");
        },
        .cancel_one => fx.cancel(external_key),
        .result => |result| model.record(result),
        .line, .exited => {},
    }
}

fn externalView(ui: *ExternalApp.Ui, model: *const ExternalModel) ExternalApp.Ui.Node {
    return ui.text(.{}, ui.fmt("{d} external results", .{model.result_count}));
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *ExternalApp,
    app: core.App,

    fn create(executor: effects_mod.EffectExecutor, adapter: ?effects_mod.ExternalEffectAdapter) !Harness {
        return createWithAllocator(executor, adapter, std.heap.page_allocator);
    }

    fn createWithAllocator(executor: effects_mod.EffectExecutor, adapter: ?effects_mod.ExternalEffectAdapter, effects_allocator: std.mem.Allocator) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(ExternalApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = ExternalApp.init(effects_allocator, .{}, .{
            .name = "external-effects",
            .scene = external_scene,
            .canvas_label = canvas_label,
            .update_fx = externalUpdate,
            .view = externalView,
        });
        errdefer app_state.deinit();
        app_state.effects.executor = executor;
        if (adapter) |binding| app_state.effects.bindExternalAdapter(binding);
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn takeWakeCount(self: *Harness) usize {
        var count: usize = 0;
        while (self.harness.null_platform.takeWake()) |_| count += 1;
        return count;
    }

    fn drainWakes(self: *Harness) !void {
        if (self.takeWakeCount() > 0) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

const LiveAdapter = struct {
    ui_thread: std.Thread.Id,
    gate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    worker_off_ui: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completion_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    cancel_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shutdown_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    workers: [2]?std.Thread = .{ null, null },
    worker_count: usize = 0,

    fn adapter(self: *LiveAdapter) effects_mod.ExternalEffectAdapter {
        return .{
            .context = self,
            .submit_fn = submit,
            .cancel_fn = cancel,
            .shutdown_fn = shutdown,
        };
    }

    fn submit(context: *anyopaque, request: effects_mod.EffectExternalRequest, completion: effects_mod.ExternalEffectCompletion) anyerror!void {
        const self: *LiveAdapter = @ptrCast(@alignCast(context));
        if (self.worker_count >= self.workers.len) return error.AdapterFull;
        const kind = request.kind;
        self.workers[self.worker_count] = try std.Thread.spawn(.{}, worker, .{ self, kind, completion });
        self.worker_count += 1;
    }

    fn worker(self: *LiveAdapter, kind: u32, completion: effects_mod.ExternalEffectCompletion) void {
        if (std.Thread.getCurrentId() != self.ui_thread) self.worker_off_ui.store(true, .release);
        while (!self.gate.load(.acquire)) std.atomic.spinLoopHint();
        const bytes: []const u8 = if (kind == 1) "one" else "two";
        completion.complete(.success, bytes) catch {
            _ = self.completion_errors.fetchAdd(1, .monotonic);
        };
        _ = self.completed.fetchAdd(1, .release);
    }

    fn cancel(context: *anyopaque, request_id: u64) void {
        const self: *LiveAdapter = @ptrCast(@alignCast(context));
        _ = request_id;
        _ = self.cancel_count.fetchAdd(1, .monotonic);
    }

    fn shutdown(context: *anyopaque) void {
        const self: *LiveAdapter = @ptrCast(@alignCast(context));
        self.shutdown_called.store(true, .release);
        self.gate.store(true, .release);
        for (self.workers[0..self.worker_count]) |maybe_worker| {
            if (maybe_worker) |worker_thread| worker_thread.join();
        }
        self.worker_count = 0;
        self.workers = .{ null, null };
    }
};

const CapturingAdapter = struct {
    completion: ?effects_mod.ExternalEffectCompletion = null,
    request_id: u64 = 0,
    fail_submit: bool = false,
    cancel_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    cancelled_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    shutdown_called: bool = false,

    fn adapter(self: *CapturingAdapter) effects_mod.ExternalEffectAdapter {
        return .{
            .context = self,
            .submit_fn = submit,
            .cancel_fn = cancel,
            .shutdown_fn = shutdown,
        };
    }

    fn submit(context: *anyopaque, request: effects_mod.EffectExternalRequest, completion: effects_mod.ExternalEffectCompletion) anyerror!void {
        const self: *CapturingAdapter = @ptrCast(@alignCast(context));
        if (self.fail_submit) return error.AdapterRejected;
        self.request_id = request.request_id;
        self.completion = completion;
    }

    fn cancel(context: *anyopaque, request_id: u64) void {
        const self: *CapturingAdapter = @ptrCast(@alignCast(context));
        self.cancelled_request_id.store(request_id, .release);
        _ = self.cancel_count.fetchAdd(1, .monotonic);
    }

    fn shutdown(context: *anyopaque) void {
        const self: *CapturingAdapter = @ptrCast(@alignCast(context));
        self.shutdown_called = true;
    }
};

fn waitForCompleted(adapter: *LiveAdapter, count: usize) !void {
    var waited_ms: usize = 0;
    while (adapter.completed.load(.acquire) < count and waited_ms < 5_000) : (waited_ms += 1) {
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    if (adapter.completed.load(.acquire) != count) return error.TestTimedOut;
}

fn externalOptions(key: u64, kind: u32, payload: []const u8) ExternalEffects.ExternalOptions {
    return .{
        .key = key,
        .kind = kind,
        .payload = payload,
        .on_result = ExternalEffects.externalMsg(.result),
    };
}

test "external options require a result handler" {
    comptime {
        var found = false;
        for (@typeInfo(ExternalEffects.ExternalOptions).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "on_result")) {
                if (field.default_value_ptr != null) @compileError("ExternalOptions.on_result must not have a default");
                if (field.type != ExternalEffects.ExternalMsgFn) @compileError("ExternalOptions.on_result must be a required ExternalMsgFn");
                found = true;
            }
        }
        if (!found) @compileError("ExternalOptions.on_result is missing");
    }
}

test "local external issue failures are synchronous and allocate no request id" {
    var unavailable = ExternalEffects.init(std.heap.page_allocator);
    defer unavailable.deinit();
    try std.testing.expectError(error.ExternalEffectRequestTooLarge, unavailable.external(externalOptions(1, 1, &oversized_request)));

    var fake = ExternalEffects.init(std.heap.page_allocator);
    defer fake.deinit();
    fake.executor = .fake;
    const first_id = try fake.external(externalOptions(1, 1, "first"));
    try std.testing.expectEqual(@as(u64, 1), first_id);
    try std.testing.expectError(error.ExternalEffectDuplicateKey, fake.external(externalOptions(1, 2, "duplicate")));
    _ = try fake.external(externalOptions(2, 2, oversized_request[0..effects_mod.max_effect_external_request_bytes]));
    var index: usize = 2;
    while (index < effects_mod.max_effects) : (index += 1) {
        _ = try fake.external(externalOptions(1_000 + index, @intCast(index), "pending"));
    }
    try std.testing.expectError(error.ExternalEffectPendingFull, fake.external(externalOptions(9_999, 99, "full")));

    var no_space: [effects_mod.max_effect_external_result_bytes - 1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&no_space);
    var allocation_failure = ExternalEffects.init(fba.allocator());
    defer allocation_failure.deinit();
    allocation_failure.executor = .fake;
    try std.testing.expectError(error.ExternalEffectAllocationFailed, allocation_failure.external(externalOptions(1, 1, "x")));
}

test "adapter unavailable and submit refusal are accepted ordered SDK terminals" {
    var unavailable = ExternalEffects.init(std.heap.page_allocator);
    defer unavailable.deinit();
    const unavailable_id = try unavailable.external(externalOptions(1, 1, "x"));
    try std.testing.expectEqual(@as(u64, 1), unavailable_id);
    switch (unavailable.takeMsg().?) {
        .result => |result| {
            try std.testing.expectEqual(unavailable_id, result.request_id);
            try std.testing.expectEqual(effects_mod.EffectExternalOutcome.adapter_unavailable, result.outcome);
        },
        else => return error.ExpectedAdapterUnavailableResult,
    }

    var rejecting = CapturingAdapter{ .fail_submit = true };
    var submit_failure = ExternalEffects.init(std.heap.page_allocator);
    defer submit_failure.deinit();
    submit_failure.bindExternalAdapter(rejecting.adapter());
    const refused_id = try submit_failure.external(externalOptions(1, 1, "x"));
    try std.testing.expectEqual(@as(usize, 0), submit_failure.pendingExternalCount());
    switch (submit_failure.takeMsg().?) {
        .result => |result| {
            try std.testing.expectEqual(refused_id, result.request_id);
            try std.testing.expectEqual(effects_mod.EffectExternalOutcome.submit_failed, result.outcome);
        },
        else => return error.ExpectedSubmitFailedResult,
    }
    rejecting.fail_submit = false;
    try std.testing.expectEqual(@as(u64, 2), try submit_failure.external(externalOptions(1, 1, "accepted")));
}

test "live external adapter returns immediately, wakes once per pending batch, and updates only on the UI thread" {
    const ui_thread = std.Thread.getCurrentId();
    var live = LiveAdapter{ .ui_thread = ui_thread };
    var h = try Harness.create(.real, live.adapter());
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_pair);
    try std.testing.expectEqual(@as(usize, 0), live.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), h.app_state.effects.pendingExternalCount());
    try std.testing.expectEqual(@as(usize, 0), h.takeWakeCount());

    live.gate.store(true, .release);
    try waitForCompleted(&live, 2);
    try std.testing.expect(live.worker_off_ui.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), live.completion_errors.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), h.takeWakeCount());
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(ui_thread, h.app_state.model.update_thread);
}

test "fake external effects preserve issue and completion order" {
    var h = try Harness.create(.fake, null);
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_pair);
    const first = h.app_state.effects.pendingExternalAt(0).?;
    const second = h.app_state.effects.pendingExternalAt(1).?;
    try std.testing.expectEqual(external_key, first.key);
    try std.testing.expectEqual(@as(u32, 1), first.kind);
    try std.testing.expectEqualStrings("alpha", first.payload);
    try std.testing.expectEqual(external_key + 10, second.key);
    try std.testing.expectEqualStrings("beta", second.payload);

    try h.app_state.effects.feedExternalResult(second.request_id, .success, "second");
    try h.app_state.effects.feedExternalResult(first.request_id, .success, "first");
    try std.testing.expectError(error.ExternalEffectDuplicateResult, h.app_state.effects.feedExternalResult(second.request_id, .success, "duplicate"));
    try std.testing.expectEqual(@as(usize, 1), h.takeWakeCount());
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(external_key + 10, h.app_state.model.keys[0]);
    try std.testing.expectEqualStrings("second", h.app_state.model.resultBytes(0));
    try std.testing.expectEqual(external_key, h.app_state.model.keys[1]);
    try std.testing.expectEqualStrings("first", h.app_state.model.resultBytes(1));

    _ = try h.app_state.effects.external(externalOptions(99, 99, "reuse-slot"));
    try std.testing.expectError(error.ExternalEffectStaleResult, h.app_state.effects.feedExternalResult(first.request_id, .success, "reused"));
}

test "external request and result payloads are binary-safe" {
    const request_bytes = [_]u8{ 0x00, 0xff, 0x41 };
    const result_bytes = [_]u8{ 0xde, 0x00, 0xff };
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.executor = .fake;

    const request_id = try effects.external(externalOptions(1, std.math.maxInt(u32), &request_bytes));
    try std.testing.expectEqualSlices(u8, &request_bytes, effects.pendingExternalAt(0).?.payload);
    try effects.feedExternalResult(request_id, .success, &result_bytes);
    switch (effects.takeMsg().?) {
        .result => |result| {
            try std.testing.expectEqual(std.math.maxInt(u32), result.kind);
            try std.testing.expectEqualSlices(u8, &result_bytes, result.bytes);
        },
        else => return error.ExpectedExternalResult,
    }
}

test "an undrained external terminal keeps its key reserved across effect kinds" {
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.executor = .fake;

    const request_id = try effects.external(externalOptions(1, 1, "external"));
    try effects.feedExternalResult(request_id, .success, "done");
    effects.spawn(.{ .key = 1, .argv = &.{"collision"} });
    effects.hostRequest(.{ .key = 1, .name = "collision" });

    try std.testing.expectEqual(@as(usize, 0), effects.pendingSpawnCount());
    try std.testing.expectEqual(@as(usize, 0), effects.pendingHostCount());
}

test "external slot reuse does not revive a cancelled spawn line" {
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.executor = .fake;

    effects.spawn(.{
        .key = stream_key,
        .argv = &.{"cancelled-stream"},
        .on_line = ExternalEffects.lineMsg(.line),
        .on_exit = ExternalEffects.exitMsg(.exited),
    });
    try effects.feedLine(stream_key, "must-not-deliver");
    effects.cancel(stream_key);
    _ = try effects.external(externalOptions(external_key, 1, "reuses-slot-zero"));

    var line_count: usize = 0;
    while (effects.takeMsg()) |msg| switch (msg) {
        .line => line_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), line_count);
}

test "drain window counts a stale physical pop without taking newer work" {
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.executor = .fake;

    effects.spawn(.{
        .key = stream_key,
        .argv = &.{"cancelled-stream"},
        .on_line = ExternalEffects.lineMsg(.line),
        .on_exit = ExternalEffects.exitMsg(.exited),
    });
    try effects.feedLine(stream_key, "stale");
    effects.cancel(stream_key);
    const request_id = try effects.external(externalOptions(external_key, 1, "newer"));

    {
        var window: ExternalEffects.DrainWindow = undefined;
        effects.beginDrainWindow(&window);
        defer effects.finishDrainWindow(&window);
        try effects.feedExternalResult(request_id, .success, "next-window");

        var result_count: usize = 0;
        while (effects.takeMsgInDrainWindow(&window)) |msg| switch (msg) {
            .result => result_count += 1,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 0), result_count);
    }

    switch (effects.takeMsg().?) {
        .result => |result| try std.testing.expectEqualStrings("next-window", result.bytes),
        else => return error.ExpectedDeferredExternalResult,
    }
}

test "drain window pending prefix shrinks when overflow evicts an old entry" {
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.executor = .fake;

    for (0..effects_mod.max_effect_pending_exits) |index| {
        effects.spawn(.{
            .key = @intCast(index + 1),
            .argv = &.{},
            .on_exit = ExternalEffects.exitMsg(.exited),
        });
    }

    var window_count: usize = 0;
    {
        var window: ExternalEffects.DrainWindow = undefined;
        effects.beginDrainWindow(&window);
        defer effects.finishDrainWindow(&window);

        try std.testing.expect(effects.takeMsgInDrainWindow(&window) != null);
        window_count += 1;
        effects.spawn(.{ .key = 10_001, .argv = &.{}, .on_exit = ExternalEffects.exitMsg(.exited) });
        effects.spawn(.{ .key = 10_002, .argv = &.{}, .on_exit = ExternalEffects.exitMsg(.exited) });
        while (effects.takeMsgInDrainWindow(&window)) |_| window_count += 1;
    }
    try std.testing.expectEqual(effects_mod.max_effect_pending_exits - 1, window_count);

    var deferred_count: usize = 0;
    while (effects.takeMsg()) |_| deferred_count += 1;
    try std.testing.expectEqual(@as(usize, 2), deferred_count);
}

test "external cancellation merges with worker results in global insertion order" {
    var h = try Harness.create(.fake, null);
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_with_stream);
    const first = h.app_state.effects.pendingExternalAt(0).?;
    const second_id = try h.app_state.effects.external(externalOptions(external_key + 1, 5, "later"));
    try h.app_state.effects.feedLine(stream_key, "before-cancel");
    h.app_state.effects.cancel(first.key);
    try h.app_state.effects.feedExternalResult(second_id, .success, "after-cancel");

    switch (h.app_state.effects.takeMsg().?) {
        .line => {},
        else => return error.ExpectedLineBeforeCancellation,
    }
    switch (h.app_state.effects.takeMsg().?) {
        .result => |result| {
            try std.testing.expectEqual(first.request_id, result.request_id);
            try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, result.outcome);
        },
        else => return error.ExpectedCancellationInOrder,
    }
    switch (h.app_state.effects.takeMsg().?) {
        .result => |result| {
            try std.testing.expectEqual(second_id, result.request_id);
            try std.testing.expectEqual(effects_mod.EffectExternalOutcome.ok, result.outcome);
        },
        else => return error.ExpectedCompletionAfterCancellation,
    }
    try h.app_state.effects.feedExit(stream_key, 0);
    _ = h.app_state.effects.takeMsg();
}

test "queue-full completion is retryable, ordered, and never consumes the request" {
    var h = try Harness.create(.fake, null);
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_with_stream);
    const request = h.app_state.effects.pendingExternalAt(0).?;
    for (0..effects_mod.max_effect_queue_entries) |_| try h.app_state.effects.feedLine(stream_key, "queued");

    try std.testing.expectError(error.ExternalEffectQueueFull, h.app_state.effects.feedExternalResult(request.request_id, .success, "retry-me"));
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingExternalCount());
    try std.testing.expect(h.app_state.effects.takeMsg() != null);
    try h.app_state.effects.feedExternalResult(request.request_id, .success, "retried");
    try std.testing.expectError(error.ExternalEffectDuplicateResult, h.app_state.effects.feedExternalResult(request.request_id, .success, "duplicate"));

    _ = h.takeWakeCount();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqualStrings("retried", h.app_state.model.resultBytes(0));
    try h.app_state.effects.feedExit(stream_key, 0);
    try h.drainWakes();
}

test "cancellation remains exact while the shared worker queue is full" {
    var h = try Harness.create(.fake, null);
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_with_stream);
    const request = h.app_state.effects.pendingExternalAt(0).?;
    for (0..effects_mod.max_effect_queue_entries) |_| try h.app_state.effects.feedLine(stream_key, "queued");
    h.app_state.effects.cancel(request.key);
    try std.testing.expectError(error.ExternalEffectStaleResult, h.app_state.effects.feedExternalResult(request.request_id, .success, "late"));

    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, h.app_state.model.outcomes[0]);
    try h.app_state.effects.feedExit(stream_key, 0);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
}

test "result bounds are exact and oversized completion remains retryable" {
    var h = try Harness.create(.fake, null);
    defer h.destroy();

    const exact_id = try h.app_state.effects.external(externalOptions(1, 1, "exact"));
    const exact = try std.testing.allocator.alloc(u8, effects_mod.max_effect_external_result_bytes);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'a');
    try h.app_state.effects.feedExternalResult(exact_id, .success, exact);
    try std.testing.expect(h.app_state.effects.hasPending());
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.max_effect_external_result_bytes, h.app_state.model.byte_lens[0]);

    const retry_id = try h.app_state.effects.external(externalOptions(2, 2, "retry"));
    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_external_result_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.ExternalEffectResultTooLarge, h.app_state.effects.feedExternalResult(retry_id, .success, oversized));
    try h.app_state.effects.feedExternalResult(retry_id, .failure, "bounded failure");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.failed, h.app_state.model.outcomes[1]);
    try std.testing.expectEqualStrings("bounded failure", h.app_state.model.resultBytes(1));
}

test "live cancellation forwards once and late completion is stale" {
    var capturing = CapturingAdapter{};
    var h = try Harness.create(.real, capturing.adapter());
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_one);
    const completion = capturing.completion.?;
    const request_id = capturing.request_id;
    try h.app_state.dispatch(&h.harness.runtime, 1, .cancel_one);
    try std.testing.expectEqual(@as(usize, 1), capturing.cancel_count.load(.acquire));
    try std.testing.expectEqual(request_id, capturing.cancelled_request_id.load(.acquire));
    try std.testing.expectError(error.ExternalEffectStaleResult, completion.complete(.success, "late"));
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, h.app_state.model.outcomes[0]);
}

test "worker completion is stale after another effect kind reuses its slot" {
    var capturing = CapturingAdapter{};
    var h = try Harness.create(.real, capturing.adapter());
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_one);
    const completion = capturing.completion.?;
    try completion.complete(.success, "first");
    try h.drainWakes();

    // The external request used the first slot. Reclaim it, then make a
    // fake spawn claim that exact slot before the retained completion is
    // called from a worker.
    h.app_state.effects.executor = .fake;
    h.app_state.effects.spawn(.{ .key = stream_key, .argv = &.{"reused-slot"} });
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingSpawnCount());

    var gate = std.atomic.Value(bool).init(true);
    var status: CompletionStatus = .pending;
    const worker = try std.Thread.spawn(.{}, completeAfterGate, .{ completion, &gate, &status });
    worker.join();
    try std.testing.expectEqual(CompletionStatus.stale, status);
}

const CompletionStatus = enum(u8) { pending, accepted, duplicate, stale, other };

fn completeAfterGate(completion: effects_mod.ExternalEffectCompletion, gate: *std.atomic.Value(bool), status: *CompletionStatus) void {
    while (!gate.load(.acquire)) std.atomic.spinLoopHint();
    completion.complete(.success, "concurrent") catch |err| {
        status.* = switch (err) {
            error.ExternalEffectDuplicateResult => .duplicate,
            error.ExternalEffectStaleResult => .stale,
            else => .other,
        };
        return;
    };
    status.* = .accepted;
}

fn cancelAfterGate(effects: *ExternalEffects, gate: *std.atomic.Value(bool), key: u64) void {
    while (!gate.load(.acquire)) std.atomic.spinLoopHint();
    effects.cancel(key);
}

test "concurrent complete calls deterministically accept one and reject one duplicate" {
    var capturing = CapturingAdapter{};
    var h = try Harness.create(.real, capturing.adapter());
    defer h.destroy();
    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_one);

    var gate = std.atomic.Value(bool).init(false);
    var first_status: CompletionStatus = .pending;
    var second_status: CompletionStatus = .pending;
    const first = try std.Thread.spawn(.{}, completeAfterGate, .{ capturing.completion.?, &gate, &first_status });
    const second = try std.Thread.spawn(.{}, completeAfterGate, .{ capturing.completion.?, &gate, &second_status });
    gate.store(true, .release);
    first.join();
    second.join();

    const accepted = @intFromBool(first_status == .accepted) + @intFromBool(second_status == .accepted);
    const duplicate = @intFromBool(first_status == .duplicate) + @intFromBool(second_status == .duplicate);
    try std.testing.expectEqual(@as(u2, 1), accepted);
    try std.testing.expectEqual(@as(u2, 1), duplicate);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
}

test "concurrent complete and cancel serialize to one cancelled terminal" {
    var capturing = CapturingAdapter{};
    var h = try Harness.create(.real, capturing.adapter());
    defer h.destroy();
    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_one);
    const completion = capturing.completion.?;

    var gate = std.atomic.Value(bool).init(false);
    var completion_status: CompletionStatus = .pending;
    const complete_thread = try std.Thread.spawn(.{}, completeAfterGate, .{ completion, &gate, &completion_status });
    const cancel_thread = try std.Thread.spawn(.{}, cancelAfterGate, .{ &h.app_state.effects, &gate, external_key });
    gate.store(true, .release);
    complete_thread.join();
    cancel_thread.join();

    try std.testing.expect(completion_status == .accepted or completion_status == .stale);
    try std.testing.expectError(error.ExternalEffectStaleResult, completion.complete(.success, "after-cancel"));
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectExternalOutcome.cancelled, h.app_state.model.outcomes[0]);
}

test "worker completion never allocates through the non-thread-safe app allocator" {
    var storage: [effects_mod.max_effect_external_result_bytes + 64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var capturing = CapturingAdapter{};
    var effects = ExternalEffects.init(fba.allocator());
    defer effects.deinit();
    effects.bindExternalAdapter(capturing.adapter());
    _ = try effects.external(externalOptions(1, 1, "request"));
    const allocated_on_ui = fba.end_index;

    var gate = std.atomic.Value(bool).init(true);
    var status: CompletionStatus = .pending;
    const worker = try std.Thread.spawn(.{}, completeAfterGate, .{ capturing.completion.?, &gate, &status });
    worker.join();
    try std.testing.expectEqual(CompletionStatus.accepted, status);
    try std.testing.expectEqual(allocated_on_ui, fba.end_index);
    try std.testing.expect(effects.takeMsg() != null);
}

test "shutdown cancels live work and waits for adapter quiescence" {
    var live = LiveAdapter{ .ui_thread = std.Thread.getCurrentId() };
    var h = try Harness.create(.real, live.adapter());
    defer h.destroy();
    try h.app_state.dispatch(&h.harness.runtime, 1, .issue_one);

    h.app_state.effects.deinit();
    try std.testing.expect(live.shutdown_called.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), live.cancel_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), live.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), live.completion_errors.load(.acquire));
}

test "fake external work never submits or cancels through a bound live adapter" {
    var capturing = CapturingAdapter{};
    var effects = ExternalEffects.init(std.heap.page_allocator);
    effects.executor = .fake;
    effects.bindExternalAdapter(capturing.adapter());
    _ = try effects.external(externalOptions(1, 1, "fake"));
    try std.testing.expectEqual(@as(u64, 0), capturing.request_id);

    effects.deinit();
    try std.testing.expectEqual(@as(usize, 0), capturing.cancel_count.load(.acquire));
    try std.testing.expect(capturing.shutdown_called);
}

test "replay feed validates key, kind, and request payload fingerprint" {
    var effects = ExternalEffects.init(std.heap.page_allocator);
    defer effects.deinit();
    effects.armReplay();
    const request_id = try effects.external(externalOptions(41, 7, "identity"));
    var request_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("identity", &request_hash, .{});
    var wrong_hash = request_hash;
    wrong_hash[0] ^= 0xff;

    try std.testing.expectError(error.ExternalEffectReplayMismatch, effects_mod.feedExternalReplayRecord(ExternalMsg, &effects, .{
        .kind = .external,
        .key = 42,
        .payload = "result",
        .external_request_id = request_id,
        .external_kind = 7,
        .external_request_hash = request_hash,
    }));
    try std.testing.expectError(error.ExternalEffectReplayMismatch, effects_mod.feedExternalReplayRecord(ExternalMsg, &effects, .{
        .kind = .external,
        .key = 41,
        .payload = "result",
        .external_request_id = request_id,
        .external_kind = 8,
        .external_request_hash = request_hash,
    }));
    try std.testing.expectError(error.ExternalEffectReplayMismatch, effects_mod.feedExternalReplayRecord(ExternalMsg, &effects, .{
        .kind = .external,
        .key = 41,
        .payload = "result",
        .external_request_id = request_id,
        .external_kind = 7,
        .external_request_hash = wrong_hash,
    }));
    try effects_mod.feedExternalReplayRecord(ExternalMsg, &effects, .{
        .kind = .external,
        .key = 41,
        .payload = "result",
        .external_request_id = request_id,
        .external_kind = 7,
        .external_request_hash = request_hash,
    });
    try std.testing.expect(effects.takeMsg() != null);
}
