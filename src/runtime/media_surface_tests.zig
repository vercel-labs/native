//! Media-surface texture channel tests: the synthetic producer battery.
//! Latest-wins staging under burst pushes, damage short-circuits at the
//! push and adoption boundaries, layout/clip compositing through the
//! widget tree, the reference renderer's deterministic placeholder (and
//! its independence from producer output), record/replay fingerprint
//! identity with NO producer attached, cross-thread pushes, and the
//! teardown discipline (a producer outliving its runtime pushes into
//! inert process-lived memory, never freed runtime state).

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const canvas_limits = @import("canvas_limits.zig");
const media_surface = @import("media_surface.zig");
const ui_app_mod = @import("ui_app.zig");
const session_record = @import("session_record.zig");
const session_replay = @import("session_replay.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;

const surface_id: u64 = 5;

fn startedGpuHarness(allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try TestHarness().create(allocator, .{ .size = geometry.SizeF.init(240, 140) });
    errdefer harness.destroy(allocator);
    harness.null_platform.gpu_surfaces = true;
    return harness;
}

const ProbeApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "media-surface-probe", .source = platform.WebViewSource.html("<h1>Media</h1>") };
    }
};

/// A tiny solid RGBA8 frame (2x2) in one color.
fn solidFrame(rgba: [4]u8) [16]u8 {
    var frame: [16]u8 = undefined;
    inline for (0..4) |pixel| @memcpy(frame[pixel * 4 .. pixel * 4 + 4], &rgba);
    return frame;
}

fn dispatchFrame(harness: *TestHarness(), app: App, frame_index: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(240, 140),
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

test "burst pushes stage latest-wins and the frame clock adopts the newest" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // A burst of three distinct frames between presents: nothing adopts
    // before the frame clock ticks, and the tick adopts ONLY the newest.
    const red = solidFrame(.{ 255, 0, 0, 255 });
    const green = solidFrame(.{ 0, 255, 0, 255 });
    const blue = solidFrame(.{ 0, 0, 255, 255 });
    try producer.pushFrame(2, 2, &red);
    try producer.pushFrame(2, 2, &green);
    try producer.pushFrame(2, 2, &blue);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);

    try dispatchFrame(harness, app, 1);
    const adopted = harness.runtime.adoptedMediaSurfaceTexture(surface_id).?;
    try std.testing.expectEqual(@as(usize, 2), adopted.width);
    try std.testing.expectEqual(@as(usize, 2), adopted.height);
    try std.testing.expect(adopted.fingerprint != 0);

    // The adopted texture rides the frame planner's resource set as a
    // presentation-only entry under the derived texture id, carrying
    // the newest (blue) pixels and its precomputed fingerprint.
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqual(canvas.mediaSurfaceTextureImageId(surface_id), resources[0].id);
    try std.testing.expect(resources[0].presentation_only);
    try std.testing.expectEqual(adopted.fingerprint, resources[0].content_fingerprint);
    try std.testing.expectEqualSlices(u8, &blue, resources[0].pixels);
}

test "unchanged frames short-circuit damage; changed frames invalidate and repaint" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    const gray = solidFrame(.{ 40, 40, 40, 255 });
    try producer.pushFrame(2, 2, &gray);
    try dispatchFrame(harness, app, 1);
    const first = harness.runtime.adoptedMediaSurfaceTexture(surface_id).?;

    // Identical bytes pushed again: adopted state, the invalidation
    // flag, and the prompt-frame request count all stay untouched.
    harness.runtime.invalidated = false;
    const requests_before = harness.null_platform.gpu_surface_frame_request_count;
    try producer.pushFrame(2, 2, &gray);
    try dispatchFrame(harness, app, 2);
    try std.testing.expectEqual(first.fingerprint, harness.runtime.adoptedMediaSurfaceTexture(surface_id).?.fingerprint);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(requests_before, harness.null_platform.gpu_surface_frame_request_count);

    // The ADOPTION boundary has its own gate: a fresh claim (whose
    // push-boundary memory reset with the claim) staging bytes that
    // match the adopted texture is dropped at adoption — no copy, no
    // invalidation.
    producer.release();
    const reclaimed = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer reclaimed.release();
    harness.runtime.invalidated = false;
    try reclaimed.pushFrame(2, 2, &gray);
    try dispatchFrame(harness, app, 3);
    try std.testing.expectEqual(first.fingerprint, harness.runtime.adoptedMediaSurfaceTexture(surface_id).?.fingerprint);
    try std.testing.expect(!harness.runtime.invalidated);
    try std.testing.expectEqual(requests_before, harness.null_platform.gpu_surface_frame_request_count);

    // A changed frame invalidates, requests a prompt repaint, and
    // re-fingerprints — the registered-image-swap contract.
    const white = solidFrame(.{ 255, 255, 255, 255 });
    try reclaimed.pushFrame(2, 2, &white);
    try dispatchFrame(harness, app, 4);
    const second = harness.runtime.adoptedMediaSurfaceTexture(surface_id).?;
    try std.testing.expect(second.fingerprint != first.fingerprint);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.null_platform.gpu_surface_frame_request_count > requests_before);
}

test "the producer channel is loud about ids, dimensions, claims, and exhaustion" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    try harness.start(app_state.app());

    // Surface ids: 0 and the reserved texture-namespace bit are refused.
    try std.testing.expectError(error.InvalidSurfaceId, harness.runtime.acquireMediaSurfaceProducer(0));
    try std.testing.expectError(error.InvalidSurfaceId, harness.runtime.acquireMediaSurfaceProducer(canvas.media_surface_image_id_bit | 3));
    // ...and the same bit is fenced off from canvas image registration,
    // so producer textures can never be shadowed by a registered image.
    const pixel = [_]u8{ 1, 2, 3, 255 };
    try std.testing.expectError(error.InvalidImageId, harness.runtime.registerCanvasImage(canvas.media_surface_image_id_bit | 3, 1, 1, &pixel));

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    // One live producer per (runtime, surface id).
    try std.testing.expectError(error.MediaSurfaceInUse, harness.runtime.acquireMediaSurfaceProducer(surface_id));

    // Frame validation mirrors the image registry's contract.
    try std.testing.expectError(error.InvalidFrameDimensions, producer.pushFrame(0, 1, &pixel));
    try std.testing.expectError(error.InvalidFrameDimensions, producer.pushFrame(2, 1, &pixel));
    const oversized_bytes = canvas_limits.max_media_surface_pixel_bytes + 4;
    const oversized = try std.testing.allocator.alloc(u8, oversized_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.FrameTooLarge, producer.pushFrame(oversized_bytes / 4, 1, oversized));

    // Exhaustion: every remaining process-wide slot claimed, the next
    // acquire fails loudly, and a release frees a slot for reuse.
    var extras: [canvas_limits.max_media_surface_channels - 1]media_surface.MediaSurfaceProducer = undefined;
    for (&extras, 0..) |*extra, index| {
        extra.* = try harness.runtime.acquireMediaSurfaceProducer(100 + index);
    }
    try std.testing.expectError(error.MediaSurfaceChannelsExhausted, harness.runtime.acquireMediaSurfaceProducer(999));
    extras[0].release();
    const reclaimed = try harness.runtime.acquireMediaSurfaceProducer(999);
    reclaimed.release();
    for (extras[1..]) |extra| extra.release();

    // A released handle (and any copy of it) is refused, idempotently.
    producer.release();
    const after = solidFrame(.{ 9, 9, 9, 255 });
    try std.testing.expectError(error.MediaSurfaceReleased, producer.pushFrame(2, 2, &after));
    producer.release();
}

