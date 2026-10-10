const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("code_editor_core");
const decoder = @import("code_editor_decoder");
const reference = @import("code-editor-reference/main.zig");
const Host = sdk.TsCoreHost(core);
const testing = std.testing;
const canvas = sdk.canvas;
const parity = @import("effects_media_parity.zig");
const wire = @import("corewire_rt");

const Adapter = sdk.TsUiAppWithFeatures(core, .{ .compiled_model = true, .runtime_markup = false });
const RuntimeFixture = struct {
    harness: *sdk.TestHarness(),
    state: *Adapter.App,
    fn create() !RuntimeFixture {
        return make(null, true);
    }
    fn make(recorder: ?*sdk.runtime.SessionRecorder, start: bool) !RuntimeFixture {
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1120, 720) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        _ = try harness.null_platform.platform().services.createWindow(.{
            .id = 1,
            .label = "main",
            .title = "Native SDK Code Editor",
            .default_frame = .init(0, 0, 1120, 720),
        });
        harness.runtime.options.security.permissions = &.{ "view", "command" };
        const state = try Adapter.create(testing.allocator, .{}, .{
            .name = "code-editor",
            .scene = reference.shell_scene,
            .on_command = core.commandMsg,
            .canvas_label = "code-editor-canvas",
            .view = decoder.buildRuntime,
            .window_view = decoder.buildRuntimeWindow,
        });
        errdefer state.destroy();
        state.effects.executor = .real;
        const self: RuntimeFixture = .{ .harness = harness, .state = state };
        if (start) {
            try harness.start(state.app());
            try self.frame(1, "code-editor-canvas");
        }
        return self;
    }
    fn destroy(self: RuntimeFixture) void {
        self.state.destroy();
        self.harness.destroy(testing.allocator);
    }
    fn frame(self: RuntimeFixture, id: sdk.platform.WindowId, label: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.state.app(), .{ .gpu_surface_frame = .{
            .window_id = id,
            .label = label,
            .size = .init(1120, 720),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 9007199254740993,
            .nonblank = true,
        } });
    }
    fn command(self: RuntimeFixture, id: sdk.platform.WindowId, name: []const u8) !void {
        try self.state.app().event(&self.harness.runtime, .{ .command = .{ .window_id = id, .name = name } });
        try self.state.drainEffects(&self.harness.runtime);
    }
    fn window(self: RuntimeFixture, label: []const u8) !sdk.platform.WindowId {
        var storage: [sdk.platform.max_windows]sdk.platform.WindowInfo = undefined;
        for (self.harness.runtime.listWindows(&storage)) |value| {
            if (std.mem.eql(u8, value.label, label)) return value.id;
        }
        return error.TestUnexpectedResult;
    }
    fn cancelDialog(context: ?*anyopaque, options: sdk.platform.OpenDialogOptions, _: []u8) !sdk.platform.OpenDialogResult {
        const platform: *sdk.platform.NullPlatform = @ptrCast(@alignCast(context.?));
        try testing.expectEqualStrings("Open Folder", options.title);
        try testing.expect(options.allow_directories and !options.allow_multiple);
        platform.open_dialog_count += 1;
        return .{ .count = 0, .paths = "" };
    }
};

test "production Code Editor adapter routes source windows, retries focus and gates dialogs" {
    const fixture = try RuntimeFixture.create();
    defer fixture.destroy();
    try fixture.command(1, "new-window");
    const secondary = try fixture.window("code-editor-2");
    try fixture.frame(secondary, "code-editor-canvas-2");
    try fixture.frame(1, "code-editor-canvas");
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expectEqual(@as(?i64, null), core.snapshotModel().pending_focus_session);
    try fixture.command(1, "open-folder");
    try testing.expectEqual(@as(i64, 0), core.snapshotModel().active_session);
    try testing.expectEqualStrings("The folder dialog could not be opened.", core.snapshotModel().sessions[0].browser.status);
    try testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.open_dialog_count);
    try fixture.command(secondary, "open-folder");
    try testing.expectEqual(@as(i64, 1), core.snapshotModel().active_session);
    try testing.expectEqualStrings("The folder dialog could not be opened.", core.snapshotModel().sessions[1].browser.status);
    try fixture.frame(1, "code-editor-canvas");
    try testing.expectEqual(@as(i64, 1), core.snapshotModel().active_session);
    fixture.harness.runtime.options.security.permissions = &.{ "view", "command", "dialog" };
    fixture.harness.runtime.options.platform.services.show_open_dialog_fn = RuntimeFixture.cancelDialog;
    try fixture.command(secondary, "open-folder");
    try testing.expectEqual(@as(usize, 1), fixture.harness.null_platform.open_dialog_count);
    try testing.expectEqualStrings("Folder selection cancelled.", core.snapshotModel().sessions[1].browser.status);
    fixture.harness.null_platform.fail_next_close_window = true;
    try fixture.command(1, "close-tab");
    try testing.expect(core.snapshotModel().pending_close_main);
    try fixture.frame(1, "code-editor-canvas");
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expect(!core.snapshotModel().pending_close_main);
    // Results and subsequent input rebuild the surviving secondary even
    // though the primary's native canvas has already been removed.
    try fixture.command(secondary, "open-folder");
    try fixture.frame(secondary, "code-editor-canvas-2");
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expectEqualStrings("Folder selection cancelled.", core.snapshotModel().sessions[1].browser.status);
    try fixture.command(secondary, "new-window");
    const third = try fixture.window("code-editor-3");
    try fixture.frame(third, "code-editor-canvas-3");
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expectEqual(@as(?i64, null), core.snapshotModel().pending_focus_session);
}

test {
    _ = @import("code-editor-reference/tests.zig");
}

test "journaled desktop window terminals restore runtime lifetime without OS focus or close" {
    const fixture = try RuntimeFixture.create();
    defer fixture.destroy();
    fixture.state.effects.armReplay();
    try fixture.command(1, "new-window");
    const secondary = try fixture.window("code-editor-2");
    try fixture.frame(secondary, "code-editor-canvas-2");
    const fx = &fixture.state.effects;
    var request = fx.pendingHostAt(0).?;
    var output: [128]u8 = undefined;
    var len = try @import("desktop_files.zig").replyHeaderFor(&output, request.payload, "");
    try fx.pushReplayWindowExecution(.{ .kind = .window_execution, .key = request.key, .code = 0, .payload = request.payload, .stderr_tail = output[0..len] });
    fx.flushDesktopCapabilities();
    try fx.feedHostResult(request.key, true, output[0..len]);
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expectEqual(@as(?i64, null), core.snapshotModel().pending_focus_session);
    fixture.harness.null_platform.fail_next_close_window = true;
    try fixture.command(1, "close-tab");
    request = fx.pendingHostAt(0).?;
    len = try @import("desktop_files.zig").replyHeaderFor(&output, request.payload, "CloseFailed");
    try fx.feedHostResult(request.key, true, output[0..len]);
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expect(core.snapshotModel().pending_close_main);
    try fixture.frame(1, "code-editor-canvas");
    request = fx.pendingHostAt(0).?;
    len = try @import("desktop_files.zig").replyHeaderFor(&output, request.payload, "");
    try fx.pushReplayWindowExecution(.{ .kind = .window_execution, .key = request.key, .code = 1, .payload = request.payload, .stderr_tail = output[0..len] });
    fx.flushDesktopCapabilities();
    try fx.feedHostResult(request.key, true, output[0..len]);
    try fixture.state.drainEffects(&fixture.harness.runtime);
    try testing.expect(!core.snapshotModel().pending_close_main);
    try testing.expect(fixture.harness.null_platform.fail_next_close_window);
    try testing.expectError(error.WindowNotFound, fixture.harness.runtime.canvasWidgetLayout(1, "code-editor-canvas"));
    try fixture.command(secondary, "new-window");
    _ = try fixture.window("code-editor-3");
}

