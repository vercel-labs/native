//! One-image app-icon pipeline: a single square source image — a PNG
//! (1:1, ideally 1024x1024) or an SVG in the supported stroke-icon
//! dialect — becomes every artifact the packaging targets need, with no
//! external tools anywhere:
//!
//! - macOS: a complete `.icns` (16/32/128/256/512 at 1x and 2x) with the
//!   platform icon convention applied automatically — full-bleed artwork
//!   is inset on the canvas and masked by the standard rounded rectangle
//!   of the macOS icon grid, so a plain square image looks native in the
//!   Dock. Artwork whose corners are already transparent (the author
//!   shaped it themselves) ships as-is, never double-masked.
//! - Windows: a multi-size `.ico` of PNG-compressed entries.
//! - Linux and mobile targets: square PNGs at their standard sizes.
//!
//! Quality rules: every raster resize is an exact area average (box
//! filter) over premultiplied LINEAR-light values — a 1024px source
//! stays crisp at 16px and alpha edges blend correctly — and SVG sources
//! are rasterized per output size through the vector core instead of
//! being scaled from a master raster. PNG output uses real deflate
//! compression (still fully deterministic: identical input bytes produce
//! identical artifacts).

const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const vector = @import("vector.zig");
const svg_icon = @import("svg_icon.zig");
const png_model = @import("png.zig");

const PointF = geometry.PointF;
const Affine = drawing_model.Affine;

// ---------------------------------------------------------------------------
// The macOS icon grid
// ---------------------------------------------------------------------------
// Modern macOS app icons are drawn on a 1024x1024 canvas whose artwork
// square is 824x824, centered (a 100px margin on every side), clipped by
// a rounded rectangle with a 185.4px corner radius. Expressed as ratios
// of the canvas edge so the same grid renders exactly at every size:

/// Artwork square edge / canvas edge (824/1024).
pub const macos_artwork_ratio: f64 = 824.0 / 1024.0;
/// Margin on each side / canvas edge (100/1024).
pub const macos_margin_ratio: f64 = 100.0 / 1024.0;
/// Rounded-rect corner radius / canvas edge (185.4/1024, which is 22.5%
/// of the artwork square). The corners here are circular arcs; the
/// platform's own icons use a continuous-curvature corner, but at every
/// shipped size the difference is below one pixel of coverage.
pub const macos_corner_radius_ratio: f64 = 185.4 / 1024.0;

/// Pixel sizes rendered for the `.icns` family (1x and 2x slots below
/// share renders: a 32px image serves both 32@1x and 16@2x).
pub const macos_render_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024 };

/// The `.icns` member types shipped, matching what the platform's own
/// icon tooling emits for the standard iconset family. The 16 and 32
/// pixel 1x slots (`ic04`/`ic05`) carry the ARGB form — an "ARGB" magic
/// followed by PackBits-style run-length-encoded A,R,G,B planes —
/// because system consumers read those two slots as RLE data, not PNG;
/// every other slot carries a PNG payload.
pub const IcnsPayload = enum { png, argb };
pub const IcnsSlot = struct { kind: [4]u8, size: usize, payload: IcnsPayload = .png };
pub const icns_slots = [_]IcnsSlot{
    .{ .kind = "ic04".*, .size = 16, .payload = .argb }, // 16x16 @1x
    .{ .kind = "ic11".*, .size = 32 }, // 16x16 @2x
    .{ .kind = "ic05".*, .size = 32, .payload = .argb }, // 32x32 @1x
    .{ .kind = "ic12".*, .size = 64 }, // 32x32 @2x
    .{ .kind = "ic07".*, .size = 128 }, // 128x128 @1x
    .{ .kind = "ic13".*, .size = 256 }, // 128x128 @2x
    .{ .kind = "ic08".*, .size = 256 }, // 256x256 @1x
    .{ .kind = "ic14".*, .size = 512 }, // 256x256 @2x
    .{ .kind = "ic09".*, .size = 512 }, // 512x512 @1x
    .{ .kind = "ic10".*, .size = 1024 }, // 512x512 @2x
};

/// Windows `.ico` directory sizes (square, unmasked — Windows renders
/// icons full-bleed).
pub const ico_sizes = [_]usize{ 16, 24, 32, 48, 64, 128, 256 };

/// Linux hicolor theme sizes (share/icons/hicolor/<N>x<N>/apps).
pub const linux_sizes = [_]usize{ 16, 24, 32, 48, 64, 128, 256, 512 };

/// Android launcher mipmap densities: mdpi through xxxhdpi at the
/// standard 48dp launcher size.
pub const AndroidDensity = struct { name: []const u8, size: usize };
pub const android_densities = [_]AndroidDensity{
    .{ .name = "mdpi", .size = 48 },
    .{ .name = "hdpi", .size = 72 },
    .{ .name = "xhdpi", .size = 96 },
    .{ .name = "xxhdpi", .size = 144 },
    .{ .name = "xxxhdpi", .size = 192 },
};

/// iOS asset catalogs take one 1024px universal image.
pub const ios_icon_size: usize = 1024;

/// The macOS canvas the pipeline composes on (and the ideal source edge).
pub const master_size: usize = 1024;

/// Sources below this edge upscale into the large slots and look soft;
/// the tooling warns (never errors) under it.
pub const min_recommended_source_size: usize = 512;

/// Dimension cap for decoded sources: far past any sensible icon while
/// keeping a hostile PNG header from driving a giant allocation.
pub const max_source_dimension: usize = 16384;

pub const Error = error{
    /// The source bytes are not a decodable PNG/SVG in the supported
    /// forms (see `formatUnsupportedMessage`).
    UnsupportedImage,
    OutOfMemory,
} || vector.Error;

// ---------------------------------------------------------------------------
// Teaching messages: the one authority packaging AND `native validate`/
// `native check` print, so every surface says the same thing.
// ---------------------------------------------------------------------------

pub fn formatNotSquareMessage(buffer: []u8, path: []const u8, width: usize, height: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "app icon source {s} is {d}x{d} - the source must be square (1:1); crop or pad the artwork so width equals height", .{ path, width, height }) catch "app icon source is not square (1:1) - crop or pad the artwork so width equals height";
}

pub fn formatUnsupportedMessage(buffer: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "app icon source {s} could not be read - supply one square image as a .png (1:1, ideally 1024x1024) or an .svg in the supported icon dialect", .{path}) catch "app icon source could not be read - supply one square .png (ideally 1024x1024) or .svg";
}

pub fn formatSmallSourceMessage(buffer: []u8, path: []const u8, width: usize, height: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "warning: app icon source {s} is {d}x{d} - upscaling never looks good; supply a 1024x1024 image (or an .svg) for crisp large sizes", .{ path, width, height }) catch "warning: app icon source is smaller than 512x512 - upscaling never looks good; supply 1024x1024 (or an .svg)";
}

pub fn formatBadExtensionMessage(buffer: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "app.zon icons entry {s} is not a supported form - use one square .png or .svg source (every platform's icons generate from it), or a prebuilt .icns (macOS) / .ico (Windows) that ships untouched", .{path}) catch "app.zon icons entries must be a .png or .svg source, or a prebuilt .icns/.ico";
}

// ---------------------------------------------------------------------------
// Source classification and loading
// ---------------------------------------------------------------------------

pub const SourceKind = enum { png, svg };

/// Kind of a generatable source path, by extension (ASCII
/// case-insensitive). Prebuilt containers (.icns/.ico) and anything else
/// return null: they are never generation inputs.
pub fn sourceKindForPath(path: []const u8) ?SourceKind {
    if (pathHasExtension(path, ".png")) return .png;
    if (pathHasExtension(path, ".svg")) return .svg;
    return null;
}

pub fn pathHasExtension(path: []const u8, extension: []const u8) bool {
    if (path.len < extension.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - extension.len ..], extension);
}

