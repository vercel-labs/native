//! Tests for the bounded TTF parser (`font_ttf.zig`) against the
//! bundled Geist Regular face: table parsing, cmap lookup, advances,
//! and glyph outlines (simple and composite) rasterized through the
//! vector core with pixel goldens in the reference conventions.
//!
//! The synthetic-font fixtures at the bottom build TrueType bytes
//! in-test (dense CJK-shaped glyphs, composite chains, over- and
//! under-declaring `maxp` tables) to prove both sides of the
//! registration-time glyph-budget gate without shipping font binaries.

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

test "bundled Geist Mono face parses and holds the fixed 0.6 em pitch" {
    const face = &font_ttf.geist_mono;
    try std.testing.expectEqual(@as(f32, 1000), face.units_per_em);
    try std.testing.expect(face.num_glyphs > 0);
    // Full printable-ASCII coverage at exactly the estimator's mono
    // pitch: layout charges 0.6 em per mono cluster, and these are the
    // outlines the reference renderer inks into those cells.
    var codepoint: u21 = 0x20;
    while (codepoint < 0x7F) : (codepoint += 1) {
        const glyph = face.glyphIndex(codepoint);
        try std.testing.expect(glyph != 0);
        try std.testing.expectEqual(@as(f32, 600), face.advance(glyph));
    }
}

test "mono outlines rasterize within the vector budgets" {
    const face = &font_ttf.geist_mono;
    // The densest ASCII glyphs (@, %, &, digits) must stay inside the
    // fixed point/contour budgets so mono captions never degrade to
    // block fallbacks mid-word.
    const probe = "@%&MW08ilj·";
    var iterator = std.unicode.Utf8Iterator{ .bytes = probe, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const glyph = face.glyphIndex(codepoint);
        try std.testing.expect(glyph != 0);
        var builder = vector.PathBuilder(256){};
        try face.glyphOutline(glyph, Affine.identity(), &builder);
        try std.testing.expect(builder.slice().len > 0);
    }
}

test "corrupt font bytes fail to parse without crashing" {
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(&.{}));
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(font_ttf.geist_regular_bytes[0..64]));
    // A face missing required tables (chop after the directory header).
    var truncated: [1024]u8 = undefined;
    @memcpy(truncated[0..1024], font_ttf.geist_regular_bytes[0..1024]);
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(&truncated));
}

test "truncated font prefixes never crash the parser" {
    // Every prefix of a real face is either rejected or parses into a
    // Face whose reads stay bounds-checked; none may crash. Walk a
    // coarse stride plus the interesting first bytes.
    var len: usize = 0;
    while (len < font_ttf.geist_mono_bytes.len) : (len += if (len < 64) 1 else 977) {
        _ = font_ttf.Face.parse(font_ttf.geist_mono_bytes[0..len]) catch continue;
    }
}

test "parseFailureReason teaches the first thing wrong and matches parse" {
    // Clean bundled faces: no reason, and parse agrees.
    try std.testing.expectEqual(@as(?[]const u8, null), font_ttf.parseFailureReason(font_ttf.geist_regular_bytes));
    try std.testing.expectEqual(@as(?[]const u8, null), font_ttf.parseFailureReason(font_ttf.geist_mono_bytes));

    // Truncations and hostile headers: a reason exists whenever parse
    // fails, and the sentence names the failure class.
    const tiny = font_ttf.parseFailureReason(font_ttf.geist_regular_bytes[0..8]).?;
    try std.testing.expect(std.mem.indexOf(u8, tiny, "truncated") != null);

    var otto: [512]u8 = undefined;
    @memcpy(otto[0..512], font_ttf.geist_regular_bytes[0..512]);
    @memcpy(otto[0..4], "OTTO");
    const cff = font_ttf.parseFailureReason(&otto).?;
    try std.testing.expect(std.mem.indexOf(u8, cff, "CFF") != null);

    var woff: [512]u8 = undefined;
    @memcpy(woff[0..512], font_ttf.geist_regular_bytes[0..512]);
    @memcpy(woff[0..4], "wOFF");
    const compressed = font_ttf.parseFailureReason(&woff).?;
    try std.testing.expect(std.mem.indexOf(u8, compressed, "WOFF") != null);

    // A directory whose table ranges run past the file.
    var chopped: [1024]u8 = undefined;
    @memcpy(chopped[0..1024], font_ttf.geist_regular_bytes[0..1024]);
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(&chopped));
    try std.testing.expect(font_ttf.parseFailureReason(&chopped) != null);

    // Contract: parse and the diagnostic never disagree, across a sweep
    // of truncation lengths.
    var len: usize = 0;
    while (len < 4096) : (len += 199) {
        const bytes = font_ttf.geist_regular_bytes[0..len];
        const parses = if (font_ttf.Face.parse(bytes)) |_| true else |_| false;
        try std.testing.expectEqual(parses, font_ttf.parseFailureReason(bytes) == null);
    }
}

