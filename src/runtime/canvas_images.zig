//! Runtime canvas image registry: decoded RGBA pixels registered at
//! runtime under caller-chosen `ImageId`s (the effect-key spirit — store
//! the id in the model, no handles to leak) and referenced from
//! image/icon/avatar widgets.
//!
//! The registry is the missing bridge between fetched/decoded bytes and
//! the canvas image pipeline, which was already id+fingerprint based end
//! to end: `registerCanvasImage` copies pixels into a bounded
//! runtime-owned pool, and the frame planner threads the registered set
//! into `CanvasFrameOptions.image_resources` for every view — the CPU
//! reference renderer (presentation, screenshots, goldens) and the GPU
//! packet planner (upload/retain/evict actions keyed by pixel
//! fingerprint) both consume it with no further plumbing. Pixel bytes
//! reach GPU packet hosts through the platform's binary upload
//! side-channel (`uploadGpuSurfaceImage`, driven by packet upload cache
//! actions at present time; `removeGpuSurfaceImage` at unregister) —
//! packets carry only id + fingerprint references, so registered images
//! never inflate packet JSON past its transport bound. Re-registering an
//! id replaces its pixels: the content fingerprint changes, so caches
//! re-upload without any explicit invalidation call.
//!
//! Capacities follow `canvas_limits`: `max_registered_canvas_images`
//! slots of `max_registered_canvas_image_pixel_bytes` each, overflow is
//! `error.ImageRegistryFull` / `error.ImageTooLarge` — never silent.

const std = @import("std");
const canvas = @import("canvas");
const canvas_frame_module = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const effects_mod = @import("effects.zig");
const runtime_media_surface = @import("media_surface.zig");

pub const max_registered_canvas_images = canvas_limits.max_registered_canvas_images;
pub const max_registered_canvas_image_pixel_bytes = canvas_limits.max_registered_canvas_image_pixel_bytes;

/// One registered image's metadata; pixels live in the runtime's slot
/// pool at the same index.
pub const CanvasImageEntry = struct {
    id: canvas.ImageId = 0,
    width: usize = 0,
    height: usize = 0,
    byte_len: usize = 0,
};

/// Dimensions of a successfully registered image (the decode-and-register
/// path reports what the platform codec produced).
pub const RegisteredCanvasImage = struct {
    width: usize = 0,
    height: usize = 0,
};

/// Decode scratch for `registerCanvasImageBytes`. Sized past the slot
/// bound because decoders may need in-buffer scratch beyond the tight
/// pixel bytes (the null platform's strict PNG parser keeps one filter
/// byte per row: raw stream <= pixels + pixels/4 since a row is at least
/// 4 pixel bytes). Loop-thread only, like the frame scratch — and
/// lazily heap-allocated per thread (1.25 MiB) on the first decode, so
/// threads that never register image bytes never carry it in their
/// static TLS block.
const CanvasImageDecodeScratch = struct {
    bytes: [max_registered_canvas_image_pixel_bytes + max_registered_canvas_image_pixel_bytes / 4]u8,
};
const canvas_image_decode_scratch = canvas.lazy_tls.LazyTls(CanvasImageDecodeScratch);

