const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const CanvasCommand = canvas.CanvasCommand;
const ReferenceImage = canvas.ReferenceImage;
const Affine = drawing_model.Affine;
const Radius = drawing_model.Radius;
const Easing = token_model.Easing;
const SpringToken = token_model.SpringToken;

const RenderBatchPlanner = canvas.RenderBatchPlanner;
const RenderPathGeometryPlanner = canvas.RenderPathGeometryPlanner;
const RenderImagePlanner = canvas.RenderImagePlanner;
const RenderLayerPlanner = canvas.RenderLayerPlanner;
const RenderPipelineCachePlanner = canvas.RenderPipelineCachePlanner;
const RenderPathGeometryCachePlanner = canvas.RenderPathGeometryCachePlanner;
const RenderImageCachePlanner = canvas.RenderImageCachePlanner;
const RenderResourceCachePlanner = canvas.RenderResourceCachePlanner;
const RenderLayerCachePlanner = canvas.RenderLayerCachePlanner;
const VisualEffectCachePlanner = canvas.VisualEffectCachePlanner;

pub const max_render_state_stack: usize = 32;

pub const RenderState = struct {
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
};

pub const RenderCommand = struct {
    command: CanvasCommand,
    id: ?ObjectId = null,
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
    local_bounds: geometry.RectF,
    bounds: geometry.RectF,
};

pub const CanvasRenderOverride = struct {
    id: ObjectId,
    opacity: ?f32 = null,
    transform: ?Affine = null,
};

pub const CanvasRenderAnimation = struct {
    id: ObjectId,
    start_ns: u64 = 0,
    duration_ms: u32 = 0,
    easing: Easing = .standard,
    spring: SpringToken = .{},
    from_opacity: ?f32 = null,
    to_opacity: ?f32 = null,
    from_transform: ?Affine = null,
    to_transform: ?Affine = null,
};

pub const RenderPlan = struct {
    commands: []const RenderCommand = &.{},
    bounds: ?geometry.RectF = null,

    pub fn commandCount(self: RenderPlan) usize {
        return self.commands.len;
    }

    pub fn batchPlan(self: RenderPlan, output: []RenderBatch) Error!RenderBatchPlan {
        var planner = RenderBatchPlanner.init(output);
        return planner.build(self);
    }

    pub fn pathGeometryPlan(self: RenderPlan, output: []RenderPathGeometry) Error!RenderPathGeometryPlan {
        var planner = RenderPathGeometryPlanner.init(output);
        return planner.build(self);
    }

    pub fn imagePlan(self: RenderPlan, output: []RenderImage) Error!RenderImagePlan {
        return self.imagePlanWithResources(&.{}, output);
    }

    pub fn imagePlanWithResources(self: RenderPlan, image_resources: []const ReferenceImage, output: []RenderImage) Error!RenderImagePlan {
        var planner = RenderImagePlanner.init(output);
        planner.image_resources = image_resources;
        return planner.build(self);
    }

    pub fn layerPlan(self: RenderPlan, output: []RenderLayer) Error!RenderLayerPlan {
        var planner = RenderLayerPlanner.init(output);
        return planner.build(self);
    }
};

pub const RenderPipelineKind = enum {
    solid,
    linear_gradient,
    image,
    glyph_run,
    path,
    shadow,
    blur,
};

pub const RenderBatch = struct {
    pipeline: RenderPipelineKind,
    command_start: usize = 0,
    command_count: usize = 0,
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    bounds: geometry.RectF = .{},
};

