const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");

pub const CanvasFrameBudget = struct {
    max_commands: usize = 0,
    max_batches: usize = 0,
    max_encoder_commands: usize = 0,
    max_pipelines: usize = 0,
    max_pipeline_uploads: usize = 0,
    max_path_geometries: usize = 0,
    max_path_geometry_uploads: usize = 0,
    max_images: usize = 0,
    max_image_uploads: usize = 0,
    max_layers: usize = 0,
    max_layer_uploads: usize = 0,
    max_resources: usize = 0,
    max_resource_uploads: usize = 0,
    max_visual_effects: usize = 0,
    max_visual_effect_uploads: usize = 0,
    max_glyph_atlas_entries: usize = 0,
    max_glyph_atlas_uploads: usize = 0,
    max_glyph_atlas_evicts: usize = 0,
    max_text_layouts: usize = 0,
    max_text_layout_lines: usize = 0,
    max_text_layout_uploads: usize = 0,
    max_text_layout_evicts: usize = 0,
    max_changes: usize = 0,

    pub fn status(self: CanvasFrameBudget, diagnostics: CanvasFrameDiagnostics) CanvasFrameBudgetStatus {
        return .{
            .commands_over = budgetExceeded(self.max_commands, diagnostics.command_count),
            .batches_over = budgetExceeded(self.max_batches, diagnostics.batch_count),
            .encoder_commands_over = budgetExceeded(self.max_encoder_commands, diagnostics.encoder_command_count),
            .pipelines_over = budgetExceeded(self.max_pipelines, diagnostics.pipeline_count),
            .pipeline_uploads_over = budgetExceeded(self.max_pipeline_uploads, diagnostics.pipeline_upload_count),
            .path_geometries_over = budgetExceeded(self.max_path_geometries, diagnostics.path_geometry_count),
            .path_geometry_uploads_over = budgetExceeded(self.max_path_geometry_uploads, diagnostics.path_geometry_upload_count),
            .images_over = budgetExceeded(self.max_images, diagnostics.image_count),
            .image_uploads_over = budgetExceeded(self.max_image_uploads, diagnostics.image_upload_count),
            .layers_over = budgetExceeded(self.max_layers, diagnostics.layer_count),
            .layer_uploads_over = budgetExceeded(self.max_layer_uploads, diagnostics.layer_upload_count),
            .resources_over = budgetExceeded(self.max_resources, diagnostics.resource_count),
            .resource_uploads_over = budgetExceeded(self.max_resource_uploads, diagnostics.resource_upload_count),
            .visual_effects_over = budgetExceeded(self.max_visual_effects, diagnostics.visual_effect_count),
            .visual_effect_uploads_over = budgetExceeded(self.max_visual_effect_uploads, diagnostics.visual_effect_upload_count),
            .glyph_atlas_entries_over = budgetExceeded(self.max_glyph_atlas_entries, diagnostics.glyph_atlas_entry_count),
            .glyph_atlas_uploads_over = budgetExceeded(self.max_glyph_atlas_uploads, diagnostics.glyph_atlas_upload_count),
            .glyph_atlas_evicts_over = budgetExceeded(self.max_glyph_atlas_evicts, diagnostics.glyph_atlas_evict_count),
            .text_layouts_over = budgetExceeded(self.max_text_layouts, diagnostics.text_layout_count),
            .text_layout_lines_over = budgetExceeded(self.max_text_layout_lines, diagnostics.text_layout_line_count),
            .text_layout_uploads_over = budgetExceeded(self.max_text_layout_uploads, diagnostics.text_layout_upload_count),
            .text_layout_evicts_over = budgetExceeded(self.max_text_layout_evicts, diagnostics.text_layout_evict_count),
            .changes_over = budgetExceeded(self.max_changes, diagnostics.change_count),
        };
    }
};

