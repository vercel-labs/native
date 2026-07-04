//! Pixel-exact unit tests for the deterministic vector rasterizer
//! (`vector.zig`): path building (including arc lowering), flattening,
//! anti-aliased scanline fill under both fill rules, and
//! stroke-to-outline with caps, joins, and the miter limit.
//!
//! Golden convention: axis-aligned coverage is asserted as exact u8
//! values (the subsample grid makes halves and quarters exact); curvy
//! shapes are pinned with an FNV-1a signature over the coverage grid,
//! like `referenceSurfaceSignature` pins reference-renderer frames.

const std = @import("std");
const geometry = @import("geometry");
const vector = @import("vector.zig");
const drawing = @import("drawing.zig");

const PointF = geometry.PointF;
const Affine = drawing.Affine;
const PathElement = drawing.PathElement;

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

    fn isEmpty(self: *const Grid) bool {
        for (self.data) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }
};

fn fullClip() vector.ClipRect {
    return .{ .x0 = 0, .y0 = 0, .x1 = @intCast(grid_size), .y1 = @intCast(grid_size) };
}

const identity = Affine.identity();

fn rectPath(builder: anytype, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try builder.moveTo(PointF.init(x0, y0));
    try builder.lineTo(PointF.init(x1, y0));
    try builder.lineTo(PointF.init(x1, y1));
    try builder.lineTo(PointF.init(x0, y1));
    try builder.close();
}

fn reverseRectPath(builder: anytype, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try builder.moveTo(PointF.init(x0, y0));
    try builder.lineTo(PointF.init(x0, y1));
    try builder.lineTo(PointF.init(x1, y1));
    try builder.lineTo(PointF.init(x1, y0));
    try builder.close();
}

// ---------------------------------------------------------------------------
// Path builder
// ---------------------------------------------------------------------------

test "path builder records verbs, tracks the current point, and closes subpaths" {
    var builder = vector.PathBuilder(16){};
    try builder.moveTo(PointF.init(1, 2));
    try builder.lineTo(PointF.init(3, 2));
    try builder.quadTo(PointF.init(4, 2), PointF.init(4, 3));
    try builder.cubicTo(PointF.init(4, 4), PointF.init(3, 5), PointF.init(2, 5));
    try builder.close();

    const elements = builder.slice();
    try std.testing.expectEqual(@as(usize, 5), elements.len);
    try std.testing.expectEqual(drawing.PathVerb.move_to, elements[0].verb);
    try std.testing.expectEqual(drawing.PathVerb.line_to, elements[1].verb);
    try std.testing.expectEqual(drawing.PathVerb.quad_to, elements[2].verb);
    try std.testing.expectEqual(drawing.PathVerb.cubic_to, elements[3].verb);
    try std.testing.expectEqual(drawing.PathVerb.close, elements[4].verb);
    // Close returns the pen to the subpath start.
    try std.testing.expectEqual(@as(f32, 1), builder.current.x);
    try std.testing.expectEqual(@as(f32, 2), builder.current.y);

    builder.reset();
    try std.testing.expectEqual(@as(usize, 0), builder.slice().len);
}

test "path builder overflow is a deterministic error" {
    var builder = vector.PathBuilder(2){};
    try builder.moveTo(PointF.init(0, 0));
    try builder.lineTo(PointF.init(1, 0));
    try std.testing.expectError(error.VectorPathTooComplex, builder.lineTo(PointF.init(2, 0)));
}

test "arc lowering ends exactly at the endpoint and emits only cubics" {
    var builder = vector.PathBuilder(32){};
    try builder.moveTo(PointF.init(12, 4));
    try builder.arcTo(8, 8, 0, false, true, PointF.init(12, 20));
    try std.testing.expectEqual(@as(f32, 12), builder.current.x);
    try std.testing.expectEqual(@as(f32, 20), builder.current.y);
    for (builder.slice()[1..]) |element| {
        try std.testing.expectEqual(drawing.PathVerb.cubic_to, element.verb);
    }
    // The final cubic endpoint is bit-exactly the requested endpoint.
    const last = builder.slice()[builder.slice().len - 1];
    try std.testing.expectEqual(@as(f32, 12), last.points[2].x);
    try std.testing.expectEqual(@as(f32, 20), last.points[2].y);
}

