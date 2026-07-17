const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const automation = @import("../automation/root.zig");
const types = @import("types.zig");
const conversions = @import("conversions.zig");

const max_mobile_command_name_bytes = types.max_mobile_command_name_bytes;
const max_mobile_input_text_bytes = types.max_mobile_input_text_bytes;
const max_mobile_asset_root_bytes = types.max_mobile_asset_root_bytes;
const max_mobile_asset_entry_bytes = types.max_mobile_asset_entry_bytes;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const mobileTouchKindFromPhase = conversions.mobileTouchKindFromPhase;
const mobileKeyKindFromPhase = conversions.mobileKeyKindFromPhase;
const mobileImeKindFromInt = conversions.mobileImeKindFromInt;
const mobileModifiersFromMask = conversions.mobileModifiersFromMask;
const copyInputText = conversions.copyInputText;
const nowNanoseconds = conversions.nowNanoseconds;

/// Host-owned storage for the shim's registered text-measure callback.
/// The canvas `TextMeasureProvider` carries a pointer to this struct as
/// its context, so the field must live on the (heap-allocated) host for
/// the runtime's lifetime.
pub const MobileTextMeasure = struct {
    measure: ?types.MobileTextMeasureFn = null,
    context: ?*anyopaque = null,
};

/// Bridges the C-ABI measure callback into the canvas provider seam. A
/// negative return (including a cleared callback) falls back to the
/// deterministic estimator inside `TextMeasureProvider.measureWidth`.
fn mobileMeasureText(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    const store: *const MobileTextMeasure = @ptrCast(@alignCast(context.?));
    const measure = store.measure orelse return -1;
    return @floatCast(measure(store.context, font_id, size, text.ptr, text.len));
}

/// Install (or clear, with a null callback) the platform text measurement
/// on the embedded runtime — the mobile counterpart of the desktop
/// platforms' `measure_text_fn` service, threaded into layout the same
/// way (`Runtime.tokensWithTextMeasure` stamps it into design tokens on
/// every rebuild). Register it before `native_sdk_app_start` so the
/// installing layout already uses real metrics; later changes apply on
/// the next rebuild.
///
/// Retained display-list commands carry the provider *pointer*, so once
/// the runtime's provider is installed it must stay in place for the
/// runtime's lifetime (the same invariant desktop platforms keep by
/// capturing it at init). Clearing therefore only nulls the callback
/// inside the host's bridge storage; the bridge then reports "no
/// measurement" and every consumer falls back to the deterministic
/// estimator.
pub fn setTextMeasure(self: anytype, measure: ?types.MobileTextMeasureFn, context: ?*anyopaque) void {
    self.text_measure = .{ .measure = measure, .context = context };
    if (measure != null and self.embedded.runtime.text_measure_provider == null) {
        self.embedded.runtime.text_measure_provider = .{
            .context = &self.text_measure,
            .measure_fn = mobileMeasureText,
        };
    }
}

/// Host-owned storage for the shim's registered audio service (callback
/// table + shim context). Lives on the (heap-allocated) host beside the
/// text-measure store so the platform-services bridge can reach it for
/// the runtime's lifetime.
pub const MobileAudio = struct {
    service: types.MobileAudioService = .{},
    context: ?*anyopaque = null,
};

/// Platform-services bridge from the runtime's audio service seam to the
/// shim's registered C callbacks. The runtime's `PlatformServices` carries
/// ONE shared context — the host's embedded `NullPlatform` — so the bridge
/// recovers the host from that field and reads the `audio` store; result
/// codes map exactly like the macOS host's (`src/platform/macos/root.zig`
/// audioLoad/audioLoadUrl and friends), so the effect layer sees identical
/// error semantics on every platform.
fn MobileAudioBridge(comptime Host: type) type {
    return struct {
        fn hostFromContext(context: ?*anyopaque) *Host {
            const null_platform: *platform.NullPlatform = @ptrCast(@alignCast(context.?));
            return @alignCast(@fieldParentPtr("null_platform", null_platform));
        }

        fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const load_fn = audio.service.load orelse return error.UnsupportedService;
            return switch (load_fn(audio.context, path.ptr, path.len)) {
                0 => {},
                1 => error.AudioSourceNotFound,
                else => error.AudioDecodeFailed,
            };
        }

        fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!platform.AudioLoadResolution {
            const audio = &hostFromContext(context).audio;
            const load_fn = audio.service.load_url orelse return error.UnsupportedService;
            return switch (load_fn(audio.context, url.ptr, url.len, if (cache_path.len > 0) cache_path.ptr else null, cache_path.len, expected_bytes)) {
                0 => .stream,
                1 => .cache,
                else => error.InvalidAudioOptions,
            };
        }

        fn audioPlay(context: ?*anyopaque) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const play_fn = audio.service.play orelse return error.UnsupportedService;
            if (play_fn(audio.context) == 0) return error.InvalidAudioOptions;
        }

        fn audioPause(context: ?*anyopaque) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const pause_fn = audio.service.pause orelse return error.UnsupportedService;
            _ = pause_fn(audio.context);
        }

        fn audioStop(context: ?*anyopaque) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const stop_fn = audio.service.stop orelse return error.UnsupportedService;
            _ = stop_fn(audio.context);
        }

        fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const seek_fn = audio.service.seek orelse return error.UnsupportedService;
            if (seek_fn(audio.context, position_ms) == 0) return error.InvalidAudioOptions;
        }

        fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
            const audio = &hostFromContext(context).audio;
            const volume_fn = audio.service.set_volume orelse return error.UnsupportedService;
            _ = volume_fn(audio.context, volume);
        }
    };
}