pub const CanvasFrameBudgetStatus = struct {
    commands_over: bool = false,
    batches_over: bool = false,
    encoder_commands_over: bool = false,
    pipelines_over: bool = false,
    pipeline_uploads_over: bool = false,
    path_geometries_over: bool = false,
    path_geometry_uploads_over: bool = false,
    images_over: bool = false,
    image_uploads_over: bool = false,
    layers_over: bool = false,
    layer_uploads_over: bool = false,
    resources_over: bool = false,
    resource_uploads_over: bool = false,
    visual_effects_over: bool = false,
    visual_effect_uploads_over: bool = false,
    glyph_atlas_entries_over: bool = false,
    glyph_atlas_uploads_over: bool = false,
    glyph_atlas_evicts_over: bool = false,
    text_layouts_over: bool = false,
    text_layout_lines_over: bool = false,
    text_layout_uploads_over: bool = false,
    text_layout_evicts_over: bool = false,
    changes_over: bool = false,

    pub fn ok(self: CanvasFrameBudgetStatus) bool {
        return self.exceededCount() == 0;
    }

    pub fn exceededCount(self: CanvasFrameBudgetStatus) usize {
        var count: usize = 0;
        if (self.commands_over) count += 1;
        if (self.batches_over) count += 1;
        if (self.encoder_commands_over) count += 1;
        if (self.pipelines_over) count += 1;
        if (self.pipeline_uploads_over) count += 1;
        if (self.path_geometries_over) count += 1;
        if (self.path_geometry_uploads_over) count += 1;
        if (self.images_over) count += 1;
        if (self.image_uploads_over) count += 1;
        if (self.layers_over) count += 1;
        if (self.layer_uploads_over) count += 1;
        if (self.resources_over) count += 1;
        if (self.resource_uploads_over) count += 1;
        if (self.visual_effects_over) count += 1;
        if (self.visual_effect_uploads_over) count += 1;
        if (self.glyph_atlas_entries_over) count += 1;
        if (self.glyph_atlas_uploads_over) count += 1;
        if (self.glyph_atlas_evicts_over) count += 1;
        if (self.text_layouts_over) count += 1;
        if (self.text_layout_lines_over) count += 1;
        if (self.text_layout_uploads_over) count += 1;
        if (self.text_layout_evicts_over) count += 1;
        if (self.changes_over) count += 1;
        return count;
    }
};

