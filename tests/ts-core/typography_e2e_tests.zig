const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("typography_core");
const decoder = @import("typography_decoder");
const canvas = sdk.canvas;
const Adapter = sdk.TsUiApp(core);

fn view(ui: *canvas.Ui(core.Msg), model: *const core.Model) canvas.Ui(core.Msg).Node {
    return decoder.build(ui, model);
}

fn expected(model: *const core.Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{});
    tokens.typography.mono_font_id = 64;
    tokens.typography.display_size = if (model.large) 42 else 32;
    tokens.radius.sm = 7;
    tokens.radius.md = 10;
    const accent = canvas.Color{ .r = if (model.accent) 0.125 else 0.3, .g = 0.25, .b = 0.9, .a = 1 };
    tokens.colors.accent = accent;
    tokens.controls.button_primary.active_background = accent;
    return tokens;
}

test "compiled model themes copy the complete register across frame and commit ownership" {
    const app = try Adapter.create(std.testing.allocator, .{}, .{ .name = "typography", .scene = .{}, .canvas_label = "canvas", .view = view });
    defer app.destroy();
    for (0..32) |index| {
        const snapshot = app.effectiveTokens();
        var reference = expected(&app.model);
        reference.surface_layout_policy = snapshot.surface_layout_policy;
        reference.grid_layout_policy = snapshot.grid_layout_policy;
        reference.container_layout_policy = snapshot.container_layout_policy;
        reference.intrinsic_layout_policy = snapshot.intrinsic_layout_policy;
        reference.widget_motion_policy = core.nativeWindowPolicy;
        reference.widget_audit_policy = core.nativeWindowPolicy;
        reference.widget_routing_policy = core.nativeWindowPolicy;
        reference.widget_change_policy = core.nativeWindowPolicy;
        reference.widget_paint_policy = core.nativeWindowPolicy;
        reference.widget_presentation_policy = core.nativeWindowPolicy;
        reference.code_content_policy = core.nativeWindowPolicy;
        try std.testing.expectEqualDeep(reference, snapshot);
        const large = app.model.large;
        core.rt.frameReset();
        app.model = core.update(&app.model, if (index % 2 == 0) .size else .accent).*;
        core.rt.frameReset();
        try std.testing.expectEqual(@as(f32, if (large) 42 else 32), snapshot.typography.display_size);
    }
}

test "compiled rich text preserves registered face runs and alignment after decoding bytes expire" {
    const model = core.initialModel();
    defer core.rt.frameReset();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = canvas.Ui(core.Msg).init(arena.allocator());
    const root = decoder.build(&ui, model);
    core.rt.frameReset();
    const tokens = expected(model);
    const tree = try ui.finalizeWithTokens(root, tokens);
    try std.testing.expectEqualStrings("Regular type", tree.root.children[0].text);
    try std.testing.expectEqual(.medium, tree.root.children[0].spans[0].weight);
    try std.testing.expect(tree.root.children[0].spans[0].monospace);
    try std.testing.expectEqual(.end, tree.root.children[2].text_alignment);
    try std.testing.expectEqualStrings("1234567890", tree.root.children[2].spans[0].text);
    const mixed = tree.root.children[1];
    try std.testing.expectEqualStrings("A single paragraph with mixed styles and registered mono.", mixed.text);
    try std.testing.expectEqual(@as(usize, 12), mixed.spans.len);
    try std.testing.expectEqual(.bold, mixed.spans[2].weight);
    try std.testing.expect(mixed.spans[6].italic);
    try std.testing.expectEqual(.accent, mixed.spans[6].color.?);
    try std.testing.expect(mixed.spans[10].monospace);
    try std.testing.expectEqual(@as(u64, 64), tokens.typography.mono_font_id);
    try std.testing.expectEqual(.end, tree.root.children[2].text_alignment);
}

