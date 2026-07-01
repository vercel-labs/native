const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const hash_model = @import("hash.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");
const equality_model = @import("equality.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const CanvasCommand = canvas.CanvasCommand;
const DisplayList = canvas.DisplayList;
const ReferenceImage = canvas.ReferenceImage;
const Affine = drawing_model.Affine;
const LinearGradient = drawing_model.LinearGradient;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const Radius = drawing_model.Radius;
const DrawImage = drawing_model.DrawImage;
const Shadow = drawing_model.Shadow;
const Blur = drawing_model.Blur;
const PathElement = drawing_model.PathElement;
const Glyph = text_model.Glyph;
const DrawText = text_model.DrawText;
const TextLayoutOptions = text_model.TextLayoutOptions;
const Easing = token_model.Easing;
const SpringToken = token_model.SpringToken;
const shadowBounds = drawing_model.shadowBounds;
const textBounds = text_model.textBounds;

const optionalRectsEqual = equality_model.optionalRectsEqual;

pub const max_render_state_stack: usize = 32;
const path_geometry_curve_segments: usize = 12;
const resourceHashTag = hash_model.resourceHashTag;
const resourceHashBytes = hash_model.resourceHashBytes;
const resourceHashU8 = hash_model.resourceHashU8;
const resourceHashU32 = hash_model.resourceHashU32;
const resourceHashU64 = hash_model.resourceHashU64;
const resourceHashUsize = hash_model.resourceHashUsize;
const resourceHashEnum = hash_model.resourceHashEnum;
const resourceHashF32 = hash_model.resourceHashF32;
const resourceHashPoint = hash_model.resourceHashPoint;
const resourceHashRect = hash_model.resourceHashRect;
const resourceHashOptionalRect = hash_model.resourceHashOptionalRect;
const resourceHashOptionalObjectId = hash_model.resourceHashOptionalObjectId;
const resourceHashAffine = hash_model.resourceHashAffine;
const resourceHashRadius = hash_model.resourceHashRadius;
const resourceHashColor = hash_model.resourceHashColor;
const resourceHashPath = hash_model.resourceHashPath;

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

pub fn motionProgress(animation: CanvasRenderAnimation, timestamp_ns: u64) f32 {
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

    fn pushClip(self: *RenderPlanner, clip: drawing_model.Clip) Error!void {
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

pub const PathGeometryCounts = struct {
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
};

pub fn analyzePathGeometry(elements: []const PathElement, kind: RenderPathGeometryKind) PathGeometryCounts {
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
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
            },
            .cubic_to => {
                if (!has_current) continue;
                counts.cubic_segment_count += 1;
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
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

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |left| {
        if (b) |right| return left.normalized().unionWith(right.normalized());
        return left;
    }
    return b;
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

fn renderPathGeometryFingerprint(command: RenderCommand, kind: RenderPathGeometryKind, elements: []const PathElement, stroke_width: f32) u64 {
    var hash = resourceHashTag("path_geometry");
    hash = resourceHashBytes(hash, @tagName(kind));
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashAffine(hash, command.transform);
    hash = resourceHashPath(hash, elements);
    hash = resourceHashF32(hash, stroke_width);
    return hash;
}

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

pub const RenderImagePlanner = struct {
    images: []RenderImage,
    image_resources: []const ReferenceImage = &.{},
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
        const resource = findReferenceImage(self.image_resources, image.image_id);
        const fingerprint = renderImageFingerprintForResource(image.image_id, resource);
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
            .width = if (resource) |value| value.width else 0,
            .height = if (resource) |value| value.height else 0,
            .pixels = if (resource) |value| value.pixels else &.{},
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

fn findReferenceImage(images: []const ReferenceImage, id: ImageId) ?ReferenceImage {
    for (images) |image| {
        if (image.id == id) return image;
    }
    return null;
}

pub fn drawImageFingerprint(image: DrawImage) u64 {
    var hash = resourceHashTag("image");
    hash = resourceHashU64(hash, image.image_id);
    hash = resourceHashOptionalRect(hash, image.src);
    hash = resourceHashEnum(hash, @intFromEnum(image.fit));
    hash = resourceHashEnum(hash, @intFromEnum(image.sampling));
    return hash;
}

pub fn renderImageFingerprint(image_id: ImageId) u64 {
    return resourceHashU64(resourceHashTag("image_texture"), image_id);
}

pub fn renderImageFingerprintForResource(image_id: ImageId, image: ?ReferenceImage) u64 {
    const value = image orelse return renderImageFingerprint(image_id);
    var hash = renderImageFingerprint(image_id);
    hash = resourceHashUsize(hash, value.width);
    hash = resourceHashUsize(hash, value.height);
    hash = resourceHashBytes(hash, value.pixels);
    return hash;
}

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

fn renderCommandNeedsLayer(command: RenderCommand) bool {
    return command.opacity != 1 or command.clip != null or !affinesEqual(command.transform, Affine.identity());
}

fn renderLayerCanExtend(layer: RenderLayer, command: RenderCommand, index: usize) bool {
    return layer.command_start + layer.command_count == index and
        layer.opacity == command.opacity and
        optionalRectsEqual(layer.clip, command.clip) and
        affinesEqual(layer.transform, command.transform);
}

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

fn glyphFontId(run_font_id: FontId, glyph: Glyph) FontId {
    return if (glyph.font_id == 0) run_font_id else glyph.font_id;
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

fn nonZeroObjectId(id: ObjectId) ?ObjectId {
    return if (id == 0) null else id;
}

fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

fn referenceTransformScale(transform: Affine) f32 {
    const x_scale = @sqrt(transform.a * transform.a + transform.b * transform.b);
    const y_scale = @sqrt(transform.c * transform.c + transform.d * transform.d);
    return @max(0.0001, @max(x_scale, y_scale));
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