test "out of range glyph ids error instead of reading wild" {
    const face = &font_ttf.geist_regular;
    var builder = vector.PathBuilder(256){};
    try std.testing.expectError(error.FontParseFailed, face.glyphOutline(60000, Affine.identity(), &builder));
}

// --------------------------------------------------------------------
// Synthetic fonts: in-test TrueType bytes with caller-controlled `maxp`
// declarations and glyph payloads. Just enough of the format for the
// parser's seven required tables; hostile fidelity (checksums, search
// ranges) is deliberately absent because the parser never reads it.

/// Fixed-buffer big-endian byte builder for synthetic tables.
const ByteBuilder = struct {
    bytes: [32768]u8 = undefined,
    len: usize = 0,

    fn appendU8(self: *ByteBuilder, value: u8) void {
        self.bytes[self.len] = value;
        self.len += 1;
    }

    fn appendU16(self: *ByteBuilder, value: u16) void {
        self.appendU8(@intCast(value >> 8));
        self.appendU8(@intCast(value & 0xFF));
    }

    fn appendI16(self: *ByteBuilder, value: i16) void {
        self.appendU16(@bitCast(value));
    }

    fn appendU32(self: *ByteBuilder, value: u32) void {
        self.appendU16(@intCast(value >> 16));
        self.appendU16(@intCast(value & 0xFFFF));
    }

    fn appendZeros(self: *ByteBuilder, count: usize) void {
        @memset(self.bytes[self.len .. self.len + count], 0);
        self.len += count;
    }

    fn slice(self: *const ByteBuilder) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Append a simple glyph of `contour_count` closed square rings, each
/// with `points_per_contour` on-curve points (must be divisible by 4)
/// walking the ring's perimeter, rings spread along x. All flags are
/// plain on-curve with 16-bit deltas, so the outline emitted for ring
/// points p0..pn is exactly moveTo(p0), lineTo(p1..pn), close.
fn appendSimpleGlyph(glyf: *ByteBuilder, contour_count: u16, points_per_contour: u16) void {
    std.debug.assert(points_per_contour % 4 == 0);
    const side = points_per_contour / 4;
    glyf.appendI16(@intCast(contour_count));
    glyf.appendZeros(8); // bbox: unread by the parser
    var contour: u16 = 0;
    while (contour < contour_count) : (contour += 1) {
        glyf.appendU16((contour + 1) * points_per_contour - 1);
    }
    glyf.appendU16(0); // no instructions
    const total = @as(usize, contour_count) * points_per_contour;
    var index: usize = 0;
    while (index < total) : (index += 1) glyf.appendU8(0x01); // on-curve, long deltas
    // Coordinates: point k of contour c walks a `side`-unit square at
    // x offset c * (side + 4).
    const point = struct {
        fn at(c: u16, k: u16, s: u16) [2]i16 {
            const quarter = k / s;
            const step: i16 = @intCast(k % s);
            const size: i16 = @intCast(s);
            const base: i16 = @intCast(@as(u32, c) * (@as(u32, s) + 4));
            return switch (quarter) {
                0 => .{ base + step, 0 },
                1 => .{ base + size, step },
                2 => .{ base + size - step, size },
                else => .{ base, size - step },
            };
        }
    }.at;
    // X deltas then Y deltas, accumulated across the whole glyph.
    var previous: i16 = 0;
    contour = 0;
    while (contour < contour_count) : (contour += 1) {
        var k: u16 = 0;
        while (k < points_per_contour) : (k += 1) {
            const p = point(contour, k, side);
            glyf.appendI16(p[0] - previous);
            previous = p[0];
        }
    }
    previous = 0;
    contour = 0;
    while (contour < contour_count) : (contour += 1) {
        var k: u16 = 0;
        while (k < points_per_contour) : (k += 1) {
            const p = point(contour, k, side);
            glyf.appendI16(p[1] - previous);
            previous = p[1];
        }
    }
}

const Component = struct { glyph: u16, dx: i16, dy: i16 };

/// Append a composite glyph placing each component by XY offset.
fn appendCompositeGlyph(glyf: *ByteBuilder, components: []const Component) void {
    glyf.appendI16(-1);
    glyf.appendZeros(8); // bbox: unread by the parser
    for (components, 0..) |component, index| {
        const more: u16 = if (index + 1 < components.len) 0x0020 else 0;
        glyf.appendU16(0x0001 | 0x0002 | more); // words + xy offsets
        glyf.appendU16(component.glyph);
        glyf.appendI16(component.dx);
        glyf.appendI16(component.dy);
    }
}

/// Append a composite glyph placed by POINT MATCHING (the placement
/// form the renderer refuses per glyph and `maxp` cannot describe).
fn appendPointMatchedComposite(glyf: *ByteBuilder, child: u16) void {
    glyf.appendI16(-1);
    glyf.appendZeros(8);
    glyf.appendU16(0x0001); // words, but NOT xy offsets: point numbers
    glyf.appendU16(child);
    glyf.appendI16(0);
    glyf.appendI16(0);
}

const DeclaredMaxima = struct {
    points: u16,
    contours: u16,
    composite_points: u16 = 0,
    composite_contours: u16 = 0,
    component_elements: u16 = 0,
    component_depth: u16 = 0,
    maxp_version: u32 = 0x00010000,
};

/// Assemble a whole font: the seven required tables around `glyf_bytes`
/// whose per-glyph offsets are `loca_offsets` (one per glyph plus the
/// final end; glyph 0 stays empty when its two offsets are equal). The
/// cmap maps 'A' + n to glyph 1 + n.
fn buildSyntheticFont(declared: DeclaredMaxima, glyf_bytes: []const u8, loca_offsets: []const u32) ByteBuilder {
    const num_glyphs: u16 = @intCast(loca_offsets.len - 1);
    var font = ByteBuilder{};
    font.appendU32(0x00010000);
    font.appendU16(7);
    font.appendZeros(6); // searchRange/entrySelector/rangeShift: unread
    const off_head: u32 = 12 + 7 * 16;
    const off_maxp = off_head + 54;
    const off_hhea = off_maxp + 32;
    const off_hmtx = off_hhea + 36;
    const off_cmap = off_hmtx + 4 * @as(u32, num_glyphs);
    const off_loca = off_cmap + 44;
    const off_glyf = off_loca + 4 * (@as(u32, num_glyphs) + 1);
    const record = struct {
        fn append(builder: *ByteBuilder, tag: *const [4]u8, offset: u32, length: u32) void {
            for (tag) |byte| builder.appendU8(byte);
            builder.appendU32(0); // checksum: unread
            builder.appendU32(offset);
            builder.appendU32(length);
        }
    }.append;
    record(&font, "head", off_head, 54);
    record(&font, "maxp", off_maxp, 32);
    record(&font, "hhea", off_hhea, 36);
    record(&font, "hmtx", off_hmtx, 4 * @as(u32, num_glyphs));
    record(&font, "cmap", off_cmap, 44);
    record(&font, "loca", off_loca, 4 * (@as(u32, num_glyphs) + 1));
    record(&font, "glyf", off_glyf, @intCast(glyf_bytes.len));

    // head: unitsPerEm at +18, indexToLocFormat at +50 (long loca).
    std.debug.assert(font.len == off_head);
    font.appendZeros(18);
    font.appendU16(1000);
    font.appendZeros(30);
    font.appendI16(1);
    font.appendI16(0);

    // maxp v1.0 with the declared maxima under test.
    std.debug.assert(font.len == off_maxp);
    font.appendU32(declared.maxp_version);
    font.appendU16(num_glyphs);
    font.appendU16(declared.points);
    font.appendU16(declared.contours);
    font.appendU16(declared.composite_points);
    font.appendU16(declared.composite_contours);
    font.appendZeros(14); // zones..instruction sizes
    font.appendU16(declared.component_elements);
    font.appendU16(declared.component_depth);

    // hhea: ascender +4, descender +6, numberOfHMetrics +34.
    std.debug.assert(font.len == off_hhea);
    font.appendZeros(4);
    font.appendI16(800);
    font.appendI16(-200);
    font.appendZeros(26);
    font.appendU16(num_glyphs);

    // hmtx: one long metric per glyph.
    std.debug.assert(font.len == off_hmtx);
    var glyph: u16 = 0;
    while (glyph < num_glyphs) : (glyph += 1) {
        font.appendU16(500);
        font.appendI16(0);
    }

    // cmap: one format-4 subtable, 'A' + n -> glyph 1 + n.
    std.debug.assert(font.len == off_cmap);
    font.appendU16(0);
    font.appendU16(1);
    font.appendU16(3);
    font.appendU16(1);
    font.appendU32(12);
    font.appendU16(4); // format
    font.appendU16(32); // subtable length
    font.appendU16(0); // language
    font.appendU16(4); // segCountX2
    font.appendZeros(6); // searchRange/entrySelector/rangeShift: unread
    font.appendU16(0x41 + num_glyphs - 2); // endCode[0]
    font.appendU16(0xFFFF); // endCode[1]
    font.appendU16(0); // reservedPad
    font.appendU16(0x41); // startCode[0]
    font.appendU16(0xFFFF); // startCode[1]
    font.appendU16(@as(u16, 1) -% @as(u16, 0x41)); // idDelta[0]: 'A' -> glyph 1
    font.appendU16(1); // idDelta[1]: 0xFFFF -> glyph 0
    font.appendU16(0); // idRangeOffset[0]
    font.appendU16(0); // idRangeOffset[1]

    // loca (long form).
    std.debug.assert(font.len == off_loca);
    for (loca_offsets) |offset| font.appendU32(offset);

    std.debug.assert(font.len == off_glyf);
    @memcpy(font.bytes[font.len .. font.len + glyf_bytes.len], glyf_bytes);
    font.len += glyf_bytes.len;
    return font;
}

test "synthetic dense glyphs beyond the old Latin-sized budgets parse and outline correctly" {
    // CJK-shaped density, truthfully declared: 84 rings x 12 points
    // (1008 points — the measured Noto Sans JP contour high-water is 84,
    // and dense kanji far exceed the old 128-point budget) plus a
    // single-contour glyph at exactly the point budget.
    var glyf = ByteBuilder{};
    var loca: [4]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0; // glyph 0: empty
    appendSimpleGlyph(&glyf, 84, 12);
    loca[2] = @intCast(glyf.len);
    appendSimpleGlyph(&glyf, 1, @intCast(font_ttf.max_glyph_points));
    loca[3] = @intCast(glyf.len);
    const font = buildSyntheticFont(
        .{ .points = font_ttf.max_glyph_points, .contours = 84 },
        glyf.slice(),
        &loca,
    );

    const face = try font_ttf.Face.parse(font.slice());
    try std.testing.expectEqual(@as(u16, 3), face.num_glyphs);
    try std.testing.expectEqual(@as(u16, 1), face.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 2), face.glyphIndex('B'));

    // The dense glyph outlines completely: every on-curve ring is
    // moveTo + 12 lineTo (the walk returns to the start point) + close,
    // so 84 * 14 elements, starting at the first ring's origin.
    var builder = vector.PathBuilder(2048){};
    try face.glyphOutline(1, Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, 84 * 14), builder.slice().len);
    const first = builder.slice()[0];
    try std.testing.expectEqual(drawing.PathVerb.move_to, first.verb);
    try std.testing.expectEqual(@as(f32, 0), first.points[0].x);
    try std.testing.expectEqual(@as(f32, 0), first.points[0].y);

    // A glyph at exactly the point budget parses and outlines too.
    builder.reset();
    try face.glyphOutline(2, Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, font_ttf.max_glyph_points + 2), builder.slice().len);

    // And the dense outline rasterizes through the vector core within
    // the edge budget.
    var grid = Grid{};
    const scale: f32 = 16.0 / face.units_per_em;
    const transform = Affine{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 2, .ty = 20 };
    builder.reset();
    try face.glyphOutline(1, transform, &builder);
    try vector.fillPath(builder.slice(), Affine.identity(), .nonzero, vector.default_tolerance, fullClip(), &grid);
}

