const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_atlas = @import("text_atlas.zig");
const text_metrics = @import("text_metrics.zig");

const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Color = drawing_model.Color;
pub const Glyph = text_atlas.Glyph;

pub const DrawText = struct {
    id: ObjectId = 0,
    font_id: FontId = 0,
    size: f32,
    origin: geometry.PointF,
    color: Color,
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
    /// Process-local measurement context used for host-aware ink bounds.
    /// Excluded from equality, hashing, and serialization.
    measure: ?*const text_metrics.TextMeasureProvider = null,
    text_layout: ?TextLayoutOptions = null,
};

pub const TextWrap = enum {
    none,
    word,
    character,
};

/// What a single-line run (`wrap = .none`) does with text that does not
/// fit `max_width`. `.ellipsis` (the default) elides the tail and paints
/// a trailing U+2026 measured with the same seam the line was measured
/// with, so the painted extent never exceeds the box. `.clip` paints the
/// full run and relies on the caller's clip — the deliberate hard-cut
/// for fixed-width cells whose content is sized by design. Wrapping
/// modes (`word`/`character`) never elide; an unbounded run
/// (`max_width <= 0`) has nothing to elide against.
pub const TextOverflow = enum {
    ellipsis,
    clip,
};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextLayoutOptions = struct {
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    /// Single-line overflow policy; only consulted when `wrap == .none`
    /// and `max_width > 0`. Trailing ellipsis is the default everywhere;
    /// horizontally scrolling consumers (text inputs) opt into `.clip`
    /// because their overflow is reachable, not lost.
    overflow: TextOverflow = .ellipsis,
    /// Optional injected measurement used for line breaking, caret, and
    /// hit-test geometry. Null falls back to the deterministic estimator.
    /// Deliberately excluded from equality, hashing, and serialization:
    /// it is process-local layout context, not drawn content.
    measure: ?*const text_metrics.TextMeasureProvider = null,
};

pub const TextLine = struct {
    text_start: usize = 0,
    text_len: usize = 0,
    glyph_start: usize = 0,
    glyph_len: usize = 0,
    bounds: geometry.RectF = .{},
    baseline: f32 = 0,
    /// Elision (`TextOverflow.ellipsis`): when set, painting inks only
    /// the first `elided_text_len` bytes (`elided_glyph_len` glyphs of a
    /// shaped run) followed by a trailing ellipsis, and `bounds` covers
    /// exactly that painted extent. `text_start`/`text_len` still cover
    /// the line's full logical range so selection, caret, and hit
    /// mapping keep addressing every byte — copy never loses the hidden
    /// tail. Null = the line fits; paint everything.
    elided_text_len: ?usize = null,
    elided_glyph_len: ?usize = null,
    /// Advance reserved (and painted) for the trailing ellipsis of an
    /// elided line, measured on the same seam as the line itself. Zero
    /// on an elided line means the box is narrower than the marker —
    /// paint nothing rather than overrun.
    ellipsis_advance: f32 = 0,

    /// Bytes of this line that painting inks (before the ellipsis).
    pub fn paintedTextLen(self: TextLine) usize {
        return self.elided_text_len orelse self.text_len;
    }

    /// Glyphs of this line that painting inks (before the ellipsis).
    pub fn paintedGlyphLen(self: TextLine) usize {
        return self.elided_glyph_len orelse self.glyph_len;
    }

    pub fn isElided(self: TextLine) bool {
        return self.elided_text_len != null or self.elided_glyph_len != null;
    }

    /// True when painting should ink the trailing ellipsis marker.
    pub fn hasEllipsis(self: TextLine) bool {
        return self.isElided() and self.ellipsis_advance > 0;
    }
};

pub const TextLayout = struct {
    lines: []const TextLine = &.{},
    bounds: ?geometry.RectF = null,

    pub fn lineCount(self: TextLayout) usize {
        return self.lines.len;
    }
};

pub const TextLayoutKey = struct {
    font_id: FontId = 0,
    size: f32 = 0,
    origin: geometry.PointF = .{},
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    overflow: TextOverflow = .ellipsis,
    text_len: usize = 0,
    glyph_count: usize = 0,
    fingerprint: u64 = 0,
};