/// Straight-alpha 8-bit RGBA pixels.
pub const Rgba8Image = struct {
    width: usize,
    height: usize,
    pixels: []u8,

    pub fn deinit(self: Rgba8Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

/// A loaded, validated icon source.
pub const Source = struct {
    kind: SourceKind,
    /// Pixel dimensions for PNG sources; the (square) viewBox extent
    /// rounded for SVG sources (SVGs never trigger the size warning).
    width: usize,
    height: usize,
    image: ?Rgba8Image = null,
    svg_buffer: ?*svg_icon.IconBuffer = null,
    svg: svg_icon.Icon = undefined,

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        if (self.image) |image| image.deinit(gpa);
        if (self.svg_buffer) |buffer| gpa.destroy(buffer);
        self.* = undefined;
    }
};

pub const LoadIssue = union(enum) {
    /// Width and height that were actually found.
    not_square: struct { width: usize, height: usize },
    /// Undecodable or outside the supported forms.
    unsupported,
};

pub const LoadResult = union(enum) {
    ok: Source,
    issue: LoadIssue,
};

/// Decode and validate source bytes. Shape problems come back as typed
/// issues (so callers can print the teaching message with the found
/// dimensions); only allocation failure is an error.
pub fn loadSource(gpa: std.mem.Allocator, bytes: []const u8, kind: SourceKind) error{OutOfMemory}!LoadResult {
    switch (kind) {
        .png => {
            const image = decodePng(gpa, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedImage => return .{ .issue = .unsupported },
            };
            if (image.width != image.height) {
                const width = image.width;
                const height = image.height;
                image.deinit(gpa);
                return .{ .issue = .{ .not_square = .{ .width = width, .height = height } } };
            }
            return .{ .ok = .{ .kind = .png, .width = image.width, .height = image.height, .image = image } };
        },
        .svg => {
            const buffer = try gpa.create(svg_icon.IconBuffer);
            errdefer gpa.destroy(buffer);
            buffer.* = .{};
            const icon = svg_icon.parse(bytes, buffer) catch {
                gpa.destroy(buffer);
                return .{ .issue = .unsupported };
            };
            const extent: usize = @intFromFloat(@max(1, @round(@max(icon.view_box.width, icon.view_box.height))));
            return .{ .ok = .{ .kind = .svg, .width = extent, .height = extent, .svg_buffer = buffer, .svg = icon } };
        },
    }
}

// ---------------------------------------------------------------------------
// Linear-light working surface
// ---------------------------------------------------------------------------
// All compositing and resampling happens on premultiplied linear-light
// f32 RGBA: averaging premultiplied values is the alpha-correct blend,
// and averaging linear (not gamma-encoded) values is the
// brightness-correct one — a black/white checkerboard downscales to the
// gray a viewer perceives, not a too-dark mush.

const LinearImage = struct {
    width: usize,
    height: usize,
    /// Premultiplied linear RGBA, four f32 per pixel.
    px: []f32,

    fn initZero(gpa: std.mem.Allocator, width: usize, height: usize) error{OutOfMemory}!LinearImage {
        const px = try gpa.alloc(f32, width * height * 4);
        @memset(px, 0);
        return .{ .width = width, .height = height, .px = px };
    }

    fn deinit(self: LinearImage, gpa: std.mem.Allocator) void {
        gpa.free(self.px);
    }
};

/// sRGB byte -> linear, precomputed once.
const srgb_to_linear_table = blk: {
    @setEvalBranchQuota(4_000_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*entry, index| {
        const value = @as(f64, @floatFromInt(index)) / 255.0;
        entry.* = @floatCast(srgbToLinear(value));
    }
    break :blk table;
};

fn srgbToLinear(value: f64) f64 {
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(value: f64) f64 {
    if (value <= 0.0031308) return value * 12.92;
    return 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
}

fn linearFromRgba8(gpa: std.mem.Allocator, image: Rgba8Image) error{OutOfMemory}!LinearImage {
    const px = try gpa.alloc(f32, image.width * image.height * 4);
    var index: usize = 0;
    while (index < image.width * image.height) : (index += 1) {
        const base = index * 4;
        const alpha = @as(f32, @floatFromInt(image.pixels[base + 3])) / 255.0;
        px[base + 0] = srgb_to_linear_table[image.pixels[base + 0]] * alpha;
        px[base + 1] = srgb_to_linear_table[image.pixels[base + 1]] * alpha;
        px[base + 2] = srgb_to_linear_table[image.pixels[base + 2]] * alpha;
        px[base + 3] = alpha;
    }
    return .{ .width = image.width, .height = image.height, .px = px };
}

fn rgba8FromLinear(gpa: std.mem.Allocator, image: LinearImage) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, image.width * image.height * 4);
    var index: usize = 0;
    while (index < image.width * image.height) : (index += 1) {
        const base = index * 4;
        const alpha = std.math.clamp(image.px[base + 3], 0, 1);
        if (alpha > 0.0001) {
            out[base + 0] = quantizeSrgb(image.px[base + 0] / alpha);
            out[base + 1] = quantizeSrgb(image.px[base + 1] / alpha);
            out[base + 2] = quantizeSrgb(image.px[base + 2] / alpha);
        } else {
            out[base + 0] = 0;
            out[base + 1] = 0;
            out[base + 2] = 0;
        }
        out[base + 3] = @intFromFloat(@round(alpha * 255.0));
    }
    return out;
}

fn quantizeSrgb(linear: f32) u8 {
    const encoded = linearToSrgb(std.math.clamp(linear, 0, 1));
    return @intFromFloat(std.math.clamp(encoded * 255.0 + 0.5, 0, 255));
}

/// Exact area-average (box) resample: every destination pixel is the
/// mean of the source area it covers, with fractional edge coverage —
/// no source pixel is skipped, so 1024 -> 16 keeps every detail's
/// energy instead of point-sampling a moire pattern out of it.
fn boxResample(gpa: std.mem.Allocator, source: LinearImage, width: usize, height: usize) error{OutOfMemory}!LinearImage {
    const out = try gpa.alloc(f32, width * height * 4);
    const ratio_x = @as(f64, @floatFromInt(source.width)) / @as(f64, @floatFromInt(width));
    const ratio_y = @as(f64, @floatFromInt(source.height)) / @as(f64, @floatFromInt(height));
    var oy: usize = 0;
    while (oy < height) : (oy += 1) {
        const sy0 = @as(f64, @floatFromInt(oy)) * ratio_y;
        const sy1 = @as(f64, @floatFromInt(oy + 1)) * ratio_y;
        var ox: usize = 0;
        while (ox < width) : (ox += 1) {
            const sx0 = @as(f64, @floatFromInt(ox)) * ratio_x;
            const sx1 = @as(f64, @floatFromInt(ox + 1)) * ratio_x;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var area: f64 = 0;
            var sy: usize = @intFromFloat(@floor(sy0));
            while (sy < source.height and @as(f64, @floatFromInt(sy)) < sy1) : (sy += 1) {
                const cover_y = @min(sy1, @as(f64, @floatFromInt(sy + 1))) - @max(sy0, @as(f64, @floatFromInt(sy)));
                if (cover_y <= 0) continue;
                var sx: usize = @intFromFloat(@floor(sx0));
                while (sx < source.width and @as(f64, @floatFromInt(sx)) < sx1) : (sx += 1) {
                    const cover_x = @min(sx1, @as(f64, @floatFromInt(sx + 1))) - @max(sx0, @as(f64, @floatFromInt(sx)));
                    if (cover_x <= 0) continue;
                    const weight = cover_x * cover_y;
                    const base = (sy * source.width + sx) * 4;
                    acc[0] += source.px[base + 0] * weight;
                    acc[1] += source.px[base + 1] * weight;
                    acc[2] += source.px[base + 2] * weight;
                    acc[3] += source.px[base + 3] * weight;
                    area += weight;
                }
            }
            const base = (oy * width + ox) * 4;
            if (area > 0) {
                out[base + 0] = @floatCast(acc[0] / area);
                out[base + 1] = @floatCast(acc[1] / area);
                out[base + 2] = @floatCast(acc[2] / area);
                out[base + 3] = @floatCast(acc[3] / area);
            } else {
                out[base + 0] = 0;
                out[base + 1] = 0;
                out[base + 2] = 0;
                out[base + 3] = 0;
            }
        }
    }
    return .{ .width = width, .height = height, .px = out };
}

// ---------------------------------------------------------------------------
// SVG rasterization (per output size, through the vector core)
// ---------------------------------------------------------------------------

const CoverageCompositeSink = struct {
    image: *LinearImage,
    /// Premultiplied linear source color.
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn pixel(self: *CoverageCompositeSink, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const xu: usize = @intCast(x);
        const yu: usize = @intCast(y);
        if (xu >= self.image.width or yu >= self.image.height) return;
        const clamped = std.math.clamp(coverage, 0, 1);
        if (clamped <= 0) return;
        const base = (yu * self.image.width + xu) * 4;
        const inverse = 1 - self.a * clamped;
        self.image.px[base + 0] = self.r * clamped + self.image.px[base + 0] * inverse;
        self.image.px[base + 1] = self.g * clamped + self.image.px[base + 1] * inverse;
        self.image.px[base + 2] = self.b * clamped + self.image.px[base + 2] * inverse;
        self.image.px[base + 3] = self.a * clamped + self.image.px[base + 3] * inverse;
    }
};

fn linearPaintSink(image: *LinearImage, paint: svg_icon.Paint) ?CoverageCompositeSink {
    const color: drawing_model.Color = switch (paint) {
        .none => return null,
        // A standalone icon has no widget foreground to inherit;
        // `currentColor` resolves to black, the SVG initial color.
        .current_color => drawing_model.Color.rgb8(0, 0, 0),
        .color => |value| value,
    };
    const linear_r: f32 = @floatCast(srgbToLinear(std.math.clamp(color.r, 0, 1)));
    const linear_g: f32 = @floatCast(srgbToLinear(std.math.clamp(color.g, 0, 1)));
    const linear_b: f32 = @floatCast(srgbToLinear(std.math.clamp(color.b, 0, 1)));
    const alpha = std.math.clamp(color.a, 0, 1);
    return .{ .image = image, .r = linear_r * alpha, .g = linear_g * alpha, .b = linear_b * alpha, .a = alpha };
}

/// Rasterize a parsed SVG icon into `image`, its viewBox mapped to the
/// square (`origin`, `origin + extent`).
fn rasterizeSvg(image: *LinearImage, icon: svg_icon.Icon, origin: f32, extent: f32) vector.Error!void {
    const box_extent = @max(icon.view_box.width, icon.view_box.height);
    if (!(box_extent > 0) or !(extent > 0)) return;
    const scale = extent / box_extent;
    // Center a non-square viewBox inside the square target.
    const offset_x = origin + (extent - icon.view_box.width * scale) * 0.5 - icon.view_box.x * scale;
    const offset_y = origin + (extent - icon.view_box.height * scale) * 0.5 - icon.view_box.y * scale;
    const transform = Affine.translate(offset_x, offset_y).multiply(Affine.scale(scale, scale));
    const clip = vector.ClipRect{ .x0 = 0, .y0 = 0, .x1 = @intCast(image.width), .y1 = @intCast(image.height) };

    for (icon.shapes) |shape| {
        const elements = icon.elements[shape.start .. shape.start + shape.len];
        if (linearPaintSink(image, shape.style.fill)) |sink| {
            var fill_sink = sink;
            try vector.fillPath(elements, transform, .nonzero, vector.default_tolerance, clip, &fill_sink);
        }
        if (linearPaintSink(image, shape.style.stroke)) |sink| {
            var stroke_sink = sink;
            try vector.strokePath(elements, transform, .{
                .width = shape.style.stroke_width * scale,
                .cap = shape.style.linecap,
                .join = shape.style.linejoin,
            }, vector.default_tolerance, clip, &stroke_sink);
        }
    }
}

// ---------------------------------------------------------------------------
// The macOS rounded-rect mask
// ---------------------------------------------------------------------------

const MaskSink = struct {
    mask: []f32,
    width: usize,

    pub fn pixel(self: *MaskSink, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const xu: usize = @intCast(x);
        const yu: usize = @intCast(y);
        if (xu >= self.width) return;
        const index = yu * self.width + xu;
        if (index >= self.mask.len) return;
        self.mask[index] = std.math.clamp(self.mask[index] + coverage, 0, 1);
    }
};

/// Anti-aliased coverage of the icon-grid rounded rectangle on a
/// `size` x `size` canvas: one f32 per pixel in [0, 1].
pub fn macosMaskCoverage(gpa: std.mem.Allocator, size: usize) Error![]f32 {
    const mask = try gpa.alloc(f32, size * size);
    errdefer gpa.free(mask);
    @memset(mask, 0);

    const edge: f32 = @floatFromInt(size);
    const x0: f32 = @floatCast(macos_margin_ratio * edge);
    const extent: f32 = @floatCast(macos_artwork_ratio * edge);
    const radius: f32 = @floatCast(macos_corner_radius_ratio * edge);
    const x1 = x0 + extent;
    const y0 = x0;
    const y1 = x1;

    var builder = vector.PathBuilder(64){};
    try builder.moveTo(PointF.init(x0 + radius, y0));
    try builder.lineTo(PointF.init(x1 - radius, y0));
    try builder.arcTo(radius, radius, 0, false, true, PointF.init(x1, y0 + radius));
    try builder.lineTo(PointF.init(x1, y1 - radius));
    try builder.arcTo(radius, radius, 0, false, true, PointF.init(x1 - radius, y1));
    try builder.lineTo(PointF.init(x0 + radius, y1));
    try builder.arcTo(radius, radius, 0, false, true, PointF.init(x0, y1 - radius));
    try builder.lineTo(PointF.init(x0, y0 + radius));
    try builder.arcTo(radius, radius, 0, false, true, PointF.init(x0 + radius, y0));
    try builder.close();

    var sink = MaskSink{ .mask = mask, .width = size };
    try vector.fillPath(
        builder.slice(),
        Affine.identity(),
        .nonzero,
        vector.default_tolerance,
        .{ .x0 = 0, .y0 = 0, .x1 = @intCast(size), .y1 = @intCast(size) },
        &sink,
    );
    return mask;
}

fn applyMask(image: *LinearImage, mask: []const f32) void {
    for (mask, 0..) |coverage, index| {
        const base = index * 4;
        image.px[base + 0] *= coverage;
        image.px[base + 1] *= coverage;
        image.px[base + 2] *= coverage;
        image.px[base + 3] *= coverage;
    }
}

/// A source whose four corners are already fully transparent shaped its
/// own silhouette (its author baked a mask and margins); the macOS path
/// ships it untouched instead of shrinking and re-masking it. Full-bleed
/// art — any opaque corner — gets the standard grid treatment.
pub fn imageIsPreShaped(image: Rgba8Image) bool {
    if (image.width == 0 or image.height == 0) return false;
    const corners = [_]usize{
        0,
        image.width - 1,
        (image.height - 1) * image.width,
        image.height * image.width - 1,
    };
    for (corners) |pixel_index| {
        if (image.pixels[pixel_index * 4 + 3] != 0) return false;
    }
    return true;
}

fn sourceIsPreShaped(gpa: std.mem.Allocator, source: *const Source) error{OutOfMemory}!bool {
    switch (source.kind) {
        .png => return imageIsPreShaped(source.image.?),
        .svg => {
            // Rasterize a small full-canvas probe and inspect its corners.
            const probe_size: usize = 64;
            var probe = try LinearImage.initZero(gpa, probe_size, probe_size);
            defer probe.deinit(gpa);
            rasterizeSvg(&probe, source.svg, 0, @floatFromInt(probe_size)) catch return false;
            const corners = [_]usize{ 0, probe_size - 1, (probe_size - 1) * probe_size, probe_size * probe_size - 1 };
            for (corners) |pixel_index| {
                if (probe.px[pixel_index * 4 + 3] > 0.004) return false;
            }
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Renders
// ---------------------------------------------------------------------------

/// Square, unmasked render of the source at `size` (Windows/Linux/mobile
/// artifacts and the pre-shaped macOS path). Straight-alpha RGBA8.
pub fn renderSquare(gpa: std.mem.Allocator, source: *const Source, size: usize) Error![]u8 {
    switch (source.kind) {
        .png => {
            var linear = try linearFromRgba8(gpa, source.image.?);
            defer linear.deinit(gpa);
            if (linear.width == size and linear.height == size) return rgba8FromLinear(gpa, linear);
            var resampled = try boxResample(gpa, linear, size, size);
            defer resampled.deinit(gpa);
            return rgba8FromLinear(gpa, resampled);
        },
        .svg => {
            var canvas = try LinearImage.initZero(gpa, size, size);
            defer canvas.deinit(gpa);
            try rasterizeSvg(&canvas, source.svg, 0, @floatFromInt(size));
            return rgba8FromLinear(gpa, canvas);
        },
    }
}

/// macOS canvas render at `size`: full-bleed sources are inset to the
/// icon-grid artwork square and masked; pre-shaped sources render
/// full-canvas untouched. Straight-alpha RGBA8.
pub fn renderMacosCanvas(gpa: std.mem.Allocator, source: *const Source, size: usize) Error![]u8 {
    const renders = try renderMacosFamily(gpa, source, &.{size});
    defer gpa.free(renders);
    return renders[0];
}

/// Render the macOS canvas at every requested size. PNG sources compose
/// a single 1024 master (inset + mask once, anti-aliased by the box
/// resample at each size); SVG sources rasterize and mask per size
/// directly. Caller owns each returned RGBA8 buffer and the slice.
fn renderMacosFamily(gpa: std.mem.Allocator, source: *const Source, sizes: []const usize) Error![][]u8 {
    const out = try gpa.alloc([]u8, sizes.len);
    var completed: usize = 0;
    // errdefers run last-declared-first: free the renders before the
    // slice that holds them.
    errdefer gpa.free(out);
    errdefer for (out[0..completed]) |render| gpa.free(render);

    const pre_shaped = try sourceIsPreShaped(gpa, source);
    switch (source.kind) {
        .png => {
            var master = try macosPngMaster(gpa, source.image.?, pre_shaped);
            defer master.deinit(gpa);
            for (sizes, 0..) |size, index| {
                if (size == master.width) {
                    out[index] = try rgba8FromLinear(gpa, master);
                } else {
                    var resampled = try boxResample(gpa, master, size, size);
                    defer resampled.deinit(gpa);
                    out[index] = try rgba8FromLinear(gpa, resampled);
                }
                completed += 1;
            }
        },
        .svg => {
            for (sizes, 0..) |size, index| {
                var canvas = try LinearImage.initZero(gpa, size, size);
                defer canvas.deinit(gpa);
                if (pre_shaped) {
                    try rasterizeSvg(&canvas, source.svg, 0, @floatFromInt(size));
                } else {
                    const edge: f32 = @floatFromInt(size);
                    const extent: f32 = @floatCast(macos_artwork_ratio * @as(f64, edge));
                    const origin: f32 = @floatCast(macos_margin_ratio * @as(f64, edge));
                    try rasterizeSvg(&canvas, source.svg, origin, extent);
                    const mask = try macosMaskCoverage(gpa, size);
                    defer gpa.free(mask);
                    applyMask(&canvas, mask);
                }
                out[index] = try rgba8FromLinear(gpa, canvas);
                completed += 1;
            }
        },
    }
    return out;
}

/// The composed 1024 linear master for a PNG source.
fn macosPngMaster(gpa: std.mem.Allocator, image: Rgba8Image, pre_shaped: bool) Error!LinearImage {
    var linear = try linearFromRgba8(gpa, image);
    if (pre_shaped) {
        if (linear.width == master_size) return linear;
        defer linear.deinit(gpa);
        return boxResample(gpa, linear, master_size, master_size);
    }
    defer linear.deinit(gpa);

    const artwork_extent: usize = @intFromFloat(@round(macos_artwork_ratio * @as(f64, @floatFromInt(master_size))));
    const margin: usize = (master_size - artwork_extent) / 2;
    var artwork = try boxResample(gpa, linear, artwork_extent, artwork_extent);
    defer artwork.deinit(gpa);

    var master = try LinearImage.initZero(gpa, master_size, master_size);
    errdefer master.deinit(gpa);
    var y: usize = 0;
    while (y < artwork_extent) : (y += 1) {
        const source_row = artwork.px[y * artwork_extent * 4 .. (y + 1) * artwork_extent * 4];
        const dest_start = ((y + margin) * master_size + margin) * 4;
        @memcpy(master.px[dest_start .. dest_start + source_row.len], source_row);
    }
    const mask = try macosMaskCoverage(gpa, master_size);
    defer gpa.free(mask);
    applyMask(&master, mask);
    return master;
}

// ---------------------------------------------------------------------------
// PNG encode (compressed, deterministic)
// ---------------------------------------------------------------------------

/// Encode straight-alpha RGBA8 as a real deflate-compressed PNG (Up row
/// filter). The canvas PNG writer (`png.zig`) emits stored blocks for
/// screenshot determinism; icon artifacts want small files, and flate
/// with fixed parameters is just as deterministic.
pub fn encodePng(gpa: std.mem.Allocator, rgba: []const u8, width: usize, height: usize) Error![]u8 {
    if (width == 0 or height == 0 or rgba.len < width * height * 4) return error.UnsupportedImage;
    const flate = std.compress.flate;
    const row_len = 1 + width * 4;
    const raw = try gpa.alloc(u8, row_len * height);
    defer gpa.free(raw);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * row_len ..][0..row_len];
        row[0] = 2; // Up filter: predict each byte from the row above.
        const current = rgba[y * width * 4 ..][0 .. width * 4];
        if (y == 0) {
            @memcpy(row[1..], current);
        } else {
            const above = rgba[(y - 1) * width * 4 ..][0 .. width * 4];
            for (current, above, row[1..]) |value, prediction, *out| out.* = value -% prediction;
        }
    }

    const zlib_capacity = raw.len + raw.len / 8 + 1024;
    const zlib_buffer = try gpa.alloc(u8, zlib_capacity);
    defer gpa.free(zlib_buffer);
    var zlib_writer = std.Io.Writer.fixed(zlib_buffer);
    const window = try gpa.alloc(u8, flate.max_window_len * 2);
    defer gpa.free(window);
    var compress = flate.Compress.init(&zlib_writer, window, .zlib, .default) catch return error.UnsupportedImage;
    compress.writer.writeAll(raw) catch return error.UnsupportedImage;
    compress.finish() catch return error.UnsupportedImage;
    const idat = zlib_writer.buffered();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &png_model.signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // truecolor with alpha
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace
    try appendPngChunk(&out, gpa, "IHDR", &ihdr);
    try appendPngChunk(&out, gpa, "IDAT", idat);
    try appendPngChunk(&out, gpa, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn appendPngChunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) error{OutOfMemory}!void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(data.len), .big);
    try list.appendSlice(gpa, &length_bytes);
    try list.appendSlice(gpa, kind);
    try list.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try list.appendSlice(gpa, &crc_bytes);
}

// ---------------------------------------------------------------------------
// PNG decode (general-purpose reader for user-supplied sources)
// ---------------------------------------------------------------------------

pub const PngHeader = struct { width: usize, height: usize };

/// Cheap dimension peek (signature + IHDR only) for validation paths
/// that should not pay for a full decode.
pub fn pngHeader(bytes: []const u8) ?PngHeader {
    if (bytes.len < png_model.signature.len + 25) return null;
    if (!std.mem.eql(u8, bytes[0..png_model.signature.len], &png_model.signature)) return null;
    const chunk = bytes[png_model.signature.len..];
    if (!std.mem.eql(u8, chunk[4..8], "IHDR")) return null;
    const width = std.mem.readInt(u32, chunk[8..12], .big);
    const height = std.mem.readInt(u32, chunk[12..16], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

/// Decode a PNG in the forms real icon sources take: 8- or 16-bit
/// samples; grayscale, truecolor, or palette color, each with or without
/// alpha (palette transparency via tRNS); all five row filters; single
/// or split IDAT chunks. Interlaced files and sub-byte depths are
/// rejected as unsupported. CRCs are not verified — a corrupt stream
/// fails at the zlib layer instead.
pub fn decodePng(gpa: std.mem.Allocator, bytes: []const u8) error{ UnsupportedImage, OutOfMemory }!Rgba8Image {
    if (bytes.len < png_model.signature.len) return error.UnsupportedImage;
    if (!std.mem.eql(u8, bytes[0..png_model.signature.len], &png_model.signature)) return error.UnsupportedImage;

    var width: usize = 0;
    var height: usize = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var saw_header = false;
    var saw_end = false;

    var offset: usize = png_model.signature.len;
    while (offset + 12 <= bytes.len) {
        const data_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const chunk_type = bytes[offset + 4 .. offset + 8];
        if (bytes.len - offset < 12 or bytes.len - offset - 12 < data_len) return error.UnsupportedImage;
        const data = bytes[offset + 8 .. offset + 8 + data_len];
        offset += 12 + data_len;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (saw_header or data.len != 13) return error.UnsupportedImage;
            saw_header = true;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return error.UnsupportedImage;
            if (width > max_source_dimension or height > max_source_dimension) return error.UnsupportedImage;
            bit_depth = data[8];
            color_type = data[9];
            if (bit_depth != 8 and bit_depth != 16) return error.UnsupportedImage;
            if (color_type == 3 and bit_depth != 8) return error.UnsupportedImage;
            switch (color_type) {
                0, 2, 3, 4, 6 => {},
                else => return error.UnsupportedImage,
            }
            if (data[10] != 0 or data[11] != 0) return error.UnsupportedImage;
            if (data[12] != 0) return error.UnsupportedImage; // no interlace
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (data.len == 0 or data.len % 3 != 0 or data.len > 256 * 3) return error.UnsupportedImage;
            palette = data;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            transparency = data;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            saw_end = true;
            break;
        }
        // Ancillary chunks (gAMA, iCCP, tEXt, ...) are skipped.
    }
    if (!saw_header or !saw_end or idat.items.len == 0) return error.UnsupportedImage;
    if (color_type == 3 and palette.len == 0) return error.UnsupportedImage;

    const channels: usize = switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const sample_bytes: usize = bit_depth / 8;
    const pixel_bytes = channels * sample_bytes;
    const row_bytes = width * pixel_bytes;
    const raw_len = height * (1 + row_bytes);

    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        const flate = std.compress.flate;
        var input: std.Io.Reader = .fixed(idat.items);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var decompress = flate.Decompress.init(&input, .zlib, window);
        decompress.reader.readSliceAll(raw) catch return error.UnsupportedImage;
    }

    // Undo the per-row prediction filters in place.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = y * (1 + row_bytes);
        const filter = raw[row_start];
        const row = raw[row_start + 1 .. row_start + 1 + row_bytes];
        const above: ?[]u8 = if (y > 0) raw[(y - 1) * (1 + row_bytes) + 1 ..][0..row_bytes] else null;
        switch (filter) {
            0 => {},
            1 => { // Sub
                var index: usize = pixel_bytes;
                while (index < row_bytes) : (index += 1) row[index] +%= row[index - pixel_bytes];
            },
            2 => { // Up
                if (above) |previous| {
                    for (row, previous) |*value, up| value.* +%= up;
                }
            },
            3 => { // Average
                var index: usize = 0;
                while (index < row_bytes) : (index += 1) {
                    const left: u16 = if (index >= pixel_bytes) row[index - pixel_bytes] else 0;
                    const up: u16 = if (above) |previous| previous[index] else 0;
                    row[index] +%= @truncate((left + up) / 2);
                }
            },
            4 => { // Paeth
                var index: usize = 0;
                while (index < row_bytes) : (index += 1) {
                    const left: i32 = if (index >= pixel_bytes) row[index - pixel_bytes] else 0;
                    const up: i32 = if (above) |previous| previous[index] else 0;
                    const up_left: i32 = if (above != null and index >= pixel_bytes) above.?[index - pixel_bytes] else 0;
                    const estimate = left + up - up_left;
                    const delta_left = @abs(estimate - left);
                    const delta_up = @abs(estimate - up);
                    const delta_up_left = @abs(estimate - up_left);
                    const prediction: i32 = if (delta_left <= delta_up and delta_left <= delta_up_left) left else if (delta_up <= delta_up_left) up else up_left;
                    row[index] +%= @intCast(prediction);
                }
            },
            else => return error.UnsupportedImage,
        }
    }

    // Expand to straight-alpha RGBA8 (16-bit samples keep the high byte).
    const pixels = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(pixels);
    y = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * (1 + row_bytes) + 1 ..][0..row_bytes];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const source = row[x * pixel_bytes ..][0..pixel_bytes];
            const dest = pixels[(y * width + x) * 4 ..][0..4];
            switch (color_type) {
                0 => {
                    const value = source[0];
                    dest.* = .{ value, value, value, 255 };
                },
                2 => {
                    dest.* = .{ source[0], source[sample_bytes], source[sample_bytes * 2], 255 };
                },
                3 => {
                    const index: usize = source[0];
                    if (index * 3 + 2 >= palette.len) return error.UnsupportedImage;
                    const alpha: u8 = if (index < transparency.len) transparency[index] else 255;
                    dest.* = .{ palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2], alpha };
                },
                4 => {
                    const value = source[0];
                    dest.* = .{ value, value, value, source[sample_bytes] };
                },
                6 => {
                    dest.* = .{ source[0], source[sample_bytes], source[sample_bytes * 2], source[sample_bytes * 3] };
                },
                else => unreachable,
            }
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

