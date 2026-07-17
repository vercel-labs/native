//! Runtime canvas image registry tests: registration lifecycle and
//! capacity bounds, the platform decode seam (through the null
//! platform's deterministic strict-PNG decoder), reference-renderer
//! pixel goldens fed by raw RGBA fixtures, and the UiApp avatar path
//! (initials fallback until `fx.registerImageBytes` succeeds).

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const canvas_limits = @import("canvas_limits.zig");
const effects_mod = @import("effects.zig");
const ui_app_model = @import("ui_app.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;

fn startedGpuHarness(allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try TestHarness().create(allocator, .{ .size = geometry.SizeF.init(240, 140) });
    errdefer harness.destroy(allocator);
    harness.null_platform.gpu_surfaces = true;
    return harness;
}

const RegistryApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "canvas-image-registry", .source = platform.WebViewSource.html("<h1>Images</h1>") };
    }
};

test "canvas image registry registers, replaces, and unregisters" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    try harness.runtime.registerCanvasImage(7, 1, 1, &red);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasImageCount());
    const info = harness.runtime.registeredCanvasImage(7).?;
    try std.testing.expectEqual(@as(usize, 1), info.width);
    try std.testing.expectEqual(@as(usize, 1), info.height);
    try std.testing.expectEqualSlices(u8, &red, harness.runtime.registeredCanvasImages()[0].pixels);

    // Re-registering the same id replaces the pixels in place.
    try harness.runtime.registerCanvasImage(7, 1, 1, &blue);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasImageCount());
    try std.testing.expectEqualSlices(u8, &blue, harness.runtime.registeredCanvasImages()[0].pixels);

    // Unregister frees the slot exactly once.
    try std.testing.expect(harness.runtime.unregisterCanvasImage(7));
    try std.testing.expect(!harness.runtime.unregisterCanvasImage(7));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasImageCount());
    try std.testing.expect(harness.runtime.registeredCanvasImage(7) == null);
}

test "canvas image registry validates ids, dimensions, and capacity" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    const pixel = [_]u8{ 1, 2, 3, 255 };
    try std.testing.expectError(error.InvalidImageId, harness.runtime.registerCanvasImage(0, 1, 1, &pixel));
    try std.testing.expectError(error.InvalidImageDimensions, harness.runtime.registerCanvasImage(1, 0, 1, &pixel));
    try std.testing.expectError(error.InvalidImageDimensions, harness.runtime.registerCanvasImage(1, 2, 1, &pixel));

    // Over the per-image slot bound: fails loudly, registers nothing.
    const oversized_bytes = canvas_limits.max_registered_canvas_image_pixel_bytes + 4;
    const oversized = try std.testing.allocator.alloc(u8, oversized_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.ImageTooLarge, harness.runtime.registerCanvasImage(1, oversized_bytes / 4, 1, oversized));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasImageCount());

    // Fill every slot; the next distinct id overflows, while replacing a
    // registered id still succeeds at capacity.
    var id: canvas.ImageId = 1;
    while (id <= canvas_limits.max_registered_canvas_images) : (id += 1) {
        try harness.runtime.registerCanvasImage(id, 1, 1, &pixel);
    }
    try std.testing.expectEqual(canvas_limits.max_registered_canvas_images, harness.runtime.registeredCanvasImageCount());
    try std.testing.expectError(error.ImageRegistryFull, harness.runtime.registerCanvasImage(id, 1, 1, &pixel));
    try harness.runtime.registerCanvasImage(3, 1, 1, &pixel);

    // Freeing one slot makes room again.
    try std.testing.expect(harness.runtime.unregisterCanvasImage(5));
    try harness.runtime.registerCanvasImage(id, 1, 1, &pixel);
    try std.testing.expectEqual(canvas_limits.max_registered_canvas_images, harness.runtime.registeredCanvasImageCount());
}

