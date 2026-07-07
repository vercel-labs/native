//! Default app-icon generator: renders the SDK's default macOS app icon
//! from vector geometry through the same path rasterizer the reference
//! renderer uses, so the icon regenerates from source — no opaque
//! binary-only asset checked in anywhere, and no external tools: the
//! `.icns` and `.ico` containers are assembled by the built-in app-icon
//! pipeline (`canvas.app_icon`) and round-trip-validated with its own
//! parsers.
//!
//! The design follows the macOS icon grid: a 1024x1024 canvas with a
//! centered 824x824 rounded-rect plate (corner radius 185.4), a subtle
//! baked drop shadow, a vertical DARK-GRAY gradient on the design-token
//! dark-neutral family (#262626 falling to #171717 — the dark scheme's
//! surface_subtle and surface steps), and a neutral layered-surface
//! mark: two offset rounded sheets, the back one translucent. No
//! letterforms, no wordmark. Dark gray is the default-plate decision:
//! apps that ship no icon get a quiet neutral plate, never a hue that
//! could read as their brand.
//!
//! Regenerate everything with ONE command from the repo root:
//!
//!   zig build generate-icon
//!
//! which writes assets/icon.{icns,png,ico,svg}, syncs the CLI's embedded
//! scaffold copies (src/tooling/default_icon.icns and default_icon.png),
//! and emits a full-bleed variant (the same design without plate or
//! margins) to every listed path — a scratch preview plus the checked-in
//! copy in the notes example, which demonstrates the packaging
//! pipeline's automatic mask + inset from one raw source and therefore
//! must regenerate in lockstep with the default.
//!
//! Usage: generate-app-icon <icns> <png> <ico> <svg> <default-icns> <default-png> <full-bleed-png>...

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const vector = canvas.vector;
const app_icon = canvas.app_icon;
const PointF = geometry.PointF;
const Affine = canvas.Affine;

// ---------------------------------------------------------------------------
// Design constants (1024 design grid)
// ---------------------------------------------------------------------------

/// Design canvas — the macOS icon grid is specified at 1024x1024.
const design_size: f32 = 1024;
/// Master raster size; every shipped size is an area-average downsample
/// of this, so edges get supersampled antialiasing on top of the
/// rasterizer's own coverage AA.
const master_size: usize = 2048;

/// The icon plate: the grid centers an 824x824 rounded rect on the 1024
/// canvas (100px margins) with a 185.4px corner radius.
const plate = RoundedRect{ .x = 100, .y = 100, .w = 824, .h = 824, .r = 185.4 };

/// Baked drop shadow (macOS icons carry their own shadow; the system
/// does not add one in the Dock).
const shadow_offset_y: f32 = 12;
const shadow_sigma: f32 = 16;
const shadow_alpha: f32 = 0.30;

/// Vertical plate gradient on the dark-neutral token family: #262626
/// (the dark scheme's surface_subtle, oklch 0.269) at the top falling
/// to #171717 (dark surface, oklch 0.205) — a dark-gray plate that
/// stays register-neutral for apps that ship no icon of their own.
const gradient_top = [3]f32{ 38.0 / 255.0, 38.0 / 255.0, 38.0 / 255.0 };
const gradient_bottom = [3]f32{ 23.0 / 255.0, 23.0 / 255.0, 23.0 / 255.0 };

/// The mark: two layered "surface" sheets, offset along the diagonal so
/// the union is centered on the canvas. The back sheet is translucent
/// white; the front sheet is opaque white.
const back_sheet = RoundedRect{ .x = 372, .y = 272, .w = 380, .h = 380, .r = 84 };
const front_sheet = RoundedRect{ .x = 272, .y = 372, .w = 380, .h = 380, .r = 84 };
const back_sheet_alpha: f32 = 0.52;

/// Shipped raster sizes: the union of the .icns family and the .ico
/// directory sizes.
const output_sizes = [_]usize{ 16, 24, 32, 48, 64, 128, 256, 512, 1024 };

const RoundedRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
};

/// Map a design-grid rounded rect through the full-bleed transform: the
/// plate square (824 wide, 100 margins) expands to cover the whole
/// canvas, so the full-bleed variant is the identical composition with
/// the plate itself removed — exactly what the packaging pipeline's
/// mask + inset reconstructs.
fn fullBleed(rect: RoundedRect) RoundedRect {
    const scale = design_size / plate.w;
    const center = design_size * 0.5;
    return .{
        .x = (rect.x - center) * scale + center,
        .y = (rect.y - center) * scale + center,
        .w = rect.w * scale,
        .h = rect.h * scale,
        .r = rect.r * scale,
    };
}