// ----------------------------------------------- video-scale frames e2e

test "the producer frame budget and the host upload bound move in lockstep" {
    // The upload validation (platform.types.uploadGpuSurfaceImage) is
    // the one gate in front of every host's image store; if its
    // media-namespace bound ever drifted below the producer's frame
    // budget, a frame the producer accepted would be adopted and then
    // refused at presentation — the silent-downstream failure this pin
    // exists to prevent.
    try std.testing.expectEqual(canvas_limits.max_media_surface_pixel_bytes, platform.max_gpu_surface_media_image_pixel_bytes);
    // The budget's flagship claim: one 1080p RGBA8 frame fits.
    try std.testing.expect(1920 * 1080 * 4 <= canvas_limits.max_media_surface_pixel_bytes);
}

fn presentProbeFrame(harness: *TestHarness(), frame_index: u64) !core.CanvasPresentationResult {
    var gpu_commands: [64]canvas.CanvasGpuCommand = undefined;
    const packet_json_buffer = try std.testing.allocator.alloc(u8, platform.max_gpu_surface_packet_json_bytes);
    defer std.testing.allocator.free(packet_json_buffer);
    const pixels = try std.testing.allocator.alloc(u8, 240 * 140 * 4);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, 240 * 140 * 4);
    defer std.testing.allocator.free(scratch);
    return harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .surface_size = geometry.SizeF.init(240, 140),
        .scale = 1,
    }, support.canvasFrameScratchStorage(&harness.runtime), &gpu_commands, packet_json_buffer, pixels, scratch, canvas.Color.rgb8(0, 0, 0), null);
}

fn setMediaSurfaceDisplayList(harness: *TestHarness(), bound_surface_id: u64) !void {
    const commands = [_]canvas.CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 240, 140),
            .fill = .{ .color = canvas.mediaSurfacePlaceholderColor(bound_surface_id) },
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = canvas.mediaSurfaceTextureImageId(bound_surface_id),
            .dst = geometry.RectF.init(0, 0, 240, 140),
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
}

test "a real 1080p frame pushes, adopts, and presents through the packet upload path" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // The budget's headline case, end to end: a full 1920x1080 RGBA8
    // frame (8,294,400 bytes) — not a synthetic 2x2 — through push,
    // adoption, and the packet present's host upload.
    const frame_bytes = 1920 * 1080 * 4;
    const frame = try std.testing.allocator.alloc(u8, frame_bytes);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    frame[0] = 12;
    frame[1] = 34;
    frame[2] = 56;
    frame[3] = 255;
    try producer.pushFrame(1920, 1080, frame);
    try dispatchFrame(harness, app, 1);

    const adopted = harness.runtime.adoptedMediaSurfaceTexture(surface_id).?;
    try std.testing.expectEqual(@as(usize, 1920), adopted.width);
    try std.testing.expectEqual(@as(usize, 1080), adopted.height);
    try std.testing.expectEqual(frame_bytes, adopted.byte_len);

    try setMediaSurfaceDisplayList(harness, surface_id);
    const result = try presentProbeFrame(harness, 2);

    // The frame PRESENTED — as a packet, never the pixel fallback, and
    // never an InvalidGpuSurfaceImage refusal after adoption.
    try std.testing.expectEqual(core.CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expect(result.packet_representable);

    // The full frame rode the binary upload side-channel to the host
    // store under the derived texture id.
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_upload_count);
    try std.testing.expectEqual(canvas.mediaSurfaceTextureImageId(surface_id), harness.null_platform.gpu_surface_image_upload_id);
    try std.testing.expectEqual(@as(usize, 1920), harness.null_platform.gpu_surface_image_upload_width);
    try std.testing.expectEqual(@as(usize, 1080), harness.null_platform.gpu_surface_image_upload_height);
    try std.testing.expectEqual(frame_bytes, harness.null_platform.gpu_surface_image_upload_byte_len);
    try std.testing.expectEqualDeep([4]u8{ 12, 34, 56, 255 }, harness.null_platform.gpuSurfaceImage(canvas.mediaSurfaceTextureImageId(surface_id)).?.sample_rgba);
}

test "the frame budget's boundary is enforced at the producer, never downstream" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    const budget = canvas_limits.max_media_surface_pixel_bytes;
    const buffer = try std.testing.allocator.alloc(u8, budget + 4);
    defer std.testing.allocator.free(buffer);
    @memset(buffer, 200);

    // One pixel past the budget refuses LOUDLY at the producer — the
    // push boundary is where a too-large frame must die, so nothing
    // over-budget can ever be staged, adopted, or handed to a host.
    try std.testing.expectError(error.FrameTooLarge, producer.pushFrame(budget / 4 + 1, 1, buffer));
    try dispatchFrame(harness, app, 1);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);

    // A frame at EXACTLY the budget passes the whole path: push, adopt,
    // packet present, host upload of every byte.
    try producer.pushFrame(2048, 1024, buffer[0..budget]);
    try dispatchFrame(harness, app, 2);
    try std.testing.expectEqual(budget, harness.runtime.adoptedMediaSurfaceTexture(surface_id).?.byte_len);

    try setMediaSurfaceDisplayList(harness, surface_id);
    const result = try presentProbeFrame(harness, 3);
    try std.testing.expectEqual(core.CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_image_upload_count);
    try std.testing.expectEqual(budget, harness.null_platform.gpu_surface_image_upload_byte_len);

    // The refused frame reached NO downstream layer: the only upload the
    // host ever saw is the exact-budget frame. (The producer-side check
    // firing FIRST is what the ordering above pins — the refusal
    // happened before adoption could stage anything.)
    try std.testing.expectEqual(canvas.mediaSurfaceTextureImageId(surface_id), harness.null_platform.gpu_surface_image_upload_id);
}