test "window execution facts refuse malformed metadata and mismatched correlation" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.armReplay();
    const payload = [_]u8{ 1, 7, 4, 0, 'm', 'a', 'i', 'n' };
    const reply = [_]u8{ 1, 7, 0, 0 };
    const Record = sdk.runtime.EffectResultRecord;
    const valid: Record = .{ .kind = .window_execution, .key = 9, .code = 0, .payload = &payload, .stderr_tail = &reply };
    for (0..payload.len) |len| {
        var bad = valid;
        bad.payload = payload[0..len];
        try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    }
    for (0..reply.len) |len| {
        var bad = valid;
        bad.stderr_tail = reply[0..len];
        try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    }
    var bad = valid;
    bad.code = 2;
    try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    bad = valid;
    bad.truncated = true;
    try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    bad = valid;
    bad.file_total = 1;
    try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    bad = valid;
    bad.stderr_tail = &.{ 1, 8, 0, 0 };
    try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    bad.stderr_tail = &.{ 1, 7, 1, 0, 'x' };
    try testing.expectError(error.ReplayDamagedRecord, fx.pushReplayWindowExecution(bad));
    try fx.finishReplay();
}

test "window execution facts require one exact request and matching terminal" {
    const payload = [_]u8{ 1, 7, 4, 0, 'm', 'a', 'i', 'n' };
    const reply = [_]u8{ 1, 7, 0, 0 };
    const valid: sdk.runtime.EffectResultRecord = .{ .kind = .window_execution, .key = 9, .code = 0, .payload = &payload, .stderr_tail = &reply };
    for (0..6) |scenario| {
        var fx = Host.Fx.init(testing.allocator);
        defer fx.deinit();
        fx.armReplay();
        fx.defer_desktop_capabilities = true;
        if (scenario != 0) try fx.pushReplayWindowExecution(valid);
        if (scenario == 1) {
            fx.flushDesktopCapabilities();
            try testing.expectError(error.ReplayWindowDivergence, fx.finishReplay());
            continue;
        }
        // A changed label and a changed capability cannot claim the fact.
        fx.hostRequest(.{
            .key = 9,
            .name = if (scenario == 2) "native-sdk.window.closeResult" else "native-sdk.window.focusResult",
            .payload = if (scenario == 3) &.{ 1, 7, 4, 0, 'e', 'l', 's', 'e' } else &payload,
        });
        fx.flushDesktopCapabilities();
        if (scenario == 2 or scenario == 3) {
            try testing.expectError(error.ReplayWindowDivergence, fx.finishReplay());
            continue;
        }
        if (scenario == 0) {
            try testing.expectError(error.ReplayWindowDivergence, fx.feedHostResult(9, true, &reply));
            continue;
        }
        try testing.expectError(error.ReplayWindowDivergence, fx.finishReplay());
        if (scenario == 4) {
            try testing.expectError(error.ReplayWindowDivergence, fx.feedHostResult(9, false, &reply));
            try testing.expectError(error.ReplayWindowDivergence, fx.feedHostResult(9, true, &.{ 1, 8, 0, 0 }));
            try fx.feedHostResult(9, true, &reply);
            try fx.finishReplay();
        } else {
            try fx.pushReplayWindowExecution(valid);
            fx.flushDesktopCapabilities();
            try fx.feedHostResult(9, true, &reply);
            try testing.expectError(error.ReplayWindowDivergence, fx.finishReplay());
        }
    }
}

test "window execution facts preserve focus and close checkpoints before delayed terminals" {
    const Buffer = struct {
        bytes: std.ArrayList(u8) = .empty,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.bytes.appendSlice(testing.allocator, bytes);
        }
    };
    var buffer: Buffer = .{};
    defer buffer.bytes.deinit(testing.allocator);
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = Buffer.write });
    recorder.begin(.{ .app_name = "code-editor", .platform_name = "test" });
    var fingerprint: u64 = 0;
    var model: []u8 = undefined;
    {
        const live = try RuntimeFixture.make(recorder, true);
        defer live.destroy();
        const runtime = &live.harness.runtime;
        const app = live.state.app();
        try runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "new-window", .window_id = 1 } });
        try runtime.dispatchPlatformEvent(app, .frame_requested);
        const secondary = try live.window("code-editor-2");
        try live.frame(secondary, "code-editor-canvas-2");
        try runtime.dispatchPlatformEvent(app, .wake);
        try runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = "close-tab", .window_id = 1 } });
        try runtime.dispatchPlatformEvent(app, .frame_requested);
        try runtime.dispatchPlatformEvent(app, .wake);
        try testing.expect(!core.snapshotModel().pending_close_main);
        try testing.expectError(error.WindowNotFound, runtime.canvasWidgetLayout(1, "code-editor-canvas"));
        fingerprint = runtime.sessionStateFingerprint();
        model = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        recorder.finish();
        try testing.expect(recorder.finished and !recorder.failed and recorder.effect_count >= 4);
    }
    defer testing.allocator.free(model);
    const replay = try RuntimeFixture.make(null, false);
    defer replay.destroy();
    // Any accidental native replay close fails. Execution facts only change
    // runtime ownership, independently of the later terminal/model commit.
    replay.harness.null_platform.fail_next_close_window = true;
    const report = try sdk.runtime.replaySession(&replay.harness.runtime, replay.state.app(), buffer.bytes.items, .{ .require_same_platform = false });
    try testing.expect(report.ok() and report.checkpoints_verified >= 2);
    try testing.expectEqual(fingerprint, replay.harness.runtime.sessionStateFingerprint());
    try testing.expectEqualSlices(u8, model, core.persistenceSnapshot());
    try testing.expect(replay.harness.null_platform.fail_next_close_window);
}

test "fake window replies journal execution after the request's settled checkpoint" {
    const Buffer = struct {
        bytes: std.ArrayList(u8) = .empty,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.bytes.appendSlice(testing.allocator, bytes);
        }
    };
    var buffer: Buffer = .{};
    defer buffer.bytes.deinit(testing.allocator);
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = Buffer.write });
    recorder.begin(.{ .app_name = "code-editor", .platform_name = "test" });
    var fingerprint: u64 = 0;
    var model: []u8 = undefined;
    {
        const live = try RuntimeFixture.make(recorder, true);
        defer live.destroy();
        live.state.effects.executor = .fake;
        const runtime = &live.harness.runtime;
        const app = live.state.app();
        for ([_][]const u8{ "new-window", "close-tab" }) |command| {
            try runtime.dispatchPlatformEvent(app, .{ .menu_command = .{ .name = command, .window_id = 1 } });
            // A full checkpoint occurs while the synthetic result is parked.
            try runtime.dispatchPlatformEvent(app, .frame_requested);
            const request = live.state.effects.pendingHostAt(0).?;
            var output: [128]u8 = undefined;
            const len = try @import("desktop_files.zig").replyHeaderFor(&output, request.payload, "");
            try live.state.effects.feedHostResult(request.key, true, output[0..len]);
            try runtime.dispatchPlatformEvent(app, .wake);
            try runtime.dispatchPlatformEvent(app, .frame_requested);
        }
        try testing.expect(!core.snapshotModel().pending_close_main);
        try testing.expectEqual(@as(?i64, null), core.snapshotModel().pending_focus_session);
        try testing.expectError(error.WindowNotFound, runtime.canvasWidgetLayout(1, "code-editor-canvas"));
        fingerprint = runtime.sessionStateFingerprint();
        model = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        recorder.finish();
        try testing.expect(recorder.finished and !recorder.failed and recorder.effect_count >= 4);
    }
    defer testing.allocator.free(model);
    const replay = try RuntimeFixture.make(null, false);
    defer replay.destroy();
    replay.harness.null_platform.fail_next_close_window = true;
    const report = try sdk.runtime.replaySession(&replay.harness.runtime, replay.state.app(), buffer.bytes.items, .{ .require_same_platform = false });
    try testing.expect(report.ok() and report.checkpoints_verified >= 4);
    try testing.expectEqual(fingerprint, replay.harness.runtime.sessionStateFingerprint());
    try testing.expectEqualSlices(u8, model, core.persistenceSnapshot());
    try testing.expect(replay.harness.null_platform.fail_next_close_window);
}

