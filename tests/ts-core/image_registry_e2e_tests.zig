const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Harness = sdk.TestHarness();
const policy = sdk.runtime.testing.image_registry_policy;
var modes: [9]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 82) modes[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        const pair = Pair{ .left = try Harness.create(std.testing.allocator, .{}), .right = try Harness.create(std.testing.allocator, .{}) };
        for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(.{ .context = h, .name = "image-registry", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            if (i == 1) h.runtime.image_registry_policy = observed;
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 200, 100) });
        }
        return pair;
    }
    fn destroy(self: Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
    }
    fn same(self: Pair) !void {
        @setEvalBranchQuota(10000);
        try exact(self.left.runtime.automationSnapshot("image-registry"), self.right.runtime.automationSnapshot("image-registry"));
        try exact(self.left.runtime.invalidated, self.right.runtime.invalidated);
        try exact(self.left.runtime.canvas_image_count, self.right.runtime.canvas_image_count);
        try exact(self.left.runtime.canvas_image_entries, self.right.runtime.canvas_image_entries);
        try exact(self.left.runtime.media_surface_count, self.right.runtime.media_surface_count);
        try exact(self.left.runtime.media_surface_entries, self.right.runtime.media_surface_entries);
        const a = self.left.runtime.registeredCanvasImages();
        const b = self.right.runtime.registeredCanvasImages();
        try exact(a, b);
        for (self.left.runtime.canvas_image_pixels, self.right.runtime.canvas_image_pixels) |x, y| try std.testing.expectEqual(x.len, y.len);
        for (self.left.runtime.media_surface_pixels, self.right.runtime.media_surface_pixels) |x, y| try std.testing.expectEqual(x.len, y.len);
        for (self.left.runtime.views[0..self.left.runtime.view_count], self.right.runtime.views[0..self.right.runtime.view_count]) |x, y| {
            try exact(x.presented_canvas_valid, y.presented_canvas_valid);
            try exact(x.gpu_canvas_frame_requested, y.gpu_canvas_frame_requested);
            try exact(x.canvas_frame_image_cache[0..x.canvas_frame_image_cache_count], y.canvas_frame_image_cache[0..y.canvas_frame_image_cache_count]);
        }
        try exact(self.left.null_platform.gpu_surface_frame_request_count, self.right.null_platform.gpu_surface_frame_request_count);
    }
};
test "compiled image registry preserves complete image lifetime, compaction and borrowed-byte ownership" {
    const pair = try Pair.create();
    defer pair.destroy();
    var pixel: [4]u8 = .{ 1, 2, 3, 255 };
    const ids = [_]u64{ 1, 9007199254740993, 0x7fffffffffffffff };
    for (ids) |id| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.registerCanvasImage(id, 1, 1, &pixel);
        try pair.same();
    }
    pixel[0] = 42;
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectEqual(@as(u8, 1), h.runtime.registeredCanvasImages()[0].pixels[0]);
        try h.runtime.registerCanvasImage(ids[1], 1, 1, &pixel);
        try std.testing.expectEqual(@as(usize, 1), h.runtime.registeredCanvasImage(ids[1]).?.width);
    }
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expect(h.runtime.unregisterCanvasImage(ids[0]));
        try std.testing.expect(!h.runtime.unregisterCanvasImage(ids[0]));
        try h.runtime.registerCanvasImage(19, 1, 1, &pixel);
    }
    try pair.same();
    try std.testing.expectEqual(ids[2], pair.right.runtime.canvas_image_entries[0].id);
    for ([_]usize{ 0, 2, std.math.maxInt(usize), std.math.maxInt(usize) / 4 + 1 }) |width| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.InvalidImageDimensions, h.runtime.registerCanvasImage(9, width, 1, &pixel));
        try pair.same();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.InvalidImageId, h.runtime.registerCanvasImage(0x8000000000000000, 0, 0, &.{}));
        try std.testing.expectError(error.InvalidImageId, h.runtime.registerCanvasImageBytes(0, &.{}));
        try std.testing.expectError(error.ImageDecodeFailed, h.runtime.registerCanvasImageBytes(29, &.{}));
    }
    try pair.same();
    for (modes[0..5]) |count| try std.testing.expect(count != 0);
}
test "compiled image registry preserves full replacement, frozen allocation ownership and refusal recovery" {
    const pair = try Pair.create();
    defer pair.destroy();
    const pixel = [_]u8{ 4, 5, 6, 255 };
    for (1..17) |id| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.registerCanvasImage(id, 1, 1, &pixel);
        try pair.same();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.ImageRegistryFull, h.runtime.registerCanvasImage(17, 1, 1, &pixel));
        try h.runtime.registerCanvasImage(2, 1, 1, &pixel);
        try std.testing.expect(h.runtime.unregisterCanvasImage(7));
        try h.runtime.registerCanvasImage(17, 1, 1, &pixel);
    }
    try pair.same();
}
test "compiled image registry preserves media adoption, repeated fingerprints, reclamation and video purge" {
    const pair = try Pair.create();
    defer pair.destroy();
    const pixel = [_]u8{ 10, 20, 30, 255 };
    for (1..8) |id| {
        // Process slots are shared: drain each lane's claim sequentially.
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            const producer = try h.runtime.acquireMediaSurfaceProducer(id);
            try producer.pushFrame(1, 1, &pixel);
            h.runtime.adoptMediaSurfaceFrames();
            try std.testing.expectEqual(@as(usize, 1), h.runtime.adoptedMediaSurfaceTexture(id).?.width);
            producer.release();
        }
        try pair.same();
    }
    // Reclaim is ordered, not insertion-time sorted; a repeated adopted
    // fingerprint leaves damage and allocation high-water marks unchanged.
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        const producer = try h.runtime.acquireMediaSurfaceProducer(7);
        try producer.pushFrame(1, 1, &pixel);
        h.runtime.adoptMediaSurfaceFrames();
        producer.release();
    }
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        const binding = h.runtime.mediaSurfaceBinding();
        const sink = try binding.acquire_fn(binding.context, 7);
        try std.testing.expect(h.runtime.adoptedMediaSurfaceTexture(7) == null);
        binding.release_fn(binding.context, sink);
    }
    try pair.same();
    for (modes[5..9]) |count| try std.testing.expect(count != 0);
}
test "compiled image registry transport preserves exact u64 fingerprints and ordered continuation" {
    const records = [_]policy.Record{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    var program = policy.plan(observed, .media_entry, &records, 4, .{ .id = 9007199254740993 });
    try std.testing.expectEqual(@as(?usize, 0), program.next);
    for (0..4) |cursor| {
        program = policy.plan(observed, .media_entry, &records, 4, .{ .id = 9007199254740993, .cursor = cursor, .facts = 3 });
        try std.testing.expectEqual(if (cursor < 3) @as(?usize, cursor + 1) else null, program.next);
    }
    for ([_]u64{ 0, 1, 9007199254740993, std.math.maxInt(u64) }) |fingerprint| {
        try std.testing.expectEqual(@as(u32, 64), policy.plan(observed, .media_equal, &.{}, 4, .{ .fingerprint = fingerprint, .previous_fingerprint = fingerprint }).action);
        try std.testing.expectEqual(@as(u32, 0), policy.plan(observed, .media_equal, &.{}, 4, .{ .fingerprint = fingerprint, .previous_fingerprint = fingerprint ^ 1 }).action);
    }
}
test "compiled image registry preserves allocation failure state and the original allocator lifetime" {
    for ([_]bool{ false, true }) |compiled| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var forbidden = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const h = try Harness.create(std.testing.allocator, .{});
        sdk.Runtime.initAt(&h.runtime, .{ .platform = h.null_platform.platform(), .trace_sink = h.trace_sink.sink(), .allocator = counting.allocator(), .environ = std.testing.environ });
        h.runtime.dispatch_error_policy = .propagate;
        try h.start(.{ .context = h, .name = "image-registry", .source = sdk.platform.WebViewSource.html("") });
        if (compiled) h.runtime.image_registry_policy = observed;
        h.runtime.options.allocator = forbidden.allocator();
        const red = [_]u8{ 255, 0, 0, 255 };
        const blue = [_]u8{ 0, 0, 255, 255 };
        try h.runtime.registerCanvasImage(1, 1, 1, &red);
        counting.fail_index = counting.alloc_index;
        try std.testing.expectError(error.OutOfMemory, h.runtime.registerCanvasImage(2, 1, 1, &blue));
        try std.testing.expectEqual(@as(usize, 1), h.runtime.canvas_image_count);
        try std.testing.expect(h.runtime.registeredCanvasImage(2) == null);
        try std.testing.expectEqualSlices(u8, &red, h.runtime.registeredCanvasImages()[0].pixels);
        try h.runtime.registerCanvasImage(1, 1, 1, &blue);
        counting.fail_index = std.math.maxInt(usize);
        try h.runtime.registerCanvasImage(2, 1, 1, &red);
        try std.testing.expectEqual(@as(usize, 2), counting.allocations);
        try std.testing.expect(h.runtime.unregisterCanvasImage(1));
        try h.runtime.registerCanvasImage(3, 1, 1, &blue);
        try std.testing.expectEqual(@as(usize, 2), counting.allocations);
        h.destroy(std.testing.allocator);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), forbidden.allocations);
        try std.testing.expectEqual(@as(usize, 0), forbidden.deallocations);
    }
}

