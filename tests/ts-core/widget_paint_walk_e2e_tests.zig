//! Complete copied schedules, state lanes, command prefixes and ownership
//! against independent native calculations through the production library.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const c = sdk.canvas;
const policy = c.widget_paint_walk_policy;
const exact = @import("component_construction_e2e_tests.zig").exact;
fn node(kind: c.WidgetKind, id: u64, parent: ?usize, depth: usize) c.WidgetLayoutNode {
    return .{ .widget = .{ .kind = kind, .id = id, .frame = .init(5, 5, 80, 30), .text = "Paint traversal" }, .frame = .init(5, 5, 80, 30), .parent_index = parent, .depth = depth };
}
fn compare(layout: c.WidgetLayoutTree, tokens: c.DesignTokens, state: c.WidgetRenderState) !void {
    const plan = try policy.Plan.init(std.testing.allocator, core.nativeWindowPolicy, layout, tokens, state);
    defer plan.deinit();
    try exact(policy.referenceRoot(layout, tokens), plan.firstRoot());
    try exact(policy.referenceSurface(layout, tokens, null), plan.firstSurface());
    try exact(policy.referenceEscaping(layout, 0, state), plan.firstEscaping());
    try exact(policy.referencePreview(layout, state), plan.previewIndex());
    for (layout.nodes, 0..) |_, i| {
        errdefer std.debug.print("paint walk node {d}\n", .{i});
        const expected = policy.referenceFacts(layout, i, tokens, state);
        const actual = plan.facts(i);
        inline for (std.meta.fields(policy.Facts)) |field| {
            if (comptime field.type == policy.Lane) {
                inline for (std.meta.fields(policy.Lane)) |member| {
                    if (comptime member.type == ?c.Affine) {
                        const left = @field(@field(expected, field.name), member.name);
                        const right = @field(@field(actual, field.name), member.name);
                        try exact(left != null, right != null);
                        if (left) |affine| inline for (std.meta.fields(c.Affine)) |entry| {
                            exact(@field(affine, entry.name), @field(right.?, entry.name)) catch |err| {
                                std.debug.print("{s}.{s}.{s}\n", .{ field.name, member.name, entry.name });
                                return err;
                            };
                        };
                        continue;
                    }
                    exact(@field(@field(expected, field.name), member.name), @field(@field(actual, field.name), member.name)) catch |err| {
                        std.debug.print("{s}.{s}\n", .{ field.name, member.name });
                        return err;
                    };
                }
            } else try exact(@field(expected, field.name), @field(actual, field.name));
        }
    }
    const saved = try std.testing.allocator.dupe(u8, plan.result);
    defer std.testing.allocator.free(saved);
    core.rt.frameReset();
    try exact(saved, plan.result);
}
test "compiled widget paint walk preserves all kinds state overrides and preview projection" {
    _ = core.initialModel();
    for (std.enums.values(c.WidgetKind)) |kind| for (0..16) |flags| {
        var nodes = [_]c.WidgetLayoutNode{ node(.input_group, 1, null, 0), node(kind, 0x20000000000001, 0, 1), node(.button, std.math.maxInt(u64), 1, 2), node(.menu_item, 0, null, 0) };
        nodes[1].widget.state.focused = flags & 1 != 0;
        nodes[1].widget.state.hovered = flags & 2 != 0;
        nodes[1].widget.state.pressed = flags & 4 != 0;
        nodes[1].widget.layout.anchor = if (flags & 8 != 0) .{} else null;
        nodes[2].widget.state.focused = true;
        const motions = [_]c.WidgetLayoutMotion{ .{ .id = nodes[1].widget.id, .offset = .{ .dx = -5, .dy = 7 }, .escape_ancestor_clips = flags & 8 != 0 }, .{ .id = nodes[1].widget.id, .offset = .{ .dx = 999, .dy = 999 }, .escape_ancestor_clips = true } };
        const states = [_]c.WidgetRenderState{ .{}, .{ .focused_id = nodes[1].widget.id, .focus_visible_id = nodes[2].widget.id, .hovered_id = 0, .pressed_id = nodes[1].widget.id, .layout_motions = &motions, .drag_preview_id = nodes[1].widget.id }, .{ .keyboard_active = false, .focused_id = 0, .hovered_id = nodes[1].widget.id, .layout_motions = &motions, .rendering_drag_preview = true } };
        for (states) |state| try compare(.{ .nodes = &nodes }, .{}, state);
    };
    try compare(.{}, .{}, .{});
}
test "compiled widget paint walk preserves layer ties full width parents and forward ancestry" {
    _ = core.initialModel();
    var nodes = [_]c.WidgetLayoutNode{ node(.button, 7, 3, 1), node(.tooltip, 2, 3, 1), node(.dialog, 3, null, 0), node(.button_group, 4, 2, 1), node(.button, 5, 3, 2), node(.button, 6, 3, 2) };
    nodes[1].widget.layout.anchor = .{};
    nodes[2].widget.layer = 90;
    nodes[0].widget.layer = std.math.minInt(i32);
    nodes[4].widget.layer = std.math.maxInt(i32);
    nodes[5].widget.semantics.hidden = true;
    var tokens: c.DesignTokens = .{};
    tokens.layer = .{ .base = -20, .overlay = 7, .floating = -100, .modal = 15 };
    for ([_]f32{ -1, 0, 1, std.math.nan(f32) }) |gap| for ([_]@TypeOf(tokens.controls.button_group_style){ .segmented, .detached }) |style| {
        nodes[3].widget.layout.gap = gap;
        tokens.controls.button_group_style = style;
        try compare(.{ .nodes = &nodes }, tokens, .{});
    };
    const parents = [_]?usize{ null, 2, std.math.maxInt(u32), if (@bitSizeOf(usize) > 32) 0x1_00000000 else std.math.maxInt(usize), std.math.maxInt(usize) };
    for (parents) |parent| {
        const detached = [_]c.WidgetLayoutNode{ node(.text, 0, parent, std.math.maxInt(usize)), node(.dialog, std.math.maxInt(u64), parent, 0) };
        try compare(.{ .nodes = &detached }, .{}, .{});
    }
}
test "compiled widget paint walk preserves nested disclosure late surfaces hidden ancestry and first drag match" {
    _ = core.initialModel();
    var nodes = [_]c.WidgetLayoutNode{ node(.accordion, 1, null, 0), node(.accordion, 2, 0, 1), node(.button, 3, 1, 2), node(.tooltip, 4, 1, 2), node(.text, 5, 3, 3), node(.button, 3, 0, 1), node(.dialog, 6, 0, 1) };
    nodes[3].widget.layout.anchor = .{};
    nodes[4].frame.y = 1000;
    const reveals = [_]u64{ 0, 1, 2, std.math.maxInt(u64) };
    const motions = [_]c.WidgetLayoutMotion{ .{ .id = 3, .offset = .{ .dx = 12, .dy = -5 }, .escape_ancestor_clips = true }, .{ .id = 3, .escape_ancestor_clips = false } };
    for (0..32) |flags| {
        nodes[0].widget.state.selected = flags & 1 != 0;
        nodes[1].widget.value = if (flags & 2 != 0) 1 else 0;
        nodes[1].frame.height = if (flags & 4 != 0) 100 else 5;
        nodes[0].frame.height = if (flags & 8 != 0) 150 else 5;
        nodes[1].widget.semantics.hidden = flags & 16 != 0;
        try compare(.{ .nodes = &nodes }, .{}, .{ .revealing_disclosure_ids = &reveals, .layout_motions = &motions, .drag_preview_id = 3 });
    }
}
test "compiled widget paint walk preserves exceptional opacity motion transforms and command identity namespace" {
    _ = core.initialModel();
    var nodes = [_]c.WidgetLayoutNode{ node(.menu_item, 1, null, 0), node(.accordion, 2, null, 0), node(.terminal, 3, null, 0) };
    const words = [_]u32{ 0, 0x80000000, 1, 0x3f000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000, 0x7fc12345, 0xffc12345, 0x7f812345, 0xff812345 };
    const mapped = policy.previewCommandId(2);
    const reveals = [_]u64{ 2, mapped };
    for (words) |word| {
        const value: f32 = @bitCast(word);
        nodes[0].widget.opacity = value;
        nodes[1].widget.value = value;
        const motions = [_]c.WidgetLayoutMotion{.{ .id = 1, .offset = .{ .dx = value, .dy = -value }, .escape_ancestor_clips = true }};
        for ([_]bool{ false, true }) |preview| compare(.{ .nodes = &nodes }, .{}, .{ .rendering_drag_preview = preview, .focused_id = mapped, .focus_visible_id = 3, .revealing_disclosure_ids = &reveals, .layout_motions = &motions }) catch |err| {
            std.debug.print("input word {x} preview {}\n", .{ word, preview });
            return err;
        };
        inline for (.{ "a", "b", "c", "d", "tx", "ty" }) |name| {
            nodes[2].widget.transform = .{};
            @field(nodes[2].widget.transform, name) = value;
            compare(.{ .nodes = &nodes }, .{}, .{}) catch |err| {
                std.debug.print("input word {x} field {s}\n", .{ word, name });
                return err;
            };
        }
    }
}
test "compiled widget paint walk preserves complete draw commands errors and capacity prefixes" {
    _ = core.initialModel();
    var nodes = [_]c.WidgetLayoutNode{ node(.scroll_view, 1, null, 0), node(.button_group, 2, 0, 1), node(.button, 3, 1, 2), node(.button, 4, 1, 2), node(.accordion, 5, 0, 1), node(.text, 6, 4, 2), node(.tooltip, 7, 4, 2), node(.dialog, 8, null, 0), node(.input_group, 9, 7, 1), node(.text_field, 10, 8, 2) };
    nodes[6].widget.layout.anchor = .{};
    nodes[2].widget.opacity = 0.5;
    nodes[3].widget.layer = -1;
    nodes[3].widget.transform = .{ .a = 1, .b = 0.125, .c = -0.25, .d = 0.75, .tx = 5, .ty = -3 };
    const a = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(b);
    var ac: [512]c.CanvasCommand = undefined;
    var bc: [512]c.CanvasCommand = undefined;
    var owned: c.WidgetLayoutTree = .{ .nodes = &nodes };
    owned.paint_walk_policy = core.nativeWindowPolicy;
    const motions = [_]c.WidgetLayoutMotion{.{ .id = 3, .offset = .{ .dx = 12, .dy = -5 }, .escape_ancestor_clips = true }};
    const reveals = [_]u64{5};
    const states = [_]c.WidgetRenderState{ .{}, .{ .revealing_disclosure_ids = &reveals, .focused_id = 10, .focus_visible_id = 10 }, .{ .drag_preview_id = 3, .drag_preview_offset = .{ .dx = 40, .dy = 50 } }, .{ .layout_motions = &motions, .revealing_disclosure_ids = &reveals } };
    for ([_]bool{ false, true }) |singular| {
        if (singular) nodes[3].widget.transform = .{ .a = 0, .d = 0 };
        for (states) |state| for ([_]usize{ 0, 1, 4, 16, 32, 64, 512 }) |capacity| {
            a.* = c.Builder.init(ac[0..capacity]);
            b.* = c.Builder.init(bc[0..capacity]);
            const expected = (c.WidgetLayoutTree{ .nodes = &nodes }).emitDisplayListWithState(a, .{}, state);
            const actual = owned.emitDisplayListWithState(b, .{}, state);
            if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
            try exact(a.commands[0..a.len], b.commands[0..b.len]);
            core.rt.frameReset();
            try exact(a.commands[0..a.len], b.commands[0..b.len]);
        };
    }
}