test "registered images draw through the reference renderer screenshot" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    // Raw RGBA fixture: 2x2 quadrant colors drawn with nearest sampling,
    // so each destination quadrant is one exact color.
    const fixture = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   255,
        0,   0,   255, 255, 255, 255, 0,   255,
    };
    try harness.runtime.registerCanvasImage(42, 2, 2, &fixture);

    var commands: [1]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawImage(.{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(20, 20, 40, 40),
        .sampling = .nearest,
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, "canvas", null);
    const pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, "canvas", null, pixels, scratch);

    // Golden quadrant probes: fixture texel colors land exactly where the
    // draw put them.
    const expectations = [_]struct { x: usize, y: usize, rgba: [4]u8 }{
        .{ .x = 30, .y = 30, .rgba = .{ 255, 0, 0, 255 } },
        .{ .x = 50, .y = 30, .rgba = .{ 0, 255, 0, 255 } },
        .{ .x = 30, .y = 50, .rgba = .{ 0, 0, 255, 255 } },
        .{ .x = 50, .y = 50, .rgba = .{ 255, 255, 0, 255 } },
    };
    for (expectations) |expectation| {
        const offset = (expectation.y * screenshot.width + expectation.x) * 4;
        try std.testing.expectEqualSlices(u8, &expectation.rgba, screenshot.rgba8[offset .. offset + 4]);
    }

    // A rounded draw (the avatar circle mask) keeps the center and cuts
    // the corners, in the same reference pass goldens use.
    var masked_commands: [1]canvas.CanvasCommand = undefined;
    var masked_builder = canvas.Builder.init(&masked_commands);
    try masked_builder.drawImage(.{
        .id = 2,
        .image_id = 42,
        .dst = geometry.RectF.init(20, 20, 40, 40),
        .sampling = .nearest,
        .radius = canvas.Radius.all(20),
    });
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", masked_builder.displayList());
    const masked = try harness.runtime.renderCanvasScreenshot(1, "canvas", null, pixels, scratch);
    const center = (40 * masked.width + 30) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, masked.rgba8[center .. center + 4]);
    const corner = (21 * masked.width + 21) * 4;
    try std.testing.expect(!std.mem.eql(u8, &[_]u8{ 255, 0, 0, 255 }, masked.rgba8[corner .. corner + 4]));

    // Unregistering removes the pixels from the next rendered frame.
    try std.testing.expect(harness.runtime.unregisterCanvasImage(42));
    const second = try harness.runtime.renderCanvasScreenshot(1, "canvas", null, pixels, scratch);
    const probe = (30 * second.width + 30) * 4;
    try std.testing.expect(!std.mem.eql(u8, &[_]u8{ 255, 0, 0, 255 }, second.rgba8[probe .. probe + 4]));
}

test "registerCanvasImageBytes decodes through the platform seam" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    var fixture: [3 * 2 * 4]u8 = undefined;
    var seed: u8 = 17;
    for (&fixture) |*byte| {
        byte.* = seed;
        seed = seed *% 29 +% 3;
    }
    var encoded_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try canvas.png.writeRgba8(&writer, 3, 2, &fixture);
    const encoded = writer.buffered();

    // Codec-less platforms surface the missing seam, never a silent no-op.
    try std.testing.expectError(error.UnsupportedService, harness.runtime.registerCanvasImageBytes(9, encoded));

    harness.null_platform.image_decode = true;
    const info = try harness.runtime.registerCanvasImageBytes(9, encoded);
    try std.testing.expectEqual(@as(usize, 3), info.width);
    try std.testing.expectEqual(@as(usize, 2), info.height);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.image_decode_count);

    // The decoded registration is byte-exact against the raw fixture.
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqual(@as(canvas.ImageId, 9), resources[0].id);
    try std.testing.expectEqualSlices(u8, &fixture, resources[0].pixels);

    // Undecodable bytes fail loudly and leave the registry unchanged.
    try std.testing.expectError(error.ImageDecodeFailed, harness.runtime.registerCanvasImageBytes(10, "not an image"));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasImageCount());
    try std.testing.expectError(error.InvalidImageId, harness.runtime.registerCanvasImageBytes(0, encoded));
}

test "registerCanvasImageBytes refuses reserved media-surface ids before decoding" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());
    harness.null_platform.image_decode = true;

    const fixture = [_]u8{ 255, 0, 0, 255 };
    var encoded_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try canvas.png.writeRgba8(&writer, 1, 1, &fixture);
    const encoded = writer.buffered();

    // An id inside the reserved media-surface texture namespace is
    // refused as an invalid id — not surfaced as a codec error — and
    // the refusal happens before the platform decoder ever runs.
    const reserved_id: canvas.ImageId = canvas.media_surface_image_id_bit | 9;
    try std.testing.expectError(error.InvalidImageId, harness.runtime.registerCanvasImageBytes(reserved_id, encoded));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.image_decode_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasImageCount());

    // The same bytes under an ordinary id decode and register fine.
    _ = try harness.runtime.registerCanvasImageBytes(9, encoded);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.image_decode_count);
}

// ---------------------------------------------------------------- avatar app

const avatar_canvas_label = "avatar-canvas";
const avatar_image_id: canvas.ImageId = 77;

/// Encoded bytes the fixture app "fetched"; set per test before
/// dispatching `.load` (module state because update fns capture nothing).
var avatar_fetched_bytes: []const u8 = &.{};