test "compiled Code Editor creates five independently owned sessions" {
    var fx = Host.Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    try std.testing.expectEqual(@as(usize, 5), Host.model().sessions.len);
    try std.testing.expect(Host.model().sessions[0].open);
    for (1..5) |_| Host.dispatch(&fx, .new_window);
    for (Host.model().sessions) |session| try std.testing.expect(session.open);
    Host.dispatch(&fx, .new_window);
    try std.testing.expectEqualStrings("Window limit reached (5).", Host.model().sessions[4].browser.status);
}

fn word64(value: anytype, comptime lower: []const u8, comptime upper: []const u8) u64 {
    return @as(u64, @intFromFloat(parity.number(@field(value, lower)))) |
        (@as(u64, @intFromFloat(parity.number(@field(value, upper)))) << 32);
}
fn optionalIndex(expected: anytype, actual: anytype) !void {
    try testing.expectEqual(expected != null, actual != null);
    if (expected) |index| try testing.expectEqual(@as(f64, @floatFromInt(index)), parity.number(actual.?));
}
fn textState(expected: anytype, actual: anytype) !void {
    try testing.expectEqualStrings(expected.text(), actual.text);
    try testing.expectEqual(@as(f64, @floatFromInt(expected.selection.anchor)), parity.number(actual.selection.anchor));
    try testing.expectEqual(@as(f64, @floatFromInt(expected.selection.focus)), parity.number(actual.selection.focus));
    try testing.expectEqual(expected.composition != null, actual.composition != null);
    if (expected.composition) |composition| {
        try testing.expectEqual(@as(f64, @floatFromInt(composition.start)), parity.number(actual.composition.?.start));
        try testing.expectEqual(@as(f64, @floatFromInt(composition.end)), parity.number(actual.composition.?.end));
    }
}
fn browserEqual(expected: *const reference.Model, actual: anytype) !void {
    try testing.expectEqualStrings(expected.rootPath(), actual.root);
    try testing.expectEqualStrings(expected.status(), actual.status);
    try testing.expectEqual(expected.entry_count, actual.entries.len);
    for (expected.entries[0..expected.entry_count], actual.entries) |*entry, value| {
        try testing.expectEqualStrings(entry.name(), value.name);
        try testing.expectEqualStrings(entry.relativePath(), value.relative_path);
        try testing.expectEqualStrings(@tagName(entry.kind), @tagName(value.kind));
        try testing.expectEqual(@as(f64, @floatFromInt(entry.depth)), parity.number(value.depth));
        try optionalIndex(entry.parent, value.parent);
        try testing.expectEqual(entry.expanded, value.expanded);
        try testing.expectEqual(entry.children_loaded, value.children_loaded);
        try testing.expectEqual(@as(f64, @floatFromInt(entry.sort_identity)), parity.number(value.sort_identity));
    }
    inline for (.{ "tree_selected_entry", "selected_entry", "preview_entry", "hovered_tab", "renaming_entry", "pending_rename_entry", "pending_expand_entry" }) |field|
        try optionalIndex(@field(expected, field), @field(actual, field));
    try testing.expectEqual(expected.pinned_count, actual.pinned_entries.len);
    for (expected.pinned_entries[0..expected.pinned_count], actual.pinned_entries) |a, b|
        try testing.expectEqual(@as(f64, @floatFromInt(a)), parity.number(b));
    try textState(expected.rename_buffer, actual.rename_buffer);
    try testing.expectEqual(expected.rename_buffer.truncated, actual.rename_truncated);
    inline for (.{ "rename_serial", "expand_serial", "picker_serial", "next_file_key" }) |field|
        try testing.expectEqual(@field(expected, field), word64(@field(actual, field), "counter_lower", "counter_upper"));
    inline for (.{ "scan_truncated", "scan_had_errors" }) |field|
        try testing.expectEqual(@field(expected, field), @field(actual, field));
    inline for (.{ "sidebar_fraction", "chrome_leading", "titlebar_height" }) |field|
        try testing.expectEqual(@as(f64, @field(expected, field)), parity.number(@field(actual, field)));
    try testing.expectEqual(expected.document_count, actual.documents.len);
    for (expected.documents[0..expected.document_count], actual.documents) |document, value| {
        try testing.expectEqual(@as(f64, @floatFromInt(document.entry_index.?)), parity.number(value.entry_index));
        try testing.expect(document.editor.value != null);
        try textState(document.editor.value.?.*, value.editor);
        try testing.expectEqual(document.editor.truncated(), value.editor_truncated);
        try testing.expectEqualStrings(@tagName(document.state), @tagName(value.state));
        try testing.expectEqual(document.source_truncated, value.source_truncated);
        inline for (.{ "read_key", "save_key" }) |field|
            try testing.expectEqual(@field(document, field), word64(@field(value, field), "counter_lower", "counter_upper"));
        try testing.expectEqual(document.save_queued, value.save_queued);
        inline for (.{ "saved_len", "pending_save_len" }) |field|
            try testing.expectEqual(@as(f64, @floatFromInt(@field(document, field))), parity.number(@field(value, field)));
        inline for (.{ "saved_hash", "pending_save_hash" }) |field|
            try testing.expectEqual(@field(document, field), word64(@field(value, field), "hash_lower", "hash_upper"));
    }
}
fn modelEqual(expected: *const reference.AppModel, actual: *const core.Model) !void {
    try testing.expectEqual(expected.sessions.len, actual.sessions.len);
    try testing.expectEqual(@as(f64, @floatFromInt(expected.active_session)), parity.number(actual.active_session));
    try optionalIndex(expected.pending_focus_session, actual.pending_focus_session);
    try testing.expectEqual(expected.pending_close_main, actual.pending_close_main);
    for (&expected.sessions, actual.sessions) |*session, value| {
        try testing.expectEqual(session.open, value.open);
        // The copied dialog result exists only between dialog and scan replies.
        try testing.expectEqualStrings("", value.pending_root);
        inline for (.{ "handled_picker_serial", "handled_rename_serial", "handled_expand_serial" }) |field|
            try testing.expectEqual(@field(session, field), word64(@field(value, field), "counter_lower", "counter_upper"));
        try browserEqual(&session.browser, value.browser);
    }
}
fn viewEqual(expected: *const reference.AppModel, actual: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const labels = [_][]const u8{ "main", "code-editor-2", "code-editor-3", "code-editor-4", "code-editor-5" };
    for (&expected.sessions, 0..) |*session, index| {
        if (!session.open) continue;
        var a = reference.BrowserUi.init(arena.allocator());
        const old = try a.finalize(reference.CompiledCodeEditorView.build(&a, &session.browser));
        var b = canvas.Ui(core.Msg).init(arena.allocator());
        const new = try b.finalize(if (index == 0) decoder.build(&b, actual) else decoder.buildWindow(&b, actual, labels[index]));
        core.rt.frameReset();
        try widgetEqual(old.root, new.root);
        try testing.expectEqual(old.handlers.len, new.handlers.len);
        for (old.handlers, new.handlers) |left, right| {
            try testing.expectEqual(left.id, right.id);
            try testing.expectEqual(left.event, right.event);
            try testing.expectEqualStrings(@tagName(left.action), @tagName(right.action));
            if (left.action == .input) {
                const edit: canvas.TextInputEvent = .{ .insert_text = "é\x00\xff" };
                const a_msg = left.action.input(edit);
                const b_msg = right.action.input(edit);
                try testing.expectEqualStrings(@tagName(a_msg), @tagName(b_msg));
                if (a_msg == .edit_code) try testing.expectEqualStrings(a_msg.edit_code.insert_text, b_msg.edit_code.insert_text);
                if (a_msg == .edit_rename) try testing.expectEqualStrings(a_msg.edit_rename.insert_text, b_msg.edit_rename.insert_text);
            } else if (left.action == .value) {
                for ([_]f32{ 0, 0.125, 0.33333334, 1 }) |value| {
                    const a_msg = left.action.value(value);
                    const b_msg = right.action.value(value);
                    try testing.expectEqualStrings(@tagName(a_msg), @tagName(b_msg));
                    try testing.expectEqual(@as(f64, a_msg.sidebar_resized), b_msg.sidebar_resized);
                }
            } else if (left.action == .context_menu) {
                try testing.expectEqual(left.action.context_menu.len, right.action.context_menu.len);
                for (left.action.context_menu, right.action.context_menu) |a_item, b_item| {
                    try testing.expectEqual(a_item != null, b_item != null);
                    if (a_item) |a_msg| {
                        try testing.expectEqualStrings(@tagName(a_msg), @tagName(b_item.?));
                        switch (a_msg) {
                            .close_tab => |value| try testing.expectEqual(@as(f64, @floatFromInt(value)), parity.number(b_item.?.close_tab)),
                            .close_other_tabs => |value| try testing.expectEqual(@as(f64, @floatFromInt(value)), parity.number(b_item.?.close_other_tabs)),
                            else => return error.UnexpectedContextMenuMessage,
                        }
                    }
                }
            } else if (left.action == .message) {
                const a_msg = left.action.message;
                const b_msg = right.action.message;
                try testing.expectEqualStrings(@tagName(a_msg), @tagName(b_msg));
                switch (a_msg) {
                    inline else => |value, tag| {
                        const T = @TypeOf(value);
                        if (comptime @typeInfo(T) == .int or @typeInfo(T) == .float)
                            try testing.expectEqual(parity.number(value), parity.number(@field(b_msg, @tagName(tag))));
                    },
                }
            }
        }
        var left: [2048]canvas.WidgetLayoutNode = undefined;
        var right: [2048]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 760, 480), .init(0, 0, 1120, 720), .init(0, 0, 1440, 900) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(old.root, frame, &left), try canvas.layoutWidgetTree(new.root, frame, &right));
    }
}
fn widgetEqual(expected: canvas.Widget, actual: canvas.Widget) anyerror!void {
    inline for (@typeInfo(canvas.Widget).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "children")) {
            try testing.expectEqual(expected.children.len, actual.children.len);
            for (expected.children, actual.children) |a, b| try widgetEqual(a, b);
        } else if (comptime !std.mem.eql(u8, field.name, "compiled_scroll_policy")) {
            parity.equal(@field(expected, field.name), @field(actual, field.name)) catch |err| {
                std.debug.print("Code Editor widget {d} ({s}) differs at {s}\n", .{ expected.id, @tagName(expected.kind), field.name });
                return err;
            };
        }
    }
}

