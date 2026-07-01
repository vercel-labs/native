const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const Affine = drawing_model.Affine;
const Color = drawing_model.Color;
const Radius = drawing_model.Radius;
const LinearGradient = drawing_model.LinearGradient;
const Fill = drawing_model.Fill;
const PathElement = drawing_model.PathElement;
const ImageFit = drawing_model.ImageFit;
const ImageSampling = drawing_model.ImageSampling;
const Glyph = text_model.Glyph;
const TextLayoutOptions = text_model.TextLayoutOptions;
const GlyphAtlasCacheAction = text_model.GlyphAtlasCacheAction;
const TextLayoutCacheAction = text_model.TextLayoutCacheAction;
const RenderPipelineKind = render_model.RenderPipelineKind;
const RenderCommand = render_model.RenderCommand;
const RenderBatch = render_model.RenderBatch;
const RenderPipelineCacheAction = render_model.RenderPipelineCacheAction;
const RenderPathGeometryCacheAction = render_model.RenderPathGeometryCacheAction;
const RenderImage = render_model.RenderImage;
const RenderImageCacheAction = render_model.RenderImageCacheAction;
const RenderLayerCacheAction = render_model.RenderLayerCacheAction;
const RenderResourceCacheAction = render_model.RenderResourceCacheAction;
const VisualEffectCacheAction = render_model.VisualEffectCacheAction;

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

pub const CanvasGpuCommandKind = enum {
    fill_rect_solid,
    fill_rect_gradient,
    fill_rounded_rect_solid,
    fill_rounded_rect_gradient,
    stroke_rect_solid,
    stroke_rect_gradient,
    draw_line_solid,
    draw_line_gradient,
    fill_path,
    stroke_path,
    draw_image,
    draw_text,
    shadow,
    blur,
    unsupported,
};

pub const CanvasGpuRoundedRect = struct {
    rect: geometry.RectF = .{},
    radius: Radius = .{},
};

pub const CanvasGpuStrokeRect = struct {
    rect: geometry.RectF = .{},
    radius: Radius = .{},
    width: f32 = 1,
};

pub const CanvasGpuLine = struct {
    from: geometry.PointF = .{},
    to: geometry.PointF = .{},
    width: f32 = 1,
};

pub const CanvasGpuShape = union(enum) {
    none,
    rect: geometry.RectF,
    rounded_rect: CanvasGpuRoundedRect,
    stroke_rect: CanvasGpuStrokeRect,
    line: CanvasGpuLine,
    path: []const PathElement,
};

pub const CanvasGpuPaint = union(enum) {
    none,
    color: Color,
    linear_gradient: LinearGradient,
};

pub const CanvasGpuImage = struct {
    image_id: ImageId = 0,
    src: ?geometry.RectF = null,
    dst: geometry.RectF = .{},
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
    sampling: ImageSampling = .linear,
};

pub const CanvasGpuText = struct {
    font_id: FontId = 0,
    size: f32 = 0,
    origin: geometry.PointF = .{},
    color: Color = .{},
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
    text_layout: ?TextLayoutOptions = null,
};

pub const CanvasGpuShadow = struct {
    rect: geometry.RectF = .{},
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color = .{},
};

pub const CanvasGpuBlur = struct {
    rect: geometry.RectF = .{},
    radius: f32 = 0,
};

pub const CanvasGpuEffect = union(enum) {
    none,
    shadow: CanvasGpuShadow,
    blur: CanvasGpuBlur,
};

pub const CanvasGpuCommand = struct {
    command_index: usize,
    id: ?ObjectId = null,
    kind: CanvasGpuCommandKind,
    pipeline: ?RenderPipelineKind = null,
    bounds: geometry.RectF = .{},
    shape: CanvasGpuShape = .none,
    paint: CanvasGpuPaint = .none,
    stroke_width: f32 = 0,
    image: ?CanvasGpuImage = null,
    text: ?CanvasGpuText = null,
    effect: CanvasGpuEffect = .none,
    clip: ?geometry.RectF = null,
    opacity: f32 = 1,
    transform: Affine = .{},
    uses_path_geometry: bool = false,
    uses_image: bool = false,
    uses_resource: bool = false,
    uses_visual_effect: bool = false,
    uses_glyph_atlas: bool = false,
    uses_text_layout: bool = false,

    pub fn supported(self: CanvasGpuCommand) bool {
        return self.kind != .unsupported;
    }

    pub fn usesCachedResource(self: CanvasGpuCommand) bool {
        return self.uses_path_geometry or
            self.uses_image or
            self.uses_resource or
            self.uses_visual_effect or
            self.uses_glyph_atlas or
            self.uses_text_layout;
    }
};

