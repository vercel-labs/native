const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame_helpers.zig");
const launch_timing = @import("launch_timing.zig");
const platform = @import("../platform/root.zig");

pub const CanvasPixelSize = canvas_frame_helpers.CanvasPixelSize;
pub const appendCanvasSummaryChange = canvas_frame_helpers.appendCanvasSummaryChange;
pub const canvasDirtyBoundsFromChanges = canvas_frame_helpers.canvasDirtyBoundsFromChanges;
pub const canvasFrameBudgetIsUnset = canvas_frame_helpers.canvasFrameBudgetIsUnset;
pub const canvasFullRepaintBounds = canvas_frame_helpers.canvasFullRepaintBounds;
pub const sizesEqual = canvas_frame_helpers.sizesEqual;
pub const canvasSurfacePixelSize = canvas_frame_helpers.canvasSurfacePixelSize;
pub const normalizedCanvasPresentationScale = canvas_frame_helpers.normalizedCanvasPresentationScale;
pub const canvasFramePixelSize = canvas_frame_helpers.canvasFramePixelSize;
pub const canvasColorToRgba8 = canvas_frame_helpers.canvasColorToRgba8;
pub const clippedCanvasDirtyBounds = canvas_frame_helpers.clippedCanvasDirtyBounds;
pub const canvasDirtyBleedInset = canvas_frame_helpers.canvasDirtyBleedInset;
pub const inflatedCanvasDirtyBounds = canvas_frame_helpers.inflatedCanvasDirtyBounds;
pub const deviceAlignedCanvasDirtyBounds = canvas_frame_helpers.deviceAlignedCanvasDirtyBounds;
pub const unionRects = canvas_frame_helpers.unionRects;
pub const canvasWidgetPointerEventFromGpuInput = canvas_frame_helpers.canvasWidgetPointerEventFromGpuInput;
pub const canvasWidgetInputBatchesDisplayListRefresh = canvas_frame_helpers.canvasWidgetInputBatchesDisplayListRefresh;
pub const canvasWidgetKeyboardEventFromGpuInput = canvas_frame_helpers.canvasWidgetKeyboardEventFromGpuInput;
pub const canvasWidgetTextInputEventFromGpuInput = canvas_frame_helpers.canvasWidgetTextInputEventFromGpuInput;
pub const canvasWidgetEscapeKey = canvas_frame_helpers.canvasWidgetEscapeKey;
pub const canvasWidgetKeyboardModifiers = canvas_frame_helpers.canvasWidgetKeyboardModifiers;
pub const mergeCanvasRenderOverrides = canvas_frame_helpers.mergeCanvasRenderOverrides;
pub const findCanvasRenderOverrideIndex = canvas_frame_helpers.findCanvasRenderOverrideIndex;
pub const canvasRenderOverrideNoop = canvas_frame_helpers.canvasRenderOverrideNoop;
pub const canvasRenderAnimationFinalOverrideNoop = canvas_frame_helpers.canvasRenderAnimationFinalOverrideNoop;
pub const canvasRenderAnimationActive = canvas_frame_helpers.canvasRenderAnimationActive;
pub const platformCanvasFrameProfileRisk = canvas_frame_helpers.platformCanvasFrameProfileRisk;
pub const gpuSurfaceFrameEventFromGpuFrame = canvas_frame_helpers.gpuSurfaceFrameEventFromGpuFrame;

