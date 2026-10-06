const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("notes_core");
const decoder = @import("notes_decoder");
const reference = @import("notes_reference.zig");
const native_model = @import("notes_model_reference.zig");
const parity = @import("effects_media_parity.zig");
const Host = sdk.TsCoreHost(core);
const testing = std.testing;
const canvas = sdk.canvas;
const wall: i64 = 1_700_000_000_000;

fn stamp(expected: i64, actual: []const u8) !void {
    var buffer: [21]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "{d}", .{expected}), actual);
}
fn bufferEqual(expected: anytype, actual: anytype) !void {
    try testing.expectEqualStrings(expected.text(), actual.text);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.anchor)), actual.selection.anchor);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.focus)), actual.selection.focus);
    try testing.expectEqual(expected.composition != null, actual.composition != null);
    if (expected.composition) |value| {
        try testing.expectEqual(@as(i64, @intCast(value.start)), actual.composition.?.start);
        try testing.expectEqual(@as(i64, @intCast(value.end)), actual.composition.?.end);
    }
    try testing.expectEqual(expected.truncated, actual.truncated);
}
fn compare(expected: *const reference.Model, actual: *const core.Model) !void {
    try testing.expectEqual(expected.folder_count, actual.folders.len);
    for (expected.folders[0..expected.folder_count], actual.folders) |*a, b| {
        try testing.expectEqual(@as(i64, a.id), b.id);
        try testing.expectEqualStrings(a.name(), b.name);
    }
    try testing.expectEqual(expected.note_count, actual.notes.len);
    for (expected.notes[0..expected.note_count], actual.notes) |*a, b| {
        try testing.expectEqual(@as(i64, a.id), b.id);
        try testing.expectEqual(@as(i64, a.folder), b.folder);
        try stamp(a.created_ms, b.created_ms);
        try stamp(a.updated_ms, b.updated_ms);
        try stamp(a.deleted_ms, b.deleted_ms);
        try bufferEqual(a.body, b.body);
    }
    inline for (.{ "next_folder_id", "next_note_id", "selected_folder", "active_note", "dialog_folder", "hovered_note" }) |field|
        try testing.expectEqual(@as(i64, @intCast(@field(expected, field))), @field(actual, field));
    inline for (.{ "store_write_inflight", "save_pending" }) |field| try testing.expectEqual(@field(expected, field), @field(actual, field));
    inline for (.{ "sidebar_split", "list_split", "note_list_scroll", "chrome_leading", "header_height" }) |field|
        try testing.expectEqual(@as(f64, @field(expected, field)), @field(actual, field));
    try bufferEqual(expected.search_buffer, actual.search_buffer);
    try bufferEqual(expected.folder_field, actual.folder_field);
    try testing.expectEqualStrings(@tagName(expected.dialog), @tagName(actual.dialog));
    try testing.expectEqualStrings(@tagName(expected.system_scheme), @tagName(actual.system_scheme));
    try stamp(expected.now_ms, actual.now_ms);
    try testing.expectEqualStrings(expected.dialog_hint, actual.dialog_hint);
    try testing.expectEqualStrings(expected.status(), actual.activity);
    try testing.expectEqualStrings(expected.storePath(), actual.store_path);
    try testing.expectEqual(.idle, std.meta.activeTag(actual.pending_clock));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ "search", "listTitle", "emptyTitle", "emptyHint", "editorText", "dialogTitle", "dialogConfirmLabel", "folderName" }) |name|
        try testing.expectEqualStrings(@field(reference.Model, name)(expected), @field(core.Model, name)(actual, alloc));
    inline for (.{ "trashCount", "noteCount", "editorMeta", "statusLine" }) |name|
        try testing.expectEqualStrings(@field(reference.Model, name)(expected, alloc), @field(core.Model, name)(actual, alloc));
    inline for (.{ "foldersFull", "trashAvailable", "trashSelected", "hasActiveNote", "activeNoteLive", "dialogOpen", "dialogNameEmpty" }) |name|
        try testing.expectEqual(@field(reference.Model, name)(expected), @field(core.Model, name)(actual));
    const old_folders = expected.folderRows(alloc);
    const new_folders = actual.folderRows(alloc);
    try testing.expectEqual(old_folders.len, new_folders.len);
    for (old_folders, new_folders) |a, b| {
        try testing.expectEqual(@as(i64, a.id), b.id);
        inline for (.{ "name", "label", "count" }) |name| try testing.expectEqualStrings(@field(a, name), @field(b, name));
        try testing.expectEqual(a.selected, b.selected);
        try testing.expectEqual(a.mutable, b.mutable);
    }
    const old_notes = expected.noteRows(alloc);
    const new_notes = actual.noteRows(alloc);
    try testing.expectEqual(old_notes.len, new_notes.len);
    for (old_notes, new_notes) |a, b| {
        try testing.expectEqual(@as(i64, a.id), b.id);
        inline for (.{ "title", "snippet", "time" }) |name| try testing.expectEqualStrings(@field(a, name), @field(b, name));
        try testing.expectEqual(a.active, b.active);
        try testing.expectEqual(a.deleted, b.deleted);
    }
    core.rt.frameReset();
}
fn viewParity(expected: *const reference.Model, actual: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = reference.NotesUi.init(arena.allocator());
    const old = try a.finalize(reference.CompiledNotesView.build(&a, expected));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const new = try b.finalize(if (backend == 0) View.build(&b, actual) else decoder.build(&b, actual));
        core.rt.frameReset();
        try parity.equal(old.root, new.root);
        try testing.expectEqual(old.handlers.len, new.handlers.len);
        for (old.handlers, new.handlers) |before, after| {
            try testing.expectEqual(before.id, after.id);
            const left = old.msgForPointer(before.id, .up);
            const right = new.msgForPointer(after.id, .up);
            try testing.expectEqual(left != null, right != null);
            if (left) |msg| try testing.expectEqualStrings(@tagName(msg), @tagName(right.?));
        }
        var left: [1024]canvas.WidgetLayoutNode = undefined;
        var right: [1024]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 1180, 760), .init(0, 0, 760, 520), .init(0, 0, 960, 680) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(old.root, frame, &left), try canvas.layoutWidgetTree(new.root, frame, &right));
    }
}
const Pair = struct {
    clock: sdk.TestClock,
    model: reference.Model,
    fx: Host.Fx,
    native_fx: reference.Effects,
    fn create(path: []const u8) !*Pair {
        const self = try testing.allocator.create(Pair);
        errdefer testing.allocator.destroy(self);
        self.clock = .{};
        self.clock.setWallMs(wall);
        self.model = native_model.initialModel(self.clock.clock());
        self.fx = .init(testing.allocator);
        errdefer self.fx.deinit();
        self.fx.executor = .fake;
        self.fx.clock = self.clock.clock();
        self.native_fx = .init(testing.allocator);
        errdefer self.native_fx.deinit();
        self.native_fx.executor = .fake;
        self.native_fx.clock = self.clock.clock();
        if (path.len > 0) self.model.setStorePath("/notes-test/store.txt");
        reference.boot(&self.model, &self.native_fx);
        Host.init(&self.fx);
        Host.dispatch(&self.fx, .{ .data_dir_set = path });
        try self.check();
        return self;
    }
    fn destroy(self: *Pair) void {
        self.fx.deinit();
        self.native_fx.deinit();
        testing.allocator.destroy(self);
    }
    fn check(self: *Pair) !void {
        try compare(&self.model, Host.model());
        try testing.expectEqual(self.native_fx.pendingFileCount(), self.fx.pendingFileCount());
        for (0..self.fx.pendingFileCount()) |i| {
            const a = self.native_fx.pendingFileAt(i).?;
            const b = self.fx.pendingFileAt(i).?;
            try testing.expectEqual(a.op, b.op);
            try testing.expectEqualStrings(a.path, b.path);
            try testing.expectEqualStrings(a.bytes, b.bytes);
        }
        try testing.expectEqual(self.native_fx.pendingTimerCount(), self.fx.pendingTimerCount());
        for (0..self.fx.pendingTimerCount()) |i| {
            const a = self.native_fx.pendingTimerAt(i).?;
            const b = self.fx.pendingTimerAt(i).?;
            try testing.expectEqual(a.interval_ms, b.interval_ms);
            try testing.expectEqual(a.mode, b.mode);
        }
        try testing.expectEqual(self.native_fx.pendingClipboardCount(), self.fx.pendingClipboardCount());
        for (0..self.fx.pendingClipboardCount()) |i| try testing.expectEqualStrings(self.native_fx.pendingClipboardAt(i).?.text, self.fx.pendingClipboardAt(i).?.text);
        try viewParity(&self.model, Host.model());
    }
    fn step(self: *Pair, native: reference.Msg, msg: core.Msg) !void {
        reference.update(&self.model, native, &self.native_fx);
        Host.dispatch(&self.fx, msg);
        while (self.native_fx.takeMsg()) |reply| reference.update(&self.model, reply, &self.native_fx);
        Host.drain(&self.fx);
        try self.check();
    }
    fn file(self: *Pair, outcome: sdk.EffectFileOutcome, bytes: []const u8) !void {
        const a = self.native_fx.pendingFileAt(0).?;
        const b = self.fx.pendingFileAt(0).?;
        try self.native_fx.feedFileResult(a.key, outcome, bytes);
        try self.fx.feedFileResult(b.key, outcome, bytes);
        while (self.native_fx.takeMsg()) |reply| reference.update(&self.model, reply, &self.native_fx);
        Host.drain(&self.fx);
        try self.check();
    }
    fn timer(self: *Pair, interval: u32) !void {
        var old: u64 = 0;
        var new: u64 = 0;
        for (0..self.native_fx.pendingTimerCount()) |i| if (self.native_fx.pendingTimerAt(i).?.interval_ms == interval) {
            old = self.native_fx.pendingTimerAt(i).?.key;
        };
        for (0..self.fx.pendingTimerCount()) |i| if (self.fx.pendingTimerAt(i).?.interval_ms == interval) {
            new = self.fx.pendingTimerAt(i).?.key;
        };
        try testing.expect(old != 0 and new != 0);
        try self.native_fx.fireTimer(old);
        try self.fx.fireTimer(new);
        while (self.native_fx.takeMsg()) |reply| reference.update(&self.model, reply, &self.native_fx);
        Host.drain(&self.fx);
        try self.check();
    }
};

