//! Deterministic CPU path rasterizer — the one vector core serving path
//! draw commands, real font glyphs, and SVG icons.
//!
//! Design constraints:
//! - std-only and allocation-free: fixed-capacity buffers on the caller's
//!   stack, no allocator anywhere.
//! - Deterministic across platforms: the raster core uses only `+ - * /`
//!   and `@sqrt` (all IEEE-754 correctly rounded). Round caps/joins and
//!   arcs are lowered to cubic Beziers via the quarter-circle kappa
//!   constant and sqrt-only half-angle identities, so no trigonometry is
//!   involved. The single exception is a nonzero `x_rotation` on
//!   `PathBuilder.arcTo` (documented there).
//! - Anti-aliased scanline fill: `sub_samples` vertical subsamples per
//!   pixel row with analytically exact horizontal span coverage,
//!   supporting both `nonzero` and `even_odd` fill rules.
//! - Stroke-to-outline: every segment, join, and cap becomes a
//!   consistently oriented polygon piece and the union is filled with the
//!   nonzero rule. Caps: butt or round. Joins: miter (with limit,
//!   falling back to bevel) or round — the built-in stroke icons need round.
//!
//! The path model is the existing wire model (`drawing.PathElement`:
//! move/line/quad/cubic/close). Arcs are a *builder-level* verb lowered to
//! cubics by `PathBuilder.arcTo`, so serialization, hashing, and the
//! AppKit packet path are untouched: paths built here remain fully
//! packet-representable, and AppKit keeps rasterizing them natively.

const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");

const PointF = geometry.PointF;
const Affine = drawing_model.Affine;
const PathElement = drawing_model.PathElement;
const PathVerb = drawing_model.PathVerb;

pub const Error = error{
    /// A fixed-capacity buffer (edges, subpath points, scanline
    /// crossings, or a `PathBuilder`) overflowed. The path is too complex
    /// for the deterministic budget; split it or simplify it.
    VectorPathTooComplex,
    /// The clipped raster region is wider than `max_raster_width` pixels.
    VectorRasterTooWide,
};

/// How a filled path decides interiorness.
pub const FillRule = enum { nonzero, even_odd };

/// Stroke end-cap shape — the wire model's type, re-exported so the
/// stroke rasterizer, the parsed icon style, and the `stroke_path`
/// command's cap channel all share one enum (no mapping layer to drift).
pub const LineCap = drawing_model.LineCap;

/// Stroke join shape. `miter` falls back to a bevel past `miter_limit`.
pub const LineJoin = enum { miter, round };

pub const StrokeStyle = struct {
    /// Stroke width in device pixels (apply any transform scale before
    /// passing it in).
    width: f32,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    /// Ratio of miter length to half stroke width above which a miter
    /// join is replaced by a bevel (the SVG default is 4).
    miter_limit: f32 = 4,
};

/// Curve flattening tolerance in device pixels: the maximum distance the
/// polyline approximation may deviate from the true curve.
pub const default_tolerance: f32 = 0.25;

/// Vertical subsamples per pixel row; horizontal coverage is exact.
pub const sub_samples: usize = 4;

pub const max_edges: usize = 4096;
pub const max_scanline_crossings: usize = 256;
pub const max_raster_width: usize = 8192;
pub const max_curve_segments: usize = 48;
pub const max_stroke_subpath_points: usize = 512;
const max_piece_points: usize = 4 * max_curve_segments + 4;

// ---------------------------------------------------------------------------
// Glyph-fill raster budgets
// ---------------------------------------------------------------------------
//
// Font registration promises that a registered face ALWAYS resolves at
// render time — the glyph-budget gate (`font_ttf.Face.parse`) refuses
// over-budget faces loudly at registration so render never degrades a
// glyph to a block fallback. That promise is only true if the raster
// capacities cover the worst load the outline budgets admit, so these
// budgets are DERIVED from them instead of trusting real faces to be
// polite (`font_ttf` cannot be imported here — it imports this module —
// so the arithmetic is written out and lockstep-pinned by a test in
// font_ttf_tests.zig against the source constants).
//
// Worst admitted glyph (1024 points / 128 contours, simple and
// flattened-composite maxima are gated equal; glyph outlines emit only
// move/line/quad/close):
//
//   quads <= points + contours          = 1024 + 128 = 1152
//     (each point emits at most one line or quad; each contour adds at
//     most one closing quad — the same walk the glyph path capacity in
//     reference.zig is derived from)
//   edges <= quads * segments + contours = 1152 * 16 + 128 = 18,560
//     (each quad flattens to at most `max_glyph_curve_segments` line
//     segments, lines and the per-contour close edge are one each)
//   scanline crossings <= edges          = 18,560
//     (an edge crosses a scanline at most once — the half-open span
//     test in `sweep` — so the edge bound is also the airtight crossing
//     bound, with no reliance on curve monotonicity under float
//     sampling)
//
// The flattening multiplier is the honest quality decision. Nothing in
// the pipeline bounds text size (`max_raster_width` bounds the clipped
// sweep window, not the accumulated edges), so tolerance-exact
// flattening has no finite bound at all — a full-em quad at an
// S-pixel em wants ceil(sqrt((S/2) / 0.25)) segments (128 at S = 8192)
// — and even the generic `max_curve_segments` cap of 48 would put the
// worst case at 1152 * 48 + 128 = 55,424 edges = 1.06 MiB of edge
// storage plus 433 KiB of crossings per rasterizer: memory-unreasonable
// for a per-thread buffer. Flattening tolerance is a quality knob, not
// correctness, so glyph fills clamp subdivision instead: at 16 segments
// the clamp only binds when a curve's flatness deviation exceeds
// 0.25 * 16^2 = 64 px — a worst-case full-em quad only reaches that
// above a 128-px em — and past it the polyline deviates at most
// deviation / 16^2 <= (em/2) / 256 = em/512 from the true curve, 0.2%
// of the em at every size (0.5 px on a 256-px em). Real faces' quads
// span fractions of the em, so everything the golden suite renders
// stays below the clamp and byte-identical.
//
// Storage: 18,560 edges * 20 B = 362.5 KiB plus 18,560 crossings * 8 B
// = 145 KiB, ~508 KiB per `GlyphRasterizer`. The glyph raster caller
// (reference.zig) keeps ONE per render thread behind a lazily
// heap-allocated pointer (`canvas.lazy_tls`), so it costs neither stack
// nor static TLS, and threads that never ink a glyph never allocate it.
pub const max_glyph_curve_segments: usize = 16;
pub const max_glyph_fill_edges: usize = 18_560;
pub const max_glyph_scanline_crossings: usize = max_glyph_fill_edges;

