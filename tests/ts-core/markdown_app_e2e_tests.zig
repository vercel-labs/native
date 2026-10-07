//! Generated Markdown recipes, typed routes, effects and owned snapshots.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("markdown_core");
const decoder = @import("markdown_decoder");
const wire = @import("corewire_rt");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const Md = canvas.markdown.Markdown(core.Msg);

fn details(ordinal: usize) core.Msg {
    return .{ .toggle_details = @intCast(ordinal) };
}
fn models(expected: core.Model, actual: core.Model, arena: std.mem.Allocator) !void {
    // Object-array records are independently owned in the decoded mirror.
    // Compare every serialized value rather than their allocation addresses.
    try std.testing.expectEqualSlices(u8, wire.encodeAlloc(core.Model, expected, arena), wire.encodeAlloc(core.Model, actual, arena));
}
fn restore(model: core.Model, arena: std.mem.Allocator) !void {
    var writer = std.Io.Writer.Allocating.init(arena);
    try writer.writer.writeInt(u32, @typeInfo(core.Model).@"struct".fields.len, .little);
    inline for (@typeInfo(core.Model).@"struct".fields, 0..) |field, index| {
        const bytes = wire.encodeAlloc(field.type, @field(model, field.name), arena);
        try writer.writer.writeInt(u32, index, .little);
        try writer.writer.writeInt(u32, @intCast(bytes.len), .little);
        try writer.writer.writeAll(bytes);
    }
    try models(model, core.restoreModel(writer.written()).*, arena);
}
fn reference(ui: *Ui, model: core.Model) Ui.Node {
    const images = ui.arena.alloc(canvas.markdown.ResolvedImage, model.images.len) catch unreachable;
    for (model.images, images) |image, *mapping| mapping.* = .{ .source = image.source, .image = @intFromFloat(parity.number(image.image)), .width = @floatCast(parity.number(image.width)), .height = @floatCast(parity.number(image.height)) };
    return ui.column(.{ .gap = 8 }, .{
        Md.view(ui, model.body, .{ .on_link = Ui.linkMsg(.open_url), .on_details = details, .details_expanded = model.expanded, .issue_link_base = model.issue, .images = images }),
        Md.view(ui, model.body, .{ .issue_link_base = "literal://" }),
    });
}
fn routes(widget: canvas.Widget, expected: Ui.Tree, actual: Ui.Tree) !void {
    try parity.equal(expected.msgForPointer(widget.id, .up), actual.msgForPointer(widget.id, .up));
    for (widget.children) |child| try routes(child, expected, actual);
}

test "compiled app Markdown preserves complete generated trees geometry handlers effects and snapshots" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const images = [_]core.ResolvedImage{
        .{ .source = "asset", .image = 0, .width = 10, .height = 10 },
        .{ .source = "asset", .image = 4294967297, .width = 240.25, .height = 120.125 },
    };
    const image_refs = [_]*const core.ResolvedImage{ &images[0], &images[1] };
    const corpus = [_][]const u8{ "", "# Title\n**bold** [go](target) #123", "A\x00\xff\xc0B <a href='u\x00\xff'>link</a>", "| Name | Value |\n| :--- | ---: |\n| **one** | two |\n\n- [x] done\n  - nested\n\n```ts\nconst café = 1;\n```", "<details>\n<summary>More [go](url)</summary>\nbody\n<details>\n<summary>Inner</summary>\ninside\n</details>\n</details>", "<a href='image-url'><img src='asset' alt='Image&#33;' width='64'></a> suffix" };
    for (corpus) |source| for ([_]bool{ false, true }) |expanded| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const flags = [_]bool{ expanded, !expanded };
        const model: core.Model = .{ .body = source, .issue = "issue://\x00\xff/", .expanded = &flags, .images = &image_refs, .lastLink = "previous\x00\xff" };
        try restore(model, arena.allocator());
        var before_ui = Ui.init(arena.allocator());
        var after_ui = Ui.init(arena.allocator());
        const expected = try before_ui.finalize(reference(&before_ui, model));
        const root = decoder.build(&after_ui, &model);
        core.rt.frameReset();
        const actual = try after_ui.finalize(root);
        try parity.equal(expected, actual);
        try routes(expected.root, expected, actual);
        var before: [4096]canvas.WidgetLayoutNode = undefined;
        var after: [4096]canvas.WidgetLayoutNode = undefined;
        for ([_]f32{ 180, 320, 720 }) |width| try parity.equal(try canvas.layoutWidgetTree(expected.root, .init(0, 0, width, 600), &before), try canvas.layoutWidgetTree(actual.root, .init(0, 0, width, 600), &after));
        const link = "effect\x00\xff";
        const next = core.update(&model, .{ .open_url = link });
        try models(core.Model{ .body = model.body, .issue = model.issue, .expanded = model.expanded, .images = model.images, .lastLink = link }, next.model.*, arena.allocator());
        try std.testing.expectEqualSlices(u8, &.{1}, next.cmd);
        const durable = try arena.allocator().dupe(u8, core.persistenceSnapshot());
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, link, core.restoreModel(durable).lastLink);
        const toggled = core.update(&model, .{ .toggle_details = 0 });
        try std.testing.expectEqual(!expanded, toggled.model.expanded[0]);
        try std.testing.expectEqual(!expanded, toggled.model.expanded[1]);
        try std.testing.expectEqualSlices(u8, &.{1}, toggled.cmd);
        core.rt.frameReset();
        try parity.equal(expected, actual);
    };
}
