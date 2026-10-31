const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const policy = sdk.runtime.testing.motion_sampling_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const huge: u64 = 9007199254740993;
const max = std.math.maxInt(u64);
const Animation = canvas.CanvasRenderAnimation;
const Override = canvas.CanvasRenderOverride;
var calls: usize = 0;
fn counted(input: []const u8, output: []u8) usize {
    if (input.len > 0 and input[0] == 73) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn parity(animations: []const Animation, now: u64, capacity: usize) !void {
    var a: [16]Override = @splat(.{ .id = 97, .opacity = 0.123, .transform = .translate(3, 4) });
    var b = a;
    const expected = canvas.sampleCanvasRenderAnimations(animations, now, a[0..capacity]);
    const actual = policy.sample(animations, now, b[0..capacity], counted);
    if (expected) |values| {
        try std.testing.expectEqual(values.len, (try actual).len);
    } else |err| try std.testing.expectError(err, actual);
    try exact(a, b);
    core.rt.frameReset();
}
test "compiled motion sampling exact u64 clocks loops channels capacity errors and untouched tails" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 4294967295, huge, max - 1_000_000, max }) |start| for ([_]u32{ 0, 1, 500, std.math.maxInt(u32) }) |duration| {
        const span = @as(u64, duration) * 1_000_000;
        for ([_]u64{ 0, start, start +| 1, start +| (span -| 1), start +| span, start +| (span * 2), max }) |now| {
            var records: [12]Animation = undefined;
            var i: usize = 0;
            inline for (std.meta.tags(canvas.CanvasRenderAnimationLoop)) |loop| inline for (std.meta.tags(canvas.Easing)) |easing| {
                records[i] = .{ .id = if (i == 0) 0 else if (i % 2 == 0) max else huge, .start_ns = start, .duration_ms = duration, .loop = loop, .easing = easing, .from_opacity = -0.0, .to_opacity = 0.75, .from_transform = .translate(7, -4), .to_transform = .scale(2, 3), .from_rotation = -95.123, .to_rotation = 375.125, .rotation_center = .{ .x = 3.125, .y = -9.25 } };
                i += 1;
            };
            calls = 0;
            try parity(&records, now, 16);
            try std.testing.expect(calls <= 4);
            try parity(&records, now, 0);
            try parity(&records, now, 5);
        }
    };
}
test "compiled motion sampling all optional channel combinations preserve omission and duplicate order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..64) |mask| {
        const value = Animation{ .id = max, .duration_ms = 1, .from_opacity = if (mask & 1 != 0) -0.0 else null, .to_opacity = if (mask & 2 != 0) 0.5 else null, .from_transform = if (mask & 4 != 0) .translate(3, 4) else null, .to_transform = if (mask & 8 != 0) .scale(2, 3) else null, .from_rotation = if (mask & 16 != 0) -90 else null, .to_rotation = if (mask & 32 != 0) 270 else null };
        const values = [_]Animation{ .{ .id = 0, .from_opacity = 0, .to_opacity = 1 }, value, .{ .id = max }, value };
        try parity(&values, 123456, 16);
        try parity(&values, 123456, 1);
    }
}
test "compiled motion sampling every easing and spring boundary matches exact float32 reference" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const springs = [_]canvas.SpringToken{ .{}, .{ .mass = 1, .stiffness = 180, .damping = 18 }, .{ .mass = -1, .stiffness = 0, .damping = -0.0 }, .{ .mass = 0.0011, .stiffness = 999, .damping = 0.0011 }, .{ .mass = std.math.nan(f32), .stiffness = std.math.inf(f32), .damping = std.math.nan(f32) }, .{ .mass = std.math.inf(f32), .stiffness = std.math.inf(f32), .damping = std.math.inf(f32) } };
    for (springs) |spring| inline for (std.meta.tags(canvas.Easing)) |easing| {
        for (0..1001) |i| {
            const now: u64 = @as(u64, @intCast(i)) * 1000;
            const native = canvas.layoutTweenProgress(easing, spring, huge, 1, huge + now);
            const compiled = policy.progress(easing, spring, huge, 1, huge + now, counted);
            try exact(native, compiled);
            core.rt.frameReset();
        }
    };
    for ([_]f32{ -0.0, 0, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 0.1234567 }) |value| {
        try parity(&.{.{ .id = huge, .duration_ms = 1, .from_opacity = value, .to_opacity = value, .from_rotation = value, .to_rotation = value, .rotation_center = .{ .x = value, .y = -value } }}, 500000, 16);
    }
}
test "compiled motion sampling preserves borrowed ABI owners across batched continuations" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 10);
    @memcpy(borrowed, "motion\x00abi");
    var pointer: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_core_native_view(&pointer, &len);
    const saved = try std.testing.allocator.dupe(u8, pointer[0..len]);
    defer std.testing.allocator.free(saved);
    var output: [2]Override = undefined;
    const animation = Animation{ .id = huge, .duration_ms = 1, .easing = .spring, .from_rotation = 0, .to_rotation = 360 };
    calls = 0;
    _ = try policy.sample(&.{ animation, animation }, 123456, &output, counted);
    try std.testing.expectEqual(@as(usize, 4), calls);
    try std.testing.expectEqualSlices(u8, "motion\x00abi", borrowed);
    try std.testing.expectEqualSlices(u8, saved, pointer[0..len]);
    const owned = output;
    _ = policy.progress(.spring, .{}, 0, 1, 456789, counted);
    try exact(owned, output);
}
var context: u8 = 0;
fn quiet(_: *anyopaque, _: *sdk.Runtime, _: sdk.Event) anyerror!void {}
test "compiled motion sampling runtime progress drives disclosure drag and split settle from recorded clocks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    inline for (std.meta.tags(canvas.Easing)) |easing| {
        const a = try sdk.TestHarness().create(std.testing.allocator, .{});
        defer a.destroy(std.testing.allocator);
        const b = try sdk.TestHarness().create(std.testing.allocator, .{});
        defer b.destroy(std.testing.allocator);
        const app = sdk.App{ .context = &context, .name = "sampling-runtime", .source = sdk.WebViewSource.html(""), .event_fn = quiet };
        var nodes: [16]canvas.WidgetLayoutNode = undefined;
        const tree = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &.{
            .{ .id = 2, .kind = .split, .value = 0.5, .children = &.{ .{ .id = 4, .kind = .text, .text = "First" }, .{ .id = 5, .kind = .text, .text = "Second" } } },
            .{ .id = 3, .kind = .split, .value = 0.5, .children = &.{ .{ .id = 6, .kind = .text, .text = "Third" }, .{ .id = 7, .kind = .text, .text = "Fourth" } } },
            .{ .id = 9, .kind = .button, .text = "Moving", .frame = .init(10, 150, 60, 30), .semantics = .{ .actions = .{ .drag = true } } },
        } }, .init(0, 0, 320, 400), &nodes);
        for ([_]@TypeOf(a){ a, b }, 0..) |h, lane| {
            h.null_platform.gpu_surfaces = true;
            try h.start(app);
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 400) });
            if (lane == 1) h.runtime.views[0].widget_tokens.widget_motion_policy = counted;
            _ = try h.runtime.setCanvasWidgetLayout(1, "canvas", tree);
            _ = try h.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
            _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = 2, .to = 0.25, .duration_ms = 1, .easing = easing });
            _ = try h.runtime.startCanvasWidgetLayoutTween(1, "canvas", .{ .id = 3, .to = 0.75, .duration_ms = 10, .easing = easing });
            const v = &h.runtime.views[0];
            const moving = v.canvasWidgetNodeIndexById(9).?;
            v.canvas_widget_disclosure_tween.active = true;
            v.canvas_widget_disclosure_tween.duration_ms = 10;
            v.canvas_widget_disclosure_tween.easing = easing;
            v.canvas_widget_disclosure_tween.move_count = 1;
            v.canvas_widget_disclosure_tween.moves[0] = .{ .node_index = moving, .from_y = 150, .to_y = 170, .from_height = 30, .to_height = 40 };
            v.canvas_widget_drag_layout_motion_count = 1;
            v.canvas_widget_drag_layout_motions[0] = .{ .id = 9, .duration_ms = 10, .easing = easing, .from_offset = .init(3, -4), .offset = .init(3, -4) };
        }
        for ([_]u64{ huge, huge + 123456, huge - 1, huge + 1_000_000, huge + 5_000_000, huge + 10_000_000, huge + 20_000_000 }) |now| {
            for ([_]@TypeOf(a){ a, b }, 0..) |h, lane| {
                calls = 0;
                try h.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{ .window_id = 1, .label = "canvas", .size = .init(320, 400), .timestamp_ns = now } });
                if (now == huge) try std.testing.expectEqual(@as(usize, if (lane == 0) 0 else 4), calls);
            }
            const av = &a.runtime.views[0];
            const bv = &b.runtime.views[0];
            try exact(av.widgetLayoutTree(), bv.widgetLayoutTree());
            try exact(av.widgetSemantics(), bv.widgetSemantics());
            try exact(av.canvasDisplayList().commands, bv.canvasDisplayList().commands);
            try exact(av.canvas_widget_layout_tweens[0..av.canvas_widget_layout_tween_count], bv.canvas_widget_layout_tweens[0..bv.canvas_widget_layout_tween_count]);
            try exact(av.canvas_widget_disclosure_tween.progress, bv.canvas_widget_disclosure_tween.progress);
            try exact(av.canvas_widget_disclosure_tween.active, bv.canvas_widget_disclosure_tween.active);
            try exact(av.canvas_widget_disclosure_tween.start_ns, bv.canvas_widget_disclosure_tween.start_ns);
            try exact(av.canvas_widget_disclosure_tween.revealing_ids[0..av.canvas_widget_disclosure_tween.revealing_id_count], bv.canvas_widget_disclosure_tween.revealing_ids[0..bv.canvas_widget_disclosure_tween.revealing_id_count]);
            try exact(av.canvas_widget_drag_layout_motions[0..av.canvas_widget_drag_layout_motion_count], bv.canvas_widget_drag_layout_motions[0..bv.canvas_widget_drag_layout_motion_count]);
            try exact(av.widget_revision, bv.widget_revision);
            try exact(a.runtime.pendingDirtyRegions(), b.runtime.pendingDirtyRegions());
            try exact(a.null_platform.gpu_surface_frame_request_count, b.null_platform.gpu_surface_frame_request_count);
            core.rt.frameReset();
        }
        try std.testing.expectEqual(@as(usize, 0), b.runtime.views[0].canvas_widget_layout_tween_count);
        try std.testing.expectEqual(@as(usize, 0), b.runtime.views[0].canvas_widget_drag_layout_motion_count);
        try std.testing.expect(!b.runtime.views[0].canvas_widget_disclosure_tween.active);
    }
}
test "compiled motion sampling transport rejects invalid numeric selectors before native writes" {
    var request: [176]u8 = @splat(0);
    request[0..4].* = .{ 73, 1, 0, 0 };
    request[4] = 1;
    request[8] = 1;
    var result: [48]u8 = @splat(0);
    result[0] = 1;
    result[4] = 1;
    result[8] = 1;
    result[40] = 3;
    try std.testing.expect(policy.resultValid(&request, &result));
    for ([_]usize{ 0, 4, 8, 12, 28, 32, 36, 40 }) |at| {
        var bad = result;
        bad[at] = 255;
        try std.testing.expect(!policy.resultValid(&request, &bad));
    }
    request[148] = 1;
    try std.testing.expect(!policy.resultValid(&request, &result));
}
extern fn nsc_core_native_view(out_ptr: *[*]const u8, out_len: *usize) callconv(.c) void;
