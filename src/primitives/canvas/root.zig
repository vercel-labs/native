const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");

pub const Error = error{
    DisplayListFull,
    DiffListFull,
    DuplicateObjectId,
    DuplicateWidgetId,
    GlyphAtlasCacheListFull,
    GlyphAtlasListFull,
    ImageCacheListFull,
    ImageListFull,
    LayerCacheListFull,
    LayerListFull,
    PathGeometryCacheListFull,
    PathGeometryListFull,
    RenderBatchListFull,
    RenderListFull,
    RenderOverrideListFull,
    RenderPipelineCacheListFull,
    RenderResourceCacheListFull,
    RenderResourceListFull,
    TextLayoutCacheListFull,
    TextLayoutLineListFull,
    TextLayoutPlanListFull,
    TextSelectionRectListFull,
    VisualEffectCacheListFull,
    VisualEffectListFull,
    TextEditBufferTooSmall,
    ReferenceRenderSurfaceTooSmall,
    ReferenceRenderUnsupportedCommand,
    RenderEncoderListFull,
    RenderStackOverflow,
    RenderStackUnderflow,
    InvalidTransform,
    WidgetDepthExceeded,
    WidgetEventRouteListFull,
    WidgetInvalidationListFull,
    WidgetLayoutListFull,
    WidgetSemanticsListFull,
};

pub const ObjectId = u64;
pub const ImageId = u64;
pub const FontId = u64;

pub const default_glyph_atlas_cache_retention_frames: u64 = 120;
pub const default_text_layout_cache_retention_frames: u64 = 120;

const max_reference_text_layout_lines: usize = 64;

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return rgba8(r, g, b, 255);
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
};

pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn identity() Affine {
        return .{};
    }

    pub fn translate(x: f32, y: f32) Affine {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(x: f32, y: f32) Affine {
        return .{ .a = x, .d = y };
    }

    pub fn multiply(self: Affine, other: Affine) Affine {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .tx = self.a * other.tx + self.c * other.ty + self.tx,
            .ty = self.b * other.tx + self.d * other.ty + self.ty,
        };
    }

    pub fn transformPoint(self: Affine, point: geometry.PointF) geometry.PointF {
        return .{
            .x = self.a * point.x + self.c * point.y + self.tx,
            .y = self.b * point.x + self.d * point.y + self.ty,
        };
    }

    pub fn transformRect(self: Affine, rect: geometry.RectF) geometry.RectF {
        const normalized = rect.normalized();
        return boundsFromPoints(&.{
            self.transformPoint(normalized.topLeft()),
            self.transformPoint(normalized.topRight()),
            self.transformPoint(normalized.bottomLeft()),
            self.transformPoint(normalized.bottomRight()),
        }) orelse geometry.RectF.zero();
    }

    pub fn inverse(self: Affine) ?Affine {
        const determinant = self.a * self.d - self.b * self.c;
        if (@abs(determinant) <= 0.000001) return null;
        const inv = 1 / determinant;
        return .{
            .a = self.d * inv,
            .b = -self.b * inv,
            .c = -self.c * inv,
            .d = self.a * inv,
            .tx = (self.c * self.ty - self.d * self.tx) * inv,
            .ty = (self.b * self.tx - self.a * self.ty) * inv,
        };
    }
};

pub const Radius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Radius {
        return .{
            .top_left = value,
            .top_right = value,
            .bottom_right = value,
            .bottom_left = value,
        };
    }
};

pub const GradientStop = struct {
    offset: f32,
    color: Color,
};

pub const LinearGradient = struct {
    start: geometry.PointF,
    end: geometry.PointF,
    stops: []const GradientStop = &.{},
};

pub const Fill = union(enum) {
    color: Color,
    linear_gradient: LinearGradient,
};

pub const Stroke = struct {
    fill: Fill,
    width: f32 = 1,
};

pub const Clip = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
};

pub const FillRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    fill: Fill,
};

pub const StrokeRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    stroke: Stroke,
};

pub const FillRoundedRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius,
    fill: Fill,
};

pub const Line = struct {
    id: ObjectId = 0,
    from: geometry.PointF,
    to: geometry.PointF,
    stroke: Stroke,
};

pub const PathVerb = enum {
    move_to,
    line_to,
    quad_to,
    cubic_to,
    close,
};

pub const PathElement = struct {
    verb: PathVerb,
    points: [3]geometry.PointF = [_]geometry.PointF{geometry.PointF.zero()} ** 3,
};

pub const FillPath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    fill: Fill,
};

pub const StrokePath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    stroke: Stroke,
};

pub const ImageFit = enum {
    stretch,
    contain,
    cover,
};

pub const ImageSampling = enum {
    nearest,
    linear,
};

pub const DrawImage = struct {
    id: ObjectId = 0,
    image_id: ImageId,
    src: ?geometry.RectF = null,
    dst: geometry.RectF,
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
    sampling: ImageSampling = .linear,
};

pub const Glyph = struct {
    id: u32,
    font_id: FontId = 0,
    x: f32,
    y: f32,
    advance: f32 = 0,
};

pub const GlyphAtlasKey = struct {
    font_id: FontId = 0,
    glyph_id: u32 = 0,
    size: f32 = 0,
    subpixel_x: u8 = 0,
    subpixel_y: u8 = 0,
};

pub const GlyphAtlasEntry = struct {
    key: GlyphAtlasKey,
    command_index: usize,
    glyph_index: usize,
};

pub const GlyphAtlasPlan = struct {
    entries: []const GlyphAtlasEntry = &.{},

    pub fn entryCount(self: GlyphAtlasPlan) usize {
        return self.entries.len;
    }

    pub fn cachePlan(self: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) Error!GlyphAtlasCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_glyph_atlas_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, retention_frames: u64, entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) Error!GlyphAtlasCachePlan {
        var planner = GlyphAtlasCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index, retention_frames);
    }
};

pub const GlyphAtlasCacheEntry = struct {
    key: GlyphAtlasKey,
    last_used_frame: u64 = 0,
};

pub const GlyphAtlasCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const GlyphAtlasCacheAction = struct {
    kind: GlyphAtlasCacheActionKind,
    key: GlyphAtlasKey,
    atlas_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const GlyphAtlasCachePlan = struct {
    entries: []const GlyphAtlasCacheEntry = &.{},
    actions: []const GlyphAtlasCacheAction = &.{},

    pub fn entryCount(self: GlyphAtlasCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: GlyphAtlasCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: GlyphAtlasCachePlan, kind: GlyphAtlasCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const DrawText = struct {
    id: ObjectId = 0,
    font_id: FontId = 0,
    size: f32,
    origin: geometry.PointF,
    color: Color,
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
    text_layout: ?TextLayoutOptions = null,
};

pub const TextWrap = enum {
    none,
    word,
    character,
};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextLayoutOptions = struct {
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
};

pub const TextLine = struct {
    text_start: usize = 0,
    text_len: usize = 0,
    glyph_start: usize = 0,
    glyph_len: usize = 0,
    bounds: geometry.RectF = .{},
    baseline: f32 = 0,
};

pub const TextLayout = struct {
    lines: []const TextLine = &.{},
    bounds: ?geometry.RectF = null,

    pub fn lineCount(self: TextLayout) usize {
        return self.lines.len;
    }
};

pub const TextLayoutKey = struct {
    font_id: FontId = 0,
    size: f32 = 0,
    origin: geometry.PointF = .{},
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    text_len: usize = 0,
    glyph_count: usize = 0,
    fingerprint: u64 = 0,
};

pub const TextLayoutPlan = struct {
    key: TextLayoutKey = .{},
    layout: TextLayout = .{},

    pub fn lineCount(self: TextLayoutPlan) usize {
        return self.layout.lineCount();
    }

    pub fn cachePlan(self: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_text_layout_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        var planner = TextLayoutCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index, retention_frames);
    }
};

pub const TextLayoutPlanSet = struct {
    plans: []const TextLayoutPlan = &.{},

    pub fn planCount(self: TextLayoutPlanSet) usize {
        return self.plans.len;
    }

    pub fn lineCount(self: TextLayoutPlanSet) usize {
        var count: usize = 0;
        for (self.plans) |plan| count += plan.lineCount();
        return count;
    }

    pub fn cachePlan(self: TextLayoutPlanSet, previous: []const TextLayoutCacheEntry, frame_index: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_text_layout_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: TextLayoutPlanSet, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        var planner = TextLayoutCachePlanner.init(entries, actions);
        return planner.buildMany(self.plans, previous, frame_index, retention_frames);
    }
};

pub const TextLayoutCacheEntry = struct {
    key: TextLayoutKey,
    line_count: usize = 0,
    bounds: ?geometry.RectF = null,
    last_used_frame: u64 = 0,
};

pub const TextLayoutCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const TextLayoutCacheAction = struct {
    kind: TextLayoutCacheActionKind,
    key: TextLayoutKey,
    layout_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const TextLayoutCachePlan = struct {
    entries: []const TextLayoutCacheEntry = &.{},
    actions: []const TextLayoutCacheAction = &.{},

    pub fn entryCount(self: TextLayoutCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: TextLayoutCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: TextLayoutCachePlan, kind: TextLayoutCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn init(start: usize, end: usize) TextRange {
        return .{ .start = start, .end = end };
    }

    pub fn normalized(self: TextRange, text_len: usize) TextRange {
        const start = @min(self.start, text_len);
        const end = @min(self.end, text_len);
        return if (start <= end)
            .{ .start = start, .end = end }
        else
            .{ .start = end, .end = start };
    }

    pub fn byteLen(self: TextRange, text_len: usize) usize {
        const range = self.normalized(text_len);
        return range.end - range.start;
    }

    pub fn isCollapsed(self: TextRange, text_len: usize) bool {
        const range = self.normalized(text_len);
        return range.start == range.end;
    }
};

pub const TextSelectionRect = struct {
    range: TextRange = .{},
    rect: geometry.RectF = .{},
};

pub const TextSelection = struct {
    anchor: usize = 0,
    focus: usize = 0,

    pub fn collapsed(offset: usize) TextSelection {
        return .{ .anchor = offset, .focus = offset };
    }

    pub fn range(self: TextSelection, text_len: usize) TextRange {
        return TextRange.init(self.anchor, self.focus).normalized(text_len);
    }

    pub fn isCollapsed(self: TextSelection, text_len: usize) bool {
        return self.range(text_len).isCollapsed(text_len);
    }
};

pub const TextCaretDirection = enum {
    previous,
    next,
    start,
    end,
};

pub const TextCaretMove = struct {
    direction: TextCaretDirection,
    extend: bool = false,
};

pub const TextCompositionUpdate = struct {
    text: []const u8 = "",
    cursor: ?usize = null,
};

pub const TextInputEvent = union(enum) {
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    move_caret: TextCaretMove,
    set_selection: TextSelection,
    set_composition: TextCompositionUpdate,
    commit_composition,
    cancel_composition,
};

pub const TextEditState = struct {
    text: []const u8 = "",
    selection: TextSelection = .{},
    composition: ?TextRange = null,

    pub fn init(text: []const u8) TextEditState {
        return .{
            .text = text,
            .selection = TextSelection.collapsed(text.len),
        };
    }

    pub fn apply(self: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
        return applyTextInputEvent(self, event, output);
    }
};

pub const Shadow = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color,
};

pub const Blur = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: f32 = 0,
};

pub const CanvasCommand = union(enum) {
    push_clip: Clip,
    pop_clip,
    push_opacity: f32,
    pop_opacity,
    transform: Affine,
    fill_rect: FillRect,
    stroke_rect: StrokeRect,
    fill_rounded_rect: FillRoundedRect,
    draw_line: Line,
    fill_path: FillPath,
    stroke_path: StrokePath,
    draw_image: DrawImage,
    draw_text: DrawText,
    shadow: Shadow,
    blur: Blur,

    pub fn objectId(self: CanvasCommand) ?ObjectId {
        const id = switch (self) {
            .push_clip => |value| value.id,
            .fill_rect => |value| value.id,
            .stroke_rect => |value| value.id,
            .fill_rounded_rect => |value| value.id,
            .draw_line => |value| value.id,
            .fill_path => |value| value.id,
            .stroke_path => |value| value.id,
            .draw_image => |value| value.id,
            .draw_text => |value| value.id,
            .shadow => |value| value.id,
            .blur => |value| value.id,
            .pop_clip, .push_opacity, .pop_opacity, .transform => 0,
        };
        return if (id == 0) null else id;
    }

    pub fn bounds(self: CanvasCommand) ?geometry.RectF {
        return switch (self) {
            .push_clip => |value| value.rect.normalized(),
            .pop_clip, .push_opacity, .pop_opacity, .transform => null,
            .fill_rect => |value| value.rect.normalized(),
            .stroke_rect => |value| strokeBounds(value.rect, value.stroke.width),
            .fill_rounded_rect => |value| value.rect.normalized(),
            .draw_line => |value| strokeBounds(geometry.RectF.fromPoints(value.from, value.to), value.stroke.width),
            .fill_path => |value| pathBounds(value.elements),
            .stroke_path => |value| if (pathBounds(value.elements)) |rect| strokeBounds(rect, value.stroke.width) else null,
            .draw_image => |value| value.dst.normalized(),
            .draw_text => |value| textBounds(value),
            .shadow => |value| shadowBounds(value),
            .blur => |value| value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
        };
    }
};

pub const CommandRef = struct {
    index: usize,
    command: CanvasCommand,
};

pub const DiffKind = enum {
    added,
    removed,
    changed,
    scene_changed,
};

pub const DiffChange = struct {
    kind: DiffKind,
    id: ?ObjectId = null,
    previous_index: ?usize = null,
    next_index: ?usize = null,
    dirty_bounds: ?geometry.RectF = null,
};

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
        var planner = RenderImagePlanner.init(output);
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
    max_text_layouts: usize = 0,
    max_text_layout_lines: usize = 0,
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
            .text_layouts_over = budgetExceeded(self.max_text_layouts, diagnostics.text_layout_count),
            .text_layout_lines_over = budgetExceeded(self.max_text_layout_lines, diagnostics.text_layout_line_count),
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
    text_layouts_over: bool = false,
    text_layout_lines_over: bool = false,
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
        if (self.text_layouts_over) count += 1;
        if (self.text_layout_lines_over) count += 1;
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
            ",\"imageCount\":{d},\"imageUploadCount\":{d},\"imageRetainCount\":{d},\"imageEvictCount\":{d},\"resourceCount\":{d},\"resourceUploadCount\":{d},\"resourceRetainCount\":{d},\"resourceEvictCount\":{d},\"visualEffectCount\":{d},\"visualEffectShadowCount\":{d},\"visualEffectBlurCount\":{d},\"visualEffectUploadCount\":{d},\"visualEffectRetainCount\":{d},\"visualEffectEvictCount\":{d},\"glyphAtlasEntryCount\":{d},\"glyphAtlasUploadCount\":{d},\"glyphAtlasRetainCount\":{d},\"glyphAtlasEvictCount\":{d},\"textLayoutCount\":{d},\"textLayoutLineCount\":{d},\"textLayoutUploadCount\":{d},\"textLayoutRetainCount\":{d},\"textLayoutEvictCount\":{d},\"changeCount\":{d},\"budgetExceededCount\":{d}",
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
                self.change_count,
                self.budget_status.exceededCount(),
            },
        );
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

fn budgetExceeded(limit: usize, value: usize) bool {
    return limit > 0 and value > limit;
}

fn canvasFrameProfile(frame: CanvasFrame) CanvasFrameProfile {
    const diagnostics = frame.diagnosticsWithoutBudgetStatus();
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

pub const CanvasRenderPassLoadAction = enum {
    skip,
    load,
    clear,
};

pub const RenderEncoderBeginPass = struct {
    load_action: CanvasRenderPassLoadAction = .skip,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    dirty_bounds: ?geometry.RectF = null,
};

pub const RenderEncoderCommand = union(enum) {
    begin_pass: RenderEncoderBeginPass,
    set_scissor: geometry.RectF,
    pipeline_cache: RenderPipelineCacheAction,
    path_geometry_cache: RenderPathGeometryCacheAction,
    image_cache: RenderImageCacheAction,
    layer_cache: RenderLayerCacheAction,
    resource_cache: RenderResourceCacheAction,
    visual_effect_cache: VisualEffectCacheAction,
    glyph_atlas_cache: GlyphAtlasCacheAction,
    text_layout_cache: TextLayoutCacheAction,
    bind_pipeline: RenderPipelineKind,
    draw_batch: RenderBatch,
    end_pass,
};

pub const RenderEncoderPlan = struct {
    commands: []const RenderEncoderCommand = &.{},

    pub fn commandCount(self: RenderEncoderPlan) usize {
        return self.commands.len;
    }

    pub fn cacheActionCount(self: RenderEncoderPlan) usize {
        var count: usize = 0;
        for (self.commands) |command| {
            switch (command) {
                .pipeline_cache, .path_geometry_cache, .image_cache, .layer_cache, .resource_cache, .visual_effect_cache, .glyph_atlas_cache, .text_layout_cache => count += 1,
                else => {},
            }
        }
        return count;
    }

    pub fn bindPipelineCount(self: RenderEncoderPlan) usize {
        var count: usize = 0;
        for (self.commands) |command| {
            switch (command) {
                .bind_pipeline => count += 1,
                else => {},
            }
        }
        return count;
    }

    pub fn drawBatchCount(self: RenderEncoderPlan) usize {
        var count: usize = 0;
        for (self.commands) |command| {
            switch (command) {
                .draw_batch => count += 1,
                else => {},
            }
        }
        return count;
    }
};

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
        try writeCanvasRenderPassJson(self, writer);
    }

    pub fn encoderPlan(self: CanvasRenderPass, output: []RenderEncoderCommand) Error!RenderEncoderPlan {
        var planner = RenderEncoderPlanner.init(output);
        return planner.build(self);
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
};

pub const ReferenceImage = struct {
    id: ImageId,
    width: usize,
    height: usize,
    pixels: []const u8,
};

pub const ReferenceRenderSurface = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    scratch: ?[]u8 = null,
    images: []const ReferenceImage = &.{},

    pub fn init(width: usize, height: usize, pixels: []u8) Error!ReferenceRenderSurface {
        const len = std.math.mul(usize, std.math.mul(usize, width, height) catch return error.ReferenceRenderSurfaceTooSmall, 4) catch return error.ReferenceRenderSurfaceTooSmall;
        if (pixels.len < len) return error.ReferenceRenderSurfaceTooSmall;
        return .{
            .width = width,
            .height = height,
            .pixels = pixels[0..len],
        };
    }

    pub fn initWithScratch(width: usize, height: usize, pixels: []u8, scratch: []u8) Error!ReferenceRenderSurface {
        var surface = try init(width, height, pixels);
        if (scratch.len < surface.pixels.len) return error.ReferenceRenderSurfaceTooSmall;
        surface.scratch = scratch[0..surface.pixels.len];
        return surface;
    }

    pub fn withImages(self: ReferenceRenderSurface, images: []const ReferenceImage) ReferenceRenderSurface {
        var next = self;
        next.images = images;
        return next;
    }

    pub fn clear(self: ReferenceRenderSurface, color: Color) void {
        const pixel = colorToRgba8(color);
        var index: usize = 0;
        while (index < self.pixels.len) : (index += 4) {
            self.pixels[index + 0] = pixel[0];
            self.pixels[index + 1] = pixel[1];
            self.pixels[index + 2] = pixel[2];
            self.pixels[index + 3] = pixel[3];
        }
    }

    pub fn renderPass(self: ReferenceRenderSurface, pass: CanvasRenderPass, clear_color: Color) Error!void {
        switch (pass.loadAction()) {
            .skip => return,
            .clear => self.clear(clear_color),
            .load => {},
        }
        const scale = referencePassScale(pass.scale);
        const scissor = if (pass.scissorBounds()) |bounds| referenceScaleRect(bounds, scale) else null;
        for (pass.commands) |command| try self.renderCommand(referenceScaleCommand(command, scale), scissor);
    }

    pub fn pixelRgba8(self: ReferenceRenderSurface, x: usize, y: usize) [4]u8 {
        if (x >= self.width or y >= self.height) return .{ 0, 0, 0, 0 };
        const index = (y * self.width + x) * 4;
        return .{
            self.pixels[index + 0],
            self.pixels[index + 1],
            self.pixels[index + 2],
            self.pixels[index + 3],
        };
    }

    fn renderCommand(self: ReferenceRenderSurface, command: RenderCommand, scissor: ?geometry.RectF) Error!void {
        const draw_bounds = referenceCommandBounds(command, scissor) orelse return;
        switch (command.command) {
            .fill_rect => |value| try self.fillRect(command, value, draw_bounds),
            .fill_rounded_rect => |value| try self.fillRoundedRect(command, value, draw_bounds),
            .stroke_rect => |value| try self.strokeRect(command, value, draw_bounds),
            .draw_line => |value| try self.drawLine(command, value, draw_bounds),
            .fill_path => |value| try self.fillPath(command, value, draw_bounds),
            .stroke_path => |value| try self.strokePath(command, value, draw_bounds),
            .draw_image => |value| try self.drawImage(command, value, draw_bounds),
            .shadow => |value| try self.drawShadow(command, value, draw_bounds),
            .blur => |value| try self.drawBlur(command, value, draw_bounds),
            .draw_text => |value| try self.drawText(command, value, draw_bounds),
            else => return error.ReferenceRenderUnsupportedCommand,
        }
    }

    fn fillRect(self: ReferenceRenderSurface, command: RenderCommand, value: FillRect, draw_bounds: geometry.RectF) Error!void {
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), command.opacity);
            }
        }
    }

    fn fillRoundedRect(self: ReferenceRenderSurface, command: RenderCommand, value: FillRoundedRect, draw_bounds: geometry.RectF) Error!void {
        const rect = command.transform.transformRect(value.rect).normalized();
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        const radius = referenceScaleRadius(value.radius, command.transform);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (referencePointInRoundedRect(point, rect, radius)) self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), command.opacity);
            }
        }
    }

    fn strokeRect(self: ReferenceRenderSurface, command: RenderCommand, value: StrokeRect, draw_bounds: geometry.RectF) Error!void {
        const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
        if (stroke_width <= 0) return;
        const half_width = stroke_width * 0.5;
        const rect = command.transform.transformRect(value.rect).normalized();
        const outer = rect.inflate(geometry.InsetsF.all(half_width));
        const inner = rect.deflate(geometry.InsetsF.all(@min(half_width, @min(rect.width, rect.height) * 0.5)));
        const radius = referenceScaleRadius(value.radius, command.transform);
        const outer_radius = referenceOutsetRadius(radius, half_width);
        const inner_radius = referenceInsetRadius(radius, half_width);
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (referencePointInRoundedRect(point, outer, outer_radius) and !referencePointInRoundedRect(point, inner, inner_radius)) {
                    self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.stroke.fill, command.transform, point), command.opacity);
                }
            }
        }
    }

    fn drawLine(self: ReferenceRenderSurface, command: RenderCommand, value: Line, draw_bounds: geometry.RectF) Error!void {
        const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
        if (stroke_width <= 0) return;
        const half_width = stroke_width * 0.5;
        const from = command.transform.transformPoint(value.from);
        const to = command.transform.transformPoint(value.to);
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (referenceDistanceToSegment(point, from, to) <= half_width) {
                    self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.stroke.fill, command.transform, point), command.opacity);
                }
            }
        }
    }

    fn fillPath(self: ReferenceRenderSurface, command: RenderCommand, value: FillPath, draw_bounds: geometry.RectF) Error!void {
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (referencePathContainsPoint(point, value.elements, command.transform)) {
                    self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), command.opacity);
                }
            }
        }
    }

    fn strokePath(self: ReferenceRenderSurface, command: RenderCommand, value: StrokePath, draw_bounds: geometry.RectF) Error!void {
        const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
        if (stroke_width <= 0) return;
        const half_width = stroke_width * 0.5;
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (referenceDistanceToPath(point, value.elements, command.transform)) |distance| {
                    if (distance <= half_width) self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.stroke.fill, command.transform, point), command.opacity);
                }
            }
        }
    }

    fn drawImage(self: ReferenceRenderSurface, command: RenderCommand, value: DrawImage, draw_bounds: geometry.RectF) Error!void {
        const image = self.findImage(value.image_id) orelse return error.ReferenceRenderUnsupportedCommand;
        if (referenceImagePixelLen(image.width, image.height)) |image_len| {
            if (image.pixels.len < image_len) return error.ReferenceRenderUnsupportedCommand;
        } else return error.ReferenceRenderUnsupportedCommand;

        const src_rect = referenceImageSourceRect(image, value.src) orelse return;
        const local_dst = referenceImageDestinationRect(value.dst, src_rect, value.fit) orelse return;
        const dst_rect = command.transform.transformRect(local_dst).normalized();
        const clipped = geometry.RectF.intersection(dst_rect, draw_bounds.normalized());
        const pixel_rect = referencePixelRect(clipped, self.width, self.height) orelse return;
        const image_opacity = std.math.clamp(value.opacity, 0, 1);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (!dst_rect.containsPoint(point)) continue;
                const u = std.math.clamp((point.x - dst_rect.x) / dst_rect.width, 0, 1);
                const v = std.math.clamp((point.y - dst_rect.y) / dst_rect.height, 0, 1);
                const sample = referenceSampleImage(image, src_rect, u, v, value.sampling);
                const index = (y * self.width + x) * 4;
                const dst = [4]u8{
                    self.pixels[index + 0],
                    self.pixels[index + 1],
                    self.pixels[index + 2],
                    self.pixels[index + 3],
                };
                const out = blendRgba8(dst, rgba8ToColor(sample), command.opacity * image_opacity);
                self.pixels[index + 0] = out[0];
                self.pixels[index + 1] = out[1];
                self.pixels[index + 2] = out[2];
                self.pixels[index + 3] = out[3];
            }
        }
    }

    fn drawShadow(self: ReferenceRenderSurface, command: RenderCommand, value: Shadow, draw_bounds: geometry.RectF) Error!void {
        const scale = referenceTransformScale(command.transform);
        const blur_radius = nonNegative(value.blur) * scale;
        const shadow_rect = command.transform.transformRect(referenceSpreadRect(value.rect.normalized().translate(value.offset), value.spread)).normalized();
        if (shadow_rect.isEmpty()) return;
        const shadow_radius = referenceScaleRadius(referenceSpreadRadius(value.radius, value.spread), command.transform);
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;

        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                const distance = referenceDistanceToRoundedRect(point, shadow_rect, shadow_radius);
                const alpha = referenceShadowFalloff(distance, blur_radius);
                if (alpha > 0) self.blendPixel(@intCast(x), @intCast(y), referenceScaleColorAlpha(value.color, alpha), command.opacity);
            }
        }
    }

    fn drawBlur(self: ReferenceRenderSurface, command: RenderCommand, value: Blur, draw_bounds: geometry.RectF) Error!void {
        const scratch = self.scratch orelse return error.ReferenceRenderUnsupportedCommand;
        const radius = nonNegative(value.radius) * referenceTransformScale(command.transform);
        if (radius <= 0) return;

        @memcpy(scratch[0..self.pixels.len], self.pixels);
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        const kernel_radius: i64 = @intCast(@max(1, referenceCeil(radius)));
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const x_i: i64 = @intCast(x);
                const y_i: i64 = @intCast(y);
                const blurred = referenceBlurSample(scratch, self.width, self.height, x_i, y_i, kernel_radius, radius);
                const index = (y * self.width + x) * 4;
                const dst = [4]u8{
                    self.pixels[index + 0],
                    self.pixels[index + 1],
                    self.pixels[index + 2],
                    self.pixels[index + 3],
                };
                const out = referenceMixRgba8(dst, blurred, command.opacity);
                self.pixels[index + 0] = out[0];
                self.pixels[index + 1] = out[1];
                self.pixels[index + 2] = out[2];
                self.pixels[index + 3] = out[3];
            }
        }
    }

    fn drawText(self: ReferenceRenderSurface, command: RenderCommand, value: DrawText, draw_bounds: geometry.RectF) Error!void {
        if (value.size <= 0) return;

        if (value.text_layout) |options| {
            if (self.drawTextLayout(command, value, draw_bounds, options)) {
                return;
            } else |err| switch (err) {
                error.TextLayoutLineListFull => {},
                else => return err,
            }
        }

        const line_height = value.size * 1.25;
        const baseline = value.origin.y;
        try self.drawTextLine(command, value, draw_bounds, .{
            .text_start = 0,
            .text_len = value.text.len,
            .glyph_start = 0,
            .glyph_len = value.glyphs.len,
            .bounds = textLineBounds(value, 0, value.text.len, 0, value.glyphs.len, baseline, line_height),
            .baseline = baseline,
        });
    }

    fn drawTextLayout(self: ReferenceRenderSurface, command: RenderCommand, value: DrawText, draw_bounds: geometry.RectF, options: TextLayoutOptions) Error!void {
        var lines: [max_reference_text_layout_lines]TextLine = undefined;
        const layout = try layoutTextRun(value, options, &lines);
        for (layout.lines) |line| {
            try self.drawTextLine(command, value, draw_bounds, line);
        }
    }

    fn drawTextLine(self: ReferenceRenderSurface, command: RenderCommand, value: DrawText, draw_bounds: geometry.RectF, line: TextLine) Error!void {
        if (line.glyph_len > 0 and line.glyph_start < value.glyphs.len) {
            const glyph_end = @min(value.glyphs.len, line.glyph_start + line.glyph_len);
            const raw_bounds = textLineBounds(value, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
            const first_x = value.glyphs[line.glyph_start].x;
            const dx = line.bounds.x - raw_bounds.x;
            for (value.glyphs[line.glyph_start..glyph_end]) |glyph| {
                const width = estimatedGlyphAdvance(glyph, value.size);
                const glyph_rect = geometry.RectF.init(value.origin.x + glyph.x - first_x + dx, line.baseline + glyph.y - value.size, width, value.size);
                self.fillTextRect(command.transform.transformRect(glyph_rect).normalized(), draw_bounds, value.color, command.opacity);
            }
            return;
        }

        const end = @min(value.text.len, line.text_start + line.text_len);
        const advance = value.size * 0.5;
        var text_offset: usize = line.text_start;
        var scalar_index: usize = 0;
        while (text_offset < end) {
            const next_offset = nextTextOffset(value.text, text_offset);
            defer {
                text_offset = next_offset;
                scalar_index += 1;
            }
            if (isReferenceTextSpace(value.text[text_offset])) continue;
            const x = line.bounds.x + @as(f32, @floatFromInt(scalar_index)) * advance;
            const glyph_rect = geometry.RectF.init(x, line.baseline - value.size, advance, value.size);
            self.fillTextRect(command.transform.transformRect(glyph_rect).normalized(), draw_bounds, value.color, command.opacity);
        }
    }

    fn fillTextRect(self: ReferenceRenderSurface, rect: geometry.RectF, draw_bounds: geometry.RectF, color: Color, opacity: f32) void {
        const clipped = geometry.RectF.intersection(rect, draw_bounds.normalized());
        const pixel_rect = referencePixelRect(clipped, self.width, self.height) orelse return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                self.blendPixel(@intCast(x), @intCast(y), color, opacity);
            }
        }
    }

    fn blendPixel(self: ReferenceRenderSurface, x: usize, y: usize, color: Color, opacity: f32) void {
        const index = (y * self.width + x) * 4;
        const dst = [4]u8{
            self.pixels[index + 0],
            self.pixels[index + 1],
            self.pixels[index + 2],
            self.pixels[index + 3],
        };
        const out = blendRgba8(dst, color, opacity);
        self.pixels[index + 0] = out[0];
        self.pixels[index + 1] = out[1];
        self.pixels[index + 2] = out[2];
        self.pixels[index + 3] = out[3];
    }

    fn findImage(self: ReferenceRenderSurface, id: ImageId) ?ReferenceImage {
        for (self.images) |image| {
            if (image.id == id) return image;
        }
        return null;
    }
};

fn referenceBlurSample(source: []const u8, width: usize, height: usize, x: i64, y: i64, kernel_radius: i64, radius: f32) [4]u8 {
    const width_i: i64 = @intCast(width);
    const height_i: i64 = @intCast(height);
    var premultiplied = [_]f32{0} ** 3;
    var alpha_total: f32 = 0;
    var weight_total: f32 = 0;

    var dy: i64 = -kernel_radius;
    while (dy <= kernel_radius) : (dy += 1) {
        const sample_y = y + dy;
        if (sample_y < 0 or sample_y >= height_i) continue;

        var dx: i64 = -kernel_radius;
        while (dx <= kernel_radius) : (dx += 1) {
            const sample_x = x + dx;
            if (sample_x < 0 or sample_x >= width_i) continue;

            const weight = referenceBlurWeight(dx, dy, radius);
            const sample_index = (@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))) * 4;
            const alpha = @as(f32, @floatFromInt(source[sample_index + 3])) / 255.0;
            premultiplied[0] += (@as(f32, @floatFromInt(source[sample_index + 0])) / 255.0) * alpha * weight;
            premultiplied[1] += (@as(f32, @floatFromInt(source[sample_index + 1])) / 255.0) * alpha * weight;
            premultiplied[2] += (@as(f32, @floatFromInt(source[sample_index + 2])) / 255.0) * alpha * weight;
            alpha_total += alpha * weight;
            weight_total += weight;
        }
    }

    if (weight_total <= 0) return .{ 0, 0, 0, 0 };
    const alpha = alpha_total / weight_total;
    if (alpha <= 0) return .{ 0, 0, 0, 0 };
    const unpremultiply = 1 / (weight_total * alpha);
    return .{
        colorChannelToByte(premultiplied[0] * unpremultiply),
        colorChannelToByte(premultiplied[1] * unpremultiply),
        colorChannelToByte(premultiplied[2] * unpremultiply),
        colorChannelToByte(alpha),
    };
}

fn referenceMixRgba8(a: [4]u8, b: [4]u8, t: f32) [4]u8 {
    const value = std.math.clamp(t, 0, 1);
    return .{
        referenceMixByte(a[0], b[0], value),
        referenceMixByte(a[1], b[1], value),
        referenceMixByte(a[2], b[2], value),
        referenceMixByte(a[3], b[3], value),
    };
}

fn referenceMixByte(a: u8, b: u8, t: f32) u8 {
    const start = @as(f32, @floatFromInt(a));
    const end = @as(f32, @floatFromInt(b));
    return @intFromFloat(@round(start + (end - start) * t));
}

fn referenceBlurWeight(dx: i64, dy: i64, radius: f32) f32 {
    const sigma = @max(radius, 0.5);
    const x = @as(f32, @floatFromInt(dx));
    const y = @as(f32, @floatFromInt(dy));
    return @exp(-(x * x + y * y) / (2 * sigma * sigma));
}

pub const Density = enum {
    compact,
    regular,
    spacious,
};

pub const Easing = enum {
    linear,
    standard,
    emphasized,
    spring,
};

pub const ColorScheme = enum {
    light,
    dark,
};

pub const ColorContrast = enum {
    standard,
    high,
};

pub const ThemeOptions = struct {
    color_scheme: ColorScheme = .light,
    contrast: ColorContrast = .standard,
    density: Density = .regular,
    reduce_motion: bool = false,
};

pub const ColorTokens = struct {
    background: Color = Color.rgb8(255, 255, 255),
    surface: Color = Color.rgb8(255, 255, 255),
    surface_subtle: Color = Color.rgb8(248, 250, 252),
    surface_pressed: Color = Color.rgb8(241, 245, 249),
    text: Color = Color.rgb8(15, 23, 42),
    text_muted: Color = Color.rgb8(100, 116, 139),
    border: Color = Color.rgba8(15, 23, 42, 28),
    accent: Color = Color.rgb8(24, 24, 27),
    accent_text: Color = Color.rgb8(255, 255, 255),
    focus_ring: Color = Color.rgb8(37, 99, 235),
    shadow: Color = Color.rgba8(15, 23, 42, 38),
    disabled: Color = Color.rgb8(226, 232, 240),

    pub fn theme(color_scheme: ColorScheme, contrast: ColorContrast) ColorTokens {
        return switch (color_scheme) {
            .light => switch (contrast) {
                .standard => light(),
                .high => highContrastLight(),
            },
            .dark => switch (contrast) {
                .standard => dark(),
                .high => highContrastDark(),
            },
        };
    }

    pub fn light() ColorTokens {
        return .{};
    }

    pub fn dark() ColorTokens {
        return .{
            .background = Color.rgb8(9, 11, 17),
            .surface = Color.rgb8(17, 24, 39),
            .surface_subtle = Color.rgb8(30, 41, 59),
            .surface_pressed = Color.rgb8(51, 65, 85),
            .text = Color.rgb8(248, 250, 252),
            .text_muted = Color.rgb8(148, 163, 184),
            .border = Color.rgba8(226, 232, 240, 42),
            .accent = Color.rgb8(244, 244, 245),
            .accent_text = Color.rgb8(9, 9, 11),
            .focus_ring = Color.rgb8(96, 165, 250),
            .shadow = Color.rgba8(0, 0, 0, 110),
            .disabled = Color.rgb8(51, 65, 85),
        };
    }

    pub fn highContrastLight() ColorTokens {
        return .{
            .background = Color.rgb8(255, 255, 255),
            .surface = Color.rgb8(255, 255, 255),
            .surface_subtle = Color.rgb8(243, 244, 246),
            .surface_pressed = Color.rgb8(229, 231, 235),
            .text = Color.rgb8(0, 0, 0),
            .text_muted = Color.rgb8(55, 65, 81),
            .border = Color.rgba8(0, 0, 0, 180),
            .accent = Color.rgb8(0, 0, 0),
            .accent_text = Color.rgb8(255, 255, 255),
            .focus_ring = Color.rgb8(0, 84, 197),
            .shadow = Color.rgba8(0, 0, 0, 96),
            .disabled = Color.rgb8(156, 163, 175),
        };
    }

    pub fn highContrastDark() ColorTokens {
        return .{
            .background = Color.rgb8(0, 0, 0),
            .surface = Color.rgb8(10, 10, 10),
            .surface_subtle = Color.rgb8(23, 23, 23),
            .surface_pressed = Color.rgb8(38, 38, 38),
            .text = Color.rgb8(255, 255, 255),
            .text_muted = Color.rgb8(229, 231, 235),
            .border = Color.rgba8(255, 255, 255, 190),
            .accent = Color.rgb8(255, 255, 255),
            .accent_text = Color.rgb8(0, 0, 0),
            .focus_ring = Color.rgb8(147, 197, 253),
            .shadow = Color.rgba8(0, 0, 0, 180),
            .disabled = Color.rgb8(82, 82, 82),
        };
    }
};

pub const TypographyTokens = struct {
    font_id: FontId = 0,
    body_size: f32 = 14,
    label_size: f32 = 12,
    title_size: f32 = 20,
    button_size: f32 = 14,
};

pub const SpacingTokens = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
};

pub const RadiusTokens = struct {
    sm: f32 = 4,
    md: f32 = 6,
    lg: f32 = 8,
    xl: f32 = 12,
};

pub const StrokeTokens = struct {
    hairline: f32 = 1,
    regular: f32 = 1,
    focus: f32 = 2,
};

pub const ShadowToken = struct {
    y: f32 = 8,
    blur: f32 = 24,
    spread: f32 = -10,
};

pub const ShadowTokens = struct {
    none: ShadowToken = .{ .y = 0, .blur = 0, .spread = 0 },
    sm: ShadowToken = .{ .y = 6, .blur = 16, .spread = -8 },
    md: ShadowToken = .{ .y = 14, .blur = 36, .spread = -16 },
};

pub const BlurTokens = struct {
    none: f32 = 0,
    sm: f32 = 8,
    md: f32 = 16,
};

pub const MotionDuration = enum {
    fast,
    normal,
    slow,
};

pub const MotionAnimationOptions = struct {
    id: ObjectId,
    start_ns: u64 = 0,
    duration: MotionDuration = .normal,
    easing: ?Easing = null,
    spring: ?SpringToken = null,
    from_opacity: ?f32 = null,
    to_opacity: ?f32 = null,
    from_transform: ?Affine = null,
    to_transform: ?Affine = null,
};

pub const MotionTokens = struct {
    fast_ms: u32 = 120,
    normal_ms: u32 = 180,
    slow_ms: u32 = 260,
    easing: Easing = .standard,
    spring: SpringToken = .{},

    pub fn reduced() MotionTokens {
        return .{
            .fast_ms = 0,
            .normal_ms = 0,
            .slow_ms = 0,
            .easing = .linear,
        };
    }

    pub fn durationMs(self: MotionTokens, duration: MotionDuration) u32 {
        return switch (duration) {
            .fast => self.fast_ms,
            .normal => self.normal_ms,
            .slow => self.slow_ms,
        };
    }

    pub fn animation(self: MotionTokens, options: MotionAnimationOptions) CanvasRenderAnimation {
        return .{
            .id = options.id,
            .start_ns = options.start_ns,
            .duration_ms = self.durationMs(options.duration),
            .easing = options.easing orelse self.easing,
            .spring = options.spring orelse self.spring,
            .from_opacity = options.from_opacity,
            .to_opacity = options.to_opacity,
            .from_transform = options.from_transform,
            .to_transform = options.to_transform,
        };
    }
};

pub const SpringToken = struct {
    mass: f32 = 1,
    stiffness: f32 = 220,
    damping: f32 = 28,
};

pub const ScrollPhysics = struct {
    wheel_multiplier: f32 = 1,
    wheel_velocity_scale: f32 = 60,
    deceleration_per_second: f32 = 0.86,
    stop_velocity: f32 = 5,
};

pub const ScrollState = struct {
    offset: f32 = 0,
    velocity: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,

    pub fn maxOffset(self: ScrollState) f32 {
        return @max(0, nonNegative(self.content_extent) - nonNegative(self.viewport_extent));
    }

    pub fn clamped(self: ScrollState) ScrollState {
        var next = self;
        const clamped_offset = std.math.clamp(nonNegative(next.offset), 0, next.maxOffset());
        if (clamped_offset != next.offset) next.velocity = 0;
        next.offset = clamped_offset;
        return next;
    }

    pub fn applyWheel(self: ScrollState, delta: f32, physics: ScrollPhysics) ScrollState {
        var next = self;
        const scaled_delta = delta * physics.wheel_multiplier;
        next.offset += scaled_delta;
        next.velocity = scaled_delta * physics.wheel_velocity_scale;
        return next.clamped();
    }

    pub fn stepKinetic(self: ScrollState, dt_ms: f32, physics: ScrollPhysics) ScrollState {
        var next = self.clamped();
        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) {
            next.velocity = 0;
            return next;
        }

        const dt_seconds = nonNegative(dt_ms) / 1000.0;
        next.offset += next.velocity * dt_seconds;
        const decay = std.math.pow(f32, std.math.clamp(physics.deceleration_per_second, 0, 1), dt_seconds);
        next.velocity *= decay;
        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) next.velocity = 0;
        return next.clamped();
    }
};

pub const VirtualListOptions = struct {
    item_count: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    viewport_extent: f32 = 0,
    scroll_offset: f32 = 0,
    overscan: usize = 0,
};

pub const VirtualListRange = struct {
    start_index: usize = 0,
    end_index: usize = 0,
    first_visible_index: usize = 0,
    last_visible_index: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    scroll_offset: f32 = 0,
    content_extent: f32 = 0,
    before_extent: f32 = 0,
    after_extent: f32 = 0,

    pub fn itemCount(self: VirtualListRange) usize {
        return self.end_index - self.start_index;
    }

    pub fn isEmpty(self: VirtualListRange) bool {
        return self.start_index >= self.end_index;
    }
};

pub fn virtualListRange(options: VirtualListOptions) VirtualListRange {
    if (options.item_count == 0 or options.item_extent <= 0 or options.viewport_extent <= 0) return .{};

    const item_extent = nonNegative(options.item_extent);
    const item_gap = nonNegative(options.item_gap);
    const stride = item_extent + item_gap;
    const item_count_f = @as(f32, @floatFromInt(options.item_count));
    const content_extent = item_count_f * item_extent + @max(0, item_count_f - 1) * item_gap;
    const max_offset = @max(0, content_extent - nonNegative(options.viewport_extent));
    const offset = std.math.clamp(nonNegative(options.scroll_offset), 0, max_offset);

    const first_visible = @min(options.item_count - 1, floorVirtualIndex(offset / stride));
    const visible_end = @min(options.item_count, ceilVirtualIndex((offset + nonNegative(options.viewport_extent) + item_gap) / stride));
    const start_index = if (first_visible > options.overscan) first_visible - options.overscan else 0;
    const end_index = @min(options.item_count, visible_end + options.overscan);

    return .{
        .start_index = start_index,
        .end_index = end_index,
        .first_visible_index = first_visible,
        .last_visible_index = if (visible_end > 0) visible_end - 1 else first_visible,
        .item_extent = item_extent,
        .item_gap = item_gap,
        .scroll_offset = offset,
        .content_extent = content_extent,
        .before_extent = @as(f32, @floatFromInt(start_index)) * stride,
        .after_extent = @as(f32, @floatFromInt(options.item_count - end_index)) * stride,
    };
}

pub const LayerTokens = struct {
    base: i32 = 0,
    floating: i32 = 100,
    overlay: i32 = 200,
    modal: i32 = 300,
};

pub const DesignTokens = struct {
    colors: ColorTokens = .{},
    typography: TypographyTokens = .{},
    spacing: SpacingTokens = .{},
    radius: RadiusTokens = .{},
    stroke: StrokeTokens = .{},
    shadow: ShadowTokens = .{},
    blur: BlurTokens = .{},
    motion: MotionTokens = .{},
    scroll: ScrollPhysics = .{},
    layer: LayerTokens = .{},
    density: Density = .regular,

    pub fn theme(options: ThemeOptions) DesignTokens {
        return .{
            .colors = ColorTokens.theme(options.color_scheme, options.contrast),
            .motion = if (options.reduce_motion) MotionTokens.reduced() else .{},
            .density = options.density,
        };
    }
};

pub const WidgetKind = enum {
    stack,
    row,
    column,
    grid,
    data_grid,
    scroll_view,
    list,
    panel,
    popover,
    menu_surface,
    text,
    icon,
    image,
    button,
    icon_button,
    text_field,
    search_field,
    tooltip,
    menu_item,
    list_item,
    data_row,
    data_cell,
    segmented_control,
    checkbox,
    toggle,
    slider,
    progress,
};

pub const WidgetCursor = enum {
    arrow,
    pointing_hand,
    text,
    resize_horizontal,
};

pub const WidgetState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    disabled: bool = false,
    selected: bool = false,
};

pub const WidgetRenderState = struct {
    focused_id: ?ObjectId = null,
    hovered_id: ?ObjectId = null,
    pressed_id: ?ObjectId = null,
};

pub const WidgetMainAlignment = enum {
    start,
    center,
    end,
    space_between,
};

pub const WidgetCrossAlignment = enum {
    stretch,
    start,
    center,
    end,
};

pub const WidgetLayoutStyle = struct {
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    grow: f32 = 0,
    main_alignment: WidgetMainAlignment = .start,
    cross_alignment: WidgetCrossAlignment = .stretch,
    clip_content: bool = false,
    columns: usize = 0,
    virtualized: bool = false,
    virtual_item_extent: f32 = 0,
    virtual_overscan: usize = 0,
    min_size: geometry.SizeF = .{},
};

pub const WidgetRole = enum {
    none,
    group,
    text,
    image,
    button,
    textbox,
    tooltip,
    dialog,
    menu,
    menuitem,
    list,
    listitem,
    row,
    grid,
    gridcell,
    tab,
    checkbox,
    switch_control,
    slider,
    progressbar,
};

pub const WidgetActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,

    pub fn isEmpty(self: WidgetActions) bool {
        return !self.focus and
            !self.press and
            !self.toggle and
            !self.increment and
            !self.decrement and
            !self.set_text and
            !self.set_selection and
            !self.select and
            !self.drag and
            !self.drop_files;
    }
};

pub const WidgetSemantics = struct {
    role: WidgetRole = .none,
    label: []const u8 = "",
    value: ?f32 = null,
    list_item_index: ?u32 = null,
    list_item_count: ?u32 = null,
    actions: WidgetActions = .{},
    hidden: bool = false,
    focusable: bool = false,
};

pub const Widget = struct {
    id: ObjectId = 0,
    kind: WidgetKind,
    frame: geometry.RectF = .{},
    opacity: f32 = 1,
    transform: Affine = .{},
    backdrop_blur: f32 = 0,
    text: []const u8 = "",
    text_alignment: TextAlign = .start,
    command: []const u8 = "",
    image_id: ImageId = 0,
    image_src: ?geometry.RectF = null,
    image_fit: ImageFit = .stretch,
    image_sampling: ImageSampling = .linear,
    image_opacity: f32 = 1,
    text_selection: ?TextSelection = null,
    text_composition: ?TextRange = null,
    value: f32 = 0,
    layer: ?i32 = null,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    semantics: WidgetSemantics = .{},
    children: []const Widget = &.{},
};

pub const max_widget_depth: usize = 32;
pub const max_widget_text_range_rects: usize = 4;
const max_widget_text_layout_lines: usize = 16;

pub const WidgetLayoutNode = struct {
    widget: Widget,
    frame: geometry.RectF,
    depth: usize,
    parent_index: ?usize = null,
};

pub const WidgetHit = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    depth: usize,
    index: usize,
    state: WidgetState,
};

pub const WidgetPointerPhase = enum {
    hover,
    down,
    move,
    up,
    cancel,
    wheel,
};

pub const WidgetPointerEvent = struct {
    phase: WidgetPointerPhase,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
    captured_id: ?ObjectId = null,
};

pub const WidgetKeyboardPhase = enum {
    key_down,
    key_up,
    text_input,
};

pub const WidgetKeyboardModifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn hasCommandModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.super;
    }

    pub fn hasNavigationModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.alt or self.super;
    }
};

pub const WidgetKeyboardEvent = struct {
    phase: WidgetKeyboardPhase,
    focused_id: ?ObjectId = null,
    key: []const u8 = "",
    text: []const u8 = "",
    edit: ?TextInputEvent = null,
    modifiers: WidgetKeyboardModifiers = .{},

    pub fn textEditEvent(self: WidgetKeyboardEvent) ?TextInputEvent {
        if (self.edit) |edit| return edit;
        return widgetKeyboardTextEditEvent(self);
    }
};

pub const WidgetFileDropEvent = struct {
    point: geometry.PointF,
    paths: []const []const u8 = &.{},
};

pub const WidgetDragEvent = struct {
    source_id: ObjectId = 0,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
};

pub const WidgetEventPhase = enum {
    capture,
    target,
    bubble,
};

pub const WidgetEventRouteEntry = struct {
    phase: WidgetEventPhase,
    node_index: usize,
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
};

pub const WidgetEventRoute = struct {
    target: ?WidgetHit = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetKeyboardRoute = struct {
    target: ?WidgetFocusTarget = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetFocusDirection = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
};

pub const WidgetFocusTarget = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    index: usize,
    state: WidgetState,
};

pub const WidgetScrollMetrics = struct {
    present: bool = false,
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
};

pub const WidgetListMetrics = struct {
    present: bool = false,
    item_index: u32 = 0,
    item_count: u32 = 0,
};

pub const WidgetSemanticsNode = struct {
    id: ObjectId,
    role: WidgetRole,
    label: []const u8,
    value: ?f32 = null,
    text_value: []const u8 = "",
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list: WidgetListMetrics = .{},
    scroll: WidgetScrollMetrics = .{},
    bounds: geometry.RectF,
    state: WidgetState,
    focusable: bool = false,
    actions: WidgetActions = .{},
    text_selection: ?TextRange = null,
    text_composition: ?TextRange = null,
    parent_index: ?usize = null,
};

pub const WidgetInvalidationKind = enum {
    added,
    removed,
    changed,
};

pub const WidgetInvalidation = struct {
    kind: WidgetInvalidationKind,
    id: ObjectId,
    previous_index: ?usize = null,
    next_index: ?usize = null,
    dirty_bounds: ?geometry.RectF = null,
    layout_dirty: bool = false,
    paint_dirty: bool = false,
    semantics_dirty: bool = false,
};

pub const WidgetLayoutTree = struct {
    nodes: []const WidgetLayoutNode = &.{},

    pub fn nodeCount(self: WidgetLayoutTree) usize {
        return self.nodes.len;
    }

    pub fn findById(self: WidgetLayoutTree, id: ObjectId) ?WidgetLayoutNode {
        if (id == 0) return null;
        for (self.nodes) |node| {
            if (node.widget.id == id) return node;
        }
        return null;
    }

    pub fn hitTest(self: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
        return hitTestWidgetLayout(self, point, .{});
    }

    pub fn hitTestWithTokens(self: WidgetLayoutTree, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
        return hitTestWidgetLayout(self, point, tokens);
    }

    pub fn cursorForHit(self: WidgetLayoutTree, hit: ?WidgetHit) WidgetCursor {
        _ = self;
        return cursorForWidgetHit(hit);
    }

    pub fn routePointerEvent(self: WidgetLayoutTree, event: WidgetPointerEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetPointerEvent(self, event, .{}, output);
    }

    pub fn routePointerEventWithTokens(self: WidgetLayoutTree, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetPointerEvent(self, event, tokens, output);
    }

    pub fn routeKeyboardEvent(self: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
        return routeWidgetKeyboardEvent(self, event, output);
    }

    pub fn routeFileDropEvent(self: WidgetLayoutTree, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetFileDropEvent(self, event, output);
    }

    pub fn routeDragEvent(self: WidgetLayoutTree, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetDragEvent(self, event, output);
    }

    pub fn focusTarget(self: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
        return focusWidgetTarget(self, current_id, direction);
    }

    pub fn focusTargetById(self: WidgetLayoutTree, id: ObjectId) ?WidgetFocusTarget {
        return focusWidgetTargetById(self, id);
    }

    pub fn collectSemantics(self: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
        return collectWidgetSemantics(self, output);
    }

    pub fn textGeometry(self: WidgetLayoutTree, id: ObjectId, tokens: DesignTokens) ?WidgetTextGeometry {
        const node = self.findById(id) orelse return null;
        return textGeometryForWidget(node.widget, tokens);
    }

    pub fn emitDisplayList(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens) Error!void {
        return emitWidgetLayout(builder, self, tokens);
    }

    pub fn emitDisplayListWithState(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens, state: WidgetRenderState) Error!void {
        return emitWidgetLayoutWithState(builder, self, tokens, state);
    }

    pub fn renderStateDirtyBounds(self: WidgetLayoutTree, previous: WidgetRenderState, next: WidgetRenderState) ?geometry.RectF {
        return widgetRenderStateDirtyBounds(self, previous, next);
    }

    pub fn diff(previous: WidgetLayoutTree, next: WidgetLayoutTree, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
        return diffWidgetLayoutTrees(previous, next, output);
    }
};

pub const DisplayList = struct {
    commands: []const CanvasCommand = &.{},

    pub fn writeJson(self: DisplayList, writer: anytype) !void {
        try writer.writeAll("{\"commands\":[");
        for (self.commands, 0..) |command, index| {
            if (index > 0) try writer.writeByte(',');
            try writeCommandJson(command, writer);
        }
        try writer.writeAll("]}");
    }

    pub fn commandCount(self: DisplayList) usize {
        return self.commands.len;
    }

    pub fn findCommandById(self: DisplayList, id: ObjectId) ?CommandRef {
        if (id == 0) return null;
        for (self.commands, 0..) |command, index| {
            if (command.objectId()) |command_id| {
                if (command_id == id) return .{ .index = index, .command = command };
            }
        }
        return null;
    }

    pub fn bounds(self: DisplayList) ?geometry.RectF {
        var result: ?geometry.RectF = null;
        for (self.commands) |command| {
            if (command.bounds()) |command_bounds| {
                result = unionOptionalBounds(result, command_bounds);
            }
        }
        return result;
    }

    pub fn diff(previous: DisplayList, next: DisplayList, output: []DiffChange) Error![]const DiffChange {
        return diffDisplayLists(previous, next, output);
    }

    pub fn renderPlan(self: DisplayList, output: []RenderCommand) Error!RenderPlan {
        var planner = RenderPlanner.init(output);
        return planner.build(self);
    }

    pub fn resourcePlan(self: DisplayList, output: []RenderResource) Error!RenderResourcePlan {
        var planner = RenderResourcePlanner.init(output);
        return planner.build(self);
    }

    pub fn visualEffectPlan(self: DisplayList, output: []VisualEffect) Error!VisualEffectPlan {
        var planner = VisualEffectPlanner.init(output);
        return planner.build(self);
    }

    pub fn glyphAtlasPlan(self: DisplayList, output: []GlyphAtlasEntry) Error!GlyphAtlasPlan {
        var planner = GlyphAtlasPlanner.init(output);
        return planner.build(self);
    }

    pub fn textLayoutPlan(self: DisplayList, options: TextLayoutOptions, output: []TextLayoutPlan, lines: []TextLine) Error!TextLayoutPlanSet {
        var planner = TextLayoutPlanner.init(output, lines);
        return planner.build(self, options);
    }

    pub fn framePlan(self: DisplayList, previous: ?DisplayList, options: CanvasFrameOptions, storage: CanvasFrameStorage) Error!CanvasFrame {
        return buildCanvasFrame(previous, self, options, storage);
    }
};

pub const Builder = struct {
    commands: []CanvasCommand,
    len: usize = 0,

    pub fn init(commands: []CanvasCommand) Builder {
        return .{ .commands = commands };
    }

    pub fn reset(self: *Builder) void {
        self.len = 0;
    }

    pub fn displayList(self: *const Builder) DisplayList {
        return .{ .commands = self.commands[0..self.len] };
    }

    pub fn append(self: *Builder, command: CanvasCommand) Error!void {
        if (self.len >= self.commands.len) return error.DisplayListFull;
        self.commands[self.len] = command;
        self.len += 1;
    }

    pub fn pushClip(self: *Builder, clip: Clip) Error!void {
        try self.append(.{ .push_clip = clip });
    }

    pub fn popClip(self: *Builder) Error!void {
        try self.append(.pop_clip);
    }

    pub fn pushOpacity(self: *Builder, opacity: f32) Error!void {
        try self.append(.{ .push_opacity = opacity });
    }

    pub fn popOpacity(self: *Builder) Error!void {
        try self.append(.pop_opacity);
    }

    pub fn transform(self: *Builder, value: Affine) Error!void {
        try self.append(.{ .transform = value });
    }

    pub fn fillRect(self: *Builder, value: FillRect) Error!void {
        try self.append(.{ .fill_rect = value });
    }

    pub fn strokeRect(self: *Builder, value: StrokeRect) Error!void {
        try self.append(.{ .stroke_rect = value });
    }

    pub fn fillRoundedRect(self: *Builder, value: FillRoundedRect) Error!void {
        try self.append(.{ .fill_rounded_rect = value });
    }

    pub fn drawLine(self: *Builder, value: Line) Error!void {
        try self.append(.{ .draw_line = value });
    }

    pub fn fillPath(self: *Builder, value: FillPath) Error!void {
        try self.append(.{ .fill_path = value });
    }

    pub fn strokePath(self: *Builder, value: StrokePath) Error!void {
        try self.append(.{ .stroke_path = value });
    }

    pub fn drawImage(self: *Builder, value: DrawImage) Error!void {
        try self.append(.{ .draw_image = value });
    }

    pub fn drawText(self: *Builder, value: DrawText) Error!void {
        try self.append(.{ .draw_text = value });
    }

    pub fn shadow(self: *Builder, value: Shadow) Error!void {
        try self.append(.{ .shadow = value });
    }

    pub fn blur(self: *Builder, value: Blur) Error!void {
        try self.append(.{ .blur = value });
    }
};

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitWidgetDepth(builder, widget, tokens, 0);
}

pub fn layoutWidgetTree(widget: Widget, bounds: geometry.RectF, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    var len: usize = 0;
    _ = try layoutWidgetDepth(widget, bounds.normalized(), null, 0, output, &len);
    return .{ .nodes = output[0..len] };
}

pub fn layoutTextRun(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayout {
    return (try layoutTextRunPlan(text, options, output)).layout;
}

pub fn layoutTextRunPlan(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayoutPlan {
    var len: usize = 0;
    var bounds: ?geometry.RectF = null;
    if (text.glyphs.len > 0) {
        try appendGlyphTextLines(output, &len, text, options, &bounds);
        return .{
            .key = textLayoutKey(text, options),
            .layout = .{ .lines = output[0..len], .bounds = bounds },
        };
    }

    var start: usize = 0;
    while (start < text.text.len) {
        const end = nextTextLineEnd(text.text, start, text.size, options);
        try appendTextLine(output, &len, text, start, end - start, start, end - start, lineHeight(text, options), options, &bounds);
        start = end;
        if (start < text.text.len and text.text[start] == '\n') start += 1;
        while (options.wrap == .word and start < text.text.len and isTextBreakByte(text.text[start])) start += 1;
    }
    if (text.text.len == 0) {
        try appendTextLine(output, &len, text, 0, 0, 0, 0, lineHeight(text, options), options, &bounds);
    }
    return .{
        .key = textLayoutKey(text, options),
        .layout = .{ .lines = output[0..len], .bounds = bounds },
    };
}

pub fn layoutTextCaretRect(text: DrawText, options: TextLayoutOptions, offset: usize, lines: []TextLine) Error!?geometry.RectF {
    const layout = try layoutTextRun(text, options, lines);
    return textCaretRectForLayout(text, layout, offset);
}

pub fn textCaretRectForLayout(text: DrawText, layout: TextLayout, offset: usize) ?geometry.RectF {
    const line = textLineForOffset(layout, text.text.len, snapTextOffset(text.text, offset)) orelse return null;
    const x = textLineCaretX(text, line, offset);
    return geometry.RectF.init(x, line.bounds.y, 1, @max(1, line.bounds.height));
}

pub fn layoutTextSelectionRects(
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    lines: []TextLine,
    output: []TextSelectionRect,
) Error![]const TextSelectionRect {
    const layout = try layoutTextRun(text, options, lines);
    return textSelectionRectsForLayout(text, layout, range, output);
}

pub fn textSelectionRectsForLayout(text: DrawText, layout: TextLayout, range: TextRange, output: []TextSelectionRect) Error![]const TextSelectionRect {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return output[0..0];

    var len: usize = 0;
    for (layout.lines) |line| {
        const line_range = textLineRange(text, line);
        const start = @max(normalized.start, line_range.start);
        const end = @min(normalized.end, line_range.end);
        if (start >= end) continue;
        if (len >= output.len) return error.TextSelectionRectListFull;

        const x0 = textLineCaretX(text, line, start);
        const x1 = textLineCaretX(text, line, end);
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        output[len] = .{
            .range = TextRange.init(start, end),
            .rect = geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
        };
        len += 1;
    }
    return output[0..len];
}

pub fn layoutTextOffsetForPoint(text: DrawText, options: TextLayoutOptions, point: geometry.PointF, lines: []TextLine) Error!?usize {
    const layout = try layoutTextRun(text, options, lines);
    return textOffsetForLayoutPoint(text, layout, point);
}

pub fn textOffsetForLayoutPoint(text: DrawText, layout: TextLayout, point: geometry.PointF) ?usize {
    const line = textLineForPoint(layout, point) orelse return null;
    return textLineOffsetForX(text, line, point.x);
}

pub fn applyTextInputEvent(state: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
    const normalized = normalizeTextEditState(state);
    return switch (event) {
        .insert_text => |text| replaceTextEditRange(normalized, activeTextReplaceRange(normalized), text, output, null, text.len),
        .delete_backward => deleteBackwardTextEdit(normalized, output),
        .delete_forward => deleteForwardTextEdit(normalized, output),
        .move_caret => |move| moveTextCaret(normalized, move),
        .set_selection => |selection| .{
            .text = normalized.text,
            .selection = snapTextSelection(normalized.text, selection),
            .composition = null,
        },
        .set_composition => |composition| setTextComposition(normalized, composition, output),
        .commit_composition => .{
            .text = normalized.text,
            .selection = normalized.selection,
            .composition = null,
        },
        .cancel_composition => cancelTextComposition(normalized, output),
    };
}

pub fn sampleCanvasRenderAnimations(animations: []const CanvasRenderAnimation, timestamp_ns: u64, output: []CanvasRenderOverride) Error![]const CanvasRenderOverride {
    var len: usize = 0;
    for (animations) |animation| {
        if (animation.id == 0) continue;
        const progress = motionProgress(animation, timestamp_ns);
        const opacity = sampleAnimatedF32(animation.from_opacity, animation.to_opacity, progress);
        const transform = sampleAnimatedAffine(animation.from_transform, animation.to_transform, progress);
        if (opacity == null and transform == null) continue;
        if (len >= output.len) return error.RenderOverrideListFull;
        output[len] = .{
            .id = animation.id,
            .opacity = opacity,
            .transform = transform,
        };
        len += 1;
    }
    return output[0..len];
}

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
        try render_plan.imagePlan(storage.images);
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
        .changes = changes,
        .dirty_bounds = dirty_bounds,
        .budget = options.budget,
    };
}

pub fn emitWidgetLayout(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens) Error!void {
    return emitWidgetLayoutWithState(builder, layout, tokens, .{});
}

fn emitWidgetLayoutWithState(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    try emitWidgetLayoutChildren(builder, layout, null, tokens, state);
}

pub const RenderPlanner = struct {
    commands: []RenderCommand,
    len: usize = 0,
    state: RenderState = .{},
    bounds_value: ?geometry.RectF = null,
    clip_stack: [max_render_state_stack]?geometry.RectF = undefined,
    clip_stack_len: usize = 0,
    opacity_stack: [max_render_state_stack]f32 = undefined,
    opacity_stack_len: usize = 0,

    pub fn init(commands: []RenderCommand) RenderPlanner {
        return .{ .commands = commands };
    }

    pub fn reset(self: *RenderPlanner) void {
        self.len = 0;
        self.state = .{};
        self.bounds_value = null;
        self.clip_stack_len = 0;
        self.opacity_stack_len = 0;
    }

    pub fn build(self: *RenderPlanner, display_list: DisplayList) Error!RenderPlan {
        self.reset();
        for (display_list.commands) |command| {
            try self.consume(command);
        }
        return .{
            .commands = self.commands[0..self.len],
            .bounds = self.bounds_value,
        };
    }

    fn consume(self: *RenderPlanner, command: CanvasCommand) Error!void {
        switch (command) {
            .push_clip => |clip| try self.pushClip(clip),
            .pop_clip => try self.popClip(),
            .push_opacity => |opacity| try self.pushOpacity(opacity),
            .pop_opacity => try self.popOpacity(),
            .transform => |transform| self.state.transform = self.state.transform.multiply(transform),
            else => try self.appendDrawCommand(command),
        }
    }

    fn pushClip(self: *RenderPlanner, clip: Clip) Error!void {
        if (self.clip_stack_len >= self.clip_stack.len) return error.RenderStackOverflow;
        self.clip_stack[self.clip_stack_len] = self.state.clip;
        self.clip_stack_len += 1;

        const transformed_clip = self.state.transform.transformRect(clip.rect);
        self.state.clip = if (self.state.clip) |existing|
            geometry.RectF.intersection(existing, transformed_clip)
        else
            transformed_clip;
    }

    fn popClip(self: *RenderPlanner) Error!void {
        if (self.clip_stack_len == 0) return error.RenderStackUnderflow;
        self.clip_stack_len -= 1;
        self.state.clip = self.clip_stack[self.clip_stack_len];
    }

    fn pushOpacity(self: *RenderPlanner, opacity: f32) Error!void {
        if (self.opacity_stack_len >= self.opacity_stack.len) return error.RenderStackOverflow;
        self.opacity_stack[self.opacity_stack_len] = self.state.opacity;
        self.opacity_stack_len += 1;
        self.state.opacity *= std.math.clamp(opacity, 0, 1);
    }

    fn popOpacity(self: *RenderPlanner) Error!void {
        if (self.opacity_stack_len == 0) return error.RenderStackUnderflow;
        self.opacity_stack_len -= 1;
        self.state.opacity = self.opacity_stack[self.opacity_stack_len];
    }

    fn appendDrawCommand(self: *RenderPlanner, command: CanvasCommand) Error!void {
        if (self.state.opacity <= 0) return;
        const command_bounds = command.bounds() orelse return;
        const transformed_bounds = self.state.transform.transformRect(command_bounds);
        const clipped_bounds = if (self.state.clip) |clip|
            geometry.RectF.intersection(clip, transformed_bounds)
        else
            transformed_bounds;
        if (clipped_bounds.isEmpty()) return;
        if (self.len >= self.commands.len) return error.RenderListFull;

        self.commands[self.len] = .{
            .command = command,
            .id = command.objectId(),
            .opacity = self.state.opacity,
            .clip = self.state.clip,
            .transform = self.state.transform,
            .local_bounds = command_bounds,
            .bounds = clipped_bounds,
        };
        self.len += 1;
        self.bounds_value = unionOptionalBounds(self.bounds_value, clipped_bounds);
    }
};

pub const RenderBatchPlanner = struct {
    batches: []RenderBatch,
    len: usize = 0,

    pub fn init(batches: []RenderBatch) RenderBatchPlanner {
        return .{ .batches = batches };
    }

    pub fn reset(self: *RenderBatchPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderBatchPlanner, render_plan: RenderPlan) Error!RenderBatchPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{
            .batches = self.batches[0..self.len],
            .bounds = render_plan.bounds,
        };
    }

    fn consume(self: *RenderBatchPlanner, command: RenderCommand, index: usize) Error!void {
        const pipeline = renderPipelineKind(command.command);
        if (self.len > 0 and renderBatchCanExtend(self.batches[self.len - 1], command, pipeline, index)) {
            const batch = &self.batches[self.len - 1];
            batch.command_count += 1;
            batch.bounds = geometry.RectF.unionWith(batch.bounds.normalized(), command.bounds.normalized());
            return;
        }

        if (self.len >= self.batches.len) return error.RenderBatchListFull;
        self.batches[self.len] = .{
            .pipeline = pipeline,
            .command_start = index,
            .command_count = 1,
            .opacity = command.opacity,
            .clip = command.clip,
            .bounds = command.bounds,
        };
        self.len += 1;
    }
};

pub const RenderPipelineCachePlanner = struct {
    entries: []RenderPipelineCacheEntry,
    actions: []RenderPipelineCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderPipelineCacheEntry, actions: []RenderPipelineCacheAction) RenderPipelineCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderPipelineCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderPipelineCachePlanner, batch_plan: RenderBatchPlan, previous: []const RenderPipelineCacheEntry, frame_index: u64) Error!RenderPipelineCachePlan {
        self.reset();
        for (batch_plan.batches, 0..) |batch, batch_index| {
            if (findRenderPipelineCacheEntry(self.entries[0..self.entry_len], batch.pipeline) != null) continue;

            const previous_index = findRenderPipelineCacheEntry(previous, batch.pipeline);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .pipeline = batch.pipeline,
                .batch_index = batch_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .pipeline = batch.pipeline,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderPipelineCacheEntry(self.entries[0..self.entry_len], entry.pipeline) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .pipeline = entry.pipeline,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderPipelineCachePlanner, entry: RenderPipelineCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.RenderPipelineCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderPipelineCachePlanner, action: RenderPipelineCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.RenderPipelineCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn findRenderPipelineCacheEntry(entries: []const RenderPipelineCacheEntry, pipeline: RenderPipelineKind) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.pipeline == pipeline) return index;
    }
    return null;
}

pub const RenderPathGeometryPlanner = struct {
    geometries: []RenderPathGeometry,
    len: usize = 0,

    pub fn init(geometries: []RenderPathGeometry) RenderPathGeometryPlanner {
        return .{ .geometries = geometries };
    }

    pub fn reset(self: *RenderPathGeometryPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderPathGeometryPlanner, render_plan: RenderPlan) Error!RenderPathGeometryPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .geometries = self.geometries[0..self.len] };
    }

    fn consume(self: *RenderPathGeometryPlanner, command: RenderCommand, index: usize) Error!void {
        switch (command.command) {
            .fill_path => |value| try self.consumePath(.fill, command, index, value.elements, 0),
            .stroke_path => |value| {
                const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
                if (stroke_width <= 0) return;
                try self.consumePath(.stroke, command, index, value.elements, stroke_width);
            },
            else => {},
        }
    }

    fn consumePath(self: *RenderPathGeometryPlanner, kind: RenderPathGeometryKind, command: RenderCommand, index: usize, elements: []const PathElement, stroke_width: f32) Error!void {
        const counts = analyzePathGeometry(elements, kind);
        if (counts.vertex_count == 0 or counts.index_count == 0) return;
        if (self.len >= self.geometries.len) return error.PathGeometryListFull;
        self.geometries[self.len] = .{
            .kind = kind,
            .command_index = index,
            .id = command.id,
            .bounds = command.bounds,
            .element_count = elements.len,
            .contour_count = counts.contour_count,
            .line_segment_count = counts.line_segment_count,
            .quadratic_segment_count = counts.quadratic_segment_count,
            .cubic_segment_count = counts.cubic_segment_count,
            .flattened_segment_count = counts.flattened_segment_count,
            .vertex_count = counts.vertex_count,
            .index_count = counts.index_count,
            .stroke_width = stroke_width,
            .fingerprint = renderPathGeometryFingerprint(command, kind, elements, stroke_width),
        };
        self.len += 1;
    }
};

pub const RenderPathGeometryCachePlanner = struct {
    entries: []RenderPathGeometryCacheEntry,
    actions: []RenderPathGeometryCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) RenderPathGeometryCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderPathGeometryCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderPathGeometryCachePlanner, geometry_plan: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64) Error!RenderPathGeometryCachePlan {
        self.reset();
        for (geometry_plan.geometries, 0..) |geometry_plan_item, geometry_index| {
            const key = renderPathGeometryKey(geometry_plan_item);
            if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderPathGeometryCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .geometry_index = geometry_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderPathGeometryCachePlanner, entry: RenderPathGeometryCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.PathGeometryCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderPathGeometryCachePlanner, action: RenderPathGeometryCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.PathGeometryCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderCommandNeedsLayer(command: RenderCommand) bool {
    return command.opacity != 1 or command.clip != null or !affinesEqual(command.transform, Affine.identity());
}

fn renderLayerCanExtend(layer: RenderLayer, command: RenderCommand, index: usize) bool {
    return layer.command_start + layer.command_count == index and
        layer.opacity == command.opacity and
        optionalRectsEqual(layer.clip, command.clip) and
        affinesEqual(layer.transform, command.transform);
}

pub const RenderEncoderPlanner = struct {
    commands: []RenderEncoderCommand,
    len: usize = 0,

    pub fn init(commands: []RenderEncoderCommand) RenderEncoderPlanner {
        return .{ .commands = commands };
    }

    pub fn reset(self: *RenderEncoderPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderEncoderPlanner, pass: CanvasRenderPass) Error!RenderEncoderPlan {
        self.reset();
        if (!pass.requiresRender()) return .{ .commands = self.commands[0..0] };

        try self.append(.{ .begin_pass = .{
            .load_action = pass.loadAction(),
            .surface_size = pass.surface_size,
            .scale = pass.scale,
            .dirty_bounds = pass.dirty_bounds,
        } });
        if (pass.scissorBounds()) |bounds| try self.append(.{ .set_scissor = bounds });

        for (pass.pipeline_actions) |action| try self.append(.{ .pipeline_cache = action });
        for (pass.path_geometry_actions) |action| try self.append(.{ .path_geometry_cache = action });
        for (pass.image_actions) |action| try self.append(.{ .image_cache = action });
        for (pass.layer_actions) |action| try self.append(.{ .layer_cache = action });
        for (pass.resource_actions) |action| try self.append(.{ .resource_cache = action });
        for (pass.visual_effect_actions) |action| try self.append(.{ .visual_effect_cache = action });
        for (pass.glyph_atlas_actions) |action| try self.append(.{ .glyph_atlas_cache = action });
        for (pass.text_layout_actions) |action| try self.append(.{ .text_layout_cache = action });

        var bound_pipeline: ?RenderPipelineKind = null;
        for (pass.batches) |batch| {
            if (bound_pipeline == null or bound_pipeline.? != batch.pipeline) {
                try self.append(.{ .bind_pipeline = batch.pipeline });
                bound_pipeline = batch.pipeline;
            }
            try self.append(.{ .draw_batch = batch });
        }
        try self.append(.end_pass);

        return .{ .commands = self.commands[0..self.len] };
    }

    fn append(self: *RenderEncoderPlanner, command: RenderEncoderCommand) Error!void {
        if (self.len >= self.commands.len) return error.RenderEncoderListFull;
        self.commands[self.len] = command;
        self.len += 1;
    }
};

pub const RenderImagePlanner = struct {
    images: []RenderImage,
    len: usize = 0,

    pub fn init(images: []RenderImage) RenderImagePlanner {
        return .{ .images = images };
    }

    pub fn reset(self: *RenderImagePlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderImagePlanner, render_plan: RenderPlan) Error!RenderImagePlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .images = self.images[0..self.len] };
    }

    fn consume(self: *RenderImagePlanner, command: RenderCommand, index: usize) Error!void {
        switch (command.command) {
            .draw_image => |value| try self.appendOrExtend(value, command, index),
            else => {},
        }
    }

    fn appendOrExtend(self: *RenderImagePlanner, image: DrawImage, command: RenderCommand, index: usize) Error!void {
        const fingerprint = renderImageFingerprint(image.image_id);
        if (findRenderImage(self.images[0..self.len], image.image_id, fingerprint)) |existing_index| {
            const existing = &self.images[existing_index];
            existing.draw_count += 1;
            existing.id = if (existing.id == command.id) existing.id else null;
            existing.bounds = geometry.RectF.unionWith(existing.bounds.normalized(), command.bounds.normalized());
            return;
        }

        if (self.len >= self.images.len) return error.ImageListFull;
        self.images[self.len] = .{
            .image_id = image.image_id,
            .command_index = index,
            .id = command.id,
            .draw_count = 1,
            .bounds = command.bounds,
            .fingerprint = fingerprint,
        };
        self.len += 1;
    }
};

pub const RenderImageCachePlanner = struct {
    entries: []RenderImageCacheEntry,
    actions: []RenderImageCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderImageCacheEntry, actions: []RenderImageCacheAction) RenderImageCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderImageCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderImageCachePlanner, image_plan: RenderImagePlan, previous: []const RenderImageCacheEntry, frame_index: u64) Error!RenderImageCachePlan {
        self.reset();
        for (image_plan.images, 0..) |image, image_index| {
            const key = renderImageKey(image);
            if (findRenderImageCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderImageCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .image_index = image_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderImageCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderImageCachePlanner, entry: RenderImageCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.ImageCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderImageCachePlanner, action: RenderImageCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.ImageCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const RenderLayerPlanner = struct {
    layers: []RenderLayer,
    len: usize = 0,

    pub fn init(layers: []RenderLayer) RenderLayerPlanner {
        return .{ .layers = layers };
    }

    pub fn reset(self: *RenderLayerPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderLayerPlanner, render_plan: RenderPlan) Error!RenderLayerPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .layers = self.layers[0..self.len] };
    }

    fn consume(self: *RenderLayerPlanner, command: RenderCommand, index: usize) Error!void {
        if (!renderCommandNeedsLayer(command)) return;

        if (self.len > 0 and renderLayerCanExtend(self.layers[self.len - 1], command, index)) {
            const layer = &self.layers[self.len - 1];
            layer.command_count += 1;
            layer.id = if (layer.id == command.id) layer.id else null;
            layer.bounds = geometry.RectF.unionWith(layer.bounds.normalized(), command.bounds.normalized());
            layer.fingerprint = renderLayerFingerprintAppend(layer.fingerprint, command);
            return;
        }

        if (self.len >= self.layers.len) return error.LayerListFull;
        self.layers[self.len] = .{
            .command_start = index,
            .command_count = 1,
            .id = command.id,
            .bounds = command.bounds,
            .opacity = command.opacity,
            .clip = command.clip,
            .transform = command.transform,
            .fingerprint = renderLayerFingerprint(command),
        };
        self.len += 1;
    }
};

pub const RenderLayerCachePlanner = struct {
    entries: []RenderLayerCacheEntry,
    actions: []RenderLayerCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) RenderLayerCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderLayerCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderLayerCachePlanner, layer_plan: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64) Error!RenderLayerCachePlan {
        self.reset();
        for (layer_plan.layers, 0..) |layer, layer_index| {
            const key = renderLayerKey(layer);
            if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderLayerCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .layer_index = layer_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderLayerCachePlanner, entry: RenderLayerCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.LayerCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderLayerCachePlanner, action: RenderLayerCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.LayerCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const RenderResourcePlanner = struct {
    resources: []RenderResource,
    len: usize = 0,

    pub fn init(resources: []RenderResource) RenderResourcePlanner {
        return .{ .resources = resources };
    }

    pub fn reset(self: *RenderResourcePlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderResourcePlanner, display_list: DisplayList) Error!RenderResourcePlan {
        self.reset();
        for (display_list.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .resources = self.resources[0..self.len] };
    }

    fn consume(self: *RenderResourcePlanner, command: CanvasCommand, index: usize) Error!void {
        switch (command) {
            .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform => {},
            .fill_rect => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .stroke_rect => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .fill_rounded_rect => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .draw_line => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .fill_path => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .stroke_path => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .draw_image => |value| try self.append(.{
                .kind = .image,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.dst.normalized(),
                .image_id = value.image_id,
                .fingerprint = drawImageFingerprint(value),
            }),
            .draw_text => |value| try self.append(.{
                .kind = .glyph_run,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = textBounds(value),
                .font_id = value.font_id,
                .glyph_count = value.glyphs.len,
                .text_len = value.text.len,
                .fingerprint = drawTextFingerprint(value),
            }),
            .shadow => |value| try self.append(.{
                .kind = .shadow,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = shadowBounds(value),
                .fingerprint = shadowFingerprint(value),
            }),
            .blur => |value| try self.append(.{
                .kind = .blur,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
                .fingerprint = blurFingerprint(value),
            }),
        }
    }

    fn consumeStroke(self: *RenderResourcePlanner, stroke: Stroke, index: usize, id: ObjectId, bounds: ?geometry.RectF) Error!void {
        try self.consumeFill(stroke.fill, index, id, bounds);
    }

    fn consumeFill(self: *RenderResourcePlanner, fill: Fill, index: usize, id: ObjectId, bounds: ?geometry.RectF) Error!void {
        switch (fill) {
            .color => {},
            .linear_gradient => |gradient| try self.append(.{
                .kind = .linear_gradient,
                .command_index = index,
                .id = nonZeroObjectId(id),
                .bounds = bounds,
                .gradient_stop_count = gradient.stops.len,
                .fingerprint = linearGradientFingerprint(gradient),
            }),
        }
    }

    fn append(self: *RenderResourcePlanner, resource: RenderResource) Error!void {
        if (self.len >= self.resources.len) return error.RenderResourceListFull;
        self.resources[self.len] = resource;
        self.len += 1;
    }
};

pub const RenderResourceCachePlanner = struct {
    entries: []RenderResourceCacheEntry,
    actions: []RenderResourceCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderResourceCacheEntry, actions: []RenderResourceCacheAction) RenderResourceCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderResourceCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderResourceCachePlanner, resource_plan: RenderResourcePlan, previous: []const RenderResourceCacheEntry, frame_index: u64) Error!RenderResourceCachePlan {
        self.reset();
        for (resource_plan.resources, 0..) |resource, resource_index| {
            const key = renderResourceKey(resource);
            if (findRenderResourceCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderResourceCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .resource_index = resource_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderResourceCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderResourceCachePlanner, entry: RenderResourceCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.RenderResourceCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderResourceCachePlanner, action: RenderResourceCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.RenderResourceCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const VisualEffectPlanner = struct {
    effects: []VisualEffect,
    len: usize = 0,

    pub fn init(effects: []VisualEffect) VisualEffectPlanner {
        return .{ .effects = effects };
    }

    pub fn reset(self: *VisualEffectPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *VisualEffectPlanner, display_list: DisplayList) Error!VisualEffectPlan {
        self.reset();
        for (display_list.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .effects = self.effects[0..self.len] };
    }

    fn consume(self: *VisualEffectPlanner, command: CanvasCommand, index: usize) Error!void {
        switch (command) {
            .shadow => |value| try self.append(.{
                .kind = .shadow,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = shadowBounds(value),
                .radius = value.radius,
                .offset = value.offset,
                .blur = nonNegative(value.blur),
                .spread = value.spread,
                .fingerprint = shadowFingerprint(value),
            }),
            .blur => |value| try self.append(.{
                .kind = .blur,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
                .blur = nonNegative(value.radius),
                .fingerprint = blurFingerprint(value),
            }),
            else => {},
        }
    }

    fn append(self: *VisualEffectPlanner, effect: VisualEffect) Error!void {
        if (self.len >= self.effects.len) return error.VisualEffectListFull;
        self.effects[self.len] = effect;
        self.len += 1;
    }
};

pub const VisualEffectCachePlanner = struct {
    entries: []VisualEffectCacheEntry,
    actions: []VisualEffectCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []VisualEffectCacheEntry, actions: []VisualEffectCacheAction) VisualEffectCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *VisualEffectCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *VisualEffectCachePlanner, effect_plan: VisualEffectPlan, previous: []const VisualEffectCacheEntry, frame_index: u64) Error!VisualEffectCachePlan {
        self.reset();
        for (effect_plan.effects, 0..) |effect, effect_index| {
            const key = visualEffectKey(effect);
            if (findVisualEffectCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findVisualEffectCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .effect_index = effect_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findVisualEffectCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *VisualEffectCachePlanner, entry: VisualEffectCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.VisualEffectCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *VisualEffectCachePlanner, action: VisualEffectCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.VisualEffectCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderResourceKey(resource: RenderResource) RenderResourceKey {
    return .{
        .kind = resource.kind,
        .id = resource.id,
        .command_index = if (resource.id == null and resource.kind != .image) resource.command_index else 0,
        .image_id = resource.image_id,
        .font_id = resource.font_id,
        .fingerprint = resource.fingerprint,
    };
}

fn findRenderResourceCacheEntry(entries: []const RenderResourceCacheEntry, key: RenderResourceKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderResourceKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderResourceKeysEqual(a: RenderResourceKey, b: RenderResourceKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.image_id == b.image_id and
        a.font_id == b.font_id and
        a.fingerprint == b.fingerprint;
}

fn renderPathGeometryKey(geometry_plan: RenderPathGeometry) RenderPathGeometryKey {
    return .{
        .kind = geometry_plan.kind,
        .id = geometry_plan.id,
        .command_index = if (geometry_plan.id == null) geometry_plan.command_index else 0,
        .fingerprint = geometry_plan.fingerprint,
    };
}

fn findRenderPathGeometryCacheEntry(entries: []const RenderPathGeometryCacheEntry, key: RenderPathGeometryKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderPathGeometryKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderPathGeometryKeysEqual(a: RenderPathGeometryKey, b: RenderPathGeometryKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.fingerprint == b.fingerprint;
}

fn renderImageKey(image: RenderImage) RenderImageKey {
    return .{
        .image_id = image.image_id,
        .fingerprint = image.fingerprint,
    };
}

fn findRenderImage(images: []const RenderImage, image_id: ImageId, fingerprint: u64) ?usize {
    for (images, 0..) |image, index| {
        if (image.image_id == image_id and image.fingerprint == fingerprint) return index;
    }
    return null;
}

fn findRenderImageCacheEntry(entries: []const RenderImageCacheEntry, key: RenderImageKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderImageKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderImageKeysEqual(a: RenderImageKey, b: RenderImageKey) bool {
    return a.image_id == b.image_id and
        a.fingerprint == b.fingerprint;
}

fn renderLayerKey(layer: RenderLayer) RenderLayerKey {
    return .{
        .id = layer.id,
        .command_start = if (layer.id == null) layer.command_start else 0,
        .fingerprint = layer.fingerprint,
    };
}

fn findRenderLayerCacheEntry(entries: []const RenderLayerCacheEntry, key: RenderLayerKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderLayerKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderLayerKeysEqual(a: RenderLayerKey, b: RenderLayerKey) bool {
    return a.id == b.id and
        a.command_start == b.command_start and
        a.fingerprint == b.fingerprint;
}

fn renderLayerFingerprint(command: RenderCommand) u64 {
    var hash = resourceHashTag("layer");
    hash = resourceHashF32(hash, command.opacity);
    hash = resourceHashOptionalRect(hash, command.clip);
    hash = resourceHashAffine(hash, command.transform);
    return renderLayerFingerprintAppend(hash, command);
}

fn renderLayerFingerprintAppend(hash: u64, command: RenderCommand) u64 {
    return resourceHashU64(hash, renderCommandFingerprint(command));
}

fn renderCommandFingerprint(command: RenderCommand) u64 {
    var hash = resourceHashTag("render_command");
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashRect(hash, command.local_bounds);
    hash = resourceHashRect(hash, command.bounds);
    return resourceHashCanvasCommand(hash, command.command);
}

fn renderPathGeometryFingerprint(command: RenderCommand, kind: RenderPathGeometryKind, elements: []const PathElement, stroke_width: f32) u64 {
    var hash = resourceHashTag("path_geometry");
    hash = resourceHashBytes(hash, @tagName(kind));
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashAffine(hash, command.transform);
    hash = resourceHashPath(hash, elements);
    hash = resourceHashF32(hash, stroke_width);
    return hash;
}

fn visualEffectKey(effect: VisualEffect) VisualEffectKey {
    return .{
        .kind = effect.kind,
        .id = effect.id,
        .command_index = if (effect.id == null) effect.command_index else 0,
        .fingerprint = effect.fingerprint,
    };
}

fn findVisualEffectCacheEntry(entries: []const VisualEffectCacheEntry, key: VisualEffectKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (visualEffectKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn visualEffectKeysEqual(a: VisualEffectKey, b: VisualEffectKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.fingerprint == b.fingerprint;
}

fn motionProgress(animation: CanvasRenderAnimation, timestamp_ns: u64) f32 {
    const raw = rawMotionProgress(animation.start_ns, animation.duration_ms, timestamp_ns);
    return easedMotionProgress(animation.easing, animation.spring, raw);
}

fn rawMotionProgress(start_ns: u64, duration_ms: u32, timestamp_ns: u64) f32 {
    if (duration_ms == 0) return 1;
    if (timestamp_ns <= start_ns) return 0;
    const duration_ns = @as(u64, duration_ms) * 1_000_000;
    const elapsed_ns = timestamp_ns - start_ns;
    if (elapsed_ns >= duration_ns) return 1;
    return @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(duration_ns));
}

fn easedMotionProgress(easing: Easing, spring: SpringToken, progress: f32) f32 {
    const t = std.math.clamp(progress, 0, 1);
    return switch (easing) {
        .linear => t,
        .standard => t * t * (3 - 2 * t),
        .emphasized => 1 - std.math.pow(f32, 1 - t, 3),
        .spring => springMotionProgress(t, spring),
    };
}

fn springMotionProgress(progress: f32, spring: SpringToken) f32 {
    if (progress <= 0) return 0;
    if (progress >= 1) return 1;
    const mass = @max(0.001, spring.mass);
    const stiffness = @max(1, spring.stiffness);
    const damping = @max(0.001, spring.damping);
    const omega = @sqrt(stiffness / mass);
    const decay = @exp(-damping * progress / (mass * 24));
    return std.math.clamp(1 - decay * @cos(omega * progress), 0, 1);
}

fn sampleAnimatedF32(from: ?f32, to: ?f32, progress: f32) ?f32 {
    const start = from orelse return null;
    const end = to orelse return null;
    return start + (end - start) * progress;
}

fn sampleAnimatedAffine(from: ?Affine, to: ?Affine, progress: f32) ?Affine {
    const start = from orelse return null;
    const end = to orelse return null;
    return .{
        .a = start.a + (end.a - start.a) * progress,
        .b = start.b + (end.b - start.b) * progress,
        .c = start.c + (end.c - start.c) * progress,
        .d = start.d + (end.d - start.d) * progress,
        .tx = start.tx + (end.tx - start.tx) * progress,
        .ty = start.ty + (end.ty - start.ty) * progress,
    };
}

pub fn applyRenderOverrides(commands: []RenderCommand, overrides: []const CanvasRenderOverride) ?geometry.RectF {
    var bounds: ?geometry.RectF = null;
    for (commands) |*command| {
        if (command.id) |id| {
            if (findRenderOverride(overrides, id)) |override| {
                applyRenderOverride(command, override);
            }
        }
        bounds = unionOptionalBounds(bounds, command.bounds);
    }
    return bounds;
}

fn applyRenderOverride(command: *RenderCommand, override: CanvasRenderOverride) void {
    if (override.opacity) |opacity| {
        command.opacity *= std.math.clamp(opacity, 0, 1);
    }
    if (override.transform) |transform| {
        command.transform = command.transform.multiply(transform);
        if (renderCommandBoundsWithOverride(command.*, null)) |bounds| {
            command.bounds = bounds;
        } else {
            command.bounds = geometry.RectF.zero();
        }
    }
}

pub fn renderOverrideDirtyBounds(commands: []const RenderCommand, previous: []const CanvasRenderOverride, next: []const CanvasRenderOverride) ?geometry.RectF {
    if (previous.len == 0 and next.len == 0) return null;

    var bounds: ?geometry.RectF = null;
    for (commands) |command| {
        const id = command.id orelse continue;
        const previous_override = findRenderOverride(previous, id);
        const next_override = findRenderOverride(next, id);
        if (renderOverridesEqual(previous_override, next_override)) continue;
        bounds = unionOptionalBounds(bounds, renderCommandBoundsWithOverride(command, previous_override));
        bounds = unionOptionalBounds(bounds, renderCommandBoundsWithOverride(command, next_override));
    }
    return bounds;
}

fn renderCommandBoundsWithOverride(command: RenderCommand, override: ?CanvasRenderOverride) ?geometry.RectF {
    const override_transform = if (override) |value| value.transform else null;
    const transform = if (override_transform) |value| command.transform.multiply(value) else command.transform;
    var bounds = transform.transformRect(command.local_bounds);
    if (command.clip) |clip| {
        bounds = geometry.RectF.intersection(bounds, clip);
    }
    const normalized = bounds.normalized();
    return if (normalized.isEmpty()) null else normalized;
}

fn findRenderOverride(overrides: []const CanvasRenderOverride, id: ObjectId) ?CanvasRenderOverride {
    for (overrides) |override| {
        if (override.id == id) return override;
    }
    return null;
}

fn renderOverridesEqual(a: ?CanvasRenderOverride, b: ?CanvasRenderOverride) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const left = a.?;
    const right = b.?;
    return left.id == right.id and
        optionalF32Equal(left.opacity, right.opacity) and
        optionalAffineEqual(left.transform, right.transform);
}

fn optionalAffineEqual(a: ?Affine, b: ?Affine) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return affinesEqual(a.?, b.?);
}

fn renderBatchCanExtend(batch: RenderBatch, command: RenderCommand, pipeline: RenderPipelineKind, index: usize) bool {
    return batch.pipeline == pipeline and
        batch.command_start + batch.command_count == index and
        batch.opacity == command.opacity and
        optionalRectsEqual(batch.clip, command.clip);
}

fn renderPipelineKind(command: CanvasCommand) RenderPipelineKind {
    return switch (command) {
        .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform => .solid,
        .fill_rect => |value| renderPipelineForFill(value.fill),
        .stroke_rect => |value| renderPipelineForStroke(value.stroke),
        .fill_rounded_rect => |value| renderPipelineForFill(value.fill),
        .draw_line => |value| renderPipelineForStroke(value.stroke),
        .fill_path, .stroke_path => .path,
        .draw_image => .image,
        .draw_text => .glyph_run,
        .shadow => .shadow,
        .blur => .blur,
    };
}

fn renderPipelineForStroke(stroke: Stroke) RenderPipelineKind {
    return renderPipelineForFill(stroke.fill);
}

fn renderPipelineForFill(fill: Fill) RenderPipelineKind {
    return switch (fill) {
        .color => .solid,
        .linear_gradient => .linear_gradient,
    };
}

const resource_hash_offset: u64 = 14695981039346656037;
const resource_hash_prime: u64 = 1099511628211;

fn linearGradientFingerprint(gradient: LinearGradient) u64 {
    var hash = resourceHashTag("linear_gradient");
    hash = resourceHashPoint(hash, gradient.start);
    hash = resourceHashPoint(hash, gradient.end);
    hash = resourceHashUsize(hash, gradient.stops.len);
    for (gradient.stops) |stop| {
        hash = resourceHashF32(hash, stop.offset);
        hash = resourceHashColor(hash, stop.color);
    }
    return hash;
}

fn drawImageFingerprint(image: DrawImage) u64 {
    var hash = resourceHashTag("image");
    hash = resourceHashU64(hash, image.image_id);
    hash = resourceHashOptionalRect(hash, image.src);
    hash = resourceHashEnum(hash, @intFromEnum(image.fit));
    hash = resourceHashEnum(hash, @intFromEnum(image.sampling));
    return hash;
}

fn renderImageFingerprint(image_id: ImageId) u64 {
    return resourceHashU64(resourceHashTag("image_texture"), image_id);
}

fn drawTextFingerprint(text: DrawText) u64 {
    var hash = resourceHashTag("glyph_run");
    hash = resourceHashU64(hash, text.font_id);
    hash = resourceHashF32(hash, text.size);
    hash = resourceHashPoint(hash, text.origin);
    hash = resourceHashBytes(hash, text.text);
    hash = resourceHashUsize(hash, text.glyphs.len);
    for (text.glyphs) |glyph| {
        hash = resourceHashU32(hash, glyph.id);
        hash = resourceHashU64(hash, glyphFontId(text.font_id, glyph));
        hash = resourceHashF32(hash, glyph.x);
        hash = resourceHashF32(hash, glyph.y);
        hash = resourceHashF32(hash, glyph.advance);
    }
    hash = resourceHashOptionalTextLayoutOptions(hash, text.text_layout);
    return hash;
}

fn textLayoutOptionsForDrawText(frame_options: TextLayoutOptions, text: DrawText) TextLayoutOptions {
    return text.text_layout orelse frame_options;
}

fn textLayoutKey(text: DrawText, options: TextLayoutOptions) TextLayoutKey {
    return .{
        .font_id = text.font_id,
        .size = text.size,
        .origin = text.origin,
        .max_width = nonNegative(options.max_width),
        .line_height = nonNegative(options.line_height),
        .wrap = options.wrap,
        .alignment = options.alignment,
        .text_len = text.text.len,
        .glyph_count = text.glyphs.len,
        .fingerprint = textLayoutFingerprint(text, options),
    };
}

fn textLayoutFingerprint(text: DrawText, options: TextLayoutOptions) u64 {
    var hash = resourceHashTag("text_layout");
    hash = resourceHashU64(hash, drawTextFingerprint(text));
    hash = resourceHashF32(hash, nonNegative(options.max_width));
    hash = resourceHashF32(hash, nonNegative(options.line_height));
    hash = resourceHashEnum(hash, @intFromEnum(options.wrap));
    hash = resourceHashEnum(hash, @intFromEnum(options.alignment));
    return hash;
}

fn findTextLayoutCacheEntry(entries: []const TextLayoutCacheEntry, key: TextLayoutKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (textLayoutKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn shouldRetainUnusedCacheEntry(frame_index: u64, last_used_frame: u64, retention_frames: u64) bool {
    if (retention_frames == 0) return false;
    if (frame_index <= last_used_frame) return true;
    return frame_index - last_used_frame <= retention_frames;
}

fn textLayoutKeysEqual(a: TextLayoutKey, b: TextLayoutKey) bool {
    return a.font_id == b.font_id and
        a.size == b.size and
        a.origin.x == b.origin.x and
        a.origin.y == b.origin.y and
        a.max_width == b.max_width and
        a.line_height == b.line_height and
        a.wrap == b.wrap and
        a.alignment == b.alignment and
        a.text_len == b.text_len and
        a.glyph_count == b.glyph_count and
        a.fingerprint == b.fingerprint;
}

fn shadowFingerprint(shadow: Shadow) u64 {
    var hash = resourceHashTag("shadow");
    hash = resourceHashRect(hash, shadow.rect);
    hash = resourceHashRadius(hash, shadow.radius);
    hash = resourceHashF32(hash, shadow.offset.dx);
    hash = resourceHashF32(hash, shadow.offset.dy);
    hash = resourceHashF32(hash, shadow.blur);
    hash = resourceHashF32(hash, shadow.spread);
    hash = resourceHashColor(hash, shadow.color);
    return hash;
}

fn blurFingerprint(blur: Blur) u64 {
    var hash = resourceHashTag("blur");
    hash = resourceHashRect(hash, blur.rect);
    hash = resourceHashF32(hash, blur.radius);
    return hash;
}

fn resourceHashTag(tag: []const u8) u64 {
    return resourceHashBytes(resource_hash_offset, tag);
}

fn resourceHashBytes(initial: u64, bytes: []const u8) u64 {
    var hash = initial;
    for (bytes) |byte| hash = resourceHashU8(hash, byte);
    return hash;
}

fn resourceHashU8(hash: u64, value: u8) u64 {
    return (hash ^ value) *% resource_hash_prime;
}

fn resourceHashU32(hash: u64, value: u32) u64 {
    var next = hash;
    next = resourceHashU8(next, @intCast(value & 0xff));
    next = resourceHashU8(next, @intCast((value >> 8) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 16) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 24) & 0xff));
    return next;
}

fn resourceHashU64(hash: u64, value: u64) u64 {
    var next = hash;
    next = resourceHashU32(next, @intCast(value & 0xffff_ffff));
    next = resourceHashU32(next, @intCast((value >> 32) & 0xffff_ffff));
    return next;
}

fn resourceHashUsize(hash: u64, value: usize) u64 {
    return resourceHashU64(hash, @intCast(value));
}

fn resourceHashEnum(hash: u64, value: anytype) u64 {
    return resourceHashU64(hash, @intCast(value));
}

fn resourceHashF32(hash: u64, value: f32) u64 {
    const bits: u32 = @bitCast(value);
    return resourceHashU32(hash, bits);
}

fn resourceHashPoint(hash: u64, point: geometry.PointF) u64 {
    return resourceHashF32(resourceHashF32(hash, point.x), point.y);
}

fn resourceHashRect(hash: u64, rect: geometry.RectF) u64 {
    var next = resourceHashF32(hash, rect.x);
    next = resourceHashF32(next, rect.y);
    next = resourceHashF32(next, rect.width);
    next = resourceHashF32(next, rect.height);
    return next;
}

fn resourceHashOptionalRect(hash: u64, rect: ?geometry.RectF) u64 {
    if (rect) |value| return resourceHashRect(resourceHashU8(hash, 1), value);
    return resourceHashU8(hash, 0);
}

fn resourceHashOptionalObjectId(hash: u64, id: ?ObjectId) u64 {
    if (id) |value| return resourceHashU64(resourceHashU8(hash, 1), value);
    return resourceHashU8(hash, 0);
}

fn resourceHashOptionalTextLayoutOptions(hash: u64, options: ?TextLayoutOptions) u64 {
    if (options) |value| {
        var next = resourceHashU8(hash, 1);
        next = resourceHashF32(next, nonNegative(value.max_width));
        next = resourceHashF32(next, nonNegative(value.line_height));
        next = resourceHashEnum(next, @intFromEnum(value.wrap));
        next = resourceHashEnum(next, @intFromEnum(value.alignment));
        return next;
    }
    return resourceHashU8(hash, 0);
}

fn resourceHashAffine(hash: u64, matrix: Affine) u64 {
    var next = resourceHashF32(hash, matrix.a);
    next = resourceHashF32(next, matrix.b);
    next = resourceHashF32(next, matrix.c);
    next = resourceHashF32(next, matrix.d);
    next = resourceHashF32(next, matrix.tx);
    next = resourceHashF32(next, matrix.ty);
    return next;
}

fn resourceHashRadius(hash: u64, radius: Radius) u64 {
    var next = resourceHashF32(hash, radius.top_left);
    next = resourceHashF32(next, radius.top_right);
    next = resourceHashF32(next, radius.bottom_right);
    next = resourceHashF32(next, radius.bottom_left);
    return next;
}

fn resourceHashColor(hash: u64, color: Color) u64 {
    var next = resourceHashF32(hash, color.r);
    next = resourceHashF32(next, color.g);
    next = resourceHashF32(next, color.b);
    next = resourceHashF32(next, color.a);
    return next;
}

fn resourceHashCanvasCommand(hash: u64, command: CanvasCommand) u64 {
    var next = resourceHashBytes(hash, @tagName(command));
    switch (command) {
        .push_clip => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
        },
        .pop_clip, .push_opacity, .pop_opacity, .transform => {},
        .fill_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashFill(next, value.fill);
        },
        .stroke_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
            next = resourceHashStroke(next, value.stroke);
        },
        .fill_rounded_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
            next = resourceHashFill(next, value.fill);
        },
        .draw_line => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPoint(next, value.from);
            next = resourceHashPoint(next, value.to);
            next = resourceHashStroke(next, value.stroke);
        },
        .fill_path => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPath(next, value.elements);
            next = resourceHashFill(next, value.fill);
        },
        .stroke_path => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPath(next, value.elements);
            next = resourceHashStroke(next, value.stroke);
        },
        .draw_image => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, drawImageFingerprint(value));
            next = resourceHashRect(next, value.dst);
            next = resourceHashF32(next, value.opacity);
        },
        .draw_text => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, drawTextFingerprint(value));
            next = resourceHashColor(next, value.color);
        },
        .shadow => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, shadowFingerprint(value));
        },
        .blur => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, blurFingerprint(value));
        },
    }
    return next;
}

fn resourceHashFill(hash: u64, fill: Fill) u64 {
    return switch (fill) {
        .color => |color| resourceHashColor(resourceHashBytes(hash, "color"), color),
        .linear_gradient => |gradient| resourceHashU64(resourceHashBytes(hash, "linear_gradient"), linearGradientFingerprint(gradient)),
    };
}

fn resourceHashStroke(hash: u64, stroke: Stroke) u64 {
    var next = resourceHashF32(resourceHashBytes(hash, "stroke"), stroke.width);
    next = resourceHashFill(next, stroke.fill);
    return next;
}

fn resourceHashPath(hash: u64, elements: []const PathElement) u64 {
    var next = resourceHashUsize(resourceHashBytes(hash, "path"), elements.len);
    for (elements) |element| {
        next = resourceHashEnum(next, @intFromEnum(element.verb));
        next = resourceHashPoint(next, element.points[0]);
        next = resourceHashPoint(next, element.points[1]);
        next = resourceHashPoint(next, element.points[2]);
    }
    return next;
}

pub const GlyphAtlasPlanner = struct {
    entries: []GlyphAtlasEntry,
    len: usize = 0,

    pub fn init(entries: []GlyphAtlasEntry) GlyphAtlasPlanner {
        return .{ .entries = entries };
    }

    pub fn reset(self: *GlyphAtlasPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *GlyphAtlasPlanner, display_list: DisplayList) Error!GlyphAtlasPlan {
        self.reset();
        for (display_list.commands, 0..) |command, command_index| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, command_index),
                else => {},
            }
        }
        return .{ .entries = self.entries[0..self.len] };
    }

    fn consumeText(self: *GlyphAtlasPlanner, text: DrawText, command_index: usize) Error!void {
        if (text.glyphs.len > 0) {
            for (text.glyphs, 0..) |glyph, glyph_index| {
                const key = GlyphAtlasKey{
                    .font_id = glyphFontId(text.font_id, glyph),
                    .glyph_id = glyph.id,
                    .size = text.size,
                    .subpixel_x = subpixelBucket(text.origin.x + glyph.x),
                    .subpixel_y = subpixelBucket(text.origin.y + glyph.y),
                };
                try self.appendUnique(key, command_index, glyph_index);
            }
            return;
        }

        var text_offset: usize = 0;
        var scalar_index: usize = 0;
        while (text_offset < text.text.len) {
            const next_offset = nextTextOffset(text.text, text_offset);
            defer {
                text_offset = next_offset;
                scalar_index += 1;
            }
            if (isReferenceTextSpace(text.text[text_offset])) continue;

            const key = GlyphAtlasKey{
                .font_id = text.font_id,
                .glyph_id = fallbackGlyphId(text.text[text_offset..next_offset]),
                .size = text.size,
                .subpixel_x = subpixelBucket(text.origin.x + @as(f32, @floatFromInt(scalar_index)) * text.size * 0.5),
                .subpixel_y = subpixelBucket(text.origin.y),
            };
            try self.appendUnique(key, command_index, scalar_index);
        }
    }

    fn appendUnique(self: *GlyphAtlasPlanner, key: GlyphAtlasKey, command_index: usize, glyph_index: usize) Error!void {
        for (self.entries[0..self.len]) |entry| {
            if (glyphAtlasKeysEqual(entry.key, key)) return;
        }
        if (self.len >= self.entries.len) return error.GlyphAtlasListFull;
        self.entries[self.len] = .{
            .key = key,
            .command_index = command_index,
            .glyph_index = glyph_index,
        };
        self.len += 1;
    }
};

pub const GlyphAtlasCachePlanner = struct {
    entries: []GlyphAtlasCacheEntry,
    actions: []GlyphAtlasCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) GlyphAtlasCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *GlyphAtlasCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *GlyphAtlasCachePlanner, plan: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, retention_frames: u64) Error!GlyphAtlasCachePlan {
        self.reset();

        for (plan.entries, 0..) |entry, atlas_index| {
            if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;

            const previous_index = findGlyphAtlasCacheEntry(previous, entry.key);
            try self.appendEntry(.{
                .key = entry.key,
                .last_used_frame = frame_index,
            });
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = entry.key,
                .atlas_index = atlas_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, previous_index| {
            if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntry(entry);
                try self.appendAction(.{
                    .kind = .retain,
                    .key = entry.key,
                    .cache_index = previous_index,
                });
            } else {
                try self.appendAction(.{
                    .kind = .evict,
                    .key = entry.key,
                    .cache_index = previous_index,
                });
            }
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *GlyphAtlasCachePlanner, entry: GlyphAtlasCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.GlyphAtlasCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn hasEntryCapacity(self: *GlyphAtlasCachePlanner) bool {
        return self.entry_len < self.entries.len;
    }

    fn appendAction(self: *GlyphAtlasCachePlanner, action: GlyphAtlasCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.GlyphAtlasCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const TextLayoutPlanner = struct {
    plans: []TextLayoutPlan,
    lines: []TextLine,
    plan_len: usize = 0,
    line_len: usize = 0,

    pub fn init(plans: []TextLayoutPlan, lines: []TextLine) TextLayoutPlanner {
        return .{ .plans = plans, .lines = lines };
    }

    pub fn reset(self: *TextLayoutPlanner) void {
        self.plan_len = 0;
        self.line_len = 0;
    }

    pub fn build(self: *TextLayoutPlanner, display_list: DisplayList, options: TextLayoutOptions) Error!TextLayoutPlanSet {
        self.reset();
        if (self.plans.len == 0 and self.lines.len == 0) return .{};

        for (display_list.commands) |command| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, options),
                else => {},
            }
        }
        return .{ .plans = self.plans[0..self.plan_len] };
    }

    fn consumeText(self: *TextLayoutPlanner, text: DrawText, options: TextLayoutOptions) Error!void {
        if (self.plan_len >= self.plans.len) return error.TextLayoutPlanListFull;
        const plan = try layoutTextRunPlan(text, textLayoutOptionsForDrawText(options, text), self.lines[self.line_len..]);
        self.plans[self.plan_len] = plan;
        self.plan_len += 1;
        self.line_len += plan.lineCount();
    }
};

pub const TextLayoutCachePlanner = struct {
    entries: []TextLayoutCacheEntry,
    actions: []TextLayoutCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) TextLayoutCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *TextLayoutCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *TextLayoutCachePlanner, plan: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64) Error!TextLayoutCachePlan {
        return self.buildMany(&.{plan}, previous, frame_index, retention_frames);
    }

    pub fn buildMany(self: *TextLayoutCachePlanner, plans: []const TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64) Error!TextLayoutCachePlan {
        self.reset();

        for (plans, 0..) |plan, layout_index| {
            if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], plan.key) != null) continue;

            const previous_index = findTextLayoutCacheEntry(previous, plan.key);
            try self.appendEntry(.{
                .key = plan.key,
                .line_count = plan.lineCount(),
                .bounds = plan.layout.bounds,
                .last_used_frame = frame_index,
            });
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = plan.key,
                .layout_index = layout_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, index| {
            if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntry(entry);
                try self.appendAction(.{
                    .kind = .retain,
                    .key = entry.key,
                    .cache_index = index,
                });
            } else {
                try self.appendAction(.{
                    .kind = .evict,
                    .key = entry.key,
                    .cache_index = index,
                });
            }
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *TextLayoutCachePlanner, entry: TextLayoutCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.TextLayoutCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn hasEntryCapacity(self: *TextLayoutCachePlanner) bool {
        return self.entry_len < self.entries.len;
    }

    fn appendAction(self: *TextLayoutCachePlanner, action: TextLayoutCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.TextLayoutCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

const WidgetPaintOrder = struct {
    layer: i32,
    index: usize,
};

fn widgetPaintLayer(widget: Widget, tokens: DesignTokens) i32 {
    if (widget.layer) |layer| return layer;
    return switch (widget.kind) {
        .popover, .menu_surface => tokens.layer.overlay,
        .tooltip => tokens.layer.floating,
        else => tokens.layer.base,
    };
}

fn nextWidgetPaintChild(children: []const Widget, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (children, 0..) |child, index| {
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(child, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn widgetLayoutDirectChildCount(layout: WidgetLayoutTree, parent_index: ?usize) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (optionalUsizeEqual(node.parent_index, parent_index)) count += 1;
    }
    return count;
}

fn nextWidgetLayoutPaintChild(layout: WidgetLayoutTree, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn previousWidgetLayoutPaintChild(layout: WidgetLayoutTree, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderBefore(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(best.?, order)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn widgetPaintOrderAfter(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer > value.layer or (order.layer == value.layer and order.index > value.index);
}

fn widgetPaintOrderBefore(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer < value.layer or (order.layer == value.layer and order.index < value.index);
}

fn widgetPaintOrderLess(a: WidgetPaintOrder, b: WidgetPaintOrder) bool {
    return a.layer < b.layer or (a.layer == b.layer and a.index < b.index);
}

fn optionalUsizeEqual(a: ?usize, b: ?usize) bool {
    if (a) |a_value| {
        return if (b) |b_value| a_value == b_value else false;
    }
    return b == null;
}

fn emitWidgetDepth(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (widget.semantics.hidden) return;

    const opacity = widgetOpacity(widget);
    if (opacity <= 0) return;
    const wrap_opacity = opacity < 1;
    const transform = widgetTransform(widget);
    const wrap_transform = !affinesEqual(transform, Affine.identity());
    const inverse_transform = if (wrap_transform) transform.inverse() orelse return error.InvalidTransform else Affine.identity();
    if (wrap_opacity) try builder.pushOpacity(opacity);
    if (wrap_transform) try builder.transform(transform);
    try emitWidgetDepthContent(builder, widget, tokens, depth);
    if (wrap_transform) try builder.transform(inverse_transform);
    if (wrap_opacity) try builder.popOpacity();
}

fn emitWidgetDepthContent(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitWidgetBackdropBlur(builder, widget);
    switch (widget.kind) {
        .stack, .row, .column, .grid, .data_grid, .list, .data_row => try emitWidgetClippedChildren(builder, widget, tokens, depth),
        .scroll_view => try emitScrollViewWidget(builder, widget, tokens, depth),
        .panel => try emitPanelWidget(builder, widget, tokens, depth),
        .popover => try emitPopoverWidget(builder, widget, tokens, depth),
        .menu_surface => try emitMenuSurfaceWidget(builder, widget, tokens, depth),
        .text => try emitTextWidget(builder, widget, tokens),
        .icon => try emitIconWidget(builder, widget, tokens),
        .image => try emitImageWidget(builder, widget),
        .button => try emitButtonWidget(builder, widget, tokens),
        .icon_button => try emitIconButtonWidget(builder, widget, tokens),
        .text_field => try emitTextFieldWidget(builder, widget, tokens),
        .search_field => try emitSearchFieldWidget(builder, widget, tokens),
        .tooltip => try emitTooltipWidget(builder, widget, tokens),
        .menu_item => try emitMenuItemWidget(builder, widget, tokens),
        .list_item => try emitListItemWidget(builder, widget, tokens),
        .data_cell => try emitDataCellWidget(builder, widget, tokens),
        .segmented_control => try emitSegmentedControlWidget(builder, widget, tokens),
        .checkbox => try emitCheckboxWidget(builder, widget, tokens),
        .toggle => try emitToggleWidget(builder, widget, tokens),
        .slider => try emitSliderWidget(builder, widget, tokens),
        .progress => try emitProgressWidget(builder, widget, tokens),
    }
}

fn emitWidgetChildren(builder: *Builder, children: []const Widget, tokens: DesignTokens, depth: usize) Error!void {
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < children.len) : (emitted += 1) {
        const child_index = nextWidgetPaintChild(children, tokens, previous) orelse return;
        const child = children[child_index];
        try emitWidgetDepth(builder, child, tokens, depth + 1);
        previous = .{ .layer = widgetPaintLayer(child, tokens), .index = child_index };
    }
}

fn emitWidgetLayoutChildren(
    builder: *Builder,
    layout: WidgetLayoutTree,
    parent_index: ?usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < child_count) : (emitted += 1) {
        const child_index = nextWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return;
        try emitWidgetLayoutNode(builder, layout, child_index, tokens, state);
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
}

fn emitWidgetLayoutNode(
    builder: *Builder,
    layout: WidgetLayoutTree,
    node_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return;

    const widget = widgetWithRenderState(widgetWithFrame(node.widget, node.frame), state);
    const opacity = widgetOpacity(widget);
    if (opacity <= 0) return;
    const wrap_opacity = opacity < 1;
    const transform = widgetTransform(widget);
    const wrap_transform = !affinesEqual(transform, Affine.identity());
    const inverse_transform = if (wrap_transform) transform.inverse() orelse return error.InvalidTransform else Affine.identity();
    if (wrap_opacity) try builder.pushOpacity(opacity);
    if (wrap_transform) try builder.transform(transform);
    try emitWidgetLayoutNodeContent(builder, layout, node_index, tokens, state, widget);
    if (wrap_transform) try builder.transform(inverse_transform);
    if (wrap_opacity) try builder.popOpacity();
}

fn emitWidgetLayoutNodeContent(
    builder: *Builder,
    layout: WidgetLayoutTree,
    node_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    try emitWidgetBackdropBlur(builder, widget);
    switch (widget.kind) {
        .stack, .row, .column, .grid, .data_grid, .list, .data_row => {},
        .scroll_view => {
            try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
            try emitWidgetLayoutChildren(builder, layout, node_index, tokens, state);
            try builder.popClip();
            try emitScrollViewScrollbar(builder, widget.frame, widgetScrollSemantics(layout, node_index).metrics, tokens, widget.id);
            return;
        },
        .panel => try emitPanelWidgetChrome(builder, widget, tokens),
        .popover => try emitPopoverWidgetChrome(builder, widget, tokens),
        .menu_surface => try emitMenuSurfaceWidgetChrome(builder, widget, tokens),
        .text => try emitTextWidget(builder, widget, tokens),
        .icon => try emitIconWidget(builder, widget, tokens),
        .image => try emitImageWidget(builder, widget),
        .button => try emitButtonWidget(builder, widget, tokens),
        .icon_button => try emitIconButtonWidget(builder, widget, tokens),
        .text_field => try emitTextFieldWidget(builder, widget, tokens),
        .search_field => try emitSearchFieldWidget(builder, widget, tokens),
        .tooltip => try emitTooltipWidget(builder, widget, tokens),
        .menu_item => try emitMenuItemWidget(builder, widget, tokens),
        .list_item => try emitListItemWidget(builder, widget, tokens),
        .data_cell => try emitDataCellWidget(builder, widget, tokens),
        .segmented_control => try emitSegmentedControlWidget(builder, widget, tokens),
        .checkbox => try emitCheckboxWidget(builder, widget, tokens),
        .toggle => try emitToggleWidget(builder, widget, tokens),
        .slider => try emitSliderWidget(builder, widget, tokens),
        .progress => try emitProgressWidget(builder, widget, tokens),
    }

    try emitWidgetLayoutClippedChildren(builder, layout, node_index, tokens, state, widget);
}

fn widgetOpacity(widget: Widget) f32 {
    return std.math.clamp(widget.opacity, 0, 1);
}

fn widgetTransform(widget: Widget) Affine {
    return widget.transform;
}

fn emitWidgetBackdropBlur(builder: *Builder, widget: Widget) Error!void {
    const radius = widgetBackdropBlur(widget);
    if (radius <= 0 or widget.frame.normalized().isEmpty()) return;
    try builder.blur(.{
        .id = widgetPartId(widget.id, 12),
        .rect = widget.frame,
        .radius = radius,
    });
}

fn widgetBackdropBlur(widget: Widget) f32 {
    return nonNegative(widget.backdrop_blur);
}

fn widgetClipsContent(widget: Widget) bool {
    return widget.kind == .scroll_view or widget.layout.clip_content;
}

fn widgetContentClip(widget: Widget, tokens: DesignTokens) Clip {
    return .{
        .id = widgetPartId(widget.id, 9),
        .rect = widget.frame,
        .radius = widgetContentClipRadius(widget, tokens),
    };
}

fn widgetContentClipRadius(widget: Widget, tokens: DesignTokens) Radius {
    if (!widget.layout.clip_content) return .{};
    return switch (widget.kind) {
        .panel, .menu_surface => Radius.all(tokens.radius.lg),
        .popover => Radius.all(tokens.radius.xl),
        .tooltip => Radius.all(tokens.radius.md),
        else => .{},
    };
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPanelWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitPopoverWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPopoverWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitMenuSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitMenuSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitScrollViewWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    try builder.popClip();
    try emitScrollViewScrollbar(builder, widget.frame, widgetScrollMetricsForWidget(widget), tokens, widget.id);
}

fn emitWidgetClippedChildren(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    if (widget.layout.clip_content) try builder.popClip();
}

const ScrollbarGeometry = struct {
    track: geometry.RectF,
    thumb: geometry.RectF,
};

fn emitScrollViewScrollbar(builder: *Builder, frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens, id: ObjectId) Error!void {
    const scrollbar = scrollViewScrollbarGeometry(frame, metrics, tokens) orelse return;
    const radius = Radius.all(scrollbar.track.width * 0.5);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 2),
        .rect = scrollbar.track,
        .radius = radius,
        .fill = .{ .color = colorWithAlpha(tokens.colors.border, @min(tokens.colors.border.a, 0.22)) },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 3),
        .rect = scrollbar.thumb,
        .radius = radius,
        .fill = .{ .color = colorWithAlpha(tokens.colors.text_muted, 0.55) },
    });
}

fn scrollViewScrollbarGeometry(frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens) ?ScrollbarGeometry {
    if (!metrics.present) return null;
    const viewport = nonNegative(metrics.viewport_extent);
    const content = nonNegative(metrics.content_extent);
    const max_offset = @max(0, content - viewport);
    if (frame.isEmpty() or viewport <= 0 or content <= viewport or max_offset <= 0) return null;

    const inset = densityValue(tokens, 3);
    const thickness = @min(@max(densityValue(tokens, 3), frame.width * 0.0125), densityValue(tokens, 6));
    const track_height = @max(0, frame.height - inset * 2);
    if (track_height <= 0 or thickness <= 0) return null;

    const track = geometry.RectF.init(
        frame.x + frame.width - inset - thickness,
        frame.y + inset,
        thickness,
        track_height,
    );
    const thumb_ratio = std.math.clamp(viewport / content, 0, 1);
    const min_thumb = @min(track_height, densityValue(tokens, 18));
    const thumb_height = @min(track_height, @max(min_thumb, track_height * thumb_ratio));
    const travel = @max(0, track_height - thumb_height);
    const offset_ratio = std.math.clamp(nonNegative(metrics.offset) / max_offset, 0, 1);
    return .{
        .track = track,
        .thumb = geometry.RectF.init(track.x, track.y + travel * offset_ratio, track.width, thumb_height),
    };
}

fn widgetScrollMetricsForWidget(widget: Widget) WidgetScrollMetrics {
    if (widget.kind != .scroll_view) return .{};

    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtentForWidget(widget, viewport);
    const max_offset = @max(0, content_extent - viewport.height);
    return .{
        .present = true,
        .offset = std.math.clamp(nonNegative(widget.value), 0, max_offset),
        .viewport_extent = viewport.height,
        .content_extent = content_extent,
    };
}

fn widgetScrollContentExtentForWidget(widget: Widget, viewport: geometry.RectF) f32 {
    if (widget.layout.virtualized) {
        return @max(viewport.height, virtualWidgetScrollContentExtent(widget, viewport.height));
    }

    const offset = nonNegative(widget.value);
    var bottom = viewport.maxY();
    for (widget.children) |child| {
        bottom = @max(bottom, child.frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

fn emitWidgetLayoutClippedChildren(
    builder: *Builder,
    layout: WidgetLayoutTree,
    parent_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetLayoutChildren(builder, layout, parent_index, tokens, state);
    if (widget.layout.clip_content) try builder.popClip();
}

fn emitPanelWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.lg);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.hairline,
        },
    });
}

fn emitPopoverWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.xl);
    const shadow_token = tokens.shadow.md;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.hairline,
        },
    });
}

fn emitMenuSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.lg);
    const shadow_token = tokens.shadow.md;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.hairline,
        },
    });
}

fn emitTextWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.body_size,
        .origin = textOrigin(widget.frame, tokens.typography.body_size, 0),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
        .text_layout = .{
            .max_width = widget.frame.width,
            .line_height = tokens.typography.body_size * 1.25,
            .wrap = .word,
            .alignment = widget.text_alignment,
        },
    });
}

fn emitIconWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    if (widget.text.len == 0) return;
    const size = iconGlyphSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = size,
        .origin = centeredTextOrigin(widget.frame, widget.text, size),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
    });
}

fn emitImageWidget(builder: *Builder, widget: Widget) Error!void {
    if (widget.image_id == 0 or widget.frame.normalized().isEmpty()) return;
    try builder.drawImage(.{
        .id = widgetPartId(widget.id, 1),
        .image_id = widget.image_id,
        .src = widget.image_src,
        .dst = widget.frame,
        .opacity = widget.image_opacity,
        .fit = widget.image_fit,
        .sampling = widget.image_sampling,
    });
}

fn emitButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = buttonFillColor(tokens, widget.state) },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.regular,
        },
    });
    if (widget.state.focused) {
        try builder.strokeRect(.{
            .id = widgetPartId(widget.id, 3),
            .rect = widget.frame,
            .radius = radius,
            .stroke = .{
                .fill = .{ .color = tokens.colors.focus_ring },
                .width = tokens.stroke.focus,
            },
        });
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.button_size,
        .origin = textOrigin(widget.frame, tokens.typography.button_size, densityValue(tokens, tokens.spacing.md)),
        .color = buttonTextColor(tokens, widget.state),
        .text = widget.text,
    });
}

fn emitIconButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = buttonFillColor(tokens, widget.state) },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = if (widget.state.focused) tokens.colors.focus_ring else tokens.colors.border },
            .width = if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        },
    });
    if (widget.text.len > 0) {
        const size = iconGlyphSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = centeredTextOrigin(widget.frame, widget.text, size),
            .color = buttonTextColor(tokens, widget.state),
            .text = widget.text,
        });
    }
}

fn emitTextFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    const text_size = widgetTextInputSize(tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const text_color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text;
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const has_text_affordances = selection_range != null or composition_range != null;

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = if (widget.state.disabled) tokens.colors.disabled else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = if (widget.state.focused) tokens.colors.focus_ring else tokens.colors.border },
            .width = if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        },
    });
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 3, 13, max_widget_text_range_rects, tokens);
        }
    }
    if (widget.text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, if (has_text_affordances) 4 else 3);
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 5, 10, max_widget_text_range_rects, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 6, tokens);
            }
        }
    }
}

fn emitSearchFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    const text_size = widgetTextInputSize(tokens);
    const icon_size = @max(8, text_size - 2);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const text_color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text;
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = if (widget.state.disabled) tokens.colors.disabled else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = if (widget.state.focused) tokens.colors.focus_ring else tokens.colors.border },
            .width = if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        },
    });
    try emitSearchFieldIcon(builder, widget, tokens, icon_size);
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 8, 0, 1, tokens);
        }
    }
    const visible_text = if (widget.text.len > 0) widget.text else widget.semantics.label;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, 9);
        command.text = visible_text;
        command.color = if (widget.text.len > 0) text_color else tokens.colors.text_muted;
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 10, 0, 1, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 11, tokens);
            }
        }
    }
}

fn emitSearchFieldIcon(builder: *Builder, widget: Widget, tokens: DesignTokens, icon_size: f32) Error!void {
    const left = widget.frame.x + densityValue(tokens, tokens.spacing.md);
    const top = widget.frame.y + @max(0, (widget.frame.height - icon_size) * 0.5);
    const box = icon_size * 0.58;
    const x0 = left;
    const y0 = top;
    const x1 = left + box;
    const y1 = top + box;
    const stroke = Stroke{ .fill = .{ .color = tokens.colors.text_muted }, .width = tokens.stroke.regular };

    try builder.drawLine(.{ .id = widgetPartId(widget.id, 3), .from = geometry.PointF.init(x0, y0), .to = geometry.PointF.init(x1, y0), .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 4), .from = geometry.PointF.init(x1, y0), .to = geometry.PointF.init(x1, y1), .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 5), .from = geometry.PointF.init(x1, y1), .to = geometry.PointF.init(x0, y1), .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 6), .from = geometry.PointF.init(x0, y1), .to = geometry.PointF.init(x0, y0), .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 7), .from = geometry.PointF.init(x1, y1), .to = geometry.PointF.init(left + icon_size, top + icon_size), .stroke = stroke });
}

fn emitTooltipWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.accent },
    });
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = tokens.typography.label_size,
            .origin = textOrigin(widget.frame, tokens.typography.label_size, densityValue(tokens, tokens.spacing.sm)),
            .color = tokens.colors.accent_text,
            .text = widget.text,
        });
    }
}

fn emitMenuItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitListItemWidget(builder, widget, tokens);
}

fn emitListItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    const fill = listItemFillColor(tokens, widget.state);
    if (fill.a > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = .{ .color = fill },
        });
    }
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 2);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.body_size,
        .origin = textOrigin(widget.frame, tokens.typography.body_size, densityValue(tokens, tokens.spacing.md)),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
    });
}

fn emitDataCellWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const state_fill = listItemFillColor(tokens, widget.state);
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .fill = .{ .color = if (state_fill.a > 0) state_fill else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.hairline,
        },
    });
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 3);
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 4),
            .font_id = tokens.typography.font_id,
            .size = tokens.typography.body_size,
            .origin = textOrigin(widget.frame, tokens.typography.body_size, densityValue(tokens, tokens.spacing.md)),
            .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
            .text = widget.text,
        });
    }
}

fn emitSegmentedControlWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = widget.state.selected or widget.value >= 0.5;
    const radius = Radius.all(tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = if (selected) tokens.colors.accent else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = if (widget.state.focused) tokens.colors.focus_ring else tokens.colors.border },
            .width = if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        },
    });
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.label_size,
        .origin = textOrigin(widget.frame, tokens.typography.label_size, densityValue(tokens, tokens.spacing.md)),
        .color = if (selected) tokens.colors.accent_text else tokens.colors.text,
        .text = widget.text,
    });
}

fn emitCheckboxWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const box_size = @min(@max(densityValue(tokens, 14), widget.frame.height * 0.55), densityValue(tokens, 20));
    const box = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - box_size) * 0.5,
        box_size,
        box_size,
    );
    const selected = booleanControlSelected(widget);
    const radius = Radius.all(tokens.radius.sm);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = box,
        .radius = radius,
        .fill = .{ .color = if (selected) tokens.colors.accent else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = box,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = if (selected) tokens.colors.accent else tokens.colors.border },
            .width = tokens.stroke.regular,
        },
    });
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 3);
    if (selected) {
        const left = geometry.PointF.init(box.x + box.width * 0.26, box.y + box.height * 0.54);
        const mid = geometry.PointF.init(box.x + box.width * 0.43, box.y + box.height * 0.70);
        const right = geometry.PointF.init(box.x + box.width * 0.76, box.y + box.height * 0.32);
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 4),
            .from = left,
            .to = mid,
            .stroke = .{ .fill = .{ .color = tokens.colors.accent_text }, .width = 2 },
        });
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 5),
            .from = mid,
            .to = right,
            .stroke = .{ .fill = .{ .color = tokens.colors.accent_text }, .width = 2 },
        });
    }
    try emitControlLabel(builder, widget, tokens, box.x + box.width + densityValue(tokens, tokens.spacing.sm), 6);
}

fn emitToggleWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = booleanControlSelected(widget);
    const knob_inset = densityValue(tokens, 2);
    const track_width = @min(widget.frame.width, @max(densityValue(tokens, 36), widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, densityValue(tokens, 24));
    const track = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    );
    const track_radius = Radius.all(track.height * 0.5);
    const knob_size = @max(0, track.height - knob_inset * 2);
    const knob_x = if (selected)
        track.x + track.width - knob_size - knob_inset
    else
        track.x + knob_inset;
    const knob = geometry.RectF.init(knob_x, track.y + knob_inset, knob_size, knob_size);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = .{ .color = if (selected) tokens.colors.accent else tokens.colors.surface_pressed },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = track,
        .radius = track_radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.regular,
        },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = Radius.all(knob.height * 0.5),
        .fill = .{ .color = if (selected) tokens.colors.accent_text else tokens.colors.surface },
    });
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 4);
    try emitControlLabel(builder, widget, tokens, track.x + track.width + densityValue(tokens, tokens.spacing.sm), 5);
}

fn emitSliderWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const value = std.math.clamp(widget.value, 0, 1);
    const track_height: f32 = densityValue(tokens, 4);
    const track = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        widget.frame.width,
        track_height,
    );
    const active = geometry.RectF.init(track.x, track.y, track.width * value, track.height);
    const knob_size = @min(@max(densityValue(tokens, 14), widget.frame.height * 0.55), densityValue(tokens, 20));
    const knob_x = std.math.clamp(
        widget.frame.x + widget.frame.width * value - knob_size * 0.5,
        widget.frame.x,
        widget.frame.x + @max(0, widget.frame.width - knob_size),
    );
    const knob = geometry.RectF.init(
        knob_x,
        widget.frame.y + (widget.frame.height - knob_size) * 0.5,
        knob_size,
        knob_size,
    );

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = Radius.all(track.height * 0.5),
        .fill = .{ .color = tokens.colors.surface_pressed },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = active,
        .radius = Radius.all(active.height * 0.5),
        .fill = .{ .color = tokens.colors.accent },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = Radius.all(knob.height * 0.5),
        .fill = .{ .color = if (widget.state.disabled) tokens.colors.disabled else tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 4),
        .rect = knob,
        .radius = Radius.all(knob.height * 0.5),
        .stroke = .{
            .fill = .{ .color = if (widget.state.focused) tokens.colors.focus_ring else tokens.colors.border },
            .width = if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        },
    });
}

fn emitProgressWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(@min(tokens.radius.md, widget.frame.height * 0.5));
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface_pressed },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = geometry.RectF.init(widget.frame.x, widget.frame.y, widget.frame.width * std.math.clamp(widget.value, 0, 1), widget.frame.height),
        .radius = radius,
        .fill = .{ .color = tokens.colors.accent },
    });
}

fn emitWidgetFocusRing(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId) Error!void {
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, slot),
        .rect = widget.frame,
        .radius = Radius.all(tokens.radius.md),
        .stroke = .{
            .fill = .{ .color = tokens.colors.focus_ring },
            .width = tokens.stroke.focus,
        },
    });
}

fn emitControlLabel(builder: *Builder, widget: Widget, tokens: DesignTokens, x: f32, slot: ObjectId) Error!void {
    if (widget.text.len == 0) return;
    try builder.drawText(.{
        .id = widgetPartId(widget.id, slot),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.label_size,
        .origin = geometry.PointF.init(x, textOrigin(widget.frame, tokens.typography.label_size, 0).y),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
    });
}

fn booleanControlSelected(widget: Widget) bool {
    return widget.state.selected or widget.value >= 0.5;
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

fn textOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    return geometry.PointF.init(
        frame.x + inset,
        frame.y + @max(size, (frame.height + size * 0.5) * 0.5),
    );
}

fn centeredTextOrigin(frame: geometry.RectF, text: []const u8, size: f32) geometry.PointF {
    return alignedTextOrigin(frame, text, size, 0, .center);
}

fn alignedTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, inset: f32, alignment: TextAlign) geometry.PointF {
    const width = estimateTextWidth(text, size);
    const available_width = @max(0, frame.width - inset * 2);
    const offset = switch (alignment) {
        .start => 0,
        .center => @max(0, (available_width - width) * 0.5),
        .end => @max(0, available_width - width),
    };
    return geometry.PointF.init(
        frame.x + inset + offset,
        frame.y + @max(size, (frame.height + size * 0.5) * 0.5),
    );
}

fn iconGlyphSize(widget: Widget, tokens: DesignTokens) f32 {
    const min_size = densityValue(tokens, 12);
    if (widget.frame.height > 0) return @min(@max(min_size, widget.frame.height * 0.48), @max(min_size, tokens.typography.title_size));
    return tokens.typography.button_size;
}

fn widgetTextSelectionRange(widget: Widget) ?TextRange {
    if (widget.kind != .text_field and widget.kind != .search_field) return null;
    if (widget.text_selection) |selection| return snapTextRange(widget.text, selection.range(widget.text.len));
    return null;
}

fn widgetTextCompositionRange(widget: Widget) ?TextRange {
    if (widget.kind != .text_field and widget.kind != .search_field) return null;
    if (widget.text_composition) |range| return snapTextRange(widget.text, range);
    return null;
}

pub fn textSelectionForWidgetPoint(widget: Widget, point: geometry.PointF, anchor: ?usize, tokens: DesignTokens) ?TextSelection {
    const offset = textOffsetForWidgetPoint(widget, point, tokens) orelse return null;
    const selection = if (anchor) |anchor_offset|
        TextSelection{ .anchor = anchor_offset, .focus = offset }
    else
        TextSelection.collapsed(offset);
    return snapTextSelection(widget.text, selection);
}

pub fn textOffsetForWidgetPoint(widget: Widget, point: geometry.PointF, tokens: DesignTokens) ?usize {
    if (widget.kind != .text_field and widget.kind != .search_field) return null;
    if (widget.state.disabled) return null;
    const text_size = widgetTextInputSize(tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    return layoutTextOffsetForPoint(draw_text, layout_options, point, &lines) catch null;
}

fn widgetTextInputSize(tokens: DesignTokens) f32 {
    return tokens.typography.body_size;
}

fn widgetTextInputLayoutOptions(widget: Widget, text_size: f32, inset: f32) TextLayoutOptions {
    const line_height = widgetTextInputLineHeight(text_size);
    return .{
        .max_width = @max(1, widget.frame.width - inset * 2),
        .line_height = line_height,
        .wrap = widgetTextInputWrap(widget, line_height),
    };
}

fn widgetTextInputLineHeight(text_size: f32) f32 {
    return text_size * 1.25;
}

fn widgetTextInputWrap(widget: Widget, line_height: f32) TextWrap {
    if (widget.kind == .text_field and widget.frame.height >= line_height * 2.25) return .word;
    return .none;
}

fn widgetTextInputOrigin(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.PointF {
    if (options.wrap != .none) {
        return geometry.PointF.init(
            widget.frame.x + inset,
            widget.frame.y + densityValue(tokens, tokens.spacing.sm) + text_size,
        );
    }
    return textOrigin(widget.frame, text_size, inset);
}

fn widgetTextInputDrawText(
    widget: Widget,
    tokens: DesignTokens,
    text_size: f32,
    origin: geometry.PointF,
    color: Color,
    options: TextLayoutOptions,
) DrawText {
    return .{
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = origin,
        .color = color,
        .text = widget.text,
        .text_layout = options,
    };
}

fn widgetTextInputInset(widget: Widget, tokens: DesignTokens) f32 {
    const text_size = widgetTextInputSize(tokens);
    return switch (widget.kind) {
        .search_field => densityValue(tokens, tokens.spacing.md) + @max(densityValue(tokens, 8), text_size - 2) + densityValue(tokens, tokens.spacing.sm),
        else => densityValue(tokens, tokens.spacing.md),
    };
}

fn densityValue(tokens: DesignTokens, value: f32) f32 {
    return value * densityScale(tokens.density);
}

fn densityScale(density: Density) f32 {
    return switch (density) {
        .compact => 0.875,
        .regular => 1,
        .spacious => 1.125,
    };
}

fn textSelectionFillColor(tokens: DesignTokens) Color {
    return Color.rgba(
        tokens.colors.focus_ring.r,
        tokens.colors.focus_ring.g,
        tokens.colors.focus_ring.b,
        0.18,
    );
}

fn colorWithAlpha(color: Color, alpha: f32) Color {
    return Color.rgba(color.r, color.g, color.b, std.math.clamp(alpha, 0, 1));
}

fn emitWidgetTextSelectionRects(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .rect = selection.rect,
            .radius = Radius.all(tokens.radius.sm),
            .fill = .{ .color = textSelectionFillColor(tokens) },
        });
    }
}

fn emitWidgetTextCompositionLines(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        const y = selection.rect.y + selection.rect.height - 1;
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .from = geometry.PointF.init(selection.rect.x, y),
            .to = geometry.PointF.init(selection.rect.x + selection.rect.width, y),
            .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = 1 },
        });
    }
}

fn widgetTextRangePart(first_part: ObjectId, overflow_first_part: ObjectId, index: usize) ObjectId {
    if (index == 0 or overflow_first_part == 0) return first_part + @as(ObjectId, @intCast(index));
    return overflow_first_part + @as(ObjectId, @intCast(index - 1));
}

fn emitWidgetTextCaret(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    offset: usize,
    part: ObjectId,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const rect = (try layoutTextCaretRect(text, options, offset, &lines)) orelse return;
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, part),
        .from = geometry.PointF.init(rect.x, rect.y),
        .to = geometry.PointF.init(rect.x, rect.y + rect.height),
        .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = tokens.stroke.regular },
    });
}

fn buttonFillColor(tokens: DesignTokens, state: WidgetState) Color {
    if (state.disabled) return tokens.colors.disabled;
    if (state.pressed or state.selected) return tokens.colors.accent;
    if (state.hovered) return tokens.colors.surface_subtle;
    return tokens.colors.surface;
}

fn buttonTextColor(tokens: DesignTokens, state: WidgetState) Color {
    if (state.disabled) return tokens.colors.text_muted;
    if (state.pressed or state.selected) return tokens.colors.accent_text;
    return tokens.colors.text;
}

fn listItemFillColor(tokens: DesignTokens, state: WidgetState) Color {
    if (state.selected or state.pressed) return tokens.colors.surface_pressed;
    if (state.hovered) return tokens.colors.surface_subtle;
    return Color.rgba(0, 0, 0, 0);
}

fn layoutWidgetDepth(
    widget: Widget,
    frame: geometry.RectF,
    parent_index: ?usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
) Error!usize {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (len.* >= output.len) return error.WidgetLayoutListFull;

    const index = len.*;
    output[index] = .{
        .widget = widgetWithFrame(widget, frame),
        .frame = frame,
        .depth = depth,
        .parent_index = parent_index,
    };
    len.* += 1;

    const content = frame.inset(widget.layout.padding);
    switch (widget.kind) {
        .row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout),
        .column => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout),
        .grid => try layoutGridChildren(widget.children, content, index, depth, output, len, widget.layout.gap, widget.layout.columns),
        .data_grid => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout),
        .data_row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout),
        .scroll_view => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout)
        else
            try layoutScrollChildren(widget.children, content, index, depth, output, len, widget.value),
        .list => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout),
        .menu_surface => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout),
        .stack, .panel, .popover => {
            for (widget.children) |child| {
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len);
            }
        },
        .text, .icon, .image, .button, .icon_button, .text_field, .search_field, .tooltip, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .toggle, .slider, .progress => {},
    }

    return index;
}

const LayoutAxis = enum {
    horizontal,
    vertical,
};

fn layoutAxisChildren(
    children: []const Widget,
    content: geometry.RectF,
    axis: LayoutAxis,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    style: WidgetLayoutStyle,
) Error!void {
    if (children.len == 0) return;

    const available_extent = switch (axis) {
        .horizontal => content.width,
        .vertical => content.height,
    };
    const cross_extent = switch (axis) {
        .horizontal => content.height,
        .vertical => content.width,
    };
    const clamped_gap = nonNegative(style.gap);
    const total_gap = clamped_gap * @as(f32, @floatFromInt(children.len - 1));
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += preferredMainExtent(child, axis);
        }
    }

    const remaining = @max(0, available_extent - fixed_extent - total_gap);
    const assigned_extent = assignedAxisChildrenExtent(children, axis, fixed_extent, grow_total, remaining);
    const used_extent = assigned_extent + total_gap;
    const free_extent = @max(0, available_extent - used_extent);
    var child_gap = clamped_gap;
    if (style.main_alignment == .space_between and children.len > 1) {
        child_gap += free_extent / @as(f32, @floatFromInt(children.len - 1));
    }
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    } + mainAxisAlignmentOffset(style.main_alignment, free_extent);

    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            @max(minMainExtent(child, axis), remaining * grow / grow_total)
        else
            preferredMainExtent(child, axis);
        const cross = preferredCrossExtent(child, axis, cross_extent);
        const cross_origin = alignedCrossAxisOrigin(content, axis, cross_extent, cross, child, style.cross_alignment);
        const child_frame = switch (axis) {
            .horizontal => geometry.RectF.init(cursor, cross_origin, main_extent, cross),
            .vertical => geometry.RectF.init(cross_origin, cursor, cross, main_extent),
        };
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len);
        cursor += main_extent + child_gap;
    }
}

fn assignedAxisChildrenExtent(children: []const Widget, axis: LayoutAxis, fixed_extent: f32, grow_total: f32, remaining: f32) f32 {
    if (grow_total <= 0) return fixed_extent;
    var assigned = fixed_extent;
    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        if (grow <= 0) continue;
        assigned += @max(minMainExtent(child, axis), remaining * grow / grow_total);
    }
    return assigned;
}

fn mainAxisAlignmentOffset(alignment: WidgetMainAlignment, free_extent: f32) f32 {
    return switch (alignment) {
        .start, .space_between => 0,
        .center => free_extent * 0.5,
        .end => free_extent,
    };
}

fn alignedCrossAxisOrigin(
    content: geometry.RectF,
    axis: LayoutAxis,
    available_extent: f32,
    child_extent: f32,
    child: Widget,
    alignment: WidgetCrossAlignment,
) f32 {
    const start = switch (axis) {
        .horizontal => content.y,
        .vertical => content.x,
    };
    const offset = switch (axis) {
        .horizontal => child.frame.y,
        .vertical => child.frame.x,
    };
    const free_extent = @max(0, available_extent - child_extent);
    return start + offset + switch (alignment) {
        .stretch, .start => 0,
        .center => free_extent * 0.5,
        .end => free_extent,
    };
}

fn layoutGridChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    gap: f32,
    requested_columns: usize,
) Error!void {
    if (children.len == 0) return;

    const columns = if (requested_columns > 0) @min(requested_columns, children.len) else children.len;
    const rows = (children.len + columns - 1) / columns;
    const clamped_gap = nonNegative(gap);
    const total_column_gap = clamped_gap * @as(f32, @floatFromInt(columns - 1));
    const total_row_gap = clamped_gap * @as(f32, @floatFromInt(rows - 1));
    const cell_width = if (columns > 0) @max(0, content.width - total_column_gap) / @as(f32, @floatFromInt(columns)) else 0;
    const fallback_cell_height = if (rows > 0) @max(0, content.height - total_row_gap) / @as(f32, @floatFromInt(rows)) else 0;

    for (children, 0..) |child, child_index| {
        const column = child_index % columns;
        const row = child_index / columns;
        const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
        const y = content.y + @as(f32, @floatFromInt(row)) * (fallback_cell_height + clamped_gap);
        const width = @max(child.layout.min_size.width, if (child.frame.width > 0) child.frame.width else cell_width);
        const height = @max(child.layout.min_size.height, if (child.frame.height > 0) child.frame.height else fallback_cell_height);
        const child_frame = geometry.RectF.init(
            x + child.frame.x,
            y + child.frame.y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len);
    }
}

fn layoutScrollChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
) Error!void {
    const scrolled_content = content.translate(geometry.OffsetF.init(0, -nonNegative(scroll_y)));
    for (children) |child| {
        _ = try layoutWidgetDepth(child, stackChildFrame(scrolled_content, child), parent_index, depth + 1, output, len);
    }
}

fn layoutVirtualVerticalChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
) Error!void {
    if (children.len == 0) return;

    const item_extent = if (style.virtual_item_extent > 0)
        style.virtual_item_extent
    else
        preferredMainExtent(children[0], .vertical);
    const range = virtualListRange(.{
        .item_count = children.len,
        .item_extent = item_extent,
        .item_gap = style.gap,
        .viewport_extent = content.height,
        .scroll_offset = scroll_y,
        .overscan = style.virtual_overscan,
    });
    if (range.isEmpty()) return;

    const stride = range.item_extent + range.item_gap;
    var index = range.start_index;
    while (index < range.end_index) : (index += 1) {
        const child = children[index];
        const y = content.y + @as(f32, @floatFromInt(index)) * stride - range.scroll_offset + child.frame.y;
        const width = @max(child.layout.min_size.width, if (child.frame.width > 0) child.frame.width else content.width);
        const height = @max(child.layout.min_size.height, if (child.frame.height > 0) child.frame.height else range.item_extent);
        const child_frame = geometry.RectF.init(
            content.x + child.frame.x,
            y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len);
    }
}

fn stackChildFrame(content: geometry.RectF, child: Widget) geometry.RectF {
    const width = if (child.frame.width > 0) child.frame.width else content.width;
    const height = if (child.frame.height > 0) child.frame.height else content.height;
    return geometry.RectF.init(
        content.x + child.frame.x,
        content.y + child.frame.y,
        @max(child.layout.min_size.width, width),
        @max(child.layout.min_size.height, height),
    );
}

fn preferredMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.width,
        .vertical => widget.frame.height,
    };
    return @max(minMainExtent(widget, axis), nonNegative(value));
}

fn preferredCrossExtent(widget: Widget, axis: LayoutAxis, available: f32) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.height,
        .vertical => widget.frame.width,
    };
    const min_value = switch (axis) {
        .horizontal => widget.layout.min_size.height,
        .vertical => widget.layout.min_size.width,
    };
    return @max(min_value, if (value > 0) value else available);
}

fn minMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => nonNegative(widget.layout.min_size.width),
        .vertical => nonNegative(widget.layout.min_size.height),
    };
}

fn hitTestWidgetLayout(layout: WidgetLayoutTree, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    return hitTestWidgetLayoutChildren(layout, null, point, tokens);
}

fn hitTestWidgetLayoutChildren(layout: WidgetLayoutTree, parent_index: ?usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    var tested: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (tested < child_count) : (tested += 1) {
        const child_index = previousWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return null;
        if (hitTestWidgetLayoutNode(layout, child_index, point, tokens)) |hit| return hit;
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
    return null;
}

fn hitTestWidgetLayoutNode(layout: WidgetLayoutTree, node_index: usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    if (node_index >= layout.nodes.len) return null;
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return null;

    const local_point = widgetLocalHitPoint(node.widget, point) orelse return null;
    if (widgetClipsContent(node.widget) and !node.frame.normalized().containsPoint(local_point)) return null;
    if (hitTestWidgetLayoutChildren(layout, node_index, local_point, tokens)) |hit| return hit;

    if (!isHitTarget(node.widget)) return null;
    if (!node.frame.normalized().containsPoint(local_point)) return null;
    return widgetHitFromNode(node, node_index);
}

fn widgetLocalHitPoint(widget: Widget, point: geometry.PointF) ?geometry.PointF {
    const transform = widgetTransform(widget);
    if (affinesEqual(transform, Affine.identity())) return point;
    return if (transform.inverse()) |inverse| inverse.transformPoint(point) else null;
}

fn widgetHitFromNode(node: WidgetLayoutNode, index: usize) WidgetHit {
    return .{
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
        .depth = node.depth,
        .index = index,
        .state = node.widget.state,
    };
}

pub fn cursorForWidgetHit(hit: ?WidgetHit) WidgetCursor {
    const target = hit orelse return .arrow;
    return cursorForWidgetTarget(target.kind, target.state);
}

pub fn cursorForWidgetTarget(kind: WidgetKind, state: WidgetState) WidgetCursor {
    if (state.disabled) return .arrow;
    return switch (kind) {
        .text_field, .search_field => .text,
        .button,
        .icon_button,
        .menu_item,
        .list_item,
        .data_cell,
        .segmented_control,
        .checkbox,
        .toggle,
        => .pointing_hand,
        .slider => .resize_horizontal,
        else => .arrow,
    };
}

fn isPointVisibleInWidgetAncestors(layout: WidgetLayoutTree, node_index: usize, point: geometry.PointF) bool {
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget) and !parent.frame.normalized().containsPoint(point)) return false;
        current = parent.parent_index;
    }
    return true;
}

fn isWidgetFrameVisibleInWidgetAncestors(layout: WidgetLayoutTree, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (frame.isEmpty()) return false;
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget) and geometry.RectF.intersection(frame, parent.frame.normalized()).isEmpty()) return false;
        current = parent.parent_index;
    }
    return true;
}

fn routeWidgetPointerEvent(layout: WidgetLayoutTree, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target = if (eventUsesPointerCapture(event)) blk: {
        break :blk capturedWidgetPointerTarget(layout, event) orelse return .{ .entries = output[0..0] };
    } else hitTestWidgetLayout(layout, event.point, tokens) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

fn eventUsesPointerCapture(event: WidgetPointerEvent) bool {
    if (event.captured_id == null) return false;
    return switch (event.phase) {
        .move, .up, .cancel => true,
        .hover, .down, .wheel => false,
    };
}

fn capturedWidgetPointerTarget(layout: WidgetLayoutTree, event: WidgetPointerEvent) ?WidgetHit {
    const id = event.captured_id orelse return null;
    return switch (event.phase) {
        .move, .up, .cancel => widgetPointerTargetById(layout, id),
        .hover, .down, .wheel => null,
    };
}

fn widgetPointerTargetById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetHit {
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!isHitTarget(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return widgetHitFromNode(node, index);
}

fn routeWidgetKeyboardEvent(layout: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
    const focused_id = event.focused_id orelse return .{ .entries = output[0..0] };
    const target_index = widgetIndexById(layout, focused_id) orelse return .{ .entries = output[0..0] };
    const target = focusTargetFromLayoutNode(layout, target_index) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

fn routeWidgetFileDropEvent(layout: WidgetLayoutTree, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    if (event.paths.len == 0) return .{ .entries = output[0..0] };
    const target_index = widgetDropTargetIndexAtPoint(layout, event.point) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

fn routeWidgetDragEvent(layout: WidgetLayoutTree, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target_index = widgetDragSourceIndex(layout, event.source_id) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

fn widgetDropTargetIndexAtPoint(layout: WidgetLayoutTree, point: geometry.PointF) ?usize {
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = layout.nodes[index];
        if (!isDropTarget(node.widget)) continue;
        if (isWidgetHiddenInAncestors(layout, index)) continue;
        if (!node.frame.normalized().containsPoint(point)) continue;
        if (!isPointVisibleInWidgetAncestors(layout, index, point)) continue;
        return index;
    }
    return null;
}

fn widgetDragSourceIndex(layout: WidgetLayoutTree, id: ObjectId) ?usize {
    if (id == 0) return null;
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!isDragSource(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return index;
}

fn widgetKeyboardTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    return switch (event.phase) {
        .text_input => if (event.text.len > 0 and !event.modifiers.hasCommandModifier()) .{ .insert_text = event.text } else null,
        .key_down => widgetKeyboardKeyDownTextEditEvent(event),
        .key_up => null,
    };
}

fn widgetKeyboardKeyDownTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.modifiers.hasNavigationModifier()) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_forward;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .previous, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .next, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "home")) return .{ .move_caret = .{ .direction = .start, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "end")) return .{ .move_caret = .{ .direction = .end, .extend = event.modifiers.shift } };
    return null;
}

fn routeWidgetEventPath(layout: WidgetLayoutTree, target_index: usize, output: []WidgetEventRouteEntry) Error![]const WidgetEventRouteEntry {
    var path: [max_widget_depth]usize = undefined;
    var path_len: usize = 0;
    var current: ?usize = target_index;
    while (current) |node_index| {
        if (path_len >= path.len) return error.WidgetDepthExceeded;
        path[path_len] = node_index;
        path_len += 1;
        current = layout.nodes[node_index].parent_index;
    }

    var len: usize = 0;
    var capture_index = path_len;
    while (capture_index > 1) {
        capture_index -= 1;
        try appendWidgetEventRouteEntry(output, &len, .capture, layout.nodes[path[capture_index]], path[capture_index]);
    }
    try appendWidgetEventRouteEntry(output, &len, .target, layout.nodes[target_index], target_index);

    var bubble_index: usize = 1;
    while (bubble_index < path_len) : (bubble_index += 1) {
        try appendWidgetEventRouteEntry(output, &len, .bubble, layout.nodes[path[bubble_index]], path[bubble_index]);
    }

    return output[0..len];
}

fn appendWidgetEventRouteEntry(
    output: []WidgetEventRouteEntry,
    len: *usize,
    phase: WidgetEventPhase,
    node: WidgetLayoutNode,
    node_index: usize,
) Error!void {
    if (len.* >= output.len) return error.WidgetEventRouteListFull;
    output[len.*] = .{
        .phase = phase,
        .node_index = node_index,
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
    };
    len.* += 1;
}

fn focusWidgetTarget(layout: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
    if (layout.nodes.len == 0) return null;
    const current_index = if (current_id) |id| widgetIndexById(layout, id) else null;
    return switch (direction) {
        .forward => focusForward(layout, current_index),
        .backward => focusBackward(layout, current_index),
        .left, .right, .up, .down => if (current_index) |index| focusSpatial(layout, index, direction) else null,
    };
}

fn focusWidgetTargetById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetFocusTarget {
    const index = widgetIndexById(layout, id) orelse return null;
    return focusTargetFromLayoutNode(layout, index);
}

fn focusForward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index: usize = if (current_index) |value| value + 1 else 0;
    while (index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    index = 0;
    const stop = current_index orelse layout.nodes.len;
    while (index < stop and index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    return null;
}

fn focusBackward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index = current_index orelse layout.nodes.len;
    while (index > 0) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    index = layout.nodes.len;
    const stop = if (current_index) |value| value + 1 else 0;
    while (index > stop) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    return null;
}

fn focusSpatial(layout: WidgetLayoutTree, current_index: usize, direction: WidgetFocusDirection) ?WidgetFocusTarget {
    const current = focusTargetFromLayoutNode(layout, current_index) orelse return null;
    const current_bounds = current.bounds.normalized();
    const current_center = current_bounds.center();
    var best: ?WidgetFocusTarget = null;
    var best_score = std.math.inf(f32);

    for (layout.nodes, 0..) |_, index| {
        if (index == current_index) continue;
        const target = focusTargetFromLayoutNode(layout, index) orelse continue;
        const target_bounds = target.bounds.normalized();
        const target_center = target_bounds.center();
        if (!spatialFocusCandidate(current_center, target_bounds, direction)) continue;

        const score = spatialFocusScore(current_bounds, target_bounds, current_center, target_center, direction);
        if (score < best_score or (score == best_score and (best == null or target.index < best.?.index))) {
            best = target;
            best_score = score;
        }
    }

    return best;
}

fn focusTargetFromLayoutNode(layout: WidgetLayoutTree, index: usize) ?WidgetFocusTarget {
    if (index >= layout.nodes.len) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return focusTargetFromNode(layout.nodes[index], index);
}

fn spatialFocusCandidate(
    current_center: geometry.PointF,
    target_bounds: geometry.RectF,
    direction: WidgetFocusDirection,
) bool {
    return switch (direction) {
        .left => target_bounds.maxX() <= current_center.x,
        .right => target_bounds.x >= current_center.x,
        .up => target_bounds.maxY() <= current_center.y,
        .down => target_bounds.y >= current_center.y,
        .forward, .backward => false,
    };
}

fn spatialFocusScore(current_bounds: geometry.RectF, target_bounds: geometry.RectF, current_center: geometry.PointF, target_center: geometry.PointF, direction: WidgetFocusDirection) f32 {
    const dx = @abs(target_center.x - current_center.x);
    const dy = @abs(target_center.y - current_center.y);
    const gap_x = rectGapX(current_bounds, target_bounds);
    const gap_y = rectGapY(current_bounds, target_bounds);
    return switch (direction) {
        .left, .right => dx * 4096 + gap_y * 4096 + dy,
        .up, .down => dy * 4096 + gap_x * 4096 + dx,
        .forward, .backward => std.math.inf(f32),
    };
}

fn rectGapX(a: geometry.RectF, b: geometry.RectF) f32 {
    if (rectsOverlapX(a, b)) return 0;
    if (b.x >= a.maxX()) return b.x - a.maxX();
    return a.x - b.maxX();
}

fn rectGapY(a: geometry.RectF, b: geometry.RectF) f32 {
    if (rectsOverlapY(a, b)) return 0;
    if (b.y >= a.maxY()) return b.y - a.maxY();
    return a.y - b.maxY();
}

fn rectsOverlapX(a: geometry.RectF, b: geometry.RectF) bool {
    return @min(a.maxX(), b.maxX()) > @max(a.x, b.x);
}

fn rectsOverlapY(a: geometry.RectF, b: geometry.RectF) bool {
    return @min(a.maxY(), b.maxY()) > @max(a.y, b.y);
}

fn focusTargetFromNode(node: WidgetLayoutNode, index: usize) ?WidgetFocusTarget {
    if (!isFocusable(node.widget)) return null;
    return .{
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
        .index = index,
        .state = node.widget.state,
    };
}

fn widgetIndexById(layout: WidgetLayoutTree, id: ObjectId) ?usize {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return null;
}

fn isWidgetHiddenInAncestors(layout: WidgetLayoutTree, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        const node = layout.nodes[index];
        if (node.widget.semantics.hidden) return true;
        current = node.parent_index;
    }
    return false;
}

fn collectWidgetSemantics(layout: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
    var len: usize = 0;
    var semantic_stack: [max_widget_depth]?usize = [_]?usize{null} ** max_widget_depth;
    var hidden_depth: ?usize = null;

    for (layout.nodes, 0..) |node, node_index| {
        if (node.depth >= max_widget_depth) return error.WidgetDepthExceeded;
        if (hidden_depth) |depth| {
            if (node.depth > depth) continue;
            hidden_depth = null;
        }
        var cursor = node.depth + 1;
        while (cursor < semantic_stack.len) : (cursor += 1) {
            semantic_stack[cursor] = null;
        }

        const role = semanticRole(node.widget);
        if (node.widget.semantics.hidden) {
            hidden_depth = node.depth;
            continue;
        }
        if (role == .none or node.widget.id == 0) continue;
        if (len >= output.len) return error.WidgetSemanticsListFull;

        const parent_index = nearestSemanticParent(semantic_stack[0..node.depth]);
        const grid = widgetGridSemantics(layout, node_index);
        const list = widgetListSemantics(layout, node_index);
        const scroll = widgetScrollSemantics(layout, node_index);
        var actions = semanticActions(node.widget);
        if (scroll.scrollable and !node.widget.state.disabled) {
            actions.focus = true;
            actions.increment = true;
            actions.decrement = true;
        }
        output[len] = .{
            .id = node.widget.id,
            .role = role,
            .label = semanticLabel(node.widget),
            .value = scroll.value orelse semanticValue(node.widget),
            .text_value = semanticTextValue(node.widget),
            .grid_row_index = grid.row_index,
            .grid_column_index = grid.column_index,
            .grid_row_count = grid.row_count,
            .grid_column_count = grid.column_count,
            .list = list.metrics,
            .scroll = scroll.metrics,
            .bounds = node.frame,
            .state = node.widget.state,
            .focusable = semanticFocusable(node.widget, actions),
            .actions = actions,
            .text_selection = widgetTextSelectionRange(node.widget),
            .text_composition = widgetTextCompositionRange(node.widget),
            .parent_index = parent_index,
        };
        semantic_stack[node.depth] = len;
        len += 1;
    }

    return output[0..len];
}

pub const WidgetTextGeometry = struct {
    caret_bounds: ?geometry.RectF = null,
    selection_bounds: ?geometry.RectF = null,
    selection_rect_count: usize = 0,
    composition_bounds: ?geometry.RectF = null,
    composition_rect_count: usize = 0,
};

pub fn textGeometryForWidget(widget: Widget, tokens: DesignTokens) WidgetTextGeometry {
    var value: WidgetTextGeometry = .{};
    if (widget.kind != .text_field and widget.kind != .search_field) return value;
    if (widget.state.disabled) return value;

    const text_size = widgetTextInputSize(tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);

    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const layout = layoutTextRun(draw_text, layout_options, &lines) catch return value;

    if (widgetTextSelectionRange(widget)) |range| {
        if (range.isCollapsed(widget.text.len)) {
            value.caret_bounds = textCaretRectForLayout(draw_text, layout, range.start);
        } else {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
            value.selection_bounds = bounds.bounds;
            value.selection_rect_count = bounds.rect_count;
        }
    }
    if (widgetTextCompositionRange(widget)) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
            value.composition_bounds = bounds.bounds;
            value.composition_rect_count = bounds.rect_count;
        }
    }
    return value;
}

const TextRangeBounds = struct {
    bounds: ?geometry.RectF = null,
    rect_count: usize = 0,
};

fn textRangeBoundsForLayout(text: DrawText, layout: TextLayout, range: TextRange) TextRangeBounds {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return .{};

    var value: TextRangeBounds = .{};
    for (layout.lines) |line| {
        const line_range = textLineRange(text, line);
        const start = @max(normalized.start, line_range.start);
        const end = @min(normalized.end, line_range.end);
        if (start >= end) continue;

        const x0 = textLineCaretX(text, line, start);
        const x1 = textLineCaretX(text, line, end);
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        value.bounds = unionOptionalBounds(
            value.bounds,
            geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
        );
        value.rect_count += 1;
    }
    return value;
}

fn nearestSemanticParent(stack: []const ?usize) ?usize {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        if (stack[index]) |semantic_index| return semantic_index;
    }
    return null;
}

fn semanticRole(widget: Widget) WidgetRole {
    if (widget.semantics.role != .none) return widget.semantics.role;
    return switch (widget.kind) {
        .stack, .row, .column, .grid, .scroll_view, .panel => .group,
        .data_grid => .grid,
        .data_row => .row,
        .popover => .dialog,
        .menu_surface => .menu,
        .list => .list,
        .text => .text,
        .icon, .image => .image,
        .button => .button,
        .icon_button => .button,
        .text_field, .search_field => .textbox,
        .tooltip => .tooltip,
        .menu_item => .menuitem,
        .list_item => .listitem,
        .data_cell => .gridcell,
        .segmented_control => .tab,
        .checkbox => .checkbox,
        .toggle => .switch_control,
        .slider => .slider,
        .progress => .progressbar,
    };
}

fn semanticLabel(widget: Widget) []const u8 {
    if (widget.semantics.label.len > 0) return widget.semantics.label;
    return widget.text;
}

fn semanticValue(widget: Widget) ?f32 {
    if (widget.semantics.value) |value| return value;
    return switch (widget.kind) {
        .list_item, .data_cell, .segmented_control => if (widget.state.selected or widget.value >= 0.5) 1 else 0,
        .checkbox, .toggle => if (booleanControlSelected(widget)) 1 else 0,
        .slider, .progress => std.math.clamp(widget.value, 0, 1),
        else => null,
    };
}

fn semanticTextValue(widget: Widget) []const u8 {
    return switch (widget.kind) {
        .text_field, .search_field => widget.text,
        else => "",
    };
}

const WidgetGridSemantics = struct {
    row_index: ?usize = null,
    column_index: ?usize = null,
    row_count: ?usize = null,
    column_count: ?usize = null,
};

fn widgetGridSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetGridSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    return switch (node.widget.kind) {
        .data_grid => .{
            .row_count = dataGridRowCount(layout, node_index),
            .column_count = maxDataGridColumnCount(layout, node_index),
        },
        .data_row => widgetDataRowGridSemantics(layout, node_index),
        .data_cell => widgetDataCellGridSemantics(layout, node_index),
        else => .{},
    };
}

fn widgetDataRowGridSemantics(layout: WidgetLayoutTree, row_index: usize) WidgetGridSemantics {
    const grid_index = layout.nodes[row_index].parent_index orelse return .{};
    if (grid_index >= layout.nodes.len or layout.nodes[grid_index].widget.kind != .data_grid) return .{};
    const grid = layout.nodes[grid_index].widget;
    const row = layout.nodes[row_index].widget;
    return .{
        .row_index = widgetChildOrdinalByKind(grid, row.id, .data_row) orelse directChildOrdinalByKind(layout, grid_index, row_index, .data_row),
        .row_count = dataGridRowCount(layout, grid_index),
        .column_count = dataRowColumnCount(layout, row_index),
    };
}

fn widgetDataCellGridSemantics(layout: WidgetLayoutTree, cell_index: usize) WidgetGridSemantics {
    const row_index = layout.nodes[cell_index].parent_index orelse return .{};
    if (row_index >= layout.nodes.len or layout.nodes[row_index].widget.kind != .data_row) return .{};
    const grid_index = layout.nodes[row_index].parent_index orelse return .{};
    if (grid_index >= layout.nodes.len or layout.nodes[grid_index].widget.kind != .data_grid) return .{};
    const grid = layout.nodes[grid_index].widget;
    const row = layout.nodes[row_index].widget;
    const cell = layout.nodes[cell_index].widget;
    return .{
        .row_index = widgetChildOrdinalByKind(grid, row.id, .data_row) orelse directChildOrdinalByKind(layout, grid_index, row_index, .data_row),
        .column_index = widgetChildOrdinalByKind(row, cell.id, .data_cell) orelse directChildOrdinalByKind(layout, row_index, cell_index, .data_cell),
        .row_count = dataGridRowCount(layout, grid_index),
        .column_count = dataRowColumnCount(layout, row_index),
    };
}

fn widgetChildCountByKind(widget: Widget, kind: WidgetKind) usize {
    var count: usize = 0;
    for (widget.children) |child| {
        if (child.kind == kind) count += 1;
    }
    return count;
}

fn widgetChildOrdinalByKind(widget: Widget, child_id: ObjectId, kind: WidgetKind) ?usize {
    if (child_id == 0) return null;
    var ordinal: usize = 0;
    for (widget.children) |child| {
        if (child.kind != kind) continue;
        if (child.id == child_id) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn dataGridRowCount(layout: WidgetLayoutTree, grid_index: usize) usize {
    const source_count = widgetChildCountByKind(layout.nodes[grid_index].widget, .data_row);
    if (source_count > 0) return source_count;
    return directChildCountByKind(layout, grid_index, .data_row);
}

fn dataRowColumnCount(layout: WidgetLayoutTree, row_index: usize) usize {
    const source_count = widgetChildCountByKind(layout.nodes[row_index].widget, .data_cell);
    if (source_count > 0) return source_count;
    return directChildCountByKind(layout, row_index, .data_cell);
}

fn directChildCountByKind(layout: WidgetLayoutTree, parent_index: usize, kind: WidgetKind) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (node.parent_index == parent_index and node.widget.kind == kind) count += 1;
    }
    return count;
}

fn directChildOrdinalByKind(layout: WidgetLayoutTree, parent_index: usize, child_index: usize, kind: WidgetKind) ?usize {
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent_index or node.widget.kind != kind) continue;
        if (index == child_index) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn maxDataGridColumnCount(layout: WidgetLayoutTree, grid_index: usize) usize {
    var max_columns: usize = 0;
    if (layout.nodes[grid_index].widget.children.len > 0) {
        for (layout.nodes[grid_index].widget.children) |row| {
            if (row.kind != .data_row) continue;
            max_columns = @max(max_columns, widgetChildCountByKind(row, .data_cell));
        }
        return max_columns;
    }
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != grid_index or node.widget.kind != .data_row) continue;
        max_columns = @max(max_columns, dataRowColumnCount(layout, index));
    }
    return max_columns;
}

const WidgetListSemantics = struct {
    metrics: WidgetListMetrics = .{},
};

fn widgetListSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetListSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    if (node.widget.kind != .list_item) return .{};

    const list_index = node.parent_index orelse return .{};
    if (list_index >= layout.nodes.len or layout.nodes[list_index].widget.kind != .list) return .{};

    if (node.widget.semantics.list_item_index) |item_index| {
        if (node.widget.semantics.list_item_count) |item_count| {
            return .{ .metrics = .{
                .present = true,
                .item_index = item_index,
                .item_count = item_count,
            } };
        }
    }

    const list = layout.nodes[list_index].widget;
    const source_count = widgetChildCountByKind(list, .list_item);
    const item_count = if (source_count > 0) source_count else directChildCountByKind(layout, list_index, .list_item);
    if (item_count == 0) return .{};

    const item_index = widgetChildOrdinalByKind(list, node.widget.id, .list_item) orelse
        directChildOrdinalByKind(layout, list_index, node_index, .list_item) orelse return .{};
    return .{ .metrics = .{
        .present = true,
        .item_index = saturatingU32(item_index),
        .item_count = saturatingU32(item_count),
    } };
}

fn saturatingU32(value: usize) u32 {
    return if (value > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(value);
}

const WidgetScrollSemantics = struct {
    metrics: WidgetScrollMetrics = .{},
    value: ?f32 = null,
    scrollable: bool = false,
};

fn widgetScrollSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetScrollSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    if (node.widget.kind != .scroll_view) return .{};

    const viewport = node.frame.inset(node.widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtent(layout, node_index, viewport);
    const max_offset = @max(0, content_extent - viewport.height);
    const offset = std.math.clamp(nonNegative(node.widget.value), 0, max_offset);
    return .{
        .metrics = .{
            .present = true,
            .offset = offset,
            .viewport_extent = viewport.height,
            .content_extent = content_extent,
        },
        .value = if (max_offset > 0) offset / max_offset else 0,
        .scrollable = max_offset > 0,
    };
}

fn widgetScrollContentExtent(layout: WidgetLayoutTree, scroll_index: usize, viewport: geometry.RectF) f32 {
    const scroll_node = layout.nodes[scroll_index];
    if (scroll_node.widget.layout.virtualized) {
        return @max(viewport.height, virtualWidgetScrollContentExtent(scroll_node.widget, viewport.height));
    }

    const scroll_depth = scroll_node.depth;
    const offset = nonNegative(scroll_node.widget.value);
    var bottom = viewport.maxY();
    var index = scroll_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > scroll_depth) : (index += 1) {
        bottom = @max(bottom, layout.nodes[index].frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

fn virtualWidgetScrollContentExtent(widget: Widget, viewport_extent: f32) f32 {
    if (widget.children.len == 0) return 0;
    const item_extent = if (widget.layout.virtual_item_extent > 0)
        widget.layout.virtual_item_extent
    else
        preferredMainExtent(widget.children[0], .vertical);
    return virtualListRange(.{
        .item_count = widget.children.len,
        .item_extent = item_extent,
        .item_gap = widget.layout.gap,
        .viewport_extent = viewport_extent,
        .scroll_offset = widget.value,
    }).content_extent;
}

fn semanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};
    var actions = defaultSemanticActions(widget);
    actions.focus = actions.focus or widget.semantics.actions.focus;
    actions.press = actions.press or widget.semantics.actions.press;
    actions.toggle = actions.toggle or widget.semantics.actions.toggle;
    actions.increment = actions.increment or widget.semantics.actions.increment;
    actions.decrement = actions.decrement or widget.semantics.actions.decrement;
    actions.set_text = actions.set_text or widget.semantics.actions.set_text;
    actions.set_selection = actions.set_selection or widget.semantics.actions.set_selection;
    actions.select = actions.select or widget.semantics.actions.select;
    actions.drag = actions.drag or widget.semantics.actions.drag;
    actions.drop_files = actions.drop_files or widget.semantics.actions.drop_files;
    return actions;
}

fn semanticFocusable(widget: Widget, actions: WidgetActions) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or actions.focus or defaultFocusable(widget);
}

fn defaultSemanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};

    var actions = WidgetActions{
        .focus = widget.semantics.focusable or defaultFocusable(widget),
    };
    switch (widget.kind) {
        .button, .icon_button, .menu_item => actions.press = true,
        .checkbox, .toggle => actions.toggle = true,
        .text_field, .search_field => {
            actions.set_text = true;
            actions.set_selection = true;
        },
        .slider => {
            actions.increment = true;
            actions.decrement = true;
        },
        .list_item, .segmented_control, .data_cell => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        else => {},
    }
    return actions;
}

fn defaultFocusable(widget: Widget) bool {
    return switch (widget.kind) {
        .scroll_view, .button, .icon_button, .text_field, .search_field, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .toggle, .slider => !widget.state.disabled,
        else => false,
    };
}

fn isFocusable(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or defaultFocusable(widget);
}

fn isDropTarget(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        widget.semantics.actions.drop_files;
}

fn isDragSource(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        widget.semantics.actions.drag;
}

fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .grid, .data_grid, .data_row, .list, .stack, .tooltip, .icon, .image => false,
        .scroll_view, .panel, .popover, .menu_surface, .text, .button, .icon_button, .text_field, .search_field, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .toggle, .slider, .progress => true,
    };
}

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
    return copy;
}

fn widgetWithRenderState(widget: Widget, state: WidgetRenderState) Widget {
    var copy = widget;
    if (state.focused_id) |focused_id| {
        copy.state.focused = copy.id != 0 and copy.id == focused_id;
    }
    if (state.hovered_id) |hovered_id| {
        copy.state.hovered = copy.id != 0 and copy.id == hovered_id;
    }
    if (state.pressed_id) |pressed_id| {
        copy.state.pressed = copy.id != 0 and copy.id == pressed_id;
    }
    return copy;
}

fn diffWidgetLayoutTrees(previous: WidgetLayoutTree, next: WidgetLayoutTree, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
    try validateUniqueWidgetIds(previous);
    try validateUniqueWidgetIds(next);

    var len: usize = 0;
    for (previous.nodes, 0..) |previous_node, previous_index| {
        const id = previous_node.widget.id;
        if (id == 0) continue;
        const next_ref = findWidgetNodeById(next, id) orelse {
            try appendWidgetInvalidation(output, &len, .{
                .kind = .removed,
                .id = id,
                .previous_index = previous_index,
                .dirty_bounds = widgetClippedDirtyBounds(previous, previous_index, widgetFullPaintBounds(previous_node)),
                .layout_dirty = true,
                .paint_dirty = true,
                .semantics_dirty = true,
            });
            continue;
        };

        var change = widgetChange(previous_node, next_ref.node, previous_index, next_ref.index);
        if (previous_node.widget.semantics.hidden != next_ref.node.widget.semantics.hidden) {
            change.dirty_bounds = unionOptionalBounds(
                widgetVisibleSubtreeFullPaintBounds(previous, previous_index),
                widgetVisibleSubtreeFullPaintBounds(next, next_ref.index),
            );
        } else if (previous_node.widget.opacity != next_ref.node.widget.opacity or !affinesEqual(previous_node.widget.transform, next_ref.node.widget.transform)) {
            change.dirty_bounds = unionOptionalBounds(
                widgetVisibleSubtreeFullPaintBounds(previous, previous_index),
                widgetVisibleSubtreeFullPaintBounds(next, next_ref.index),
            );
        } else {
            change.dirty_bounds = widgetChangedClippedDirtyBounds(previous, previous_index, next, next_ref.index, change.dirty_bounds);
        }
        if (change.layout_dirty or change.paint_dirty or change.semantics_dirty) {
            try appendWidgetInvalidation(output, &len, change);
        }
    }

    for (next.nodes, 0..) |next_node, next_index| {
        const id = next_node.widget.id;
        if (id == 0) continue;
        if (findWidgetNodeById(previous, id) == null) {
            try appendWidgetInvalidation(output, &len, .{
                .kind = .added,
                .id = id,
                .next_index = next_index,
                .dirty_bounds = widgetClippedDirtyBounds(next, next_index, widgetFullPaintBounds(next_node)),
                .layout_dirty = true,
                .paint_dirty = true,
                .semantics_dirty = true,
            });
        }
    }

    return output[0..len];
}

fn appendWidgetInvalidation(output: []WidgetInvalidation, len: *usize, invalidation: WidgetInvalidation) Error!void {
    if (len.* >= output.len) return error.WidgetInvalidationListFull;
    output[len.*] = invalidation;
    len.* += 1;
}

const WidgetNodeRef = struct {
    index: usize,
    node: WidgetLayoutNode,
};

fn findWidgetNodeById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetNodeRef {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return .{ .index = index, .node = node };
    }
    return null;
}

fn validateUniqueWidgetIds(layout: WidgetLayoutTree) Error!void {
    for (layout.nodes, 0..) |node, index| {
        const id = node.widget.id;
        if (id == 0) continue;
        var cursor = index + 1;
        while (cursor < layout.nodes.len) : (cursor += 1) {
            if (layout.nodes[cursor].widget.id == id) return error.DuplicateWidgetId;
        }
    }
}

fn widgetChange(previous: WidgetLayoutNode, next: WidgetLayoutNode, previous_index: usize, next_index: usize) WidgetInvalidation {
    const layout_dirty =
        previous.widget.kind != next.widget.kind or
        previous.depth != next.depth or
        previous.parent_index != next.parent_index or
        !rectsEqual(previous.frame, next.frame) or
        !widgetLayoutStylesEqual(previous.widget.layout, next.widget.layout);
    const content_dirty = !std.mem.eql(u8, previous.widget.text, next.widget.text) or
        previous.widget.value != next.widget.value or
        previous.widget.image_id != next.widget.image_id or
        !optionalRectsEqual(previous.widget.image_src, next.widget.image_src) or
        previous.widget.image_fit != next.widget.image_fit or
        previous.widget.image_sampling != next.widget.image_sampling or
        previous.widget.image_opacity != next.widget.image_opacity or
        !optionalTextSelectionsEqual(previous.widget.text_selection, next.widget.text_selection) or
        !optionalTextRangesEqual(previous.widget.text_composition, next.widget.text_composition);
    const behavior_dirty = !std.mem.eql(u8, previous.widget.command, next.widget.command);
    const visual_dirty = previous.widget.opacity != next.widget.opacity or
        !affinesEqual(previous.widget.transform, next.widget.transform) or
        previous.widget.backdrop_blur != next.widget.backdrop_blur or
        previous.widget.text_alignment != next.widget.text_alignment;
    const state_dirty = !widgetStatesEqual(previous.widget.state, next.widget.state);
    const visibility_dirty = previous.widget.semantics.hidden != next.widget.semantics.hidden;
    const layer_dirty = previous.widget.layer != next.widget.layer;
    const semantics_dirty =
        layout_dirty or
        content_dirty or
        behavior_dirty or
        state_dirty or
        !widgetSemanticsEqual(previous.widget.semantics, next.widget.semantics);
    const paint_dirty = layout_dirty or content_dirty or visual_dirty or state_dirty or visibility_dirty or layer_dirty;

    const dirty_bounds = if (layout_dirty or visibility_dirty or layer_dirty)
        unionOptionalBounds(widgetFullPaintBounds(previous), widgetFullPaintBounds(next))
    else if (paint_dirty)
        widgetPaintChangeBounds(previous.widget, next.widget)
    else
        null;

    return .{
        .kind = .changed,
        .id = previous.widget.id,
        .previous_index = previous_index,
        .next_index = next_index,
        .dirty_bounds = dirty_bounds,
        .layout_dirty = layout_dirty,
        .paint_dirty = paint_dirty,
        .semantics_dirty = semantics_dirty,
    };
}

fn widgetRenderStateDirtyBounds(layout: WidgetLayoutTree, previous: WidgetRenderState, next: WidgetRenderState) ?geometry.RectF {
    var ids: [6]?ObjectId = [_]?ObjectId{null} ** 6;
    var id_len: usize = 0;
    if (previous.focused_id != next.focused_id) {
        appendOptionalObjectId(&ids, &id_len, previous.focused_id);
        appendOptionalObjectId(&ids, &id_len, next.focused_id);
    }
    if (previous.hovered_id != next.hovered_id) {
        appendOptionalObjectId(&ids, &id_len, previous.hovered_id);
        appendOptionalObjectId(&ids, &id_len, next.hovered_id);
    }
    if (previous.pressed_id != next.pressed_id) {
        appendOptionalObjectId(&ids, &id_len, previous.pressed_id);
        appendOptionalObjectId(&ids, &id_len, next.pressed_id);
    }

    var bounds: ?geometry.RectF = null;
    for (ids[0..id_len]) |maybe_id| {
        const id = maybe_id orelse continue;
        const index = widgetIndexById(layout, id) orelse continue;
        const node = layout.nodes[index];
        const base = widgetWithFrame(node.widget, node.frame);
        const previous_widget = widgetWithRenderState(base, previous);
        const next_widget = widgetWithRenderState(base, next);
        if (widgetStatesEqual(previous_widget.state, next_widget.state)) continue;
        bounds = unionOptionalBounds(bounds, widgetClippedDirtyBounds(layout, index, widgetPaintChangeBounds(previous_widget, next_widget)));
    }
    return bounds;
}

fn appendOptionalObjectId(output: []?ObjectId, len: *usize, maybe_id: ?ObjectId) void {
    const id = maybe_id orelse return;
    if (id == 0) return;
    for (output[0..len.*]) |existing| {
        if (existing != null and existing.? == id) return;
    }
    if (len.* >= output.len) return;
    output[len.*] = id;
    len.* += 1;
}

fn widgetFullPaintBounds(node: WidgetLayoutNode) geometry.RectF {
    return widgetFullPaintBoundsWithTransform(node, widgetTransform(node.widget));
}

fn widgetFullPaintBoundsWithTransform(node: WidgetLayoutNode, transform: Affine) geometry.RectF {
    var bounds = node.frame.normalized();
    if (widgetFrameStrokeBounds(node.widget)) |stroke_bounds| {
        bounds = geometry.RectF.unionWith(bounds, stroke_bounds.normalized());
    }
    if (widgetShadowPaintBounds(node.widget)) |shadow_bounds| {
        bounds = geometry.RectF.unionWith(bounds, shadow_bounds.normalized());
    }
    if (widgetBackdropBlurPaintBounds(node.widget)) |blur_bounds| {
        bounds = geometry.RectF.unionWith(bounds, blur_bounds.normalized());
    }
    return transform.transformRect(bounds).normalized();
}

fn widgetVisibleSubtreeFullPaintBounds(layout: WidgetLayoutTree, root_index: usize) ?geometry.RectF {
    if (root_index >= layout.nodes.len) return null;

    const root_depth = layout.nodes[root_index].depth;
    var bounds: ?geometry.RectF = null;
    var hidden_depth: ?usize = null;
    var index = root_index;
    while (index < layout.nodes.len) : (index += 1) {
        const node = layout.nodes[index];
        if (index != root_index and node.depth <= root_depth) break;
        if (hidden_depth) |depth| {
            if (node.depth > depth) continue;
            hidden_depth = null;
        }
        if (node.widget.semantics.hidden) {
            hidden_depth = node.depth;
            continue;
        }
        bounds = unionOptionalBounds(bounds, widgetClippedDirtyBounds(layout, index, widgetFullPaintBoundsWithTransform(node, widgetAccumulatedTransform(layout, index))));
    }
    return bounds;
}

fn widgetAccumulatedTransform(layout: WidgetLayoutTree, node_index: usize) Affine {
    var indices: [max_widget_depth]usize = undefined;
    var len: usize = 0;
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len or len >= indices.len) break;
        indices[len] = index;
        len += 1;
        current = layout.nodes[index].parent_index;
    }

    var transform = Affine.identity();
    while (len > 0) {
        len -= 1;
        transform = transform.multiply(widgetTransform(layout.nodes[indices[len]].widget));
    }
    return transform;
}

fn widgetChangedClippedDirtyBounds(
    previous: WidgetLayoutTree,
    previous_index: usize,
    next: WidgetLayoutTree,
    next_index: usize,
    bounds: ?geometry.RectF,
) ?geometry.RectF {
    return unionOptionalBounds(
        widgetClippedDirtyBounds(previous, previous_index, bounds),
        widgetClippedDirtyBounds(next, next_index, bounds),
    );
}

fn widgetClippedDirtyBounds(layout: WidgetLayoutTree, node_index: usize, bounds: ?geometry.RectF) ?geometry.RectF {
    if (node_index >= layout.nodes.len) return null;
    if (isWidgetHiddenInAncestors(layout, node_index)) return null;

    var clipped = (bounds orelse return null).normalized();
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        if (parent_index >= layout.nodes.len) return null;
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget)) {
            clipped = geometry.RectF.intersection(clipped, parent.frame.normalized());
            if (clipped.isEmpty()) return null;
        }
        current = parent.parent_index;
    }
    return clipped;
}

fn widgetPaintChangeBounds(previous: Widget, next: Widget) ?geometry.RectF {
    var bounds = unionOptionalBounds(previous.frame, next.frame);
    bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(previous));
    bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(next));
    bounds = unionOptionalBounds(bounds, widgetBackdropBlurPaintBounds(previous));
    bounds = unionOptionalBounds(bounds, widgetBackdropBlurPaintBounds(next));
    return bounds;
}

fn widgetFrameStrokeBounds(widget: Widget) ?geometry.RectF {
    const width = widgetFrameStrokeWidth(widget);
    if (width <= 0) return null;
    return strokeBounds(widget.frame, width);
}

fn widgetFocusPaintBounds(widget: Widget) ?geometry.RectF {
    if (!widget.state.focused or widgetFocusStrokeWidth(widget) <= 0) return null;
    const tokens: DesignTokens = .{};
    return strokeBounds(widget.frame, tokens.stroke.focus);
}

fn widgetFrameStrokeWidth(widget: Widget) f32 {
    const tokens: DesignTokens = .{};
    return switch (widget.kind) {
        .panel, .popover, .menu_surface => tokens.stroke.hairline,
        .button, .icon_button, .text_field, .search_field, .segmented_control => if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        .data_cell => if (widget.state.focused) tokens.stroke.focus else tokens.stroke.hairline,
        .slider => if (widget.state.focused) tokens.stroke.focus else tokens.stroke.regular,
        .list_item, .menu_item, .checkbox, .toggle => if (widget.state.focused) tokens.stroke.focus else 0,
        else => 0,
    };
}

fn widgetFocusStrokeWidth(widget: Widget) f32 {
    const tokens: DesignTokens = .{};
    return switch (widget.kind) {
        .button,
        .icon_button,
        .text_field,
        .search_field,
        .menu_item,
        .list_item,
        .data_cell,
        .segmented_control,
        .checkbox,
        .toggle,
        .slider,
        => tokens.stroke.focus,
        else => 0,
    };
}

fn widgetShadowPaintBounds(widget: Widget) ?geometry.RectF {
    const tokens: DesignTokens = .{};
    const token = switch (widget.kind) {
        .panel, .tooltip => tokens.shadow.sm,
        .popover, .menu_surface => tokens.shadow.md,
        else => return null,
    };
    if (token.y == 0 and token.blur == 0 and token.spread == 0) return null;
    return shadowBounds(.{
        .rect = widget.frame,
        .radius = widgetShadowRadius(widget),
        .offset = .{ .dx = 0, .dy = token.y },
        .blur = token.blur,
        .spread = token.spread,
        .color = tokens.colors.shadow,
    });
}

fn widgetBackdropBlurPaintBounds(widget: Widget) ?geometry.RectF {
    const radius = widgetBackdropBlur(widget);
    if (radius <= 0) return null;
    return widget.frame.normalized().inflate(geometry.InsetsF.all(radius));
}

fn widgetShadowRadius(widget: Widget) Radius {
    const tokens: DesignTokens = .{};
    return switch (widget.kind) {
        .popover => Radius.all(tokens.radius.xl),
        .panel, .menu_surface => Radius.all(tokens.radius.lg),
        .tooltip => Radius.all(tokens.radius.md),
        else => Radius.all(0),
    };
}

fn widgetStatesEqual(a: WidgetState, b: WidgetState) bool {
    return a.hovered == b.hovered and
        a.pressed == b.pressed and
        a.focused == b.focused and
        a.disabled == b.disabled and
        a.selected == b.selected;
}

fn widgetLayoutStylesEqual(a: WidgetLayoutStyle, b: WidgetLayoutStyle) bool {
    return insetsEqual(a.padding, b.padding) and
        a.gap == b.gap and
        a.grow == b.grow and
        a.main_alignment == b.main_alignment and
        a.cross_alignment == b.cross_alignment and
        a.clip_content == b.clip_content and
        a.columns == b.columns and
        a.virtualized == b.virtualized and
        a.virtual_item_extent == b.virtual_item_extent and
        a.virtual_overscan == b.virtual_overscan and
        sizesEqual(a.min_size, b.min_size);
}

fn widgetSemanticsEqual(a: WidgetSemantics, b: WidgetSemantics) bool {
    return a.role == b.role and
        std.mem.eql(u8, a.label, b.label) and
        optionalF32Equal(a.value, b.value) and
        a.list_item_index == b.list_item_index and
        a.list_item_count == b.list_item_count and
        widgetActionsEqual(a.actions, b.actions) and
        a.hidden == b.hidden and
        a.focusable == b.focusable;
}

fn widgetActionsEqual(a: WidgetActions, b: WidgetActions) bool {
    return a.focus == b.focus and
        a.press == b.press and
        a.toggle == b.toggle and
        a.increment == b.increment and
        a.decrement == b.decrement and
        a.set_text == b.set_text and
        a.set_selection == b.set_selection and
        a.select == b.select and
        a.drag == b.drag and
        a.drop_files == b.drop_files;
}

fn glyphAtlasKeysEqual(a: GlyphAtlasKey, b: GlyphAtlasKey) bool {
    return a.font_id == b.font_id and
        a.glyph_id == b.glyph_id and
        a.size == b.size and
        a.subpixel_x == b.subpixel_x and
        a.subpixel_y == b.subpixel_y;
}

fn glyphFontId(run_font_id: FontId, glyph: Glyph) FontId {
    return if (glyph.font_id == 0) run_font_id else glyph.font_id;
}

fn findGlyphAtlasCacheEntry(entries: []const GlyphAtlasCacheEntry, key: GlyphAtlasKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (glyphAtlasKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn diffDisplayLists(previous: DisplayList, next: DisplayList, output: []DiffChange) Error![]const DiffChange {
    try validateUniqueObjectIds(previous);
    try validateUniqueObjectIds(next);

    var len: usize = 0;
    if (!unkeyedCommandsEqual(previous, next)) {
        try appendDiffChange(output, &len, .{
            .kind = .scene_changed,
            .dirty_bounds = unionOptionalBounds(previous.bounds(), next.bounds()),
        });
    }

    for (previous.commands, 0..) |previous_command, previous_index| {
        const id = previous_command.objectId() orelse continue;
        const next_ref = next.findCommandById(id) orelse {
            try appendDiffChange(output, &len, .{
                .kind = .removed,
                .id = id,
                .previous_index = previous_index,
                .dirty_bounds = previous_command.bounds(),
            });
            continue;
        };

        if (previous_index != next_ref.index or !commandsEqual(previous_command, next_ref.command)) {
            try appendDiffChange(output, &len, .{
                .kind = .changed,
                .id = id,
                .previous_index = previous_index,
                .next_index = next_ref.index,
                .dirty_bounds = unionOptionalBounds(previous_command.bounds(), next_ref.command.bounds()),
            });
        }
    }

    for (next.commands, 0..) |next_command, next_index| {
        const id = next_command.objectId() orelse continue;
        if (previous.findCommandById(id) == null) {
            try appendDiffChange(output, &len, .{
                .kind = .added,
                .id = id,
                .next_index = next_index,
                .dirty_bounds = next_command.bounds(),
            });
        }
    }

    return output[0..len];
}

fn appendDiffChange(output: []DiffChange, len: *usize, change: DiffChange) Error!void {
    if (len.* >= output.len) return error.DiffListFull;
    output[len.*] = change;
    len.* += 1;
}

fn validateUniqueObjectIds(display_list: DisplayList) Error!void {
    for (display_list.commands, 0..) |command, index| {
        const id = command.objectId() orelse continue;
        var cursor = index + 1;
        while (cursor < display_list.commands.len) : (cursor += 1) {
            if (display_list.commands[cursor].objectId()) |other_id| {
                if (other_id == id) return error.DuplicateObjectId;
            }
        }
    }
}

fn unkeyedCommandsEqual(previous: DisplayList, next: DisplayList) bool {
    var previous_index: usize = 0;
    var next_index: usize = 0;
    while (true) {
        const previous_command = nextUnkeyedCommand(previous, &previous_index);
        const next_command = nextUnkeyedCommand(next, &next_index);
        if (previous_command == null and next_command == null) return true;
        if (previous_command == null or next_command == null) return false;
        if (!commandsEqual(previous_command.?, next_command.?)) return false;
    }
}

fn nextUnkeyedCommand(display_list: DisplayList, index: *usize) ?CanvasCommand {
    while (index.* < display_list.commands.len) : (index.* += 1) {
        const command = display_list.commands[index.*];
        if (command.objectId() == null) {
            index.* += 1;
            return command;
        }
    }
    return null;
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
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

fn boundsFromPoints(points: []const geometry.PointF) ?geometry.RectF {
    if (points.len == 0) return null;
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points[1..]) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn strokeBounds(rect: geometry.RectF, width: f32) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(nonNegative(width) * 0.5));
}

const ReferencePixelRect = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
};

const reference_curve_segments: usize = 12;

fn referenceCommandBounds(command: RenderCommand, scissor: ?geometry.RectF) ?geometry.RectF {
    var bounds = command.bounds.normalized();
    if (scissor) |rect| {
        bounds = geometry.RectF.intersection(bounds, rect.normalized());
    }
    return if (bounds.isEmpty()) null else bounds;
}

fn referencePassScale(scale: f32) f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return 1;
    return scale;
}

fn referenceScaleCommand(command: RenderCommand, scale: f32) RenderCommand {
    if (scale == 1) return command;
    var scaled = command;
    const transform = Affine.scale(scale, scale);
    scaled.transform = transform.multiply(command.transform);
    scaled.local_bounds = referenceScaleRect(command.local_bounds, scale);
    scaled.bounds = referenceScaleRect(command.bounds, scale);
    if (command.clip) |clip| scaled.clip = referenceScaleRect(clip, scale);
    return scaled;
}

fn referenceScaleRect(rect: geometry.RectF, scale: f32) geometry.RectF {
    return geometry.RectF.init(rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale);
}

fn referencePixelCenter(x: usize, y: usize) geometry.PointF {
    return geometry.PointF.init(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
}

fn referenceSampleFill(fill: Fill, transform: Affine, point: geometry.PointF) Color {
    return switch (fill) {
        .color => |color| color,
        .linear_gradient => |gradient| referenceSampleLinearGradient(gradient, transform, point),
    };
}

fn isReferenceTextSpace(byte: u8) bool {
    return byte == '\n' or byte == '\r' or byte == '\t' or byte == ' ';
}

fn referenceSampleLinearGradient(gradient: LinearGradient, transform: Affine, point: geometry.PointF) Color {
    if (gradient.stops.len == 0) return Color.rgba8(0, 0, 0, 0);
    if (gradient.stops.len == 1) return gradient.stops[0].color;

    const start = transform.transformPoint(gradient.start);
    const end = transform.transformPoint(gradient.end);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const length_sq = dx * dx + dy * dy;
    const t = if (length_sq <= 0.000001) 0 else ((point.x - start.x) * dx + (point.y - start.y) * dy) / length_sq;

    var previous = gradient.stops[0];
    if (t <= previous.offset) return previous.color;
    for (gradient.stops[1..]) |stop| {
        if (t <= stop.offset) {
            const span = stop.offset - previous.offset;
            const local_t = if (@abs(span) <= 0.000001) 1 else std.math.clamp((t - previous.offset) / span, 0, 1);
            return referenceMixColor(previous.color, stop.color, local_t);
        }
        previous = stop;
    }
    return previous.color;
}

fn referenceMixColor(a: Color, b: Color, t: f32) Color {
    const value = std.math.clamp(t, 0, 1);
    return .{
        .r = referenceMixSrgb(a.r, b.r, value),
        .g = referenceMixSrgb(a.g, b.g, value),
        .b = referenceMixSrgb(a.b, b.b, value),
        .a = a.a + (b.a - a.a) * value,
    };
}

fn referenceMixSrgb(a: f32, b: f32, t: f32) f32 {
    const start = referenceSrgbToLinear(a);
    const end = referenceSrgbToLinear(b);
    return referenceLinearToSrgb(start + (end - start) * std.math.clamp(t, 0, 1));
}

fn referenceSrgbToLinear(value: f32) f32 {
    const channel = std.math.clamp(value, 0, 1);
    if (channel <= 0.04045) return channel / 12.92;
    return std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn referenceLinearToSrgb(value: f32) f32 {
    const channel = std.math.clamp(value, 0, 1);
    if (channel <= 0.0031308) return channel * 12.92;
    return 1.055 * std.math.pow(f32, channel, 1.0 / 2.4) - 0.055;
}

fn referenceScaleColorAlpha(color: Color, alpha: f32) Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a * std.math.clamp(alpha, 0, 1),
    };
}

fn referenceShadowFalloff(distance: f32, blur_radius: f32) f32 {
    if (blur_radius <= 0) return if (distance <= 0) 1 else 0;
    const t = std.math.clamp(1 - distance / blur_radius, 0, 1);
    return t * t * (3 - 2 * t);
}

fn referenceDistanceToSegment(point: geometry.PointF, from: geometry.PointF, to: geometry.PointF) f32 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length_sq = dx * dx + dy * dy;
    if (length_sq <= 0.000001) {
        const px = point.x - from.x;
        const py = point.y - from.y;
        return @sqrt(px * px + py * py);
    }

    const t = std.math.clamp(((point.x - from.x) * dx + (point.y - from.y) * dy) / length_sq, 0, 1);
    const closest = geometry.PointF.init(from.x + dx * t, from.y + dy * t);
    const px = point.x - closest.x;
    const py = point.y - closest.y;
    return @sqrt(px * px + py * py);
}

fn referencePathContainsPoint(point: geometry.PointF, elements: []const PathElement, transform: Affine) bool {
    var inside = false;
    var has_current = false;
    var current = geometry.PointF.zero();
    var subpath_start = geometry.PointF.zero();

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                current = transform.transformPoint(element.points[0]);
                subpath_start = current;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    current = transform.transformPoint(element.points[0]);
                    subpath_start = current;
                    has_current = true;
                    continue;
                }
                const next = transform.transformPoint(element.points[0]);
                if (referenceSegmentCrossesRay(point, current, next)) inside = !inside;
                current = next;
            },
            .quad_to => {
                if (!has_current) continue;
                const control = transform.transformPoint(element.points[0]);
                const end = transform.transformPoint(element.points[1]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceQuadPoint(current, control, end, t);
                    if (referenceSegmentCrossesRay(point, previous, next)) inside = !inside;
                    previous = next;
                }
                current = end;
            },
            .cubic_to => {
                if (!has_current) continue;
                const control_a = transform.transformPoint(element.points[0]);
                const control_b = transform.transformPoint(element.points[1]);
                const end = transform.transformPoint(element.points[2]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceCubicPoint(current, control_a, control_b, end, t);
                    if (referenceSegmentCrossesRay(point, previous, next)) inside = !inside;
                    previous = next;
                }
                current = end;
            },
            .close => {
                if (has_current) {
                    if (referenceSegmentCrossesRay(point, current, subpath_start)) inside = !inside;
                    current = subpath_start;
                }
            },
        }
    }

    return inside;
}

fn referenceDistanceToPath(point: geometry.PointF, elements: []const PathElement, transform: Affine) ?f32 {
    var has_distance = false;
    var min_distance: f32 = 0;
    var has_current = false;
    var current = geometry.PointF.zero();
    var subpath_start = geometry.PointF.zero();

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                current = transform.transformPoint(element.points[0]);
                subpath_start = current;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    current = transform.transformPoint(element.points[0]);
                    subpath_start = current;
                    has_current = true;
                    continue;
                }
                const next = transform.transformPoint(element.points[0]);
                referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, current, next));
                current = next;
            },
            .quad_to => {
                if (!has_current) continue;
                const control = transform.transformPoint(element.points[0]);
                const end = transform.transformPoint(element.points[1]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceQuadPoint(current, control, end, t);
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, previous, next));
                    previous = next;
                }
                current = end;
            },
            .cubic_to => {
                if (!has_current) continue;
                const control_a = transform.transformPoint(element.points[0]);
                const control_b = transform.transformPoint(element.points[1]);
                const end = transform.transformPoint(element.points[2]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceCubicPoint(current, control_a, control_b, end, t);
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, previous, next));
                    previous = next;
                }
                current = end;
            },
            .close => {
                if (has_current) {
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, current, subpath_start));
                    current = subpath_start;
                }
            },
        }
    }

    return if (has_distance) min_distance else null;
}

fn referenceMinDistance(has_distance: *bool, min_distance: *f32, distance: f32) void {
    if (!has_distance.* or distance < min_distance.*) {
        has_distance.* = true;
        min_distance.* = distance;
    }
}

fn referenceSegmentCrossesRay(point: geometry.PointF, a: geometry.PointF, b: geometry.PointF) bool {
    if ((a.y > point.y) == (b.y > point.y)) return false;
    const x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y);
    return x > point.x;
}

fn referenceQuadPoint(a: geometry.PointF, b: geometry.PointF, c: geometry.PointF, t: f32) geometry.PointF {
    const u = 1 - t;
    return geometry.PointF.init(
        u * u * a.x + 2 * u * t * b.x + t * t * c.x,
        u * u * a.y + 2 * u * t * b.y + t * t * c.y,
    );
}

fn referenceCubicPoint(a: geometry.PointF, b: geometry.PointF, c: geometry.PointF, d: geometry.PointF, t: f32) geometry.PointF {
    const u = 1 - t;
    return geometry.PointF.init(
        u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
        u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y,
    );
}

fn referenceSpreadRect(rect: geometry.RectF, spread: f32) geometry.RectF {
    const normalized = rect.normalized();
    if (spread >= 0) return normalized.inflate(geometry.InsetsF.all(spread));
    return normalized.deflate(geometry.InsetsF.all(-spread));
}

fn referenceSpreadRadius(radius: Radius, spread: f32) Radius {
    return if (spread >= 0) referenceOutsetRadius(radius, spread) else referenceInsetRadius(radius, -spread);
}

fn referenceDistanceToRoundedRect(point: geometry.PointF, rect: geometry.RectF, radius: Radius) f32 {
    if (referencePointInRoundedRect(point, rect, radius)) return 0;

    const normalized = rect.normalized();
    if (normalized.isEmpty()) return 0;

    const max_radius = @min(normalized.width, normalized.height) * 0.5;
    const top_left = std.math.clamp(nonNegative(radius.top_left), 0, max_radius);
    const top_right = std.math.clamp(nonNegative(radius.top_right), 0, max_radius);
    const bottom_right = std.math.clamp(nonNegative(radius.bottom_right), 0, max_radius);
    const bottom_left = std.math.clamp(nonNegative(radius.bottom_left), 0, max_radius);

    if (point.x < normalized.x + top_left and point.y < normalized.y + top_left) {
        return referenceDistanceToCircle(point, geometry.PointF.init(normalized.x + top_left, normalized.y + top_left), top_left);
    }
    if (point.x >= normalized.maxX() - top_right and point.y < normalized.y + top_right) {
        return referenceDistanceToCircle(point, geometry.PointF.init(normalized.maxX() - top_right, normalized.y + top_right), top_right);
    }
    if (point.x >= normalized.maxX() - bottom_right and point.y >= normalized.maxY() - bottom_right) {
        return referenceDistanceToCircle(point, geometry.PointF.init(normalized.maxX() - bottom_right, normalized.maxY() - bottom_right), bottom_right);
    }
    if (point.x < normalized.x + bottom_left and point.y >= normalized.maxY() - bottom_left) {
        return referenceDistanceToCircle(point, geometry.PointF.init(normalized.x + bottom_left, normalized.maxY() - bottom_left), bottom_left);
    }

    const dx = @max(@max(normalized.x - point.x, 0), point.x - normalized.maxX());
    const dy = @max(@max(normalized.y - point.y, 0), point.y - normalized.maxY());
    return @sqrt(dx * dx + dy * dy);
}

fn referenceDistanceToCircle(point: geometry.PointF, center: geometry.PointF, radius: f32) f32 {
    const dx = point.x - center.x;
    const dy = point.y - center.y;
    return @max(0, @sqrt(dx * dx + dy * dy) - radius);
}

fn referencePixelRect(rect: geometry.RectF, width: usize, height: usize) ?ReferencePixelRect {
    const normalized = rect.normalized();
    if (normalized.isEmpty() or width == 0 or height == 0) return null;
    const x0 = clampI32(referenceFloor(normalized.minX()), 0, @intCast(width));
    const y0 = clampI32(referenceFloor(normalized.minY()), 0, @intCast(height));
    const x1 = clampI32(referenceCeil(normalized.maxX()), 0, @intCast(width));
    const y1 = clampI32(referenceCeil(normalized.maxY()), 0, @intCast(height));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

fn referenceImagePixelLen(width: usize, height: usize) ?usize {
    const pixel_count = std.math.mul(usize, width, height) catch return null;
    return std.math.mul(usize, pixel_count, 4) catch return null;
}

fn referenceImageSourceRect(image: ReferenceImage, src: ?geometry.RectF) ?geometry.RectF {
    const full = geometry.RectF.init(0, 0, @floatFromInt(image.width), @floatFromInt(image.height));
    const requested = if (src) |rect| rect.normalized() else full;
    const clipped = geometry.RectF.intersection(requested, full);
    return if (clipped.isEmpty()) null else clipped;
}

fn referenceImageDestinationRect(dst: geometry.RectF, src: geometry.RectF, fit: ImageFit) ?geometry.RectF {
    const normalized = dst.normalized();
    if (normalized.isEmpty() or src.width <= 0 or src.height <= 0) return null;
    if (fit == .stretch) return normalized;

    const src_aspect = src.width / src.height;
    const dst_aspect = normalized.width / normalized.height;
    var width = normalized.width;
    var height = normalized.height;
    switch (fit) {
        .stretch => unreachable,
        .contain => {
            if (dst_aspect > src_aspect) {
                height = normalized.height;
                width = height * src_aspect;
            } else {
                width = normalized.width;
                height = width / src_aspect;
            }
        },
        .cover => {
            if (dst_aspect > src_aspect) {
                width = normalized.width;
                height = width / src_aspect;
            } else {
                height = normalized.height;
                width = height * src_aspect;
            }
        },
    }

    return geometry.RectF.init(
        normalized.x + (normalized.width - width) * 0.5,
        normalized.y + (normalized.height - height) * 0.5,
        width,
        height,
    );
}

const ReferencePremultipliedLinearColor = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

fn referenceSampleImage(image: ReferenceImage, src: geometry.RectF, u: f32, v: f32, sampling: ImageSampling) [4]u8 {
    return switch (sampling) {
        .nearest => referenceSampleImageNearest(image, src, u, v),
        .linear => referenceSampleImageLinear(image, src, u, v),
    };
}

fn referenceSampleImageNearest(image: ReferenceImage, src: geometry.RectF, u: f32, v: f32) [4]u8 {
    const sample_x_f = src.x + std.math.clamp(u, 0, 1) * src.width;
    const sample_y_f = src.y + std.math.clamp(v, 0, 1) * src.height;
    const x = clampI32(referenceFloor(sample_x_f), 0, @intCast(image.width - 1));
    const y = clampI32(referenceFloor(sample_y_f), 0, @intCast(image.height - 1));
    return referenceImagePixel(image, x, y);
}

fn referenceSampleImageLinear(image: ReferenceImage, src: geometry.RectF, u: f32, v: f32) [4]u8 {
    const sample_x_f = src.x + std.math.clamp(u, 0, 1) * src.width - 0.5;
    const sample_y_f = src.y + std.math.clamp(v, 0, 1) * src.height - 0.5;
    const x_floor = referenceFloor(sample_x_f);
    const y_floor = referenceFloor(sample_y_f);
    const x0 = clampI32(x_floor, 0, @intCast(image.width - 1));
    const y0 = clampI32(y_floor, 0, @intCast(image.height - 1));
    const x1 = clampI32(x_floor + 1, 0, @intCast(image.width - 1));
    const y1 = clampI32(y_floor + 1, 0, @intCast(image.height - 1));
    const tx = std.math.clamp(sample_x_f - @as(f32, @floatFromInt(x_floor)), 0, 1);
    const ty = std.math.clamp(sample_y_f - @as(f32, @floatFromInt(y_floor)), 0, 1);

    const top_left = referenceImagePixel(image, x0, y0);
    const top_right = referenceImagePixel(image, x1, y0);
    const bottom_left = referenceImagePixel(image, x0, y1);
    const bottom_right = referenceImagePixel(image, x1, y1);

    const sample = referenceBilinearPremultipliedLinearColor(top_left, top_right, bottom_left, bottom_right, tx, ty);
    if (sample.a <= 0.000001) return .{ 0, 0, 0, 0 };

    const inverse_alpha = 1 / sample.a;
    return .{
        colorChannelToByte(referenceLinearToSrgb(sample.r * inverse_alpha)),
        colorChannelToByte(referenceLinearToSrgb(sample.g * inverse_alpha)),
        colorChannelToByte(referenceLinearToSrgb(sample.b * inverse_alpha)),
        colorChannelToByte(sample.a),
    };
}

fn referenceImagePixel(image: ReferenceImage, x: i32, y: i32) [4]u8 {
    const index = (@as(usize, @intCast(y)) * image.width + @as(usize, @intCast(x))) * 4;
    return .{
        image.pixels[index + 0],
        image.pixels[index + 1],
        image.pixels[index + 2],
        image.pixels[index + 3],
    };
}

fn referenceBilinearPremultipliedLinearColor(top_left: [4]u8, top_right: [4]u8, bottom_left: [4]u8, bottom_right: [4]u8, tx: f32, ty: f32) ReferencePremultipliedLinearColor {
    const top = referenceMixPremultipliedLinearColor(referencePremultiplySrgba8(top_left), referencePremultiplySrgba8(top_right), tx);
    const bottom = referenceMixPremultipliedLinearColor(referencePremultiplySrgba8(bottom_left), referencePremultiplySrgba8(bottom_right), tx);
    return referenceMixPremultipliedLinearColor(top, bottom, ty);
}

fn referencePremultiplySrgba8(pixel: [4]u8) ReferencePremultipliedLinearColor {
    const alpha = @as(f32, @floatFromInt(pixel[3])) / 255.0;
    return .{
        .r = referenceSrgbToLinear(@as(f32, @floatFromInt(pixel[0])) / 255.0) * alpha,
        .g = referenceSrgbToLinear(@as(f32, @floatFromInt(pixel[1])) / 255.0) * alpha,
        .b = referenceSrgbToLinear(@as(f32, @floatFromInt(pixel[2])) / 255.0) * alpha,
        .a = alpha,
    };
}

fn referenceMixPremultipliedLinearColor(a: ReferencePremultipliedLinearColor, b: ReferencePremultipliedLinearColor, t: f32) ReferencePremultipliedLinearColor {
    const value = std.math.clamp(t, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * value,
        .g = a.g + (b.g - a.g) * value,
        .b = a.b + (b.b - a.b) * value,
        .a = a.a + (b.a - a.a) * value,
    };
}

fn referencePointInRoundedRect(point: geometry.PointF, rect: geometry.RectF, radius: Radius) bool {
    const normalized = rect.normalized();
    if (!normalized.containsPoint(point)) return false;
    const max_radius = @min(normalized.width, normalized.height) * 0.5;
    const top_left = std.math.clamp(nonNegative(radius.top_left), 0, max_radius);
    const top_right = std.math.clamp(nonNegative(radius.top_right), 0, max_radius);
    const bottom_right = std.math.clamp(nonNegative(radius.bottom_right), 0, max_radius);
    const bottom_left = std.math.clamp(nonNegative(radius.bottom_left), 0, max_radius);

    if (point.x < normalized.x + top_left and point.y < normalized.y + top_left) {
        return referencePointInCorner(point, geometry.PointF.init(normalized.x + top_left, normalized.y + top_left), top_left);
    }
    if (point.x >= normalized.maxX() - top_right and point.y < normalized.y + top_right) {
        return referencePointInCorner(point, geometry.PointF.init(normalized.maxX() - top_right, normalized.y + top_right), top_right);
    }
    if (point.x >= normalized.maxX() - bottom_right and point.y >= normalized.maxY() - bottom_right) {
        return referencePointInCorner(point, geometry.PointF.init(normalized.maxX() - bottom_right, normalized.maxY() - bottom_right), bottom_right);
    }
    if (point.x < normalized.x + bottom_left and point.y >= normalized.maxY() - bottom_left) {
        return referencePointInCorner(point, geometry.PointF.init(normalized.x + bottom_left, normalized.maxY() - bottom_left), bottom_left);
    }
    return true;
}

fn referencePointInCorner(point: geometry.PointF, center: geometry.PointF, radius: f32) bool {
    if (radius <= 0) return false;
    const dx = point.x - center.x;
    const dy = point.y - center.y;
    return dx * dx + dy * dy <= radius * radius;
}

fn referenceScaleRadius(radius: Radius, transform: Affine) Radius {
    const scale = referenceTransformScale(transform);
    return .{
        .top_left = radius.top_left * scale,
        .top_right = radius.top_right * scale,
        .bottom_right = radius.bottom_right * scale,
        .bottom_left = radius.bottom_left * scale,
    };
}

fn referenceInsetRadius(radius: Radius, inset: f32) Radius {
    return .{
        .top_left = @max(0, radius.top_left - inset),
        .top_right = @max(0, radius.top_right - inset),
        .bottom_right = @max(0, radius.bottom_right - inset),
        .bottom_left = @max(0, radius.bottom_left - inset),
    };
}

fn referenceOutsetRadius(radius: Radius, outset: f32) Radius {
    return .{
        .top_left = @max(0, radius.top_left + outset),
        .top_right = @max(0, radius.top_right + outset),
        .bottom_right = @max(0, radius.bottom_right + outset),
        .bottom_left = @max(0, radius.bottom_left + outset),
    };
}

fn referenceTransformScale(transform: Affine) f32 {
    const x_scale = @sqrt(transform.a * transform.a + transform.b * transform.b);
    const y_scale = @sqrt(transform.c * transform.c + transform.d * transform.d);
    return @max(0.0001, @max(x_scale, y_scale));
}

fn referenceFloor(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@floor(value));
}

fn referenceCeil(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@ceil(value));
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    return @min(@max(value, min_value), max_value);
}

fn colorToRgba8(color: Color) [4]u8 {
    return .{
        colorChannelToByte(color.r),
        colorChannelToByte(color.g),
        colorChannelToByte(color.b),
        colorChannelToByte(color.a),
    };
}

fn rgba8ToColor(pixel: [4]u8) Color {
    return Color.rgba(
        @as(f32, @floatFromInt(pixel[0])) / 255.0,
        @as(f32, @floatFromInt(pixel[1])) / 255.0,
        @as(f32, @floatFromInt(pixel[2])) / 255.0,
        @as(f32, @floatFromInt(pixel[3])) / 255.0,
    );
}

fn blendRgba8(dst: [4]u8, src: Color, opacity: f32) [4]u8 {
    const src_a = std.math.clamp(src.a * std.math.clamp(opacity, 0, 1), 0, 1);
    const dst_a = @as(f32, @floatFromInt(dst[3])) / 255.0;
    const out_a = src_a + dst_a * (1 - src_a);
    if (out_a <= 0) return .{ 0, 0, 0, 0 };

    const dst_r = @as(f32, @floatFromInt(dst[0])) / 255.0;
    const dst_g = @as(f32, @floatFromInt(dst[1])) / 255.0;
    const dst_b = @as(f32, @floatFromInt(dst[2])) / 255.0;
    return .{
        colorChannelToByte((std.math.clamp(src.r, 0, 1) * src_a + dst_r * dst_a * (1 - src_a)) / out_a),
        colorChannelToByte((std.math.clamp(src.g, 0, 1) * src_a + dst_g * dst_a * (1 - src_a)) / out_a),
        colorChannelToByte((std.math.clamp(src.b, 0, 1) * src_a + dst_b * dst_a * (1 - src_a)) / out_a),
        colorChannelToByte(out_a),
    };
}

fn colorChannelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}

fn shadowBounds(value: Shadow) geometry.RectF {
    const spread = nonNegative(@abs(value.spread));
    const blur_radius = nonNegative(value.blur);
    return value.rect
        .normalized()
        .translate(value.offset)
        .inflate(geometry.InsetsF.all(spread + blur_radius));
}

const PathGeometryCounts = struct {
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
};

fn analyzePathGeometry(elements: []const PathElement, kind: RenderPathGeometryKind) PathGeometryCounts {
    var counts = PathGeometryCounts{};
    var has_current = false;

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                counts.contour_count += 1;
                counts.vertex_count += 1;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    counts.contour_count += 1;
                    counts.vertex_count += 1;
                    has_current = true;
                    continue;
                }
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
                counts.vertex_count += 1;
            },
            .quad_to => {
                if (!has_current) continue;
                counts.quadratic_segment_count += 1;
                counts.flattened_segment_count += reference_curve_segments;
                counts.vertex_count += reference_curve_segments;
            },
            .cubic_to => {
                if (!has_current) continue;
                counts.cubic_segment_count += 1;
                counts.flattened_segment_count += reference_curve_segments;
                counts.vertex_count += reference_curve_segments;
            },
            .close => {
                if (!has_current) continue;
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
            },
        }
    }

    switch (kind) {
        .fill => {
            counts.index_count = if (counts.vertex_count >= 3) (counts.vertex_count - 2) * 3 else 0;
        },
        .stroke => {
            counts.vertex_count = counts.flattened_segment_count * 4;
            counts.index_count = counts.flattened_segment_count * 6;
        },
    }
    return counts;
}

fn pathBounds(elements: []const PathElement) ?geometry.RectF {
    var has_point = false;
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (elements) |element| {
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count]) |point| {
            if (!has_point) {
                has_point = true;
                min_x = point.x;
                min_y = point.y;
                max_x = point.x;
                max_y = point.y;
            } else {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
        }
    }
    if (!has_point) return null;
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn textBounds(value: DrawText) ?geometry.RectF {
    if (value.glyphs.len == 0 and value.text.len == 0) return null;
    if (value.text_layout) |options| {
        var lines: [max_reference_text_layout_lines]TextLine = undefined;
        if (layoutTextRun(value, options, &lines)) |layout| {
            if (layout.bounds) |bounds| return bounds;
        } else |_| {}
    }

    var min_x = value.origin.x;
    var min_y = value.origin.y - value.size;
    var max_x = value.origin.x;
    var max_y = value.origin.y + value.size * 0.25;
    if (value.glyphs.len > 0) {
        min_x = value.origin.x + value.glyphs[0].x;
        max_x = min_x + estimatedGlyphAdvance(value.glyphs[0], value.size);
        min_y = value.origin.y + value.glyphs[0].y - value.size;
        max_y = value.origin.y + value.glyphs[0].y + value.size * 0.25;
        for (value.glyphs[1..]) |glyph| {
            const glyph_x = value.origin.x + glyph.x;
            const glyph_y = value.origin.y + glyph.y;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, value.size));
            min_y = @min(min_y, glyph_y - value.size);
            max_y = @max(max_y, glyph_y + value.size * 0.25);
        }
    } else {
        max_x = value.origin.x + estimateTextWidth(value.text, value.size);
    }

    return geometry.RectF.init(
        min_x,
        min_y,
        @max(value.size * 0.25, max_x - min_x),
        @max(value.size * 1.25, max_y - min_y),
    );
}

fn estimatedGlyphAdvance(glyph: Glyph, size: f32) f32 {
    return @max(size * 0.25, glyph.advance);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn floorVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@floor(value));
}

fn ceilVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn nonZeroObjectId(id: ObjectId) ?ObjectId {
    return if (id == 0) null else id;
}

fn subpixelBucket(value: f32) u8 {
    const fraction = value - @floor(value);
    const scaled = @floor(fraction * 4.0);
    return @intFromFloat(std.math.clamp(scaled, 0, 3));
}

fn nextTextLineEnd(text: []const u8, start: usize, size: f32, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) {
        return nextExplicitLineEnd(text, start);
    }

    var index = start;
    var last_break: ?usize = null;
    while (index < text.len) {
        if (text[index] == '\n') return index;
        const next_index = nextTextOffset(text, index);
        const next_width = estimateTextWidth(text[start..next_index], size);
        if (isTextBreakByte(text[index])) last_break = next_index;
        if (next_width > max_width) {
            if (index == start) return next_index;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return trimTrailingTextBreak(text, start, break_index);
                }
            }
            return index;
        }
        index = next_index;
    }
    return text.len;
}

fn appendGlyphTextLines(output: []TextLine, len: *usize, text: DrawText, options: TextLayoutOptions, bounds: *?geometry.RectF) Error!void {
    const height = lineHeight(text, options);
    const initial_len = len.*;
    var glyph_start: usize = 0;
    while (glyph_start < text.glyphs.len) {
        while (options.wrap == .word and glyph_start < text.glyphs.len and isGlyphTextBreak(text, glyph_start)) glyph_start += 1;
        if (glyph_start >= text.glyphs.len) break;

        const glyph_end = nextGlyphLineEnd(text, glyph_start, options);
        const range = textRangeForGlyphRange(text.text, glyph_start, glyph_end - glyph_start, text.glyphs.len);
        try appendTextLine(output, len, text, range.start, range.byteLen(text.text.len), glyph_start, glyph_end - glyph_start, height, options, bounds);
        glyph_start = glyph_end;
    }
    if (len.* == initial_len) try appendTextLine(output, len, text, 0, 0, 0, 0, height, options, bounds);
}

fn nextGlyphLineEnd(text: DrawText, start: usize, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) return text.glyphs.len;

    var index = start;
    var width: f32 = 0;
    var last_break: ?usize = null;
    while (index < text.glyphs.len) {
        if (isGlyphTextBreak(text, index)) last_break = index;
        const next_width = width + estimatedGlyphAdvance(text.glyphs[index], text.size);
        if (next_width > max_width) {
            if (index == start) return index + 1;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return break_index;
                }
            }
            return index;
        }
        width = next_width;
        index += 1;
    }
    return text.glyphs.len;
}

fn nextExplicitLineEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\n') return index;
    }
    return text.len;
}

fn trimTrailingTextBreak(text: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) {
        trimmed -= 1;
    }
    return if (trimmed == start) end else trimmed;
}

fn appendTextLine(
    output: []TextLine,
    len: *usize,
    text: DrawText,
    text_start: usize,
    text_len: usize,
    glyph_start: usize,
    glyph_len: usize,
    line_height: f32,
    options: TextLayoutOptions,
    bounds: *?geometry.RectF,
) Error!void {
    if (len.* >= output.len) return error.TextLayoutLineListFull;
    const baseline = text.origin.y + @as(f32, @floatFromInt(len.*)) * line_height;
    const line_bounds = alignTextLineBounds(
        textLineBounds(text, text_start, text_len, glyph_start, glyph_len, baseline, line_height),
        options,
    );
    output[len.*] = .{
        .text_start = text_start,
        .text_len = text_len,
        .glyph_start = glyph_start,
        .glyph_len = glyph_len,
        .bounds = line_bounds,
        .baseline = baseline,
    };
    len.* += 1;
    bounds.* = unionOptionalBounds(bounds.*, line_bounds);
}

fn alignTextLineBounds(bounds: geometry.RectF, options: TextLayoutOptions) geometry.RectF {
    const max_width = nonNegative(options.max_width);
    if (max_width <= 0 or bounds.width >= max_width) return bounds;
    const extra = max_width - bounds.width;
    const dx = switch (options.alignment) {
        .start => 0,
        .center => extra * 0.5,
        .end => extra,
    };
    return bounds.translate(geometry.OffsetF.init(dx, 0));
}

fn textLineForOffset(layout: TextLayout, text_len: usize, offset: usize) ?TextLine {
    if (layout.lines.len == 0) return null;
    const normalized = @min(offset, text_len);
    var previous: ?TextLine = null;
    for (layout.lines) |line| {
        const range = textLineRangeForLength(text_len, line);
        if (normalized < range.start) return previous orelse line;
        if (normalized <= range.end) return line;
        previous = line;
    }
    return previous;
}

fn textLineForPoint(layout: TextLayout, point: geometry.PointF) ?TextLine {
    var previous: ?TextLine = null;
    for (layout.lines) |line| {
        if (point.y < line.bounds.y + line.bounds.height) return line;
        previous = line;
    }
    return previous;
}

fn textLineRange(text: DrawText, line: TextLine) TextRange {
    return textLineRangeForLength(text.text.len, line);
}

fn textLineRangeForLength(text_len: usize, line: TextLine) TextRange {
    const start = @min(line.text_start, text_len);
    const end = @min(text_len, start + line.text_len);
    return TextRange.init(start, end);
}

fn textLineCaretX(text: DrawText, line: TextLine, offset: usize) f32 {
    const range = textLineRange(text, line);
    const snapped = clampTextOffsetToRange(text.text, range, offset);
    if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len) {
        return textLineGlyphCaretX(text, line, range, snapped);
    }
    return line.bounds.x + estimateTextWidth(text.text[range.start..snapped], text.size);
}

fn textLineGlyphCaretX(text: DrawText, line: TextLine, range: TextRange, offset: usize) f32 {
    if (range.end <= range.start) return line.bounds.x;
    if (offset <= range.start) return line.bounds.x;
    if (offset >= range.end) return line.bounds.x + line.bounds.width;

    const scalar_count = utf8ScalarCount(text.text[range.start..range.end]);
    if (scalar_count == 0) return line.bounds.x;
    const scalar_index = utf8ScalarIndexForOffset(text.text[range.start..range.end], offset - range.start);
    const glyph_offset = @min(line.glyph_len, (scalar_index * line.glyph_len) / scalar_count);
    if (glyph_offset == 0) return line.bounds.x;
    if (glyph_offset >= line.glyph_len or line.glyph_start + glyph_offset >= text.glyphs.len) return line.bounds.x + line.bounds.width;

    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const glyph = text.glyphs[line.glyph_start + glyph_offset];
    return text.origin.x + glyph.x - first_x + (line.bounds.x - raw_bounds.x);
}

fn textLineOffsetForX(text: DrawText, line: TextLine, x: f32) usize {
    const range = textLineRange(text, line);
    if (x <= line.bounds.x) return range.start;
    if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len) {
        return textLineGlyphOffsetForX(text, line, range, x);
    }

    const advance = @max(1, text.size * 0.5);
    var cursor = range.start;
    var caret_x = line.bounds.x;
    while (cursor < range.end) {
        if (x < caret_x + advance * 0.5) return cursor;
        caret_x += advance;
        cursor = nextTextOffset(text.text, cursor);
    }
    return range.end;
}

fn textLineGlyphOffsetForX(text: DrawText, line: TextLine, range: TextRange, x: f32) usize {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const dx = line.bounds.x - raw_bounds.x;
    for (text.glyphs[line.glyph_start..glyph_end], 0..) |glyph, glyph_index| {
        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance * 0.5) {
            const glyph_range = textRangeForGlyphRange(text.text, line.glyph_start + glyph_index, 1, text.glyphs.len);
            return clampTextOffsetToRange(text.text, range, glyph_range.start);
        }
    }
    return range.end;
}

fn clampTextOffsetToRange(text: []const u8, range: TextRange, offset: usize) usize {
    const snapped = snapTextOffset(text, offset);
    if (snapped < range.start) return range.start;
    if (snapped > range.end) return range.end;
    return snapped;
}

fn utf8ScalarIndexForOffset(text: []const u8, offset: usize) usize {
    const target = snapTextOffset(text, offset);
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < target) : (index += 1) {
        cursor = nextTextOffset(text, cursor);
    }
    return index;
}

fn lineHeight(text: DrawText, options: TextLayoutOptions) f32 {
    return if (options.line_height > 0) options.line_height else text.size * 1.25;
}

fn textLineBounds(text: DrawText, text_start: usize, text_len: usize, glyph_start: usize, glyph_len: usize, baseline: f32, line_height: f32) geometry.RectF {
    if (glyph_len > 0 and glyph_start < text.glyphs.len) {
        const glyphs = text.glyphs[glyph_start..@min(text.glyphs.len, glyph_start + glyph_len)];
        const origin_x = glyphs[0].x;
        var min_x: f32 = 0;
        var max_x = estimatedGlyphAdvance(glyphs[0], text.size);
        var min_y = baseline - text.size;
        var max_y = min_y + line_height;
        for (glyphs) |glyph| {
            const glyph_x = glyph.x - origin_x;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, text.size));
            min_y = @min(min_y, baseline + glyph.y - text.size);
            max_y = @max(max_y, baseline + glyph.y + text.size * 0.25);
        }
        return geometry.RectF.init(text.origin.x + min_x, min_y, @max(0, max_x - min_x), @max(0, max_y - min_y));
    }
    return geometry.RectF.init(
        text.origin.x,
        baseline - text.size,
        estimateTextWidth(text.text[text_start..@min(text.text.len, text_start + text_len)], text.size),
        line_height,
    );
}

fn estimateTextWidth(text: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(utf8ScalarCount(text))) * size * 0.5;
}

fn isTextBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isGlyphTextBreak(text: DrawText, glyph_index: usize) bool {
    if (glyph_index >= text.glyphs.len) return false;
    const range = textRangeForGlyphRange(text.text, glyph_index, 1, text.glyphs.len);
    return range.start < range.end and isTextBreakByte(text.text[range.start]);
}

fn textRangeForGlyphRange(text: []const u8, glyph_start: usize, glyph_len: usize, glyph_count: usize) TextRange {
    if (text.len == 0 or glyph_count == 0) return TextRange.init(0, 0);
    const scalar_count = utf8ScalarCount(text);
    if (scalar_count == 0) return TextRange.init(0, 0);

    const glyph_end = @min(glyph_count, glyph_start + glyph_len);
    const start_scalar = @min(scalar_count, (glyph_start * scalar_count) / glyph_count);
    const end_scalar = @min(scalar_count, ((glyph_end * scalar_count) + glyph_count - 1) / glyph_count);
    return TextRange.init(textOffsetForScalarIndex(text, start_scalar), textOffsetForScalarIndex(text, end_scalar));
}

fn textOffsetForScalarIndex(text: []const u8, scalar_index: usize) usize {
    var offset: usize = 0;
    var index: usize = 0;
    while (offset < text.len and index < scalar_index) : (index += 1) {
        offset = nextTextOffset(text, offset);
    }
    return offset;
}

fn fallbackGlyphId(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0;
    const first = bytes[0];
    const len = utf8SequenceLength(first);
    if (len == 1 or len > bytes.len) return first;

    var value: u32 = switch (len) {
        2 => @as(u32, first & 0x1f),
        3 => @as(u32, first & 0x0f),
        4 => @as(u32, first & 0x07),
        else => return first,
    };
    var index: usize = 1;
    while (index < len) : (index += 1) {
        const byte = bytes[index];
        if (!isUtf8ContinuationByte(byte)) return first;
        value = (value << 6) | @as(u32, byte & 0x3f);
    }
    return value;
}

fn utf8ScalarCount(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        count += 1;
        index += @min(utf8SequenceLength(text[index]), text.len - index);
    }
    return count;
}

const TextReplaceResult = struct {
    text: []const u8,
    inserted_range: TextRange,
};

fn normalizeTextEditState(state: TextEditState) TextEditState {
    return .{
        .text = state.text,
        .selection = snapTextSelection(state.text, state.selection),
        .composition = if (state.composition) |range| snapTextRange(state.text, range) else null,
    };
}

fn activeTextReplaceRange(state: TextEditState) TextRange {
    if (state.composition) |range| return snapTextRange(state.text, range);
    return state.selection.range(state.text.len);
}

fn replaceTextEditRange(
    state: TextEditState,
    range: TextRange,
    replacement: []const u8,
    output: []u8,
    composition: ?TextRange,
    cursor_offset: usize,
) Error!TextEditState {
    const result = try replaceTextRange(state.text, range, replacement, output);
    const cursor = snapTextOffset(result.text, result.inserted_range.start + @min(cursor_offset, replacement.len));
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(cursor),
        .composition = composition,
    };
}

fn setTextComposition(state: TextEditState, composition: TextCompositionUpdate, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    const cursor = snapTextOffset(composition.text, composition.cursor orelse composition.text.len);
    const result = try replaceTextRange(state.text, range, composition.text, output);
    const absolute_cursor = snapTextOffset(result.text, result.inserted_range.start + cursor);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(absolute_cursor),
        .composition = result.inserted_range,
    };
}

fn cancelTextComposition(state: TextEditState, output: []u8) Error!TextEditState {
    const composition = state.composition orelse return state;
    const range = snapTextRange(state.text, composition);
    const result = try replaceTextRange(state.text, range, "", output);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(result.inserted_range.start),
        .composition = null,
    };
}

fn deleteBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextOffset(state.text, caret)), "", output, null, 0);
}

fn moveTextCaret(state: TextEditState, move: TextCaretMove) TextEditState {
    const range = state.selection.range(state.text.len);
    const focus = snapTextOffset(state.text, state.selection.focus);
    const target = switch (move.direction) {
        .previous => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextOffset(state.text, focus),
        .next => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextOffset(state.text, focus),
        .start => 0,
        .end => state.text.len,
    };
    const selection = if (move.extend)
        TextSelection{ .anchor = state.selection.anchor, .focus = target }
    else
        TextSelection.collapsed(target);
    return .{
        .text = state.text,
        .selection = snapTextSelection(state.text, selection),
        .composition = null,
    };
}

fn replaceTextRange(source: []const u8, range: TextRange, replacement: []const u8, output: []u8) Error!TextReplaceResult {
    const snapped = snapTextRange(source, range);
    const prefix_len = snapped.start;
    const suffix = source[snapped.end..];
    const suffix_start = prefix_len + replacement.len;
    const next_len = prefix_len + replacement.len + suffix.len;
    if (next_len > output.len) return error.TextEditBufferTooSmall;

    if (suffix_start > snapped.end) {
        std.mem.copyBackwards(u8, output[suffix_start..next_len], suffix);
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
    } else {
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
        std.mem.copyForwards(u8, output[suffix_start..next_len], suffix);
    }
    return .{
        .text = output[0..next_len],
        .inserted_range = TextRange.init(prefix_len, suffix_start),
    };
}

fn snapTextSelection(text: []const u8, selection: TextSelection) TextSelection {
    return .{
        .anchor = snapTextOffset(text, selection.anchor),
        .focus = snapTextOffset(text, selection.focus),
    };
}

fn snapTextRange(text: []const u8, range: TextRange) TextRange {
    const normalized = range.normalized(text.len);
    return TextRange.init(
        snapTextOffset(text, normalized.start),
        snapTextOffset(text, normalized.end),
    ).normalized(text.len);
}

fn previousTextOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    if (cursor == 0) return 0;
    cursor -= 1;
    while (cursor > 0 and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

fn nextTextOffset(text: []const u8, offset: usize) usize {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return text.len;
    return @min(text.len, cursor + utf8SequenceLength(text[cursor]));
}

fn snapTextOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and cursor < text.len and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

fn utf8SequenceLength(lead: u8) usize {
    if ((lead & 0x80) == 0) return 1;
    if ((lead & 0xe0) == 0xc0) return 2;
    if ((lead & 0xf0) == 0xe0) return 3;
    if ((lead & 0xf8) == 0xf0) return 4;
    return 1;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn commandsEqual(a: CanvasCommand, b: CanvasCommand) bool {
    return switch (a) {
        .push_clip => |value| switch (b) {
            .push_clip => |other| clipsEqual(value, other),
            else => false,
        },
        .pop_clip => switch (b) {
            .pop_clip => true,
            else => false,
        },
        .push_opacity => |value| switch (b) {
            .push_opacity => |other| value == other,
            else => false,
        },
        .pop_opacity => switch (b) {
            .pop_opacity => true,
            else => false,
        },
        .transform => |value| switch (b) {
            .transform => |other| affinesEqual(value, other),
            else => false,
        },
        .fill_rect => |value| switch (b) {
            .fill_rect => |other| fillRectsEqual(value, other),
            else => false,
        },
        .stroke_rect => |value| switch (b) {
            .stroke_rect => |other| strokeRectsEqual(value, other),
            else => false,
        },
        .fill_rounded_rect => |value| switch (b) {
            .fill_rounded_rect => |other| fillRoundedRectsEqual(value, other),
            else => false,
        },
        .draw_line => |value| switch (b) {
            .draw_line => |other| linesEqual(value, other),
            else => false,
        },
        .fill_path => |value| switch (b) {
            .fill_path => |other| fillPathsEqual(value, other),
            else => false,
        },
        .stroke_path => |value| switch (b) {
            .stroke_path => |other| strokePathsEqual(value, other),
            else => false,
        },
        .draw_image => |value| switch (b) {
            .draw_image => |other| drawImagesEqual(value, other),
            else => false,
        },
        .draw_text => |value| switch (b) {
            .draw_text => |other| drawTextsEqual(value, other),
            else => false,
        },
        .shadow => |value| switch (b) {
            .shadow => |other| shadowsEqual(value, other),
            else => false,
        },
        .blur => |value| switch (b) {
            .blur => |other| blursEqual(value, other),
            else => false,
        },
    };
}

fn clipsEqual(a: Clip, b: Clip) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius);
}

fn fillRectsEqual(a: FillRect, b: FillRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and fillsEqual(a.fill, b.fill);
}

fn strokeRectsEqual(a: StrokeRect, b: StrokeRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and strokesEqual(a.stroke, b.stroke);
}

fn fillRoundedRectsEqual(a: FillRoundedRect, b: FillRoundedRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and fillsEqual(a.fill, b.fill);
}

fn linesEqual(a: Line, b: Line) bool {
    return a.id == b.id and pointsEqual(a.from, b.from) and pointsEqual(a.to, b.to) and strokesEqual(a.stroke, b.stroke);
}

fn fillPathsEqual(a: FillPath, b: FillPath) bool {
    return a.id == b.id and pathElementsEqual(a.elements, b.elements) and fillsEqual(a.fill, b.fill);
}

fn strokePathsEqual(a: StrokePath, b: StrokePath) bool {
    return a.id == b.id and pathElementsEqual(a.elements, b.elements) and strokesEqual(a.stroke, b.stroke);
}

fn drawImagesEqual(a: DrawImage, b: DrawImage) bool {
    return a.id == b.id and
        a.image_id == b.image_id and
        optionalRectsEqual(a.src, b.src) and
        rectsEqual(a.dst, b.dst) and
        a.opacity == b.opacity and
        a.fit == b.fit and
        a.sampling == b.sampling;
}

fn drawTextsEqual(a: DrawText, b: DrawText) bool {
    return a.id == b.id and
        a.font_id == b.font_id and
        a.size == b.size and
        pointsEqual(a.origin, b.origin) and
        colorsEqual(a.color, b.color) and
        std.mem.eql(u8, a.text, b.text) and
        glyphsEqual(a.glyphs, b.glyphs) and
        optionalTextLayoutOptionsEqual(a.text_layout, b.text_layout);
}

fn optionalTextLayoutOptionsEqual(a: ?TextLayoutOptions, b: ?TextLayoutOptions) bool {
    if (a) |left| {
        if (b) |right| return textLayoutOptionsEqual(left, right);
        return false;
    }
    return b == null;
}

fn textLayoutOptionsEqual(a: TextLayoutOptions, b: TextLayoutOptions) bool {
    return nonNegative(a.max_width) == nonNegative(b.max_width) and
        nonNegative(a.line_height) == nonNegative(b.line_height) and
        a.wrap == b.wrap and
        a.alignment == b.alignment;
}

fn shadowsEqual(a: Shadow, b: Shadow) bool {
    return a.id == b.id and
        rectsEqual(a.rect, b.rect) and
        radiiEqual(a.radius, b.radius) and
        offsetsEqual(a.offset, b.offset) and
        a.blur == b.blur and
        a.spread == b.spread and
        colorsEqual(a.color, b.color);
}

fn blursEqual(a: Blur, b: Blur) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and a.radius == b.radius;
}

fn fillsEqual(a: Fill, b: Fill) bool {
    return switch (a) {
        .color => |value| switch (b) {
            .color => |other| colorsEqual(value, other),
            else => false,
        },
        .linear_gradient => |value| switch (b) {
            .linear_gradient => |other| linearGradientsEqual(value, other),
            else => false,
        },
    };
}

fn strokesEqual(a: Stroke, b: Stroke) bool {
    return a.width == b.width and fillsEqual(a.fill, b.fill);
}

fn linearGradientsEqual(a: LinearGradient, b: LinearGradient) bool {
    return pointsEqual(a.start, b.start) and pointsEqual(a.end, b.end) and gradientStopsEqual(a.stops, b.stops);
}

fn gradientStopsEqual(a: []const GradientStop, b: []const GradientStop) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.offset != right.offset or !colorsEqual(left.color, right.color)) return false;
    }
    return true;
}

fn pathElementsEqual(a: []const PathElement, b: []const PathElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.verb != right.verb) return false;
        if (!pointsEqual(left.points[0], right.points[0])) return false;
        if (!pointsEqual(left.points[1], right.points[1])) return false;
        if (!pointsEqual(left.points[2], right.points[2])) return false;
    }
    return true;
}

fn glyphsEqual(a: []const Glyph, b: []const Glyph) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.id != right.id or left.font_id != right.font_id or left.x != right.x or left.y != right.y or left.advance != right.advance) return false;
    }
    return true;
}

fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

fn optionalRectsEqual(a: ?geometry.RectF, b: ?geometry.RectF) bool {
    if (a) |left| {
        if (b) |right| return rectsEqual(left, right);
        return false;
    }
    return b == null;
}

fn sizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

fn insetsEqual(a: geometry.InsetsF, b: geometry.InsetsF) bool {
    return a.top == b.top and
        a.right == b.right and
        a.bottom == b.bottom and
        a.left == b.left;
}

fn pointsEqual(a: geometry.PointF, b: geometry.PointF) bool {
    return a.x == b.x and a.y == b.y;
}

fn offsetsEqual(a: geometry.OffsetF, b: geometry.OffsetF) bool {
    return a.dx == b.dx and a.dy == b.dy;
}

fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn radiiEqual(a: Radius, b: Radius) bool {
    return a.top_left == b.top_left and
        a.top_right == b.top_right and
        a.bottom_right == b.bottom_right and
        a.bottom_left == b.bottom_left;
}

fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

fn optionalF32Equal(a: ?f32, b: ?f32) bool {
    if (a) |left| {
        if (b) |right| return left == right;
        return false;
    }
    return b == null;
}

fn optionalTextSelectionsEqual(a: ?TextSelection, b: ?TextSelection) bool {
    if (a) |left| {
        if (b) |right| return left.anchor == right.anchor and left.focus == right.focus;
        return false;
    }
    return b == null;
}

fn optionalTextRangesEqual(a: ?TextRange, b: ?TextRange) bool {
    if (a) |left| {
        if (b) |right| return left.start == right.start and left.end == right.end;
        return false;
    }
    return b == null;
}

fn writeCommandJson(command: CanvasCommand, writer: anytype) !void {
    try writer.writeAll("{\"op\":");
    try json.writeString(writer, @tagName(command));
    switch (command) {
        .push_clip => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
        },
        .pop_clip, .pop_opacity => {},
        .push_opacity => |value| try writer.print(",\"opacity\":{d}", .{value}),
        .transform => |value| {
            try writer.writeAll(",\"matrix\":");
            try writeAffineJson(value, writer);
        },
        .fill_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .stroke_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .fill_rounded_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .draw_line => |value| {
            try writer.print(",\"id\":{d},\"from\":", .{value.id});
            try writePointJson(value.from, writer);
            try writer.writeAll(",\"to\":");
            try writePointJson(value.to, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .fill_path => |value| {
            try writer.print(",\"id\":{d},\"path\":", .{value.id});
            try writePathJson(value.elements, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .stroke_path => |value| {
            try writer.print(",\"id\":{d},\"path\":", .{value.id});
            try writePathJson(value.elements, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .draw_image => |value| {
            try writer.print(",\"id\":{d},\"image\":{d},\"dst\":", .{ value.id, value.image_id });
            try writeRectJson(value.dst, writer);
            try writer.writeAll(",\"src\":");
            if (value.src) |src| {
                try writeRectJson(src, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"opacity\":{d},\"fit\":", .{value.opacity});
            try json.writeString(writer, @tagName(value.fit));
            try writer.writeAll(",\"sampling\":");
            try json.writeString(writer, @tagName(value.sampling));
        },
        .draw_text => |value| {
            try writer.print(",\"id\":{d},\"font\":{d},\"size\":{d},\"origin\":", .{ value.id, value.font_id, value.size });
            try writePointJson(value.origin, writer);
            try writer.writeAll(",\"color\":");
            try writeColorJson(value.color, writer);
            try writer.writeAll(",\"text\":");
            try json.writeString(writer, value.text);
            try writer.writeAll(",\"glyphs\":");
            try writeGlyphsJson(value.glyphs, writer);
            if (value.text_layout) |options| {
                try writer.writeAll(",\"layout\":");
                try writeTextLayoutOptionsJson(options, writer);
            }
        },
        .shadow => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.print(",\"offset\":[{d},{d}],\"blur\":{d},\"spread\":{d},\"color\":", .{ value.offset.dx, value.offset.dy, value.blur, value.spread });
            try writeColorJson(value.color, writer);
        },
        .blur => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.print(",\"radius\":{d}", .{value.radius});
        },
    }
    try writer.writeByte('}');
}

fn writeTextLayoutOptionsJson(options: TextLayoutOptions, writer: anytype) !void {
    try writer.print("{{\"maxWidth\":{d},\"lineHeight\":{d},\"wrap\":", .{
        nonNegative(options.max_width),
        nonNegative(options.line_height),
    });
    try json.writeString(writer, @tagName(options.wrap));
    try writer.writeAll(",\"align\":");
    try json.writeString(writer, @tagName(options.alignment));
    try writer.writeByte('}');
}

fn writeCanvasRenderPassJson(pass: CanvasRenderPass, writer: anytype) !void {
    try writer.print(
        "{{\"frameIndex\":{d},\"timestampNs\":{d},\"surfaceWidth\":{d},\"surfaceHeight\":{d},\"scale\":{d},\"loadAction\":",
        .{ pass.frame_index, pass.timestamp_ns, pass.surface_size.width, pass.surface_size.height, pass.scale },
    );
    try json.writeString(writer, @tagName(pass.loadAction()));
    try writer.writeAll(",\"fullRepaint\":");
    try writer.writeAll(if (pass.full_repaint) "true" else "false");
    try writer.writeAll(",\"requiresRender\":");
    try writer.writeAll(if (pass.requiresRender()) "true" else "false");
    try writer.writeAll(",\"dirtyBounds\":");
    try writeOptionalRectJson(pass.dirty_bounds, writer);
    try writer.writeAll(",\"scissorBounds\":");
    try writeOptionalRectJson(pass.scissorBounds(), writer);
    try writer.writeAll(",\"commands\":[");
    for (pass.commands, 0..) |command, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderCommandJson(command, index, writer);
    }
    try writer.writeAll("],\"batches\":[");
    for (pass.batches, 0..) |batch, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderBatchJson(batch, writer);
    }
    try writer.writeAll("],\"pipelineActions\":[");
    for (pass.pipeline_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderPipelineCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"pathGeometries\":[");
    for (pass.path_geometries, 0..) |geometry_plan, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderPathGeometryJson(geometry_plan, writer);
    }
    try writer.writeAll("],\"pathGeometryActions\":[");
    for (pass.path_geometry_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderPathGeometryCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"images\":[");
    for (pass.images, 0..) |image, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderImageJson(image, writer);
    }
    try writer.writeAll("],\"imageActions\":[");
    for (pass.image_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderImageCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"layers\":[");
    for (pass.layers, 0..) |layer, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderLayerJson(layer, writer);
    }
    try writer.writeAll("],\"layerActions\":[");
    for (pass.layer_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderLayerCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"resources\":[");
    for (pass.resources, 0..) |resource, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderResourceJson(resource, writer);
    }
    try writer.writeAll("],\"resourceActions\":[");
    for (pass.resource_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderResourceCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"visualEffects\":[");
    for (pass.visual_effects, 0..) |effect, index| {
        if (index > 0) try writer.writeByte(',');
        try writeVisualEffectJson(effect, writer);
    }
    try writer.writeAll("],\"visualEffectActions\":[");
    for (pass.visual_effect_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeVisualEffectCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"glyphAtlasEntries\":[");
    for (pass.glyph_atlas_entries, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writeGlyphAtlasEntryJson(entry, writer);
    }
    try writer.writeAll("],\"glyphAtlasActions\":[");
    for (pass.glyph_atlas_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeGlyphAtlasCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"textLayouts\":[");
    for (pass.text_layouts, 0..) |layout, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTextLayoutPlanJson(layout, writer);
    }
    try writer.writeAll("],\"textLayoutActions\":[");
    for (pass.text_layout_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTextLayoutCacheActionJson(action, writer);
    }
    try writer.writeAll("]}");
}

fn writeRenderCommandJson(command: RenderCommand, index: usize, writer: anytype) !void {
    try writer.print("{{\"index\":{d},\"id\":", .{index});
    try writeOptionalObjectIdJson(command.id, writer);
    try writer.print(",\"opacity\":{d},\"clip\":", .{command.opacity});
    try writeOptionalRectJson(command.clip, writer);
    try writer.writeAll(",\"transform\":");
    try writeAffineJson(command.transform, writer);
    try writer.writeAll(",\"localBounds\":");
    try writeRectJson(command.local_bounds, writer);
    try writer.writeAll(",\"bounds\":");
    try writeRectJson(command.bounds, writer);
    try writer.writeAll(",\"command\":");
    try writeCommandJson(command.command, writer);
    try writer.writeByte('}');
}

fn writeRenderBatchJson(batch: RenderBatch, writer: anytype) !void {
    try writer.writeAll("{\"pipeline\":");
    try json.writeString(writer, @tagName(batch.pipeline));
    try writer.print(",\"commandStart\":{d},\"commandCount\":{d},\"opacity\":{d},\"clip\":", .{ batch.command_start, batch.command_count, batch.opacity });
    try writeOptionalRectJson(batch.clip, writer);
    try writer.writeAll(",\"bounds\":");
    try writeRectJson(batch.bounds, writer);
    try writer.writeByte('}');
}

fn writeRenderPipelineCacheActionJson(action: RenderPipelineCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"pipeline\":");
    try json.writeString(writer, @tagName(action.pipeline));
    try writer.writeAll(",\"batchIndex\":");
    try writeOptionalUsizeJson(action.batch_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeRenderPathGeometryJson(geometry_plan: RenderPathGeometry, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(geometry_plan.kind));
    try writer.print(",\"commandIndex\":{d},\"id\":", .{geometry_plan.command_index});
    try writeOptionalObjectIdJson(geometry_plan.id, writer);
    try writer.writeAll(",\"bounds\":");
    try writeRectJson(geometry_plan.bounds, writer);
    try writer.print(
        ",\"elementCount\":{d},\"contourCount\":{d},\"lineSegmentCount\":{d},\"quadraticSegmentCount\":{d},\"cubicSegmentCount\":{d},\"flattenedSegmentCount\":{d},\"vertexCount\":{d},\"indexCount\":{d},\"strokeWidth\":{d},\"fingerprint\":{d}}}",
        .{
            geometry_plan.element_count,
            geometry_plan.contour_count,
            geometry_plan.line_segment_count,
            geometry_plan.quadratic_segment_count,
            geometry_plan.cubic_segment_count,
            geometry_plan.flattened_segment_count,
            geometry_plan.vertex_count,
            geometry_plan.index_count,
            geometry_plan.stroke_width,
            geometry_plan.fingerprint,
        },
    );
}

fn writeRenderPathGeometryCacheActionJson(action: RenderPathGeometryCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeRenderPathGeometryKeyJson(action.key, writer);
    try writer.writeAll(",\"geometryIndex\":");
    try writeOptionalUsizeJson(action.geometry_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeRenderPathGeometryKeyJson(key: RenderPathGeometryKey, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(key.kind));
    try writer.writeAll(",\"id\":");
    try writeOptionalObjectIdJson(key.id, writer);
    try writer.print(",\"commandIndex\":{d},\"fingerprint\":{d}}}", .{ key.command_index, key.fingerprint });
}

fn writeRenderImageJson(image: RenderImage, writer: anytype) !void {
    try writer.print("{{\"imageId\":{d},\"commandIndex\":{d},\"id\":", .{ image.image_id, image.command_index });
    try writeOptionalObjectIdJson(image.id, writer);
    try writer.print(",\"drawCount\":{d},\"bounds\":", .{image.draw_count});
    try writeRectJson(image.bounds, writer);
    try writer.print(",\"fingerprint\":{d}}}", .{image.fingerprint});
}

fn writeRenderImageCacheActionJson(action: RenderImageCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeRenderImageKeyJson(action.key, writer);
    try writer.writeAll(",\"imageIndex\":");
    try writeOptionalUsizeJson(action.image_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeRenderImageKeyJson(key: RenderImageKey, writer: anytype) !void {
    try writer.print("{{\"imageId\":{d},\"fingerprint\":{d}}}", .{ key.image_id, key.fingerprint });
}

fn writeRenderLayerJson(layer: RenderLayer, writer: anytype) !void {
    try writer.print("{{\"commandStart\":{d},\"commandCount\":{d},\"id\":", .{ layer.command_start, layer.command_count });
    try writeOptionalObjectIdJson(layer.id, writer);
    try writer.writeAll(",\"bounds\":");
    try writeRectJson(layer.bounds, writer);
    try writer.print(",\"opacity\":{d},\"clip\":", .{layer.opacity});
    try writeOptionalRectJson(layer.clip, writer);
    try writer.writeAll(",\"transform\":");
    try writeAffineJson(layer.transform, writer);
    try writer.print(",\"fingerprint\":{d}}}", .{layer.fingerprint});
}

fn writeRenderLayerCacheActionJson(action: RenderLayerCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeRenderLayerKeyJson(action.key, writer);
    try writer.writeAll(",\"layerIndex\":");
    try writeOptionalUsizeJson(action.layer_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeRenderLayerKeyJson(key: RenderLayerKey, writer: anytype) !void {
    try writer.writeAll("{\"id\":");
    try writeOptionalObjectIdJson(key.id, writer);
    try writer.print(",\"commandStart\":{d},\"fingerprint\":{d}}}", .{ key.command_start, key.fingerprint });
}

fn writeRenderResourceJson(resource: RenderResource, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(resource.kind));
    try writer.print(",\"commandIndex\":{d},\"id\":", .{resource.command_index});
    try writeOptionalObjectIdJson(resource.id, writer);
    try writer.writeAll(",\"bounds\":");
    try writeOptionalRectJson(resource.bounds, writer);
    try writer.print(",\"imageId\":{d},\"fontId\":{d},\"gradientStopCount\":{d},\"glyphCount\":{d},\"textLen\":{d},\"fingerprint\":{d}}}", .{
        resource.image_id,
        resource.font_id,
        resource.gradient_stop_count,
        resource.glyph_count,
        resource.text_len,
        resource.fingerprint,
    });
}

fn writeRenderResourceCacheActionJson(action: RenderResourceCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeRenderResourceKeyJson(action.key, writer);
    try writer.writeAll(",\"resourceIndex\":");
    try writeOptionalUsizeJson(action.resource_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeRenderResourceKeyJson(key: RenderResourceKey, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(key.kind));
    try writer.writeAll(",\"id\":");
    try writeOptionalObjectIdJson(key.id, writer);
    try writer.print(",\"commandIndex\":{d},\"imageId\":{d},\"fontId\":{d},\"fingerprint\":{d}}}", .{ key.command_index, key.image_id, key.font_id, key.fingerprint });
}

fn writeVisualEffectJson(effect: VisualEffect, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(effect.kind));
    try writer.print(",\"commandIndex\":{d},\"id\":", .{effect.command_index});
    try writeOptionalObjectIdJson(effect.id, writer);
    try writer.writeAll(",\"bounds\":");
    try writeOptionalRectJson(effect.bounds, writer);
    try writer.writeAll(",\"radius\":");
    try writeRadiusJson(effect.radius, writer);
    try writer.print(",\"offset\":[{d},{d}],\"blur\":{d},\"spread\":{d},\"fingerprint\":{d}}}", .{
        effect.offset.dx,
        effect.offset.dy,
        effect.blur,
        effect.spread,
        effect.fingerprint,
    });
}

fn writeVisualEffectCacheActionJson(action: VisualEffectCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeVisualEffectKeyJson(action.key, writer);
    try writer.writeAll(",\"effectIndex\":");
    try writeOptionalUsizeJson(action.effect_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeVisualEffectKeyJson(key: VisualEffectKey, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(key.kind));
    try writer.writeAll(",\"id\":");
    try writeOptionalObjectIdJson(key.id, writer);
    try writer.print(",\"commandIndex\":{d},\"fingerprint\":{d}}}", .{ key.command_index, key.fingerprint });
}

fn writeGlyphAtlasEntryJson(entry: GlyphAtlasEntry, writer: anytype) !void {
    try writer.print("{{\"key\":{{\"fontId\":{d},\"glyphId\":{d},\"size\":{d},\"subpixelX\":{d},\"subpixelY\":{d}}},\"commandIndex\":{d},\"glyphIndex\":{d}}}", .{
        entry.key.font_id,
        entry.key.glyph_id,
        entry.key.size,
        entry.key.subpixel_x,
        entry.key.subpixel_y,
        entry.command_index,
        entry.glyph_index,
    });
}

fn writeGlyphAtlasCacheActionJson(action: GlyphAtlasCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeGlyphAtlasKeyJson(action.key, writer);
    try writer.writeAll(",\"atlasIndex\":");
    try writeOptionalUsizeJson(action.atlas_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeGlyphAtlasKeyJson(key: GlyphAtlasKey, writer: anytype) !void {
    try writer.print("{{\"fontId\":{d},\"glyphId\":{d},\"size\":{d},\"subpixelX\":{d},\"subpixelY\":{d}}}", .{
        key.font_id,
        key.glyph_id,
        key.size,
        key.subpixel_x,
        key.subpixel_y,
    });
}

fn writeTextLayoutPlanJson(plan: TextLayoutPlan, writer: anytype) !void {
    try writer.writeAll("{\"key\":");
    try writeTextLayoutKeyJson(plan.key, writer);
    try writer.print(",\"lineCount\":{d},\"bounds\":", .{plan.lineCount()});
    try writeOptionalRectJson(plan.layout.bounds, writer);
    try writer.writeByte('}');
}

fn writeTextLayoutCacheActionJson(action: TextLayoutCacheAction, writer: anytype) !void {
    try writer.writeAll("{\"kind\":");
    try json.writeString(writer, @tagName(action.kind));
    try writer.writeAll(",\"key\":");
    try writeTextLayoutKeyJson(action.key, writer);
    try writer.writeAll(",\"layoutIndex\":");
    try writeOptionalUsizeJson(action.layout_index, writer);
    try writer.writeAll(",\"cacheIndex\":");
    try writeOptionalUsizeJson(action.cache_index, writer);
    try writer.writeByte('}');
}

fn writeTextLayoutKeyJson(key: TextLayoutKey, writer: anytype) !void {
    try writer.print("{{\"fontId\":{d},\"size\":{d},\"origin\":[{d},{d}],\"maxWidth\":{d},\"lineHeight\":{d},\"wrap\":", .{
        key.font_id,
        key.size,
        key.origin.x,
        key.origin.y,
        key.max_width,
        key.line_height,
    });
    try json.writeString(writer, @tagName(key.wrap));
    try writer.writeAll(",\"align\":");
    try json.writeString(writer, @tagName(key.alignment));
    try writer.print(",\"textLen\":{d},\"glyphCount\":{d},\"fingerprint\":{d}}}", .{
        key.text_len,
        key.glyph_count,
        key.fingerprint,
    });
}

fn writeOptionalRectJson(rect: ?geometry.RectF, writer: anytype) !void {
    if (rect) |value| {
        try writeRectJson(value, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalObjectIdJson(id: ?ObjectId, writer: anytype) !void {
    if (id) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalUsizeJson(value: ?usize, writer: anytype) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeRectJson(rect: geometry.RectF, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ rect.x, rect.y, rect.width, rect.height });
}

fn writePointJson(point: geometry.PointF, writer: anytype) !void {
    try writer.print("[{d},{d}]", .{ point.x, point.y });
}

fn writeColorJson(color: Color, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ color.r, color.g, color.b, color.a });
}

fn writeRadiusJson(radius: Radius, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left });
}

fn writeAffineJson(matrix: Affine, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d},{d},{d}]", .{ matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty });
}

fn writeFillJson(fill: Fill, writer: anytype) !void {
    switch (fill) {
        .color => |color| {
            try writer.writeAll("{\"kind\":\"color\",\"color\":");
            try writeColorJson(color, writer);
            try writer.writeByte('}');
        },
        .linear_gradient => |gradient| {
            try writer.writeAll("{\"kind\":\"linear_gradient\",\"start\":");
            try writePointJson(gradient.start, writer);
            try writer.writeAll(",\"end\":");
            try writePointJson(gradient.end, writer);
            try writer.writeAll(",\"stops\":[");
            for (gradient.stops, 0..) |stop, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.print("{{\"offset\":{d},\"color\":", .{stop.offset});
                try writeColorJson(stop.color, writer);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        },
    }
}

fn writeStrokeJson(stroke: Stroke, writer: anytype) !void {
    try writer.writeAll("{\"width\":");
    try writer.print("{d}", .{stroke.width});
    try writer.writeAll(",\"fill\":");
    try writeFillJson(stroke.fill, writer);
    try writer.writeByte('}');
}

fn writePathJson(elements: []const PathElement, writer: anytype) !void {
    try writer.writeByte('[');
    for (elements, 0..) |element, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"verb\":");
        try json.writeString(writer, @tagName(element.verb));
        try writer.writeAll(",\"points\":[");
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count], 0..) |point, point_index| {
            if (point_index > 0) try writer.writeByte(',');
            try writePointJson(point, writer);
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');
}

fn writeGlyphsJson(glyphs: []const Glyph, writer: anytype) !void {
    try writer.writeByte('[');
    for (glyphs, 0..) |glyph, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d}", .{glyph.id});
        if (glyph.font_id != 0) try writer.print(",\"font\":{d}", .{glyph.font_id});
        try writer.print(",\"x\":{d},\"y\":{d},\"advance\":{d}}}", .{ glyph.x, glyph.y, glyph.advance });
    }
    try writer.writeByte(']');
}

test "widget layout resolves row sizing and emits laid out commands" {
    const row_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 80, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(0, 0, 0, 8),
            .value = 0.5,
            .layout = .{ .grow = 1, .min_size = geometry.SizeF.init(40, 8) },
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 60, 20),
            .text = "Ready",
        },
    };
    const panel_children = [_]Widget{
        .{
            .kind = .row,
            .frame = geometry.RectF.init(0, 0, 0, 40),
            .layout = .{ .gap = 8 },
            .children = &row_children,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .layout = .{ .padding = geometry.InsetsF.all(12) },
        .children = &panel_children,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 300, 80), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 300, 80));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(12, 12, 80, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(100, 12, 120, 8));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(228, 12, 60, 20));

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(100, 12, 60, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
}

test "widget layout aligns row children on main and cross axes" {
    const centered_children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 40, 12),
            .text = "A",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 20, 16),
            .text = "B",
        },
    };
    const centered = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{
            .gap = 4,
            .main_alignment = .center,
            .cross_alignment = .center,
        },
        .children = &centered_children,
    };

    var centered_nodes: [3]WidgetLayoutNode = undefined;
    const centered_layout = try layoutWidgetTree(centered, geometry.RectF.init(0, 0, 120, 40), &centered_nodes);
    try expectLayoutFrame(centered_layout, 2, geometry.RectF.init(28, 14, 40, 12));
    try expectLayoutFrame(centered_layout, 3, geometry.RectF.init(72, 12, 20, 16));

    const spaced_children = [_]Widget{
        .{ .id = 5, .kind = .text, .frame = geometry.RectF.init(0, 0, 40, 12), .text = "A" },
        .{ .id = 6, .kind = .text, .frame = geometry.RectF.init(0, 0, 20, 16), .text = "B" },
    };
    const spaced = Widget{
        .id = 4,
        .kind = .row,
        .layout = .{ .main_alignment = .space_between },
        .children = &spaced_children,
    };

    var spaced_nodes: [3]WidgetLayoutNode = undefined;
    const spaced_layout = try layoutWidgetTree(spaced, geometry.RectF.init(0, 0, 120, 40), &spaced_nodes);
    try expectLayoutFrame(spaced_layout, 5, geometry.RectF.init(0, 0, 40, 12));
    try expectLayoutFrame(spaced_layout, 6, geometry.RectF.init(100, 0, 20, 16));
}

test "widget text alignment emits local text layout options" {
    const tokens = DesignTokens{
        .typography = .{ .font_id = 1, .body_size = 10 },
    };

    const centered = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 20, 100, 20),
        .text = "Hi",
        .text_alignment = .center,
    };
    var center_commands: [1]CanvasCommand = undefined;
    var center_builder = Builder.init(&center_commands);
    try emitWidgetTree(&center_builder, centered, tokens);
    switch (center_builder.displayList().commands[0]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 1)), text.id);
            try std.testing.expectApproxEqAbs(@as(f32, 10), text.origin.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 32.5), text.origin.y, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(@as(f32, 100), text.text_layout.?.max_width);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    const end = Widget{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 20, 100, 20),
        .text = "Hi",
        .text_alignment = .end,
    };
    var end_commands: [1]CanvasCommand = undefined;
    var end_builder = Builder.init(&end_commands);
    try emitWidgetTree(&end_builder, end, tokens);
    switch (end_builder.displayList().commands[0]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextAlign.end, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget opacity wraps subtree display list commands" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(8, 10, 80, 20),
        .text = "Fade",
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .opacity = 0.5,
        .children = &children,
    };

    var direct_commands: [3]CanvasCommand = undefined;
    var direct_builder = Builder.init(&direct_commands);
    try emitWidgetTree(&direct_builder, root, .{});
    const direct_display_list = direct_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), direct_display_list.commandCount());
    switch (direct_display_list.commands[0]) {
        .push_opacity => |opacity| try std.testing.expectEqual(@as(f32, 0.5), opacity),
        else => return error.TestUnexpectedResult,
    }
    switch (direct_display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Fade", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(direct_display_list.commands[2] == .pop_opacity);

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try direct_display_list.renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 1), render_plan.commandCount());
    try std.testing.expectEqual(@as(f32, 0.5), render_plan.commands[0].opacity);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 40), &nodes);
    var layout_commands: [3]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, .{});
    const layout_display_list = layout_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), layout_display_list.commandCount());
    switch (layout_display_list.commands[0]) {
        .push_opacity => |opacity| try std.testing.expectEqual(@as(f32, 0.5), opacity),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(layout_display_list.commands[2] == .pop_opacity);

    var transparent_commands: [1]CanvasCommand = undefined;
    var transparent_builder = Builder.init(&transparent_commands);
    try emitWidgetTree(&transparent_builder, .{ .kind = .stack, .opacity = 0, .children = &children }, .{});
    try std.testing.expectEqual(@as(usize, 0), transparent_builder.displayList().commandCount());
}

test "widget transform wraps subtree display list commands" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 40, 20),
            .transform = Affine.translate(20, 0),
            .text = "Move",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(0, 24, 40, 20),
            .text = "Still",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .transform => |transform| try std.testing.expectEqualDeep(Affine.translate(20, 0), transform),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Move", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .transform => |transform| try std.testing.expectEqualDeep(Affine.translate(-20, 0), transform),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Still", text.text),
        else => return error.TestUnexpectedResult,
    }

    var render_commands: [2]RenderCommand = undefined;
    const render_plan = try display_list.renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 2), render_plan.commandCount());
    try std.testing.expectEqualDeep(Affine.translate(20, 0), render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(Affine.identity(), render_plan.commands[1].transform);

    var invalid_commands: [1]CanvasCommand = undefined;
    var invalid_builder = Builder.init(&invalid_commands);
    try std.testing.expectError(error.InvalidTransform, emitWidgetTree(&invalid_builder, .{
        .kind = .text,
        .transform = Affine.scale(0, 1),
        .text = "Bad",
    }, .{}));
    try std.testing.expectEqual(@as(usize, 0), invalid_builder.displayList().commandCount());
}

test "widget transform affects hit testing" {
    const button = Widget{
        .id = 4,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 32, 24),
        .transform = Affine.translate(40, 0),
        .text = "Go",
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(button, button.frame, &nodes);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(8, 12)) == null);
    const hit = layout.hitTest(geometry.PointF.init(48, 12)).?;
    try std.testing.expectEqual(@as(ObjectId, 4), hit.id);
    try std.testing.expectEqual(WidgetKind.button, hit.kind);
}

test "widget clip content wraps subtree display list and hit testing" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "Clip",
        .semantics = .{ .focusable = true },
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 50, 20),
        .layout = .{ .clip_content = true },
        .children = &children,
    };

    var direct_commands: [3]CanvasCommand = undefined;
    var direct_builder = Builder.init(&direct_commands);
    try emitWidgetTree(&direct_builder, root, .{});
    const direct_display_list = direct_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), direct_display_list.commandCount());
    switch (direct_display_list.commands[0]) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 50, 20), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (direct_display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Clip", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(direct_display_list.commands[2] == .pop_clip);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &nodes);
    var layout_commands: [3]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, .{});
    const layout_display_list = layout_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), layout_display_list.commandCount());
    try std.testing.expect(layout_display_list.commands[0] == .push_clip);
    try std.testing.expect(layout_display_list.commands[2] == .pop_clip);

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(45, 10)).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(55, 10)) == null);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
}

test "widget layout hit testing prefers deepest topmost enabled target" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(8, 8, 90, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 90, 32),
            .text = "Active",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 80), &nodes);
    const active_hit = layout.hitTest(geometry.PointF.init(24, 24)).?;
    try std.testing.expectEqual(@as(ObjectId, 3), active_hit.id);
    try std.testing.expectEqual(WidgetKind.button, active_hit.kind);

    const panel_hit = layout.hitTest(geometry.PointF.init(10, 10)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), panel_hit.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(200, 10)) == null);
}

test "widget layout resolves cursor intent from hit targets" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(8, 8, 90, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(8, 48, 120, 32), .text = "Query" },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(8, 88, 120, 32), .value = 0.5 },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 140), &nodes);
    try std.testing.expectEqual(WidgetCursor.pointing_hand, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 16))));
    try std.testing.expectEqual(WidgetCursor.text, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 56))));
    try std.testing.expectEqual(WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 96))));
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(layout.hitTest(geometry.PointF.init(150, 130))));
    try std.testing.expectEqual(WidgetCursor.arrow, cursorForWidgetTarget(.button, .{ .disabled = true }));
}

test "widget grid layout places children in deterministic cells" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
        .{ .id = 4, .kind = .button, .text = "Three" },
        .{ .id = 5, .kind = .button, .text = "Four" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .grid,
        .layout = .{ .gap = 8, .columns = 2 },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 208, 88), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 100, 40));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(108, 0, 100, 40));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 48, 100, 40));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(108, 48, 100, 40));

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    try std.testing.expectEqual(@as(usize, 8), builder.displayList().commandCount());
}

test "widget data grid exposes rows cells semantics and display list" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Name", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const deployment_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .command = "cell.open", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &deployment_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 240, 58), &nodes);
    try std.testing.expectEqual(@as(usize, 7), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 240, 58));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 240, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 120, 28));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(120, 0, 120, 28));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 30, 240, 28));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 30, 120, 28));
    try expectLayoutFrame(layout, 7, geometry.RectF.init(120, 30, 120, 28));

    const hit = layout.hitTest(geometry.PointF.init(8, 38)).?;
    try std.testing.expectEqual(@as(ObjectId, 6), hit.id);
    try std.testing.expectEqual(WidgetKind.data_cell, hit.kind);

    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 7), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqualStrings("Deployments", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[2].role);
    try std.testing.expectEqualStrings("Name", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 1), semantics[2].parent_index);
    try std.testing.expect(semantics[2].focusable);
    try std.testing.expect(semantics[2].actions.focus);
    try std.testing.expect(semantics[2].actions.select);
    try std.testing.expect(!semantics[2].actions.press);
    try std.testing.expectEqual(WidgetRole.row, semantics[4].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[4].parent_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[5].role);
    try std.testing.expectEqualStrings("Edge API", semantics[5].label);
    try std.testing.expect(semantics[5].actions.select);
    try std.testing.expect(semantics[5].actions.press);
    try expectRect(geometry.RectF.init(0, 30, 120, 28), semantics[5].bounds);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 12), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rect => |fill| try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 1)), fill.id),
        else => return error.UnexpectedCommand,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Name", text.text),
        else => return error.UnexpectedCommand,
    }
}

test "widget virtualized data grid lays out visible rows" {
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .value = 25,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
        },
        .children = &rows,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 160, 45), &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 160, 45));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 160, 20));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 25, 160, 20));
    try std.testing.expect(layout.findById(2) == null);
    try std.testing.expect(layout.findById(5) == null);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqual(@as(?usize, 4), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 0), semantics[0].grid_column_count);

    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(ObjectId, 3), semantics[1].id);
    try std.testing.expectEqual(@as(?usize, 1), semantics[1].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 4), semantics[1].grid_row_count);

    try std.testing.expectEqual(WidgetRole.row, semantics[2].role);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[2].id);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 4), semantics[2].grid_row_count);
}

test "widget scroll view offsets children and clips display list" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 20,
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 60), &nodes);
    try std.testing.expectEqual(@as(usize, 4), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 120, 60));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -20, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 24, 120, 32));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 60, 120, 32));

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 13), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 120, 60), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[10] == .pop_clip);
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |track| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 2)), track.id);
            try expectRect(geometry.RectF.init(114, 3, 3, 54), track.rect);
            try expectFillColor(Color.rgba8(15, 23, 42, 28), track.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .fill_rounded_rect => |thumb| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 3)), thumb.id);
            try std.testing.expectApproxEqAbs(@as(f32, 12.642), thumb.rect.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 28.928), thumb.rect.height, 0.001);
            try expectFillColor(Color.rgba(100.0 / 255.0, 116.0 / 255.0, 139.0 / 255.0, 0.55), thumb.fill);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(10, 4)).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTest(geometry.PointF.init(10, 50)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(10, 58)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.scroll_view, blank_hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 70)) == null);

    var route_buffer: [2]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .wheel, .point = geometry.PointF.init(10, 58), .delta = geometry.OffsetF.init(0, -12) }, &route_buffer);
    try std.testing.expectEqual(@as(ObjectId, 1), route.target.?.id);
    try std.testing.expectEqual(@as(usize, 1), route.entries.len);
    try std.testing.expectEqual(WidgetEventPhase.target, route.entries[0].phase);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 4), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0 / 52.0), semantics[0].value.?, 0.001);
    try std.testing.expect(semantics[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 20.0), semantics[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 60.0), semantics[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 112.0), semantics[0].scroll.content_extent);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.focus);
    try std.testing.expect(semantics[0].actions.increment);
    try std.testing.expect(semantics[0].actions.decrement);
}

test "widget focus traversal skips scroll clipped children" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 20,
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 60), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -20, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 24, 120, 32));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 60, 120, 32));

    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(1, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTarget(3, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(1, .backward).?.id);
    try std.testing.expect(layout.focusTargetById(4) == null);
}

test "scroll state applies wheel deltas kinetic decay and bounds" {
    const physics = ScrollPhysics{
        .wheel_multiplier = 2,
        .wheel_velocity_scale = 10,
        .deceleration_per_second = 0.5,
        .stop_velocity = 1,
    };
    const start = ScrollState{
        .offset = 10,
        .viewport_extent = 100,
        .content_extent = 360,
    };

    const wheeled = start.applyWheel(30, physics);
    try std.testing.expectEqual(@as(f32, 70), wheeled.offset);
    try std.testing.expectEqual(@as(f32, 600), wheeled.velocity);

    const stepped = wheeled.stepKinetic(100, physics);
    try std.testing.expect(stepped.offset > wheeled.offset);
    try std.testing.expect(stepped.velocity > 0);
    try std.testing.expect(stepped.velocity < wheeled.velocity);

    const clamped = wheeled.applyWheel(1000, physics);
    try std.testing.expectEqual(@as(f32, 260), clamped.offset);
    try std.testing.expectEqual(@as(f32, 0), clamped.velocity);
}

test "virtual list range computes visible and overscan windows" {
    const range = virtualListRange(.{
        .item_count = 100,
        .item_extent = 24,
        .item_gap = 4,
        .viewport_extent = 70,
        .scroll_offset = 50,
        .overscan = 1,
    });

    try std.testing.expectEqual(@as(usize, 0), range.start_index);
    try std.testing.expectEqual(@as(usize, 6), range.end_index);
    try std.testing.expectEqual(@as(usize, 1), range.first_visible_index);
    try std.testing.expectEqual(@as(usize, 4), range.last_visible_index);
    try std.testing.expectEqual(@as(usize, 6), range.itemCount());
    try std.testing.expectEqual(@as(f32, 2796), range.content_extent);
    try std.testing.expectEqual(@as(f32, 2632), range.after_extent);

    const empty = virtualListRange(.{
        .item_count = 10,
        .item_extent = 0,
        .viewport_extent = 100,
    });
    try std.testing.expect(empty.isEmpty());
}

test "widget virtualized scroll view lays out only visible overscan children" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
        .{ .id = 6, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Four" },
        .{ .id = 7, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Five" },
        .{ .id = 8, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Six" },
        .{ .id = 9, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Seven" },
        .{ .id = 10, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Eight" },
        .{ .id = 11, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Nine" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 45,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 50), &nodes);
    try std.testing.expectEqual(@as(usize, 6), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 120, 50));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -45, 120, 20));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, -20, 120, 20));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 5, 120, 20));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 30, 120, 20));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 55, 120, 20));
    try std.testing.expect(layout.findById(7) == null);

    try std.testing.expectEqual(@as(ObjectId, 4), layout.hitTest(geometry.PointF.init(10, 8)).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 56)) == null);
}

test "widget virtualized list exposes logical item semantics" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Four" },
        .{ .id = 7, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Five" },
        .{ .id = 8, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Six" },
        .{ .id = 9, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Seven" },
        .{ .id = 10, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Eight" },
        .{ .id = 11, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Nine" },
    };
    const list = Widget{
        .id = 1,
        .kind = .list,
        .value = 45,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 120, 50), &nodes);
    try std.testing.expectEqual(@as(usize, 6), layout.nodeCount());
    try std.testing.expect(layout.findById(7) == null);

    var semantics_buffer: [6]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 6), semantics.len);
    try std.testing.expectEqual(WidgetRole.list, semantics[0].role);
    try std.testing.expect(!semantics[0].list.present);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[1].role);
    try std.testing.expectEqual(@as(ObjectId, 2), semantics[1].id);
    try std.testing.expect(semantics[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), semantics[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[1].list.item_count);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[3].role);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[3].id);
    try std.testing.expect(semantics[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), semantics[3].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[3].list.item_count);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[5].role);
    try std.testing.expectEqual(@as(ObjectId, 6), semantics[5].id);
    try std.testing.expect(semantics[5].list.present);
    try std.testing.expectEqual(@as(u32, 4), semantics[5].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[5].list.item_count);
}

test "widget pointer route includes capture target and bubble phases" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Run",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var route_entries: [5]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(20, 20),
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(@as(usize, 5), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .capture, 5);
    try expectRouteEntry(route.entries[2], .target, 2);
    try expectRouteEntry(route.entries[3], .bubble, 5);
    try expectRouteEntry(route.entries[4], .bubble, 1);
}

test "widget pointer route honors captured target for drag lifecycle" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Run",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);

    var move_entries: [5]WidgetEventRouteEntry = undefined;
    const move_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &move_entries);
    try std.testing.expect(move_route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), move_route.target.?.id);
    try std.testing.expectEqual(@as(usize, 5), move_route.entries.len);
    try expectRouteEntry(move_route.entries[0], .capture, 1);
    try expectRouteEntry(move_route.entries[1], .capture, 5);
    try expectRouteEntry(move_route.entries[2], .target, 2);
    try expectRouteEntry(move_route.entries[3], .bubble, 5);
    try expectRouteEntry(move_route.entries[4], .bubble, 1);

    var up_entries: [5]WidgetEventRouteEntry = undefined;
    const up_route = try layout.routePointerEvent(.{
        .phase = .up,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &up_entries);
    try std.testing.expectEqual(@as(ObjectId, 2), up_route.target.?.id);

    var cancel_entries: [5]WidgetEventRouteEntry = undefined;
    const cancel_route = try layout.routePointerEvent(.{
        .phase = .cancel,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &cancel_entries);
    try std.testing.expectEqual(@as(ObjectId, 2), cancel_route.target.?.id);
}

test "widget pointer route skips scroll clipped captured targets" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 40,
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -40, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 8, 120, 32));

    var hidden_entries: [0]WidgetEventRouteEntry = .{};
    const hidden_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(10, 20),
        .captured_id = 2,
    }, &hidden_entries);
    try std.testing.expect(hidden_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), hidden_route.entries.len);

    var visible_entries: [3]WidgetEventRouteEntry = undefined;
    const visible_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(180, 80),
        .captured_id = 3,
    }, &visible_entries);
    try std.testing.expect(visible_route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 3), visible_route.target.?.id);
    try std.testing.expectEqual(@as(usize, 3), visible_route.entries.len);
    try expectRouteEntry(visible_route.entries[0], .capture, 1);
    try expectRouteEntry(visible_route.entries[1], .target, 3);
    try expectRouteEntry(visible_route.entries[2], .bubble, 1);
}

test "widget pointer capture does not retarget hover down or wheel" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{.{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 80, 32),
            .text = "Run",
        }},
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const hover_route = try layout.routePointerEvent(.{
        .phase = .hover,
        .point = geometry.PointF.init(200, 20),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(hover_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), hover_route.entries.len);

    const down_route = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(200, 20),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(down_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), down_route.entries.len);

    const wheel_route = try layout.routePointerEvent(.{
        .phase = .wheel,
        .point = geometry.PointF.init(200, 20),
        .delta = geometry.OffsetF.init(0, -16),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(wheel_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), wheel_route.entries.len);
}

test "widget pointer route handles no hit and bounded output" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{.{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 80, 32),
            .text = "Run",
        }},
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};
    const no_hit = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(200, 20),
    }, &empty_entries);
    try std.testing.expect(no_hit.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_hit.entries.len);

    var small_entries: [1]WidgetEventRouteEntry = undefined;
    try std.testing.expectError(error.WidgetEventRouteListFull, layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(20, 20),
    }, &small_entries));
}

test "widget file drop route targets explicit drop semantics" {
    const row_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Upload",
    }};
    const root_children = [_]Widget{.{
        .id = 2,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 44),
        .semantics = .{ .actions = .{ .drop_files = true } },
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    const paths = [_][]const u8{"/tmp/image.png"};
    var route_entries: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
        .paths = &paths,
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.row, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    for (semantics) |semantic| {
        if (semantic.id == 2) {
            try std.testing.expect(semantic.actions.drop_files);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "widget file drop route ignores missing paths disabled and non-drop targets" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{
            .{
                .id = 2,
                .kind = .panel,
                .frame = geometry.RectF.init(8, 8, 80, 44),
                .semantics = .{ .actions = .{ .drop_files = true } },
                .state = .{ .disabled = true },
            },
            .{
                .id = 3,
                .kind = .button,
                .frame = geometry.RectF.init(96, 8, 80, 44),
                .text = "Plain",
            },
        },
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 80), &nodes);
    const paths = [_][]const u8{"/tmp/report.csv"};
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const no_paths = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(no_paths.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_paths.entries.len);

    const disabled = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
        .paths = &paths,
    }, &empty_entries);
    try std.testing.expect(disabled.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled.entries.len);

    const plain = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(110, 20),
        .paths = &paths,
    }, &empty_entries);
    try std.testing.expect(plain.target == null);
    try std.testing.expectEqual(@as(usize, 0), plain.entries.len);
}

test "widget drag route targets explicit drag source semantics" {
    const row_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Move",
    }};
    const root_children = [_]Widget{.{
        .id = 2,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 44),
        .semantics = .{ .actions = .{ .drag = true } },
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var route_entries: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(60, 40),
        .delta = geometry.OffsetF.init(20, 4),
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.row, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    for (semantics) |semantic| {
        if (semantic.id == 2) {
            try std.testing.expect(semantic.actions.drag);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "widget drag route ignores missing disabled and non-drag sources" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{
            .{
                .id = 2,
                .kind = .panel,
                .frame = geometry.RectF.init(8, 8, 80, 44),
                .semantics = .{ .actions = .{ .drag = true } },
                .state = .{ .disabled = true },
            },
            .{
                .id = 3,
                .kind = .button,
                .frame = geometry.RectF.init(96, 8, 80, 44),
                .text = "Plain",
            },
        },
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const no_source = try layout.routeDragEvent(.{
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(no_source.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_source.entries.len);

    const disabled = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(disabled.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled.entries.len);

    const plain = try layout.routeDragEvent(.{
        .source_id = 3,
        .point = geometry.PointF.init(110, 20),
    }, &empty_entries);
    try std.testing.expect(plain.target == null);
    try std.testing.expectEqual(@as(usize, 0), plain.entries.len);
}

test "widget drag route skips scroll clipped sources" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden", .semantics = .{ .actions = .{ .drag = true } } },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible", .semantics = .{ .actions = .{ .drag = true } } },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 40,
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -40, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 8, 120, 32));

    var hidden_entries: [0]WidgetEventRouteEntry = .{};
    const hidden = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(180, 80),
        .delta = geometry.OffsetF.init(12, 0),
    }, &hidden_entries);
    try std.testing.expect(hidden.target == null);
    try std.testing.expectEqual(@as(usize, 0), hidden.entries.len);

    var visible_entries: [3]WidgetEventRouteEntry = undefined;
    const visible = try layout.routeDragEvent(.{
        .source_id = 3,
        .point = geometry.PointF.init(180, 80),
        .delta = geometry.OffsetF.init(12, 0),
    }, &visible_entries);
    try std.testing.expect(visible.target != null);
    try std.testing.expectEqual(@as(ObjectId, 3), visible.target.?.id);
    try std.testing.expectEqual(@as(usize, 3), visible.entries.len);
    try expectRouteEntry(visible.entries[0], .capture, 1);
    try expectRouteEntry(visible.entries[1], .target, 3);
    try expectRouteEntry(visible.entries[2], .bubble, 1);
}

test "widget keyboard route uses focused target and ancestors" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 0, 120, 32),
        .text = "Find",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 140, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 180, 80), &nodes);
    var route_entries: [5]WidgetEventRouteEntry = undefined;
    const route = try layout.routeKeyboardEvent(.{
        .phase = .key_down,
        .focused_id = 2,
        .key = "enter",
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.text_field, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 5), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .capture, 5);
    try expectRouteEntry(route.entries[2], .target, 2);
    try expectRouteEntry(route.entries[3], .bubble, 5);
    try expectRouteEntry(route.entries[4], .bubble, 1);
}

test "widget keyboard route handles missing focus non-focus targets and bounded output" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(8, 8, 100, 20),
            .text = "Title",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(8, 36, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 76, 100, 32),
            .text = "Run",
        },
    };
    const root = Widget{ .id = 1, .kind = .panel, .children = &children };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);

    var empty_entries: [0]WidgetEventRouteEntry = .{};
    const no_focus = try layout.routeKeyboardEvent(.{ .phase = .key_down, .key = "enter" }, &empty_entries);
    try std.testing.expect(no_focus.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_focus.entries.len);

    const text_target = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 2, .key = "enter" }, &empty_entries);
    try std.testing.expect(text_target.target == null);
    try std.testing.expectEqual(@as(usize, 0), text_target.entries.len);

    const disabled_target = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 3, .key = "enter" }, &empty_entries);
    try std.testing.expect(disabled_target.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled_target.entries.len);

    var small_entries: [1]WidgetEventRouteEntry = undefined;
    try std.testing.expectError(error.WidgetEventRouteListFull, layout.routeKeyboardEvent(.{
        .phase = .key_down,
        .focused_id = 4,
        .key = "enter",
    }, &small_entries));
}

test "widget focus traversal skips disabled nodes and wraps" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 100, 20),
            .text = "Search",
            .semantics = .{ .focusable = true },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 28, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(0, 68, 100, 32),
            .text = "Apply",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(4, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(2, .backward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .backward).?.id);
}

test "widget focus target lookup validates focusable ids" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 100, 20),
            .text = "Title",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 28, 100, 32),
            .text = "Run",
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(0, 68, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);
    try std.testing.expect(layout.focusTargetById(2) == null);
    try std.testing.expect(layout.focusTargetById(4) == null);
    try std.testing.expect(layout.focusTargetById(99) == null);

    const target = layout.focusTargetById(3).?;
    try std.testing.expectEqual(@as(ObjectId, 3), target.id);
    try std.testing.expectEqual(WidgetKind.button, target.kind);
}

test "design tokens provide theme and contrast palettes" {
    const light = DesignTokens.theme(.{});
    try std.testing.expectEqual(Density.regular, light.density);
    try std.testing.expectEqualDeep(ColorTokens.light(), light.colors);

    const dark = DesignTokens.theme(.{ .color_scheme = .dark, .density = .compact });
    try std.testing.expectEqual(Density.compact, dark.density);
    try std.testing.expectEqualDeep(ColorTokens.dark(), dark.colors);
    try std.testing.expectEqualDeep(Color.rgb8(9, 11, 17), dark.colors.background);
    try std.testing.expectEqualDeep(Color.rgb8(248, 250, 252), dark.colors.text);

    const high_contrast = DesignTokens.theme(.{ .color_scheme = .dark, .contrast = .high, .density = .spacious });
    try std.testing.expectEqual(Density.spacious, high_contrast.density);
    try std.testing.expectEqualDeep(ColorTokens.highContrastDark(), high_contrast.colors);
    try std.testing.expectEqualDeep(Color.rgb8(0, 0, 0), high_contrast.colors.background);
    try std.testing.expectEqualDeep(Color.rgba8(255, 255, 255, 190), high_contrast.colors.border);

    const reduced_motion = DesignTokens.theme(.{ .reduce_motion = true });
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.slow));
    try std.testing.expectEqual(Easing.linear, reduced_motion.motion.easing);
}

test "themed design tokens flow into widget display lists" {
    const tokens = DesignTokens.theme(.{ .color_scheme = .dark, .contrast = .high });
    const button = Widget{
        .id = 9,
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 96, 32),
        .text = "Run",
        .state = .{ .selected = true, .focused = true },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());

    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.border, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget spatial focus traversal moves across data grid cells" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &row_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 240, 58), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .right).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(4, .left).?.id);
    try std.testing.expectEqual(@as(ObjectId, 6), layout.focusTarget(3, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 7), layout.focusTarget(4, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(6, .up).?.id);
    try std.testing.expect(layout.focusTarget(3, .left) == null);
    try std.testing.expect(layout.focusTarget(3, .up) == null);
    try std.testing.expect(layout.focusTarget(null, .right) == null);
}

test "widget spatial focus traversal reaches staggered targets" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 40, 24),
            .text = "Start",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(72, 40, 40, 24),
            .text = "Next",
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(60, 88, 40, 24),
            .text = "Lower",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 128), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .right).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(3, .left).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(3, .up).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .down).?.id);
}

test "widget layout collects accessibility semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 100, 32),
            .text = "Run",
            .semantics = .{ .label = "Run query" },
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(10, 52, 160, 8),
            .value = 0.75,
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 68, 120, 20),
            .text = "Hidden note",
            .semantics = .{ .hidden = true },
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .semantics = .{ .label = "Dashboard card" },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 120), &nodes);
    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Dashboard card", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);

    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqualStrings("Run query", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.focus);
    try std.testing.expect(semantics[1].actions.press);
    try std.testing.expect(!semantics[1].actions.toggle);

    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0.75), semantics[2].value);
    try std.testing.expect(semantics[2].actions.isEmpty());
    try expectRect(geometry.RectF.init(10, 52, 160, 8), semantics[2].bounds);
}

test "widget disabled semantics suppresses focusability and actions" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(8, 8, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
            .semantics = .{ .focusable = true, .actions = .{ .focus = true, .press = true } },
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(8, 48, 140, 20),
            .text = "Disabled copy",
            .state = .{ .disabled = true },
            .semantics = .{ .focusable = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 76, 100, 32),
            .text = "Active",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.focusTargetById(2) == null);
    try std.testing.expect(layout.focusTargetById(3) == null);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);

    try std.testing.expectEqual(@as(ObjectId, 2), semantics[0].id);
    try std.testing.expect(semantics[0].state.disabled);
    try std.testing.expect(!semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.isEmpty());

    try std.testing.expectEqual(@as(ObjectId, 3), semantics[1].id);
    try std.testing.expect(semantics[1].state.disabled);
    try std.testing.expect(!semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.isEmpty());

    try std.testing.expectEqual(@as(ObjectId, 4), semantics[2].id);
    try std.testing.expect(semantics[2].focusable);
    try std.testing.expect(semantics[2].actions.focus);
    try std.testing.expect(semantics[2].actions.press);
}

test "widget hidden semantics suppresses descendant semantics" {
    const hidden_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Hidden child",
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .panel,
            .frame = geometry.RectF.init(8, 8, 120, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 64, 120, 32),
            .text = "Visible",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .semantics = .{ .label = "Root" },
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);
    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(@as(ObjectId, 1), semantics[0].id);
    try std.testing.expectEqualStrings("Root", semantics[0].label);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[1].id);
    try std.testing.expectEqualStrings("Visible", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
}

test "widget hidden subtrees do not receive input routes" {
    const hidden_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Hidden child",
        .semantics = .{ .actions = .{ .drag = true, .drop_files = true } },
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .panel,
            .frame = geometry.RectF.init(8, 8, 120, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 64, 120, 32),
            .text = "Visible",
        },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);

    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 16)) == null);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.hitTest(geometry.PointF.init(16, 72)).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.focusTargetById(3) == null);

    var route_buffer: [4]WidgetEventRouteEntry = undefined;
    const pointer_route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expect(pointer_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), pointer_route.entries.len);

    const keyboard_route = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 3, .key = "Enter" }, &route_buffer);
    try std.testing.expect(keyboard_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), keyboard_route.entries.len);

    const paths = [_][]const u8{"/tmp/report.csv"};
    const drop_route = try layout.routeFileDropEvent(.{ .point = geometry.PointF.init(16, 16), .paths = &paths }, &route_buffer);
    try std.testing.expect(drop_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), drop_route.entries.len);

    const drag_route = try layout.routeDragEvent(.{ .source_id = 3, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expect(drag_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), drag_route.entries.len);
}

test "widget controls expose roles values focus and hit testing" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 46, 120, 28),
            .text = "Focus",
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(10, 82, 160, 32),
            .value = 0.35,
        },
    };
    const root = Widget{ .id = 1, .kind = .panel, .children = &children };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 220, 140), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(4, .backward).?.id);

    const slider_hit = layout.hitTest(geometry.PointF.init(40, 94)).?;
    try std.testing.expectEqual(@as(ObjectId, 4), slider_hit.id);
    try std.testing.expectEqual(WidgetKind.slider, slider_hit.kind);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 4), semantics.len);
    try std.testing.expectEqual(WidgetRole.checkbox, semantics[1].role);
    try std.testing.expectEqualStrings("Live", semantics[1].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.focus);
    try std.testing.expect(semantics[1].actions.toggle);
    try std.testing.expectEqual(WidgetRole.switch_control, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
    try std.testing.expect(semantics[2].actions.toggle);
    try std.testing.expectEqual(WidgetRole.slider, semantics[3].role);
    try std.testing.expectEqual(@as(?f32, 0.35), semantics[3].value);
    try std.testing.expect(semantics[3].actions.focus);
    try std.testing.expect(semantics[3].actions.increment);
    try std.testing.expect(semantics[3].actions.decrement);
    try std.testing.expect(!semantics[3].actions.press);
}

test "widget icons expose image and button semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .icon,
            .frame = geometry.RectF.init(8, 8, 24, 24),
            .text = "?",
            .semantics = .{ .label = "Help" },
        },
        .{
            .id = 3,
            .kind = .icon_button,
            .frame = geometry.RectF.init(40, 4, 32, 32),
            .text = "+",
            .state = .{ .focused = true },
            .semantics = .{ .label = "Add item" },
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 16)) == null);

    const button_hit = layout.hitTest(geometry.PointF.init(48, 16)).?;
    try std.testing.expectEqual(@as(ObjectId, 3), button_hit.id);
    try std.testing.expectEqual(WidgetKind.icon_button, button_hit.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Help", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqualStrings("Add item", semantics[1].label);
    try std.testing.expect(semantics[1].focusable);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3) },
        .stroke = .{ .focus = 4 },
    };
    var icon_commands: [1]CanvasCommand = undefined;
    var icon_builder = Builder.init(&icon_commands);
    try emitWidgetTree(&icon_builder, children[0], tokens);
    const icon_display_list = icon_builder.displayList();
    try std.testing.expectEqual(@as(usize, 1), icon_display_list.commandCount());
    switch (icon_display_list.commands[0]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 1)), text.id);
            try std.testing.expectEqualStrings("?", text.text);
        },
        else => return error.TestUnexpectedResult,
    }

    var button_commands: [3]CanvasCommand = undefined;
    var button_builder = Builder.init(&button_commands);
    try emitWidgetTree(&button_builder, children[1], tokens);
    const button_display_list = button_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), button_display_list.commandCount());
    switch (button_display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 4), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (button_display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 3)), text.id);
            try std.testing.expectEqualStrings("+", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget image emits draw image and exposes image semantics" {
    const image = Widget{
        .id = 8,
        .kind = .image,
        .frame = geometry.RectF.init(12, 14, 80, 48),
        .image_id = 42,
        .image_src = geometry.RectF.init(0, 0, 320, 192),
        .image_fit = .cover,
        .image_sampling = .nearest,
        .image_opacity = 0.75,
        .semantics = .{ .label = "Deployment preview" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(image, image.frame, &nodes);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(20, 20)) == null);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Deployment preview", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);

    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 1), display_list.commandCount());
    switch (display_list.commands[0]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(8, 1)), draw.id);
            try std.testing.expectEqual(@as(ImageId, 42), draw.image_id);
            try expectRect(geometry.RectF.init(0, 0, 320, 192), draw.src);
            try expectRect(geometry.RectF.init(12, 14, 80, 48), draw.dst);
            try std.testing.expectEqual(ImageFit.cover, draw.fit);
            try std.testing.expectEqual(ImageSampling.nearest, draw.sampling);
            try std.testing.expectEqual(@as(f32, 0.75), draw.opacity);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget text fields expose textbox semantics and render focused chrome" {
    const text_field = Widget{
        .id = 8,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .text = "search terms",
        .state = .{ .focused = true },
        .semantics = .{ .label = "Search" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(text_field, text_field.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 8), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.text_field, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Search", semantics[0].label);
    try std.testing.expectEqualStrings("search terms", semantics[0].text_value);
    try std.testing.expect(semantics[0].focusable);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3) },
        .stroke = .{ .focus = 3 },
    };
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, text_field, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualStrings("search terms", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "widget search fields expose textbox semantics and render search chrome" {
    const search_field = Widget{
        .id = 10,
        .kind = .search_field,
        .frame = geometry.RectF.init(10, 12, 220, 36),
        .text = "customers",
        .text_selection = TextSelection.collapsed(9),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Search customers" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(search_field, search_field.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 10), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.search_field, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Search customers", semantics[0].label);
    try std.testing.expectEqualStrings("customers", semantics[0].text_value);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expectEqualDeep(TextRange.init(9, 9), semantics[0].text_selection.?);
    const search_geometry = layout.textGeometry(10, .{}).?;
    try expectRect(geometry.RectF.init(105, 19.5, 1, 17.5), search_geometry.caret_bounds.?);
    try std.testing.expectEqual(@as(usize, 0), search_geometry.selection_rect_count);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3), .text_muted = Color.rgb8(90, 91, 92) },
        .stroke = .{ .focus = 3 },
    };
    var commands: [9]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, search_field, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_line => |line| try std.testing.expectEqual(@as(ObjectId, widgetPartId(10, 3)), line.id),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .draw_text => |text| try std.testing.expectEqualStrings("customers", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "widget text fields render selection caret and composition ranges" {
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(10, 20, 30) },
    };
    const composing = Widget{
        .id = 9,
        .kind = .text_field,
        .frame = geometry.RectF.init(8, 10, 180, 36),
        .text = "abcdef",
        .text_selection = .{ .anchor = 1, .focus = 4 },
        .text_composition = TextRange.init(2, 4),
        .state = .{ .focused = true },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(composing, composing.frame, &nodes);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqualDeep(TextRange.init(1, 4), semantics[0].text_selection.?);
    try std.testing.expectEqualDeep(TextRange.init(2, 4), semantics[0].text_composition.?);
    const text_geometry = layout.textGeometry(9, .{}).?;
    try std.testing.expect(text_geometry.caret_bounds == null);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.selection_rect_count);
    try expectRect(geometry.RectF.init(27, 17.5, 21, 17.5), text_geometry.selection_bounds.?);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.composition_rect_count);
    try expectRect(geometry.RectF.init(34, 17.5, 14, 17.5), text_geometry.composition_bounds.?);

    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |selection| try expectFillColor(textSelectionFillColor(tokens), selection.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("abcdef", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextWrap.none, text.text_layout.?.wrap);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_line => |line| try expectFillColor(tokens.colors.focus_ring, line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }

    const caret = Widget{
        .id = 10,
        .kind = .text_field,
        .frame = geometry.RectF.init(8, 10, 180, 36),
        .text = "abcd",
        .text_selection = TextSelection.collapsed(2),
        .state = .{ .focused = true },
    };
    var caret_commands: [4]CanvasCommand = undefined;
    var caret_builder = Builder.init(&caret_commands);
    try emitWidgetTree(&caret_builder, caret, tokens);
    const caret_display_list = caret_builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), caret_display_list.commandCount());
    switch (caret_display_list.commands[3]) {
        .draw_line => |line| {
            try expectFillColor(tokens.colors.focus_ring, line.stroke.fill);
            try std.testing.expectEqual(line.from.x, line.to.x);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget text fields render wrapped selection geometry" {
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(10, 20, 30) },
        .typography = .{ .body_size = 10 },
        .spacing = .{ .sm = 4, .md = 4 },
    };
    const field = Widget{
        .id = 11,
        .kind = .text_field,
        .frame = geometry.RectF.init(4, 6, 28, 60),
        .text = "AB CD",
        .text_selection = .{ .anchor = 1, .focus = 5 },
        .state = .{ .focused = true },
    };

    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, tokens);

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(field, field.frame, &nodes);
    const text_geometry = layout.textGeometry(11, tokens).?;
    try std.testing.expectEqual(@as(usize, 2), text_geometry.selection_rect_count);
    try expectRect(geometry.RectF.init(8, 10, 10, 25), text_geometry.selection_bounds.?);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 3)), selection.id);
            try expectRect(geometry.RectF.init(13, 10, 5, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 13)), selection.id);
            try expectRect(geometry.RectF.init(8, 22.5, 10, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 4)), text.id);
            try std.testing.expectEqualStrings("AB CD", text.text);
            try std.testing.expectEqual(TextWrap.word, text.text_layout.?.wrap);
            try std.testing.expectEqual(@as(f32, 20), text.text_layout.?.max_width);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget text fields map pointer positions to caret selections" {
    const tokens = DesignTokens{};
    const field = Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 160, 32),
        .text = "AéB",
    };
    try std.testing.expectEqual(@as(usize, 0), textOffsetForWidgetPoint(field, geometry.PointF.init(18, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 1), textOffsetForWidgetPoint(field, geometry.PointF.init(26, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 3), textOffsetForWidgetPoint(field, geometry.PointF.init(34, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 4), textOffsetForWidgetPoint(field, geometry.PointF.init(80, 24), tokens).?);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), textSelectionForWidgetPoint(field, geometry.PointF.init(34, 24), null, tokens).?);
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 1, .focus = 4 }, textSelectionForWidgetPoint(field, geometry.PointF.init(80, 24), 1, tokens).?);

    const search = Widget{
        .id = 3,
        .kind = .search_field,
        .frame = geometry.RectF.init(10, 52, 180, 32),
        .text = "Find",
    };
    try std.testing.expectEqual(@as(usize, 0), textOffsetForWidgetPoint(search, geometry.PointF.init(24, 64), tokens).?);
    try std.testing.expectEqual(@as(usize, 1), textOffsetForWidgetPoint(search, geometry.PointF.init(48, 64), tokens).?);
    try std.testing.expect(textOffsetForWidgetPoint(.{ .kind = .text_field, .state = .{ .disabled = true } }, geometry.PointF.init(0, 0), tokens) == null);

    const wrapped_tokens = DesignTokens{
        .typography = .{ .body_size = 10 },
        .spacing = .{ .sm = 4, .md = 4 },
    };
    const wrapped = Widget{
        .id = 4,
        .kind = .text_field,
        .frame = geometry.RectF.init(4, 6, 28, 60),
        .text = "AB CD",
    };
    try std.testing.expectEqual(@as(usize, 4), textOffsetForWidgetPoint(wrapped, geometry.PointF.init(14, 24), wrapped_tokens).?);
}

test "widget tooltip emits overlay chrome and tooltip semantics" {
    const tokens = DesignTokens{};
    const tooltip = Widget{
        .id = 1,
        .kind = .tooltip,
        .frame = geometry.RectF.init(10, 12, 140, 28),
        .text = "Saved",
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(tooltip, tooltip.frame, &nodes);

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .shadow => |shadow| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 1)), shadow.id);
            try expectRect(geometry.RectF.init(10, 12, 140, 28), shadow.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 2)), fill.id);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 3)), text.id);
            try std.testing.expectEqualStrings("Saved", text.text);
            try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(layout.hitTest(geometry.PointF.init(20, 20)) == null);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.tooltip, semantics[0].role);
    try std.testing.expectEqualStrings("Saved", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);
}

test "widget popover emits overlay chrome and routes child events" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Open",
    }};
    const popover = Widget{
        .id = 1,
        .kind = .popover,
        .frame = geometry.RectF.init(20, 24, 180, 120),
        .layout = .{ .padding = geometry.InsetsF.all(10) },
        .semantics = .{ .label = "Command palette" },
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(popover, popover.frame, &nodes);
    try std.testing.expectEqual(@as(usize, 2), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(20, 24, 180, 120));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(30, 34, 100, 32));

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(40, 44)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(190, 130)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.popover, blank_hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 10)) == null);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(40, 44) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.dialog, semantics[0].role);
    try std.testing.expectEqualStrings("Command palette", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);
}

test "widget menu surface groups menu items semantically" {
    const items = [_]Widget{
        .{
            .id = 2,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Rename",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .menu_item,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Archive",
        },
    };
    const menu = Widget{
        .id = 1,
        .kind = .menu_surface,
        .frame = geometry.RectF.init(20, 24, 180, 90),
        .layout = .{ .padding = geometry.InsetsF.all(6), .gap = 2 },
        .semantics = .{ .label = "More actions" },
        .children = &items,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(menu, menu.frame, &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(20, 24, 180, 90));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(26, 30, 168, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(26, 60, 168, 28));

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());

    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(34, 38)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(190, 108)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.menu_surface, blank_hit.kind);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(34, 38) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.menu, semantics[0].role);
    try std.testing.expectEqualStrings("More actions", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[1].role);
    try std.testing.expectEqualStrings("Rename", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[2].role);
    try std.testing.expectEqualStrings("Archive", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].parent_index);
}

test "widget list item and segmented controls expose selectable semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .frame = geometry.RectF.init(8, 8, 160, 32),
            .text = "Inbox",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(8, 48, 96, 32),
            .text = "Open",
            .value = 1,
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 100), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.list_item, layout.hitTest(geometry.PointF.init(20, 20)).?.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[0].role);
    try std.testing.expectEqualStrings("Inbox", semantics[0].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expectEqual(WidgetRole.tab, semantics[1].role);
    try std.testing.expectEqualStrings("Open", semantics[1].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
}

test "widget data grids expose row and column semantics" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .children = &row_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 320, 180), &nodes);
    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 7), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expect(semantics[0].grid_row_index == null);
    try std.testing.expect(semantics[0].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_column_count);

    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].grid_row_index);
    try std.testing.expect(semantics[1].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), semantics[1].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[1].grid_column_count);

    try std.testing.expectEqual(WidgetRole.gridcell, semantics[2].role);
    try std.testing.expectEqualStrings("Project", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_column_count);

    try std.testing.expectEqual(WidgetRole.gridcell, semantics[5].role);
    try std.testing.expectEqualStrings("Edge API", semantics[5].label);
    try std.testing.expectEqual(@as(?usize, 1), semantics[5].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[5].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), semantics[5].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[5].grid_column_count);
}

test "widget list layout groups list items semantically" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 32),
            .text = "Inbox",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 32),
            .text = "Archive",
        },
    };
    const list = Widget{
        .id = 1,
        .kind = .list,
        .text = "Mailboxes",
        .layout = .{ .padding = geometry.InsetsF.all(8), .gap = 4 },
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 220, 88), &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 220, 88));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(8, 8, 204, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(8, 44, 204, 32));

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    try std.testing.expectEqual(@as(usize, 3), builder.displayList().commandCount());

    const hit = layout.hitTest(geometry.PointF.init(16, 16)).?;
    try std.testing.expectEqual(@as(ObjectId, 2), hit.id);
    try std.testing.expectEqual(WidgetKind.list_item, hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 82)) == null);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try std.testing.expectEqual(@as(ObjectId, 1), route.entries[0].id);
    try std.testing.expectEqual(WidgetEventPhase.capture, route.entries[0].phase);
    try std.testing.expectEqual(@as(ObjectId, 2), route.entries[1].id);
    try std.testing.expectEqual(WidgetEventPhase.target, route.entries[1].phase);
    try std.testing.expectEqual(@as(ObjectId, 1), route.entries[2].id);
    try std.testing.expectEqual(WidgetEventPhase.bubble, route.entries[2].phase);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.list, semantics[0].role);
    try std.testing.expectEqualStrings("Mailboxes", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expect(!semantics[0].list.present);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expect(semantics[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), semantics[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), semantics[1].list.item_count);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[2].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].parent_index);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
    try std.testing.expect(semantics[2].list.present);
    try std.testing.expectEqual(@as(u32, 1), semantics[2].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), semantics[2].list.item_count);
}

test "widget layout reports fixed buffer errors" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &children };

    var small_nodes: [2]WidgetLayoutNode = undefined;
    try std.testing.expectError(error.WidgetLayoutListFull, layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &small_nodes));

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &nodes);
    var small_semantics: [1]WidgetSemanticsNode = undefined;
    try std.testing.expectError(error.WidgetSemanticsListFull, layout.collectSemantics(&small_semantics));
}

test "widget layout diff tracks added removed and layout changes by id" {
    const previous_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 100, 30),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(10, 50, 100, 8),
            .value = 0.4,
        },
    };
    const next_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(20, 10, 100, 30),
            .text = "Run",
            .state = .{ .focused = true },
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 50, 100, 20),
            .text = "Done",
        },
    };

    var previous_nodes: [4]WidgetLayoutNode = undefined;
    var next_nodes: [4]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &previous_children }, geometry.RectF.init(0, 0, 180, 100), &previous_nodes);
    const next = try layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &next_children }, geometry.RectF.init(0, 0, 180, 100), &next_nodes);

    var invalidations_buffer: [4]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);

    try std.testing.expectEqual(WidgetInvalidationKind.changed, invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(9.5, 9, 111.5, 32), invalidations[0].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.removed, invalidations[1].kind);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[1].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 8), invalidations[1].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.added, invalidations[2].kind);
    try std.testing.expectEqual(@as(ObjectId, 4), invalidations[2].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 20), invalidations[2].dirty_bounds);
}

test "widget layout diff includes paint overdraw in dirty bounds" {
    const panel_child = [_]Widget{.{
        .id = 2,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 100, 40),
    }};
    const hidden_panel_child = [_]Widget{.{
        .id = 2,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 100, 40),
        .semantics = .{ .hidden = true },
    }};
    const overflow_panel_children = [_]Widget{.{
        .id = 6,
        .kind = .text,
        .frame = geometry.RectF.init(100, 10, 80, 20),
        .text = "Overflow",
    }};
    const visible_overflow_panel_child = [_]Widget{.{
        .id = 5,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 40, 20),
        .children = &overflow_panel_children,
    }};
    const hidden_overflow_panel_child = [_]Widget{.{
        .id = 5,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 40, 20),
        .semantics = .{ .hidden = true },
        .children = &overflow_panel_children,
    }};
    const unfocused_child = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(10, 70, 100, 30),
        .text = "Focus",
    }};
    const focused_child = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(10, 70, 100, 30),
        .text = "Focus",
        .state = .{ .focused = true },
    }};

    var previous_panel_nodes: [2]WidgetLayoutNode = undefined;
    var next_panel_nodes: [1]WidgetLayoutNode = undefined;
    var hidden_panel_nodes: [2]WidgetLayoutNode = undefined;
    var visible_overflow_panel_nodes: [3]WidgetLayoutNode = undefined;
    var hidden_overflow_panel_nodes: [3]WidgetLayoutNode = undefined;
    const previous_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &panel_child }, geometry.RectF.init(0, 0, 160, 120), &previous_panel_nodes);
    const next_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &.{} }, geometry.RectF.init(0, 0, 160, 120), &next_panel_nodes);
    const hidden_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &hidden_panel_child }, geometry.RectF.init(0, 0, 160, 120), &hidden_panel_nodes);
    const visible_overflow_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &visible_overflow_panel_child }, geometry.RectF.init(0, 0, 220, 120), &visible_overflow_panel_nodes);
    const hidden_overflow_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &hidden_overflow_panel_child }, geometry.RectF.init(0, 0, 220, 120), &hidden_overflow_panel_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const panel_invalidations = try WidgetLayoutTree.diff(previous_panel, next_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.removed, panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), panel_invalidations[0].id);
    try expectRect(geometry.RectF.init(-14, -8, 148, 88), panel_invalidations[0].dirty_bounds);

    const hidden_panel_invalidations = try WidgetLayoutTree.diff(previous_panel, hidden_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), hidden_panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, hidden_panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), hidden_panel_invalidations[0].id);
    try std.testing.expect(!hidden_panel_invalidations[0].layout_dirty);
    try std.testing.expect(hidden_panel_invalidations[0].paint_dirty);
    try std.testing.expect(hidden_panel_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(-14, -8, 148, 88), hidden_panel_invalidations[0].dirty_bounds);

    const hidden_overflow_panel_invalidations = try WidgetLayoutTree.diff(visible_overflow_panel, hidden_overflow_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), hidden_overflow_panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, hidden_overflow_panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 5), hidden_overflow_panel_invalidations[0].id);
    try std.testing.expect(hidden_overflow_panel_invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(-14, -8, 204, 68), hidden_overflow_panel_invalidations[0].dirty_bounds);

    var unfocused_nodes: [2]WidgetLayoutNode = undefined;
    var focused_nodes: [2]WidgetLayoutNode = undefined;
    const unfocused = try layoutWidgetTree(.{ .kind = .stack, .children = &unfocused_child }, geometry.RectF.init(0, 0, 160, 120), &unfocused_nodes);
    const focused = try layoutWidgetTree(.{ .kind = .stack, .children = &focused_child }, geometry.RectF.init(0, 0, 160, 120), &focused_nodes);

    const focus_invalidations = try WidgetLayoutTree.diff(unfocused, focused, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), focus_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, focus_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 3), focus_invalidations[0].id);
    try expectRect(geometry.RectF.init(9, 69, 102, 32), focus_invalidations[0].dirty_bounds);
}

test "widget render state dirty bounds tracks changed runtime states" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 12, 96, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(10, 56, 96, 32),
            .text = "Stop",
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 100, 96, 20),
            .text = "Label",
        },
    };
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 160, 140), &nodes);

    try expectRect(
        geometry.RectF.init(9, 11, 98, 78),
        layout.renderStateDirtyBounds(
            .{ .focused_id = 2, .hovered_id = 2, .pressed_id = 2 },
            .{ .focused_id = 3, .hovered_id = 3 },
        ),
    );
    try std.testing.expect(layout.renderStateDirtyBounds(.{ .focused_id = 2 }, .{ .focused_id = 2 }) == null);
    try std.testing.expect(layout.renderStateDirtyBounds(.{ .focused_id = 99 }, .{ .focused_id = 100 }) == null);
}

test "widget render state dirty bounds clips to scroll ancestors" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
    }};
    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 120, 60),
        &nodes,
    );

    try expectRect(
        geometry.RectF.init(0, 50, 120, 10),
        layout.renderStateDirtyBounds(.{}, .{ .pressed_id = 2 }),
    );
}

test "widget layout diff separates paint and semantics dirtiness" {
    const previous_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
    }};
    const pressed_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .state = .{ .pressed = true },
    }};
    const semantic_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .semantics = .{ .label = "Run report" },
    }};
    const command_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .command = "report.run",
    }};
    const action_previous_child = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Report",
    }};
    const action_child = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Report",
        .semantics = .{ .actions = .{ .focus = true, .press = true } },
    }};
    const image_previous_child = [_]Widget{.{
        .id = 3,
        .kind = .image,
        .frame = geometry.RectF.init(8, 12, 80, 48),
        .image_id = 11,
    }};
    const image_next_child = [_]Widget{.{
        .id = 3,
        .kind = .image,
        .frame = geometry.RectF.init(8, 12, 80, 48),
        .image_id = 12,
        .image_src = geometry.RectF.init(0, 0, 640, 360),
        .image_fit = .contain,
        .image_sampling = .nearest,
        .image_opacity = 0.5,
    }};

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var pressed_nodes: [2]WidgetLayoutNode = undefined;
    var semantic_nodes: [2]WidgetLayoutNode = undefined;
    var command_nodes: [2]WidgetLayoutNode = undefined;
    var action_previous_nodes: [2]WidgetLayoutNode = undefined;
    var action_nodes: [2]WidgetLayoutNode = undefined;
    var image_previous_nodes: [2]WidgetLayoutNode = undefined;
    var image_next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const pressed = try layoutWidgetTree(.{ .kind = .stack, .children = &pressed_child }, geometry.RectF.init(0, 0, 140, 80), &pressed_nodes);
    const semantic = try layoutWidgetTree(.{ .kind = .stack, .children = &semantic_child }, geometry.RectF.init(0, 0, 140, 80), &semantic_nodes);
    const command = try layoutWidgetTree(.{ .kind = .stack, .children = &command_child }, geometry.RectF.init(0, 0, 140, 80), &command_nodes);
    const action_previous = try layoutWidgetTree(.{ .kind = .stack, .children = &action_previous_child }, geometry.RectF.init(0, 0, 140, 80), &action_previous_nodes);
    const action = try layoutWidgetTree(.{ .kind = .stack, .children = &action_child }, geometry.RectF.init(0, 0, 140, 80), &action_nodes);
    const image_previous = try layoutWidgetTree(.{ .kind = .stack, .children = &image_previous_child }, geometry.RectF.init(0, 0, 140, 80), &image_previous_nodes);
    const image_next = try layoutWidgetTree(.{ .kind = .stack, .children = &image_next_child }, geometry.RectF.init(0, 0, 140, 80), &image_next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const pressed_invalidations = try WidgetLayoutTree.diff(previous, pressed, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), pressed_invalidations.len);
    try std.testing.expect(!pressed_invalidations[0].layout_dirty);
    try std.testing.expect(pressed_invalidations[0].paint_dirty);
    try std.testing.expect(pressed_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 10, 100, 30), pressed_invalidations[0].dirty_bounds);

    const semantic_invalidations = try WidgetLayoutTree.diff(previous, semantic, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantic_invalidations.len);
    try std.testing.expect(!semantic_invalidations[0].layout_dirty);
    try std.testing.expect(!semantic_invalidations[0].paint_dirty);
    try std.testing.expect(semantic_invalidations[0].semantics_dirty);
    try std.testing.expect(semantic_invalidations[0].dirty_bounds == null);

    const command_invalidations = try WidgetLayoutTree.diff(previous, command, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), command_invalidations.len);
    try std.testing.expect(!command_invalidations[0].layout_dirty);
    try std.testing.expect(!command_invalidations[0].paint_dirty);
    try std.testing.expect(command_invalidations[0].semantics_dirty);
    try std.testing.expect(command_invalidations[0].dirty_bounds == null);

    const action_invalidations = try WidgetLayoutTree.diff(action_previous, action, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), action_invalidations.len);
    try std.testing.expect(!action_invalidations[0].layout_dirty);
    try std.testing.expect(!action_invalidations[0].paint_dirty);
    try std.testing.expect(action_invalidations[0].semantics_dirty);

    const image_invalidations = try WidgetLayoutTree.diff(image_previous, image_next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), image_invalidations.len);
    try std.testing.expect(!image_invalidations[0].layout_dirty);
    try std.testing.expect(image_invalidations[0].paint_dirty);
    try std.testing.expect(image_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(8, 12, 80, 48), image_invalidations[0].dirty_bounds);
}

test "widget layout diff marks grid column changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const previous_grid = Widget{ .id = 1, .kind = .grid, .layout = .{ .columns = 2, .gap = 8 }, .children = &children };
    const next_grid = Widget{ .id = 1, .kind = .grid, .layout = .{ .columns = 1, .gap = 8 }, .children = &children };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_grid, geometry.RectF.init(0, 0, 208, 88), &previous_nodes);
    const next = try layoutWidgetTree(next_grid, geometry.RectF.init(0, 0, 208, 88), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(invalidations[0].semantics_dirty);
}

test "widget layout diff marks list spacing changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Two" },
    };
    const previous_list = Widget{ .id = 1, .kind = .list, .layout = .{ .gap = 4 }, .children = &children };
    const next_list = Widget{ .id = 1, .kind = .list, .layout = .{ .gap = 8 }, .children = &children };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_list, geometry.RectF.init(0, 0, 120, 80), &previous_nodes);
    const next = try layoutWidgetTree(next_list, geometry.RectF.init(0, 0, 120, 80), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 2), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expect(invalidations[1].paint_dirty);
}

test "widget layout diff marks axis alignment changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .frame = geometry.RectF.init(0, 0, 40, 12), .text = "A" },
        .{ .id = 3, .kind = .text, .frame = geometry.RectF.init(0, 0, 20, 16), .text = "B" },
    };
    const previous_row = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{ .gap = 4 },
        .children = &children,
    };
    const next_row = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{
            .gap = 4,
            .main_alignment = .end,
            .cross_alignment = .center,
        },
        .children = &children,
    };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_row, geometry.RectF.init(0, 0, 120, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_row, geometry.RectF.init(0, 0, 120, 40), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[2].id);
    try std.testing.expect(invalidations[2].layout_dirty);
}

test "widget layout diff marks text alignment changes as paint dirty" {
    const previous_text = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 12, 120, 24),
        .text = "Status",
    };
    const next_text = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 12, 120, 24),
        .text = "Status",
        .text_alignment = .end,
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_text, previous_text.frame, &previous_nodes);
    const next = try layoutWidgetTree(next_text, next_text.frame, &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 12, 120, 24), invalidations[0].dirty_bounds);
}

test "widget layout diff marks opacity changes as subtree paint dirty" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(20, 0, 30, 10),
        .text = "Fade",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .children = &children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .opacity = 0.5,
        .children = &children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 10, 10), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 10, 10), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(0, 0, 50, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff marks transform changes as subtree paint dirty" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(20, 0, 30, 10),
        .text = "Move",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .children = &children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .transform = Affine.translate(10, 0),
        .children = &children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 10, 10), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 10, 10), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(0, 0, 60, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff marks backdrop blur changes as paint dirty" {
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .backdrop_blur = 6,
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(10, 12, 80, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(10, 12, 80, 40), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(4, 6, 92, 52), invalidations[0].dirty_bounds);
}

test "widget layout diff clips paint dirtiness to clip content ancestors" {
    const previous_children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "One",
    }};
    const next_children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "Two",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .layout = .{ .clip_content = true },
        .children = &previous_children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .layout = .{ .clip_content = true },
        .children = &next_children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 50, 20), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 50, 20), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(40, 0, 10, 20), invalidations[0].dirty_bounds);
}

test "widget layout diff marks scroll offset changes as child layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
    };
    const previous_scroll = Widget{ .id = 1, .kind = .scroll_view, .value = 0, .children = &children };
    const next_scroll = Widget{ .id = 1, .kind = .scroll_view, .value = 12, .children = &children };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_scroll, geometry.RectF.init(0, 0, 120, 60), &previous_nodes);
    const next = try layoutWidgetTree(next_scroll, geometry.RectF.init(0, 0, 120, 60), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 2), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expect(invalidations[1].paint_dirty);
}

test "widget layout diff clips paint dirtiness to scroll ancestors" {
    const previous_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
    }};
    const pressed_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
        .state = .{ .pressed = true },
    }};
    const previous_scroll = Widget{ .id = 1, .kind = .scroll_view, .children = &previous_children };
    const pressed_scroll = Widget{ .id = 1, .kind = .scroll_view, .children = &pressed_children };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var pressed_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_scroll, geometry.RectF.init(0, 0, 120, 60), &previous_nodes);
    const pressed = try layoutWidgetTree(pressed_scroll, geometry.RectF.init(0, 0, 120, 60), &pressed_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, pressed, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(0, 50, 120, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff reports duplicate ids and output overflow" {
    const duplicate_children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 2, .kind = .text, .text = "Two" },
    };
    const changed_children = [_]Widget{.{
        .id = 3,
        .kind = .text,
        .text = "Changed",
    }};

    var duplicate_nodes: [3]WidgetLayoutNode = undefined;
    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const duplicate = try layoutWidgetTree(.{ .kind = .stack, .children = &duplicate_children }, geometry.RectF.init(0, 0, 100, 100), &duplicate_nodes);
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &.{.{ .id = 3, .kind = .text, .text = "Old" }} }, geometry.RectF.init(0, 0, 100, 100), &previous_nodes);
    const next = try layoutWidgetTree(.{ .kind = .stack, .children = &changed_children }, geometry.RectF.init(0, 0, 100, 100), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    try std.testing.expectError(error.DuplicateWidgetId, WidgetLayoutTree.diff(duplicate, next, &invalidations_buffer));

    var empty_invalidations: [0]WidgetInvalidation = .{};
    try std.testing.expectError(error.WidgetInvalidationListFull, WidgetLayoutTree.diff(previous, next, &empty_invalidations));
}

test "widget tree emits panel button text and progress commands" {
    const tokens: DesignTokens = .{};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Launch",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(16, 64, 200, 20),
            .text = "Frames stay retained",
        },
        .{
            .id = 4,
            .kind = .progress,
            .frame = geometry.RectF.init(16, 96, 160, 8),
            .value = 0.25,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 240, 128),
        .children = &children,
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 1)), display_list.commands[0].objectId());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expect(display_list.commands[3] == .fill_rounded_rect);

    switch (display_list.commands[5]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 4)), text.id);
            try std.testing.expectEqualStrings("Launch", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 1)), text.id);
            try std.testing.expectEqualStrings("Frames stay retained", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(4, 2)), fill.id);
            try expectRect(geometry.RectF.init(16, 96, 40, 8), fill.rect);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget tree emits backdrop blur before widget content" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(18, 24, 100, 18),
        .text = "Glass",
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(10, 12, 140, 72),
        .backdrop_blur = 8,
        .children = &children,
    };

    var commands: [2]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, .{});

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), display_list.commandCount());
    switch (display_list.commands[0]) {
        .blur => |blur| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 12)), blur.id);
            try expectRect(geometry.RectF.init(10, 12, 140, 72), blur.rect);
            try std.testing.expectEqual(@as(f32, 8), blur.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 1)), text.id);
            try std.testing.expectEqualStrings("Glass", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget display list skips hidden subtrees" {
    const hidden_button = Widget{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 32),
        .text = "Hidden",
        .semantics = .{ .hidden = true },
    };
    var hidden_commands: [4]CanvasCommand = undefined;
    var hidden_builder = Builder.init(&hidden_commands);
    try emitWidgetTree(&hidden_builder, hidden_button, .{});
    try std.testing.expectEqual(@as(usize, 0), hidden_builder.displayList().commandCount());

    const hidden_scroll_children = [_]Widget{.{
        .id = 4,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 0, 32),
        .text = "Nested",
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Visible",
        },
        .{
            .id = 3,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(16, 64, 160, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_scroll_children,
        },
        .{
            .id = 5,
            .kind = .text,
            .frame = geometry.RectF.init(16, 124, 120, 20),
            .text = "Visible text",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 220, 160),
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &nodes);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    const display_list = builder.displayList();
    var saw_visible_button = false;
    var saw_visible_text = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == widgetPartId(2, 1)) saw_visible_button = true;
            if (id == widgetPartId(5, 1)) saw_visible_text = true;
            if ((id > widgetPartId(3, 0) and id < widgetPartId(4, 0)) or
                (id > widgetPartId(4, 0) and id < widgetPartId(5, 0)))
            {
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expect(saw_visible_button);
    try std.testing.expect(saw_visible_text);
}

test "widget display list renders through reference surface" {
    const tokens: DesignTokens = .{};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Launch",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(16, 64, 200, 20),
            .text = "Frames stay retained",
        },
        .{
            .id = 4,
            .kind = .progress,
            .frame = geometry.RectF.init(16, 96, 160, 8),
            .value = 0.25,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 240, 128),
        .children = &children,
    };

    var layout_nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &layout_nodes);

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);

    var render_commands: [12]RenderCommand = undefined;
    var render_batches: [12]RenderBatch = undefined;
    var resources: [8]RenderResource = undefined;
    var resource_cache_entries: [8]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [8]RenderResourceCacheAction = undefined;
    var glyphs: [64]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [64]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [64]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try builder.displayList().framePlan(null, .{
        .surface_size = geometry.SizeF.init(240, 128),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, frame.renderPass().loadAction());
    try std.testing.expectEqual(@as(usize, 9), frame.renderPass().commandCount());

    var pixels: [240 * 128 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(240, 128, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 220, 20);
    try expectPixelRgba8(.{ 24, 24, 27, 255 }, surface, 20, 100);
}

test "widget emitter applies button state tokens" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    const button = Widget{
        .id = 7,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 140, 40),
        .text = "Pressed",
        .state = .{ .pressed = true, .focused = true },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(7, 3)), stroke.id);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies density tokens to spacing and affordances" {
    const button = Widget{
        .id = 1,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 140, 40),
        .text = "Density",
    };

    var compact_button_commands: [4]CanvasCommand = undefined;
    var compact_button_builder = Builder.init(&compact_button_commands);
    try emitWidgetTree(&compact_button_builder, button, .{ .density = .compact });
    switch (compact_button_builder.displayList().commands[2]) {
        .draw_text => |text| try std.testing.expectApproxEqAbs(@as(f32, 10.5), text.origin.x, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var regular_button_commands: [4]CanvasCommand = undefined;
    var regular_button_builder = Builder.init(&regular_button_commands);
    try emitWidgetTree(&regular_button_builder, button, .{ .density = .regular });
    switch (regular_button_builder.displayList().commands[2]) {
        .draw_text => |text| try std.testing.expectApproxEqAbs(@as(f32, 12), text.origin.x, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var spacious_button_commands: [4]CanvasCommand = undefined;
    var spacious_button_builder = Builder.init(&spacious_button_commands);
    try emitWidgetTree(&spacious_button_builder, button, .{ .density = .spacious });
    switch (spacious_button_builder.displayList().commands[2]) {
        .draw_text => |text| try std.testing.expectApproxEqAbs(@as(f32, 13.5), text.origin.x, 0.001),
        else => return error.TestUnexpectedResult,
    }

    const checkbox = Widget{
        .id = 2,
        .kind = .checkbox,
        .frame = geometry.RectF.init(0, 0, 80, 20),
    };

    var compact_checkbox_commands: [2]CanvasCommand = undefined;
    var compact_checkbox_builder = Builder.init(&compact_checkbox_commands);
    try emitWidgetTree(&compact_checkbox_builder, checkbox, .{ .density = .compact });
    switch (compact_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 12.25), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var regular_checkbox_commands: [2]CanvasCommand = undefined;
    var regular_checkbox_builder = Builder.init(&regular_checkbox_commands);
    try emitWidgetTree(&regular_checkbox_builder, checkbox, .{ .density = .regular });
    switch (regular_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 14), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var spacious_checkbox_commands: [2]CanvasCommand = undefined;
    var spacious_checkbox_builder = Builder.init(&spacious_checkbox_commands);
    try emitWidgetTree(&spacious_checkbox_builder, checkbox, .{ .density = .spacious });
    switch (spacious_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 15.75), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "widget layout emission can render runtime focus state" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 100, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 40, 100, 32),
            .text = "Stop",
            .state = .{ .hovered = true, .pressed = true, .focused = true },
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 140, 100), &nodes);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayListWithState(&builder, tokens, .{ .focused_id = 2, .hovered_id = 2, .pressed_id = 2 });

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    var saw_runtime_focus = false;
    var saw_stale_focus = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == widgetPartId(2, 3)) saw_runtime_focus = true;
            if (id == widgetPartId(3, 3)) saw_stale_focus = true;
        }
    }
    try std.testing.expect(saw_runtime_focus);
    try std.testing.expect(!saw_stale_focus);
}

test "widget layer tokens order display emission and hit testing" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(8, 8, 96, 64),
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 80, 32),
            .text = "Base",
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 120, 90), &nodes);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(20, 20)).?.id);

    const lowered_overlay = DesignTokens{
        .layer = .{
            .base = 10,
            .floating = 20,
            .overlay = 0,
            .modal = 30,
        },
    };
    var lowered_commands: [8]CanvasCommand = undefined;
    var lowered_builder = Builder.init(&lowered_commands);
    try layout.emitDisplayList(&lowered_builder, lowered_overlay);
    const lowered_display_list = lowered_builder.displayList();
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), lowered_display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), lowered_display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTestWithTokens(geometry.PointF.init(20, 20), lowered_overlay).?.id);
}

test "widget explicit layers override token defaults for overlay ordering" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(8, 8, 96, 64),
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 80, 32),
            .text = "Top",
            .layer = 500,
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 120, 90), &nodes);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTest(geometry.PointF.init(20, 20)).?.id);
}

test "widget emitter renders checkbox toggle and slider controls" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 10,
        .kind = .checkbox,
        .frame = geometry.RectF.init(0, 0, 120, 32),
        .text = "Live",
        .state = .{ .selected = true, .focused = true },
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 11,
        .kind = .toggle,
        .frame = geometry.RectF.init(0, 40, 120, 32),
        .text = "Mode",
        .value = 1,
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 12,
        .kind = .slider,
        .frame = geometry.RectF.init(0, 84, 160, 32),
        .value = 0.25,
        .state = .{ .focused = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 14), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[3] == .draw_line);
    try std.testing.expect(display_list.commands[4] == .draw_line);
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Live", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Mode", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(0, 98, 40, 4), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(12, 4)), stroke.id);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter renders list item and segmented control states" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
            .surface_pressed = Color.rgb8(220, 224, 230),
        },
        .stroke = .{ .focus = 3 },
    };
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 20,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 0, 160, 32),
        .text = "Inbox",
        .state = .{ .selected = true, .focused = true },
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 21,
        .kind = .segmented_control,
        .frame = geometry.RectF.init(0, 40, 96, 32),
        .text = "Open",
        .state = .{ .selected = true, .focused = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface_pressed, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Inbox", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter reports depth and display list overflow" {
    var tiny_commands: [2]CanvasCommand = undefined;
    var tiny_builder = Builder.init(&tiny_commands);
    try std.testing.expectError(error.DisplayListFull, emitWidgetTree(&tiny_builder, .{
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 120, 36),
        .text = "Overflow",
    }, .{}));

    var widgets: [max_widget_depth + 1]Widget = undefined;
    var index = widgets.len;
    while (index > 0) {
        index -= 1;
        widgets[index] = .{
            .kind = .stack,
            .children = if (index + 1 < widgets.len) widgets[index + 1 .. index + 2] else &.{},
        };
    }

    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try std.testing.expectError(error.WidgetDepthExceeded, emitWidgetTree(&builder, widgets[0], .{}));
}

test "builder records replayable commands" {
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushClip(.{ .id = 1, .rect = geometry.RectF.init(0, 0, 320, 240), .radius = Radius.all(8) });
    try builder.pushOpacity(0.75);
    try builder.fillRoundedRect(.{
        .id = 2,
        .rect = geometry.RectF.init(12, 16, 180, 96),
        .radius = Radius.all(12),
        .fill = .{ .color = Color.rgb8(17, 24, 39) },
    });
    try builder.popOpacity();
    try builder.popClip();

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .push_clip);
    try std.testing.expect(display_list.commands[2] == .fill_rounded_rect);
}

test "builder reports fixed buffer overflow" {
    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushOpacity(1);
    try std.testing.expectError(error.DisplayListFull, builder.popOpacity());
}

test "display list finds commands and computes conservative bounds" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(5, 5), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(15, 30), geometry.PointF.init(20, 0), geometry.PointF.init(35, 35) } },
        .{ .verb = .close },
    };

    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.strokeRect(.{
        .id = 1,
        .rect = geometry.RectF.init(10, 10, 100, 40),
        .stroke = .{ .fill = .{ .color = Color.rgb8(0, 0, 0) }, .width = 4 },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    });
    try builder.shadow(.{
        .id = 3,
        .rect = geometry.RectF.init(20, 20, 40, 20),
        .offset = .{ .dx = 0, .dy = 8 },
        .blur = 12,
        .spread = -4,
        .color = Color.rgba8(0, 0, 0, 64),
    });

    const display_list = builder.displayList();
    const path_ref = display_list.findCommandById(2).?;
    try std.testing.expectEqual(@as(usize, 1), path_ref.index);
    try std.testing.expectEqual(@as(?ObjectId, 2), path_ref.command.objectId());
    try std.testing.expect(display_list.findCommandById(99) == null);

    try expectRect(geometry.RectF.init(8, 8, 104, 44), display_list.commands[0].bounds());
    try expectRect(geometry.RectF.init(5, 0, 30, 35), display_list.commands[1].bounds());
    try expectRect(geometry.RectF.init(4, 12, 72, 52), display_list.commands[2].bounds());
    try expectRect(geometry.RectF.init(4, 0, 108, 64), display_list.bounds());
}

test "display list diffs changed added removed and unkeyed scene commands" {
    const previous_commands = [_]CanvasCommand{
        .{ .push_opacity = 1 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .draw_image = .{ .id = 3, .image_id = 8, .dst = geometry.RectF.init(180, 0, 32, 32) } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(10, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .blur = .{ .id = 4, .rect = geometry.RectF.init(220, 0, 24, 24), .radius = 6 } },
    };

    var changes: [8]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &previous_commands }, .{ .commands = &next_commands }, &changes);
    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(DiffKind.scene_changed, diff[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, null), diff[0].id);
    try std.testing.expect(diff[0].dirty_bounds != null);
    try std.testing.expectEqual(DiffKind.changed, diff[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), diff[1].id);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].previous_index);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].next_index);
    try expectRect(geometry.RectF.init(0, 0, 110, 100), diff[1].dirty_bounds);
    try std.testing.expectEqual(DiffKind.removed, diff[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), diff[2].id);
    try expectRect(geometry.RectF.init(180, 0, 32, 32), diff[2].dirty_bounds);
    try std.testing.expectEqual(DiffKind.added, diff[3].kind);
    try std.testing.expectEqual(@as(?ObjectId, 4), diff[3].id);
    try expectRect(geometry.RectF.init(214, -6, 36, 36), diff[3].dirty_bounds);
}

test "display list diff ignores unchanged keyed commands" {
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(8, 8, 120, 40),
            .radius = Radius.all(10),
            .fill = .{ .color = Color.rgb8(15, 23, 42) },
        } },
    };

    var changes: [1]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &commands }, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "display list diff rejects duplicate object ids" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .blur = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .radius = 4 } },
    };

    var changes: [2]DiffChange = undefined;
    try std.testing.expectError(error.DuplicateObjectId, DisplayList.diff(.{ .commands = &commands }, .{}, &changes));
}

test "affine transforms points and conservative rect bounds" {
    const transform = Affine.translate(10, 5).multiply(Affine.scale(2, 3));
    try std.testing.expectEqualDeep(geometry.PointF.init(14, 14), transform.transformPoint(geometry.PointF.init(2, 3)));
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 5, 20, 15), transform.transformRect(geometry.RectF.init(0, 0, 10, 5)));
    const inverse = transform.inverse().?;
    const restored = inverse.transformPoint(geometry.PointF.init(14, 14));
    try std.testing.expectApproxEqAbs(@as(f32, 2), restored.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), restored.y, 0.00001);
    try std.testing.expect(Affine.scale(0, 1).inverse() == null);
}

test "render plan resolves transform clip and opacity state" {
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(10, 10, 50, 50) } },
        .{ .push_opacity = 0.5 },
        .{ .transform = Affine.translate(10, 0) },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 30, 30), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
        .pop_clip,
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 2), plan.commandCount());

    try std.testing.expectEqual(@as(?ObjectId, 1), plan.commands[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), plan.commands[0].opacity);
    try expectRect(geometry.RectF.init(10, 10, 50, 50), plan.commands[0].clip);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), plan.commands[0].transform);
    try expectRect(geometry.RectF.init(0, 0, 30, 30), plan.commands[0].local_bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 10, 30, 20), plan.commands[0].bounds);

    try std.testing.expectEqual(@as(?ObjectId, 3), plan.commands[1].id);
    try std.testing.expectEqual(@as(f32, 1), plan.commands[1].opacity);
    try std.testing.expect(plan.commands[1].clip == null);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), plan.commands[1].transform);
    try expectRect(geometry.RectF.init(0, 0, 4, 4), plan.commands[1].local_bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 4, 4), plan.commands[1].bounds);
    try expectRect(geometry.RectF.init(10, 0, 30, 30), plan.bounds);
}

test "render plan reports output and stack errors" {
    const draw_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };
    var empty_render_commands: [0]RenderCommand = .{};
    try std.testing.expectError(error.RenderListFull, (DisplayList{ .commands = &draw_commands }).renderPlan(&empty_render_commands));

    const bad_clip_commands = [_]CanvasCommand{.pop_clip};
    var render_commands: [1]RenderCommand = undefined;
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_clip_commands }).renderPlan(&render_commands));

    const bad_opacity_commands = [_]CanvasCommand{.pop_opacity};
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_opacity_commands }).renderPlan(&render_commands));
}

test "render batch plan groups adjacent commands by pipeline and state" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rounded_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .radius = Radius.all(4), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(48, 0),
            .end = geometry.PointF.init(68, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 4,
            .font_id = 1,
            .size = 12,
            .origin = geometry.PointF.init(72, 18),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var batches: [4]RenderBatch = undefined;
    const batch_plan = try render_plan.batchPlan(&batches);

    try std.testing.expectEqual(@as(usize, 3), batch_plan.batchCount());
    try std.testing.expectEqual(RenderPipelineKind.solid, batch_plan.batches[0].pipeline);
    try std.testing.expectEqual(@as(usize, 0), batch_plan.batches[0].command_start);
    try std.testing.expectEqual(@as(usize, 2), batch_plan.batches[0].command_count);
    try expectRect(geometry.RectF.init(0, 0, 44, 20), batch_plan.batches[0].bounds);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, batch_plan.batches[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), batch_plan.batches[1].command_start);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, batch_plan.batches[2].pipeline);
    try std.testing.expectEqual(@as(usize, 3), batch_plan.batches[2].command_start);
    try expectRect(geometry.RectF.init(0, 0, 84, 21), batch_plan.bounds);
}

test "render batch plan respects clip opacity and output limits" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .{ .push_clip = .{ .rect = geometry.RectF.init(48, 0, 20, 20) } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .color = Color.rgb8(15, 23, 42) } } },
        .pop_clip,
    };

    var render_commands: [3]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var batches: [3]RenderBatch = undefined;
    const batch_plan = try render_plan.batchPlan(&batches);

    try std.testing.expectEqual(@as(usize, 3), batch_plan.batchCount());
    try std.testing.expectEqual(@as(f32, 0.5), batch_plan.batches[0].opacity);
    try std.testing.expect(batch_plan.batches[0].clip == null);
    try std.testing.expectEqual(@as(f32, 1), batch_plan.batches[1].opacity);
    try std.testing.expect(batch_plan.batches[1].clip == null);
    try expectRect(geometry.RectF.init(48, 0, 20, 20), batch_plan.batches[2].clip);

    var empty_batches: [0]RenderBatch = .{};
    try std.testing.expectError(error.RenderBatchListFull, render_plan.batchPlan(&empty_batches));
}

test "render path geometry plan estimates fill and stroke tessellation" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .quad_to, .points = .{ geometry.PointF.init(24, 16), geometry.PointF.init(12, 22), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(8, 26), geometry.PointF.init(-4, 18), geometry.PointF.init(0, 0) } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path,
            .fill = .{ .color = Color.rgb8(255, 255, 255) },
        } },
        .{ .transform = Affine.scale(2, 2) },
        .{ .stroke_path = .{
            .id = 2,
            .elements = &path,
            .stroke = .{ .fill = .{ .color = Color.rgb8(24, 24, 27) }, .width = 2 },
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var geometries: [2]RenderPathGeometry = undefined;
    const geometry_plan = try render_plan.pathGeometryPlan(&geometries);

    try std.testing.expectEqual(@as(usize, 2), geometry_plan.geometryCount());
    try std.testing.expectEqual(@as(usize, 130), geometry_plan.vertexCount());
    try std.testing.expectEqual(@as(usize, 228), geometry_plan.indexCount());

    try std.testing.expectEqual(RenderPathGeometryKind.fill, geometry_plan.geometries[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), geometry_plan.geometries[0].id);
    try std.testing.expectEqual(@as(usize, 0), geometry_plan.geometries[0].command_index);
    try std.testing.expectEqual(@as(usize, 5), geometry_plan.geometries[0].element_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].contour_count);
    try std.testing.expectEqual(@as(usize, 2), geometry_plan.geometries[0].line_segment_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].quadratic_segment_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].cubic_segment_count);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[0].flattened_segment_count);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[0].vertex_count);
    try std.testing.expectEqual(@as(usize, 72), geometry_plan.geometries[0].index_count);
    try std.testing.expectEqual(@as(f32, 0), geometry_plan.geometries[0].stroke_width);

    try std.testing.expectEqual(RenderPathGeometryKind.stroke, geometry_plan.geometries[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), geometry_plan.geometries[1].id);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[1].command_index);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[1].flattened_segment_count);
    try std.testing.expectEqual(@as(usize, 104), geometry_plan.geometries[1].vertex_count);
    try std.testing.expectEqual(@as(usize, 156), geometry_plan.geometries[1].index_count);
    try std.testing.expectEqual(@as(f32, 4), geometry_plan.geometries[1].stroke_width);
    try expectRect(geometry.RectF.init(-4, 0, 28, 26), geometry_plan.geometries[0].bounds);
    try expectRect(geometry.RectF.init(-10, -2, 60, 56), geometry_plan.geometries[1].bounds);
}

test "render path geometry fingerprint tracks geometry not paint" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const changed_path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};
    const recolored_commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    const reshaped_commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &changed_path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var geometries: [1]RenderPathGeometry = undefined;
    const geometry_plan = try render_plan.pathGeometryPlan(&geometries);

    var recolored_render_commands: [1]RenderCommand = undefined;
    const recolored_render_plan = try (DisplayList{ .commands = &recolored_commands }).renderPlan(&recolored_render_commands);
    var recolored_geometries: [1]RenderPathGeometry = undefined;
    const recolored_geometry_plan = try recolored_render_plan.pathGeometryPlan(&recolored_geometries);

    var reshaped_render_commands: [1]RenderCommand = undefined;
    const reshaped_render_plan = try (DisplayList{ .commands = &reshaped_commands }).renderPlan(&reshaped_render_commands);
    var reshaped_geometries: [1]RenderPathGeometry = undefined;
    const reshaped_geometry_plan = try reshaped_render_plan.pathGeometryPlan(&reshaped_geometries);

    try std.testing.expectEqual(geometry_plan.geometries[0].fingerprint, recolored_geometry_plan.geometries[0].fingerprint);
    try std.testing.expect(geometry_plan.geometries[0].fingerprint != reshaped_geometry_plan.geometries[0].fingerprint);
}

test "render path geometry cache plan uploads retains and evicts geometries" {
    const previous_geometries = [_]RenderPathGeometry{
        .{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 },
        .{ .kind = .stroke, .command_index = 1, .id = 2, .bounds = geometry.RectF.init(24, 0, 20, 20), .vertex_count = 4, .index_count = 6, .stroke_width = 2, .fingerprint = 22 },
    };
    var previous_entries: [2]RenderPathGeometryCacheEntry = undefined;
    var previous_actions: [2]RenderPathGeometryCacheAction = undefined;
    const previous_cache = try (RenderPathGeometryPlan{ .geometries = &previous_geometries }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());

    const next_geometries = [_]RenderPathGeometry{
        .{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 },
        .{ .kind = .stroke, .command_index = 1, .id = 3, .bounds = geometry.RectF.init(48, 0, 20, 20), .vertex_count = 8, .index_count = 12, .stroke_width = 4, .fingerprint = 33 },
    };
    var next_entries: [2]RenderPathGeometryCacheEntry = undefined;
    var next_actions: [3]RenderPathGeometryCacheAction = undefined;
    const next_cache = try (RenderPathGeometryPlan{ .geometries = &next_geometries }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);
    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), next_cache.actions[0].key.id);
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), next_cache.actions[1].key.id);
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), next_cache.actions[2].key.id);
}

test "render path geometry plans report output overflow" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_geometries: [0]RenderPathGeometry = .{};
    try std.testing.expectError(error.PathGeometryListFull, render_plan.pathGeometryPlan(&no_geometries));

    const geometries = [_]RenderPathGeometry{.{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 }};
    var no_entries: [0]RenderPathGeometryCacheEntry = .{};
    var actions: [1]RenderPathGeometryCacheAction = undefined;
    try std.testing.expectError(error.PathGeometryCacheListFull, (RenderPathGeometryPlan{ .geometries = &geometries }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderPathGeometryCacheEntry = undefined;
    var no_actions: [0]RenderPathGeometryCacheAction = .{};
    try std.testing.expectError(error.PathGeometryCacheListFull, (RenderPathGeometryPlan{ .geometries = &geometries }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render layer plan groups composited commands by state" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .pop_opacity,
        .{ .push_clip = .{ .rect = geometry.RectF.init(48, 0, 20, 20) } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .color = Color.rgb8(15, 23, 42) } } },
        .pop_clip,
        .{ .transform = Affine.translate(10, 0) },
        .{ .fill_rect = .{ .id = 4, .rect = geometry.RectF.init(72, 0, 20, 20), .fill = .{ .color = Color.rgb8(37, 99, 235) } } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var layers: [3]RenderLayer = undefined;
    const layer_plan = try render_plan.layerPlan(&layers);

    try std.testing.expectEqual(@as(usize, 3), layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.opacityLayerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.clipLayerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.transformLayerCount());
    try std.testing.expectEqual(@as(usize, 0), layer_plan.layers[0].command_start);
    try std.testing.expectEqual(@as(usize, 2), layer_plan.layers[0].command_count);
    try std.testing.expect(layer_plan.layers[0].id == null);
    try std.testing.expectEqual(@as(f32, 0.5), layer_plan.layers[0].opacity);
    try expectRect(geometry.RectF.init(0, 0, 44, 20), layer_plan.layers[0].bounds);
    try std.testing.expectEqual(@as(?ObjectId, 3), layer_plan.layers[1].id);
    try expectRect(geometry.RectF.init(48, 0, 20, 20), layer_plan.layers[1].clip);
    try std.testing.expectEqual(@as(?ObjectId, 4), layer_plan.layers[2].id);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), layer_plan.layers[2].transform);
    try expectRect(geometry.RectF.init(82, 0, 20, 20), layer_plan.layers[2].bounds);

    const changed_commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 0, 0) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .pop_opacity,
    };
    var changed_render_commands: [2]RenderCommand = undefined;
    const changed_render_plan = try (DisplayList{ .commands = &changed_commands }).renderPlan(&changed_render_commands);
    var changed_layers: [1]RenderLayer = undefined;
    const changed_layer_plan = try changed_render_plan.layerPlan(&changed_layers);
    try std.testing.expect(layer_plan.layers[0].fingerprint != changed_layer_plan.layers[0].fingerprint);
}

test "render layer cache plan uploads retains and evicts layers" {
    const previous_layers = [_]RenderLayer{
        .{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 },
        .{ .command_start = 1, .command_count = 1, .id = 2, .bounds = geometry.RectF.init(24, 0, 20, 20), .clip = geometry.RectF.init(24, 0, 20, 20), .fingerprint = 22 },
    };
    var previous_entries: [2]RenderLayerCacheEntry = undefined;
    var previous_actions: [2]RenderLayerCacheAction = undefined;
    const previous_cache = try (RenderLayerPlan{ .layers = &previous_layers }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());

    const next_layers = [_]RenderLayer{
        .{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 },
        .{ .command_start = 1, .command_count = 1, .id = 3, .bounds = geometry.RectF.init(48, 0, 20, 20), .transform = Affine.translate(10, 0), .fingerprint = 33 },
    };
    var next_entries: [2]RenderLayerCacheEntry = undefined;
    var next_actions: [3]RenderLayerCacheAction = undefined;
    const next_cache = try (RenderLayerPlan{ .layers = &next_layers }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);
    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderLayerCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), next_cache.actions[0].key.id);
    try std.testing.expectEqual(RenderLayerCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), next_cache.actions[1].key.id);
    try std.testing.expectEqual(RenderLayerCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), next_cache.actions[2].key.id);
}

test "render layer plans report output overflow" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
    };
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_layers: [0]RenderLayer = .{};
    try std.testing.expectError(error.LayerListFull, render_plan.layerPlan(&no_layers));

    const layers = [_]RenderLayer{.{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 }};
    var no_entries: [0]RenderLayerCacheEntry = .{};
    var actions: [1]RenderLayerCacheAction = undefined;
    try std.testing.expectError(error.LayerCacheListFull, (RenderLayerPlan{ .layers = &layers }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderLayerCacheEntry = undefined;
    var no_actions: [0]RenderLayerCacheAction = .{};
    try std.testing.expectError(error.LayerCacheListFull, (RenderLayerPlan{ .layers = &layers }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render pipeline cache plan uploads retains and evicts pipelines" {
    const first_batches = [_]RenderBatch{
        .{ .pipeline = .solid, .command_start = 0, .command_count = 1 },
        .{ .pipeline = .linear_gradient, .command_start = 1, .command_count = 1 },
        .{ .pipeline = .solid, .command_start = 2, .command_count = 1 },
    };
    var first_entries: [2]RenderPipelineCacheEntry = undefined;
    var first_actions: [2]RenderPipelineCacheAction = undefined;
    const first_cache = try (RenderBatchPlan{ .batches = &first_batches }).cachePlan(&.{}, 1, &first_entries, &first_actions);

    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.uploadCount());
    try std.testing.expectEqual(RenderPipelineKind.solid, first_cache.entries[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, first_cache.entries[1].pipeline);
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    const second_batches = [_]RenderBatch{
        .{ .pipeline = .linear_gradient, .command_start = 0, .command_count = 1 },
        .{ .pipeline = .glyph_run, .command_start = 1, .command_count = 1 },
    };
    var second_entries: [2]RenderPipelineCacheEntry = undefined;
    var second_actions: [3]RenderPipelineCacheAction = undefined;
    const second_cache = try (RenderBatchPlan{ .batches = &second_batches }).cachePlan(first_cache.entries, 2, &second_entries, &second_actions);

    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), second_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.evictCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, second_cache.actions[0].pipeline);
    try std.testing.expectEqual(@as(usize, 0), second_cache.actions[0].batch_index.?);
    try std.testing.expectEqual(@as(usize, 1), second_cache.actions[0].cache_index.?);
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, second_cache.actions[1].pipeline);
    try std.testing.expectEqual(RenderPipelineCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(RenderPipelineKind.solid, second_cache.actions[2].pipeline);
}

test "render pipeline cache plan reports output overflow" {
    const batches = [_]RenderBatch{.{ .pipeline = .solid, .command_start = 0, .command_count = 1 }};
    var no_entries: [0]RenderPipelineCacheEntry = .{};
    var actions: [1]RenderPipelineCacheAction = undefined;
    try std.testing.expectError(error.RenderPipelineCacheListFull, (RenderBatchPlan{ .batches = &batches }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderPipelineCacheEntry = undefined;
    var no_actions: [0]RenderPipelineCacheAction = .{};
    try std.testing.expectError(error.RenderPipelineCacheListFull, (RenderBatchPlan{ .batches = &batches }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render image plan deduplicates texture cache inputs" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{
            .id = 1,
            .image_id = 42,
            .dst = geometry.RectF.init(0, 0, 20, 20),
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .src = geometry.RectF.init(4, 4, 12, 12),
            .dst = geometry.RectF.init(48, 0, 20, 20),
            .opacity = 0.5,
            .fit = .cover,
        } },
        .{ .draw_image = .{
            .id = 3,
            .image_id = 77,
            .dst = geometry.RectF.init(80, 0, 16, 16),
        } },
    };

    var render_commands: [3]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var images: [2]RenderImage = undefined;
    const image_plan = try render_plan.imagePlan(&images);

    try std.testing.expectEqual(@as(usize, 2), image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 3), image_plan.drawCount());
    try std.testing.expectEqual(@as(ImageId, 42), image_plan.images[0].image_id);
    try std.testing.expect(image_plan.images[0].id == null);
    try std.testing.expectEqual(@as(usize, 2), image_plan.images[0].draw_count);
    try expectRect(geometry.RectF.init(0, 0, 68, 20), image_plan.images[0].bounds);
    try std.testing.expectEqual(renderImageFingerprint(42), image_plan.images[0].fingerprint);
    try std.testing.expectEqual(@as(ImageId, 77), image_plan.images[1].image_id);
    try std.testing.expectEqual(@as(?ObjectId, 3), image_plan.images[1].id);
}

test "render image cache plan uploads retains and evicts textures" {
    const previous_images = [_]RenderImage{
        .{ .image_id = 8, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .fingerprint = renderImageFingerprint(8) },
        .{ .image_id = 9, .command_index = 1, .id = 2, .draw_count = 1, .bounds = geometry.RectF.init(24, 0, 20, 20), .fingerprint = renderImageFingerprint(9) },
    };
    var previous_entries: [2]RenderImageCacheEntry = undefined;
    var previous_actions: [2]RenderImageCacheAction = undefined;
    const previous_cache = try (RenderImagePlan{ .images = &previous_images }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), previous_cache.entries[0].last_used_frame);

    const next_images = [_]RenderImage{
        .{ .image_id = 8, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .fingerprint = renderImageFingerprint(8) },
        .{ .image_id = 10, .command_index = 1, .id = 3, .draw_count = 1, .bounds = geometry.RectF.init(48, 0, 20, 20), .fingerprint = renderImageFingerprint(10) },
    };
    var next_entries: [2]RenderImageCacheEntry = undefined;
    var next_actions: [3]RenderImageCacheAction = undefined;
    const next_cache = try (RenderImagePlan{ .images = &next_images }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);

    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), next_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderImageCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(ImageId, 8), next_cache.actions[0].key.image_id);
    try std.testing.expectEqual(@as(?usize, 0), next_cache.actions[0].image_index);
    try std.testing.expectEqual(@as(?usize, 0), next_cache.actions[0].cache_index);
    try std.testing.expectEqual(RenderImageCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(ImageId, 10), next_cache.actions[1].key.image_id);
    try std.testing.expectEqual(RenderImageCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(ImageId, 9), next_cache.actions[2].key.image_id);
    try std.testing.expectEqual(@as(u64, 2), next_cache.entries[0].last_used_frame);
}

test "render image plans report output overflow" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 1,
        .dst = geometry.RectF.init(0, 0, 10, 10),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_images: [0]RenderImage = .{};
    try std.testing.expectError(error.ImageListFull, render_plan.imagePlan(&no_images));

    const images = [_]RenderImage{.{ .image_id = 1, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 10, 10), .fingerprint = renderImageFingerprint(1) }};
    var no_entries: [0]RenderImageCacheEntry = .{};
    var actions: [1]RenderImageCacheAction = undefined;
    try std.testing.expectError(error.ImageCacheListFull, (RenderImagePlan{ .images = &images }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderImageCacheEntry = undefined;
    var no_actions: [0]RenderImageCacheAction = .{};
    try std.testing.expectError(error.ImageCacheListFull, (RenderImagePlan{ .images = &images }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "resource plan collects renderer cache inputs" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(59, 130, 246) },
    };
    const glyphs = [_]Glyph{.{ .id = 7, .x = 0, .y = 0, .advance = 9 }};
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 100, 40),
            .radius = Radius.all(8),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(0, 0),
                .end = geometry.PointF.init(100, 40),
                .stops = &stops,
            } },
        } },
        .{ .draw_image = .{ .id = 2, .image_id = 99, .dst = geometry.RectF.init(8, 8, 32, 32) } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(48, 24),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
            .glyphs = &glyphs,
        } },
        .{ .shadow = .{
            .id = 4,
            .rect = geometry.RectF.init(0, 0, 100, 40),
            .offset = geometry.OffsetF.init(0, 8),
            .blur = 16,
            .spread = -4,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{ .id = 5, .rect = geometry.RectF.init(0, 0, 20, 20), .radius = 6 } },
    };

    var resources: [5]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);
    try std.testing.expectEqual(@as(usize, 5), plan.resourceCount());
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), plan.resources[0].id);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[0].gradient_stop_count);
    try expectRect(geometry.RectF.init(0, 0, 100, 40), plan.resources[0].bounds);

    try std.testing.expectEqual(RenderResourceKind.image, plan.resources[1].kind);
    try std.testing.expectEqual(@as(ImageId, 99), plan.resources[1].image_id);
    try expectRect(geometry.RectF.init(8, 8, 32, 32), plan.resources[1].bounds);

    try std.testing.expectEqual(RenderResourceKind.glyph_run, plan.resources[2].kind);
    try std.testing.expectEqual(@as(FontId, 5), plan.resources[2].font_id);
    try std.testing.expectEqual(@as(usize, 1), plan.resources[2].glyph_count);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[2].text_len);

    try std.testing.expectEqual(RenderResourceKind.shadow, plan.resources[3].kind);
    try expectRect(geometry.RectF.init(-20, -12, 140, 80), plan.resources[3].bounds);

    try std.testing.expectEqual(RenderResourceKind.blur, plan.resources[4].kind);
    try expectRect(geometry.RectF.init(-6, -6, 32, 32), plan.resources[4].bounds);
}

test "resource plan collects gradient resources for lines and paths" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
    };
    const gradient_fill = Fill{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &stops,
    } };
    const commands = [_]CanvasCommand{
        .{ .draw_line = .{
            .id = 1,
            .from = geometry.PointF.init(0, 0),
            .to = geometry.PointF.init(20, 20),
            .stroke = .{ .fill = gradient_fill, .width = 2 },
        } },
        .{ .fill_path = .{
            .id = 2,
            .elements = &path,
            .fill = gradient_fill,
        } },
    };

    var resources: [2]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);
    try std.testing.expectEqual(@as(usize, 2), plan.resourceCount());
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[0].kind);
    try std.testing.expectEqual(@as(usize, 0), plan.resources[0].command_index);
    try std.testing.expectEqual(@as(?ObjectId, 1), plan.resources[0].id);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[0].gradient_stop_count);
    try expectRect(geometry.RectF.init(-1, -1, 22, 22), plan.resources[0].bounds);
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[1].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.resources[1].command_index);
    try std.testing.expectEqual(@as(?ObjectId, 2), plan.resources[1].id);
    try expectRect(geometry.RectF.init(4, 4, 16, 16), plan.resources[1].bounds);
}

test "resource cache plan uploads retains and evicts resources" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const first_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_image = .{ .id = 2, .image_id = 8, .dst = geometry.RectF.init(24, 0, 20, 20) } },
    };
    const second_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 7,
            .size = 12,
            .origin = geometry.PointF.init(24, 16),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var first_resources: [2]RenderResource = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).resourcePlan(&first_resources);
    var first_entries: [2]RenderResourceCacheEntry = undefined;
    var first_actions: [2]RenderResourceCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, first_cache.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, first_cache.actions[1].kind);
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    var second_resources: [2]RenderResource = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).resourcePlan(&second_resources);
    var second_entries: [2]RenderResourceCacheEntry = undefined;
    var second_actions: [3]RenderResourceCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);

    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), second_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), second_cache.actions[0].cache_index);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(RenderResourceKind.glyph_run, second_cache.actions[1].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(RenderResourceKind.image, second_cache.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), second_cache.entries[0].last_used_frame);
}

test "resource cache plan treats changed fingerprints as uploads" {
    const first_stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const second_stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(37, 99, 235) },
    };
    const first_commands = [_]CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &first_stops,
    } } } }};
    const second_commands = [_]CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &second_stops,
    } } } }};

    var first_resources: [1]RenderResource = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).resourcePlan(&first_resources);
    var first_entries: [1]RenderResourceCacheEntry = undefined;
    var first_actions: [1]RenderResourceCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);

    var second_resources: [1]RenderResource = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).resourcePlan(&second_resources);
    try std.testing.expect(first_plan.resources[0].fingerprint != second_plan.resources[0].fingerprint);

    var second_entries: [1]RenderResourceCacheEntry = undefined;
    var second_actions: [2]RenderResourceCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);
    try std.testing.expectEqual(@as(usize, 2), second_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, second_cache.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, second_cache.actions[1].kind);
}

test "resource cache plan reports output overflow" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{ .id = 1, .image_id = 1, .dst = geometry.RectF.init(0, 0, 10, 10) } },
    };
    var resources: [1]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);

    var no_entries: [0]RenderResourceCacheEntry = .{};
    var actions: [1]RenderResourceCacheAction = undefined;
    try std.testing.expectError(error.RenderResourceCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderResourceCacheEntry = undefined;
    var no_actions: [0]RenderResourceCacheAction = .{};
    try std.testing.expectError(error.RenderResourceCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "resource plan reports output overflow" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{ .id = 1, .image_id = 1, .dst = geometry.RectF.init(0, 0, 10, 10) } },
    };
    var resources: [0]RenderResource = .{};
    try std.testing.expectError(error.RenderResourceListFull, (DisplayList{ .commands = &commands }).resourcePlan(&resources));
}

test "visual effect plan collects shadow and blur cache inputs" {
    const commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 7,
            .rect = geometry.RectF.init(10, 20, 30, 40),
            .radius = Radius.all(5),
            .offset = .{ .dx = 3, .dy = 4 },
            .blur = 12,
            .spread = -2,
            .color = Color.rgba8(0, 0, 0, 96),
        } },
        .{ .blur = .{
            .id = 0,
            .rect = geometry.RectF.init(80, 90, 20, 10),
            .radius = 6,
        } },
    };

    var effects: [2]VisualEffect = undefined;
    const plan = try (DisplayList{ .commands = &commands }).visualEffectPlan(&effects);
    try std.testing.expectEqual(@as(usize, 2), plan.effectCount());
    try std.testing.expectEqual(@as(usize, 1), plan.shadowCount());
    try std.testing.expectEqual(@as(usize, 1), plan.blurCount());
    try std.testing.expectEqual(VisualEffectKind.shadow, plan.effects[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 7), plan.effects[0].id);
    try expectRect(geometry.RectF.init(-1, 10, 58, 68), plan.effects[0].bounds);
    try std.testing.expect(radiiEqual(Radius.all(5), plan.effects[0].radius));
    try std.testing.expectEqual(@as(f32, 12), plan.effects[0].blur);
    try std.testing.expectEqual(@as(f32, -2), plan.effects[0].spread);
    try std.testing.expectEqual(VisualEffectKind.blur, plan.effects[1].kind);
    try std.testing.expect(plan.effects[1].id == null);
    try expectRect(geometry.RectF.init(74, 84, 32, 22), plan.effects[1].bounds);
    try std.testing.expectEqual(@as(f32, 6), plan.effects[1].blur);

    const key = visualEffectKey(plan.effects[1]);
    try std.testing.expectEqual(VisualEffectKind.blur, key.kind);
    try std.testing.expect(key.id == null);
    try std.testing.expectEqual(@as(usize, 1), key.command_index);
}

test "visual effect cache plan uploads retains and evicts effects" {
    const first_commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 20, 20),
            .blur = 8,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(30, 0, 20, 20),
            .radius = 4,
        } },
    };
    const second_commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 20, 20),
            .blur = 8,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(30, 0, 20, 20),
            .radius = 10,
        } },
    };

    var first_effects: [2]VisualEffect = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).visualEffectPlan(&first_effects);
    var first_entries: [2]VisualEffectCacheEntry = undefined;
    var first_actions: [2]VisualEffectCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    var second_effects: [2]VisualEffect = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).visualEffectPlan(&second_effects);
    var second_entries: [2]VisualEffectCacheEntry = undefined;
    var second_actions: [3]VisualEffectCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);
    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.evictCount());
    try std.testing.expectEqual(VisualEffectCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(VisualEffectKind.shadow, second_cache.actions[0].key.kind);
    try std.testing.expectEqual(VisualEffectCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(VisualEffectKind.blur, second_cache.actions[1].key.kind);
    try std.testing.expectEqual(VisualEffectCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(VisualEffectKind.blur, second_cache.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), second_cache.entries[0].last_used_frame);
}

test "visual effect plans report output overflow" {
    const commands = [_]CanvasCommand{.{ .shadow = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .blur = 4,
        .color = Color.rgba8(0, 0, 0, 64),
    } }};
    var no_effects: [0]VisualEffect = .{};
    try std.testing.expectError(error.VisualEffectListFull, (DisplayList{ .commands = &commands }).visualEffectPlan(&no_effects));

    var effects: [1]VisualEffect = undefined;
    const plan = try (DisplayList{ .commands = &commands }).visualEffectPlan(&effects);
    var no_entries: [0]VisualEffectCacheEntry = .{};
    var actions: [1]VisualEffectCacheAction = undefined;
    try std.testing.expectError(error.VisualEffectCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]VisualEffectCacheEntry = undefined;
    var no_actions: [0]VisualEffectCacheAction = .{};
    try std.testing.expectError(error.VisualEffectCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "glyph atlas plan deduplicates shaped glyph keys" {
    const first_glyphs = [_]Glyph{
        .{ .id = 10, .x = 0.10, .y = 0, .advance = 8 },
        .{ .id = 11, .x = 8.25, .y = 0, .advance = 8 },
    };
    const second_glyphs = [_]Glyph{
        .{ .id = 10, .x = 0.20, .y = 0, .advance = 8 },
        .{ .id = 10, .x = 0.55, .y = 0, .advance = 8 },
    };
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 7,
            .size = 16,
            .origin = geometry.PointF.init(12, 24),
            .color = Color.rgb8(15, 23, 42),
            .glyphs = &first_glyphs,
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 7,
            .size = 16,
            .origin = geometry.PointF.init(12, 24),
            .color = Color.rgb8(15, 23, 42),
            .glyphs = &second_glyphs,
        } },
    };

    var entries: [4]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 3), plan.entryCount());
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[0].key.font_id);
    try std.testing.expectEqual(@as(u32, 10), plan.entries[0].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 0), plan.entries[0].key.subpixel_x);
    try std.testing.expectEqual(@as(u32, 11), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 1), plan.entries[1].key.subpixel_x);
    try std.testing.expectEqual(@as(u32, 10), plan.entries[2].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[2].key.subpixel_x);
}

test "glyph atlas plan honors shaped fallback font overrides" {
    const glyphs = [_]Glyph{
        .{ .id = 41, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 9001, .font_id = 11, .x = 8, .y = 0, .advance = 14 },
        .{ .id = 42, .x = 22, .y = 0, .advance = 8 },
    };
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(12, 24),
        .color = Color.rgb8(15, 23, 42),
        .text = "A🙂B",
        .glyphs = &glyphs,
    } }};

    var entries: [3]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 3), plan.entryCount());
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[0].key.font_id);
    try std.testing.expectEqual(@as(FontId, 11), plan.entries[1].key.font_id);
    try std.testing.expectEqual(@as(u32, 9001), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[2].key.font_id);

    const primary_only = [_]Glyph{
        .{ .id = 41, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 9001, .x = 8, .y = 0, .advance = 14 },
        .{ .id = 42, .x = 22, .y = 0, .advance = 8 },
    };
    const primary_commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(12, 24),
        .color = Color.rgb8(15, 23, 42),
        .text = "A🙂B",
        .glyphs = &primary_only,
    } }};

    var changes: [1]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &primary_commands }, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 1), diff.len);
    try std.testing.expectEqual(DiffKind.changed, diff[0].kind);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DisplayList{ .commands = &commands }).writeJson(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"font\":11") != null);
}

test "glyph atlas plan falls back to utf8 scalar glyph keys" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 3,
        .size = 12,
        .origin = geometry.PointF.init(0.5, 8.75),
        .color = Color.rgb8(15, 23, 42),
        .text = "A é",
    } }};

    var entries: [2]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 2), plan.entryCount());
    try std.testing.expectEqual(@as(u32, 'A'), plan.entries[0].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[0].key.subpixel_x);
    try std.testing.expectEqual(@as(u8, 3), plan.entries[0].key.subpixel_y);
    try std.testing.expectEqual(@as(usize, 0), plan.entries[0].glyph_index);
    try std.testing.expectEqual(@as(u32, 0x00e9), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[1].key.subpixel_x);
    try std.testing.expectEqual(@as(usize, 2), plan.entries[1].glyph_index);
}

test "glyph atlas plan reports output overflow" {
    const glyphs = [_]Glyph{.{ .id = 10, .x = 0, .y = 0 }};
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 1,
        .size = 14,
        .origin = geometry.PointF.init(0, 0),
        .color = Color.rgb8(0, 0, 0),
        .glyphs = &glyphs,
    } }};
    var entries: [0]GlyphAtlasEntry = .{};
    try std.testing.expectError(error.GlyphAtlasListFull, (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries));
}

test "glyph atlas cache plan uploads retains and evicts glyphs" {
    const previous = [_]GlyphAtlasCacheEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .last_used_frame = 3,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 66, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .last_used_frame = 3,
        },
    };
    const atlas_entries = [_]GlyphAtlasEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .command_index = 0,
            .glyph_index = 0,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 67, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .command_index = 0,
            .glyph_index = 1,
        },
    };

    var cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var cache_actions: [3]GlyphAtlasCacheAction = undefined;
    const cache = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&previous, 4, &cache_entries, &cache_actions);

    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), cache.evictCount());
    try std.testing.expectEqual(@as(u64, 4), cache.entries[0].last_used_frame);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.retain, cache.actions[0].kind);
    try std.testing.expectEqual(@as(u32, 65), cache.actions[0].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 0), cache.actions[0].atlas_index.?);
    try std.testing.expectEqual(@as(usize, 0), cache.actions[0].cache_index.?);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.upload, cache.actions[1].kind);
    try std.testing.expectEqual(@as(u32, 67), cache.actions[1].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 1), cache.actions[1].atlas_index.?);
    try std.testing.expect(cache.actions[1].cache_index == null);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.evict, cache.actions[2].kind);
    try std.testing.expectEqual(@as(u32, 66), cache.actions[2].key.glyph_id);
    try std.testing.expect(cache.actions[2].atlas_index == null);
    try std.testing.expectEqual(@as(usize, 1), cache.actions[2].cache_index.?);
}

test "glyph atlas cache plan keeps recent unused glyphs warm" {
    const previous = [_]GlyphAtlasCacheEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
            .last_used_frame = 3,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 66, .size = 14 },
            .last_used_frame = 3,
        },
    };
    const atlas_entries = [_]GlyphAtlasEntry{.{
        .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
        .command_index = 0,
        .glyph_index = 0,
    }};

    var warm_entries: [2]GlyphAtlasCacheEntry = undefined;
    var warm_actions: [2]GlyphAtlasCacheAction = undefined;
    const warm = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlanWithRetention(&previous, 4, 2, &warm_entries, &warm_actions);
    try std.testing.expectEqual(@as(usize, 2), warm.entryCount());
    try std.testing.expectEqual(@as(usize, 0), warm.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), warm.retainCount());
    try std.testing.expectEqual(@as(usize, 0), warm.evictCount());
    try std.testing.expectEqual(@as(u64, 4), warm.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 3), warm.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].atlas_index);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].cache_index);
    try std.testing.expect(warm.actions[1].atlas_index == null);
    try std.testing.expectEqual(@as(?usize, 1), warm.actions[1].cache_index);

    var stale_entries: [2]GlyphAtlasCacheEntry = undefined;
    var stale_actions: [2]GlyphAtlasCacheAction = undefined;
    const stale = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlanWithRetention(&previous, 6, 2, &stale_entries, &stale_actions);
    try std.testing.expectEqual(@as(usize, 1), stale.entryCount());
    try std.testing.expectEqual(@as(usize, 1), stale.retainCount());
    try std.testing.expectEqual(@as(usize, 1), stale.evictCount());
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.evict, stale.actions[1].kind);
    try std.testing.expectEqual(@as(u32, 66), stale.actions[1].key.glyph_id);
    try std.testing.expectEqual(@as(?usize, 1), stale.actions[1].cache_index);
}

test "glyph atlas cache plan reports output overflow" {
    const atlas_entries = [_]GlyphAtlasEntry{.{
        .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
        .command_index = 0,
        .glyph_index = 0,
    }};
    var no_cache_entries: [0]GlyphAtlasCacheEntry = .{};
    var cache_actions: [1]GlyphAtlasCacheAction = undefined;
    try std.testing.expectError(error.GlyphAtlasCacheListFull, (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&.{}, 1, &no_cache_entries, &cache_actions));

    var cache_entries: [1]GlyphAtlasCacheEntry = undefined;
    var no_cache_actions: [0]GlyphAtlasCacheAction = .{};
    try std.testing.expectError(error.GlyphAtlasCacheListFull, (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&.{}, 1, &cache_entries, &no_cache_actions));
}

test "canvas frame plan builds first frame renderer packet" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(16, 16, 160, 72),
            .radius = Radius.all(12),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(16, 16),
                .end = geometry.PointF.init(176, 88),
                .stops = &stops,
            } },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(28, 48),
            .color = Color.rgb8(15, 23, 42),
            .text = "OK",
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [2]RenderBatch = undefined;
    var pipeline_cache_entries: [2]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [2]RenderPipelineCacheAction = undefined;
    var resources: [2]RenderResource = undefined;
    var resource_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]RenderResourceCacheAction = undefined;
    var glyphs: [2]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [1]TextLayoutPlan = undefined;
    var text_layout_lines: [1]TextLine = undefined;
    var text_layout_cache_entries: [1]TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [1]TextLayoutCacheAction = undefined;
    var changes: [2]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 7,
        .timestamp_ns = 88,
        .surface_size = geometry.SizeF.init(320, 200),
        .scale = 2,
        .budget = .{
            .max_commands = 1,
            .max_batches = 2,
            .max_encoder_commands = 13,
            .max_pipelines = 2,
            .max_pipeline_uploads = 1,
            .max_resources = 2,
            .max_resource_uploads = 1,
            .max_glyph_atlas_entries = 2,
        },
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(u64, 7), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 88), frame.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), frame.surface_size);
    try std.testing.expectEqual(@as(f32, 2), frame.scale);
    try std.testing.expect(frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 2), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.batch_plan.batchCount());
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, frame.batch_plan.batches[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, frame.batch_plan.batches[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.actionCount());
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, frame.pipeline_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, frame.pipeline_cache_plan.actions[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, frame.pipeline_cache_plan.actions[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), frame.resource_plan.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[1].kind);
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_plan.lineCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), frame.dirty_bounds);

    const render_pass = frame.renderPass();
    try std.testing.expect(render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, render_pass.loadAction());
    try std.testing.expectEqual(@as(u64, 7), render_pass.frame_index);
    try std.testing.expectEqual(@as(u64, 88), render_pass.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), render_pass.surface_size);
    try std.testing.expectEqual(@as(f32, 2), render_pass.scale);
    try std.testing.expectEqual(@as(usize, 2), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.batchCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.pipelineActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryVertexCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryIndexCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.imageCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.imageActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.layerCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.layerActionCount());
    try std.testing.expectEqual(@as(usize, 14), render_pass.encoderCommandCount());
    try std.testing.expectEqual(@as(usize, 7), render_pass.encoderCacheActionCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderBindPipelineCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderDrawBatchCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.resourceActionCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.glyphAtlasEntryCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.glyphAtlasActionCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutLineCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutActionCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, render_pass.pipeline_actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, render_pass.resource_actions[0].kind);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.upload, render_pass.glyph_atlas_actions[0].kind);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, render_pass.text_layout_actions[0].kind);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), render_pass.scissorBounds());

    var encoder_commands: [16]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 14), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 7), encoder_plan.cacheActionCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.bindPipelineCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.drawBatchCount());
    switch (encoder_plan.commands[0]) {
        .begin_pass => |begin| {
            try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, begin.load_action);
            try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), begin.surface_size);
        },
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[1]) {
        .set_scissor => |bounds| try expectRect(geometry.RectF.init(0, 0, 320, 200), bounds),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[encoder_plan.commands.len - 1]) {
        .end_pass => {},
        else => return error.TestExpectedEqual,
    }

    var render_pass_json_buffer: [8192]u8 = undefined;
    var render_pass_json_writer = std.Io.Writer.fixed(&render_pass_json_buffer);
    try render_pass.writeJson(&render_pass_json_writer);
    const render_pass_json = render_pass_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"loadAction\":\"clear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"scissorBounds\":[0,0,320,200]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"commands\":[{\"index\":0,\"id\":1,\"opacity\":1,\"clip\":null,\"transform\":[1,0,0,1,0,0],\"localBounds\":[16,16,160,72],\"bounds\":[16,16,160,72],\"command\":{\"op\":\"fill_rounded_rect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"batches\":[{\"pipeline\":\"linear_gradient\",\"commandStart\":0,\"commandCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"pipelineActions\":[{\"kind\":\"upload\",\"pipeline\":\"linear_gradient\",\"batchIndex\":0,\"cacheIndex\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"pathGeometries\":[],\"pathGeometryActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"images\":[],\"imageActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"layers\":[],\"layerActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"resources\":[{\"kind\":\"linear_gradient\",\"commandIndex\":0,\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"resourceActions\":[{\"kind\":\"upload\",\"key\":{\"kind\":\"linear_gradient\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"glyphAtlasEntries\":[{\"key\":{\"fontId\":5,\"glyphId\":79") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"glyphAtlasActions\":[{\"kind\":\"upload\",\"key\":{\"fontId\":5,\"glyphId\":79") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"textLayouts\":[{\"key\":{\"fontId\":5,\"size\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"textLayoutActions\":[{\"kind\":\"upload\",\"key\":{\"fontId\":5,\"size\":14") != null);

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(u64, 7), diagnostics.frame_index);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.command_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.batch_count);
    try std.testing.expectEqual(@as(usize, 14), diagnostics.encoder_command_count);
    try std.testing.expectEqual(@as(usize, 7), diagnostics.encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.pipeline_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.pipeline_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.pipeline_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.pipeline_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_index_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_opacity_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_clip_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_transform_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_entry_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_line_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text_layout_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text_layout_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.change_count);
    try std.testing.expect(diagnostics.full_repaint);
    try std.testing.expect(diagnostics.requires_render);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), diagnostics.dirty_bounds);
    try std.testing.expect(!diagnostics.budgetOk());
    try std.testing.expect(diagnostics.budget_status.commands_over);
    try std.testing.expect(!diagnostics.budget_status.batches_over);
    try std.testing.expect(diagnostics.budget_status.encoder_commands_over);
    try std.testing.expect(!diagnostics.budget_status.pipelines_over);
    try std.testing.expect(diagnostics.budget_status.pipeline_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.path_geometries_over);
    try std.testing.expect(!diagnostics.budget_status.path_geometry_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.images_over);
    try std.testing.expect(!diagnostics.budget_status.image_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.layers_over);
    try std.testing.expect(!diagnostics.budget_status.layer_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.resources_over);
    try std.testing.expect(diagnostics.budget_status.resource_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.glyph_atlas_entries_over);
    try std.testing.expect(!diagnostics.budget_status.text_layouts_over);
    try std.testing.expect(!diagnostics.budget_status.text_layout_lines_over);
    try std.testing.expect(!diagnostics.budget_status.changes_over);
    try std.testing.expectEqual(@as(usize, 4), diagnostics.budget_status.exceededCount());
    try std.testing.expectEqual(@as(usize, 4), frame.budgetStatus().exceededCount());

    var diagnostics_json_buffer: [2048]u8 = undefined;
    var diagnostics_json_writer = std.Io.Writer.fixed(&diagnostics_json_buffer);
    try frame.writeDiagnosticsJson(&diagnostics_json_writer);
    try std.testing.expectEqualStrings(
        "{\"frameIndex\":7,\"commandCount\":2,\"batchCount\":2,\"encoderCommandCount\":14,\"encoderCacheActionCount\":7,\"encoderBindPipelineCount\":2,\"encoderDrawBatchCount\":2,\"pipelineCount\":2,\"pipelineUploadCount\":2,\"pipelineRetainCount\":0,\"pipelineEvictCount\":0,\"pathGeometryCount\":0,\"pathGeometryVertexCount\":0,\"pathGeometryIndexCount\":0,\"pathGeometryUploadCount\":0,\"pathGeometryRetainCount\":0,\"pathGeometryEvictCount\":0,\"layerCount\":0,\"layerOpacityCount\":0,\"layerClipCount\":0,\"layerTransformCount\":0,\"layerUploadCount\":0,\"layerRetainCount\":0,\"layerEvictCount\":0,\"imageCount\":0,\"imageUploadCount\":0,\"imageRetainCount\":0,\"imageEvictCount\":0,\"resourceCount\":2,\"resourceUploadCount\":2,\"resourceRetainCount\":0,\"resourceEvictCount\":0,\"visualEffectCount\":0,\"visualEffectShadowCount\":0,\"visualEffectBlurCount\":0,\"visualEffectUploadCount\":0,\"visualEffectRetainCount\":0,\"visualEffectEvictCount\":0,\"glyphAtlasEntryCount\":2,\"glyphAtlasUploadCount\":2,\"glyphAtlasRetainCount\":0,\"glyphAtlasEvictCount\":0,\"textLayoutCount\":1,\"textLayoutLineCount\":1,\"textLayoutUploadCount\":1,\"textLayoutRetainCount\":0,\"textLayoutEvictCount\":0,\"changeCount\":0,\"budgetExceededCount\":4,\"budgetOk\":false,\"fullRepaint\":true,\"requiresRender\":true,\"dirtyBounds\":[0,0,320,200]}",
        diagnostics_json_writer.buffered(),
    );

    var clean_json_buffer: [2048]u8 = undefined;
    var clean_json_writer = std.Io.Writer.fixed(&clean_json_buffer);
    try (CanvasFrameDiagnostics{ .frame_index = 8 }).writeJson(&clean_json_writer);
    try std.testing.expectEqualStrings(
        "{\"frameIndex\":8,\"commandCount\":0,\"batchCount\":0,\"encoderCommandCount\":0,\"encoderCacheActionCount\":0,\"encoderBindPipelineCount\":0,\"encoderDrawBatchCount\":0,\"pipelineCount\":0,\"pipelineUploadCount\":0,\"pipelineRetainCount\":0,\"pipelineEvictCount\":0,\"pathGeometryCount\":0,\"pathGeometryVertexCount\":0,\"pathGeometryIndexCount\":0,\"pathGeometryUploadCount\":0,\"pathGeometryRetainCount\":0,\"pathGeometryEvictCount\":0,\"layerCount\":0,\"layerOpacityCount\":0,\"layerClipCount\":0,\"layerTransformCount\":0,\"layerUploadCount\":0,\"layerRetainCount\":0,\"layerEvictCount\":0,\"imageCount\":0,\"imageUploadCount\":0,\"imageRetainCount\":0,\"imageEvictCount\":0,\"resourceCount\":0,\"resourceUploadCount\":0,\"resourceRetainCount\":0,\"resourceEvictCount\":0,\"visualEffectCount\":0,\"visualEffectShadowCount\":0,\"visualEffectBlurCount\":0,\"visualEffectUploadCount\":0,\"visualEffectRetainCount\":0,\"visualEffectEvictCount\":0,\"glyphAtlasEntryCount\":0,\"glyphAtlasUploadCount\":0,\"glyphAtlasRetainCount\":0,\"glyphAtlasEvictCount\":0,\"textLayoutCount\":0,\"textLayoutLineCount\":0,\"textLayoutUploadCount\":0,\"textLayoutRetainCount\":0,\"textLayoutEvictCount\":0,\"changeCount\":0,\"budgetExceededCount\":0,\"budgetOk\":true,\"fullRepaint\":false,\"requiresRender\":false,\"dirtyBounds\":null}",
        clean_json_writer.buffered(),
    );
}

test "render encoder plan skips clean passes and reports output overflow" {
    var clean_encoder_commands: [1]RenderEncoderCommand = undefined;
    const clean_plan = try (CanvasRenderPass{}).encoderPlan(&clean_encoder_commands);
    try std.testing.expectEqual(@as(usize, 0), clean_plan.commandCount());

    const batches = [_]RenderBatch{.{ .pipeline = .solid, .command_start = 0, .command_count = 1 }};
    const pass = CanvasRenderPass{
        .full_repaint = true,
        .batches = &batches,
    };
    var encoder_commands: [4]RenderEncoderCommand = undefined;
    const plan = try pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 4), plan.commandCount());
    try std.testing.expectEqual(@as(usize, 1), plan.bindPipelineCount());
    try std.testing.expectEqual(@as(usize, 1), plan.drawBatchCount());

    var too_small: [3]RenderEncoderCommand = undefined;
    try std.testing.expectError(error.RenderEncoderListFull, pass.encoderPlan(&too_small));
}

test "canvas frame plan carries path geometry cache actions" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var pipeline_cache_entries: [1]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [1]RenderPipelineCacheAction = undefined;
    var path_geometries: [1]RenderPathGeometry = undefined;
    var path_geometry_cache_entries: [1]RenderPathGeometryCacheEntry = undefined;
    var path_geometry_cache_actions: [1]RenderPathGeometryCacheAction = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 4,
        .surface_size = geometry.SizeF.init(64, 64),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .path_geometries = &path_geometries,
        .path_geometry_cache_entries = &path_geometry_cache_entries,
        .path_geometry_cache_actions = &path_geometry_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_plan.geometryCount());
    try std.testing.expectEqual(@as(usize, 3), frame.path_geometry_plan.vertexCount());
    try std.testing.expectEqual(@as(usize, 3), frame.path_geometry_plan.indexCount());
    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, frame.path_geometry_cache_plan.actions[0].kind);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(@as(usize, 1), render_pass.pathGeometryCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.pathGeometryActionCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.pathGeometryVertexCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.pathGeometryIndexCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderCacheActionCount());

    var encoder_commands: [8]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 7), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.cacheActionCount());
    switch (encoder_plan.commands[2]) {
        .pipeline_cache => |action| try std.testing.expectEqual(RenderPipelineKind.path, action.pipeline),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[3]) {
        .path_geometry_cache => |action| {
            try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, action.kind);
            try std.testing.expectEqual(RenderPathGeometryKind.fill, action.key.kind);
            try std.testing.expectEqual(@as(?ObjectId, 1), action.key.id);
        },
        else => return error.TestExpectedEqual,
    }

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.path_geometry_count);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.path_geometry_vertex_count);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.path_geometry_index_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.path_geometry_upload_count);
}

test "canvas frame plan carries image cache actions" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(8, 8, 24, 24),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var pipeline_cache_entries: [1]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [1]RenderPipelineCacheAction = undefined;
    var images: [1]RenderImage = undefined;
    var image_cache_entries: [1]RenderImageCacheEntry = undefined;
    var image_cache_actions: [1]RenderImageCacheAction = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 6,
        .surface_size = geometry.SizeF.init(64, 64),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .images = &images,
        .image_cache_entries = &image_cache_entries,
        .image_cache_actions = &image_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 1), frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 1), frame.image_plan.drawCount());
    try std.testing.expectEqual(@as(ImageId, 42), frame.image_plan.images[0].image_id);
    try std.testing.expectEqual(@as(usize, 1), frame.image_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderImageCacheActionKind.upload, frame.image_cache_plan.actions[0].kind);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(@as(usize, 1), render_pass.imageCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.imageActionCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.encoderCacheActionCount());

    var encoder_commands: [8]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 8), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 3), encoder_plan.cacheActionCount());
    switch (encoder_plan.commands[2]) {
        .pipeline_cache => |action| try std.testing.expectEqual(RenderPipelineKind.image, action.pipeline),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[3]) {
        .image_cache => |action| {
            try std.testing.expectEqual(RenderImageCacheActionKind.upload, action.kind);
            try std.testing.expectEqual(@as(ImageId, 42), action.key.image_id);
        },
        else => return error.TestExpectedEqual,
    }

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.image_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.image_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_evict_count);

    const profile = frame.profile();
    try std.testing.expectEqual(@as(u64, 6), profile.frame_index);
    try std.testing.expect(profile.requires_render);
    try std.testing.expect(profile.full_repaint);
    try std.testing.expectEqual(@as(usize, 3), profile.cache_action_count);
    try std.testing.expectEqual(@as(usize, 3), profile.cache_upload_count);
    try std.testing.expectEqual(@as(usize, 1), profile.image_count);
    try std.testing.expectEqual(CanvasFrameProfileRisk.high, profile.risk);
}

test "canvas frame plan carries resource cache retain upload and evict actions" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const previous_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_image = .{ .id = 2, .image_id = 8, .dst = geometry.RectF.init(24, 0, 20, 20) } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 7,
            .size = 12,
            .origin = geometry.PointF.init(24, 16),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var previous_render_commands: [2]RenderCommand = undefined;
    var previous_render_batches: [2]RenderBatch = undefined;
    var previous_resources: [2]RenderResource = undefined;
    var previous_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var previous_cache_actions: [2]RenderResourceCacheAction = undefined;
    var previous_glyphs: [0]GlyphAtlasEntry = .{};
    var previous_changes: [0]DiffChange = .{};
    const previous_frame = try (DisplayList{ .commands = &previous_commands }).framePlan(null, .{
        .frame_index = 1,
    }, .{
        .render_commands = &previous_render_commands,
        .render_batches = &previous_render_batches,
        .resources = &previous_resources,
        .resource_cache_entries = &previous_cache_entries,
        .resource_cache_actions = &previous_cache_actions,
        .glyph_atlas_entries = &previous_glyphs,
        .changes = &previous_changes,
    });

    var next_render_commands: [2]RenderCommand = undefined;
    var next_render_batches: [2]RenderBatch = undefined;
    var next_resources: [2]RenderResource = undefined;
    var next_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var next_cache_actions: [3]RenderResourceCacheAction = undefined;
    var next_glyphs: [2]GlyphAtlasEntry = undefined;
    var next_glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var next_glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var next_changes: [2]DiffChange = undefined;
    const next_frame = try (DisplayList{ .commands = &next_commands }).framePlan(.{ .commands = &previous_commands }, .{
        .frame_index = 2,
        .previous_resource_cache = previous_frame.resource_cache_plan.entries,
    }, .{
        .render_commands = &next_render_commands,
        .render_batches = &next_render_batches,
        .resources = &next_resources,
        .resource_cache_entries = &next_cache_entries,
        .resource_cache_actions = &next_cache_actions,
        .glyph_atlas_entries = &next_glyphs,
        .glyph_atlas_cache_entries = &next_glyph_cache_entries,
        .glyph_atlas_cache_actions = &next_glyph_cache_actions,
        .changes = &next_changes,
    });

    try std.testing.expectEqual(@as(usize, 2), next_frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 3), next_frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.evictCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.retain, next_frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, next_frame.resource_cache_plan.actions[0].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, next_frame.resource_cache_plan.actions[1].kind);
    try std.testing.expectEqual(RenderResourceKind.glyph_run, next_frame.resource_cache_plan.actions[1].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, next_frame.resource_cache_plan.actions[2].kind);
    try std.testing.expectEqual(RenderResourceKind.image, next_frame.resource_cache_plan.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), next_frame.resource_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(usize, 2), next_frame.glyph_atlas_cache_plan.uploadCount());

    const diagnostics = next_frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.change_count);
}

test "canvas frame plan clips incremental dirty bounds to surface" {
    const previous_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(70, 0, 20, 20), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(20, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(70, 0, 20, 20), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [2]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &next_commands }).framePlan(.{ .commands = &previous_commands }, .{
        .surface_size = geometry.SizeF.init(50, 50),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 1), frame.changes.len);
    try std.testing.expectEqual(DiffKind.changed, frame.changes[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), frame.changes[0].id);
    try expectRect(geometry.RectF.init(0, 0, 50, 40), frame.dirty_bounds);

    const render_pass = frame.renderPass();
    try std.testing.expect(render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.load, render_pass.loadAction());
    try std.testing.expectEqual(@as(usize, 2), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.batchCount());
    try expectRect(geometry.RectF.init(0, 0, 50, 40), render_pass.scissorBounds());

    const profile = frame.profile();
    try std.testing.expect(profile.requires_render);
    try std.testing.expect(!profile.full_repaint);
    try std.testing.expectEqual(@as(f32, 2500), profile.surface_area);
    try std.testing.expectEqual(@as(f32, 2000), profile.dirty_area);
    try std.testing.expectEqual(@as(f32, 0.8), profile.dirty_ratio);
    try std.testing.expectEqual(CanvasFrameProfileRisk.high, profile.risk);

    var profile_json_buffer: [1024]u8 = undefined;
    var profile_json_writer = std.Io.Writer.fixed(&profile_json_buffer);
    try frame.writeProfileJson(&profile_json_writer);
    const profile_json = profile_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"dirtyArea\":2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"risk\":\"high\"") != null);
}

test "canvas frame plan leaves unchanged retained frame clean" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(!frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds == null);

    const render_pass = frame.renderPass();
    try std.testing.expect(!render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.skip, render_pass.loadAction());
    try std.testing.expect(render_pass.scissorBounds() == null);
    try std.testing.expectEqual(@as(usize, 1), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.batchCount());

    const profile = frame.profile();
    try std.testing.expect(!profile.requires_render);
    try std.testing.expectEqual(CanvasFrameProfileRisk.idle, profile.risk);
    try std.testing.expectEqual(@as(usize, 0), profile.encoder_command_count);
    try std.testing.expectEqual(@as(usize, 0), profile.work_units);
}

test "canvas frame plan applies render overrides without display list changes" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    const overrides = [_]CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
        .transform = Affine.translate(10, 0),
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .render_overrides = &overrides,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 20, 10), frame.dirty_bounds);
    try std.testing.expectEqual(@as(usize, 1), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(f32, 0.5), frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 10, 10), frame.render_plan.commands[0].bounds);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(CanvasRenderPassLoadAction.load, render_pass.loadAction());
    try expectRect(geometry.RectF.init(0, 0, 20, 10), render_pass.scissorBounds());

    var pixels: [40 * 20 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(40, 20, &pixels);
    surface.clear(Color.rgb8(0, 0, 0));
    try surface.renderPass(render_pass, Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 5, 5);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 15, 5);

    var clean_render_commands: [1]RenderCommand = undefined;
    var clean_render_batches: [1]RenderBatch = undefined;
    var clean_changes: [1]DiffChange = undefined;
    const clean_frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .previous_render_overrides = &overrides,
        .render_overrides = &overrides,
    }, .{
        .render_commands = &clean_render_commands,
        .render_batches = &clean_render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &clean_changes,
    });

    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 10, 10), clean_frame.render_plan.commands[0].bounds);
}

test "canvas render animations sample overrides for frame planning" {
    const animations = [_]CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = 1_000,
        .duration_ms = 1000,
        .easing = .linear,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = Affine.translate(0, 0),
        .to_transform = Affine.translate(20, 0),
    }};

    var overrides: [1]CanvasRenderOverride = undefined;
    const sampled = try sampleCanvasRenderAnimations(&animations, 500_001_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);
    try std.testing.expectEqual(@as(ObjectId, 1), sampled[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), sampled[0].opacity.?);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), sampled[0].transform.?);

    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .render_overrides = sampled,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 20, 10), frame.dirty_bounds);
    try std.testing.expectEqual(@as(f32, 0.5), frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), frame.render_plan.commands[0].transform);

    var empty_overrides: [0]CanvasRenderOverride = .{};
    try std.testing.expectError(error.RenderOverrideListFull, sampleCanvasRenderAnimations(&animations, 500_001_000, &empty_overrides));
}

test "motion tokens build render animations" {
    const tokens = MotionTokens{
        .fast_ms = 90,
        .normal_ms = 160,
        .slow_ms = 320,
        .easing = .linear,
        .spring = .{ .mass = 2, .stiffness = 180, .damping = 22 },
    };

    try std.testing.expectEqual(@as(u32, 90), tokens.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 160), tokens.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 320), tokens.durationMs(.slow));

    const animation = tokens.animation(.{
        .id = 7,
        .start_ns = 10_000,
        .duration = .slow,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = Affine.translate(0, 0),
        .to_transform = Affine.translate(16, 0),
    });

    try std.testing.expectEqual(@as(ObjectId, 7), animation.id);
    try std.testing.expectEqual(@as(u64, 10_000), animation.start_ns);
    try std.testing.expectEqual(@as(u32, 320), animation.duration_ms);
    try std.testing.expectEqual(Easing.linear, animation.easing);
    try std.testing.expectEqual(@as(f32, 2), animation.spring.mass);
    try std.testing.expectEqual(@as(f32, 180), animation.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 22), animation.spring.damping);

    var overrides: [1]CanvasRenderOverride = undefined;
    const sampled = try sampleCanvasRenderAnimations(&.{animation}, animation.start_ns + 160_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);
    try std.testing.expectEqual(@as(ObjectId, 7), sampled[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), sampled[0].opacity.?);
    try std.testing.expectEqualDeep(Affine.translate(8, 0), sampled[0].transform.?);

    const override_animation = tokens.animation(.{
        .id = 8,
        .easing = .emphasized,
        .spring = .{ .mass = 3, .stiffness = 140, .damping = 18 },
    });
    try std.testing.expectEqual(Easing.emphasized, override_animation.easing);
    try std.testing.expectEqual(@as(f32, 3), override_animation.spring.mass);
    try std.testing.expectEqual(@as(f32, 140), override_animation.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 18), override_animation.spring.damping);

    const reduced = MotionTokens.reduced();
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.slow));
    const reduced_animation = reduced.animation(.{
        .id = 9,
        .duration = .slow,
        .from_opacity = 0,
        .to_opacity = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), reduced_animation.duration_ms);
    try std.testing.expectEqual(Easing.linear, reduced_animation.easing);
    try std.testing.expectEqual(@as(f32, 1), motionProgress(reduced_animation, reduced_animation.start_ns));
}

test "reference renderer clears and fills solid rect render pass" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);

    try surface.renderPass(.{}, Color.rgb8(255, 255, 255));
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
}

test "reference renderer applies render pass scale" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 1, 1),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(2, 2),
        .scale = 2,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer applies render pass scissor on load" {
    const commands = [_]RenderCommand{.{
        .command = .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 4, 4),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .local_bounds = geometry.RectF.init(0, 0, 4, 4),
        .bounds = geometry.RectF.init(0, 0, 4, 4),
    }};

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    surface.clear(Color.rgb8(0, 0, 255));
    try surface.renderPass(.{
        .dirty_bounds = geometry.RectF.init(1, 1, 2, 2),
        .commands = &commands,
    }, Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 3, 3);
}

test "reference renderer applies clip transform and opacity" {
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .rect = geometry.RectF.init(1, 1, 2, 2) } },
        .{ .push_opacity = 0.5 },
        .{ .transform = Affine.translate(1, 0) },
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 3, 3),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .pop_opacity,
        .pop_clip,
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer samples transformed clipped linear gradients" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 0, 0) },
        .{ .offset = 1, .color = Color.rgb8(0, 0, 255) },
    };
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .rect = geometry.RectF.init(2, 0, 1, 1) } },
        .{ .transform = Affine.translate(1, 0) },
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 2, 1),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(0, 0),
                .end = geometry.PointF.init(2, 0),
                .stops = &stops,
            } },
        } },
        .pop_clip,
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 1, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 137, 0, 225, 255 }, surface, 2, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 0);
}

test "reference renderer draws stroked lines" {
    const commands = [_]CanvasCommand{.{ .draw_line = .{
        .id = 1,
        .from = geometry.PointF.init(0.5, 1.5),
        .to = geometry.PointF.init(2.5, 1.5),
        .stroke = .{ .fill = .{ .color = Color.rgb8(255, 0, 0) }, .width = 1 },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 3),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 3 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 3, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 2);
}

test "reference renderer fills closed paths" {
    const elements = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(1, 1), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(3, 1), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(3, 3), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(1, 3), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &elements,
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer strokes paths" {
    const elements = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(2.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
    };
    const commands = [_]CanvasCommand{.{ .stroke_path = .{
        .id = 1,
        .elements = &elements,
        .stroke = .{ .fill = .{ .color = Color.rgb8(255, 0, 0) }, .width = 1 },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 3),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 3 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 3, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 1);
}

test "reference renderer draws soft shadows" {
    const commands = [_]CanvasCommand{.{ .shadow = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .blur = 1,
        .color = Color.rgba8(0, 0, 0, 128),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 27 }, surface, 0, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 64 }, surface, 0, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 128 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 64 }, surface, 3, 2);
}

test "reference renderer blurs with caller scratch storage" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 1, 1),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .{ .fill_rect = .{
            .id = 2,
            .rect = geometry.RectF.init(2, 0, 1, 1),
            .fill = .{ .color = Color.rgb8(0, 0, 255) },
        } },
        .{ .blur = .{
            .id = 3,
            .rect = geometry.RectF.init(0, 0, 3, 1),
            .radius = 1,
        } },
    };

    var render_commands: [3]RenderCommand = undefined;
    var render_batches: [3]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(3, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [3 * 1 * 4]u8 = undefined;
    var scratch: [3 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.initWithScratch(3, 1, &pixels, &scratch);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 159, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 70, 0, 70, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 0, 0, 159, 255 }, surface, 2, 0);
}

test "reference renderer blurs transparent colors without dark fringes" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 1, 1),
            .fill = .{ .color = Color.rgba8(255, 0, 0, 128) },
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(0, 0, 3, 1),
            .radius = 1,
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [2]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(3, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [3 * 1 * 4]u8 = undefined;
    var scratch: [3 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.initWithScratch(3, 1, &pixels, &scratch);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 80 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 35 }, surface, 1, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 0 }, surface, 2, 0);
}

test "reference renderer draws proxy text runs" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .text = "A B",
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [3]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [3]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [3]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(5, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    var pixels: [5 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(5, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 4, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 3);
}

test "reference renderer advances proxy text by utf8 scalars" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .text = "é B",
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [4]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [4]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(5, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    var pixels: [5 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(5, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 4, 1);
}

test "reference renderer applies shaped glyph y offsets" {
    const shaped_glyphs = [_]Glyph{.{ .id = 1, .x = 0, .y = 1, .advance = 1 }};
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 2,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .glyphs = &shaped_glyphs,
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [1]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [1]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [1]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 5),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    var pixels: [4 * 5 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 5, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 2);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 3);
}

test "reference renderer draws image resources" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
        .fit = .contain,
    } }};
    const image_pixels = [_]u8{
        255, 0, 0,   255,
        0,   0, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 1,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 225, 0, 137, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 137, 0, 225, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 3, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 3);
}

test "reference renderer bilinear-filters scaled images" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
    } }};
    const image_pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 207, 137, 137, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 207, 225, 225, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 3, 3);
}

test "reference renderer nearest-filters scaled images" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
        .sampling = .nearest,
    } }};
    const image_pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 3, 3);
}

test "reference renderer filters scaled image alpha premultiplied" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 1),
    } }};
    const image_pixels = [_]u8{
        255, 0, 0,   255,
        0,   0, 255, 0,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 1,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 1 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 1, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 191 }, surface, 1, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 64 }, surface, 2, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 0 }, surface, 3, 0);
}

test "reference renderer rejects unsupported images" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 2, 2),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(2, 2),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [2 * 2 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(2, 2, &pixels);
    try std.testing.expectError(error.ReferenceRenderUnsupportedCommand, surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0)));
}

test "canvas frame plan reports diff storage overflow" {
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    try std.testing.expectError(error.DiffListFull, (DisplayList{ .commands = &next_commands }).framePlan(.{}, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    }));
}

test "text edit state applies utf8-aware caret insert and delete events" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("AéB");

    state = try state.apply(.{ .move_caret = .{ .direction = .previous } }, &storage_a);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    state = try state.apply(.delete_backward, &storage_a);
    try std.testing.expectEqualStrings("AB", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    state = try state.apply(.{ .insert_text = "x" }, &storage_b);
    try std.testing.expectEqualStrings("AxB", state.text);
    try std.testing.expectEqual(@as(usize, 2), state.selection.focus);

    state = try state.apply(.{ .set_selection = .{ .anchor = 1, .focus = 3 } }, &storage_a);
    state = try state.apply(.delete_forward, &storage_a);
    try std.testing.expectEqualStrings("A", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    var small: [1]u8 = undefined;
    try std.testing.expectError(error.TextEditBufferTooSmall, state.apply(.{ .insert_text = "toolong" }, &small));
}

test "widget keyboard events map to text edit events" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("Hi");

    const insert = (WidgetKeyboardEvent{ .phase = .text_input, .text = "!" }).textEditEvent().?;
    state = try state.apply(insert, &storage_a);
    try std.testing.expectEqualStrings("Hi!", state.text);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    const backspace = (WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace" }).textEditEvent().?;
    state = try state.apply(backspace, &storage_b);
    try std.testing.expectEqualStrings("Hi", state.text);
    try std.testing.expectEqual(@as(usize, 2), state.selection.focus);

    const extend_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .shift = true } }).textEditEvent().?;
    state = try state.apply(extend_left, &storage_a);
    try std.testing.expectEqual(@as(usize, 2), state.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    const delete_forward = (WidgetKeyboardEvent{ .phase = .key_down, .key = "delete" }).textEditEvent().?;
    state = try state.apply(delete_forward, &storage_b);
    try std.testing.expectEqualStrings("H", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    const home = (WidgetKeyboardEvent{ .phase = .key_down, .key = "home" }).textEditEvent().?;
    state = try state.apply(home, &storage_a);
    try std.testing.expectEqual(@as(usize, 0), state.selection.focus);

    const option_insert = (WidgetKeyboardEvent{ .phase = .text_input, .text = "@", .modifiers = .{ .alt = true } }).textEditEvent().?;
    switch (option_insert) {
        .insert_text => |text| try std.testing.expectEqualStrings("@", text),
        else => try std.testing.expect(false),
    }

    try std.testing.expect((WidgetKeyboardEvent{ .phase = .text_input, .text = "a", .modifiers = .{ .super = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .alt = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_up, .key = "backspace" }).textEditEvent() == null);
}

test "text edit state tracks ime composition ranges" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("hello");

    state = try state.apply(.{ .set_selection = .{ .anchor = 1, .focus = 4 } }, &storage_a);
    state = try state.apply(.{ .set_composition = .{ .text = "é", .cursor = 2 } }, &storage_a);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expectEqualDeep(TextRange.init(1, 3), state.composition.?);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    state = try state.apply(.commit_composition, &storage_b);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expect(state.composition == null);

    state = try state.apply(.{ .set_composition = .{ .text = "ll", .cursor = 2 } }, &storage_b);
    try std.testing.expectEqualStrings("héllo", state.text);
    state = try state.apply(.cancel_composition, &storage_a);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);
    try std.testing.expect(state.composition == null);
}

test "text bounds follow utf8 scalar fallback and shaped y offsets" {
    try expectRect(geometry.RectF.init(2, 8, 15, 12.5), textBounds(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(2, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "é B",
    }));

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = -2, .advance = 6 },
        .{ .id = 2, .x = 8, .y = 3, .advance = 5 },
    };
    try expectRect(geometry.RectF.init(4, 8, 13, 17.5), textBounds(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .glyphs = &glyphs,
    }));
}

test "text bounds and reference renderer honor per-run wrapping" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(255, 255, 255),
        .text = "ABCD",
        .text_layout = .{ .max_width = 10, .line_height = 12, .wrap = .character },
    };
    try expectRect(geometry.RectF.init(0, 0, 10, 24), textBounds(text));

    const commands = [_]CanvasCommand{.{ .draw_text = text }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 1), render_plan.commandCount());
    try expectRect(geometry.RectF.init(0, 0, 10, 24), render_plan.commands[0].bounds);

    var pixels: [16 * 32 * 4]u8 = [_]u8{0} ** (16 * 32 * 4);
    const surface = try ReferenceRenderSurface.init(16, 32, &pixels);
    try surface.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(16, 32),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 1, 1);
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 1, 13);
}

test "text layout wraps words into deterministic line boxes" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world from zero",
    };

    var lines: [4]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word }, &lines);
    const layout = plan.layout;
    try std.testing.expectEqual(@as(FontId, 1), plan.key.font_id);
    try std.testing.expectEqual(@as(f32, 10), plan.key.size);
    try std.testing.expectEqual(@as(f32, 30), plan.key.max_width);
    try std.testing.expectEqual(@as(f32, 14), plan.key.line_height);
    try std.testing.expectEqual(TextWrap.word, plan.key.wrap);
    try std.testing.expectEqual(TextAlign.start, plan.key.alignment);
    try std.testing.expectEqual(text.text.len, plan.key.text_len);
    try std.testing.expectEqual(@as(usize, 0), plan.key.glyph_count);
    try std.testing.expect(plan.key.fingerprint != 0);
    try std.testing.expectEqual(@as(usize, 4), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(4, 10, 25, 14), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 34), layout.lines[1].baseline);
    try std.testing.expectEqual(@as(usize, 12), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_len);
    try std.testing.expectEqual(@as(usize, 17), layout.lines[3].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[3].text_len);
    try expectRect(geometry.RectF.init(4, 10, 25, 56), layout.bounds);
}

test "text layout aligns fallback and shaped line boxes" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hi",
    };

    var center_lines: [1]TextLine = undefined;
    const centered = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .alignment = .center }, &center_lines);
    try std.testing.expectEqual(TextAlign.center, centered.key.alignment);
    try expectRect(geometry.RectF.init(14, 10, 10, 14), centered.layout.lines[0].bounds);
    try expectRect(geometry.RectF.init(14, 10, 10, 14), centered.layout.bounds);

    var end_lines: [1]TextLine = undefined;
    const end = try layoutTextRun(text, .{ .max_width = 30, .line_height = 14, .alignment = .end }, &end_lines);
    try expectRect(geometry.RectF.init(24, 10, 10, 14), end.lines[0].bounds);

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 2, .x = 8, .y = 0, .advance = 4 },
    };
    var shaped_lines: [1]TextLine = undefined;
    const shaped = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .max_width = 20, .line_height = 14, .alignment = .center }, &shaped_lines);

    try expectRect(geometry.RectF.init(8, 10, 12, 14), shaped.lines[0].bounds);
    try expectRect(geometry.RectF.init(8, 10, 12, 14), shaped.bounds);
}

test "text layout maps caret selection and points across wrapped fallback lines" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world",
    };
    const options = TextLayoutOptions{ .max_width = 30, .line_height = 14, .wrap = .word };

    var caret_lines: [2]TextLine = undefined;
    try expectRect(geometry.RectF.init(29, 10, 1, 14), try layoutTextCaretRect(text, options, 5, &caret_lines));

    var selection_lines: [2]TextLine = undefined;
    var selection_rects: [2]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(3, 8), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqualDeep(TextRange.init(3, 5), rects[0].range);
    try expectRect(geometry.RectF.init(19, 10, 10, 14), rects[0].rect);
    try std.testing.expectEqualDeep(TextRange.init(6, 8), rects[1].range);
    try expectRect(geometry.RectF.init(4, 24, 10, 14), rects[1].rect);

    var point_lines: [2]TextLine = undefined;
    const offset = (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(16, 25), &point_lines)).?;
    try std.testing.expectEqual(@as(usize, 8), offset);

    var overflow_lines: [2]TextLine = undefined;
    var one_rect: [1]TextSelectionRect = undefined;
    try std.testing.expectError(error.TextSelectionRectListFull, layoutTextSelectionRects(text, options, TextRange.init(3, 8), &overflow_lines, &one_rect));
}

test "text layout maps caret selection and points across shaped glyph lines" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 2, .y = -3, .advance = 5 },
        .{ .id = 2, .x = 6, .y = 4, .advance = 4 },
    };
    const text = DrawText{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(10, 20),
        .color = Color.rgb8(255, 255, 255),
        .text = "AV",
        .glyphs = &glyphs,
    };
    const options = TextLayoutOptions{ .line_height = 12 };

    var caret_lines: [1]TextLine = undefined;
    try expectRect(geometry.RectF.init(14, 7, 1, 19.5), try layoutTextCaretRect(text, options, 1, &caret_lines));

    var selection_lines: [1]TextLine = undefined;
    var selection_rects: [1]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(1, 2), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try expectRect(geometry.RectF.init(14, 7, 4, 19.5), rects[0].rect);

    var point_lines: [1]TextLine = undefined;
    const offset = (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(13, 12), &point_lines)).?;
    try std.testing.expectEqual(@as(usize, 1), offset);

    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .font_id = text.font_id,
        .size = text.size,
        .origin = text.origin,
        .color = text.color,
        .text = text.text,
        .glyphs = text.glyphs,
        .text_layout = options,
    } }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var pixels: [24 * 32 * 4]u8 = [_]u8{0} ** (24 * 32 * 4);
    const surface = try ReferenceRenderSurface.init(24, 32, &pixels);
    try surface.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(24, 32),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 10, 8);
}

test "text layout measures utf8 scalars for fallback wrapping" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(2, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "éééé éé",
    };

    var lines: [3]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .max_width = 20, .line_height = 12, .wrap = .word }, &lines);
    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 8), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(2, 8, 20, 12), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 9), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[1].text_len);
    try expectRect(geometry.RectF.init(2, 20, 10, 12), layout.lines[1].bounds);
    try expectRect(geometry.RectF.init(2, 8, 20, 24), layout.bounds);

    var character_lines: [3]TextLine = undefined;
    const character_layout = try layoutTextRun(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "ééé",
    }, .{ .max_width = 10, .line_height = 12, .wrap = .character }, &character_lines);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), character_layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 4), character_layout.lines[0].text_len);
    try std.testing.expectEqual(@as(usize, 4), character_layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lines[1].text_len);
}

test "text layout cache plans upload retain and evict work" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world from zero",
    };

    var lines: [4]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word }, &lines);
    var entries: [1]TextLayoutCacheEntry = undefined;
    var actions: [1]TextLayoutCacheAction = undefined;
    const first = try plan.cachePlan(&.{}, 1, &entries, &actions);
    try std.testing.expectEqual(@as(usize, 1), first.entryCount());
    try std.testing.expectEqual(@as(usize, 1), first.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), first.retainCount());
    try std.testing.expectEqual(@as(usize, 0), first.evictCount());
    try std.testing.expectEqual(@as(usize, 4), first.entries[0].line_count);
    try std.testing.expectEqual(@as(u64, 1), first.entries[0].last_used_frame);
    try expectRect(geometry.RectF.init(4, 10, 25, 56), first.entries[0].bounds);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, first.actions[0].kind);

    var retained_entries: [1]TextLayoutCacheEntry = undefined;
    var retained_actions: [1]TextLayoutCacheAction = undefined;
    const retained = try plan.cachePlan(first.entries, 2, &retained_entries, &retained_actions);
    try std.testing.expectEqual(@as(usize, 1), retained.entryCount());
    try std.testing.expectEqual(@as(usize, 0), retained.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained.evictCount());
    try std.testing.expectEqual(@as(u64, 2), retained.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), retained.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 0), retained.actions[0].cache_index);

    var changed_lines: [4]TextLine = undefined;
    const changed_plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word, .alignment = .center }, &changed_lines);
    var changed_entries: [1]TextLayoutCacheEntry = undefined;
    var changed_actions: [2]TextLayoutCacheAction = undefined;
    const changed = try changed_plan.cachePlan(retained.entries, 3, &changed_entries, &changed_actions);
    try std.testing.expectEqual(@as(usize, 1), changed.entryCount());
    try std.testing.expectEqual(@as(usize, 1), changed.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed.evictCount());
    try std.testing.expectEqual(TextAlign.center, changed.entries[0].key.alignment);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, changed.actions[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), changed.actions[0].layout_index);
    try std.testing.expectEqual(TextLayoutCacheActionKind.evict, changed.actions[1].kind);
    try std.testing.expect(changed.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 0), changed.actions[1].cache_index);
}

test "display list text layout plan caches multiple text runs" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 10),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 28),
            .color = Color.rgb8(0, 0, 0),
            .text = "Beta",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [2]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{}, &plans, &lines);
    try std.testing.expectEqual(@as(usize, 2), plan_set.planCount());
    try std.testing.expectEqual(@as(usize, 2), plan_set.lineCount());
    try std.testing.expect(plan_set.plans[0].key.fingerprint != plan_set.plans[1].key.fingerprint);

    var entries: [2]TextLayoutCacheEntry = undefined;
    var actions: [2]TextLayoutCacheAction = undefined;
    const first = try plan_set.cachePlan(&.{}, 1, &entries, &actions);
    try std.testing.expectEqual(@as(usize, 2), first.uploadCount());
    try std.testing.expectEqual(@as(?usize, 0), first.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 1), first.actions[1].layout_index);

    var retained_entries: [2]TextLayoutCacheEntry = undefined;
    var retained_actions: [2]TextLayoutCacheAction = undefined;
    const retained = try plan_set.cachePlan(first.entries, 2, &retained_entries, &retained_actions);
    try std.testing.expectEqual(@as(usize, 2), retained.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained.evictCount());
}

test "text layout cache keeps recent unused layouts warm" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 10),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 28),
            .color = Color.rgb8(0, 0, 0),
            .text = "Beta",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [2]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{}, &plans, &lines);

    var first_entries: [2]TextLayoutCacheEntry = undefined;
    var first_actions: [2]TextLayoutCacheAction = undefined;
    const first = try plan_set.cachePlanWithRetention(&.{}, 1, 2, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first.uploadCount());

    const visible_plan_set = TextLayoutPlanSet{ .plans = plan_set.plans[0..1] };
    var warm_entries: [2]TextLayoutCacheEntry = undefined;
    var warm_actions: [2]TextLayoutCacheAction = undefined;
    const warm = try visible_plan_set.cachePlanWithRetention(first.entries, 2, 2, &warm_entries, &warm_actions);
    try std.testing.expectEqual(@as(usize, 2), warm.entryCount());
    try std.testing.expectEqual(@as(usize, 0), warm.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), warm.retainCount());
    try std.testing.expectEqual(@as(usize, 0), warm.evictCount());
    try std.testing.expectEqual(@as(u64, 2), warm.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), warm.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].cache_index);
    try std.testing.expect(warm.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 1), warm.actions[1].cache_index);

    var stale_entries: [2]TextLayoutCacheEntry = undefined;
    var stale_actions: [2]TextLayoutCacheAction = undefined;
    const stale = try visible_plan_set.cachePlanWithRetention(first.entries, 4, 2, &stale_entries, &stale_actions);
    try std.testing.expectEqual(@as(usize, 1), stale.entryCount());
    try std.testing.expectEqual(@as(usize, 1), stale.retainCount());
    try std.testing.expectEqual(@as(usize, 1), stale.evictCount());
    try std.testing.expectEqual(TextLayoutCacheActionKind.evict, stale.actions[1].kind);
    try std.testing.expect(stale.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 1), stale.actions[1].cache_index);
}

test "display list text layout plan honors per-run options" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(2, 18),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha beta",
            .text_layout = .{ .max_width = 30, .line_height = 14, .wrap = .word, .alignment = .end },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(2, 42),
            .color = Color.rgb8(0, 0, 0),
            .text = "Gamma",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [4]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{ .max_width = 80, .line_height = 20, .alignment = .center }, &plans, &lines);
    try std.testing.expectEqual(@as(usize, 2), plan_set.planCount());
    try std.testing.expectEqual(@as(f32, 30), plan_set.plans[0].key.max_width);
    try std.testing.expectEqual(@as(f32, 14), plan_set.plans[0].key.line_height);
    try std.testing.expectEqual(TextAlign.end, plan_set.plans[0].key.alignment);
    try std.testing.expectEqual(@as(f32, 80), plan_set.plans[1].key.max_width);
    try std.testing.expectEqual(@as(f32, 20), plan_set.plans[1].key.line_height);
    try std.testing.expectEqual(TextAlign.center, plan_set.plans[1].key.alignment);
    try std.testing.expect(plan_set.plans[0].key.fingerprint != plan_set.plans[1].key.fingerprint);
}

test "text layout cache reports capacity overflow" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello",
    };
    var lines: [1]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{}, &lines);

    var no_entries: [0]TextLayoutCacheEntry = .{};
    var actions: [1]TextLayoutCacheAction = undefined;
    try std.testing.expectError(error.TextLayoutCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]TextLayoutCacheEntry = undefined;
    var no_actions: [0]TextLayoutCacheAction = .{};
    try std.testing.expectError(error.TextLayoutCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "text layout handles newlines and shaped glyph runs" {
    const text = DrawText{
        .font_id = 1,
        .size = 12,
        .origin = geometry.PointF.init(0, 12),
        .color = Color.rgb8(0, 0, 0),
        .text = "One\nTwo",
    };
    var lines: [2]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .line_height = 16, .wrap = .none }, &lines);
    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[0].text_len);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 28), layout.lines[1].baseline);

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 9 },
        .{ .id = 2, .x = 9, .y = 0, .advance = 10 },
    };
    var shaped_lines: [1]TextLine = undefined;
    const shaped = try layoutTextRun(.{
        .font_id = 2,
        .size = 14,
        .origin = geometry.PointF.init(3, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .line_height = 20 }, &shaped_lines);
    try std.testing.expectEqual(@as(usize, 1), shaped.lineCount());
    try std.testing.expectEqual(@as(usize, 2), shaped.lines[0].glyph_len);
    try expectRect(geometry.RectF.init(3, 4, 19, 20), shaped.lines[0].bounds);
}

test "text layout bounds shaped glyph positions and vertical offsets" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 2, .y = -3, .advance = 5 },
        .{ .id = 2, .x = 6, .y = 4, .advance = 4 },
    };
    var lines: [1]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(10, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .line_height = 12 }, &lines);

    try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
    try expectRect(geometry.RectF.init(10, 7, 8, 19.5), layout.lines[0].bounds);
    try expectRect(geometry.RectF.init(10, 7, 8, 19.5), layout.bounds);
}

test "text layout wraps shaped glyph runs by glyph advances" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 2, .x = 8, .y = 0, .advance = 7 },
        .{ .id = 3, .x = 15, .y = 0, .advance = 6 },
        .{ .id = 4, .x = 21, .y = 0, .advance = 9 },
        .{ .id = 5, .x = 30, .y = 0, .advance = 5 },
    };
    var lines: [3]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 12,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "abcde",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 18, .wrap = .character }, &lines);

    try std.testing.expectEqual(@as(usize, 3), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(4, 8, 15, 18), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].glyph_len);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 38), layout.lines[1].baseline);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].glyph_start);
    try std.testing.expectEqual(@as(usize, 1), layout.lines[2].glyph_len);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 1), layout.lines[2].text_len);
    try expectRect(geometry.RectF.init(4, 8, 15, 54), layout.bounds);
}

test "text layout word-wraps shaped glyph runs at mapped spaces" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 5 },
        .{ .id = 2, .x = 5, .y = 0, .advance = 5 },
        .{ .id = 3, .x = 10, .y = 0, .advance = 5 },
        .{ .id = 4, .x = 15, .y = 0, .advance = 5 },
        .{ .id = 5, .x = 20, .y = 0, .advance = 5 },
        .{ .id = 6, .x = 25, .y = 0, .advance = 5 },
    };
    var lines: [2]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hi all",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 14, .wrap = .word }, &lines);

    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(0, 0, 10, 14), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].glyph_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].glyph_len);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_len);
    try expectRect(geometry.RectF.init(0, 14, 15, 14), layout.lines[1].bounds);
    try expectRect(geometry.RectF.init(0, 0, 15, 28), layout.bounds);
}

test "text layout keeps an empty line for shaped whitespace runs" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 5 },
        .{ .id = 2, .x = 5, .y = 0, .advance = 5 },
    };
    var lines: [1]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "  ",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 14, .wrap = .word }, &lines);

    try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(0, 0, 0, 14), layout.bounds);
}

test "text layout reports output overflow" {
    var lines: [0]TextLine = .{};
    try std.testing.expectError(error.TextLayoutLineListFull, layoutTextRun(.{
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello",
    }, .{}, &lines));
}

test "display list serializes deterministically" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(59, 130, 246) },
    };
    const glyphs = [_]Glyph{
        .{ .id = 42, .x = 12, .y = 28, .advance = 9 },
        .{ .id = 43, .x = 21, .y = 28, .advance = 8 },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.fillRect(.{
        .id = 10,
        .rect = geometry.RectF.init(0, 0, 360, 180),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(360, 180),
            .stops = &stops,
        } },
    });
    try builder.shadow(.{
        .id = 11,
        .rect = geometry.RectF.init(24, 24, 220, 96),
        .radius = Radius.all(16),
        .offset = .{ .dx = 0, .dy = 18 },
        .blur = 42,
        .spread = -8,
        .color = Color.rgba8(15, 23, 42, 48),
    });
    try builder.drawText(.{
        .id = 12,
        .font_id = 7,
        .size = 17,
        .origin = geometry.PointF.init(32, 52),
        .color = Color.rgb8(15, 23, 42),
        .text = "Hi",
        .glyphs = &glyphs,
    });

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try builder.displayList().writeJson(&writer);

    const expected =
        "{\"commands\":[{\"op\":\"fill_rect\",\"id\":10,\"rect\":[0,0,360,180],\"fill\":{\"kind\":\"linear_gradient\",\"start\":[0,0],\"end\":[360,180],\"stops\":[{\"offset\":0,\"color\":[1,1,1,1]},{\"offset\":1,\"color\":[0.23137255,0.50980395,0.9647059,1]}]}},{\"op\":\"shadow\",\"id\":11,\"rect\":[24,24,220,96],\"radius\":[16,16,16,16],\"offset\":[0,18],\"blur\":42,\"spread\":-8,\"color\":[0.05882353,0.09019608,0.16470589,0.1882353]},{\"op\":\"draw_text\",\"id\":12,\"font\":7,\"size\":17,\"origin\":[32,52],\"color\":[0.05882353,0.09019608,0.16470589,1],\"text\":\"Hi\",\"glyphs\":[{\"id\":42,\"x\":12,\"y\":28,\"advance\":9},{\"id\":43,\"x\":21,\"y\":28,\"advance\":8}]}]}";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "display list serializes per-run text layout options" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 3,
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Wrapped",
        .text_layout = .{ .max_width = 42, .line_height = 14, .wrap = .character, .alignment = .center },
    } }};

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DisplayList{ .commands = &commands }).writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"op\":\"draw_text\",\"id\":3,\"font\":1,\"size\":10,\"origin\":[4,20],\"color\":[0,0,0,1],\"text\":\"Wrapped\",\"glyphs\":[],\"layout\":{\"maxWidth\":42,\"lineHeight\":14,\"wrap\":\"character\",\"align\":\"center\"}}]}",
        writer.buffered(),
    );
}

fn expectRect(expected: geometry.RectF, actual: ?geometry.RectF) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualDeep(expected, actual.?);
}

fn expectPixelRgba8(expected: [4]u8, surface: ReferenceRenderSurface, x: usize, y: usize) !void {
    try std.testing.expectEqualDeep(expected, surface.pixelRgba8(x, y));
}

fn expectLayoutFrame(layout: WidgetLayoutTree, id: ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(expected, node.frame);
}

fn expectRouteEntry(entry: WidgetEventRouteEntry, phase: WidgetEventPhase, id: ObjectId) !void {
    try std.testing.expectEqual(phase, entry.phase);
    try std.testing.expectEqual(id, entry.id);
}

fn expectFillColor(expected: Color, actual: Fill) !void {
    switch (actual) {
        .color => |color| try std.testing.expectEqualDeep(expected, color),
        else => return error.TestUnexpectedResult,
    }
}
