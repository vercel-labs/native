//! Complete synchronous installation results against an independent native
//! caller, using the real registry and platform codec boundary on both sides.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("boot_images_core");
const parity = @import("effects_media_parity.zig");
const testing = std.testing;
const Adapter = sdk.TsUiApp(core);
const NativeReport = struct {
    id: u64 = 0,
    registered: bool = false,
    width: usize = 0,
    height: usize = 0,
    failure: ?anyerror = null,
};
const NativeModel = struct {
    reports: [32]NativeReport = @splat(.{}),
    count: usize = 0,
    booted: bool = false,
    boot_report_count: usize = 0,
};
const NativeMsg = union(enum) { noop, other };
const NativeApp = sdk.UiApp(NativeModel, NativeMsg);
const views = [_]sdk.ShellView{.{ .label = "images-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Boot Images", .width = 320, .height = 240, .views = &views }};
const scene: sdk.ShellConfig = .{ .windows = &windows };
var images: []const Adapter.BootImage = &.{};
var native_first_view: ?usize = null;
var compiled_first_view: ?usize = null;

fn nativeBoot(model: *NativeModel, fx: *NativeApp.Effects) void {
    for (images) |image| {
        var report: NativeReport = .{ .id = image.id };
        if (fx.registerImageBytes(image.id, image.bytes)) |result| {
            report.registered = true;
            report.width = result.width;
            report.height = result.height;
        } else |err| report.failure = err;
        if (image.id == 41) continue;
        model.reports[model.count] = report;
        model.count += 1;
    }
    // The compiled initial command reads the same journaled clock after
    // registration. Its reply observes all committed registration results.
    _ = fx.wallMs();
    model.booted = true;
    model.boot_report_count = model.count;
}
fn nativeUpdate(_: *NativeModel, _: NativeMsg) void {}
fn nativeView(ui: *NativeApp.Ui, model: *const NativeModel) NativeApp.Ui.Node {
    if (native_first_view == null) native_first_view = model.count;
    return ui.column(.{}, .{ui.text(.{}, "Boot Images")});
}
fn CompiledView(comptime Bridge: type) type {
    return struct {
        fn build(ui: *Bridge.Ui, model: *const Bridge.Model) Bridge.Ui.Node {
            if (compiled_first_view == null) compiled_first_view = @intCast(model.reportCount());
            return ui.column(.{}, .{ui.text(.{}, "Boot Images")});
        }
    };
}

fn compareReports(expected: *const NativeModel) !void {
    const actual = core.snapshotModel();
    try testing.expectEqual(expected.count, actual.reports.len);
    try testing.expectEqual(expected.booted, actual.booted);
    try testing.expectEqual(@as(i64, @intCast(expected.boot_report_count)), actual.bootReportCount);
    for (expected.reports[0..expected.count], actual.reports) |report, got| {
        var decimal: [20]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&decimal, "{d}", .{report.id}), got.id);
        try testing.expectEqual(report.registered, got.registered);
        try testing.expectEqual(@as(f64, @floatFromInt(report.width)), got.width);
        try testing.expectEqual(@as(f64, @floatFromInt(report.height)), got.height);
        try testing.expectEqualStrings(if (report.failure) |err| @errorName(err) else "", got.errorName);
    }
}

fn pairedInstallation(comptime optimized: bool, codec: bool, assets: []const Adapter.BootImage) !void {
    const Bridge = sdk.TsUiAppWithFeatures(core, .{ .runtime_markup = false, .compiled_model = optimized });
    images = assets;
    defer images = &.{};
    native_first_view = null;
    compiled_first_view = null;
    const native = try NativeApp.create(testing.allocator, .{
        .name = "boot-images", .scene = scene, .canvas_label = "images-canvas",
        .update = nativeUpdate, .init_fx = nativeBoot, .view = nativeView,
    });
    defer native.destroy();
    var boot_images: [32]Bridge.BootImage = undefined;
    for (assets, 0..) |asset, index| boot_images[index] = .{ .id = asset.id, .bytes = asset.bytes };
    const compiled = try Bridge.create(testing.allocator, .{ .boot_images = boot_images[0..assets.len] }, .{
        .name = "boot-images", .scene = scene, .canvas_label = "images-canvas", .view = CompiledView(Bridge).build,
    });
    defer compiled.destroy();
    const left = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(320, 240) });
    defer left.destroy(testing.allocator);
    const right = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(320, 240) });
    defer right.destroy(testing.allocator);
    left.null_platform.gpu_surfaces = true;
    right.null_platform.gpu_surfaces = true;
    left.null_platform.image_decode = codec;
    right.null_platform.image_decode = codec;
    try left.start(native.app());
    try right.start(compiled.app());
    left.runtime.started_timestamp_ns = 0;
    right.runtime.started_timestamp_ns = 0;
    left.runtime.views[0].gpu_surface_created_timestamp_ns = 1;
    right.runtime.views[0].gpu_surface_created_timestamp_ns = 1;
    for (1..3) |ordinal| {
        const frame: sdk.platform.GpuSurfaceFrameEvent = .{ .label = "images-canvas", .size = .init(320, 240), .frame_index = ordinal, .timestamp_ns = ordinal * 16_666_667, .frame_interval_ns = 16_666_667 };
        try left.runtime.dispatchPlatformEvent(native.app(), .{ .gpu_surface_frame = frame });
        try right.runtime.dispatchPlatformEvent(compiled.app(), .{ .gpu_surface_frame = frame });
        try compareReports(&native.model);
        try testing.expectEqual(native_first_view, compiled_first_view);
        try testing.expectEqual(@as(?usize, native.model.count), compiled_first_view);
        try parity.equal(left.runtime.registeredCanvasImages(), right.runtime.registeredCanvasImages());
        try parity.equal(left.runtime.automationSnapshot("boot-images"), right.runtime.automationSnapshot("boot-images"));
        try parity.equal((try left.runtime.canvasDisplayList(1, "images-canvas")).commands, (try right.runtime.canvasDisplayList(1, "images-canvas")).commands);
        try testing.expectEqual(left.null_platform.image_decode_count, right.null_platform.image_decode_count);
        try testing.expectEqual(@as(usize, 0), compiled.effects.pendingImageLoadCount());
        try testing.expectEqual(@as(usize, 0), compiled.effects.pendingHostCount());
        try testing.expectEqual(@as(usize, 0), compiled.effects.pendingTimerCount());
        try parity.equal(native.effects.windowActionState(), compiled.effects.windowActionState());
        // A subsequent helper and frame reset must not invalidate IDs,
        // error names, report storage, or registry-owned pixels.
        const saved = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(saved);
        _ = core.snapshotModel().reportCount();
        core.rt.frameReset();
        try compareReports(&native.model);
        try testing.expectEqualSlices(u8, saved, core.persistenceSnapshot());
    }
}

