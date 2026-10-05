const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("effects_probe_core");
const decoder = @import("effects_probe_decoder");
const reference = @import("effects_probe_reference.zig");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const Host = sdk.TsCoreHost(core);
const testing = std.testing;

fn compare(native: *const reference.Model, model: *const core.Model) !void {
    try testing.expectEqual(native.visible_count, model.lines.len);
    try testing.expectEqual(@as(i64, @intCast(native.total_lines >> 32)), model.total_lines.upper_word);
    try testing.expectEqual(@as(i64, @intCast(native.total_lines & 0xFFFFFFFF)), model.total_lines.lower_word);
    try testing.expectEqual(@as(i64, native.dropped_lines), model.dropped_lines);
    try testing.expectEqual(native.streaming, model.streaming);
    try testing.expectEqual(native.last_exit != null, model.last_exit != null);
    if (native.last_exit) |exit| {
        const actual = model.last_exit.?;
        try testing.expectEqualStrings(@tagName(exit.reason), @tagName(actual.reason));
        try testing.expectEqual(@as(f64, @floatFromInt(exit.code)), actual.code);
        try testing.expectEqual(@as(f64, @floatFromInt(exit.dropped_lines)), actual.droppedLines);
        try testing.expectEqualStrings(exit.output, actual.output);
        try testing.expectEqual(exit.output_truncated, actual.outputTruncated);
        try testing.expectEqualStrings(exit.stderr_tail, actual.stderrTail);
        try testing.expectEqual(exit.stderr_truncated, actual.stderrTruncated);
    }
    try testing.expectEqual(native.copied != null, model.copied != null);
    if (native.copied) |outcome| try testing.expectEqualStrings(@tagName(outcome), @tagName(model.copied.?));
    for (model.lines, 0..) |line, index| try testing.expectEqualStrings(native.lineAt(index), line.line);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(native.statusText(arena.allocator()), model.statusText(arena.allocator()));
}
fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = reference.ProbeUi.init(arena.allocator());
    const expected = try a.finalize(reference.view(&a, native));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const actual = try b.finalize(if (backend == 0) View.build(&b, model) else decoder.build(&b, model));
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |old, new| {
            try testing.expectEqual(old.id, new.id);
            const before = expected.msgForPointer(old.id, .up);
            const after = actual.msgForPointer(new.id, .up);
            try testing.expectEqual(before != null, after != null);
            if (before) |msg| try testing.expectEqualStrings(@tagName(msg), @tagName(after.?));
        }
        var left: [128]canvas.WidgetLayoutNode = undefined;
        var right: [128]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 560, 480), .init(0, 0, 720, 640), .init(0, 0, 400, 320) }) |frame| try parity.equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
    }
}
test "compiled probe retains complete line windows, loss, exit records, clipboard outcomes and views" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    native_fx.executor = .fake;
    var native = reference.Model{};
    Host.init(&fx);
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    reference.update(&native, .start, &native_fx);
    Host.dispatch(&fx, .start);
    const request = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(reference.stream_argv.len, request.argv.len);
    for (reference.stream_argv, request.argv) |old, new| try testing.expectEqualStrings(old, new);
    for (0..40) |index| {
        var bytes: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&bytes, "line {d}: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .{index});
        const drops: u32 = @intCast(index % 5);
        try native_fx.feedLineWithMetadata(1, line, index % 2 == 0, drops);
        while (native_fx.takeMsg()) |msg| reference.update(&native, msg, &native_fx);
        try fx.feedLineWithMetadata(request.key, line, index % 2 == 0, drops);
        Host.drain(&fx);
        @memset(&bytes, 0xA5);
        try compare(&native, Host.model());
        try viewParity(&native, Host.model());
    }
    inline for (std.meta.tags(sdk.EffectClipboardOutcome)) |outcome| {
        reference.update(&native, .copy_status, &native_fx);
        Host.dispatch(&fx, .copy_status);
        const old = native_fx.pendingClipboardAt(0).?;
        const new = fx.pendingClipboardAt(0).?;
        try testing.expectEqualStrings(old.text, new.text);
        try native_fx.feedClipboardResult(old.key, outcome, "ignored write payload");
        try fx.feedClipboardResult(new.key, outcome, "ignored write payload");
        while (native_fx.takeMsg()) |msg| reference.update(&native, msg, &native_fx);
        Host.drain(&fx);
        try compare(&native, Host.model());
        try viewParity(&native, Host.model());
    }
    try native_fx.feedExitWithMetadata(1, -9, .signaled, .{ .dropped_lines = 73, .output_truncated = true, .stderr_truncated = true });
    try fx.feedExitWithMetadata(request.key, -9, .signaled, .{ .dropped_lines = 73, .output_truncated = true, .stderr_truncated = true });
    while (native_fx.takeMsg()) |msg| reference.update(&native, msg, &native_fx);
    Host.drain(&fx);
    try compare(&native, Host.model());
    try viewParity(&native, Host.model());
    inline for (std.meta.tags(sdk.EffectExitReason)) |reason| {
        reference.update(&native, .{ .exited = .{ .key = 1, .reason = reason, .code = -9, .dropped_lines = 73, .output = "out", .output_truncated = true, .stderr_tail = "error", .stderr_truncated = true } }, &native_fx);
        Host.dispatch(&fx, .{ .exited = .{ .key = "1", .reason = std.meta.stringToEnum(core.ExitReason, @tagName(reason)).?, .code = -9, .droppedLines = 73, .output = "out", .outputTruncated = true, .stderrTail = "error", .stderrTruncated = true } });
        try compare(&native, Host.model());
        try viewParity(&native, Host.model());
    }
}
test {
    _ = @import("effects_probe_reference_tests.zig");
}

