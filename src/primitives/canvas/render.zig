const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const equality_model = @import("equality.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const CanvasCommand = canvas.CanvasCommand;
const DisplayList = canvas.DisplayList;
const ReferenceImage = canvas.ReferenceImage;
const Affine = drawing_model.Affine;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const Easing = token_model.Easing;
const SpringToken = token_model.SpringToken;

const optionalRectsEqual = equality_model.optionalRectsEqual;
const optionalF32Equal = equality_model.optionalF32Equal;

const render_resources = @import("render_resources.zig");

pub const RenderImage = render_resources.RenderImage;
pub const RenderImagePlan = render_resources.RenderImagePlan;
pub const RenderImagePlanner = render_resources.RenderImagePlanner;
pub const RenderImageKey = render_resources.RenderImageKey;
pub const RenderImageCacheEntry = render_resources.RenderImageCacheEntry;
pub const RenderImageCacheActionKind = render_resources.RenderImageCacheActionKind;
pub const RenderImageCacheAction = render_resources.RenderImageCacheAction;
pub const RenderImageCachePlan = render_resources.RenderImageCachePlan;
pub const RenderImageCachePlanner = render_resources.RenderImageCachePlanner;
pub const RenderResourceKind = render_resources.RenderResourceKind;
pub const RenderResource = render_resources.RenderResource;
pub const RenderResourcePlan = render_resources.RenderResourcePlan;
pub const RenderResourcePlanner = render_resources.RenderResourcePlanner;
pub const RenderResourceKey = render_resources.RenderResourceKey;
pub const RenderResourceCacheEntry = render_resources.RenderResourceCacheEntry;
pub const RenderResourceCacheActionKind = render_resources.RenderResourceCacheActionKind;
pub const RenderResourceCacheAction = render_resources.RenderResourceCacheAction;
pub const RenderResourceCachePlan = render_resources.RenderResourceCachePlan;
pub const RenderResourceCachePlanner = render_resources.RenderResourceCachePlanner;
pub const RenderLayer = render_resources.RenderLayer;
pub const RenderLayerPlan = render_resources.RenderLayerPlan;
pub const RenderLayerPlanner = render_resources.RenderLayerPlanner;
pub const RenderLayerKey = render_resources.RenderLayerKey;
pub const RenderLayerCacheEntry = render_resources.RenderLayerCacheEntry;
pub const RenderLayerCacheActionKind = render_resources.RenderLayerCacheActionKind;
pub const RenderLayerCacheAction = render_resources.RenderLayerCacheAction;
pub const RenderLayerCachePlan = render_resources.RenderLayerCachePlan;
pub const RenderLayerCachePlanner = render_resources.RenderLayerCachePlanner;
pub const VisualEffectKind = render_resources.VisualEffectKind;
pub const VisualEffect = render_resources.VisualEffect;
pub const VisualEffectPlan = render_resources.VisualEffectPlan;
pub const VisualEffectPlanner = render_resources.VisualEffectPlanner;
pub const VisualEffectKey = render_resources.VisualEffectKey;
pub const VisualEffectCacheEntry = render_resources.VisualEffectCacheEntry;
pub const VisualEffectCacheActionKind = render_resources.VisualEffectCacheActionKind;
pub const VisualEffectCacheAction = render_resources.VisualEffectCacheAction;
pub const VisualEffectCachePlan = render_resources.VisualEffectCachePlan;
pub const VisualEffectCachePlanner = render_resources.VisualEffectCachePlanner;
pub const drawImageFingerprint = render_resources.drawImageFingerprint;
pub const renderImageFingerprint = render_resources.renderImageFingerprint;
pub const renderImageFingerprintForResource = render_resources.renderImageFingerprintForResource;

const render_paths = @import("render_paths.zig");

pub const RenderPathGeometryKind = render_paths.RenderPathGeometryKind;
pub const RenderPathGeometry = render_paths.RenderPathGeometry;
pub const RenderPathGeometryPlan = render_paths.RenderPathGeometryPlan;
pub const RenderPathGeometryPlanner = render_paths.RenderPathGeometryPlanner;
pub const PathGeometryCounts = render_paths.PathGeometryCounts;
pub const analyzePathGeometry = render_paths.analyzePathGeometry;
pub const RenderPathGeometryKey = render_paths.RenderPathGeometryKey;
pub const RenderPathGeometryCacheEntry = render_paths.RenderPathGeometryCacheEntry;
pub const RenderPathGeometryCacheActionKind = render_paths.RenderPathGeometryCacheActionKind;
pub const RenderPathGeometryCacheAction = render_paths.RenderPathGeometryCacheAction;
pub const RenderPathGeometryCachePlan = render_paths.RenderPathGeometryCachePlan;
pub const RenderPathGeometryCachePlanner = render_paths.RenderPathGeometryCachePlanner;

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
    /// Ping-pong the from→to sweep forever (0→1→0→…, one sweep per
    /// `duration_ms`): the caret-blink shape. A looping animation never
    /// completes — it stays active until explicitly removed.
    loop: bool = false,
};

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
    const raw = if (animation.loop)
        pingPongMotionProgress(animation.start_ns, animation.duration_ms, timestamp_ns)
    else
        rawMotionProgress(animation.start_ns, animation.duration_ms, timestamp_ns);
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

/// Looping sweep: fold elapsed time into a 0→1→0 triangle, one from→to
/// sweep per `duration_ms`. Easing applies to each sweep, so a standard
/// ease reads as a smooth fade out and back — the caret-blink shape.
fn pingPongMotionProgress(start_ns: u64, duration_ms: u32, timestamp_ns: u64) f32 {
    if (duration_ms == 0) return 1;
    if (timestamp_ns <= start_ns) return 0;
    const duration_ns = @as(u64, duration_ms) * 1_000_000;
    const phase_ns = (timestamp_ns - start_ns) % (duration_ns * 2);
    const forward = phase_ns < duration_ns;
    const sweep_ns = if (forward) phase_ns else phase_ns - duration_ns;
    const sweep = @as(f32, @floatFromInt(sweep_ns)) / @as(f32, @floatFromInt(duration_ns));
    return if (forward) sweep else 1 - sweep;
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

fn affinesEqual(a: Affine, b: Affine) bool {
    return equality_model.affinesEqual(a, b);
}
