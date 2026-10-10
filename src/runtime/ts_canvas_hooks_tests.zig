const std = @import("std");
const testing = std.testing;
const canvas = @import("canvas");
const hooks = @import("ts_canvas_hooks.zig");
const Scratch = @import("view_canvas.zig").CanvasDisplayListScratch;

const Color = struct { r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 1 };
const Point = struct { x: f64 = 0, y: f64 = 0 };
const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 10, height: f64 = 10 };
const Stop = struct { offset: f64, color: Color = .{} };
const Fill = union(enum) { color: Color, linear_gradient: struct { start: Point = .{}, end: Point = .{}, stops: []const Stop } };
const Command = union(enum) {
    rect: struct { id: []const u8 = "1", rect: Rect = .{}, fill: Fill = .{ .color = .{} } },
    rounded_rect: struct { id: []const u8 = "1", rect: Rect = .{}, radius: f64 = 1, fill: Fill = .{ .color = .{} } },
};
const Context = struct { width: f64, height: f64, background: Color, surface: Color, border: Color };
const Transform = struct { a: f64 = 1, b: f64 = 0, c: f64 = 0, d: f64 = 1, tx: f64 = 0, ty: f64 = 0 };
const Animation = struct {
    label: []const u8 = "target", index: f64 = 0,
    part: enum { fill, text } = .fill, durationMs: f64 = 900,
    easing: canvas.Easing = .linear, loop: canvas.CanvasRenderAnimationLoop = .none,
    fromOpacity: f64 = 1, toOpacity: f64 = 1, fromTransform: Transform = .{}, toTransform: Transform = .{},
};
const Core = struct {
    pub const Msg = union(enum) { noop };
    pub const rt = struct { pub fn frameAllocator() std.mem.Allocator { return testing.allocator; } };
    pub const Model = struct {
        commands: []const Command = &.{}, declarations: []const Animation = &.{},
        pub fn canvasChrome(self: *const Model, _: Context) []const Command { return self.commands; }
        pub fn canvasAnimations(self: *const Model) []const Animation { return self.declarations; }
    };
};
const App = struct { pub const Ui = canvas.Ui(Core.Msg); };
const H = hooks.Hooks(Core, Core.Model, App);

fn chrome(commands: []const Command, builder: *canvas.Builder) !void {
    try H.chrome(&.{ .commands = commands }, builder, .init(400, 300), .{});
}

test "TypeScript canvas chrome validates exact identities and bounds before native submission" {
    var output: [65]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    try chrome(&.{.{ .rect = .{ .id = "18446744073709551615" } }}, &builder);
    try testing.expectEqual(std.math.maxInt(u64), builder.displayList().commands[0].fill_rect.id);
    for ([_][]const u8{ "", "01", "-1", "1x", "18446744073709551616", "184467440737095516150" }) |id| {
        builder = canvas.Builder.init(&output);
        try testing.expectError(error.InvalidCanvasId, chrome(&.{.{ .rect = .{ .id = id } }}, &builder));
    }
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.DuplicateCanvasChromeId, chrome(&.{ .{ .rect = .{} }, .{ .rounded_rect = .{} } }, &builder));
    var many: [65]Command = @splat(.{ .rect = .{} });
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.CanvasChromeCommandLimit, chrome(&many, &builder));
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), std.math.floatMax(f64) }) |value| {
        builder = canvas.Builder.init(&output);
        try testing.expectError(error.InvalidCanvasScalar, chrome(&.{.{ .rect = .{ .rect = .{ .x = value } } }}, &builder));
    }
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasGeometry, chrome(&.{.{ .rect = .{ .rect = .{ .width = -1 } } }}, &builder));
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasColor, chrome(&.{.{ .rect = .{ .fill = .{ .color = .{ .r = 1.01 } } } }}, &builder));
    builder = canvas.Builder.init(&output);
    try testing.expectError(error.InvalidCanvasRadius, chrome(&.{.{ .rounded_rect = .{ .radius = -1 } }}, &builder));
}

