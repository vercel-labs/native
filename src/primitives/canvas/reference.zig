const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");
const frame_model = @import("frame.zig");

const Error = canvas.Error;
const ImageId = canvas.ImageId;
const Color = drawing_model.Color;
const Affine = drawing_model.Affine;
const Radius = drawing_model.Radius;
const LinearGradient = drawing_model.LinearGradient;
const Fill = drawing_model.Fill;
const FillRect = drawing_model.FillRect;
const StrokeRect = drawing_model.StrokeRect;
const FillRoundedRect = drawing_model.FillRoundedRect;
const Line = drawing_model.Line;
const PathElement = drawing_model.PathElement;
const FillPath = drawing_model.FillPath;
const StrokePath = drawing_model.StrokePath;
const ImageFit = drawing_model.ImageFit;
const ImageSampling = drawing_model.ImageSampling;
const DrawImage = drawing_model.DrawImage;
const Shadow = drawing_model.Shadow;
const Blur = drawing_model.Blur;
const DrawText = text_model.DrawText;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const RenderCommand = render_model.RenderCommand;
const CanvasRenderPass = frame_model.CanvasRenderPass;

const layoutTextRun = text_model.layoutTextRun;
const textLineBounds = text_model.textLineBounds;
const estimatedGlyphAdvance = text_model.estimatedGlyphAdvance;
const measureTextAdvance = text_model.measureTextAdvance;
const nextTextOffset = text_model.nextTextOffset;

const reference_blur = @import("reference_blur.zig");
const reference_paths = @import("reference_paths.zig");
const vector = @import("vector.zig");
const font_ttf = @import("font_ttf.zig");

/// Element budget for one glyph outline: the bundled face's densest
/// glyphs stay well under this (maxp: 96 points per simple glyph).
const reference_glyph_path_capacity: usize = 256;

const referenceBlurKernel = reference_blur.referenceBlurKernel;
const referenceBlurSampleWithKernel = reference_blur.referenceBlurSampleWithKernel;
const referenceBlurSample = reference_blur.referenceBlurSample;
const referenceDistanceToSegment = reference_paths.referenceDistanceToSegment;