const Pair = struct {
    model: reference.AppModel,
    native_fx: reference.Effects,
    fx: Host.Fx,
    fn create() !*Pair {
        const self = try testing.allocator.create(Pair);
        errdefer testing.allocator.destroy(self);
        self.model = .{};
        self.model.init();
        self.native_fx = .init(testing.allocator);
        errdefer self.native_fx.deinit();
        self.native_fx.executor = .fake;
        self.fx = .init(testing.allocator);
        errdefer self.fx.deinit();
        self.fx.executor = .fake;
        Host.init(&self.fx);
        try self.check();
        return self;
    }
    fn destroy(self: *Pair) void {
        self.model.deinit();
        self.native_fx.deinit();
        self.fx.deinit();
        testing.allocator.destroy(self);
    }
    fn check(self: *Pair) !void {
        try modelEqual(&self.model, Host.model());
        try testing.expectEqual(self.native_fx.pendingFileCount(), self.fx.pendingFileCount());
        for (0..self.fx.pendingFileCount()) |i| {
            const a = self.native_fx.pendingFileAt(i).?;
            const b = self.fx.pendingFileAt(i).?;
            try testing.expectEqual(a.op, b.op);
            try testing.expectEqualStrings(a.path, b.path);
            try testing.expectEqualStrings(a.bytes, b.bytes);
        }
        try viewEqual(&self.model, Host.model());
    }
    fn step(self: *Pair, native: reference.Msg, msg: core.Msg) !void {
        reference.appUpdate(&self.model, native, &self.native_fx);
        Host.dispatch(&self.fx, msg);
        // The native wrapper consumes each pending OS intent before returning
        // to the event loop; fake execution preserves the boundary for replies.
        for (&self.model.sessions, 0..) |*session, index| {
            if (!session.open) continue;
            if (session.browser.pending_rename_entry != null and session.browser.rename_serial != session.handled_rename_serial) {
                session.handled_rename_serial = session.browser.rename_serial;
                self.model.active_session = @intCast(index);
            }
            if (session.browser.pending_expand_entry != null and session.browser.expand_serial != session.handled_expand_serial) {
                session.handled_expand_serial = session.browser.expand_serial;
                self.model.active_session = @intCast(index);
            }
            if (session.browser.picker_serial != session.handled_picker_serial) {
                session.handled_picker_serial = session.browser.picker_serial;
                self.model.active_session = @intCast(index);
            }
        }
        while (self.native_fx.takeMsg()) |reply| reference.appUpdate(&self.model, reply, &self.native_fx);
        Host.drain(&self.fx);
        try self.check();
    }
    fn scan(self: *Pair, path: []const u8, dir: std.Io.Dir) !void {
        const owner = self.model.active_session;
        try self.step(.open_folder, .open_folder);
        try reference.scanOpenDirectory(&self.model.sessions[owner].browser, testing.io, testing.allocator, path, dir);
        const picker = self.fx.pendingHostAt(0).?;
        var folder: [1024]u8 = undefined;
        const header = try @import("desktop_files.zig").replyHeaderFor(&folder, picker.payload, "");
        std.mem.writeInt(u16, folder[header..][0..2], @intCast(path.len), .little);
        @memcpy(folder[header + 2 ..][0..path.len], path);
        try self.fx.feedHostResult(picker.key, true, folder[0 .. header + 2 + path.len]);
        Host.drain(&self.fx);
        const request = self.fx.pendingHostAt(0).?;
        try testing.expectEqualStrings("native-sdk.fs.listDirectory", request.name);
        var output: [64 * 1024]u8 = undefined;
        const reply = try @import("desktop_files.zig").execute(testing.io, request.name, request.payload, &output);
        try self.fx.feedHostResult(request.key, true, reply);
        Host.drain(&self.fx);
        try self.check();
    }
    fn directory(self: *Pair) !void {
        const request = self.fx.pendingHostAt(0).?;
        try testing.expectEqualStrings("native-sdk.fs.listDirectory", request.name);
        const owner = request.payload[1];
        const browser = &self.model.sessions[owner].browser;
        try reference.loadDirectoryChildren(browser, testing.io, browser.pending_expand_entry.?);
        browser.pending_expand_entry = null;
        var output: [64 * 1024]u8 = undefined;
        const reply = try @import("desktop_files.zig").execute(testing.io, request.name, request.payload, &output);
        try self.fx.feedHostResult(request.key, true, reply);
        Host.drain(&self.fx);
        try self.check();
    }
    fn rename(self: *Pair) !void {
        const request = self.fx.pendingHostAt(0).?;
        try testing.expectEqualStrings("native-sdk.fs.renameExclusive", request.name);
        const desktop = @import("desktop_files.zig");
        var reader = try desktop.request(request.payload);
        const old_path = try reader.field();
        const new_path = try reader.field();
        try reader.finish();
        const owner = request.payload[1];
        const browser = &self.model.sessions[owner].browser;
        reference.performPendingRenameOnDisk(browser, testing.io);
        const succeeded = browser.renaming_entry == null;
        // Each independent implementation sees the same initial disk. Only
        // this test-owned rename is restored between the two executions.
        if (succeeded) try std.Io.Dir.cwd().rename(new_path, std.Io.Dir.cwd(), old_path, testing.io);
        var output: [1024]u8 = undefined;
        const reply = try desktop.execute(testing.io, request.name, request.payload, &output);
        try self.fx.feedHostResult(request.key, true, reply);
        Host.drain(&self.fx);
        try self.check();
    }
    fn file(self: *Pair, outcome: sdk.EffectFileOutcome, bytes: []const u8) !void {
        const a = self.native_fx.pendingFileAt(0).?;
        const b = self.fx.pendingFileAt(0).?;
        try self.native_fx.feedFileResult(a.key, outcome, bytes);
        try self.fx.feedFileResult(b.key, outcome, bytes);
        const left = self.native_fx.takeMsg().?.file_done;
        const right = self.fx.takeMsg().?.file_done;
        try testing.expectEqual(left.key, try std.fmt.parseInt(u64, right.key, 10));
        try testing.expectEqualStrings(@tagName(left.op), @tagName(right.operation));
        try testing.expectEqualStrings(@tagName(left.event), @tagName(right.event));
        try testing.expectEqualStrings(@tagName(left.outcome), @tagName(right.outcome));
        try testing.expectEqualStrings(left.bytes, right.bytes);
        try testing.expectEqual(left.total, try std.fmt.parseInt(u64, right.totalBytes, 10));
        try testing.expectEqual(left.mtime_ms, try std.fmt.parseInt(i64, right.mtimeMs, 10));
        try testing.expectEqual(left.exists, right.exists);
        try testing.expectEqual(@as(f64, @floatFromInt(left.dropped_before)), parity.number(right.droppedBefore));
        reference.appUpdate(&self.model, .{ .file_done = left }, &self.native_fx);
        Host.dispatch(&self.fx, .{ .file_done = right });
        try self.check();
    }
};