test "Notes complete model effects widgets and layout match the native reference through editing folders trash and save coalescing" {
    const pair = try Pair.create("/notes-test");
    defer pair.destroy();
    try pair.file(.not_found, "");
    try pair.step(.{ .hover_note = 4 }, .{ .hover_note = 4 });
    try pair.step(.{ .unhover_note = 7 }, .{ .unhover_note = 7 });
    try pair.step(.{ .unhover_note = 4 }, .{ .unhover_note = 4 });
    try pair.step(.{ .search_edit = .{ .insert_text = "COFFEE" } }, .{ .search_edit = .{ .insert_text = "COFFEE" } });
    try pair.step(.next_note, .next_note);
    try pair.step(.prev_note, .prev_note);
    try pair.step(.dismiss, .dismiss);
    try pair.step(.{ .select_folder = 3 }, .{ .select_folder = 3 });
    try pair.step(.{ .sidebar_resized = 0.25 }, .{ .sidebar_resized = 0.25 });
    try pair.step(.{ .list_resized = 0.41 }, .{ .list_resized = 0.41 });
    try pair.step(.new_note, .new_note);
    try pair.step(.{ .edit = .{ .insert_text = "Café 日本🙂\n\nOwned note text" } }, .{ .edit = .{ .insert_text = "Café 日本🙂\n\nOwned note text" } });
    try pair.step(.{ .edit = .{ .move_caret = .{ .direction = .start, .extend = true } } }, .{ .edit = .{ .move_caret = .{ .direction = .start, .extend = true } } });
    try pair.step(.{ .edit = .{ .insert_text = "Replaced\n\nA second line" } }, .{ .edit = .{ .insert_text = "Replaced\n\nA second line" } });
    try pair.timer(800);
    try pair.file(.ok, "");
    try pair.file(.disk_full, "");
    try pair.step(.{ .trash_note = 8 }, .{ .trash_note = 8 });
    try pair.file(.ok, "");
    try pair.step(.select_trash, .select_trash);
    try pair.step(.{ .edit = .{ .insert_text = "refused" } }, .{ .edit = .{ .insert_text = "refused" } });
    try pair.step(.{ .restore_note = 8 }, .{ .restore_note = 8 });
    try pair.file(.ok, "");
    try pair.step(.open_create_folder, .open_create_folder);
    try pair.step(.confirm_dialog, .confirm_dialog);
    try pair.step(.{ .folder_field_edit = .{ .insert_text = "Ideas" } }, .{ .folder_field_edit = .{ .insert_text = "Ideas" } });
    try pair.step(.confirm_dialog, .confirm_dialog);
    try pair.step(.{ .folder_field_edit = .clear }, .{ .folder_field_edit = .clear });
    try pair.step(.{ .folder_field_edit = .{ .insert_text = "  Projects\n2026  " } }, .{ .folder_field_edit = .{ .insert_text = "  Projects\n2026  " } });
    try pair.step(.confirm_dialog, .confirm_dialog);
    try pair.file(.ok, "");
    try pair.step(.open_rename_folder, .open_rename_folder);
    try pair.step(.{ .folder_field_edit = .clear }, .{ .folder_field_edit = .clear });
    try pair.step(.{ .folder_field_edit = .{ .insert_text = "Work" } }, .{ .folder_field_edit = .{ .insert_text = "Work" } });
    try pair.step(.confirm_dialog, .confirm_dialog);
    try pair.file(.ok, "");
    try pair.step(.{ .delete_folder = 3 }, .{ .delete_folder = 3 });
    try pair.file(.ok, "");
    try pair.step(.select_trash, .select_trash);
    try pair.step(.delete_note, .delete_note);
    try pair.file(.ok, "");
    try pair.step(.{ .select_folder_at = 0 }, .{ .select_folder_at = "0" });
    try pair.step(.copy_note, .copy_note);
    const a = pair.native_fx.pendingClipboardAt(0).?;
    const b = pair.fx.pendingClipboardAt(0).?;
    try pair.native_fx.feedClipboardResult(a.key, .ok, "");
    try pair.fx.feedClipboardResult(b.key, .ok, "");
    while (pair.native_fx.takeMsg()) |msg| reference.update(&pair.model, msg, &pair.native_fx);
    Host.drain(&pair.fx);
    try pair.check();
    pair.clock.setWallMs(wall + 60000);
    try pair.timer(30000);
    try pair.timer(30000);
    try pair.step(.{ .system_scheme = .dark }, .{ .system_scheme = .{ .colorScheme = .dark, .reduceMotion = false, .highContrast = false } });
}

