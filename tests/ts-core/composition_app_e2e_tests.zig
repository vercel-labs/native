//! Actual generated helpers, the production decoder, and retained ownership.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("composition_core");
const decoder = @import("composition_decoder");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("composition_fixture.native"));

fn restore(model: *const core.Model, arena: std.mem.Allocator) !void {
    // The native mirror is read-only. Install test states through the actual
    // tagged persistence ABI so the generated helpers see committed state.
    const texts = [_][]const u8{ model.label, model.description, model.meta, model.indicator };
    var size: usize = 4 + 16 + 9;
    for (texts) |text| size += 12 + text.len;
    const snapshot = try arena.alloc(u8, size);
    std.mem.writeInt(u32, snapshot[0..4], 6, .little);
    std.mem.writeInt(u32, snapshot[4..8], 0, .little);
    std.mem.writeInt(u32, snapshot[8..12], 8, .little);
    std.mem.writeInt(i64, snapshot[12..20], model.active, .little);
    var at: usize = 20;
    for (texts, 1..) |text, index| {
        std.mem.writeInt(u32, snapshot[at..][0..4], @intCast(index), .little);
        std.mem.writeInt(u32, snapshot[at + 4 ..][0..4], @intCast(4 + text.len), .little);
        std.mem.writeInt(u32, snapshot[at + 8 ..][0..4], @intCast(text.len), .little);
        @memcpy(snapshot[at + 12 ..][0..text.len], text);
        at += 12 + text.len;
    }
    std.mem.writeInt(u32, snapshot[at..][0..4], 5, .little);
    std.mem.writeInt(u32, snapshot[at + 4 ..][0..4], 1, .little);
    snapshot[at + 8] = @intFromBool(model.selected);
    try parity.equal(model.*, core.restoreModel(snapshot).*);
}

fn owners(widget: canvas.Widget) !void {
    try std.testing.expect(widget.appearance_policy == core.nativeWindowPolicy);
    if (widget.kind == .input_group or widget.kind == .row or widget.kind == .column or widget.kind == .stack or widget.kind == .textarea)
        try std.testing.expect(widget.interaction_policy == core.nativeTextPolicy);
    for (widget.children) |child| try owners(child);
}

test "compiled app composition preserves whole generated trees geometry handlers and raw bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_][]const u8{ "Draft café", "A\x00\xff\xc0B", "" }) |label| {
        for ([_]i64{ -1, 0, 1, 2, 3, 9007199254740991 }) |active| {
            for ([_]bool{ false, true }) |present| {
                const model = core.Model{ .active = active, .label = label,
                    .description = if (present) "Preview\x00\xff" else "",
                    .meta = if (present) "meta\x00\xc0" else "",
                    .indicator = if (present) "\x00\xff" else "", .selected = present };
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                try restore(&model, arena.allocator());
                var reference = Ui.init(arena.allocator());
                var compiled = Ui.init(arena.allocator());
                const expected = try reference.finalize(View.build(&reference, &model));
                const root = decoder.build(&compiled, &model);
                core.rt.frameReset();
                const actual = try compiled.finalize(root);
                try parity.equal(expected.root, actual.root);
                try parity.equal(expected.handlers, actual.handlers);
                try owners(actual.root);
                var before: [128]canvas.WidgetLayoutNode = undefined;
                var after: [128]canvas.WidgetLayoutNode = undefined;
                for ([_]f32{ 240, 720 }) |width| try parity.equal(
                    try canvas.layoutWidgetTree(expected.root, .init(0, 0, width, 480), &before),
                    try canvas.layoutWidgetTree(actual.root, .init(0, 0, width, 480), &after));
                // A later recipe call cannot overwrite the native copied tree.
                var request: [64]u8 = @splat(0);
                request[0] = 19;
                var result: [128]u8 = undefined;
                try std.testing.expectEqual(@as(usize, 128), core.nativeWindowPolicy(&request, &result));
                core.rt.frameReset();
                try parity.equal(expected.root, actual.root);
            }
        }
    }
}
