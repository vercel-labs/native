const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");

pub const Error = error{
    DisplayListFull,
    DiffListFull,
    DuplicateObjectId,
    DuplicateWidgetId,
    GlyphAtlasListFull,
    RenderBatchListFull,
    RenderListFull,
    RenderResourceCacheListFull,
    RenderResourceListFull,
    TextLayoutLineListFull,
    TextEditBufferTooSmall,
    RenderStackOverflow,
    RenderStackUnderflow,
    WidgetDepthExceeded,
    WidgetEventRouteListFull,
    WidgetInvalidationListFull,
    WidgetLayoutListFull,
    WidgetSemanticsListFull,
};

pub const ObjectId = u64;
pub const ImageId = u64;
pub const FontId = u64;

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

pub const DrawImage = struct {
    id: ObjectId = 0,
    image_id: ImageId,
    src: ?geometry.RectF = null,
    dst: geometry.RectF,
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
};

pub const Glyph = struct {
    id: u32,
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
};

pub const DrawText = struct {
    id: ObjectId = 0,
    font_id: FontId = 0,
    size: f32,
    origin: geometry.PointF,
    color: Color,
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
};

pub const TextWrap = enum {
    none,
    word,
    character,
};

pub const TextLayoutOptions = struct {
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
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
    bounds: geometry.RectF,
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

pub const CanvasFrameOptions = struct {
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    full_repaint: bool = false,
    previous_resource_cache: []const RenderResourceCacheEntry = &.{},
};

pub const CanvasFrameStorage = struct {
    render_commands: []RenderCommand,
    render_batches: []RenderBatch,
    resources: []RenderResource,
    resource_cache_entries: []RenderResourceCacheEntry,
    resource_cache_actions: []RenderResourceCacheAction,
    glyph_atlas_entries: []GlyphAtlasEntry,
    changes: []DiffChange,
};

pub const CanvasFrameDiagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
    batch_count: usize = 0,
    resource_count: usize = 0,
    resource_upload_count: usize = 0,
    resource_retain_count: usize = 0,
    resource_evict_count: usize = 0,
    glyph_atlas_entry_count: usize = 0,
    change_count: usize = 0,
    full_repaint: bool = false,
    requires_render: bool = false,
    dirty_bounds: ?geometry.RectF = null,
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
    resource_plan: RenderResourcePlan = .{},
    resource_cache_plan: RenderResourceCachePlan = .{},
    glyph_atlas_plan: GlyphAtlasPlan = .{},
    changes: []const DiffChange = &.{},
    dirty_bounds: ?geometry.RectF = null,

    pub fn requiresRender(self: CanvasFrame) bool {
        return self.full_repaint or self.dirty_bounds != null;
    }

    pub fn diagnostics(self: CanvasFrame) CanvasFrameDiagnostics {
        return .{
            .frame_index = self.frame_index,
            .command_count = self.render_plan.commandCount(),
            .batch_count = self.batch_plan.batchCount(),
            .resource_count = self.resource_plan.resourceCount(),
            .resource_upload_count = self.resource_cache_plan.uploadCount(),
            .resource_retain_count = self.resource_cache_plan.retainCount(),
            .resource_evict_count = self.resource_cache_plan.evictCount(),
            .glyph_atlas_entry_count = self.glyph_atlas_plan.entryCount(),
            .change_count = self.changes.len,
            .full_repaint = self.full_repaint,
            .requires_render = self.requiresRender(),
            .dirty_bounds = self.dirty_bounds,
        };
    }
};

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

pub const MotionTokens = struct {
    fast_ms: u32 = 120,
    normal_ms: u32 = 180,
    slow_ms: u32 = 260,
    easing: Easing = .standard,
    spring: SpringToken = .{},
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
    layer: LayerTokens = .{},
    density: Density = .regular,
};

pub const WidgetKind = enum {
    stack,
    row,
    column,
    grid,
    scroll_view,
    list,
    panel,
    popover,
    menu_surface,
    text,
    icon,
    button,
    icon_button,
    text_field,
    tooltip,
    menu_item,
    list_item,
    segmented_control,
    checkbox,
    toggle,
    slider,
    progress,
};

