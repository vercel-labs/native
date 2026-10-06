//! Generated chart trees retain exact data and typed state across dispatches.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("chart_core");
const decoder = @import("chart_decoder");
const exact = @import("component_construction_e2e_tests.zig").exact;
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("chart_fixture.native"));

test "compiled app chart preserves complete trees geometry raw words dispatch effects and owned results" {
    var model = core.initialModel().model.*;
    defer core.rt.frameReset();
    const samples = [_]f64{ 0.125, -0.0, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) };
    for (0..samples.len + 3) |i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        var before_root = View.build(&reference, &model);
        stampReference(&before_root);
        const expected = try reference.finalize(before_root);
        const root = decoder.build(&compiled, &model);
        core.rt.frameReset();
        const actual = try compiled.finalize(root);
        try exact(expected.root, actual.root);
        try exact(expected.handlers, actual.handlers);
        var before: [1024]canvas.WidgetLayoutNode = undefined;
        var after: [1024]canvas.WidgetLayoutNode = undefined;
        for ([_]f32{ 40, 480, 720 }) |width| try exact(try canvas.layoutWidgetTree(expected.root, .init(0, 0, width, 600), &before), try canvas.layoutWidgetTree(actual.root, .init(0, 0, width, 600), &after));
        const msg: core.Msg = if (i < samples.len) .{ .append = samples[i] } else if (i == samples.len) .toggle else .reset;
        const result = core.update(&model, msg);
        model = result.model.*;
        try std.testing.expectEqualSlices(u8, if (msg == .reset) &.{} else &.{1}, result.cmd);
    }
}

// The reference uses the same already-delivered interaction/appearance owners;
// its chart preparation and markup construction remain independent native code.
fn stampReference(node: *Ui.Node) void {
    node.widget.appearance_policy = core.nativeWindowPolicy;
    node.widget.interaction_policy = core.nativeTextPolicy;
    for (@constCast(node.nodes)) |*child| stampReference(child);
}