// ---------------------------------------------------------------------------
// ARGB payloads (the 16/32 px 1x members)
// ---------------------------------------------------------------------------

/// Encode straight-alpha RGBA8 as an icns ARGB payload: the "ARGB"
/// magic, then the A, R, G, B planes each run-length encoded with the
/// PackBits-style scheme icns uses (control < 0x80: that many + 1
/// literal bytes follow; control >= 0x80: repeat the next byte
/// control - 0x80 + 3 times).
pub fn encodeArgb(gpa: std.mem.Allocator, rgba: []const u8, width: usize, height: usize) Error![]u8 {
    if (width == 0 or height == 0 or rgba.len < width * height * 4) return error.UnsupportedImage;
    const pixel_count = width * height;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ARGB");
    const plane = try gpa.alloc(u8, pixel_count);
    defer gpa.free(plane);
    const channel_order = [4]usize{ 3, 0, 1, 2 }; // A, R, G, B
    for (channel_order) |channel| {
        var index: usize = 0;
        while (index < pixel_count) : (index += 1) plane[index] = rgba[index * 4 + channel];
        try appendPackBits(&out, gpa, plane);
    }
    return out.toOwnedSlice(gpa);
}

fn appendPackBits(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < bytes.len) {
        var run: usize = 1;
        while (index + run < bytes.len and bytes[index + run] == bytes[index] and run < 130) run += 1;
        if (run >= 3) {
            try list.append(gpa, @intCast(0x80 + run - 3));
            try list.append(gpa, bytes[index]);
            index += run;
            continue;
        }
        // Literal segment: up to 128 bytes, stopping before the next
        // three-byte repeat run.
        var end = index + 1;
        while (end < bytes.len and end - index < 128) {
            if (end + 2 < bytes.len and bytes[end] == bytes[end + 1] and bytes[end] == bytes[end + 2]) break;
            end += 1;
        }
        try list.append(gpa, @intCast(end - index - 1));
        try list.appendSlice(gpa, bytes[index..end]);
        index = end;
    }
}

