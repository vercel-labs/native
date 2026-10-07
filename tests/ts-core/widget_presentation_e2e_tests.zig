//! Complete copied presentation facts and retained commands against the
//! independent native reference through the production scriptc library.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const policy = canvas.widget_presentation_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
const Tree = canvas.WidgetLayoutTree;
const spans = [_]canvas.TextSpan{.{ .text = "Clipped\x00\xff paragraph" }};
fn node(kind: canvas.WidgetKind, id: u64, parent: ?usize, frame: sdk.geometry.RectF) canvas.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .frame = frame, .spans = if (kind == .text) &spans else &.{}, .text = "Clipped paragraph" }, .frame = frame, .parent_index = parent, .depth = 0 };
}
fn compare(layout: Tree, tokens: canvas.DesignTokens, state: canvas.WidgetRenderState) !void {
    const plan = try policy.Plan.init(std.testing.allocator, core.nativeWindowPolicy, layout, tokens, state);
    defer plan.deinit();
    try exact(canvas.widgetLayoutRootBounds(layout), plan.root());
    var owned = layout;
    owned.presentation_policy = core.nativeWindowPolicy;
    try exact(canvas.widgetLayoutRootBounds(layout), canvas.widgetLayoutRootBounds(owned));
    for (layout.nodes, 0..) |_, i| {
        errdefer std.debug.print("presentation node {d}\n", .{i});
        try exact(policy.referenceFacts(layout, i, tokens, state), plan.facts(i));
    }
    const saved = try std.testing.allocator.dupe(u8, plan.result);
    defer std.testing.allocator.free(saved);
    core.rt.frameReset();
    try exact(saved, plan.result);
}
test "compiled widget presentation preserves root presence all kinds and clipped motion ancestry" {
    _ = core.initialModel();
    for (std.enums.values(canvas.WidgetKind)) |kind| for (0..16) |flags| {
        var nodes = [_]canvas.WidgetLayoutNode{
            node(.scroll_view, 1, null, .init(0, 0, 120, 100)),
            node(kind, 0x20000000000001, 0, .init(30, 40, 60, 40)),
            node(.text, std.math.maxInt(u64), 1, .init(20, 30, 80, 70)),
            node(.panel, 4, null, .init(-20, -10, 5, 5)),
        };
        nodes[0].widget.transform = .{ .a = 1, .b = 0.125, .c = -0.25, .d = 0.75, .tx = 5, .ty = -3 };
        nodes[1].widget.layout.clip_content = flags & 1 != 0;
        nodes[1].widget.layout.anchor = if (flags & 2 != 0) .{} else null;
        nodes[3].widget.semantics.hidden = true;
        const motions = [_]canvas.WidgetLayoutMotion{
            .{ .id = nodes[1].widget.id, .offset = .{ .dx = -15.5, .dy = 4.25 }, .escape_ancestor_clips = flags & 4 != 0 },
            .{ .id = nodes[1].widget.id, .offset = .{ .dx = 900, .dy = 900 }, .escape_ancestor_clips = true },
            .{ .id = 1, .offset = .{ .dx = 2, .dy = -3 } },
        };
        const tree: Tree = .{ .nodes = &nodes, .root_bounds = if (flags & 8 != 0) .init(150, 110, -180, -130) else null };
        try compare(tree, .{}, .{});
        try compare(tree, .{}, .{ .layout_motions = &motions });
        try compare(tree, .{}, .{ .layout_motions = &motions, .drag_preview_id = nodes[1].widget.id, .drag_preview_origin = .init(10, 5), .drag_preview_offset = .{ .dx = 32.25, .dy = -14.75 } });
    };
    try compare(.{}, .{}, .{});
}
test "compiled widget presentation preserves full width parents identities and drag presence" {
    _ = core.initialModel();
    const parents = [_]?usize{ null, 0, 3, std.math.maxInt(u32), if (@bitSizeOf(usize) > 32) 0x1_00000000 else std.math.maxInt(usize), std.math.maxInt(usize) };
    for (parents) |parent| for ([_]canvas.WidgetKind{ .text, .dialog }) |kind| {
        const nodes = [_]canvas.WidgetLayoutNode{ node(.scroll_view, 0, null, .init(0, 0, 100, 100)), node(kind, std.math.maxInt(u64), parent, .init(5, 5, 20, 20)) };
        const motions = [_]canvas.WidgetLayoutMotion{ .{ .id = 0, .offset = .{ .dx = 100, .dy = 100 }, .escape_ancestor_clips = true }, .{ .id = std.math.maxInt(u64), .offset = .{ .dx = 4, .dy = 5 } } };
        for ([_]?u64{ null, 0, 0xffffffff, 0x100000000, std.math.maxInt(u64) }) |id| {
            const state: canvas.WidgetRenderState = .{ .layout_motions = &motions, .drag_preview_id = id, .drag_preview_offset = .{ .dx = 2.5, .dy = -3.75 } };
            try compare(.{ .nodes = &nodes }, .{}, state);
            var preview = state;
            preview.rendering_drag_preview = true;
            try compare(.{ .nodes = &nodes }, .{}, preview);
        }
    };
}
test "compiled widget presentation preserves depth boundary singular transforms and exceptional words" {
    _ = core.initialModel();
    var nodes: [34]canvas.WidgetLayoutNode = undefined;
    for (&nodes, 0..) |*n, i| n.* = node(.text, i + 1, if (i == 0) null else i - 1, .init(0, 0, 40, 40));
    try compare(.{ .nodes = &nodes }, .{}, .{});
    nodes[20].widget.layout.anchor = .{};
    try compare(.{ .nodes = &nodes }, .{}, .{});
    const words = [_]u32{ 0, 0x80000000, 1, 0x3f800000, 0x7f800000, 0xff800000, 0x7fc12345 };
    var short = [_]canvas.WidgetLayoutNode{ node(.scroll_view, 1, null, .init(0, 0, 100, 100)), node(.text, 2, 0, .init(2, 3, 40, 40)) };
    for (words) |word| {
        const value: f32 = @bitCast(word);
        inline for (.{ "a", "b", "c", "d", "tx", "ty" }) |name| {
            short[0].widget.transform = .{};
            @field(short[0].widget.transform, name) = value;
            try compare(.{ .nodes = &short }, .{}, .{});
        }
    }
    short[0].widget.transform = .{ .a = 0, .d = 0 };
    try compare(.{ .nodes = &short }, .{}, .{});
}
test "compiled widget presentation preserves snapped span bounds and preview transition commands" {
    _ = core.initialModel();
    const nodes = [_]canvas.WidgetLayoutNode{ node(.scroll_view, 1, null, .init(-0.5, -1.5, 120, 100)), node(.text, 2, 0, .init(-1.5, 20.5, 100.5, 50.5)) };
    for ([_]f32{ 0, -1, 1, 1.25, 2, std.math.inf(f32), std.math.nan(f32) }) |scale| {
        var tokens: canvas.DesignTokens = .{};
        tokens.pixel_snap.geometry = true;
        tokens.pixel_snap.scale = scale;
        try compare(.{ .nodes = &nodes }, tokens, .{});
    }
    const a = try std.testing.allocator.create(canvas.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(canvas.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [256]canvas.CanvasCommand = undefined;
    var bc: [256]canvas.CanvasCommand = undefined;
    var owned: Tree = .{ .nodes = &nodes };
    owned.presentation_policy = core.nativeWindowPolicy;
    const motions = [_]canvas.WidgetLayoutMotion{.{ .id = 2, .offset = .{ .dx = 12, .dy = -15 }, .escape_ancestor_clips = true }};
    const states = [_]canvas.WidgetRenderState{ .{}, .{ .drag_preview_id = 2, .drag_preview_origin = .init(5, 4), .drag_preview_offset = .{ .dx = 40, .dy = 50 } }, .{ .layout_motions = &motions } };
    for (states) |state| for ([_]usize{ 0, 1, 4, 16, 256 }) |capacity| {
        a.* = canvas.Builder.init(ac[0..capacity]);
        b.* = canvas.Builder.init(bc[0..capacity]);
        const expected = (Tree{ .nodes = &nodes }).emitDisplayListWithState(a, .{}, state);
        const actual = owned.emitDisplayListWithState(b, .{}, state);
        if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
        core.rt.frameReset();
        try exact(a.commands[0..a.len], b.commands[0..b.len]);
    };
}