test "degenerate arcs fall back to lines" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(2, 2));
    try builder.arcTo(0, 5, 0, false, true, PointF.init(9, 2));
    try std.testing.expectEqual(drawing.PathVerb.line_to, builder.slice()[1].verb);
    // Zero-length arc emits nothing.
    const len_before = builder.slice().len;
    try builder.arcTo(4, 4, 0, false, true, PointF.init(9, 2));
    try std.testing.expectEqual(len_before, builder.slice().len);
}

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

test "curve segment counts scale with deviation and clamp at the budget" {
    const a = PointF.init(0, 0);
    const c = PointF.init(10, 0);
    // A control point on the chord flattens to a single segment.
    try std.testing.expectEqual(@as(usize, 1), vector.quadSegmentCount(a, PointF.init(5, 0), c, 0.25));
    const shallow = vector.quadSegmentCount(a, PointF.init(5, 4), c, 0.25);
    const deep = vector.quadSegmentCount(a, PointF.init(5, 40), c, 0.25);
    try std.testing.expect(shallow > 1);
    try std.testing.expect(deep > shallow);
    const extreme = vector.quadSegmentCount(a, PointF.init(5, 100000), c, 0.25);
    try std.testing.expectEqual(vector.max_curve_segments, extreme);
    const cubic = vector.cubicSegmentCount(a, PointF.init(3, 12), PointF.init(7, 12), c, 0.25);
    try std.testing.expect(cubic > 1);
}

// ---------------------------------------------------------------------------
// Fill
// ---------------------------------------------------------------------------

test "fill covers an axis aligned rect with exact partial coverage" {
    var builder = vector.PathBuilder(8){};
    try rectPath(&builder, 0.5, 0.5, 2.5, 2.5);
    var grid = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &grid);

    // Corners cover a quarter pixel, edges a half, the center is solid.
    try std.testing.expectEqual(@as(u8, 64), grid.at(0, 0));
    try std.testing.expectEqual(@as(u8, 128), grid.at(1, 0));
    try std.testing.expectEqual(@as(u8, 64), grid.at(2, 0));
    try std.testing.expectEqual(@as(u8, 128), grid.at(0, 1));
    try std.testing.expectEqual(@as(u8, 255), grid.at(1, 1));
    try std.testing.expectEqual(@as(u8, 128), grid.at(2, 1));
    try std.testing.expectEqual(@as(u8, 64), grid.at(0, 2));
    try std.testing.expectEqual(@as(u8, 128), grid.at(1, 2));
    try std.testing.expectEqual(@as(u8, 64), grid.at(2, 2));
    try std.testing.expectEqual(@as(u8, 0), grid.at(3, 1));
    try std.testing.expectEqual(@as(u8, 0), grid.at(1, 3));
}

test "fill rules diverge where same winding contours overlap" {
    var builder = vector.PathBuilder(16){};
    try rectPath(&builder, 1, 1, 6, 6);
    try rectPath(&builder, 4, 4, 9, 9);

    var nonzero = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &nonzero);
    var even_odd = Grid{};
    try vector.fillPath(builder.slice(), identity, .even_odd, 0.25, fullClip(), &even_odd);

    // Overlap region: winding 2 stays solid under nonzero, cancels under
    // even-odd.
    try std.testing.expectEqual(@as(u8, 255), nonzero.at(5, 5));
    try std.testing.expectEqual(@as(u8, 0), even_odd.at(5, 5));
    // Non-overlapping interiors agree.
    try std.testing.expectEqual(@as(u8, 255), nonzero.at(2, 2));
    try std.testing.expectEqual(@as(u8, 255), even_odd.at(2, 2));
    try std.testing.expectEqual(@as(u8, 255), nonzero.at(8, 8));
    try std.testing.expectEqual(@as(u8, 255), even_odd.at(8, 8));
}