/// Decode an ARGB payload back to straight-alpha RGBA8 (tests and
/// round-trip validation of our own output).
pub fn decodeArgb(gpa: std.mem.Allocator, payload: []const u8, width: usize, height: usize) Error![]u8 {
    if (payload.len < 4 or !std.mem.eql(u8, payload[0..4], "ARGB")) return error.UnsupportedImage;
    const pixel_count = width * height;
    const planes = try gpa.alloc(u8, pixel_count * 4);
    defer gpa.free(planes);
    var produced: usize = 0;
    var offset: usize = 4;
    while (produced < pixel_count * 4) {
        if (offset >= payload.len) return error.UnsupportedImage;
        const control = payload[offset];
        offset += 1;
        if (control >= 0x80) {
            const run = @as(usize, control) - 0x80 + 3;
            if (offset >= payload.len or produced + run > planes.len) return error.UnsupportedImage;
            @memset(planes[produced .. produced + run], payload[offset]);
            offset += 1;
            produced += run;
        } else {
            const run = @as(usize, control) + 1;
            if (offset + run > payload.len or produced + run > planes.len) return error.UnsupportedImage;
            @memcpy(planes[produced .. produced + run], payload[offset .. offset + run]);
            offset += run;
            produced += run;
        }
    }
    const rgba = try gpa.alloc(u8, pixel_count * 4);
    errdefer gpa.free(rgba);
    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        rgba[index * 4 + 3] = planes[index]; // A
        rgba[index * 4 + 0] = planes[pixel_count + index]; // R
        rgba[index * 4 + 1] = planes[pixel_count * 2 + index]; // G
        rgba[index * 4 + 2] = planes[pixel_count * 3 + index]; // B
    }
    return rgba;
}