test "Notes store loads preserve every signed timestamp malformed prefix duplicate id and body byte" {
    for ([_][]const u8{
        "unreadable",
        "native-sdk-notes v1\nfolder 1 Home\nnote 1 1 0 -1 3\na\x00b\n",
        "native-sdk-notes v2\nfolder 1 Home\nfolder 1 Duplicate\nnote 1 99 -9007199254740993 9007199254740993 0 4\n\xff\xc3\x00x\nnote 1 1 9223372036854775807 9007199254740992 -9223372036854775808 1\nz\n",
        "native-sdk-notes v2\nfolder 1 Home\nnote 2 -0 0 0 0 -0\n\n",
        "native-sdk-notes v2\nfolder +0_1 Home\nnote +0_1 1 -0 +0_0 0 0\n\nunknown\n",
        "native-sdk-notes v2\nfolder 1 Home\nnote 2 1 0 0 0 4 extra ignored\nbody\nnote 0 1 0 0 0 0\n",
        "native-sdk-notes v2\nfolder 1 Home\nnote 2 1 0 0 0 4097\n",
    }) |store| {
        const pair = try Pair.create("/notes-test");
        defer pair.destroy();
        // -1 keeps subtraction defined for both signed-i64 endpoints.
        pair.clock.setWallMs(-1);
        try pair.timer(30000);
        try pair.file(.ok, store);
    }
}