/// Install (or clear, with an all-null table) the shim's platform audio
/// service on the embedded runtime — the mobile counterpart of the desktop
/// hosts' `audio_*_fn` platform services. Registration flips the host's
/// `audio_playback`/`audio_streaming` capability answers to match what was
/// actually registered, so `runtime.supports` stays honest in both
/// directions. Register before `native_sdk_app_start` (like the text
/// measure) so the first effect dispatch already sees the service; a
/// partial playback table is refused whole with `error.InvalidCommand`.
pub fn setAudioService(self: anytype, service: types.MobileAudioService, context: ?*anyopaque) anyerror!void {
    const Host = std.meta.Child(@TypeOf(self));
    const Bridge = MobileAudioBridge(Host);
    const playback = service.playbackComplete();
    if (!playback and !service.empty()) return error.InvalidCommand;
    const streaming = playback and service.load_url != null;
    self.audio = .{ .service = service, .context = if (playback) context else null };
    const services = &self.embedded.runtime.options.platform.services;
    services.audio_load_fn = if (playback) Bridge.audioLoad else null;
    services.audio_load_url_fn = if (streaming) Bridge.audioLoadUrl else null;
    services.audio_play_fn = if (playback) Bridge.audioPlay else null;
    services.audio_pause_fn = if (playback) Bridge.audioPause else null;
    services.audio_stop_fn = if (playback) Bridge.audioStop else null;
    services.audio_seek_fn = if (playback) Bridge.audioSeek else null;
    services.audio_set_volume_fn = if (playback) Bridge.audioSetVolume else null;
    self.null_platform.audio_playback = playback;
    self.null_platform.audio_streaming = streaming;
}

/// Host-owned storage for the shim's registered image-decode service
/// (callback table + shim context). Lives on the (heap-allocated) host
/// beside the audio store so the platform-services bridge can reach it
/// for the runtime's lifetime.
pub const MobileImage = struct {
    service: types.MobileImageService = .{},
    context: ?*anyopaque = null,
};

/// Platform-services bridge from the runtime's image-decode seam
/// (`PlatformServices.decode_image_fn`, the `fx.registerImageBytes` path)
/// to the shim's registered C callback. Context recovery mirrors the
/// audio bridge: the services table carries the host's embedded
/// `NullPlatform`, and the host is recovered from that field. Result
/// codes map exactly like the macOS host's `decodeImage`
/// (`src/platform/macos/root.zig`): 1 decoded, -1 too large for the
/// buffer, anything else undecodable — with the shim-reported dimensions
/// re-validated against the buffer before any slice is formed, so a
/// buggy shim answer surfaces as `error.ImageDecodeFailed`, never as an
/// out-of-bounds pixel slice.
fn MobileImageBridge(comptime Host: type) type {
    return struct {
        fn hostFromContext(context: ?*anyopaque) *Host {
            const null_platform: *platform.NullPlatform = @ptrCast(@alignCast(context.?));
            return @alignCast(@fieldParentPtr("null_platform", null_platform));
        }

        fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8) anyerror!platform.DecodedImage {
            const image = &hostFromContext(context).image;
            const decode_fn = image.service.decode orelse return error.UnsupportedService;
            var width: usize = 0;
            var height: usize = 0;
            return switch (decode_fn(image.context, bytes.ptr, bytes.len, buffer.ptr, buffer.len, &width, &height)) {
                1 => {
                    if (width == 0 or height == 0) return error.ImageDecodeFailed;
                    const row_len = std.math.mul(usize, width, 4) catch return error.ImageDecodeFailed;
                    const byte_len = std.math.mul(usize, row_len, height) catch return error.ImageDecodeFailed;
                    if (byte_len > buffer.len) return error.ImageDecodeFailed;
                    return .{ .width = width, .height = height, .rgba8 = buffer[0..byte_len] };
                },
                -1 => error.ImageTooLarge,
                else => error.ImageDecodeFailed,
            };
        }
    };
}

/// Install (or clear, with an all-null table) the shim's platform image
/// decoder on the embedded runtime — the mobile counterpart of the
/// desktop hosts' `decode_image_fn` platform service. Registration flips
/// the runtime's service entry so `fx.registerImageBytes` decodes for
/// real; clearing (and never registering) keeps the honest decline:
/// `error.UnsupportedService`, image/avatar widgets on their fallback.
/// Register before `native_sdk_app_start` (like the audio service) so a
/// boot-effect registration already sees the codec.
pub fn setImageService(self: anytype, service: types.MobileImageService, context: ?*anyopaque) void {
    const Host = std.meta.Child(@TypeOf(self));
    const Bridge = MobileImageBridge(Host);
    const complete = service.complete();
    self.image = .{ .service = service, .context = if (complete) context else null };
    const services = &self.embedded.runtime.options.platform.services;
    services.decode_image_fn = if (complete) Bridge.decodeImage else null;
}

