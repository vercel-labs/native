//! Cover-art generator for the soundboard example: renders the eight
//! abstract album covers (gradients + one geometric motif each) and writes
//! them to `src/covers/cover-<n>.png`. Deterministic — the same source
//! always produces byte-identical PNGs.
//!
//! Run from the example directory:
//!
//!   zig run tools/gen_covers.zig
//!
//! The PNG encoder below mirrors `canvas.png.writeRgba8` exactly (8-bit
//! RGBA, zlib stream of stored deflate blocks): the runtime's strict test
//! decoder (`harness.null_platform.image_decode`) accepts only that subset,
//! so covers generated here decode both live (CGImageSource) and in the
//! deterministic test suite. The duplication is confined to this dev-only
//! tool; the example's tests decode every committed cover, so drift between
//! the two writers fails loudly.

const std = @import("std");

const size: usize = 256; // committed cover size
const super: usize = 2; // 2x2 supersampling for clean edges
const hi: usize = size * super;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const pixels = try allocator.alloc(u8, size * size * 4);
    const hires = try allocator.alloc(f32, hi * hi * 3);

    const out_buffer = try allocator.alloc(u8, encodedRgba8ByteLen(size, size));

    for (covers, 1..) |cover, index| {
        render(cover, hires);
        downsample(hires, pixels);

        var writer = std.Io.Writer.fixed(out_buffer);
        try writeRgba8(&writer, size, size, pixels);
        const encoded = writer.buffered();

        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "src/covers/cover-{d}.png", .{index});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = encoded });
        std.debug.print("wrote {s} ({d} bytes)\n", .{ path, encoded.len });
    }
}

// ----------------------------------------------------------------- palette

const Rgb = struct { r: f32, g: f32, b: f32 };

fn rgb(r: u8, g: u8, b: u8) Rgb {
    // sRGB bytes to linear-ish floats (gamma-2 approximation, comptime
    // friendly) so gradient midpoints stay luminous instead of muddy.
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    return .{ .r = rf * rf, .g = gf * gf, .b = bf * bf };
}

fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    const clamped = std.math.clamp(t, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * clamped,
        .g = a.g + (b.g - a.g) * clamped,
        .b = a.b + (b.b - a.b) * clamped,
    };
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Soft-edged coverage for a signed distance: 1 fully inside, 0 outside,
/// with a ~1.5px (hi-res) anti-aliased edge.
fn edge(distance: f32) f32 {
    return 1 - smoothstep(-1.5, 1.5, distance);
}

// ------------------------------------------------------------------ motifs

const Motif = enum {
    glow_ring, // off-center ring with a soft outer glow
    horizon, // horizon line with a low sun
    stripes, // wide diagonal bands
    sun_disc, // one large soft disc
    loops, // concentric rings
    orbits, // two orbital arcs and a small planet
    waves, // stacked sine bands
    breakwater, // wavy split field with a signal dot
};

const Cover = struct {
    top: Rgb,
    bottom: Rgb,
    ink: Rgb, // motif color
    motif: Motif,
    diagonal: bool = false, // gradient axis: vertical or diagonal
};

// Order matches the album table in src/model.zig.
const covers = [_]Cover{
    // 1 Midnight Voltage — Neon Cascade
    .{ .top = rgb(43, 27, 77), .bottom = rgb(255, 94, 145), .ink = rgb(255, 214, 231), .motif = .glow_ring, .diagonal = true },
    // 2 Glass Horizon — Aurora Fields
    .{ .top = rgb(127, 216, 208), .bottom = rgb(13, 43, 69), .ink = rgb(244, 250, 247), .motif = .horizon },
    // 3 Ember Lines — Cinder & Sage
    .{ .top = rgb(226, 87, 27), .bottom = rgb(74, 16, 48), .ink = rgb(255, 200, 150), .motif = .stripes, .diagonal = true },
    // 4 Slow Light — Marlowe
    .{ .top = rgb(246, 226, 184), .bottom = rgb(217, 131, 36), .ink = rgb(252, 246, 231), .motif = .sun_disc },
    // 5 Northern Loops — Polar Echo
    .{ .top = rgb(223, 233, 243), .bottom = rgb(40, 53, 110), .ink = rgb(250, 252, 255), .motif = .loops, .diagonal = true },
    // 6 Paper Planets — The Cartographers
    .{ .top = rgb(191, 230, 200), .bottom = rgb(20, 83, 45), .ink = rgb(240, 250, 240), .motif = .orbits },
    // 7 Velvet Static — Ivy Meridian
    .{ .top = rgb(109, 42, 88), .bottom = rgb(240, 166, 184), .ink = rgb(250, 226, 235), .motif = .waves, .diagonal = true },
    // 8 Salt & Signal — Harbor Lights
    .{ .top = rgb(18, 50, 79), .bottom = rgb(43, 84, 120), .ink = rgb(255, 127, 102), .motif = .breakwater },
};