test "compiled Code Editor retains complete documents, hashes, queued saves and tab effects" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "first.ts", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "second.zig", .data = "" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
    try pair.file(.ok, "Café 日本\nconst value = 42;\n");
    try pair.step(.{ .pin_entry = 0 }, .{ .pin_entry = 0 });
    try pair.step(.{ .edit_code = .{ .insert_text = "🙂" } }, .{ .edit_code = .{ .insert_text = "🙂" } });
    try pair.step(.save_file, .save_file);
    try pair.step(.{ .edit_code = .{ .insert_text = "newer" } }, .{ .edit_code = .{ .insert_text = "newer" } });
    try pair.step(.save_file, .save_file);
    try pair.step(.{ .close_tab = 0 }, .{ .close_tab = 0 });
    try pair.file(.ok, "");
    try pair.file(.disk_full, "");
    try pair.step(.save_file, .save_file);
    try pair.file(.ok, "");
    try pair.step(.{ .preview_entry = 1 }, .{ .preview_entry = 1 });
    try pair.file(.truncated, "valid\xf0\x9f");
    try pair.step(.previous_tab, .previous_tab);
    try pair.step(.next_tab, .next_tab);
    try pair.step(.{ .close_other_tabs = 0 }, .{ .close_other_tabs = 0 });
    try pair.step(.{ .close_tab = 0 }, .{ .close_tab = 0 });
}

fn answerWindow(fx: *Host.Fx, failure: []const u8) !void {
    const request = fx.pendingHostAt(0).?;
    var reply: [128]u8 = undefined;
    const len = try @import("desktop_files.zig").replyHeaderFor(&reply, request.payload, failure);
    try fx.feedHostResult(request.key, true, reply[0..len]);
    Host.drain(fx);
}

test "compiled Code Editor retains window intents across failures and rejects stale generations" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.step(.new_window, .new_window);
    var request = pair.fx.pendingHostAt(0).?;
    try testing.expectEqualStrings("native-sdk.window.focusResult", request.name);
    var stale: [128]u8 = undefined;
    const stale_len = try @import("desktop_files.zig").replyHeaderFor(&stale, request.payload, "");
    try answerWindow(&pair.fx, "WindowNotFound");
    try pair.check();
    try testing.expectEqual(@as(usize, 0), pair.fx.pendingHostCount());
    Host.dispatch(&pair.fx, .window_retry);
    request = pair.fx.pendingHostAt(0).?;
    try pair.fx.feedHostResult(request.key, false, "unsupported");
    Host.drain(&pair.fx);
    try pair.check();
    try pair.step(.new_window, .new_window);
    Host.dispatch(&pair.fx, .{ .focus_done = stale[0..stale_len] });
    try pair.check();
    pair.model.pending_focus_session = null;
    try answerWindow(&pair.fx, "");
    try pair.check();
    // Reusing the SAME session label also invalidates its previous reply.
    try pair.step(.{ .close_window = 1 }, .{ .close_window = 1 });
    try pair.step(.new_window, .new_window);
    Host.dispatch(&pair.fx, .{ .focus_done = stale[0..stale_len] });
    try pair.check();
    pair.model.pending_focus_session = null;
    try answerWindow(&pair.fx, "");
    try pair.check();
    pair.model.active_session = 0;
    Host.dispatch(&pair.fx, .{ .window_changed = "main" });
    try pair.step(.close_active_tab, .close_active_tab);
    request = pair.fx.pendingHostAt(0).?;
    try testing.expectEqualStrings("native-sdk.window.closeResult", request.name);
    try answerWindow(&pair.fx, "CloseFailure");
    try pair.check();
    Host.dispatch(&pair.fx, .window_retry);
    pair.model.pending_close_main = false;
    try answerWindow(&pair.fx, "");
    try pair.check();
}

