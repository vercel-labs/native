const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const clock_mod = @import("clock.zig");
const platform_mod = @import("../platform/root.zig");

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
const max_recorded_output_bytes = 128;

const StreamModel = struct {
    line_storage: [max_recorded_lines][max_recorded_line_bytes]u8 = undefined,
    line_lens: [max_recorded_lines]usize = [_]usize{0} ** max_recorded_lines,
    line_count: usize = 0,
    truncated_count: usize = 0,
    // Full-length proof for lines beyond the recording prefix (raised
    // per-spawn line bounds deliver lines the 96-byte storage cannot).
    last_line_len: usize = 0,
    last_line_hash: u64 = 0,
    dropped_before_total: u32 = 0,
    exit_count: usize = 0,
    exit_code: i32 = 0,
    exit_reason: ?effects_mod.EffectExitReason = null,
    exit_dropped_lines: u32 = 0,
    // Collect-mode exit payloads: lengths and hashes for big outputs,
    // bounded prefixes for exact-content assertions on small ones (the
    // slices are drain scratch, so the model copies what it keeps).
    output_len: usize = 0,
    output_hash: u64 = 0,
    output_truncated: bool = false,
    output_prefix: [max_recorded_output_bytes]u8 = undefined,
    output_prefix_len: usize = 0,
    stderr_len: usize = 0,
    stderr_hash: u64 = 0,
    stderr_truncated: bool = false,
    stderr_prefix: [max_recorded_output_bytes]u8 = undefined,
    stderr_prefix_len: usize = 0,

    fn recordLine(model: *StreamModel, line: effects_mod.EffectLine) void {
        model.dropped_before_total += line.dropped_before;
        if (line.truncated) model.truncated_count += 1;
        model.last_line_len = line.line.len;
        model.last_line_hash = std.hash.Wyhash.hash(0, line.line);
        if (model.line_count >= max_recorded_lines) return;
        const len = @min(line.line.len, max_recorded_line_bytes);
        @memcpy(model.line_storage[model.line_count][0..len], line.line[0..len]);
        model.line_lens[model.line_count] = len;
        model.line_count += 1;
    }

    fn lineAt(model: *const StreamModel, index: usize) []const u8 {
        return model.line_storage[index][0..model.line_lens[index]];
    }

    fn recordExit(model: *StreamModel, exit: effects_mod.EffectExit) void {
        model.exit_count += 1;
        model.exit_code = exit.code;
        model.exit_reason = exit.reason;
        model.exit_dropped_lines = exit.dropped_lines;
        model.output_len = exit.output.len;
        model.output_hash = std.hash.Wyhash.hash(0, exit.output);
        model.output_truncated = exit.output_truncated;
        model.output_prefix_len = @min(exit.output.len, max_recorded_output_bytes);
        @memcpy(model.output_prefix[0..model.output_prefix_len], exit.output[0..model.output_prefix_len]);
        model.stderr_len = exit.stderr_tail.len;
        model.stderr_hash = std.hash.Wyhash.hash(0, exit.stderr_tail);
        model.stderr_truncated = exit.stderr_truncated;
        model.stderr_prefix_len = @min(exit.stderr_tail.len, max_recorded_output_bytes);
        @memcpy(model.stderr_prefix[0..model.stderr_prefix_len], exit.stderr_tail[0..model.stderr_prefix_len]);
    }

    fn outputPrefix(model: *const StreamModel) []const u8 {
        return model.output_prefix[0..model.output_prefix_len];
    }

    fn stderrPrefix(model: *const StreamModel) []const u8 {
        return model.stderr_prefix[0..model.stderr_prefix_len];
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
var test_max_line_bytes: usize = effects_mod.max_effect_line_bytes;

fn streamUpdate(model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void {
    switch (msg) {
        .start => fx.spawn(.{
            .key = stream_key,
            .argv = test_argv,
            .stdin = test_stdin,
            .max_line_bytes = test_max_line_bytes,
            .on_line = StreamEffects.lineMsg(.line),
            .on_exit = StreamEffects.exitMsg(.done),
        }),
        .stop => fx.cancel(stream_key),
        .line => |line| model.recordLine(line),
        .done => |exit| model.recordExit(exit),
    }
}

/// The collect-mode twin of `streamUpdate`: same Msg shape, spawns with
/// `.output = .collect`. `on_line` stays wired to prove collect spawns
/// never dispatch line Msgs.
fn collectUpdate(model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void {
    switch (msg) {
        .start => fx.spawn(.{
            .key = stream_key,
            .argv = test_argv,
            .stdin = test_stdin,
            .output = .collect,
            .on_line = StreamEffects.lineMsg(.line),
            .on_exit = StreamEffects.exitMsg(.done),
        }),
        .stop => fx.cancel(stream_key),
        .line => |line| model.recordLine(line),
        .done => |exit| model.recordExit(exit),
    }
}

fn streamView(ui: *StreamApp.Ui, model: *const StreamModel) StreamApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} lines", .{model.line_count})),
        ui.button(.{ .on_press = .start }, "Start"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

fn streamOptions(update_fx: *const fn (model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void) StreamApp.Options {
    return .{
        .name = "effects-stream",
        .scene = stream_scene,
        .canvas_label = canvas_label,
        .update_fx = update_fx,
        .view = streamView,
    };
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *StreamApp,
    app: core.App,

    fn create() !Harness {
        return createWith(streamUpdate);
    }

    fn createWith(update_fx: *const fn (model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(StreamApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = StreamApp.init(std.heap.page_allocator, .{}, streamOptions(update_fx));
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

test "a raised per-spawn line bound delivers long lines intact and truncates at the override" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{ "claude", "-p", "--output-format", "stream-json" };
    test_stdin = null;
    test_max_line_bytes = 16 * 1024;
    defer test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const request = h.app_state.effects.pendingSpawnAt(0).?;
    try std.testing.expectEqual(@as(usize, 16 * 1024), request.max_line_bytes);

    // A 6000-byte NDJSON-style event: 1.5x the default cap, intact under
    // the raised bound (this exact shape was destroyed by the old 4 KiB
    // line cap when a chat client streamed agent NDJSON events).
    const long_line = try std.testing.allocator.alloc(u8, 6000);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'x');
    long_line[0] = '{';
    long_line[5999] = '}';
    try fx.feedLine(stream_key, long_line);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.truncated_count);
    try std.testing.expectEqual(@as(usize, 6000), h.app_state.model.last_line_len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, long_line), h.app_state.model.last_line_hash);

    // Beyond even the raised bound: cut at the override, flagged.
    const huge_line = try std.testing.allocator.alloc(u8, 16 * 1024 + 500);
    defer std.testing.allocator.free(huge_line);
    @memset(huge_line, 'y');
    try fx.feedLine(stream_key, huge_line);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.truncated_count);
    try std.testing.expectEqual(@as(usize, 16 * 1024), h.app_state.model.last_line_len);

    try fx.feedExit(stream_key, 0);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
}

test "per-spawn line bounds above the ceiling (or zero) are rejected loudly" {
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    test_argv = &.{"firehose"};
    test_stdin = null;
    test_max_line_bytes = effects_mod.max_effect_line_bytes_ceiling + 1;
    defer test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.rejected, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.activeCount());

    test_max_line_bytes = 0;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.rejected, h.app_state.model.exit_reason.?);

    // The ceiling itself is accepted.
    test_max_line_bytes = effects_mod.max_effect_line_bytes_ceiling;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingSpawnCount());
    try h.app_state.effects.feedExit(stream_key, 0);
    try h.drainWakes();
}

test "fake executor collect mode accumulates output and delivers it on the exit" {
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{ "gh", "issue", "list", "--json", "number,title" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const request = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectOutputMode.collect, request.output);

    // Fed lines accumulate (with their newlines) instead of dispatching
    // on_line Msgs; stderr accumulates into the tail.
    try fx.feedLine(stream_key, "{\"number\":1,");
    try fx.feedLine(stream_key, "\"title\":\"giant single-line json\"}");
    try fx.feedStderr(stream_key, "warning: rate limited\n");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.exit_count);

    try fx.feedExit(stream_key, 2);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(@as(i32, 2), h.app_state.model.exit_code);
    try std.testing.expectEqualStrings(
        "{\"number\":1,\n\"title\":\"giant single-line json\"}\n",
        h.app_state.model.outputPrefix(),
    );
    try std.testing.expect(!h.app_state.model.output_truncated);
    try std.testing.expectEqualStrings("warning: rate limited\n", h.app_state.model.stderrPrefix());
    try std.testing.expect(!h.app_state.model.stderr_truncated);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);

    // The slot retires once the drain took the output buffer.
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
    try std.testing.expectError(error.EffectNotFound, fx.feedLine(stream_key, "late"));
}