fn render(cover: Cover, out: []f32) void {
    const extent: f32 = @floatFromInt(hi);
    for (0..hi) |py| {
        for (0..hi) |px| {
            const x: f32 = @floatFromInt(px);
            const y: f32 = @floatFromInt(py);
            const u = x / extent;
            const v = y / extent;

            const t = if (cover.diagonal) (u + v) * 0.5 else v;
            var color = mix(cover.top, cover.bottom, t);
            color = applyMotif(cover, color, x, y, u, v, extent);

            // Gentle corner vignette keeps the set cohesive.
            const dx = u - 0.5;
            const dy = v - 0.5;
            const vignette = 1 - 0.18 * smoothstep(0.42, 0.72, @sqrt(dx * dx + dy * dy));
            color.r *= vignette;
            color.g *= vignette;
            color.b *= vignette;

            const base = (py * hi + px) * 3;
            out[base] = color.r;
            out[base + 1] = color.g;
            out[base + 2] = color.b;
        }
    }
}

fn applyMotif(cover: Cover, base: Rgb, x: f32, y: f32, u: f32, v: f32, extent: f32) Rgb {
    switch (cover.motif) {
        .glow_ring => {
            const cx = extent * 0.66;
            const cy = extent * 0.34;
            const radius = extent * 0.24;
            const dist = @sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            // Soft halo behind the ring.
            const halo = 0.35 * (1 - smoothstep(0, extent * 0.42, dist));
            const color = mix(base, cover.ink, halo);
            const ring = edge(@abs(dist - radius) - extent * 0.016);
            return mix(color, cover.ink, ring * 0.9);
        },
        .horizon => {
            const horizon_y = extent * 0.62;
            // Low sun resting on the horizon.
            const cx = extent * 0.5;
            const dist = @sqrt((x - cx) * (x - cx) + (y - horizon_y) * (y - horizon_y));
            const glow = 0.5 * (1 - smoothstep(0, extent * 0.3, dist));
            var color = mix(base, cover.ink, if (y < horizon_y) glow else glow * 0.25);
            const disc = edge(dist - extent * 0.11);
            color = mix(color, cover.ink, if (y <= horizon_y) disc * 0.95 else 0);
            const line = edge(@abs(y - horizon_y) - extent * 0.004);
            return mix(color, cover.ink, line * 0.8);
        },
        .stripes => {
            // Three wide translucent bands along the counter-diagonal.
            const d = (u - v) * extent;
            var coverage: f32 = 0;
            const width = extent * 0.052;
            const offsets = [_]f32{ -0.3, 0.0, 0.3 };
            for (offsets) |offset| {
                coverage = @max(coverage, edge(@abs(d - offset * extent) - width));
            }
            return mix(base, cover.ink, coverage * 0.42);
        },
        .sun_disc => {
            const cx = extent * 0.38;
            const cy = extent * 0.4;
            const dist = @sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            const halo = 0.4 * (1 - smoothstep(0, extent * 0.5, dist));
            const color = mix(base, cover.ink, halo);
            const disc = edge(dist - extent * 0.2);
            return mix(color, cover.ink, disc * 0.85);
        },
        .loops => {
            const cx = extent * 0.3;
            const cy = extent * 0.72;
            const dist = @sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            var coverage: f32 = 0;
            var radius = extent * 0.1;
            while (radius < extent * 0.75) : (radius += extent * 0.13) {
                coverage = @max(coverage, edge(@abs(dist - radius) - extent * 0.011));
            }
            return mix(base, cover.ink, coverage * 0.65);
        },
        .orbits => {
            const cx = extent * 0.54;
            const cy = extent * 0.48;
            const dist = @sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            var color = base;
            const inner = edge(@abs(dist - extent * 0.2) - extent * 0.007);
            const outer = edge(@abs(dist - extent * 0.34) - extent * 0.007);
            color = mix(color, cover.ink, @max(inner, outer) * 0.7);
            // The planet sits on the outer orbit, upper left.
            const angle = std.math.pi * 1.22;
            const planet_x = cx + extent * 0.34 * @cos(angle);
            const planet_y = cy + extent * 0.34 * @sin(angle);
            const planet = edge(@sqrt((x - planet_x) * (x - planet_x) + (y - planet_y) * (y - planet_y)) - extent * 0.05);
            return mix(color, cover.ink, planet * 0.95);
        },
        .waves => {
            var coverage: f32 = 0;
            const rows = [_]f32{ 0.3, 0.5, 0.7 };
            for (rows, 0..) |row, index| {
                const phase: f32 = @floatFromInt(index);
                const wave_y = extent * row + extent * 0.035 * @sin(u * std.math.tau * 1.5 + phase * 1.7);
                coverage = @max(coverage, edge(@abs(y - wave_y) - extent * 0.012));
            }
            return mix(base, cover.ink, coverage * 0.55);
        },
        .breakwater => {
            const boundary = extent * 0.66 + extent * 0.05 * @sin(u * std.math.tau * 1.25 + 0.6);
            const field = smoothstep(boundary - 1.5, boundary + 1.5, y);
            var color = mix(base, cover.ink, field * 0.9);
            // Signal dot high in the sky field.
            const dist = @sqrt((x - extent * 0.72) * (x - extent * 0.72) + (y - extent * 0.26) * (y - extent * 0.26));
            const halo = 0.3 * (1 - smoothstep(0, extent * 0.2, dist));
            color = mix(color, rgb(250, 250, 245), if (y < boundary) halo else 0);
            const dot = edge(dist - extent * 0.045);
            return mix(color, rgb(252, 250, 244), dot * 0.95);
        },
    }
}

