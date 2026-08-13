//! File-effect coverage: `fx.writeFile`/`fx.readFile` through the fake
//! executor (deterministic request/feed round trips, truncation,
//! cancel, rejection) and the real executor against
//! `std.testing.tmpDir` — bounded, key-based, one terminal Msg per
//! effect with explicit outcomes, exactly like spawn and fetch.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const clock_mod = @import("clock.zig");

const canvas_label = "file-canvas";

const file_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const file_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Files",
    .width = 400,
    .height = 300,
    .views = &file_views,
}};
const file_scene: app_manifest.ShellConfig = .{ .windows = &file_windows };

const max_recorded_bytes = 96;

const FileModel = struct {
    result_count: usize = 0,
    last_op: ?effects_mod.EffectFileOp = null,
    last_outcome: ?effects_mod.EffectFileOutcome = null,
    dropped_before_total: u32 = 0,
    // Payload proof: length + hash for big reads, a bounded prefix for
    // exact-content assertions on small ones (the slice is drain
    // scratch, so the model copies what it keeps).
    bytes_len: usize = 0,
    bytes_hash: u64 = 0,
    bytes_prefix: [max_recorded_bytes]u8 = undefined,
    bytes_prefix_len: usize = 0,

    fn record(model: *FileModel, result: effects_mod.EffectFileResult) void {
        model.result_count += 1;
        model.last_op = result.op;
        model.last_outcome = result.outcome;
        model.dropped_before_total += result.dropped_before;
        model.bytes_len = result.bytes.len;
        model.bytes_hash = std.hash.Wyhash.hash(0, result.bytes);
        model.bytes_prefix_len = @min(result.bytes.len, max_recorded_bytes);
        @memcpy(model.bytes_prefix[0..model.bytes_prefix_len], result.bytes[0..model.bytes_prefix_len]);
    }

    fn bytesPrefix(model: *const FileModel) []const u8 {
        return model.bytes_prefix[0..model.bytes_prefix_len];
    }
};

const FileMsg = union(enum) {
    save,
    load,
    stop,
    file_result: effects_mod.EffectFileResult,
};

const FileApp = ui_app_model.UiApp(FileModel, FileMsg);
const FileEffects = FileApp.Effects;

const file_key: u64 = 77;

// Set by each test before dispatching `.save`/`.load`.
var test_path: []const u8 = "";
var test_bytes: []const u8 = "";
/// The reload idiom (one-shot): when set, the update reacts to a file
/// terminal by immediately reading the same key again.
var test_reread_on_result: bool = false;

fn fileUpdate(model: *FileModel, msg: FileMsg, fx: *FileEffects) void {
    switch (msg) {
        .save => fx.writeFile(.{
            .key = file_key,
            .path = test_path,
            .bytes = test_bytes,
            .on_result = FileEffects.fileMsg(.file_result),
        }),
        .load => fx.readFile(.{
            .key = file_key,
            .path = test_path,
            .on_result = FileEffects.fileMsg(.file_result),
        }),
        .stop => fx.cancel(file_key),
        .file_result => |result| {
            model.record(result);
            if (test_reread_on_result) {
                test_reread_on_result = false;
                fx.readFile(.{
                    .key = file_key,
                    .path = test_path,
                    .on_result = FileEffects.fileMsg(.file_result),
                });
            }
        },
    }
}

fn fileView(ui: *FileApp.Ui, model: *const FileModel) FileApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results", .{model.result_count})),
        ui.button(.{ .on_press = .save }, "Save"),
        ui.button(.{ .on_press = .load }, "Load"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *FileApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(FileApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = FileApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-files",
            .scene = file_scene,
            .canvas_label = canvas_label,
            .update_fx = fileUpdate,
            .view = fileView,
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

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

// ------------------------------------------------------------ fake executor

test "fake executor records file requests and feeds results back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Write: the request is recorded whole, not executed.
    test_path = "sessions/vercel__ai-7417.json";
    test_bytes = "{\"repo\":\"vercel/ai\"}";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    const write_request = fx.pendingFileAt(0).?;
    try std.testing.expectEqual(file_key, write_request.key);
    try std.testing.expectEqual(effects_mod.EffectFileOp.write, write_request.op);
    try std.testing.expectEqualStrings("sessions/vercel__ai-7417.json", write_request.path);
    try std.testing.expectEqualStrings("{\"repo\":\"vercel/ai\"}", write_request.bytes);

    try fx.feedFileResult(file_key, .ok, "");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.bytes_len);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());

    // Read: the fed content arrives as the terminal Msg's bytes.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    const read_request = fx.pendingFileAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, read_request.op);
    try std.testing.expectEqualStrings("", read_request.bytes);
    try fx.feedFileResult(file_key, .ok, "{\"stage\":\"ready\"}");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqualStrings("{\"stage\":\"ready\"}", h.app_state.model.bytesPrefix());

    // Failure outcomes pass through as fed.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try fx.feedFileResult(file_key, .not_found, "");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.not_found, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.bytes_len);
}