pub const WidgetState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    disabled: bool = false,
    selected: bool = false,
};

pub const WidgetLayoutStyle = struct {
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    grow: f32 = 0,
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
    tab,
    checkbox,
    switch_control,
    slider,
    progressbar,
};

pub const WidgetSemantics = struct {
    role: WidgetRole = .none,
    label: []const u8 = "",
    value: ?f32 = null,
    hidden: bool = false,
    focusable: bool = false,
};

pub const Widget = struct {
    id: ObjectId = 0,
    kind: WidgetKind,
    frame: geometry.RectF = .{},
    text: []const u8 = "",
    text_selection: ?TextSelection = null,
    text_composition: ?TextRange = null,
    value: f32 = 0,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    semantics: WidgetSemantics = .{},
    children: []const Widget = &.{},
};

pub const max_widget_depth: usize = 32;

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
};

pub const WidgetKeyboardEvent = struct {
    phase: WidgetKeyboardPhase,
    focused_id: ?ObjectId = null,
    key: []const u8 = "",
    text: []const u8 = "",
    modifiers: WidgetKeyboardModifiers = .{},
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
};

pub const WidgetFocusTarget = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    index: usize,
    state: WidgetState,
};

pub const WidgetSemanticsNode = struct {
    id: ObjectId,
    role: WidgetRole,
    label: []const u8,
    value: ?f32 = null,
    bounds: geometry.RectF,
    state: WidgetState,
    focusable: bool = false,
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
        return hitTestWidgetLayout(self, point);
    }

    pub fn routePointerEvent(self: WidgetLayoutTree, event: WidgetPointerEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetPointerEvent(self, event, output);
    }

    pub fn routeKeyboardEvent(self: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
        return routeWidgetKeyboardEvent(self, event, output);
    }

    pub fn focusTarget(self: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
        return focusWidgetTarget(self, current_id, direction);
    }

    pub fn collectSemantics(self: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
        return collectWidgetSemantics(self, output);
    }

    pub fn emitDisplayList(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens) Error!void {
        return emitWidgetLayout(builder, self, tokens);
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

    pub fn glyphAtlasPlan(self: DisplayList, output: []GlyphAtlasEntry) Error!GlyphAtlasPlan {
        var planner = GlyphAtlasPlanner.init(output);
        return planner.build(self);
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
    var len: usize = 0;
    var bounds: ?geometry.RectF = null;
    if (text.glyphs.len > 0) {
        try appendTextLine(output, &len, text, 0, text.text.len, 0, text.glyphs.len, lineHeight(text, options), &bounds);
        return .{ .lines = output[0..len], .bounds = bounds };
    }

    var start: usize = 0;
    while (start < text.text.len) {
        const end = nextTextLineEnd(text.text, start, text.size, options);
        try appendTextLine(output, &len, text, start, end - start, start, end - start, lineHeight(text, options), &bounds);
        start = end;
        if (start < text.text.len and text.text[start] == '\n') start += 1;
        while (options.wrap == .word and start < text.text.len and isTextBreakByte(text.text[start])) start += 1;
    }
    if (text.text.len == 0) {
        try appendTextLine(output, &len, text, 0, 0, 0, 0, lineHeight(text, options), &bounds);
    }
    return .{ .lines = output[0..len], .bounds = bounds };
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

pub fn buildCanvasFrame(previous: ?DisplayList, next: DisplayList, options: CanvasFrameOptions, storage: CanvasFrameStorage) Error!CanvasFrame {
    const render_plan = try next.renderPlan(storage.render_commands);
    const batch_plan = try render_plan.batchPlan(storage.render_batches);
    const resource_plan = try next.resourcePlan(storage.resources);
    const resource_cache_plan = try resource_plan.cachePlan(
        options.previous_resource_cache,
        options.frame_index,
        storage.resource_cache_entries,
        storage.resource_cache_actions,
    );
    const glyph_atlas_plan = try next.glyphAtlasPlan(storage.glyph_atlas_entries);

    const full_repaint = options.full_repaint or previous == null;
    var changes: []const DiffChange = storage.changes[0..0];
    var dirty_bounds: ?geometry.RectF = null;

    if (full_repaint) {
        dirty_bounds = fullRepaintBounds(options.surface_size, render_plan.bounds);
    } else {
        changes = try DisplayList.diff(previous.?, next, storage.changes);
        dirty_bounds = clippedDirtyBounds(dirtyBoundsFromChanges(changes), options.surface_size);
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
        .resource_plan = resource_plan,
        .resource_cache_plan = resource_cache_plan,
        .glyph_atlas_plan = glyph_atlas_plan,
        .changes = changes,
        .dirty_bounds = dirty_bounds,
    };
}

pub fn emitWidgetLayout(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens) Error!void {
    var clip_stack_depths: [max_widget_depth]usize = undefined;
    var clip_stack_len: usize = 0;

    for (layout.nodes) |node| {
        const widget = widgetWithFrame(node.widget, node.frame);
        while (clip_stack_len > 0 and node.depth <= clip_stack_depths[clip_stack_len - 1]) {
            try builder.popClip();
            clip_stack_len -= 1;
        }
        switch (widget.kind) {
            .stack, .row, .column, .grid, .list => {},
            .scroll_view => {
                if (clip_stack_len >= clip_stack_depths.len) return error.RenderStackOverflow;
                try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
                clip_stack_depths[clip_stack_len] = node.depth;
                clip_stack_len += 1;
            },
            .panel => try emitPanelWidgetChrome(builder, widget, tokens),
            .popover => try emitPopoverWidgetChrome(builder, widget, tokens),
            .menu_surface => try emitMenuSurfaceWidgetChrome(builder, widget, tokens),
            .text => try emitTextWidget(builder, widget, tokens),
            .icon => try emitIconWidget(builder, widget, tokens),
            .button => try emitButtonWidget(builder, widget, tokens),
            .icon_button => try emitIconButtonWidget(builder, widget, tokens),
            .text_field => try emitTextFieldWidget(builder, widget, tokens),
            .tooltip => try emitTooltipWidget(builder, widget, tokens),
            .menu_item => try emitMenuItemWidget(builder, widget, tokens),
            .list_item => try emitListItemWidget(builder, widget, tokens),
            .segmented_control => try emitSegmentedControlWidget(builder, widget, tokens),
            .checkbox => try emitCheckboxWidget(builder, widget, tokens),
            .toggle => try emitToggleWidget(builder, widget, tokens),
            .slider => try emitSliderWidget(builder, widget, tokens),
            .progress => try emitProgressWidget(builder, widget, tokens),
        }
    }
    while (clip_stack_len > 0) {
        try builder.popClip();
        clip_stack_len -= 1;
    }
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
    return hash;
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
        hash = resourceHashF32(hash, glyph.x);
        hash = resourceHashF32(hash, glyph.y);
        hash = resourceHashF32(hash, glyph.advance);
    }
    return hash;
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
                    .font_id = text.font_id,
                    .glyph_id = glyph.id,
                    .size = text.size,
                    .subpixel_x = subpixelBucket(text.origin.x + glyph.x),
                    .subpixel_y = subpixelBucket(text.origin.y + glyph.y),
                };
                try self.appendUnique(key, command_index, glyph_index);
            }
            return;
        }

        for (text.text, 0..) |byte, byte_index| {
            const key = GlyphAtlasKey{
                .font_id = text.font_id,
                .glyph_id = byte,
                .size = text.size,
                .subpixel_x = subpixelBucket(text.origin.x + @as(f32, @floatFromInt(byte_index)) * text.size * 0.5),
                .subpixel_y = subpixelBucket(text.origin.y),
            };
            try self.appendUnique(key, command_index, byte_index);
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

fn emitWidgetDepth(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;

    switch (widget.kind) {
        .stack, .row, .column, .grid, .list => try emitWidgetChildren(builder, widget.children, tokens, depth),
        .scroll_view => try emitScrollViewWidget(builder, widget, tokens, depth),
        .panel => try emitPanelWidget(builder, widget, tokens, depth),
        .popover => try emitPopoverWidget(builder, widget, tokens, depth),
        .menu_surface => try emitMenuSurfaceWidget(builder, widget, tokens, depth),
        .text => try emitTextWidget(builder, widget, tokens),
        .icon => try emitIconWidget(builder, widget, tokens),
        .button => try emitButtonWidget(builder, widget, tokens),
        .icon_button => try emitIconButtonWidget(builder, widget, tokens),
        .text_field => try emitTextFieldWidget(builder, widget, tokens),
        .tooltip => try emitTooltipWidget(builder, widget, tokens),
        .menu_item => try emitMenuItemWidget(builder, widget, tokens),
        .list_item => try emitListItemWidget(builder, widget, tokens),
        .segmented_control => try emitSegmentedControlWidget(builder, widget, tokens),
        .checkbox => try emitCheckboxWidget(builder, widget, tokens),
        .toggle => try emitToggleWidget(builder, widget, tokens),
        .slider => try emitSliderWidget(builder, widget, tokens),
        .progress => try emitProgressWidget(builder, widget, tokens),
    }
}

fn emitWidgetChildren(builder: *Builder, children: []const Widget, tokens: DesignTokens, depth: usize) Error!void {
    for (children) |child| {
        try emitWidgetDepth(builder, child, tokens, depth + 1);
    }
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPanelWidgetChrome(builder, widget, tokens);
    try emitWidgetChildren(builder, widget.children, tokens, depth);
}

fn emitPopoverWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPopoverWidgetChrome(builder, widget, tokens);
    try emitWidgetChildren(builder, widget.children, tokens, depth);
}

