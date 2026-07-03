const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");

const canvas_label = "stream-canvas";

const stream_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const stream_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Stream",
    .width = 400,
    .height = 300,
    .views = &stream_views,
}};
const stream_scene: app_manifest.ShellConfig = .{ .windows = &stream_windows };

const max_recorded_lines = 32;
const max_recorded_line_bytes = 96;

const StreamModel = struct {
    line_storage: [max_recorded_lines][max_recorded_line_bytes]u8 = undefined,
    line_lens: [max_recorded_lines]usize = [_]usize{0} ** max_recorded_lines,
    line_count: usize = 0,
    truncated_count: usize = 0,
    dropped_before_total: u32 = 0,
    exit_count: usize = 0,
    exit_code: i32 = 0,
    exit_reason: ?effects_mod.EffectExitReason = null,
    exit_dropped_lines: u32 = 0,

    fn recordLine(model: *StreamModel, line: effects_mod.EffectLine) void {
        model.dropped_before_total += line.dropped_before;
        if (line.truncated) model.truncated_count += 1;
        if (model.line_count >= max_recorded_lines) return;
        const len = @min(line.line.len, max_recorded_line_bytes);
        @memcpy(model.line_storage[model.line_count][0..len], line.line[0..len]);
        model.line_lens[model.line_count] = len;
        model.line_count += 1;
    }

    fn lineAt(model: *const StreamModel, index: usize) []const u8 {
        return model.line_storage[index][0..model.line_lens[index]];
    }
};

const StreamMsg = union(enum) {
    start,
    stop,
    line: effects_mod.EffectLine,
    done: effects_mod.EffectExit,
};

const StreamApp = ui_app_model.UiApp(StreamModel, StreamMsg);
const StreamEffects = StreamApp.Effects;

const stream_key: u64 = 42;

// Set by each test before dispatching `.start`; comptime-known argv sets
// keep the update function closure-free.
var test_argv: []const []const u8 = &.{};
var test_stdin: ?[]const u8 = null;

fn streamUpdate(model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void {
    switch (msg) {
        .start => fx.spawn(.{
            .key = stream_key,
            .argv = test_argv,
            .stdin = test_stdin,
            .on_line = StreamEffects.lineMsg(.line),
            .on_exit = StreamEffects.exitMsg(.done),
        }),
        .stop => fx.cancel(stream_key),
        .line => |line| model.recordLine(line),
        .done => |exit| {
            model.exit_count += 1;
            model.exit_code = exit.code;
            model.exit_reason = exit.reason;
            model.exit_dropped_lines = exit.dropped_lines;
        },
    }
}

fn streamView(ui: *StreamApp.Ui, model: *const StreamModel) StreamApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} lines", .{model.line_count})),
        ui.button(.{ .on_press = .start }, "Start"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

fn streamOptions() StreamApp.Options {
    return .{
        .name = "effects-stream",
        .scene = stream_scene,
        .canvas_label = canvas_label,
        .update_fx = streamUpdate,
        .view = streamView,
    };
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *StreamApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(StreamApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = StreamApp.init(std.heap.page_allocator, .{}, streamOptions());
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
        try std.testing.expect(app_state.installed);
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    /// Consume all pending wake requests and deliver a single `.wake`
    /// platform event for the batch (one drain empties the whole queue;
    /// batching also keeps the harness trace sink within capacity).
    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

fn retainedTextExists(runtime: *core.Runtime, text: []const u8) !bool {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, text)) return true;
    }
    return false;
}

test "two-arg update options still construct unchanged" {
    // Signature duality: the plain form compiles and initializes exactly
    // as before the effects channel existed.
    const PlainApp = ui_app_model.UiApp(StreamModel, StreamMsg);
    const plainUpdate = struct {
        fn update(model: *StreamModel, msg: StreamMsg) void {
            _ = model;
            _ = msg;
        }
    }.update;
    const app_state = try std.testing.allocator.create(PlainApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = PlainApp.init(std.testing.allocator, .{}, .{
        .name = "effects-plain",
        .scene = stream_scene,
        .canvas_label = canvas_label,
        .update = plainUpdate,
        .view = streamView,
    });
    defer app_state.deinit();
    try std.testing.expect(app_state.options.update_fx == null);
}

test "fake executor captures spawn requests and feeds lines and exits back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{ "gh", "issue", "list", "--json", "number,title" };
    test_stdin = "payload";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // The request was recorded, not executed.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const request = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqual(stream_key, request.key);
    try std.testing.expectEqual(@as(usize, 5), request.argv.len);
    try std.testing.expectEqualStrings("gh", request.argv[0]);
    try std.testing.expectEqualStrings("number,title", request.argv[4]);
    try std.testing.expectEqualStrings("payload", request.stdin);
    try std.testing.expectEqual(@as(usize, 1), fx.activeCount());

    // Synthetic lines drain through the wake path into update + rebuild.
    try fx.feedLine(stream_key, "alpha");
    try fx.feedLine(stream_key, "beta");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("alpha", h.app_state.model.lineAt(0));
    try std.testing.expectEqualStrings("beta", h.app_state.model.lineAt(1));
    try std.testing.expect(try retainedTextExists(&h.harness.runtime, "2 lines"));

    // The synthetic exit retires the effect and reports the code.
    try fx.feedExit(stream_key, 3);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(@as(i32, 3), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(stream_key, "late"));
}