test "fake reads over the file bound arrive cut with outcome truncated" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_file_bytes + 3);
    defer std.testing.allocator.free(oversized);
    for (oversized, 0..) |*byte, index| byte.* = @truncate(index);

    test_path = "sessions/huge.json";
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try fx.feedFileResult(file_key, .ok, oversized);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);

    try std.testing.expectEqual(effects_mod.EffectFileOutcome.truncated, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.max_effect_file_bytes, h.app_state.model.bytes_len);
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0, oversized[0..effects_mod.max_effect_file_bytes]),
        h.app_state.model.bytes_hash,
    );
}

test "cancelling a fake file effect delivers one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_path = "sessions/pending.json";
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.cancelled, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());

    // The key is terminal: feeding it now reports EffectNotFound.
    try std.testing.expectError(error.EffectNotFound, fx.feedFileResult(file_key, .ok, ""));
}

test "an update that rereads the same key from its own file result parks instead of rejecting" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_path = "sessions/state.json";
    test_bytes = "";
    test_reread_on_result = true;
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try fx.feedFileResult(file_key, .ok, "{\"stage\":\"one\"}");

    // The drain retires the slot BEFORE the terminal Msg reaches
    // update, so the handler's reread of its own key is a fresh
    // accepted file effect — the reload idiom must not regress.
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());

    // The reread occupancy is fully live: its own terminal delivers.
    try fx.feedFileResult(file_key, .ok, "{\"stage\":\"two\"}");
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqualStrings("{\"stage\":\"two\"}", h.app_state.model.bytesPrefix());
}

test "file requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Empty path.
    test_path = "";
    test_bytes = "x";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectFileOp.write, h.app_state.model.last_op.?);

    // Over-long path.
    const long_path = try std.testing.allocator.alloc(u8, effects_mod.max_effect_file_path_bytes + 1);
    defer std.testing.allocator.free(long_path);
    @memset(long_path, 'p');
    test_path = long_path;
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, h.app_state.model.last_outcome.?);

    // Over-bound write payload: rejected outright, never cut on disk.
    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'b');
    test_path = "sessions/too-big.json";
    test_bytes = oversized;
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 3), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());

    // Duplicate active key.
    test_bytes = "small";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 4), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, h.app_state.model.last_op.?);
    // The original write is still pending, untouched by the rejection.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
}

// ------------------------------------------------------------ real executor

fn waitForRealResult(h: *Harness, count: usize) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        try h.drainWakes();
        if (h.app_state.model.result_count >= count) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

/// Wait for the worker's terminal entry WITHOUT draining it, so a test
/// can act (e.g. cancel) between completion and drain deterministically.
fn waitForPendingResult(h: *Harness) !void {
    const io = std.testing.io;
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        if (h.app_state.effects.hasPending()) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

test "real executor writes a file (creating parent dirs) and reads it back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Harness.create();
    defer h.destroy();

    var path_buffer: [256]u8 = undefined;
    // Nested path relative to the process cwd: proves parent creation.
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/nested/dir/session.json", .{tmp.sub_path[0..]});
    test_bytes = "{\"repo\":\"vercel/ai\",\"number\":7417}";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try waitForRealResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectFileOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h.app_state.model.last_outcome.?);

    // The bytes are on disk, whole.
    const on_disk = try tmp.dir.readFileAlloc(io, "nested/dir/session.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(on_disk);
    try std.testing.expectEqualStrings("{\"repo\":\"vercel/ai\",\"number\":7417}", on_disk);

    // And the read effect round-trips them.
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try waitForRealResult(&h, 2);
    try std.testing.expectEqual(effects_mod.EffectFileOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqualStrings("{\"repo\":\"vercel/ai\",\"number\":7417}", h.app_state.model.bytesPrefix());

    // A rewrite replaces the file whole (no append, no stale tail).
    test_bytes = "{\"n\":2}";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try waitForRealResult(&h, 3);
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try waitForRealResult(&h, 4);
    try std.testing.expectEqualStrings("{\"n\":2}", h.app_state.model.bytesPrefix());

    // Happy-path teardown pin: quick local ops join promptly and the
    // abandon safety net never fires (no leak, no detached thread).
    const fx = &h.app_state.effects;
    fx.deinit();
    try std.testing.expectEqual(@as(u32, 0), fx.abandoned_file_workers);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }
}