test "opposite winding carves a hole under both rules" {
    var builder = vector.PathBuilder(16){};
    try rectPath(&builder, 1, 1, 9, 9);
    try reverseRectPath(&builder, 3, 3, 7, 7);

    var nonzero = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &nonzero);
    var even_odd = Grid{};
    try vector.fillPath(builder.slice(), identity, .even_odd, 0.25, fullClip(), &even_odd);

    try std.testing.expectEqual(@as(u8, 0), nonzero.at(5, 5));
    try std.testing.expectEqual(@as(u8, 0), even_odd.at(5, 5));
    try std.testing.expectEqual(@as(u8, 255), nonzero.at(2, 5));
    try std.testing.expectEqual(@as(u8, 255), even_odd.at(2, 5));
}

test "circle fill is symmetric, solid inside, empty outside" {
    var builder = vector.PathBuilder(8){};
    try builder.circle(PointF.init(12, 12), 6);
    var grid = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &grid);

    try std.testing.expectEqual(@as(u8, 255), grid.at(12, 12));
    try std.testing.expectEqual(@as(u8, 255), grid.at(8, 12));
    try std.testing.expectEqual(@as(u8, 0), grid.at(3, 3));
    try std.testing.expectEqual(@as(u8, 0), grid.at(20, 20));
    // Kappa circle geometry is 4-fold symmetric around the center at
    // (12, 12): pixel (12 + i, 12 + j) mirrors to (11 - i, 11 - j).
    var j: usize = 0;
    while (j < 8) : (j += 1) {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try std.testing.expectEqual(grid.at(11 - i, 12 + j), grid.at(12 + i, 12 + j));
            try std.testing.expectEqual(grid.at(12 + i, 11 - j), grid.at(12 + i, 12 + j));
        }
    }
}

test "svg endpoint arcs honor sweep and large arc flags" {
    // Right-bulging semicircle: sweep from (12,4) to (12,20).
    var right = vector.PathBuilder(32){};
    try right.moveTo(PointF.init(12, 4));
    try right.arcTo(8, 8, 0, false, true, PointF.init(12, 20));
    try right.close();
    var right_grid = Grid{};
    try vector.fillPath(right.slice(), identity, .nonzero, 0.25, fullClip(), &right_grid);
    try std.testing.expectEqual(@as(u8, 255), right_grid.at(17, 12));
    try std.testing.expectEqual(@as(u8, 0), right_grid.at(6, 12));

    // Flipping sweep bulges left.
    var left = vector.PathBuilder(32){};
    try left.moveTo(PointF.init(12, 4));
    try left.arcTo(8, 8, 0, false, false, PointF.init(12, 20));
    try left.close();
    var left_grid = Grid{};
    try vector.fillPath(left.slice(), identity, .nonzero, 0.25, fullClip(), &left_grid);
    try std.testing.expectEqual(@as(u8, 255), left_grid.at(6, 12));
    try std.testing.expectEqual(@as(u8, 0), left_grid.at(17, 12));

    // Large arc: the center flips across the chord, so the contour
    // (closed by the chord at x = 12) sweeps most of a circle centered
    // right of the chord — solid far right of where the small arc ends.
    var large = vector.PathBuilder(64){};
    try large.moveTo(PointF.init(12, 8));
    try large.arcTo(6, 6, 0, true, true, PointF.init(12, 16));
    try large.close();
    var large_grid = Grid{};
    try vector.fillPath(large.slice(), identity, .nonzero, 0.25, fullClip(), &large_grid);
    try std.testing.expectEqual(@as(u8, 255), large_grid.at(16, 12));
    try std.testing.expectEqual(@as(u8, 255), large_grid.at(20, 12));
    try std.testing.expectEqual(@as(u8, 255), large_grid.at(12, 12));
    try std.testing.expectEqual(@as(u8, 0), large_grid.at(8, 12));

    // The small arc between the same endpoints is a thin lens hugging
    // the chord: same near-chord pixel, empty where the large arc is
    // solid.
    var small = vector.PathBuilder(64){};
    try small.moveTo(PointF.init(12, 8));
    try small.arcTo(6, 6, 0, false, true, PointF.init(12, 16));
    try small.close();
    var small_grid = Grid{};
    try vector.fillPath(small.slice(), identity, .nonzero, 0.25, fullClip(), &small_grid);
    try std.testing.expectEqual(@as(u8, 255), small_grid.at(12, 12));
    try std.testing.expectEqual(@as(u8, 0), small_grid.at(16, 12));
    try std.testing.expectEqual(@as(u8, 0), small_grid.at(8, 12));
}