const max_reference_text_layout_lines: usize = 64;
const max_reference_blur_kernel_samples: usize = 4096;

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

    pub fn clearRect(self: ReferenceRenderSurface, rect: geometry.RectF, color: Color) void {
        const pixel_rect = referencePixelRect(rect, self.width, self.height) orelse return;
        const pixel = colorToRgba8(color);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const index = (y * self.width + x) * 4;
                self.pixels[index + 0] = pixel[0];
                self.pixels[index + 1] = pixel[1];
                self.pixels[index + 2] = pixel[2];
                self.pixels[index + 3] = pixel[3];
            }
        }
    }

    pub fn renderPass(self: ReferenceRenderSurface, pass: CanvasRenderPass, clear_color: Color) Error!void {
        const scale = referencePassScale(pass.scale);
        const scissor = if (pass.scissorBounds()) |bounds| referenceScaleRect(bounds, scale) else null;
        switch (pass.loadAction()) {
            .skip => return,
            .clear => self.clear(clear_color),
            .load => if (scissor) |bounds| self.clearRect(bounds, clear_color),
        }
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
        // Anti-aliased scanline fill via the shared vector core. The wire
        // command keeps its historical even-odd interiorness; consumers
        // wanting nonzero (glyphs, icons) call the vector core directly.
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var sink = ReferenceCoverageSink{
            .surface = self,
            .fill = value.fill,
            .transform = command.transform,
            .opacity = command.opacity,
        };
        vector.fillPath(
            value.elements,
            command.transform,
            .even_odd,
            vector.default_tolerance,
            referenceVectorClip(pixel_rect),
            &sink,
        ) catch return error.ReferenceRenderUnsupportedCommand;
    }

    fn strokePath(self: ReferenceRenderSurface, command: RenderCommand, value: StrokePath, draw_bounds: geometry.RectF) Error!void {
        // Anti-aliased stroke-to-outline via the shared vector core with
        // round caps and joins, matching the historical distance-field
        // semantics of this command.
        const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
        if (stroke_width <= 0) return;
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var sink = ReferenceCoverageSink{
            .surface = self,
            .fill = value.stroke.fill,
            .transform = command.transform,
            .opacity = command.opacity,
        };
        vector.strokePath(
            value.elements,
            command.transform,
            .{ .width = stroke_width, .cap = .round, .join = .round },
            vector.default_tolerance,
            referenceVectorClip(pixel_rect),
            &sink,
        ) catch return error.ReferenceRenderUnsupportedCommand;
    }

    fn drawImage(self: ReferenceRenderSurface, command: RenderCommand, value: DrawImage, draw_bounds: geometry.RectF) Error!void {
        // A draw whose image is absent from the resource set skips: with
        // runtime-registered images, "not registered (yet/anymore)" is a
        // legitimate transient state (an avatar mid-fetch, an id
        // unregistered while a stale tree still references it), and a
        // pure view must not be able to fail presentation with it. A
        // PRESENT image whose pixel buffer is undersized stays a loud
        // error — that is a corrupt resource, not a lifecycle state.
        const image = self.findImage(value.image_id) orelse return;
        if (referenceImagePixelLen(image.width, image.height)) |image_len| {
            if (image.pixels.len < image_len) return error.ReferenceRenderUnsupportedCommand;
        } else return error.ReferenceRenderUnsupportedCommand;

        const src_rect = referenceImageSourceRect(image, value.src) orelse return;
        const local_dst = referenceImageDestinationRect(value.dst, src_rect, value.fit) orelse return;
        const dst_rect = command.transform.transformRect(local_dst).normalized();
        // The rounded mask applies over the REQUESTED destination (the
        // widget frame), not the fit-expanded rect a `.cover` draw fills.
        const mask_rect = command.transform.transformRect(value.dst).normalized();
        const mask_radius = referenceScaleRadius(value.radius, command.transform);
        const has_mask = mask_radius.top_left > 0 or mask_radius.top_right > 0 or
            mask_radius.bottom_right > 0 or mask_radius.bottom_left > 0;
        const clipped = geometry.RectF.intersection(dst_rect, draw_bounds.normalized());
        const pixel_rect = referencePixelRect(clipped, self.width, self.height) orelse return;
        const image_opacity = std.math.clamp(value.opacity, 0, 1);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (!dst_rect.containsPoint(point)) continue;
                if (has_mask and !referencePointInRoundedRect(point, mask_rect, mask_radius)) continue;
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
        const kernel_width: usize = @intCast(kernel_radius * 2 + 1);
        const kernel_sample_count = kernel_width * kernel_width;
        var kernel_storage: [max_reference_blur_kernel_samples]f32 = undefined;
        const kernel: ?[]const f32 = if (kernel_sample_count <= kernel_storage.len)
            referenceBlurKernel(kernel_storage[0..kernel_sample_count], kernel_radius, radius)
        else
            null;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const x_i: i64 = @intCast(x);
                const y_i: i64 = @intCast(y);
                const blurred = if (kernel) |weights|
                    referenceBlurSampleWithKernel(scratch, self.width, self.height, x_i, y_i, kernel_radius, weights)
                else
                    referenceBlurSample(scratch, self.width, self.height, x_i, y_i, kernel_radius, radius);
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
                const pen_x = value.origin.x + glyph.x - first_x + dx;
                const baseline = line.baseline + glyph.y;
                const glyph_rect = geometry.RectF.init(pen_x, baseline - value.size, width, value.size);
                const codepoint = referenceGlyphCodepoint(value.text, glyph.text_start, glyph.text_len);
                self.drawGlyphBox(command, value, draw_bounds, codepoint, pen_x, baseline, glyph_rect);
            }
            return;
        }

        // Without shaped glyphs the pen walks the same per-cluster
        // advances layout measured with — the injected provider when the
        // run carries one, the deterministic estimator otherwise — so
        // painted lines end exactly at their measured bounds. Walking the
        // raw estimator here while a provider measured the line dropped
        // one tail glyph per multibyte codepoint: the flat 0.65em
        // multibyte estimate overshot the provider's real advances and
        // pushed the tail past the measured clip bounds.
        const measure = if (value.text_layout) |options| options.measure else null;
        const end = @min(value.text.len, line.text_start + line.text_len);
        var text_offset: usize = line.text_start;
        var x = line.bounds.x;
        while (text_offset < end) {
            const next_offset = nextTextOffset(value.text, text_offset);
            const advance = measureTextAdvance(measure, value.font_id, value.size, value.text, line.text_start, text_offset, next_offset);
            defer {
                text_offset = next_offset;
                x += advance;
            }
            if (isReferenceTextSpace(value.text[text_offset])) continue;
            const glyph_rect = geometry.RectF.init(x, line.baseline - value.size, advance, value.size);
            const codepoint = referenceGlyphCodepoint(value.text, text_offset, next_offset - text_offset);
            self.drawGlyphBox(command, value, draw_bounds, codepoint, x, line.baseline, glyph_rect);
        }
    }

    /// Paint one glyph: the real Geist outline through the vector core
    /// when the codepoint resolves, the historical block rect otherwise
    /// (unmapped codepoints, glyphs beyond the outline budgets, or draws
    /// carrying no text bytes). Layout is untouched — the pen position
    /// and advance still come from the deterministic estimator.
    fn drawGlyphBox(
        self: ReferenceRenderSurface,
        command: RenderCommand,
        value: DrawText,
        draw_bounds: geometry.RectF,
        codepoint: ?u21,
        pen_x: f32,
        baseline: f32,
        block_rect: geometry.RectF,
    ) void {
        if (codepoint) |cp| {
            if (self.drawGlyphOutline(command, value, draw_bounds, cp, pen_x, baseline, block_rect.width)) return;
        }
        self.fillTextRect(command.transform.transformRect(block_rect).normalized(), draw_bounds, value.color, command.opacity);
    }

    /// True when the glyph was handled (drawn, or intentionally empty
    /// like a space); false requests the block fallback.
    fn drawGlyphOutline(
        self: ReferenceRenderSurface,
        command: RenderCommand,
        value: DrawText,
        draw_bounds: geometry.RectF,
        codepoint: u21,
        pen_x: f32,
        baseline: f32,
        cell_advance: f32,
    ) bool {
        const face = &font_ttf.geist_regular;
        const glyph = face.glyphIndex(codepoint);
        if (glyph == 0) return false;

        // Center the outline's natural advance inside its layout cell when
        // the cell is wider — mono runs charge a fixed 0.6 em pitch while
        // the bundled sans outlines keep proportional ink, and left-aligned
        // ink read as clumps with stray gaps ("i nl i ne"). Real mono faces
        // center narrow glyphs in the fixed cell, so the reference render
        // does the same. Sans cells equal their natural advance (inset 0),
        // keeping every proportional golden byte-identical.
        const natural_advance = value.size * (face.advance(glyph) / face.units_per_em);
        const cell_inset = @max(0, (cell_advance - natural_advance) * 0.5);

        const scale = value.size / face.units_per_em;
        // Font units are y-up; bake the flip and em scaling into the pen
        // placement, then apply the command transform on top.
        const local = Affine{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = pen_x + cell_inset, .ty = baseline };
        const total = command.transform.multiply(local);

        var builder = vector.PathBuilder(reference_glyph_path_capacity){};
        face.glyphOutline(glyph, total, &builder) catch return false;
        if (builder.slice().len == 0) return true; // Space: nothing to ink.

        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return true;
        var sink = ReferenceCoverageSink{
            .surface = self,
            .fill = .{ .color = value.color },
            .transform = command.transform,
            .opacity = command.opacity,
        };
        // The outline is already in device space; TrueType interiorness
        // is the nonzero rule.
        vector.fillPath(
            builder.slice(),
            Affine.identity(),
            .nonzero,
            vector.default_tolerance,
            referenceVectorClip(pixel_rect),
            &sink,
        ) catch return false;
        return true;
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
        return findReferenceImage(self.images, id);
    }
};