/// Half-open device-pixel clip window: pixels with `x0 <= x < x1` and
/// `y0 <= y < y1` may be emitted.
pub const ClipRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

/// Kappa: control-point offset factor approximating a quarter circle with
/// one cubic Bezier.
pub const circle_kappa: f32 = 0.5522847498307936;

// ---------------------------------------------------------------------------
// Path builder
// ---------------------------------------------------------------------------

/// Fixed-capacity builder over the wire path model. Arc verbs are lowered
/// to cubic Beziers at build time so the emitted elements stay
/// serializable, hashable, and packet-representable unchanged.
pub fn PathBuilder(comptime capacity: usize) type {
    return struct {
        elements: [capacity]PathElement = undefined,
        len: usize = 0,
        current: PointF = PointF.zero(),
        subpath_start: PointF = PointF.zero(),
        has_current: bool = false,

        const Self = @This();

        pub fn slice(self: *const Self) []const PathElement {
            return self.elements[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.has_current = false;
            self.current = PointF.zero();
            self.subpath_start = PointF.zero();
        }

        pub fn moveTo(self: *Self, point: PointF) Error!void {
            try self.append(.{ .verb = .move_to, .points = .{ point, PointF.zero(), PointF.zero() } });
            self.current = point;
            self.subpath_start = point;
            self.has_current = true;
        }

        pub fn lineTo(self: *Self, point: PointF) Error!void {
            if (!self.has_current) return self.moveTo(point);
            try self.append(.{ .verb = .line_to, .points = .{ point, PointF.zero(), PointF.zero() } });
            self.current = point;
        }

        pub fn quadTo(self: *Self, control: PointF, end: PointF) Error!void {
            if (!self.has_current) try self.moveTo(PointF.zero());
            try self.append(.{ .verb = .quad_to, .points = .{ control, end, PointF.zero() } });
            self.current = end;
        }

        pub fn cubicTo(self: *Self, control_a: PointF, control_b: PointF, end: PointF) Error!void {
            if (!self.has_current) try self.moveTo(PointF.zero());
            try self.append(.{ .verb = .cubic_to, .points = .{ control_a, control_b, end } });
            self.current = end;
        }

        pub fn close(self: *Self) Error!void {
            if (!self.has_current) return;
            try self.append(.{ .verb = .close });
            self.current = self.subpath_start;
        }

        /// SVG endpoint arc (the `A`/`a` path command), lowered to cubic
        /// Beziers. `x_rotation_deg` is the ellipse x-axis rotation in
        /// degrees; when it is zero (every built-in icon) the lowering is
        /// sqrt-only and fully deterministic. A nonzero rotation uses
        /// `@cos`/`@sin` once and is the sole non-sqrt code path in this
        /// module.
        pub fn arcTo(
            self: *Self,
            rx_in: f32,
            ry_in: f32,
            x_rotation_deg: f32,
            large_arc: bool,
            sweep: bool,
            end: PointF,
        ) Error!void {
            if (!self.has_current) try self.moveTo(PointF.zero());
            const start = self.current;
            var rx = @abs(rx_in);
            var ry = @abs(ry_in);
            if (rx <= 0 or ry <= 0) return self.lineTo(end);
            if (start.x == end.x and start.y == end.y) return;

            var cos_phi: f32 = 1;
            var sin_phi: f32 = 0;
            if (x_rotation_deg != 0) {
                const phi = x_rotation_deg * std.math.pi / 180.0;
                cos_phi = @cos(phi);
                sin_phi = @sin(phi);
            }

            // SVG implementation notes F.6.5: endpoint to center form.
            const half_dx = (start.x - end.x) * 0.5;
            const half_dy = (start.y - end.y) * 0.5;
            const x1p = cos_phi * half_dx + sin_phi * half_dy;
            const y1p = -sin_phi * half_dx + cos_phi * half_dy;

            const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
            if (lambda > 1) {
                const scale = @sqrt(lambda);
                rx *= scale;
                ry *= scale;
            }

            const rx2 = rx * rx;
            const ry2 = ry * ry;
            const denom = rx2 * y1p * y1p + ry2 * x1p * x1p;
            if (denom <= 0) return self.lineTo(end);
            const radicand = @max(0, (rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p) / denom);
            var coefficient = @sqrt(radicand);
            if (large_arc == sweep) coefficient = -coefficient;
            const cxp = coefficient * (rx * y1p / ry);
            const cyp = coefficient * (-ry * x1p / rx);

            const center = PointF.init(
                cos_phi * cxp - sin_phi * cyp + (start.x + end.x) * 0.5,
                sin_phi * cxp + cos_phi * cyp + (start.y + end.y) * 0.5,
            );

            const unit_from = normalizeOrNull(PointF.init((x1p - cxp) / rx, (y1p - cyp) / ry)) orelse return self.lineTo(end);
            const unit_to = normalizeOrNull(PointF.init((-x1p - cxp) / rx, (-y1p - cyp) / ry)) orelse return self.lineTo(end);

            const frame = ArcFrame{
                .center = center,
                .rx = rx,
                .ry = ry,
                .cos_phi = cos_phi,
                .sin_phi = sin_phi,
            };
            if (large_arc) {
                // Split at the point diametrically opposite the short-way
                // midpoint; each half is then at most 180 degrees.
                const sum = PointF.init(unit_from.x + unit_to.x, unit_from.y + unit_to.y);
                const mid = if (normalizeOrNull(sum)) |unit|
                    PointF.init(-unit.x, -unit.y)
                else
                    rotate90(unit_from, sweep);
                try self.emitUnitArc(frame, unit_from, mid, sweep);
                try self.emitUnitArc(frame, mid, unit_to, sweep);
            } else {
                try self.emitUnitArc(frame, unit_from, unit_to, sweep);
            }
            self.current = end;
        }

        /// Full circle as four kappa cubics (sqrt-free, deterministic).
        pub fn circle(self: *Self, center: PointF, radius: f32) Error!void {
            if (radius <= 0) return;
            const r = radius;
            const k = circle_kappa * r;
            const cx = center.x;
            const cy = center.y;
            try self.moveTo(PointF.init(cx + r, cy));
            try self.cubicTo(PointF.init(cx + r, cy + k), PointF.init(cx + k, cy + r), PointF.init(cx, cy + r));
            try self.cubicTo(PointF.init(cx - k, cy + r), PointF.init(cx - r, cy + k), PointF.init(cx - r, cy));
            try self.cubicTo(PointF.init(cx - r, cy - k), PointF.init(cx - k, cy - r), PointF.init(cx, cy - r));
            try self.cubicTo(PointF.init(cx + k, cy - r), PointF.init(cx + r, cy - k), PointF.init(cx + r, cy));
            try self.close();
        }

        /// Arc of at most 180 degrees between unit vectors, recursively
        /// bisected (sqrt-only) until each piece is at most ~90 degrees,
        /// then emitted as one cubic per piece.
        fn emitUnitArc(self: *Self, frame: ArcFrame, a: PointF, b: PointF, sweep: bool) Error!void {
            const dot = a.x * b.x + a.y * b.y;
            if (dot < 0.1) {
                // More than ~84 degrees: bisect at the short-way midpoint
                // (or the sweep-side perpendicular at exactly 180).
                const sum = PointF.init(a.x + b.x, a.y + b.y);
                const mid = normalizeOrNull(sum) orelse rotate90(a, sweep);
                // The short-way midpoint must lie on the sweep side; for
                // arcs <= 180 degrees it always does.
                try self.emitUnitArc(frame, a, mid, sweep);
                try self.emitUnitArc(frame, mid, b, sweep);
                return;
            }
            // tan(theta/4) from cos(theta) via sqrt-only half-angle
            // identities: cos(t/2) = sqrt((1+cos t)/2), sin(t/2) =
            // sqrt((1-cos t)/2), tan(t/4) = sin(t/2) / (1 + cos(t/2)).
            const clamped = std.math.clamp(dot, -1, 1);
            const cos_half = @sqrt((1 + clamped) * 0.5);
            const sin_half = @sqrt((1 - clamped) * 0.5);
            const tan_quarter = sin_half / (1 + cos_half);
            const k = (4.0 / 3.0) * tan_quarter;

            const ta = rotate90(a, sweep);
            const tb = rotate90(b, sweep);
            const c1 = PointF.init(a.x + ta.x * k, a.y + ta.y * k);
            const c2 = PointF.init(b.x - tb.x * k, b.y - tb.y * k);
            try self.cubicTo(frame.map(c1), frame.map(c2), frame.map(b));
        }

        fn append(self: *Self, element: PathElement) Error!void {
            if (self.len >= capacity) return error.VectorPathTooComplex;
            self.elements[self.len] = element;
            self.len += 1;
        }
    };
}

const ArcFrame = struct {
    center: PointF,
    rx: f32,
    ry: f32,
    cos_phi: f32,
    sin_phi: f32,

    fn map(self: ArcFrame, unit: PointF) PointF {
        const x = unit.x * self.rx;
        const y = unit.y * self.ry;
        return PointF.init(
            self.center.x + self.cos_phi * x - self.sin_phi * y,
            self.center.y + self.sin_phi * x + self.cos_phi * y,
        );
    }
};

fn normalizeOrNull(v: PointF) ?PointF {
    const len = @sqrt(v.x * v.x + v.y * v.y);
    if (len <= 0.000001) return null;
    return PointF.init(v.x / len, v.y / len);
}

/// Rotate a vector 90 degrees in the sweep direction (y-down screen
/// coordinates: `sweep` follows increasing angle, i.e. clockwise on
/// screen).
fn rotate90(v: PointF, sweep: bool) PointF {
    return if (sweep) PointF.init(-v.y, v.x) else PointF.init(v.y, -v.x);
}

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

/// Deterministic segment count for a quadratic: the maximum deviation of
/// the chord from the curve is bounded by the second difference over 4,
/// and subdividing into n segments divides it by n^2.
pub fn quadSegmentCount(p0: PointF, p1: PointF, p2: PointF, tolerance: f32) usize {
    return quadSegmentCountLimited(p0, p1, p2, tolerance, max_curve_segments);
}

fn quadSegmentCountLimited(p0: PointF, p1: PointF, p2: PointF, tolerance: f32, segment_limit: usize) usize {
    const dx = @abs(p0.x - 2 * p1.x + p2.x);
    const dy = @abs(p0.y - 2 * p1.y + p2.y);
    const deviation = @max(dx, dy) * 0.25;
    return segmentCountForDeviation(deviation, tolerance, segment_limit);
}

/// Deterministic segment count for a cubic from the larger of its two
/// second differences (conservative flatness bound).
pub fn cubicSegmentCount(p0: PointF, p1: PointF, p2: PointF, p3: PointF, tolerance: f32) usize {
    return cubicSegmentCountLimited(p0, p1, p2, p3, tolerance, max_curve_segments);
}

fn cubicSegmentCountLimited(p0: PointF, p1: PointF, p2: PointF, p3: PointF, tolerance: f32, segment_limit: usize) usize {
    const d1x = @abs(p0.x - 2 * p1.x + p2.x);
    const d1y = @abs(p0.y - 2 * p1.y + p2.y);
    const d2x = @abs(p1.x - 2 * p2.x + p3.x);
    const d2y = @abs(p1.y - 2 * p2.y + p3.y);
    const deviation = @max(@max(d1x, d1y), @max(d2x, d2y)) * 0.75;
    return segmentCountForDeviation(deviation, tolerance, segment_limit);
}

fn segmentCountForDeviation(deviation: f32, tolerance: f32, segment_limit: usize) usize {
    const tol = @max(0.01, tolerance);
    if (!(deviation > tol)) return 1;
    const count = @ceil(@sqrt(deviation / tol));
    if (!(count > 1)) return 1;
    if (count >= @as(f32, @floatFromInt(segment_limit))) return segment_limit;
    return @intFromFloat(count);
}

fn quadPoint(a: PointF, b: PointF, c: PointF, t: f32) PointF {
    const u = 1 - t;
    return PointF.init(
        u * u * a.x + 2 * u * t * b.x + t * t * c.x,
        u * u * a.y + 2 * u * t * b.y + t * t * c.y,
    );
}

fn cubicPoint(a: PointF, b: PointF, c: PointF, d: PointF, t: f32) PointF {
    const u = 1 - t;
    return PointF.init(
        u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
        u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y,
    );
}

/// Walk a path in device space (transform applied), flattening curves to
/// line segments within `tolerance`, reporting subpaths to `sink`:
/// `subpathBegin(point)`, `subpathPoint(point)`, `subpathEnd(closed)`.
/// `segment_limit` caps the per-curve flattening count
/// (`max_curve_segments` generically; `max_glyph_curve_segments` for
/// glyph fills — see the glyph budget derivation above).
fn walkPath(elements: []const PathElement, transform: Affine, tolerance: f32, segment_limit: usize, sink: anytype) Error!void {
    var has_current = false;
    var active = false;
    var current = PointF.zero();
    var subpath_start = PointF.zero();

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                if (active) {
                    try sink.subpathEnd(false);
                    active = false;
                }
                current = transform.transformPoint(element.points[0]);
                subpath_start = current;
                has_current = true;
            },
            .line_to => {
                const next = transform.transformPoint(element.points[0]);
                if (!has_current) {
                    current = next;
                    subpath_start = next;
                    has_current = true;
                    continue;
                }
                try ensureActive(sink, &active, current);
                try sink.subpathPoint(next);
                current = next;
            },
            .quad_to => {
                if (!has_current) continue;
                const control = transform.transformPoint(element.points[0]);
                const end = transform.transformPoint(element.points[1]);
                try ensureActive(sink, &active, current);
                const segments = quadSegmentCountLimited(current, control, end, tolerance, segment_limit);
                var index: usize = 1;
                while (index <= segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
                    try sink.subpathPoint(quadPoint(current, control, end, t));
                }
                current = end;
            },
            .cubic_to => {
                if (!has_current) continue;
                const control_a = transform.transformPoint(element.points[0]);
                const control_b = transform.transformPoint(element.points[1]);
                const end = transform.transformPoint(element.points[2]);
                try ensureActive(sink, &active, current);
                const segments = cubicSegmentCountLimited(current, control_a, control_b, end, tolerance, segment_limit);
                var index: usize = 1;
                while (index <= segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
                    try sink.subpathPoint(cubicPoint(current, control_a, control_b, end, t));
                }
                current = end;
            },
            .close => {
                if (active) {
                    try sink.subpathEnd(true);
                    active = false;
                }
                if (has_current) current = subpath_start;
            },
        }
    }
    if (active) try sink.subpathEnd(false);
}