test "elliptical arc respects distinct radii" {
    var builder = vector.PathBuilder(64){};
    try builder.moveTo(PointF.init(4, 12));
    try builder.arcTo(8, 4, 0, false, true, PointF.init(20, 12));
    try builder.close();
    var grid = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &grid);
    // Sweep from left to right bulges up (SVG bridge arc), and the
    // semi-minor axis of 4 bounds the bulge: covered just above the
    // chord, empty beyond y = 8 and below the chord.
    try std.testing.expectEqual(@as(u8, 255), grid.at(12, 9));
    try std.testing.expectEqual(@as(u8, 0), grid.at(12, 6));
    try std.testing.expectEqual(@as(u8, 0), grid.at(12, 14));
}

test "fill respects the clip window" {
    var builder = vector.PathBuilder(8){};
    try rectPath(&builder, 0, 0, 20, 20);
    var grid = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, .{ .x0 = 0, .y0 = 0, .x1 = 5, .y1 = 5 }, &grid);
    try std.testing.expectEqual(@as(u8, 255), grid.at(4, 4));
    try std.testing.expectEqual(@as(u8, 0), grid.at(5, 4));
    try std.testing.expectEqual(@as(u8, 0), grid.at(4, 5));
    try std.testing.expectEqual(@as(u8, 0), grid.at(12, 12));
}

test "empty and unclosed inputs rasterize to nothing or their implicit closure" {
    var grid = Grid{};
    try vector.fillPath(&.{}, identity, .nonzero, 0.25, fullClip(), &grid);
    try std.testing.expect(grid.isEmpty());

    // A lone move draws nothing.
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(5, 5));
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &grid);
    try std.testing.expect(grid.isEmpty());

    // An unclosed triangle is implicitly closed for filling.
    builder.reset();
    try builder.moveTo(PointF.init(2, 2));
    try builder.lineTo(PointF.init(10, 2));
    try builder.lineTo(PointF.init(2, 10));
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &grid);
    try std.testing.expectEqual(@as(u8, 255), grid.at(3, 3));
}

test "transformed fill flattens in device space" {
    // Scaling a small circle by 2 is bit-identical to building the large
    // circle directly: the doubling is exact in IEEE-754 and flattening
    // happens after the transform.
    var small = vector.PathBuilder(8){};
    try small.circle(PointF.init(6, 6), 3);
    var scaled = Grid{};
    try vector.fillPath(small.slice(), Affine.scale(2, 2), .nonzero, 0.25, fullClip(), &scaled);

    var big = vector.PathBuilder(8){};
    try big.circle(PointF.init(12, 12), 6);
    var direct = Grid{};
    try vector.fillPath(big.slice(), identity, .nonzero, 0.25, fullClip(), &direct);

    try std.testing.expectEqualSlices(u8, &direct.data, &scaled.data);
}

test "fill rasterization is deterministic across runs" {
    var builder = vector.PathBuilder(16){};
    try builder.circle(PointF.init(11.3, 12.7), 7.1);
    var first = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &first);
    var second = Grid{};
    try vector.fillPath(builder.slice(), identity, .nonzero, 0.25, fullClip(), &second);
    try std.testing.expectEqualSlices(u8, &first.data, &second.data);
    try std.testing.expectEqual(first.signature(), second.signature());
}

// ---------------------------------------------------------------------------
// Stroke
// ---------------------------------------------------------------------------

