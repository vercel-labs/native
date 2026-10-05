const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = sdk.canvas;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Workspace = canvas.RenderCacheWorkspace;

fn check(comptime Planner: type, plan: anytype, previous: anytype, capacity: usize, action_capacity: usize, frame: u64) !void {
    const Entry = @FieldType(Planner, "entries");
    const Action = @FieldType(Planner, "actions");
    const allocator = std.testing.allocator;
    const a = try allocator.alloc(@typeInfo(Entry).pointer.child, capacity);
    defer allocator.free(a);
    const b = try allocator.alloc(@typeInfo(Entry).pointer.child, capacity);
    defer allocator.free(b);
    const aa = try allocator.alloc(@typeInfo(Action).pointer.child, action_capacity);
    defer allocator.free(aa);
    const ba = try allocator.alloc(@typeInfo(Action).pointer.child, action_capacity);
    defer allocator.free(ba);
    const P = @TypeOf(plan);
    const count = @field(plan, if (@hasField(P, "batches")) "batches" else if (@hasField(P, "geometries")) "geometries" else if (@hasField(P, "images")) "images" else if (@hasField(P, "layers")) "layers" else if (@hasField(P, "resources")) "resources" else "effects").len;
    var workspace = Workspace.init(core.nativeWindowPolicy, count + previous.len, @min(capacity, count), @min(action_capacity, count + previous.len));
    defer workspace.deinit();
    var native = Planner.init(a, aa);
    var compiled = Planner.init(b, ba);
    const expected = native.build(plan, previous, frame);
    const actual = compiled.buildCompiled(plan, previous, frame, &workspace);
    if (expected) |result| try exact(result, try actual) else |err| try std.testing.expectError(err, actual);
    try exact(native.entry_len, compiled.entry_len);
    try exact(native.action_len, compiled.action_len);
    try exact(a[0..native.entry_len], b[0..compiled.entry_len]);
    try exact(aa[0..native.action_len], ba[0..compiled.action_len]);
}

test "compiled pipeline cache preserves full records first previous matches and action-before-entry failures" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const plan = canvas.RenderBatchPlan{ .batches = &.{ .{ .pipeline = .path, .command_count = 9 }, .{ .pipeline = .path }, .{ .pipeline = .image } } };
    const old = [_]canvas.RenderPipelineCacheEntry{ .{ .pipeline = .path, .last_used_frame = 9007199254740993 }, .{ .pipeline = .path, .last_used_frame = 7 }, .{ .pipeline = .blur }, .{ .pipeline = .blur } };
    for ([_]usize{ 0, 1, 2, 9 }) |capacity| for ([_]usize{ 0, 1, 2, 3, 9 }) |actions| {
        try check(canvas.RenderPipelineCachePlanner, plan, &old, capacity, actions, 0xffffffffffffffff);
        core.rt.frameReset();
    };
}

