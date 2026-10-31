//! Behavioral harness for dual-ledger-csv-split, ts track. The grader
//! copies this next to the transpiled core.zig (the whole import graph
//! emits as one module), the rt kernel, and cmdview.zig, then runs
//! `zig test harness.zig`. Asserts the shared behavioral spec: the export
//! writes the byte-exact quoted CSV to export.csv through the file effect,
//! the four-state lifecycle holds with re-entry guarded, exports track
//! removals, and the starter behavior stays intact.

const std = @import("std");
const core = @import("core.zig");
const cmdview = @import("cmdview.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_buf: [4096]u8 = undefined;

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

test "the starter behavior is intact: totals, removal, reset" {
    fresh();
    try std.testing.expect(core.expenseCount(g_model) == 4);
    try std.testing.expect(core.totalCents(g_model) == 55450);
    _ = dispatch(.{ .remove = 3 });
    try std.testing.expect(core.expenseCount(g_model) == 3);
    try std.testing.expect(core.totalCents(g_model) == 49050);
    _ = dispatch(.reset);
    try std.testing.expect(core.expenseCount(g_model) == 4);
    try std.testing.expect(core.totalCents(g_model) == 55450);
}

test "export writes the byte-exact quoted CSV to export.csv" {
    fresh();
    try std.testing.expect(g_model.export_state == .idle);
    const cmd = dispatch(.export_csv);
    try std.testing.expect(g_model.export_state == .exporting);
    const write = cmdview.findOp(cmd, .write_file) orelse return error.NoWriteIssued;
    try std.testing.expectEqualStrings("export.csv", write.path);
    try std.testing.expectEqualStrings(seeded_csv, write.bytes);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).exported), write.ok_tag);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).export_failed), write.err_tag);
    _ = dispatch(.exported);
    try std.testing.expect(g_model.export_state == .done);
}

test "export while exporting is a no-op; done allows a new export" {
    fresh();
    _ = dispatch(.export_csv);
    const during = dispatch(.export_csv);
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(during, .write_file));
    try std.testing.expect(g_model.export_state == .exporting);
    _ = dispatch(.exported);
    const again = dispatch(.export_csv);
    try std.testing.expect(cmdview.findOp(again, .write_file) != null);
}

test "a write failure is a visible failed state and export can retry" {
    fresh();
    _ = dispatch(.export_csv);
    _ = dispatch(.{ .export_failed = "io_failed" });
    try std.testing.expect(g_model.export_state == .failed);
    const retry = dispatch(.export_csv);
    try std.testing.expect(cmdview.findOp(retry, .write_file) != null);
    try std.testing.expect(g_model.export_state == .exporting);
}

test "the export follows removals" {
    fresh();
    _ = dispatch(.{ .remove = 3 });
    const cmd = dispatch(.export_csv);
    const write = cmdview.findOp(cmd, .write_file) orelse return error.NoWriteIssued;
    try std.testing.expectEqualStrings(csv_after_remove, write.bytes);
}