// -------------------------------------------------- presented-pixel capture
//
// The damage seam behind `native_sdk_app_render_pixels_damage`. The
// runtime's frame dispatch presents the mobile surface through the CPU
// pixel path once per changed frame — an INCREMENTAL, dirty-scissored
// raster into the ui-app's retained pixel buffer (the same machinery the
// desktop software platforms use). The capture below rides that present:
// it remembers a borrowed view of the presented buffer plus the damage
// accumulated since the shim last consumed it, so the ABI call can hand
// the shim exactly the changed pixels without a second raster. Every
// changed frame therefore costs ONE dirty-region raster and one
// damage-region copy — never the full-surface re-render the plain
// `native_sdk_app_render_pixels` screenshot pays.

/// The platform pixel presenter the capture bridge chains
/// (`PlatformServices.present_gpu_surface_pixels_fn`'s shape).
pub const MobilePresentPixelsFn = *const fn (context: ?*anyopaque, pixels: platform.GpuSurfacePixels) anyerror!void;

/// One rectangle in device-pixel units.
pub const MobilePixelRect = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,

    fn unionWith(self: MobilePixelRect, other: MobilePixelRect) MobilePixelRect {
        if (self.width == 0 or self.height == 0) return other;
        if (other.width == 0 or other.height == 0) return self;
        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self.x + self.width, other.x + other.width);
        const max_y = @max(self.y + self.height, other.y + other.height);
        return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
    }
};

/// Host-owned mirror of the last presented mobile-surface pixels: a
/// BORROWED view of the runtime's presented buffer (the ui-app owns it;
/// the slice is refreshed on every capture, and every buffer
/// reallocation is a surface-size change whose present re-captures
/// before any ABI read — the embed entry points all run on the shim's
/// single loop thread), the accumulated damage since the shim's last
/// `native_sdk_app_render_pixels_damage` delivery, and the delivery
/// bookkeeping for the shim's single retained buffer.
pub const MobilePresentedCanvas = struct {
    pixels: []const u8 = &.{},
    width: usize = 0,
    height: usize = 0,
    scale: f32 = 0,
    /// Captured presents; 0 = nothing presented yet.
    epoch: u64 = 0,
    /// Damage accumulated since the last delivery (device pixels); null
    /// with `epoch > 0` means no visual change since then.
    damage: ?MobilePixelRect = null,
    /// Delivery bookkeeping: which capture epoch (and at what
    /// dimensions) the shim's retained buffer last received. A zero
    /// epoch or dimension drift forces the next delivery to copy the
    /// full surface.
    delivered_epoch: u64 = 0,
    delivered_width: usize = 0,
    delivered_height: usize = 0,
};

/// The dirty rect's device-pixel coverage, mirroring the reference
/// renderer's rounding exactly (`referencePixelRect`: floor(min) ..
/// ceil(max), clipped) so the reported damage covers every pixel the
/// dirty-scissored raster touched.
fn mobilePixelRectFromBounds(bounds: geometry.RectF, scale: f32, width: usize, height: usize) ?MobilePixelRect {
    const normalized = bounds.normalized();
    if (normalized.isEmpty() or width == 0 or height == 0) return null;
    const effective_scale = if (!std.math.isFinite(scale) or scale <= 0) 1 else scale;
    const min_x = @floor(normalized.minX() * effective_scale);
    const min_y = @floor(normalized.minY() * effective_scale);
    const max_x = @ceil(normalized.maxX() * effective_scale);
    const max_y = @ceil(normalized.maxY() * effective_scale);
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    const x0: usize = @intFromFloat(std.math.clamp(min_x, 0, width_f));
    const y0: usize = @intFromFloat(std.math.clamp(min_y, 0, height_f));
    const x1: usize = @intFromFloat(std.math.clamp(max_x, 0, width_f));
    const y1: usize = @intFromFloat(std.math.clamp(max_y, 0, height_f));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

fn mobileFullPixelRect(width: usize, height: usize) MobilePixelRect {
    return .{ .x = 0, .y = 0, .width = width, .height = height };
}

/// Record one pixel present into the host's capture state. Dimension or
/// scale changes reset the delivery bookkeeping (the shim's buffer no
/// longer matches) and mark the full surface damaged; steady-state
/// presents union their dirty rect in. A present with no dirty rect is
/// conservatively a full-surface damage (full repaints report the full
/// surface as their dirty bounds anyway).
pub fn recordPresentedPixels(state: *MobilePresentedCanvas, pixels: platform.GpuSurfacePixels) void {
    const byte_len = pixels.expectedByteLen() orelse return;
    if (pixels.rgba8.len != byte_len) return;
    const changed_shape = state.epoch == 0 or
        state.width != pixels.width or
        state.height != pixels.height or
        state.scale != pixels.scale_factor;
    state.pixels = pixels.rgba8;
    state.width = pixels.width;
    state.height = pixels.height;
    state.scale = pixels.scale_factor;
    state.epoch += 1;
    if (changed_shape) {
        state.damage = mobileFullPixelRect(pixels.width, pixels.height);
        state.delivered_epoch = 0;
        return;
    }
    const incoming = if (pixels.dirty_bounds) |bounds|
        mobilePixelRectFromBounds(bounds, pixels.scale_factor, pixels.width, pixels.height) orelse return
    else
        mobileFullPixelRect(pixels.width, pixels.height);
    state.damage = if (state.damage) |current| current.unionWith(incoming) else incoming;
}

/// Platform-services bridge that chains the platform's own pixel
/// presenter (the null platform's recording present — nonblank sample,
/// present counters) and then captures the presented frame for the
/// damage ABI. Context recovery mirrors the audio bridge: the services
/// table carries the host's embedded `NullPlatform`, and the host is
/// recovered from that field.
fn MobilePresentCaptureBridge(comptime Host: type) type {
    return struct {
        fn hostFromContext(context: ?*anyopaque) *Host {
            const null_platform: *platform.NullPlatform = @ptrCast(@alignCast(context.?));
            return @alignCast(@fieldParentPtr("null_platform", null_platform));
        }

        fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: platform.GpuSurfacePixels) anyerror!void {
            const self = hostFromContext(context);
            if (self.present_pixels_chain) |chain| try chain(context, pixels);
            recordPresentedPixels(&self.presented, pixels);
        }
    };
}