// ------------------------------------------------------------- widget app

const media_canvas_label = "media-canvas";

const MediaModel = struct {
    surface: u64 = surface_id,
    count: u32 = 0,
};

const MediaMsg = union(enum) {
    increment,
};

const MediaApp = ui_app_mod.UiApp(MediaModel, MediaMsg);

fn mediaUpdate(model: *MediaModel, msg: MediaMsg) void {
    switch (msg) {
        .increment => model.count += 1,
    }
}

fn mediaView(ui: *MediaApp.Ui, model: *const MediaModel) MediaApp.Ui.Node {
    // The surface sits inside a CLIPPING parent (scroll viewports
    // always clip) that is shorter than the surface's declared height,
    // so the clip test below can probe pixels outside the viewport:
    // composited like any widget means the parent's clip crops it. The
    // surface also carries its own corner radius, masked on the draw.
    return ui.column(.{ .gap = 8, .padding = 10 }, .{
        ui.el(.scroll_view, .{ .width = 160, .height = 60 }, .{
            ui.mediaSurface(.{
                .image = model.surface,
                .width = 140,
                .height = 120,
                .style = .{ .radius = 12 },
                .semantics = .{ .label = "Synthetic preview" },
            }),
        }),
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.button(.{ .on_press = .increment }, "Increment"),
    });
}

const media_views = [_]app_manifest.ShellView{
    .{ .label = media_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const media_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Media",
    .width = 240,
    .height = 220,
    .views = &media_views,
}};
const media_scene: app_manifest.ShellConfig = .{ .windows = &media_windows };

fn mediaOptions() MediaApp.Options {
    return .{
        .name = "media-surface-app",
        .scene = media_scene,
        .canvas_label = media_canvas_label,
        .update = mediaUpdate,
        .view = mediaView,
    };
}

fn mediaAppFrame(harness: *TestHarness(), app: App, frame_index: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = media_canvas_label,
        .size = geometry.SizeF.init(240, 220),
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

fn mediaScreenshot(harness: *TestHarness(), out: []u8, scratch: []u8) !core.CanvasScreenshot {
    return harness.runtime.renderCanvasScreenshot(1, media_canvas_label, null, out, scratch);
}

test "the widget composites the placeholder deterministically, clipped like any widget" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 220) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(MediaApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = MediaApp.init(std.testing.allocator, .{}, mediaOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try mediaAppFrame(harness, app, 1);
    try std.testing.expect(app_state.installed);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, media_canvas_label, null);
    const pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);

    // Locate the surface's laid-out frame and its clipping parent.
    const layout = try harness.runtime.canvasWidgetLayout(1, media_canvas_label);
    var surface_frame: ?geometry.RectF = null;
    var viewport_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.kind == .media_surface) surface_frame = node.frame;
        if (node.widget.kind == .scroll_view) viewport_frame = node.frame;
    }
    const media_frame = surface_frame.?;
    const clip_frame = viewport_frame.?;
    // The declared height (120) overflows the 60-tall clipping viewport.
    try std.testing.expect(media_frame.maxY() > clip_frame.maxY());

    const placeholder = canvas.mediaSurfacePlaceholderColor(surface_id);
    const expected = [4]u8{
        @intFromFloat(@round(placeholder.r * 255)),
        @intFromFloat(@round(placeholder.g * 255)),
        @intFromFloat(@round(placeholder.b * 255)),
        255,
    };

    const before = try mediaScreenshot(harness, pixels, scratch);
    const inside_x: usize = @intFromFloat(media_frame.x + 8);
    const inside_y: usize = @intFromFloat(media_frame.y + 8);
    const inside = (inside_y * before.width + inside_x) * 4;
    try std.testing.expectEqualSlices(u8, &expected, before.rgba8[inside .. inside + 4]);
    // Outside the clipping parent (but inside the surface's declared
    // frame): the parent's clip crops the surface like any widget.
    const clipped_y: usize = @intFromFloat(clip_frame.maxY() + 4);
    const clipped = (clipped_y * before.width + inside_x) * 4;
    try std.testing.expect(!std.mem.eql(u8, &expected, before.rgba8[clipped .. clipped + 4]));
    // The surface's own corner radius masks the draw: the rounded
    // corner pixel is not placeholder-colored while the face is.
    const corner_x: usize = @intFromFloat(media_frame.x + 1);
    const corner_y: usize = @intFromFloat(media_frame.y + 1);
    const corner = (corner_y * before.width + corner_x) * 4;
    try std.testing.expect(!std.mem.eql(u8, &expected, before.rgba8[corner .. corner + 4]));

    // Reference-placeholder determinism: a producer pushing REAL frames
    // changes nothing in the reference render — goldens can never
    // depend on producer output. Byte-identical before/after.
    const golden = try std.testing.allocator.dupe(u8, before.rgba8);
    defer std.testing.allocator.free(golden);

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();
    const magenta = solidFrame(.{ 255, 0, 255, 255 });
    try producer.pushFrame(2, 2, &magenta);
    try mediaAppFrame(harness, app, 2);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);

    const after = try mediaScreenshot(harness, pixels, scratch);
    try std.testing.expectEqualSlices(u8, golden, after.rgba8);

    // ...while the GPU/packet side of the same plan sees the texture:
    // the resource set carries the adopted pixels for upload.
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualSlices(u8, &magenta, resources[0].pixels);
    try std.testing.expect(resources[0].presentation_only);
}

test "the surface's a11y line is producer-independent, so fingerprints exclude texture contents" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 220) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(MediaApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = MediaApp.init(std.testing.allocator, .{}, mediaOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try mediaAppFrame(harness, app, 1);

    const before = harness.runtime.sessionStateFingerprint();
    try std.testing.expect(before != 0);

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();
    const cyan = solidFrame(.{ 0, 255, 255, 255 });
    try producer.pushFrame(2, 2, &cyan);
    try mediaAppFrame(harness, app, 2);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);

    // Texture contents are presentation chrome: the session fingerprint
    // (hashed over the a11y tree) is identical with frames flowing.
    try std.testing.expectEqual(before, harness.runtime.sessionStateFingerprint());
}

// ------------------------------------------------------- entry reclaim