test "fake executor collect mode truncates over-bound output and stderr loudly" {
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"firehose"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);

    // One giant "line" past the collect bound: kept up to the bound, the
    // overflow discarded and flagged — never silently.
    const big = try std.testing.allocator.alloc(u8, effects_mod.max_effect_collect_bytes + 16);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try fx.feedLine(stream_key, big);

    // Stderr past the tail capacity keeps the LAST bytes and flags it.
    var noisy: [effects_mod.max_effect_stderr_tail_bytes + 904]u8 = undefined;
    for (&noisy, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    try fx.feedStderr(stream_key, &noisy);

    try fx.feedExit(stream_key, 0);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.max_effect_collect_bytes, h.app_state.model.output_len);
    try std.testing.expect(h.app_state.model.output_truncated);
    try std.testing.expectEqual(effects_mod.max_effect_stderr_tail_bytes, h.app_state.model.stderr_len);
    try std.testing.expect(h.app_state.model.stderr_truncated);
    // The tail is the last max_effect_stderr_tail_bytes of the fed
    // pattern, oldest kept byte first.
    const expected_first: u8 = 'a' + @as(u8, @intCast(904 % 26));
    try std.testing.expectEqual(expected_first, h.app_state.model.stderrPrefix()[0]);
    const expected_hash = std.hash.Wyhash.hash(0, noisy[904..]);
    try std.testing.expectEqual(expected_hash, h.app_state.model.stderr_hash);
}