test "TypeScript canvas gradients outlive helper input and native copies outlive subsequent declarations" {
    var stops = [_]Stop{ .{ .offset = 0, .color = .{ .r = 0.25 } }, .{ .offset = 1 } };
    var commands = [_]Command{.{ .rect = .{ .fill = .{ .linear_gradient = .{ .stops = &stops } } } }};
    var output: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&output);
    try chrome(&commands, &builder);
    stops[0].color.r = 0.75;
    try testing.expectEqual(@as(f32, 0.25), builder.displayList().commands[0].fill_rect.fill.linear_gradient.stops[0].color.r);
    const scratch = try testing.allocator.create(Scratch);
    defer testing.allocator.destroy(scratch);
    scratch.* = .{};
    const owned = try scratch.copyCanvasCommand(builder.displayList().commands[0]);
    builder = canvas.Builder.init(&output);
    try chrome(&commands, &builder);
    try testing.expectEqual(@as(f32, 0.25), owned.fill_rect.fill.linear_gradient.stops[0].color.r);
    try testing.expectEqual(@as(f32, 0.75), builder.displayList().commands[0].fill_rect.fill.linear_gradient.stops[0].color.r);
    stops[0].offset = 1.1;
    try testing.expectError(error.InvalidCanvasGradientOffset, chrome(&commands, &builder));
    var many: [17]Stop = @splat(.{ .offset = 0 });
    commands[0].rect.fill.linear_gradient.stops = &many;
    try testing.expectError(error.CanvasGradientStopLimit, chrome(&commands, &builder));
}

test "TypeScript canvas animations retain widget identities and exact clocks and reject invalid batches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = App.Ui.init(arena.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{ ui.text(.{ .semantics = .{ .label = "target" } }, "first"), ui.text(.{ .semantics = .{ .label = "target" } }, "second") }));
    var declarations = [_]Animation{ .{}, .{ .index = 1, .part = .text } };
    var model = Core.Model{ .declarations = &declarations };
    var out: [4]canvas.CanvasRenderAnimation = undefined;
    try testing.expectEqual(@as(usize, 2), H.animations(&model, &tree, std.math.maxInt(u64), &out));
    try testing.expectEqual(std.math.maxInt(u64), out[0].start_ns);
    try testing.expectEqual(canvas.widgetCommandPartId(.{ .widget_id = tree.root.children[1].id, .slot = 4 }), out[1].id);
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, out[0..1]));
    declarations[1] = declarations[0];
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    model.declarations = declarations[0..1];
    for ([_]f64{ -1, 0.5, 4294967296, std.math.nan(f64) }) |invalid| {
        declarations[0].index = invalid;
        try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
        declarations[0].index = 0;
        declarations[0].durationMs = invalid;
        try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
        declarations[0].durationMs = 900;
    }
    declarations[0].fromOpacity = 1.1;
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    declarations[0].fromOpacity = 1;
    declarations[0].toTransform.tx = std.math.inf(f64);
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
    declarations[0].toTransform.tx = 0;
    declarations[0].index = 2;
    try testing.expectEqual(@as(usize, 0), H.animations(&model, &tree, 0, &out));
}

test "TypeScript canvas markup surfaces preserve bound blur grids anchors and dismissal in both native engines" {
    const Model = struct { blur: enum { none, sm, md } = .md };
    const Msg = union(enum) { dismiss };
    const Ui = canvas.Ui(Msg);
    const source =
        \\<column>
        \\  <stack>
        \\    <text>Trigger</text>
        \\    <popover anchor="below" backdrop-blur="{blur}" on-dismiss="dismiss">
        \\      <menu-surface on-dismiss="dismiss"><menu-item on-press="dismiss">Open</menu-item></menu-surface>
        \\    </popover>
        \\  </stack>
        \\  <data-grid text="Rows"><table-row><table-cell>Cell</table-cell></table-row></data-grid>
        \\</column>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interpreted = try canvas.MarkupView(Model, Msg).init(arena.allocator(), source);
    const Compiled = canvas.CompiledMarkupView(Model, Msg, source);
    for ([_]@FieldType(Model, "blur"){ .none, .sm, .md }) |blur| {
        const model = Model{ .blur = blur };
        var left = Ui.init(arena.allocator());
        var right = Ui.init(arena.allocator());
        const a = try left.finalize(try interpreted.build(&left, &model));
        const b = try right.finalize(Compiled.build(&right, &model));
        try testing.expectEqualDeep(a.root, b.root);
        const popup = b.root.children[0].children[1];
        try testing.expectEqual(canvas.WidgetKind.popover, popup.kind);
        try testing.expectEqual(canvas.WidgetAnchorPlacement.below, popup.layout.anchor.?.placement);
        try testing.expectEqual(Msg.dismiss, b.msgForDismiss(popup.id).?);
        try testing.expectEqual(canvas.WidgetKind.menu_surface, popup.children[0].kind);
        try testing.expectEqual(Msg.dismiss, b.msgForDismiss(popup.children[0].id).?);
        try testing.expectEqual(canvas.WidgetKind.data_grid, b.root.children[1].kind);
    }
    for ([_][]const u8{ "<popover backdrop-blur=\"lg\" />", "<popover backdrop-blur=\"3\" />" }) |invalid| {
        var view = try canvas.MarkupView(Model, Msg).init(arena.allocator(), invalid);
        var ui = Ui.init(arena.allocator());
        try testing.expectError(error.MarkupBuild, view.build(&ui, &.{}));
    }
}
