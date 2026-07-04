const geometry = @import("geometry");
const json = @import("json");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");
const gpu_model = @import("gpu.zig");

const ObjectId = canvas.ObjectId;
const CanvasCommand = canvas.CanvasCommand;
const CanvasRenderPass = canvas.CanvasRenderPass;

const Color = drawing_model.Color;
const Radius = drawing_model.Radius;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const PathElement = drawing_model.PathElement;
const Affine = drawing_model.Affine;

const Glyph = text_model.Glyph;
const GlyphAtlasEntry = text_model.GlyphAtlasEntry;
const GlyphAtlasCacheAction = text_model.GlyphAtlasCacheAction;
const GlyphAtlasKey = text_model.GlyphAtlasKey;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const TextLayoutPlan = text_model.TextLayoutPlan;
const TextLayoutCacheAction = text_model.TextLayoutCacheAction;
const TextLayoutKey = text_model.TextLayoutKey;

const RenderCommand = render_model.RenderCommand;
const RenderBatch = render_model.RenderBatch;
const RenderPipelineCacheAction = render_model.RenderPipelineCacheAction;
const RenderPathGeometry = render_model.RenderPathGeometry;
const RenderPathGeometryCacheAction = render_model.RenderPathGeometryCacheAction;
const RenderPathGeometryKey = render_model.RenderPathGeometryKey;
const RenderImage = render_model.RenderImage;
const RenderImageCacheAction = render_model.RenderImageCacheAction;
const RenderImageKey = render_model.RenderImageKey;
const RenderLayer = render_model.RenderLayer;
const RenderLayerCacheAction = render_model.RenderLayerCacheAction;
const RenderLayerKey = render_model.RenderLayerKey;
const RenderResource = render_model.RenderResource;
const RenderResourceCacheAction = render_model.RenderResourceCacheAction;
const RenderResourceKey = render_model.RenderResourceKey;
const VisualEffect = render_model.VisualEffect;
const VisualEffectCacheAction = render_model.VisualEffectCacheAction;
const VisualEffectKey = render_model.VisualEffectKey;

const CanvasGpuPacket = gpu_model.CanvasGpuPacket;
const CanvasGpuCommand = gpu_model.CanvasGpuCommand;
const CanvasGpuShape = gpu_model.CanvasGpuShape;
const CanvasGpuPaint = gpu_model.CanvasGpuPaint;
const CanvasGpuImage = gpu_model.CanvasGpuImage;
const CanvasGpuText = gpu_model.CanvasGpuText;
const CanvasGpuEffect = gpu_model.CanvasGpuEffect;

pub fn writeDisplayListJson(display_list: canvas.DisplayList, writer: anytype) !void {
    try writer.writeAll("{\"commands\":[");
    for (display_list.commands, 0..) |command, index| {
        if (index > 0) try writer.writeByte(',');
        try writeCommandJson(command, writer);
    }
    try writer.writeAll("]}");
}

fn nonNegative(value: f32) f32 {
    return if (value < 0) 0 else value;
}