fn ensureActive(sink: anytype, active: *bool, start: PointF) Error!void {
    if (active.*) return;
    try sink.subpathBegin(start);
    active.* = true;
}

// ---------------------------------------------------------------------------
// Edge accumulation + scanline sweep
// ---------------------------------------------------------------------------

const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// Winding contribution: +1 for a downward edge, -1 for upward.
    dir: f32,
};

/// Fixed-capacity edge accumulator plus the anti-aliased scanline sweep,
/// generic over its edge/crossing budgets: `Rasterizer` (the generic
/// path/icon budgets, stack-sized) and `GlyphRasterizer` (the derived
/// glyph budgets above, sized for a per-thread heap slot) are the two
/// instantiations. It holds no pointers and is reusable via `resetEdges`.
pub fn RasterizerType(comptime edge_capacity: usize, comptime crossing_capacity: usize) type {
    return struct {
        edges: [edge_capacity]Edge = undefined,
        edge_count: usize = 0,
        min_x: f32 = 0,
        min_y: f32 = 0,
        max_x: f32 = 0,
        max_y: f32 = 0,
        /// Scanline scratch for `sweep`, in the struct rather than its
        /// stack frame so the glyph instantiation's 145 KiB rides the
        /// same per-thread heap slot as its edges.
        crossings: [crossing_capacity]Crossing = undefined,

        const Self = @This();

        pub fn resetEdges(self: *Self) void {
            self.edge_count = 0;
        }

        pub fn addEdge(self: *Self, a: PointF, b: PointF) Error!void {
            if (a.y == b.y) return;
            if (!std.math.isFinite(a.x) or !std.math.isFinite(a.y) or !std.math.isFinite(b.x) or !std.math.isFinite(b.y)) return;
            if (self.edge_count >= edge_capacity) return error.VectorPathTooComplex;
            if (self.edge_count == 0) {
                self.min_x = @min(a.x, b.x);
                self.max_x = @max(a.x, b.x);
                self.min_y = @min(a.y, b.y);
                self.max_y = @max(a.y, b.y);
            } else {
                self.min_x = @min(self.min_x, @min(a.x, b.x));
                self.max_x = @max(self.max_x, @max(a.x, b.x));
                self.min_y = @min(self.min_y, @min(a.y, b.y));
                self.max_y = @max(self.max_y, @max(a.y, b.y));
            }
            self.edges[self.edge_count] = .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y, .dir = if (b.y > a.y) 1 else -1 };
            self.edge_count += 1;
        }

        /// Append a closed polygon ring with canonical orientation (pieces of
        /// a stroke union must all wind the same way for the nonzero rule).
        pub fn addPolygon(self: *Self, points: []const PointF) Error!void {
            if (points.len < 3) return;
            var area: f32 = 0;
            var index: usize = 0;
            while (index < points.len) : (index += 1) {
                const a = points[index];
                const b = points[(index + 1) % points.len];
                area += a.x * b.y - b.x * a.y;
            }
            if (@abs(area) <= 0.000000001) return;
            if (area >= 0) {
                index = 0;
                while (index < points.len) : (index += 1) {
                    try self.addEdge(points[index], points[(index + 1) % points.len]);
                }
            } else {
                index = points.len;
                while (index > 0) : (index -= 1) {
                    try self.addEdge(points[index % points.len], points[index - 1]);
                }
            }
        }

        /// Sweep the accumulated edges, emitting `sink.pixel(x, y, coverage)`
        /// for every pixel inside `clip` with coverage > 0. Coverage is in
        /// (0, 1]; `sub_samples` vertical subsamples, exact horizontal spans.
        pub fn sweep(self: *Self, rule: FillRule, clip: ClipRect, sink: anytype) Error!void {
            if (self.edge_count == 0) return;
            const y_begin = @max(clip.y0, floorI(self.min_y));
            const y_end = @min(clip.y1, ceilI(self.max_y));
            const x_begin = @max(clip.x0, floorI(self.min_x));
            const x_end = @min(clip.x1, ceilI(self.max_x));
            if (x_end <= x_begin or y_end <= y_begin) return;
            const width: usize = @intCast(x_end - x_begin);
            if (width > max_raster_width) return error.VectorRasterTooWide;

            const x_origin = @as(f32, @floatFromInt(x_begin));
            const weight = 1.0 / @as(f32, @floatFromInt(sub_samples));
            var row: [max_raster_width]f32 = undefined;

            var y = y_begin;
            while (y < y_end) : (y += 1) {
                @memset(row[0..width], 0);
                var sub: usize = 0;
                while (sub < sub_samples) : (sub += 1) {
                    const sy = @as(f32, @floatFromInt(y)) +
                        (@as(f32, @floatFromInt(sub)) + 0.5) / @as(f32, @floatFromInt(sub_samples));
                    var crossing_count: usize = 0;
                    for (self.edges[0..self.edge_count]) |edge| {
                        const top = @min(edge.y0, edge.y1);
                        const bottom = @max(edge.y0, edge.y1);
                        if (!(sy >= top and sy < bottom)) continue;
                        const x = edge.x0 + (sy - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0);
                        if (crossing_count >= crossing_capacity) return error.VectorPathTooComplex;
                        self.crossings[crossing_count] = .{ .x = x, .dir = edge.dir };
                        crossing_count += 1;
                    }
                    if (crossing_count == 0) continue;
                    sortCrossings(self.crossings[0..crossing_count]);

                    var winding: f32 = 0;
                    var parity = false;
                    var inside = false;
                    var span_start: f32 = 0;
                    for (self.crossings[0..crossing_count]) |crossing| {
                        const was_inside = inside;
                        switch (rule) {
                            .nonzero => {
                                winding += crossing.dir;
                                inside = winding != 0;
                            },
                            .even_odd => {
                                parity = !parity;
                                inside = parity;
                            },
                        }
                        if (!was_inside and inside) {
                            span_start = crossing.x;
                        } else if (was_inside and !inside) {
                            accumulateSpan(row[0..width], x_origin, span_start, crossing.x, weight);
                        }
                    }
                }
                for (row[0..width], 0..) |coverage, i| {
                    if (coverage > 0.0009) {
                        sink.pixel(x_begin + @as(i32, @intCast(i)), y, @min(1, coverage));
                    }
                }
            }
        }
    };
}

