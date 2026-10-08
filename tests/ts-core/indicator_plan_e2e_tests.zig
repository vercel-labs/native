//! Complete spinner drawing, anchors and loop arming against native references.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const Harness = sdk.TestHarness();
fn bits(word: u32) f32 {
    return @bitCast(word);
}
const boundary_values = [_]f32{ 0, -0.0, 1, bits(0x3f7fffff), bits(0x3f800001), 0.5, 0.25, 0.75, 0.3125, -0.25, 2, std.math.nan(f32), bits(0x7f812345), std.math.inf(f32), -std.math.inf(f32), bits(1), bits(0x00800000), bits(0x3e800001), bits(0x3f3fffff) };
const frames = [_]sdk.geometry.RectF{ .init(2.5, 3.25, 24.5, 20.75), .init(0, 0, 16, 16), .init(5, 5, -12, -16), .init(1, 1, bits(8), bits(8)), .init(-3.125, 7.75, 300.5, 17.25), .init(0, 0, std.math.nan(f32), 12), .init(0, 0, 0, 10), .init(0, 0, 3.0e38, 3.0e38), .init(1, 2, bits(0x7f812345), 18), .init(1, 2, 18, bits(0x7f812345)), .init(1, 2, bits(0xff812345), bits(0x7f800001)) };
fn compare(widget: c.Widget, tokens: c.DesignTokens, capacity: usize, path_used: usize, retained: bool) !void {
    var compiled = tokens;
    compiled.control_command_policy = core.nativeWindowPolicy;
    var as: [32]c.CanvasCommand = undefined;
    var bs: [32]c.CanvasCommand = undefined;
    var a = c.Builder.init(as[0..capacity]);
    var b = c.Builder.init(bs[0..capacity]);
    a.path_element_len = path_used;
    b.path_element_len = path_used;
    const nodes = [_]c.WidgetLayoutNode{.{ .widget = widget, .frame = widget.frame, .depth = 0 }};
    const tree: c.WidgetLayoutTree = .{ .nodes = &nodes, .root_bounds = .init(-20, -10, 400, 250) };
    const ae: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&a, tokens, .{}) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&a, widget, tokens) catch |err| break :blk err;
        break :blk null;
    };
    const be: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&b, compiled, .{}) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&b, widget, compiled) catch |err| break :blk err;
        break :blk null;
    };
    try std.testing.expectEqual(ae, be);
    try std.testing.expectEqual(a.path_element_len, b.path_element_len);
    try exact(a.displayList().commands, b.displayList().commands);
    core.rt.frameReset();
    try exact(a.displayList().commands, b.displayList().commands);
}
fn spinner(id: u64, frame: sdk.geometry.RectF, value: f32) c.Widget {
    return .{ .id = id, .kind = .spinner, .frame = frame, .value = value };
}
fn styled(style: c.SpinnerStyleToken, reduce: bool) c.DesignTokens {
    var tokens = c.DesignTokens.theme(.{ .pack = .geist, .reduce_motion = reduce });
    tokens.metrics.spinner_style = style;
    return tokens;
}
test "compiled widget metric indicator spinners preserve complete arc and segmented paths across poses" {
    _ = core.initialModel();
    var random = std.Random.DefaultPrng.init(0x5b1e_7a11_0c0d_e051);
    var values: [boundary_values.len + 1536]f32 = undefined;
    @memcpy(values[0..boundary_values.len], &boundary_values);
    for (values[boundary_values.len..], 0..) |*v, i| v.* = if (i % 3 == 0) bits(random.random().int(u32)) else random.random().float(f32);
    for ([_]c.SpinnerStyleToken{ .arc, .segmented }) |style| for ([_]bool{ false, true }) |reduce| for (values) |value| {
        try compare(spinner(0xfedcba9876543210, frames[0], value), styled(style, reduce), 32, 0, false);
    };
    for ([_]c.SpinnerStyleToken{ .arc, .segmented }) |style| for ([_]bool{ false, true }) |reduce| for (frames) |frame| for (boundary_values) |value| for ([_]bool{ false, true }) |retained| {
        try compare(spinner(0x1234, frame, value), styled(style, reduce), 32, 0, retained);
    };
}
test "compiled widget metric indicator spinners preserve tokens appearance identities and capacity prefixes" {
    _ = core.initialModel();
    const ids = [_]u64{ 0, 1, 0x0fff_ffff_ffff_ffff, 0x1000_0000_0000_0000, std.math.maxInt(u64) };
    const counts = [_]u32{ 0, 1, 3, 7, 12, 15, 16, std.math.maxInt(u32) };
    const ratios = [_]f32{ 0.25, 0, -0.5, 2, std.math.nan(f32), bits(1), bits(0x7f812345) };
    const tails = [_]f32{ 0.15, 0, -1, 2, std.math.nan(f32), -0.0, bits(0x7f812345) };
    const strokes = [_]?f32{ null, 0, 3.5, -2, std.math.nan(f32), std.math.inf(f32), bits(0x7f812345) };
    for ([_]bool{ false, true }) |owner| for (ids) |id| for (strokes) |stroke| for ([_]c.SpinnerStyleToken{ .arc, .segmented }) |style| {
        var widget = spinner(id, frames[0], 0.625);
        widget.style.stroke_width = stroke;
        widget.style.foreground = .rgba(0.125, 0.25, 0.5, 0.75);
        widget.state.disabled = stroke == null;
        if (owner) widget.appearance_policy = core.nativeWindowPolicy;
        try compare(widget, styled(style, false), 32, 0, false);
        try compare(widget, styled(style, true), 32, 0, true);
    };
    for (counts) |count| for (ratios, 0..) |ratio, r| for (tails) |tail| for ([_]bool{ false, true }) |reduce| {
        var tokens = styled(.segmented, reduce);
        tokens.metrics.spinner_segment_count = count;
        tokens.metrics.spinner_tail_opacity = tail;
        switch (r % 3) {
            0 => tokens.metrics.spinner_segment_length_ratio = ratio,
            1 => tokens.metrics.spinner_segment_thickness_ratio = ratio,
            else => tokens.metrics.spinner_segment_radius_ratio = ratio,
        }
        try compare(spinner(0xfedcba9876543210, frames[0], 0.8125), tokens, 32, 0, false);
    };
    // Display-list and path-storage exhaustion fail at the same command with
    // the same complete prefix.
    for ([_]c.SpinnerStyleToken{ .arc, .segmented }) |style| for (0..17) |capacity| for ([_]usize{ 0, 4, 37, c.max_chart_path_elements_per_frame - 9, c.max_chart_path_elements_per_frame - 4 }) |used| {
        try compare(spinner(77, frames[0], 0.375), styled(style, true), capacity, used, capacity % 2 == 0);
    };
}
test "compiled widget metric indicator anchors preserve segment counts snapped rotation centers and identities" {
    _ = core.initialModel();
    for ([_]bool{ false, true }) |snap| for ([_]f32{ 1, 2, 1.5, 0, -1, std.math.nan(f32), std.math.inf(f32) }) |scale| for (frames) |frame| for ([_]u32{ 0, 4, 12, 15, 99 }) |count| {
        var tokens = styled(.segmented, false);
        tokens.pixel_snap.geometry = snap;
        tokens.pixel_snap.scale = scale;
        tokens.metrics.spinner_segment_count = count;
        var compiled = tokens;
        compiled.control_command_policy = core.nativeWindowPolicy;
        const widget = spinner(std.math.maxInt(u64) - 3, frame, 0.5);
        try std.testing.expectEqual(c.spinnerWidgetSegmentCount(tokens), c.spinnerWidgetSegmentCount(compiled));
        try exact(c.spinnerWidgetRotationCenter(widget, tokens), c.spinnerWidgetRotationCenter(widget, compiled));
        const anchors = c.indicator_plan_policy.anchors(widget, compiled);
        try std.testing.expectEqual(c.spinnerWidgetSegmentCount(tokens), anchors.count);
        try std.testing.expectEqual(c.spinnerWidgetArcCommandId(widget.id), anchors.arc_id);
        for (0..anchors.count) |i| try std.testing.expectEqual(c.spinnerWidgetSegmentCommandId(widget.id, i), anchors.segment_ids[i]);
        core.rt.frameReset();
    };
}
var quiet_context: u8 = 0;
fn quiet(_: *anyopaque, _: *sdk.Runtime, _: sdk.Event) anyerror!void {}
fn app() sdk.App {
    return .{ .context = &quiet_context, .name = "indicator", .source = sdk.WebViewSource.html("<h1>Indicator</h1>"), .event_fn = quiet };
}
test "compiled widget metric indicator loop arming preserves native rotations opacity phases and commands" {
    defer core.rt.frameReset();
    _ = core.initialModel();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }) |h| {
        h.null_platform.gpu_surfaces = true;
        try h.start(app());
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 400) });
    }
    const children = [_]c.Widget{
        .{ .id = std.math.maxInt(u64), .kind = .spinner, .frame = .init(10.25, 10.75, 20.5, 19.25), .value = 0.125 },
        .{ .id = 0x0fff_ffff_ffff_fff0, .kind = .spinner, .frame = .init(40, 10, 33.5, 33.5), .value = 0.875 },
        .{ .id = 0, .kind = .spinner, .frame = .init(80, 10, 16, 16) },
        .{ .id = 9, .kind = .skeleton, .frame = .init(10, 60, 80, 20) },
    };
    var nodes: [6]c.WidgetLayoutNode = undefined;
    const layout = try c.layoutWidgetTree(.{ .kind = .stack, .children = &children }, .init(0, 0, 320, 400), &nodes);
    for ([_]c.SpinnerStyleToken{ .arc, .segmented, .arc }, 0..) |style, round| for ([_]u32{ 12, 15, 3 }) |count| for ([_]f32{ 1, 1.5 }) |scale| {
        for ([_]*Harness{ a, b }, 0..) |h, lane| {
            var tokens = styled(style, false);
            tokens.metrics.spinner_segment_count = count;
            tokens.pixel_snap.scale = scale;
            if (lane == 1) {
                tokens.widget_motion_policy = core.nativeWindowPolicy;
                tokens.control_command_policy = core.nativeWindowPolicy;
            }
            _ = try h.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
            _ = try h.runtime.setCanvasWidgetLayout(1, "canvas", layout);
            try h.runtime.dispatchPlatformEvent(app(), .{ .gpu_surface_frame = .{ .window_id = 1, .label = "canvas", .size = .init(320, 400), .timestamp_ns = 9_007_199_254_740_993 + round * 1_000_000 } });
            _ = try h.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
        }
        const ra = &a.runtime.views[0];
        const rb = &b.runtime.views[0];
        try exact(ra.canvasRenderAnimations(), rb.canvasRenderAnimations());
        try exact(ra.canvas_widget_loop_animation_ids[0..ra.canvas_widget_loop_animation_count], rb.canvas_widget_loop_animation_ids[0..rb.canvas_widget_loop_animation_count]);
        try exact(ra.canvasDisplayList().commands, rb.canvasDisplayList().commands);
        try std.testing.expectEqual(a.null_platform.gpu_surface_frame_request_count, b.null_platform.gpu_surface_frame_request_count);
        try std.testing.expect(rb.canvas_widget_loop_animation_count > 0);
        core.rt.frameReset();
    };
}