/// Encode one render as the payload its slot expects.
pub fn encodeIcnsPayload(gpa: std.mem.Allocator, slot: IcnsSlot, rgba: []const u8) Error![]u8 {
    return switch (slot.payload) {
        .png => encodePng(gpa, rgba, slot.size, slot.size),
        .argb => encodeArgb(gpa, rgba, slot.size, slot.size),
    };
}

// ---------------------------------------------------------------------------
// .icns container (a sequence of typed members)
// ---------------------------------------------------------------------------

pub const IcnsMember = struct {
    kind: [4]u8,
    data: []const u8,
};

/// Assemble an `.icns` file: the 8-byte header, a TOC member, then each
/// member as type + big-endian total length + payload.
pub fn writeIcns(gpa: std.mem.Allocator, members: []const IcnsMember) error{OutOfMemory}![]u8 {
    var total: usize = 8; // file header
    total += 8 + members.len * 8; // TOC
    for (members) |member| total += 8 + member.data.len;

    var out = try gpa.alloc(u8, total);
    writeIcnsHeader(out[0..8], "icns".*, total);
    var offset: usize = 8;
    writeIcnsHeader(out[offset..][0..8], "TOC ".*, 8 + members.len * 8);
    offset += 8;
    for (members) |member| {
        writeIcnsHeader(out[offset..][0..8], member.kind, 8 + member.data.len);
        offset += 8;
    }
    for (members) |member| {
        writeIcnsHeader(out[offset..][0..8], member.kind, 8 + member.data.len);
        offset += 8;
        @memcpy(out[offset..][0..member.data.len], member.data);
        offset += member.data.len;
    }
    return out;
}

