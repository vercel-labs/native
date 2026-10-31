//! Behavioral harness for dual-notes-autosave, ts track. The grader copies
//! this next to the transpiled core.zig, the rt kernel, and cmdview.zig,
//! then runs `zig test harness.zig`. Asserts the shared behavioral spec:
//! keyed 800ms debounce re-armed per edit, the pinned notes.tsv
//! serialization on fire and on Save now (which also cancels the pending
//! autosave), the five-state save lifecycle including the late-result race,
//! and the starter behavior kept intact.

const std = @import("std");
const core = @import("core.zig");
const cmdview = @import("cmdview.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_buf: [4096]u8 = undefined;

fn fresh() void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
}

fn dispatch(msg: core.Msg) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(g_buf[0..r.cmd.len], r.cmd);
    rt.frameReset();
    return g_buf[0..r.cmd.len];
}

/// Replace the selected note's body: clear, then insert. Returns the
/// INSERT dispatch's cmd bytes (where the re-armed debounce shows up).
fn editBody(text: []const u8) []const u8 {
    _ = dispatch(.{ .edit = .clear });
    return dispatch(.{ .edit = .{ .insert_text = text } });
}

const serialized_after_edit =
    "1\tGroceries\tmilk, eggs, bread\n" ++
    "2\tIdeas\tnative first\n" ++
    "3\tStandup\tdemo the panel\n";

test "the starter behavior is intact: selection and text editing" {
    fresh();
    try std.testing.expectEqualStrings("milk, eggs", core.editorText(g_model));
    _ = dispatch(.{ .select = 2 });
    try std.testing.expectEqualStrings("Ideas", core.selectedTitle(g_model));
    try std.testing.expectEqualStrings("native first", core.editorText(g_model));
    _ = dispatch(.{ .select = 1 });
    _ = editBody("call mom");
    try std.testing.expectEqualStrings("call mom", core.editorText(g_model));
    _ = dispatch(.{ .select = 3 });
    try std.testing.expectEqualStrings("demo the panel", core.editorText(g_model));
}

test "starts clean; edits mark dirty and re-arm one keyed 800ms debounce" {
    fresh();
    try std.testing.expect(g_model.save_state == .clean);
    const first = editBody("milk");
    try std.testing.expect(g_model.save_state == .dirty);
    const delay = cmdview.findOp(first, .delay) orelse return error.NoDebounceArmed;
    try std.testing.expectEqual(@as(f64, 800), delay.after_ms);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).autosave_fired), delay.msg_tag);

    var key_buf: [64]u8 = undefined;
    @memcpy(key_buf[0..delay.key.len], delay.key);
    const key = key_buf[0..delay.key.len];

    const second = editBody("milk, eggs");
    const rearmed = cmdview.findOp(second, .delay) orelse return error.DebounceNotRearmed;
    try std.testing.expectEqualStrings(key, rearmed.key);
    try std.testing.expectEqual(@as(f64, 800), rearmed.after_ms);
}

test "the autosave fire writes the pinned serialization to notes.tsv" {
    fresh();
    _ = editBody("milk, eggs, bread");
    const fired = dispatch(.{ .autosave_fired = 0 });
    try std.testing.expect(g_model.save_state == .saving);
    const write = cmdview.findOp(fired, .write_file) orelse return error.NoWriteIssued;
    try std.testing.expectEqualStrings("notes.tsv", write.path);
    try std.testing.expectEqualStrings(serialized_after_edit, write.bytes);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).saved), write.ok_tag);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).save_failed), write.err_tag);
    _ = dispatch(.saved);
    try std.testing.expect(g_model.save_state == .saved);
}

test "save now writes immediately, cancels the pending autosave, and no-ops when clean" {
    fresh();
    // Clean: nothing to save.
    const idle = dispatch(.save_now);
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(idle, .write_file));
    try std.testing.expect(g_model.save_state == .clean);

    const edited = editBody("milk, eggs, bread");
    const delay = cmdview.findOp(edited, .delay) orelse return error.NoDebounceArmed;
    var key_buf: [64]u8 = undefined;
    @memcpy(key_buf[0..delay.key.len], delay.key);
    const key = key_buf[0..delay.key.len];

    const now = dispatch(.save_now);
    const write = cmdview.findOp(now, .write_file) orelse return error.NoWriteIssued;
    try std.testing.expectEqualStrings("notes.tsv", write.path);
    try std.testing.expectEqualStrings(serialized_after_edit, write.bytes);
    const cancel = cmdview.findOp(now, .cancel) orelse return error.PendingAutosaveNotCancelled;
    try std.testing.expectEqualStrings(key, cancel.key);
    try std.testing.expect(g_model.save_state == .saving);

    // Save now while a save is in flight: nothing new.
    const during = dispatch(.save_now);
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(during, .write_file));

    _ = dispatch(.saved);
    try std.testing.expect(g_model.save_state == .saved);

    // A stale fire after everything saved writes nothing.
    const stale = dispatch(.{ .autosave_fired = 0 });
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(stale, .write_file));
    try std.testing.expect(g_model.save_state == .saved);
}

test "a save result landing after newer edits does not mark them saved" {
    fresh();
    _ = editBody("v1");
    _ = dispatch(.{ .autosave_fired = 0 });
    try std.testing.expect(g_model.save_state == .saving);
    _ = editBody("v2");
    try std.testing.expect(g_model.save_state == .dirty);
    _ = dispatch(.saved);
    try std.testing.expect(g_model.save_state == .dirty);
}

test "a write failure is a visible failed state; editing recovers to dirty" {
    fresh();
    _ = editBody("v1");
    _ = dispatch(.{ .autosave_fired = 0 });
    _ = dispatch(.{ .save_failed = "io_failed" });
    try std.testing.expect(g_model.save_state == .failed);
    _ = editBody("v2");
    try std.testing.expect(g_model.save_state == .dirty);
}

test "serialization follows edits on other notes" {
    fresh();
    _ = dispatch(.{ .select = 2 });
    _ = editBody("native first, always");
    const fired = dispatch(.{ .autosave_fired = 0 });
    const write = cmdview.findOp(fired, .write_file) orelse return error.NoWriteIssued;
    try std.testing.expectEqualStrings(
        "1\tGroceries\tmilk, eggs\n" ++
            "2\tIdeas\tnative first, always\n" ++
            "3\tStandup\tdemo the panel\n",
        write.bytes,
    );
}