test "reclaiming a retained texture removes the host image and the widget serves the placeholder" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 220) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(MediaApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = MediaApp.init(std.testing.allocator, .{}, mediaOptions());
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try mediaAppFrame(harness, app, 1);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, media_canvas_label, null);
    const pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const before = try mediaScreenshot(harness, pixels, scratch);
    const golden = try std.testing.allocator.dupe(u8, before.rgba8);
    defer std.testing.allocator.free(golden);

    // A producer pushes; the app's frame presents the packet, so the
    // texture rides the upload side-channel into the HOST-WIDE store —
    // the store AppKit's packet draw resolves images from.
    const texture_id = canvas.mediaSurfaceTextureImageId(surface_id);
    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    const magenta = solidFrame(.{ 255, 0, 255, 255 });
    try producer.pushFrame(2, 2, &magenta);
    try mediaAppFrame(harness, app, 2);
    try std.testing.expect(harness.null_platform.gpuSurfaceImage(texture_id) != null);

    // Release retains the last adopted frame (a paused player keeps its
    // final picture): the entry, the resource, and the host copy all
    // stay — release is NOT a reclaim.
    producer.release();
    try mediaAppFrame(harness, app, 3);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
    try std.testing.expect(harness.null_platform.gpuSurfaceImage(texture_id) != null);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_image_remove_count);

    // Fill every runtime texture entry with LIVE channels, then adopt
    // one more: the retained entry is the only inactive one, so it is
    // reclaimed — and the host-side image must go with it.
    var live: [canvas_limits.max_media_surface_channels]media_surface.MediaSurfaceProducer = undefined;
    for (&live, 0..) |*extra, index| {
        extra.* = try harness.runtime.acquireMediaSurfaceProducer(101 + index);
        const shade: u8 = @intCast(index + 1);
        const frame = solidFrame(.{ shade, shade, shade, 255 });
        try extra.pushFrame(2, 2, &frame);
    }
    defer for (live) |extra| extra.release();
    try mediaAppFrame(harness, app, 4);

    // The reclaim removed the host texture through the platform seam.
    try std.testing.expect(harness.null_platform.gpu_surface_image_remove_count >= 1);
    try std.testing.expectEqual(texture_id, harness.null_platform.gpu_surface_image_remove_id);
    try std.testing.expect(harness.null_platform.gpuSurfaceImage(texture_id) == null);

    // Both engines now resolve the id to NOTHING: the runtime resource
    // set no longer carries it (packet hosts skip the draw — no stale
    // store image left to resolve), and the reference render of the
    // still-bound widget is byte-identical to the placeholder golden.
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);
    for (harness.runtime.registeredCanvasImages()) |resource| {
        try std.testing.expect(resource.id != texture_id);
    }
    try mediaAppFrame(harness, app, 5);
    const after = try mediaScreenshot(harness, pixels, scratch);
    try std.testing.expectEqualSlices(u8, golden, after.rgba8);
}

test "reclaim is safe on hosts without the upload seam" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    // Model a platform that never wired image uploads: the reclaim's
    // best-effort removal must swallow UnsupportedService, exactly like
    // unregisterCanvasImage does.
    harness.null_platform.gpu_surface_image_uploads = false;
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const retained = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    const first = solidFrame(.{ 1, 1, 1, 255 });
    try retained.pushFrame(2, 2, &first);
    try dispatchFrame(harness, app, 1);
    retained.release();

    var live: [canvas_limits.max_media_surface_channels]media_surface.MediaSurfaceProducer = undefined;
    for (&live, 0..) |*extra, index| {
        extra.* = try harness.runtime.acquireMediaSurfaceProducer(301 + index);
        const shade: u8 = @intCast(index + 1);
        const frame = solidFrame(.{ shade, 0, 0, 255 });
        try extra.pushFrame(2, 2, &frame);
    }
    defer for (live) |extra| extra.release();
    // The adoption reclaims the retained entry; the platform refuses the
    // removal with UnsupportedService and adoption proceeds anyway.
    try dispatchFrame(harness, app, 2);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(301) != null);
}

test "surface-id rotation never grows the host image store" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    // The rotating-player shape: every rotation binds a NEW surface id,
    // pushes a frame, presents it (uploading the texture to the host
    // store), and releases. Ids rotate far past the channel budget; the
    // host store must stay bounded by it — before the reclaim removed
    // host images, every rotation left one stale NSImage-analog behind.
    const rotations: usize = canvas_limits.max_media_surface_channels * 3;
    var rotation: usize = 0;
    while (rotation < rotations) : (rotation += 1) {
        const rotating_id: u64 = 400 + rotation;
        const producer = try harness.runtime.acquireMediaSurfaceProducer(rotating_id);
        const shade: u8 = @intCast(rotation + 1);
        const frame = solidFrame(.{ shade, shade, 0, 255 });
        try producer.pushFrame(2, 2, &frame);
        try setMediaSurfaceDisplayList(harness, rotating_id);
        try dispatchFrame(harness, app, rotation + 1);
        _ = try presentProbeFrame(harness, rotation + 1);
        try std.testing.expect(harness.null_platform.gpu_surface_image_count <= canvas_limits.max_media_surface_channels);
        producer.release();
    }

    // Every rotation past the entry budget reclaimed one retained
    // texture and removed its host image; the store ends bounded.
    try std.testing.expectEqual(rotations - canvas_limits.max_media_surface_channels, harness.null_platform.gpu_surface_image_remove_count);
    try std.testing.expect(harness.null_platform.gpu_surface_image_count <= canvas_limits.max_media_surface_channels);
}

