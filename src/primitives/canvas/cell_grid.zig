//! The packed cell grid: one display-list command for a whole terminal
//! screen.
//!
//! Every other canvas command draws one shape. This one draws a
//! REGULAR LATTICE of them — a `cols` x `rows` array of cells, each
//! carrying its own background, foreground, grapheme cluster, and style
//! — and every renderer expands it itself. It exists because a terminal
//! is the one surface whose content scales with AREA rather than with
//! design: a screen styled per cell merges into nothing, and paying two
//! display-list commands per cell (one background run, one text run)
//! put a 200x60 truecolor viewport at ~24,000 commands against a
//! per-view budget of 4,096 — 9 rows of 60, the rest bare background.
//! No budget raise reaches that shape: one command slot costs ~700 B
//! across the view's retained mirrors, so 60,000 commands (300x100) is
//! 40 MiB per view before the pixels exist.
//!
//! A grid is ONE command and ONE retained key. Its cost is linear in
//! CELLS, at 20 bytes each: a 300x100 screen is 600 KB of cells and 1
//! command, and it either paints whole or reports that it could not.
//! The retained diff replaces it wholesale — a screen that changed is
//! one changed key, which is also what makes reflow safe (a row that
//! loses a run cannot leave an orphaned per-run command behind, because
//! there are no per-run commands).
//!
//! What the grid does NOT carry, deliberately:
//!   - Box-drawing cells. They render as exact GEOMETRY at cell bounds
//!     (`terminal_box.zig`) because glyphs fill the em box, not the
//!     padded cell, and borders drawn from them show seams. Those cells
//!     keep their background in the grid and paint no ink from it.
//!   - The cursor, the keyboard caret, the selection wash, the
//!     scrollback thumb. All are a handful of commands per frame and
//!     all composite OVER the grid.
//!
//! Colors arrive RESOLVED and 8-bit. A terminal's color model is
//! 8-bit-per-channel by construction (ANSI, 256-color, and truecolor
//! all land there), so storing cells at canvas `Color` precision would
//! quadruple the array to buy nothing. `CellColor` converts at the
//! edges.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_metrics = @import("text_metrics.zig");

const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Color = drawing_model.Color;

/// A cell's color at the terminal's own precision. Conversion is
/// round-trip stable for any color that entered as 8-bit — which is
/// every color a terminal produces.
pub const CellColor = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub fn fromColor(color: Color) CellColor {
        return .{
            .r = channelToU8(color.r),
            .g = channelToU8(color.g),
            .b = channelToU8(color.b),
            .a = channelToU8(color.a),
        };
    }

    pub fn toColor(self: CellColor) Color {
        return Color.rgba(
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        );
    }

    pub fn eql(self: CellColor, other: CellColor) bool {
        return self.r == other.r and self.g == other.g and
            self.b == other.b and self.a == other.a;
    }

    pub fn bits(self: CellColor) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }
};

fn channelToU8(value: f32) u8 {
    if (!(value > 0)) return 0;
    if (value >= 1) return 255;
    return @intFromFloat(@round(value * 255));
}

/// SGR underline styles. `none` means the cell carries no underline at
/// all — the flag and the style are one field, so a cell can never be
/// "underlined with no style" or "styled but not underlined".
pub const CellUnderline = enum(u3) {
    none,
    single,
    double,
    curly,
    dotted,
    dashed,
};

/// Cell occupancy. A `wide` cell paints a two-column cluster; the
/// `spacer` column after it carries the primary's background (the
/// producer resolves that) and no ink of its own.
pub const CellWidth = enum(u2) { narrow, wide, spacer };

/// Everything about a cell that is not a color or a cluster. Packed to
/// 16 bits so `Cell` stays 20 bytes.
pub const CellFlags = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    /// Whether `bg` paints. A cell without one shows the grid's surface
    /// background, which the painter already filled.
    has_background: bool = false,
    /// Whether `underline_color` paints. Without it an underline takes
    /// the cell's foreground, the SGR default.
    has_underline_color: bool = false,
    underline: CellUnderline = .none,
    width: CellWidth = .narrow,
    _reserved: u5 = 0,

    pub fn bits(self: CellFlags) u16 {
        return @bitCast(self);
    }

    pub fn fromBits(value: u16) CellFlags {
        return @bitCast(value);
    }
};

