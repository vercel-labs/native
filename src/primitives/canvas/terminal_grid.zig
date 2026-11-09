//! The terminal grid: the `.terminal` widget's cell model and painter.
//!
//! The canvas owns the PIXELS of a terminal, never the emulator: a
//! `TerminalGrid` is a resolved snapshot of one emulator viewport —
//! per-cell code points, cluster bytes, and final colors — produced
//! outside this module (the runtime's terminal session adapter feeds a
//! live emulator; tests and the docs previews build snapshots by hand).
//! Keeping the snapshot emulator-free is what lets the widget render on
//! every canvas target: cell state arrives as plain data, and this
//! painter turns it into REAL text runs, geometric box drawing
//! (`terminal_box.zig`), the selection wash, the cursor, and the
//! scrollback indicator — damage kept row-shaped by stable command ids.
//!
//! Colors arrive RESOLVED. The producer owns the palette policy (the
//! theme-derived ANSI-16 story, exact 256-color and truecolor); the
//! painter draws the colors it is handed, so two producers with
//! different palette policies still paint through one code path.
//!
//! Budgets: painting degrades ROW-ATOMICALLY under three ceilings — the
//! display-list command budget, the text-byte store, and the
//! glyph-atlas proxy — so a pathological screen paints fewer complete
//! rows instead of failing the whole frame. Each ceiling's preflight
//! mirrors the paint loop's emissions exactly; counting bytes the loop
//! would suppress would silently blank every row after a paintable one.

const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");
const box = @import("terminal_box.zig");

/// Grid ceilings, derived from the per-view canvas budgets: the glyph
/// budget bounds how many cells can hold ink at once, and the command
/// budget bounds per-row style runs. A viewport is clamped to these
/// before it reaches an emulator, so a huge window degrades to a
/// bounded grid instead of a budget error.
pub const max_cols: usize = 320;
pub const max_rows: usize = 96;
pub const max_cells: usize = 7168;

/// Painter budgets when the grid rides the WIDGET tree, where it shares
/// the per-view stores with every other widget. The command reserve is
/// the tail held back from the display-list capacity for the widgets
/// emitted after the grid (a status bar, window chrome); the text
/// reserve holds back the same store their labels draw from; the glyph
/// budget mirrors the runtime's per-view glyph-atlas capacity minus a
/// chrome allowance (a lockstep test on the runtime side keeps the
/// mirror honest). A grid that would cross any of them degrades to
/// fewer complete rows instead of failing the frame.
pub const widget_command_reserve: usize = 256;
pub const widget_text_reserve: usize = 8192;
// Sized to hold ONE maximal filled-line chart series after the grid: a
// 256-point series strokes its polyline (256 elements) AND fills its
// area (the points plus closure vertices down to the baseline), so the
// reserve derives from the series ceiling with slack for the closure —
// a flat 512 fell three elements short of exactly that documented
// maximum.
pub const widget_path_reserve: usize = 2 * chart_ceiling + 16;
const chart_ceiling: usize = canvas.max_chart_points_per_series;
pub const widget_glyph_budget: usize = 8192 - 512;

/// One text run's staging capacity — shared by the paint loop's scratch
/// and the preflight's per-cell cap so measure and emission agree.
/// Sized to the WHOLE display-list text store, so the paint tier is
/// never the binding constraint on a grapheme cluster: any cluster the
/// producer hands over paints complete, and only a cluster the store
/// itself cannot hold skips — row-atomically, the preflight rule.
const text_scratch_bytes: usize = canvas.max_display_list_text_bytes;

/// Cell occupancy: a `.wide` cell paints a two-column cluster and the
/// following `.spacer` column carries no ink of its own (its background
/// is pre-resolved by the producer to extend the primary's, so a styled
/// wide character never paints over half its width).
pub const TerminalWide = enum(u2) { narrow, wide, spacer };

/// One resolved viewport cell. `cp == 0` paints no ink (an empty cell,
/// or one whose style suppressed it — the producer resolves invisible
/// styling to 0 so measure and paint cannot disagree). Box-drawing code
/// points render as GEOMETRY at exact cell bounds, never font glyphs,
/// so their `cluster` stays empty.
pub const TerminalCell = struct {
    /// Primary code point; 0 paints nothing.
    cp: u21 = 0,
    /// UTF-8 bytes of the full cluster (primary code point plus every
    /// combining mark), producer-owned for the snapshot's lifetime.
    /// Empty exactly when `cp` is 0 or names a box-drawing cell.
    cluster: []const u8 = "",
    fg: canvas.Color = canvas.Color.rgba(1, 1, 1, 1),
    /// Resolved cell background; null paints the grid background only.
    bg: ?canvas.Color = null,
    underline: bool = false,
    wide: TerminalWide = .narrow,
};