fn emitMenuSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitMenuSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetChildren(builder, widget.children, tokens, depth);
}

fn emitScrollViewWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    try builder.popClip();
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
        .origin = textOrigin(widget.frame, tokens.typography.button_size, tokens.spacing.md),
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
    const text_size = tokens.typography.body_size;
    const origin = textOrigin(widget.frame, text_size, tokens.spacing.md);
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
            try builder.fillRoundedRect(.{
                .id = widgetPartId(widget.id, 3),
                .rect = textRangeInlineRect(widget.text, widget.frame, range, text_size, tokens.spacing.md),
                .radius = Radius.all(tokens.radius.sm),
                .fill = .{ .color = textSelectionFillColor(tokens) },
            });
        }
    }
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, if (has_text_affordances) 4 else 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = origin,
            .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
            .text = widget.text,
        });
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            const rect = textRangeInlineRect(widget.text, widget.frame, range, text_size, tokens.spacing.md);
            const y = rect.y + rect.height - 1;
            try builder.drawLine(.{
                .id = widgetPartId(widget.id, 5),
                .from = geometry.PointF.init(rect.x, y),
                .to = geometry.PointF.init(rect.x + rect.width, y),
                .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = 1 },
            });
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                const x = origin.x + estimateTextOffsetX(widget.text, range.start, text_size);
                try builder.drawLine(.{
                    .id = widgetPartId(widget.id, 6),
                    .from = geometry.PointF.init(x, origin.y - text_size),
                    .to = geometry.PointF.init(x, origin.y + 2),
                    .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = tokens.stroke.regular },
                });
            }
        }
    }
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
            .origin = textOrigin(widget.frame, tokens.typography.label_size, tokens.spacing.sm),
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
        .origin = textOrigin(widget.frame, tokens.typography.body_size, tokens.spacing.md),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
    });
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
        .origin = textOrigin(widget.frame, tokens.typography.label_size, tokens.spacing.md),
        .color = if (selected) tokens.colors.accent_text else tokens.colors.text,
        .text = widget.text,
    });
}

