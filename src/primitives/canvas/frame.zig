const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");
const canvas = @import("root.zig");
const render_model = @import("render.zig");
const text_model = @import("text.zig");
const gpu_model = @import("gpu.zig");
const serialization = @import("serialization.zig");

const Error = canvas.Error;
const DiffChange = canvas.DiffChange;
const DisplayList = canvas.DisplayList;
const ReferenceImage = canvas.ReferenceImage;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;

const CanvasRenderOverride = render_model.CanvasRenderOverride;
const RenderPipelineKind = render_model.RenderPipelineKind;
const RenderCommand = render_model.RenderCommand;
const RenderPlan = render_model.RenderPlan;
const RenderBatch = render_model.RenderBatch;
const RenderBatchPlan = render_model.RenderBatchPlan;
const RenderPipelineCacheEntry = render_model.RenderPipelineCacheEntry;
const RenderPipelineCacheAction = render_model.RenderPipelineCacheAction;
const RenderPipelineCachePlan = render_model.RenderPipelineCachePlan;
const RenderPathGeometry = render_model.RenderPathGeometry;
const RenderPathGeometryPlan = render_model.RenderPathGeometryPlan;
const RenderPathGeometryCacheEntry = render_model.RenderPathGeometryCacheEntry;
const RenderPathGeometryCacheAction = render_model.RenderPathGeometryCacheAction;
const RenderPathGeometryCachePlan = render_model.RenderPathGeometryCachePlan;
const RenderImage = render_model.RenderImage;
const RenderImagePlan = render_model.RenderImagePlan;
const RenderImageCacheEntry = render_model.RenderImageCacheEntry;
const RenderImageCacheAction = render_model.RenderImageCacheAction;
const RenderImageCachePlan = render_model.RenderImageCachePlan;
const RenderLayer = render_model.RenderLayer;
const RenderLayerPlan = render_model.RenderLayerPlan;
const RenderLayerCacheEntry = render_model.RenderLayerCacheEntry;
const RenderLayerCacheAction = render_model.RenderLayerCacheAction;
const RenderLayerCachePlan = render_model.RenderLayerCachePlan;
const RenderResource = render_model.RenderResource;
const RenderResourcePlan = render_model.RenderResourcePlan;
const RenderResourceCacheEntry = render_model.RenderResourceCacheEntry;
const RenderResourceCacheAction = render_model.RenderResourceCacheAction;
const RenderResourceCachePlan = render_model.RenderResourceCachePlan;
const VisualEffect = render_model.VisualEffect;
const VisualEffectPlan = render_model.VisualEffectPlan;
const VisualEffectCacheEntry = render_model.VisualEffectCacheEntry;
const VisualEffectCacheAction = render_model.VisualEffectCacheAction;
const VisualEffectCachePlan = render_model.VisualEffectCachePlan;

const GlyphAtlasPlan = text_model.GlyphAtlasPlan;
const GlyphAtlasEntry = text_model.GlyphAtlasEntry;
const GlyphAtlasCacheEntry = text_model.GlyphAtlasCacheEntry;
const GlyphAtlasCacheAction = text_model.GlyphAtlasCacheAction;
const GlyphAtlasCachePlan = text_model.GlyphAtlasCachePlan;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const TextLayoutPlan = text_model.TextLayoutPlan;
const TextLayoutPlanSet = text_model.TextLayoutPlanSet;
const TextLayoutCacheEntry = text_model.TextLayoutCacheEntry;
const TextLayoutCacheAction = text_model.TextLayoutCacheAction;
const TextLayoutCachePlan = text_model.TextLayoutCachePlan;
const CanvasRenderPassLoadAction = gpu_model.CanvasRenderPassLoadAction;
const RenderEncoderCommand = gpu_model.RenderEncoderCommand;
const RenderEncoderPlan = gpu_model.RenderEncoderPlan;
const RenderEncoderPlanner = gpu_model.RenderEncoderPlanner;
const CanvasGpuCommand = gpu_model.CanvasGpuCommand;
const CanvasGpuPacket = gpu_model.CanvasGpuPacket;
const CanvasGpuPacketSummary = gpu_model.CanvasGpuPacketSummary;
const CanvasGpuPacketPlanner = gpu_model.CanvasGpuPacketPlanner;
const renderCommandIntersectsDirtyBounds = gpu_model.renderCommandIntersectsDirtyBounds;
const canvasGpuCommandFromRenderCommand = gpu_model.canvasGpuCommandFromRenderCommand;

