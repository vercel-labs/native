const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame_helpers.zig");
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
const validation = @import("validation.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_view = @import("view.zig");

const CanvasPresentationResult = runtime_api.CanvasPresentationResult;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const max_canvas_render_animations_per_view = canvas_limits.max_canvas_render_animations_per_view;
const max_canvas_text_layouts_per_view = canvas_limits.max_canvas_text_layouts_per_view;
threadlocal var canvas_frame_text_layout_plans_scratch: [max_canvas_text_layouts_per_view]canvas.TextLayoutPlan = undefined;
threadlocal var canvas_frame_text_layout_lines_scratch: [max_canvas_text_layouts_per_view]canvas.TextLine = undefined;
threadlocal var canvas_frame_text_layout_cache_entries_scratch: [max_canvas_text_layouts_per_view]canvas.TextLayoutCacheEntry = undefined;
threadlocal var canvas_frame_text_layout_cache_actions_scratch: [max_canvas_text_layouts_per_view * 2]canvas.TextLayoutCacheAction = undefined;

const validateViewLabel = validation.validateViewLabel;
const canvasRenderAnimationStartNsForView = runtime_view.canvasRenderAnimationStartNsForView;

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
            try self.views[index].copyCanvasRenderAnimations(animations);
            self.invalidateFor(.state, self.views[index].frame);
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
            const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
            recordCanvasClearColor(self, window_id, label, clear_color);
            var packet = try canvas_frame.gpuPacket(output);
            packet.scale = normalizedCanvasPresentationScale(packet_scale, canvas_frame.scale);
            if (!packet.requiresRender()) return packet;
            try uploadCanvasPacketImages(self, packet);
            var writer = std.Io.Writer.fixed(packet_json_buffer);
            packet.writeJson(&writer) catch return error.UnsupportedService;
            try self.options.platform.services.presentGpuSurfacePacket(.{
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
                .json = writer.buffered(),
            });
            if (runtimeFindViewIndex(self, window_id, label)) |index| {
                self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
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
            const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
            recordCanvasClearColor(self, window_id, label, clear_color);
            if (!canvas_frame.requiresRender()) {
                return .{ .frame = canvas_frame, .mode = .skipped };
            }

            if (gpu_commands.len > 0 and packet_json_buffer.len > 0 and self.options.platform.services.present_gpu_surface_packet_fn != null) {
                var packet = try canvas_frame.gpuPacket(gpu_commands);
                packet.scale = normalizedCanvasPresentationScale(pixel_scale, canvas_frame.scale);
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
                    var writer = std.Io.Writer.fixed(packet_json_buffer);
                    const packet_presented = blk: {
                        uploadCanvasPacketImages(self, packet) catch |err| switch (err) {
                            error.UnsupportedService => break :blk false,
                            else => return err,
                        };
                        packet.writeJson(&writer) catch break :blk false;
                        self.options.platform.services.presentGpuSurfacePacket(.{
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
                            .json = writer.buffered(),
                        }) catch |err| switch (err) {
                            error.UnsupportedService => break :blk false,
                            else => return err,
                        };
                        break :blk true;
                    };
                    if (packet_presented) {
                        if (runtimeFindViewIndex(self, window_id, label)) |index| {
                            self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
                        }
                        return result;
                    }
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
            surface = surface.withImages(canvas_frame.image_resources);
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
        /// with the last presented clear color. `pixels` (and optionally
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
            surface = surface.withImages(canvas_frame.image_resources);
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
            const text_layout_plan = try display_list.textLayoutPlan(frame_options.text_layout_options, storage.text_layout_plans, storage.text_layout_lines);
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
            const dirty_bounds = if (full_repaint)
                canvasFullRepaintBounds(frame_options.surface_size, render_plan.bounds)
            else
                clippedCanvasDirtyBounds(unionRects(canvasDirtyBoundsFromChanges(changes), unionRects(render_override_dirty_bounds, render_animation_dirty_bounds)), frame_options.surface_size);

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
                .changes = changes,
                .dirty_bounds = dirty_bounds,
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
            } else {
                self.views[index].recordCanvasFrame(canvas_frame);
            }
            return canvas_frame;
        }

        pub fn canvasFrameScratchStorage(self: *Runtime) canvas.CanvasFrameStorage {
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
                .text_layout_plans = &canvas_frame_text_layout_plans_scratch,
                .text_layout_lines = &canvas_frame_text_layout_lines_scratch,
                .text_layout_cache_entries = &canvas_frame_text_layout_cache_entries_scratch,
                .text_layout_cache_actions = &canvas_frame_text_layout_cache_actions_scratch,
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