const runtime_api = @import("api.zig");
const runtime_clock = @import("clock.zig");
const validation = @import("validation.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_view = @import("view.zig");

const CanvasPresentationResult = runtime_api.CanvasPresentationResult;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const max_canvas_render_animations_per_view = canvas_limits.max_canvas_render_animations_per_view;
const max_canvas_text_layouts_per_view = canvas_limits.max_canvas_text_layouts_per_view;
const max_canvas_text_layout_lines_per_view = canvas_limits.max_canvas_text_layout_lines_per_view;
const max_canvas_retained_packet_commands_per_view = canvas_limits.max_canvas_retained_packet_commands_per_view;
// The frame planner's per-thread scratch behind one lazily
// heap-allocated pointer (~1.8 MiB that would otherwise sit in the
// static TLS template every OS thread's loader clones): the text-layout
// planning arrays plus the packet patch-derivation arrays declared with
// their contract below. Init happens on a thread's first frame plan —
// the runtime loop thread by construction — so window-host, COM,
// accessibility, and worker threads never allocate it. Every field is
// per-use scratch (no cross-frame state), so first-use init cannot
// change planner output; the arrays carry no default and stay
// uninitialized, exactly like the `= undefined` statics they replace.
const CanvasFrameScratch = struct {
    text_layout_plans: [max_canvas_text_layouts_per_view]canvas.TextLayoutPlan,
    text_layout_lines: [max_canvas_text_layout_lines_per_view]canvas.TextLine,
    text_layout_cache_entries: [max_canvas_text_layouts_per_view]canvas.TextLayoutCacheEntry,
    text_layout_cache_actions: [max_canvas_text_layouts_per_view * 2]canvas.TextLayoutCacheAction,
    packet_current: [max_canvas_retained_packet_commands_per_view]CanvasPacketCurrentCommand,
    packet_current_sort: [max_canvas_retained_packet_commands_per_view]u32,
    packet_baseline_sort: [max_canvas_retained_packet_commands_per_view]u32,
    packet_baseline_matched: [max_canvas_retained_packet_commands_per_view]bool,
    packet_baseline_stable: [max_canvas_retained_packet_commands_per_view]bool,
    packet_upsert: [max_canvas_retained_packet_commands_per_view]bool,
};
const canvas_frame_scratch = canvas.lazy_tls.LazyTls(CanvasFrameScratch);

/// One entry of the frame's CURRENT keyed command list — the full draw
/// order the retained packet protocol works on (never the scissor
/// subset). `render_index` points back into the frame's render plan so
/// upserts re-encode only the commands that changed; `bounds` is the
/// resolved render bounds, mirrored into the retained baseline so the
/// next frame's patch-derived dirty rect can name the pixels an upsert
/// or evict vacates.
const CanvasPacketCurrentCommand = struct {
    key: u64,
    fingerprint: u64,
    render_index: u32,
    bounds: geometry.RectF,
};

// Patch-derivation scratch (the `packet_*` fields of
// `CanvasFrameScratch` above): the current keyed list, a key-sorted
// index over it for duplicate detection, a key-sorted index over the
// view's retained baseline for O(log n) lookups, per-baseline matched
// flags (unmatched = evict), and per-current upsert flags. ~104 KiB per
// planning thread total. The matched/upsert flags persist between
// `computeCanvasPacketPatchStats` and `writeCanvasPacketPatchBinary` on
// the same thread — the same contract the statics carried.

const validateViewLabel = validation.validateViewLabel;
const canvasRenderAnimationStartNsForView = runtime_view.canvasRenderAnimationStartNsForView;
const canvas_frame_log = std.log.scoped(.zero_canvas_frame);

/// Result of `renderCanvasScreenshot`: tightly packed RGBA8 pixels sliced
/// from the caller's buffer.
pub const CanvasScreenshot = struct {
    width: usize,
    height: usize,
    rgba8: []const u8,
};

pub fn RuntimeCanvasFrames(comptime Runtime: type) type {
    return struct {
        pub fn setCanvasDisplayList(self: *Runtime, window_id: platform.WindowId, label: []const u8, display_list: canvas.DisplayList) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            var canvas_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined;
            const changes = try canvas.DisplayList.diff(self.views[index].canvasDisplayList(), display_list, &canvas_changes);
            try self.views[index].copyCanvasDisplayList(display_list);
            self.views[index].canvas_display_list_widget_owned = false;
            self.views[index].canvas_widget_display_list_prefix_count = 0;
            self.views[index].canvas_widget_display_list_suffix_count = 0;
            self.views[index].canvas_widget_display_list_reserved_count = 0;
            invalidateForCanvasChanges(self, self.views[index].frame, changes);
            if (changes.len > 0) try requestCanvasFrameForView(self, index);
            return self.views[index].info();
        }

        pub fn canvasDisplayList(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DisplayList {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].canvasDisplayList();
        }

        pub fn setCanvasRenderAnimations(self: *Runtime, window_id: platform.WindowId, label: []const u8, animations: []const canvas.CanvasRenderAnimation) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            try validateCanvasRenderAnimations(animations);
            // Replacing NOTHING with NOTHING is a no-op: a rebuild that
            // never declared animations must not schedule work.
            if (animations.len == 0 and
                self.views[index].canvas_render_animation_count == 0 and
                self.views[index].canvas_frame_render_override_count == 0)
            {
                return self.views[index].info();
            }
            // Invalidate the AFFECTED commands, not the whole view: the
            // union of the display-list bounds of every command a
            // previously APPLIED override or a new animation targets,
            // widened by the animations' from/to transforms. The next
            // planned frame recomputes exact override dirt; this region
            // only schedules the repaint — but a UiApp rebuild re-bases
            // its animations on EVERY update, and a full-frame region
            // here silently defeated incremental presentation.
            const dirty = canvasRenderAnimationScheduleDirtyBounds(&self.views[index], animations);
            try self.views[index].copyCanvasRenderAnimations(animations);
            if (dirty) |local_dirty| {
                if (canvasDirtyRegionForView(self.views[index].frame, local_dirty)) |region| {
                    self.invalidateFor(.state, region);
                } else {
                    self.invalidateFor(.state, self.views[index].frame);
                }
            } else if (animations.len == 0 and self.views[index].canvas_frame_render_override_count == 0) {
                // Cleared an inert set (no applied overrides on screen):
                // nothing painted from it, nothing to repaint.
                self.invalidateFor(.state, null);
            } else {
                // Targets not in the current display list (or bounds
                // unknown): stay loud with the full view.
                self.invalidateFor(.state, self.views[index].frame);
            }
            try requestCanvasFrameForView(self, index);
            return self.views[index].info();
        }

        pub fn clearCanvasRenderAnimations(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (self.views[index].canvas_render_animation_count == 0 and self.views[index].canvas_frame_render_override_count == 0) return self.views[index].info();
            self.views[index].canvas_render_animation_count = 0;
            self.invalidateFor(.state, self.views[index].frame);
            try requestCanvasFrameForView(self, index);
            return self.views[index].info();
        }

        pub fn canvasRenderAnimations(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror![]const canvas.CanvasRenderAnimation {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].canvasRenderAnimations();
        }

        pub fn canvasRenderAnimationStartNs(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!u64 {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return canvasRenderAnimationStartNsForView(&self.views[index]);
        }

        pub fn canvasFramePlan(self: *const Runtime, window_id: platform.WindowId, label: []const u8, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) anyerror!canvas.CanvasFrame {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            var frame_options = options;
            if (frame_options.surface_size.isEmpty()) frame_options.surface_size = self.views[index].frame.size();
            return self.views[index].canvasDisplayList().framePlan(previous, frame_options, storage);
        }

        pub fn nextCanvasFrame(self: *Runtime, window_id: platform.WindowId, label: []const u8, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) anyerror!canvas.CanvasFrame {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return try planCanvasFrameForView(self, index, options, storage, true);
        }

        pub fn nextCanvasGpuPacket(self: *Runtime, window_id: platform.WindowId, label: []const u8, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage, output: []canvas.CanvasGpuCommand) anyerror!canvas.CanvasGpuPacket {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const canvas_frame = try planCanvasFrameForView(self, index, options, storage, true);
            return try canvas_frame.gpuPacket(output);
        }

        pub fn presentNextCanvasGpuPacket(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            options: canvas.CanvasFrameOptions,
            storage: canvas.CanvasFrameStorage,
            clear_color: canvas.Color,
            output: []canvas.CanvasGpuCommand,
            packet_json_buffer: []u8,
        ) anyerror!canvas.CanvasGpuPacket {
            return try self.presentNextCanvasGpuPacketWithScale(window_id, label, options, storage, clear_color, output, packet_json_buffer, null);
        }

        pub fn presentNextCanvasGpuPacketWithScale(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            options: canvas.CanvasFrameOptions,
            storage: canvas.CanvasFrameStorage,
            clear_color: canvas.Color,
            output: []canvas.CanvasGpuCommand,
            packet_json_buffer: []u8,
            packet_scale: ?f32,
        ) anyerror!canvas.CanvasGpuPacket {
            var canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
            recordCanvasClearColor(self, window_id, label, clear_color);
            const presentation_scale = normalizedCanvasPresentationScale(packet_scale, canvas_frame.scale);
            // Widen BEFORE the packet build so the scissor-culled
            // command subset rides the widened scissor.
            widenCanvasFrameDirtyForPresentationScale(&canvas_frame, presentation_scale);
            var packet = try canvas_frame.gpuPacket(output);
            packet.scale = presentation_scale;
            if (!packet.requiresRender()) return packet;
            uploadCanvasPacketImages(self, packet) catch |err| {
                if (err == error.UnsupportedService) {
                    recordCanvasPacketFallback(self, window_id, label, .{ .reason = .missing_service });
                }
                return err;
            };
            // A refused present surfaces as error.UnsupportedService so
            // callers (UiApp's frame loop) take their existing pixel
            // fallback; the refusal reason was already recorded on the
            // view. Packets with unrepresentable commands are still
            // offered — the null platform accepts them for inspection —
            // but a real host's refusal is attributed to the command,
            // not to a missing service.
            const refusal: CanvasPacketRefusal = if (packet.fullyRepresentable())
                .{ .reason = .missing_service }
            else
                .{ .reason = .unsupported_command, .command_kind = firstUnsupportedCommandName(canvas_frame, packet) };
            const presented = try presentCanvasPacketEncoded(self, window_id, label, canvas_frame, packet, clear_color, packet_json_buffer, refusal);
            if (!presented) return error.UnsupportedService;
            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
                // The platform present call succeeded: this frame painted
                // through the packet path. A failed attempt never stamps.
                self.views[index].gpu_present_path = .packet;
                clearCanvasPacketFallback(&self.views[index]);
                recordCanvasPresentInputLatency(&self.views[index]);
            }
            return packet;
        }

        pub fn presentNextCanvasFrame(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            options: canvas.CanvasFrameOptions,
            storage: canvas.CanvasFrameStorage,
            gpu_commands: []canvas.CanvasGpuCommand,
            packet_json_buffer: []u8,
            pixels: []u8,
            scratch: []u8,
            clear_color: canvas.Color,
            pixel_scale: ?f32,
        ) anyerror!CanvasPresentationResult {
            var canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
            recordCanvasClearColor(self, window_id, label, clear_color);
            if (!canvas_frame.requiresRender()) {
                return .{ .frame = canvas_frame, .mode = .skipped };
            }
            const presentation_scale = normalizedCanvasPresentationScale(pixel_scale, canvas_frame.scale);
            // Widen BEFORE the packet build (and the pixel fallback below)
            // so the scissor-culled command subset rides the widened
            // scissor.
            widenCanvasFrameDirtyForPresentationScale(&canvas_frame, presentation_scale);

            const services = self.options.platform.services;
            const packet_service_available = services.present_gpu_surface_packet_fn != null or
                services.present_gpu_surface_packet_binary_fn != null;
            if (gpu_commands.len > 0 and packet_json_buffer.len > 0) {
                if (packet_service_available) {
                    var packet = try canvas_frame.gpuPacket(gpu_commands);
                    packet.scale = presentation_scale;
                    const result = CanvasPresentationResult{
                        .frame = canvas_frame,
                        .mode = .gpu_packet,
                        .packet_command_count = packet.commandCount(),
                        .packet_cache_action_count = packet.cacheActionCount(),
                        .packet_cached_resource_command_count = packet.cachedResourceCommandCount(),
                        .packet_unsupported_command_count = packet.unsupported_command_count,
                        .packet_representable = packet.fullyRepresentable(),
                    };
                    if (packet.fullyRepresentable()) {
                        const packet_presented = blk: {
                            uploadCanvasPacketImages(self, packet) catch |err| switch (err) {
                                error.UnsupportedService => {
                                    recordCanvasPacketFallback(self, window_id, label, .{ .reason = .missing_service });
                                    break :blk false;
                                },
                                else => return err,
                            };
                            break :blk try presentCanvasPacketEncoded(self, window_id, label, canvas_frame, packet, clear_color, packet_json_buffer, .{ .reason = .missing_service });
                        };
                        if (packet_presented) {
                            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                                self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
                                self.views[index].gpu_present_path = .packet;
                                clearCanvasPacketFallback(&self.views[index]);
                                recordCanvasPresentInputLatency(&self.views[index]);
                            }
                            return result;
                        }
                    } else {
                        recordCanvasPacketFallback(self, window_id, label, .{
                            .reason = .unsupported_command,
                            .command_kind = firstUnsupportedCommandName(canvas_frame, packet),
                        });
                    }
                } else {
                    // The caller offered packet transport buffers, so a
                    // packet was wanted; the platform simply has no
                    // packet presenter.
                    recordCanvasPacketFallback(self, window_id, label, .{ .reason = .missing_service });
                }
            }

            var pixel_frame = canvas_frame;
            if (pixel_scale) |scale| pixel_frame.scale = scale;
            try presentCanvasFramePixelsWithRecord(self, window_id, label, pixel_frame, canvas_frame, pixels, scratch, clear_color);
            return .{
                .frame = canvas_frame,
                .mode = .pixels,
                .packet_representable = false,
            };
        }

        pub fn presentCanvasFramePixels(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            canvas_frame: canvas.CanvasFrame,
            pixels: []u8,
            scratch: []u8,
            clear_color: canvas.Color,
        ) anyerror!void {
            try presentCanvasFramePixelsWithRecord(self, window_id, label, canvas_frame, canvas_frame, pixels, scratch, clear_color);
        }

        fn presentCanvasFramePixelsWithRecord(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            canvas_frame: canvas.CanvasFrame,
            record_frame: canvas.CanvasFrame,
            pixels: []u8,
            scratch: []u8,
            clear_color: canvas.Color,
        ) anyerror!void {
            recordCanvasClearColor(self, window_id, label, clear_color);
            if (!canvas_frame.requiresRender()) return;
            const pixel_size = try canvasFramePixelSize(canvas_frame);
            var surface = if (scratch.len >= pixel_size.byte_len)
                try canvas.ReferenceRenderSurface.initWithScratch(pixel_size.width, pixel_size.height, pixels, scratch)
            else
                try canvas.ReferenceRenderSurface.init(pixel_size.width, pixel_size.height, pixels);
            surface = surface.withImages(canvas_frame.image_resources).withFonts(canvas_frame.font_resources).withRenderMemo(self.options.pixel_present_render_memo);
            // Frame-profile `present` stage for the CPU pixel path: the
            // reference raster + the host present call (the software
            // equivalent of the packet host's decode+draw).
            const present_begin = self.frame_profile.begin();
            defer self.frame_profile.end(.present, present_begin);
            try surface.renderPass(canvas_frame.renderPass(), clear_color);
            try self.options.platform.services.presentGpuSurfacePixels(.{
                .window_id = window_id,
                .label = label,
                .width = pixel_size.width,
                .height = pixel_size.height,
                .scale_factor = canvas_frame.scale,
                .dirty_bounds = canvas_frame.dirty_bounds,
                .rgba8 = surface.pixels,
            });
            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                self.views[index].recordCanvasFramePresentationComplete(record_frame);
                // The platform present call succeeded: this frame painted
                // through the pixel path (covers the direct pixel entry
                // points and the packet-fallback route alike).
                self.views[index].gpu_present_path = .pixels;
                recordCanvasPresentInputLatency(&self.views[index]);
                // Pixels-only hosts that opted in keep the keyed mirror
                // ALIVE across pixel presents: the buffer now shows this
                // frame's keyed list, so the next plan refines its dirty
                // bounds from the key+fingerprint edit script instead of
                // the summary union (which marks every keyed command
                // changed on a Msg rebuild). The pixel adoption is marked
                // so the packet patch gate can never encode against it.
                var baseline_adopted = false;
                if (self.options.pixel_present_retained_baseline) {
                    if (gatherCanvasPacketCurrentCommands(record_frame)) |current| {
                        adoptCanvasPixelPresentBaseline(&self.views[index], current, record_frame.surface_size, record_frame.scale);
                        baseline_adopted = true;
                    }
                }
                // Otherwise: pixels on the glass no longer match the
                // retained command dictionary (the host drops its copy on
                // pixel presents too) — the next packet present must be
                // FULL.
                if (!baseline_adopted) self.views[index].canvas_packet_baseline_valid = false;
                self.views[index].gpu_present_packet_mode = .none;
                self.views[index].gpu_present_patch_bytes = 0;
                self.views[index].gpu_present_patch_upsert_count = 0;
                self.views[index].gpu_present_patch_evict_count = 0;
            }
        }

        pub fn presentNextCanvasFramePixels(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            options: canvas.CanvasFrameOptions,
            storage: canvas.CanvasFrameStorage,
            pixels: []u8,
            scratch: []u8,
            clear_color: canvas.Color,
        ) anyerror!canvas.CanvasFrame {
            const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
            try self.presentCanvasFramePixels(window_id, label, canvas_frame, pixels, scratch, clear_color);
            return canvas_frame;
        }

        /// Push the pixel bytes behind every `upload` image cache action
        /// in `packet` through the platform's binary side-channel
        /// (`uploadGpuSurfaceImage`) BEFORE the packet is presented, so
        /// the host holds the texture when it applies the action. Packet
        /// JSON carries only id + fingerprint references — pixel payloads
        /// never ride it, so frames with registered images stay under the
        /// packet JSON bound instead of falling back to the software
        /// pixel path. Absent resources (a draw referencing an id that is
        /// not registered — a legitimate transient state) upload nothing;
        /// the host skips those draws exactly like the reference
        /// renderer. `error.UnsupportedService` (platform without the
        /// seam) propagates so callers take their existing pixel
        /// fallback.
        fn uploadCanvasPacketImages(self: *Runtime, packet: canvas.CanvasGpuPacket) anyerror!void {
            for (packet.image_actions) |action| {
                if (action.kind != .upload) continue;
                const image_index = action.image_index orelse continue;
                if (image_index >= packet.images.len) continue;
                const image = packet.images[image_index];
                if (image.width == 0 or image.height == 0 or image.pixels.len == 0) continue;
                try self.options.platform.services.uploadGpuSurfaceImage(.{
                    .id = image.image_id,
                    .width = image.width,
                    .height = image.height,
                    .rgba8 = image.pixels,
                });
            }
        }

        /// Encode `packet` and push it through the platform's packet
        /// presenter. The compact binary encoding is preferred whenever
        /// the platform wires the binary presenter; a platform that
        /// wires it but refuses the call itself
        /// (`error.UnsupportedService`) gets the JSON attempt in the
        /// same frame, so capability negotiation is a per-present
        /// conversation rather than a boot-time contract and the JSON
        /// path stays alive for compatibility and wire debugging.
        ///
        /// On the binary path, presentation is INCREMENTAL whenever the
        /// view holds a valid retained baseline: the frame's full keyed
        /// command list is diffed against the baseline's key+fingerprint
        /// mirror and only the edits (upserts + evicts + the draw-order
        /// vector) ride the wire as a `patch` present. Everything else —
        /// no baseline, resized surface, unrepresentable or over-budget
        /// command lists, duplicate keys, host refusal, patch overflow —
        /// resolves to a FULL keyed present in the same frame that
        /// rebuilds both sides' retained state under a fresh generation.
        /// Drift can therefore cost one full present, never wrong pixels.
        ///
        /// Returns true when a present succeeded. Every refusal records
        /// its fallback reason on the view BEFORE returning, so
        /// automation snapshots explain WHY a frame left the packet
        /// path; `refusal` names the reason to record when a presenter
        /// exists but declines (the caller knows whether the packet was
        /// representable — this helper does not).
        fn presentCanvasPacketEncoded(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            canvas_frame: canvas.CanvasFrame,
            packet: canvas.CanvasGpuPacket,
            clear_color: canvas.Color,
            packet_bytes_buffer: []u8,
            refusal: CanvasPacketRefusal,
        ) anyerror!bool {
            const services = self.options.platform.services;
            var base = platform.GpuSurfacePacket{
                .window_id = window_id,
                .label = label,
                .frame_index = packet.frame_index,
                .timestamp_ns = packet.timestamp_ns,
                .surface_size = packet.surface_size,
                .scale_factor = packet.scale,
                .clear_color_rgba8 = canvasColorToRgba8(clear_color),
                .requires_render = packet.requiresRender(),
                .command_count = packet.commandCount(),
                .cache_action_count = packet.cacheActionCount(),
                .cached_resource_command_count = packet.cachedResourceCommandCount(),
                .unsupported_command_count = packet.unsupported_command_count,
                .representable = packet.fullyRepresentable(),
            };
            if (services.present_gpu_surface_packet_binary_fn != null) binary: {
                const binary_buffer = packet_bytes_buffer[0..@min(packet_bytes_buffer.len, platform.max_gpu_surface_packet_binary_bytes)];
                const view_index = runtimeFindViewIndex(self, window_id, label);
                // Frame-profile `patch` stage: gathering the keyed list +
                // diffing it against the retained baseline. Stamps no-op
                // unless profiling is on.
                const patch_begin = self.frame_profile.begin();
                // The retained protocol works on the frame's FULL keyed
                // draw order (never the scissor subset); null when the
                // full list is unrepresentable, over the retained budget,
                // or carries duplicate keys — those frames present
                // through the non-retained encoding below.
                const current = if (view_index != null) gatherCanvasPacketCurrentCommands(canvas_frame) else null;
                // Patch derivation runs eagerly with the gather (one
                // profile stage, one scratch fill the encoder below
                // reads); null when the view holds no usable baseline.
                const patch_stats: ?CanvasPacketPatchStats = stats: {
                    const current_commands = current orelse break :stats null;
                    const view = &self.views[view_index.?];
                    if (!view.canvas_packet_baseline_valid) break :stats null;
                    // A baseline a PIXEL present adopted refines dirty
                    // bounds only — no host retains a dictionary for it,
                    // so a patch encoded against it would edit nothing.
                    if (view.canvas_packet_baseline_pixels) break :stats null;
                    if (!sizesEqual(view.canvas_packet_baseline_surface_size, packet.surface_size) or
                        view.canvas_packet_baseline_scale != packet.scale) break :stats null;
                    break :stats computeCanvasPacketPatchStats(view, current_commands);
                };
                self.frame_profile.end(.patch, patch_begin);

                // ---- incremental attempt: patch the host's retained list.
                if (current) |current_commands| patch: {
                    const view = &self.views[view_index.?];
                    const stats = patch_stats orelse break :patch;
                    // A patch that re-encodes EVERY command is strictly
                    // larger than the keyed full present (same upserts
                    // plus the order vector), so frames where everything
                    // changed — a scroll step shifting the whole view —
                    // present full, which also refreshes the baseline
                    // generation.
                    if (stats.upsert_count >= current_commands.len) break :patch;
                    var writer = std.Io.Writer.fixed(binary_buffer);
                    // A patch that outgrows the transport is not a
                    // failure — the full present below is the compact
                    // form.
                    const encode_begin = self.frame_profile.begin();
                    writeCanvasPacketPatchBinary(view, canvas_frame, packet, current_commands, stats, &writer) catch break :patch;
                    self.frame_profile.end(.encode, encode_begin);
                    base.binary = writer.buffered();
                    base.json = "";
                    base.command_count = current_commands.len;
                    const present_begin = self.frame_profile.begin();
                    services.presentGpuSurfacePacketBinary(base) catch |err| switch (err) {
                        error.UnsupportedService => {
                            // Host refused the patch (retained state
                            // lost, generation drift, budget, decode).
                            // Record the reason, then resync via the
                            // full present below in this same frame.
                            recordCanvasPacketFallback(self, window_id, label, .{ .reason = .patch_refused });
                            view.canvas_packet_baseline_valid = false;
                            break :patch;
                        },
                        else => return err,
                    };
                    self.frame_profile.end(.present, present_begin);
                    adoptCanvasPacketBaseline(view, current_commands, packet);
                    view.gpu_present_packet_mode = .patch;
                    view.gpu_present_patch_bytes = base.binary.len;
                    view.gpu_present_patch_upsert_count = stats.upsert_count;
                    view.gpu_present_patch_evict_count = stats.evict_count;
                    return true;
                }

                // ---- full keyed present: (re)build both sides' retained
                // state under a fresh generation.
                if (current) |current_commands| {
                    const view = &self.views[view_index.?];
                    const generation = if (view.canvas_packet_generation == std.math.maxInt(u64)) 1 else view.canvas_packet_generation + 1;
                    var writer = std.Io.Writer.fixed(binary_buffer);
                    const encode_begin = self.frame_profile.begin();
                    writeCanvasPacketFullBinary(canvas_frame, packet, current_commands, generation, &writer) catch {
                        view.canvas_packet_baseline_valid = false;
                        if (services.present_gpu_surface_packet_fn == null) {
                            recordCanvasPacketFallback(self, window_id, label, .{
                                .reason = .binary_overflow,
                                .needed_bytes = canvasPacketFullBinaryByteSize(canvas_frame, packet, current_commands, generation),
                                .limit_bytes = binary_buffer.len,
                            });
                            return false;
                        }
                        break :binary;
                    };
                    self.frame_profile.end(.encode, encode_begin);
                    base.binary = writer.buffered();
                    base.json = "";
                    base.command_count = current_commands.len;
                    const present_begin = self.frame_profile.begin();
                    services.presentGpuSurfacePacketBinary(base) catch |err| switch (err) {
                        // A host that refuses the keyed full present is
                        // refusing this binary encoding, not the retained
                        // protocol: negotiate down to JSON.
                        error.UnsupportedService => {
                            view.canvas_packet_baseline_valid = false;
                            break :binary;
                        },
                        else => return err,
                    };
                    self.frame_profile.end(.present, present_begin);
                    view.canvas_packet_generation = generation;
                    adoptCanvasPacketBaseline(view, current_commands, packet);
                    view.gpu_present_packet_mode = .full;
                    view.gpu_present_patch_bytes = 0;
                    view.gpu_present_patch_upsert_count = 0;
                    view.gpu_present_patch_evict_count = 0;
                    return true;
                }

                // ---- non-retained binary present (no view, duplicate
                // keys, over-budget or unrepresentable full list): the
                // scissor-subset packet under generation 0, which the
                // host draws but never retains.
                if (view_index) |index| self.views[index].canvas_packet_baseline_valid = false;
                var writer = std.Io.Writer.fixed(binary_buffer);
                const encode_begin = self.frame_profile.begin();
                packet.writeBinary(&writer) catch {
                    // A frame too big for the binary encoding might
                    // still matter to a JSON-only host (whose binary
                    // presenter would have refused anyway), so the JSON
                    // attempt below delivers the single per-frame
                    // verdict — unless there is no JSON presenter at
                    // all, in which case this overflow IS the verdict.
                    if (services.present_gpu_surface_packet_fn == null) {
                        recordCanvasPacketFallback(self, window_id, label, .{
                            .reason = .binary_overflow,
                            .needed_bytes = canvasPacketEncodedByteSize(packet, .binary),
                            .limit_bytes = binary_buffer.len,
                        });
                        return false;
                    }
                    break :binary;
                };
                self.frame_profile.end(.encode, encode_begin);
                base.binary = writer.buffered();
                base.json = "";
                base.command_count = packet.commandCount();
                const present_begin = self.frame_profile.begin();
                services.presentGpuSurfacePacketBinary(base) catch |err| switch (err) {
                    // The platform wires the binary seam but declines at
                    // call time: negotiate down to JSON.
                    error.UnsupportedService => break :binary,
                    else => return err,
                };
                self.frame_profile.end(.present, present_begin);
                if (view_index) |index| recordCanvasPacketFullPresent(&self.views[index]);
                return true;
            }
            if (services.present_gpu_surface_packet_fn == null) {
                recordCanvasPacketFallback(self, window_id, label, .{ .reason = .missing_service });
                return false;
            }
            // The transport buffer may exceed the JSON wire bound (it is
            // sized for the larger binary encoding); clamp so an
            // oversized encode fails HERE as a recorded overflow instead
            // of tripping the service wrapper's validation.
            const json_buffer = packet_bytes_buffer[0..@min(packet_bytes_buffer.len, platform.max_gpu_surface_packet_json_bytes)];
            var writer = std.Io.Writer.fixed(json_buffer);
            const encode_begin = self.frame_profile.begin();
            packet.writeJson(&writer) catch {
                recordCanvasPacketFallback(self, window_id, label, .{
                    .reason = .json_overflow,
                    .needed_bytes = canvasPacketEncodedByteSize(packet, .json),
                    .limit_bytes = json_buffer.len,
                });
                return false;
            };
            self.frame_profile.end(.encode, encode_begin);
            base.json = writer.buffered();
            base.binary = "";
            base.command_count = packet.commandCount();
            const present_begin = self.frame_profile.begin();
            services.presentGpuSurfacePacket(base) catch |err| switch (err) {
                error.UnsupportedService => {
                    recordCanvasPacketFallback(self, window_id, label, refusal);
                    return false;
                },
                else => return err,
            };
            self.frame_profile.end(.present, present_begin);
            // JSON presents bypass the retained protocol entirely (the
            // host invalidates its retained state on them too).
            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                self.views[index].canvas_packet_baseline_valid = false;
                recordCanvasPacketFullPresent(&self.views[index]);
            }
            return true;
        }

        fn recordCanvasClearColor(self: *Runtime, window_id: platform.WindowId, label: []const u8, clear_color: canvas.Color) void {
            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                self.views[index].canvas_clear_color = clear_color;
            }
        }

        /// Render the view's current retained canvas scene through the
        /// deterministic CPU reference renderer — the same pixel path the
        /// software presentation uses (`presentCanvasFramePixels`) — without
        /// presenting or mutating presentation state. The frame is planned
        /// as a full repaint at the view's last frame timestamp, cleared
        /// with the view's declared clear color — recorded by presents AND
        /// by widget display-list emissions (from live tokens), so a theme
        /// change screenshots correctly without an intervening present.
        /// `pixels` (and optionally
        /// `scratch`, for layer effects) must hold
        /// `canvasScreenshotPixelSize(...).byte_len` bytes.
        pub fn renderCanvasScreenshot(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            scale: ?f32,
            pixels: []u8,
            scratch: []u8,
        ) anyerror!CanvasScreenshot {
            return renderCanvasScreenshotWithMemo(self, window_id, label, scale, pixels, scratch, null);
        }

        /// `renderCanvasScreenshot` with a caller-owned render memo for
        /// hosts that re-render the same retained scene every frame (the
        /// docs live previews): heavyweight per-pixel commands (backdrop
        /// blur, drop shadow, big fills) whose inputs are byte-identical
        /// to the previous render replay their stored pixels instead of
        /// re-running their loops. Output bytes are identical with or
        /// without the memo — it only moves time, never pixels.
        pub fn renderCanvasScreenshotWithMemo(
            self: *Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            scale: ?f32,
            pixels: []u8,
            scratch: []u8,
            render_memo: ?*canvas.ReferenceRenderMemo,
        ) anyerror!CanvasScreenshot {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            const canvas_frame = try planCanvasFrameForView(self, index, .{
                .frame_index = self.views[index].gpu_frame_index,
                .timestamp_ns = self.views[index].gpu_timestamp_ns,
                .surface_size = canvasScreenshotSurfaceSize(&self.views[index]),
                .scale = normalizedCanvasPresentationScale(scale, 1),
                .full_repaint = true,
            }, canvasFrameScratchStorage(self), false);
            const pixel_size = try canvasFramePixelSize(canvas_frame);
            var surface = if (scratch.len >= pixel_size.byte_len)
                try canvas.ReferenceRenderSurface.initWithScratch(pixel_size.width, pixel_size.height, pixels, scratch)
            else
                try canvas.ReferenceRenderSurface.init(pixel_size.width, pixel_size.height, pixels);
            surface = surface.withImages(canvas_frame.image_resources).withFonts(canvas_frame.font_resources).withRenderMemo(render_memo);
            try surface.renderPass(canvas_frame.renderPass(), self.views[index].canvas_clear_color);
            return .{
                .width = pixel_size.width,
                .height = pixel_size.height,
                .rgba8 = surface.pixels,
            };
        }

        /// Pixel dimensions `renderCanvasScreenshot` will produce for the
        /// view at the given scale (default 1).
        pub fn canvasScreenshotPixelSize(
            self: *const Runtime,
            window_id: platform.WindowId,
            label: []const u8,
            scale: ?f32,
        ) anyerror!CanvasPixelSize {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return canvasSurfacePixelSize(canvasScreenshotSurfaceSize(&self.views[index]), normalizedCanvasPresentationScale(scale, 1));
        }

        fn canvasScreenshotSurfaceSize(view: anytype) geometry.SizeF {
            return if (view.gpu_size.isEmpty()) view.frame.size() else view.gpu_size;
        }

        pub fn planCanvasFrameForView(self: *Runtime, index: usize, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage, record: bool) anyerror!canvas.CanvasFrame {
            // Frame-profile `plan` stage: the whole render-plan cascade
            // (batches, caches, text layout, diff). Recording plans only —
            // diagnostic previews and screenshots re-plan without
            // presenting and would double-count. No-op unless profiling
            // is on.
            const plan_begin = if (record) self.frame_profile.begin() else 0;
            defer if (record) self.frame_profile.end(.plan, plan_begin);
            // Launch laps (env-gated, once per process): bracket the
            // startup frame's render-plan cascade so the launch timeline
            // splits plan cost (text layout, caches, diff) from the
            // reconcile/emit segment before it and the encode/present
            // segment after it.
            launch_timing.lapOnce("first_plan_begin");
            defer launch_timing.lapOnce("first_plan_done");
            var frame_options = options;
            if (frame_options.surface_size.isEmpty()) {
                frame_options.surface_size = if (self.views[index].gpu_size.isEmpty()) self.views[index].frame.size() else self.views[index].gpu_size;
            }
            // Runtime-registered images feed every view unless the caller
            // supplied its own resource set: the CPU pixel paths
            // (presentation, screenshots) and the GPU packet plan both
            // read `image_resources` from the planned frame.
            if (frame_options.image_resources.len == 0) {
                frame_options.image_resources = self.registeredCanvasImages();
            }
            // Runtime-registered fonts feed every view the same way: the
            // CPU pixel paths resolve registered font ids from the
            // planned frame's `font_resources`.
            if (frame_options.font_resources.len == 0) {
                frame_options.font_resources = self.registeredCanvasFonts();
            }
            if (canvasFrameBudgetIsUnset(frame_options.budget)) {
                frame_options.budget = self.views[index].canvas_frame_budget;
            }
            frame_options.previous_resource_cache = self.views[index].canvasFrameResourceCache();
            frame_options.previous_pipeline_cache = self.views[index].canvasFramePipelineCache();
            frame_options.previous_path_geometry_cache = self.views[index].canvasFramePathGeometryCache();
            frame_options.previous_image_cache = self.views[index].canvasFrameImageCache();
            frame_options.previous_layer_cache = self.views[index].canvasFrameLayerCache();
            frame_options.previous_visual_effect_cache = self.views[index].canvasFrameVisualEffectCache();
            frame_options.previous_glyph_atlas_cache = self.views[index].canvasFrameGlyphAtlasCache();
            frame_options.previous_text_layout_cache = self.views[index].canvasFrameTextLayoutCache();
            const scheduled_render_overrides = try self.views[index].sampleCanvasRenderAnimations(
                frame_options.timestamp_ns,
                &self.canvas_frame_render_override_samples,
            );
            const render_overrides = try mergeCanvasRenderOverrides(
                scheduled_render_overrides,
                frame_options.render_overrides,
                &self.canvas_frame_render_override_combined,
            );
            if (frame_options.previous_render_overrides.len == 0) {
                frame_options.previous_render_overrides = self.views[index].canvasFrameRenderOverrides();
            }
            frame_options.render_overrides = render_overrides;

            const display_list = self.views[index].canvasDisplayList();
            const canvas_changed = self.views[index].canvas_revision != self.views[index].presented_canvas_revision;
            const canvas_surface_changed = !sizesEqual(self.views[index].presented_canvas_surface_size, frame_options.surface_size) or
                self.views[index].presented_canvas_scale != frame_options.scale;
            if (!frame_options.full_repaint and
                self.views[index].presented_canvas_valid and
                !canvas_changed and
                !canvas_surface_changed and
                frame_options.previous_render_overrides.len == 0 and
                frame_options.render_overrides.len == 0)
            {
                const canvas_frame = canvas.CanvasFrame{
                    .frame_index = frame_options.frame_index,
                    .timestamp_ns = frame_options.timestamp_ns,
                    .surface_size = frame_options.surface_size,
                    .scale = frame_options.scale,
                    .display_list = display_list,
                    .image_resources = frame_options.image_resources,
                    .font_resources = frame_options.font_resources,
                    .changes = storage.changes[0..0],
                    .budget = frame_options.budget,
                };
                self.views[index].recordCanvasFrame(canvas_frame);
                return canvas_frame;
            }

            var render_plan = try display_list.renderPlan(storage.render_commands);
            const render_override_dirty_bounds = canvas.renderOverrideDirtyBounds(render_plan.commands, frame_options.previous_render_overrides, frame_options.render_overrides);
            const render_animation_dirty_bounds = self.views[index].canvasRenderAnimationDirtyBoundsForOverrides(frame_options.previous_render_overrides, frame_options.render_overrides);
            render_plan.bounds = canvas.applyRenderOverrides(storage.render_commands[0..render_plan.commandCount()], frame_options.render_overrides);
            const batch_plan = try render_plan.batchPlan(storage.render_batches);
            const pipeline_cache_plan = if (storage.pipeline_cache_entries.len == 0 and storage.pipeline_cache_actions.len == 0)
                canvas.RenderPipelineCachePlan{}
            else
                try batch_plan.cachePlan(
                    frame_options.previous_pipeline_cache,
                    frame_options.frame_index,
                    storage.pipeline_cache_entries,
                    storage.pipeline_cache_actions,
                );
            const path_geometry_plan = if (storage.path_geometries.len == 0)
                canvas.RenderPathGeometryPlan{}
            else
                try render_plan.pathGeometryPlan(storage.path_geometries);
            const path_geometry_cache_plan = if (storage.path_geometry_cache_entries.len == 0 and storage.path_geometry_cache_actions.len == 0)
                canvas.RenderPathGeometryCachePlan{}
            else
                try path_geometry_plan.cachePlan(
                    frame_options.previous_path_geometry_cache,
                    frame_options.frame_index,
                    storage.path_geometry_cache_entries,
                    storage.path_geometry_cache_actions,
                );
            const image_plan = if (storage.images.len == 0)
                canvas.RenderImagePlan{}
            else
                try render_plan.imagePlanWithResources(frame_options.image_resources, storage.images);
            const image_cache_plan = if (storage.image_cache_entries.len == 0 and storage.image_cache_actions.len == 0)
                canvas.RenderImageCachePlan{}
            else
                try image_plan.cachePlan(
                    frame_options.previous_image_cache,
                    frame_options.frame_index,
                    storage.image_cache_entries,
                    storage.image_cache_actions,
                );
            const layer_plan = if (storage.layers.len == 0)
                canvas.RenderLayerPlan{}
            else
                try render_plan.layerPlan(storage.layers);
            const layer_cache_plan = if (storage.layer_cache_entries.len == 0 and storage.layer_cache_actions.len == 0)
                canvas.RenderLayerCachePlan{}
            else
                try layer_plan.cachePlan(
                    frame_options.previous_layer_cache,
                    frame_options.frame_index,
                    storage.layer_cache_entries,
                    storage.layer_cache_actions,
                );
            const resource_plan = try display_list.resourcePlan(storage.resources);
            const resource_cache_plan = try resource_plan.cachePlan(
                frame_options.previous_resource_cache,
                frame_options.frame_index,
                storage.resource_cache_entries,
                storage.resource_cache_actions,
            );
            const visual_effect_plan = if (storage.visual_effects.len == 0)
                canvas.VisualEffectPlan{}
            else
                try display_list.visualEffectPlan(storage.visual_effects);
            const visual_effect_cache_plan = if (storage.visual_effect_cache_entries.len == 0 and storage.visual_effect_cache_actions.len == 0)
                canvas.VisualEffectCachePlan{}
            else
                try visual_effect_plan.cachePlan(
                    frame_options.previous_visual_effect_cache,
                    frame_options.frame_index,
                    storage.visual_effect_cache_entries,
                    storage.visual_effect_cache_actions,
                );
            const glyph_atlas_plan = try display_list.glyphAtlasPlan(storage.glyph_atlas_entries);
            const glyph_atlas_cache_plan = try glyph_atlas_plan.cachePlanWithRetention(
                frame_options.previous_glyph_atlas_cache,
                frame_options.frame_index,
                frame_options.glyph_atlas_cache_retention_frames,
                storage.glyph_atlas_cache_entries,
                storage.glyph_atlas_cache_actions,
            );
            const text_layout_plan = display_list.textLayoutPlan(frame_options.text_layout_options, storage.text_layout_plans, storage.text_layout_lines) catch |err| {
                // Teach the fix at the failure site: the bare error
                // name kills the frame without saying which budget bound
                // it or where the headroom telemetry lives.
                switch (err) {
                    error.TextLayoutPlanListFull => canvas_frame_log.warn(
                        "text layout plan capacity exceeded: the per-frame budget is {d} text runs (canvas_limits.max_canvas_text_layouts_per_view) - reduce visible draw_text commands or virtualize long text; snapshots report headroom as text_layout_plans=N/{d}",
                        .{ canvas_limits.max_canvas_text_layouts_per_view, canvas_limits.max_canvas_text_layouts_per_view },
                    ),
                    error.TextLayoutLineListFull => canvas_frame_log.warn(
                        "text layout line capacity exceeded: the per-frame budget is {d} wrapped lines across all text runs (canvas_limits.max_canvas_text_layout_lines_per_view) - clip or window long wrapped text; snapshots report headroom as text_layout_lines=N/{d}",
                        .{ canvas_limits.max_canvas_text_layout_lines_per_view, canvas_limits.max_canvas_text_layout_lines_per_view },
                    ),
                    else => {},
                }
                return err;
            };
            const text_layout_cache_plan = if (storage.text_layout_cache_entries.len == 0 and storage.text_layout_cache_actions.len == 0)
                canvas.TextLayoutCachePlan{}
            else
                try text_layout_plan.cachePlanWithRetention(
                    frame_options.previous_text_layout_cache,
                    frame_options.frame_index,
                    frame_options.text_layout_cache_retention_frames,
                    storage.text_layout_cache_entries,
                    storage.text_layout_cache_actions,
                );

            const full_repaint = frame_options.full_repaint or
                !self.views[index].presented_canvas_valid or
                canvas_surface_changed or
                (canvas_changed and (self.views[index].presented_canvas_has_unkeyed or self.views[index].currentCanvasHasUnkeyed()));
            const changes = if (full_repaint)
                storage.changes[0..0]
            else
                try self.views[index].diffPresentedCanvasSummary(storage.changes);
            var dirty_rects: [canvas.max_canvas_frame_dirty_rects]geometry.RectF = undefined;
            var dirty_rect_count: usize = 0;
            const dirty_bounds = if (full_repaint)
                canvasFullRepaintBounds(frame_options.surface_size, render_plan.bounds)
            else dirty: {
                // Every incremental dirty rect leaves here inflated by
                // one device pixel (`canvasDirtyBleedInset`) and snapped
                // OUTWARD to the device-pixel grid
                // (`deviceAlignedCanvasDirtyBounds`). The inflation
                // covers the PAINTED extent of what changed —
                // antialiased edges and glyph overshoot ink up to a
                // device pixel past a command's bounds on host
                // rasterizers — or content that shrinks, moves, or
                // disappears strands a stale fringe the repaint never
                // clears. The snap keeps the CULL region identical to
                // the CLEARED pixels: clears land on whole pixels while
                // culling tests the float rect, so a fractional dirty
                // edge would erase the boundary pixel's antialiased
                // coverage without redrawing the unchanged neighbor
                // that painted it. Both land on the finalized rects
                // (the refined union, each refined cluster, and the
                // summary fallback), which covers every contribution:
                // dilation distributes over union.
                const bleed = canvasDirtyBleedInset(frame_options.scale);
                const overrides_dirty = unionRects(render_override_dirty_bounds, render_animation_dirty_bounds);
                // Msg rebuilds: the presented summary records ids and
                // bounds but not content, so a rebuild marks every keyed
                // command changed and the dirty rect degrades to the
                // window even when only a handful of commands differ.
                // When the view holds a valid retained baseline for this
                // exact surface, derive the dirty rect from the SAME
                // key+fingerprint edit script the patch present ships —
                // the changed commands' union (old and new extents), not
                // the view — and keep the per-change rect clusters so
                // far-apart changes present as a dirty rect LIST instead
                // of their bounding union. Refused refinements (no
                // baseline, unkeyable list, z-order shuffle of unchanged
                // commands) keep the conservative summary union below.
                // Deliberately NO small-list floor: every other
                // min_entries_for_index gate picks index vs linear scan
                // with byte-identical results, but skipping refinement
                // here changes the dirty AREA — a scene one command
                // under a floor would repaint the full window per click
                // (a measured ~17 ms of direct-command re-raster on a
                // 68-command dashboard) where the derived rect costs a
                // sub-millisecond sort over at most the retained-packet
                // command budget. Pixel-adopted baselines raise the
                // stakes further: a full-window repaint there means a
                // full-surface CPU raster AND a full-surface upload, so
                // refinement must run at any command count.
                if (canvas_changed and
                    self.views[index].canvas_packet_baseline_valid and
                    sizesEqual(self.views[index].canvas_packet_baseline_surface_size, frame_options.surface_size) and
                    self.views[index].canvas_packet_baseline_scale == frame_options.scale)
                {
                    if (gatherCanvasPacketCurrentCommandsFromPlan(render_plan.commands, frame_options.surface_size, render_plan.bounds)) |current| {
                        if (canvasPacketPatchDirtyBounds(&self.views[index], current)) |patch_dirty| {
                            var refined = patch_dirty;
                            if (overrides_dirty) |overrides_rect| refined.add(overrides_rect);
                            const clipped = clippedCanvasDirtyBounds(deviceAlignedCanvasDirtyBounds(inflatedCanvasDirtyBounds(refined.bounds, bleed), frame_options.scale), frame_options.surface_size);
                            // A list of one rect adds nothing over the
                            // scissor; ship it only when it splits.
                            if (clipped != null and refined.rect_count > 1) {
                                for (refined.rects[0..refined.rect_count]) |rect| {
                                    const clipped_rect = clippedCanvasDirtyBounds(deviceAlignedCanvasDirtyBounds(inflatedCanvasDirtyBounds(rect, bleed), frame_options.scale), frame_options.surface_size) orelse continue;
                                    dirty_rects[dirty_rect_count] = clipped_rect;
                                    dirty_rect_count += 1;
                                }
                                if (dirty_rect_count < 2) dirty_rect_count = 0;
                            }
                            break :dirty clipped;
                        }
                    }
                }
                break :dirty clippedCanvasDirtyBounds(deviceAlignedCanvasDirtyBounds(inflatedCanvasDirtyBounds(unionRects(canvasDirtyBoundsFromChanges(changes), overrides_dirty), bleed), frame_options.scale), frame_options.surface_size);
            };

            const canvas_frame = canvas.CanvasFrame{
                .frame_index = frame_options.frame_index,
                .timestamp_ns = frame_options.timestamp_ns,
                .surface_size = frame_options.surface_size,
                .scale = frame_options.scale,
                .full_repaint = full_repaint,
                .display_list = display_list,
                .render_plan = render_plan,
                .batch_plan = batch_plan,
                .pipeline_cache_plan = pipeline_cache_plan,
                .path_geometry_plan = path_geometry_plan,
                .path_geometry_cache_plan = path_geometry_cache_plan,
                .image_plan = image_plan,
                .image_cache_plan = image_cache_plan,
                .layer_plan = layer_plan,
                .layer_cache_plan = layer_cache_plan,
                .resource_plan = resource_plan,
                .resource_cache_plan = resource_cache_plan,
                .visual_effect_plan = visual_effect_plan,
                .visual_effect_cache_plan = visual_effect_cache_plan,
                .glyph_atlas_plan = glyph_atlas_plan,
                .glyph_atlas_cache_plan = glyph_atlas_cache_plan,
                .text_layout_plan = text_layout_plan,
                .text_layout_cache_plan = text_layout_cache_plan,
                .image_resources = frame_options.image_resources,
                .font_resources = frame_options.font_resources,
                .changes = changes,
                .dirty_bounds = dirty_bounds,
                .dirty_rects = dirty_rects,
                .dirty_rect_count = dirty_rect_count,
                .budget = frame_options.budget,
            };
            if (record) {
                try self.views[index].copyCanvasFramePipelineCache(canvas_frame.pipeline_cache_plan.entries);
                try self.views[index].copyCanvasFramePathGeometryCache(canvas_frame.path_geometry_cache_plan.entries);
                try self.views[index].copyCanvasFrameImageCache(canvas_frame.image_cache_plan.entries);
                try self.views[index].copyCanvasFrameLayerCache(canvas_frame.layer_cache_plan.entries);
                try self.views[index].copyCanvasFrameResourceCache(canvas_frame.resource_cache_plan.entries);
                try self.views[index].copyCanvasFrameVisualEffectCache(canvas_frame.visual_effect_cache_plan.entries);
                try self.views[index].copyCanvasFrameGlyphAtlasCache(canvas_frame.glyph_atlas_cache_plan.entries);
                try self.views[index].copyCanvasFrameTextLayoutCache(canvas_frame.text_layout_cache_plan.entries);
                try self.views[index].copyPresentedCanvasSummary(display_list, canvas_frame.surface_size, canvas_frame.scale);
                self.views[index].recordCanvasFrame(canvas_frame);
                try self.views[index].copyCanvasFrameRenderOverrides(frame_options.render_overrides);
                if (self.views[index].pruneCompletedNoopCanvasRenderAnimations(frame_options.timestamp_ns)) {
                    self.views[index].compactCanvasFrameRenderOverrideNoops();
                }
                if (self.views[index].canvasRenderAnimationsActive(frame_options.timestamp_ns)) {
                    self.invalidateFor(.state, self.views[index].frame);
                }
                // An armed tooltip show delay — and a running anchor-gap
                // transit grace — only fire on a presented frame's
                // timestamp, so frames must keep coming while either is
                // pending: the render-animation pump's policy. This
                // per-frame leg takes over from the FIRST invalidation,
                // which the intent choke point kicks the moment any
                // deadline arms (reconcileCanvasTooltipIntent step 5 —
                // a deadline armed by an event that repainted nothing
                // would otherwise wait forever for a frame nothing
                // requested). Settled shown tooltips and the warm
                // window need no pump: both step on journaled input
                // timestamps.
                if (self.views[index].canvasTooltipIntentArmed()) {
                    self.invalidateFor(.state, self.views[index].frame);
                }
            } else {
                self.views[index].recordCanvasFrame(canvas_frame);
            }
            return canvas_frame;
        }

        pub fn canvasFrameScratchStorage(self: *Runtime) canvas.CanvasFrameStorage {
            const scratch = canvas_frame_scratch.get();
            return .{
                .render_commands = &self.canvas_frame_render_commands,
                .render_batches = &self.canvas_frame_render_batches,
                .pipeline_cache_entries = &self.canvas_frame_pipeline_cache_entries,
                .pipeline_cache_actions = &self.canvas_frame_pipeline_cache_actions,
                .path_geometries = &self.canvas_frame_path_geometries,
                .path_geometry_cache_entries = &self.canvas_frame_path_geometry_cache_entries,
                .path_geometry_cache_actions = &self.canvas_frame_path_geometry_cache_actions,
                .images = &self.canvas_frame_images,
                .image_cache_entries = &self.canvas_frame_image_cache_entries,
                .image_cache_actions = &self.canvas_frame_image_cache_actions,
                .layers = &self.canvas_frame_layers,
                .layer_cache_entries = &self.canvas_frame_layer_cache_entries,
                .layer_cache_actions = &self.canvas_frame_layer_cache_actions,
                .resources = &self.canvas_frame_resources,
                .resource_cache_entries = &self.canvas_frame_resource_cache_entries,
                .resource_cache_actions = &self.canvas_frame_resource_cache_actions,
                .visual_effects = &self.canvas_frame_visual_effects,
                .visual_effect_cache_entries = &self.canvas_frame_visual_effect_cache_entries,
                .visual_effect_cache_actions = &self.canvas_frame_visual_effect_cache_actions,
                .glyph_atlas_entries = &self.canvas_frame_glyph_atlas_entries,
                .glyph_atlas_cache_entries = &self.canvas_frame_glyph_atlas_cache_entries,
                .glyph_atlas_cache_actions = &self.canvas_frame_glyph_atlas_cache_actions,
                .text_layout_plans = &scratch.text_layout_plans,
                .text_layout_lines = &scratch.text_layout_lines,
                .text_layout_cache_entries = &scratch.text_layout_cache_entries,
                .text_layout_cache_actions = &scratch.text_layout_cache_actions,
                .changes = &self.canvas_frame_changes,
            };
        }

        pub fn gpuSurfaceFrame(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.GpuFrame {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            return self.views[index].info().gpuFrame() orelse error.InvalidViewOptions;
        }

        pub fn setCanvasFrameBudget(self: *Runtime, window_id: platform.WindowId, label: []const u8, budget: canvas.CanvasFrameBudget) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            self.views[index].canvas_frame_budget = budget;
            self.views[index].refreshCanvasFrameBudgetStatus();
            return self.views[index].info();
        }

        pub fn setGpuSurfaceInputLatencyBudget(self: *Runtime, window_id: platform.WindowId, label: []const u8, budget_ns: u64) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            self.views[index].gpu_input_latency_budget_ns = budget_ns;
            self.views[index].gpu_input_latency_budget_custom = true;
            self.views[index].refreshGpuSurfaceInputLatencyBudgetStatus();
            return self.views[index].info();
        }

        pub fn requestCanvasFrameForView(self: *Runtime, view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            self.options.platform.services.requestGpuSurfaceFrame(
                self.views[view_index].window_id,
                self.views[view_index].label,
            ) catch |err| switch (err) {
                error.UnsupportedService => return,
                else => return err,
            };
            // A frame event is now coming for this view — the deferred
            // accessibility settle logic keys off this.
            self.views[view_index].gpu_canvas_frame_requested = true;
        }

        pub fn invalidateForCanvasChanges(self: *Runtime, view_frame: geometry.RectF, changes: []const canvas.DiffChange) void {
            var emitted_dirty_region = false;
            for (changes) |change| {
                const local_dirty = change.dirty_bounds orelse continue;
                if (canvasDirtyRegionForView(view_frame, local_dirty)) |dirty_region| {
                    self.invalidateFor(.state, dirty_region);
                    emitted_dirty_region = true;
                }
            }
            if (!emitted_dirty_region and changes.len > 0) self.invalidateFor(.state, view_frame);
        }
    };
}