pub const TerminalRow = struct {
    cells: []const TerminalCell = &.{},
    /// Inclusive selected column range, viewport-resolved by the
    /// producer (the painter draws the wash; the selection MODEL stays
    /// with the emulator).
    selection: ?[2]u16 = null,
};

pub const TerminalCursorShape = enum { block, bar, underline };

pub const TerminalCursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    shape: TerminalCursorShape = .block,
};

pub const TerminalCellPos = struct { x: u16 = 0, y: u16 = 0 };

/// Scrollback indicator state: `offset` rows of content sit above the
/// viewport's first row, `len` rows are visible, `total` rows exist.
pub const TerminalScrollbar = struct {
    offset: u32 = 0,
    len: u32 = 0,
    total: u32 = 0,
};

/// One resolved emulator viewport, ready to paint. Produced outside the
/// canvas (the runtime session adapter, a test, a docs scene); every
/// slice is producer-owned and must outlive the build that references
/// it.
pub const TerminalGrid = struct {
    rows: []const TerminalRow = &.{},
    /// Resolved surface colors: the producer's palette policy applied
    /// (theme defaults, an application's OSC overrides, DECSCNM).
    background: canvas.Color,
    foreground: canvas.Color,
    cursor_color: canvas.Color,
    selection_color: canvas.Color,
    cursor: ?TerminalCursor = null,
    /// The session is live: the cursor paints filled; an ended session
    /// paints it hollow-dim, the honest at-rest state.
    running: bool = true,
    /// Keyboard-selection caret: while selection mode is armed the head
    /// cell paints a focus outline (the selection wash itself rides the
    /// rows' `selection` ranges).
    select_head: ?TerminalCellPos = null,
    scrollbar: TerminalScrollbar = .{},
    /// The viewport as PLAIN TEXT — the grid's accessibility surface (a
    /// terminal's semantic content is its text) and, through the widget
    /// text channel, the a11y-tree fingerprint's coverage of the
    /// viewport's CHARACTERS. It is text only: colors, styles, the
    /// cursor position, the selection, and the running state are NOT
    /// encoded here, so two viewports with identical characters but
    /// different colors or cursor cells hash alike. The producer that
    /// owns replay-grade determinism must fold those channels into its
    /// own checkpoint; this field is the text-coverage layer, not a
    /// whole-cell-state hash. Empty means "unknown", never "same as
    /// before".
    screen_text: []const u8 = "",
    /// The emulator-serialized pointer selection, ready for the
    /// platform clipboard. Empty means no copyable selection. This is
    /// deliberately separate from `screen_text`: terminal selections
    /// follow cell pins (including soft wraps and wide cells), so byte
    /// offsets into the accessibility string are not an honest
    /// selection model.
    selection_text: []const u8 = "",
    /// Whether the emulator currently owns a selection, including a
    /// whitespace-only range whose trimmed `selection_text` is empty.
    /// Pointer release uses this to distinguish select-drag from click.
    selection_active: bool = false,
};

/// The app-visible terminal view state: the payload `on-terminal`
/// delivers and the shape the `scrollback` attribute echoes back into
/// (the ScrollState source-wins precedent). Deliberately ONLY what the
/// app legitimately owns — the scrollback position it may set and the
/// layout-derived grid it may display; emulator internals (cell state,
/// modes, selection pins) stay framework-owned and never surface here.
pub const TerminalState = struct {
    /// Rows the viewport sits above the live screen; 0 is pinned to the
    /// bottom (the live view). Echo it into `scrollback` and the
    /// runtime-owned position survives rebuilds; move it model-side to
    /// scroll programmatically.
    scrollback: u32 = 0,
    /// Total rows of history above the live screen (the scrollback
    /// ceiling `scrollback` clamps against).
    history: u32 = 0,
    /// The live grid the layout derived, in cells — what the pty was
    /// last resized to.
    cols: u16 = 0,
    rows: u16 = 0,
};

/// Mono cell metrics at the terminal type size, derived from the active
/// tokens: one seam shared by the painter and the runtime's grid sizing
/// so the cells painted and the cols/rows pushed to the pty can never
/// disagree.
pub const TerminalCellMetrics = struct {
    width: f32,
    height: f32,
    font_size: f32,
};