test "compiled path image layer and effect caches preserve exact keys positions frame stamps and partial writes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const id: u64 = 9007199254740993;
    const paths = canvas.RenderPathGeometryPlan{ .geometries = &.{ .{ .kind = .fill, .id = 0, .command_index = 99, .fingerprint = id }, .{ .kind = .fill, .id = 0, .command_index = 100, .fingerprint = id }, .{ .kind = .stroke, .command_index = id, .fingerprint = id + 1 } } };
    const old_paths = [_]canvas.RenderPathGeometryCacheEntry{ .{ .key = .{ .kind = .fill, .id = 0, .fingerprint = id } }, .{ .key = .{ .kind = .fill, .id = 0, .fingerprint = id } }, .{ .key = .{ .kind = .stroke, .id = id, .fingerprint = 0xffffffffffffffff } }, .{ .key = .{ .kind = .stroke, .id = id, .fingerprint = 0xffffffffffffffff } } };
    const images = canvas.RenderImagePlan{ .images = &.{ .{ .image_id = id, .fingerprint = id }, .{ .image_id = id, .fingerprint = id }, .{ .image_id = id + 1, .fingerprint = id } } };
    const old_images = [_]canvas.RenderImageCacheEntry{ .{ .key = .{ .image_id = id, .fingerprint = id } }, .{ .key = .{ .image_id = id, .fingerprint = id } }, .{ .key = .{ .image_id = id, .fingerprint = id + 1 } } };
    const layers = canvas.RenderLayerPlan{ .layers = &.{ .{ .id = 0, .command_start = id, .fingerprint = id }, .{ .id = 0, .command_start = id + 1, .fingerprint = id }, .{ .command_start = id, .fingerprint = id } } };
    const old_layers = [_]canvas.RenderLayerCacheEntry{ .{ .key = .{ .id = 0, .fingerprint = id } }, .{ .key = .{ .id = 0, .fingerprint = id } }, .{ .key = .{ .command_start = id + 1, .fingerprint = id } }, .{ .key = .{ .id = 0, .command_start = 1, .fingerprint = id } } };
    const effects = canvas.VisualEffectPlan{ .effects = &.{ .{ .kind = .blur, .id = 0, .command_index = id, .fingerprint = id }, .{ .kind = .blur, .id = 0, .command_index = id + 1, .fingerprint = id }, .{ .kind = .shadow, .command_index = id, .fingerprint = id } } };
    const old_effects = [_]canvas.VisualEffectCacheEntry{ .{ .key = .{ .kind = .blur, .id = 0, .fingerprint = id } }, .{ .key = .{ .kind = .blur, .id = 0, .fingerprint = id } }, .{ .key = .{ .kind = .shadow, .command_index = id + 1, .fingerprint = id } }, .{ .key = .{ .kind = .shadow, .command_index = id + 1, .fingerprint = id } } };
    for ([_]usize{ 0, 1, 2, 9 }) |capacity| for ([_]usize{ 0, 1, 2, 3, 9 }) |actions| for ([_]u64{ 0, id, 0xffffffffffffffff }) |frame| {
        try check(canvas.RenderPathGeometryCachePlanner, paths, &old_paths, capacity, actions, frame);
        try check(canvas.RenderImageCachePlanner, images, &old_images, capacity, actions, frame);
        try check(canvas.RenderLayerCachePlanner, layers, &old_layers, capacity, actions, frame);
        try check(canvas.VisualEffectCachePlanner, effects, &old_effects, capacity, actions, frame);
        core.rt.frameReset();
    };
}

test "compiled resource cache preserves every key field indexed thresholds oversized inputs and ordered failure state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const id: u64 = 9007199254740993;
    const small = canvas.RenderResourcePlan{ .resources = &.{ .{ .kind = .image, .command_index = id, .image_id = id, .font_id = id + 1, .fingerprint = id + 2 }, .{ .kind = .image, .command_index = id + 1, .image_id = id, .font_id = id + 1, .fingerprint = id + 2 }, .{ .kind = .glyph_run, .id = 0, .command_index = id, .image_id = id, .font_id = id + 2, .fingerprint = id + 2 } } };
    const old = [_]canvas.RenderResourceCacheEntry{ .{ .key = .{ .kind = .image, .image_id = id, .font_id = id + 1, .fingerprint = id + 2 } }, .{ .key = .{ .kind = .image, .image_id = id, .font_id = id + 1, .fingerprint = id + 2 } }, .{ .key = .{ .kind = .glyph_run, .id = 0, .command_index = 1, .image_id = id, .font_id = id + 2, .fingerprint = id + 2 } } };
    for ([_]usize{ 0, 1, 2, 9 }) |capacity| for ([_]usize{ 0, 1, 2, 3, 9 }) |actions| {
        try check(canvas.RenderResourceCachePlanner, small, &old, capacity, actions, 0xffffffffffffffff);
        core.rt.frameReset();
    };
    const allocator = std.testing.allocator;
    for ([_]usize{ 63, 64, 2048, 2049 }) |count| {
        const resources = try allocator.alloc(canvas.RenderResource, count);
        defer allocator.free(resources);
        const previous = try allocator.alloc(canvas.RenderResourceCacheEntry, count);
        defer allocator.free(previous);
        for (resources, previous, 0..) |*r, *p, i| {
            r.* = .{ .kind = .image, .command_index = i, .image_id = id + i / 2, .fingerprint = id + 1 };
            p.* = .{ .key = .{ .kind = .image, .image_id = r.image_id, .fingerprint = r.fingerprint }, .last_used_frame = 8 };
        }
        try check(canvas.RenderResourceCachePlanner, canvas.RenderResourcePlan{ .resources = resources }, previous, count, count * 2, id);
        try check(canvas.RenderResourceCachePlanner, canvas.RenderResourcePlan{}, previous, 0, count, id);
        core.rt.frameReset();
    }
}