/// Wire the presented-pixel capture into the embedded runtime: chain the
/// platform's pixel presenter behind the capture bridge, drop the packet
/// presenters (no mobile shim consumes packets, and their presence
/// forces the pixel path to a FULL repaint every changed frame), opt
/// the runtime into the pixel-present retained baseline so per-frame
/// dirty bounds refine to the commands that actually changed, and attach
/// the host's render memo so heavyweight per-pixel commands replay and
/// scaled image draws blend from scale-once panels. Call once from the
/// host's `create`, after the embedded runtime is initialized.
pub fn installPresentCapture(self: anytype) void {
    const Host = std.meta.Child(@TypeOf(self));
    const Bridge = MobilePresentCaptureBridge(Host);
    const services = &self.embedded.runtime.options.platform.services;
    self.present_pixels_chain = services.present_gpu_surface_pixels_fn;
    services.present_gpu_surface_pixels_fn = Bridge.presentGpuSurfacePixels;
    services.present_gpu_surface_packet_fn = null;
    services.present_gpu_surface_packet_binary_fn = null;
    self.embedded.runtime.options.pixel_present_retained_baseline = true;
    self.render_memo = canvas.ReferenceRenderMemo.init(std.heap.page_allocator);
    self.embedded.runtime.options.pixel_present_render_memo = &self.render_memo;
}

/// Deliver the captured present into the shim's RETAINED buffer: copies
/// only the damage accumulated since the previous delivery (the full
/// surface when the buffer is out of sync — first call, size or scale
/// change) and reports the copied region. Returns false when no capture
/// matches the request (nothing presented yet, scale drift, byte-length
/// mismatch) — the caller falls back to a full render.
pub fn deliverPresentedPixels(self: anytype, scale: f32, buffer: []u8, out: *types.MobileCanvasPixelsDamage) bool {
    const state: *MobilePresentedCanvas = &self.presented;
    if (state.epoch == 0) return false;
    if (state.scale != scale) return false;
    const byte_len = state.width * state.height * 4;
    if (state.pixels.len != byte_len or buffer.len < byte_len) return false;

    const in_sync = state.delivered_epoch != 0 and
        state.delivered_width == state.width and
        state.delivered_height == state.height;
    const copy_rect: ?MobilePixelRect = if (in_sync) state.damage else mobileFullPixelRect(state.width, state.height);
    var damage = MobilePixelRect{};
    if (copy_rect) |rect| {
        damage = rect;
        const row_stride = state.width * 4;
        const first_byte = rect.x * 4;
        const span = rect.width * 4;
        var row: usize = 0;
        while (row < rect.height) : (row += 1) {
            const offset = (rect.y + row) * row_stride + first_byte;
            @memcpy(buffer[offset .. offset + span], state.pixels[offset .. offset + span]);
        }
    }
    out.* = .{
        .width = state.width,
        .height = state.height,
        .byte_len = byte_len,
        .damage_x = damage.x,
        .damage_y = damage.y,
        .damage_width = damage.width,
        .damage_height = damage.height,
    };
    state.delivered_epoch = state.epoch;
    state.delivered_width = state.width;
    state.delivered_height = state.height;
    state.damage = null;
    return true;
}

