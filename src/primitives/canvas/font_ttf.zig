//! Bounded, std-only TrueType outline parser: `glyf`/`loca`/`cmap`
//! (format 4)/`hmtx` — exactly the tables the bundled Geist face uses.
//! It feeds glyph outlines (as move/line/quad/close verbs) into any
//! path sink (in practice `vector.PathBuilder`), so the reference
//! renderer can paint real text everywhere AppKit is not rasterizing —
//! screenshots, `render_pixels`, mobile embeds, headless frames.
//!
//! Deliberately NOT a full font stack: no hinting, no kerning, no
//! shaping, no CFF. The deterministic estimator (`text_metrics.zig`)
//! derives its advance table from this face's `cmap`/`hmtx`, so layout
//! measures with exactly the advances these outlines are inked at.
//! All parsing is bounds-checked against fixed budgets sized from the
//! bundled and registered-face fixtures (237 points / 26 contours per
//! simple glyph), and any glyph beyond the budget fails with a recoverable
//! error so callers can fall back to block glyphs.
//!
//! The bundled face is embedded at comptime and its table directory is
//! validated at comptime: a corrupt bundle is a compile error, and the
//! runtime path never re-validates table presence.

const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");

const PointF = geometry.PointF;
const Affine = drawing_model.Affine;

pub const Error = error{
    /// Structurally invalid or truncated font data.
    FontParseFailed,
    /// A glyph exceeds the fixed point/contour/depth budgets.
    FontGlyphTooComplex,
} || @import("vector.zig").Error;

pub const max_glyph_points: usize = 237;
pub const max_glyph_contours: usize = 26;
pub const max_composite_depth: usize = 4;
pub const max_composite_components: usize = 8;

/// The bundled Geist Regular face (OFL), embedded so the reference
/// renderer paints real text without any platform font machinery. It
/// serves the sans font ids (weight/italic span variants included) at
/// their estimator advances; additional faces can be bundled without
/// changing callers.
pub const geist_regular_bytes: []const u8 = @embedFile("fonts/Geist-Regular.ttf");

/// Comptime-validated view over the bundled face. Using a comptime
/// constant means table presence and offsets are proven at build time.
pub const geist_regular = Face.parse(geist_regular_bytes) catch @compileError("bundled Geist-Regular.ttf failed to parse");

/// The bundled Geist Mono Regular face (OFL, same family): mono runs
/// ink real fixed-pitch outlines. Before this face landed, mono font
/// ids borrowed the proportional sans outlines centered inside the
/// 0.6 em mono cell, which read as broken letterspacing at caption
/// sizes — wide caps (M, W: ~0.83 em) overflowed the cell into their
/// neighbors while narrow glyphs (I: ~0.27 em) floated in gulfs. Every
/// covered glyph in this face advances exactly 600/1000 units, the
/// same 0.6 em pitch the deterministic estimator has always charged
/// for mono runs, so text layout metrics are unchanged — only the ink.
pub const geist_mono_bytes: []const u8 = @embedFile("fonts/GeistMono-Regular.ttf");

/// Comptime-validated view over the bundled mono face.
pub const geist_mono = Face.parse(geist_mono_bytes) catch @compileError("bundled GeistMono-Regular.ttf failed to parse");

