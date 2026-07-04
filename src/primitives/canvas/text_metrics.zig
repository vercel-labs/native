const std = @import("std");
const canvas = @import("root.zig");
const font_ttf = @import("font_ttf.zig");
const text_atlas = @import("text_atlas.zig");
const text_interaction = @import("text_interaction.zig");

const FontId = canvas.FontId;
pub const Glyph = text_atlas.Glyph;
const default_sans_font_id = canvas.default_sans_font_id;
const default_mono_font_id = canvas.default_mono_font_id;
const utf8SequenceLength = text_interaction.utf8SequenceLength;

/// Injected text measurement. The engine stays pure: platforms provide a
/// context pointer plus a function that returns the width of a single-line
/// run of `text` at `size` for `font_id`, shaped with the same font
/// resolution the presentation layer draws with. When no provider is
/// installed every consumer falls back to the deterministic estimator
/// below, keeping the reference renderer and golden tests bit-identical.
pub const TextMeasureProvider = struct {
    context: ?*anyopaque = null,
    measure_fn: *const fn (context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8) f32,

    pub fn measureWidth(self: TextMeasureProvider, font_id: FontId, size: f32, text: []const u8) f32 {
        if (text.len == 0) return 0;
        const width = self.measure_fn(self.context, font_id, size, text);
        if (!(width >= 0) or !isFiniteF32(width)) return estimateTextWidthForFont(font_id, text, size);
        return width;
    }
};

/// Width of a text run: the provider when installed, the deterministic
/// estimator otherwise. This is the single measurement seam every layout
/// consumer (intrinsic widget sizing, line breaking, caret and selection
/// geometry) goes through. The provider is carried as a pointer so the
/// seam costs one word inside retained command storage; the pointee must
/// outlive layout state that carries it (runtimes own one for their whole
/// lifetime).
pub fn measureTextWidthForFont(provider: ?*const TextMeasureProvider, font_id: FontId, text: []const u8, size: f32) f32 {
    if (provider) |value| return value.measureWidth(font_id, size, text);
    return estimateTextWidthForFont(font_id, text, size);
}

/// Advance of the cluster `text[cluster_start..cluster_end]` within a line
/// starting at `line_start`. With a provider the advance is the difference
/// of two prefix widths so kerning against the preceding text is honored;
/// without one it is the estimator's per-cluster advance (bit-identical to
/// the historical behavior).
pub fn measureTextAdvance(
    provider: ?*const TextMeasureProvider,
    font_id: FontId,
    size: f32,
    text: []const u8,
    line_start: usize,
    cluster_start: usize,
    cluster_end: usize,
) f32 {
    if (provider) |value| {
        const with_cluster = value.measureWidth(font_id, size, text[line_start..cluster_end]);
        const without_cluster = value.measureWidth(font_id, size, text[line_start..cluster_start]);
        return @max(0, with_cluster - without_cluster);
    }
    return estimateTextAdvanceForBytes(font_id, text[cluster_start..cluster_end], size);
}

fn isFiniteF32(value: f32) bool {
    return value - value == 0;
}

pub fn estimateTextWidth(text: []const u8, size: f32) f32 {
    return estimateTextWidthForFont(default_sans_font_id, text, size);
}

pub fn estimateTextWidthForFont(font_id: FontId, text: []const u8, size: f32) f32 {
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = @min(text.len, index + utf8SequenceLength(text[index]));
        width += estimateTextAdvanceForBytes(font_id, text[index..next], size);
        index = next;
    }
    return width;
}

/// Design pitch for the reserved mono id. The repo bundles no mono
/// face, so this stays a constant rather than a derived metric: 0.6 em
/// is Geist Mono's actual advance (600/1000 units in every published
/// weight), so the estimator, the live Geist Mono provider path, and
/// SF Mono (0.6 em) all agree on the pitch.
const mono_advance_em: f32 = 0.6;

/// The bundled face's `.notdef` advance in em units (0.6 em in Geist).
/// This is the width the face itself declares for "I do not have this
/// glyph", so it is what layout charges for codepoints outside the
/// face's coverage (and for control or malformed bytes, which paint as
/// the same block fallback).
const notdef_advance_em: f32 = faceAdvanceEm(&font_ttf.geist_regular, 0);

/// Em-unit advances for the printable ASCII range, read from the
/// bundled face's `cmap`/`hmtx` at comptime. Layout therefore measures
/// with exactly the advances the reference renderer inks; a bundle
/// swap that drops ASCII coverage is a compile error.
const ascii_advance_em: [0x7F - 0x20]f32 = blk: {
    @setEvalBranchQuota(400_000);
    var table: [0x7F - 0x20]f32 = undefined;
    for (&table, 0x20..) |*slot, codepoint| {
        const glyph = font_ttf.geist_regular.glyphIndex(codepoint);
        if (glyph == 0) @compileError("bundled Geist face is missing printable ASCII coverage");
        slot.* = faceAdvanceEm(&font_ttf.geist_regular, glyph);
    }
    break :blk table;
};

