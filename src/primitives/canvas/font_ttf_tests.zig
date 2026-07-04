//! Tests for the bounded TTF parser (`font_ttf.zig`) against the
//! bundled Geist Regular face: table parsing, cmap lookup, advances,
//! and glyph outlines (simple and composite) rasterized through the
//! vector core with pixel goldens in the reference conventions.

const std = @import("std");
const geometry = @import("geometry");
const font_ttf = @import("font_ttf.zig");
const vector = @import("vector.zig");
const drawing = @import("drawing.zig");

const PointF = geometry.PointF;
const Affine = drawing.Affine;

const grid_size: usize = 24;

const Grid = struct {
    data: [grid_size * grid_size]u8 = [_]u8{0} ** (grid_size * grid_size),

    pub fn pixel(self: *Grid, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= grid_size or py >= grid_size) return;
        self.data[py * grid_size + px] = @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * 255));
    }

    fn at(self: *const Grid, x: usize, y: usize) u8 {
        return self.data[y * grid_size + x];
    }

    fn signature(self: *const Grid) u64 {
        var hash: u64 = 14695981039346656037;
        for (self.data) |byte| {
            hash = (hash ^ byte) *% 1099511628211;
        }
        return hash;
    }

    fn inkCount(self: *const Grid) usize {
        var count: usize = 0;
        for (self.data) |byte| {
            if (byte > 0) count += 1;
        }
        return count;
    }
};

fn fullClip() vector.ClipRect {
    return .{ .x0 = 0, .y0 = 0, .x1 = @intCast(grid_size), .y1 = @intCast(grid_size) };
}

/// Rasterize one codepoint at `size` px with its baseline at `baseline`,
/// pen at x = 2.
fn rasterizeCodepoint(codepoint: u32, size: f32, baseline: f32, grid: *Grid) !void {
    const face = &font_ttf.geist_regular;
    const glyph = face.glyphIndex(codepoint);
    try std.testing.expect(glyph != 0);
    const scale = size / face.units_per_em;
    const transform = Affine{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 2, .ty = baseline };
    var builder = vector.PathBuilder(256){};
    try face.glyphOutline(glyph, transform, &builder);
    try vector.fillPath(builder.slice(), Affine.identity(), .nonzero, vector.default_tolerance, fullClip(), grid);
}

test "bundled Geist face parses with the expected metrics" {
    const face = &font_ttf.geist_regular;
    try std.testing.expectEqual(@as(f32, 1000), face.units_per_em);
    try std.testing.expectEqual(@as(u16, 825), face.num_glyphs);
    try std.testing.expectEqual(@as(i16, 920), face.ascender);
    try std.testing.expectEqual(@as(i16, -220), face.descender);
    try std.testing.expect(!face.long_loca);
}

test "cmap resolves ascii and rejects unmapped codepoints" {
    const face = &font_ttf.geist_regular;
    try std.testing.expect(face.glyphIndex('A') != 0);
    try std.testing.expect(face.glyphIndex('z') != 0);
    try std.testing.expect(face.glyphIndex('0') != 0);
    try std.testing.expect(face.glyphIndex(' ') != 0);
    try std.testing.expect(face.glyphIndex(0xE9) != 0); // e-acute (composite)
    // Distinct letters map to distinct glyphs.
    try std.testing.expect(face.glyphIndex('A') != face.glyphIndex('B'));
    // Outside the BMP or unmapped: .notdef.
    try std.testing.expectEqual(@as(u16, 0), face.glyphIndex(0x1F600));
    try std.testing.expectEqual(@as(u16, 0), face.glyphIndex(0xFFFE));
}

test "advances are positive and ordered sensibly" {
    const face = &font_ttf.geist_regular;
    const narrow = face.advance(face.glyphIndex('i'));
    const wide = face.advance(face.glyphIndex('m'));
    const space = face.advance(face.glyphIndex(' '));
    try std.testing.expect(narrow > 0);
    try std.testing.expect(space > 0);
    try std.testing.expect(wide > narrow);
    // The deterministic estimator factors were derived from this face:
    // 'm' is 0.879em there and the real advance agrees within 2%.
    const em_fraction = wide / face.units_per_em;
    try std.testing.expect(@abs(em_fraction - 0.879) < 0.02);
}

