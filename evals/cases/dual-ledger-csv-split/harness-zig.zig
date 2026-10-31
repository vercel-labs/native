//! Behavioral harness for dual-ledger-csv-split, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig and run through `native test`.
//! Asserts the same behavioral spec the ts track's harness asserts.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

const seeded_csv =
    "label,category,cents\n" ++
    "Standing desk,gear,45900\n" ++
    "\"Cable, HDMI 2m\",gear,1900\n" ++
    "Team lunch,food,6400\n" ++
    "\"Mug \"\"Team\"\" x4\",gear,1250\n";

const csv_after_remove =
    "label,category,cents\n" ++
    "Standing desk,gear,45900\n" ++
    "\"Cable, HDMI 2m\",gear,1900\n" ++
    "\"Mug \"\"Team\"\" x4\",gear,1250\n";

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

test "the starter behavior is intact: totals, removal, reset" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.expenseCount() == 4);
    try testing.expect(rig.model.totalCents() == 55450);
    rig.dispatch(.{ .remove = 3 });
    try testing.expect(rig.model.expenseCount() == 3);
    try testing.expect(rig.model.totalCents() == 49050);
    rig.dispatch(.reset);
    try testing.expect(rig.model.expenseCount() == 4);
    try testing.expect(rig.model.totalCents() == 55450);
}

test "export writes the byte-exact quoted CSV to export.csv" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.export_state == .idle);
    rig.dispatch(.export_csv);
    try testing.expect(rig.model.export_state == .exporting);
    const write = try rig.pendingWrite();
    try testing.expectEqualStrings("export.csv", write.path);
    try testing.expectEqualStrings(seeded_csv, write.bytes);
    try rig.finishWrite(.ok);
    try testing.expect(rig.model.export_state == .done);
}

test "export while exporting is a no-op; done allows a new export" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.export_csv);
    rig.dispatch(.export_csv);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingFileCount());
    try testing.expect(rig.model.export_state == .exporting);
    try rig.finishWrite(.ok);
    rig.dispatch(.export_csv);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingFileCount());
}

test "a write failure is a visible failed state and export can retry" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.export_csv);
    try rig.finishWrite(.io_failed);
    try testing.expect(rig.model.export_state == .failed);
    rig.dispatch(.export_csv);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingFileCount());
    try testing.expect(rig.model.export_state == .exporting);
}

test "the export follows removals" {
    var rig = Rig.init();
    defer rig.deinit();
    rig.dispatch(.{ .remove = 3 });
    rig.dispatch(.export_csv);
    const write = try rig.pendingWrite();
    try testing.expectEqualStrings(csv_after_remove, write.bytes);
}