test {
    _ = @import("notes_reference_tests.zig");
}

fn notesCommand(name: []const u8) ?core.Msg {
    return core.commandMsg(name);
}

fn notesReplay(comptime compiled_view: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = .init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "notes", 1180, 760));
    var fingerprint: u64 = 0;
    var full_model: ?[]u8 = null;
    defer if (full_model) |bytes| testing.allocator.free(bytes);
    {
        const state = try Adapter.create(testing.allocator, .{}, .{ .name = "notes", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build, .on_command = notesCommand });
        defer state.destroy();
        state.effects.executor = .fake;
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1180, 760) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = reference.canvas_label, .size = .init(1180, 760), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        const folder = parity.find(&state.tree.?.root, "Inbox folder") orelse return error.WidgetNotFound;
        var click: [128]u8 = undefined;
        try harness.runtime.dispatchAutomationCommand(state.app(), try std.fmt.bufPrint(&click, "widget-click {s} {d}", .{ reference.canvas_label, folder.id }));
        try testing.expectEqual(@as(i64, 1), state.model.selected_folder);
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.new-note" } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.new-folder" } });
        try parity.action(&harness.runtime, state.app(), &state.tree.?.root, reference.canvas_label, "Cancel", "press");
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.folder-2" } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.copy-note" } });
        if (state.effects.pendingClipboardAt(0)) |request| {
            try state.effects.feedClipboardResult(request.key, .ok, "");
            try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
        }
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.delete-note" } });
        const trash = parity.find(&state.tree.?.root, "Recently Deleted folder") orelse return error.WidgetNotFound;
        try harness.runtime.dispatchAutomationCommand(state.app(), try std.fmt.bufPrint(&click, "widget-click {s} {d}", .{ reference.canvas_label, trash.id }));
        try testing.expectEqual(@as(i64, std.math.maxInt(u32)), state.model.selected_folder);
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .menu_command = .{ .window_id = 1, .name = "notes.dismiss" } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
        fingerprint = harness.runtime.sessionStateFingerprint();
        full_model = try std.json.Stringify.valueAlloc(testing.allocator, state.model, .{});
        recorder.finish();
        try testing.expect(!recorder.failed);
        try testing.expect(recorder.effect_count >= 4);
    }
    const state = try Adapter.create(testing.allocator, .{}, .{ .name = "notes", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled_view) decoder.build else View.build, .on_command = notesCommand });
    defer state.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1180, 760) });
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
test "Notes complete model effects and every sealed checkpoint replay on both view backends" {
    try notesReplay(false);
    try notesReplay(true);
}