test "feedStderr on a lines-mode spawn reports EffectNotFound" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"stream"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectError(error.EffectNotFound, fx.feedStderr(stream_key, "nope"));
    try fx.feedExit(stream_key, 0);
    try h.drainWakes();
}

test "cancelling a fake collect spawn delivers a cancelled exit with empty payloads" {
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"doomed"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedLine(stream_key, "collected but never delivered");
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.cancelled, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.output_len);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.stderr_len);
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
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

// ------------------------------------------------------------- init_fx

const BootModel = struct {
    init_runs: u32 = 0,
    line_count: u32 = 0,
    exit_code: i32 = -999,
};

const BootMsg = union(enum) {
    line: effects_mod.EffectLine,
    done: effects_mod.EffectExit,
};

const BootApp = ui_app_model.UiApp(BootModel, BootMsg);
const BootEffects = BootApp.Effects;

const boot_key: u64 = 7;

fn bootInit(model: *BootModel, fx: *BootEffects) void {
    model.init_runs += 1;
    fx.spawn(.{
        .key = boot_key,
        .argv = &.{ "gh", "issue", "list", "--json", "number,title" },
        .on_line = BootEffects.lineMsg(.line),
        .on_exit = BootEffects.exitMsg(.done),
    });
}

fn bootUpdate(model: *BootModel, msg: BootMsg, fx: *BootEffects) void {
    _ = fx;
    switch (msg) {
        .line => model.line_count += 1,
        .done => |exit| model.exit_code = exit.code,
    }
}

fn bootView(ui: *BootApp.Ui, model: *const BootModel) BootApp.Ui.Node {
    return ui.text(.{}, ui.fmt("{d} lines", .{model.line_count}));
}

test "init_fx runs exactly once on install and the fake executor records the boot spawn" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(BootApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = BootApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-boot",
        .scene = stream_scene,
        .canvas_label = canvas_label,
        .update_fx = bootUpdate,
        .init_fx = bootInit,
        .view = bootView,
    });
    defer app_state.deinit();
    // Set before the installing frame: the boot spawn must be recorded,
    // not executed.
    app_state.effects.executor = .fake;
    const app = app_state.app();
    try harness.start(app);
    try std.testing.expectEqual(@as(u32, 0), app_state.model.init_runs);

    // The installing frame runs the init command before the first build.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.init_runs);
    try std.testing.expectEqual(@as(usize, 1), app_state.effects.pendingSpawnCount());
    const request = app_state.effects.pendingSpawnAt(0).?;
    try std.testing.expectEqual(boot_key, request.key);
    try std.testing.expectEqualStrings("gh", request.argv[0]);

    // Later frames and resizes never rerun it.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .label = canvas_label,
        .window_id = 1,
        .frame = geometry.RectF.init(0, 0, 500, 400),
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.model.init_runs);
    try std.testing.expectEqual(@as(usize, 1), app_state.effects.pendingSpawnCount());

    // Boot results land through the ordinary drain path.
    try app_state.effects.feedLine(boot_key, "issue 1");
    try app_state.effects.feedExit(boot_key, 0);
    try harness.runtime.dispatchPlatformEvent(app, .wake);
    try std.testing.expectEqual(@as(u32, 1), app_state.model.line_count);
    try std.testing.expectEqual(@as(i32, 0), app_state.model.exit_code);
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

test "teardown mid-stream kills the real child and joins its worker before returning" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // A child that would outlive the whole suite: only the teardown's
    // kill can end it. Waiting for the first line proves the worker is
    // mid-stream (child spawned, stdout pipe open) when deinit runs —
    // the exact posture of the e2e battery's timed-out cancel test.
    test_argv = &.{ "/bin/sh", "-c", "echo streaming; sleep 30" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawLine);

    const fx = &h.app_state.effects;
    const start_ns = clock_mod.monotonicNanoseconds();
    fx.deinit();
    const elapsed_ms = (clock_mod.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;

    // The kill ended the child — nothing waited out its 30s sleep
    // (generous bound: a loaded runner still reaps a SIGKILLed child
    // orders of magnitude faster than the sleep)...
    try std.testing.expect(elapsed_ms < 10_000);
    // ...and every worker was JOINED, not abandoned: no slot keeps a
    // thread handle and none is still running, so the owner may free
    // the channel's memory immediately. This pins the ownership hole
    // behind the e2e cascade: a timed-out harness used to free the
    // channel while a detached worker still held its slot pointer,
    // and the worker segfaulted the NEXT test inside
    // `slot.child_mutex.lock()`. The abandonment itself was a
    // thread-timing window; the joined-and-idle invariant asserted
    // here is its deterministic contract.
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }
    // Joined, not abandoned: the group-kill converged this worker well
    // inside the spawn deadline, so the abandon safety net stayed quiet.
    try std.testing.expectEqual(@as(u32, 0), fx.abandoned_spawn_workers);
}