test "synthetic composites at the depth and component budgets parse and outline" {
    // Glyph 1: a simple ring. Glyphs 2..5: a composite chain nested to
    // exactly `max_composite_depth`. Glyph 6: one composite carrying
    // exactly `max_composite_components` offset copies of the ring.
    var glyf = ByteBuilder{};
    var loca: [8]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    appendSimpleGlyph(&glyf, 1, 4);
    loca[2] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 1, .dx = 10, .dy = 0 }});
    loca[3] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 2, .dx = 10, .dy = 0 }});
    loca[4] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 3, .dx = 10, .dy = 0 }});
    loca[5] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 4, .dx = 10, .dy = 0 }});
    loca[6] = @intCast(glyf.len);
    var components: [font_ttf.max_composite_components]Component = undefined;
    for (&components, 0..) |*component, index| {
        component.* = .{ .glyph = 1, .dx = @intCast(index * 8), .dy = 0 };
    }
    appendCompositeGlyph(&glyf, &components);
    loca[7] = @intCast(glyf.len);
    const font = buildSyntheticFont(.{
        .points = 4,
        .contours = 1,
        .composite_points = 8 * 4, // the component fan, flattened
        .composite_contours = 8,
        .component_elements = font_ttf.max_composite_components,
        .component_depth = font_ttf.max_composite_depth,
    }, glyf.slice(), &loca);

    const face = try font_ttf.Face.parse(font.slice());

    // The chain bottoms out at the simple ring (moveTo + 4 lineTo +
    // close), its XY offsets summed.
    var builder = vector.PathBuilder(64){};
    try face.glyphOutline(5, Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, 6), builder.slice().len);
    try std.testing.expectEqual(@as(f32, 40), builder.slice()[0].points[0].x);

    // The full component fan emits one ring per component.
    builder.reset();
    try face.glyphOutline(6, Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, 6 * font_ttf.max_composite_components), builder.slice().len);
}