pub const CanvasRenderPass = struct {
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    full_repaint: bool = false,
    dirty_bounds: ?geometry.RectF = null,
    commands: []const RenderCommand = &.{},
    batches: []const RenderBatch = &.{},
    pipeline_actions: []const RenderPipelineCacheAction = &.{},
    path_geometries: []const RenderPathGeometry = &.{},
    path_geometry_actions: []const RenderPathGeometryCacheAction = &.{},
    images: []const RenderImage = &.{},
    image_actions: []const RenderImageCacheAction = &.{},
    layers: []const RenderLayer = &.{},
    layer_actions: []const RenderLayerCacheAction = &.{},
    resources: []const RenderResource = &.{},
    resource_actions: []const RenderResourceCacheAction = &.{},
    visual_effects: []const VisualEffect = &.{},
    visual_effect_actions: []const VisualEffectCacheAction = &.{},
    glyph_atlas_entries: []const GlyphAtlasEntry = &.{},
    glyph_atlas_actions: []const GlyphAtlasCacheAction = &.{},
    text_layouts: []const TextLayoutPlan = &.{},
    text_layout_actions: []const TextLayoutCacheAction = &.{},

    pub fn requiresRender(self: CanvasRenderPass) bool {
        return self.full_repaint or self.dirty_bounds != null;
    }

    pub fn loadAction(self: CanvasRenderPass) CanvasRenderPassLoadAction {
        if (!self.requiresRender()) return .skip;
        return if (self.full_repaint) .clear else .load;
    }

    pub fn scissorBounds(self: CanvasRenderPass) ?geometry.RectF {
        return if (self.requiresRender()) self.dirty_bounds else null;
    }

    pub fn commandCount(self: CanvasRenderPass) usize {
        return self.commands.len;
    }

    pub fn batchCount(self: CanvasRenderPass) usize {
        return self.batches.len;
    }

    pub fn pipelineActionCount(self: CanvasRenderPass) usize {
        return self.pipeline_actions.len;
    }

    pub fn pathGeometryCount(self: CanvasRenderPass) usize {
        return self.path_geometries.len;
    }

    pub fn pathGeometryActionCount(self: CanvasRenderPass) usize {
        return self.path_geometry_actions.len;
    }

    pub fn pathGeometryVertexCount(self: CanvasRenderPass) usize {
        var count: usize = 0;
        for (self.path_geometries) |geometry_plan| count += geometry_plan.vertex_count;
        return count;
    }

    pub fn pathGeometryIndexCount(self: CanvasRenderPass) usize {
        var count: usize = 0;
        for (self.path_geometries) |geometry_plan| count += geometry_plan.index_count;
        return count;
    }

    pub fn imageCount(self: CanvasRenderPass) usize {
        return self.images.len;
    }

    pub fn imageActionCount(self: CanvasRenderPass) usize {
        return self.image_actions.len;
    }

    pub fn layerCount(self: CanvasRenderPass) usize {
        return self.layers.len;
    }

    pub fn layerActionCount(self: CanvasRenderPass) usize {
        return self.layer_actions.len;
    }

    pub fn encoderCommandCount(self: CanvasRenderPass) usize {
        if (!self.requiresRender()) return 0;
        var count: usize = 2 + self.encoderCacheActionCount() + self.encoderBindPipelineCount() + self.encoderDrawBatchCount();
        if (self.scissorBounds() != null) count += 1;
        return count;
    }

    pub fn encoderCacheActionCount(self: CanvasRenderPass) usize {
        if (!self.requiresRender()) return 0;
        return self.pipeline_actions.len +
            self.path_geometry_actions.len +
            self.image_actions.len +
            self.layer_actions.len +
            self.resource_actions.len +
            self.visual_effect_actions.len +
            self.glyph_atlas_actions.len +
            self.text_layout_actions.len;
    }

    pub fn encoderBindPipelineCount(self: CanvasRenderPass) usize {
        if (!self.requiresRender()) return 0;
        var count: usize = 0;
        var bound_pipeline: ?RenderPipelineKind = null;
        for (self.batches) |batch| {
            if (bound_pipeline == null or bound_pipeline.? != batch.pipeline) {
                count += 1;
                bound_pipeline = batch.pipeline;
            }
        }
        return count;
    }

    pub fn encoderDrawBatchCount(self: CanvasRenderPass) usize {
        return if (self.requiresRender()) self.batches.len else 0;
    }

    pub fn resourceCount(self: CanvasRenderPass) usize {
        return self.resources.len;
    }

    pub fn resourceActionCount(self: CanvasRenderPass) usize {
        return self.resource_actions.len;
    }

    pub fn visualEffectCount(self: CanvasRenderPass) usize {
        return self.visual_effects.len;
    }

    pub fn visualEffectActionCount(self: CanvasRenderPass) usize {
        return self.visual_effect_actions.len;
    }

    pub fn glyphAtlasEntryCount(self: CanvasRenderPass) usize {
        return self.glyph_atlas_entries.len;
    }

    pub fn glyphAtlasActionCount(self: CanvasRenderPass) usize {
        return self.glyph_atlas_actions.len;
    }

    pub fn textLayoutCount(self: CanvasRenderPass) usize {
        return self.text_layouts.len;
    }

    pub fn textLayoutLineCount(self: CanvasRenderPass) usize {
        var count: usize = 0;
        for (self.text_layouts) |plan| count += plan.lineCount();
        return count;
    }

    pub fn textLayoutActionCount(self: CanvasRenderPass) usize {
        return self.text_layout_actions.len;
    }

    pub fn writeJson(self: CanvasRenderPass, writer: anytype) !void {
        try serialization.writeCanvasRenderPassJson(self, writer);
    }

    pub fn encoderPlan(self: CanvasRenderPass, output: []RenderEncoderCommand) Error!RenderEncoderPlan {
        var planner = RenderEncoderPlanner.init(output);
        return planner.build(self);
    }

    pub fn gpuPacket(self: CanvasRenderPass, output: []CanvasGpuCommand) Error!CanvasGpuPacket {
        var planner = CanvasGpuPacketPlanner.init(output);
        return planner.build(self);
    }

    pub fn gpuPacketSummary(self: CanvasRenderPass) CanvasGpuPacketSummary {
        if (!self.requiresRender()) return .{};
        var summary = CanvasGpuPacketSummary{
            .load_action = self.loadAction(),
            .cache_action_count = self.encoderCacheActionCount(),
        };
        const scissor_bounds = self.scissorBounds();
        for (self.commands, 0..) |command, index| {
            if (scissor_bounds) |scissor| {
                if (!renderCommandIntersectsDirtyBounds(command, scissor)) continue;
            }
            const gpu_command = canvasGpuCommandFromRenderCommand(command, index);
            summary.command_count += 1;
            if (gpu_command.usesCachedResource()) summary.cached_resource_command_count += 1;
            if (!gpu_command.supported()) summary.unsupported_command_count += 1;
        }
        return summary;
    }
};