// ------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [256 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) session_record.RecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "a session recorded with a live producer replays fingerprint-identical with NO producer" {
    const gpa = std.testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;

    // Record: a producer pushes distinct frames between presented
    // frames while the app also does model work (increments), with
    // per-frame fingerprint checkpoints.
    var recorded_model: MediaModel = undefined;
    var recorded_fingerprint: u64 = 0;
    {
        const recorder = try std.heap.page_allocator.create(session_record.SessionRecorder);
        defer std.heap.page_allocator.destroy(recorder);
        recorder.* = session_record.SessionRecorder.init(buffer.sink());
        recorder.begin(.{ .platform_name = "test", .app_name = "media-surface-app", .window_width = 240, .window_height = 220 });

        const harness = try TestHarness().create(gpa, .{ .size = geometry.SizeF.init(240, 220) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.session_recorder = recorder;

        const app_state = try gpa.create(MediaApp);
        defer gpa.destroy(app_state);
        app_state.* = MediaApp.init(std.heap.page_allocator, .{}, mediaOptions());
        defer app_state.deinit();
        const app = app_state.app();
        try harness.start(app);
        try mediaAppFrame(harness, app, 1);
        try harness.runtime.dispatchPlatformEvent(app, .frame_requested);

        const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
        defer producer.release();

        const layout = try harness.runtime.canvasWidgetLayout(1, media_canvas_label);
        var button_frame: ?geometry.RectF = null;
        for (layout.nodes) |node| {
            if (node.widget.kind == .button) button_frame = node.frame;
        }
        const press_frame = button_frame.?;

        var frame_index: u64 = 2;
        var shade: u8 = 10;
        while (frame_index < 6) : (frame_index += 1) {
            const frame = solidFrame(.{ shade, shade, 0, 255 });
            try producer.pushFrame(2, 2, &frame);
            shade +%= 40;
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = media_canvas_label,
                .kind = .pointer_down,
                .x = press_frame.x + press_frame.width * 0.5,
                .y = press_frame.y + press_frame.height * 0.5,
            } });
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = media_canvas_label,
                .kind = .pointer_up,
                .x = press_frame.x + press_frame.width * 0.5,
                .y = press_frame.y + press_frame.height * 0.5,
            } });
            try mediaAppFrame(harness, app, frame_index);
            try harness.runtime.dispatchPlatformEvent(app, .frame_requested);
        }
        try std.testing.expect(app_state.model.count > 0);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);

        recorder.finish();
        try std.testing.expect(!recorder.failed);
        recorded_model = app_state.model;
        recorded_fingerprint = harness.runtime.sessionStateFingerprint();
    }

    // Replay into a fresh runtime and app with NO producer attached:
    // every checkpoint verifies and the final fingerprint matches —
    // texture contents were never part of the session's identity.
    {
        const harness = try TestHarness().create(gpa, .{ .size = geometry.SizeF.init(240, 220) });
        defer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try gpa.create(MediaApp);
        defer gpa.destroy(app_state);
        app_state.* = MediaApp.init(std.heap.page_allocator, .{}, mediaOptions());
        defer app_state.deinit();

        const report = try session_replay.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
            .verify = true,
            .require_same_platform = false,
        });
        try std.testing.expect(report.ok());
        try std.testing.expect(report.events_replayed > 0);
        try std.testing.expect(report.checkpoints_verified > 0);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);
        try std.testing.expectEqualDeep(recorded_model, app_state.model);
        try std.testing.expectEqual(recorded_fingerprint, harness.runtime.sessionStateFingerprint());
    }
}

// ---------------------------------------------------- docs example pin

/// The public SDK root, exactly as an app or a toolkit extension
/// imports it: the docs' producer recipe must be writable against THESE
/// exports, not module-internal paths.
const media = @import("../root.zig");

test "docs example: the typed producer callback is writable against the public exports" {
    // docs/src/app/media-producers/page.mdx, "The mpv shape": the docs
    // machinery checks prose patterns, not Zig fences (the
    // test-docs-media-producer-contracts step pins the signature in the
    // page AND in this file), so this test is the compile-shaped mirror
    // of the example — the same callback signature, driven against a
    // real claim so the pin is behavior, not just types.
    const Mpv = struct {
        pixels: [16]u8,
        stopped: bool = false,

        const Frame = struct { width: usize, height: usize, pixels: []const u8 };

        fn renderFrameRgba8(self: *@This()) Frame {
            return .{ .width = 2, .height = 2, .pixels = &self.pixels };
        }

        fn stop(self: *@This()) void {
            self.stopped = true;
        }
    };
    const Glue = struct {
        // The docs example's exact signature (`media` being the app's
        // alias for the SDK root).
        fn onMpvFrame(player: *Mpv, producer: media.MediaSurfaceProducer) void {
            const frame = player.renderFrameRgba8();
            producer.pushFrame(frame.width, frame.height, frame.pixels) catch |err| switch (err) {
                error.MediaSurfaceReleased => player.stop(), // the app tore the surface down
                else => {},
            };
        }
    };

    // The handle `Runtime.acquireMediaSurfaceProducer` returns IS the
    // exported type, at the SDK root and the runtime root alike (and
    // the channel budgets ride beside it, like the image registry's).
    comptime std.debug.assert(media.MediaSurfaceProducer == media_surface.MediaSurfaceProducer);
    comptime std.debug.assert(media.runtime.MediaSurfaceProducer == media.MediaSurfaceProducer);
    comptime std.debug.assert(media.max_media_surface_channels == canvas_limits.max_media_surface_channels);
    comptime std.debug.assert(media.max_media_surface_pixel_bytes == canvas_limits.max_media_surface_pixel_bytes);

    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    var player: Mpv = .{ .pixels = solidFrame(.{ 9, 8, 7, 255 }) };
    const producer: media.MediaSurfaceProducer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    Glue.onMpvFrame(&player, producer);
    try dispatchFrame(harness, app, 1);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
    try std.testing.expect(!player.stopped);

    // A released handle drives the example's teardown arm.
    producer.release();
    Glue.onMpvFrame(&player, producer);
    try std.testing.expect(player.stopped);
}

// -------------------------------------------------- lazy texture buffers

/// A started GPU harness whose runtime froze `runtime_allocator` at
/// init. The runtime's `owned_allocator` captures `Options.allocator`
/// in `initAt` and mutating `options.allocator` on a live runtime
/// deliberately retargets nothing, so a test allocator must be injected
/// through the real capture site: re-initialize the runtime in place
/// with the harness's own platform and trace wiring (nothing is
/// heap-owned yet, so the re-init leaks nothing).
fn startedGpuHarnessWithRuntimeAllocator(gpa: std.mem.Allocator, runtime_allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try startedGpuHarness(gpa);
    errdefer harness.destroy(gpa);
    core.Runtime.initAt(&harness.runtime, .{
        .platform = harness.null_platform.platform(),
        .trace_sink = harness.trace_sink.sink(),
        .allocator = runtime_allocator,
        .environ = std.testing.environ,
    });
    // Match TestHarness().init: tests fail loud on handler/update errors.
    harness.runtime.dispatch_error_policy = .propagate;
    return harness;
}

