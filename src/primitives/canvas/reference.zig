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
const text_ellipsis_codepoint = text_model.text_ellipsis_codepoint;
const estimatedGlyphAdvance = text_model.estimatedGlyphAdvance;
const measureTextAdvance = text_model.measureTextAdvance;
const nextTextOffset = text_model.nextTextOffset;

const reference_blur = @import("reference_blur.zig");
const reference_paths = @import("reference_paths.zig");
const render_fingerprints = @import("render_fingerprints.zig");
const vector = @import("vector.zig");
const font_ttf = @import("font_ttf.zig");

/// Element budget for one glyph outline: the bundled face's densest
/// glyphs stay well under this (maxp: 96 points per simple glyph).
const reference_glyph_path_capacity: usize = 256;

const referenceBlurKernel = reference_blur.referenceBlurKernel;
const referenceBlurSampleWithKernel = reference_blur.referenceBlurSampleWithKernel;
const referenceBlurSample = reference_blur.referenceBlurSample;
pub const ReferenceRenderMemo = @import("reference_memo.zig").ReferenceRenderMemo;
const referenceDistanceToSegment = reference_paths.referenceDistanceToSegment;

const max_reference_text_layout_lines: usize = 64;
const max_reference_blur_kernel_samples: usize = 4096;

pub const ReferenceImage = struct {
    id: ImageId,
    width: usize,
    height: usize,
    pixels: []const u8,
};

/// One runtime-registered font face the reference renderer resolves text
/// runs against: a `FontId` mapped to a parsed TrueType face. The face
/// (and the bytes it borrows) must outlive the surface; runtimes own
/// both in their registered-font pool.
pub const ReferenceFont = struct {
    id: canvas.FontId,
    face: *const font_ttf.Face,
};