// ---------------------------------------------------------------------------
// Rasterization helpers
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
        self.mask[index] = @min(1, self.mask[index] + coverage);
    }
};

/// Fill `mask` with the coverage of a rounded rect given in design
/// coordinates, scaled to the master raster.
fn rasterizeRoundedRect(mask: []f32, rect: RoundedRect, offset_y: f32) !void {
    const scale = @as(f32, @floatFromInt(master_size)) / design_size;
    var builder = vector.PathBuilder(64){};
    const x0 = rect.x;
    const y0 = rect.y + offset_y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h + offset_y;
    const r = rect.r;
    try builder.moveTo(PointF.init(x0 + r, y0));
    try builder.lineTo(PointF.init(x1 - r, y0));
    try builder.arcTo(r, r, 0, false, true, PointF.init(x1, y0 + r));
    try builder.lineTo(PointF.init(x1, y1 - r));
    try builder.arcTo(r, r, 0, false, true, PointF.init(x1 - r, y1));
    try builder.lineTo(PointF.init(x0 + r, y1));
    try builder.arcTo(r, r, 0, false, true, PointF.init(x0, y1 - r));
    try builder.lineTo(PointF.init(x0, y0 + r));
    try builder.arcTo(r, r, 0, false, true, PointF.init(x0 + r, y0));
    try builder.close();

    @memset(mask, 0);
    var sink = MaskSink{ .mask = mask, .width = master_size };
    const clip = vector.ClipRect{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast(master_size),
        .y1 = @intCast(master_size),
    };
    try vector.fillPath(
        builder.slice(),
        Affine.scale(scale, scale),
        .nonzero,
        vector.default_tolerance,
        clip,
        &sink,
    );
}

/// Fill `mask` with full coverage (the full-bleed background).
fn fillMask(mask: []f32) void {
    @memset(mask, 1);
}

/// Composite `mask` over the premultiplied RGBA f32 canvas with a solid
/// color. `alpha` scales the mask.
fn compositeSolid(pixels: []f32, mask: []const f32, r: f32, g: f32, b: f32, alpha: f32) void {
    for (mask, 0..) |coverage, i| {
        if (coverage <= 0) continue;
        const sa = coverage * alpha;
        const inv = 1 - sa;
        const base = i * 4;
        pixels[base + 0] = r * sa + pixels[base + 0] * inv;
        pixels[base + 1] = g * sa + pixels[base + 1] * inv;
        pixels[base + 2] = b * sa + pixels[base + 2] * inv;
        pixels[base + 3] = sa + pixels[base + 3] * inv;
    }
}

/// Composite `mask` with a vertical linear gradient spanning `top_y` to
/// `top_y + span` in design coordinates.
fn compositeVerticalGradient(pixels: []f32, mask: []const f32, top_y_design: f32, span_design: f32) void {
    const scale = @as(f32, @floatFromInt(master_size)) / design_size;
    const top_y = top_y_design * scale;
    const span = span_design * scale;
    var y: usize = 0;
    while (y < master_size) : (y += 1) {
        const t = std.math.clamp((@as(f32, @floatFromInt(y)) + 0.5 - top_y) / span, 0, 1);
        const r = gradient_top[0] + (gradient_bottom[0] - gradient_top[0]) * t;
        const g = gradient_top[1] + (gradient_bottom[1] - gradient_top[1]) * t;
        const b = gradient_top[2] + (gradient_bottom[2] - gradient_top[2]) * t;
        var x: usize = 0;
        while (x < master_size) : (x += 1) {
            const i = y * master_size + x;
            const coverage = mask[i];
            if (coverage <= 0) continue;
            const inv = 1 - coverage;
            const base = i * 4;
            pixels[base + 0] = r * coverage + pixels[base + 0] * inv;
            pixels[base + 1] = g * coverage + pixels[base + 1] * inv;
            pixels[base + 2] = b * coverage + pixels[base + 2] * inv;
            pixels[base + 3] = coverage + pixels[base + 3] * inv;
        }
    }
}

// ---------------------------------------------------------------------------
// Shadow blur: three box passes approximate a gaussian (Wells '86).
// ---------------------------------------------------------------------------