test "real executor reports missing files as not_found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Harness.create();
    defer h.destroy();

    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/absent.json", .{tmp.sub_path[0..]});
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try waitForRealResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.not_found, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.bytes_len);
}

test "real executor cuts over-bound reads with outcome truncated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Harness.create();
    defer h.destroy();

    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_file_bytes + 1024);
    defer std.testing.allocator.free(oversized);
    for (oversized, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    try tmp.dir.writeFile(io, .{ .sub_path = "huge.bin", .data = oversized });

    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/huge.bin", .{tmp.sub_path[0..]});
    try h.app_state.dispatch(&h.harness.runtime, 1, .load);
    try waitForRealResult(&h, 1);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.truncated, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.max_effect_file_bytes, h.app_state.model.bytes_len);
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0, oversized[0..effects_mod.max_effect_file_bytes]),
        h.app_state.model.bytes_hash,
    );
}

test "append and stat are bounded one-shot file effects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/log/events.log", .{tmp.sub_path[0..]});
    fx.appendFile(.{ .key = 1, .path = path, .bytes = "one", .on_result = Fx.fileMsg(.result) });
    while (fx.takeMsg() == null) try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    fx.appendFile(.{ .key = 2, .path = path, .bytes = "-two", .on_result = Fx.fileMsg(.result) });
    while (fx.takeMsg() == null) try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    fx.statFile(.{ .key = 3, .path = path, .on_result = Fx.fileMsg(.result) });
    var stat_result: ?effects_mod.EffectFileResult = null;
    while (stat_result == null) {
        if (fx.takeMsg()) |msg| stat_result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(stat_result.?.exists);
    try std.testing.expectEqual(@as(u64, 7), stat_result.?.total);
    const bytes = try tmp.dir.readFileAlloc(io, "log/events.log", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("one-two", bytes);
}

test "streaming file round-trip has no total-size cliff and finalizes atomically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/export.bin", .{tmp.sub_path[0..]});
    const chunk = try std.testing.allocator.alloc(u8, effects_mod.effect_file_stream_chunk_bytes);
    defer std.testing.allocator.free(chunk);
    for (chunk, 0..) |*byte, index| byte.* = @truncate(index);

    fx.writeFileStream(.{ .key = 44, .path = path, .on_result = Fx.fileMsg(.result) });
    var write_result: ?effects_mod.EffectFileResult = null;
    while (write_result == null) {
        if (fx.takeMsg()) |msg| write_result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 0), write_result.?.total);
    for (0..5) |_| {
        fx.writeFileChunk(.{ .key = 44, .bytes = chunk, .on_result = Fx.fileMsg(.result) });
        write_result = null;
        while (write_result == null) {
            if (fx.takeMsg()) |msg| write_result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(@as(u64, 0), write_result.?.total);
    }
    fx.writeFileClose(.{ .key = 44, .on_result = Fx.fileMsg(.result) });
    write_result = null;
    while (write_result == null) {
        if (fx.takeMsg()) |msg| write_result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 0), write_result.?.total);

    fx.readFileStream(.{ .key = 45, .path = path, .on_result = Fx.fileMsg(.result) });
    var chunks: usize = 0;
    var total: u64 = 0;
    while (true) {
        const msg = fx.takeMsg() orelse {
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
            continue;
        };
        if (msg.result.event == .chunk) chunks += 1 else {
            try std.testing.expectEqual(effects_mod.EffectFileEvent.done, msg.result.event);
            total = msg.result.total;
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), chunks);
    try std.testing.expectEqual(@as(u64, chunk.len * 5), total);
}

