const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const platform = @import("../platform/root.zig");

const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
const max_canvas_gradient_stops_per_view = canvas_limits.max_canvas_gradient_stops_per_view;
const max_canvas_path_elements_per_view = canvas_limits.max_canvas_path_elements_per_view;
const max_canvas_glyphs_per_view = canvas_limits.max_canvas_glyphs_per_view;
const max_canvas_text_bytes_per_view = canvas_limits.max_canvas_text_bytes_per_view;

const appendCanvasSummaryChange = canvas_frame_helpers.appendCanvasSummaryChange;
const unionRects = canvas_frame_helpers.unionRects;
const findCanvasRenderOverrideIndex = canvas_frame_helpers.findCanvasRenderOverrideIndex;
const canvasRenderOverrideNoop = canvas_frame_helpers.canvasRenderOverrideNoop;
const canvasRenderAnimationFinalOverrideNoop = canvas_frame_helpers.canvasRenderAnimationFinalOverrideNoop;
const canvasRenderAnimationActive = canvas_frame_helpers.canvasRenderAnimationActive;
const platformCanvasFrameProfileRisk = canvas_frame_helpers.platformCanvasFrameProfileRisk;

pub const CanvasWidgetDisplayListChrome = struct {
    prefix_command_count: usize = 0,
    suffix_command_count: usize = 0,
    reserved_command_count: usize = 0,
};

pub const CanvasRenderAnimationDirtyBounds = struct {
    id: canvas.ObjectId,
    bounds: ?geometry.RectF,
};

pub const CanvasResourceCounts = struct {
    command_count: usize = 0,
    gradient_stop_count: usize = 0,
    path_element_count: usize = 0,
    glyph_count: usize = 0,
    text_byte_count: usize = 0,

    pub fn fromDisplayList(display_list: canvas.DisplayList) anyerror!CanvasResourceCounts {
        var counts: CanvasResourceCounts = .{};
        try addCanvasCount(&counts.command_count, display_list.commands.len, max_canvas_commands_per_view, error.CanvasCommandLimitReached);
        for (display_list.commands) |command| try counts.addCommand(command);
        return counts;
    }

    pub fn addCommand(self: *CanvasResourceCounts, command: canvas.CanvasCommand) anyerror!void {
        switch (command) {
            .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform, .draw_image, .blur => {},
            .fill_rect => |value| try self.addFill(value.fill),
            .stroke_rect => |value| try self.addStroke(value.stroke),
            .fill_rounded_rect => |value| try self.addFill(value.fill),
            .draw_line => |value| try self.addStroke(value.stroke),
            .fill_path => |value| {
                try addCanvasCount(&self.path_element_count, value.elements.len, max_canvas_path_elements_per_view, error.CanvasPathElementLimitReached);
                try self.addFill(value.fill);
            },
            .stroke_path => |value| {
                try addCanvasCount(&self.path_element_count, value.elements.len, max_canvas_path_elements_per_view, error.CanvasPathElementLimitReached);
                try self.addStroke(value.stroke);
            },
            .draw_text => |value| {
                try addCanvasCount(&self.text_byte_count, value.text.len, max_canvas_text_bytes_per_view, error.CanvasTextTooLarge);
                try addCanvasCount(&self.glyph_count, value.glyphs.len, max_canvas_glyphs_per_view, error.CanvasGlyphLimitReached);
            },
            .shadow => |value| {
                _ = value;
            },
        }
    }

    pub fn addStroke(self: *CanvasResourceCounts, stroke: canvas.Stroke) anyerror!void {
        try self.addFill(stroke.fill);
    }

    pub fn addFill(self: *CanvasResourceCounts, fill: canvas.Fill) anyerror!void {
        switch (fill) {
            .color => {},
            .linear_gradient => |gradient| try addCanvasCount(&self.gradient_stop_count, gradient.stops.len, max_canvas_gradient_stops_per_view, error.CanvasGradientStopLimitReached),
        }
    }
};