test "six compiled cache calls reuse native buffers and preserve borrowed core bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.modelSnapshot();
    const before = try std.testing.allocator.dupe(u8, borrowed);
    defer std.testing.allocator.free(before);
    var workspace = Workspace.init(core.nativeWindowPolicy, 4, 4, 4);
    defer workspace.deinit();
    const request_pointer = workspace.request.ptr;
    const result_pointer = workspace.result.ptr;
    inline for (.{ canvas.RenderPipelineCachePlanner, canvas.RenderPathGeometryCachePlanner, canvas.RenderImageCachePlanner, canvas.RenderLayerCachePlanner, canvas.RenderResourceCachePlanner, canvas.VisualEffectCachePlanner }, .{ canvas.RenderBatchPlan, canvas.RenderPathGeometryPlan, canvas.RenderImagePlan, canvas.RenderLayerPlan, canvas.RenderResourcePlan, canvas.VisualEffectPlan }) |Planner, Plan| {
        var entries: [1]@typeInfo(@FieldType(Planner, "entries")).pointer.child = undefined;
        var actions: [1]@typeInfo(@FieldType(Planner, "actions")).pointer.child = undefined;
        var planner = Planner.init(&entries, &actions);
        _ = try planner.buildCompiled(Plan{}, &.{}, 9007199254740993, &workspace);
        try std.testing.expect(workspace.request.ptr == request_pointer and workspace.result.ptr == result_pointer);
        try std.testing.expectEqualSlices(u8, before, borrowed);
    }
}

const Storage = struct {
    value: canvas.CanvasFrameStorage,
    fn init() !Storage {
        var result: Storage = undefined;
        inline for (@typeInfo(canvas.CanvasFrameStorage).@"struct".fields) |field| {
            const E = @typeInfo(field.type).pointer.child;
            const buffer = try std.testing.allocator.alloc(E, 64);
            @memset(std.mem.sliceAsBytes(buffer), 0);
            @field(result.value, field.name) = buffer;
        }
        return result;
    }
    fn deinit(self: Storage) void {
        inline for (@typeInfo(canvas.CanvasFrameStorage).@"struct".fields) |field| std.testing.allocator.free(@field(self.value, field.name));
    }
};
const path_elements = [_]canvas.PathElement{ .{ .verb = .move_to, .points = .{ .init(2, 2), .{}, .{} } }, .{ .verb = .line_to, .points = .{ .init(20, 20), .{}, .{} } }, .{ .verb = .line_to, .points = .{ .init(2, 20), .{}, .{} } }, .{ .verb = .close } };
const scene = [_]canvas.CanvasCommand{
    .{ .push_opacity = 0.5 },
    .{ .fill_path = .{ .id = 1, .elements = &path_elements, .fill = .{ .color = canvas.Color.rgb8(20, 40, 60) } } },
    .{ .draw_image = .{ .id = 2, .image_id = 9, .dst = .init(20, 20, 30, 30) } },
    .{ .shadow = .{ .id = 3, .rect = .init(20, 20, 30, 30), .blur = 3, .color = canvas.Color.rgb8(0, 0, 0) } },
    .{ .blur = .{ .id = 4, .rect = .init(40, 40, 30, 30), .radius = 2 } },
    .pop_opacity,
};
var family_calls: [6]usize = .{0} ** 6;
var planning_calls: [2]usize = .{0} ** 2;
fn observedPolicy(request: []const u8, output: []u8) usize {
    if (request[0] == 12) family_calls[request[1]] += 1;
    if (request[0] == 13) planning_calls[request[1]] += 1;
    return core.nativeWindowPolicy(request, output);
}