test "a fresh runtime allocates zero media-texture bytes until an adoption happens" {
    // Count every runtime-allocator call: construction, startup, frames,
    // and even a live CLAIM with staged pushes perform NONE — texture
    // buffer storage is on-demand at first adoption. (The regression
    // pinned here: an embedded pool at the frame budget put 4 x 8 MiB =
    // 32 MiB in every Runtime — the docs wasm preview host carries one
    // Runtime per component tile — before any producer existed; the
    // registered-font-pool regression's twin.)
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try startedGpuHarnessWithRuntimeAllocator(std.testing.allocator, counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });
    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();
    const red = solidFrame(.{ 255, 0, 0, 255 });
    try producer.pushFrame(2, 2, &red);
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);

    // Even an allocator that refuses everything leaves the channel
    // operational: the adoption drops THIS frame loudly and the next
    // one retries — never a torn entry, never a crash. The FROZEN
    // allocator itself turns refusing (ownership never moves; only the
    // backing behavior changes), because swapping options.allocator
    // would retarget nothing.
    counting.fail_index = 0;
    try dispatchFrame(harness, app, 1);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);

    // The first adoption is the first allocation: exactly one, exactly
    // the frame budget (freed by Runtime.deinit through
    // harness.destroy — the leak-checked test allocator backs it).
    counting.fail_index = std.math.maxInt(usize);
    const green = solidFrame(.{ 0, 255, 0, 255 });
    try producer.pushFrame(2, 2, &green);
    try dispatchFrame(harness, app, 2);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(canvas_limits.max_media_surface_pixel_bytes, counting.allocated_bytes);

    // A second adoption of the SAME entry reuses the buffer: the count
    // stays one — the allocation is per used channel, not per frame.
    const blue = solidFrame(.{ 0, 0, 255, 255 });
    try producer.pushFrame(2, 2, &blue);
    try dispatchFrame(harness, app, 3);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
}

test "media buffer ownership freezes at init: a mutated options.allocator sees zero activity" {
    // The hazard pinned here: `Runtime.options` is public and mutable,
    // so if the lazy adoption allocation and deinit's free both read
    // `options.allocator` LIVE, swapping it between adoption and deinit
    // frees through the wrong allocator — silent UB. Ownership must
    // freeze into `owned_allocator` at init instead.
    var frozen = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try startedGpuHarnessWithRuntimeAllocator(std.testing.allocator, frozen.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });
    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();
    const red = solidFrame(.{ 255, 0, 0, 255 });
    try producer.pushFrame(2, 2, &red);
    try dispatchFrame(harness, app, 1);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
    try std.testing.expectEqual(@as(usize, 1), frozen.allocations);

    // Sabotage: swap options.allocator AFTER the adoption allocated.
    // fail_index = 0 poisons the swapped-in allocator (any allocation
    // through it refuses), and its counters pin that deinit routes
    // NOTHING here — neither an alloc nor, critically, the free.
    var poisoned = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.runtime.options.allocator = poisoned.allocator();

    harness.runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), frozen.deallocations);
    try std.testing.expectEqual(canvas_limits.max_media_surface_pixel_bytes, frozen.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), poisoned.allocations);
    try std.testing.expectEqual(@as(usize, 0), poisoned.deallocations);
    try std.testing.expectEqual(@as(usize, 0), poisoned.freed_bytes);
    // harness.destroy's second deinit finds the buffers already
    // returned (deinit resets them to empty) — no double free through
    // either allocator.
}

// ------------------------------------------------ dropped-frame retries

test "an adoption-OOM drop retries with byte-identical pixels on the next push" {
    // The static-frame shape: a paused video (or album art) producer
    // re-pushes the SAME bytes after its frame was dropped. The drop
    // must forget the push-boundary fingerprint, or the identical
    // retry dies in the dedup gate — no stage, no wake, the surface
    // stays blank until the pixels happen to change.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try startedGpuHarnessWithRuntimeAllocator(std.testing.allocator, counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });
    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // The lazy texture-buffer allocation fails at first adoption: this
    // frame drops loudly, nothing is adopted.
    const still = solidFrame(.{ 21, 22, 23, 255 });
    try producer.pushFrame(2, 2, &still);
    counting.fail_index = 0;
    try dispatchFrame(harness, app, 1);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);

    // Memory recovers and the producer re-pushes the SAME bytes: the
    // push must stage AND wake again (the drop reopened both gates),
    // and the next adoption lands the frame.
    counting.fail_index = std.math.maxInt(usize);
    const requests_before = harness.null_platform.pendingFrameRequestCount();
    try producer.pushFrame(2, 2, &still);
    try std.testing.expectEqual(requests_before + 1, harness.null_platform.pendingFrameRequestCount());
    try dispatchFrame(harness, app, 2);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualSlices(u8, &still, resources[0].pixels);
}

test "a registry-full drop retries with byte-identical pixels on the next push" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    // Fill the runtime's texture registry from claims that stay LIVE,
    // so no entry is reclaimable.
    var live: [canvas_limits.max_media_surface_channels]media_surface.MediaSurfaceProducer = undefined;
    for (&live, 0..) |*extra, index| {
        extra.* = try harness.runtime.acquireMediaSurfaceProducer(501 + index);
        const shade: u8 = @intCast(index + 1);
        const frame = solidFrame(.{ shade, 0, shade, 255 });
        try extra.pushFrame(2, 2, &frame);
    }
    defer for (live[1..]) |extra| extra.release();
    try dispatchFrame(harness, app, 1);
    try std.testing.expectEqual(canvas_limits.max_media_surface_channels, harness.runtime.media_surface_count);

    // Free ONE slot for the new producer, then rename the released
    // surface's entry to a still-live surface id. That manufactures
    // the registry-full drop's shape, which no single-threaded API
    // sequence can reach (the entry budget equals the process-wide
    // slot budget, so a full table of actively claimed entries plus a
    // fifth staged surface requires a release racing the lock-free
    // ownership snapshot): every entry reads as actively claimed
    // while a staged frame has nowhere to land.
    live[0].release();
    var renamed_index: usize = 0;
    for (harness.runtime.media_surface_entries[0..harness.runtime.media_surface_count], 0..) |entry, index| {
        if (entry.surface_id == 501) renamed_index = index;
    }
    harness.runtime.media_surface_entries[renamed_index].surface_id = 502;

    const producer = try harness.runtime.acquireMediaSurfaceProducer(999);
    defer producer.release();
    const still = solidFrame(.{ 77, 78, 79, 255 });
    try producer.pushFrame(2, 2, &still);
    try dispatchFrame(harness, app, 2);
    // Registry full of live surfaces: this frame dropped loudly.
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(999) == null);

    // The release becomes visible (the entry is reclaimable again) and
    // the producer re-pushes the SAME bytes: the drop must have
    // reopened the push-boundary gate, so the retry stages, wakes, and
    // the next adoption reclaims the entry and lands the frame.
    harness.runtime.media_surface_entries[renamed_index].surface_id = 501;
    const requests_before = harness.null_platform.pendingFrameRequestCount();
    try producer.pushFrame(2, 2, &still);
    try std.testing.expectEqual(requests_before + 1, harness.null_platform.pendingFrameRequestCount());
    try dispatchFrame(harness, app, 3);
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(999) != null);
    const texture_id = canvas.mediaSurfaceTextureImageId(999);
    var landed = false;
    for (harness.runtime.registeredCanvasImages()) |resource| {
        if (resource.id != texture_id) continue;
        landed = true;
        try std.testing.expectEqualSlices(u8, &still, resource.pixels);
    }
    try std.testing.expect(landed);
}