test "Notes command bytes match native suffix parsing through the entire usize range" {
    const pair = try Pair.create("");
    defer pair.destroy();
    for ([_][]const u8{
        "notes.folder-1",                    "notes.folder-+0_2",                 "notes.folder-3__0",             "notes.folder-00004",
        "notes.folder-9007199254740991",     "notes.folder-9007199254740992",     "notes.folder-9007199254740993", "notes.folder-9223372036854775808",
        "notes.folder-18446744073709551615", "notes.folder-18446744073709551616", "notes.folder-",                 "notes.folder-+",
        "notes.folder-0",                    "notes.folder--0",                   "notes.folder--1",               "notes.folder-_1",
        "notes.folder-1_",                   "notes.folder-1x",                   "notes.folder- 1",               "notes.folder-1\x00",
        "notes.folder-\xff",                 "notes.folder-0x1",                  "notes.new-note\x00",
    }) |name| {
        const before = reference.command(name);
        const after = core.commandMsg(name);
        try testing.expectEqual(before != null, after != null);
        if (before) |msg| {
            var buffer: [20]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "{d}", .{msg.select_folder_at}), after.?.select_folder_at);
            try pair.step(msg, after.?);
        }
        core.rt.frameReset();
    }
}

test "Notes compiled view owns every byte text field" {
    try decoder.testByteTextRecords();
}