/// The stack-friendly instantiation every generic path/icon fill and
/// stroke uses (~82 KiB).
pub const Rasterizer = RasterizerType(max_edges, max_scanline_crossings);

/// The glyph-fill instantiation, sized by the derived budgets above so
/// any outline the font registration gate admits rasterizes (~508 KiB —
/// callers keep one per thread on the heap, never on the stack; see
/// `fillGlyphPath`).
pub const GlyphRasterizer = RasterizerType(max_glyph_fill_edges, max_glyph_scanline_crossings);

const Crossing = struct {
    x: f32,
    dir: f32,
};

fn sortCrossings(crossings: []Crossing) void {
    var i: usize = 1;
    while (i < crossings.len) : (i += 1) {
        const value = crossings[i];
        var j = i;
        while (j > 0 and crossings[j - 1].x > value.x) : (j -= 1) {
            crossings[j] = crossings[j - 1];
        }
        crossings[j] = value;
    }
}

fn accumulateSpan(row: []f32, x_origin: f32, span_start: f32, span_end: f32, weight: f32) void {
    const width_f = @as(f32, @floatFromInt(row.len));
    const a = std.math.clamp(span_start - x_origin, 0, width_f);
    const b = std.math.clamp(span_end - x_origin, 0, width_f);
    if (b <= a) return;
    var px: usize = @intFromFloat(@floor(a));
    while (px < row.len) : (px += 1) {
        const left = @max(a, @as(f32, @floatFromInt(px)));
        const right = @min(b, @as(f32, @floatFromInt(px + 1)));
        if (right <= left) break;
        row[px] += (right - left) * weight;
    }
}