test "a rejected write-stream chunk can retry without losing its atomic sink" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "export.bin", .data = "previous generation" });

    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fx = Fx.init(failing.allocator());
    defer fx.deinit();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/export.bin", .{tmp.sub_path[0..]});

    fx.writeFileStream(.{ .key = 55, .path = path, .on_result = Fx.fileMsg(.result) });
    var result: ?effects_mod.EffectFileResult = null;
    while (result == null) {
        if (fx.takeMsg()) |msg| result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, result.?.outcome);

    // Reject the engine-owned chunk copy after the atomic sink is open.
    failing.fail_index = failing.alloc_index;
    fx.writeFileChunk(.{ .key = 55, .bytes = "replacement", .on_result = Fx.fileMsg(.result) });
    result = null;
    while (result == null) {
        if (fx.takeMsg()) |msg| result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, result.?.outcome);

    const still_visible = try tmp.dir.readFileAlloc(io, "export.bin", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(still_visible);
    try std.testing.expectEqualStrings("previous generation", still_visible);

    failing.fail_index = std.math.maxInt(usize);
    fx.writeFileChunk(.{ .key = 55, .bytes = "replacement", .on_result = Fx.fileMsg(.result) });
    result = null;
    while (result == null) {
        if (fx.takeMsg()) |msg| result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, result.?.outcome);
    fx.writeFileClose(.{ .key = 55, .on_result = Fx.fileMsg(.result) });
    result = null;
    while (result == null) {
        if (fx.takeMsg()) |msg| result = msg.result else try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, result.?.outcome);

    const visible = try tmp.dir.readFileAlloc(io, "export.bin", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("replacement", visible);
}

test "an unclosed write stream never exposes a partial destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "export.bin", .data = "previous generation" });
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/export.bin", .{tmp.sub_path[0..]});

    var fx = Fx.init(std.testing.allocator);
    fx.writeFileStream(.{ .key = 54, .path = path, .on_result = Fx.fileMsg(.result) });
    while (fx.takeMsg() == null) try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    fx.writeFileChunk(.{ .key = 54, .bytes = "partial replacement", .on_result = Fx.fileMsg(.result) });
    while (fx.takeMsg() == null) try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    fx.deinit();

    const visible = try tmp.dir.readFileAlloc(io, "export.bin", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("previous generation", visible);
}

test "stream sinks reject duplicate and out-of-order operations loudly" {
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.writeFileStream(.{ .key = 9, .path = "out.bin", .on_result = Fx.fileMsg(.result) });
    fx.writeFileStream(.{ .key = 9, .path = "other.bin", .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, fx.takeMsg().?.result.outcome);
    try fx.acknowledgeFakeFileStreamOpen(9);
    try fx.feedFileResultDetailed(.{ .key = 9, .op = .write_stream_open, .outcome = .ok });
    _ = fx.takeMsg().?;
    fx.writeFileChunk(.{ .key = 9, .bytes = "one", .on_result = Fx.fileMsg(.result) });
    fx.writeFileChunk(.{ .key = 9, .bytes = "two", .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.out_of_order, fx.takeMsg().?.result.outcome);
}

test "loop-side stream protocol results are journaled as replay-regenerated" {
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    const Capture = struct {
        var records: [8]effects_mod.EffectResultRecord = undefined;
        var count: usize = 0;

        fn note(_: *anyopaque, record: effects_mod.EffectResultRecord) void {
            records[count] = record;
            count += 1;
        }
    };

    Capture.count = 0;
    var context: u8 = 0;
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindJournal(.{ .context = &context, .record_fn = Capture.note });

    fx.writeFileChunk(.{ .key = 40, .bytes = "orphan", .on_result = Fx.fileMsg(.result) });
    _ = fx.takeMsg().?;

    fx.writeFileStream(.{ .key = 41, .path = "sink.bin", .on_result = Fx.fileMsg(.result) });
    try fx.acknowledgeFakeFileStreamOpen(41);
    try fx.feedFileResultDetailed(.{ .key = 41, .op = .write_stream_open, .outcome = .ok });
    _ = fx.takeMsg().?;

    fx.writeFileChunk(.{ .key = 41, .bytes = "one", .on_result = Fx.fileMsg(.result) });
    fx.writeFileChunk(.{ .key = 41, .bytes = "two", .on_result = Fx.fileMsg(.result) });
    _ = fx.takeMsg().?;
    try fx.feedFileResultDetailed(.{ .key = 41, .op = .write_stream_chunk, .outcome = .ok, .total = 3 });
    _ = fx.takeMsg().?;

    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    fx.writeFileChunk(.{ .key = 41, .bytes = oversized, .on_result = Fx.fileMsg(.result) });
    _ = fx.takeMsg().?;

    fx.writeFileClose(.{ .key = 42, .on_result = Fx.fileMsg(.result) });
    _ = fx.takeMsg().?;

    try std.testing.expectEqual(@as(usize, 6), Capture.count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.sink_missing, Capture.records[0].file_outcome);
    try std.testing.expect(Capture.records[0].file_rejected_admission);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, Capture.records[1].file_outcome);
    try std.testing.expect(!Capture.records[1].file_rejected_admission);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.out_of_order, Capture.records[2].file_outcome);
    try std.testing.expect(Capture.records[2].file_rejected_admission);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, Capture.records[3].file_outcome);
    try std.testing.expect(!Capture.records[3].file_rejected_admission);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, Capture.records[4].file_outcome);
    try std.testing.expect(Capture.records[4].file_rejected_admission);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.sink_missing, Capture.records[5].file_outcome);
    try std.testing.expect(Capture.records[5].file_rejected_admission);
}