/// One resolved cell, 20 bytes.
///
/// The cluster lives in the grid's shared `text` blob rather than in
/// the cell, because clusters are variable-length and most cells hold
/// one ASCII byte: an inline buffer sized for the worst grapheme would
/// dwarf everything else here. `text_len == 0` paints no ink (an empty
/// cell, a spacer, or a box-drawing cell the geometry painter owns).
pub const Cell = extern struct {
    /// Byte offset of this cell's cluster in the grid's `text`.
    text_offset: u32 = 0,
    fg: CellColor = .{},
    bg: CellColor = .{},
    underline_color: CellColor = .{},
    /// `CellFlags` bits. Stored as an integer so the struct stays
    /// `extern` — a stable layout the wire format and the host
    /// renderers can read without re-deriving Zig's packing rules.
    flags: u16 = 0,
    /// Cluster byte length. A grapheme past 255 bytes is not a
    /// terminal cell; the painter drops the tail rather than grow every
    /// cell by three bytes.
    text_len: u8 = 0,
    _reserved: u8 = 0,

    pub fn style(self: Cell) CellFlags {
        return CellFlags.fromBits(self.flags);
    }

    pub fn cluster(self: Cell, text: []const u8) []const u8 {
        if (self.text_len == 0) return "";
        const start = self.text_offset;
        const end = start + self.text_len;
        if (end > text.len) return "";
        return text[start..end];
    }

    /// Whether this cell puts ink on the glass beyond its background.
    pub fn hasInk(self: Cell) bool {
        if (self.text_len != 0) return true;
        const flags = self.style();
        return flags.underline != .none or flags.strikethrough or flags.overline;
    }
};

comptime {
    // The whole point of the primitive: a screen costs cells, and a
    // cell costs 20 bytes. A regression here silently multiplies every
    // per-view budget that counts them.
    std.debug.assert(@sizeOf(Cell) == 20);
}