test "a composite flattening to more points than any simple glyph renders within the derived path capacity" {
    // The failure the composite gate exists to prevent: a face whose
    // simple glyphs are modest but whose composites flatten far denser.
    // Glyph 1: a 128-point ring (the face's densest simple glyph).
    // Glyph 2: a composite fanning 8 offset copies of it — flattened
    // 1024 points / 8 contours, exactly `max_composite_points`, eight
    // times denser than any simple glyph in the face.
    var glyf = ByteBuilder{};
    var loca: [4]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    appendSimpleGlyph(&glyf, 1, 128);
    loca[2] = @intCast(glyf.len);
    var components: [font_ttf.max_composite_components]Component = undefined;
    for (&components, 0..) |*component, index| {
        component.* = .{ .glyph = 1, .dx = @intCast(index * 40), .dy = 0 };
    }
    appendCompositeGlyph(&glyf, &components);
    loca[3] = @intCast(glyf.len);
    const font = buildSyntheticFont(.{
        .points = 128,
        .contours = 1,
        .composite_points = @intCast(font_ttf.max_composite_points),
        .composite_contours = 8,
        .component_elements = font_ttf.max_composite_components,
        .component_depth = 1,
    }, glyf.slice(), &loca);

    // Truthful at-budget composite maxima pass the gate...
    const face = try font_ttf.Face.parse(font.slice());

    // ...and the flattened outline fits a builder sized exactly like
    // the reference renderer's glyph path capacity: points + 3*contours
    // taken over max(simple budgets, composite budgets). Each ring
    // emits moveTo + 128 lineTo + close, so the fan is 8 * 130 = 1040
    // elements — past what the face's simple maxima alone could emit
    // (130 + 3), inside the composite-aware bound.
    const capacity = @max(
        font_ttf.max_glyph_points + 3 * font_ttf.max_glyph_contours,
        font_ttf.max_composite_points + 3 * font_ttf.max_composite_contours,
    );
    var builder = vector.PathBuilder(capacity){};
    try face.glyphOutline(2, Affine.identity(), &builder);
    try std.testing.expectEqual(@as(usize, 8 * 130), builder.slice().len);
    try std.testing.expect(builder.slice().len > 128 + 3 * 1);

    // The same fan rasterizes through the vector core.
    var grid = Grid{};
    const scale: f32 = 16.0 / face.units_per_em;
    var raster_builder = vector.PathBuilder(capacity){};
    try face.glyphOutline(2, .{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 2, .ty = 20 }, &raster_builder);
    try vector.fillPath(raster_builder.slice(), Affine.identity(), .nonzero, vector.default_tolerance, fullClip(), &grid);
    try std.testing.expect(grid.inkCount() > 0);
}