/// Widen a planned frame's incremental damage when the present's
/// EFFECTIVE scale carries a larger device pixel than the plan's: the
/// AA bleed allowance was folded in at plan scale
/// (`canvasDirtyBleedInset`), so a presentation-scale override below it
/// must add the difference or the one-device-pixel fringe reopens
/// (e.g. planned at scale 2, presented at scale 1: half a point of
/// allowance where the host's raster apron spans a full point). No-op
/// for full repaints, equal or finer presentation scales, and frames
/// with nothing dirty.
fn widenCanvasFrameDirtyForPresentationScale(canvas_frame: *canvas.CanvasFrame, presentation_scale: f32) void {
    if (canvas_frame.full_repaint) return;
    const extra = canvasDirtyBleedInset(presentation_scale) - canvasDirtyBleedInset(canvas_frame.scale);
    if (!(extra > 0)) return;
    // Re-align on the COARSER presentation grid too: the plan's snap
    // used its finer grid, whose edges can split a presented pixel.
    canvas_frame.dirty_bounds = clippedCanvasDirtyBounds(deviceAlignedCanvasDirtyBounds(inflatedCanvasDirtyBounds(canvas_frame.dirty_bounds, extra), presentation_scale), canvas_frame.surface_size);
    var kept: usize = 0;
    for (canvas_frame.dirty_rects[0..canvas_frame.dirty_rect_count]) |rect| {
        const widened = clippedCanvasDirtyBounds(deviceAlignedCanvasDirtyBounds(inflatedCanvasDirtyBounds(rect, extra), presentation_scale), canvas_frame.surface_size) orelse continue;
        canvas_frame.dirty_rects[kept] = widened;
        kept += 1;
    }
    canvas_frame.dirty_rect_count = if (kept < 2) 0 else kept;
}

