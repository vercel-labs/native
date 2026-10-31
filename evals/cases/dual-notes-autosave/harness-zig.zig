//! Behavioral harness for dual-notes-autosave, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig and run through `native test`.
//! Drives update with the deterministic fake effects executor and asserts
//! the same behavioral spec the ts track's harness asserts.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const main = @import("main.zig");

const testing = std.testing;

const serialized_after_edit =
    "1\tGroceries\tmilk, eggs, bread\n" ++
    "2\tIdeas\tnative first\n" ++
    "3\tStandup\tdemo the panel\n";

const Rig = struct {
    model: main.Model,
    fx: main.Effects,

    fn init() Rig {
        var fx = main.Effects.init(testing.allocator);
        fx.executor = .fake;
        return .{ .model = main.initialModel(), .fx = fx };
    }

    fn deinit(self: *Rig) void {
        self.fx.deinit();
    }

    fn dispatch(self: *Rig, msg: main.Msg) void {
        main.update(&self.model, msg, &self.fx);
    }

    fn drain(self: *Rig) void {
        while (self.fx.takeMsg()) |msg| main.update(&self.model, msg, &self.fx);
    }

    /// Replace the selected note's body: clear, then insert.
    fn editBody(self: *Rig, text: []const u8) void {
        self.dispatch(.{ .edit = .clear });
        self.dispatch(.{ .edit = .{ .insert_text = text } });
    }

    /// Fire the armed autosave debounce and drain it through update.
    fn fireAutosave(self: *Rig) !void {
        const timer = self.fx.pendingTimerAt(0) orelse return error.NoDebounceArmed;
        try self.fx.fireTimer(timer.key);
        self.drain();
    }

    /// The single pending write, or an error naming what is missing.
    fn pendingWrite(self: *Rig) !main.Effects.FileRequest {
        const request = self.fx.pendingFileAt(0) orelse return error.NoWriteIssued;
        try testing.expectEqual(native_sdk.EffectFileOp.write, request.op);
        return request;
    }

    fn finishWrite(self: *Rig, outcome: native_sdk.EffectFileOutcome) !void {
        const request = try self.pendingWrite();
        try self.fx.feedFileResult(request.key, outcome, "");
        self.drain();
    }
};

test "the starter behavior is intact: selection and text editing" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expectEqualStrings("milk, eggs", rig.model.editorText());
    rig.dispatch(.{ .select = 2 });
    try testing.expectEqualStrings("Ideas", rig.model.selectedTitle());
    try testing.expectEqualStrings("native first", rig.model.editorText());
    rig.dispatch(.{ .select = 1 });
    rig.editBody("call mom");
    try testing.expectEqualStrings("call mom", rig.model.editorText());
    rig.dispatch(.{ .select = 3 });
    try testing.expectEqualStrings("demo the panel", rig.model.editorText());
}

test "starts clean; edits mark dirty and re-arm one keyed 800ms debounce" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.save_state == .clean);
    rig.editBody("milk");
    try testing.expect(rig.model.save_state == .dirty);
    const timer = rig.fx.pendingTimerAt(0) orelse return error.NoDebounceArmed;
    try testing.expectEqual(@as(u64, 800), timer.interval_ms);

    rig.editBody("milk, eggs");
    // Still exactly ONE armed timer, same key: the re-arm idiom, not a pile.
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingTimerCount());
    const rearmed = rig.fx.pendingTimerAt(0) orelse return error.DebounceNotRearmed;
    try testing.expectEqual(timer.key, rearmed.key);
    try testing.expectEqual(@as(u64, 800), rearmed.interval_ms);
}

test "the autosave fire writes the pinned serialization to notes.tsv" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.editBody("milk, eggs, bread");
    try rig.fireAutosave();
    try testing.expect(rig.model.save_state == .saving);
    const write = try rig.pendingWrite();
    try testing.expectEqualStrings("notes.tsv", write.path);
    try testing.expectEqualStrings(serialized_after_edit, write.bytes);
    try rig.finishWrite(.ok);
    try testing.expect(rig.model.save_state == .saved);
}

test "save now writes immediately, cancels the pending autosave, and no-ops when clean" {
    var rig = Rig.init();
    defer rig.deinit();
    // Clean: nothing to save.
    rig.dispatch(.save_now);
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingFileCount());
    try testing.expect(rig.model.save_state == .clean);

    rig.editBody("milk, eggs, bread");
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingTimerCount());
    rig.dispatch(.save_now);
    // The pending autosave is CANCELLED, not left to fire into a no-op.
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingTimerCount());
    const write = try rig.pendingWrite();
    try testing.expectEqualStrings("notes.tsv", write.path);
    try testing.expectEqualStrings(serialized_after_edit, write.bytes);
    try testing.expect(rig.model.save_state == .saving);

    // Save now while a save is in flight: nothing new.
    rig.dispatch(.save_now);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingFileCount());

    try rig.finishWrite(.ok);
    try testing.expect(rig.model.save_state == .saved);

    // A stale fire after everything saved writes nothing.
    rig.dispatch(.{ .autosave_fired = .{ .key = 0, .timestamp_ns = 0, .outcome = .fired } });
    try testing.expectEqual(@as(usize, 0), rig.fx.pendingFileCount());
    try testing.expect(rig.model.save_state == .saved);
}

test "a save result landing after newer edits does not mark them saved" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.editBody("v1");
    try rig.fireAutosave();
    try testing.expect(rig.model.save_state == .saving);
    rig.editBody("v2");
    try testing.expect(rig.model.save_state == .dirty);
    try rig.finishWrite(.ok);
    try testing.expect(rig.model.save_state == .dirty);
}

test "a write failure is a visible failed state; editing recovers to dirty" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.editBody("v1");
    try rig.fireAutosave();
    try rig.finishWrite(.io_failed);
    try testing.expect(rig.model.save_state == .failed);
    rig.editBody("v2");
    try testing.expect(rig.model.save_state == .dirty);
}

test "serialization follows edits on other notes" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.{ .select = 2 });
    rig.editBody("native first, always");
    try rig.fireAutosave();
    const write = try rig.pendingWrite();
    try testing.expectEqualStrings(
        "1\tGroceries\tmilk, eggs\n" ++
            "2\tIdeas\tnative first, always\n" ++
            "3\tStandup\tdemo the panel\n",
        write.bytes,
    );
}