// The escaped-descendant shape the spawn teardown deadline exists for:
// `set -m` enables job control in the child shell, which puts the
// background job in its OWN process group — outside the group
// `killPublishedChild` signals — while the job keeps the inherited
// stdout write end open. The shell exits at once; the escapee never
// sees the kill; EOF never arrives; the worker's blocking read would
// hold teardown forever. (This is `setsid` daemonization in portable
// clothes — macOS ships no setsid(1), but /bin/bash is everywhere the
// POSIX suites run.) Echoing `$!` hands the test the escapee's pid.
const escaped_holder_argv: []const []const u8 = &.{ "/bin/bash", "-c", "set -m; sleep 300 & echo $!" };

fn parseEscapedPid(h: *Harness) !std.posix.pid_t {
    return std.fmt.parseInt(std.posix.pid_t, h.app_state.model.lineAt(0), 10);
}

test "teardown interrupts a spawn worker held hostage by an escaped descendant and joins it with no leak" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    // Interruption stays on (the default): the group-kill provably
    // misses the escapee, so the best-effort cancel at the halfway
    // mark must interrupt the blocked pipe read and JOIN the worker —
    // the abandon safety net must never fire here.
    fx.spawn_join_deadline_ms = 2_000;

    test_argv = escaped_holder_argv;
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    // The echoed pid line proves the worker is mid-stream: child
    // spawned and published, stdout pipe open, read blocked.
    try waitForRealCompletion(&h, sawLine);
    const escaped_pid = try parseEscapedPid(&h);
    // The escapee outlives the interruption by design (nothing kills
    // it); reap it so a 300s sleeper never leaks into the suite.
    defer std.posix.kill(escaped_pid, .KILL) catch {};

    fx.deinit();

    // Joined, not leaked: the syscall interruption converged the worker
    // inside the deadline (deinit is deadline-bounded either way, so
    // reaching these asserts already proves it returned).
    try std.testing.expectEqual(@as(u32, 0), fx.abandoned_spawn_workers);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }
}

test "teardown abandons a spawn worker held hostage by an escaped descendant and leaks its context loudly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    // Tiny injected budget, interruption disabled: this test pins the
    // SAFETY NET (abandon-and-leak). The interruption path that
    // normally converges this shape first has its own test above.
    fx.spawn_join_deadline_ms = 300;
    fx.spawn_join_interrupt = false;

    test_argv = escaped_holder_argv;
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawLine);
    const escaped_pid = try parseEscapedPid(&h);

    // Grab the worker context before teardown abandons the slot: after
    // the abandon it is exactly the leaked, process-lived memory the
    // test walks to reach the direct child's recorded pid.
    var leaked: @TypeOf(fx.slots[0].spawn_ctx) = null;
    for (&fx.slots) |*slot| {
        if (slot.kind == .spawn and slot.state.load(.acquire) == .running) leaked = slot.spawn_ctx;
    }
    try std.testing.expect(leaked != null);

    const start_ns = clock_mod.monotonicNanoseconds();
    fx.deinit();
    const elapsed_ms = (clock_mod.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;

    // Teardown returned on the injected budget's order of magnitude
    // (generous bound for congested runners) instead of waiting out the
    // escapee's 300s sleep...
    try std.testing.expect(elapsed_ms < 10_000);
    // ...and abandoned exactly the stuck worker, loudly through the
    // counter seam, leaving no joinable thread and no running slot —
    // the owner may free the channel's memory right now.
    try std.testing.expectEqual(@as(u32, 1), fx.abandoned_spawn_workers);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }

    // The process stays healthy after the leak: a fresh channel runs a
    // spawn to completion and its own safety net stays quiet.
    var h2 = try Harness.create();
    defer h2.destroy();
    test_argv = &.{ "/bin/sh", "-c", "printf 'alive\\n'" };
    try h2.app_state.dispatch(&h2.harness.runtime, 1, .start);
    try waitForRealCompletion(&h2, sawExit);
    try std.testing.expectEqual(@as(u32, 0), h2.app_state.effects.abandoned_spawn_workers);

    // Wake the abandoned worker under the leak invariant: killing the
    // escaped holder closes the last stdout write end, the blocked read
    // reaches EOF, and the worker walks its leaked context — the child
    // handshake it locks to mark reaping, the pid recorded there — to
    // reap the (zombie) direct child, then finds itself abandoned and
    // exits without touching the torn-down channel. If the leak were
    // not honored, this walk is where a use-after-free would crash the
    // test. The direct child's disappearance is the deterministic proof
    // the worker really woke and completed the walk: only its
    // `child.wait` reaps that zombie.
    const direct_pid = leaked.?.child_id.?;
    try std.posix.kill(escaped_pid, .KILL);
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        if (std.posix.kill(direct_pid, @enumFromInt(0))) |_| {
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        } else |err| {
            try std.testing.expectEqual(error.ProcessNotFound, err);
            break;
        }
    }
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(direct_pid, @enumFromInt(0)));
}