test "a face declaring maxima beyond the budgets is refused at parse with a teaching" {
    var glyf = ByteBuilder{};
    var loca: [3]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    appendSimpleGlyph(&glyf, 1, 4);
    loca[2] = @intCast(glyf.len);

    const over_budget = [_]DeclaredMaxima{
        .{ .points = font_ttf.max_glyph_points + 1, .contours = 1 },
        .{ .points = 4, .contours = font_ttf.max_glyph_contours + 1 },
        .{ .points = 4, .contours = 1, .composite_points = font_ttf.max_composite_points + 1 },
        .{ .points = 4, .contours = 1, .composite_contours = font_ttf.max_composite_contours + 1 },
        .{ .points = 4, .contours = 1, .component_elements = font_ttf.max_composite_components + 1 },
        .{ .points = 4, .contours = 1, .component_depth = font_ttf.max_composite_depth + 1 },
    };
    for (over_budget) |declared| {
        const font = buildSyntheticFont(declared, glyf.slice(), &loca);
        try std.testing.expectError(error.FontGlyphTooComplex, font_ttf.Face.parse(font.slice()));
        // The teaching machinery names the refusal — simple AND
        // flattened-composite budgets by name — and the maxima stay
        // readable for callers that format the face's numbers.
        const reason = font_ttf.parseFailureReason(font.slice()).?;
        try std.testing.expect(std.mem.indexOf(u8, reason, "budgets") != null);
        try std.testing.expect(std.mem.indexOf(u8, reason, "flattened composite") != null);
        const maxima = font_ttf.declaredGlyphMaxima(font.slice()).?;
        try std.testing.expect(!maxima.withinBudgets());
        try std.testing.expectEqual(declared.composite_points, maxima.composite_points);
        try std.testing.expectEqual(declared.composite_contours, maxima.composite_contours);
    }

    // The same font declared truthfully parses: the gate reads maxima,
    // not vibes.
    const honest = buildSyntheticFont(.{ .points = 4, .contours = 1 }, glyf.slice(), &loca);
    _ = try font_ttf.Face.parse(honest.slice());
    try std.testing.expectEqual(@as(?[]const u8, null), font_ttf.parseFailureReason(honest.slice()));

    // A maxp that is not the version-1.0 glyf form is a parse failure
    // with its own teaching.
    const wrong_version = buildSyntheticFont(.{ .points = 4, .contours = 1, .maxp_version = 0x00005000 }, glyf.slice(), &loca);
    try std.testing.expectError(error.FontParseFailed, font_ttf.Face.parse(wrong_version.slice()));
    const version_reason = font_ttf.parseFailureReason(wrong_version.slice()).?;
    try std.testing.expect(std.mem.indexOf(u8, version_reason, "maxp") != null);
}