fn emitCheckboxWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const box_size = @min(@max(14, widget.frame.height * 0.55), 20);
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
    try emitControlLabel(builder, widget, tokens, box.x + box.width + tokens.spacing.sm, 6);
}

fn emitToggleWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = booleanControlSelected(widget);
    const track_width = @min(widget.frame.width, @max(36, widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, 24);
    const track = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    );
    const track_radius = Radius.all(track.height * 0.5);
    const knob_size = @max(0, track.height - 4);
    const knob_x = if (selected)
        track.x + track.width - knob_size - 2
    else
        track.x + 2;
    const knob = geometry.RectF.init(knob_x, track.y + 2, knob_size, knob_size);

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
    try emitControlLabel(builder, widget, tokens, track.x + track.width + tokens.spacing.sm, 5);
}

fn emitSliderWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const value = std.math.clamp(widget.value, 0, 1);
    const track_height: f32 = 4;
    const track = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        widget.frame.width,
        track_height,
    );
    const active = geometry.RectF.init(track.x, track.y, track.width * value, track.height);
    const knob_size = @min(@max(14, widget.frame.height * 0.55), 20);
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
    const width = estimateTextWidth(text, size);
    return geometry.PointF.init(
        frame.x + @max(0, (frame.width - width) * 0.5),
        frame.y + @max(size, (frame.height + size * 0.5) * 0.5),
    );
}