/// The command.
///
/// Geometry is implied rather than stored per cell: cell (x, y) covers
/// `origin + (x * cell_width, y * cell_height)` at `cell_width x
/// cell_height`. That is what makes the array packed — and it is also
/// the terminal's own model, so nothing is lost.
pub const CellGrid = struct {
    id: ObjectId = 0,
    /// Top-left of cell (0, 0) in canvas points.
    origin: geometry.PointF = .{},
    /// One cell's advance and one row's height, in canvas points.
    /// Deliberately not device-pixel quantized: the advance has to be
    /// the one the text renderer walks a run by, or glyphs drift out of
    /// their cells across a wide row.
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    /// Row-major, exactly `cols * rows` entries. A grid whose slice is
    /// shorter paints only the cells it has (renderers bound their
    /// loops by the slice), which keeps a malformed command from
    /// reading past its array.
    cells: []const Cell = &.{},
    /// Cluster bytes the cells index into.
    text: []const u8 = "",
    /// The REGULAR mono face. `bold_font_id` / `italic_font_id` /
    /// `bold_italic_font_id` are its companions; 0 means "not
    /// registered", and a cell asking for a variant that is not there
    /// falls back to synthesis (see `CellFace`).
    font_id: FontId = 0,
    bold_font_id: FontId = 0,
    italic_font_id: FontId = 0,
    bold_italic_font_id: FontId = 0,
    font_size: f32 = 0,
    /// Baseline offset from a row's top edge, in canvas points. The
    /// painter computes it once from the cell box and the font size so
    /// every renderer puts the baseline in the same place instead of
    /// re-deriving it from metrics it may not share.
    baseline: f32 = 0,
    /// Measurement seam, exactly as `DrawText.text_layout.measure`
    /// carries one: process-local layout context, excluded from
    /// equality, hashing, and serialization.
    measure: ?*const text_metrics.TextMeasureProvider = null,

    /// The face a cell's style asks for, and whether the renderer has
    /// to synthesize the difference.
    ///
    /// A terminal's bold and italic are SGR attributes, not layout: the
    /// cell they land in is fixed by its index either way. So face
    /// selection changes ink and never geometry — a bold row covers the
    /// same rects as a regular one, which is the invariant the whole
    /// packed-cell model rests on.
    pub fn face(self: CellGrid, flags: CellFlags) CellFace {
        const want_bold = flags.bold;
        const want_italic = flags.italic;
        if (want_bold and want_italic and self.bold_italic_font_id != 0) {
            return .{ .font_id = self.bold_italic_font_id };
        }
        if (want_bold and want_italic) {
            // A half-family (bold but no bold-italic) still beats
            // synthesizing both: take the real weight and shear it.
            if (self.bold_font_id != 0) return .{ .font_id = self.bold_font_id, .synthetic_italic = true };
            if (self.italic_font_id != 0) return .{ .font_id = self.italic_font_id, .synthetic_bold = true };
            return .{ .font_id = self.font_id, .synthetic_bold = true, .synthetic_italic = true };
        }
        if (want_bold) {
            if (self.bold_font_id != 0) return .{ .font_id = self.bold_font_id };
            return .{ .font_id = self.font_id, .synthetic_bold = true };
        }
        if (want_italic) {
            if (self.italic_font_id != 0) return .{ .font_id = self.italic_font_id };
            return .{ .font_id = self.font_id, .synthetic_italic = true };
        }
        return .{ .font_id = self.font_id };
    }

    pub fn cellCount(self: CellGrid) usize {
        return @as(usize, self.cols) * @as(usize, self.rows);
    }

    /// The cell at (x, y), or null when the command's slice does not
    /// reach it.
    pub fn at(self: CellGrid, x: usize, y: usize) ?Cell {
        if (x >= self.cols or y >= self.rows) return null;
        const index = y * @as(usize, self.cols) + x;
        if (index >= self.cells.len) return null;
        return self.cells[index];
    }

    /// The rect cell (x, y) covers.
    pub fn cellRect(self: CellGrid, x: usize, y: usize) geometry.RectF {
        return geometry.RectF.init(
            self.origin.x + @as(f32, @floatFromInt(x)) * self.cell_width,
            self.origin.y + @as(f32, @floatFromInt(y)) * self.cell_height,
            self.cell_width,
            self.cell_height,
        );
    }

    /// The whole lattice, which is also the command's raster extent:
    /// every cell's ink is clipped to its own cell by construction, so
    /// unlike a text run the grid can never ink past its declared
    /// bounds.
    pub fn bounds(self: CellGrid) geometry.RectF {
        return geometry.RectF.init(
            self.origin.x,
            self.origin.y,
            @as(f32, @floatFromInt(self.cols)) * self.cell_width,
            @as(f32, @floatFromInt(self.rows)) * self.cell_height,
        ).normalized();
    }
};

/// The face one cell draws with, plus what the renderer must fake.
///
/// Synthesis is a FALLBACK, never the plan: registering real companion
/// faces (`DesignTokens.typography.mono_bold_font_id` and friends)
/// switches these flags off and the ink comes from the type designer
/// instead of from arithmetic. Both renderers apply the same synthesis
/// rules (`CellSynthesis`) so a bold run is never bold on one path and
/// regular on the other — a mismatch between the oracle and the host is
/// worse than no bold at all.
pub const CellFace = struct {
    font_id: FontId,
    synthetic_bold: bool = false,
    synthetic_italic: bool = false,
};