/// Offsets and metrics for one parsed TrueType face. Holds a slice of
/// the raw bytes; all glyph reads are bounds-checked at call time.
pub const Face = struct {
    bytes: []const u8,
    units_per_em: f32,
    long_loca: bool,
    num_glyphs: u16,
    num_h_metrics: u16,
    ascender: i16,
    descender: i16,
    cmap4_offset: usize,
    loca_offset: usize,
    loca_len: usize,
    glyf_offset: usize,
    glyf_len: usize,
    hmtx_offset: usize,
    hmtx_len: usize,

    pub fn parse(bytes: []const u8) Error!Face {
        const table_count = try readU16(bytes, 4);
        var head: ?Range = null;
        var maxp: ?Range = null;
        var cmap: ?Range = null;
        var loca: ?Range = null;
        var glyf: ?Range = null;
        var hmtx: ?Range = null;
        var hhea: ?Range = null;
        var index: usize = 0;
        while (index < table_count) : (index += 1) {
            const record = 12 + index * 16;
            const tag = try readBytes(bytes, record, 4);
            const offset = try readU32(bytes, record + 8);
            const length = try readU32(bytes, record + 12);
            if (offset + length > bytes.len) return error.FontParseFailed;
            const range = Range{ .offset = offset, .len = length };
            if (std.mem.eql(u8, tag, "head")) head = range;
            if (std.mem.eql(u8, tag, "maxp")) maxp = range;
            if (std.mem.eql(u8, tag, "cmap")) cmap = range;
            if (std.mem.eql(u8, tag, "loca")) loca = range;
            if (std.mem.eql(u8, tag, "glyf")) glyf = range;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = range;
            if (std.mem.eql(u8, tag, "hhea")) hhea = range;
        }
        const head_r = head orelse return error.FontParseFailed;
        const maxp_r = maxp orelse return error.FontParseFailed;
        const cmap_r = cmap orelse return error.FontParseFailed;
        const loca_r = loca orelse return error.FontParseFailed;
        const glyf_r = glyf orelse return error.FontParseFailed;
        const hmtx_r = hmtx orelse return error.FontParseFailed;
        const hhea_r = hhea orelse return error.FontParseFailed;

        const units_per_em = try readU16(bytes, head_r.offset + 18);
        if (units_per_em == 0) return error.FontParseFailed;
        const index_to_loc = try readI16(bytes, head_r.offset + 50);
        const num_glyphs = try readU16(bytes, maxp_r.offset + 4);
        const ascender = try readI16(bytes, hhea_r.offset + 4);
        const descender = try readI16(bytes, hhea_r.offset + 6);
        const num_h_metrics = try readU16(bytes, hhea_r.offset + 34);
        if (num_h_metrics == 0) return error.FontParseFailed;

        // Pick a format-4 unicode subtable (platform 0, or 3/1).
        const subtable_count = try readU16(bytes, cmap_r.offset + 2);
        var cmap4: ?usize = null;
        var sub: usize = 0;
        while (sub < subtable_count) : (sub += 1) {
            const record = cmap_r.offset + 4 + sub * 8;
            const platform = try readU16(bytes, record);
            const encoding = try readU16(bytes, record + 2);
            const sub_offset = cmap_r.offset + try readU32(bytes, record + 4);
            const format = try readU16(bytes, sub_offset);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (unicode and format == 4 and cmap4 == null) cmap4 = sub_offset;
        }
        const cmap4_offset = cmap4 orelse return error.FontParseFailed;

        return .{
            .bytes = bytes,
            .units_per_em = @floatFromInt(units_per_em),
            .long_loca = index_to_loc != 0,
            .num_glyphs = num_glyphs,
            .num_h_metrics = num_h_metrics,
            .ascender = ascender,
            .descender = descender,
            .cmap4_offset = cmap4_offset,
            .loca_offset = loca_r.offset,
            .loca_len = loca_r.len,
            .glyf_offset = glyf_r.offset,
            .glyf_len = glyf_r.len,
            .hmtx_offset = hmtx_r.offset,
            .hmtx_len = hmtx_r.len,
        };
    }

    /// Glyph index for a unicode codepoint via the format-4 subtable;
    /// 0 (`.notdef`) when unmapped (callers fall back to block glyphs).
    pub fn glyphIndex(self: *const Face, codepoint: u32) u16 {
        if (codepoint > 0xFFFF) return 0;
        const cp: u16 = @intCast(codepoint);
        const base = self.cmap4_offset;
        const seg_count_x2 = readU16(self.bytes, base + 6) catch return 0;
        const seg_count = seg_count_x2 / 2;
        if (seg_count == 0) return 0;
        const end_codes = base + 14;
        const start_codes = end_codes + seg_count_x2 + 2;
        const id_deltas = start_codes + seg_count_x2;
        const id_range_offsets = id_deltas + seg_count_x2;

        var segment: usize = 0;
        while (segment < seg_count) : (segment += 1) {
            const end_code = readU16(self.bytes, end_codes + segment * 2) catch return 0;
            if (cp > end_code) continue;
            const start_code = readU16(self.bytes, start_codes + segment * 2) catch return 0;
            if (cp < start_code) return 0;
            const id_delta = readU16(self.bytes, id_deltas + segment * 2) catch return 0;
            const range_offset = readU16(self.bytes, id_range_offsets + segment * 2) catch return 0;
            if (range_offset == 0) {
                return cp +% id_delta;
            }
            const glyph_at = id_range_offsets + segment * 2 + range_offset + (@as(usize, cp - start_code)) * 2;
            const glyph = readU16(self.bytes, glyph_at) catch return 0;
            if (glyph == 0) return 0;
            return glyph +% id_delta;
        }
        return 0;
    }

    /// Horizontal advance in font units.
    pub fn advance(self: *const Face, glyph: u16) f32 {
        const metric_index = @min(glyph, self.num_h_metrics - 1);
        const value = readU16(self.bytes, self.hmtx_offset + @as(usize, metric_index) * 4) catch return 0;
        return @floatFromInt(value);
    }

    /// Emit the glyph outline through `transform` into `sink`
    /// (`moveTo`/`lineTo`/`quadTo`/`close`). Coordinates handed to the
    /// transform are raw font units (y-up); bake the y-flip and em
    /// scaling into `transform`. Empty glyphs (spaces) emit nothing.
    pub fn glyphOutline(self: *const Face, glyph: u16, transform: Affine, sink: anytype) Error!void {
        try self.glyphOutlineInner(glyph, transform, sink, 0);
    }

    fn glyphOutlineInner(self: *const Face, glyph: u16, transform: Affine, sink: anytype, depth: usize) Error!void {
        if (depth > max_composite_depth) return error.FontGlyphTooComplex;
        if (glyph >= self.num_glyphs) return error.FontParseFailed;
        const range = try self.glyphRange(glyph);
        if (range.len == 0) return;
        const offset = self.glyf_offset + range.offset;
        const contour_count = try readI16(self.bytes, offset);
        if (contour_count >= 0) {
            try self.simpleOutline(offset, @intCast(contour_count), transform, sink);
        } else {
            try self.compositeOutline(offset, transform, sink, depth);
        }
    }

    fn glyphRange(self: *const Face, glyph: u16) Error!Range {
        const index: usize = glyph;
        if (self.long_loca) {
            const start = try readU32(self.bytes, self.loca_offset + index * 4);
            const end = try readU32(self.bytes, self.loca_offset + index * 4 + 4);
            if (end < start or end > self.glyf_len) return error.FontParseFailed;
            return .{ .offset = start, .len = end - start };
        }
        const start = 2 * @as(usize, try readU16(self.bytes, self.loca_offset + index * 2));
        const end = 2 * @as(usize, try readU16(self.bytes, self.loca_offset + index * 2 + 2));
        if (end < start or end > self.glyf_len) return error.FontParseFailed;
        return .{ .offset = start, .len = end - start };
    }

    fn simpleOutline(self: *const Face, glyph_offset: usize, contour_count: usize, transform: Affine, sink: anytype) Error!void {
        if (contour_count > max_glyph_contours) return error.FontGlyphTooComplex;
        var end_points: [max_glyph_contours]u16 = undefined;
        var cursor = glyph_offset + 10;
        var contour: usize = 0;
        var point_count: usize = 0;
        while (contour < contour_count) : (contour += 1) {
            const end_point = try readU16(self.bytes, cursor);
            end_points[contour] = end_point;
            point_count = @as(usize, end_point) + 1;
            cursor += 2;
        }
        if (point_count == 0) return;
        if (point_count > max_glyph_points) return error.FontGlyphTooComplex;

        const instruction_len = try readU16(self.bytes, cursor);
        cursor += 2 + @as(usize, instruction_len);

        // Flags (run-length encoded with REPEAT).
        var flags: [max_glyph_points]u8 = undefined;
        var flag_index: usize = 0;
        while (flag_index < point_count) {
            const flag = try readU8(self.bytes, cursor);
            cursor += 1;
            flags[flag_index] = flag;
            flag_index += 1;
            if (flag & 0x08 != 0) {
                var repeat = try readU8(self.bytes, cursor);
                cursor += 1;
                while (repeat > 0) : (repeat -= 1) {
                    if (flag_index >= point_count) return error.FontParseFailed;
                    flags[flag_index] = flag;
                    flag_index += 1;
                }
            }
        }

        // X coordinates (deltas; short/same-bit encoded), then Y.
        var xs: [max_glyph_points]f32 = undefined;
        var x_accum: i32 = 0;
        var point: usize = 0;
        while (point < point_count) : (point += 1) {
            const flag = flags[point];
            if (flag & 0x02 != 0) {
                const delta: i32 = try readU8(self.bytes, cursor);
                cursor += 1;
                x_accum += if (flag & 0x10 != 0) delta else -delta;
            } else if (flag & 0x10 == 0) {
                x_accum += try readI16(self.bytes, cursor);
                cursor += 2;
            }
            xs[point] = @floatFromInt(x_accum);
        }
        var ys: [max_glyph_points]f32 = undefined;
        var y_accum: i32 = 0;
        point = 0;
        while (point < point_count) : (point += 1) {
            const flag = flags[point];
            if (flag & 0x04 != 0) {
                const delta: i32 = try readU8(self.bytes, cursor);
                cursor += 1;
                y_accum += if (flag & 0x20 != 0) delta else -delta;
            } else if (flag & 0x20 == 0) {
                y_accum += try readI16(self.bytes, cursor);
                cursor += 2;
            }
            ys[point] = @floatFromInt(y_accum);
        }

        // Emit each contour with TrueType quadratic semantics: off-curve
        // runs imply on-curve midpoints.
        var start: usize = 0;
        contour = 0;
        while (contour < contour_count) : (contour += 1) {
            const end = @as(usize, end_points[contour]);
            if (end + 1 < start + 1) return error.FontParseFailed;
            try emitContour(transform, sink, flags[start .. end + 1], xs[start .. end + 1], ys[start .. end + 1]);
            start = end + 1;
        }
    }

    fn compositeOutline(self: *const Face, glyph_offset: usize, transform: Affine, sink: anytype, depth: usize) Error!void {
        var cursor = glyph_offset + 10;
        var component: usize = 0;
        while (component < max_composite_components) : (component += 1) {
            const flags = try readU16(self.bytes, cursor);
            const child: u16 = try readU16(self.bytes, cursor + 2);
            cursor += 4;

            // Only XY-offset placement is supported (point matching does
            // not occur in the bundled face).
            if (flags & 0x0002 == 0) return error.FontGlyphTooComplex;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 0x0001 != 0) {
                dx = @floatFromInt(try readI16(self.bytes, cursor));
                dy = @floatFromInt(try readI16(self.bytes, cursor + 2));
                cursor += 4;
            } else {
                dx = @floatFromInt(try readI8(self.bytes, cursor));
                dy = @floatFromInt(try readI8(self.bytes, cursor + 1));
                cursor += 2;
            }

            var a: f32 = 1;
            var b: f32 = 0;
            var c: f32 = 0;
            var d: f32 = 1;
            if (flags & 0x0008 != 0) {
                a = try readF2Dot14(self.bytes, cursor);
                d = a;
                cursor += 2;
            } else if (flags & 0x0040 != 0) {
                a = try readF2Dot14(self.bytes, cursor);
                d = try readF2Dot14(self.bytes, cursor + 2);
                cursor += 4;
            } else if (flags & 0x0080 != 0) {
                a = try readF2Dot14(self.bytes, cursor);
                b = try readF2Dot14(self.bytes, cursor + 2);
                c = try readF2Dot14(self.bytes, cursor + 4);
                d = try readF2Dot14(self.bytes, cursor + 6);
                cursor += 8;
            }

            const child_transform = transform.multiply(.{ .a = a, .b = b, .c = c, .d = d, .tx = dx, .ty = dy });
            try self.glyphOutlineInner(child, child_transform, sink, depth + 1);

            if (flags & 0x0020 == 0) return;
        }
        return error.FontGlyphTooComplex;
    }
};