fn floorI(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@floor(value));
}

fn ceilI(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@ceil(value));
}

// ---------------------------------------------------------------------------
// Fill
// ---------------------------------------------------------------------------

/// Rasterize a filled path (subpaths implicitly closed) with the given
/// fill rule, calling `sink.pixel(x, y, coverage)` per covered pixel.
pub fn fillPath(
    elements: []const PathElement,
    transform: Affine,
    rule: FillRule,
    tolerance: f32,
    clip: ClipRect,
    sink: anytype,
) Error!void {
    var raster: Rasterizer = .{};
    try accumulateFillEdges(&raster, elements, transform, tolerance);
    try raster.sweep(rule, clip, sink);
}

/// Rasterize one glyph outline's fill through the derived glyph budgets
/// (see their derivation above): flattening clamps at
/// `max_glyph_curve_segments` and the edge/crossing capacities cover the
/// densest outline the font registration gate admits, so a
/// budget-admitted glyph NEVER fails with `VectorPathTooComplex` — the
/// registration promise ("a registered face always resolves at render
/// time") holds at the raster layer too. `raster` is caller-owned
/// storage (~508 KiB: keep one per thread on the heap, e.g. behind
/// `canvas.lazy_tls`, never on the stack); it is reset here, so it needs
/// no initialization beyond existing.
pub fn fillGlyphPath(
    raster: *GlyphRasterizer,
    elements: []const PathElement,
    transform: Affine,
    rule: FillRule,
    tolerance: f32,
    clip: ClipRect,
    sink: anytype,
) Error!void {
    raster.resetEdges();
    var edge_sink = FillEdgeSink(GlyphRasterizer){ .raster = raster };
    try walkPath(elements, transform, tolerance, max_glyph_curve_segments, &edge_sink);
    try raster.sweep(rule, clip, sink);
}