test "butt caps end exactly at the segment, round caps extend it" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(4.5, 12.5));
    try builder.lineTo(PointF.init(19.5, 12.5));

    var butt = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 3, .cap = .butt }, 0.25, fullClip(), &butt);
    // Band is y in [11, 14], x in [4.5, 19.5].
    try std.testing.expectEqual(@as(u8, 255), butt.at(12, 11));
    try std.testing.expectEqual(@as(u8, 255), butt.at(12, 13));
    try std.testing.expectEqual(@as(u8, 0), butt.at(12, 10));
    try std.testing.expectEqual(@as(u8, 0), butt.at(12, 14));
    try std.testing.expectEqual(@as(u8, 128), butt.at(4, 12));
    try std.testing.expectEqual(@as(u8, 0), butt.at(3, 12));
    try std.testing.expectEqual(@as(u8, 128), butt.at(19, 12));
    try std.testing.expectEqual(@as(u8, 0), butt.at(20, 12));

    var round = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 3, .cap = .round }, 0.25, fullClip(), &round);
    try std.testing.expect(round.at(3, 12) > 0);
    try std.testing.expect(round.at(20, 12) > 0);
    try std.testing.expect(round.at(4, 12) > butt.at(4, 12));
}

test "zero width strokes draw nothing" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(4, 12));
    try builder.lineTo(PointF.init(20, 12));
    var grid = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 0 }, 0.25, fullClip(), &grid);
    try std.testing.expect(grid.isEmpty());
}

test "round cap renders a dot for a zero length segment" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(12, 12));
    try builder.lineTo(PointF.init(12, 12));

    var round = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 6, .cap = .round }, 0.25, fullClip(), &round);
    try std.testing.expectEqual(@as(u8, 255), round.at(12, 12));
    try std.testing.expectEqual(@as(u8, 255), round.at(11, 11));

    var butt = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 6, .cap = .butt }, 0.25, fullClip(), &butt);
    try std.testing.expect(butt.isEmpty());
}

test "miter join fills the outer corner, round softens it, limit bevels it" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(5, 5));
    try builder.lineTo(PointF.init(15, 5));
    try builder.lineTo(PointF.init(15, 15));

    var miter = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 4, .join = .miter }, 0.25, fullClip(), &miter);
    // The miter tip square [15,17]x[3,5] covers the corner pixel solid.
    try std.testing.expectEqual(@as(u8, 255), miter.at(16, 3));
    try std.testing.expectEqual(@as(u8, 255), miter.at(16, 4));

    var round = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 4, .join = .round }, 0.25, fullClip(), &round);
    try std.testing.expect(round.at(16, 3) > 0);
    try std.testing.expect(round.at(16, 3) < 255);

    var bevel = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 4, .join = .miter, .miter_limit = 1 }, 0.25, fullClip(), &bevel);
    try std.testing.expect(bevel.at(16, 3) < miter.at(16, 3));
    // All variants share the segment interiors.
    try std.testing.expectEqual(@as(u8, 255), miter.at(10, 5));
    try std.testing.expectEqual(@as(u8, 255), round.at(10, 5));
    try std.testing.expectEqual(@as(u8, 255), bevel.at(10, 5));
    try std.testing.expectEqual(@as(u8, 255), miter.at(15, 10));
}

test "closed rectangle stroke rings the outline and leaves the interior empty" {
    var builder = vector.PathBuilder(8){};
    try rectPath(&builder, 6, 6, 18, 18);
    var grid = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 2, .join = .miter }, 0.25, fullClip(), &grid);

    try std.testing.expectEqual(@as(u8, 255), grid.at(5, 12));
    try std.testing.expectEqual(@as(u8, 255), grid.at(12, 5));
    try std.testing.expectEqual(@as(u8, 255), grid.at(18, 12));
    try std.testing.expectEqual(@as(u8, 255), grid.at(12, 18));
    // Miter joins square off all four outer corners of the closed ring.
    try std.testing.expectEqual(@as(u8, 255), grid.at(5, 5));
    try std.testing.expectEqual(@as(u8, 255), grid.at(18, 5));
    try std.testing.expectEqual(@as(u8, 255), grid.at(18, 18));
    try std.testing.expectEqual(@as(u8, 255), grid.at(5, 18));
    // Interior stays empty.
    try std.testing.expectEqual(@as(u8, 0), grid.at(12, 12));
    try std.testing.expectEqual(@as(u8, 0), grid.at(8, 12));
}