test "an abandoned spawn worker survives the owner's allocator dying: its leak is process-lived only" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    // The channel — and every caller-side allocation it makes — lives
    // in an arena backed by the leak-checking testing allocator and is
    // deinitialized right after teardown: the exact owner-lifetime
    // posture the abandon leak must survive (mirroring the file
    // worker's arena test). The channel struct itself sits in the arena
    // too, so even the worker's `self` pointer dies with the owner.
    const Channel = effects_mod.Effects(StreamMsg);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_live = true;
    defer if (arena_live) arena.deinit();
    const fx = try arena.allocator().create(Channel);
    fx.* = Channel.init(arena.allocator());
    fx.spawn_join_deadline_ms = 300;
    fx.spawn_join_interrupt = false;

    // A short-lived escapee this time: it exits on its own (~2s), so
    // the abandoned worker's wake needs no outside kill — by then the
    // leaked context is the only handle on the effect left anywhere.
    fx.spawn(.{
        .key = 1,
        .argv = &.{ "/bin/bash", "-c", "set -m; sleep 2 & echo held" },
        .on_line = null,
        .on_exit = null,
    });
    // The queued "held" line proves the worker published its child and
    // reached the blocking read (publish happens-before the enqueue).
    var setup_ms: usize = 0;
    while (setup_ms < 20_000) : (setup_ms += 10) {
        if (fx.hasPending()) break;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(fx.hasPending());
    var leaked: @TypeOf(fx.slots[0].spawn_ctx) = null;
    for (&fx.slots) |*slot| {
        if (slot.kind == .spawn and slot.state.load(.acquire) == .running) leaked = slot.spawn_ctx;
    }
    try std.testing.expect(leaked != null);

    fx.deinit();
    try std.testing.expectEqual(@as(u32, 1), fx.abandoned_spawn_workers);
    const direct_pid = leaked.?.child_id.?;

    // Kill the owner's allocator: everything the channel ever got from
    // it — including the channel struct — is gone. The abandoned worker
    // must not notice: all it can still reach (its context, that
    // context's buffers, the executor io) is `process_allocator`
    // storage.
    arena.deinit();
    arena_live = false;

    // The escapee exits on its own; EOF wakes the abandoned worker,
    // which walks only its leaked context (marking reaping under the
    // context's child mutex, reaping the zombie direct child) and exits
    // without touching the dead arena — if any of its reachable memory
    // were caller-allocated, this walk is where the use-after-free
    // would crash the test. The zombie's disappearance proves the wake.
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        if (std.posix.kill(direct_pid, @enumFromInt(0))) |_| {
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        } else |err| {
            try std.testing.expectEqual(error.ProcessNotFound, err);
            break;
        }
    }
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(direct_pid, @enumFromInt(0)));

    // And the happy path still frees everything through the same seams:
    // a fresh channel backed DIRECTLY by the testing allocator runs a
    // real spawn to completion and tears down joined — the leak check
    // at test end guards the caller-side allocations, and
    // `joinWorker`/`deinit` return the context and executor io to
    // `process_allocator`.
    var healthy = Channel.init(std.testing.allocator);
    defer healthy.deinit();
    healthy.spawn(.{
        .key = 2,
        .argv = &.{ "/bin/sh", "-c", "printf 'alive\\n'" },
        .on_line = null,
        .on_exit = null,
    });
    var healthy_ms: usize = 0;
    while (healthy_ms < 20_000) : (healthy_ms += 10) {
        if (healthy.hasPending()) break;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(healthy.hasPending());
    healthy.deinit();
    try std.testing.expectEqual(@as(u32, 0), healthy.abandoned_spawn_workers);
}

test "a spawn teardown storm never leaks a worker into the next harness" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // The e2e cascade's shape, run deterministically and repeatedly: a
    // harness dies while its real child still streams (or while a
    // cancel is racing the spawn), then the next round builds a fresh
    // executor over recycled heap. Before the join fix an abandoned
    // worker could resume inside freed memory and crash a later round;
    // with it, destroy cannot return while any worker lives. Bounded
    // iterations keep the storm CI-cheap.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var h = try Harness.create();
        // Runs at each iteration's end — the storm's teardown — and on
        // an error return alike.
        defer h.destroy();
        test_argv = &.{ "/bin/sh", "-c", "echo tick; sleep 30" };
        test_stdin = null;
        try h.app_state.dispatch(&h.harness.runtime, 1, .start);
        // Odd rounds race a wire cancel against the spawn before the
        // teardown; even rounds tear down against the bare stream.
        if (round % 2 == 1) try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    }
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

test "real executor streams a single line beyond the default cap intact with a raised bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // One 6000-byte line — 1.5x the default 4 KiB cap that truncated
    // long stream-json events — followed by a short line, both intact
    // under a raised per-spawn bound. POSIX-portable across the macOS
    // and ubuntu runners.
    test_argv = &.{ "/bin/sh", "-c", "printf 'short\\n'; dd if=/dev/zero bs=6000 count=1 2>/dev/null | tr '\\0' 'x'; printf '\\n'" };
    test_stdin = null;
    test_max_line_bytes = 16 * 1024;
    defer test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.truncated_count);
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.exit_dropped_lines);
    try std.testing.expectEqualStrings("short", h.app_state.model.lineAt(0));
    // The long line (the last delivered) arrived byte-exact.
    const expected = try std.testing.allocator.alloc(u8, 6000);
    defer std.testing.allocator.free(expected);
    @memset(expected, 'x');
    try std.testing.expectEqual(@as(usize, 6000), h.app_state.model.last_line_len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, expected), h.app_state.model.last_line_hash);
}