test "path-policy file rejections are journaled as executor truth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    const Capture = struct {
        var record: ?effects_mod.EffectResultRecord = null;

        fn note(_: *anyopaque, value: effects_mod.EffectResultRecord) void {
            record = value;
        }
    };

    Capture.record = null;
    var context: u8 = 0;
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindJournal(.{ .context = &context, .record_fn = Capture.note });
    fx.bindFileAccess(.{ .roots = &.{}, .permitted = false, .enforce = true });

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/denied.bin", .{tmp.sub_path[0..]});
    fx.readFile(.{ .key = 61, .path = path, .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, fx.takeMsg().?.result.outcome);
    try std.testing.expect(Capture.record != null);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, Capture.record.?.file_outcome);
    try std.testing.expect(!Capture.record.?.file_rejected_admission);
}

test "read streams replace and cancel silently while sinks cancel loudly" {
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.readFileStream(.{ .key = 20, .path = "first.bin", .on_result = Fx.fileMsg(.result) });
    fx.readFileStream(.{ .key = 20, .path = "replacement.bin", .on_result = Fx.fileMsg(.result) });
    try fx.feedFileResultDetailed(.{ .key = 20, .op = .read_stream, .event = .chunk, .outcome = .ok, .bytes = "replacement", .total = 11 });
    try std.testing.expectEqualStrings("replacement", fx.takeMsg().?.result.bytes);
    fx.cancel(20);
    try std.testing.expectEqual(@as(?TestMsg, null), fx.takeMsg());
    try std.testing.expectError(error.EffectNotFound, fx.feedFileResultDetailed(.{ .key = 20, .op = .read_stream, .event = .done, .outcome = .ok, .total = 11 }));

    fx.writeFileStream(.{ .key = 21, .path = "sink.bin", .on_result = Fx.fileMsg(.result) });
    fx.cancel(21);
    const cancelled = fx.takeMsg().?.result;
    try std.testing.expectEqual(effects_mod.EffectFileOp.write_stream_open, cancelled.op);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.cancelled, cancelled.outcome);
}

test "replay cancellation keeps a fake sink parked for its recorded terminal" {
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.armReplay();

    fx.writeFileStream(.{ .key = 22, .path = "sink.bin", .on_result = Fx.fileMsg(.result) });
    fx.cancel(22);
    try std.testing.expectEqual(@as(?TestMsg, null), fx.takeMsg());
    try fx.feedFileResultDetailed(.{ .key = 22, .op = .write_stream_open, .outcome = .cancelled });
    const cancelled = fx.takeMsg().?.result;
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.cancelled, cancelled.outcome);
}

test "disk capacity errors are closed and enum-named across whole and streaming writes" {
    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    fx.failNextFileOperationForTest(error.NoSpaceLeft);
    fx.writeFile(.{ .key = 31, .path = "whole.bin", .bytes = "x", .on_result = Fx.fileMsg(.result) });
    var result = fx.takeMsg().?.result;
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.disk_full, result.outcome);
    try std.testing.expectEqualStrings("disk_full", @tagName(result.outcome));

    fx.failNextFileOperationForTest(error.DiskQuota);
    fx.writeFileStream(.{ .key = 32, .path = "stream.bin", .on_result = Fx.fileMsg(.result) });
    result = fx.takeMsg().?.result;
    try std.testing.expectEqual(effects_mod.EffectFileOp.write_stream_open, result.op);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.disk_full, result.outcome);

    fx.writeFileStream(.{ .key = 33, .path = "stream-chunk.bin", .on_result = Fx.fileMsg(.result) });
    try fx.acknowledgeFakeFileStreamOpen(33);
    try fx.feedFileResultDetailed(.{ .key = 33, .op = .write_stream_open, .outcome = .ok });
    _ = fx.takeMsg().?;
    fx.failNextFileOperationForTest(error.NoSpaceLeft);
    fx.writeFileChunk(.{ .key = 33, .bytes = "chunk", .on_result = Fx.fileMsg(.result) });
    result = fx.takeMsg().?.result;
    try std.testing.expectEqual(effects_mod.EffectFileOp.write_stream_chunk, result.op);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.disk_full, result.outcome);
}