fn iconGlyphSize(widget: Widget, tokens: DesignTokens) f32 {
    if (widget.frame.height > 0) return @min(@max(12, widget.frame.height * 0.48), @max(12, tokens.typography.title_size));
    return tokens.typography.button_size;
}

fn widgetTextSelectionRange(widget: Widget) ?TextRange {
    if (widget.kind != .text_field) return null;
    if (widget.text_selection) |selection| return snapTextRange(widget.text, selection.range(widget.text.len));
    return null;
}

fn widgetTextCompositionRange(widget: Widget) ?TextRange {
    if (widget.kind != .text_field) return null;
    if (widget.text_composition) |range| return snapTextRange(widget.text, range);
    return null;
}

fn textRangeInlineRect(text: []const u8, frame: geometry.RectF, range: TextRange, size: f32, inset: f32) geometry.RectF {
    const normalized = snapTextRange(text, range);
    const origin = textOrigin(frame, size, inset);
    const start_x = origin.x + estimateTextOffsetX(text, normalized.start, size);
    const end_x = origin.x + estimateTextOffsetX(text, normalized.end, size);
    return geometry.RectF.init(
        start_x,
        origin.y - size,
        @max(1, end_x - start_x),
        size * 1.25,
    );
}

fn estimateTextOffsetX(text: []const u8, offset: usize, size: f32) f32 {
    const target = snapTextOffset(text, offset);
    var cursor: usize = 0;
    var width: f32 = 0;
    while (cursor < target) {
        width += size * 0.5;
        cursor = nextTextOffset(text, cursor);
    }
    return width;
}

fn textSelectionFillColor(tokens: DesignTokens) Color {
    return Color.rgba(
        tokens.colors.focus_ring.r,
        tokens.colors.focus_ring.g,
        tokens.colors.focus_ring.b,
        0.18,
    );
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
        .row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout.gap),
        .column => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout.gap),
        .grid => try layoutGridChildren(widget.children, content, index, depth, output, len, widget.layout.gap, widget.layout.columns),
        .scroll_view => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout)
        else
            try layoutScrollChildren(widget.children, content, index, depth, output, len, widget.value),
        .list => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout.gap),
        .menu_surface => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout.gap),
        .stack, .panel, .popover => {
            for (widget.children) |child| {
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len);
            }
        },
        .text, .icon, .button, .icon_button, .text_field, .tooltip, .menu_item, .list_item, .segmented_control, .checkbox, .toggle, .slider, .progress => {},
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
    gap: f32,
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
    const clamped_gap = nonNegative(gap);
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
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    };

    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            @max(minMainExtent(child, axis), remaining * grow / grow_total)
        else
            preferredMainExtent(child, axis);
        const cross = preferredCrossExtent(child, axis, cross_extent);
        const child_frame = switch (axis) {
            .horizontal => geometry.RectF.init(cursor, content.y + child.frame.y, main_extent, cross),
            .vertical => geometry.RectF.init(content.x + child.frame.x, cursor, cross, main_extent),
        };
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len);
        cursor += main_extent + clamped_gap;
    }
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

fn hitTestWidgetLayout(layout: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = layout.nodes[index];
        if (!isHitTarget(node.widget)) continue;
        if (!node.frame.normalized().containsPoint(point)) continue;
        if (!isPointVisibleInWidgetAncestors(layout, index, point)) continue;
        return .{
            .id = node.widget.id,
            .kind = node.widget.kind,
            .bounds = node.frame,
            .depth = node.depth,
            .index = index,
            .state = node.widget.state,
        };
    }
    return null;
}