test "real executor collect mode delivers a giant single-line stdout intact" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();

    // One 100 KB line with no newline until the very end — 25x the line
    // cap that used to force fold-wrappers around `gh --json`.
    // POSIX-portable across the macOS and ubuntu runners.
    test_argv = &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=1000 count=100 2>/dev/null | tr '\\0' 'x'; printf 'END\\n'" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 100_004), h.app_state.model.output_len);
    try std.testing.expect(!h.app_state.model.output_truncated);
    // Byte-exact delivery, verified by hash against the known content.
    const expected = try std.testing.allocator.alloc(u8, 100_004);
    defer std.testing.allocator.free(expected);
    @memset(expected[0..100_000], 'x');
    @memcpy(expected[100_000..], "END\n");
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, expected), h.app_state.model.output_hash);
    // No line framing: on_line never fired despite being wired.
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.exit_dropped_lines);
}

test "real executor collect mode delivers the stderr tail on failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();

    test_argv = &.{ "/bin/sh", "-c", "printf 'partial out\\n'; printf 'error: not logged in\\nrun gh auth login\\n' >&2; exit 4" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(i32, 4), h.app_state.model.exit_code);
    try std.testing.expectEqualStrings("partial out\n", h.app_state.model.outputPrefix());
    try std.testing.expectEqualStrings("error: not logged in\nrun gh auth login\n", h.app_state.model.stderrPrefix());
    try std.testing.expect(!h.app_state.model.stderr_truncated);
}

test "real executor collect mode truncates past the collect bound with the flag set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.createWith(collectUpdate);
    defer h.destroy();

    // 600 KB of stdout against the 512 KiB bound; a chatty stderr rides
    // along to prove the concurrent drain never deadlocks.
    test_argv = &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=1000 count=600 2>/dev/null | tr '\\0' 'y'; printf 'done\\n' >&2" };
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);

    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);
    try std.testing.expectEqual(effects_mod.max_effect_collect_bytes, h.app_state.model.output_len);
    try std.testing.expect(h.app_state.model.output_truncated);
    try std.testing.expectEqualStrings("done\n", h.app_state.model.stderrPrefix());
}

// ------------------------------------------------------------- fx timers

const TimerModel = struct {
    fired: u32 = 0,
    rejected: u32 = 0,
    last_fired_key: u64 = 0,
    last_rejected_key: u64 = 0,
};

const TimerMsg = union(enum) {
    start_repeating,
    start_one_shot,
    start_zero_interval,
    start_many,
    replace,
    stop,
    tick: effects_mod.EffectTimer,
};

const TimerApp = ui_app_model.UiApp(TimerModel, TimerMsg);
const TimerEffects = TimerApp.Effects;

const tick_key: u64 = 9001;

fn timerUpdate(model: *TimerModel, msg: TimerMsg, fx: *TimerEffects) void {
    switch (msg) {
        .start_repeating => fx.startTimer(.{
            .key = tick_key,
            .interval_ms = 250,
            .mode = .repeating,
            .on_fire = TimerEffects.timerMsg(.tick),
        }),
        .start_one_shot => fx.startTimer(.{
            .key = tick_key,
            .interval_ms = 100,
            .on_fire = TimerEffects.timerMsg(.tick),
        }),
        .start_zero_interval => fx.startTimer(.{
            .key = tick_key,
            .interval_ms = 0,
            .on_fire = TimerEffects.timerMsg(.tick),
        }),
        .start_many => {
            var key: u64 = 1;
            while (key <= effects_mod.max_effect_timers + 1) : (key += 1) {
                fx.startTimer(.{
                    .key = key,
                    .interval_ms = 100,
                    .mode = .repeating,
                    .on_fire = TimerEffects.timerMsg(.tick),
                });
            }
        },
        .replace => fx.startTimer(.{
            .key = tick_key,
            .interval_ms = 500,
            .mode = .one_shot,
            .on_fire = TimerEffects.timerMsg(.tick),
        }),
        .stop => fx.cancelTimer(tick_key),
        .tick => |timer| switch (timer.outcome) {
            .fired => {
                model.fired += 1;
                model.last_fired_key = timer.key;
            },
            .rejected => {
                model.rejected += 1;
                model.last_rejected_key = timer.key;
            },
        },
    }
}

fn timerBootInit(model: *TimerModel, fx: *TimerEffects) void {
    _ = model;
    fx.startTimer(.{
        .key = tick_key,
        .interval_ms = 250,
        .mode = .repeating,
        .on_fire = TimerEffects.timerMsg(.tick),
    });
}

fn timerView(ui: *TimerApp.Ui, model: *const TimerModel) TimerApp.Ui.Node {
    return ui.text(.{}, ui.fmt("{d} ticks", .{model.fired}));
}