/// Per-pixel coverage sink for the vector core: samples the fill at the
/// pixel center and blends with the coverage folded into alpha.
const ReferenceCoverageSink = struct {
    surface: ReferenceRenderSurface,
    fill: Fill,
    transform: Affine,
    opacity: f32,

    pub fn pixel(self: *ReferenceCoverageSink, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= self.surface.width or py >= self.surface.height) return;
        const point = referencePixelCenter(px, py);
        const color = referenceSampleFill(self.fill, self.transform, point);
        self.surface.blendPixel(px, py, referenceScaleColorAlpha(color, coverage), self.opacity);
    }
};

fn referenceVectorClip(pixel_rect: ReferencePixelRect) vector.ClipRect {
    return .{
        .x0 = @intCast(pixel_rect.x),
        .y0 = @intCast(pixel_rect.y),
        .x1 = @intCast(pixel_rect.x + pixel_rect.width),
        .y1 = @intCast(pixel_rect.y + pixel_rect.height),
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

const ReferencePixelRect = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
};

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

/// Decode the first codepoint of the cluster `text[start..start+len]`;
/// null when the draw carries no text bytes for the glyph (pure glyph-id
/// draws keep their historical block rendering).
fn referenceGlyphCodepoint(text: []const u8, start: usize, len: usize) ?u21 {
    if (len == 0 or start >= text.len) return null;
    const end = @min(text.len, start + len);
    const cluster = text[start..end];
    const seq_len = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return null;
    if (seq_len > cluster.len) return null;
    return std.unicode.utf8Decode(cluster[0..seq_len]) catch null;
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

fn findReferenceImage(images: []const ReferenceImage, id: ImageId) ?ReferenceImage {
    for (images) |image| {
        if (image.id == id) return image;
    }
    return null;
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
fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