pub const ReferenceRenderSurface = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    scratch: ?[]u8 = null,
    images: []const ReferenceImage = &.{},
    fonts: []const ReferenceFont = &.{},
    /// Optional memo for large per-pixel commands (see
    /// `ReferenceRenderMemo`): when present, a heavyweight command
    /// (backdrop blur, drop shadow, big fills) whose inputs are
    /// byte-identical to a previous render replays its stored output
    /// instead of re-running its pixel loop. Same bytes either way —
    /// this only moves time.
    render_memo: ?*ReferenceRenderMemo = null,

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

    /// Runtime-registered faces text runs resolve against before the
    /// bundled fallback mapping (see `referenceFaceForFontId`).
    pub fn withFonts(self: ReferenceRenderSurface, fonts: []const ReferenceFont) ReferenceRenderSurface {
        var next = self;
        next.fonts = fonts;
        return next;
    }

    /// Attach a render memo that outlives this render pass (one per
    /// live scene). Purely an optimization: output bytes are identical
    /// with or without it.
    pub fn withRenderMemo(self: ReferenceRenderSurface, memo: ?*ReferenceRenderMemo) ReferenceRenderSurface {
        var next = self;
        next.render_memo = memo;
        return next;
    }

    /// A memo lookup in flight for one command: the memo to store into
    /// and the fully built key. Null everywhere a memo doesn't apply
    /// (no memo attached, or the rect is too small to be worth a hash).
    const MemoProbe = struct {
        memo: *ReferenceRenderMemo,
        key: ReferenceRenderMemo.Key,
    };

    /// Build the memo key for a per-pixel command about to run.
    /// `params_hash` must cover every command parameter the pixel loop
    /// reads (see `referenceMemoParamsHash`); `apron_rows` is how far
    /// beyond its rect the command reads destination pixels (the blur's
    /// kernel radius; zero for single-pixel blends). Must be called
    /// BEFORE the command writes any pixels — the key hashes the
    /// destination bytes as the command will read them.
    fn memoProbe(self: ReferenceRenderSurface, pixel_rect: ReferencePixelRect, apron_rows: usize, params_hash: u64) ?MemoProbe {
        const memo = self.render_memo orelse return null;
        if (pixel_rect.width * pixel_rect.height < memo.min_pixels) return null;
        return .{
            .memo = memo,
            .key = ReferenceRenderMemo.keyFor(
                self.pixels,
                self.width,
                self.height,
                pixel_rect.x,
                pixel_rect.y,
                pixel_rect.width,
                pixel_rect.height,
                apron_rows,
                params_hash,
            ),
        };
    }

    /// Replay a memoized command's output rows into the framebuffer.
    /// True on a hit (the command is done); false means render normally
    /// and offer the result to `memoStore`.
    fn memoReplay(self: ReferenceRenderSurface, probe: ?MemoProbe, pixel_rect: ReferencePixelRect) bool {
        const p = probe orelse return false;
        const cached = p.memo.find(p.key) orelse return false;
        var row: usize = 0;
        while (row < pixel_rect.height) : (row += 1) {
            const src_offset = row * pixel_rect.width * 4;
            const dst_offset = ((pixel_rect.y + row) * self.width + pixel_rect.x) * 4;
            @memcpy(
                self.pixels[dst_offset .. dst_offset + pixel_rect.width * 4],
                cached[src_offset .. src_offset + pixel_rect.width * 4],
            );
        }
        return true;
    }

    /// Remember a freshly rendered command's output rows for the next
    /// frame. Storage failure just means the next identical run
    /// recomputes.
    fn memoStore(self: ReferenceRenderSurface, probe: ?MemoProbe, pixel_rect: ReferencePixelRect) void {
        const p = probe orelse return;
        const buffer = p.memo.store(p.key) orelse return;
        var row: usize = 0;
        while (row < pixel_rect.height) : (row += 1) {
            const dst_offset = row * pixel_rect.width * 4;
            const src_offset = ((pixel_rect.y + row) * self.width + pixel_rect.x) * 4;
            @memcpy(
                buffer[dst_offset .. dst_offset + pixel_rect.width * 4],
                self.pixels[src_offset .. src_offset + pixel_rect.width * 4],
            );
        }
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
        // One-time sRGB decode/encode table fills (see the tables' doc
        // comments); outside the per-pixel loops so the hot path pays no
        // checks.
        ensureSrgbToLinearByteTable();
        ensureLinearToSrgbTable();
        // Fresh per-pass panel-fill budget (see the memo's doc comment).
        if (self.render_memo) |memo| memo.image_scale_fills_this_pass = 0;
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
        // Render memo: a large translucent fill (the modal scrim's wash
        // covers the whole viewport) blends every pixel; it reads only
        // the pixel it writes, so no apron rows join the key.
        const probe = self.memoProbe(pixel_rect, 0, referenceMemoParamsHash(1, command, value));
        if (self.memoReplay(probe, pixel_rect)) return;
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), command.opacity);
            }
        }
        self.memoStore(probe, pixel_rect);
    }

    fn fillRoundedRect(self: ReferenceRenderSurface, command: RenderCommand, value: FillRoundedRect, draw_bounds: geometry.RectF) Error!void {
        const rect = command.transform.transformRect(value.rect).normalized();
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        const radius = referenceScaleRadius(value.radius, command.transform);
        // Render memo: a large rounded fill (a dialog surface) tests the
        // corner mask per pixel; it reads only the pixel it blends into,
        // so no apron rows join the key.
        const probe = self.memoProbe(pixel_rect, 0, referenceMemoParamsHash(2, command, value));
        if (self.memoReplay(probe, pixel_rect)) return;
        // Square-cornered fills keep the legacy binary pixel-center
        // test (bit-identical on integer bounds); rounded fills take
        // the anti-aliased signed-distance coverage.
        const binary = referenceRadiusIsZero(radius);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (binary) {
                    if (referencePointInRoundedRect(point, rect, radius)) self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), command.opacity);
                    continue;
                }
                const coverage = referenceRoundedRectCoverage(point, rect, radius);
                if (coverage > 0) self.blendPixelCoverage(@intCast(x), @intCast(y), referenceSampleFill(value.fill, command.transform, point), coverage, command.opacity, .linear_light);
            }
        }
        self.memoStore(probe, pixel_rect);
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
        // Render memo: a rounded border's pixel rect spans the WHOLE
        // stroked rect (a dialog outline covers the dialog), and every
        // pixel tests two corner masks. It reads only the pixel it
        // blends into, so no apron rows join the key.
        const probe = self.memoProbe(pixel_rect, 0, referenceMemoParamsHash(5, command, value));
        if (self.memoReplay(probe, pixel_rect)) return;
        // Square-cornered borders keep the legacy binary ring test
        // (bit-identical on integer bounds). Rounded borders derive
        // BOTH ring edges from the same signed-distance field —
        // coverage is outer-edge coverage minus inner-edge coverage —
        // so the border weight stays uniform around the whole shape
        // (the inner edge stays in the field even when the inset
        // radius bottoms out at a square corner).
        const binary = referenceRadiusIsZero(radius);
        var y = pixel_rect.y;
        while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
            var x = pixel_rect.x;
            while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                const point = referencePixelCenter(x, y);
                if (binary) {
                    if (referencePointInRoundedRect(point, outer, outer_radius) and !referencePointInRoundedRect(point, inner, inner_radius)) {
                        self.blendPixel(@intCast(x), @intCast(y), referenceSampleFill(value.stroke.fill, command.transform, point), command.opacity);
                    }
                    continue;
                }
                const coverage = std.math.clamp(referenceRoundedRectCoverage(point, outer, outer_radius) - referenceRoundedRectCoverage(point, inner, inner_radius), 0, 1);
                if (coverage > 0) {
                    self.blendPixelCoverage(@intCast(x), @intCast(y), referenceSampleFill(value.stroke.fill, command.transform, point), coverage, command.opacity, .linear_light);
                }
            }
        }
        self.memoStore(probe, pixel_rect);
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
            .coverage_blend = .linear_light,
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
        // Anti-aliased stroke-to-outline via the shared vector core. End
        // caps come from the command's cap channel: butt is the default
        // (matching what hosts draw for an unadorned stroke), and
        // emitters that want round ends — the stroke-icon dialect, the
        // house spinner arc — opt in per command. Joins stay round: the
        // historical distance-field semantics of this command rounded
        // every join, and no emitter has asked for another shape.
        const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
        if (stroke_width <= 0) return;
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        var sink = ReferenceCoverageSink{
            .surface = self,
            .fill = value.stroke.fill,
            .transform = command.transform,
            .opacity = command.opacity,
            .coverage_blend = .linear_light,
        };
        vector.strokePath(
            value.elements,
            command.transform,
            .{ .width = stroke_width, .cap = value.cap, .join = .round },
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
        // Scale-once panel (memo-attached surfaces): a destination
        // pixel's sampled color depends only on its offset inside
        // `dst_rect` and the rect's subpixel phase. `(px + 0.5) -
        // dst_rect.x` and `(offset + 0.5) - phase_x` name the SAME exact
        // real number (`px + 0.5`, `offset + 0.5`, `dst_rect.x`, and its
        // exactly-representable fractional part are all exact f32
        // values), and one IEEE subtraction rounds one exact value one
        // way — so a panel filled with the phase-relative formula holds
        // bit-identical samples to direct evaluation at ANY position
        // with the same phase. The expensive linear resampling then runs
        // once per (image content, size, phase) and every later repaint
        // — the cover-loading cascade, a re-opened view, a whole-pixel
        // move — blends from the panel.
        if (self.imageScalePanel(image, value, src_rect, dst_rect, pixel_rect)) |panel| {
            const dst_x0: i64 = @intFromFloat(@floor(dst_rect.x));
            const dst_y0: i64 = @intFromFloat(@floor(dst_rect.y));
            var y = pixel_rect.y;
            while (y < pixel_rect.y + pixel_rect.height) : (y += 1) {
                var x = pixel_rect.x;
                while (x < pixel_rect.x + pixel_rect.width) : (x += 1) {
                    const point = referencePixelCenter(x, y);
                    if (!dst_rect.containsPoint(point)) continue;
                    if (has_mask and !referencePointInRoundedRect(point, mask_rect, mask_radius)) continue;
                    const column: usize = @intCast(@as(i64, @intCast(x)) - dst_x0);
                    const row: usize = @intCast(@as(i64, @intCast(y)) - dst_y0);
                    const offset = (row * panel.width + column) * 4;
                    const sample = [4]u8{ panel.pixels[offset], panel.pixels[offset + 1], panel.pixels[offset + 2], panel.pixels[offset + 3] };
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
            return;
        }
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

    /// A borrowed sampled panel for this draw, or null when the draw
    /// samples directly (no memo attached, fractional alignment, too
    /// small to matter, over the pool bounds, or allocation failure).
    /// See the alignment proof at the call site.
    const ImageScalePanel = struct {
        pixels: []const u8,
        width: usize,
    };

    fn imageScalePanel(self: ReferenceRenderSurface, image: ReferenceImage, value: DrawImage, src_rect: geometry.RectF, dst_rect: geometry.RectF, pixel_rect: ReferencePixelRect) ?ImageScalePanel {
        const memo = self.render_memo orelse return null;
        // Exact-arithmetic bounds: pixel offsets and phases must stay in
        // f32's exact-integer range for the phase-relative identity
        // (2^22 leaves a full bit of headroom under 2^24).
        const limit: f32 = 4_194_304;
        if (!(dst_rect.width > 0 and dst_rect.height > 0)) return null;
        if (@abs(dst_rect.x) > limit or @abs(dst_rect.y) > limit or dst_rect.width > limit or dst_rect.height > limit) return null;
        // The panel spans the rect's full pixel coverage: columns
        // floor(minX) .. ceil(maxX)-1, exactly the extent
        // `referencePixelRect` can ever visit for this rect.
        const x_floor = @floor(dst_rect.x);
        const y_floor = @floor(dst_rect.y);
        const phase_x = dst_rect.x - x_floor;
        const phase_y = dst_rect.y - y_floor;
        const x_end: i64 = referenceCeil(dst_rect.maxX());
        const y_end: i64 = referenceCeil(dst_rect.maxY());
        const panel_width: usize = @intCast(@max(0, x_end - @as(i64, @intFromFloat(x_floor))));
        const panel_height: usize = @intCast(@max(0, y_end - @as(i64, @intFromFloat(y_floor))));
        if (panel_width == 0 or panel_height == 0) return null;
        if (panel_width * panel_height < memo.min_pixels) return null;
        const key = ReferenceRenderMemo.ImageScaleKey{
            .content_hash = render_fingerprints.renderImageFingerprintForResource(value.image_id, image),
            .src_x = src_rect.x,
            .src_y = src_rect.y,
            .src_width = src_rect.width,
            .src_height = src_rect.height,
            .dst_width = dst_rect.width,
            .dst_height = dst_rect.height,
            .phase_x = phase_x,
            .phase_y = phase_y,
            .dst_width_px = panel_width,
            .dst_height_px = panel_height,
            .sampling = @intFromEnum(value.sampling),
        };
        if (memo.findImageScale(key)) |pixels| return .{ .pixels = pixels, .width = panel_width };
        // Fill only when this draw would render the WHOLE panel anyway
        // (fully on-surface, unclipped by the scissor) and the pass has
        // fill budget left: a clipped or over-budget miss samples its
        // visible pixels directly instead of paying a full-panel fill
        // for a panel a re-phasing scroll may never reuse.
        if (pixel_rect.width != panel_width or pixel_rect.height != panel_height) return null;
        if (memo.image_scale_fills_this_pass >= ReferenceRenderMemo.max_image_scale_fills_per_pass) return null;
        const buffer = memo.storeImageScale(key) orelse return null;
        memo.image_scale_fills_this_pass += 1;
        // Fill with the phase-relative formula — bit-identical to the
        // absolute one (see the call site). Edge cells whose center
        // falls outside the rect hold clamped samples the blend loop's
        // containment check never reads.
        var row: usize = 0;
        while (row < panel_height) : (row += 1) {
            const v = std.math.clamp(((@as(f32, @floatFromInt(row)) + 0.5) - phase_y) / dst_rect.height, 0, 1);
            var column: usize = 0;
            while (column < panel_width) : (column += 1) {
                const u = std.math.clamp(((@as(f32, @floatFromInt(column)) + 0.5) - phase_x) / dst_rect.width, 0, 1);
                const sample = referenceSampleImage(image, src_rect, u, v, value.sampling);
                const offset = (row * panel_width + column) * 4;
                buffer[offset] = sample[0];
                buffer[offset + 1] = sample[1];
                buffer[offset + 2] = sample[2];
                buffer[offset + 3] = sample[3];
            }
        }
        return .{ .pixels = buffer, .width = panel_width };
    }

    fn drawShadow(self: ReferenceRenderSurface, command: RenderCommand, value: Shadow, draw_bounds: geometry.RectF) Error!void {
        const scale = referenceTransformScale(command.transform);
        const blur_radius = nonNegative(value.blur) * scale;
        const shadow_rect = command.transform.transformRect(referenceSpreadRect(value.rect.normalized().translate(value.offset), value.spread)).normalized();
        if (shadow_rect.isEmpty()) return;
        const shadow_radius = referenceScaleRadius(referenceSpreadRadius(value.radius, value.spread), command.transform);
        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;

        // Render memo: the shadow evaluates a rounded-rect distance
        // field per pixel over its whole halo. It reads only the pixel
        // it blends into, so no apron rows join the key.
        const probe = self.memoProbe(pixel_rect, 0, referenceMemoParamsHash(3, command, value));
        if (self.memoReplay(probe, pixel_rect)) return;

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

        self.memoStore(probe, pixel_rect);
    }

    fn drawBlur(self: ReferenceRenderSurface, command: RenderCommand, value: Blur, draw_bounds: geometry.RectF) Error!void {
        const scratch = self.scratch orelse return error.ReferenceRenderUnsupportedCommand;
        const radius = nonNegative(value.radius) * referenceTransformScale(command.transform);
        if (radius <= 0) return;

        const pixel_rect = referencePixelRect(draw_bounds, self.width, self.height) orelse return;
        const kernel_radius: i64 = @intCast(@max(1, referenceCeil(radius)));

        // Render memo: the blur is the renderer's most expensive command
        // — an O(kernel²) Gaussian gather per output pixel over what is
        // usually the whole viewport (the modal scrim). Its inputs are
        // the source rows within a kernel-radius apron of the rect (the
        // mix's destination pixels lie inside that region too), so the
        // apron rows join the key.
        const probe = self.memoProbe(pixel_rect, @intCast(kernel_radius), referenceMemoParamsHash(4, command, value));
        if (self.memoReplay(probe, pixel_rect)) return;

        @memcpy(scratch[0..self.pixels.len], self.pixels);
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

        self.memoStore(probe, pixel_rect);
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
            // An elided line inks only its kept prefix, then the marker.
            const glyph_end = @min(value.glyphs.len, line.glyph_start + line.paintedGlyphLen());
            const raw_bounds = textLineBounds(value, line.text_start, line.paintedTextLen(), line.glyph_start, line.paintedGlyphLen(), line.baseline, line.bounds.height);
            const first_x = if (line.glyph_start < value.glyphs.len) value.glyphs[line.glyph_start].x else 0;
            const dx = line.bounds.x - raw_bounds.x;
            for (value.glyphs[line.glyph_start..glyph_end]) |glyph| {
                const width = estimatedGlyphAdvance(glyph, value.size);
                const pen_x = value.origin.x + glyph.x - first_x + dx;
                const baseline = line.baseline + glyph.y;
                const glyph_rect = geometry.RectF.init(pen_x, baseline - value.size, width, value.size);
                const codepoint = referenceGlyphCodepoint(value.text, glyph.text_start, glyph.text_len);
                self.drawGlyphBox(command, value, draw_bounds, codepoint, pen_x, baseline, glyph_rect);
            }
            self.drawTextLineEllipsis(command, value, draw_bounds, line);
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
        const end = @min(value.text.len, line.text_start + line.paintedTextLen());
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
        self.drawTextLineEllipsis(command, value, draw_bounds, line);
    }

    /// The trailing ellipsis of an elided line, drawn at the painted
    /// right edge with the advance layout reserved for it — the same
    /// codepoint-to-outline path every glyph takes, so a face lacking
    /// U+2026 falls back to the documented block treatment.
    fn drawTextLineEllipsis(self: ReferenceRenderSurface, command: RenderCommand, value: DrawText, draw_bounds: geometry.RectF, line: TextLine) void {
        if (!line.hasEllipsis()) return;
        const pen_x = line.bounds.maxX() - line.ellipsis_advance;
        const glyph_rect = geometry.RectF.init(pen_x, line.baseline - value.size, line.ellipsis_advance, value.size);
        self.drawGlyphBox(command, value, draw_bounds, text_ellipsis_codepoint, pen_x, line.baseline, glyph_rect);
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
        const face = referenceFaceForFontId(self.fonts, value.font_id);
        const glyph = face.glyphIndex(codepoint);
        if (glyph == 0) return false;

        // Center the outline's natural advance inside its layout cell when
        // the cell is wider. With the bundled mono face this is the
        // identity for every covered glyph (natural advance == the 0.6 em
        // cell layout charges, so inset 0), and sans cells equal their
        // natural advance too — the inset stays for any future face whose
        // ink runs narrower than its layout cell.
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
        // Glyph coverage blends in sRGB, not linear light (see
        // `CoverageBlend`): apparent text weight is set by how edge
        // pixels darken, and re-blending them in linear light thins
        // dark-on-light runs and blooms light-on-dark runs at UI sizes.
        var sink = ReferenceCoverageSink{
            .surface = self,
            .fill = .{ .color = value.color },
            .transform = command.transform,
            .opacity = command.opacity,
            .coverage_blend = .srgb,
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

    /// Blend one pixel whose fractional alpha is ANTI-ALIASED EDGE
    /// COVERAGE (kept separate from the color's own alpha so the blend
    /// can tell an AA fringe from a translucent wash — see
    /// `CoverageBlend`).
    fn blendPixelCoverage(self: ReferenceRenderSurface, x: usize, y: usize, color: Color, coverage: f32, opacity: f32, blend: CoverageBlend) void {
        const index = (y * self.width + x) * 4;
        const dst = [4]u8{
            self.pixels[index + 0],
            self.pixels[index + 1],
            self.pixels[index + 2],
            self.pixels[index + 3],
        };
        const out = blendRgba8Coverage(dst, color, coverage, opacity, blend);
        self.pixels[index + 0] = out[0];
        self.pixels[index + 1] = out[1];
        self.pixels[index + 2] = out[2];
        self.pixels[index + 3] = out[3];
    }

    fn findImage(self: ReferenceRenderSurface, id: ImageId) ?ReferenceImage {
        return findReferenceImage(self.images, id);
    }
};

/// Which space a shape's fractional edge coverage blends in.
///
/// GEOMETRY — rounded rects, filled/stroked paths, icons, chart marks —
/// blends its anti-aliased edge pixels in LINEAR LIGHT. Compositing the
/// sRGB-encoded bytes directly weights half coverage far below half the
/// light (a 50% black-on-white fringe lands near 21% luminance instead
/// of 50%), so every edge grows a dark rim on light backgrounds (a light
/// halo on dark ones) that reads as jagged even though the coverage
/// values are correct. Decoding to linear light, blending, and
/// re-encoding removes the rim.
///
/// GLYPHS stay in sRGB. Text coverage funnels through the exact same
/// vector core, but apparent text WEIGHT is a product of how edge pixels
/// darken: the same coverage blended in linear light renders visibly
/// thinner dark-on-light runs and bloomier light-on-dark runs at UI
/// sizes, and the toolkit's type ramp was tuned against sRGB-blended
/// stems. sRGB glyph compositing also matches the packet-backed macOS
/// text pipeline, so mixed CPU/host frames keep one text weight.
///
/// Only opaque-source fractional-coverage pixels differ between the two
/// modes: fully covered pixels short-circuit identically in either
/// space, and translucent sources (washes, scrims, faded layers) keep
/// sRGB blending so overlay brightness — tuned in sRGB terms — is
/// untouched and an AA edge never diverges from the interior it borders.
const CoverageBlend = enum { linear_light, srgb };

/// Per-pixel coverage sink for the vector core: samples the fill at the
/// pixel center and blends with the coverage, in the blend space the
/// emitter declared (geometry linear-light, glyphs sRGB — see
/// `CoverageBlend`).
const ReferenceCoverageSink = struct {
    surface: ReferenceRenderSurface,
    fill: Fill,
    transform: Affine,
    opacity: f32,
    coverage_blend: CoverageBlend,

    pub fn pixel(self: *ReferenceCoverageSink, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= self.surface.width or py >= self.surface.height) return;
        const point = referencePixelCenter(px, py);
        const color = referenceSampleFill(self.fill, self.transform, point);
        self.surface.blendPixelCoverage(px, py, color, coverage, self.opacity, self.coverage_blend);
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

/// Hash a command's parameters for the render memo key: the kind tag
/// keeps different command types with coincidentally equal fields apart,
/// and `command.opacity` + `command.transform` join the value struct
/// because the pixel loops read all three. Clip needs no hashing — the
/// planner folds it into `command.bounds`, which reaches the key through
/// the pixel rect.
fn referenceMemoParamsHash(kind: u8, command: RenderCommand, value: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0x9e37_79b9);
    referenceMemoHashValue(&hasher, kind);
    referenceMemoHashValue(&hasher, command.opacity);
    referenceMemoHashValue(&hasher, command.transform);
    referenceMemoHashValue(&hasher, value);
    return hasher.final();
}

/// Recursively hash a plain value BIT-EXACTLY: floats hash their bit
/// patterns (so -0.0 and 0.0, or two NaNs, are distinct keys — stricter
/// than `==`, which can only cause a spurious miss, never a wrong hit).
/// Supports exactly the shapes command values are built from; anything
/// else is a compile error so a new field can't silently escape the key.
fn referenceMemoHashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: Bits = @bitCast(value);
            hasher.update(std.mem.asBytes(&bits));
        },
        .int => hasher.update(std.mem.asBytes(&value)),
        .bool => hasher.update(&[1]u8{@intFromBool(value)}),
        .@"enum" => referenceMemoHashValue(hasher, @intFromEnum(value)),
        .optional => {
            if (value) |inner| {
                hasher.update(&[1]u8{1});
                referenceMemoHashValue(hasher, inner);
            } else {
                hasher.update(&[1]u8{0});
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| referenceMemoHashValue(hasher, @field(value, field.name));
        },
        .@"union" => {
            switch (value) {
                inline else => |inner, tag| {
                    referenceMemoHashValue(hasher, @intFromEnum(tag));
                    referenceMemoHashValue(hasher, inner);
                },
            }
        },
        .pointer => |info| {
            // Slices of plain items (a gradient's stops). Length first so
            // concatenations can't collide.
            comptime std.debug.assert(info.size == .slice);
            referenceMemoHashValue(hasher, value.len);
            for (value) |item| referenceMemoHashValue(hasher, item);
        },
        .array => {
            for (value) |item| referenceMemoHashValue(hasher, item);
        },
        else => @compileError("unsupported memo param type " ++ @typeName(T)),
    }
}

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

/// The face a run's font id inks with: a runtime-registered face when
/// the id matches one (validated at registration, so a registered id
/// always resolves — no render-time fallback decision), otherwise the
/// bundled mapping — the mono face for the reserved mono id, the sans
/// face for everything else (the weight and italic span variants keep
/// the regular outlines at their estimator advances, exactly as before).
/// Glyphs missing from whichever face wins keep the per-glyph notdef
/// block fallback in `drawGlyphBox`; a registered face never cascades
/// into the bundled faces mid-run.
fn referenceFaceForFontId(fonts: []const ReferenceFont, font_id: canvas.FontId) *const font_ttf.Face {
    for (fonts) |font| {
        if (font.id == font_id) return font.face;
    }
    if (font_id == canvas.default_mono_font_id) return &font_ttf.geist_mono;
    return &font_ttf.geist_regular;
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
    // Belt over the renderPass-level fill: direct sampler callers (unit
    // tests, future paths) stay correct. One predictable branch per
    // output pixel — noise next to the twelve pows the table replaces.
    ensureSrgbToLinearByteTable();
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

/// Precomputed `referenceSrgbToLinear(byte / 255.0)` for every byte
/// value: the linear image sampler decodes twelve sRGB channels per
/// output pixel, and each decode costs a `pow` — the single hottest
/// operation in a full-surface raster with photographic covers. Filled
/// lazily by evaluating the function itself over its exact 256 possible
/// inputs, so lookups are bit-identical to direct evaluation — this
/// only moves time, never pixels. The benign-race fill (any two fills
/// write identical bytes) keeps the hot path free of atomics.
var srgb_to_linear_byte_table: [256]f32 = undefined;
var srgb_to_linear_byte_table_ready: bool = false;

fn ensureSrgbToLinearByteTable() void {
    if (srgb_to_linear_byte_table_ready) return;
    for (&srgb_to_linear_byte_table, 0..) |*value, index| {
        value.* = referenceSrgbToLinear(@as(f32, @floatFromInt(index)) / 255.0);
    }
    srgb_to_linear_byte_table_ready = true;
}

/// Precomputed `referenceLinearToSrgb` over evenly spaced linear inputs:
/// the linear-light coverage blend re-encodes three channels per fringe
/// pixel, and each direct encode costs a `pow`. 4096 entries keep the
/// nearest-entry result within one 8-bit step of direct evaluation: the
/// curve is steepest near black (slope 12.92), where one table cell
/// still spans under one output byte step, so the looked-up value sits
/// within half a step of exact and the final byte rounding moves by at
/// most one level. Same benign-race lazy fill as the decode table above.
const linear_to_srgb_table_len = 4096;
var linear_to_srgb_table: [linear_to_srgb_table_len]f32 = undefined;
var linear_to_srgb_table_ready: bool = false;

fn ensureLinearToSrgbTable() void {
    if (linear_to_srgb_table_ready) return;
    for (&linear_to_srgb_table, 0..) |*value, index| {
        value.* = referenceLinearToSrgb(@as(f32, @floatFromInt(index)) / (linear_to_srgb_table_len - 1));
    }
    linear_to_srgb_table_ready = true;
}

fn referenceLinearToSrgbLut(value: f32) f32 {
    const index: usize = @intFromFloat(@round(std.math.clamp(value, 0, 1) * (linear_to_srgb_table_len - 1)));
    return linear_to_srgb_table[index];
}

fn referencePremultiplySrgba8(pixel: [4]u8) ReferencePremultipliedLinearColor {
    const alpha = @as(f32, @floatFromInt(pixel[3])) / 255.0;
    return .{
        .r = srgb_to_linear_byte_table[pixel[0]] * alpha,
        .g = srgb_to_linear_byte_table[pixel[1]] * alpha,
        .b = srgb_to_linear_byte_table[pixel[2]] * alpha,
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

/// True when every corner is square — the gate for the legacy binary
/// pixel-center rasterization, which keeps radius-0 rects on integer
/// bounds bit-identical to their historical bytes.
fn referenceRadiusIsZero(radius: Radius) bool {
    return radius.top_left <= 0 and radius.top_right <= 0 and
        radius.bottom_right <= 0 and radius.bottom_left <= 0;
}

/// Fractional coverage of the pixel centered at `point` against a
/// rounded rect: `clamp(0.5 - d, 0, 1)` of the EXACT signed distance to
/// the shape boundary. One closed form serves arcs and straight
/// segments alike, so coverage is a continuous function around the
/// whole perimeter — a per-region model (arc ramp here, binary edge
/// there) disagrees with itself about where the boundary is at the
/// hand-off points and grows nubs or notches into the silhouette.
///
/// The distance is the classic rounded-rect field: with `q = |p - c| -
/// (half_extent - r)` for the corner radius `r` of the quadrant `p`
/// lies in, `d = length(max(q, 0)) + min(max(q.x, q.y), 0) - r`. It is
/// exact for any per-corner radii, including square (r = 0) corners,
/// and along a straight segment it reduces to the plain axis distance
/// (the selected radius cancels), so the field is continuous where
/// quadrants with different radii meet. Cheap fully-inside/outside
/// short circuits keep the square root off interior and far-apron
/// pixels; the exact form runs only near the boundary band.
fn referenceRoundedRectCoverage(point: geometry.PointF, rect: geometry.RectF, radius: Radius) f32 {
    const normalized = rect.normalized();
    if (normalized.isEmpty()) return 0;
    const max_radius = @min(normalized.width, normalized.height) * 0.5;

    const half_width = normalized.width * 0.5;
    const half_height = normalized.height * 0.5;
    const dx = point.x - (normalized.x + half_width);
    const dy = point.y - (normalized.y + half_height);
    const corner_radius = std.math.clamp(nonNegative(if (dx < 0)
        (if (dy < 0) radius.top_left else radius.bottom_left)
    else
        (if (dy < 0) radius.top_right else radius.bottom_right)), 0, max_radius);

    const qx = @abs(dx) - half_width + corner_radius;
    const qy = @abs(dy) - half_height + corner_radius;
    // Fully inside: with both components non-positive the distance is
    // `max(qx, qy) - r`, so anything at least half a pixel inside the
    // radius-inset cross is full coverage.
    if (@max(qx, qy) <= -0.5) return 1;
    // Fully outside: the distance is at least `qx - r` (and `qy - r`),
    // so anything at least half a pixel beyond the bounding box is
    // zero coverage.
    if (qx - corner_radius >= 0.5 or qy - corner_radius >= 0.5) return 0;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const distance = @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0) - corner_radius;
    return std.math.clamp(0.5 - distance, 0, 1);
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

/// Source-over with the source's fractional alpha split into COLOR alpha
/// and EDGE COVERAGE, so the blend space can key off what the alpha
/// means (see `CoverageBlend`).
///
/// Linear-light blending is reserved for the one case the split targets:
/// an effectively opaque source's anti-aliased fringe. Everything else —
/// sRGB-mode callers (glyphs), fully covered pixels, and translucent
/// sources — folds coverage into alpha and takes the historical sRGB
/// blend, byte for byte. That routing is also the cost story: interiors
/// (`coverage >= 1`) and washes never pay a decode/encode round-trip, so
/// the linear math runs only on the thin edge band, where the two table
/// lookups per channel replace `pow` evaluations.
fn blendRgba8Coverage(dst: [4]u8, src: Color, coverage: f32, opacity: f32, blend: CoverageBlend) [4]u8 {
    const cov = std.math.clamp(coverage, 0, 1);
    const src_a = std.math.clamp(src.a, 0, 1) * std.math.clamp(opacity, 0, 1);
    if (blend == .srgb or cov <= 0 or cov >= 1 or src_a < 1) {
        return blendRgba8(dst, referenceScaleColorAlpha(src, cov), opacity);
    }

    // Belt over the renderPass-level fills for direct callers (unit
    // tests, future paths): two predictable branches per fringe pixel.
    ensureSrgbToLinearByteTable();
    ensureLinearToSrgbTable();

    // Alpha stays in coverage space — it counts covered area, not light
    // — so the alpha math is IDENTICAL to the sRGB path; only the color
    // channels decode to linear light. `out_a >= cov > 0` here, so the
    // straight-alpha un-premultiply divide is safe. The source decodes
    // through the same byte quantization its coverage-1 pixels store,
    // so a fringe converges exactly onto the interior bytes it borders.
    const dst_a = @as(f32, @floatFromInt(dst[3])) / 255.0;
    const out_a = cov + dst_a * (1 - cov);
    const src_r = srgb_to_linear_byte_table[colorChannelToByte(src.r)];
    const src_g = srgb_to_linear_byte_table[colorChannelToByte(src.g)];
    const src_b = srgb_to_linear_byte_table[colorChannelToByte(src.b)];
    const dst_r = srgb_to_linear_byte_table[dst[0]];
    const dst_g = srgb_to_linear_byte_table[dst[1]];
    const dst_b = srgb_to_linear_byte_table[dst[2]];
    const dst_weight = dst_a * (1 - cov);
    return .{
        colorChannelToByte(referenceLinearToSrgbLut((src_r * cov + dst_r * dst_weight) / out_a)),
        colorChannelToByte(referenceLinearToSrgbLut((src_g * cov + dst_g * dst_weight) / out_a)),
        colorChannelToByte(referenceLinearToSrgbLut((src_b * cov + dst_b * dst_weight) / out_a)),
        colorChannelToByte(out_a),
    };
}

fn colorChannelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}
fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