test "file access gating covers whole, append, stat, and stream verbs without consuming slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app-data");

    const TestMsg = union(enum) { result: effects_mod.EffectFileResult };
    const Fx = effects_mod.Effects(TestMsg);
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var root_buffer: [256]u8 = undefined;
    var inside_buffer: [256]u8 = undefined;
    var outside_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/app-data", .{tmp.sub_path[0..]});
    const inside = try std.fmt.bufPrint(&inside_buffer, "{s}/owned.bin", .{root});
    const outside = try std.fmt.bufPrint(&outside_buffer, ".zig-cache/tmp/{s}/outside.bin", .{tmp.sub_path[0..]});
    fx.bindFileAccess(.{ .roots = &.{root}, .permitted = false, .enforce = true });

    fx.writeFile(.{ .key = 1, .path = inside, .bytes = "ok", .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    fx.cancel(1);
    _ = fx.takeMsg().?;

    fx.readFile(.{ .key = 2, .path = outside, .on_result = Fx.fileMsg(.result) });
    fx.writeFile(.{ .key = 3, .path = outside, .bytes = "x", .on_result = Fx.fileMsg(.result) });
    fx.appendFile(.{ .key = 4, .path = outside, .bytes = "x", .on_result = Fx.fileMsg(.result) });
    fx.statFile(.{ .key = 5, .path = outside, .on_result = Fx.fileMsg(.result) });
    fx.readFileStream(.{ .key = 6, .path = outside, .on_result = Fx.fileMsg(.result) });
    fx.writeFileStream(.{ .key = 7, .path = outside, .on_result = Fx.fileMsg(.result) });
    const refused_ops = [_]effects_mod.EffectFileOp{ .read, .write, .append, .stat, .read_stream, .write_stream_open };
    for (refused_ops) |expected_op| {
        const refused = fx.takeMsg().?.result;
        try std.testing.expectEqual(expected_op, refused.op);
        try std.testing.expectEqual(effects_mod.EffectFileOutcome.rejected, refused.outcome);
        try std.testing.expectEqualStrings("rejected", @tagName(refused.outcome));
    }
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());

    var granted = Fx.init(std.testing.allocator);
    defer granted.deinit();
    granted.executor = .fake;
    granted.bindFileAccess(.{ .roots = &.{}, .permitted = true, .enforce = true });
    granted.statFile(.{ .key = 8, .path = outside, .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), granted.pendingFileCount());
    granted.readFile(.{ .key = 9, .path = inside, .on_result = Fx.fileMsg(.result) });
    granted.readFileStream(.{ .key = 10, .path = inside, .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(@as(usize, 2), granted.pendingFileCount());

    // Full matrix: both whole-file and stream families are admitted inside
    // app roots regardless of the grant, and outside only with the grant.
    var inside_ungranted = Fx.init(std.testing.allocator);
    defer inside_ungranted.deinit();
    inside_ungranted.executor = .fake;
    inside_ungranted.bindFileAccess(.{ .roots = &.{root}, .permitted = false, .enforce = true });
    inside_ungranted.readFile(.{ .key = 40, .path = inside, .on_result = Fx.fileMsg(.result) });
    inside_ungranted.readFileStream(.{ .key = 41, .path = inside, .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), inside_ungranted.pendingFileCount());
    try inside_ungranted.feedFileResultDetailed(.{ .key = 41, .op = .read_stream, .event = .done, .outcome = .ok });
    _ = inside_ungranted.takeMsg().?;

    granted.readFileStream(.{ .key = 42, .path = outside, .on_result = Fx.fileMsg(.result) });
    try granted.feedFileResultDetailed(.{ .key = 42, .op = .read_stream, .event = .done, .outcome = .ok });
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, granted.takeMsg().?.result.outcome);

    var warn_only = Fx.init(std.testing.allocator);
    defer warn_only.deinit();
    warn_only.executor = .fake;
    warn_only.bindFileAccess(.{ .roots = &.{root}, .permitted = false, .enforce = false });
    warn_only.statFile(.{ .key = 43, .path = outside, .on_result = Fx.fileMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), warn_only.pendingFileCount());
}

test "runtime binding defaults support one warn-only release before enforcement" {
    const binding_warn: effects_mod.FileAccessBinding = .{ .roots = &.{}, .permitted = false, .enforce = false };
    const binding_enforce: effects_mod.FileAccessBinding = .{ .roots = &.{}, .permitted = false, .enforce = true };
    try std.testing.expectEqual(
        @import("file_access.zig").Decision.warn,
        @import("file_access.zig").decide(std.testing.allocator, std.testing.io, binding_warn, ".zig-cache/outside-file"),
    );
    try std.testing.expectEqual(
        @import("file_access.zig").Decision.reject,
        @import("file_access.zig").decide(std.testing.allocator, std.testing.io, binding_enforce, ".zig-cache/outside-file"),
    );
}

// --------------------------------------------------- bounded teardown

/// Create a FIFO at `path` (POSIX-only; callers gate on the platform).
/// A file write against it blocks forever inside `open(O_WRONLY)`
/// while no reader exists — the uninterruptible-blocking-I/O posture
/// the teardown deadline exists for.
fn makeFifo(path: []const u8) !void {
    var command_buffer: [512]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "mkfifo '{s}'", .{path});
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", command },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

test "teardown abandons a file worker stuck on a reader-less FIFO and leaks its world loudly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fifo_path_buffer: [256]u8 = undefined;
    const fifo_path = try std.fmt.bufPrint(&fifo_path_buffer, ".zig-cache/tmp/{s}/stuck.fifo", .{tmp.sub_path[0..]});
    try makeFifo(fifo_path);

    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    // Tiny injected budget, interruption disabled: this test pins the
    // SAFETY NET (abandon-and-leak). The interruption path that
    // normally converges first has its own test below.
    fx.file_join_deadline_ms = 300;
    fx.file_join_interrupt = false;

    test_path = fifo_path;
    test_bytes = "never delivered";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    // Let the worker reach the blocking open. Not required for the
    // abandon to fire — with interruption off, any still-running
    // posture past the deadline is abandoned — but it exercises the
    // real blocked shape.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    const start_ns = clock_mod.monotonicNanoseconds();
    fx.deinit();
    const elapsed_ms = (clock_mod.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;

    // Teardown returned on the budget's order of magnitude (generous
    // bound for congested runners) instead of hanging behind the FIFO
    // forever...
    try std.testing.expect(elapsed_ms < 10_000);
    // ...and abandoned exactly the stuck worker, loudly through the
    // counter seam, leaving no joinable thread and no running slot —
    // the owner may free the channel's memory right now.
    try std.testing.expectEqual(@as(u32, 1), fx.abandoned_file_workers);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }

    // The process is healthy after the leak: a fresh channel runs a
    // real file round trip and its own safety net stays quiet.
    var h2 = try Harness.create();
    defer h2.destroy();
    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/healthy.json", .{tmp.sub_path[0..]});
    test_bytes = "{\"alive\":true}";
    try h2.app_state.dispatch(&h2.harness.runtime, 1, .save);
    try waitForRealResult(&h2, 1);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.ok, h2.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(u32, 0), h2.app_state.effects.abandoned_file_workers);

    // Wake the abandoned worker under the leak invariant: opening the
    // FIFO's read end completes its blocked open; it performs its
    // write against its (leaked, still-valid) context and buffer,
    // closes the FIFO, finds itself abandoned, and exits without
    // touching the torn-down channel — if the leak were not honored,
    // this is where a use-after-free would crash the test. Draining to
    // EOF keeps the read end open across the worker's write (a write
    // into a reader-less pipe raises SIGPIPE, and the io's no-op
    // handler is not installed between tests) and proves the worker
    // really woke: EOF only arrives once it opened and closed the
    // write end.
    var reader = try std.Io.Dir.cwd().openFile(io, fifo_path, .{});
    defer reader.close(io);
    var drain_buffer: [128]u8 = undefined;
    while (true) {
        const read_slices: [1][]u8 = .{&drain_buffer};
        const count = reader.readStreaming(io, &read_slices) catch break;
        if (count == 0) break;
    }
}