// ------------------------------------------------------- producer wakes

test "a push wakes an idle compositor: one coalesced frame request that adopts on dispatch" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // The idle shape: NO frame is scheduled (the demand-driven host is
    // asleep), and a producer pushes. The push itself must request one
    // cross-thread frame — the same `request_frame_fn` channel the
    // automation arrival watcher wakes the loop through.
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());
    const red = solidFrame(.{ 255, 0, 0, 255 });
    try producer.pushFrame(2, 2, &red);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());

    // Burst pushes coalesce: the wake already in flight carries them
    // (latest-wins), no second platform call.
    const green = solidFrame(.{ 0, 255, 0, 255 });
    const blue = solidFrame(.{ 0, 0, 255, 255 });
    try producer.pushFrame(2, 2, &green);
    try producer.pushFrame(2, 2, &blue);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());

    // The loop drains the request exactly like a live host marshals it:
    // one `.frame_requested` on the loop thread. That frame ADOPTS the
    // newest staged bytes (no gpu_surface_frame ever dispatched), and
    // adoption's invalidation arms the prompt gpu frame that will
    // composite them.
    const gpu_requests_before = harness.null_platform.gpu_surface_frame_request_count;
    const wake_event = harness.null_platform.takeFrameRequest().?;
    try harness.runtime.dispatchPlatformEvent(app, wake_event);
    const adopted = harness.runtime.adoptedMediaSurfaceTexture(surface_id).?;
    try std.testing.expect(adopted.fingerprint != 0);
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualSlices(u8, &blue, resources[0].pixels);
    try std.testing.expect(harness.null_platform.gpu_surface_frame_request_count > gpu_requests_before);

    // The adoption drained the coalescer: the NEXT changed push wakes
    // again — a paced producer gets one wake per adopted frame, never
    // fewer (the stall this channel exists to prevent) and never a
    // backlog of platform calls.
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());
    const white = solidFrame(.{ 255, 255, 255, 255 });
    try producer.pushFrame(2, 2, &white);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());
}

test "damage-skipped and refused pushes wake nothing" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);

    // Adopt one frame through the wake path so the channel is warm.
    const gray = solidFrame(.{ 40, 40, 40, 255 });
    try producer.pushFrame(2, 2, &gray);
    while (harness.null_platform.takeFrameRequest()) |event| {
        try harness.runtime.dispatchPlatformEvent(app, event);
    }
    try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);

    // Identical bytes: the push-boundary damage gate fires BEFORE the
    // wake — unchanged video never stirs an idle scheduler.
    try producer.pushFrame(2, 2, &gray);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());

    // A released handle's push is refused before staging AND wakes
    // nothing — a stale producer cannot burn the loop awake.
    producer.release();
    const after = solidFrame(.{ 9, 9, 9, 255 });
    try std.testing.expectError(error.MediaSurfaceReleased, producer.pushFrame(2, 2, &after));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());

    // An invalid frame is refused at validation, long before the wake.
    const reclaimed = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer reclaimed.release();
    const pixel = [_]u8{ 1, 2, 3, 255 };
    try std.testing.expectError(error.InvalidFrameDimensions, reclaimed.pushFrame(2, 1, &pixel));
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());
}

test "disarmed wake bindings never touch the platform again; pushes stay functional" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // Armed: a fresh push wakes.
    const red = solidFrame(.{ 255, 0, 0, 255 });
    try producer.pushFrame(2, 2, &red);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());
    while (harness.null_platform.takeFrameRequest()) |event| {
        try harness.runtime.dispatchPlatformEvent(app, event);
    }

    // Disarmed (what the run loop's exit defer, TestHarness.destroy,
    // and the embed host's destroy invoke before the platform dies):
    // pushes still stage — and the compositor's own frame clock still
    // adopts them — but NOTHING calls into the platform anymore. This
    // is the whole teardown-safety contract: after disarm returns, a
    // producer thread cannot reach the host, so the host may die.
    harness.runtime.disarmMediaSurfaceWakes();
    const green = solidFrame(.{ 0, 255, 0, 255 });
    try producer.pushFrame(2, 2, &green);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.pendingFrameRequestCount());
    try dispatchFrame(harness, app, 2);
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualSlices(u8, &green, resources[0].pixels);

    // Re-acquiring re-arms: the disarm ends BINDINGS, not the channel.
    producer.release();
    const rearmed = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer rearmed.release();
    const blue = solidFrame(.{ 0, 0, 255, 255 });
    try rearmed.pushFrame(2, 2, &blue);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());
    while (harness.null_platform.takeFrameRequest()) |event| {
        try harness.runtime.dispatchPlatformEvent(app, event);
    }
}

// -------------------------------------------------- threads and teardown

test "cross-thread pushes stage safely and the loop adopts the newest" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: ProbeApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });

    const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
    defer producer.release();

    // A real producer thread pushes a burst of distinct frames; the
    // loop thread adopts on its own frame clock. Joining first makes
    // the assertion deterministic: latest-wins leaves exactly the final
    // frame staged.
    const Worker = struct {
        fn run(handle: media_surface.MediaSurfaceProducer) void {
            var shade: u8 = 1;
            while (shade <= 50) : (shade += 1) {
                const frame = solidFrame(.{ shade, 0, shade, 255 });
                handle.pushFrame(2, 2, &frame) catch return;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{producer});
    thread.join();

    // Fifty distinct cross-thread pushes with no adoption in between:
    // the wake coalescer latched after the first, so the idle loop was
    // asked for exactly ONE frame.
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.pendingFrameRequestCount());

    try dispatchFrame(harness, app, 1);
    const final = solidFrame(.{ 50, 0, 50, 255 });
    const resources = harness.runtime.registeredCanvasImages();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualSlices(u8, &final, resources[0].pixels);
}

