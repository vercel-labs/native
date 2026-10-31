const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const p = c.CanvasFrameCoordinationPolicy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [7]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 75) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
fn reference(f: p.Facts, mode: p.Mode) p.Program {
    var r: p.Program = .{ .surface = .{}, .scale = 0, .inherit_images = false, .inherit_fonts = false, .inherit_budget = false, .no_op = false, .canvas_changed = false, .surface_changed = false, .observe_unkeyed = false, .full_repaint = false, .refine_damage = false, .bounds = null, .invalid_pixels = false, .pixel_width = 0, .pixel_height = 0, .pixel_bytes = 0 };
    switch (mode) {
        .defaults => {
            r.surface = if (!f.surface.isEmpty()) f.surface else if (!f.gpu_size.isEmpty()) f.gpu_size else f.frame_size;
            r.inherit_images = f.images == 0;
            r.inherit_fonts = f.fonts == 0;
            r.inherit_budget = sdk.runtime.testing.referenceFrameBudgetUnset(f.budget);
        },
        .admission, .repaint => {
            const changed = f.revision != f.presented_revision;
            const surface_changed = f.surface.width != f.previous_surface.width or f.surface.height != f.previous_surface.height or f.scale != f.previous_scale;
            r.full_repaint = f.full_repaint or !f.presented_valid or surface_changed or (changed and (f.presented_unkeyed or (mode == .repaint and f.current_unkeyed)));
            if (mode == .admission) {
                r.canvas_changed = changed;
                r.surface_changed = surface_changed;
                r.no_op = !f.full_repaint and f.presented_valid and !changed and !surface_changed and f.previous_overrides == 0 and f.current_overrides == 0;
                r.observe_unkeyed = !r.full_repaint and changed;
            } else r.refine_damage = !r.full_repaint and changed and f.baseline_valid and f.surface.width == f.baseline_surface.width and f.surface.height == f.baseline_surface.height and f.scale == f.baseline_scale;
        },
        .bounds => r.bounds = sdk.runtime.testing.referenceFrameBounds(f.surface, f.render_bounds),
        .scale => r.scale = sdk.runtime.testing.referenceFrameScale(f.requested_scale, f.fallback_scale),
        .pixels => {
            const size = sdk.runtime.canvasSurfacePixelSize(f.surface, f.scale) catch {
                r.invalid_pixels = true;
                return r;
            };
            r.pixel_width = size.width;
            r.pixel_height = size.height;
            r.pixel_bytes = size.byte_len;
        },
        .screenshot => {
            r.surface = if (f.gpu_size.isEmpty()) f.frame_size else f.gpu_size;
            r.scale = sdk.runtime.testing.referenceFrameScale(f.requested_scale, f.fallback_scale);
        },
    }
    return r;
}
fn compare(facts: p.Facts, mode: p.Mode) !void {
    const expected = reference(facts, mode);
    const actual = p.plan(facts, mode, observed);
    try exact(expected, actual);
    core.rt.frameReset();
    try exact(expected, actual);
}
const samples = [_]f32{ -std.math.inf(f32), -16384, -1, -std.math.floatMin(f32), -0.0, 0, std.math.floatTrueMin(f32), std.math.floatMin(f32), 0.125, 0.99999994, 1, 1.00000012, 1.75, 64.25, 16383.999, 16384, 16384.002, std.math.floatMax(f32), std.math.inf(f32), std.math.nan(f32) };