fn writeIcnsHeader(dest: *[8]u8, kind: [4]u8, length: usize) void {
    dest[0..4].* = kind;
    std.mem.writeInt(u32, dest[4..8], @intCast(length), .big);
}

/// Iterator over the members of an `.icns` file (TOC members skipped),
/// for tests and round-trip validation of our own output.
pub const IcnsIterator = struct {
    bytes: []const u8,
    offset: usize,

    pub fn init(bytes: []const u8) ?IcnsIterator {
        if (bytes.len < 8) return null;
        if (!std.mem.eql(u8, bytes[0..4], "icns")) return null;
        const total = std.mem.readInt(u32, bytes[4..8], .big);
        if (total != bytes.len) return null;
        return .{ .bytes = bytes, .offset = 8 };
    }

    pub fn next(self: *IcnsIterator) ?IcnsMember {
        while (self.offset + 8 <= self.bytes.len) {
            const kind: [4]u8 = self.bytes[self.offset..][0..4].*;
            const length = std.mem.readInt(u32, self.bytes[self.offset + 4 ..][0..4], .big);
            if (length < 8 or self.offset + length > self.bytes.len) return null;
            const data = self.bytes[self.offset + 8 .. self.offset + length];
            self.offset += length;
            if (std.mem.eql(u8, &kind, "TOC ")) continue;
            return .{ .kind = kind, .data = data };
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// .ico container (a directory of PNG-compressed entries)
// ---------------------------------------------------------------------------

pub const IcoEntry = struct {
    size: usize,
    data: []const u8,
};

/// Assemble an `.ico` file with PNG-compressed entries.
pub fn writeIco(gpa: std.mem.Allocator, entries: []const IcoEntry) error{OutOfMemory}![]u8 {
    var total: usize = 6 + entries.len * 16;
    for (entries) |entry| total += entry.data.len;
    var out = try gpa.alloc(u8, total);

    std.mem.writeInt(u16, out[0..2], 0, .little); // reserved
    std.mem.writeInt(u16, out[2..4], 1, .little); // type: icon
    std.mem.writeInt(u16, out[4..6], @intCast(entries.len), .little);
    var directory: usize = 6;
    var payload: usize = 6 + entries.len * 16;
    for (entries) |entry| {
        // A dimension byte of 0 means 256 in the .ico directory.
        const dimension: u8 = if (entry.size >= 256) 0 else @intCast(entry.size);
        out[directory + 0] = dimension; // width
        out[directory + 1] = dimension; // height
        out[directory + 2] = 0; // palette size
        out[directory + 3] = 0; // reserved
        std.mem.writeInt(u16, out[directory + 4 ..][0..2], 1, .little); // planes
        std.mem.writeInt(u16, out[directory + 6 ..][0..2], 32, .little); // bits per pixel
        std.mem.writeInt(u32, out[directory + 8 ..][0..4], @intCast(entry.data.len), .little);
        std.mem.writeInt(u32, out[directory + 12 ..][0..4], @intCast(payload), .little);
        directory += 16;
        @memcpy(out[payload..][0..entry.data.len], entry.data);
        payload += entry.data.len;
    }
    return out;
}

pub const IcoDirectoryEntry = struct {
    /// Stored dimension (0 in the file means 256; reported as 256 here).
    size: usize,
    data: []const u8,
};

/// Iterator over `.ico` directory entries for tests and validation.
pub const IcoIterator = struct {
    bytes: []const u8,
    count: usize,
    index: usize,

    pub fn init(bytes: []const u8) ?IcoIterator {
        if (bytes.len < 6) return null;
        if (std.mem.readInt(u16, bytes[0..2], .little) != 0) return null;
        if (std.mem.readInt(u16, bytes[2..4], .little) != 1) return null;
        const count = std.mem.readInt(u16, bytes[4..6], .little);
        if (bytes.len < 6 + @as(usize, count) * 16) return null;
        return .{ .bytes = bytes, .count = count, .index = 0 };
    }

    pub fn next(self: *IcoIterator) ?IcoDirectoryEntry {
        if (self.index >= self.count) return null;
        const entry = self.bytes[6 + self.index * 16 ..][0..16];
        self.index += 1;
        const dimension: usize = if (entry[0] == 0) 256 else entry[0];
        const length = std.mem.readInt(u32, entry[8..12], .little);
        const offset = std.mem.readInt(u32, entry[12..16], .little);
        if (@as(usize, offset) + length > self.bytes.len) return null;
        return .{ .size = dimension, .data = self.bytes[offset..][0..length] };
    }
};

// ---------------------------------------------------------------------------
// Top-level artifact builders
// ---------------------------------------------------------------------------

/// Build the complete macOS `.icns` from a loaded source.
pub fn buildIcns(gpa: std.mem.Allocator, source: *const Source) Error![]u8 {
    const renders = try renderMacosFamily(gpa, source, &macos_render_sizes);
    defer {
        for (renders) |render| gpa.free(render);
        gpa.free(renders);
    }
    var payloads: [icns_slots.len][]u8 = undefined;
    var encoded: usize = 0;
    defer for (payloads[0..encoded]) |bytes| gpa.free(bytes);
    var members: [icns_slots.len]IcnsMember = undefined;
    for (icns_slots, 0..) |slot, index| {
        payloads[index] = try encodeIcnsPayload(gpa, slot, renders[renderSizeIndex(slot.size)]);
        encoded += 1;
        members[index] = .{ .kind = slot.kind, .data = payloads[index] };
    }
    return writeIcns(gpa, &members);
}

fn renderSizeIndex(size: usize) usize {
    for (macos_render_sizes, 0..) |candidate, index| {
        if (candidate == size) return index;
    }
    unreachable;
}

/// Build the multi-size Windows `.ico` from a loaded source (square,
/// unmasked).
pub fn buildIco(gpa: std.mem.Allocator, source: *const Source) Error![]u8 {
    var pngs: [ico_sizes.len][]u8 = undefined;
    var encoded: usize = 0;
    defer for (pngs[0..encoded]) |bytes| gpa.free(bytes);
    var entries: [ico_sizes.len]IcoEntry = undefined;
    for (ico_sizes, 0..) |size, index| {
        const rgba = try renderSquare(gpa, source, size);
        defer gpa.free(rgba);
        pngs[index] = try encodePng(gpa, rgba, size, size);
        encoded += 1;
        entries[index] = .{ .size = size, .data = pngs[index] };
    }
    return writeIco(gpa, &entries);
}

/// Encode one square PNG at `size` from a loaded source (Linux hicolor
/// sizes, mobile launcher densities, the iOS catalog image).
pub fn buildSquarePng(gpa: std.mem.Allocator, source: *const Source, size: usize) Error![]u8 {
    const rgba = try renderSquare(gpa, source, size);
    defer gpa.free(rgba);
    return encodePng(gpa, rgba, size, size);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testGradientSource(gpa: std.mem.Allocator, extent: usize) !Source {
    const pixels = try gpa.alloc(u8, extent * extent * 4);
    var y: usize = 0;
    while (y < extent) : (y += 1) {
        var x: usize = 0;
        while (x < extent) : (x += 1) {
            const base = (y * extent + x) * 4;
            pixels[base + 0] = @truncate((x * 255) / extent);
            pixels[base + 1] = @truncate((y * 255) / extent);
            pixels[base + 2] = 96;
            pixels[base + 3] = 255;
        }
    }
    return .{ .kind = .png, .width = extent, .height = extent, .image = .{ .width = extent, .height = extent, .pixels = pixels } };
}

test "png encode/decode round-trips rgba pixels" {
    const gpa = testing.allocator;
    const extent: usize = 21;
    var source = try testGradientSource(gpa, extent);
    defer source.deinit(gpa);
    const encoded = try encodePng(gpa, source.image.?.pixels, extent, extent);
    defer gpa.free(encoded);
    const decoded = try decodePng(gpa, encoded);
    defer decoded.deinit(gpa);
    try testing.expectEqual(extent, decoded.width);
    try testing.expectEqual(extent, decoded.height);
    try testing.expectEqualSlices(u8, source.image.?.pixels, decoded.pixels);

    const header = pngHeader(encoded) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(extent, header.width);
    try testing.expectEqual(extent, header.height);
}

test "png decoder reads the strict writer's stored-block output" {
    const gpa = testing.allocator;
    const width: usize = 5;
    const height: usize = 4;
    var pixels: [width * height * 4]u8 = undefined;
    var seed: u8 = 11;
    for (&pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 31 +% 7;
    }
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try png_model.writeRgba8(&writer, width, height, &pixels);
    const decoded = try decodePng(gpa, writer.buffered());
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}

/// Assemble a minimal PNG by hand with an arbitrary IHDR + filtered raw
/// stream (stored deflate blocks), to exercise decode paths the two
/// encoders never emit.
fn testBuildPng(gpa: std.mem.Allocator, width: usize, height: usize, bit_depth: u8, color_type: u8, palette: []const u8, transparency: []const u8, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &png_model.signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = bit_depth;
    ihdr[9] = color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendPngChunk(&out, gpa, "IHDR", &ihdr);
    if (palette.len > 0) try appendPngChunk(&out, gpa, "PLTE", palette);
    if (transparency.len > 0) try appendPngChunk(&out, gpa, "tRNS", transparency);

    // zlib stream of one stored deflate block.
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    try idat.appendSlice(gpa, &.{ 0x78, 0x01 });
    try idat.append(gpa, 1); // BFINAL, stored
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, length_bytes[0..2], @intCast(raw.len), .little);
    std.mem.writeInt(u16, length_bytes[2..4], @intCast(raw.len ^ 0xFFFF), .little);
    try idat.appendSlice(gpa, length_bytes[0..4]);
    try idat.appendSlice(gpa, raw);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(raw), .big);
    try idat.appendSlice(gpa, &adler_bytes);
    try appendPngChunk(&out, gpa, "IDAT", idat.items);
    try appendPngChunk(&out, gpa, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

test "png decoder undoes sub, average, and paeth filters" {
    const gpa = testing.allocator;
    // 2x2 RGB, rows filtered with Sub then Paeth.
    // Row 0 pixels: (10,20,30) (14,25,37) -> Sub deltas (10,20,30) (4,5,7).
    // Row 1 pixels: (12,22,32) (16,27,39); Paeth predictor for the first
    // pixel is up (10,20,30) -> deltas (2,2,2); for the second, left/up/
    // up-left = (12,22,32)/(14,25,37)/(10,20,30) -> estimates pick up.
    const raw = [_]u8{
        1, 10, 20, 30, 4, 5, 7,
        4, 2,  2,  2,  2, 2, 2,
    };
    const encoded = try testBuildPng(gpa, 2, 2, 8, 2, &.{}, &.{}, &raw);
    defer gpa.free(encoded);
    const decoded = try decodePng(gpa, encoded);
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 14, 25, 37, 255 }, decoded.pixels[0..8]);
    try testing.expectEqual(@as(u8, 12), decoded.pixels[8]);
    try testing.expectEqual(@as(u8, 22), decoded.pixels[9]);
    try testing.expectEqual(@as(u8, 32), decoded.pixels[10]);
    try testing.expectEqual(@as(u8, 16), decoded.pixels[12]);

    // Average filter, 1x2 grayscale: second row averages left=0, up=64.
    const gray_raw = [_]u8{ 0, 64, 3, 32 };
    const gray = try testBuildPng(gpa, 1, 2, 8, 0, &.{}, &.{}, &gray_raw);
    defer gpa.free(gray);
    const gray_decoded = try decodePng(gpa, gray);
    defer gray_decoded.deinit(gpa);
    try testing.expectEqual(@as(u8, 64), gray_decoded.pixels[0]);
    try testing.expectEqual(@as(u8, 64), gray_decoded.pixels[4]); // 32 + (0+64)/2
}

test "png decoder expands palette entries with transparency" {
    const gpa = testing.allocator;
    const palette = [_]u8{ 255, 0, 0, 0, 255, 0 };
    const transparency = [_]u8{ 128 }; // entry 0 half-transparent, entry 1 opaque
    const raw = [_]u8{ 0, 0, 1 }; // one row: filter 0, indexes 0 and 1
    const encoded = try testBuildPng(gpa, 2, 1, 8, 3, &palette, &transparency, &raw);
    defer gpa.free(encoded);
    const decoded = try decodePng(gpa, encoded);
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128, 0, 255, 0, 255 }, decoded.pixels);
}