/// Accumulate a filled path's edges into an existing rasterizer (lets a
/// caller union several paths — e.g. all glyph contours of one text run —
/// before one sweep).
pub fn accumulateFillEdges(
    raster: *Rasterizer,
    elements: []const PathElement,
    transform: Affine,
    tolerance: f32,
) Error!void {
    var sink = FillEdgeSink(Rasterizer){ .raster = raster };
    try walkPath(elements, transform, tolerance, max_curve_segments, &sink);
}

fn FillEdgeSink(comptime Raster: type) type {
    return struct {
        raster: *Raster,
        start: PointF = PointF.zero(),
        current: PointF = PointF.zero(),

        const Self = @This();

        fn subpathBegin(self: *Self, point: PointF) Error!void {
            self.start = point;
            self.current = point;
        }

        fn subpathPoint(self: *Self, point: PointF) Error!void {
            try self.raster.addEdge(self.current, point);
            self.current = point;
        }

        fn subpathEnd(self: *Self, closed: bool) Error!void {
            _ = closed;
            // Fill semantics always close the contour.
            try self.raster.addEdge(self.current, self.start);
        }
    };
}

// ---------------------------------------------------------------------------
// Stroke
// ---------------------------------------------------------------------------

/// Rasterize a stroked path: flatten, convert to an outline (segment
/// quads + join and cap pieces, all consistently oriented), and fill the
/// union with the nonzero rule. `style.width` is in device pixels.
pub fn strokePath(
    elements: []const PathElement,
    transform: Affine,
    style: StrokeStyle,
    tolerance: f32,
    clip: ClipRect,
    sink: anytype,
) Error!void {
    if (!(style.width > 0)) return;
    var raster: Rasterizer = .{};
    try accumulateStrokeEdges(&raster, elements, transform, style, tolerance);
    try raster.sweep(.nonzero, clip, sink);
}