fn emitContour(transform: Affine, sink: anytype, flags: []const u8, xs: []const f32, ys: []const f32) Error!void {
    const count = flags.len;
    if (count == 0) return;

    const onCurve = struct {
        fn check(flag: u8) bool {
            return flag & 0x01 != 0;
        }
    }.check;

    // Find a starting on-curve point; if every point is off-curve, start
    // from the implied midpoint of the last and first points.
    var start_index: ?usize = null;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (onCurve(flags[index])) {
            start_index = index;
            break;
        }
    }

    var start_point: PointF = undefined;
    if (start_index) |si| {
        start_point = PointF.init(xs[si], ys[si]);
    } else {
        start_point = PointF.init((xs[count - 1] + xs[0]) * 0.5, (ys[count - 1] + ys[0]) * 0.5);
    }
    try sink.moveTo(transform.transformPoint(start_point));

    const first = if (start_index) |si| si + 1 else 0;
    var pending_control: ?PointF = null;
    var step: usize = 0;
    while (step < count) : (step += 1) {
        const i = (first + step) % count;
        const point = PointF.init(xs[i], ys[i]);
        if (onCurve(flags[i])) {
            if (pending_control) |control| {
                try sink.quadTo(transform.transformPoint(control), transform.transformPoint(point));
                pending_control = null;
            } else {
                try sink.lineTo(transform.transformPoint(point));
            }
        } else {
            if (pending_control) |control| {
                const implied = PointF.init((control.x + point.x) * 0.5, (control.y + point.y) * 0.5);
                try sink.quadTo(transform.transformPoint(control), transform.transformPoint(implied));
            }
            pending_control = point;
        }
    }
    // Close back to the start.
    if (pending_control) |control| {
        try sink.quadTo(transform.transformPoint(control), transform.transformPoint(start_point));
    }
    try sink.close();
}