/// What to record when a packet attempt fails: the reason plus the
/// overflow byte math or the offending command kind, whichever applies.
const CanvasPacketRefusal = struct {
    reason: platform.GpuPresentFallbackReason,
    needed_bytes: usize = 0,
    limit_bytes: usize = 0,
    command_kind: []const u8 = "",
};

/// Edit-script size of the last patch encode, for telemetry.
const CanvasPacketPatchStats = struct {
    upsert_count: usize = 0,
    evict_count: usize = 0,
};

/// Stamp `gpu_input_latency` at the RESPONDING present's completion:
/// the present call above just returned synchronously, so the wall
/// clock NOW (the domain every host and automation input timestamp
/// uses) is the moment the input's pixels reached the swapchain. The
/// paced completion event that used to stamp this arrives up to a
/// frame interval later and measured the pacing channel, not the
/// glass; it remains the fallback for inputs that present nothing.
fn recordCanvasPresentInputLatency(view: anytype) void {
    if (view.gpu_pending_input_timestamp_ns == 0) return;
    view.recordGpuSurfaceInputLatencyForFrame(runtime_clock.timestampToU64(runtime_clock.nowNanoseconds()));
}

/// Build the frame's CURRENT keyed command list — every supported render
/// command intersecting the full-repaint bounds, in draw order, with its
/// retain key and content fingerprint. This is the exact set a full
/// keyed present ships (and the host retains), so patches derived from
/// it can never disagree with a full re-present. Returns null when the
/// frame cannot ride the retained protocol: an unsupported command
/// anywhere in the FULL list (a scissor subset might hide it), more
/// commands than the retained budget
/// (`canvas_limits.max_canvas_retained_packet_commands_per_view`), or
/// duplicate retain keys (which would corrupt a keyed dictionary) — those
/// frames present through the non-retained encoding instead.
fn gatherCanvasPacketCurrentCommands(canvas_frame: canvas.CanvasFrame) ?[]const CanvasPacketCurrentCommand {
    return gatherCanvasPacketCurrentCommandsFromPlan(canvas_frame.render_plan.commands, canvas_frame.surface_size, canvas_frame.render_plan.bounds);
}