/// A runtime embedded in a host that owns the main loop (the mobile
/// shims, game engines, custom render loops, headless tests). Lifecycle:
/// `init`/`initInPlace`, `defer embedded.deinit()`, `start`, host-pumped
/// events and `frame`s, `stop` (dispatches app_shutdown), and finally
/// that deferred `deinit` — `stop` only tells the app it is shutting
/// down; `deinit` is what returns the embedded runtime's heap-owned
/// registrations (registered canvas font bytes), so a direct embedder
/// that creates and destroys apps in one process leaks a full font
/// registry per cycle without it.
pub const EmbeddedApp = struct {
    app: runtime.App,
    runtime: runtime.Runtime,

    pub fn init(app: runtime.App, platform_value: platform.Platform) EmbeddedApp {
        var embedded: EmbeddedApp = undefined;
        embedded.initInPlace(app, platform_value);
        return embedded;
    }

    pub fn initInPlace(self: *EmbeddedApp, app: runtime.App, platform_value: platform.Platform) void {
        self.app = app;
        runtime.Runtime.initAt(&self.runtime, .{ .platform = platform_value });
    }

    /// End of the embedded lifecycle, symmetric with `init`/`initInPlace`:
    /// releases everything the embedded app owns on the heap — the
    /// runtime's registered canvas font bytes (`Runtime.deinit`); `init`
    /// itself allocates nothing else. Idempotent: a second call is a
    /// no-op, so `defer embedded.deinit()` composes with early exits.
    /// Everything borrowing the runtime (parsed faces, measure
    /// providers, views) is invalid past this point.
    pub fn deinit(self: *EmbeddedApp) void {
        self.runtime.deinit();
    }

    pub fn start(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_start);
    }

    pub fn activate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_activated);
    }

    pub fn deactivate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_deactivated);
    }

    pub fn resize(self: *EmbeddedApp, surface: platform.Surface) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .surface_resized = surface });
        if (surface.native_handle != null) {
            try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_resized = .{
                .window_id = 1,
                .label = mobile_gpu_surface_label,
                .frame = geometry.RectF.fromSize(surface.size),
                .scale_factor = surface.scale_factor,
            } });
        }
    }

    pub fn touch(self: *EmbeddedApp, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileTouchKindFromPhase(phase),
            .timestamp_ns = nowNanoseconds(),
            .pointer_id = id,
            .x = x,
            .y = y,
            .button = 0,
            .pressure = pressure,
        } });
    }

    pub fn scroll(self: *EmbeddedApp, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = .scroll,
            .timestamp_ns = nowNanoseconds(),
            .pointer_id = id,
            .x = x,
            .y = y,
            .delta_x = delta_x,
            .delta_y = delta_y,
        } });
    }

    pub fn key(self: *EmbeddedApp, phase: c_int, key_value: []const u8, text_value: []const u8, modifiers_mask: u32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileKeyKindFromPhase(phase),
            .timestamp_ns = nowNanoseconds(),
            .key = key_value,
            .text = text_value,
            .modifiers = mobileModifiersFromMask(modifiers_mask),
        } });
    }

    pub fn text(self: *EmbeddedApp, text_value: []const u8) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = .text_input,
            .timestamp_ns = nowNanoseconds(),
            .text = text_value,
        } });
    }

    pub fn ime(self: *EmbeddedApp, kind: c_int, text_value: []const u8, cursor: isize) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileImeKindFromInt(kind),
            .timestamp_ns = nowNanoseconds(),
            .text = text_value,
            .composition_cursor = if (cursor >= 0) @intCast(cursor) else null,
        } });
    }

    pub fn frame(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .frame_requested);
    }

    pub fn command(self: *EmbeddedApp, name: []const u8) anyerror!void {
        try self.runtime.dispatchCommand(self.app, .{
            .name = name,
            .source = .native_view,
            .window_id = 1,
            .view_label = "mobile-header",
        });
    }

    pub fn widgetSemantics(self: *const EmbeddedApp) anyerror![]const canvas.WidgetSemanticsNode {
        return self.runtime.canvasWidgetSemantics(1, mobile_gpu_surface_label);
    }

    pub fn gpuFrameState(self: *const EmbeddedApp) anyerror!platform.GpuFrame {
        return self.runtime.gpuSurfaceFrame(1, mobile_gpu_surface_label);
    }

    /// The mobile surface's retained-canvas revisions: `current` is what
    /// `gpu_frame_state` reports, `presented` is the revision the last
    /// planned present reflects (it advances at plan time even when a
    /// change turned out to move no pixels, so a host gating on it
    /// converges instead of polling forever). Zeros when the view does
    /// not exist yet.
    pub const CanvasRevisions = struct {
        current: u64 = 0,
        presented: u64 = 0,
    };

    pub fn canvasRevisions(self: *const EmbeddedApp) CanvasRevisions {
        for (self.runtime.views[0..self.runtime.view_count]) |*view| {
            if (!view.open or view.window_id != 1 or view.kind != .gpu_surface) continue;
            if (!std.mem.eql(u8, view.label, mobile_gpu_surface_label)) continue;
            return .{ .current = view.canvas_revision, .presented = view.presented_canvas_revision };
        }
        return .{};
    }

    pub fn widgetTextGeometry(self: *const EmbeddedApp, id: canvas.ObjectId) anyerror!canvas.WidgetTextGeometry {
        return self.runtime.canvasWidgetTextGeometry(1, mobile_gpu_surface_label, id);
    }

    pub fn widgetAction(self: *EmbeddedApp, action: runtime.CanvasWidgetAccessibilityAction) anyerror!void {
        _ = try self.runtime.dispatchCanvasWidgetAccessibilityAction(self.app, 1, mobile_gpu_surface_label, action);
    }

    /// Focus / IME-intent state for the mobile surface: reads the live
    /// pointer/keyboard focus (`canvas_widget_focused_id`, the same state
    /// desktop hosts key their IME activation on) rather than the
    /// source-declared semantics `focused` flag, and reports whether the
    /// focused widget accepts text edits right now.
    pub fn textInputState(self: *const EmbeddedApp) types.MobileTextInputState {
        var state = types.MobileTextInputState{};
        for (self.runtime.views[0..self.runtime.view_count]) |*view| {
            if (!view.open or view.window_id != 1 or view.kind != .gpu_surface) continue;
            if (!std.mem.eql(u8, view.label, mobile_gpu_surface_label)) continue;
            if (!view.focused or view.canvas_widget_focused_id == 0) return state;
            state.widget_id = view.canvas_widget_focused_id;
            for (view.widgetSemantics()) |node| {
                if (node.id != state.widget_id) continue;
                state.x = node.bounds.x;
                state.y = node.bounds.y;
                state.width = node.bounds.width;
                state.height = node.bounds.height;
                break;
            }
            if (view.canEditCanvasWidgetText(state.widget_id)) state.active = 1;
            return state;
        }
        return state;
    }

    /// One report from the shim's audio player, dispatched exactly like a
    /// desktop platform's `.audio` event: the runtime routes it into the
    /// active playback channel's `on_event` Msg (and the journal). Kind
    /// ordinals match `platform.AudioEventKind` (0 loaded, 1 position,
    /// 2 completed, 3 failed). Shims must call this between runtime entry
    /// points (their loop thread, never from inside a service callback) —
    /// the same next-turn discipline the macOS host keeps for its LOADED
    /// acknowledgment.
    pub fn audioEvent(self: *EmbeddedApp, kind: c_int, position_ms: u64, duration_ms: u64, playing: bool, buffering: bool) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .audio = .{
            .kind = try conversions.mobileAudioEventKindFromInt(kind),
            .position_ms = position_ms,
            .duration_ms = duration_ms,
            .playing = playing,
            .buffering = buffering,
        } });
    }

    pub fn stop(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_shutdown);
    }
};