/// Everything one paint needs beyond the grid.
pub const TerminalPaintOptions = struct {
    /// Grid origin and extent in canvas points (the text region).
    frame: geometry.RectF,
    tokens: canvas.DesignTokens,
    /// Whether this terminal owns keyboard focus. A live focused cursor
    /// paints solid; an unfocused cursor paints as a hollow outline, the
    /// conventional terminal-window focus cue. Defaults on for direct
    /// painter callers; the `.terminal` widget always supplies its live
    /// logical focus state.
    focused: bool = true,
    /// The rect the grid background fills — the widget's whole frame,
    /// so the inset text region sits on a full-bleed surface. Null
    /// fills `frame` (tests that paint the grid alone).
    background_frame: ?geometry.RectF = null,
    /// Namespace for the emitted command ids: stable per widget, so the
    /// retained renderer matches rows across rebuilds and damage stays
    /// row-shaped. Pass the widget id (or any per-grid-stable value).
    id_base: u64 = 0,
    /// Hard ceiling on display-list commands this paint may emit. A
    /// pathological screen (every cell a different style, so no run
    /// merges) can generate more commands than the budget; painting
    /// stops row-wise at the ceiling rather than overflowing the frame.
    /// 0 means unbounded (tests that size their own builder).
    command_budget: usize = 0,
    /// Display-list TEXT bytes to hold back from the grid for the other
    /// widgets in the same view (they draw their own glyphs into the
    /// SAME per-view text store): the grid degrades to fewer painted
    /// rows instead of pushing the combined display list over the
    /// runtime limit and failing the whole frame. 0 means the grid may
    /// use the whole store.
    text_reserve: usize = 0,
    /// Path elements to hold back from the grid for the widgets after
    /// it (a chart's polylines, the checkbox mark, the spinner arc all
    /// draw from the same per-view element store): the grid's
    /// rounded-corner rows degrade instead of starving them into
    /// ChartPathElementListFull. 0 means the grid may use the whole
    /// store.
    path_reserve: usize = 0,
    /// Ceiling on glyph-ATLAS ENTRIES the grid may claim in one paint
    /// (the runtime's per-view atlas capacity minus a reserve): every
    /// new distinct code point is charged at the atlas's subpixel
    /// variant multiplier (`atlas_variants_per_glyph`), since one
    /// scalar occupies up to four x-bucket entries across a row's
    /// columns. Painting stops row-atomically BEFORE the row whose new
    /// code points would cross it. 0 means unbounded.
    glyph_budget: usize = 0,
};

/// The painter's command-id base for a caller's `id_base` (typically a
/// widget id): the widget part-id convention scaled up. `widgetPartId`
/// reserves the low 4 bits for a widget's part slots (`id *% 16 + slot`,
/// slots < 16); the grid needs a larger slot space (rows x runs x
/// decorations), so it reserves the low 24 bits (`id *% 2^24 + offset`,
/// every painter offset < 2^24). The guarantee is EXACTLY the part-id
/// convention's: the wrapping multiply discards the id's top bits, so
/// two ids agreeing modulo 2^40 share a namespace (as two ids agreeing
/// modulo 2^60 share a `widgetPartId` namespace) — the framework's
/// accepted residual, unreachable for the structural-hash ids real
/// widgets carry and identical in kind to what every other widget's
/// commands already live with. Within one grid, and between grids whose
/// ids differ modulo 2^40, commands can never collide.
/// An id of 0 is the framework's ANONYMOUS convention (`widgetPartId`
/// returns 0 for it): the painter then emits EVERY command with id 0 —
/// no retained identity, no cross-widget collisions.
/// A caller that emits its OWN commands around the grid (a widget's
/// focus ring) must derive its ids from THIS base at an offset the
/// painter leaves free (see `reserved_id_offset`).
pub fn paintIdBase(id: u64) u64 {
    return id *% (1 << 24);
}

/// An id offset the painter never emits (its own commands stay within
/// `id_base + [0, 0x61_ffff]`): callers layering commands over the grid
/// claim ids at `paintIdBase(id) + reserved_id_offset + n` (n < 2^16,
/// keeping the whole namespace under the 2^24 stride).
pub const reserved_id_offset: u64 = 0x62_0000;

pub fn cellMetrics(tokens: canvas.DesignTokens) TerminalCellMetrics {
    if (tokens.terminal_paint_policy) |policy| return @import("terminal_paint_policy.zig").metrics(tokens, policy);
    return @import("terminal_grid_reference.zig").cellMetrics(tokens);
}

pub fn clampGrid(proposed_cols: usize, proposed_rows: usize) TerminalCellPos {
    return @import("terminal_grid_reference.zig").clampGrid(proposed_cols, proposed_rows);
}

pub fn clampGridWithPolicy(proposed_cols: usize, proposed_rows: usize, policy: ?*const fn ([]const u8, []u8) usize) TerminalCellPos {
    if (policy) |owner| return @import("terminal_paint_policy.zig").clampGrid(proposed_cols, proposed_rows, owner);
    return clampGrid(proposed_cols, proposed_rows);
}

pub fn paint(grid: TerminalGrid, builder: *canvas.Builder, options: TerminalPaintOptions) !void {
    if (options.tokens.terminal_paint_policy) |policy| return @import("terminal_paint_policy.zig").paint(grid, builder, options, policy);
    return @import("terminal_grid_reference.zig").paint(grid, builder, options);
}