test "cancel discards queued lines and reports exactly one cancelled exit" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{ "agent", "chat" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(stream_key, "streamed before cancel");

    // Cancel BEFORE draining: the queued line must never become a Msg.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.cancelled, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(effects_mod.effect_error_exit_code, h.app_state.model.exit_code);

    // The slot is free again and the key no longer feeds.
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(stream_key, "late"));

    // Cancelling an unknown key is a no-op.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
}

test "cancelled lines stay filtered after the slot is reused by a new spawn" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"first"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(stream_key, "from the cancelled spawn");
    // Cancel retires the slot while its line is still queued...
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    // ...and a new spawn with the same key reuses that slot before the
    // queue drains. The sticky cancelled generation must keep filtering.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(stream_key, "from the new spawn");
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("from the new spawn", h.app_state.model.lineAt(0));
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.cancelled, h.app_state.model.exit_reason.?);
}

test "a cancel that races the natural exit still reports cancelled and drops lines" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"racer"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(stream_key, "landed before the exit");
    try fx.feedExit(stream_key, 0);
    // The effect already finished (its exit is queued); the app cancels
    // before draining. The promise holds: no lines, one cancelled exit.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.cancelled, h.app_state.model.exit_reason.?);
}

test "queue overflow drops lines loudly and truncates over-long lines" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"firehose"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // Fill the queue, then push three more lines that must drop.
    var index: usize = 0;
    while (index < effects_mod.max_effect_queue_entries) : (index += 1) {
        try fx.feedLine(stream_key, "fits");
    }
    try fx.feedLine(stream_key, "dropped 1");
    try fx.feedLine(stream_key, "dropped 2");
    try fx.feedLine(stream_key, "dropped 3");

    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.dropped_before_total);

    // The next delivered line carries the drop count; nothing is silent.
    try fx.feedLine(stream_key, "after the storm");
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 3), h.app_state.model.dropped_before_total);

    // Over-long lines arrive truncated and flagged.
    const long_line = [_]u8{'x'} ** (effects_mod.max_effect_line_bytes + 100);
    try fx.feedLine(stream_key, &long_line);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.truncated_count);

    // The exit reports the lifetime drop total.
    try fx.feedExit(stream_key, 0);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 3), h.app_state.model.exit_dropped_lines);
}

const RejectModel = struct {
    rejected: u32 = 0,
    exited: u32 = 0,
};

const RejectMsg = union(enum) {
    spawn_many,
    spawn_dup,
    spawn_huge,
    done: effects_mod.EffectExit,
};

const RejectApp = ui_app_model.UiApp(RejectModel, RejectMsg);
const RejectEffects = RejectApp.Effects;

fn rejectUpdate(model: *RejectModel, msg: RejectMsg, fx: *RejectEffects) void {
    switch (msg) {
        .spawn_many => {
            var key: u64 = 1;
            while (key <= effects_mod.max_effects + 1) : (key += 1) {
                fx.spawn(.{
                    .key = key,
                    .argv = &.{"cmd"},
                    .on_exit = RejectEffects.exitMsg(.done),
                });
            }
        },
        .spawn_dup => {
            fx.spawn(.{ .key = 500, .argv = &.{"cmd"}, .on_exit = RejectEffects.exitMsg(.done) });
            fx.spawn(.{ .key = 500, .argv = &.{"cmd"}, .on_exit = RejectEffects.exitMsg(.done) });
        },
        .spawn_huge => {
            const huge = [_]u8{'a'} ** (effects_mod.max_effect_argv_bytes + 1);
            fx.spawn(.{ .key = 600, .argv = &.{&huge}, .on_exit = RejectEffects.exitMsg(.done) });
        },
        .done => |exit| switch (exit.reason) {
            .rejected => model.rejected += 1,
            else => model.exited += 1,
        },
    }
}

fn rejectView(ui: *RejectApp.Ui, model: *const RejectModel) RejectApp.Ui.Node {
    return ui.text(.{}, ui.fmt("{d} rejected", .{model.rejected}));
}