test "an abandoned file worker survives the owner's allocator dying: its leak is process-lived only" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fifo_path_buffer: [256]u8 = undefined;
    const fifo_path = try std.fmt.bufPrint(&fifo_path_buffer, ".zig-cache/tmp/{s}/arena.fifo", .{tmp.sub_path[0..]});
    try makeFifo(fifo_path);

    // The channel — and every caller-side allocation it makes — lives
    // in an arena backed by the leak-checking testing allocator and is
    // deinitialized right after teardown: the exact owner-lifetime
    // posture the abandon leak must survive. The channel struct itself
    // sits in the arena too, so even the worker's `self` pointer dies
    // with the owner.
    const Channel = effects_mod.Effects(FileMsg);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_live = true;
    defer if (arena_live) arena.deinit();
    const fx = try arena.allocator().create(Channel);
    fx.* = Channel.init(arena.allocator());
    // Tiny injected budget, interruption disabled: pin the
    // abandon-and-leak safety net, exactly like the loud-leak test.
    fx.file_join_deadline_ms = 300;
    fx.file_join_interrupt = false;

    fx.writeFile(.{ .key = 1, .path = fifo_path, .bytes = "never delivered", .on_result = null });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    fx.deinit();
    try std.testing.expectEqual(@as(u32, 1), fx.abandoned_file_workers);

    // Kill the owner's allocator: everything the channel ever got from
    // it — including the channel struct — is gone. The abandoned
    // worker must not notice: all it can still reach (its context,
    // that context's buffer, the executor io) is `process_allocator`
    // storage.
    arena.deinit();
    arena_live = false;

    // Wake the abandoned worker under that invariant: opening the
    // FIFO's read end completes its blocked open; it writes through
    // its process-lived context and buffer, finds itself abandoned,
    // and exits without touching the dead arena — if any of its
    // reachable memory were caller-allocated, this walk is where the
    // use-after-free would crash the test. Draining to EOF keeps the
    // read end open across the worker's write and proves the worker
    // really woke.
    var reader = try std.Io.Dir.cwd().openFile(io, fifo_path, .{});
    defer reader.close(io);
    var drain_buffer: [128]u8 = undefined;
    while (true) {
        const read_slices: [1][]u8 = .{&drain_buffer};
        const count = reader.readStreaming(io, &read_slices) catch break;
        if (count == 0) break;
    }

    // And the happy path still frees everything through the same
    // seams: a fresh channel backed DIRECTLY by the testing allocator
    // runs a real write to completion and tears down joined — the
    // leak check at test end guards the caller-side allocations, and
    // `joinWorker`/`deinit` return the context, worker buffer, and
    // executor io to `process_allocator`.
    var healthy = Channel.init(std.testing.allocator);
    defer healthy.deinit();
    var path_buffer: [256]u8 = undefined;
    const healthy_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/healthy.json", .{tmp.sub_path[0..]});
    healthy.writeFile(.{ .key = 2, .path = healthy_path, .bytes = "{\"alive\":true}", .on_result = null });
    var waited_ms: usize = 0;
    while (waited_ms < 20_000) : (waited_ms += 10) {
        if (healthy.hasPending()) break;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(healthy.hasPending());
    healthy.deinit();
    try std.testing.expectEqual(@as(u32, 0), healthy.abandoned_file_workers);
}