test "png decoder rejects unsupported forms" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedImage, decodePng(gpa, "not a png"));
    // Interlaced flag set.
    var interlaced = std.ArrayList(u8).empty;
    defer interlaced.deinit(gpa);
    try interlaced.appendSlice(gpa, &png_model.signature);
    var ihdr: [13]u8 = .{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 1 };
    try appendPngChunk(&interlaced, gpa, "IHDR", &ihdr);
    try testing.expectError(error.UnsupportedImage, decodePng(gpa, interlaced.items));
}

test "load source reports non-square dimensions" {
    const gpa = testing.allocator;
    const pixels = try gpa.alloc(u8, 4 * 2 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 200);
    const encoded = try encodePng(gpa, pixels, 4, 2);
    defer gpa.free(encoded);
    const result = try loadSource(gpa, encoded, .png);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .issue => |issue| {
            try testing.expectEqual(@as(usize, 4), issue.not_square.width);
            try testing.expectEqual(@as(usize, 2), issue.not_square.height);
        },
    }
    var message_buffer: [512]u8 = undefined;
    const message = formatNotSquareMessage(&message_buffer, "assets/icon.png", 4, 2);
    try testing.expect(std.mem.indexOf(u8, message, "4x2") != null);
    try testing.expect(std.mem.indexOf(u8, message, "square") != null);
}

test "load source rejects undecodable bytes as unsupported" {
    const gpa = testing.allocator;
    const png_result = try loadSource(gpa, "definitely not an image", .png);
    try testing.expect(png_result == .issue and png_result.issue == .unsupported);
    const svg_result = try loadSource(gpa, "<div>not svg</div>", .svg);
    try testing.expect(svg_result == .issue and svg_result.issue == .unsupported);
}

test "checkerboard downscales to uniform gray, not moire" {
    const gpa = testing.allocator;
    const extent: usize = 256;
    const pixels = try gpa.alloc(u8, extent * extent * 4);
    defer gpa.free(pixels);
    var y: usize = 0;
    while (y < extent) : (y += 1) {
        var x: usize = 0;
        while (x < extent) : (x += 1) {
            const base = (y * extent + x) * 4;
            const value: u8 = if ((x / 2 + y / 2) % 2 == 0) 0 else 255;
            pixels[base + 0] = value;
            pixels[base + 1] = value;
            pixels[base + 2] = value;
            pixels[base + 3] = 255;
        }
    }
    var source = Source{ .kind = .png, .width = extent, .height = extent, .image = .{ .width = extent, .height = extent, .pixels = pixels } };
    const small = try renderSquare(gpa, &source, 16);
    defer gpa.free(small);
    // Every pixel identical (16 divides the 2px cells evenly), gray, and
    // near the sRGB encoding of linear 0.5 (~188) — a naive gamma-space
    // average would land at 127 instead.
    const first = small[0];
    try testing.expect(first >= 180 and first <= 195);
    var index: usize = 0;
    while (index < 16 * 16) : (index += 1) {
        try testing.expectEqual(first, small[index * 4 + 0]);
        try testing.expectEqual(first, small[index * 4 + 1]);
        try testing.expectEqual(first, small[index * 4 + 2]);
        try testing.expectEqual(@as(u8, 255), small[index * 4 + 3]);
    }
}