test "compiled probe retains exact native u64 counter formatting across word and safe-number boundaries" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    native_fx.executor = .fake;
    for ([_]u64{ 0xFFFF_FFFF, 0x1_FFFF_FFFF_FFFFFF, 0x8000_0000_0000_0000, std.math.maxInt(u64) - 1 }) |count| {
        var native: reference.Model = .{ .total_lines = count, .streaming = true };
        // Restore through the canonical compiled ABI; the Zig mirror is a
        // read-only snapshot and cannot replace the compiler-owned root.
        Host.init(&fx);
        const snapshot = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(snapshot);
        var at: usize = 4;
        for (0..std.mem.readInt(u32, snapshot[0..4], .little)) |_| {
            const tag = std.mem.readInt(u32, snapshot[at..][0..4], .little);
            const len = std.mem.readInt(u32, snapshot[at + 4 ..][0..4], .little);
            at += 8;
            if (tag == 1) {
                try testing.expectEqual(@as(u32, 16), len);
                std.mem.writeInt(i64, snapshot[at..][0..8], @intCast(count >> 32), .little);
                std.mem.writeInt(i64, snapshot[at + 8 ..][0..8], @intCast(count & 0xFFFFFFFF), .little);
            }
            if (tag == 3) snapshot[at] = 1;
            at += len;
        }
        const model = core.restoreModel(snapshot);
        reference.update(&native, .{ .line = .{ .key = 1, .line = "boundary" } }, &native_fx);
        const result = core.update(model, .{ .line = .{ .key = "1", .line = "boundary", .truncated = false, .droppedBefore = 0 } });
        try compare(&native, result.model);
        // Exercise the entire status-bar string as well as the two words.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "{d} lines total · 0 dropped", .{count + 1}), result.model.totals(arena.allocator()));
        core.rt.frameReset();
    }
}
fn probeReplay(comptime compiled_view: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = .init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "effects-probe", 560, 480));
    var fingerprint: u64 = 0;
    var full_model: ?[]u8 = null;
    defer if (full_model) |bytes| testing.allocator.free(bytes);
    {
        const state = try Adapter.create(testing.allocator, .{}, .{ .name = "effects-probe", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build });
        defer state.destroy();
        state.effects.executor = .fake;
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(560, 480) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = reference.canvas_label, .size = .init(560, 480), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Start stream", "press");
        const key = state.effects.pendingSpawnAt(0).?.key;
        for (0..30) |i| {
            var line: [96]u8 = undefined;
            try state.effects.feedLineWithMetadata(key, try std.fmt.bufPrint(&line, "line {d}: Café", .{i}), i % 2 == 0, @intCast(i % 3));
            try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        }
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Copy status", "press");
        try state.effects.feedClipboardResult(state.effects.pendingClipboardAt(0).?.key, .ok, "");
        try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        try state.effects.feedExitWithMetadata(key, -9, .signaled, .{ .dropped_lines = 31, .output_truncated = true, .stderr_truncated = true });
        try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
        fingerprint = harness.runtime.sessionStateFingerprint();
        full_model = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
        recorder.finish();
        try testing.expect(!recorder.failed);
        try testing.expect(recorder.effect_count >= 32);
    }
    const state = try Adapter.create(testing.allocator, .{}, .{ .name = "effects-probe", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build });
    defer state.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(560, 480) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    const replayed = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
    defer testing.allocator.free(replayed);
    try testing.expectEqualStrings(full_model.?, replayed);
}
test "complete probe model, effects and every checkpoint replay on both view backends" {
    try probeReplay(false);
    try probeReplay(true);
}