fn forcedDark(_: *const core.Model) Adapter.App.ThemeState {
    return .{ .color_scheme = .dark };
}
fn completeTokens(_: *const core.Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = .dark });
    tokens.typography.display_size = 71;
    return tokens;
}
fn restamp(reference: *canvas.DesignTokens, actual: canvas.DesignTokens) void {
    reference.pixel_snap.scale = actual.pixel_snap.scale;
    reference.surface_layout_policy = actual.surface_layout_policy;
    reference.grid_layout_policy = actual.grid_layout_policy;
    reference.container_layout_policy = actual.container_layout_policy;
    reference.intrinsic_layout_policy = actual.intrinsic_layout_policy;
    reference.widget_motion_policy = core.nativeWindowPolicy;
    reference.widget_audit_policy = core.nativeWindowPolicy;
    reference.widget_routing_policy = core.nativeWindowPolicy;
    reference.widget_change_policy = core.nativeWindowPolicy;
    reference.widget_paint_policy = core.nativeWindowPolicy;
    reference.widget_presentation_policy = core.nativeWindowPolicy;
    reference.code_content_policy = core.nativeWindowPolicy;
}
test "compiled themes retain forced scheme, accessibility and complete-register precedence" {
    const app = try Adapter.create(std.testing.allocator, .{}, .{ .name = "theme-coordination", .scene = .{}, .canvas_label = "canvas", .view = view, .theme_state_fn = forcedDark });
    defer app.destroy();
    app.pixel_snap_scale = 2;
    for (0..4) |index| {
        app.system_appearance.high_contrast = index & 1 != 0;
        app.system_appearance.reduce_motion = index & 2 != 0;
        const actual = app.effectiveTokens();
        var reference = canvas.DesignTokens.theme(.{ .color_scheme = .dark, .contrast = if (app.system_appearance.high_contrast) .high else .standard, .reduce_motion = app.system_appearance.reduce_motion });
        const custom = expected(&app.model);
        reference.typography.mono_font_id = custom.typography.mono_font_id;
        reference.typography.display_size = custom.typography.display_size;
        reference.radius.sm = custom.radius.sm;
        reference.radius.md = custom.radius.md;
        reference.colors.accent = custom.colors.accent;
        reference.controls.button_primary.active_background = custom.controls.button_primary.active_background;
        restamp(&reference, actual);
        try std.testing.expectEqual(@as(f32, 2), actual.pixel_snap.scale);
        try std.testing.expectEqualDeep(reference, actual);
    }
    app.options.tokens = completeTokens(&app.model);
    var reference = app.options.tokens.?;
    restamp(&reference, app.effectiveTokens());
    try std.testing.expectEqualDeep(reference, app.effectiveTokens());
    app.options.tokens_fn = completeTokens;
    app.options.tokens.?.typography.display_size = 99;
    reference = completeTokens(&app.model);
    restamp(&reference, app.effectiveTokens());
    try std.testing.expectEqualDeep(reference, app.effectiveTokens());
}

test "compiled theme control retains five-byte ABI and validates the optional overrides flag" {
    defer core.rt.frameReset();
    for (0..2) |function| for (0..2) |fixed| for (0..2) |helper| for (0..3) |scheme| {
        const follows = function == 0 and fixed == 0 and (helper == 0 or scheme == 0);
        const derives = function != 0 or helper != 0 or follows;
        var result: [4]u8 = undefined;
        const legacy = [_]u8{ 2, @intCast(function), @intCast(fixed), @intCast(helper), @intCast(scheme) };
        const reference = [_]u8{ if (function != 0) 1 else if (fixed != 0) 2 else 0, @intFromBool(follows), @intFromBool(derives), 0 };
        try std.testing.expectEqual(result.len, core.nativeThemePolicy(&legacy, &result));
        try std.testing.expectEqualSlices(u8, &reference, &result);
        core.rt.frameReset();
        for (0..2) |overrides| {
            const request = [_]u8{ 2, @intCast(function), @intCast(fixed), @intCast(helper), @intCast(scheme), @intCast(overrides) };
            var expected_result = reference;
            expected_result[2] = @intFromBool(derives or overrides != 0);
            try std.testing.expectEqual(result.len, core.nativeThemePolicy(&request, &result));
            try std.testing.expectEqualSlices(u8, &expected_result, &result);
            core.rt.frameReset();
        }
    };
}