const AvatarModel = struct {
    image: canvas.ImageId = 0,
    failed: bool = false,
};

const AvatarMsg = union(enum) {
    load,
};

const AvatarApp = ui_app_model.UiApp(AvatarModel, AvatarMsg);

fn avatarUpdate(model: *AvatarModel, msg: AvatarMsg, fx: *effects_mod.Effects(AvatarMsg)) void {
    switch (msg) {
        .load => {
            // The remote-avatar path: fetched bytes -> decode+register ->
            // ImageId in the model only on success, so the view keeps the
            // initials fallback while loading or after a failure.
            _ = fx.registerImageBytes(avatar_image_id, avatar_fetched_bytes) catch {
                model.failed = true;
                return;
            };
            model.image = avatar_image_id;
        },
    }
}

fn avatarView(ui: *AvatarApp.Ui, model: *const AvatarModel) AvatarApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.avatar(.{ .image = model.image, .semantics = .{ .label = "Native SDK" } }, "NS"),
        ui.button(.{ .on_press = .load }, "Load"),
    });
}

const avatar_views = [_]app_manifest.ShellView{
    .{ .label = avatar_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const avatar_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Avatar",
    .width = 240,
    .height = 200,
    .views = &avatar_views,
}};
const avatar_scene: app_manifest.ShellConfig = .{ .windows = &avatar_windows };

fn avatarOptions() AvatarApp.Options {
    return .{
        .name = "ui-app-avatar",
        .scene = avatar_scene,
        .canvas_label = avatar_canvas_label,
        .update_fx = avatarUpdate,
        .view = avatarView,
    };
}

fn retainedAvatarImageId(runtime: *core.Runtime) !canvas.ImageId {
    const layout = try runtime.canvasWidgetLayout(1, avatar_canvas_label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .avatar) return node.widget.image_id;
    }
    return error.TestUnexpectedResult;
}

fn avatarScreenshotContains(runtime: *core.Runtime, allocator: std.mem.Allocator, rgba: [4]u8) !bool {
    const pixel_size = try runtime.canvasScreenshotPixelSize(1, avatar_canvas_label, null);
    const pixels = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(pixels);
    const scratch = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(scratch);
    const screenshot = try runtime.renderCanvasScreenshot(1, avatar_canvas_label, null, pixels, scratch);
    var offset: usize = 0;
    while (offset < screenshot.rgba8.len) : (offset += 4) {
        if (std.mem.eql(u8, &rgba, screenshot.rgba8[offset .. offset + 4])) return true;
    }
    return false;
}

fn findAvatarButtonId(tree: AvatarApp.Ui.Tree) ?canvas.ObjectId {
    return findKindTextIn(tree.root, .button, "Load");
}

fn findKindTextIn(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindTextIn(child, kind, text)) |id| return id;
    }
    return null;
}

test "avatar app falls back to initials until fetched bytes register" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.image_decode = true;

    const app_state = try std.testing.allocator.create(AvatarApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = AvatarApp.init(std.testing.allocator, .{}, avatarOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = avatar_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // Loading state: no image registered, the avatar renders initials.
    const avatar_red = [4]u8{ 250, 20, 20, 255 };
    try std.testing.expectEqual(@as(canvas.ImageId, 0), try retainedAvatarImageId(&harness.runtime));
    try std.testing.expect(!try avatarScreenshotContains(&harness.runtime, std.testing.allocator, avatar_red));

    // A failed fetch/decode keeps the fallback: the model never learns the id.
    avatar_fetched_bytes = "definitely not a png";
    const load_id = findAvatarButtonId(app_state.tree.?).?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ avatar_canvas_label, load_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expect(app_state.model.failed);
    try std.testing.expectEqual(@as(canvas.ImageId, 0), try retainedAvatarImageId(&harness.runtime));

    // "Fetched" bytes arrive: a solid PNG registered under the id swaps
    // the initials for pixels on the next retained frame.
    var fixture: [32 * 32 * 4]u8 = undefined;
    var offset: usize = 0;
    while (offset < fixture.len) : (offset += 4) {
        @memcpy(fixture[offset .. offset + 4], &avatar_red);
    }
    var encoded_buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_buffer);
    try canvas.png.writeRgba8(&writer, 32, 32, &fixture);
    avatar_fetched_bytes = writer.buffered();

    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(avatar_image_id, app_state.model.image);
    try std.testing.expectEqual(avatar_image_id, try retainedAvatarImageId(&harness.runtime));
    try std.testing.expect(harness.runtime.registeredCanvasImage(avatar_image_id) != null);
    try std.testing.expect(try avatarScreenshotContains(&harness.runtime, std.testing.allocator, avatar_red));
}