test "two runtimes with full retained tables adopt concurrently without deadlock" {
    // The retained-entry reclaim scan reads slot ownership LOCK-FREE
    // (media_surface.mediaSurfaceHasActiveSlot); before that, it locked
    // OTHER mailbox slots while the adoption loop held the drained one:
    // self-deadlock the moment one runtime's table filled (the spin
    // mutex is not reentrant), ABBA between two runtimes draining
    // different slots and scanning each other's. This stress drives
    // exactly that shape — two runtimes, both texture tables FULL, both
    // reclaiming on every adoption, concurrently on real threads — for
    // a bounded iteration count. Completion is the deadlock assertion;
    // the SpinMutex debug lock-discipline assertion (no thread ever
    // holds two media-surface mutexes) turns any reintroduced nesting
    // into an instant loud failure in ANY debug test run, so the fix
    // cannot regress silently between stress runs.
    const gpa = std.testing.allocator;

    var harnesses: [2]*TestHarness() = undefined;
    harnesses[0] = try TestHarness().create(gpa, .{ .size = geometry.SizeF.init(64, 64) });
    defer harnesses[0].destroy(gpa);
    harnesses[1] = try TestHarness().create(gpa, .{ .size = geometry.SizeF.init(64, 64) });
    defer harnesses[1].destroy(gpa);

    // Fill each runtime's texture table with RETAINED entries (claim ->
    // push -> adopt -> release, rotating ids), so every raced adoption
    // below finds the table full and runs the reclaim scan while it
    // holds the drained slot's mutex.
    for (harnesses, 0..) |harness, harness_index| {
        var rotation: usize = 0;
        while (rotation < canvas_limits.max_media_surface_channels) : (rotation += 1) {
            const seed_id: u64 = 10_000 * (@as(u64, harness_index) + 1) + rotation;
            const producer = try harness.runtime.acquireMediaSurfaceProducer(seed_id);
            const shade: u8 = @intCast(rotation + 1);
            const frame = solidFrame(.{ shade, shade, shade, 255 });
            try producer.pushFrame(2, 2, &frame);
            harness.runtime.adoptMediaSurfaceFrames();
            producer.release();
        }
        try std.testing.expectEqual(canvas_limits.max_media_surface_channels, harness.runtime.media_surface_count);
    }

    const iterations: usize = 200;
    const Driver = struct {
        fn drive(harness: *TestHarness(), id_base: u64) !void {
            var iteration: usize = 0;
            while (iteration < iterations) : (iteration += 1) {
                // Each thread is its own runtime's only driver, so the
                // loop-thread-only calls (acquire, adopt) are honest;
                // the SLOTS are process-wide shared state, which is the
                // contention under test. Two threads hold at most one
                // claim each — four slots never exhaust.
                const rotating_id = id_base + iteration;
                const producer = try harness.runtime.acquireMediaSurfaceProducer(rotating_id);
                defer producer.release();
                const shade: u8 = @truncate(iteration +% 1);
                const frame = solidFrame(.{ shade, @truncate(id_base), shade, 255 });
                try producer.pushFrame(2, 2, &frame);
                // Table full + fresh surface id = reclaim scan while
                // the drained slot's data mutex is held, every time.
                harness.runtime.adoptMediaSurfaceFrames();
                if (harness.runtime.adoptedMediaSurfaceTexture(rotating_id) == null) return error.AdoptionLost;
            }
        }

        fn run(harness: *TestHarness(), id_base: u64, failed: *std.atomic.Value(bool)) void {
            drive(harness, id_base) catch failed.store(true, .release);
        }
    };

    var failed = std.atomic.Value(bool).init(false);
    const first = try std.Thread.spawn(.{}, Driver.run, .{ harnesses[0], @as(u64, 20_000), &failed });
    const second = try std.Thread.spawn(.{}, Driver.run, .{ harnesses[1], @as(u64, 30_000), &failed });
    first.join();
    second.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "a producer outliving its runtime pushes into inert process-lived memory" {
    const gpa = std.testing.allocator;

    // First life: a runtime claims the channel and adopts one frame.
    var orphan: media_surface.MediaSurfaceProducer = undefined;
    {
        const harness = try startedGpuHarness(gpa);
        defer harness.destroy(gpa);
        var app_state: ProbeApp = .{};
        const app = app_state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{
            .window_id = 1,
            .label = "canvas",
            .kind = .gpu_surface,
            .frame = geometry.RectF.init(0, 0, 240, 140),
        });
        orphan = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
        const first = solidFrame(.{ 1, 2, 3, 255 });
        try orphan.pushFrame(2, 2, &first);
        try dispatchFrame(harness, app, 1);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) != null);
        // Leave a WAKE PENDING at teardown: the staged-but-never-adopted
        // push below arms the coalescer, and the harness dies without
        // ever answering it — teardown with a pending wake must be safe.
        const requests_before_parting = harness.null_platform.pendingFrameRequestCount();
        const parting = solidFrame(.{ 4, 5, 6, 255 });
        try orphan.pushFrame(2, 2, &parting);
        try std.testing.expectEqual(requests_before_parting + 1, harness.null_platform.pendingFrameRequestCount());
        // The harness (and the whole Runtime, and its PLATFORM) dies
        // here with the producer NOT released — the decoder-outlives-
        // the-view shape. destroy disarms the wake bindings first, so
        // the orphan's later pushes can never call into the freed host.
    }

    // The orphan handle keeps pushing after its runtime is gone: the
    // pushes land in the process-lived mailbox slot (never freed, never
    // adopted again) and its wake binding is DISARMED — no use-after-
    // free by construction on either half.
    const after_teardown = solidFrame(.{ 200, 100, 50, 255 });
    try orphan.pushFrame(2, 2, &after_teardown);

    // Second life: a NEW runtime acquires the SAME surface id. It gets
    // its own claim; the orphan's staged frame never crosses over.
    {
        const harness = try startedGpuHarness(gpa);
        defer harness.destroy(gpa);
        var app_state: ProbeApp = .{};
        const app = app_state.app();
        try harness.start(app);
        _ = try harness.runtime.createView(.{
            .window_id = 1,
            .label = "canvas",
            .kind = .gpu_surface,
            .frame = geometry.RectF.init(0, 0, 240, 140),
        });
        const producer = try harness.runtime.acquireMediaSurfaceProducer(surface_id);
        defer producer.release();

        // Before the new producer pushes: nothing to adopt (the orphan's
        // frame belongs to the dead runtime's claim).
        try dispatchFrame(harness, app, 1);
        try std.testing.expect(harness.runtime.adoptedMediaSurfaceTexture(surface_id) == null);

        const fresh = solidFrame(.{ 7, 7, 7, 255 });
        try producer.pushFrame(2, 2, &fresh);
        try dispatchFrame(harness, app, 2);
        const resources = harness.runtime.registeredCanvasImages();
        try std.testing.expectEqual(@as(usize, 1), resources.len);
        try std.testing.expectEqualSlices(u8, &fresh, resources[0].pixels);

        // The orphan still pushes into its own (dead) claim harmlessly
        // while the new channel is live.
        try orphan.pushFrame(2, 2, &after_teardown);
        try dispatchFrame(harness, app, 3);
        try std.testing.expectEqualSlices(u8, &fresh, harness.runtime.registeredCanvasImages()[0].pixels);
    }

    // Free the orphan's slot for later tests in this binary.
    orphan.release();
}