fn isPointVisibleInWidgetAncestors(layout: WidgetLayoutTree, node_index: usize, point: geometry.PointF) bool {
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (parent.widget.kind == .scroll_view and !parent.frame.normalized().containsPoint(point)) return false;
        current = parent.parent_index;
    }
    return true;
}

fn routeWidgetPointerEvent(layout: WidgetLayoutTree, event: WidgetPointerEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target = hitTestWidgetLayout(layout, event.point) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

fn routeWidgetKeyboardEvent(layout: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
    const focused_id = event.focused_id orelse return .{ .entries = output[0..0] };
    const target_index = widgetIndexById(layout, focused_id) orelse return .{ .entries = output[0..0] };
    const target = focusTargetFromNode(layout.nodes[target_index], target_index) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
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
    };
}

fn focusForward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index: usize = if (current_index) |value| value + 1 else 0;
    while (index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromNode(layout.nodes[index], index)) |target| return target;
    }
    index = 0;
    const stop = current_index orelse layout.nodes.len;
    while (index < stop and index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromNode(layout.nodes[index], index)) |target| return target;
    }
    return null;
}

fn focusBackward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index = current_index orelse layout.nodes.len;
    while (index > 0) {
        index -= 1;
        if (focusTargetFromNode(layout.nodes[index], index)) |target| return target;
    }
    index = layout.nodes.len;
    const stop = if (current_index) |value| value + 1 else 0;
    while (index > stop) {
        index -= 1;
        if (focusTargetFromNode(layout.nodes[index], index)) |target| return target;
    }
    return null;
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

fn collectWidgetSemantics(layout: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
    var len: usize = 0;
    var semantic_stack: [max_widget_depth]?usize = [_]?usize{null} ** max_widget_depth;

    for (layout.nodes) |node| {
        if (node.depth >= max_widget_depth) return error.WidgetDepthExceeded;
        var cursor = node.depth + 1;
        while (cursor < semantic_stack.len) : (cursor += 1) {
            semantic_stack[cursor] = null;
        }

        const role = semanticRole(node.widget);
        if (node.widget.semantics.hidden or role == .none or node.widget.id == 0) continue;
        if (len >= output.len) return error.WidgetSemanticsListFull;

        const parent_index = nearestSemanticParent(semantic_stack[0..node.depth]);
        output[len] = .{
            .id = node.widget.id,
            .role = role,
            .label = semanticLabel(node.widget),
            .value = semanticValue(node.widget),
            .bounds = node.frame,
            .state = node.widget.state,
            .focusable = node.widget.semantics.focusable or defaultFocusable(node.widget),
            .text_selection = widgetTextSelectionRange(node.widget),
            .text_composition = widgetTextCompositionRange(node.widget),
            .parent_index = parent_index,
        };
        semantic_stack[node.depth] = len;
        len += 1;
    }

    return output[0..len];
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
        .popover => .dialog,
        .menu_surface => .menu,
        .list => .list,
        .text => .text,
        .icon => .image,
        .button => .button,
        .icon_button => .button,
        .text_field => .textbox,
        .tooltip => .tooltip,
        .menu_item => .menuitem,
        .list_item => .listitem,
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
        .list_item, .segmented_control => if (widget.state.selected or widget.value >= 0.5) 1 else 0,
        .checkbox, .toggle => if (booleanControlSelected(widget)) 1 else 0,
        .slider, .progress => std.math.clamp(widget.value, 0, 1),
        else => null,
    };
}

fn defaultFocusable(widget: Widget) bool {
    return switch (widget.kind) {
        .button, .icon_button, .text_field, .menu_item, .list_item, .segmented_control, .checkbox, .toggle, .slider => !widget.state.disabled,
        else => false,
    };
}

fn isFocusable(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or defaultFocusable(widget);
}

fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .grid, .list, .stack, .tooltip, .icon => false,
        .scroll_view, .panel, .popover, .menu_surface, .text, .button, .icon_button, .text_field, .menu_item, .list_item, .segmented_control, .checkbox, .toggle, .slider, .progress => true,
    };
}

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
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
                .dirty_bounds = previous_node.frame,
                .layout_dirty = true,
                .paint_dirty = true,
                .semantics_dirty = true,
            });
            continue;
        };

        const change = widgetChange(previous_node, next_ref.node, previous_index, next_ref.index);
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
                .dirty_bounds = next_node.frame,
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
        !optionalTextSelectionsEqual(previous.widget.text_selection, next.widget.text_selection) or
        !optionalTextRangesEqual(previous.widget.text_composition, next.widget.text_composition);
    const state_dirty = !widgetStatesEqual(previous.widget.state, next.widget.state);
    const semantics_dirty =
        layout_dirty or
        content_dirty or
        state_dirty or
        !widgetSemanticsEqual(previous.widget.semantics, next.widget.semantics);
    const paint_dirty = layout_dirty or content_dirty or state_dirty;

    return .{
        .kind = .changed,
        .id = previous.widget.id,
        .previous_index = previous_index,
        .next_index = next_index,
        .dirty_bounds = if (layout_dirty or paint_dirty)
            unionOptionalBounds(previous.frame, next.frame)
        else
            null,
        .layout_dirty = layout_dirty,
        .paint_dirty = paint_dirty,
        .semantics_dirty = semantics_dirty,
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
        a.hidden == b.hidden and
        a.focusable == b.focusable;
}

fn glyphAtlasKeysEqual(a: GlyphAtlasKey, b: GlyphAtlasKey) bool {
    return a.font_id == b.font_id and
        a.glyph_id == b.glyph_id and
        a.size == b.size and
        a.subpixel_x == b.subpixel_x and
        a.subpixel_y == b.subpixel_y;
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

fn shadowBounds(value: Shadow) geometry.RectF {
    const spread = nonNegative(@abs(value.spread));
    const blur_radius = nonNegative(value.blur);
    return value.rect
        .normalized()
        .translate(value.offset)
        .inflate(geometry.InsetsF.all(spread + blur_radius));
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

    var min_x = value.origin.x;
    var max_x = value.origin.x;
    if (value.glyphs.len > 0) {
        min_x = value.origin.x + value.glyphs[0].x;
        max_x = min_x + estimatedGlyphAdvance(value.glyphs[0], value.size);
        for (value.glyphs[1..]) |glyph| {
            const glyph_x = value.origin.x + glyph.x;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, value.size));
        }
    } else {
        max_x = value.origin.x + @as(f32, @floatFromInt(value.text.len)) * value.size * 0.5;
    }

    return geometry.RectF.init(
        min_x,
        value.origin.y - value.size,
        @max(value.size * 0.25, max_x - min_x),
        value.size * 1.25,
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
    while (index < text.len) : (index += 1) {
        if (text[index] == '\n') return index;
        const next_width = estimateTextWidth(text[start .. index + 1], size);
        if (isTextBreakByte(text[index])) last_break = index + 1;
        if (next_width > max_width) {
            if (index == start) return index + 1;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return trimTrailingTextBreak(text, start, break_index);
                }
            }
            return index;
        }
    }
    return text.len;
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
    bounds: *?geometry.RectF,
) Error!void {
    if (len.* >= output.len) return error.TextLayoutLineListFull;
    const baseline = text.origin.y + @as(f32, @floatFromInt(len.*)) * line_height;
    const line_bounds = geometry.RectF.init(
        text.origin.x,
        baseline - text.size,
        textLineWidth(text, text_start, text_len, glyph_start, glyph_len),
        line_height,
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

fn lineHeight(text: DrawText, options: TextLayoutOptions) f32 {
    return if (options.line_height > 0) options.line_height else text.size * 1.25;
}

fn textLineWidth(text: DrawText, text_start: usize, text_len: usize, glyph_start: usize, glyph_len: usize) f32 {
    if (glyph_len > 0 and glyph_start < text.glyphs.len) {
        const glyphs = text.glyphs[glyph_start..@min(text.glyphs.len, glyph_start + glyph_len)];
        var width: f32 = 0;
        for (glyphs) |glyph| width += estimatedGlyphAdvance(glyph, text.size);
        return width;
    }
    return estimateTextWidth(text.text[text_start..@min(text.text.len, text_start + text_len)], text.size);
}

fn estimateTextWidth(text: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * size * 0.5;
}

fn isTextBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
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
        a.fit == b.fit;
}

fn drawTextsEqual(a: DrawText, b: DrawText) bool {
    return a.id == b.id and
        a.font_id == b.font_id and
        a.size == b.size and
        pointsEqual(a.origin, b.origin) and
        colorsEqual(a.color, b.color) and
        std.mem.eql(u8, a.text, b.text) and
        glyphsEqual(a.glyphs, b.glyphs);
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
        if (left.id != right.id or left.x != right.x or left.y != right.y or left.advance != right.advance) return false;
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
        try writer.print("{{\"id\":{d},\"x\":{d},\"y\":{d},\"advance\":{d}}}", .{ glyph.id, glyph.x, glyph.y, glyph.advance });
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

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 11), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 120, 60), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[display_list.commands.len - 1] == .pop_clip);

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

    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0.75), semantics[2].value);
    try expectRect(geometry.RectF.init(10, 52, 160, 8), semantics[2].bounds);
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
    try std.testing.expectEqual(WidgetRole.switch_control, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
    try std.testing.expectEqual(WidgetRole.slider, semantics[3].role);
    try std.testing.expectEqual(@as(?f32, 0.35), semantics[3].value);
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
        .draw_text => |text| try std.testing.expectEqualStrings("abcdef", text.text),
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
    try std.testing.expectEqual(WidgetRole.listitem, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[2].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].parent_index);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
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
    try expectRect(geometry.RectF.init(10, 10, 110, 30), invalidations[0].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.removed, invalidations[1].kind);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[1].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 8), invalidations[1].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.added, invalidations[2].kind);
    try std.testing.expectEqual(@as(ObjectId, 4), invalidations[2].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 20), invalidations[2].dirty_bounds);
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

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var pressed_nodes: [2]WidgetLayoutNode = undefined;
    var semantic_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const pressed = try layoutWidgetTree(.{ .kind = .stack, .children = &pressed_child }, geometry.RectF.init(0, 0, 140, 80), &pressed_nodes);
    const semantic = try layoutWidgetTree(.{ .kind = .stack, .children = &semantic_child }, geometry.RectF.init(0, 0, 140, 80), &semantic_nodes);

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
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 10, 30, 20), plan.commands[0].bounds);

    try std.testing.expectEqual(@as(?ObjectId, 3), plan.commands[1].id);
    try std.testing.expectEqual(@as(f32, 1), plan.commands[1].opacity);
    try std.testing.expect(plan.commands[1].clip == null);
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