pub const CanvasFrameDiagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
    batch_count: usize = 0,
    encoder_command_count: usize = 0,
    encoder_cache_action_count: usize = 0,
    encoder_bind_pipeline_count: usize = 0,
    encoder_draw_batch_count: usize = 0,
    pipeline_count: usize = 0,
    pipeline_upload_count: usize = 0,
    pipeline_retain_count: usize = 0,
    pipeline_evict_count: usize = 0,
    path_geometry_count: usize = 0,
    path_geometry_vertex_count: usize = 0,
    path_geometry_index_count: usize = 0,
    path_geometry_upload_count: usize = 0,
    path_geometry_retain_count: usize = 0,
    path_geometry_evict_count: usize = 0,
    image_count: usize = 0,
    image_upload_count: usize = 0,
    image_retain_count: usize = 0,
    image_evict_count: usize = 0,
    layer_count: usize = 0,
    layer_opacity_count: usize = 0,
    layer_clip_count: usize = 0,
    layer_transform_count: usize = 0,
    layer_upload_count: usize = 0,
    layer_retain_count: usize = 0,
    layer_evict_count: usize = 0,
    resource_count: usize = 0,
    resource_upload_count: usize = 0,
    resource_retain_count: usize = 0,
    resource_evict_count: usize = 0,
    visual_effect_count: usize = 0,
    visual_effect_shadow_count: usize = 0,
    visual_effect_blur_count: usize = 0,
    visual_effect_upload_count: usize = 0,
    visual_effect_retain_count: usize = 0,
    visual_effect_evict_count: usize = 0,
    glyph_atlas_entry_count: usize = 0,
    glyph_atlas_upload_count: usize = 0,
    glyph_atlas_retain_count: usize = 0,
    glyph_atlas_evict_count: usize = 0,
    text_layout_count: usize = 0,
    text_layout_line_count: usize = 0,
    text_layout_upload_count: usize = 0,
    text_layout_retain_count: usize = 0,
    text_layout_evict_count: usize = 0,
    gpu_packet_command_count: usize = 0,
    gpu_packet_cache_action_count: usize = 0,
    gpu_packet_cached_resource_command_count: usize = 0,
    gpu_packet_unsupported_command_count: usize = 0,
    gpu_packet_representable: bool = true,
    change_count: usize = 0,
    full_repaint: bool = false,
    requires_render: bool = false,
    dirty_bounds: ?geometry.RectF = null,
    budget: CanvasFrameBudget = .{},
    budget_status: CanvasFrameBudgetStatus = .{},

    pub fn budgetOk(self: CanvasFrameDiagnostics) bool {
        return self.budget_status.ok();
    }

    pub fn writeJson(self: CanvasFrameDiagnostics, writer: anytype) !void {
        try writer.print(
            "{{\"frameIndex\":{d},\"commandCount\":{d},\"batchCount\":{d},\"encoderCommandCount\":{d},\"encoderCacheActionCount\":{d},\"encoderBindPipelineCount\":{d},\"encoderDrawBatchCount\":{d},\"pipelineCount\":{d},\"pipelineUploadCount\":{d},\"pipelineRetainCount\":{d},\"pipelineEvictCount\":{d},\"pathGeometryCount\":{d},\"pathGeometryVertexCount\":{d},\"pathGeometryIndexCount\":{d},\"pathGeometryUploadCount\":{d},\"pathGeometryRetainCount\":{d},\"pathGeometryEvictCount\":{d},\"layerCount\":{d},\"layerOpacityCount\":{d},\"layerClipCount\":{d},\"layerTransformCount\":{d},\"layerUploadCount\":{d},\"layerRetainCount\":{d},\"layerEvictCount\":{d}",
            .{
                self.frame_index,
                self.command_count,
                self.batch_count,
                self.encoder_command_count,
                self.encoder_cache_action_count,
                self.encoder_bind_pipeline_count,
                self.encoder_draw_batch_count,
                self.pipeline_count,
                self.pipeline_upload_count,
                self.pipeline_retain_count,
                self.pipeline_evict_count,
                self.path_geometry_count,
                self.path_geometry_vertex_count,
                self.path_geometry_index_count,
                self.path_geometry_upload_count,
                self.path_geometry_retain_count,
                self.path_geometry_evict_count,
                self.layer_count,
                self.layer_opacity_count,
                self.layer_clip_count,
                self.layer_transform_count,
                self.layer_upload_count,
                self.layer_retain_count,
                self.layer_evict_count,
            },
        );
        try writer.print(
            ",\"imageCount\":{d},\"imageUploadCount\":{d},\"imageRetainCount\":{d},\"imageEvictCount\":{d},\"resourceCount\":{d},\"resourceUploadCount\":{d},\"resourceRetainCount\":{d},\"resourceEvictCount\":{d},\"visualEffectCount\":{d},\"visualEffectShadowCount\":{d},\"visualEffectBlurCount\":{d},\"visualEffectUploadCount\":{d},\"visualEffectRetainCount\":{d},\"visualEffectEvictCount\":{d},\"glyphAtlasEntryCount\":{d},\"glyphAtlasUploadCount\":{d},\"glyphAtlasRetainCount\":{d},\"glyphAtlasEvictCount\":{d},\"textLayoutCount\":{d},\"textLayoutLineCount\":{d},\"textLayoutUploadCount\":{d},\"textLayoutRetainCount\":{d},\"textLayoutEvictCount\":{d},\"gpuPacketCommandCount\":{d},\"gpuPacketCacheActionCount\":{d},\"gpuPacketCachedResourceCommandCount\":{d},\"gpuPacketUnsupportedCommandCount\":{d}",
            .{
                self.image_count,
                self.image_upload_count,
                self.image_retain_count,
                self.image_evict_count,
                self.resource_count,
                self.resource_upload_count,
                self.resource_retain_count,
                self.resource_evict_count,
                self.visual_effect_count,
                self.visual_effect_shadow_count,
                self.visual_effect_blur_count,
                self.visual_effect_upload_count,
                self.visual_effect_retain_count,
                self.visual_effect_evict_count,
                self.glyph_atlas_entry_count,
                self.glyph_atlas_upload_count,
                self.glyph_atlas_retain_count,
                self.glyph_atlas_evict_count,
                self.text_layout_count,
                self.text_layout_line_count,
                self.text_layout_upload_count,
                self.text_layout_retain_count,
                self.text_layout_evict_count,
                self.gpu_packet_command_count,
                self.gpu_packet_cache_action_count,
                self.gpu_packet_cached_resource_command_count,
                self.gpu_packet_unsupported_command_count,
            },
        );
        try writer.writeAll(",\"gpuPacketRepresentable\":");
        try writer.writeAll(if (self.gpu_packet_representable) "true" else "false");
        try writer.print(",\"changeCount\":{d},\"budgetExceededCount\":{d}", .{ self.change_count, self.budget_status.exceededCount() });
        try writer.writeAll(",\"budgetOk\":");
        try writer.writeAll(if (self.budgetOk()) "true" else "false");
        try writer.writeAll(",\"fullRepaint\":");
        try writer.writeAll(if (self.full_repaint) "true" else "false");
        try writer.writeAll(",\"requiresRender\":");
        try writer.writeAll(if (self.requires_render) "true" else "false");
        try writer.writeAll(",\"dirtyBounds\":");
        if (self.dirty_bounds) |bounds| {
            try writeRectJson(bounds, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
};

pub const CanvasFrameProfileRisk = enum {
    idle,
    low,
    moderate,
    high,
};

pub const CanvasFrameProfile = struct {
    frame_index: u64 = 0,
    requires_render: bool = false,
    full_repaint: bool = false,
    dirty_bounds: ?geometry.RectF = null,
    surface_area: f32 = 0,
    dirty_area: f32 = 0,
    dirty_ratio: f32 = 0,
    command_count: usize = 0,
    batch_count: usize = 0,
    encoder_command_count: usize = 0,
    cache_action_count: usize = 0,
    cache_upload_count: usize = 0,
    cache_retain_count: usize = 0,
    cache_evict_count: usize = 0,
    path_geometry_vertex_count: usize = 0,
    path_geometry_index_count: usize = 0,
    image_count: usize = 0,
    layer_count: usize = 0,
    visual_effect_count: usize = 0,
    glyph_atlas_entry_count: usize = 0,
    text_layout_line_count: usize = 0,
    work_units: usize = 0,
    risk: CanvasFrameProfileRisk = .idle,

    pub fn writeJson(self: CanvasFrameProfile, writer: anytype) !void {
        try writer.print(
            "{{\"frameIndex\":{d},\"requiresRender\":{},\"fullRepaint\":{},\"dirtyBounds\":",
            .{ self.frame_index, self.requires_render, self.full_repaint },
        );
        try writeOptionalRectJson(self.dirty_bounds, writer);
        try writer.print(
            ",\"surfaceArea\":{d},\"dirtyArea\":{d},\"dirtyRatio\":{d},\"commandCount\":{d},\"batchCount\":{d},\"encoderCommandCount\":{d},\"cacheActionCount\":{d},\"cacheUploadCount\":{d},\"cacheRetainCount\":{d},\"cacheEvictCount\":{d},\"pathGeometryVertexCount\":{d},\"pathGeometryIndexCount\":{d},\"imageCount\":{d},\"layerCount\":{d},\"visualEffectCount\":{d},\"glyphAtlasEntryCount\":{d},\"textLayoutLineCount\":{d},\"workUnits\":{d},\"risk\":",
            .{
                self.surface_area,
                self.dirty_area,
                self.dirty_ratio,
                self.command_count,
                self.batch_count,
                self.encoder_command_count,
                self.cache_action_count,
                self.cache_upload_count,
                self.cache_retain_count,
                self.cache_evict_count,
                self.path_geometry_vertex_count,
                self.path_geometry_index_count,
                self.image_count,
                self.layer_count,
                self.visual_effect_count,
                self.glyph_atlas_entry_count,
                self.text_layout_line_count,
                self.work_units,
            },
        );
        try json.writeString(writer, @tagName(self.risk));
        try writer.writeByte('}');
    }
};

pub fn canvasFrameProfile(frame: anytype) CanvasFrameProfile {
    const diagnostics = frame.diagnostics();
    const surface_area = sizeArea(frame.surface_size);
    const dirty_area = optionalRectArea(frame.dirty_bounds);
    const cache_upload_count = diagnostics.pipeline_upload_count +
        diagnostics.path_geometry_upload_count +
        diagnostics.image_upload_count +
        diagnostics.layer_upload_count +
        diagnostics.resource_upload_count +
        diagnostics.visual_effect_upload_count +
        diagnostics.glyph_atlas_upload_count +
        diagnostics.text_layout_upload_count;
    const cache_retain_count = diagnostics.pipeline_retain_count +
        diagnostics.path_geometry_retain_count +
        diagnostics.image_retain_count +
        diagnostics.layer_retain_count +
        diagnostics.resource_retain_count +
        diagnostics.visual_effect_retain_count +
        diagnostics.glyph_atlas_retain_count +
        diagnostics.text_layout_retain_count;
    const cache_evict_count = diagnostics.pipeline_evict_count +
        diagnostics.path_geometry_evict_count +
        diagnostics.image_evict_count +
        diagnostics.layer_evict_count +
        diagnostics.resource_evict_count +
        diagnostics.visual_effect_evict_count +
        diagnostics.glyph_atlas_evict_count +
        diagnostics.text_layout_evict_count;
    var profile = CanvasFrameProfile{
        .frame_index = frame.frame_index,
        .requires_render = frame.requiresRender(),
        .full_repaint = frame.full_repaint,
        .dirty_bounds = frame.dirty_bounds,
        .surface_area = surface_area,
        .dirty_area = dirty_area,
        .dirty_ratio = dirtyAreaRatio(dirty_area, surface_area),
        .command_count = diagnostics.command_count,
        .batch_count = diagnostics.batch_count,
        .encoder_command_count = diagnostics.encoder_command_count,
        .cache_action_count = cache_upload_count + cache_retain_count + cache_evict_count,
        .cache_upload_count = cache_upload_count,
        .cache_retain_count = cache_retain_count,
        .cache_evict_count = cache_evict_count,
        .path_geometry_vertex_count = diagnostics.path_geometry_vertex_count,
        .path_geometry_index_count = diagnostics.path_geometry_index_count,
        .image_count = diagnostics.image_count,
        .layer_count = diagnostics.layer_count,
        .visual_effect_count = diagnostics.visual_effect_count,
        .glyph_atlas_entry_count = diagnostics.glyph_atlas_entry_count,
        .text_layout_line_count = diagnostics.text_layout_line_count,
    };
    profile.work_units = canvasFrameProfileWorkUnits(profile, diagnostics);
    profile.risk = canvasFrameProfileRisk(profile, diagnostics);
    return profile;
}

fn canvasFrameProfileWorkUnits(profile: CanvasFrameProfile, diagnostics: CanvasFrameDiagnostics) usize {
    if (!profile.requires_render) return 0;

    var units = profile.command_count +
        profile.batch_count * 2 +
        profile.encoder_command_count +
        profile.cache_upload_count * 12 +
        profile.cache_retain_count +
        profile.cache_evict_count * 3 +
        profile.image_count * 4 +
        profile.layer_count * 3 +
        diagnostics.visual_effect_shadow_count * 20 +
        diagnostics.visual_effect_blur_count * 24 +
        profile.glyph_atlas_entry_count * 2 +
        profile.text_layout_line_count * 2;
    units += profile.path_geometry_vertex_count / 8;
    units += profile.path_geometry_index_count / 12;
    if (profile.full_repaint or profile.dirty_ratio >= 0.75) {
        units += 25;
    } else if (profile.dirty_ratio >= 0.25) {
        units += 10;
    }
    return units;
}

fn canvasFrameProfileRisk(profile: CanvasFrameProfile, diagnostics: CanvasFrameDiagnostics) CanvasFrameProfileRisk {
    if (!profile.requires_render) return .idle;
    if (profile.full_repaint or
        profile.dirty_ratio >= 0.75 or
        profile.cache_upload_count > 16 or
        profile.work_units >= 160 or
        (diagnostics.visual_effect_blur_count > 0 and profile.dirty_ratio >= 0.25))
    {
        return .high;
    }
    if (profile.dirty_ratio >= 0.25 or
        profile.cache_upload_count > 4 or
        profile.work_units >= 80 or
        profile.visual_effect_count > 0)
    {
        return .moderate;
    }
    return .low;
}

fn sizeArea(size: geometry.SizeF) f32 {
    return nonNegative(size.width) * nonNegative(size.height);
}

fn optionalRectArea(rect: ?geometry.RectF) f32 {
    const value = rect orelse return 0;
    const normalized = value.normalized();
    return nonNegative(normalized.width) * nonNegative(normalized.height);
}

fn dirtyAreaRatio(dirty_area: f32, surface_area: f32) f32 {
    if (surface_area <= 0) return if (dirty_area > 0) 1 else 0;
    return std.math.clamp(dirty_area / surface_area, 0, 1);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn budgetExceeded(limit: usize, value: usize) bool {
    return limit > 0 and value > limit;
}

fn writeOptionalRectJson(rect: ?geometry.RectF, writer: anytype) !void {
    if (rect) |value| {
        try writeRectJson(value, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeRectJson(rect: geometry.RectF, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ rect.x, rect.y, rect.width, rect.height });
}