pub const CanvasGpuPacket = struct {
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    load_action: CanvasRenderPassLoadAction = .skip,
    surface_size: geometry.SizeF = .{},
    scale: f32 = 1,
    scissor: ?geometry.RectF = null,
    images: []const RenderImage = &.{},
    image_actions: []const RenderImageCacheAction = &.{},
    commands: []const CanvasGpuCommand = &.{},
    batch_count: usize = 0,
    pipeline_action_count: usize = 0,
    path_geometry_count: usize = 0,
    path_geometry_action_count: usize = 0,
    image_count: usize = 0,
    image_action_count: usize = 0,
    layer_count: usize = 0,
    layer_action_count: usize = 0,
    resource_count: usize = 0,
    resource_action_count: usize = 0,
    visual_effect_count: usize = 0,
    visual_effect_action_count: usize = 0,
    glyph_atlas_entry_count: usize = 0,
    glyph_atlas_action_count: usize = 0,
    text_layout_count: usize = 0,
    text_layout_line_count: usize = 0,
    text_layout_action_count: usize = 0,
    unsupported_command_count: usize = 0,

    pub fn requiresRender(self: CanvasGpuPacket) bool {
        return self.load_action != .skip;
    }

    pub fn commandCount(self: CanvasGpuPacket) usize {
        return self.commands.len;
    }

    pub fn cacheActionCount(self: CanvasGpuPacket) usize {
        return self.pipeline_action_count +
            self.path_geometry_action_count +
            self.image_action_count +
            self.layer_action_count +
            self.resource_action_count +
            self.visual_effect_action_count +
            self.glyph_atlas_action_count +
            self.text_layout_action_count;
    }

    pub fn cachedResourceCommandCount(self: CanvasGpuPacket) usize {
        var count: usize = 0;
        for (self.commands) |command| {
            if (command.usesCachedResource()) count += 1;
        }
        return count;
    }

    pub fn fullyRepresentable(self: CanvasGpuPacket) bool {
        return self.unsupported_command_count == 0;
    }

    pub fn writeJson(self: CanvasGpuPacket, writer: anytype) !void {
        try canvas.writeCanvasGpuPacketJson(self, writer);
    }
};

pub const CanvasGpuPacketSummary = struct {
    load_action: CanvasRenderPassLoadAction = .skip,
    command_count: usize = 0,
    cache_action_count: usize = 0,
    cached_resource_command_count: usize = 0,
    unsupported_command_count: usize = 0,

    pub fn requiresRender(self: CanvasGpuPacketSummary) bool {
        return self.load_action != .skip;
    }

    pub fn fullyRepresentable(self: CanvasGpuPacketSummary) bool {
        return self.unsupported_command_count == 0;
    }
};