/// Accumulate a stroked path's outline edges into an existing rasterizer.
pub fn accumulateStrokeEdges(
    raster: *Rasterizer,
    elements: []const PathElement,
    transform: Affine,
    style: StrokeStyle,
    tolerance: f32,
) Error!void {
    if (!(style.width > 0)) return;
    var sink = StrokeSink{
        .raster = raster,
        .half_width = style.width * 0.5,
        .style = style,
        .tolerance = @max(0.01, tolerance),
    };
    try walkPath(elements, transform, tolerance, max_curve_segments, &sink);
}

const StrokeSink = struct {
    raster: *Rasterizer,
    half_width: f32,
    style: StrokeStyle,
    tolerance: f32,
    points: [max_stroke_subpath_points]PointF = undefined,
    count: usize = 0,

    fn subpathBegin(self: *StrokeSink, point: PointF) Error!void {
        self.count = 0;
        self.points[0] = point;
        self.count = 1;
    }

    fn subpathPoint(self: *StrokeSink, point: PointF) Error!void {
        const last = self.points[self.count - 1];
        const dx = point.x - last.x;
        const dy = point.y - last.y;
        if (dx * dx + dy * dy <= 0.000000000001) return;
        if (self.count >= max_stroke_subpath_points) return error.VectorPathTooComplex;
        self.points[self.count] = point;
        self.count += 1;
    }

    fn subpathEnd(self: *StrokeSink, closed: bool) Error!void {
        var pts = self.points[0..self.count];
        var is_closed = closed;
        if (is_closed and pts.len >= 2) {
            const first = pts[0];
            const last = pts[pts.len - 1];
            const dx = first.x - last.x;
            const dy = first.y - last.y;
            if (dx * dx + dy * dy <= 0.000000000001) {
                pts = pts[0 .. pts.len - 1];
            }
        }
        if (pts.len < 2) is_closed = false;
        try strokePolyline(self.raster, pts, is_closed, self.half_width, self.style, self.tolerance);
        self.count = 0;
    }
};

fn strokePolyline(
    raster: *Rasterizer,
    points: []const PointF,
    closed: bool,
    half_width: f32,
    style: StrokeStyle,
    tolerance: f32,
) Error!void {
    if (points.len == 0) return;
    if (points.len == 1) {
        // A degenerate subpath: round caps render a dot, butt caps
        // nothing (matching SVG stroke semantics).
        if (style.cap == .round) try emitDisc(raster, points[0], half_width, tolerance);
        return;
    }

    const segment_count = if (closed) points.len else points.len - 1;
    var index: usize = 0;
    while (index < segment_count) : (index += 1) {
        const a = points[index];
        const b = points[(index + 1) % points.len];
        try emitSegmentQuad(raster, a, b, half_width);
    }

    if (closed) {
        index = 0;
        while (index < points.len) : (index += 1) {
            const prev = points[(index + points.len - 1) % points.len];
            const vertex = points[index];
            const next = points[(index + 1) % points.len];
            try emitJoin(raster, prev, vertex, next, half_width, style, tolerance);
        }
    } else {
        index = 1;
        while (index + 1 <= points.len - 1) : (index += 1) {
            try emitJoin(raster, points[index - 1], points[index], points[index + 1], half_width, style, tolerance);
        }
        if (style.cap == .round) {
            try emitDisc(raster, points[0], half_width, tolerance);
            try emitDisc(raster, points[points.len - 1], half_width, tolerance);
        }
    }
}