pub const CanvasFrame = struct {
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    full_repaint: bool = false,
    display_list: DisplayList = .{},
    render_plan: RenderPlan = .{},
    batch_plan: RenderBatchPlan = .{},
    pipeline_cache_plan: RenderPipelineCachePlan = .{},
    path_geometry_plan: RenderPathGeometryPlan = .{},
    path_geometry_cache_plan: RenderPathGeometryCachePlan = .{},
    image_plan: RenderImagePlan = .{},
    image_cache_plan: RenderImageCachePlan = .{},
    layer_plan: RenderLayerPlan = .{},
    layer_cache_plan: RenderLayerCachePlan = .{},
    resource_plan: RenderResourcePlan = .{},
    resource_cache_plan: RenderResourceCachePlan = .{},
    visual_effect_plan: VisualEffectPlan = .{},
    visual_effect_cache_plan: VisualEffectCachePlan = .{},
    glyph_atlas_plan: GlyphAtlasPlan = .{},
    glyph_atlas_cache_plan: GlyphAtlasCachePlan = .{},
    text_layout_plan: TextLayoutPlanSet = .{},
    text_layout_cache_plan: TextLayoutCachePlan = .{},
    image_resources: []const ReferenceImage = &.{},
    changes: []const DiffChange = &.{},
    dirty_bounds: ?geometry.RectF = null,
    budget: CanvasFrameBudget = .{},

    pub fn requiresRender(self: CanvasFrame) bool {
        return self.full_repaint or self.dirty_bounds != null;
    }

    pub fn budgetStatus(self: CanvasFrame) CanvasFrameBudgetStatus {
        return self.budget.status(self.diagnosticsWithoutBudgetStatus());
    }

    pub fn diagnostics(self: CanvasFrame) CanvasFrameDiagnostics {
        var result = self.diagnosticsWithoutBudgetStatus();
        result.budget_status = self.budget.status(result);
        return result;
    }

    fn diagnosticsWithoutBudgetStatus(self: CanvasFrame) CanvasFrameDiagnostics {
        const render_pass = self.renderPass();
        const gpu_packet_summary = render_pass.gpuPacketSummary();
        return .{
            .frame_index = self.frame_index,
            .command_count = self.render_plan.commandCount(),
            .batch_count = self.batch_plan.batchCount(),
            .encoder_command_count = render_pass.encoderCommandCount(),
            .encoder_cache_action_count = render_pass.encoderCacheActionCount(),
            .encoder_bind_pipeline_count = render_pass.encoderBindPipelineCount(),
            .encoder_draw_batch_count = render_pass.encoderDrawBatchCount(),
            .pipeline_count = self.pipeline_cache_plan.entryCount(),
            .pipeline_upload_count = self.pipeline_cache_plan.uploadCount(),
            .pipeline_retain_count = self.pipeline_cache_plan.retainCount(),
            .pipeline_evict_count = self.pipeline_cache_plan.evictCount(),
            .path_geometry_count = self.path_geometry_plan.geometryCount(),
            .path_geometry_vertex_count = self.path_geometry_plan.vertexCount(),
            .path_geometry_index_count = self.path_geometry_plan.indexCount(),
            .path_geometry_upload_count = self.path_geometry_cache_plan.uploadCount(),
            .path_geometry_retain_count = self.path_geometry_cache_plan.retainCount(),
            .path_geometry_evict_count = self.path_geometry_cache_plan.evictCount(),
            .image_count = self.image_plan.imageCount(),
            .image_upload_count = self.image_cache_plan.uploadCount(),
            .image_retain_count = self.image_cache_plan.retainCount(),
            .image_evict_count = self.image_cache_plan.evictCount(),
            .layer_count = self.layer_plan.layerCount(),
            .layer_opacity_count = self.layer_plan.opacityLayerCount(),
            .layer_clip_count = self.layer_plan.clipLayerCount(),
            .layer_transform_count = self.layer_plan.transformLayerCount(),
            .layer_upload_count = self.layer_cache_plan.uploadCount(),
            .layer_retain_count = self.layer_cache_plan.retainCount(),
            .layer_evict_count = self.layer_cache_plan.evictCount(),
            .resource_count = self.resource_plan.resourceCount(),
            .resource_upload_count = self.resource_cache_plan.uploadCount(),
            .resource_retain_count = self.resource_cache_plan.retainCount(),
            .resource_evict_count = self.resource_cache_plan.evictCount(),
            .visual_effect_count = self.visual_effect_plan.effectCount(),
            .visual_effect_shadow_count = self.visual_effect_plan.shadowCount(),
            .visual_effect_blur_count = self.visual_effect_plan.blurCount(),
            .visual_effect_upload_count = self.visual_effect_cache_plan.uploadCount(),
            .visual_effect_retain_count = self.visual_effect_cache_plan.retainCount(),
            .visual_effect_evict_count = self.visual_effect_cache_plan.evictCount(),
            .glyph_atlas_entry_count = self.glyph_atlas_plan.entryCount(),
            .glyph_atlas_upload_count = self.glyph_atlas_cache_plan.uploadCount(),
            .glyph_atlas_retain_count = self.glyph_atlas_cache_plan.retainCount(),
            .glyph_atlas_evict_count = self.glyph_atlas_cache_plan.evictCount(),
            .text_layout_count = self.text_layout_plan.planCount(),
            .text_layout_line_count = self.text_layout_plan.lineCount(),
            .text_layout_upload_count = self.text_layout_cache_plan.uploadCount(),
            .text_layout_retain_count = self.text_layout_cache_plan.retainCount(),
            .text_layout_evict_count = self.text_layout_cache_plan.evictCount(),
            .gpu_packet_command_count = gpu_packet_summary.command_count,
            .gpu_packet_cache_action_count = gpu_packet_summary.cache_action_count,
            .gpu_packet_cached_resource_command_count = gpu_packet_summary.cached_resource_command_count,
            .gpu_packet_unsupported_command_count = gpu_packet_summary.unsupported_command_count,
            .gpu_packet_representable = gpu_packet_summary.fullyRepresentable(),
            .change_count = self.changes.len,
            .full_repaint = self.full_repaint,
            .requires_render = self.requiresRender(),
            .dirty_bounds = self.dirty_bounds,
            .budget = self.budget,
        };
    }

    pub fn writeDiagnosticsJson(self: CanvasFrame, writer: anytype) !void {
        try self.diagnostics().writeJson(writer);
    }

    pub fn profile(self: CanvasFrame) CanvasFrameProfile {
        return canvasFrameProfile(self);
    }

    pub fn writeProfileJson(self: CanvasFrame, writer: anytype) !void {
        try self.profile().writeJson(writer);
    }

    pub fn renderPass(self: CanvasFrame) CanvasRenderPass {
        return .{
            .frame_index = self.frame_index,
            .timestamp_ns = self.timestamp_ns,
            .surface_size = self.surface_size,
            .scale = self.scale,
            .full_repaint = self.full_repaint,
            .dirty_bounds = self.dirty_bounds,
            .commands = self.render_plan.commands,
            .batches = self.batch_plan.batches,
            .pipeline_actions = self.pipeline_cache_plan.actions,
            .path_geometries = self.path_geometry_plan.geometries,
            .path_geometry_actions = self.path_geometry_cache_plan.actions,
            .images = self.image_plan.images,
            .image_actions = self.image_cache_plan.actions,
            .layers = self.layer_plan.layers,
            .layer_actions = self.layer_cache_plan.actions,
            .resources = self.resource_plan.resources,
            .resource_actions = self.resource_cache_plan.actions,
            .visual_effects = self.visual_effect_plan.effects,
            .visual_effect_actions = self.visual_effect_cache_plan.actions,
            .glyph_atlas_entries = self.glyph_atlas_plan.entries,
            .glyph_atlas_actions = self.glyph_atlas_cache_plan.actions,
            .text_layouts = self.text_layout_plan.plans,
            .text_layout_actions = self.text_layout_cache_plan.actions,
        };
    }

    pub fn gpuPacket(self: CanvasFrame, output: []CanvasGpuCommand) Error!CanvasGpuPacket {
        return self.renderPass().gpuPacket(output);
    }

    pub fn gpuPacketSummary(self: CanvasFrame) CanvasGpuPacketSummary {
        return self.renderPass().gpuPacketSummary();
    }
};