fn replayInstallation(comptime optimized: bool, codec: bool) !void {
    const Bridge = sdk.TsUiAppWithFeatures(core, .{ .runtime_markup = false, .compiled_model = optimized });
    const pixels = [_]u8{ 17, 29, 255, 255, 0, 255, 19, 128 };
    var encoded_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try sdk.canvas.png.writeRgba8(&writer, 2, 1, &pixels);
    const assets = [_]Bridge.BootImage{
        .{ .id = 7, .bytes = writer.buffered() },
        .{ .id = 23, .bytes = "not an image" },
        .{ .id = 0, .bytes = writer.buffered() },
        .{ .id = 41, .bytes = writer.buffered() },
    };
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    var recorder = sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "boot-images", 320, 240));
    var fingerprint: u64 = 0;
    var saved: ?[]u8 = null;
    defer if (saved) |bytes| testing.allocator.free(bytes);
    var resources: []sdk.canvas.ReferenceImage = &.{};
    defer {
        for (resources) |resource| testing.allocator.free(resource.pixels);
        testing.allocator.free(resources);
    }
    {
        const state = try Bridge.create(testing.allocator, .{ .boot_images = &assets }, .{
            .name = "boot-images", .scene = scene, .canvas_label = "images-canvas", .view = CompiledView(Bridge).build,
        });
        defer state.destroy();
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(320, 240) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.image_decode = codec;
        harness.runtime.options.session_recorder = &recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = "images-canvas", .size = .init(320, 240), .frame_index = 1 } });
        fingerprint = harness.runtime.sessionStateFingerprint();
        saved = try testing.allocator.dupe(u8, core.modelSnapshot());
        const registered = harness.runtime.registeredCanvasImages();
        resources = try testing.allocator.alloc(sdk.canvas.ReferenceImage, registered.len);
        @memset(resources, .{ .id = 0, .width = 0, .height = 0, .pixels = &.{} });
        for (resources, registered) |*resource, original| {
            const pixels_copy = try testing.allocator.dupe(u8, original.pixels);
            resource.* = original;
            resource.pixels = pixels_copy;
        }
        recorder.finish();
        try testing.expect(!recorder.failed);
    }
    const state = try Bridge.create(testing.allocator, .{ .boot_images = &assets }, .{
        .name = "boot-images", .scene = scene, .canvas_label = "images-canvas", .view = CompiledView(Bridge).build,
    });
    defer state.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(320, 240) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = codec;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    try testing.expectEqualSlices(u8, saved.?, core.modelSnapshot());
    try parity.equal(resources, harness.runtime.registeredCanvasImages());
}

test "complete boot image results and native pixels survive sealed replay in both model representations" {
    inline for (.{ false, true }) |optimized| {
        try replayInstallation(optimized, false);
        try replayInstallation(optimized, true);
    }
}

test "synchronous boot reports preserve exact native IDs, failures, replacements and first-frame ordering" {
    var pixels: [3 * 2 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @intCast((index * 29 + 17) % 256);
    var encoded_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try sdk.canvas.png.writeRgba8(&writer, 3, 2, &pixels);
    var second_buffer: [1024]u8 = undefined;
    var second = std.Io.Writer.fixed(&second_buffer);
    const blue = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    try sdk.canvas.png.writeRgba8(&second, 2, 1, &blue);
    const assets = [_]Adapter.BootImage{
        .{ .id = 0, .bytes = writer.buffered() },
        .{ .id = 1, .bytes = writer.buffered() },
        .{ .id = 9_007_199_254_740_993, .bytes = writer.buffered() },
        .{ .id = std.math.maxInt(u64), .bytes = writer.buffered() },
        .{ .id = 23, .bytes = "not an image" },
        .{ .id = 1, .bytes = second.buffered() },
        .{ .id = 1, .bytes = "bad replacement" },
        .{ .id = 41, .bytes = writer.buffered() },
    };
    inline for (.{ false, true }) |optimized| {
        try pairedInstallation(optimized, false, &assets);
        try pairedInstallation(optimized, true, &assets);
        try pairedInstallation(optimized, true, &.{});
    }
}