test "Notes complete theme tokens match both native palettes" {
    const Adapter = sdk.TsUiApp(core);
    const state = try Adapter.create(testing.allocator, .{}, .{ .name = "notes", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = decoder.build });
    defer state.destroy();
    for ([_]canvas.ColorScheme{ .light, .dark }) |scheme| {
        Host.dispatch(&state.effects, .{ .system_scheme = .{ .colorScheme = switch (scheme) {
            .light => .light,
            .dark => .dark,
        }, .reduceMotion = false, .highContrast = false } });
        state.model = Host.model().*;
        const model = reference.Model{ .system_scheme = scheme };
        const actual = state.options.token_overrides_fn.?(&state.model).apply(canvas.DesignTokens.theme(.{ .color_scheme = scheme }));
        try parity.equal(reference.notesTokens(&model), actual);
        core.rt.frameReset();
    }
}

test "Notes text capacities composition selection and refused inserts preserve native state" {
    const pair = try Pair.create("");
    defer pair.destroy();
    try pair.step(.new_note, .new_note);
    try pair.step(.{ .edit = .{ .insert_text = "Café 日本\r\n🙂" } }, .{ .edit = .{ .insert_text = "Café 日本\r\n🙂" } });
    try pair.step(.{ .edit = .{ .set_selection = .{ .anchor = 2, .focus = 6 } } }, .{ .edit = .{ .set_selection = .{ .anchor = 2, .focus = 6 } } });
    try pair.step(.{ .edit = .{ .set_composition = .{ .text = "かな", .cursor = 3 } } }, .{ .edit = .{ .set_composition = .{ .text = "かな", .cursor = 3 } } });
    try pair.step(.{ .edit = .cancel_composition }, .{ .edit = .cancel_composition });
    try pair.step(.{ .edit = .{ .set_composition = .{ .text = "é", .cursor = null } } }, .{ .edit = .{ .set_composition = .{ .text = "é", .cursor = null } } });
    try pair.step(.{ .edit = .commit_composition }, .{ .edit = .commit_composition });
    try pair.step(.{ .edit = .clear }, .{ .edit = .clear });
    const large = try testing.allocator.alloc(u8, 4100);
    defer testing.allocator.free(large);
    @memset(large, 'a');
    @memcpy(large[4094..4098], "🙂");
    try pair.step(.{ .edit = .{ .insert_text = large } }, .{ .edit = .{ .insert_text = large } });
    try pair.step(.{ .edit = .delete_backward }, .{ .edit = .delete_backward });
    try pair.step(.{ .search_edit = .{ .insert_text = large[0..52] } }, .{ .search_edit = .{ .insert_text = large[0..52] } });
    try pair.step(.dismiss, .dismiss);
    try pair.step(.open_create_folder, .open_create_folder);
    try pair.step(.{ .folder_field_edit = .{ .insert_text = large[0..36] } }, .{ .folder_field_edit = .{ .insert_text = large[0..36] } });
    try pair.step(.close_dialog, .close_dialog);
    try pair.step(.open_create_folder, .open_create_folder);
}

test "Notes every whole file terminal outcome matches native coordination" {
    for (std.enums.values(sdk.EffectFileOutcome)) |outcome| {
        const pair = try Pair.create("/notes-test");
        defer pair.destroy();
        try pair.file(outcome, "");
        try pair.step(.new_note, .new_note);
        try pair.step(.new_note, .new_note);
        try pair.file(outcome, "");
    }
}