test "compiled image registry preserves media allocation failure and byte-identical retry" {
    for ([_]bool{ false, true }) |compiled| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var forbidden = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const h = try Harness.create(std.testing.allocator, .{});
        sdk.Runtime.initAt(&h.runtime, .{ .platform = h.null_platform.platform(), .trace_sink = h.trace_sink.sink(), .allocator = counting.allocator(), .environ = std.testing.environ });
        try h.start(.{ .context = h, .name = "image-registry", .source = sdk.platform.WebViewSource.html("") });
        if (compiled) h.runtime.image_registry_policy = observed;
        h.runtime.options.allocator = forbidden.allocator();
        const producer = try h.runtime.acquireMediaSurfaceProducer(29);
        const pixel = [_]u8{ 10, 20, 30, 255 };
        try producer.pushFrame(1, 1, &pixel);
        counting.fail_index = counting.alloc_index;
        h.runtime.adoptMediaSurfaceFrames();
        try std.testing.expectEqual(@as(usize, 1), h.runtime.media_surface_count);
        try std.testing.expectEqual(@as(u64, 29), h.runtime.media_surface_entries[0].surface_id);
        try std.testing.expectEqual(@as(u64, 0), h.runtime.media_surface_entries[0].fingerprint);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.media_surface_pixels[0].len);
        try std.testing.expect(h.runtime.adoptedMediaSurfaceTexture(29) == null);
        counting.fail_index = std.math.maxInt(usize);
        try producer.pushFrame(1, 1, &pixel);
        h.runtime.adoptMediaSurfaceFrames();
        const adopted = h.runtime.adoptedMediaSurfaceTexture(29).?;
        try std.testing.expectEqual(@as(usize, 4), adopted.byte_len);
        try std.testing.expectEqualSlices(u8, &pixel, h.runtime.media_surface_pixels[0][0..adopted.byte_len]);
        try producer.pushFrame(1, 1, &pixel);
        h.runtime.adoptMediaSurfaceFrames();
        try std.testing.expectEqual(@as(usize, 1), counting.allocations);
        producer.release();
        h.destroy(std.testing.allocator);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), forbidden.allocations);
        try std.testing.expectEqual(@as(usize, 0), forbidden.deallocations);
    }
}