test "glyph atlas plan falls back to byte glyph keys" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 3,
        .size = 12,
        .origin = geometry.PointF.init(0.5, 8.75),
        .color = Color.rgb8(15, 23, 42),
        .text = "ABC",
    } }};

    var entries: [3]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 3), plan.entryCount());
    try std.testing.expectEqual(@as(u32, 'A'), plan.entries[0].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[0].key.subpixel_x);
    try std.testing.expectEqual(@as(u8, 3), plan.entries[0].key.subpixel_y);
    try std.testing.expectEqual(@as(u32, 'B'), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(u32, 'C'), plan.entries[2].key.glyph_id);
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
    var resources: [2]RenderResource = undefined;
    var resource_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]RenderResourceCacheAction = undefined;
    var glyphs: [2]GlyphAtlasEntry = undefined;
    var changes: [2]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 7,
        .timestamp_ns = 88,
        .surface_size = geometry.SizeF.init(320, 200),
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
    try std.testing.expectEqual(@as(usize, 2), frame.resource_plan.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[1].kind);
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), frame.dirty_bounds);

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(u64, 7), diagnostics.frame_index);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.command_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.batch_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_entry_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.change_count);
    try std.testing.expect(diagnostics.full_repaint);
    try std.testing.expect(diagnostics.requires_render);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), diagnostics.dirty_bounds);
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

    const diagnostics = next_frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_evict_count);
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

test "text layout wraps words into deterministic line boxes" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world from zero",
    };

    var lines: [4]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .max_width = 30, .line_height = 14, .wrap = .word }, &lines);
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

fn expectRect(expected: geometry.RectF, actual: ?geometry.RectF) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualDeep(expected, actual.?);
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