test "compiled Code Editor validates complete read outcomes and exact hash boundaries" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.ts", .data = "" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    const source = try testing.allocator.alloc(u8, reference.max_preview_bytes + 4);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @intCast(32 + index *% 73 % 95);
    for ([_]usize{ 0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 47, 48, 49, 64, 95, 96, 97, 255, 256, 1024, reference.max_preview_bytes - 1, reference.max_preview_bytes, reference.max_preview_bytes + 1 }) |count| {
        try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
        try pair.file(.ok, source[0..count]);
        try pair.step(.{ .close_tab = 0 }, .{ .close_tab = 0 });
    }
    for ([_][]const u8{ "\x00", "ok\x00tail", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xff", "\x80", "\xe0\x80", "\xf0\x9f", "é日本🙂" }) |bytes| {
        for ([_]sdk.EffectFileOutcome{ .ok, .truncated }) |outcome| {
            try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
            try pair.file(outcome, bytes);
            try pair.step(.{ .close_tab = 0 }, .{ .close_tab = 0 });
        }
    }
    for ([_]sdk.EffectFileOutcome{ .not_found, .io_failed, .cancelled, .rejected }) |outcome| {
        try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
        try pair.file(outcome, "");
        try pair.step(.{ .close_tab = 0 }, .{ .close_tab = 0 });
    }
}

test "compiled Code Editor preserves lazy expansion, rename remapping and every callback" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "folder", .default_dir);
    try tmp.dir.createDir(testing.io, ".git", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zebra.ts", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "folder/inside.ts", .data = "" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    try pair.step(.{ .toggle_entry = 0 }, .{ .toggle_entry = 0 }); // skipped .git
    try pair.step(.{ .toggle_entry = 1 }, .{ .toggle_entry = 1 });
    try pair.directory();
    try pair.step(.{ .preview_entry = 2 }, .{ .preview_entry = 2 });
    try pair.file(.ok, "const café = 1;\n");
    try pair.step(.{ .pin_entry = 2 }, .{ .pin_entry = 2 });
    try pair.step(.{ .hover_tab = 2 }, .{ .hover_tab = 2 });
    try pair.step(.{ .begin_rename = 1 }, .{ .begin_rename = 1 });
    try pair.step(.{ .edit_rename = .clear }, .{ .edit_rename = .clear });
    try pair.step(.{ .edit_rename = .{ .insert_text = "aaa" } }, .{ .edit_rename = .{ .insert_text = "aaa" } });
    try pair.step(.commit_rename, .commit_rename);
    try pair.rename();
    try pair.step(.{ .toggle_entry = 1 }, .{ .toggle_entry = 1 });
    try pair.step(.{ .toggle_entry = 1 }, .{ .toggle_entry = 1 });
    try pair.step(.{ .select_entry = 65535 }, .{ .select_entry = 65535 });
    try pair.step(.{ .begin_rename = 1 }, .{ .begin_rename = 1 });
    try pair.step(.{ .edit_rename = .clear }, .{ .edit_rename = .clear });
    try pair.step(.{ .edit_rename = .{ .insert_text = "../bad" } }, .{ .edit_rename = .{ .insert_text = "../bad" } });
    try pair.step(.commit_rename, .commit_rename);
}

test "compiled Code Editor retains complete Unicode editing, composition and save failures" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.ts", .data = "" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
    try pair.file(.ok, "é\r\n日本🙂 tail\n");
    try pair.step(.{ .edit_code = .{ .set_selection = .{ .anchor = 1, .focus = 9 } } }, .{ .edit_code = .{ .set_selection = .{ .anchor = 1, .focus = 9 } } });
    try pair.step(.{ .edit_code = .{ .set_composition = .{ .text = "🙂", .cursor = 2 } } }, .{ .edit_code = .{ .set_composition = .{ .text = "🙂", .cursor = 2 } } });
    try pair.step(.{ .edit_code = .{ .set_composition = .{ .text = "日本語", .cursor = null } } }, .{ .edit_code = .{ .set_composition = .{ .text = "日本語", .cursor = null } } });
    try pair.step(.{ .edit_code = .commit_composition }, .{ .edit_code = .commit_composition });
    try pair.step(.{ .edit_code = .delete_word_backward }, .{ .edit_code = .delete_word_backward });
    try pair.step(.{ .edit_code = .{ .move_caret = .{ .direction = .previous, .extend = true } } }, .{ .edit_code = .{ .move_caret = .{ .direction = .previous, .extend = true } } });
    try pair.step(.{ .edit_code = .{ .insert_text = "saved" } }, .{ .edit_code = .{ .insert_text = "saved" } });
    for ([_]sdk.EffectFileOutcome{ .io_failed, .rejected, .cancelled, .disk_full, .ok }) |outcome| {
        try pair.step(.save_file, .save_file);
        try pair.file(outcome, "");
    }
}

test "compiled Code Editor preserves exclusive rename races and case-only changes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Widget.ts", .data = "original" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "occupied.ts", .data = "destination" });
    try pair.step(.{ .begin_rename = 0 }, .{ .begin_rename = 0 });
    try pair.step(.{ .edit_rename = .clear }, .{ .edit_rename = .clear });
    try pair.step(.{ .edit_rename = .{ .insert_text = "occupied.ts" } }, .{ .edit_rename = .{ .insert_text = "occupied.ts" } });
    try pair.step(.commit_rename, .commit_rename);
    try pair.rename();
    var storage: [64]u8 = undefined;
    try testing.expectEqualStrings("destination", try tmp.dir.readFile(testing.io, "occupied.ts", &storage));
    try testing.expectEqualStrings("original", try tmp.dir.readFile(testing.io, "Widget.ts", &storage));
    try pair.step(.{ .edit_rename = .clear }, .{ .edit_rename = .clear });
    try pair.step(.{ .edit_rename = .{ .insert_text = "widget.ts" } }, .{ .edit_rename = .{ .insert_text = "widget.ts" } });
    try pair.step(.commit_rename, .commit_rename);
    try pair.rename();
    try testing.expectEqualStrings("original", try tmp.dir.readFile(testing.io, "widget.ts", &storage));
}

test "compiled Code Editor preserves the sixteen pinned tab limit and a seventeenth preview" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var name: [64]u8 = undefined;
    for (0..18) |i| try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "file-{d:0>2}.ts", .{i}), .data = "" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.scan(path[0..len], tmp.dir);
    for (0..17) |i| {
        try pair.step(.{ .preview_entry = @intCast(i) }, .{ .preview_entry = @intCast(i) });
        try pair.file(.ok, "const value = 1;\n");
        try pair.step(.{ .pin_entry = @intCast(i) }, .{ .pin_entry = @intCast(i) });
    }
    try testing.expectEqual(@as(usize, 16), pair.model.sessions[0].browser.pinned_count);
    try testing.expectEqual(@as(usize, 17), pair.model.sessions[0].browser.document_count);
    try testing.expectEqualStrings("Open tab limit reached (16).", Host.model().sessions[0].browser.status);
    try pair.step(.{ .close_other_tabs = 16 }, .{ .close_other_tabs = 16 });
    try pair.step(.close_active_tab, .close_active_tab);
}

