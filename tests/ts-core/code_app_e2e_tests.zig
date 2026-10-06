//! Actual generated code views, complete trees and copied ABI ownership.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("code_core");
const decoder = @import("code_decoder");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("code_fixture.native"));

fn restore(model: core.Model, arena: std.mem.Allocator) !void {
    const texts = [_][]const u8{ model.sourceBytes, model.addedSpec, model.removedSpec };
    var size: usize = 4 + 9;
    for (texts) |text| size += 12 + text.len;
    const snapshot = try arena.alloc(u8, size);
    std.mem.writeInt(u32, snapshot[0..4], 4, .little);
    var at: usize = 4;
    for (texts, 0..) |text, index| {
        std.mem.writeInt(u32, snapshot[at..][0..4], @intCast(index), .little);
        std.mem.writeInt(u32, snapshot[at + 4 ..][0..4], @intCast(4 + text.len), .little);
        std.mem.writeInt(u32, snapshot[at + 8 ..][0..4], @intCast(text.len), .little);
        @memcpy(snapshot[at + 12 ..][0..text.len], text);
        at += 12 + text.len;
    }
    std.mem.writeInt(u32, snapshot[at..][0..4], 3, .little);
    std.mem.writeInt(u32, snapshot[at + 4 ..][0..4], 1, .little);
    snapshot[at + 8] = @intFromBool(model.numbered);
    try parity.equal(model, core.restoreModel(snapshot).*);
}

test "compiled app code preserves complete generated trees geometry input effects and retained bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const large = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(large);
    for (large, 0..) |*byte, i| byte.* = if (i % 16 == 15) '\n' else 'x';
    for ([_][]const u8{ "", "const café = 1;\n", "A\x00\xff\xc0B\n", "return <Outer a={<Leaf />}>text</Outer>;", "# Heading\n```ts\nconst x = 1;\n```\n", large }) |source| for ([_]bool{ false, true }) |numbered| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const model: core.Model = .{ .sourceBytes = source, .addedSpec = "1,32,64,96,128", .removedSpec = "2,31,63,95,127", .numbered = numbered };
        try restore(model, arena.allocator());
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        const expected = try reference.finalize(View.build(&reference, &model));
        const root = decoder.build(&compiled, &model);
        core.rt.frameReset();
        const actual = try compiled.finalize(root);
        try parity.equal(expected.root, actual.root);
        try parity.equal(expected.handlers, actual.handlers);
        var before: [1024]canvas.WidgetLayoutNode = undefined;
        var after: [1024]canvas.WidgetLayoutNode = undefined;
        for ([_]f32{ 40, 320, 720 }) |width| try parity.equal(try canvas.layoutWidgetTree(expected.root, .init(0, 0, width, 600), &before), try canvas.layoutWidgetTree(actual.root, .init(0, 0, width, 600), &after));
        for ([_][]const u8{ "Wrapped editor", "Editor" }) |label| {
            const a = parity.find(&expected.root, label).?;
            const b = parity.find(&actual.root, label).?;
            const event: canvas.TextInputEvent = .{ .insert_text = "edit\x00\xff" };
            const msg = actual.msgForTextEdit(b.id, event).?;
            try parity.equal(expected.msgForTextEdit(a.id, event).?, msg);
            const result = core.update(&model, msg);
            try std.testing.expectEqualSlices(u8, "edit\x00\xff", result.model.sourceBytes);
            try std.testing.expectEqualSlices(u8, &.{1}, result.cmd);
            core.rt.frameReset();
            try restore(model, arena.allocator());
        }
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
    };
}