test "a face that under-declares its maxp hits the per-glyph backstops, never wild reads" {
    // Glyph 1 really carries more contours than the budget; glyph 2 is
    // a composite chain one level past the depth budget; glyph 3 places
    // its component by point matching. maxp declares none of it.
    var glyf = ByteBuilder{};
    var loca: [10]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    appendSimpleGlyph(&glyf, @intCast(font_ttf.max_glyph_contours + 1), 4);
    loca[2] = @intCast(glyf.len);
    appendSimpleGlyph(&glyf, 1, 4);
    loca[3] = @intCast(glyf.len);
    // Five nested composites: the deepest simple child sits one level
    // past `max_composite_depth`.
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 2, .dx = 0, .dy = 0 }});
    loca[4] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 3, .dx = 0, .dy = 0 }});
    loca[5] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 4, .dx = 0, .dy = 0 }});
    loca[6] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 5, .dx = 0, .dy = 0 }});
    loca[7] = @intCast(glyf.len);
    appendCompositeGlyph(&glyf, &.{.{ .glyph = 6, .dx = 0, .dy = 0 }});
    loca[8] = @intCast(glyf.len);
    appendPointMatchedComposite(&glyf, 2);
    loca[9] = @intCast(glyf.len);
    const font = buildSyntheticFont(.{ .points = 4, .contours = 1, .component_depth = 1, .component_elements = 1 }, glyf.slice(), &loca);

    // The lie passes the gate (declared maxima are tiny)...
    const face = try font_ttf.Face.parse(font.slice());

    // ...and the per-glyph backstops catch the reality, recoverably.
    var builder = vector.PathBuilder(2048){};
    try std.testing.expectError(error.FontGlyphTooComplex, face.glyphOutline(1, Affine.identity(), &builder));
    builder.reset();
    try std.testing.expectError(error.FontGlyphTooComplex, face.glyphOutline(7, Affine.identity(), &builder));
    builder.reset();
    try std.testing.expectError(error.FontGlyphTooComplex, face.glyphOutline(8, Affine.identity(), &builder));
}

test "declaredGlyphMaxima reads the bundled faces' true maxima" {
    // Pins the measured ground truth the budget constants document.
    const regular = font_ttf.declaredGlyphMaxima(font_ttf.geist_regular_bytes).?;
    try std.testing.expectEqual(@as(u16, 96), regular.points);
    try std.testing.expectEqual(@as(u16, 16), regular.contours);
    try std.testing.expectEqual(@as(u16, 89), regular.composite_points);
    try std.testing.expectEqual(@as(u16, 5), regular.composite_contours);
    try std.testing.expectEqual(@as(u16, 4), regular.component_elements);
    try std.testing.expectEqual(@as(u16, 3), regular.component_depth);
    try std.testing.expect(regular.withinBudgets());

    const mono = font_ttf.declaredGlyphMaxima(font_ttf.geist_mono_bytes).?;
    try std.testing.expectEqual(@as(u16, 116), mono.points);
    try std.testing.expectEqual(@as(u16, 16), mono.contours);
    try std.testing.expectEqual(@as(u16, 104), mono.composite_points);
    try std.testing.expectEqual(@as(u16, 10), mono.composite_contours);
    try std.testing.expectEqual(@as(u16, 3), mono.component_elements);
    try std.testing.expectEqual(@as(u16, 1), mono.component_depth);
    try std.testing.expect(mono.withinBudgets());

    // Not-a-font blobs answer null instead of erroring.
    try std.testing.expectEqual(@as(?font_ttf.GlyphMaxima, null), font_ttf.declaredGlyphMaxima("not a font"));
}