pub fn RuntimeCanvasImages(comptime Runtime: type) type {
    return struct {
        /// Register (or replace) decoded pixels under `id`: tightly
        /// packed, row-major, straight-alpha RGBA8, exactly
        /// `width * height * 4` bytes. The runtime copies the pixels, so
        /// the caller's buffer is free when this returns. Every
        /// gpu_surface view repaints with the new image on its next
        /// frame; replacing an id changes the content fingerprint, so
        /// GPU-side caches re-upload without explicit invalidation.
        /// Errors: `error.InvalidImageId` (id 0 is the "no image"
        /// sentinel), `error.InvalidImageDimensions` (zero/overflowing
        /// dimensions or a pixel slice that is not exactly
        /// `width * height * 4`), `error.ImageTooLarge` (over the
        /// per-image slot bound), `error.ImageRegistryFull` (all
        /// `max_registered_canvas_images` slots hold other ids).
        pub fn registerCanvasImage(self: *Runtime, id: canvas.ImageId, width: usize, height: usize, rgba8: []const u8) anyerror!void {
            if (id == 0) return error.InvalidImageId;
            // The high bit is the media-surface texture namespace
            // (`canvas.media_surface_image_id_bit`): producer-pushed
            // textures and registered images share one flat id space,
            // so a registration inside the reserved namespace is
            // refused loudly rather than shadowed silently.
            if ((id & canvas.media_surface_image_id_bit) != 0) return error.InvalidImageId;
            if (width == 0 or height == 0) return error.InvalidImageDimensions;
            const row_len = std.math.mul(usize, width, 4) catch return error.InvalidImageDimensions;
            const byte_len = std.math.mul(usize, row_len, height) catch return error.InvalidImageDimensions;
            if (rgba8.len != byte_len) return error.InvalidImageDimensions;
            if (byte_len > max_registered_canvas_image_pixel_bytes) return error.ImageTooLarge;

            const index = findCanvasImageIndex(self, id) orelse blk: {
                if (self.canvas_image_count >= max_registered_canvas_images) return error.ImageRegistryFull;
                const index = self.canvas_image_count;
                self.canvas_image_count += 1;
                break :blk index;
            };
            @memcpy(self.canvas_image_pixels[index][0..byte_len], rgba8);
            self.canvas_image_entries[index] = .{
                .id = id,
                .width = width,
                .height = height,
                .byte_len = byte_len,
            };
            // No pixel push here: GPU packet hosts receive the bytes
            // through the binary upload side-channel when a packet's
            // upload cache action first references the new content
            // fingerprint (`uploadCanvasPacketImages` on the packet
            // present path), which also covers caller-supplied
            // `image_resources` sets that never pass through this
            // registry.
            noteCanvasImagesChanged(self);
        }

        /// Decode encoded image bytes (PNG, JPEG, ... — whatever the
        /// platform codec supports) through
        /// `PlatformServices.decode_image_fn` and register the pixels
        /// under `id` in one step — the fetch-avatar path:
        /// `fx.fetch` bytes in `update`, decode+register here, store the
        /// id in the model. On top of `registerCanvasImage`'s errors:
        /// `error.UnsupportedService` (platform has no codec),
        /// `error.ImageDecodeFailed` (undecodable bytes),
        /// `error.ImageTooLarge` (decoded pixels over the slot bound).
        /// `error.InvalidImageId` covers the same ids
        /// `registerCanvasImage` refuses (0 and the reserved
        /// media-surface namespace) and fires before any decode work.
        pub fn registerCanvasImageBytes(self: *Runtime, id: canvas.ImageId, bytes: []const u8) anyerror!RegisteredCanvasImage {
            if (id == 0) return error.InvalidImageId;
            // Same reserved-namespace refusal as `registerCanvasImage`
            // (see the comment there), checked before the decode so an
            // unusable id never reaches the platform codec — the caller
            // gets `error.InvalidImageId`, not a codec error, and pays
            // no decode cost for it.
            if ((id & canvas.media_surface_image_id_bit) != 0) return error.InvalidImageId;
            const decoded = try self.options.platform.services.decodeImage(bytes, &canvas_image_decode_scratch.get().bytes);
            if (decoded.rgba8.len > max_registered_canvas_image_pixel_bytes) return error.ImageTooLarge;
            try registerCanvasImage(self, id, decoded.width, decoded.height, decoded.rgba8);
            return .{ .width = decoded.width, .height = decoded.height };
        }

        /// Remove `id` from the registry, freeing its slot. Returns
        /// whether the id was registered. Views repaint without the
        /// image on their next frame (draws referencing a missing id
        /// skip, exactly like an unregistered id).
        pub fn unregisterCanvasImage(self: *Runtime, id: canvas.ImageId) bool {
            const index = findCanvasImageIndex(self, id) orelse return false;
            const last = self.canvas_image_count - 1;
            if (index != last) {
                self.canvas_image_entries[index] = self.canvas_image_entries[last];
                @memcpy(
                    self.canvas_image_pixels[index][0..self.canvas_image_entries[index].byte_len],
                    self.canvas_image_pixels[last][0..self.canvas_image_entries[index].byte_len],
                );
            }
            self.canvas_image_entries[last] = .{};
            self.canvas_image_count = last;
            // Best-effort drop of the platform-side texture: platforms
            // without the upload seam report UnsupportedService, and a
            // failed removal only costs the host a stale (unreferenced)
            // texture until the id is re-uploaded — never a wrong frame,
            // since packets key uploads by content fingerprint.
            self.options.platform.services.removeGpuSurfaceImage(id) catch {};
            noteCanvasImagesChanged(self);
            return true;
        }

        /// The registered set as the `ReferenceImage` slice both
        /// renderers consume, rebuilt into runtime scratch (pixels are
        /// borrowed from the slot pool, valid until the next
        /// register/unregister), with the adopted media-surface
        /// textures appended as `presentation_only` entries — GPU and
        /// packet hosts upload and composite those, the deterministic
        /// reference renderer skips them by policy (the media surface's
        /// id-derived placeholder is what it draws instead).
        pub fn registeredCanvasImages(self: *Runtime) []const canvas.ReferenceImage {
            for (self.canvas_image_entries[0..self.canvas_image_count], 0..) |entry, index| {
                self.canvas_image_resources_scratch[index] = .{
                    .id = entry.id,
                    .width = entry.width,
                    .height = entry.height,
                    .pixels = self.canvas_image_pixels[index][0..entry.byte_len],
                };
            }
            const media = runtime_media_surface.RuntimeMediaSurfaces(Runtime).adoptedMediaSurfaceTextures(
                self,
                self.canvas_image_resources_scratch[self.canvas_image_count..],
            );
            return self.canvas_image_resources_scratch[0 .. self.canvas_image_count + media.len];
        }

        /// Dimensions of a registered image, or null when `id` is not
        /// registered.
        pub fn registeredCanvasImage(self: *const Runtime, id: canvas.ImageId) ?RegisteredCanvasImage {
            const index = findCanvasImageIndex(self, id) orelse return null;
            const entry = self.canvas_image_entries[index];
            return .{ .width = entry.width, .height = entry.height };
        }

        pub fn registeredCanvasImageCount(self: *const Runtime) usize {
            return self.canvas_image_count;
        }

        /// The registry as the type-erased binding `Effects(Msg)` carries
        /// so `update` can register fetched pixels (`fx.registerImage`,
        /// `fx.registerImageBytes`, `fx.unregisterImage`). `UiApp` binds
        /// this alongside the platform services.
        pub fn canvasImageRegistryBinding(self: *Runtime) effects_mod.ImageRegistryBinding {
            const Adapter = struct {
                fn register(context: *anyopaque, id: u64, width: usize, height: usize, rgba8: []const u8) anyerror!void {
                    const runtime: *Runtime = @ptrCast(@alignCast(context));
                    return registerCanvasImage(runtime, id, width, height, rgba8);
                }
                fn registerBytes(context: *anyopaque, id: u64, bytes: []const u8) anyerror!effects_mod.RegisteredImage {
                    const runtime: *Runtime = @ptrCast(@alignCast(context));
                    const info = try registerCanvasImageBytes(runtime, id, bytes);
                    return .{ .width = info.width, .height = info.height };
                }
                fn unregister(context: *anyopaque, id: u64) bool {
                    const runtime: *Runtime = @ptrCast(@alignCast(context));
                    return unregisterCanvasImage(runtime, id);
                }
            };
            return .{
                .context = self,
                .register_fn = Adapter.register,
                .register_bytes_fn = Adapter.registerBytes,
                .unregister_fn = Adapter.unregister,
            };
        }

        fn findCanvasImageIndex(self: *const Runtime, id: canvas.ImageId) ?usize {
            for (self.canvas_image_entries[0..self.canvas_image_count], 0..) |entry, index| {
                if (entry.id == id) return index;
            }
            return null;
        }

        /// Registered pixels (or adopted media-surface textures, which
        /// ride the same resource set) changed: force every gpu_surface
        /// view to re-render its next frame (an image swap with an
        /// unchanged display list would otherwise take the skip path)
        /// and request frames so the repaint is not gated on other
        /// input. Pub for media_surface.zig's adoption path.
        pub fn noteCanvasImagesChanged(self: *Runtime) void {
            const frame_methods = canvas_frame_module.RuntimeCanvasFrames(Runtime);
            for (self.views[0..self.view_count], 0..) |*view, index| {
                if (!view.open or view.kind != .gpu_surface) continue;
                view.presented_canvas_valid = false;
                self.invalidateFor(.state, view.frame);
                frame_methods.requestCanvasFrameForView(self, index) catch {};
            }
        }
    };
}