pub const CanvasFrameOptions = struct {
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    full_repaint: bool = false,
    budget: CanvasFrameBudget = .{},
    previous_pipeline_cache: []const RenderPipelineCacheEntry = &.{},
    previous_path_geometry_cache: []const RenderPathGeometryCacheEntry = &.{},
    previous_image_cache: []const RenderImageCacheEntry = &.{},
    previous_resource_cache: []const RenderResourceCacheEntry = &.{},
    previous_layer_cache: []const RenderLayerCacheEntry = &.{},
    previous_visual_effect_cache: []const VisualEffectCacheEntry = &.{},
    previous_glyph_atlas_cache: []const GlyphAtlasCacheEntry = &.{},
    previous_text_layout_cache: []const TextLayoutCacheEntry = &.{},
    image_resources: []const ReferenceImage = &.{},
    glyph_atlas_cache_retention_frames: u64 = default_glyph_atlas_cache_retention_frames,
    text_layout_cache_retention_frames: u64 = default_text_layout_cache_retention_frames,
    text_layout_options: TextLayoutOptions = .{},
    previous_render_overrides: []const CanvasRenderOverride = &.{},
    render_overrides: []const CanvasRenderOverride = &.{},
};

pub const CanvasFrameStorage = struct {
    render_commands: []RenderCommand,
    render_batches: []RenderBatch,
    pipeline_cache_entries: []RenderPipelineCacheEntry = &.{},
    pipeline_cache_actions: []RenderPipelineCacheAction = &.{},
    path_geometries: []RenderPathGeometry = &.{},
    path_geometry_cache_entries: []RenderPathGeometryCacheEntry = &.{},
    path_geometry_cache_actions: []RenderPathGeometryCacheAction = &.{},
    images: []RenderImage = &.{},
    image_cache_entries: []RenderImageCacheEntry = &.{},
    image_cache_actions: []RenderImageCacheAction = &.{},
    layers: []RenderLayer = &.{},
    layer_cache_entries: []RenderLayerCacheEntry = &.{},
    layer_cache_actions: []RenderLayerCacheAction = &.{},
    resources: []RenderResource,
    resource_cache_entries: []RenderResourceCacheEntry,
    resource_cache_actions: []RenderResourceCacheAction,
    visual_effects: []VisualEffect = &.{},
    visual_effect_cache_entries: []VisualEffectCacheEntry = &.{},
    visual_effect_cache_actions: []VisualEffectCacheAction = &.{},
    glyph_atlas_entries: []GlyphAtlasEntry,
    glyph_atlas_cache_entries: []GlyphAtlasCacheEntry = &.{},
    glyph_atlas_cache_actions: []GlyphAtlasCacheAction = &.{},
    text_layout_plans: []TextLayoutPlan = &.{},
    text_layout_lines: []TextLine = &.{},
    text_layout_cache_entries: []TextLayoutCacheEntry = &.{},
    text_layout_cache_actions: []TextLayoutCacheAction = &.{},
    changes: []DiffChange,
};

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

pub fn canvasFrameProfile(frame: CanvasFrame) CanvasFrameProfile {
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