test "macos mask has transparent corners, opaque center, smooth edges" {
    const gpa = testing.allocator;
    const size: usize = 128;
    const mask = try macosMaskCoverage(gpa, size);
    defer gpa.free(mask);
    // Canvas corners sit in the margin: zero coverage.
    try testing.expectEqual(@as(f32, 0), mask[0]);
    try testing.expectEqual(@as(f32, 0), mask[size - 1]);
    try testing.expectEqual(@as(f32, 0), mask[(size - 1) * size]);
    try testing.expectEqual(@as(f32, 0), mask[size * size - 1]);
    // Center fully covered.
    try testing.expectEqual(@as(f32, 1), mask[(size / 2) * size + size / 2]);
    // The artwork corner arc produces fractional coverage somewhere: scan
    // the top-left corner region for a strictly partial pixel.
    var found_partial = false;
    var y: usize = 0;
    while (y < size / 2) : (y += 1) {
        var x: usize = 0;
        while (x < size / 2) : (x += 1) {
            const coverage = mask[y * size + x];
            if (coverage > 0.05 and coverage < 0.95) found_partial = true;
        }
    }
    try testing.expect(found_partial);
}

test "full-bleed source is masked and inset on the macos canvas" {
    const gpa = testing.allocator;
    var source = try testGradientSource(gpa, 256);
    defer source.deinit(gpa);
    try testing.expect(!imageIsPreShaped(source.image.?));
    const canvas = try renderMacosCanvas(gpa, &source, 64);
    defer gpa.free(canvas);
    // Corners transparent (margin + mask), center opaque.
    try testing.expectEqual(@as(u8, 0), canvas[3]);
    try testing.expectEqual(@as(u8, 0), canvas[(64 * 64 - 1) * 4 + 3]);
    try testing.expectEqual(@as(u8, 255), canvas[(32 * 64 + 32) * 4 + 3]);
    // The margin band itself is empty: a pixel just inside the canvas
    // edge midline is outside the artwork square.
    try testing.expectEqual(@as(u8, 0), canvas[(32 * 64 + 0) * 4 + 3]);
}

test "pre-shaped source ships untouched on the macos canvas" {
    const gpa = testing.allocator;
    const extent: usize = 128;
    const pixels = try gpa.alloc(u8, extent * extent * 4);
    var y: usize = 0;
    while (y < extent) : (y += 1) {
        var x: usize = 0;
        while (x < extent) : (x += 1) {
            const base = (y * extent + x) * 4;
            // A centered opaque disc: corners transparent -> pre-shaped.
            const dx = @as(f32, @floatFromInt(x)) - 63.5;
            const dy = @as(f32, @floatFromInt(y)) - 63.5;
            const inside = dx * dx + dy * dy <= 60.0 * 60.0;
            pixels[base + 0] = 255;
            pixels[base + 1] = 0;
            pixels[base + 2] = 0;
            pixels[base + 3] = if (inside) 255 else 0;
        }
    }
    var source = Source{ .kind = .png, .width = extent, .height = extent, .image = .{ .width = extent, .height = extent, .pixels = pixels } };
    defer source.deinit(gpa);
    try testing.expect(imageIsPreShaped(source.image.?));
    const canvas = try renderMacosCanvas(gpa, &source, 128);
    defer gpa.free(canvas);
    // The disc edge reaches x=4 at the midline — inside the 12.5% margin
    // a full-bleed source would have been inset behind.
    try testing.expect(canvas[(64 * 128 + 5) * 4 + 3] > 200);
}

test "icns round-trips its own members" {
    const gpa = testing.allocator;
    var source = try testGradientSource(gpa, 64);
    defer source.deinit(gpa);
    const icns = try buildIcns(gpa, &source);
    defer gpa.free(icns);

    var iterator = IcnsIterator.init(icns) orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    while (iterator.next()) |member| {
        const slot = icns_slots[seen];
        try testing.expectEqualSlices(u8, &slot.kind, &member.kind);
        switch (slot.payload) {
            .png => {
                const header = pngHeader(member.data) orelse return error.TestUnexpectedResult;
                try testing.expectEqual(slot.size, header.width);
                try testing.expectEqual(slot.size, header.height);
            },
            .argb => {
                const rgba = try decodeArgb(gpa, member.data, slot.size, slot.size);
                defer gpa.free(rgba);
                try testing.expectEqual(slot.size * slot.size * 4, rgba.len);
            },
        }
        seen += 1;
    }
    try testing.expectEqual(icns_slots.len, seen);
}

test "argb payload round-trips rgba pixels" {
    const gpa = testing.allocator;
    const extent: usize = 16;
    var source = try testGradientSource(gpa, extent);
    defer source.deinit(gpa);
    const payload = try encodeArgb(gpa, source.image.?.pixels, extent, extent);
    defer gpa.free(payload);
    try testing.expectEqualSlices(u8, "ARGB", payload[0..4]);
    const decoded = try decodeArgb(gpa, payload, extent, extent);
    defer gpa.free(decoded);
    try testing.expectEqualSlices(u8, source.image.?.pixels, decoded);

    // Long uniform runs compress: a solid square's payload is far
    // smaller than its raw planes.
    const solid = try gpa.alloc(u8, 32 * 32 * 4);
    defer gpa.free(solid);
    @memset(solid, 77);
    const solid_payload = try encodeArgb(gpa, solid, 32, 32);
    defer gpa.free(solid_payload);
    try testing.expect(solid_payload.len < 32 * 32);
    const solid_decoded = try decodeArgb(gpa, solid_payload, 32, 32);
    defer gpa.free(solid_decoded);
    try testing.expectEqualSlices(u8, solid, solid_decoded);
}

test "ico round-trips its own directory" {
    const gpa = testing.allocator;
    var source = try testGradientSource(gpa, 64);
    defer source.deinit(gpa);
    const ico = try buildIco(gpa, &source);
    defer gpa.free(ico);

    var iterator = IcoIterator.init(ico) orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    while (iterator.next()) |entry| {
        try testing.expectEqual(ico_sizes[seen], entry.size);
        const header = pngHeader(entry.data) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(ico_sizes[seen], header.width);
        seen += 1;
    }
    try testing.expectEqual(ico_sizes.len, seen);
}

test "svg source rasterizes per size" {
    const gpa = testing.allocator;
    const svg = "<svg viewBox=\"0 0 24 24\"><rect x=\"0\" y=\"0\" width=\"24\" height=\"24\" fill=\"#ff0000\"/></svg>";
    const result = try loadSource(gpa, svg, .svg);
    var source = switch (result) {
        .ok => |value| value,
        .issue => return error.TestUnexpectedResult,
    };
    defer source.deinit(gpa);

    const square = try renderSquare(gpa, &source, 32);
    defer gpa.free(square);
    // Full-bleed red: center and corners opaque red.
    try testing.expectEqual(@as(u8, 255), square[(16 * 32 + 16) * 4 + 0]);
    try testing.expectEqual(@as(u8, 255), square[(16 * 32 + 16) * 4 + 3]);
    try testing.expectEqual(@as(u8, 255), square[3]);

    // The macOS canvas masks the full-bleed rect: corners become
    // transparent, center stays opaque.
    const canvas = try renderMacosCanvas(gpa, &source, 32);
    defer gpa.free(canvas);
    try testing.expectEqual(@as(u8, 0), canvas[3]);
    try testing.expectEqual(@as(u8, 255), canvas[(16 * 32 + 16) * 4 + 3]);
}

test "source kind classification by extension" {
    try testing.expectEqual(SourceKind.png, sourceKindForPath("assets/icon.png").?);
    try testing.expectEqual(SourceKind.png, sourceKindForPath("assets/ICON.PNG").?);
    try testing.expectEqual(SourceKind.svg, sourceKindForPath("assets/icon.svg").?);
    try testing.expectEqual(@as(?SourceKind, null), sourceKindForPath("assets/icon.icns"));
    try testing.expectEqual(@as(?SourceKind, null), sourceKindForPath("assets/icon.ico"));
    try testing.expectEqual(@as(?SourceKind, null), sourceKindForPath("assets/icon.jpg"));
}