pub const CanvasDisplayListScratch = struct {
    gradient_stops: [max_canvas_gradient_stops_per_view]canvas.GradientStop = undefined,
    gradient_stop_count: usize = 0,
    path_elements: [max_canvas_path_elements_per_view]canvas.PathElement = undefined,
    path_element_count: usize = 0,
    glyphs: [max_canvas_glyphs_per_view]canvas.Glyph = undefined,
    glyph_count: usize = 0,
    text_bytes: [max_canvas_text_bytes_per_view]u8 = undefined,
    text_len: usize = 0,

    pub fn appendCopiedCommand(self: *CanvasDisplayListScratch, builder: *canvas.Builder, command: canvas.CanvasCommand) anyerror!void {
        try builder.append(try self.copyCanvasCommand(command));
    }

    pub fn copyCanvasCommand(self: *CanvasDisplayListScratch, command: canvas.CanvasCommand) anyerror!canvas.CanvasCommand {
        return switch (command) {
            .push_clip => |value| .{ .push_clip = value },
            .pop_clip => .pop_clip,
            .push_opacity => |value| .{ .push_opacity = value },
            .pop_opacity => .pop_opacity,
            .transform => |value| .{ .transform = value },
            .fill_rect => |value| blk: {
                var copy = value;
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_rect = copy };
            },
            .stroke_rect => |value| blk: {
                var copy = value;
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .stroke_rect = copy };
            },
            .fill_rounded_rect => |value| blk: {
                var copy = value;
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_rounded_rect = copy };
            },
            .draw_line => |value| blk: {
                var copy = value;
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .draw_line = copy };
            },
            .fill_path => |value| blk: {
                var copy = value;
                copy.elements = try self.copyCanvasPathElements(value.elements);
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_path = copy };
            },
            .stroke_path => |value| blk: {
                var copy = value;
                copy.elements = try self.copyCanvasPathElements(value.elements);
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .stroke_path = copy };
            },
            .draw_image => |value| .{ .draw_image = value },
            .draw_text => |value| blk: {
                var copy = value;
                copy.text = try self.copyCanvasText(value.text);
                copy.glyphs = try self.copyCanvasGlyphs(value.glyphs);
                break :blk .{ .draw_text = copy };
            },
            .shadow => |value| .{ .shadow = value },
            .blur => |value| .{ .blur = value },
        };
    }

    pub fn copyCanvasStroke(self: *CanvasDisplayListScratch, stroke: canvas.Stroke) anyerror!canvas.Stroke {
        var copy = stroke;
        copy.fill = try self.copyCanvasFill(stroke.fill);
        return copy;
    }

    pub fn copyCanvasFill(self: *CanvasDisplayListScratch, fill: canvas.Fill) anyerror!canvas.Fill {
        return switch (fill) {
            .color => |color| .{ .color = color },
            .linear_gradient => |gradient| .{ .linear_gradient = .{
                .start = gradient.start,
                .end = gradient.end,
                .stops = try self.copyCanvasGradientStops(gradient.stops),
            } },
        };
    }

    pub fn copyCanvasGradientStops(self: *CanvasDisplayListScratch, stops: []const canvas.GradientStop) anyerror![]const canvas.GradientStop {
        const end = self.gradient_stop_count + stops.len;
        if (end > self.gradient_stops.len) return error.CanvasGradientStopLimitReached;
        const start = self.gradient_stop_count;
        @memcpy(self.gradient_stops[start..end], stops);
        self.gradient_stop_count = end;
        return self.gradient_stops[start..end];
    }

    pub fn copyCanvasPathElements(self: *CanvasDisplayListScratch, elements: []const canvas.PathElement) anyerror![]const canvas.PathElement {
        const end = self.path_element_count + elements.len;
        if (end > self.path_elements.len) return error.CanvasPathElementLimitReached;
        const start = self.path_element_count;
        @memcpy(self.path_elements[start..end], elements);
        self.path_element_count = end;
        return self.path_elements[start..end];
    }

    pub fn copyCanvasGlyphs(self: *CanvasDisplayListScratch, glyphs: []const canvas.Glyph) anyerror![]const canvas.Glyph {
        const end = self.glyph_count + glyphs.len;
        if (end > self.glyphs.len) return error.CanvasGlyphLimitReached;
        const start = self.glyph_count;
        @memcpy(self.glyphs[start..end], glyphs);
        self.glyph_count = end;
        return self.glyphs[start..end];
    }

    pub fn copyCanvasText(self: *CanvasDisplayListScratch, text: []const u8) anyerror![]const u8 {
        const end = self.text_len + text.len;
        if (end > self.text_bytes.len) return error.CanvasTextTooLarge;
        const start = self.text_len;
        @memcpy(self.text_bytes[start..end], text);
        self.text_len = end;
        return self.text_bytes[start..end];
    }
};

fn addCanvasCount(value: *usize, amount: usize, max_value: usize, comptime failure: anyerror) anyerror!void {
    if (amount > max_value or value.* > max_value - amount) return failure;
    value.* += amount;
}

/// Probe-table scratch for the presented-summary diff (see canvas
/// plan_key_index.zig): sized for the per-view command budget (2048) at
/// the half-full bound; small lists keep the linear scans.
const summary_id_index_slots = 4096;
const SummaryIdIndex = canvas.plan_key_index.HashSlots(summary_id_index_slots);
threadlocal var summary_current_id_index: SummaryIdIndex = .{};
threadlocal var summary_presented_id_index: SummaryIdIndex = .{};

pub const PresentedCanvasCommand = struct {
    id: ?canvas.ObjectId = null,
    bounds: ?geometry.RectF = null,
};