/// Why `Face.parse` rejects `bytes`, as a self-contained teaching
/// sentence for registration-time diagnostics, or null when the bytes
/// parse cleanly (`parse` is the single authority; this never disagrees
/// with it). Kept out of `parse` itself so the render-path error stays a
/// cheap enum while registration (a startup, once-per-font event) can
/// afford the prose.
pub fn parseFailureReason(bytes: []const u8) ?[]const u8 {
    // `parse` is the single authority: bytes it accepts never get a
    // reason (a recognizable-but-parseable oddity like a swapped magic
    // is not a failure), and bytes it rejects always get one.
    _ = Face.parse(bytes) catch return diagnoseParseFailure(bytes);
    return null;
}

fn diagnoseParseFailure(bytes: []const u8) []const u8 {
    if (bytes.len < 12) return "file is truncated before the TrueType table directory (fewer than 12 bytes)";
    if (std.mem.eql(u8, bytes[0..4], "OTTO")) return "font carries CFF/PostScript outlines ('OTTO'); only TrueType 'glyf' outlines are supported - use a TrueType build of the family";
    if (std.mem.eql(u8, bytes[0..4], "wOFF") or std.mem.eql(u8, bytes[0..4], "wOF2")) return "font is WOFF/WOFF2-compressed; decompress to a raw .ttf before registering";
    if (std.mem.eql(u8, bytes[0..4], "ttcf")) return "font is a TrueType collection (.ttc); extract the single face to register";

    const table_count = readU16(bytes, 4) catch return "table directory is truncated";
    const required = [_]struct { tag: []const u8, teach: []const u8 }{
        .{ .tag = "head", .teach = "missing required table 'head' (font header)" },
        .{ .tag = "maxp", .teach = "missing required table 'maxp' (glyph counts)" },
        .{ .tag = "cmap", .teach = "missing required table 'cmap' (codepoint mapping)" },
        .{ .tag = "loca", .teach = "missing required table 'loca' (glyph offsets); CFF-only or bitmap fonts are not supported" },
        .{ .tag = "glyf", .teach = "missing required table 'glyf' (TrueType outlines); CFF-only or bitmap fonts are not supported" },
        .{ .tag = "hmtx", .teach = "missing required table 'hmtx' (horizontal advances)" },
        .{ .tag = "hhea", .teach = "missing required table 'hhea' (horizontal header)" },
    };
    var found = [_]bool{false} ** required.len;
    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const record = 12 + index * 16;
        const tag = readBytes(bytes, record, 4) catch return "table directory is truncated (a table record runs past the end of the file)";
        const offset = readU32(bytes, record + 8) catch return "table directory is truncated (a table record runs past the end of the file)";
        const length = readU32(bytes, record + 12) catch return "table directory is truncated (a table record runs past the end of the file)";
        if (offset + length > bytes.len) return "a table's declared range runs past the end of the file (truncated download?)";
        for (required, 0..) |entry, slot| {
            if (std.mem.eql(u8, tag, entry.tag)) found[slot] = true;
        }
    }
    for (required, 0..) |entry, slot| {
        if (!found[slot]) return entry.teach;
    }
    // Structure looks complete, so the failure is field-level.
    return "font tables are present but malformed: needs a nonzero units-per-em, at least one horizontal metric, and a Unicode format-4 'cmap' subtable";
}

const Range = struct {
    offset: usize,
    len: usize,
};

fn readBytes(bytes: []const u8, offset: usize, len: usize) Error![]const u8 {
    if (offset + len > bytes.len) return error.FontParseFailed;
    return bytes[offset .. offset + len];
}

fn readU8(bytes: []const u8, offset: usize) Error!u8 {
    if (offset >= bytes.len) return error.FontParseFailed;
    return bytes[offset];
}

fn readI8(bytes: []const u8, offset: usize) Error!i8 {
    return @bitCast(try readU8(bytes, offset));
}

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return error.FontParseFailed;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return error.FontParseFailed;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn readF2Dot14(bytes: []const u8, offset: usize) Error!f32 {
    const raw = try readI16(bytes, offset);
    return @as(f32, @floatFromInt(raw)) / 16384.0;
}