pub const MobileHostApp = struct {
    null_platform: platform.NullPlatform,
    embedded: EmbeddedApp,
    last_error: ?anyerror = null,
    activation_count: usize = 0,
    deactivation_count: usize = 0,
    command_count: usize = 0,
    mobile_surface_resize_count: usize = 0,
    mobile_surface_width: f32 = 0,
    mobile_surface_height: f32 = 0,
    mobile_surface_scale: f32 = 1,
    input_count: usize = 0,
    touch_count: usize = 0,
    last_touch_id: u64 = 0,
    last_touch_kind: platform.GpuSurfaceInputKind = .pointer_up,
    last_touch_timestamp_ns: u64 = 0,
    last_touch_x: f32 = 0,
    last_touch_y: f32 = 0,
    last_touch_delta_x: f32 = 0,
    last_touch_delta_y: f32 = 0,
    last_touch_pressure: f32 = 0,
    last_input_kind: platform.GpuSurfaceInputKind = .pointer_up,
    last_input_timestamp_ns: u64 = 0,
    last_input_key: [max_mobile_input_text_bytes]u8 = undefined,
    last_input_key_len: usize = 0,
    last_input_text: [max_mobile_input_text_bytes]u8 = undefined,
    last_input_text_len: usize = 0,
    last_input_composition_cursor: ?usize = null,
    last_input_modifiers: platform.ShortcutModifiers = .{},
    asset_root: [max_mobile_asset_root_bytes]u8 = undefined,
    asset_root_len: usize = 0,
    asset_entry: [max_mobile_asset_entry_bytes]u8 = undefined,
    asset_entry_len: usize = 0,
    automation_dir: [max_mobile_asset_root_bytes]u8 = undefined,
    automation_dir_len: usize = 0,
    automation_io: ?*std.Io.Threaded = null,
    text_measure: MobileTextMeasure = .{},
    audio: MobileAudio = .{},
    // Image decode stays declined until the shim registers a real codec
    // (`native_sdk_app_set_image_service`): the null platform's strict
    // test decoder is opt-in (`image_decode`, default off), so with no
    // registration `fx.registerImageBytes` reports UnsupportedService and
    // image/avatar widgets keep their fallback — never a bundled codec.
    image: MobileImage = .{},
    /// Standing host chrome reports (see `setFormFactor` /
    /// `setChromeTabsProjected`): composed into every viewport-driven
    /// chrome publish.
    form_factor: platform.FormFactor = .unknown,
    chrome_tabs_projected: bool = false,
    /// Presented-pixel capture state for the damage ABI. The fixed
    /// WebView shell presents no gpu-surface pixels, so this stays at
    /// its empty zero-epoch state and `native_sdk_app_render_pixels_damage`
    /// answers through the full-render fallback — the same honest error
    /// path as `native_sdk_app_render_pixels`.
    presented: MobilePresentedCanvas = .{},
    present_pixels_chain: ?MobilePresentPixelsFn = null,
    last_command_name: [max_mobile_command_name_bytes + 1]u8 = [_]u8{0} ** (max_mobile_command_name_bytes + 1),

    pub fn create() !*MobileHostApp {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(MobileHostApp);
        errdefer allocator.destroy(self);
        self.null_platform = platform.NullPlatform.init(.{});
        // Audio is declined until the shim registers a real service
        // (`native_sdk_app_set_audio_service`): the null platform's
        // deterministic fake player belongs to hermetic tests, not to a
        // real app — a load that "succeeds" but never sounds or ticks
        // would be a lie. Cleared before `platform()` is snapshotted
        // below so the runtime's service table starts without audio.
        self.null_platform.audio_playback = false;
        self.null_platform.audio_streaming = false;
        self.last_error = null;
        self.activation_count = 0;
        self.deactivation_count = 0;
        self.command_count = 0;
        self.mobile_surface_resize_count = 0;
        self.mobile_surface_width = 0;
        self.mobile_surface_height = 0;
        self.mobile_surface_scale = 1;
        self.input_count = 0;
        self.touch_count = 0;
        self.last_touch_id = 0;
        self.last_touch_kind = .pointer_up;
        self.last_touch_timestamp_ns = 0;
        self.last_touch_x = 0;
        self.last_touch_y = 0;
        self.last_touch_delta_x = 0;
        self.last_touch_delta_y = 0;
        self.last_touch_pressure = 0;
        self.last_input_kind = .pointer_up;
        self.last_input_timestamp_ns = 0;
        self.last_input_key = undefined;
        self.last_input_key_len = 0;
        self.last_input_text = undefined;
        self.last_input_text_len = 0;
        self.last_input_composition_cursor = null;
        self.last_input_modifiers = .{};
        self.asset_root = undefined;
        self.asset_root_len = 0;
        self.asset_entry = undefined;
        self.asset_entry_len = 0;
        self.automation_dir = undefined;
        self.automation_dir_len = 0;
        self.automation_io = null;
        self.text_measure = .{};
        self.audio = .{};
        self.image = .{};
        self.form_factor = .unknown;
        self.chrome_tabs_projected = false;
        self.presented = .{};
        self.present_pixels_chain = null;
        self.last_command_name = [_]u8{0} ** (max_mobile_command_name_bytes + 1);
        self.embedded.initInPlace(.{
            .context = self,
            .name = "native-sdk-mobile",
            .source_fn = mobileSource,
            .event_fn = handleEvent,
        }, self.null_platform.platform());
        return self;
    }

    pub fn destroy(self: *MobileHostApp) void {
        disableAutomation(self);
        // One lifecycle owner: the embedded app's own deinit returns
        // the runtime's heap-owned storage (registered canvas font
        // bytes, lazily allocated media-surface texture buffers) AND
        // disarms the producer wake bindings, so a media producer the
        // embedding app keeps past destroy can never wake the freed
        // host storage (the embedded null platform included).
        self.embedded.deinit();
        std.heap.page_allocator.destroy(self);
    }

    pub fn start(self: *MobileHostApp) anyerror!void {
        try self.embedded.start();
    }

    pub fn frame(self: *MobileHostApp) anyerror!void {
        try self.embedded.frame();
    }

    /// The fixed WebView shell declares no scene, so it declares no
    /// platform chrome: the tab set is empty, there is no primary
    /// action, and no selection exists — the honest zero a canvas-less
    /// host answers the chrome ABI with.
    pub fn chromeTabs(self: *const MobileHostApp) []const app_manifest.ShellTab {
        _ = self;
        return &.{};
    }

    pub fn chromePrimaryAction(self: *const MobileHostApp) ?app_manifest.ShellPrimaryAction {
        _ = self;
        return null;
    }

    pub fn chromeSelectedTab(self: *const MobileHostApp) []const u8 {
        _ = self;
        return "";
    }

    /// No scene means no navigation projection either: depth answers -1
    /// (hosts present no transitions) and no back command exists.
    pub fn chromeNavigationDepth(self: *const MobileHostApp) isize {
        _ = self;
        return -1;
    }

    pub fn chromeNavigationBackCommand(self: *const MobileHostApp) []const u8 {
        _ = self;
        return "";
    }

    fn source(self: *MobileHostApp) platform.WebViewSource {
        if (self.asset_root_len > 0) {
            return platform.WebViewSource.assets(.{
                .root_path = self.asset_root[0..self.asset_root_len],
                .entry = if (self.asset_entry_len > 0) self.asset_entry[0..self.asset_entry_len] else "index.html",
                .origin = "zero://app",
                .spa_fallback = true,
            });
        }
        return platform.WebViewSource.html(mobile_html);
    }

    fn handleEvent(context: *anyopaque, runtime_value: *runtime.Runtime, event: runtime.Event) anyerror!void {
        _ = runtime_value;
        const self: *MobileHostApp = @ptrCast(@alignCast(context));
        switch (event) {
            .lifecycle => |lifecycle| switch (lifecycle) {
                .activate => self.activation_count += 1,
                .deactivate => self.deactivation_count += 1,
                else => {},
            },
            .command => |command_event| {
                self.command_count += 1;
                const count = @min(command_event.name.len, max_mobile_command_name_bytes);
                @memcpy(self.last_command_name[0..count], command_event.name[0..count]);
                self.last_command_name[count] = 0;
            },
            .gpu_surface_resized => |resize| {
                if (!std.mem.eql(u8, resize.label, mobile_gpu_surface_label)) return;
                self.mobile_surface_resize_count += 1;
                self.mobile_surface_width = resize.frame.width;
                self.mobile_surface_height = resize.frame.height;
                self.mobile_surface_scale = resize.scale_factor;
            },
            .gpu_surface_input => |input| {
                if (!std.mem.eql(u8, input.label, mobile_gpu_surface_label)) return;
                self.input_count += 1;
                self.last_input_kind = input.kind;
                self.last_input_timestamp_ns = input.timestamp_ns;
                self.last_input_key_len = copyInputText(&self.last_input_key, input.key);
                self.last_input_text_len = copyInputText(&self.last_input_text, input.text);
                self.last_input_composition_cursor = input.composition_cursor;
                self.last_input_modifiers = input.modifiers;
                switch (input.kind) {
                    .pointer_down, .pointer_up, .pointer_cancel, .pointer_move, .pointer_drag, .scroll => {
                        self.touch_count += 1;
                        self.last_touch_id = input.pointer_id;
                        self.last_touch_kind = input.kind;
                        self.last_touch_timestamp_ns = input.timestamp_ns;
                        self.last_touch_x = input.x;
                        self.last_touch_y = input.y;
                        self.last_touch_delta_x = input.delta_x;
                        self.last_touch_delta_y = input.delta_y;
                        self.last_touch_pressure = input.pressure;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

fn mobileSource(context: *anyopaque) anyerror!platform.WebViewSource {
    const self: *MobileHostApp = @ptrCast(@alignCast(context));
    return self.source();
}

pub const mobile_html =
    \\<!doctype html>
    \\<html>
    \\<body style="font-family: system-ui; padding: 2rem;">
    \\  <h1>native-sdk mobile</h1>
    \\  <p>This content is loaded through the native-sdk embedded C ABI.</p>
    \\</body>
    \\</html>
;

pub fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

/// Publish the viewport's safe-area insets as the mobile surface's window
/// chrome — the same `windowChrome` platform channel macOS answers with
/// its titlebar band and traffic-light cluster — so a `UiApp` subscribed
/// to `on_chrome` pads for the notch, status bar, and home indicator with
/// the identical code path it pads for desktop chrome. The keyboard is
/// input avoidance, not OS chrome, so it stays out of the report (the
/// runtime keeps insetting layout by the keyboard's residual overlap).
/// The host's standing chrome reports — form factor, projected declared
/// tabs — ride every publish so a viewport push never erases them.
pub fn publishViewportChrome(self: anytype, safe_area_insets: geometry.InsetsF) void {
    self.null_platform.window_chrome = .{
        .insets = safe_area_insets,
        .form_factor = self.form_factor,
        .tabs_projected = self.chrome_tabs_projected,
    };
}

/// Record the host-reported form factor (`native_sdk_app_set_form_factor`)
/// on the window-chrome channel. The report is standing state: it
/// composes into every later `publishViewportChrome` and updates the
/// live chrome immediately, so the app's next chrome re-query (the
/// resize the host's layout pass triggers, or the pre-install query)
/// delivers it as an ordinary `on_chrome` Msg.
pub fn setFormFactor(self: anytype, form_factor: platform.FormFactor) void {
    self.form_factor = form_factor;
    self.null_platform.window_chrome.form_factor = form_factor;
}

/// Record whether the host is projecting the app's declared chrome tabs
/// as real native controls (`native_sdk_app_set_chrome_tabs_projected`).
/// Standing state on the chrome channel, exactly like the form factor:
/// an app whose canvas composes its own tab switcher yields it while
/// this is set.
pub fn setChromeTabsProjected(self: anytype, projected: bool) void {
    self.chrome_tabs_projected = projected;
    self.null_platform.window_chrome.tabs_projected = projected;
}

pub fn recordError(self: anytype, err: anyerror) void {
    self.last_error = err;
}

/// Point the embedded runtime's automation server at `dir` (the desktop
/// equivalent is `-Dautomation=true` + `.zig-cache/native-sdk-automation`;
/// mobile shims pass an absolute path inside the app's data container).
/// The host-pumped frame loop then consumes the `command-<n>.txt` queue
/// and publishes `snapshot.txt` / `accessibility.txt` / `windows.txt`
/// exactly like the desktop runners.
pub fn enableAutomation(self: anytype, dir: []const u8) anyerror!void {
    if (dir.len == 0) return error.InvalidCommand;
    if (dir.len > self.automation_dir.len) return error.WindowSourceTooLarge;
    const allocator = std.heap.page_allocator;
    if (self.automation_io == null) {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        self.automation_io = threaded;
    }
    @memcpy(self.automation_dir[0..dir.len], dir);
    self.automation_dir_len = dir.len;
    self.embedded.runtime.options.automation = automation.Server.init(
        self.automation_io.?.io(),
        self.automation_dir[0..self.automation_dir_len],
        self.embedded.app.name,
    );
}

pub fn disableAutomation(self: anytype) void {
    self.embedded.runtime.options.automation = null;
    self.automation_dir_len = 0;
    if (self.automation_io) |threaded| {
        threaded.deinit();
        std.heap.page_allocator.destroy(threaded);
        self.automation_io = null;
    }
}