const TimerHarness = struct {
    harness: *core.TestHarness(),
    app_state: *TimerApp,
    app: core.App,

    fn create(init_fx: ?*const fn (model: *TimerModel, fx: *TimerEffects) void) !TimerHarness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(TimerApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = TimerApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-timers",
            .scene = stream_scene,
            .canvas_label = canvas_label,
            .update_fx = timerUpdate,
            .init_fx = init_fx,
            .view = timerView,
        });
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

    fn destroy(self: *TimerHarness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn drainWakes(self: *TimerHarness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

test "fake executor records fx timers and fires them by hand" {
    var h = try TimerHarness.create(null);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Firing a key that was never started reports EffectNotFound.
    try std.testing.expectError(error.EffectNotFound, fx.fireTimer(tick_key));

    try h.app_state.dispatch(&h.harness.runtime, 1, .start_repeating);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    const request = fx.pendingTimerAt(0).?;
    try std.testing.expectEqual(tick_key, request.key);
    try std.testing.expectEqual(@as(u64, 250), request.interval_ms);
    try std.testing.expectEqual(effects_mod.TimerMode.repeating, request.mode);
    // Timers never consume the effect slots.
    try std.testing.expectEqual(@as(usize, 0), fx.activeCount());
    // The recording never touched the platform timer service.
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.timerStartCount());

    // A repeating timer fires as many times as the test says and stays
    // armed; each fire drains as one Msg through the wake path.
    try fx.fireTimer(tick_key);
    try h.drainWakes();
    try fx.fireTimer(tick_key);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 2), h.app_state.model.fired);
    try std.testing.expectEqual(tick_key, h.app_state.model.last_fired_key);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    try std.testing.expect(try retainedTextExists(&h.harness.runtime, "2 ticks"));

    // cancelTimer stops it; the retired key no longer fires.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    try std.testing.expectError(error.EffectNotFound, fx.fireTimer(tick_key));
    // Cancelling an unknown key is a no-op.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);

    // A one-shot retires after its single fire.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start_one_shot);
    try std.testing.expectEqual(effects_mod.TimerMode.one_shot, fx.pendingTimerAt(0).?.mode);
    try fx.fireTimer(tick_key);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 3), h.app_state.model.fired);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    try std.testing.expectError(error.EffectNotFound, fx.fireTimer(tick_key));
}

test "fx timer capacity and zero intervals reject loudly" {
    var h = try TimerHarness.create(null);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // One more timer than the table holds: exactly one rejection Msg.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start_many);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.rejected);
    try std.testing.expectEqual(@as(u64, effects_mod.max_effect_timers + 1), h.app_state.model.last_rejected_key);
    try std.testing.expectEqual(effects_mod.max_effect_timers, fx.pendingTimerCount());

    // A zero interval is rejected without claiming a slot (the table is
    // full here, but the rejection is the interval's, delivered first).
    try h.app_state.dispatch(&h.harness.runtime, 1, .start_zero_interval);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 2), h.app_state.model.rejected);
    try std.testing.expectEqual(tick_key, h.app_state.model.last_rejected_key);
    try std.testing.expectEqual(effects_mod.max_effect_timers, fx.pendingTimerCount());
}

test "starting an active fx timer key replaces it in place" {
    var h = try TimerHarness.create(null);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start_repeating);
    try h.app_state.dispatch(&h.harness.runtime, 1, .replace);
    try h.drainWakes();

    // No rejection, no second slot: the same key restarted.
    try std.testing.expectEqual(@as(u32, 0), h.app_state.model.rejected);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    const request = fx.pendingTimerAt(0).?;
    try std.testing.expectEqual(tick_key, request.key);
    try std.testing.expectEqual(@as(u64, 500), request.interval_ms);
    try std.testing.expectEqual(effects_mod.TimerMode.one_shot, request.mode);

    // The replacement's one-shot semantics hold: one fire, then retired.
    try fx.fireTimer(tick_key);
    try h.drainWakes();
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.fired);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
}

test "real-mode fx timers arm reserved platform timers and route fires back into update" {
    var h = try TimerHarness.create(timerBootInit);
    defer h.destroy();
    // Default `.real` executor against the null platform: init_fx armed
    // the boot timer on the installing frame, through the bound services.
    try std.testing.expectEqual(@as(usize, 1), h.harness.null_platform.timerStartCount());
    const platform_id = effects_mod.effect_timer_platform_id_base;
    const armed = h.harness.null_platform.startedTimer(platform_id).?;
    try std.testing.expect(armed.active);
    try std.testing.expect(armed.repeats);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), armed.interval_ns);
    try std.testing.expect(platform_id >= platform_mod.reserved_timer_id_base);

    // A fired platform timer routes through UiApp.handleTimer back into
    // update — never through Options.on_timer.
    try h.harness.runtime.dispatchPlatformEvent(h.app, h.harness.null_platform.fireTimer(platform_id, 5_000_000).?);
    try std.testing.expectEqual(@as(u32, 1), h.app_state.model.fired);
    try std.testing.expectEqual(tick_key, h.app_state.model.last_fired_key);
    try std.testing.expect(try retainedTextExists(&h.harness.runtime, "1 ticks"));

    // fx.cancelTimer reaches the platform cancel arm and disarms it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expectEqual(@as(usize, 1), h.harness.null_platform.timerCancelCount());
    try std.testing.expect(!h.harness.null_platform.startedTimer(platform_id).?.active);
    try std.testing.expect(h.harness.null_platform.fireTimer(platform_id, 6_000_000) == null);
}