test "compiled frame coordination preserves complete defaults and all budget resource words" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (samples) |width| for (samples) |gpu_width| {
        const facts: p.Facts = .{ .surface = .init(width, 48.5), .gpu_size = .init(gpu_width, 24.25), .frame_size = .init(-0.0, 17.5) };
        try compare(facts, .defaults);
        try compare(facts, .screenshot);
    };
    inline for (@typeInfo(c.CanvasFrameBudget).@"struct".fields) |field| {
        var facts: p.Facts = .{ .surface = .init(64, 48) };
        @field(facts.budget, field.name) = std.math.maxInt(usize);
        try compare(facts, .defaults);
    }
    for ([_]usize{ 0, 1, std.math.maxInt(u32), std.math.maxInt(usize) }) |count| {
        try compare(.{ .images = count }, .defaults);
        try compare(.{ .fonts = count }, .defaults);
    }
}
test "compiled frame coordination preserves exact revisions no-op repaint and refinement admission" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..32) |bits| for ([_]u64{ 0, 1, 0xffffffff, 0x100000000, 0x20000000000001, 0xffffffffffffffff }) |revision| for (0..8) |variant| {
        var facts: p.Facts = .{ .surface = .init(64.25, 48.5), .previous_surface = .init(64.25, 48.5), .baseline_surface = .init(64.25, 48.5), .scale = 1.75, .previous_scale = 1.75, .baseline_scale = 1.75, .revision = revision, .presented_revision = revision, .full_repaint = bits & 1 != 0, .presented_valid = bits & 2 != 0, .presented_unkeyed = bits & 4 != 0, .current_unkeyed = bits & 8 != 0, .baseline_valid = bits & 16 != 0 };
        switch (variant) {
            1 => facts.presented_revision = revision -% 1,
            2 => facts.previous_overrides = std.math.maxInt(usize),
            3 => facts.current_overrides = 1,
            4 => facts.previous_surface.width = std.math.nan(f32),
            5 => facts.baseline_scale = std.math.nan(f32),
            6 => {
                facts.surface.width = -0.0;
                facts.previous_surface.width = 0;
                facts.baseline_surface.width = 0;
            },
            7 => {
                facts.scale = std.math.inf(f32);
                facts.previous_scale = std.math.inf(f32);
                facts.baseline_scale = std.math.inf(f32);
            },
            else => {},
        }
        try compare(facts, .admission);
        try compare(facts, .repaint);
    };
}
test "compiled frame coordination preserves complete float32 bounds scales and pixel admission" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (samples) |width| for (samples) |height| {
        try compare(.{ .surface = .init(width, height) }, .bounds);
        try compare(.{ .surface = .init(width, height), .render_bounds = .init(-0.0, 7.25, -13.5, std.math.nan(f32)) }, .bounds);
        for (samples) |scale| try compare(.{ .surface = .init(width, height), .scale = scale }, .pixels);
    };
    for (samples) |wanted| for (samples) |fallback| {
        try compare(.{ .requested_scale = wanted, .fallback_scale = fallback }, .scale);
        try compare(.{ .gpu_size = .init(-0.0, 17), .frame_size = .init(64.25, 48.5), .requested_scale = wanted, .fallback_scale = fallback }, .screenshot);
    };
    for (samples) |fallback| try compare(.{ .fallback_scale = fallback }, .scale);
}
test "compiled frame coordination retains copied NaN and signed-zero bounds through borrowed result reset" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const nan: f32 = @bitCast(@as(u32, 0xffc12345));
    const fallback = sdk.geometry.RectF.init(nan, -0.0, 1.00000012, std.math.inf(f32));
    const result = p.plan(.{ .surface = .init(-0.0, 1), .render_bounds = fallback }, .bounds, observed);
    core.rt.frameReset();
    inline for (.{ "x", "y", "width", "height" }) |field| try std.testing.expectEqual(@as(u32, @bitCast(@field(fallback, field))), @as(u32, @bitCast(@field(result.bounds.?, field))));
    const surface_result = p.plan(.{ .surface = .init(nan, 1) }, .bounds, observed);
    try std.testing.expectEqual(@as(u32, 0xffc12345), @as(u32, @bitCast(surface_result.bounds.?.width)));
}
test "compiled frame coordination runtime preserves complete frames retained no-op and screenshot pixels" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Storage = @import("render_cache_e2e_tests.zig").Storage;
    var storage_a = try Storage.init();
    defer storage_a.deinit();
    var storage_b = try Storage.init();
    defer storage_b.deinit();
    const a = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    var context: u8 = 0;
    for ([_]@TypeOf(a){ a, b }, 0..) |h, lane| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = &context, .name = "frame-coordination-parity", .source = sdk.platform.WebViewSource.html(""), .render_cache_policy = if (lane == 1) observed else null, .render_damage_policy = if (lane == 1) observed else null });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 64, 48) });
    }
    var scene = [_]c.CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = .init(2, 2, 8, 8), .fill = .{ .color = c.Color.rgb8(20, 30, 40) } } }};
    const pixels = try std.testing.allocator.alloc(u8, 128 * 96 * 4 * 4);
    defer std.testing.allocator.free(pixels);
    for (0..9) |step| {
        if (step != 1 and step != 2) {
            scene[0].fill_rect.id = if (step == 4) 0 else 1;
            scene[0].fill_rect.fill = .{ .color = c.Color.rgb8(@intCast(20 + step), 30, 40) };
            for ([_]@TypeOf(a){ a, b }) |h| _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &scene });
        }
        for ([_]@TypeOf(a){ a, b }) |h| if (step == 2) {
            h.runtime.views[0].gpu_size = .init(64, 48);
        };
        const options = c.CanvasFrameOptions{ .frame_index = step + 1, .timestamp_ns = (step + 1) * 16000, .surface_size = if (step < 3) .{} else .init(64, 48), .scale = if (step == 6) 1.75 else 1, .full_repaint = step == 7, .budget = if (step == 8) .{ .max_images = 1 } else .{} };
        const left = try a.runtime.nextCanvasFrame(1, "canvas", options, storage_a.value);
        const right = try b.runtime.nextCanvasFrame(1, "canvas", options, storage_b.value);
        try @import("render_cache_e2e_tests.zig").frameEqual(left, right, observed);
        try exact(sdk.runtime.testing.runtimeViewInfo(a.runtime.views[0]), sdk.runtime.testing.runtimeViewInfo(b.runtime.views[0]));
        for ([_]?f32{ null, -0.0, std.math.nan(f32), 1.75 }) |scale| {
            const size_a = try a.runtime.canvasScreenshotPixelSize(1, "canvas", scale);
            const size_b = try b.runtime.canvasScreenshotPixelSize(1, "canvas", scale);
            try exact(size_a, size_b);
            const size = size_a.byte_len;
            const shot_a = try a.runtime.renderCanvasScreenshot(1, "canvas", scale, pixels[0..size], pixels[128 * 96 * 4 ..][0..size]);
            const shot_b = try b.runtime.renderCanvasScreenshot(1, "canvas", scale, pixels[128 * 96 * 4 * 2 ..][0..size], pixels[128 * 96 * 4 * 3 ..][0..size]);
            try exact(shot_a, shot_b);
        }
        core.rt.frameReset();
    }
    for (calls) |count| try std.testing.expect(count > 0);
}