test "both runtime frame consumers use compiled state batching and all six caches and preserve complete warm changed and empty frames" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const native = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer native.destroy(std.testing.allocator);
    const compiled = try sdk.runtime.TestHarness().create(std.testing.allocator, .{});
    defer compiled.destroy(std.testing.allocator);
    var context: u8 = 0;
    for ([_]@TypeOf(native){ native, compiled }, 0..) |h, lane| {
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = &context, .name = "cache-parity", .source = sdk.platform.WebViewSource.html(""), .render_cache_policy = if (lane == 1) observedPolicy else null, .render_plan_policy = if (lane == 1) observedPolicy else null });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 160, 120) });
    }
    try std.testing.expect(compiled.runtime.render_cache_policy == observedPolicy);
    try std.testing.expect(compiled.runtime.render_plan_policy == observedPolicy);
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    var changed = scene;
    changed[2].draw_image.image_id = 10;
    changed[3].shadow.blur = 4;
    for ([_][]const canvas.CanvasCommand{ &scene, &scene, &changed, &.{} }, 0..) |commands, phase| {
        for ([_]@TypeOf(native){ native, compiled }) |h| _ = try h.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = commands });
        const options = canvas.CanvasFrameOptions{ .frame_index = 9007199254740993 + phase, .timestamp_ns = 33, .full_repaint = true };
        family_calls = .{0} ** 6;
        planning_calls = .{0} ** 2;
        const diagnostic = try native.runtime.canvasFramePlan(1, "canvas", null, options, a.value);
        try frameEqual(diagnostic, try compiled.runtime.canvasFramePlan(1, "canvas", null, options, b.value));
        try exact([_]usize{1} ** 6, family_calls);
        try exact([_]usize{ 1, 1 }, planning_calls);
        family_calls = .{0} ** 6;
        planning_calls = .{0} ** 2;
        const presentation = try native.runtime.nextCanvasFrame(1, "canvas", options, a.value);
        try frameEqual(presentation, try compiled.runtime.nextCanvasFrame(1, "canvas", options, b.value));
        try exact([_]usize{1} ** 6, family_calls);
        try exact([_]usize{ 1, 1 }, planning_calls);
        if (phase < 3) {
            try std.testing.expect(presentation.pipeline_cache_plan.entries.len > 0);
            try std.testing.expect(presentation.path_geometry_cache_plan.entries.len > 0);
            try std.testing.expect(presentation.image_cache_plan.entries.len > 0);
            try std.testing.expect(presentation.layer_cache_plan.entries.len > 0);
            try std.testing.expect(presentation.resource_cache_plan.entries.len > 0);
            try std.testing.expect(presentation.visual_effect_cache_plan.entries.len > 0);
        }
        core.rt.frameReset();
    }
}

test "frame cache failure preserves action-before-entry storage and prevents downstream extraction" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const list = canvas.DisplayList{ .commands = &scene };
    var sa = a.value;
    var sb = b.value;
    sa.pipeline_cache_entries = sa.pipeline_cache_entries[0..0];
    sb.pipeline_cache_entries = sb.pipeline_cache_entries[0..0];
    sa.pipeline_cache_actions = sa.pipeline_cache_actions[0..1];
    sb.pipeline_cache_actions = sb.pipeline_cache_actions[0..1];
    // Later resource extraction is also too small. Pipeline failure must win.
    sa.resources = sa.resources[0..0];
    sb.resources = sb.resources[0..0];
    try std.testing.expectError(error.RenderPipelineCacheListFull, list.framePlan(null, .{}, sa));
    family_calls = .{0} ** 6;
    try std.testing.expectError(error.RenderPipelineCacheListFull, list.framePlan(null, .{ .render_cache_policy = observedPolicy }, sb));
    try exact([_]usize{ 1, 0, 0, 0, 0, 0 }, family_calls);
    try exact(a.value, b.value);
    try std.testing.expectEqual(@as(@TypeOf(b.value.pipeline_cache_actions[0].kind), .upload), b.value.pipeline_cache_actions[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), b.value.pipeline_cache_actions[0].batch_index);
}