fn boxBlurPass(source: []const f32, dest: []f32, width: usize, height: usize, radius: usize, comptime horizontal: bool) void {
    const window = @as(f32, @floatFromInt(2 * radius + 1));
    const major = if (horizontal) height else width;
    const minor = if (horizontal) width else height;
    var line: usize = 0;
    while (line < major) : (line += 1) {
        var sum: f32 = 0;
        var i: usize = 0;
        while (i <= radius and i < minor) : (i += 1) sum += at(source, width, line, i, horizontal);
        var pos: usize = 0;
        while (pos < minor) : (pos += 1) {
            setAt(dest, width, line, pos, horizontal, sum / window);
            if (pos + radius + 1 < minor) sum += at(source, width, line, pos + radius + 1, horizontal);
            if (pos >= radius) sum -= at(source, width, line, pos - radius, horizontal);
        }
    }
}

inline fn at(buffer: []const f32, width: usize, line: usize, pos: usize, comptime horizontal: bool) f32 {
    return if (horizontal) buffer[line * width + pos] else buffer[pos * width + line];
}

inline fn setAt(buffer: []f32, width: usize, line: usize, pos: usize, comptime horizontal: bool, value: f32) void {
    if (horizontal) buffer[line * width + pos] = value else buffer[pos * width + line] = value;
}

/// Approximate a gaussian blur of `sigma` (master-raster pixels) with
/// three box passes per axis.
fn gaussianBlur(mask: []f32, scratch: []f32, sigma: f32) void {
    // Ideal box width for three passes: w = sqrt(12 sigma^2 / 3 + 1).
    const w = @sqrt(12.0 * sigma * sigma / 3.0 + 1.0);
    const radius: usize = @intFromFloat(@max(1, (w - 1) / 2));
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        boxBlurPass(mask, scratch, master_size, master_size, radius, true);
        boxBlurPass(scratch, mask, master_size, master_size, radius, false);
    }
}

// ---------------------------------------------------------------------------
// Downsampling: exact area average from the master raster.
// ---------------------------------------------------------------------------

fn downsample(allocator: std.mem.Allocator, master: []const f32, size: usize) ![]u8 {
    const out = try allocator.alloc(u8, size * size * 4);
    const ratio = @as(f64, @floatFromInt(master_size)) / @as(f64, @floatFromInt(size));
    var oy: usize = 0;
    while (oy < size) : (oy += 1) {
        const sy0 = @as(f64, @floatFromInt(oy)) * ratio;
        const sy1 = @as(f64, @floatFromInt(oy + 1)) * ratio;
        var ox: usize = 0;
        while (ox < size) : (ox += 1) {
            const sx0 = @as(f64, @floatFromInt(ox)) * ratio;
            const sx1 = @as(f64, @floatFromInt(ox + 1)) * ratio;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var area: f64 = 0;
            var sy: usize = @intFromFloat(@floor(sy0));
            while (sy < master_size and @as(f64, @floatFromInt(sy)) < sy1) : (sy += 1) {
                const cover_y = @min(sy1, @as(f64, @floatFromInt(sy + 1))) - @max(sy0, @as(f64, @floatFromInt(sy)));
                if (cover_y <= 0) continue;
                var sx: usize = @intFromFloat(@floor(sx0));
                while (sx < master_size and @as(f64, @floatFromInt(sx)) < sx1) : (sx += 1) {
                    const cover_x = @min(sx1, @as(f64, @floatFromInt(sx + 1))) - @max(sx0, @as(f64, @floatFromInt(sx)));
                    if (cover_x <= 0) continue;
                    const weight = cover_x * cover_y;
                    const base = (sy * master_size + sx) * 4;
                    acc[0] += master[base + 0] * weight;
                    acc[1] += master[base + 1] * weight;
                    acc[2] += master[base + 2] * weight;
                    acc[3] += master[base + 3] * weight;
                    area += weight;
                }
            }
            const base = (oy * size + ox) * 4;
            const alpha = if (area > 0) acc[3] / area else 0;
            // Un-premultiply for PNG straight-alpha storage.
            if (alpha > 0.0001) {
                out[base + 0] = quantize(acc[0] / area / alpha);
                out[base + 1] = quantize(acc[1] / area / alpha);
                out[base + 2] = quantize(acc[2] / area / alpha);
            } else {
                out[base + 0] = 0;
                out[base + 1] = 0;
                out[base + 2] = 0;
            }
            out[base + 3] = quantize(alpha);
        }
    }
    return out;
}

fn quantize(value: f64) u8 {
    return @intFromFloat(std.math.clamp(value * 255.0 + 0.5, 0, 255));
}

// ---------------------------------------------------------------------------
// Composition
// ---------------------------------------------------------------------------