fn faceAdvanceEm(face: *const font_ttf.Face, glyph: u16) f32 {
    return face.advance(glyph) / face.units_per_em;
}

pub fn estimateTextAdvanceForBytes(font_id: FontId, bytes: []const u8, size: f32) f32 {
    if (bytes.len == 0) return 0;
    if (font_id == default_mono_font_id) return size * mono_advance_em;
    const weight = sansVariantWidthFactor(font_id);
    return size * clusterAdvanceEm(bytes) * weight;
}

/// Em-unit advance of one UTF-8 cluster, derived from the bundled face:
/// a comptime `hmtx` table for printable ASCII, a runtime lookup against
/// the embedded face for every other covered codepoint (so the estimate
/// is definitionally in lockstep with the bytes the renderer inks), and
/// three documented fallbacks for what the face cannot answer — East
/// Asian wide/fullwidth codepoints charge a full em (the advance CJK
/// fallback fonts such as PingFang use, and the cell a fullwidth block
/// glyph should occupy), uncovered symbol/pictograph blocks charge
/// 0.8 em (the AppleSymbols cascade class real macOS text falls back
/// to), everything else charges the face's own `.notdef` advance.
fn clusterAdvanceEm(bytes: []const u8) f32 {
    if (bytes.len == 1) {
        const byte = bytes[0];
        if (byte >= 0x20 and byte < 0x7F) return ascii_advance_em[byte - 0x20];
        return notdef_advance_em;
    }
    // `utf8Decode` asserts (rather than errors) when the slice length
    // does not match the lead byte, so truncated clusters — possible at
    // the end of a run — take the notdef fallback explicitly.
    if (bytes.len != utf8SequenceLength(bytes[0])) return notdef_advance_em;
    const codepoint = std.unicode.utf8Decode(bytes) catch return notdef_advance_em;
    const face = &font_ttf.geist_regular;
    const glyph = face.glyphIndex(codepoint);
    if (glyph != 0) return faceAdvanceEm(face, glyph);
    if (isEastAsianWideCodepoint(codepoint)) return 1.0;
    if (isSymbolPictographCodepoint(codepoint)) return 0.8;
    return notdef_advance_em;
}

/// Symbol and pictograph blocks the bundled face does not cover but that
/// real dynamic content carries constantly (GitHub markdown ballot boxes
/// U+2610/U+2611, technical symbols, geometric shapes). Live macOS text
/// draws these through CoreText's cascade — AppleSymbols answers the
/// ballot boxes at 0.83 em behind the bundled sans — so charging the
/// face's 0.6 em `.notdef` advance under-reserved the cell every time the
/// deterministic estimator measured one. 0.8 em is the documented
/// approximation of that cascade class (measured: U+2610/U+2611 0.83 em
/// via AppleSymbols; only codepoints the face itself cannot answer reach
/// this class, so covered symbols like → keep their exact face advance).
fn isSymbolPictographCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        // Arrows through Misc Symbols and Arrows: arrows, math operators,
        // misc technical, control pictures, enclosed alphanumerics, box
        // drawing/blocks, geometric shapes, misc symbols, dingbats.
        0x2190...0x2BFF => true,
        else => false,
    };
}

/// East Asian wide / fullwidth blocks (Unicode EAW `W`/`F`, plus the
/// emoji planes, which render fullwidth everywhere). The bundled face
/// covers none of these, so they take the 1.0 em fallback instead of
/// the `.notdef` advance.
fn isEastAsianWideCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        0x1100...0x115F, // Hangul jamo
        0x2E80...0x303E, // CJK radicals, Kangxi, CJK symbols and punctuation
        0x3041...0x33FF, // Kana, CJK compatibility
        0x3400...0x4DBF, // CJK extension A
        0x4E00...0x9FFF, // CJK unified ideographs
        0xA000...0xA4CF, // Yi
        0xA960...0xA97F, // Hangul jamo extended-A
        0xAC00...0xD7A3, // Hangul syllables
        0xF900...0xFAFF, // CJK compatibility ideographs
        0xFE10...0xFE19, // Vertical forms
        0xFE30...0xFE6F, // CJK compatibility forms, small form variants
        0xFF00...0xFF60, // Fullwidth forms
        0xFFE0...0xFFE6, // Fullwidth signs
        0x1F300...0x1FAFF, // Emoji and symbol planes
        0x20000...0x3FFFD, // CJK extensions B and beyond
        => true,
        else => false,
    };
}

/// Width factor for the reserved sans variant ids (span weight/slant).
/// The regular id keeps factor 1 exactly, so existing single-style text
/// measurements — and every golden derived from them — are unchanged.
fn sansVariantWidthFactor(font_id: FontId) f32 {
    if (font_id == canvas.default_sans_medium_font_id) return 1.02;
    if (font_id == canvas.default_sans_bold_font_id) return 1.04;
    if (font_id == canvas.default_sans_bold_italic_font_id) return 1.04;
    return 1;
}

pub fn estimatedGlyphAdvance(glyph: Glyph, size: f32) f32 {
    return @max(size * 0.25, glyph.advance);
}

