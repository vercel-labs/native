const geometry = @import("geometry");
const canvas = @import("root.zig");
const render_model = @import("render.zig");
const text_model = @import("text.zig");
const gpu_model = @import("gpu.zig");
const serialization = @import("serialization.zig");
const frame_metrics = @import("frame_metrics.zig");

const Error = canvas.Error;
const DiffChange = canvas.DiffChange;
const DisplayList = canvas.DisplayList;
const ReferenceImage = canvas.ReferenceImage;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;

const CanvasRenderOverride = render_model.CanvasRenderOverride;
const applyRenderOverrides = render_model.applyRenderOverrides;
const renderOverrideDirtyBounds = render_model.renderOverrideDirtyBounds;
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

pub const CanvasFrameBudget = frame_metrics.CanvasFrameBudget;
pub const CanvasFrameBudgetStatus = frame_metrics.CanvasFrameBudgetStatus;
pub const CanvasFrameDiagnostics = frame_metrics.CanvasFrameDiagnostics;
pub const CanvasFrameProfileRisk = frame_metrics.CanvasFrameProfileRisk;
pub const CanvasFrameProfile = frame_metrics.CanvasFrameProfile;
pub const canvasFrameProfile = frame_metrics.canvasFrameProfile;

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

pub fn buildCanvasFrame(previous: ?DisplayList, next: DisplayList, options: CanvasFrameOptions, storage: CanvasFrameStorage) Error!CanvasFrame {
    var render_plan = try next.renderPlan(storage.render_commands);
    const render_override_dirty_bounds = renderOverrideDirtyBounds(render_plan.commands, options.previous_render_overrides, options.render_overrides);
    render_plan.bounds = applyRenderOverrides(storage.render_commands[0..render_plan.commandCount()], options.render_overrides);
    const batch_plan = try render_plan.batchPlan(storage.render_batches);
    const pipeline_cache_plan = if (storage.pipeline_cache_entries.len == 0 and storage.pipeline_cache_actions.len == 0)
        RenderPipelineCachePlan{}
    else
        try batch_plan.cachePlan(
            options.previous_pipeline_cache,
            options.frame_index,
            storage.pipeline_cache_entries,
            storage.pipeline_cache_actions,
        );
    const path_geometry_plan = if (storage.path_geometries.len == 0)
        RenderPathGeometryPlan{}
    else
        try render_plan.pathGeometryPlan(storage.path_geometries);
    const path_geometry_cache_plan = if (storage.path_geometry_cache_entries.len == 0 and storage.path_geometry_cache_actions.len == 0)
        RenderPathGeometryCachePlan{}
    else
        try path_geometry_plan.cachePlan(
            options.previous_path_geometry_cache,
            options.frame_index,
            storage.path_geometry_cache_entries,
            storage.path_geometry_cache_actions,
        );
    const image_plan = if (storage.images.len == 0)
        RenderImagePlan{}
    else
        try render_plan.imagePlanWithResources(options.image_resources, storage.images);
    const image_cache_plan = if (storage.image_cache_entries.len == 0 and storage.image_cache_actions.len == 0)
        RenderImageCachePlan{}
    else
        try image_plan.cachePlan(
            options.previous_image_cache,
            options.frame_index,
            storage.image_cache_entries,
            storage.image_cache_actions,
        );
    const layer_plan = if (storage.layers.len == 0)
        RenderLayerPlan{}
    else
        try render_plan.layerPlan(storage.layers);
    const layer_cache_plan = if (storage.layer_cache_entries.len == 0 and storage.layer_cache_actions.len == 0)
        RenderLayerCachePlan{}
    else
        try layer_plan.cachePlan(
            options.previous_layer_cache,
            options.frame_index,
            storage.layer_cache_entries,
            storage.layer_cache_actions,
        );
    const resource_plan = try next.resourcePlan(storage.resources);
    const resource_cache_plan = try resource_plan.cachePlan(
        options.previous_resource_cache,
        options.frame_index,
        storage.resource_cache_entries,
        storage.resource_cache_actions,
    );
    const visual_effect_plan = if (storage.visual_effects.len == 0)
        VisualEffectPlan{}
    else
        try next.visualEffectPlan(storage.visual_effects);
    const visual_effect_cache_plan = if (storage.visual_effect_cache_entries.len == 0 and storage.visual_effect_cache_actions.len == 0)
        VisualEffectCachePlan{}
    else
        try visual_effect_plan.cachePlan(
            options.previous_visual_effect_cache,
            options.frame_index,
            storage.visual_effect_cache_entries,
            storage.visual_effect_cache_actions,
        );
    const glyph_atlas_plan = try next.glyphAtlasPlan(storage.glyph_atlas_entries);
    const glyph_atlas_cache_plan = try glyph_atlas_plan.cachePlanWithRetention(
        options.previous_glyph_atlas_cache,
        options.frame_index,
        options.glyph_atlas_cache_retention_frames,
        storage.glyph_atlas_cache_entries,
        storage.glyph_atlas_cache_actions,
    );
    const text_layout_plan = try next.textLayoutPlan(options.text_layout_options, storage.text_layout_plans, storage.text_layout_lines);
    const text_layout_cache_plan = if (storage.text_layout_cache_entries.len == 0 and storage.text_layout_cache_actions.len == 0)
        TextLayoutCachePlan{}
    else
        try text_layout_plan.cachePlanWithRetention(
            options.previous_text_layout_cache,
            options.frame_index,
            options.text_layout_cache_retention_frames,
            storage.text_layout_cache_entries,
            storage.text_layout_cache_actions,
        );

    const full_repaint = options.full_repaint or previous == null;
    var changes: []const DiffChange = storage.changes[0..0];
    var dirty_bounds: ?geometry.RectF = null;

    if (full_repaint) {
        dirty_bounds = fullRepaintBounds(options.surface_size, render_plan.bounds);
    } else {
        changes = try DisplayList.diff(previous.?, next, storage.changes);
        dirty_bounds = clippedDirtyBounds(unionOptionalBounds(dirtyBoundsFromChanges(changes), render_override_dirty_bounds), options.surface_size);
    }

    return .{
        .frame_index = options.frame_index,
        .timestamp_ns = options.timestamp_ns,
        .surface_size = options.surface_size,
        .scale = options.scale,
        .full_repaint = full_repaint,
        .display_list = next,
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
        .image_resources = options.image_resources,
        .changes = changes,
        .dirty_bounds = dirty_bounds,
        .budget = options.budget,
    };
}

fn dirtyBoundsFromChanges(changes: []const DiffChange) ?geometry.RectF {
    var result: ?geometry.RectF = null;
    for (changes) |change| {
        result = unionOptionalBounds(result, change.dirty_bounds);
    }
    return result;
}

fn fullRepaintBounds(surface_size: geometry.SizeF, render_bounds: ?geometry.RectF) ?geometry.RectF {
    if (surfaceRect(surface_size)) |surface| return surface;
    return render_bounds;
}

fn clippedDirtyBounds(bounds: ?geometry.RectF, surface_size: geometry.SizeF) ?geometry.RectF {
    const dirty = bounds orelse return null;
    const normalized = dirty.normalized();
    if (surfaceRect(surface_size)) |surface| {
        const clipped = geometry.RectF.intersection(surface, normalized);
        return if (clipped.isEmpty()) null else clipped;
    }
    return if (normalized.isEmpty()) null else normalized;
}

fn surfaceRect(surface_size: geometry.SizeF) ?geometry.RectF {
    const rect = geometry.RectF.fromSize(surface_size).normalized();
    return if (rect.isEmpty()) null else rect;
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
}