// --------------------------------------------------------------------
// Glyph raster budgets: the registration gate admits faces up to the
// outline budgets, and the vector core's glyph-fill budgets are DERIVED
// from them (vector.zig's glyph budget block), so a gate-admitted glyph
// must rasterize — never `VectorPathTooComplex`, never a block fallback.
// The zigzag fixtures below are the truthful adversarial maxima.

/// Append a single-contour zigzag glyph: `point_count` points marching x
/// one font unit per point, y alternating 0 and `height`. With
/// `on_curve` every point is an on-curve corner — ~one scanline crossing
/// per point, the crossing-budget worst case. Without it every point is
/// an off-curve control (TrueType implies on-curve midpoints), so the
/// contour is one full-height quad per point — the flattening
/// worst case: at large sizes every quad clamps at
/// `vector.max_glyph_curve_segments`, which is the edge-budget maximum.
fn appendZigzagGlyph(glyf: *ByteBuilder, point_count: u16, height: i16, on_curve: bool) void {
    glyf.appendI16(1); // one contour
    glyf.appendZeros(8); // bbox: unread by the parser
    glyf.appendU16(point_count - 1);
    glyf.appendU16(0); // no instructions
    var index: usize = 0;
    while (index < point_count) : (index += 1) glyf.appendU8(if (on_curve) 0x01 else 0x00);
    // X deltas: start at 0, then +1 unit per point.
    glyf.appendI16(0);
    index = 1;
    while (index < point_count) : (index += 1) glyf.appendI16(1);
    // Y deltas: alternate 0 -> height -> 0 -> ...
    glyf.appendI16(0);
    index = 1;
    while (index < point_count) : (index += 1) glyf.appendI16(if (index % 2 == 1) height else -height);
}

/// The truthful budget-maximal zigzag face: glyph 1 ('A') the on-curve
/// line zigzag, glyph 2 ('B') the all-off-curve quad zigzag, both at
/// exactly `max_glyph_points` in one contour, `maxp` declaring the
/// truth — the registration gate admits this face.
fn buildZigzagFont() ByteBuilder {
    var glyf = ByteBuilder{};
    var loca: [4]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0; // glyph 0: empty
    appendZigzagGlyph(&glyf, @intCast(font_ttf.max_glyph_points), 1000, true);
    loca[2] = @intCast(glyf.len);
    appendZigzagGlyph(&glyf, @intCast(font_ttf.max_glyph_points), 1000, false);
    loca[3] = @intCast(glyf.len);
    return buildSyntheticFont(
        .{ .points = @intCast(font_ttf.max_glyph_points), .contours = 1 },
        glyf.slice(),
        &loca,
    );
}

test "glyph raster budgets stay lockstep with the outline budgets they derive from" {
    // The derivation chain in vector.zig, pinned against the source
    // constants (vector.zig cannot import font_ttf.zig — the import
    // runs the other way): quads <= points + contours over both glyph
    // forms the gate admits, edges <= quads * clamp + close edges,
    // crossings <= edges (an edge crosses a scanline at most once).
    const quads = @max(
        font_ttf.max_glyph_points + font_ttf.max_glyph_contours,
        font_ttf.max_composite_points + font_ttf.max_composite_contours,
    );
    const closes = @max(font_ttf.max_glyph_contours, font_ttf.max_composite_contours);
    try std.testing.expectEqual(quads * vector.max_glyph_curve_segments + closes, vector.max_glyph_fill_edges);
    try std.testing.expectEqual(vector.max_glyph_fill_edges, vector.max_glyph_scanline_crossings);
}