pub const RenderEncoderPlanner = struct {
    commands: []RenderEncoderCommand,
    len: usize = 0,

    pub fn init(commands: []RenderEncoderCommand) RenderEncoderPlanner {
        return .{ .commands = commands };
    }

    pub fn reset(self: *RenderEncoderPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderEncoderPlanner, pass: canvas.CanvasRenderPass) Error!RenderEncoderPlan {
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

pub const CanvasGpuPacketPlanner = struct {
    commands: []CanvasGpuCommand,
    len: usize = 0,
    unsupported_count: usize = 0,

    pub fn init(commands: []CanvasGpuCommand) CanvasGpuPacketPlanner {
        return .{ .commands = commands };
    }

    pub fn reset(self: *CanvasGpuPacketPlanner) void {
        self.len = 0;
        self.unsupported_count = 0;
    }

    pub fn build(self: *CanvasGpuPacketPlanner, pass: canvas.CanvasRenderPass) Error!CanvasGpuPacket {
        self.reset();
        if (!pass.requiresRender()) {
            return .{
                .frame_index = pass.frame_index,
                .timestamp_ns = pass.timestamp_ns,
                .load_action = .skip,
                .surface_size = pass.surface_size,
                .scale = pass.scale,
            };
        }

        const scissor_bounds = pass.scissorBounds();
        for (pass.commands, 0..) |command, index| {
            if (scissor_bounds) |scissor| {
                if (!renderCommandIntersectsDirtyBounds(command, scissor)) continue;
            }
            try self.append(canvasGpuCommandFromRenderCommand(command, index));
        }

        return .{
            .frame_index = pass.frame_index,
            .timestamp_ns = pass.timestamp_ns,
            .load_action = pass.loadAction(),
            .surface_size = pass.surface_size,
            .scale = pass.scale,
            .scissor = pass.scissorBounds(),
            .images = pass.images,
            .image_actions = pass.image_actions,
            .commands = self.commands[0..self.len],
            .batch_count = pass.batchCount(),
            .pipeline_action_count = pass.pipelineActionCount(),
            .path_geometry_count = pass.pathGeometryCount(),
            .path_geometry_action_count = pass.pathGeometryActionCount(),
            .image_count = pass.imageCount(),
            .image_action_count = pass.imageActionCount(),
            .layer_count = pass.layerCount(),
            .layer_action_count = pass.layerActionCount(),
            .resource_count = pass.resourceCount(),
            .resource_action_count = pass.resourceActionCount(),
            .visual_effect_count = pass.visualEffectCount(),
            .visual_effect_action_count = pass.visualEffectActionCount(),
            .glyph_atlas_entry_count = pass.glyphAtlasEntryCount(),
            .glyph_atlas_action_count = pass.glyphAtlasActionCount(),
            .text_layout_count = pass.textLayoutCount(),
            .text_layout_line_count = pass.textLayoutLineCount(),
            .text_layout_action_count = pass.textLayoutActionCount(),
            .unsupported_command_count = self.unsupported_count,
        };
    }

    fn append(self: *CanvasGpuPacketPlanner, command: CanvasGpuCommand) Error!void {
        if (self.len >= self.commands.len) return error.CanvasGpuCommandListFull;
        if (!command.supported()) self.unsupported_count += 1;
        self.commands[self.len] = command;
        self.len += 1;
    }
};

pub fn renderCommandIntersectsDirtyBounds(command: RenderCommand, dirty_bounds: geometry.RectF) bool {
    const command_bounds = command.bounds.normalized();
    const dirty = dirty_bounds.normalized();
    if (command_bounds.isEmpty() or dirty.isEmpty()) return false;
    return command_bounds.intersects(dirty);
}

pub fn canvasGpuCommandFromRenderCommand(command: RenderCommand, command_index: usize) CanvasGpuCommand {
    var packet_command = CanvasGpuCommand{
        .command_index = command_index,
        .id = command.id,
        .kind = .unsupported,
        .bounds = command.bounds,
        .clip = command.clip,
        .opacity = command.opacity,
        .transform = command.transform,
    };

    switch (command.command) {
        .fill_rect => |value| {
            packet_command.kind = canvasGpuFillRectKind(value.fill);
            packet_command.pipeline = canvasGpuFillPipeline(value.fill);
            packet_command.shape = .{ .rect = value.rect.normalized() };
            packet_command.paint = canvasGpuPaint(value.fill);
            packet_command.uses_resource = canvasGpuFillUsesResource(value.fill);
        },
        .fill_rounded_rect => |value| {
            packet_command.kind = canvasGpuRoundedRectKind(value.fill);
            packet_command.pipeline = canvasGpuFillPipeline(value.fill);
            packet_command.shape = .{ .rounded_rect = .{
                .rect = value.rect.normalized(),
                .radius = value.radius,
            } };
            packet_command.paint = canvasGpuPaint(value.fill);
            packet_command.uses_resource = canvasGpuFillUsesResource(value.fill);
        },
        .stroke_rect => |value| {
            packet_command.kind = canvasGpuStrokeRectKind(value.stroke.fill);
            packet_command.pipeline = canvasGpuFillPipeline(value.stroke.fill);
            packet_command.shape = .{ .stroke_rect = .{
                .rect = value.rect.normalized(),
                .radius = value.radius,
                .width = value.stroke.width,
            } };
            packet_command.paint = canvasGpuPaint(value.stroke.fill);
            packet_command.stroke_width = value.stroke.width;
            packet_command.uses_resource = canvasGpuFillUsesResource(value.stroke.fill);
        },
        .draw_line => |value| {
            packet_command.kind = canvasGpuLineKind(value.stroke.fill);
            packet_command.pipeline = canvasGpuFillPipeline(value.stroke.fill);
            packet_command.shape = .{ .line = .{
                .from = value.from,
                .to = value.to,
                .width = value.stroke.width,
            } };
            packet_command.paint = canvasGpuPaint(value.stroke.fill);
            packet_command.stroke_width = value.stroke.width;
            packet_command.uses_resource = canvasGpuFillUsesResource(value.stroke.fill);
        },
        .fill_path => |value| {
            packet_command.kind = .fill_path;
            packet_command.pipeline = .path;
            packet_command.shape = .{ .path = value.elements };
            packet_command.paint = canvasGpuPaint(value.fill);
            packet_command.uses_path_geometry = true;
            packet_command.uses_resource = canvasGpuFillUsesResource(value.fill);
        },
        .stroke_path => |value| {
            packet_command.kind = .stroke_path;
            packet_command.pipeline = .path;
            packet_command.shape = .{ .path = value.elements };
            packet_command.paint = canvasGpuPaint(value.stroke.fill);
            packet_command.stroke_width = value.stroke.width;
            packet_command.uses_path_geometry = true;
            packet_command.uses_resource = canvasGpuFillUsesResource(value.stroke.fill);
        },
        .draw_image => |value| {
            packet_command.kind = .draw_image;
            packet_command.pipeline = .image;
            packet_command.image = .{
                .image_id = value.image_id,
                .src = value.src,
                .dst = value.dst.normalized(),
                .opacity = value.opacity,
                .fit = value.fit,
                .sampling = value.sampling,
            };
            packet_command.uses_image = true;
            packet_command.uses_resource = true;
        },
        .draw_text => |value| {
            packet_command.kind = .draw_text;
            packet_command.pipeline = .glyph_run;
            packet_command.paint = .{ .color = value.color };
            packet_command.text = .{
                .font_id = value.font_id,
                .size = value.size,
                .origin = value.origin,
                .color = value.color,
                .text = value.text,
                .glyphs = value.glyphs,
                .text_layout = value.text_layout,
            };
            packet_command.uses_resource = true;
            packet_command.uses_glyph_atlas = true;
            packet_command.uses_text_layout = value.text_layout != null;
        },
        .shadow => |value| {
            packet_command.kind = .shadow;
            packet_command.pipeline = .shadow;
            packet_command.effect = .{ .shadow = .{
                .rect = value.rect.normalized(),
                .radius = value.radius,
                .offset = value.offset,
                .blur = value.blur,
                .spread = value.spread,
                .color = value.color,
            } };
            packet_command.uses_resource = true;
            packet_command.uses_visual_effect = true;
        },
        .blur => |value| {
            packet_command.kind = .blur;
            packet_command.pipeline = .blur;
            packet_command.effect = .{ .blur = .{
                .rect = value.rect.normalized(),
                .radius = value.radius,
            } };
            packet_command.uses_resource = true;
            packet_command.uses_visual_effect = true;
        },
        .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform => {},
    }
    return packet_command;
}

fn canvasGpuPaint(fill: Fill) CanvasGpuPaint {
    return switch (fill) {
        .color => |color| .{ .color = color },
        .linear_gradient => |gradient| .{ .linear_gradient = gradient },
    };
}

fn canvasGpuFillPipeline(fill: Fill) RenderPipelineKind {
    return switch (fill) {
        .color => .solid,
        .linear_gradient => .linear_gradient,
    };
}

fn canvasGpuFillUsesResource(fill: Fill) bool {
    return switch (fill) {
        .color => false,
        .linear_gradient => true,
    };
}

fn canvasGpuFillRectKind(fill: Fill) CanvasGpuCommandKind {
    return switch (fill) {
        .color => .fill_rect_solid,
        .linear_gradient => .fill_rect_gradient,
    };
}

fn canvasGpuRoundedRectKind(fill: Fill) CanvasGpuCommandKind {
    return switch (fill) {
        .color => .fill_rounded_rect_solid,
        .linear_gradient => .fill_rounded_rect_gradient,
    };
}

fn canvasGpuStrokeRectKind(fill: Fill) CanvasGpuCommandKind {
    return switch (fill) {
        .color => .stroke_rect_solid,
        .linear_gradient => .stroke_rect_gradient,
    };
}

fn canvasGpuLineKind(fill: Fill) CanvasGpuCommandKind {
    return switch (fill) {
        .color => .draw_line_solid,
        .linear_gradient => .draw_line_gradient,
    };
}