/// Plan-time twin of `gatherCanvasPacketCurrentCommands`: the frame
/// planner derives Msg-rebuild dirty bounds from the same keyed list
/// before the `CanvasFrame` value exists. Same inputs, same scratch,
/// byte-identical output.
fn gatherCanvasPacketCurrentCommandsFromPlan(render_commands: []const canvas.RenderCommand, surface_size: geometry.SizeF, render_bounds: ?geometry.RectF) ?[]const CanvasPacketCurrentCommand {
    const full_bounds = canvasFullRepaintBounds(surface_size, render_bounds) orelse return null;
    const scratch = canvas_frame_scratch.get();
    var count: usize = 0;
    for (render_commands, 0..) |command, index| {
        if (!canvas.renderCommandIntersectsDirtyBounds(command, full_bounds)) continue;
        const gpu_command = canvas.canvasGpuCommandFromRenderCommand(command, index);
        if (!gpu_command.supported()) return null;
        if (count >= scratch.packet_current.len) return null;
        const fingerprint = canvas.canvasGpuCommandFingerprint(gpu_command);
        scratch.packet_current[count] = .{
            .key = canvas.canvasGpuPacketCommandKey(gpu_command, fingerprint),
            .fingerprint = fingerprint,
            .render_index = @intCast(index),
            .bounds = command.bounds,
        };
        count += 1;
    }
    const sorted = scratch.packet_current_sort[0..count];
    for (sorted, 0..) |*slot, index| slot.* = @intCast(index);
    std.sort.pdq(u32, sorted, @as([]const CanvasPacketCurrentCommand, scratch.packet_current[0..count]), canvasPacketCurrentKeyLessThan);
    var index: usize = 1;
    while (index < count) : (index += 1) {
        if (scratch.packet_current[sorted[index - 1]].key == scratch.packet_current[sorted[index]].key) return null;
    }
    return scratch.packet_current[0..count];
}