fn emitSegmentQuad(raster: *Rasterizer, a: PointF, b: PointF, half_width: f32) Error!void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.000001) return;
    const nx = dy / len * half_width;
    const ny = -dx / len * half_width;
    const quad = [4]PointF{
        PointF.init(a.x + nx, a.y + ny),
        PointF.init(b.x + nx, b.y + ny),
        PointF.init(b.x - nx, b.y - ny),
        PointF.init(a.x - nx, a.y - ny),
    };
    try raster.addPolygon(&quad);
}

fn emitJoin(
    raster: *Rasterizer,
    prev: PointF,
    vertex: PointF,
    next: PointF,
    half_width: f32,
    style: StrokeStyle,
    tolerance: f32,
) Error!void {
    const din = normalizeOrNull(PointF.init(vertex.x - prev.x, vertex.y - prev.y)) orelse return;
    const dout = normalizeOrNull(PointF.init(next.x - vertex.x, next.y - vertex.y)) orelse return;
    const cross_z = din.x * dout.y - din.y * dout.x;
    const dot = din.x * dout.x + din.y * dout.y;

    // Nearly straight: the segment quads already cover the wedge to
    // within tolerance, so skip the join piece (keeps dense flattened
    // curves cheap and the edge budget bounded).
    if (dot > 0 and half_width * (1 - dot) < tolerance * 0.25) return;

    switch (style.join) {
        .round => try emitDisc(raster, vertex, half_width, tolerance),
        .miter => {
            if (@abs(cross_z) <= 0.000001) return;
            // Outer side: opposite the turn direction. Left normal of a
            // direction d (y-down) is (d.y, -d.x).
            const sign: f32 = if (cross_z > 0) 1 else -1;
            const na = PointF.init(din.y * sign * half_width, -din.x * sign * half_width);
            const nb = PointF.init(dout.y * sign * half_width, -dout.x * sign * half_width);
            const a = PointF.init(vertex.x + na.x, vertex.y + na.y);
            const b = PointF.init(vertex.x + nb.x, vertex.y + nb.y);
            const mid = normalizeOrNull(PointF.init(na.x + nb.x, na.y + nb.y)) orelse return;
            const cos_half = (mid.x * na.x + mid.y * na.y) / half_width;
            if (cos_half <= 0.000001) return;
            const miter_ratio = 1 / cos_half;
            if (miter_ratio <= @max(1, style.miter_limit)) {
                const miter_len = half_width * miter_ratio;
                const tip = PointF.init(vertex.x + mid.x * miter_len, vertex.y + mid.y * miter_len);
                const wedge = [4]PointF{ vertex, a, tip, b };
                try raster.addPolygon(&wedge);
            } else {
                const bevel = [3]PointF{ vertex, a, b };
                try raster.addPolygon(&bevel);
            }
        },
    }
}

/// A full disc (round cap / round join) as four kappa-cubic quarter arcs
/// flattened at `tolerance`. Overlap with segment quads is harmless: all
/// pieces share one orientation under the nonzero rule.
fn emitDisc(raster: *Rasterizer, center: PointF, radius: f32, tolerance: f32) Error!void {
    if (radius <= 0) return;
    var points: [max_piece_points]PointF = undefined;
    var count: usize = 0;
    const r = radius;
    const k = circle_kappa * r;
    const cx = center.x;
    const cy = center.y;
    const anchors = [5]PointF{
        PointF.init(cx + r, cy),
        PointF.init(cx, cy + r),
        PointF.init(cx - r, cy),
        PointF.init(cx, cy - r),
        PointF.init(cx + r, cy),
    };
    const controls = [4][2]PointF{
        .{ PointF.init(cx + r, cy + k), PointF.init(cx + k, cy + r) },
        .{ PointF.init(cx - k, cy + r), PointF.init(cx - r, cy + k) },
        .{ PointF.init(cx - r, cy - k), PointF.init(cx - k, cy - r) },
        .{ PointF.init(cx + k, cy - r), PointF.init(cx + r, cy - k) },
    };
    points[count] = anchors[0];
    count += 1;
    var quarter: usize = 0;
    while (quarter < 4) : (quarter += 1) {
        const p0 = anchors[quarter];
        const c1 = controls[quarter][0];
        const c2 = controls[quarter][1];
        const p3 = anchors[quarter + 1];
        const segments = cubicSegmentCount(p0, c1, c2, p3, tolerance);
        var index: usize = 1;
        while (index <= segments) : (index += 1) {
            const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
            if (count >= max_piece_points) return error.VectorPathTooComplex;
            points[count] = cubicPoint(p0, c1, c2, p3, t);
            count += 1;
        }
    }
    // The final point equals the first; addPolygon closes the ring, so
    // drop it to avoid a zero-length edge.
    if (count > 1) count -= 1;
    try raster.addPolygon(points[0..count]);
}