const Variant = enum {
    /// The shipped icon: plate + margins + shadow on a transparent canvas.
    plate,
    /// The same composition covering the full square, no plate or shadow —
    /// input for pipelines that apply the platform mask themselves.
    full_bleed,
};

fn renderMaster(gpa: std.mem.Allocator, master: []f32, mask: []f32, scratch: []f32, variant: Variant) !void {
    @memset(master, 0);
    switch (variant) {
        .plate => {
            // 1. Baked drop shadow under the plate.
            try rasterizeRoundedRect(mask, plate, shadow_offset_y);
            gaussianBlur(mask, scratch, shadow_sigma * (@as(f32, @floatFromInt(master_size)) / design_size));
            compositeSolid(master, mask, 0, 0, 0, shadow_alpha);
            // 2. The plate with its vertical gradient.
            try rasterizeRoundedRect(mask, plate, 0);
            compositeVerticalGradient(master, mask, plate.y, plate.h);
            // 3 + 4. Surface sheets.
            try rasterizeRoundedRect(mask, back_sheet, 0);
            compositeSolid(master, mask, 1, 1, 1, back_sheet_alpha);
            try rasterizeRoundedRect(mask, front_sheet, 0);
            compositeSolid(master, mask, 1, 1, 1, 1);
        },
        .full_bleed => {
            fillMask(mask);
            compositeVerticalGradient(master, mask, 0, design_size);
            try rasterizeRoundedRect(mask, fullBleed(back_sheet), 0);
            compositeSolid(master, mask, 1, 1, 1, back_sheet_alpha);
            try rasterizeRoundedRect(mask, fullBleed(front_sheet), 0);
            compositeSolid(master, mask, 1, 1, 1, 1);
        },
    }
    _ = gpa;
}

// ---------------------------------------------------------------------------
// SVG mirror of the same geometry, for design handoff and preview.
// ---------------------------------------------------------------------------

fn writeSvg(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const svg = try std.fmt.allocPrint(allocator,
        \\<!-- Generated by `zig build generate-icon` (tools/generate_app_icon.zig). Edit the tool, not this file. -->
        \\<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
        \\  <defs>
        \\    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">
        \\      <stop offset="0" stop-color="{s}"/>
        \\      <stop offset="1" stop-color="{s}"/>
        \\    </linearGradient>
        \\    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
        \\      <feDropShadow dx="0" dy="{d}" stdDeviation="{d}" flood-color="#000000" flood-opacity="{d}"/>
        \\    </filter>
        \\  </defs>
        \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" rx="{d}" fill="url(#plate)" filter="url(#shadow)"/>
        \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" rx="{d}" fill="#ffffff" fill-opacity="{d}"/>
        \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" rx="{d}" fill="#ffffff"/>
        \\</svg>
        \\
    , .{
        hexColor(gradient_top),
        hexColor(gradient_bottom),
        shadow_offset_y,
        shadow_sigma,
        shadow_alpha,
        plate.x,
        plate.y,
        plate.w,
        plate.h,
        plate.r,
        back_sheet.x,
        back_sheet.y,
        back_sheet.w,
        back_sheet.h,
        back_sheet.r,
        back_sheet_alpha,
        front_sheet.x,
        front_sheet.y,
        front_sheet.w,
        front_sheet.h,
        front_sheet.r,
    });
    defer allocator.free(svg);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = svg });
}

