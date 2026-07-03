const canvas = @import("root.zig");
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

pub fn estimateTextAdvanceForBytes(font_id: FontId, bytes: []const u8, size: f32) f32 {
    if (bytes.len == 0) return 0;
    if (font_id == default_mono_font_id) return size * 0.6;
    const weight = sansVariantWidthFactor(font_id);
    if (bytes.len > 1) return size * 0.65 * weight;
    return size * geistSansAdvanceFactor(bytes[0]) * weight;
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

fn geistSansAdvanceFactor(byte: u8) f32 {
    return switch (byte) {
        ' ' => 0.25,
        '!' => 0.268,
        '"' => 0.408,
        '#' => 0.654,
        '$' => 0.647,
        '%' => 0.844,
        '&' => 0.718,
        '\'' => 0.213,
        '(' => 0.365,
        ')' => 0.365,
        '*' => 0.469,
        '+' => 0.633,
        ',' => 0.214,
        '-' => 0.424,
        '.' => 0.2,
        '/' => 0.458,
        '0' => 0.66,
        '1' => 0.348,
        '2' => 0.596,
        '3' => 0.622,
        '4' => 0.584,
        '5' => 0.602,
        '6' => 0.601,
        '7' => 0.553,
        '8' => 0.621,
        '9' => 0.601,
        ':' => 0.237,
        ';' => 0.237,
        '<' => 0.605,
        '=' => 0.606,
        '>' => 0.605,
        '?' => 0.498,
        '@' => 0.899,
        'A' => 0.668,
        'B' => 0.678,
        'C' => 0.7,
        'D' => 0.701,
        'E' => 0.602,
        'F' => 0.589,
        'G' => 0.707,
        'H' => 0.702,
        'I' => 0.269,
        'J' => 0.596,
        'K' => 0.651,
        'L' => 0.579,
        'M' => 0.876,
        'N' => 0.737,
        'O' => 0.74,
        'P' => 0.649,
        'Q' => 0.74,
        'R' => 0.67,
        'S' => 0.647,
        'T' => 0.578,
        'U' => 0.688,
        'V' => 0.668,
        'W' => 0.91,
        'X' => 0.628,
        'Y' => 0.628,
        'Z' => 0.542,
        '[' => 0.349,
        '\\' => 0.458,
        ']' => 0.349,
        '^' => 0.537,
        '_' => 0.562,
        '`' => 0.35,
        'a' => 0.574,
        'b' => 0.602,
        'c' => 0.551,
        'd' => 0.602,
        'e' => 0.567,
        'f' => 0.401,
        'g' => 0.601,
        'h' => 0.584,
        'i' => 0.252,
        'j' => 0.258,
        'k' => 0.594,
        'l' => 0.288,
        'm' => 0.879,
        'n' => 0.584,
        'o' => 0.578,
        'p' => 0.602,
        'q' => 0.602,
        'r' => 0.385,
        's' => 0.529,
        't' => 0.399,
        'u' => 0.586,
        'v' => 0.534,
        'w' => 0.817,
        'x' => 0.584,
        'y' => 0.535,
        'z' => 0.549,
        '{' => 0.365,
        '|' => 0.256,
        '}' => 0.365,
        '~' => 0.633,
        else => 0.58,
    };
}