fn canvasPacketCurrentKeyLessThan(current: []const CanvasPacketCurrentCommand, a: u32, b: u32) bool {
    return current[a].key < current[b].key;
}

fn canvasPacketBaselineKeyLessThan(keys: []const u64, a: u32, b: u32) bool {
    return keys[a] < keys[b];
}

/// Binary search over `sorted` (an index array ordered by key) for `key`;
/// returns the baseline index holding it.
fn findCanvasPacketBaselineIndex(keys: []const u64, sorted: []const u32, key: u64) ?usize {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const candidate = keys[sorted[mid]];
        if (candidate == key) return sorted[mid];
        if (candidate < key) low = mid + 1 else high = mid;
    }
    return null;
}

/// Diff the frame's current keyed list against the view's retained
/// baseline: fills the matched/upsert scratch flags (which the patch
/// encoder reads) and returns the edit counts, so callers can decide
/// patch-vs-full BEFORE paying for the encode.
fn computeCanvasPacketPatchStats(view: anytype, current: []const CanvasPacketCurrentCommand) CanvasPacketPatchStats {
    const baseline_count = view.canvas_packet_baseline_count;
    const baseline_keys = view.canvas_packet_baseline_keys[0..baseline_count];
    const baseline_fingerprints = view.canvas_packet_baseline_fingerprints[0..baseline_count];

    const scratch = canvas_frame_scratch.get();
    const baseline_sorted = scratch.packet_baseline_sort[0..baseline_count];
    for (baseline_sorted, 0..) |*slot, index| slot.* = @intCast(index);
    std.sort.pdq(u32, baseline_sorted, @as([]const u64, baseline_keys), canvasPacketBaselineKeyLessThan);
    const matched = scratch.packet_baseline_matched[0..baseline_count];
    @memset(matched, false);
    const upserts = scratch.packet_upsert[0..current.len];

    var stats = CanvasPacketPatchStats{};
    for (current, 0..) |entry, index| {
        upserts[index] = true;
        if (findCanvasPacketBaselineIndex(baseline_keys, baseline_sorted, entry.key)) |baseline_index| {
            matched[baseline_index] = true;
            if (baseline_fingerprints[baseline_index] == entry.fingerprint) upserts[index] = false;
        }
        if (upserts[index]) stats.upsert_count += 1;
    }
    for (matched) |flag| {
        if (!flag) stats.evict_count += 1;
    }
    return stats;
}

