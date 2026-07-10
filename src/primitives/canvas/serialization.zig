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
            // The cap key appears only for the non-default shape: butt is
            // implied by absence, so existing snapshots stay byte-stable
            // and readers without cap handling keep their old meaning.
            if (value.cap != .butt) {
                try writer.writeAll(",\"cap\":");
                try json.writeString(writer, @tagName(value.cap));
            }
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
    try writer.writeAll(",\"overflow\":");
    try json.writeString(writer, @tagName(options.overflow));
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
    try writer.writeAll(",\"cap\":");
    try json.writeString(writer, @tagName(command.cap));
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
/// Both packet encodings (JSON and binary) draw from this one layout so
/// they can never disagree on line breaks. Returns null when the run
/// exceeds the line budget, which keeps the host's legacy wrapping
/// fallback.
fn packetTextLayout(value: CanvasGpuText, options: TextLayoutOptions, lines: []TextLine) ?text_model.TextLayout {
    return text_model.layoutTextRun(.{
        .font_id = value.font_id,
        .size = value.size,
        .origin = value.origin,
        .color = value.color,
        .text = value.text,
        .glyphs = value.glyphs,
        .text_layout = options,
    }, options, lines) catch null;
}

fn writeCanvasGpuTextLinesJson(value: CanvasGpuText, options: TextLayoutOptions, writer: anytype) !void {
    var lines: [max_packet_text_layout_lines]TextLine = undefined;
    const layout = packetTextLayout(value, options, &lines) orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeByte('[');
    for (layout.lines, 0..) |line, index| {
        if (index > 0) try writer.writeByte(',');
        // Elided lines ship their painted bytes — kept prefix plus the
        // ellipsis — so hosts that draw packet lines verbatim ink
        // exactly the extent the engine measured, with no host-side
        // elision logic to drift.
        const start = @min(line.text_start, value.text.len);
        const end = @min(value.text.len, start + line.paintedTextLen());
        try writer.print("{{\"x\":{d},\"baseline\":{d},\"text\":", .{ line.bounds.x, line.baseline });
        try json.writeStringParts(writer, &.{ value.text[start..end], packetLineEllipsis(line) });
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

/// The trailing marker appended to an elided packet line's text (empty
/// when the line fits or the box cannot even hold the marker).
fn packetLineEllipsis(line: TextLine) []const u8 {
    return if (line.hasEllipsis()) text_model.text_ellipsis else "";
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
    try writer.writeAll(",\"overflow\":");
    try json.writeString(writer, @tagName(key.overflow));
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

// ---------------------------------------------------------------------------
// Compact binary gpu-surface packet encoding (wire format v4).
//
// The version this comment names, the `binary_packet_version` constant
// below, and the host decoder's spec comment (appkit_host.m) must agree;
// the `test-wire-format-version-prose` build check pins all three, so
// bumping the constant without updating the prose fails the suite.
//
// Little-endian, length-prefixed throughout, no field names, no decimal
// formatting, and no glyph arrays (the packet host draws text through the
// system text stack from the run's UTF-8 text plus the engine-measured
// lines, so glyph payloads — the bulk of a text-heavy JSON packet — never
// ride the wire). The AppKit host decoder
// (`NativeSdkPacketDictionaryFromBinary` in appkit_host.m) pins the same
// layout and tag tables independently; a disagreement fails the host
// decode loudly (refused present -> recorded fallback) instead of drawing
// garbage. Bump `binary_packet_version` on ANY layout change.
//
// v2 (from v1): every header carries a retained-state `generation`, every
// command rides behind an explicit retain `key` (its ObjectId, or a
// synthetic key for unkeyed commands), and a third load action `patch`
// (3) carries an edit script (evicts + keyed upserts + the full draw-order
// vector) against the host's retained command dictionary instead of the
// full command list. Generation 0 means "do not retain": the host draws
// the frame but never answers a later patch from it.
//
// v3 (from v2): flags bit1 introduces an optional DIRTY RECT LIST after
// the scissor — the exact rects the frame's edit script touches, so a
// patch whose changes sit at opposite window corners repaints (and
// re-uploads) two small rects instead of their bounding union. The
// scissor stays the union of the list (hosts may honor either; pixels
// outside every rect are unchanged by construction).
//
// v4 (from v3): every command carries a stroke end-cap code (u8, 0 butt
// / 1 round) after stroke_width, so packet hosts stroke open subpaths
// (the checkbox mark, the spinner arc) with the same cap the reference
// renderer rasterizes instead of their engine default.
//
// Layout:
//   "NSGP" u8[4] | version u8 | load_action u8 (1 load / 2 clear /
//     3 patch) | flags u8 (bit0 scissor, bit1 dirty rect list) | reserved u8
//   | generation u64 | [scissor f32[4]]
//   | [dirty_rect_count u32 | dirty rects f32[4][]]
//   | image_count u32 | images { image_id u64, fingerprint u64,
//       width u32, height u32 }
//   | image_action_count u32 | actions { kind u8 (0 upload / 1 retain /
//       2 evict), key_image_id u64, key_fingerprint u64,
//       image_index u32 (0xFFFFFFFF = none) }
//   | load/clear: command_count u32 | commands { key u64, command (see
//       writeCanvasGpuCommandBinary) }
//   | patch: evict_count u32 | evict keys u64[]
//     | upsert_count u32 | upserts { key u64, command }
//     | order_count u32 | order keys u64[]

pub const binary_packet_magic = "NSGP";
pub const binary_packet_version: u8 = 4;

/// Most dirty rects a patch header carries: enough to keep far-apart
/// small changes (a switch plus a status line) from fusing into a
/// window-sized union, few enough that host-side per-rect clears,
/// clips, culls, and texture uploads stay O(1) per command.
pub const max_binary_packet_dirty_rects: usize = 8;

/// Wire code for the `patch` load action (`CanvasRenderPassLoadAction`
/// has no patch member — patches are a transport-level edit script, not
/// a render pass the engine plans).
pub const binary_packet_load_action_patch: u8 = 3;

const binary_image_index_none: u32 = 0xFFFF_FFFF;

const hash = @import("hash.zig");

/// Content fingerprint of a packet command: covers every field the binary
/// command encoding serializes (measured text lines are a deterministic
/// function of the hashed text inputs, so hashing the inputs is hashing
/// the lines without paying `layoutTextRun` for unchanged runs — that
/// skip IS the patch win on text-heavy views). Equal fingerprints mean
/// byte-identical wire encodings; `canvas_frame_patch_tests.zig` pins
/// field coverage so a new encoded field cannot silently stop
/// invalidating patches.
pub fn canvasGpuCommandFingerprint(command: CanvasGpuCommand) u64 {
    var h = hash.resourceHashTag("gpu-packet-command");
    h = hash.resourceHashU8(h, binaryCommandKindCode(command.kind));
    h = hash.resourceHashRect(h, command.bounds);
    h = hash.resourceHashF32(h, command.opacity);
    h = hash.resourceHashF32(h, command.stroke_width);
    h = hash.resourceHashEnum(h, @intFromEnum(command.cap));
    h = hash.resourceHashOptionalObjectId(h, command.id);
    h = hash.resourceHashOptionalRect(h, command.clip);
    h = hash.resourceHashAffine(h, command.transform);
    switch (command.shape) {
        .none => h = hash.resourceHashU8(h, 0),
        .rect => |rect| h = hash.resourceHashRect(hash.resourceHashU8(h, 1), rect),
        .rounded_rect => |rounded_rect| {
            h = hash.resourceHashU8(h, 2);
            h = hash.resourceHashRect(h, rounded_rect.rect);
            h = hash.resourceHashRadius(h, rounded_rect.radius);
        },
        .stroke_rect => |stroke_rect| {
            h = hash.resourceHashU8(h, 3);
            h = hash.resourceHashRect(h, stroke_rect.rect);
            h = hash.resourceHashRadius(h, stroke_rect.radius);
            h = hash.resourceHashF32(h, stroke_rect.width);
        },
        .line => |line| {
            h = hash.resourceHashU8(h, 4);
            h = hash.resourceHashPoint(h, line.from);
            h = hash.resourceHashPoint(h, line.to);
            h = hash.resourceHashF32(h, line.width);
        },
        .path => |elements| h = hash.resourceHashPath(hash.resourceHashU8(h, 5), elements),
    }
    switch (command.paint) {
        .none => h = hash.resourceHashU8(h, 0),
        .color => |color| h = hash.resourceHashColor(hash.resourceHashU8(h, 1), color),
        .linear_gradient => |gradient| {
            h = hash.resourceHashU8(h, 2);
            h = hash.resourceHashPoint(h, gradient.start);
            h = hash.resourceHashPoint(h, gradient.end);
            h = hash.resourceHashUsize(h, gradient.stops.len);
            for (gradient.stops) |stop| {
                h = hash.resourceHashF32(h, stop.offset);
                h = hash.resourceHashColor(h, stop.color);
            }
        },
    }
    if (command.image) |image| {
        h = hash.resourceHashU8(h, 1);
        h = hash.resourceHashU64(h, image.image_id);
        h = hash.resourceHashOptionalRect(h, image.src);
        h = hash.resourceHashRect(h, image.dst);
        h = hash.resourceHashF32(h, image.opacity);
        h = hash.resourceHashEnum(h, @intFromEnum(image.fit));
        h = hash.resourceHashEnum(h, @intFromEnum(image.sampling));
        h = hash.resourceHashRadius(h, image.radius);
    } else {
        h = hash.resourceHashU8(h, 0);
    }
    if (command.text) |text| {
        h = hash.resourceHashU8(h, 1);
        h = hash.resourceHashU64(h, text.font_id);
        h = hash.resourceHashF32(h, text.size);
        h = hash.resourceHashPoint(h, text.origin);
        h = hash.resourceHashColor(h, text.color);
        h = hash.resourceHashBytes(h, text.text);
        h = hash.resourceHashUsize(h, text.glyphs.len);
        for (text.glyphs) |glyph| {
            h = hash.resourceHashU32(h, glyph.id);
            h = hash.resourceHashU64(h, glyph.font_id);
            h = hash.resourceHashF32(h, glyph.x);
            h = hash.resourceHashF32(h, glyph.y);
            h = hash.resourceHashF32(h, glyph.advance);
            h = hash.resourceHashUsize(h, glyph.text_start);
            h = hash.resourceHashUsize(h, glyph.text_len);
        }
        if (text.text_layout) |options| {
            h = hash.resourceHashU8(h, 1);
            h = hash.resourceHashF32(h, nonNegative(options.max_width));
            h = hash.resourceHashF32(h, nonNegative(options.line_height));
            h = hash.resourceHashEnum(h, @intFromEnum(options.wrap));
            h = hash.resourceHashEnum(h, @intFromEnum(options.alignment));
            // Default overflow stays out of the hash: fingerprints of
            // runs the elision default never touches keep their pinned
            // values; clip-opted runs hash apart from elided twins.
            if (options.overflow != .ellipsis) {
                h = hash.resourceHashEnum(hash.resourceHashBytes(h, "text_overflow"), @intFromEnum(options.overflow));
            }
        } else {
            h = hash.resourceHashU8(h, 0);
        }
    } else {
        h = hash.resourceHashU8(h, 0);
    }
    switch (command.effect) {
        .none => h = hash.resourceHashU8(h, 0),
        .shadow => |shadow| {
            h = hash.resourceHashU8(h, 1);
            h = hash.resourceHashRect(h, shadow.rect);
            h = hash.resourceHashRadius(h, shadow.radius);
            h = hash.resourceHashF32(h, shadow.offset.dx);
            h = hash.resourceHashF32(h, shadow.offset.dy);
            h = hash.resourceHashF32(h, shadow.blur);
            h = hash.resourceHashF32(h, shadow.spread);
            h = hash.resourceHashColor(h, shadow.color);
        },
        .blur => |blur| {
            h = hash.resourceHashU8(h, 2);
            h = hash.resourceHashRect(h, blur.rect);
            h = hash.resourceHashF32(h, blur.radius);
        },
    }
    return h;
}

/// Retain key for a packet command: the widget-stamped ObjectId when
/// present, else a synthetic key derived from the command's render-plan
/// index + content fingerprint. Unkeyed commands therefore degrade to
/// evict+insert whenever anything above them shifts their index — correct,
/// just not cheap; stamping ids is the fast path.
pub fn canvasGpuPacketCommandKey(command: CanvasGpuCommand, fingerprint: u64) u64 {
    if (command.id) |id| return id;
    var h = hash.resourceHashTag("gpu-packet-synthetic-key");
    h = hash.resourceHashUsize(h, command.command_index);
    h = hash.resourceHashU64(h, fingerprint);
    return h;
}

/// Shared v2 packet header + image sections; `load_action_code` is the
/// wire code (1 load / 2 clear / 3 patch).
pub fn writeCanvasGpuPacketBinaryHeader(
    load_action_code: u8,
    generation: u64,
    scissor: ?geometry.RectF,
    dirty_rects: []const geometry.RectF,
    images: []const RenderImage,
    image_actions: []const RenderImageCacheAction,
    writer: anytype,
) !void {
    try writer.writeAll(binary_packet_magic);
    try writer.writeByte(binary_packet_version);
    try writer.writeByte(load_action_code);
    var flags: u8 = 0;
    if (scissor != null) flags |= 0x01;
    // The dirty rect list refines a scissor; without one it means
    // nothing, so it never rides alone.
    const write_dirty_rects = scissor != null and dirty_rects.len > 0 and dirty_rects.len <= max_binary_packet_dirty_rects;
    if (write_dirty_rects) flags |= 0x02;
    try writer.writeByte(flags);
    try writer.writeByte(0);
    try writer.writeInt(u64, generation, .little);
    if (scissor) |rect| try writeBinaryRect(rect, writer);
    if (write_dirty_rects) {
        try writer.writeInt(u32, @intCast(dirty_rects.len), .little);
        for (dirty_rects) |rect| try writeBinaryRect(rect, writer);
    }

    try writer.writeInt(u32, @intCast(images.len), .little);
    for (images) |image| {
        try writer.writeInt(u64, image.image_id, .little);
        try writer.writeInt(u64, image.fingerprint, .little);
        try writer.writeInt(u32, @intCast(image.width), .little);
        try writer.writeInt(u32, @intCast(image.height), .little);
    }

    try writer.writeInt(u32, @intCast(image_actions.len), .little);
    for (image_actions) |action| {
        try writer.writeByte(switch (action.kind) {
            .upload => 0,
            .retain => 1,
            .evict => 2,
        });
        try writer.writeInt(u64, action.key.image_id, .little);
        try writer.writeInt(u64, action.key.fingerprint, .little);
        try writer.writeInt(u32, if (action.image_index) |index| @intCast(index) else binary_image_index_none, .little);
    }
}

/// One retained command: retain key + the v1 command encoding.
pub fn writeCanvasGpuCommandBinaryKeyed(key: u64, command: CanvasGpuCommand, writer: anytype) !void {
    try writer.writeInt(u64, key, .little);
    try writeCanvasGpuCommandBinary(command, writer);
}

pub fn writeCanvasGpuPacketBinary(packet: CanvasGpuPacket, writer: anytype) !void {
    try writeCanvasGpuPacketBinaryHeader(switch (packet.load_action) {
        .skip => 0,
        .load => 1,
        .clear => 2,
    }, packet.generation, packet.scissor, &.{}, packet.images, packet.image_actions, writer);

    try writer.writeInt(u32, @intCast(packet.commands.len), .little);
    for (packet.commands) |command| {
        const fingerprint = canvasGpuCommandFingerprint(command);
        try writeCanvasGpuCommandBinaryKeyed(canvasGpuPacketCommandKey(command, fingerprint), command, writer);
    }
}

const binary_command_flag_id: u8 = 0x01;
const binary_command_flag_clip: u8 = 0x02;
const binary_command_flag_transform: u8 = 0x04;
const binary_command_flag_shape: u8 = 0x08;
const binary_command_flag_paint: u8 = 0x10;
const binary_command_flag_image: u8 = 0x20;
const binary_command_flag_text: u8 = 0x40;
const binary_command_flag_effect: u8 = 0x80;

/// Command layout: kind u8 | flags u8 | bounds f32[4] | opacity f32
/// | stroke_width f32 | cap u8 (0 butt / 1 round) | [id u64]
/// | [clip f32[4]] | [transform f32[6]]
/// | [shape] | [paint] | [image] | [text] | [effect] — each optional
/// section present exactly when its flag bit is set. The identity
/// transform is elided (the flag doubles as "non-identity").
fn writeCanvasGpuCommandBinary(command: CanvasGpuCommand, writer: anytype) !void {
    try writer.writeByte(binaryCommandKindCode(command.kind));
    var flags: u8 = 0;
    if (command.id != null) flags |= binary_command_flag_id;
    if (command.clip != null) flags |= binary_command_flag_clip;
    const identity_transform = command.transform.a == 1 and command.transform.b == 0 and
        command.transform.c == 0 and command.transform.d == 1 and
        command.transform.tx == 0 and command.transform.ty == 0;
    if (!identity_transform) flags |= binary_command_flag_transform;
    if (command.shape != .none) flags |= binary_command_flag_shape;
    if (command.paint != .none) flags |= binary_command_flag_paint;
    if (command.image != null) flags |= binary_command_flag_image;
    if (command.text != null) flags |= binary_command_flag_text;
    if (command.effect != .none) flags |= binary_command_flag_effect;
    try writer.writeByte(flags);
    try writeBinaryRect(command.bounds, writer);
    try writeBinaryF32(command.opacity, writer);
    try writeBinaryF32(command.stroke_width, writer);
    try writer.writeByte(switch (command.cap) {
        .butt => 0,
        .round => 1,
    });
    if (command.id) |id| try writer.writeInt(u64, id, .little);
    if (command.clip) |clip| try writeBinaryRect(clip, writer);
    if (!identity_transform) try writeBinaryAffine(command.transform, writer);
    if (command.shape != .none) try writeBinaryShape(command.shape, writer);
    if (command.paint != .none) try writeBinaryPaint(command.paint, writer);
    if (command.image) |image| try writeBinaryImage(image, writer);
    if (command.text) |text| try writeBinaryText(text, writer);
    if (command.effect != .none) try writeBinaryEffect(command.effect, writer);
}

/// Stable wire codes for the command kind — pinned independently of the
/// Zig enum's declaration order so a reordered enum cannot silently
/// change the wire format. `.unsupported` maps to 255: hosts refuse it,
/// and the runtime never presents unrepresentable packets anyway.
fn binaryCommandKindCode(kind: gpu_model.CanvasGpuCommandKind) u8 {
    return switch (kind) {
        .fill_rect_solid => 0,
        .fill_rect_gradient => 1,
        .fill_rounded_rect_solid => 2,
        .fill_rounded_rect_gradient => 3,
        .stroke_rect_solid => 4,
        .stroke_rect_gradient => 5,
        .draw_line_solid => 6,
        .draw_line_gradient => 7,
        .fill_path => 8,
        .stroke_path => 9,
        .draw_image => 10,
        .draw_text => 11,
        .shadow => 12,
        .blur => 13,
        .unsupported => 255,
    };
}

/// Shape: tag u8 (1 rect / 2 rounded_rect / 3 stroke_rect / 4 line /
/// 5 path) + payload.
fn writeBinaryShape(shape: CanvasGpuShape, writer: anytype) !void {
    switch (shape) {
        .none => unreachable, // callers gate on the shape flag
        .rect => |rect| {
            try writer.writeByte(1);
            try writeBinaryRect(rect, writer);
        },
        .rounded_rect => |rounded_rect| {
            try writer.writeByte(2);
            try writeBinaryRect(rounded_rect.rect, writer);
            try writeBinaryRadius(rounded_rect.radius, writer);
        },
        .stroke_rect => |stroke_rect| {
            try writer.writeByte(3);
            try writeBinaryRect(stroke_rect.rect, writer);
            try writeBinaryRadius(stroke_rect.radius, writer);
            try writeBinaryF32(stroke_rect.width, writer);
        },
        .line => |line| {
            try writer.writeByte(4);
            try writeBinaryPoint(line.from, writer);
            try writeBinaryPoint(line.to, writer);
            try writeBinaryF32(line.width, writer);
        },
        .path => |elements| {
            try writer.writeByte(5);
            try writer.writeInt(u32, @intCast(elements.len), .little);
            for (elements) |element| {
                const verb_code: u8 = switch (element.verb) {
                    .move_to => 0,
                    .line_to => 1,
                    .quad_to => 2,
                    .cubic_to => 3,
                    .close => 4,
                };
                try writer.writeByte(verb_code);
                const point_count: usize = switch (element.verb) {
                    .move_to, .line_to => 1,
                    .quad_to => 2,
                    .cubic_to => 3,
                    .close => 0,
                };
                for (element.points[0..point_count]) |point| {
                    try writeBinaryPoint(point, writer);
                }
            }
        },
    }
}

/// Paint: tag u8 (1 color / 2 linear_gradient) + payload.
fn writeBinaryPaint(paint: CanvasGpuPaint, writer: anytype) !void {
    switch (paint) {
        .none => unreachable, // callers gate on the paint flag
        .color => |color| {
            try writer.writeByte(1);
            try writeBinaryColor(color, writer);
        },
        .linear_gradient => |gradient| {
            try writer.writeByte(2);
            try writeBinaryPoint(gradient.start, writer);
            try writeBinaryPoint(gradient.end, writer);
            try writer.writeInt(u32, @intCast(gradient.stops.len), .little);
            for (gradient.stops) |stop| {
                try writeBinaryF32(stop.offset, writer);
                try writeBinaryColor(stop.color, writer);
            }
        },
    }
}

/// Image draw: image_id u64 | has_src u8 [src f32[4]] | dst f32[4]
/// | opacity f32 | fit u8 (0 stretch / 1 contain / 2 cover)
/// | sampling u8 (0 nearest / 1 linear) | radius f32[4].
fn writeBinaryImage(image: CanvasGpuImage, writer: anytype) !void {
    try writer.writeInt(u64, image.image_id, .little);
    if (image.src) |src| {
        try writer.writeByte(1);
        try writeBinaryRect(src, writer);
    } else {
        try writer.writeByte(0);
    }
    try writeBinaryRect(image.dst, writer);
    try writeBinaryF32(image.opacity, writer);
    try writer.writeByte(switch (image.fit) {
        .stretch => 0,
        .contain => 1,
        .cover => 2,
    });
    try writer.writeByte(switch (image.sampling) {
        .nearest => 0,
        .linear => 1,
    });
    try writeBinaryRadius(image.radius, writer);
}

/// Text draw: font_id u64 | size f32 | origin f32[2] | color f32[4]
/// | text u32+bytes | has_layout u8 | layout { max_width f32,
/// line_height f32, wrap u8 (0 none / 1 word / 2 character), align u8
/// (0 start / 1 center / 2 end), has_lines u8, [line_count u32, lines
/// { x f32, baseline f32, text u32+bytes }] }. Lines carry the same
/// engine-measured breaks the JSON encoding serializes; has_lines = 0
/// keeps the host's legacy wrapping fallback for runs past the line
/// budget.
fn writeBinaryText(text: CanvasGpuText, writer: anytype) !void {
    try writer.writeInt(u64, text.font_id, .little);
    try writeBinaryF32(text.size, writer);
    try writeBinaryPoint(text.origin, writer);
    try writeBinaryColor(text.color, writer);
    try writeBinarySlice(text.text, writer);
    const options = text.text_layout orelse {
        try writer.writeByte(0);
        return;
    };
    try writer.writeByte(1);
    try writeBinaryF32(nonNegative(options.max_width), writer);
    try writeBinaryF32(nonNegative(options.line_height), writer);
    try writer.writeByte(switch (options.wrap) {
        .none => 0,
        .word => 1,
        .character => 2,
    });
    try writer.writeByte(switch (options.alignment) {
        .start => 0,
        .center => 1,
        .end => 2,
    });
    var lines: [max_packet_text_layout_lines]TextLine = undefined;
    const layout = packetTextLayout(text, options, &lines) orelse {
        try writer.writeByte(0);
        return;
    };
    try writer.writeByte(1);
    try writer.writeInt(u32, @intCast(layout.lines.len), .little);
    for (layout.lines) |line| {
        // Elided lines ship painted bytes (kept prefix + ellipsis),
        // mirroring the JSON encoding, so both packet hosts draw the
        // measured extent verbatim.
        const start = @min(line.text_start, text.text.len);
        const end = @min(text.text.len, start + line.paintedTextLen());
        try writeBinaryF32(line.bounds.x, writer);
        try writeBinaryF32(line.baseline, writer);
        const ellipsis = packetLineEllipsis(line);
        try writer.writeInt(u32, @intCast(end - start + ellipsis.len), .little);
        try writer.writeAll(text.text[start..end]);
        try writer.writeAll(ellipsis);
    }
}

/// Effect: tag u8 (1 shadow / 2 blur) + payload.
fn writeBinaryEffect(effect: CanvasGpuEffect, writer: anytype) !void {
    switch (effect) {
        .none => unreachable, // callers gate on the effect flag
        .shadow => |shadow| {
            try writer.writeByte(1);
            try writeBinaryRect(shadow.rect, writer);
            try writeBinaryRadius(shadow.radius, writer);
            try writeBinaryF32(shadow.offset.dx, writer);
            try writeBinaryF32(shadow.offset.dy, writer);
            try writeBinaryF32(shadow.blur, writer);
            try writeBinaryF32(shadow.spread, writer);
            try writeBinaryColor(shadow.color, writer);
        },
        .blur => |blur| {
            try writer.writeByte(2);
            try writeBinaryRect(blur.rect, writer);
            try writeBinaryF32(blur.radius, writer);
        },
    }
}

fn writeBinarySlice(bytes: []const u8, writer: anytype) !void {
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}

fn writeBinaryF32(value: f32, writer: anytype) !void {
    try writer.writeInt(u32, @bitCast(value), .little);
}

fn writeBinaryRect(rect: geometry.RectF, writer: anytype) !void {
    try writeBinaryF32(rect.x, writer);
    try writeBinaryF32(rect.y, writer);
    try writeBinaryF32(rect.width, writer);
    try writeBinaryF32(rect.height, writer);
}

fn writeBinaryPoint(point: geometry.PointF, writer: anytype) !void {
    try writeBinaryF32(point.x, writer);
    try writeBinaryF32(point.y, writer);
}

fn writeBinaryColor(color: Color, writer: anytype) !void {
    try writeBinaryF32(color.r, writer);
    try writeBinaryF32(color.g, writer);
    try writeBinaryF32(color.b, writer);
    try writeBinaryF32(color.a, writer);
}

fn writeBinaryRadius(radius: Radius, writer: anytype) !void {
    try writeBinaryF32(radius.top_left, writer);
    try writeBinaryF32(radius.top_right, writer);
    try writeBinaryF32(radius.bottom_right, writer);
    try writeBinaryF32(radius.bottom_left, writer);
}

fn writeBinaryAffine(matrix: Affine, writer: anytype) !void {
    try writeBinaryF32(matrix.a, writer);
    try writeBinaryF32(matrix.b, writer);
    try writeBinaryF32(matrix.c, writer);
    try writeBinaryF32(matrix.d, writer);
    try writeBinaryF32(matrix.tx, writer);
    try writeBinaryF32(matrix.ty, writer);
}