test "desktop capabilities reject malformed boundaries and preserve complete directory errors" {
    const desktop = @import("desktop_files.zig");
    var output: [64 * 1024]u8 = undefined;
    for ([_][]const u8{ "", "\x00\x00", "\x01", "\x01\x00\x00", "\x01\x00\xff\xff\x00\x00\x00\x00", "\x01\x00\x01\x00\x00\x00\x01\x00\x00" }) |payload|
        try testing.expectError(error.InvalidRequest, desktop.execute(testing.io, "native-sdk.fs.listDirectory", payload, &output));
    try testing.expectError(error.InvalidRequest, desktop.validatePath(""));
    try testing.expectError(error.InvalidRequest, desktop.validatePath("nul\x00path"));
    const too_long = try testing.allocator.alloc(u8, desktop.max_path_bytes + 1);
    defer testing.allocator.free(too_long);
    @memset(too_long, 'a');
    try testing.expectError(error.InvalidRequest, desktop.validatePath(too_long));
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "child", .data = "bytes" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    var payload: [2048]u8 = undefined;
    payload[0..8].* = .{ 1, 4, 0, 0, 255, 0, 0, 0 };
    std.mem.writeInt(u16, payload[6..8], @intCast(len), .little);
    @memcpy(payload[8..][0..len], path[0..len]);
    const reply = try desktop.execute(testing.io, "native-sdk.fs.listDirectory", payload[0 .. 8 + len], &output);
    try testing.expectEqualStrings("\x01\x04\x00\x00\x01\x00\x00", reply); // cap, flags, exact owner
    payload[2] = 1;
    payload[8] = 0;
    try testing.expectError(error.InvalidRequest, desktop.execute(testing.io, "native-sdk.fs.listDirectory", payload[0 .. 8 + len], &output));
    try testing.expectError(error.OverBound, desktop.replyHeader(output[0..3], 0, ""));
}

const CapabilitySpy = struct {
    calls: usize = 0,
    fn external(_: *anyopaque, _: []const u8) anyerror!void {
        return error.UnexpectedOsCall;
    }
    fn local(_: *anyopaque, _: i64, _: sdk.platform.LocalTimeStyle, _: []u8) anyerror![]const u8 {
        return error.UnexpectedOsCall;
    }
    fn execute(context: *anyopaque, _: []const u8, _: []const u8, _: []u8) anyerror![]const u8 {
        const self: *CapabilitySpy = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.UnexpectedOsCall;
    }
};
test "fake desktop capability requests copy ownership and never call the OS executor" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var spy: CapabilitySpy = .{};
    fx.bindSystemServices(.{ .context = &spy, .open_external_url_fn = CapabilitySpy.external, .reveal_path_fn = CapabilitySpy.external, .format_local_time_fn = CapabilitySpy.local, .execute_capability_fn = CapabilitySpy.execute });
    Host.init(&fx);
    Host.dispatch(&fx, .new_window);
    fx.defer_desktop_capabilities = true;
    fx.flushDesktopCapabilities();
    const request = fx.pendingHostAt(0).?;
    try testing.expectEqual(@as(usize, 0), spy.calls);
    try testing.expectEqualStrings("\x02\x01\x03\x00100\x0d\x00code-editor-2", request.payload);
    var reply: [128]u8 = undefined;
    const len = try @import("desktop_files.zig").replyHeaderFor(&reply, request.payload, "");
    try fx.feedHostResult(request.key, true, reply[0..len]);
    @memset(&reply, 255);
    Host.drain(&fx);
    try testing.expectEqual(@as(usize, 0), spy.calls);
    try testing.expectEqual(@as(?i64, null), Host.model().pending_focus_session);
}

const DeferredCapabilitySpy = struct {
    fx: *Host.Fx,
    values: [8]u8 = @splat(0),
    calls: usize = 0,
    reenter: bool = false,
    fn result(_: sdk.EffectHostResult) core.Msg {
        return .window_retry;
    }
    fn issue(self: *DeferredCapabilitySpy, key: u64, payload: []const u8) void {
        self.fx.hostRequest(.{ .key = key, .name = "native-sdk.window.focusResult", .payload = payload, .on_result = result });
    }
    fn execute(context: *anyopaque, name: []const u8, payload: []const u8, output: []u8) anyerror![]const u8 {
        const self: *DeferredCapabilitySpy = @ptrCast(@alignCast(context));
        try testing.expectEqualStrings("native-sdk.window.focusResult", name);
        self.values[self.calls] = payload[0];
        self.calls += 1;
        if (self.reenter and payload[0] == 'C') {
            self.reenter = false;
            self.issue(1, "D"); // replace the active native call's occupancy
            self.fx.flushDesktopCapabilities(); // nested flush cannot execute it
            try testing.expectEqualStrings("C", payload); // original storage lives
        }
        output[0] = payload[0];
        return output[0..1];
    }
};
test "deferred desktop capabilities preserve issue order, replacement, cancellation and reentrant ownership" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.defer_desktop_capabilities = true;
    var spy: DeferredCapabilitySpy = .{ .fx = &fx };
    fx.bindSystemServices(.{ .context = &spy, .open_external_url_fn = CapabilitySpy.external, .reveal_path_fn = CapabilitySpy.external, .format_local_time_fn = CapabilitySpy.local, .execute_capability_fn = DeferredCapabilitySpy.execute });
    var transient = [_]u8{'A'};
    spy.issue(1, &transient);
    transient[0] = 'Z';
    spy.issue(2, "B");
    spy.issue(1, "C");
    spy.issue(3, "X");
    fx.cancel(3);
    try testing.expectEqual(@as(usize, 0), spy.calls);
    spy.reenter = true;
    fx.flushDesktopCapabilities();
    try testing.expectEqualSlices(u8, "BC", spy.values[0..spy.calls]);
    try testing.expect(fx.takeMsg() != null); // B is the only delivered terminal
    try testing.expect(fx.takeMsg() == null); // C's replaced reply is swallowed
    fx.flushDesktopCapabilities();
    try testing.expectEqualSlices(u8, "BCD", spy.values[0..spy.calls]);
    try testing.expect(fx.takeMsg() != null);
    try testing.expect(fx.takeMsg() == null);
}

fn pendingCapability(fx: *Host.Fx, name: []const u8, owner: u8) !Host.Fx.HostRequest {
    for (0..fx.pendingHostCount()) |at| {
        const request = fx.pendingHostAt(at).?;
        if (std.mem.eql(u8, request.name, name) and request.payload[1] == owner) return request;
    }
    return error.TestUnexpectedResult;
}

