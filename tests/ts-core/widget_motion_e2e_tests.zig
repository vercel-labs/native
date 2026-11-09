//! Motion through the shipped compiled library and the independent native
//! runtime paths, with complete retained geometry, semantics and commands.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const geometry = sdk.geometry;
const Harness = sdk.TestHarness();
var quiet_context: u8 = 0;
fn quiet(_: *anyopaque, _: *sdk.Runtime, _: sdk.Event) anyerror!void {}
fn app() sdk.App {
    return .{ .context = &quiet_context, .name = "motion", .source = sdk.WebViewSource.html("<h1>Motion</h1>"), .event_fn = quiet };
}
const Pair = struct {
    reference: *Harness,
    compiled: *Harness,
    fn init() !Pair {
        const a = try Harness.create(std.testing.allocator, .{});
        errdefer a.destroy(std.testing.allocator);
        const b = try Harness.create(std.testing.allocator, .{});
        errdefer b.destroy(std.testing.allocator);
        for ([_]*Harness{ a, b }) |h| {
            h.null_platform.gpu_surfaces = true;
            try h.start(app());
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 400) });
        }
        b.runtime.views[0].widget_tokens.widget_motion_policy = core.nativeWindowPolicy;
        return .{ .reference = a, .compiled = b };
    }
    fn deinit(self: Pair) void {
        self.reference.destroy(std.testing.allocator);
        self.compiled.destroy(std.testing.allocator);
    }
    fn frame(self: Pair, stamp: u64) !void {
        for ([_]*Harness{ self.reference, self.compiled }) |h| try h.runtime.dispatchPlatformEvent(app(), .{ .gpu_surface_frame = .{ .window_id = 1, .label = "canvas", .size = .init(320, 400), .timestamp_ns = stamp } });
        try self.compare();
    }
    fn compare(self: Pair) !void {
        const a = &self.reference.runtime.views[0];
        const b = &self.compiled.runtime.views[0];
        try std.testing.expectEqualDeep(a.widgetLayoutTree(), b.widgetLayoutTree());
        try std.testing.expectEqualDeep(a.widgetSemantics(), b.widgetSemantics());
        try std.testing.expectEqualDeep(a.canvasRenderAnimations(), b.canvasRenderAnimations());
        try std.testing.expectEqualDeep(a.canvas_widget_layout_tweens[0..a.canvas_widget_layout_tween_count], b.canvas_widget_layout_tweens[0..b.canvas_widget_layout_tween_count]);
        const ad = a.canvas_widget_disclosure_tween;
        const bd = b.canvas_widget_disclosure_tween;
        try std.testing.expectEqual(ad.active, bd.active);
        try std.testing.expectEqual(ad.start_ns, bd.start_ns);
        try std.testing.expectEqual(ad.duration_ms, bd.duration_ms);
        try std.testing.expectEqual(ad.progress, bd.progress);
        try std.testing.expectEqualDeep(ad.moves[0..ad.move_count], bd.moves[0..bd.move_count]);
        try std.testing.expectEqualDeep(ad.revealing_ids[0..ad.revealing_id_count], bd.revealing_ids[0..bd.revealing_id_count]);
        try std.testing.expectEqualDeep(a.canvas_widget_drag_layout_motions[0..a.canvas_widget_drag_layout_motion_count], b.canvas_widget_drag_layout_motions[0..b.canvas_widget_drag_layout_motion_count]);
        try std.testing.expectEqualDeep(a.canvas_widget_loop_animation_ids[0..a.canvas_widget_loop_animation_count], b.canvas_widget_loop_animation_ids[0..b.canvas_widget_loop_animation_count]);
        try std.testing.expectEqual(a.canvas_widget_caret_blink_id, b.canvas_widget_caret_blink_id);
        try std.testing.expectEqualDeep(a.canvasDisplayList().commands, b.canvasDisplayList().commands);
        try std.testing.expectEqual(self.reference.null_platform.gpu_surface_frame_request_count, self.compiled.null_platform.gpu_surface_frame_request_count);
        try std.testing.expectEqual(a.widget_revision, b.widget_revision);
    }
    fn install(self: Pair, layout: canvas.WidgetLayoutTree) !void {
        for ([_]*Harness{ self.reference, self.compiled }) |h| {
            _ = try h.runtime.setCanvasWidgetLayout(1, "canvas", layout);
            _ = try h.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
        }
        try self.compare();
    }
};
const Msg = union(enum) { toggle, press };
const Ui = canvas.Ui(Msg);
fn split(allocator: std.mem.Allocator, value: f32, duration: u32) !canvas.WidgetLayoutTree {
    var ui = Ui.init(allocator);
    const tree = try ui.finalize(ui.el(.split, .{ .value = value, .resize_duration = duration }, .{ ui.text(.{}, "First"), ui.text(.{}, "Second") }));
    return canvas.layoutWidgetTree(tree.root, .init(0, 0, 320, 400), try allocator.alloc(canvas.WidgetLayoutNode, 8));
}
fn disclosure(allocator: std.mem.Allocator, open: bool) !canvas.WidgetLayoutTree {
    var ui = Ui.init(allocator);
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.text(.{}, "Before"),
        ui.el(.accordion, .{ .text = "Section", .selected = open, .on_toggle = .toggle }, .{ ui.text(.{}, "Revealed body"), ui.button(.{ .on_press = .press }, "Inside") }),
        ui.text(.{}, "After"),
    }));
    return canvas.layoutWidgetTree(tree.root, .init(0, 0, 320, 400), try allocator.alloc(canvas.WidgetLayoutNode, 32));
}
test "compiled widget motion split admission retarget settle and reduced motion preserve complete runtime state" {
    defer core.rt.frameReset();
    const pair = try Pair.init();
    defer pair.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const layout = try split(arena.allocator(), 0.5, 0);
    const id = layout.nodes[0].widget.id;
    try pair.install(layout);
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| {
        try std.testing.expectError(error.InvalidCommand, h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = 0, .to = 0.25 }));
        _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = id, .to = 0.25, .duration_ms = 160, .easing = .linear });
    }
    try pair.compare();
    const start = 9_007_199_254_740_993;
    try pair.frame(start);
    try pair.frame(start + 80_000_000);
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| {
        _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = id, .to = 0.25, .duration_ms = 160 });
        _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = id, .to = 0.75, .duration_ms = 160, .easing = .linear });
    }
    try pair.compare();
    try pair.frame(start - 1);
    try pair.frame(start + 160_000_000);
    try pair.frame(start + 170_000_000);
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| {
        _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = id, .to = 0.3 });
        h.runtime.appearance.reduce_motion = true;
        _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = id, .to = 0.3 });
    }
    try pair.compare();
}
test "compiled widget motion source declarations and disclosure refresh preserve complete adoption and frame state" {
    defer core.rt.frameReset();
    const pair = try Pair.init();
    defer pair.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try pair.install(try split(arena.allocator(), 0.5, 160));
    try pair.install(try split(arena.allocator(), 0.25, 160));
    try pair.frame(1_000_000_000);
    try pair.frame(1_080_000_000);
    try pair.install(try split(arena.allocator(), 0.25, 160));
    try pair.frame(1_200_000_000);
    try pair.install(try disclosure(arena.allocator(), false));
    try pair.install(try disclosure(arena.allocator(), true));
    try pair.frame(2_000_000_000);
    try pair.frame(2_090_000_000);
    try pair.install(try disclosure(arena.allocator(), true));
    try pair.frame(2_200_000_000);
    try pair.install(try disclosure(arena.allocator(), false));
    try pair.frame(3_000_000_000);
    try pair.frame(3_200_000_000);
}
test "compiled widget motion drag landing retarget preserves presented offsets and rejects adoption atomically" {
    defer core.rt.frameReset();
    const pair = try Pair.init();
    defer pair.deinit();
    const first = canvas.Widget{ .id = 9_007_199_254_740_993, .kind = .button, .frame = .init(10, 10, 60, 30), .semantics = .{ .actions = .{ .drag = true } } };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const initial = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{first} }, .init(0, 0, 320, 400), &nodes);
    try pair.install(initial);
    var next = nodes;
    next[1].frame.y = 80;
    next[1].widget.frame = next[1].frame;
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| h.runtime.views[0].canvas_widget_drag_layout_motion_armed = true;
    try pair.install(.{ .nodes = &next, .root_bounds = initial.root_bounds });
    try pair.frame(1_000_000_000);
    try pair.frame(1_090_000_000);
    var retarget = next;
    retarget[1].frame.y = 120;
    retarget[1].widget.frame = retarget[1].frame;
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| {
        h.runtime.views[0].canvas_widget_drag_layout_motion_armed = true;
        h.runtime.views[0].canvas_widget_drag_landing_source_id = first.id;
        h.runtime.views[0].canvas_widget_drag_landing_origin = .init(40, 150);
    }
    try pair.install(.{ .nodes = &retarget, .root_bounds = initial.root_bounds });
    try pair.frame(2_000_000_000);
    try pair.frame(2_200_000_000);
    var rejected = retarget;
    const oversized = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    rejected[1].widget.text = oversized;
    for ([_]*Harness{ pair.reference, pair.compiled }) |h| {
        h.runtime.views[0].canvas_widget_drag_layout_motion_armed = true;
        try std.testing.expectError(error.WidgetTextTooLarge, h.runtime.setCanvasWidgetLayout(1, "canvas", .{ .nodes = &rejected, .root_bounds = initial.root_bounds }));
        try std.testing.expect(h.runtime.views[0].canvas_widget_drag_layout_motion_armed);
    }
    try pair.compare();
}
test "compiled widget motion loop phase refresh visibility capacity and caret admission preserve renderer state" {
    defer core.rt.frameReset();
    const pair = try Pair.init();
    defer pair.deinit();
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const children = [_]canvas.Widget{
        .{ .id = 5, .kind = .spinner, .frame = .init(10, 10, 20, 20) },
        .{ .id = 6, .kind = .skeleton, .frame = .init(40, 10, 80, 20) },
        .{ .id = 7, .kind = .input, .text = "input", .text_selection = .{ .anchor = 1, .focus = 1 }, .frame = .init(10, 60, 180, 32) },
    };
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, .init(0, 0, 320, 400), &nodes);
    try pair.install(layout);
    try pair.frame(9_007_199_254_740_993);
    for ([_]*Harness{ pair.reference, pair.compiled }, 0..) |h, lane| {
        var tokens = canvas.DesignTokens.theme(.{ .pack = .geist });
        if (lane == 1) tokens.widget_motion_policy = core.nativeWindowPolicy;
        _ = try h.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
        h.runtime.views[0].focused = true;
        h.runtime.views[0].canvas_widget_focused_id = 7;
        h.runtime.views[0].canvas_widget_focus_visible_id = 7;
        _ = try h.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    }
    try pair.compare();
    try pair.frame(9_007_199_354_740_993);
    try pair.install(layout);
    for ([_]*Harness{ pair.reference, pair.compiled }, 0..) |h, lane| {
        var tokens = canvas.DesignTokens.theme(.{ .pack = .geist, .reduce_motion = true });
        if (lane == 1) tokens.widget_motion_policy = core.nativeWindowPolicy;
        _ = try h.runtime.setCanvasWidgetDesignTokens(1, "canvas", tokens);
        h.runtime.views[0].focused = false;
        _ = try h.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    }
    try pair.compare();
    try std.testing.expectEqual(@as(usize, 0), pair.compiled.runtime.views[0].canvas_widget_loop_animation_count);
    try std.testing.expectEqual(@as(u64, 0), pair.compiled.runtime.views[0].canvas_widget_caret_blink_id);
}
test "compiled widget motion capacity pressure preserves native disclosure snap and bounded loop admission" {
    defer core.rt.frameReset();
    const pair = try Pair.init();
    defer pair.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |open| {
        var ui = Ui.init(arena.allocator());
        const children = try arena.allocator().alloc(Ui.Node, 300);
        children[0] = ui.el(.accordion, .{ .text = "Section", .selected = open, .on_toggle = .toggle }, .{ui.text(.{}, "Body")});
        for (children[1..]) |*child| child.* = ui.text(.{}, "Below");
        const tree = try ui.finalize(ui.column(.{}, children));
        const layout = try canvas.layoutWidgetTree(tree.root, .init(0, 0, 320, 20000), try arena.allocator().alloc(canvas.WidgetLayoutNode, 320));
        try pair.install(layout);
    }
    try std.testing.expect(!pair.compiled.runtime.views[0].canvas_widget_disclosure_tween.active);
    const children = try arena.allocator().alloc(canvas.Widget, 66);
    for (children, 0..) |*widget, i| widget.* = .{ .id = @intCast(1000 + i), .kind = .spinner, .frame = .init(10, 10, 20, 20) };
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = children }, .init(0, 0, 320, 400), try arena.allocator().alloc(canvas.WidgetLayoutNode, 70));
    try pair.install(layout);
    try std.testing.expectEqual(@as(usize, 64), pair.compiled.runtime.views[0].canvas_widget_loop_animation_count);
    try pair.frame(1_000_000_000);
    var reduced = [_]canvas.Widget{children[0]};
    reduced[0].semantics.hidden = true;
    const empty = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &reduced }, .init(0, 0, 320, 400), try arena.allocator().alloc(canvas.WidgetLayoutNode, 2));
    try pair.install(empty);
    try std.testing.expectEqual(@as(usize, 0), pair.compiled.runtime.views[0].canvas_widget_loop_animation_count);
}
test "compiled widget motion segmented phases preserve complete exact native integer plans" {
    defer core.rt.frameReset();
    const starts = [_]u64{ 0, 1, 0xffff_ffff, 9_007_199_254_740_993, std.math.maxInt(u64) - 5_000_000_000_000_000 };
    for ([_]u32{ 0, 1, 1200, std.math.maxInt(u32) }) |period| for ([_]u32{ 3, 12, 15 }) |count| for ([_]bool{ false, true }) |existing| for (starts) |start| {
        for (0..count) |segment| {
            var request: [48]u8 = @splat(0);
            request[0..4].* = .{ 18, 7, @as(u8, 31) | (@as(u8, @intFromBool(existing)) << 5), 1 };
            std.mem.writeInt(u32, request[4..8], period, .little);
            std.mem.writeInt(u32, request[8..12], count, .little);
            std.mem.writeInt(u32, request[12..16], @intCast(segment), .little);
            std.mem.writeInt(u32, request[16..20], 64, .little);
            packetFloat(request[20..24], 0.15);
            std.mem.writeInt(u64, request[24..32], start, .little);
            std.mem.writeInt(u64, request[32..40], start, .little);
            var output: [32]u8 = undefined;
            try std.testing.expectEqual(output.len, core.nativeWindowPolicy(&request, &output));
            const ns: u64 = @as(u64, @max(1, period)) * 1_000_000;
            const anchor = if (existing) start else start -| ns;
            var expected: [32]u8 = @splat(0);
            expected[0..3].* = .{ 1, 0, @intFromEnum(canvas.CanvasRenderAnimationLoop.wrap) };
            std.mem.writeInt(u32, expected[4..8], @max(1, period), .little);
            std.mem.writeInt(u64, expected[8..16], anchor + ns / count * segment, .little);
            packetFloat(expected[16..20], 1);
            packetFloat(expected[20..24], 0.15);
            try std.testing.expectEqualSlices(u8, &expected, &output);
            const frozen = output;
            core.rt.frameReset();
            try std.testing.expectEqualSlices(u8, &frozen, &output);
        }
    };
    for ([_]u32{ 0, 0x80000000, 0x7fc00037, 0xff800000, 0x7f800000 }) |bits| {
        var request: [48]u8 = @splat(0);
        request[0..4].* = .{ 18, 7, 31, 1 };
        std.mem.writeInt(u32, request[4..8], 1200, .little);
        std.mem.writeInt(u32, request[8..12], 12, .little);
        std.mem.writeInt(u32, request[16..20], 64, .little);
        std.mem.writeInt(u32, request[20..24], bits, .little);
        var value: f32 = @bitCast(bits);
        std.mem.doNotOptimizeAway(&value);
        var output: [32]u8 = undefined;
        try std.testing.expectEqual(output.len, core.nativeWindowPolicy(&request, &output));
        try std.testing.expectEqual(@as(u32, @bitCast(std.math.clamp(value, 0, 1))), std.mem.readInt(u32, output[20..24], .little));
    }
}
fn packetFloat(bytes: []u8, v: f32) void {
    std.mem.writeInt(u32, bytes[0..4], @bitCast(v), .little);
}
test "compiled widget motion copies exact f32 poses and u64 clocks across arena resets" {
    defer core.rt.frameReset();
    const values = [_]f32{ 0, -0.0, 0.33333334, 0.731, -100001.17, 100001.17 };
    for (0..4) |mode| for (values) |from| for (values) |to| for ([_]f32{ 0, 0.33333334, 0.731, 1 }) |progress| {
        var request: [32]u8 = @splat(0);
        request[0..4].* = .{ 18, 4, 0, @intCast(mode) };
        packetFloat(request[4..8], progress);
        packetFloat(request[8..12], from);
        packetFloat(request[12..16], to);
        var output: [12]u8 = undefined;
        try std.testing.expectEqual(output.len, core.nativeWindowPolicy(&request, &output));
        const expected = if (mode == 3) from * (1 - progress) else if (mode != 2 and progress >= 1) to else from + (to - from) * progress;
        try std.testing.expectEqual(@as(u32, @bitCast(expected)), std.mem.readInt(u32, output[4..8], .little));
        const saved = output;
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, &saved, &output);
    };
    const words = [_]u64{ 0, 1, 0xffff_ffff, 0x1_0000_0000, 9_007_199_254_740_993, std.math.maxInt(u64) };
    for (words) |start| for (words) |stamp| {
        var request: [24]u8 = @splat(0);
        request[0..2].* = .{ 18, 5 };
        std.mem.writeInt(u64, request[8..16], start, .little);
        std.mem.writeInt(u64, request[16..24], stamp, .little);
        var output: [8]u8 = undefined;
        try std.testing.expectEqual(output.len, core.nativeWindowPolicy(&request, &output));
        try std.testing.expectEqual(if (start == 0 or stamp < start) stamp else start, std.mem.readInt(u64, &output, .little));
    };
}
test "compiled widget motion owner reaches static and model themes and both app windows without growing Widget" {
    defer core.rt.frameReset();
    try std.testing.expectEqual(@as(usize, 792), @sizeOf(canvas.Widget));
    const Adapter = sdk.TsUiApp(core);
    const Factory = struct {
        fn view(ui: *Adapter.Ui, _: *const core.Model) Adapter.Ui.Node {
            return ui.text(.{}, "Motion");
        }
        fn panel(ui: *Adapter.Ui, model: *const core.Model, _: []const u8) Adapter.Ui.Node {
            return view(ui, model);
        }
        fn windows(_: *const core.Model, scratch: *Adapter.App.WindowsScratch) []const Adapter.App.WindowDescriptor {
            scratch.windows[0] = .{ .label = "panel", .canvas_label = "panel-canvas", .title = "Panel" };
            return scratch.windows[0..1];
        }
        fn tokens(_: *const core.Model) canvas.DesignTokens {
            return canvas.DesignTokens.theme(.{ .pack = .geist });
        }
    };
    for (0..3) |theme| {
        const harness = try Harness.create(std.testing.allocator, .{ .size = .init(320, 200) });
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const state = try Adapter.create(std.testing.allocator, .{}, .{
            .name = "motion",
            .scene = .{ .windows = &.{.{ .label = "main", .title = "Main", .width = 320, .height = 200, .views = &.{.{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }} }} },
            .canvas_label = "canvas",
            .view = Factory.view,
            .windows_fn = Factory.windows,
            .window_view = Factory.panel,
            .tokens = if (theme == 1) canvas.DesignTokens.theme(.{ .pack = .geist }) else null,
            .tokens_fn = if (theme == 2) Factory.tokens else null,
        });
        defer state.destroy();
        try std.testing.expect(state.options.widget_motion_policy == core.nativeWindowPolicy);
        try std.testing.expect(state.effectiveTokens().widget_motion_policy == core.nativeWindowPolicy);
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(320, 200), .timestamp_ns = 1_000_000 } });
        var panel_id: sdk.WindowId = 0;
        var buffer: [sdk.platform.max_windows]sdk.WindowInfo = undefined;
        for (harness.runtime.listWindows(&buffer)) |window| if (std.mem.eql(u8, window.label, "panel")) {
            panel_id = window.id;
        };
        try std.testing.expect(panel_id != 0);
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .window_id = panel_id, .label = "panel-canvas", .size = .init(480, 360), .timestamp_ns = 2_000_000 } });
        for (harness.runtime.views[0..harness.runtime.view_count]) |v| if (v.kind == .gpu_surface) try std.testing.expect(v.widget_tokens.widget_motion_policy == core.nativeWindowPolicy);
        try harness.stop(state.app());
    }
}