pub fn writeCommandJson(command: CanvasCommand, writer: anytype) !void {
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
            if (radiusIsSet(value.radius)) {
                try writer.writeAll(",\"radius\":");
                try writeRadiusJson(value.radius, writer);
            }
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

pub fn writeCanvasRenderPassJson(pass: CanvasRenderPass, writer: anytype) !void {
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

pub fn writeCanvasGpuPacketJson(packet: CanvasGpuPacket, writer: anytype) !void {
    try writer.print(
        "{{\"frameIndex\":{d},\"timestampNs\":{d},\"surfaceWidth\":{d},\"surfaceHeight\":{d},\"scale\":{d},\"loadAction\":",
        .{ packet.frame_index, packet.timestamp_ns, packet.surface_size.width, packet.surface_size.height, packet.scale },
    );
    try json.writeString(writer, @tagName(packet.load_action));
    try writer.writeAll(",\"requiresRender\":");
    try writer.writeAll(if (packet.requiresRender()) "true" else "false");
    try writer.writeAll(",\"scissorBounds\":");
    try writeOptionalRectJson(packet.scissor, writer);
    try writer.print(
        ",\"commandCount\":{d},\"cacheActionCount\":{d},\"cachedResourceCommandCount\":{d},\"unsupportedCommandCount\":{d}",
        .{ packet.commandCount(), packet.cacheActionCount(), packet.cachedResourceCommandCount(), packet.unsupported_command_count },
    );
    try writer.writeAll(",\"representable\":");
    try writer.writeAll(if (packet.fullyRepresentable()) "true" else "false");
    try writer.writeAll(",\"images\":[");
    for (packet.images, 0..) |image, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderImagePacketJson(image, writer);
    }
    try writer.writeAll("],\"imageActions\":[");
    for (packet.image_actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRenderImageCacheActionJson(action, writer);
    }
    try writer.writeAll("],\"commands\":[");
    for (packet.commands, 0..) |command, index| {
        if (index > 0) try writer.writeByte(',');
        try writeCanvasGpuCommandJson(command, writer);
    }
    try writer.writeAll("]}");
}

fn writeCanvasGpuCommandJson(command: CanvasGpuCommand, writer: anytype) !void {
    try writer.print("{{\"index\":{d},\"id\":", .{command.command_index});
    try writeOptionalObjectIdJson(command.id, writer);
    try writer.writeAll(",\"kind\":");
    try json.writeString(writer, @tagName(command.kind));
    try writer.writeAll(",\"pipeline\":");
    if (command.pipeline) |pipeline| {
        try json.writeString(writer, @tagName(pipeline));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"bounds\":");
    try writeRectJson(command.bounds, writer);
    try writer.writeAll(",\"shape\":");
    try writeCanvasGpuShapeJson(command.shape, writer);
    try writer.writeAll(",\"paint\":");
    try writeCanvasGpuPaintJson(command.paint, writer);
    try writer.print(",\"strokeWidth\":{d}", .{command.stroke_width});
    try writer.writeAll(",\"image\":");
    try writeCanvasGpuImageJson(command.image, writer);
    try writer.writeAll(",\"text\":");
    try writeCanvasGpuTextJson(command.text, writer);
    try writer.writeAll(",\"effect\":");
    try writeCanvasGpuEffectJson(command.effect, writer);
    try writer.writeAll(",\"clip\":");
    try writeOptionalRectJson(command.clip, writer);
    try writer.print(",\"opacity\":{d},\"transform\":", .{command.opacity});
    try writeAffineJson(command.transform, writer);
    try writer.writeAll(",\"usesPathGeometry\":");
    try writer.writeAll(if (command.uses_path_geometry) "true" else "false");
    try writer.writeAll(",\"usesImage\":");
    try writer.writeAll(if (command.uses_image) "true" else "false");
    try writer.writeAll(",\"usesResource\":");
    try writer.writeAll(if (command.uses_resource) "true" else "false");
    try writer.writeAll(",\"usesVisualEffect\":");
    try writer.writeAll(if (command.uses_visual_effect) "true" else "false");
    try writer.writeAll(",\"usesGlyphAtlas\":");
    try writer.writeAll(if (command.uses_glyph_atlas) "true" else "false");
    try writer.writeAll(",\"usesTextLayout\":");
    try writer.writeAll(if (command.uses_text_layout) "true" else "false");
    try writer.writeByte('}');
}

fn writeCanvasGpuShapeJson(shape: CanvasGpuShape, writer: anytype) !void {
    switch (shape) {
        .none => try writer.writeAll("null"),
        .rect => |rect| {
            try writer.writeAll("{\"kind\":\"rect\",\"rect\":");
            try writeRectJson(rect, writer);
            try writer.writeByte('}');
        },
        .rounded_rect => |rounded_rect| {
            try writer.writeAll("{\"kind\":\"rounded_rect\",\"rect\":");
            try writeRectJson(rounded_rect.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(rounded_rect.radius, writer);
            try writer.writeByte('}');
        },
        .stroke_rect => |stroke_rect| {
            try writer.writeAll("{\"kind\":\"stroke_rect\",\"rect\":");
            try writeRectJson(stroke_rect.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(stroke_rect.radius, writer);
            try writer.print(",\"width\":{d}}}", .{stroke_rect.width});
        },
        .line => |line| {
            try writer.writeAll("{\"kind\":\"line\",\"from\":");
            try writePointJson(line.from, writer);
            try writer.writeAll(",\"to\":");
            try writePointJson(line.to, writer);
            try writer.print(",\"width\":{d}}}", .{line.width});
        },
        .path => |path| {
            try writer.writeAll("{\"kind\":\"path\",\"path\":");
            try writePathJson(path, writer);
            try writer.writeByte('}');
        },
    }
}

fn writeCanvasGpuPaintJson(paint: CanvasGpuPaint, writer: anytype) !void {
    switch (paint) {
        .none => try writer.writeAll("null"),
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

fn writeCanvasGpuImageJson(image: ?CanvasGpuImage, writer: anytype) !void {
    const value = image orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.print("{{\"image\":{d},\"src\":", .{value.image_id});
    try writeOptionalRectJson(value.src, writer);
    try writer.writeAll(",\"dst\":");
    try writeRectJson(value.dst, writer);
    try writer.print(",\"opacity\":{d},\"fit\":", .{value.opacity});
    try json.writeString(writer, @tagName(value.fit));
    try writer.writeAll(",\"sampling\":");
    try json.writeString(writer, @tagName(value.sampling));
    // Zero radius is omitted so image payloads without the rounded mask
    // stay byte-identical to the pre-radius wire format.
    if (radiusIsSet(value.radius)) {
        try writer.writeAll(",\"radius\":");
        try writeRadiusJson(value.radius, writer);
    }
    try writer.writeByte('}');
}

fn radiusIsSet(radius: Radius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or
        radius.bottom_right > 0 or radius.bottom_left > 0;
}

fn writeCanvasGpuTextJson(text: ?CanvasGpuText, writer: anytype) !void {
    const value = text orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.print("{{\"font\":{d},\"size\":{d},\"origin\":", .{ value.font_id, value.size });
    try writePointJson(value.origin, writer);
    try writer.writeAll(",\"color\":");
    try writeColorJson(value.color, writer);
    try writer.writeAll(",\"text\":");
    try json.writeString(writer, value.text);
    try writer.writeAll(",\"glyphs\":");
    try writeGlyphsJson(value.glyphs, writer);
    try writer.writeAll(",\"layout\":");
    if (value.text_layout) |options| {
        try writeTextLayoutOptionsJson(options, writer);
        try writer.writeAll(",\"lines\":");
        try writeCanvasGpuTextLinesJson(value, options, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

/// Line budget for packet text lines; matches the reference renderer's
/// `max_reference_text_layout_lines` so both paths degrade at the same
/// depth.
const max_packet_text_layout_lines: usize = 64;

/// The engine's measured line breaks for a packet text command. The packet
/// host draws these lines verbatim instead of re-breaking the text with its
/// own line breaker, so drawn line breaks can never disagree with the
/// layout that measured the box — host-side re-wrapping broke tight
/// intrinsic single-line boxes mid-word. Uses the same
/// `layoutTextRun` the reference renderer and selection geometry draw from,
/// including the injected measure provider carried by the layout options.
/// Serializes `null` when the run exceeds the line budget, which keeps the
/// host's legacy wrapping fallback.
fn writeCanvasGpuTextLinesJson(value: CanvasGpuText, options: TextLayoutOptions, writer: anytype) !void {
    var lines: [max_packet_text_layout_lines]TextLine = undefined;
    const layout = text_model.layoutTextRun(.{
        .font_id = value.font_id,
        .size = value.size,
        .origin = value.origin,
        .color = value.color,
        .text = value.text,
        .glyphs = value.glyphs,
        .text_layout = options,
    }, options, &lines) catch {
        try writer.writeAll("null");
        return;
    };
    try writer.writeByte('[');
    for (layout.lines, 0..) |line, index| {
        if (index > 0) try writer.writeByte(',');
        const start = @min(line.text_start, value.text.len);
        const end = @min(value.text.len, start + line.text_len);
        try writer.print("{{\"x\":{d},\"baseline\":{d},\"text\":", .{ line.bounds.x, line.baseline });
        try json.writeString(writer, value.text[start..end]);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeCanvasGpuEffectJson(effect: CanvasGpuEffect, writer: anytype) !void {
    switch (effect) {
        .none => try writer.writeAll("null"),
        .shadow => |shadow| {
            try writer.writeAll("{\"kind\":\"shadow\",\"rect\":");
            try writeRectJson(shadow.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(shadow.radius, writer);
            try writer.print(",\"offset\":[{d},{d}],\"blur\":{d},\"spread\":{d},\"color\":", .{ shadow.offset.dx, shadow.offset.dy, shadow.blur, shadow.spread });
            try writeColorJson(shadow.color, writer);
            try writer.writeByte('}');
        },
        .blur => |blur| {
            try writer.writeAll("{\"kind\":\"blur\",\"rect\":");
            try writeRectJson(blur.rect, writer);
            try writer.print(",\"radius\":{d}}}", .{blur.radius});
        },
    }
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
    try writer.print(",\"width\":{d},\"height\":{d},\"pixelByteLength\":{d},\"fingerprint\":{d}}}", .{ image.width, image.height, image.pixels.len, image.fingerprint });
}

/// Packet images are references, never payloads: id + dimensions +
/// content fingerprint. The pixel bytes travel out-of-band through the
/// platform's binary image-upload side-channel
/// (`PlatformServices.uploadGpuSurfaceImage`), so a registered image can
/// never push a frame's packet JSON over the transport bound (which used
/// to evict the whole frame to the software pixel path).
fn writeRenderImagePacketJson(image: RenderImage, writer: anytype) !void {
    try writer.print("{{\"imageId\":{d},\"commandIndex\":{d},\"id\":", .{ image.image_id, image.command_index });
    try writeOptionalObjectIdJson(image.id, writer);
    try writer.print(",\"drawCount\":{d},\"bounds\":", .{image.draw_count});
    try writeRectJson(image.bounds, writer);
    try writer.print(",\"width\":{d},\"height\":{d},\"fingerprint\":{d}}}", .{ image.width, image.height, image.fingerprint });
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
        try writer.print(",\"x\":{d},\"y\":{d},\"advance\":{d}", .{ glyph.x, glyph.y, glyph.advance });
        if (glyph.text_len != 0) try writer.print(",\"textStart\":{d},\"textLen\":{d}", .{ glyph.text_start, glyph.text_len });
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}