var repaint_runtime: *sdk.Runtime = undefined;
var repaint_calls: usize = 0;
fn shrinkingRepaint(_: ?*anyopaque, _: sdk.platform.WindowId, _: []const u8) anyerror!void {
    repaint_calls += 1;
    // A host callback changes the published extent. The original iterator
    // still visits its second slot and observes its current flags.
    repaint_runtime.view_count = 1;
}
test "compiled image registry retains repaint iterator extent across host callbacks" {
    for ([_]bool{ false, true }) |compiled| {
        const h = try Harness.create(std.testing.allocator, .{});
        defer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = h, .name = "image-registry", .source = sdk.platform.WebViewSource.html("") });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "first", .kind = .gpu_surface, .frame = .init(0, 0, 100, 100) });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = .init(0, 0, 100, 100) });
        if (compiled) h.runtime.image_registry_policy = observed;
        const extent = h.runtime.view_count;
        h.runtime.views[extent - 1].presented_canvas_valid = true;
        repaint_runtime = &h.runtime;
        repaint_calls = 0;
        const saved = h.runtime.options.platform.services.request_gpu_surface_frame_fn;
        h.runtime.options.platform.services.request_gpu_surface_frame_fn = shrinkingRepaint;
        try h.runtime.registerCanvasImage(1, 1, 1, &.{ 1, 2, 3, 255 });
        h.runtime.options.platform.services.request_gpu_surface_frame_fn = saved;
        h.runtime.view_count = extent;
        try std.testing.expectEqual(@as(usize, 1), repaint_calls);
        try std.testing.expect(!h.runtime.views[extent - 1].presented_canvas_valid);
    }
}