test "real executor reports unspawnable binaries as spawn_failed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    test_argv = &.{"/nonexistent/native-sdk-effects-test-binary"};
    test_stdin = null;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try waitForRealCompletion(&h, sawExit);
    try std.testing.expectEqual(effects_mod.EffectExitReason.spawn_failed, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.line_count);
}

test "a spawn exit still undelivered occupies its key against a respawn; delivery frees it" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"worker"};
    test_stdin = null;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());

    // The fed exit queues the terminal and parks the slot — posted but
    // undelivered. A respawn of the same key inside that window must
    // reject: under session replay the first spawn is still a parked
    // `.running` fake here (its journaled exit feeds at the recorded
    // delivery position), so a live accept would journal a Msg stream
    // replay rejects.
    try fx.feedExit(stream_key, 0);
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());

    // Delivery order: the staged rejection first (loop-side pending),
    // then the queued exit.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(i32, 0), h.app_state.model.exit_code);

    // The window ends at delivery: the same key spawns again.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
}

/// One-shot flag for the respawn-from-own-exit idiom test below.
var test_respawn_on_exit: bool = false;

/// `streamUpdate` plus the restart idiom: the exit handler answers its
/// own terminal by respawning the same key (one-shot).
fn respawnUpdate(model: *StreamModel, msg: StreamMsg, fx: *StreamEffects) void {
    if (msg == .done and test_respawn_on_exit) {
        test_respawn_on_exit = false;
        model.recordExit(msg.done);
        fx.spawn(.{
            .key = stream_key,
            .argv = test_argv,
            .on_line = StreamEffects.lineMsg(.line),
            .on_exit = StreamEffects.exitMsg(.done),
        });
        return;
    }
    streamUpdate(model, msg, fx);
}

test "an update that respawns the same key from its own exit parks instead of rejecting" {
    var h = try Harness.createWith(respawnUpdate);
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"worker"};
    test_stdin = null;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    test_respawn_on_exit = true;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedExit(stream_key, 0);

    // The drain clears the undelivered-exit marker AND retires the slot
    // BEFORE the terminal Msg reaches update, so the handler's respawn
    // of its own key is a fresh accepted spawn — the restart idiom must
    // not regress. (The retire is the loop-side half of the worker's
    // post-then-store epilogue; on this fed path the slot was already
    // `.draining`, so the drain's store is an idempotent re-store.)
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(effects_mod.EffectExitReason.exited, h.app_state.model.exit_reason.?);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());

    // The respawned occupancy is a full fresh effect, not a resurrected
    // slot: its own exit delivers and the cycle restarts cleanly.
    test_respawn_on_exit = true;
    try fx.feedExit(stream_key, 7);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.exit_count);
    try std.testing.expectEqual(@as(i32, 7), h.app_state.model.exit_code);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    test_respawn_on_exit = false;
}

/// Spawn slots carrying a set undelivered-exit marker.
fn markedExitSlotCount(fx: *StreamEffects) usize {
    var count: usize = 0;
    for (&fx.slots) |*slot| {
        if (slot.kind == .spawn and slot.exit_undelivered) count += 1;
    }
    return count;
}

test "consuming a fed lines exit clears the undelivered-exit marker" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_argv = &.{"worker"};
    test_stdin = null;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 0), markedExitSlotCount(fx));

    // Posted but undelivered: the marker holds the slot (and the key).
    try fx.feedExit(stream_key, 0);
    try std.testing.expectEqual(@as(usize, 1), markedExitSlotCount(fx));

    // Dequeueing the exit IS its delivery: the drain must clear the
    // marker when it consumes the exit, or `reclaimSlots` holds the
    // slot out of `.idle` forever.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.exit_count);
    try std.testing.expectEqual(@as(usize, 0), markedExitSlotCount(fx));
}

test "every delivered lines exit hands its slot back for reuse" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    test_argv = &.{"/nonexistent/native-sdk-effects-test-binary"};
    test_stdin = null;
    test_max_line_bytes = effects_mod.max_effect_line_bytes;
    // Each round runs the real worker epilogue end to end (an
    // unspawnable binary is still worker truth: the worker posts a
    // `.spawn_failed` exit through the same mark-then-post commit) and
    // must return its slot. More rounds than the pool has slots proves
    // delivery frees them: a marker the drain's consume ever missed
    // would strand its slot in `.draining`, exhaust the pool, and turn
    // a later round's reason into `.rejected`.
    const io = std.testing.io;
    var round: usize = 1;
    while (round <= effects_mod.max_effects + 1) : (round += 1) {
        try h.app_state.dispatch(&h.harness.runtime, 1, .start);
        var waited_ms: usize = 0;
        while (h.app_state.model.exit_count < round) : (waited_ms += 10) {
            if (waited_ms >= 20_000) return error.TestTimedOut;
            try h.drainWakes();
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        }
        try std.testing.expectEqual(round, h.app_state.model.exit_count);
        try std.testing.expectEqual(effects_mod.EffectExitReason.spawn_failed, h.app_state.model.exit_reason.?);
        try std.testing.expectEqual(@as(usize, 0), markedExitSlotCount(&h.app_state.effects));
    }
}