test "capacity limits reject loudly: slots, duplicate keys, oversized argv" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(RejectApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RejectApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-reject",
        .scene = stream_scene,
        .canvas_label = canvas_label,
        .update_fx = rejectUpdate,
        .view = rejectView,
    });
    defer app_state.deinit();
    app_state.effects.executor = .fake;
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

    // One more spawn than there are slots: exactly one rejection.
    try app_state.dispatch(&harness.runtime, 1, .spawn_many);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.rejected);
    try std.testing.expectEqual(@as(usize, effects_mod.max_effects), app_state.effects.activeCount());

    // Retire them all so the next cases start clean.
    var key: u64 = 1;
    while (key <= effects_mod.max_effects) : (key += 1) {
        try app_state.effects.feedExit(key, 0);
    }
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, effects_mod.max_effects), app_state.model.exited);

    // Duplicate active key: second spawn rejected.
    try app_state.dispatch(&harness.runtime, 1, .spawn_dup);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 2), app_state.model.rejected);
    try app_state.effects.feedExit(500, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);

    // Oversized argv: rejected without claiming a slot.
    try app_state.dispatch(&harness.runtime, 1, .spawn_huge);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 3), app_state.model.rejected);
    try std.testing.expectEqual(@as(usize, 0), app_state.effects.activeCount());
}

fn waitForRealCompletion(h: *Harness, condition: *const fn (model: *const StreamModel) bool) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        try h.drainWakes();
        if (condition(&h.app_state.model)) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

fn sawExit(model: *const StreamModel) bool {
    return model.exit_count > 0;
}

fn sawLine(model: *const StreamModel) bool {
    return model.line_count > 0;
}

test "real executor streams a process's stdout lines into the model" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // POSIX-portable across the macOS and ubuntu runners.
    test_argv = &.{ "/bin/sh", "-c", "printf 'alpha\\nbeta\\ngamma\\n'" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(usize, 3), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("alpha", h.app_state.model.lineAt(0));
    try std.testing.expectEqualStrings("beta", h.app_state.model.lineAt(1));
    try std.testing.expectEqualStrings("gamma", h.app_state.model.lineAt(2));
    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.exit_dropped_lines);
    // The rebuild that followed the drain retained the new view text.
    try std.testing.expect(try retainedTextExists(&h.harness.runtime, "3 lines"));
    // The worker nudged the platform through wake_fn at least once.
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real executor pipes stdin and reports nonzero exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    test_argv = &.{ "/bin/sh", "-c", "cat; exit 7" };
    test_stdin = "from stdin\n";
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.line_count);
    try std.testing.expectEqualStrings("from stdin", h.app_state.model.lineAt(0));
    try std.testing.expectEqual(@as(i32, 7), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
}

test "real executor cancels a long-running stream cleanly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // A stream that would run for minutes: prove cancel kills and reaps.
    test_argv = &.{ "/bin/sh", "-c", "i=0; while :; do echo tick $i; i=$((i+1)); sleep 0.05; done" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawLine);

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try waitForRealCompletion(&h, sawExit);
    try std.testing.expectEqual(effects_mod.EffectExitReason.cancelled, h.app_state.model.exit_reason.?);

    // After the cancelled exit, no further line Msgs arrive.
    const lines_after_cancel = h.app_state.model.line_count;
    const io = std.testing.io;
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try h.drainWakes();
    try std.testing.expectEqual(lines_after_cancel, h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());
}

test "real executor children inherit the parent environment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // Regression: `ensureIo` once built its `std.Io.Threaded` with the
    // default `.environ = .empty`, so every spawned child saw a blank
    // environment (no HOME, no PATH) — `gh` inside an app reported "not
    // logged in" despite the parent being authenticated. Assert the
    // child actually sees both. POSIX-portable across the macOS and
    // ubuntu runners; `${VAR:?}` makes a missing variable exit nonzero.
    test_argv = &.{ "/bin/sh", "-c", "printf 'HOME=%s\\nPATH=%s\\n' \"${HOME:?}\" \"${PATH:?}\"" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.line_count);
    // Non-empty values, not just present-but-blank.
    try std.testing.expect(h.app_state.model.lineAt(0).len > "HOME=".len);
    try std.testing.expect(std.mem.startsWith(u8, h.app_state.model.lineAt(0), "HOME="));
    try std.testing.expect(h.app_state.model.lineAt(1).len > "PATH=".len);
    try std.testing.expect(std.mem.startsWith(u8, h.app_state.model.lineAt(1), "PATH="));
}

test "real executor reports unspawnable binaries as spawn_failed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    test_argv = &.{"/nonexistent/zero-native-effects-test-binary"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);
    try std.testing.expectEqual(effects_mod.EffectExitReason.spawn_failed, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
}