test "render state batching and six cache cost include frame buffers copying and reset" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var storage = try Storage.init();
    defer storage.deinit();
    const list = canvas.DisplayList{ .commands = &scene };
    const warm = try list.framePlan(null, .{}, storage.value);
    // Keep warm native records separate from the next frame's mutable storage.
    var output = try Storage.init();
    defer output.deinit();
    const options = canvas.CanvasFrameOptions{ .previous_pipeline_cache = warm.pipeline_cache_plan.entries, .previous_path_geometry_cache = warm.path_geometry_cache_plan.entries, .previous_image_cache = warm.image_cache_plan.entries, .previous_layer_cache = warm.layer_cache_plan.entries, .previous_resource_cache = warm.resource_cache_plan.entries, .previous_visual_effect_cache = warm.visual_effect_cache_plan.entries };
    for ([_]?*const fn ([]const u8, []u8) usize{ null, core.nativeWindowPolicy }, 0..) |policy, lane| {
        var selected = options;
        selected.render_cache_policy = policy;
        selected.render_plan_policy = policy;
        const begin = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..100) |_| {
            const frame = try list.framePlan(null, selected, output.value);
            std.mem.doNotOptimizeAway(frame);
            core.rt.frameReset();
        }
        std.debug.print("render-and-cache complete frame lane {d}: {d} ns (including frame buffers, copying and enclosing reset)\n", .{ lane, @divTrunc(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - begin, 100) });
    }
}

fn frameEqual(a: canvas.CanvasFrame, b: canvas.CanvasFrame) !void {
    inline for (@typeInfo(canvas.CanvasFrame).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "dirty_rects")) try exact(@field(a, field.name), @field(b, field.name));
    }
    // The fixed backing array is undefined past the published count.
    try exact(a.dirtyRects(), b.dirtyRects());
}

test "render and batch failures precede every cache and preserve complete frame storage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const list = canvas.DisplayList{ .commands = &scene };
    for ([_]bool{ false, true }) |batch| {
        var sa = a.value;
        var sb = b.value;
        if (batch) {
            sa.render_batches = sa.render_batches[0..0];
            sb.render_batches = sb.render_batches[0..0];
        } else {
            sa.render_commands = sa.render_commands[0..0];
            sb.render_commands = sb.render_commands[0..0];
        }
        sa.pipeline_cache_entries = sa.pipeline_cache_entries[0..0];
        sb.pipeline_cache_entries = sb.pipeline_cache_entries[0..0];
        const err = if (batch) error.RenderBatchListFull else error.RenderListFull;
        try std.testing.expectError(err, list.framePlan(null, .{}, sa));
        family_calls = .{0} ** 6;
        planning_calls = .{0} ** 2;
        try std.testing.expectError(err, list.framePlan(null, .{ .render_cache_policy = observedPolicy, .render_plan_policy = observedPolicy }, sb));
        try exact([_]usize{0} ** 6, family_calls);
        try exact([_]usize{ 1, @intFromBool(batch) }, planning_calls);
        try exact(a.value, b.value);
        core.rt.frameReset();
    }
}

test "render planning and cache ownership remain independently selectable" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a = try Storage.init();
    defer a.deinit();
    var b = try Storage.init();
    defer b.deinit();
    const list = canvas.DisplayList{ .commands = &scene };
    const reference = try list.framePlan(null, .{}, a.value);
    for ([_]bool{ false, true }) |plan| {
        family_calls = .{0} ** 6;
        planning_calls = .{0} ** 2;
        const compiled = try list.framePlan(null, .{ .render_cache_policy = if (plan) null else observedPolicy, .render_plan_policy = if (plan) observedPolicy else null }, b.value);
        try frameEqual(reference, compiled);
        try exact([_]usize{if (plan) 0 else 1} ** 6, family_calls);
        try exact([_]usize{if (plan) 1 else 0} ** 2, planning_calls);
        core.rt.frameReset();
    }
}