pub fn RuntimeViewCanvasFrame(comptime RuntimeView: type) type {
    return struct {
        pub fn canvasDisplayList(self: *const RuntimeView) canvas.DisplayList {
            return .{ .commands = self.canvas_commands[0..self.canvas_command_count] };
        }

        pub fn validateCanvasWidgetDisplayListChrome(self: *const RuntimeView, chrome: CanvasWidgetDisplayListChrome) anyerror!void {
            if (chrome.prefix_command_count > self.canvas_command_count) return error.InvalidCommand;
            if (chrome.suffix_command_count > self.canvas_command_count - chrome.prefix_command_count) return error.InvalidCommand;
            if (chrome.reserved_command_count > max_canvas_commands_per_view) return error.CanvasCommandLimitReached;
        }

        pub fn canvasFrameResourceCache(self: *const RuntimeView) []const canvas.RenderResourceCacheEntry {
            return self.canvas_frame_resource_cache[0..self.canvas_frame_resource_cache_count];
        }

        pub fn canvasFramePathGeometryCache(self: *const RuntimeView) []const canvas.RenderPathGeometryCacheEntry {
            return self.canvas_frame_path_geometry_cache[0..self.canvas_frame_path_geometry_cache_count];
        }

        pub fn canvasFrameImageCache(self: *const RuntimeView) []const canvas.RenderImageCacheEntry {
            return self.canvas_frame_image_cache[0..self.canvas_frame_image_cache_count];
        }

        pub fn canvasFrameLayerCache(self: *const RuntimeView) []const canvas.RenderLayerCacheEntry {
            return self.canvas_frame_layer_cache[0..self.canvas_frame_layer_cache_count];
        }

        pub fn canvasFrameVisualEffectCache(self: *const RuntimeView) []const canvas.VisualEffectCacheEntry {
            return self.canvas_frame_visual_effect_cache[0..self.canvas_frame_visual_effect_cache_count];
        }

        pub fn canvasRenderAnimations(self: *const RuntimeView) []const canvas.CanvasRenderAnimation {
            return self.canvas_render_animations[0..self.canvas_render_animation_count];
        }

        pub fn canvasFrameRenderOverrides(self: *const RuntimeView) []const canvas.CanvasRenderOverride {
            return self.canvas_frame_render_overrides[0..self.canvas_frame_render_override_count];
        }

        pub fn canvasFramePipelineCache(self: *const RuntimeView) []const canvas.RenderPipelineCacheEntry {
            return self.canvas_frame_pipeline_cache[0..self.canvas_frame_pipeline_cache_count];
        }

        pub fn canvasFrameGlyphAtlasCache(self: *const RuntimeView) []const canvas.GlyphAtlasCacheEntry {
            return self.canvas_frame_glyph_atlas_cache[0..self.canvas_frame_glyph_atlas_cache_count];
        }

        pub fn canvasFrameTextLayoutCache(self: *const RuntimeView) []const canvas.TextLayoutCacheEntry {
            return self.canvas_frame_text_layout_cache[0..self.canvas_frame_text_layout_cache_count];
        }

        pub fn copyCanvasDisplayList(self: *RuntimeView, display_list: canvas.DisplayList) anyerror!void {
            _ = try CanvasResourceCounts.fromDisplayList(display_list);
            if (display_list.commands.len > 0 and display_list.commands.ptr == self.canvas_commands[0..].ptr) {
                self.canvas_revision += 1;
                return;
            }

            self.canvas_command_count = 0;
            self.canvas_gradient_stop_count = 0;
            self.canvas_path_element_count = 0;
            self.canvas_glyph_count = 0;
            self.canvas_text_len = 0;

            for (display_list.commands) |command| {
                self.canvas_commands[self.canvas_command_count] = try self.copyCanvasCommand(command);
                self.canvas_command_count += 1;
            }
            self.canvas_revision += 1;
        }

        pub fn copyCanvasFrameResourceCache(self: *RuntimeView, entries: []const canvas.RenderResourceCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_resource_cache.len) return error.RenderResourceListFull;
            @memcpy(self.canvas_frame_resource_cache[0..entries.len], entries);
            self.canvas_frame_resource_cache_count = entries.len;
        }

        pub fn copyCanvasFramePathGeometryCache(self: *RuntimeView, entries: []const canvas.RenderPathGeometryCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_path_geometry_cache.len) return error.PathGeometryListFull;
            @memcpy(self.canvas_frame_path_geometry_cache[0..entries.len], entries);
            self.canvas_frame_path_geometry_cache_count = entries.len;
        }

        pub fn copyCanvasFrameImageCache(self: *RuntimeView, entries: []const canvas.RenderImageCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_image_cache.len) return error.ImageListFull;
            @memcpy(self.canvas_frame_image_cache[0..entries.len], entries);
            self.canvas_frame_image_cache_count = entries.len;
        }

        pub fn copyCanvasFrameLayerCache(self: *RuntimeView, entries: []const canvas.RenderLayerCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_layer_cache.len) return error.LayerListFull;
            @memcpy(self.canvas_frame_layer_cache[0..entries.len], entries);
            self.canvas_frame_layer_cache_count = entries.len;
        }

        pub fn copyCanvasFrameVisualEffectCache(self: *RuntimeView, entries: []const canvas.VisualEffectCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_visual_effect_cache.len) return error.VisualEffectListFull;
            @memcpy(self.canvas_frame_visual_effect_cache[0..entries.len], entries);
            self.canvas_frame_visual_effect_cache_count = entries.len;
        }

        pub fn copyCanvasRenderAnimations(self: *RuntimeView, animations: []const canvas.CanvasRenderAnimation) anyerror!void {
            if (animations.len > self.canvas_render_animations.len) return error.RenderAnimationListFull;
            @memcpy(self.canvas_render_animations[0..animations.len], animations);
            self.canvas_render_animation_count = animations.len;
            self.canvas_render_animation_dirty_bounds_count = 0;
        }

        pub fn replaceCanvasRenderAnimation(self: *RuntimeView, animation: canvas.CanvasRenderAnimation) anyerror!void {
            if (animation.id == 0) return error.InvalidViewOptions;
            var index: usize = 0;
            while (index < self.canvas_render_animation_count) : (index += 1) {
                if (self.canvas_render_animations[index].id == animation.id) {
                    self.canvas_render_animations[index] = animation;
                    return;
                }
            }
            if (self.canvas_render_animation_count >= self.canvas_render_animations.len) return error.RenderAnimationListFull;
            self.canvas_render_animations[self.canvas_render_animation_count] = animation;
            self.canvas_render_animation_count += 1;
        }

        pub fn removeCanvasRenderAnimation(self: *RuntimeView, id: canvas.ObjectId) void {
            var len: usize = 0;
            for (self.canvasRenderAnimations()) |animation| {
                if (animation.id == id) continue;
                self.canvas_render_animations[len] = animation;
                len += 1;
            }
            self.canvas_render_animation_count = len;
            self.removeCanvasRenderAnimationDirtyBounds(id);
        }

        pub fn replaceCanvasRenderAnimationDirtyBounds(self: *RuntimeView, id: canvas.ObjectId, bounds: ?geometry.RectF) anyerror!void {
            if (id == 0) return error.InvalidViewOptions;
            if (bounds == null) {
                self.removeCanvasRenderAnimationDirtyBounds(id);
                return;
            }
            for (self.canvas_render_animation_dirty_bounds[0..self.canvas_render_animation_dirty_bounds_count]) |*entry| {
                if (entry.id == id) {
                    entry.bounds = bounds;
                    return;
                }
            }
            if (self.canvas_render_animation_dirty_bounds_count >= self.canvas_render_animation_dirty_bounds.len) return error.RenderAnimationListFull;
            self.canvas_render_animation_dirty_bounds[self.canvas_render_animation_dirty_bounds_count] = .{
                .id = id,
                .bounds = bounds,
            };
            self.canvas_render_animation_dirty_bounds_count += 1;
        }

        pub fn removeCanvasRenderAnimationDirtyBounds(self: *RuntimeView, id: canvas.ObjectId) void {
            var len: usize = 0;
            for (self.canvas_render_animation_dirty_bounds[0..self.canvas_render_animation_dirty_bounds_count]) |entry| {
                if (entry.id == id) continue;
                self.canvas_render_animation_dirty_bounds[len] = entry;
                len += 1;
            }
            self.canvas_render_animation_dirty_bounds_count = len;
        }

        pub fn canvasRenderAnimationDirtyBoundsForOverrides(
            self: *const RuntimeView,
            previous: []const canvas.CanvasRenderOverride,
            next: []const canvas.CanvasRenderOverride,
        ) ?geometry.RectF {
            var bounds: ?geometry.RectF = null;
            for (self.canvas_render_animation_dirty_bounds[0..self.canvas_render_animation_dirty_bounds_count]) |entry| {
                if (findCanvasRenderOverrideIndex(previous, entry.id) == null and findCanvasRenderOverrideIndex(next, entry.id) == null) continue;
                bounds = unionRects(bounds, entry.bounds);
            }
            return bounds;
        }

        pub fn copyCanvasFrameRenderOverrides(self: *RuntimeView, overrides: []const canvas.CanvasRenderOverride) anyerror!void {
            if (overrides.len > self.canvas_frame_render_overrides.len) return error.RenderOverrideListFull;
            @memcpy(self.canvas_frame_render_overrides[0..overrides.len], overrides);
            self.canvas_frame_render_override_count = overrides.len;
        }

        pub fn compactCanvasFrameRenderOverrideNoops(self: *RuntimeView) void {
            var len: usize = 0;
            for (self.canvasFrameRenderOverrides()) |override| {
                if (canvasRenderOverrideNoop(override)) continue;
                self.canvas_frame_render_overrides[len] = override;
                len += 1;
            }
            self.canvas_frame_render_override_count = len;
        }

        pub fn sampleCanvasRenderAnimations(self: *const RuntimeView, timestamp_ns: u64, output: []canvas.CanvasRenderOverride) anyerror![]const canvas.CanvasRenderOverride {
            return canvas.sampleCanvasRenderAnimations(self.canvasRenderAnimations(), timestamp_ns, output);
        }

        pub fn pruneCompletedNoopCanvasRenderAnimations(self: *RuntimeView, timestamp_ns: u64) bool {
            var len: usize = 0;
            var pruned = false;
            for (self.canvasRenderAnimations()) |animation| {
                if (!canvasRenderAnimationActive(animation, timestamp_ns) and canvasRenderAnimationFinalOverrideNoop(animation)) {
                    pruned = true;
                    self.removeCanvasRenderAnimationDirtyBounds(animation.id);
                    continue;
                }
                self.canvas_render_animations[len] = animation;
                len += 1;
            }
            self.canvas_render_animation_count = len;
            return pruned;
        }

        pub fn canvasRenderAnimationsActive(self: *const RuntimeView, timestamp_ns: u64) bool {
            for (self.canvasRenderAnimations()) |animation| {
                if (canvasRenderAnimationActive(animation, timestamp_ns)) return true;
            }
            return false;
        }

        pub fn copyCanvasFramePipelineCache(self: *RuntimeView, entries: []const canvas.RenderPipelineCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_pipeline_cache.len) return error.RenderPipelineCacheListFull;
            @memcpy(self.canvas_frame_pipeline_cache[0..entries.len], entries);
            self.canvas_frame_pipeline_cache_count = entries.len;
        }

        pub fn copyCanvasFrameGlyphAtlasCache(self: *RuntimeView, entries: []const canvas.GlyphAtlasCacheEntry) anyerror!void {
            if (entries.len > self.canvas_frame_glyph_atlas_cache.len) return error.GlyphAtlasListFull;
            @memcpy(self.canvas_frame_glyph_atlas_cache[0..entries.len], entries);
            self.canvas_frame_glyph_atlas_cache_count = entries.len;
        }

        pub fn copyCanvasFrameTextLayoutCache(self: *RuntimeView, entries: []const canvas.TextLayoutCacheEntry) anyerror!void {
            const count = @min(entries.len, self.canvas_frame_text_layout_cache.len);
            @memcpy(self.canvas_frame_text_layout_cache[0..count], entries[0..count]);
            self.canvas_frame_text_layout_cache_count = count;
        }

        pub fn recordCanvasFrame(self: *RuntimeView, frame: canvas.CanvasFrame) void {
            const render_pass = frame.renderPass();
            const gpu_packet_summary = frame.gpuPacketSummary();
            self.canvas_frame_requires_render = frame.requiresRender();
            self.canvas_frame_full_repaint = frame.full_repaint;
            self.canvas_frame_batch_count = frame.batch_plan.batchCount();
            self.canvas_frame_encoder_command_count = render_pass.encoderCommandCount();
            self.canvas_frame_encoder_cache_action_count = render_pass.encoderCacheActionCount();
            self.canvas_frame_encoder_bind_pipeline_count = render_pass.encoderBindPipelineCount();
            self.canvas_frame_encoder_draw_batch_count = render_pass.encoderDrawBatchCount();
            self.canvas_frame_pipeline_count = frame.pipeline_cache_plan.entryCount();
            self.canvas_frame_pipeline_upload_count = frame.pipeline_cache_plan.uploadCount();
            self.canvas_frame_pipeline_retain_count = frame.pipeline_cache_plan.retainCount();
            self.canvas_frame_pipeline_evict_count = frame.pipeline_cache_plan.evictCount();
            self.canvas_frame_path_geometry_count = frame.path_geometry_plan.geometryCount();
            self.canvas_frame_path_geometry_vertex_count = frame.path_geometry_plan.vertexCount();
            self.canvas_frame_path_geometry_index_count = frame.path_geometry_plan.indexCount();
            self.canvas_frame_path_geometry_upload_count = frame.path_geometry_cache_plan.uploadCount();
            self.canvas_frame_path_geometry_retain_count = frame.path_geometry_cache_plan.retainCount();
            self.canvas_frame_path_geometry_evict_count = frame.path_geometry_cache_plan.evictCount();
            self.canvas_frame_image_count = frame.image_plan.imageCount();
            self.canvas_frame_image_upload_count = frame.image_cache_plan.uploadCount();
            self.canvas_frame_image_retain_count = frame.image_cache_plan.retainCount();
            self.canvas_frame_image_evict_count = frame.image_cache_plan.evictCount();
            self.canvas_frame_layer_count = frame.layer_plan.layerCount();
            self.canvas_frame_layer_opacity_count = frame.layer_plan.opacityLayerCount();
            self.canvas_frame_layer_clip_count = frame.layer_plan.clipLayerCount();
            self.canvas_frame_layer_transform_count = frame.layer_plan.transformLayerCount();
            self.canvas_frame_layer_upload_count = frame.layer_cache_plan.uploadCount();
            self.canvas_frame_layer_retain_count = frame.layer_cache_plan.retainCount();
            self.canvas_frame_layer_evict_count = frame.layer_cache_plan.evictCount();
            self.canvas_frame_resource_count = frame.resource_plan.resourceCount();
            self.canvas_frame_resource_upload_count = frame.resource_cache_plan.uploadCount();
            self.canvas_frame_resource_retain_count = frame.resource_cache_plan.retainCount();
            self.canvas_frame_resource_evict_count = frame.resource_cache_plan.evictCount();
            self.canvas_frame_visual_effect_count = frame.visual_effect_plan.effectCount();
            self.canvas_frame_visual_effect_shadow_count = frame.visual_effect_plan.shadowCount();
            self.canvas_frame_visual_effect_blur_count = frame.visual_effect_plan.blurCount();
            self.canvas_frame_visual_effect_upload_count = frame.visual_effect_cache_plan.uploadCount();
            self.canvas_frame_visual_effect_retain_count = frame.visual_effect_cache_plan.retainCount();
            self.canvas_frame_visual_effect_evict_count = frame.visual_effect_cache_plan.evictCount();
            self.canvas_frame_glyph_atlas_entry_count = frame.glyph_atlas_plan.entryCount();
            self.canvas_frame_glyph_atlas_upload_count = frame.glyph_atlas_cache_plan.uploadCount();
            self.canvas_frame_glyph_atlas_retain_count = frame.glyph_atlas_cache_plan.retainCount();
            self.canvas_frame_glyph_atlas_evict_count = frame.glyph_atlas_cache_plan.evictCount();
            self.canvas_frame_text_layout_count = frame.text_layout_plan.planCount();
            self.canvas_frame_text_layout_line_count = frame.text_layout_plan.lineCount();
            self.canvas_frame_text_layout_upload_count = frame.text_layout_cache_plan.uploadCount();
            self.canvas_frame_text_layout_retain_count = frame.text_layout_cache_plan.retainCount();
            self.canvas_frame_text_layout_evict_count = frame.text_layout_cache_plan.evictCount();
            self.canvas_frame_gpu_packet_command_count = gpu_packet_summary.command_count;
            self.canvas_frame_gpu_packet_cache_action_count = gpu_packet_summary.cache_action_count;
            self.canvas_frame_gpu_packet_cached_resource_command_count = gpu_packet_summary.cached_resource_command_count;
            self.canvas_frame_gpu_packet_unsupported_command_count = gpu_packet_summary.unsupported_command_count;
            self.canvas_frame_gpu_packet_representable = gpu_packet_summary.fullyRepresentable();
            self.canvas_frame_change_count = frame.changes.len;
            self.canvas_frame_budget = frame.budget;
            self.canvas_frame_budget_status = frame.budgetStatus();
            self.canvas_frame_dirty_bounds = frame.dirty_bounds;
            const profile = frame.profile();
            self.canvas_frame_profile_work_units = profile.work_units;
            self.canvas_frame_profile_risk = platformCanvasFrameProfileRisk(profile.risk);
            self.canvas_frame_profile_surface_area = profile.surface_area;
            self.canvas_frame_profile_dirty_area = profile.dirty_area;
            self.canvas_frame_profile_dirty_ratio = profile.dirty_ratio;
        }

        pub fn recordCanvasFramePresentationComplete(self: *RuntimeView, frame: canvas.CanvasFrame) void {
            if (!self.presented_canvas_valid or self.presented_canvas_revision != self.canvas_revision) return;
            self.recordCanvasFrame(.{
                .frame_index = frame.frame_index,
                .timestamp_ns = frame.timestamp_ns,
                .surface_size = frame.surface_size,
                .scale = frame.scale,
                .display_list = self.canvasDisplayList(),
                .changes = &.{},
                .budget = frame.budget,
            });
        }

        pub fn refreshCanvasFrameBudgetStatus(self: *RuntimeView) void {
            self.canvas_frame_budget_status = self.canvas_frame_budget.status(.{
                .command_count = self.canvas_command_count,
                .batch_count = self.canvas_frame_batch_count,
                .encoder_command_count = self.canvas_frame_encoder_command_count,
                .encoder_cache_action_count = self.canvas_frame_encoder_cache_action_count,
                .encoder_bind_pipeline_count = self.canvas_frame_encoder_bind_pipeline_count,
                .encoder_draw_batch_count = self.canvas_frame_encoder_draw_batch_count,
                .pipeline_count = self.canvas_frame_pipeline_count,
                .pipeline_upload_count = self.canvas_frame_pipeline_upload_count,
                .pipeline_retain_count = self.canvas_frame_pipeline_retain_count,
                .pipeline_evict_count = self.canvas_frame_pipeline_evict_count,
                .path_geometry_count = self.canvas_frame_path_geometry_count,
                .path_geometry_vertex_count = self.canvas_frame_path_geometry_vertex_count,
                .path_geometry_index_count = self.canvas_frame_path_geometry_index_count,
                .path_geometry_upload_count = self.canvas_frame_path_geometry_upload_count,
                .path_geometry_retain_count = self.canvas_frame_path_geometry_retain_count,
                .path_geometry_evict_count = self.canvas_frame_path_geometry_evict_count,
                .image_count = self.canvas_frame_image_count,
                .image_upload_count = self.canvas_frame_image_upload_count,
                .image_retain_count = self.canvas_frame_image_retain_count,
                .image_evict_count = self.canvas_frame_image_evict_count,
                .layer_count = self.canvas_frame_layer_count,
                .layer_opacity_count = self.canvas_frame_layer_opacity_count,
                .layer_clip_count = self.canvas_frame_layer_clip_count,
                .layer_transform_count = self.canvas_frame_layer_transform_count,
                .layer_upload_count = self.canvas_frame_layer_upload_count,
                .layer_retain_count = self.canvas_frame_layer_retain_count,
                .layer_evict_count = self.canvas_frame_layer_evict_count,
                .resource_count = self.canvas_frame_resource_count,
                .resource_upload_count = self.canvas_frame_resource_upload_count,
                .resource_retain_count = self.canvas_frame_resource_retain_count,
                .resource_evict_count = self.canvas_frame_resource_evict_count,
                .visual_effect_count = self.canvas_frame_visual_effect_count,
                .visual_effect_shadow_count = self.canvas_frame_visual_effect_shadow_count,
                .visual_effect_blur_count = self.canvas_frame_visual_effect_blur_count,
                .visual_effect_upload_count = self.canvas_frame_visual_effect_upload_count,
                .visual_effect_retain_count = self.canvas_frame_visual_effect_retain_count,
                .visual_effect_evict_count = self.canvas_frame_visual_effect_evict_count,
                .glyph_atlas_entry_count = self.canvas_frame_glyph_atlas_entry_count,
                .glyph_atlas_upload_count = self.canvas_frame_glyph_atlas_upload_count,
                .glyph_atlas_retain_count = self.canvas_frame_glyph_atlas_retain_count,
                .glyph_atlas_evict_count = self.canvas_frame_glyph_atlas_evict_count,
                .text_layout_count = self.canvas_frame_text_layout_count,
                .text_layout_line_count = self.canvas_frame_text_layout_line_count,
                .text_layout_upload_count = self.canvas_frame_text_layout_upload_count,
                .text_layout_retain_count = self.canvas_frame_text_layout_retain_count,
                .text_layout_evict_count = self.canvas_frame_text_layout_evict_count,
                .change_count = self.canvas_frame_change_count,
                .full_repaint = self.canvas_frame_full_repaint,
                .requires_render = self.canvas_frame_requires_render,
                .dirty_bounds = self.canvas_frame_dirty_bounds,
            });
        }

        pub fn copyPresentedCanvasSummary(self: *RuntimeView, display_list: canvas.DisplayList, surface_size: geometry.SizeF, scale: f32) anyerror!void {
            _ = try CanvasResourceCounts.fromDisplayList(display_list);

            self.presented_canvas_valid = true;
            self.presented_canvas_surface_size = surface_size;
            self.presented_canvas_scale = scale;
            self.presented_canvas_command_count = 0;
            self.presented_canvas_has_unkeyed = false;

            for (display_list.commands) |command| {
                if (self.presented_canvas_command_count >= self.presented_canvas_commands.len) return error.CanvasCommandLimitReached;
                const id = command.objectId();
                // `bounds()` re-derives text layout for wrapped runs;
                // compute it once for both the summary and the unkeyed
                // check.
                const command_bounds = command.bounds();
                self.presented_canvas_commands[self.presented_canvas_command_count] = .{
                    .id = id,
                    .bounds = command_bounds,
                };
                if (id == null and command_bounds != null) self.presented_canvas_has_unkeyed = true;
                self.presented_canvas_command_count += 1;
            }
            self.presented_canvas_revision = self.canvas_revision;
        }

        pub fn copyPresentedCanvasSummaryFrom(self: *RuntimeView, source: *const RuntimeView) void {
            self.presented_canvas_valid = source.presented_canvas_valid;
            self.presented_canvas_command_count = source.presented_canvas_command_count;
            self.presented_canvas_revision = source.presented_canvas_revision;
            self.presented_canvas_surface_size = source.presented_canvas_surface_size;
            self.presented_canvas_scale = source.presented_canvas_scale;
            self.presented_canvas_has_unkeyed = source.presented_canvas_has_unkeyed;
            @memcpy(self.presented_canvas_commands[0..source.presented_canvas_command_count], source.presented_canvas_commands[0..source.presented_canvas_command_count]);
        }

        pub fn currentCanvasHasUnkeyed(self: *const RuntimeView) bool {
            for (self.canvasDisplayList().commands) |command| {
                if (command.objectId() == null and command.bounds() != null) return true;
            }
            return false;
        }

        pub fn diffPresentedCanvasSummary(self: *const RuntimeView, output: []canvas.DiffChange) anyerror![]const canvas.DiffChange {
            if (self.canvas_revision == self.presented_canvas_revision) return output[0..0];

            // Id lookups ride the probe-table index whenever the lists
            // are worth a table reset and fit its half-full bound;
            // otherwise the linear scans run as before. Same changes
            // either way — the indexed lookup resolves to the
            // lowest-index match exactly like the scans.
            const current_commands = self.canvasDisplayList().commands;
            const presented = self.presented_canvas_commands[0..self.presented_canvas_command_count];
            const use_index = (current_commands.len >= canvas.plan_key_index.min_entries_for_index or
                presented.len >= canvas.plan_key_index.min_entries_for_index) and
                canvas.plan_key_index.fitsHashSlots(summary_id_index_slots, current_commands.len) and
                canvas.plan_key_index.fitsHashSlots(summary_id_index_slots, presented.len);
            if (use_index) {
                summary_current_id_index.reset();
                for (current_commands, 0..) |command, index| {
                    const id = command.objectId() orelse continue;
                    var p = SummaryIdIndex.probe(canvas.plan_key_index.mixHash(id));
                    while (summary_current_id_index.next(&p)) |_| {}
                    summary_current_id_index.insert(p, @intCast(index));
                }
                summary_presented_id_index.reset();
                for (presented, 0..) |command, index| {
                    const id = command.id orelse continue;
                    var p = SummaryIdIndex.probe(canvas.plan_key_index.mixHash(id));
                    while (summary_presented_id_index.next(&p)) |_| {}
                    summary_presented_id_index.insert(p, @intCast(index));
                }
            }

            var len: usize = 0;
            for (presented) |previous| {
                const id = previous.id orelse continue;
                const current_ref = if (use_index)
                    currentCanvasCommandByIdIndexed(current_commands, id)
                else
                    self.currentCanvasCommandById(id);
                if (current_ref == null) {
                    try appendCanvasSummaryChange(output, &len, .{
                        .kind = .removed,
                        .id = id,
                        .dirty_bounds = previous.bounds,
                    });
                }
            }

            for (current_commands, 0..) |command, index| {
                const id = command.objectId() orelse continue;
                const bounds = command.bounds();
                const previous_ref = if (use_index)
                    presentedCanvasCommandByIdIndexed(presented, id)
                else
                    self.presentedCanvasCommandById(id);
                if (previous_ref) |previous| {
                    try appendCanvasSummaryChange(output, &len, .{
                        .kind = .changed,
                        .id = id,
                        .previous_index = previous.index,
                        .next_index = index,
                        .dirty_bounds = unionRects(previous.command.bounds, bounds),
                    });
                } else {
                    try appendCanvasSummaryChange(output, &len, .{
                        .kind = .added,
                        .id = id,
                        .next_index = index,
                        .dirty_bounds = bounds,
                    });
                }
            }

            return output[0..len];
        }

        fn currentCanvasCommandByIdIndexed(commands: []const canvas.CanvasCommand, id: canvas.ObjectId) ?canvas.CommandRef {
            var p = SummaryIdIndex.probe(canvas.plan_key_index.mixHash(id));
            while (summary_current_id_index.next(&p)) |candidate| {
                if (commands[candidate].objectId() == id) return .{ .index = candidate, .command = commands[candidate] };
            }
            return null;
        }

        fn presentedCanvasCommandByIdIndexed(presented: []const PresentedCanvasCommand, id: canvas.ObjectId) ?PresentedCanvasCommandRef {
            var p = SummaryIdIndex.probe(canvas.plan_key_index.mixHash(id));
            while (summary_presented_id_index.next(&p)) |candidate| {
                if (presented[candidate].id == id) return .{ .index = candidate, .command = presented[candidate] };
            }
            return null;
        }

        pub fn currentCanvasCommandById(self: *const RuntimeView, id: canvas.ObjectId) ?canvas.CommandRef {
            for (self.canvasDisplayList().commands, 0..) |command, index| {
                if (command.objectId() == id) return .{ .index = index, .command = command };
            }
            return null;
        }

        const PresentedCanvasCommandRef = struct {
            index: usize,
            command: PresentedCanvasCommand,
        };

        pub fn presentedCanvasCommandById(self: *const RuntimeView, id: canvas.ObjectId) ?PresentedCanvasCommandRef {
            for (self.presented_canvas_commands[0..self.presented_canvas_command_count], 0..) |command, index| {
                if (command.id == id) return .{ .index = index, .command = command };
            }
            return null;
        }

        pub fn copyCanvasCommand(self: *RuntimeView, command: canvas.CanvasCommand) anyerror!canvas.CanvasCommand {
            return switch (command) {
                .push_clip => |value| .{ .push_clip = value },
                .pop_clip => .pop_clip,
                .push_opacity => |value| .{ .push_opacity = value },
                .pop_opacity => .pop_opacity,
                .transform => |value| .{ .transform = value },
                .fill_rect => |value| blk: {
                    var copy = value;
                    copy.fill = try self.copyCanvasFill(value.fill);
                    break :blk .{ .fill_rect = copy };
                },
                .stroke_rect => |value| blk: {
                    var copy = value;
                    copy.stroke = try self.copyCanvasStroke(value.stroke);
                    break :blk .{ .stroke_rect = copy };
                },
                .fill_rounded_rect => |value| blk: {
                    var copy = value;
                    copy.fill = try self.copyCanvasFill(value.fill);
                    break :blk .{ .fill_rounded_rect = copy };
                },
                .draw_line => |value| blk: {
                    var copy = value;
                    copy.stroke = try self.copyCanvasStroke(value.stroke);
                    break :blk .{ .draw_line = copy };
                },
                .fill_path => |value| blk: {
                    var copy = value;
                    copy.elements = try self.copyCanvasPathElements(value.elements);
                    copy.fill = try self.copyCanvasFill(value.fill);
                    break :blk .{ .fill_path = copy };
                },
                .stroke_path => |value| blk: {
                    var copy = value;
                    copy.elements = try self.copyCanvasPathElements(value.elements);
                    copy.stroke = try self.copyCanvasStroke(value.stroke);
                    break :blk .{ .stroke_path = copy };
                },
                .draw_image => |value| .{ .draw_image = value },
                .draw_text => |value| blk: {
                    var copy = value;
                    copy.text = try self.copyCanvasText(value.text);
                    copy.glyphs = try self.copyCanvasGlyphs(value.glyphs);
                    break :blk .{ .draw_text = copy };
                },
                .shadow => |value| .{ .shadow = value },
                .blur => |value| .{ .blur = value },
            };
        }

        pub fn copyCanvasStroke(self: *RuntimeView, stroke: canvas.Stroke) anyerror!canvas.Stroke {
            var copy = stroke;
            copy.fill = try self.copyCanvasFill(stroke.fill);
            return copy;
        }

        pub fn copyCanvasFill(self: *RuntimeView, fill: canvas.Fill) anyerror!canvas.Fill {
            return switch (fill) {
                .color => |color| .{ .color = color },
                .linear_gradient => |gradient| .{ .linear_gradient = .{
                    .start = gradient.start,
                    .end = gradient.end,
                    .stops = try self.copyCanvasGradientStops(gradient.stops),
                } },
            };
        }

        pub fn copyCanvasGradientStops(self: *RuntimeView, stops: []const canvas.GradientStop) anyerror![]const canvas.GradientStop {
            const end = self.canvas_gradient_stop_count + stops.len;
            if (end > self.canvas_gradient_stops.len) return error.CanvasGradientStopLimitReached;
            const start = self.canvas_gradient_stop_count;
            @memcpy(self.canvas_gradient_stops[start..end], stops);
            self.canvas_gradient_stop_count = end;
            return self.canvas_gradient_stops[start..end];
        }

        pub fn copyCanvasPathElements(self: *RuntimeView, elements: []const canvas.PathElement) anyerror![]const canvas.PathElement {
            const end = self.canvas_path_element_count + elements.len;
            if (end > self.canvas_path_elements.len) return error.CanvasPathElementLimitReached;
            const start = self.canvas_path_element_count;
            @memcpy(self.canvas_path_elements[start..end], elements);
            self.canvas_path_element_count = end;
            return self.canvas_path_elements[start..end];
        }

        pub fn copyCanvasGlyphs(self: *RuntimeView, glyphs: []const canvas.Glyph) anyerror![]const canvas.Glyph {
            const end = self.canvas_glyph_count + glyphs.len;
            if (end > self.canvas_glyphs.len) return error.CanvasGlyphLimitReached;
            const start = self.canvas_glyph_count;
            @memcpy(self.canvas_glyphs[start..end], glyphs);
            self.canvas_glyph_count = end;
            return self.canvas_glyphs[start..end];
        }

        pub fn copyCanvasText(self: *RuntimeView, text: []const u8) anyerror![]const u8 {
            const end = self.canvas_text_len + text.len;
            if (end > self.canvas_text_bytes.len) return error.CanvasTextTooLarge;
            const start = self.canvas_text_len;
            @memcpy(self.canvas_text_bytes[start..end], text);
            self.canvas_text_len = end;
            return self.canvas_text_bytes[start..end];
        }
    };
}