/// Box-filter the supersampled linear buffer down to the committed size and
/// gamma-encode to sRGB bytes.
fn downsample(hires: []const f32, out: []u8) void {
    const samples: f32 = @floatFromInt(super * super);
    for (0..size) |py| {
        for (0..size) |px| {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            for (0..super) |sy| {
                for (0..super) |sx| {
                    const base = ((py * super + sy) * hi + (px * super + sx)) * 3;
                    r += hires[base];
                    g += hires[base + 1];
                    b += hires[base + 2];
                }
            }
            const target = (py * size + px) * 4;
            out[target] = encodeChannel(r / samples);
            out[target + 1] = encodeChannel(g / samples);
            out[target + 2] = encodeChannel(b / samples);
            out[target + 3] = 255;
        }
    }
}

fn encodeChannel(linear: f32) u8 {
    const encoded = @sqrt(std.math.clamp(linear, 0, 1));
    return @intFromFloat(@round(encoded * 255));
}

// ------------------------------------------------------------- PNG writer
// A byte-exact mirror of `canvas.png.writeRgba8` (see the module comment).

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
const max_stored_block_bytes: usize = 65535;
const chunk_overhead: usize = 12; // length + type + crc

fn rowByteLen(width: usize) usize {
    return 1 + width * 4; // filter byte + pixels
}

fn rawStreamLen(width: usize, height: usize) usize {
    return height * rowByteLen(width);
}

fn storedBlockCount(raw_len: usize) usize {
    return (raw_len + max_stored_block_bytes - 1) / max_stored_block_bytes;
}

fn encodedRgba8ByteLen(width: usize, height: usize) usize {
    const raw_len = rawStreamLen(width, height);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    return signature.len + (chunk_overhead + 13) + (chunk_overhead + idat_data_len) + chunk_overhead;
}

fn writeRgba8(writer: *std.Io.Writer, width: usize, height: usize, rgba8: []const u8) anyerror!void {
    try writer.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor with alpha
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(writer, "IHDR", &ihdr);

    const raw_len = rawStreamLen(width, height);
    const row_bytes = rowByteLen(width);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(idat_data_len), .big);
    try writer.writeAll(&length_bytes);
    var crc = std.hash.Crc32.init();
    crc.update("IDAT");
    try writer.writeAll("IDAT");

    const zlib_header = [_]u8{ 0x78, 0x01 };
    crc.update(&zlib_header);
    try writer.writeAll(&zlib_header);

    var adler: std.hash.Adler32 = .{};
    const filter_byte = [_]u8{0};
    var block_start: usize = 0;
    while (block_start < raw_len) {
        const block_len = @min(raw_len - block_start, max_stored_block_bytes);
        const block_end = block_start + block_len;
        const is_final = block_end == raw_len;
        var block_header: [5]u8 = undefined;
        block_header[0] = if (is_final) 1 else 0; // BFINAL, BTYPE=00 (stored)
        std.mem.writeInt(u16, block_header[1..3], @intCast(block_len), .little);
        std.mem.writeInt(u16, block_header[3..5], @intCast(block_len ^ 0xFFFF), .little);
        crc.update(&block_header);
        try writer.writeAll(&block_header);

        var position = block_start;
        while (position < block_end) {
            const row = position / row_bytes;
            const column = position % row_bytes;
            if (column == 0) {
                crc.update(&filter_byte);
                adler.update(&filter_byte);
                try writer.writeAll(&filter_byte);
                position += 1;
                continue;
            }
            const pixel_start = row * width * 4 + (column - 1);
            const available = @min(row_bytes - column, block_end - position);
            const slice = rgba8[pixel_start .. pixel_start + available];
            crc.update(slice);
            adler.update(slice);
            try writer.writeAll(slice);
            position += available;
        }
        block_start = block_end;
    }

    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler.adler, .big);
    crc.update(&adler_bytes);
    try writer.writeAll(&adler_bytes);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);

    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) anyerror!void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(data.len), .big);
    try writer.writeAll(&length_bytes);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);
}