/// The pixels the retained-patch edit script can touch, derived from
/// the SAME key+fingerprint diff the patch present ships: the union of
/// every upserted command's current bounds, the baseline bounds of the
/// key it replaces (content changed — the OLD pixels repaint too), and
/// every evicted baseline entry's bounds (vacated pixels). `.{ .bounds
/// = null }` means the edit script is empty — nothing visual changed.
/// `rects` refines the union into up to `max_canvas_frame_dirty_rects`
/// clusters so far-apart small changes (a switch plus a status line)
/// stay two small repaints instead of a window-sized one. Returns null
/// (refinement refused, caller keeps its conservative dirty) when
/// unchanged commands moved relative to each other in draw order: a
/// z-order shuffle changes pixels only where commands overlap, which a
/// bounds union of the CHANGED set cannot name.
const CanvasPacketPatchDirty = struct {
    bounds: ?geometry.RectF = null,
    rects: [canvas.max_canvas_frame_dirty_rects]geometry.RectF = undefined,
    rect_count: usize = 0,

    /// Fold `rect` in: union with the first intersecting cluster, a new
    /// cluster while slots remain, else the cluster whose union grows
    /// the least. `bounds` stays the union of everything added.
    fn add(self: *CanvasPacketPatchDirty, rect: geometry.RectF) void {
        const normalized = rect.normalized();
        if (normalized.isEmpty()) return;
        self.bounds = unionRects(self.bounds, normalized);
        for (self.rects[0..self.rect_count]) |*cluster| {
            if (cluster.intersects(normalized)) {
                cluster.* = geometry.RectF.unionWith(cluster.*, normalized);
                return;
            }
        }
        if (self.rect_count < self.rects.len) {
            self.rects[self.rect_count] = normalized;
            self.rect_count += 1;
            return;
        }
        var best_index: usize = 0;
        var best_cost: f32 = std.math.floatMax(f32);
        for (self.rects[0..self.rect_count], 0..) |cluster, index| {
            const merged = geometry.RectF.unionWith(cluster, normalized);
            const cost = merged.width * merged.height - cluster.width * cluster.height;
            if (cost < best_cost) {
                best_cost = cost;
                best_index = index;
            }
        }
        self.rects[best_index] = geometry.RectF.unionWith(self.rects[best_index], normalized);
    }
};

fn canvasPacketPatchDirtyBounds(view: anytype, current: []const CanvasPacketCurrentCommand) ?CanvasPacketPatchDirty {
    const baseline_count = view.canvas_packet_baseline_count;
    const baseline_keys = view.canvas_packet_baseline_keys[0..baseline_count];
    const baseline_fingerprints = view.canvas_packet_baseline_fingerprints[0..baseline_count];
    const baseline_bounds = view.canvas_packet_baseline_bounds[0..baseline_count];

    const scratch = canvas_frame_scratch.get();
    const baseline_sorted = scratch.packet_baseline_sort[0..baseline_count];
    for (baseline_sorted, 0..) |*slot, index| slot.* = @intCast(index);
    std.sort.pdq(u32, baseline_sorted, @as([]const u64, baseline_keys), canvasPacketBaselineKeyLessThan);
    const matched = scratch.packet_baseline_matched[0..baseline_count];
    const stable = scratch.packet_baseline_stable[0..baseline_count];
    @memset(matched, false);
    @memset(stable, false);

    var dirty = CanvasPacketPatchDirty{};
    for (current, 0..) |entry, index| {
        scratch.packet_upsert[index] = true;
        if (findCanvasPacketBaselineIndex(baseline_keys, baseline_sorted, entry.key)) |baseline_index| {
            matched[baseline_index] = true;
            if (baseline_fingerprints[baseline_index] == entry.fingerprint) {
                stable[baseline_index] = true;
                scratch.packet_upsert[index] = false;
                continue;
            }
            dirty.add(baseline_bounds[baseline_index]);
        }
        dirty.add(entry.bounds);
    }
    for (matched, 0..) |flag, index| {
        if (!flag) dirty.add(baseline_bounds[index]);
    }

    // Order guard: the unchanged (stable) keys must appear in the same
    // relative draw order on both sides, or overlap-dependent pixels
    // outside the union may change.
    var baseline_walk: usize = 0;
    for (current, 0..) |entry, index| {
        if (scratch.packet_upsert[index]) continue;
        while (baseline_walk < baseline_count and !stable[baseline_walk]) baseline_walk += 1;
        if (baseline_walk >= baseline_count or baseline_keys[baseline_walk] != entry.key) return null;
        baseline_walk += 1;
    }

    return dirty;
}

/// Encode the incremental `patch` present: evicts (baseline keys gone
/// from the current list), keyed upserts (new or fingerprint-changed
/// commands, re-encoded), and the full draw-order vector. Unchanged
/// commands are never re-encoded — for text runs that skips
/// `layoutTextRun` entirely, which is most of what a transcript frame
/// used to pay. Reads the scratch flags `computeCanvasPacketPatchStats`
/// filled for the same `current` list. Errors are overflow of the
/// caller's transport buffer.
fn writeCanvasPacketPatchBinary(
    view: anytype,
    canvas_frame: canvas.CanvasFrame,
    packet: canvas.CanvasGpuPacket,
    current: []const CanvasPacketCurrentCommand,
    stats: CanvasPacketPatchStats,
    writer: *std.Io.Writer,
) !void {
    const baseline_count = view.canvas_packet_baseline_count;
    const baseline_keys = view.canvas_packet_baseline_keys[0..baseline_count];
    const scratch = canvas_frame_scratch.get();
    const matched = scratch.packet_baseline_matched[0..baseline_count];
    const upserts = scratch.packet_upsert[0..current.len];

    try canvas.writeCanvasGpuPacketBinaryHeader(
        canvas.binary_packet_load_action_patch,
        view.canvas_packet_generation,
        packet.scissor,
        canvas_frame.dirtyRects(),
        packet.images,
        packet.image_actions,
        writer,
    );
    try writer.writeInt(u32, @intCast(stats.evict_count), .little);
    for (matched, 0..) |flag, index| {
        if (!flag) try writer.writeInt(u64, baseline_keys[index], .little);
    }
    try writer.writeInt(u32, @intCast(stats.upsert_count), .little);
    const render_commands = canvas_frame.render_plan.commands;
    for (current, 0..) |entry, index| {
        if (!upserts[index]) continue;
        const command = canvas.canvasGpuCommandFromRenderCommand(render_commands[entry.render_index], entry.render_index);
        try canvas.writeCanvasGpuCommandBinaryKeyed(entry.key, command, writer);
    }
    try writer.writeInt(u32, @intCast(current.len), .little);
    for (current) |entry| try writer.writeInt(u64, entry.key, .little);
}

/// Encode the FULL keyed present that (re)builds the host's retained
/// command dictionary: a `clear` over the full-repaint bounds carrying
/// the whole keyed command list under `generation`. Byte-identical
/// content whether it is a first baseline or a resync, which is what the
/// golden patch-vs-full equivalence test compares against.
fn writeCanvasPacketFullBinary(
    canvas_frame: canvas.CanvasFrame,
    packet: canvas.CanvasGpuPacket,
    current: []const CanvasPacketCurrentCommand,
    generation: u64,
    writer: *std.Io.Writer,
) !void {
    const scissor = canvasFullRepaintBounds(canvas_frame.surface_size, canvas_frame.render_plan.bounds);
    // Load-action wire code 2 = clear (see serialization.zig's layout).
    try canvas.writeCanvasGpuPacketBinaryHeader(2, generation, scissor, &.{}, packet.images, packet.image_actions, writer);
    try writer.writeInt(u32, @intCast(current.len), .little);
    const render_commands = canvas_frame.render_plan.commands;
    for (current) |entry| {
        const command = canvas.canvasGpuCommandFromRenderCommand(render_commands[entry.render_index], entry.render_index);
        try canvas.writeCanvasGpuCommandBinaryKeyed(entry.key, command, writer);
    }
}