fn hexColor(rgb: [3]f32) [7]u8 {
    var out: [7]u8 = undefined;
    out[0] = '#';
    const digits = "0123456789abcdef";
    for (rgb, 0..) |channel, i| {
        const value: u8 = @intFromFloat(std.math.clamp(channel * 255.0 + 0.5, 0, 255));
        out[1 + i * 2] = digits[value >> 4];
        out[2 + i * 2] = digits[value & 15];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 8) usage();
    const icns_path = args[1];
    const png_path = args[2];
    const ico_path = args[3];
    const svg_path = args[4];
    const default_icns_path = args[5];
    const default_png_path = args[6];
    // One or more full-bleed outputs: the scratch preview plus every
    // checked-in copy that must stay in lockstep with the default (the
    // notes example's raw one-image source), so a default redesign can
    // never leave a stale committed copy behind.
    const full_bleed_png_paths = args[7..];

    const pixel_count = master_size * master_size;
    const master = try gpa.alloc(f32, pixel_count * 4);
    defer gpa.free(master);
    const mask = try gpa.alloc(f32, pixel_count);
    defer gpa.free(mask);
    const scratch = try gpa.alloc(f32, pixel_count);
    defer gpa.free(scratch);

    // The shipped (plate) variant at every output size.
    try renderMaster(gpa, master, mask, scratch, .plate);
    var renders: [output_sizes.len][]u8 = undefined;
    var pngs: [output_sizes.len][]u8 = undefined;
    var encoded_count: usize = 0;
    defer for (renders[0..encoded_count], pngs[0..encoded_count]) |rgba, bytes| {
        gpa.free(rgba);
        gpa.free(bytes);
    };
    for (output_sizes, 0..) |size, i| {
        renders[i] = try downsample(gpa, master, size);
        pngs[i] = try app_icon.encodePng(gpa, renders[i], size, size);
        encoded_count += 1;
    }

    // .icns straight from the built-in writer (each slot in the payload
    // form it expects), then round-trip-check it with the built-in
    // parsers.
    var payloads: [app_icon.icns_slots.len][]u8 = undefined;
    var payload_count: usize = 0;
    defer for (payloads[0..payload_count]) |bytes| gpa.free(bytes);
    var members: [app_icon.icns_slots.len]app_icon.IcnsMember = undefined;
    for (app_icon.icns_slots, 0..) |slot, i| {
        payloads[i] = try app_icon.encodeIcnsPayload(gpa, slot, renders[sizeIndex(slot.size)]);
        payload_count += 1;
        members[i] = .{ .kind = slot.kind, .data = payloads[i] };
    }
    const icns = try app_icon.writeIcns(gpa, &members);
    defer gpa.free(icns);
    var icns_iterator = app_icon.IcnsIterator.init(icns) orelse return error.InvalidGeneratedIcns;
    var member_count: usize = 0;
    while (icns_iterator.next()) |member| {
        const slot = app_icon.icns_slots[member_count];
        switch (slot.payload) {
            .png => {
                const header = app_icon.pngHeader(member.data) orelse return error.InvalidGeneratedIcns;
                if (header.width != slot.size) return error.InvalidGeneratedIcns;
            },
            .argb => {
                const rgba = try app_icon.decodeArgb(gpa, member.data, slot.size, slot.size);
                gpa.free(rgba);
            },
        }
        member_count += 1;
    }
    if (member_count != app_icon.icns_slots.len) return error.InvalidGeneratedIcns;

    var cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = icns_path, .data = icns });
    try cwd.writeFile(io, .{ .sub_path = default_icns_path, .data = icns });
    try cwd.writeFile(io, .{ .sub_path = png_path, .data = pngs[sizeIndex(1024)] });
    try cwd.writeFile(io, .{ .sub_path = default_png_path, .data = pngs[sizeIndex(1024)] });

    var ico_entries: [app_icon.ico_sizes.len]app_icon.IcoEntry = undefined;
    for (app_icon.ico_sizes, 0..) |size, i| ico_entries[i] = .{ .size = size, .data = pngs[sizeIndex(size)] };
    const ico = try app_icon.writeIco(gpa, &ico_entries);
    defer gpa.free(ico);
    try cwd.writeFile(io, .{ .sub_path = ico_path, .data = ico });

    try writeSvg(gpa, io, svg_path);

    // The full-bleed variant (1024 only): the pipeline-demo source.
    try renderMaster(gpa, master, mask, scratch, .full_bleed);
    const full_bleed_rgba = try downsample(gpa, master, 1024);
    defer gpa.free(full_bleed_rgba);
    const full_bleed_png = try app_icon.encodePng(gpa, full_bleed_rgba, 1024, 1024);
    defer gpa.free(full_bleed_png);
    for (full_bleed_png_paths) |full_bleed_png_path| {
        if (std.fs.path.dirname(full_bleed_png_path)) |parent| try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = full_bleed_png_path, .data = full_bleed_png });
    }

    std.debug.print("generated {s} ({d} members), {s}, {s}, {s}, {s}, {s}", .{
        icns_path,
        app_icon.icns_slots.len,
        png_path,
        ico_path,
        svg_path,
        default_icns_path,
        default_png_path,
    });
    for (full_bleed_png_paths) |full_bleed_png_path| std.debug.print(", {s}", .{full_bleed_png_path});
    std.debug.print("\n", .{});
}

fn sizeIndex(size: usize) usize {
    for (output_sizes, 0..) |candidate, i| {
        if (candidate == size) return i;
    }
    unreachable;
}

fn usage() noreturn {
    std.debug.print("usage: generate-app-icon <icns> <png> <ico> <svg> <default-icns> <default-png> <full-bleed-png>...\n", .{});
    std.process.exit(2);
}