/// The synthesis rules, in one place because two renderers implement
/// them and they have to agree.
pub const CellSynthesis = struct {
    /// Faux bold draws the glyph twice, the second pass offset in x.
    /// Deterministic, and it cannot change the advance: the pen is the
    /// cell, so the extra pass only thickens ink inside it.
    pub fn boldOffset(font_size: f32) f32 {
        return @max(1, @round(font_size / 14));
    }

    /// Faux italic shears about the BASELINE by this tangent (~11
    /// degrees, the conventional oblique). Sheared ink can overhang into
    /// the next cell, which is exactly why every renderer paints all
    /// backgrounds before any glyph.
    pub const italic_tangent: f32 = 0.2;
};

/// Decoration geometry, shared by every renderer so the reference
/// rasterizer and the host encoders cannot disagree about where an
/// underline sits.
///
/// Thicknesses scale with the font size and floor at one point, the
/// same rule the terminal box painter uses for its strokes.
pub const CellDecoration = struct {
    /// The rect an underline of `style` fills for a cell of `rect`.
    /// `double` returns the upper bar; `underlineSecondRect` returns
    /// the lower one.
    pub fn underlineRect(rect: geometry.RectF, font_size: f32) geometry.RectF {
        const thickness = strokeWidth(font_size);
        return geometry.RectF.init(rect.x, rect.y + rect.height - thickness * 2, rect.width, thickness);
    }

    pub fn underlineSecondRect(rect: geometry.RectF, font_size: f32) geometry.RectF {
        const thickness = strokeWidth(font_size);
        return geometry.RectF.init(rect.x, rect.y + rect.height - thickness * 4, rect.width, thickness);
    }

    pub fn strikethroughRect(rect: geometry.RectF, font_size: f32) geometry.RectF {
        const thickness = strokeWidth(font_size);
        return geometry.RectF.init(rect.x, rect.y + @round(rect.height * 0.55) - thickness, rect.width, thickness);
    }

    pub fn overlineRect(rect: geometry.RectF, font_size: f32) geometry.RectF {
        const thickness = strokeWidth(font_size);
        return geometry.RectF.init(rect.x, rect.y, rect.width, thickness);
    }

    pub fn strokeWidth(font_size: f32) f32 {
        return @max(1, @round(font_size / 12));
    }

    /// Dotted and dashed underlines paint as a run of segments inside
    /// the underline rect; curly paints as a sampled wave. Both are
    /// expressed as "the i-th segment rect" so every renderer walks the
    /// identical geometry. Returns null past the last segment.
    pub fn dashSegment(rect: geometry.RectF, style: CellUnderline, index: usize) ?geometry.RectF {
        const period: f32 = switch (style) {
            .dotted => @max(2, @round(rect.height * 2)),
            .dashed => @max(4, @round(rect.height * 6)),
            else => return if (index == 0) rect else null,
        };
        const on: f32 = switch (style) {
            .dotted => @max(1, @round(period * 0.5)),
            .dashed => @max(2, @round(period * 0.6)),
            else => period,
        };
        const start = @as(f32, @floatFromInt(index)) * period;
        if (start >= rect.width) return null;
        const width = @min(on, rect.width - start);
        return geometry.RectF.init(rect.x + start, rect.y, width, rect.height);
    }

    /// A curly underline's `index`-th sample rect: the wave is drawn as
    /// a column of one-point-wide ticks whose y follows a triangle, so
    /// a CPU rasterizer and a GPU encoder produce the same pixels
    /// without either owning a curve rasterizer.
    pub fn curlSegment(rect: geometry.RectF, font_size: f32, index: usize) ?geometry.RectF {
        const start = @as(f32, @floatFromInt(index));
        if (start >= rect.width) return null;
        const thickness = strokeWidth(font_size);
        const amplitude = thickness;
        const period = @max(4, @round(font_size / 3));
        const phase = @mod(start, period) / period;
        // Triangle wave in [0, 1]: up for the first half, down for the
        // second, so consecutive ticks trace a zigzag.
        const ramp = if (phase < 0.5) phase * 2 else (1 - phase) * 2;
        return geometry.RectF.init(
            rect.x + start,
            rect.y - amplitude + ramp * amplitude * 2,
            1,
            thickness,
        );
    }
};