/// Byte size the overflowing full keyed encode actually needed, measured
/// with a discarding writer — overflow-path diagnostics only.
fn canvasPacketFullBinaryByteSize(
    canvas_frame: canvas.CanvasFrame,
    packet: canvas.CanvasGpuPacket,
    current: []const CanvasPacketCurrentCommand,
    generation: u64,
) usize {
    var trailing: [128]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&trailing);
    writeCanvasPacketFullBinary(canvas_frame, packet, current, generation, &discarding.writer) catch return 0;
    return @intCast(discarding.fullCount());
}

/// A successful retained present (full or patch) makes `current` the
/// view's baseline: the engine-side mirror of what the host now retains.
fn adoptCanvasPacketBaseline(view: anytype, current: []const CanvasPacketCurrentCommand, packet: canvas.CanvasGpuPacket) void {
    adoptCanvasBaselineEntries(view, current, packet.surface_size, packet.scale);
    view.canvas_packet_baseline_pixels = false;
}

/// The pixel-present twin of `adoptCanvasPacketBaseline`
/// (`Options.pixel_present_retained_baseline` hosts): the mirror now
/// describes what the presented PIXEL buffer shows. Marked so the packet
/// patch gate refuses it — only the frame planner's dirty-bounds
/// refinement may consume a pixel-adopted baseline.
fn adoptCanvasPixelPresentBaseline(view: anytype, current: []const CanvasPacketCurrentCommand, surface_size: geometry.SizeF, scale: f32) void {
    adoptCanvasBaselineEntries(view, current, surface_size, scale);
    view.canvas_packet_baseline_pixels = true;
}

fn adoptCanvasBaselineEntries(view: anytype, current: []const CanvasPacketCurrentCommand, surface_size: geometry.SizeF, scale: f32) void {
    for (current, 0..) |entry, index| {
        view.canvas_packet_baseline_keys[index] = entry.key;
        view.canvas_packet_baseline_fingerprints[index] = entry.fingerprint;
        view.canvas_packet_baseline_bounds[index] = entry.bounds;
    }
    view.canvas_packet_baseline_count = current.len;
    view.canvas_packet_baseline_surface_size = surface_size;
    view.canvas_packet_baseline_scale = scale;
    view.canvas_packet_baseline_valid = true;
}

/// Telemetry for packet presents that moved the whole frame (non-retained
/// binary and JSON): mode `full`, no patch bytes.
fn recordCanvasPacketFullPresent(view: anytype) void {
    view.gpu_present_packet_mode = .full;
    view.gpu_present_patch_bytes = 0;
    view.gpu_present_patch_upsert_count = 0;
    view.gpu_present_patch_evict_count = 0;
}

/// Emit the rate-limited fallback diagnostic on the first fallback, on
/// every reason change, and every this-many fallback frames while the
/// reason holds — loud enough to notice a steady oscillation in a debug
/// build, quiet enough that a 60 fps fallback loop cannot flood stderr
/// (one line every ~2 s).
const canvas_packet_fallback_log_interval_frames: usize = 120;

const CanvasPacketEncoding = enum { json, binary };

/// Full encoded size of `packet` in the given encoding, measured with a
/// discarding writer — used only on the overflow path to report how many
/// bytes the frame actually needed against the transport limit.
fn canvasPacketEncodedByteSize(packet: canvas.CanvasGpuPacket, encoding: CanvasPacketEncoding) usize {
    var trailing: [128]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&trailing);
    switch (encoding) {
        .json => packet.writeJson(&discarding.writer) catch return 0,
        .binary => packet.writeBinary(&discarding.writer) catch return 0,
    }
    return @intCast(discarding.fullCount());
}

/// Name of the first display-list command the packet planner could not
/// represent — the plan keeps the source command at `command_index`, so
/// the diagnostic names the author-facing kind (`draw_text`, ...), not
/// the packet's opaque `unsupported` tag.
fn firstUnsupportedCommandName(canvas_frame: canvas.CanvasFrame, packet: canvas.CanvasGpuPacket) []const u8 {
    for (packet.commands) |command| {
        if (command.supported()) continue;
        const render_commands = canvas_frame.render_plan.commands;
        if (command.command_index < render_commands.len) {
            return @tagName(render_commands[command.command_index].command);
        }
        return @tagName(command.kind);
    }
    return "";
}

/// Record WHY a packet attempt failed on the view (reason, overflow byte
/// math, offending command kind, and a running fallback-frame counter
/// that never resets while the view is open), then emit the rate-limited
/// debug diagnostic. Every packet-attempt failure funnels through here so
/// no fallback is ever silent again: automation snapshots surface the
/// fields as `present_fallback=...` on the view line.
fn recordCanvasPacketFallback(self: anytype, window_id: platform.WindowId, label: []const u8, refusal: CanvasPacketRefusal) void {
    const index = runtimeFindViewIndex(self, window_id, label) orelse return;
    const view = &self.views[index];
    const reason_changed = view.gpu_present_fallback_reason != refusal.reason;
    view.gpu_present_fallback_reason = refusal.reason;
    view.gpu_present_fallback_needed_bytes = refusal.needed_bytes;
    view.gpu_present_fallback_limit_bytes = refusal.limit_bytes;
    const kind_len = @min(refusal.command_kind.len, view.gpu_present_fallback_command_kind_storage.len);
    @memcpy(view.gpu_present_fallback_command_kind_storage[0..kind_len], refusal.command_kind[0..kind_len]);
    view.gpu_present_fallback_command_kind_len = kind_len;
    view.gpu_present_fallback_frame_count += 1;

    const should_log = view.gpu_present_fallback_frame_count == 1 or
        reason_changed or
        view.gpu_present_fallback_frame_count - view.gpu_present_fallback_logged_count >= canvas_packet_fallback_log_interval_frames;
    if (!should_log) return;
    view.gpu_present_fallback_logged_count = view.gpu_present_fallback_frame_count;
    canvas_frame_log.debug(
        "gpu packet present fell back to the CPU pixel path for view \"{s}\": reason={s} needed={d}B limit={d}B command={s} fallback_frames={d} - the pixel path rasterizes text and shapes differently, so a steady fallback reads as flickering glyphs; snapshots carry the same fields as present_fallback= on the view line",
        .{
            label,
            @tagName(refusal.reason),
            refusal.needed_bytes,
            refusal.limit_bytes,
            refusal.command_kind,
            view.gpu_present_fallback_frame_count,
        },
    );
}

/// A successful packet present clears the sticky reason and details; the
/// cumulative fallback-frame counter deliberately survives, so snapshots
/// taken on a healthy frame still expose that the view has been
/// oscillating.
fn clearCanvasPacketFallback(view: anytype) void {
    view.gpu_present_fallback_reason = .none;
    view.gpu_present_fallback_needed_bytes = 0;
    view.gpu_present_fallback_limit_bytes = 0;
    view.gpu_present_fallback_command_kind_len = 0;
}

fn validateCanvasRenderAnimations(animations: []const canvas.CanvasRenderAnimation) !void {
    if (animations.len > max_canvas_render_animations_per_view) return error.RenderAnimationListFull;
    for (animations) |animation| {
        if (animation.id == 0) return error.InvalidViewOptions;
    }
}

fn validateRuntimeViewParent(self: anytype, window_id: platform.WindowId) !void {
    const index = runtimeFindWindowIndexById(self, window_id) orelse return error.WindowNotFound;
    if (!self.windows[index].info.open) return error.WindowNotFound;
}

fn runtimeFindWindowIndexById(self: anytype, id: platform.WindowId) ?usize {
    for (self.windows[0..self.window_count], 0..) |window, index| {
        if (window.info.id == id) return index;
    }
    return null;
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |*view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}

fn canvasDirtyRegionForView(view_frame: geometry.RectF, local_dirty: geometry.RectF) ?geometry.RectF {
    const normalized_view = view_frame.normalized();
    const surface_bounds = geometry.RectF.init(0, 0, normalized_view.width, normalized_view.height);
    const clipped = geometry.RectF.intersection(surface_bounds, local_dirty.normalized());
    if (clipped.isEmpty()) return null;
    return clipped.translate(.{ .dx = normalized_view.x, .dy = normalized_view.y });
}

/// The view-local dirty bounds replacing the animation set can touch NOW:
/// every command a previously APPLIED override moved (it may snap back)
/// plus every command a new animation targets, each widened by the
/// animation's from/to transforms (and the circumscribed square of a
/// rotation about its center). Null when no targeted command exists in
/// the current display list — the caller stays loud with the full view.
fn canvasRenderAnimationScheduleDirtyBounds(view: anytype, animations: []const canvas.CanvasRenderAnimation) ?geometry.RectF {
    const display_list = view.canvasDisplayList();
    var bounds: ?geometry.RectF = null;
    var found_any = false;

    for (view.canvas_frame_render_overrides[0..view.canvas_frame_render_override_count]) |override| {
        const rect = canvasCommandBoundsById(display_list, override.id) orelse continue;
        found_any = true;
        bounds = unionRects(bounds, rect);
        if (override.transform) |transform| bounds = unionRects(bounds, transform.transformRect(rect));
    }

    for (animations) |animation| {
        const rect = canvasCommandBoundsById(display_list, animation.id) orelse continue;
        found_any = true;
        bounds = unionRects(bounds, rect);
        if (animation.from_transform) |transform| bounds = unionRects(bounds, transform.transformRect(rect));
        if (animation.to_transform) |transform| bounds = unionRects(bounds, transform.transformRect(rect));
        if (animation.from_rotation != null or animation.to_rotation != null) {
            bounds = unionRects(bounds, canvasRotationCircumscribedBounds(rect, animation.rotation_center));
        }
    }

    if (!found_any) return null;
    return bounds;
}

fn canvasCommandBoundsById(display_list: canvas.DisplayList, id: canvas.ObjectId) ?geometry.RectF {
    if (id == 0) return null;
    const command_ref = display_list.findCommandById(id) orelse return null;
    return command_ref.command.bounds();
}

/// Every pose of `rect` rotating about `center` stays inside the square
/// circumscribing the farthest corner — the conservative dirty extent of
/// a rotation animation.
fn canvasRotationCircumscribedBounds(rect: geometry.RectF, center: geometry.PointF) geometry.RectF {
    const normalized = rect.normalized();
    const corners = [_]geometry.PointF{
        normalized.topLeft(),
        normalized.topRight(),
        normalized.bottomLeft(),
        normalized.bottomRight(),
    };
    var radius: f32 = 0;
    for (corners) |corner| {
        const dx = corner.x - center.x;
        const dy = corner.y - center.y;
        radius = @max(radius, @sqrt(dx * dx + dy * dy));
    }
    return geometry.RectF.init(center.x - radius, center.y - radius, radius * 2, radius * 2);
}