test "space glyph maps but carries no outline" {
    const face = &font_ttf.geist_regular;
    var builder = vector.PathBuilder(256){};
    try face.glyphOutline(face.glyphIndex(' '), Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, 0), builder.slice().len);
}

test "capital H rasterizes as two stems joined by a crossbar" {
    var grid = Grid{};
    try rasterizeCodepoint('H', 16, 18, &grid);
    // Stems land on x=3..4 and x=10..11 with exact anti-aliased edge
    // coverage; the crossbar row at y=12 is solid between them and the
    // inter-stem gap is empty away from the crossbar.
    try std.testing.expectEqual(@as(u8, 216), grid.at(4, 8));
    try std.testing.expectEqual(@as(u8, 239), grid.at(11, 8));
    try std.testing.expectEqual(@as(u8, 255), grid.at(7, 12));
    try std.testing.expectEqual(@as(u8, 0), grid.at(7, 8));
    try std.testing.expectEqual(@as(u8, 0), grid.at(7, 17));
    // Nothing below the baseline for 'H'.
    var x: usize = 0;
    while (x < grid_size) : (x += 1) {
        try std.testing.expectEqual(@as(u8, 0), grid.at(x, 19));
    }
}

test "letter O keeps its counter under the nonzero rule" {
    var grid = Grid{};
    try rasterizeCodepoint('O', 16, 18, &grid);
    // The ring inks, the counter (inner hole) stays empty: TrueType
    // winds inner contours opposite the outer ones.
    try std.testing.expect(grid.at(3, 12) > 0);
    try std.testing.expect(grid.at(13, 12) > 0);
    try std.testing.expectEqual(@as(u8, 0), grid.at(8, 12));
}

test "descender of p reaches below the baseline" {
    var grid = Grid{};
    try rasterizeCodepoint('p', 16, 12, &grid);
    // Stem continues below the baseline at y=12.
    try std.testing.expect(grid.at(3, 14) > 0);
}

test "composite e-acute renders base and accent" {
    var grid = Grid{};
    try rasterizeCodepoint(0xE9, 16, 18, &grid);
    var base_ink: usize = 0;
    var accent_ink: usize = 0;
    var y: usize = 0;
    while (y < grid_size) : (y += 1) {
        var x: usize = 0;
        while (x < grid_size) : (x += 1) {
            if (grid.at(x, y) == 0) continue;
            // x-height of Geist is 0.53em -> the 'e' bowl starts around
            // y = 9.5 at 16px; anything inked clearly above it is the
            // accent component.
            if (y < 8) accent_ink += 1 else base_ink += 1;
        }
    }
    try std.testing.expect(accent_ink > 0);
    try std.testing.expect(base_ink > accent_ink);
}

test "glyph rasterization is deterministic and pinned" {
    var first = Grid{};
    try rasterizeCodepoint('g', 16, 14, &first);
    var second = Grid{};
    try rasterizeCodepoint('g', 16, 14, &second);
    try std.testing.expectEqualSlices(u8, &first.data, &second.data);
    try std.testing.expect(first.inkCount() > 10);
    try std.testing.expectEqual(@as(u64, 12321457692853131437), first.signature());
}

test "corrupt font bytes fail to parse without crashing" {
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(&.{}));
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(font_ttf.geist_regular_bytes[0..64]));
    // A face missing required tables (chop after the directory header).
    var truncated: [1024]u8 = undefined;
    @memcpy(truncated[0..1024], font_ttf.geist_regular_bytes[0..1024]);
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(&truncated));
}

test "out of range glyph ids error instead of reading wild" {
    const face = &font_ttf.geist_regular;
    var builder = vector.PathBuilder(256){};
    try std.testing.expectError(error.FontParseFailed, face.glyphOutline(60000, Affine.identity(), &builder));
}

test "font_coverage answers identically to the face's cmap" {
    // The std-only coverage module (markup tofu guard) re-reads the
    // same embedded bytes with its own minimal cmap walk; it must never
    // drift from the renderer's `Face.glyphIndex`.
    const font_coverage = @import("font_coverage.zig");
    const face = &font_ttf.geist_regular;
    var codepoint: u21 = 0x20;
    while (codepoint < 0x3000) : (codepoint += 1) {
        try std.testing.expectEqual(face.glyphIndex(codepoint) != 0, font_coverage.covers(codepoint));
    }
    try std.testing.expectEqual(face.glyphIndex(0x1F600) != 0, font_coverage.covers(0x1F600));
}