test "stroke of a curved path is smooth and deterministic" {
    var builder = vector.PathBuilder(8){};
    try builder.moveTo(PointF.init(4, 18));
    try builder.quadTo(PointF.init(12, 2), PointF.init(20, 18));

    var first = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 3, .cap = .round, .join = .round }, 0.25, fullClip(), &first);
    var second = Grid{};
    try vector.strokePath(builder.slice(), identity, .{ .width = 3, .cap = .round, .join = .round }, 0.25, fullClip(), &second);
    try std.testing.expectEqualSlices(u8, &first.data, &second.data);

    // The apex of the curve (near y = 10 at x = 12) carries the band.
    try std.testing.expect(first.at(12, 10) == 255);
    try std.testing.expect(first.at(12, 2) == 0);
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

test "edge budget overflow is a deterministic error" {
    var elements: [4200]PathElement = undefined;
    elements[0] = .{ .verb = .move_to, .points = .{ PointF.init(0, 0), PointF.zero(), PointF.zero() } };
    var index: usize = 1;
    while (index < elements.len) : (index += 1) {
        const x: f32 = @floatFromInt(index);
        const y: f32 = if (index % 2 == 0) 0 else 10;
        elements[index] = .{ .verb = .line_to, .points = .{ PointF.init(x, y), PointF.zero(), PointF.zero() } };
    }
    var grid = Grid{};
    try std.testing.expectError(
        error.VectorPathTooComplex,
        vector.fillPath(&elements, identity, .nonzero, 0.25, fullClip(), &grid),
    );
}

test "overwide raster regions are rejected" {
    var builder = vector.PathBuilder(8){};
    try rectPath(&builder, 0, 0, 9000, 4);
    var grid = Grid{};
    try std.testing.expectError(
        error.VectorRasterTooWide,
        vector.fillPath(builder.slice(), identity, .nonzero, 0.25, .{ .x0 = 0, .y0 = 0, .x1 = 9000, .y1 = 4 }, &grid),
    );
}

test "stroke subpath point budget overflow is a deterministic error" {
    var elements: [600]PathElement = undefined;
    elements[0] = .{ .verb = .move_to, .points = .{ PointF.init(0, 0), PointF.zero(), PointF.zero() } };
    var index: usize = 1;
    while (index < elements.len) : (index += 1) {
        const x: f32 = @floatFromInt(index);
        const y: f32 = if (index % 2 == 0) 0 else 10;
        elements[index] = .{ .verb = .line_to, .points = .{ PointF.init(x, y), PointF.zero(), PointF.zero() } };
    }
    var grid = Grid{};
    try std.testing.expectError(
        error.VectorPathTooComplex,
        vector.strokePath(&elements, identity, .{ .width = 1 }, 0.25, fullClip(), &grid),
    );
}

// ---------------------------------------------------------------------------
// Signature goldens (curvy shapes)
// ---------------------------------------------------------------------------

test "signature goldens pin curvy coverage byte for byte" {
    var circle = vector.PathBuilder(8){};
    try circle.circle(PointF.init(12, 12), 7.5);
    var circle_grid = Grid{};
    try vector.fillPath(circle.slice(), identity, .nonzero, 0.25, fullClip(), &circle_grid);
    try std.testing.expectEqual(@as(u64, 5089557305873932749), circle_grid.signature());

    var wave = vector.PathBuilder(8){};
    try wave.moveTo(PointF.init(2, 12));
    try wave.cubicTo(PointF.init(8, 2), PointF.init(16, 22), PointF.init(22, 12));
    var wave_grid = Grid{};
    try vector.strokePath(wave.slice(), identity, .{ .width = 2.5, .cap = .round, .join = .round }, 0.25, fullClip(), &wave_grid);
    try std.testing.expectEqual(@as(u64, 17640634242114431619), wave_grid.signature());

    var icon = vector.PathBuilder(16){};
    // A stroke-dialect check mark: stroke-2 in a 24x24 box.
    try icon.moveTo(PointF.init(4, 12));
    try icon.lineTo(PointF.init(9, 17));
    try icon.lineTo(PointF.init(20, 6));
    var icon_grid = Grid{};
    try vector.strokePath(icon.slice(), identity, .{ .width = 2, .cap = .round, .join = .round }, 0.25, fullClip(), &icon_grid);
    try std.testing.expectEqual(@as(u64, 9634424213823865389), icon_grid.signature());
}
