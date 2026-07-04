//! Std-only coverage lookup against the bundled face's cmap.
//!
//! A codepoint outside `Geist-Regular.ttf`'s character map renders as a
//! tofu box everywhere the bundled outlines are the only glyph source —
//! the reference renderer (`automate screenshot`), mobile embeds, and
//! any provider-less measurement path. This module answers exactly one
//! question — "can the bundled face draw this codepoint?" — with no
//! canvas/geometry dependencies, so the markup validator (which doubles
//! as the LSP's module root and must stay std-only) and both markup
//! engines can share it, and the compiled engine can evaluate it at
//! comptime.
//!
//! Deliberately NOT part of `font_ttf.zig`: that file owns outlines and
//! metrics and imports the vector core; this one reads the same
//! embedded bytes but only walks the format-4 cmap segments, mirroring
//! `font_ttf.Face.glyphIndex` (a lockstep test in `font_ttf_tests.zig`
//! keeps the two answering identically).

const std = @import("std");

pub const face_name = "Geist Regular";

const font_bytes: []const u8 = @embedFile("fonts/Geist-Regular.ttf");

/// Offset of the format-4 unicode cmap subtable, resolved at comptime so
/// runtime lookups skip straight to segment scanning.
const cmap4_offset: usize = findCmap4(font_bytes) catch @compileError("bundled font: no format-4 unicode cmap");

/// True when the bundled face maps `codepoint` to a real glyph. Control
/// characters are layout, not glyphs — callers should skip them before
/// asking. Comptime-callable.
pub fn covers(codepoint: u21) bool {
    return glyphIndex(codepoint) != 0;
}

fn glyphIndex(codepoint: u21) u16 {
    if (codepoint > 0xFFFF) return 0;
    const cp: u16 = @intCast(codepoint);
    const base = cmap4_offset;
    const seg_count_x2 = readU16(font_bytes, base + 6) catch return 0;
    const seg_count = seg_count_x2 / 2;
    if (seg_count == 0) return 0;
    const end_codes = base + 14;
    const start_codes = end_codes + seg_count_x2 + 2;
    const id_deltas = start_codes + seg_count_x2;
    const id_range_offsets = id_deltas + seg_count_x2;

    var segment: usize = 0;
    while (segment < seg_count) : (segment += 1) {
        const end_code = readU16(font_bytes, end_codes + segment * 2) catch return 0;
        if (cp > end_code) continue;
        const start_code = readU16(font_bytes, start_codes + segment * 2) catch return 0;
        if (cp < start_code) return 0;
        const id_delta = readU16(font_bytes, id_deltas + segment * 2) catch return 0;
        const range_offset = readU16(font_bytes, id_range_offsets + segment * 2) catch return 0;
        if (range_offset == 0) {
            return cp +% id_delta;
        }
        const glyph_at = id_range_offsets + segment * 2 + range_offset + (@as(usize, cp - start_code)) * 2;
        const glyph = readU16(font_bytes, glyph_at) catch return 0;
        if (glyph == 0) return 0;
        return glyph +% id_delta;
    }
    return 0;
}

fn findCmap4(bytes: []const u8) !usize {
    const table_count = try readU16(bytes, 4);
    var cmap: ?usize = null;
    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const record = 12 + index * 16;
        const tag = try readBytes(bytes, record, 4);
        if (std.mem.eql(u8, tag, "cmap")) {
            cmap = try readU32(bytes, record + 8);
        }
    }
    const cmap_offset = cmap orelse return error.FontParseFailed;
    const subtable_count = try readU16(bytes, cmap_offset + 2);
    var sub: usize = 0;
    while (sub < subtable_count) : (sub += 1) {
        const record = cmap_offset + 4 + sub * 8;
        const platform = try readU16(bytes, record);
        const encoding = try readU16(bytes, record + 2);
        const sub_offset = cmap_offset + try readU32(bytes, record + 4);
        const format = try readU16(bytes, sub_offset);
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (unicode and format == 4) return sub_offset;
    }
    return error.FontParseFailed;
}

fn readBytes(bytes: []const u8, offset: usize, len: usize) ![]const u8 {
    if (offset + len > bytes.len) return error.FontParseFailed;
    return bytes[offset .. offset + len];
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    const slice = try readBytes(bytes, offset, 2);
    return std.mem.readInt(u16, slice[0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    const slice = try readBytes(bytes, offset, 4);
    return @intCast(std.mem.readInt(u32, slice[0..4], .big));
}

test "coverage answers for known covered and uncovered codepoints" {
    // Everything the showcase apps ship: ASCII, typographic punctuation,
    // Latin-1 letters, arrows.
    for ([_]u21{ 'A', 'z', '0', ' ', 0x2026, 0x00B7, 0x2014, 0x00B1, 0x00F7, 0x2192, 0x00E9, 0x201C, 0x2019, 0x2022 }) |cp| {
        try std.testing.expect(covers(cp));
    }
    // The recurring tofu class: ⌘, ⑂, ◑, ✓, CJK, astral plane.
    for ([_]u21{ 0x2318, 0x2442, 0x25D1, 0x2713, 0x4E2D, 0x1F600 }) |cp| {
        try std.testing.expect(!covers(cp));
    }
}