pub const RenderBatchPlan = struct {
    batches: []const RenderBatch = &.{},
    bounds: ?geometry.RectF = null,

    pub fn batchCount(self: RenderBatchPlan) usize {
        return self.batches.len;
    }

    pub fn cachePlan(self: RenderBatchPlan, previous: []const RenderPipelineCacheEntry, frame_index: u64, entries: []RenderPipelineCacheEntry, actions: []RenderPipelineCacheAction) Error!RenderPipelineCachePlan {
        var planner = RenderPipelineCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderPipelineCacheEntry = struct {
    pipeline: RenderPipelineKind,
    last_used_frame: u64 = 0,
};

pub const RenderPipelineCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderPipelineCacheAction = struct {
    kind: RenderPipelineCacheActionKind,
    pipeline: RenderPipelineKind,
    batch_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderPipelineCachePlan = struct {
    entries: []const RenderPipelineCacheEntry = &.{},
    actions: []const RenderPipelineCacheAction = &.{},

    pub fn entryCount(self: RenderPipelineCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderPipelineCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderPipelineCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderPipelineCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderPipelineCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderPipelineCachePlan, kind: RenderPipelineCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderPathGeometryKind = enum {
    fill,
    stroke,
};

pub const RenderPathGeometry = struct {
    kind: RenderPathGeometryKind,
    command_index: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    element_count: usize = 0,
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
    stroke_width: f32 = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryPlan = struct {
    geometries: []const RenderPathGeometry = &.{},

    pub fn geometryCount(self: RenderPathGeometryPlan) usize {
        return self.geometries.len;
    }

    pub fn vertexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.vertex_count;
        return count;
    }

    pub fn indexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.index_count;
        return count;
    }

    pub fn cachePlan(self: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) Error!RenderPathGeometryCachePlan {
        var planner = RenderPathGeometryCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderPathGeometryKey = struct {
    kind: RenderPathGeometryKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryCacheEntry = struct {
    key: RenderPathGeometryKey,
    last_used_frame: u64 = 0,
};

pub const RenderPathGeometryCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderPathGeometryCacheAction = struct {
    kind: RenderPathGeometryCacheActionKind,
    key: RenderPathGeometryKey,
    geometry_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderPathGeometryCachePlan = struct {
    entries: []const RenderPathGeometryCacheEntry = &.{},
    actions: []const RenderPathGeometryCacheAction = &.{},

    pub fn entryCount(self: RenderPathGeometryCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderPathGeometryCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderPathGeometryCachePlan, kind: RenderPathGeometryCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderImage = struct {
    image_id: ImageId,
    command_index: usize = 0,
    id: ?ObjectId = null,
    draw_count: usize = 0,
    bounds: geometry.RectF = .{},
    width: usize = 0,
    height: usize = 0,
    pixels: []const u8 = &.{},
    fingerprint: u64 = 0,
};

pub const RenderImagePlan = struct {
    images: []const RenderImage = &.{},

    pub fn imageCount(self: RenderImagePlan) usize {
        return self.images.len;
    }

    pub fn drawCount(self: RenderImagePlan) usize {
        var count: usize = 0;
        for (self.images) |image| count += image.draw_count;
        return count;
    }

    pub fn cachePlan(self: RenderImagePlan, previous: []const RenderImageCacheEntry, frame_index: u64, entries: []RenderImageCacheEntry, actions: []RenderImageCacheAction) Error!RenderImageCachePlan {
        var planner = RenderImageCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderImageKey = struct {
    image_id: ImageId,
    fingerprint: u64 = 0,
};

pub const RenderImageCacheEntry = struct {
    key: RenderImageKey,
    last_used_frame: u64 = 0,
};

pub const RenderImageCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderImageCacheAction = struct {
    kind: RenderImageCacheActionKind,
    key: RenderImageKey,
    image_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderImageCachePlan = struct {
    entries: []const RenderImageCacheEntry = &.{},
    actions: []const RenderImageCacheAction = &.{},

    pub fn entryCount(self: RenderImageCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderImageCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderImageCachePlan, kind: RenderImageCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderResourceKind = enum {
    linear_gradient,
    image,
    glyph_run,
    shadow,
    blur,
};

pub const RenderResource = struct {
    kind: RenderResourceKind,
    command_index: usize,
    id: ?ObjectId = null,
    bounds: ?geometry.RectF = null,
    image_id: ImageId = 0,
    font_id: FontId = 0,
    gradient_stop_count: usize = 0,
    glyph_count: usize = 0,
    text_len: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderResourcePlan = struct {
    resources: []const RenderResource = &.{},

    pub fn resourceCount(self: RenderResourcePlan) usize {
        return self.resources.len;
    }

    pub fn cachePlan(self: RenderResourcePlan, previous: []const RenderResourceCacheEntry, frame_index: u64, entries: []RenderResourceCacheEntry, actions: []RenderResourceCacheAction) Error!RenderResourceCachePlan {
        var planner = RenderResourceCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderResourceKey = struct {
    kind: RenderResourceKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    image_id: ImageId = 0,
    font_id: FontId = 0,
    fingerprint: u64 = 0,
};

pub const RenderResourceCacheEntry = struct {
    key: RenderResourceKey,
    last_used_frame: u64 = 0,
};

pub const RenderResourceCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderResourceCacheAction = struct {
    kind: RenderResourceCacheActionKind,
    key: RenderResourceKey,
    resource_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderResourceCachePlan = struct {
    entries: []const RenderResourceCacheEntry = &.{},
    actions: []const RenderResourceCacheAction = &.{},

    pub fn entryCount(self: RenderResourceCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderResourceCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderResourceCachePlan, kind: RenderResourceCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderLayer = struct {
    command_start: usize = 0,
    command_count: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
    fingerprint: u64 = 0,
};

pub const RenderLayerPlan = struct {
    layers: []const RenderLayer = &.{},

    pub fn layerCount(self: RenderLayerPlan) usize {
        return self.layers.len;
    }

    pub fn opacityLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.opacity != 1) count += 1;
        }
        return count;
    }

    pub fn clipLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.clip != null) count += 1;
        }
        return count;
    }

    pub fn transformLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (!affinesEqual(layer.transform, Affine.identity())) count += 1;
        }
        return count;
    }

    pub fn cachePlan(self: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64, entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) Error!RenderLayerCachePlan {
        var planner = RenderLayerCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderLayerKey = struct {
    id: ?ObjectId = null,
    command_start: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderLayerCacheEntry = struct {
    key: RenderLayerKey,
    last_used_frame: u64 = 0,
};

pub const RenderLayerCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderLayerCacheAction = struct {
    kind: RenderLayerCacheActionKind,
    key: RenderLayerKey,
    layer_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderLayerCachePlan = struct {
    entries: []const RenderLayerCacheEntry = &.{},
    actions: []const RenderLayerCacheAction = &.{},

    pub fn entryCount(self: RenderLayerCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderLayerCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderLayerCachePlan, kind: RenderLayerCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const VisualEffectKind = enum {
    shadow,
    blur,
};

pub const VisualEffect = struct {
    kind: VisualEffectKind,
    command_index: usize,
    id: ?ObjectId = null,
    bounds: ?geometry.RectF = null,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    fingerprint: u64 = 0,
};

pub const VisualEffectPlan = struct {
    effects: []const VisualEffect = &.{},

    pub fn effectCount(self: VisualEffectPlan) usize {
        return self.effects.len;
    }

    pub fn shadowCount(self: VisualEffectPlan) usize {
        return self.effectCountByKind(.shadow);
    }

    pub fn blurCount(self: VisualEffectPlan) usize {
        return self.effectCountByKind(.blur);
    }

    pub fn cachePlan(self: VisualEffectPlan, previous: []const VisualEffectCacheEntry, frame_index: u64, entries: []VisualEffectCacheEntry, actions: []VisualEffectCacheAction) Error!VisualEffectCachePlan {
        var planner = VisualEffectCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }

    fn effectCountByKind(self: VisualEffectPlan, kind: VisualEffectKind) usize {
        var count: usize = 0;
        for (self.effects) |effect| {
            if (effect.kind == kind) count += 1;
        }
        return count;
    }
};

pub const VisualEffectKey = struct {
    kind: VisualEffectKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    fingerprint: u64 = 0,
};

pub const VisualEffectCacheEntry = struct {
    key: VisualEffectKey,
    last_used_frame: u64 = 0,
};

pub const VisualEffectCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const VisualEffectCacheAction = struct {
    kind: VisualEffectCacheActionKind,
    key: VisualEffectKey,
    effect_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const VisualEffectCachePlan = struct {
    entries: []const VisualEffectCacheEntry = &.{},
    actions: []const VisualEffectCacheAction = &.{},

    pub fn entryCount(self: VisualEffectCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: VisualEffectCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: VisualEffectCachePlan, kind: VisualEffectCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}