test "desktop replies retain session ownership through replacement and window reuse" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    Host.dispatch(&fx, .open_folder);
    const first = try pendingCapability(&fx, "native-sdk.dialog.openDirectory", 0);
    const first_key = first.key;
    var stale: [128]u8 = undefined;
    const header = try @import("desktop_files.zig").replyHeaderFor(&stale, first.payload, "");
    stale[header..][0..2].* = .{ 0, 0 }; // cancellation result
    Host.dispatch(&fx, .new_window);
    try fx.feedHostResult(first_key, false, "PermissionDenied");
    Host.drain(&fx);
    try testing.expectEqualStrings("The folder dialog could not be opened.", Host.model().sessions[0].browser.status);
    try testing.expectEqualStrings("", Host.model().sessions[1].browser.status);
    Host.dispatch(&fx, .open_folder);
    const retired = (try pendingCapability(&fx, "native-sdk.dialog.openDirectory", 1)).key;
    Host.dispatch(&fx, .{ .close_window = 1 });
    try testing.expectError(error.EffectNotFound, fx.feedHostResult(retired, true, stale[0 .. header + 2]));
    Host.dispatch(&fx, .new_window);
    Host.dispatch(&fx, .open_folder);
    const replacement = try pendingCapability(&fx, "native-sdk.dialog.openDirectory", 1);
    var old: [128]u8 = undefined;
    const old_header = try @import("desktop_files.zig").replyHeaderFor(&old, replacement.payload, "");
    old[old_header..][0..2].* = .{ 0, 0 };
    Host.dispatch(&fx, .open_folder); // replaces the same owner's prior request
    Host.dispatch(&fx, .{ .folder_done = old[0 .. old_header + 2] });
    try testing.expect(Host.model().sessions[1].folder_token.len > 0);
    try testing.expectEqualStrings("", Host.model().sessions[1].browser.status);
    const live = try pendingCapability(&fx, "native-sdk.dialog.openDirectory", 1);
    var reply: [128]u8 = undefined;
    const live_header = try @import("desktop_files.zig").replyHeaderFor(&reply, live.payload, "");
    reply[live_header..][0..2].* = .{ 0, 0 };
    try fx.feedHostResult(live.key, true, reply[0 .. live_header + 2]);
    Host.drain(&fx);
    try testing.expectEqualStrings("Folder selection cancelled.", Host.model().sessions[1].browser.status);
    try testing.expectEqual(@as(usize, 0), Host.model().sessions[1].folder_token.len);
}

fn restoreComplete(model: core.Model, allocator: std.mem.Allocator) ![]const u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    try writer.writer.writeInt(u32, @typeInfo(core.Model).@"struct".fields.len, .little);
    inline for (@typeInfo(core.Model).@"struct".fields, 0..) |field, ordinal| {
        const value = wire.encodeAlloc(field.type, @field(model, field.name), allocator);
        try writer.writer.writeInt(u32, ordinal, .little);
        try writer.writer.writeInt(u32, @intCast(value.len), .little);
        try writer.writer.writeAll(value);
    }
    _ = core.restoreRuntimeModel(writer.written());
    core.rt.frameReset();
    return writer.written();
}

test "complete Code Editor snapshot retains all 85 full-capacity documents without a native model mirror" {
    const pair = try Pair.create();
    defer pair.destroy();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file.ts", .data = "x" });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root);
    try pair.scan(root[0..root_len], tmp.dir);
    try pair.step(.{ .preview_entry = 0 }, .{ .preview_entry = 0 });
    try pair.file(.ok, "x");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var model = Host.model().*;
    const sessions = try alloc.alloc(*const core.BrowserSession, 5);
    const template = model.sessions[0].*;
    const template_document = template.browser.documents[0].*;
    const template_entry = template.browser.entries[0].*;
    const native_template = pair.model.sessions[0].browser;
    pair.model.sessions[0].browser.documents[0].editor.deinit();
    var total: usize = 0;
    for (&pair.model.sessions, sessions, 0..) |*expected, *slot, session_index| {
        expected.open = true;
        expected.browser = native_template;
        expected.browser.documents = @splat(.{});
        const browser = try alloc.create(core.BrowserState);
        browser.* = template.browser.*;
        const session = try alloc.create(core.BrowserSession);
        session.* = template;
        session.browser = browser;
        slot.* = session;
        const entries = try alloc.alloc(*const core.ExplorerEntry, 17);
        const documents = try alloc.alloc(*const core.EditorDocument, 17);
        const pinned = try alloc.alloc(f64, 16);
        expected.browser.root_len = root_len;
        @memcpy(expected.browser.root_storage[0..root_len], root[0..root_len]);
        expected.browser.entry_count = 17;
        expected.browser.document_count = 17;
        expected.browser.pinned_count = 16;
        expected.browser.tree_selected_entry = 0;
        expected.browser.selected_entry = 16;
        expected.browser.preview_entry = 16;
        expected.browser.picker_serial = 1;
        expected.handled_picker_serial = 1;
        for (entries, documents, 0..) |*entry_slot, *document_slot, document_index| {
            const name = try std.fmt.allocPrint(alloc, "file-{d}.ts", .{document_index});
            const entry = try alloc.create(core.ExplorerEntry);
            entry.* = template_entry;
            entry.name = name;
            entry.relative_path = name;
            entry.sort_identity = @intCast(document_index);
            entry_slot.* = entry;
            const native_entry = &expected.browser.entries[document_index];
            native_entry.* = .{ .kind = .file, .sort_identity = @intCast(document_index), .depth = @intCast(entry.depth), .children_loaded = entry.children_loaded };
            native_entry.name_len = name.len;
            @memcpy(native_entry.name_storage[0..name.len], name);
            native_entry.relative_len = name.len;
            @memcpy(native_entry.relative_storage[0..name.len], name);
            const text = try alloc.alloc(u8, reference.max_preview_bytes);
            @memset(text, @as(u8, @intCast('a' + session_index)));
            text[text.len - 1] = @intCast('a' + document_index);
            const hash = std.hash.Wyhash.hash(0, text);
            const owned_hash = try alloc.create(core.ContentHash);
            owned_hash.* = .{ .hash_lower = @intCast(hash & 0xffffffff), .hash_upper = @intCast(hash >> 32) };
            const document = try alloc.create(core.EditorDocument);
            document.* = template_document;
            document.entry_index = @intCast(document_index);
            document.editor = .{ .text = text, .selection = .{ .anchor = @intCast(text.len), .focus = @intCast(text.len) }, .composition = null };
            document.saved_len = @intCast(text.len);
            document.saved_hash = owned_hash;
            document_slot.* = document;
            expected.browser.documents[document_index] = .{
                .entry_index = @intCast(document_index),
                .editor = try reference.EditorBuffer.init(testing.allocator, text),
                .state = .text,
                .saved_len = text.len,
                .saved_hash = hash,
            };
            if (document_index < 16) {
                pinned[document_index] = @floatFromInt(document_index);
                expected.browser.pinned_entries[document_index] = @intCast(document_index);
            }
            total += text.len;
        }
        browser.entries = entries;
        browser.documents = documents;
        browser.pinned_entries = pinned;
        browser.tree_selected_entry = 0;
        browser.selected_entry = 16;
        browser.preview_entry = 16;
        // Each session retains the template's exact counters and geometry.
        expected.browser.next_file_key = word64(browser.next_file_key, "counter_lower", "counter_upper");
    }
    model.sessions = sessions;
    try testing.expectEqual(@as(usize, 85 * reference.max_preview_bytes), total);
    const snapshot = try restoreComplete(model, alloc);
    try testing.expect(snapshot.len >= total and snapshot.len > 31 * 1024 * 1024);
    try modelEqual(&pair.model, core.snapshotModel());
    const actual = try alloc.dupe(u8, core.persistenceSnapshot());
    try testing.expectEqualSlices(u8, snapshot, actual);
    _ = core.restoreRuntimeModel(actual);
    core.rt.frameReset();
    const before = core.rt.snapshotDecodeCount();
    const RuntimeHost = sdk.TsCoreHostWithRuntimeModel(core, true);
    RuntimeHost.dispatch(&pair.fx, .window_context_unavailable);
    try testing.expectEqual(before, core.rt.snapshotDecodeCount());
    try modelEqual(&pair.model, core.snapshotModel());
}