test "teardown interrupts a file worker stuck on a reader-less FIFO and joins it with no leak" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fifo_path_buffer: [256]u8 = undefined;
    const fifo_path = try std.fmt.bufPrint(&fifo_path_buffer, ".zig-cache/tmp/{s}/interrupted.fifo", .{tmp.sub_path[0..]});
    try makeFifo(fifo_path);

    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    // Interruption stays on (the default): the best-effort cancel at
    // the halfway mark must interrupt the blocked open and JOIN the
    // worker — the abandon safety net must never fire here.
    fx.file_join_deadline_ms = 2_000;

    test_path = fifo_path;
    test_bytes = "never delivered";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    fx.deinit();

    // Joined, not leaked: the syscall interruption converged the
    // worker inside the deadline (deinit is deadline-bounded either
    // way, so reaching these asserts already proves it returned).
    try std.testing.expectEqual(@as(u32, 0), fx.abandoned_file_workers);
    for (&fx.slots) |*slot| {
        try std.testing.expect(slot.worker_thread == null);
        try std.testing.expect(slot.state.load(.acquire) != .running);
    }
}

test "a cancel racing a finished file effect still reports one cancelled terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Harness.create();
    defer h.destroy();

    var path_buffer: [256]u8 = undefined;
    test_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/racy.json", .{tmp.sub_path[0..]});
    test_bytes = "{\"cancelled\":true}";
    try h.app_state.dispatch(&h.harness.runtime, 1, .save);
    // Let the worker finish and queue its terminal, then cancel BEFORE
    // the drain runs: the drain must rewrite the terminal to cancelled.
    try waitForPendingResult(&h);
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try waitForRealResult(&h, 1);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectFileOutcome.cancelled, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.bytes_len);
}