test "truthful budget-maximal zigzag glyphs pass the gate and rasterize at the max raster size" {
    const font = buildZigzagFont();
    // The registration gate (`registerCanvasFont` routes every face
    // through this parse) ADMITS the truthful declaration...
    const face = try font_ttf.Face.parse(font.slice());

    // ...so both zigzags must rasterize at the largest sweep the core
    // serves (`max_raster_width` = an 8192-px em; the clamp makes the
    // budgets size-independent above it). The band clip sits at ~30% of
    // the em, where the line zigzag crosses one edge per point (~1024
    // crossings — the old shared 256-crossing cap refused this) and the
    // quad zigzag's ~1025 full-height quads each flatten to the 16-
    // segment clamp (~16,400 edges — the old shared 4096-edge cap
    // refused that).
    const InkCounter = struct {
        covered: usize = 0,
        pub fn pixel(self: *@This(), x: i32, y: i32, coverage: f32) void {
            _ = x;
            _ = y;
            if (coverage > 0) self.covered += 1;
        }
    };
    const size: f32 = @floatFromInt(vector.max_raster_width);
    const scale = size / face.units_per_em;
    const raster = try std.testing.allocator.create(vector.GlyphRasterizer);
    defer std.testing.allocator.destroy(raster);
    const band_y0: i32 = @intFromFloat(size - 700 * scale);
    for ([_]u21{ 'A', 'B' }) |codepoint| {
        const glyph = face.glyphIndex(codepoint);
        try std.testing.expect(glyph != 0);
        var builder = vector.PathBuilder(font_ttf.max_glyph_points + 3 * font_ttf.max_glyph_contours){};
        try face.glyphOutline(glyph, .{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 0, .ty = size }, &builder);
        var counter = InkCounter{};
        try vector.fillGlyphPath(
            raster,
            builder.slice(),
            Affine.identity(),
            .nonzero,
            vector.default_tolerance,
            .{ .x0 = 0, .y0 = band_y0, .x1 = @intCast(vector.max_raster_width), .y1 = band_y0 + 32 },
            &counter,
        );
        try std.testing.expect(counter.covered > 0);
    }
}

test "a gate-admitted zigzag face inks outlines on both reference text paths, never the block fallback" {
    // End to end through the reference renderer at the max raster size,
    // on BOTH `drawTextLine` branches: the per-cluster pen walk (plain
    // text) and the shaped-glyph branch (the glyph array the atlas plan
    // keys glyphs by). The block fallback is a solid cell; the zigzag
    // outline alternates inked slivers with background every few
    // pixels, so a mid-glyph row must show many ink transitions —
    // a solid run (block) shows at most two.
    const reference = @import("reference.zig");
    const render_model = @import("render.zig");
    const frame_model = @import("frame.zig");
    const text_model = @import("text.zig");

    const font = buildZigzagFont();
    const face = try font_ttf.Face.parse(font.slice());

    const width: usize = vector.max_raster_width;
    const height: usize = 32;
    const size: f32 = @floatFromInt(vector.max_raster_width);
    // Put the surface band at ~30% of the em: baseline sits below the
    // surface, the zigzag's strokes cross every visible row.
    const baseline: f32 = @as(f32, @floatFromInt(height / 2)) + 0.3 * size;

    const pixels = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(pixels);

    const fonts = [_]reference.ReferenceFont{.{ .id = 64, .face = &face }};
    const shaped = [_]text_model.Glyph{.{ .id = 1, .x = 0, .y = 0, .text_start = 0, .text_len = 1 }};
    const bounds = geometry.RectF.init(0, 0, @floatFromInt(width), @floatFromInt(height));

    for ([_]bool{ false, true }) |use_shaped_glyphs| {
        const glyph_slice: []const text_model.Glyph = if (use_shaped_glyphs) &shaped else &.{};
        const commands = [_]render_model.RenderCommand{.{
            .command = .{ .draw_text = .{
                .id = 1,
                .font_id = 64,
                .size = size,
                .origin = geometry.PointF.init(0, baseline),
                .color = drawing.Color.rgb8(255, 255, 255),
                .text = "A",
                .glyphs = glyph_slice,
            } },
            .local_bounds = bounds,
            .bounds = bounds,
        }};
        const surface = (try reference.ReferenceRenderSurface.init(width, height, pixels)).withFonts(&fonts);
        try surface.renderPass(frame_model.CanvasRenderPass{
            .surface_size = geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)),
            .full_repaint = true,
            .commands = &commands,
        }, drawing.Color.rgba8(0, 0, 0, 0));

        // Mid-band row: count inked pixels and ink<->background
        // transitions. The outline's ~8-px slivers produce hundreds of
        // transitions; the block fallback would be one solid run.
        const row = height / 2;
        var inked: usize = 0;
        var transitions: usize = 0;
        var previous_inked = false;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const alpha = pixels[(row * width + x) * 4 + 3];
            const is_inked = alpha > 0;
            if (is_inked) inked += 1;
            if (is_inked != previous_inked) transitions += 1;
            previous_inked = is_inked;
        }
        try std.testing.expect(inked > 0);
        try std.testing.expect(transitions > 100);
    }
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
