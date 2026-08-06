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
//! Budgets: painting degrades ROW-ATOMICALLY under the frame's shared
//! ceilings — the packed-cell store, the cluster-text store, the
//! display-list command budget (box geometry and selection washes), and
//! the glyph-atlas proxy — so a pathological screen paints fewer
//! complete rows instead of failing the whole frame. Degrading is never
//! SILENT: `paintReport` returns the rows that reached the list and the
//! store that stopped it, and every paint — including the
//! void-returning `paint` — records the same fact on the builder
//! (`canvas.DisplayListDegradation`) for the runtime and the host app to
//! surface. A user looking at a half-blank terminal must be able to
//! learn that a budget, not their program, ate the bottom of the screen.
//!
//! A screen is ONE COMMAND PER ROW. The painter emits packed
//! `cell_grid` commands (`cell_grid.zig`) carrying every cell's
//! background, cluster, foreground, and style, and every renderer
//! expands the lattice itself. What that replaced: one background
//! command per contiguous same-colour run plus one text command per
//! contiguous same-foreground run, which merged into nothing on a
//! styled screen and put a 200x60 truecolor viewport at ~24,000
//! commands against a budget of 4,096 — nine rows of sixty, the rest
//! bare background. Measured after: 60 of 60 rows, and a 300x100
//! truecolor screen (30,000 cells) in 103 commands. Cost is linear in
//! CELLS at 20 bytes each, and bounded in commands by `max_rows`.
//!
//! Why per ROW and not one command for the whole screen: a retained
//! command is the unit of CHANGE. One command per screen makes a
//! keystroke re-encode and re-upload every cell, which is the
//! full-surface cost the packed cell exists to remove, merely moved
//! from the CPU rasterizer to the wire. A row is the granularity a
//! terminal actually changes at, so per-row keys keep an incremental
//! present small without teaching every renderer and both hosts a
//! sub-command dirty protocol.
//!
//! Three things fall out of that shape, and all three were bugs before:
//!   - Reflow is safe. A row is one retained key replaced wholesale,
//!     so a row that loses a run cannot orphan a per-run command whose
//!     stale pixels then survive a resize.
//!   - Cell geometry is exact. A cell's position is its INDEX, so a
//!     combining mark or a wide cluster can no longer advance its
//!     neighbours out of their columns, whatever the face does.
//!   - Every SGR attribute has somewhere to live: bold, italic,
//!     strikethrough, overline, six underline styles, and an underline
//!     colour, none of which a `draw_text` run could carry.
//!
//! What still emits its own commands, deliberately: box-drawing cells
//! (exact GEOMETRY at cell bounds — glyphs fill the em box, not the
//! padded cell, and borders drawn from them show seams), the selection
//! wash, the cursor, the keyboard caret, and the scrollback thumb. All
//! composite OVER the lattice and all are a handful of commands.

const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");
const box = @import("terminal_box.zig");

/// Grid ceilings bound allocation and command-id geometry. Cell count is not a
/// glyph-atlas proxy: the atlas charges distinct glyph/subpixel keys, while a
/// terminal commonly repeats a small alphabet across tens of thousands of
/// cells. The painter's own distinct-glyph, text, path, and command preflights
/// remain the resource fences.
pub const max_cols: usize = 320;
pub const max_rows: usize = 96;
pub const max_cells: usize = max_cols * max_rows;

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
/// Packed cells held back for a SECOND terminal in the same view: a
/// split gives each pane half the store, which is exactly what two
/// 160x100 panes need out of the 32768-cell frame budget.
pub const widget_cell_reserve: usize = canvas.max_display_list_cells / 2;

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

/// SGR underline styles a cell can carry. Selected by
/// `TerminalCell.underline_style` and painted only when `underline` is
/// set, so the historical boolean keeps its exact meaning.
pub const TerminalUnderline = enum {
    single,
    double,
    curly,
    dotted,
    dashed,
};

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
    /// The remaining SGR attributes. They arrive resolved like the
    /// colours do and ride the packed cell grid to every renderer; a
    /// producer that does not track one simply leaves the default.
    /// `bold` and `italic` reach the cell but need registered companion
    /// faces to change the GLYPH — with a single mono face they are
    /// carried, not synthesised, which is the honest behaviour and what
    /// the docs already state about weight axes.
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    /// Which underline `underline` paints.
    underline_style: TerminalUnderline = .single,
    /// SGR 58 underline colour; null takes the cell foreground.
    underline_color: ?canvas.Color = null,
};

pub const TerminalRow = struct {
    cells: []const TerminalCell = &.{},
    /// Inclusive selected column range, viewport-resolved by the
    /// producer (the painter draws the wash; the selection MODEL stays
    /// with the emulator).
    selection: ?[2]u16 = null,
};

/// `block_hollow` is a SHAPE the emulator asked for, distinct from the
/// hollow outline an unfocused window paints: a focused terminal whose
/// program requested a hollow block gets one, and the focus-driven
/// outline stays a property of focus. Conflating them (the historical
/// behaviour) made "hollow" mean two different things at once.
pub const TerminalCursorShape = enum { block, block_hollow, bar, underline };

pub const TerminalCursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    shape: TerminalCursorShape = .block,
    /// The emulator asked the cursor to blink.
    ///
    /// The painter draws the cursor's visible pose and nothing else —
    /// blinking is TIME, and a painter has none. The runtime reads this
    /// off the focused terminal's grid and arms the same looping
    /// opacity animation a text caret uses, keyed on
    /// `cursorCommandId(widget_id)`. A renderer that ignores the
    /// animation still draws the cursor in the right place, so the
    /// degradation is a cursor that does not blink, never one that goes
    /// missing.
    blinking: bool = false,
    /// The cursor sits on a wide cell and covers two columns.
    wide: bool = false,
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

/// Glyphs in the advance probe. A row paints as MERGED text runs the
/// text layout advances itself, so the cell width has to be the layout's
/// own advance: one glyph's measured width is its box, which on a real
/// mono face sits inside the advance, and the difference compounds
/// across a run until the row's tail clips at the widget edge. Measuring
/// a run and dividing takes the advance the layout will actually use
/// (every mono cell the same), so column N lands where the painter's
/// backgrounds, cursor, and selection put it.
const advance_probe_len = 16;
const advance_probe = "M" ** advance_probe_len;

pub fn cellMetrics(tokens: canvas.DesignTokens) TerminalCellMetrics {
    const font_size = tokens.typography.label_size;
    const height = @round(font_size * 1.4);
    var width: f32 = @round(font_size * 0.6);
    const measured = canvas.measureTextWidthForFont(
        tokens.text_measure,
        tokens.typography.mono_font_id,
        advance_probe,
        font_size,
    );
    if (measured > 0) width = measured / advance_probe_len;
    // Deliberately NOT quantized to the device pixel grid: the cell
    // width has to be the advance the text renderer actually walks a
    // merged run by, and that advance is the face's, not a rounded one.
    // Rounding it — even to a whole device pixel — makes every glyph in
    // a run land a fraction past its cell, and by column 50 the drift is
    // visible against the cell backgrounds, cursor, and selection.
    return .{ .width = width, .height = height, .font_size = font_size };
}

/// Clamp a proposed grid to the allocation and command-id geometry bounds.
/// Painter resources are content-dependent and are fenced during paint; they
/// must not shrink the PTY to a fraction of its visible pane.
pub fn clampGrid(proposed_cols: usize, proposed_rows: usize) TerminalCellPos {
    return .{
        .x = @intCast(std.math.clamp(proposed_cols, 2, max_cols)),
        .y = @intCast(std.math.clamp(proposed_rows, 2, max_rows)),
    };
}

// ------------------------------------------------------------- painting

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
    /// Packed-grid CELLS to hold back for the widgets after this one
    /// (another terminal in a split, a code view). The grid degrades to
    /// fewer painted rows instead of starving them.
    cell_reserve: usize = 0,
};

/// What stopped a paint short of the grid's last row.
///
/// The four store values are BUDGET losses — content the frame could
/// not hold. `.viewport` is not a loss at all: rows starting below the
/// frame's bottom edge have nowhere to paint, which is what a viewport
/// taller than its widget honestly looks like. `.torn` is the
/// defensive case: a builder store hit its floor mid-row despite the
/// preflights, and the partial row was rolled back whole.
pub const TerminalPaintStop = enum {
    commands,
    /// The frame's packed-cell store. The terminal's own budget now: a
    /// screen costs cells, and this is the one that bounds how big a
    /// screen can be.
    cells,
    text_bytes,
    path_elements,
    glyphs,
    viewport,
    torn,

    /// Whether this stop means content was LOST to a budget (as opposed
    /// to a viewport that simply ends).
    pub fn isBudget(self: TerminalPaintStop) bool {
        return self != .viewport;
    }
};

/// What one paint actually put on the glass.
///
/// `rows_painted < rows_total` with a budget `stopped_by` is
/// TRUNCATION: the rows past `rows_painted` are not on the glass and
/// the surface below them is bare grid background. Callers surface it
/// (a status line, a log line, a smaller requested grid); the painter
/// additionally records budget stops on the builder, so callers of the
/// void-returning `paint` are never left guessing.
pub const TerminalPaintReport = struct {
    /// Rows the producer handed over.
    rows_total: usize = 0,
    /// Rows painted COMPLETE, counted from the top (the painter never
    /// skips a row and resumes: it stops).
    rows_painted: usize = 0,
    stopped_by: ?TerminalPaintStop = null,

    /// Content was lost to a budget (not merely clipped by the frame).
    pub fn truncated(self: TerminalPaintReport) bool {
        const stop = self.stopped_by orelse return false;
        return stop.isBudget();
    }

    fn store(stop: TerminalPaintStop) ?canvas.DisplayListStore {
        return switch (stop) {
            .commands, .torn => .commands,
            .cells => .cells,
            .text_bytes => .text_bytes,
            .path_elements => .path_elements,
            .glyphs => .glyphs,
            .viewport => null,
        };
    }
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

/// The command id the painter gives a grid's CURSOR.
///
/// Public because blinking is the runtime's job, not the painter's: the
/// painter draws the cursor's visible pose, and the runtime arms the
/// ping-pong opacity animation that makes it blink (the same one a text
/// caret uses). Both sides need the id, so it lives here rather than
/// being re-derived from the painter's internal offsets.
pub fn cursorCommandId(id: u64) u64 {
    if (id == 0) return 0;
    return paintIdBase(id) +% 0x61_0002;
}

/// The paint's command-id derivation: keyed grids take `base + offset`
/// (offsets < 2^24, disjoint per widget by the `paintIdBase` stride);
/// an anonymous grid (caller id 0) emits every command with id 0, the
/// `widgetPartId` convention for identity-less widgets.
const CommandIds = struct {
    base: u64,
    keyed: bool,

    fn at(self: CommandIds, offset: u64) u64 {
        return if (self.keyed) self.base +% offset else 0;
    }
};

/// Atlas entries one DISTINCT code point can occupy: the runtime atlas
/// keys on (font, glyph, size, subpixel_x, subpixel_y), and the
/// subpixel quantization has FOUR x buckets — a fractional cell width
/// walks the same scalar through all of them across a row's columns
/// (the grid's rows share one y bucket: row advance is the rounded
/// integral cell height). The glyph preflight charges every new code
/// point at this multiplier so a grid within its budget can never
/// undercount its own atlas usage 4x and fail the frame with
/// GlyphAtlasListFull.
const atlas_variants_per_glyph: usize = 4;

/// Distinct-code-point probe set backing `glyph_budget`: open-addressed,
/// power-of-two slots, zero meaning empty (a stored value is `cp + 1` so
/// U+0000 never aliases an empty slot). Sized at twice the runtime's
/// per-view atlas capacity so any honest budget stays under half load
/// and lookups stay O(1); budgets are clamped to half the slots so the
/// probe loop can never run against a full table.
const glyph_probe_slots: usize = 16384;

fn glyphProbeInsert(slots: *[glyph_probe_slots]u32, cp: u21) bool {
    const stored: u32 = @as(u32, cp) + 1;
    var index: usize = (stored *% 0x9E37_79B1) >> (32 - 14);
    while (true) {
        const entry = slots[index];
        if (entry == stored) return false;
        if (entry == 0) {
            slots[index] = stored;
            return true;
        }
        index = (index + 1) & (glyph_probe_slots - 1);
    }
}

/// Count the row's code points NOT yet in `seen`, inserting them —
/// mirroring the paint loop's emissions exactly (spacer cells and box
/// cells contribute nothing; a cluster's combining marks count like its
/// primary). Entries inserted by a row the budget then rejects stay in
/// the set harmlessly: painting stops at that row, so the set is never
/// consulted again.
fn rowNewGlyphs(row: TerminalRow, seen: *[glyph_probe_slots]u32) usize {
    var new_count: usize = 0;
    for (row.cells) |cell| {
        if (cell.wide == .spacer or cell.cp == 0) continue;
        if (box.isBoxDrawing(cell.cp)) continue;
        var iterator = std.unicode.Utf8Iterator{ .bytes = cell.cluster, .i = 0 };
        while (iterator.nextCodepoint()) |cp| {
            if (glyphProbeInsert(seen, cp)) new_count += 1;
        }
    }
    return new_count;
}

/// The bytes painting will actually EMIT for one cell — the preflight
/// (`rowTextBytes`) sums these against the text store, so this mirrors
/// the paint loop's suppressions exactly: spacer, empty, and box cells
/// paint no text.
fn cellTextBytes(cell: TerminalCell) usize {
    if (cell.wide == .spacer or cell.cp == 0) return 0;
    if (box.isBoxDrawing(cell.cp)) return 0;
    return cell.cluster.len;
}

fn rowTextBytes(row: TerminalRow) usize {
    var total: usize = 0;
    for (row.cells) |cell| total += cellTextBytes(cell);
    return total;
}

/// Rounded-corner code points that draw through `strokePath` and so
/// consume the builder's path-element store (three elements each). Every
/// other box glyph paints as `fillRect`s and consumes none.
fn cellPathElements(cell: TerminalCell) usize {
    if (cell.wide == .spacer or cell.cp == 0) return 0;
    return switch (cell.cp) {
        0x256D, 0x256E, 0x256F, 0x2570 => 3,
        else => 0,
    };
}

fn rowPathElements(row: TerminalRow) usize {
    var total: usize = 0;
    for (row.cells) |cell| total += cellPathElements(cell);
    return total;
}

/// Text bytes ALREADY in the display list — every `draw_text`, whether
/// its bytes are builder-owned (a chart's labels, this grid's own runs)
/// or referenced from view-owned memory (an earlier text widget). The
/// runtime's per-view text budget (`CanvasResourceCounts`, 32 KiB)
/// counts them all, so the grid must degrade against this total, not
/// against its builder-owned counter alone.
fn displayListTextBytes(list: canvas.DisplayList) usize {
    var total: usize = 0;
    for (list.commands) |command| {
        if (command == .draw_text) total += command.draw_text.text.len;
    }
    return total;
}

/// Path elements already in the display list — every `fill_path`/
/// `stroke_path`, including static (comptime) paths that bypass the
/// builder's element store (an icon's geometry). The runtime's per-view
/// path-element budget (2048) counts them all.
fn displayListPathElements(list: canvas.DisplayList) usize {
    var total: usize = 0;
    for (list.commands) |command| {
        total += switch (command) {
            .fill_path => |c| c.elements.len,
            .stroke_path => |c| c.elements.len,
            else => 0,
        };
    }
    return total;
}

fn multiCodepointCluster(cell: TerminalCell) bool {
    if (cell.cp == 0 or cell.cluster.len == 0) return false;
    const primary_len = std.unicode.utf8CodepointSequenceLength(cell.cp) catch 1;
    return cell.cluster.len > primary_len;
}

/// Exact upper bound on the commands emitted for one row.
///
/// Backgrounds and text runs cost NOTHING here any more: they are cells
/// in the row's slice of the packed grid, and the whole grid is one
/// command. What still emits per row is the ink the lattice cannot
/// express — box-drawing geometry at exact cell bounds — plus the
/// selection wash.
fn rowCommandCost(row: TerminalRow) usize {
    var total: usize = if (row.selection != null) 1 else 0;
    var i: usize = 0;
    while (i < row.cells.len) {
        const cell = row.cells[i];
        if (cell.wide == .spacer or cell.cp == 0 or !box.isBoxDrawing(cell.cp)) {
            i += 1;
            continue;
        }
        var span: usize = 1;
        if (box.mergesHorizontally(cell.cp)) {
            while (i + span < row.cells.len) : (span += 1) {
                const next = row.cells[i + span];
                if (next.cp != cell.cp or !colorEql(next.fg, cell.fg)) break;
            }
        }
        total += box.maxCommands(cell.cp);
        i += span;
    }
    return total;
}

fn colorEql(a: canvas.Color, b: canvas.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// Slots in the cluster intern table. Open-addressed, power of two,
/// zero meaning empty (a stored value is `offset + 1` so offset 0 never
/// aliases an empty slot). A screen's DISTINCT clusters are its
/// alphabet — hundreds, not tens of thousands — so 4096 slots keep the
/// table far under half load and lookups O(1); a screen that somehow
/// fills it simply stops interning and appends, which costs bytes, not
/// correctness.
const cluster_intern_slots: usize = 4096;

/// Intern `cluster` into `blob`, returning its offset. Repeat clusters
/// (every space, every `e`) resolve to the copy already there.
fn internCluster(
    cluster: []const u8,
    blob: *[text_scratch_bytes]u8,
    blob_len: *usize,
    slots: *[cluster_intern_slots]u32,
) ?u32 {
    if (cluster.len == 0) return null;
    var hash: u32 = 2166136261;
    for (cluster) |byte| hash = (hash ^ byte) *% 16777619;
    var index: usize = (hash *% 0x9E37_79B1) >> (32 - 12);
    var probes: usize = 0;
    while (probes < cluster_intern_slots) : (probes += 1) {
        const entry = slots[index];
        if (entry == 0) break;
        const start = entry - 1;
        const end = start + cluster.len;
        if (end <= blob_len.* and std.mem.eql(u8, blob[start..end], cluster)) return start;
        index = (index + 1) & (cluster_intern_slots - 1);
    }
    if (blob_len.* + cluster.len > blob.len) return null;
    const offset: u32 = @intCast(blob_len.*);
    @memcpy(blob[offset..][0..cluster.len], cluster);
    blob_len.* += cluster.len;
    if (probes < cluster_intern_slots) slots[index] = offset + 1;
    return offset;
}

/// Resolve one producer cell into its packed form. Box-drawing cells
/// keep their BACKGROUND here and contribute no cluster: their ink is
/// exact geometry the painter emits separately, and a glyph drawn in
/// their place would show seams between rows.
fn packCell(
    cell: TerminalCell,
    blob: *[text_scratch_bytes]u8,
    blob_len: *usize,
    slots: *[cluster_intern_slots]u32,
) canvas.Cell {
    var flags = canvas.CellFlags{
        .bold = cell.bold,
        .italic = cell.italic,
        .strikethrough = cell.strikethrough,
        .overline = cell.overline,
        .width = switch (cell.wide) {
            .narrow => .narrow,
            .wide => .wide,
            .spacer => .spacer,
        },
    };
    if (cell.underline) {
        flags.underline = switch (cell.underline_style) {
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
    }
    var packed_cell = canvas.Cell{
        .fg = canvas.CellColor.fromColor(cell.fg),
    };
    if (cell.bg) |color| {
        packed_cell.bg = canvas.CellColor.fromColor(color);
        flags.has_background = true;
    }
    if (cell.underline_color) |color| {
        packed_cell.underline_color = canvas.CellColor.fromColor(color);
        flags.has_underline_color = true;
    }
    const inks = cell.cp != 0 and cell.wide != .spacer and !box.isBoxDrawing(cell.cp);
    if (inks and cell.cluster.len > 0 and cell.cluster.len <= 255) {
        if (internCluster(cell.cluster, blob, blob_len, slots)) |offset| {
            packed_cell.text_offset = offset;
            packed_cell.text_len = @intCast(cell.cluster.len);
        }
    }
    packed_cell.flags = flags.bits();
    return packed_cell;
}

/// Fill one lattice row. Columns past the producer's row are left as
/// default cells — no background, no ink — which is exactly what a
/// short row looks like.
fn fillGridRow(
    row: TerminalRow,
    out: []canvas.Cell,
    blob: *[text_scratch_bytes]u8,
    blob_len: *usize,
    slots: *[cluster_intern_slots]u32,
) void {
    const shared = @min(out.len, row.cells.len);
    for (out[0..shared], row.cells[0..shared]) |*slot, cell| {
        slot.* = packCell(cell, blob, blob_len, slots);
    }
    for (out[shared..]) |*slot| slot.* = .{};
}

/// Paint the grid into the display list: per-row background runs, the
/// selection wash, per-run text, decorations, the cursor, the keyboard
/// caret, and the scrollback indicator. Row commands carry stable ids
/// derived from `options.id_base` so the retained renderer's diff keeps
/// damage row-shaped.
///
/// The historical signature, kept for every existing caller: it paints
/// exactly what `paintReport` paints and drops the report. Budget
/// truncation still reaches the caller — the report's facts are
/// recorded on `builder.degradation` either way — but a caller that
/// wants the row counts in hand should call `paintReport` directly.
pub fn paint(grid: TerminalGrid, builder: *canvas.Builder, options: TerminalPaintOptions) !void {
    _ = try paintReport(grid, builder, options);
}

/// `paint`, returning what it managed to place: the rows painted, the
/// rows the producer handed over, and the store that stopped it (see
/// `TerminalPaintReport`). Budget stops are also recorded on the
/// builder so the runtime and the host app can surface them without
/// threading a return value through every emitter.
pub fn paintReport(grid: TerminalGrid, builder: *canvas.Builder, options: TerminalPaintOptions) !TerminalPaintReport {
    var report = TerminalPaintReport{ .rows_total = grid.rows.len };
    const tokens = options.tokens;
    const metrics = cellMetrics(tokens);
    // The command-id namespace (see `paintIdBase`): the widget part-id
    // convention with a 24-bit slot space. An anonymous caller (id 0)
    // keeps the framework's unkeyed convention — every command id 0.
    const ids = CommandIds{ .base = paintIdBase(options.id_base), .keyed = options.id_base != 0 };

    // Fixed prologue/epilogue overhead (background fill, clip push,
    // scrollbar thumb, clip pop): if the builder — with whatever earlier
    // widgets already emitted — cannot seat that overhead under the
    // budget, the paint degrades to nothing BEFORE emitting the prologue,
    // so a full builder never overruns its ceiling and never leaves an
    // unbalanced clip. The `builder.len` term is what makes the check an
    // ABSOLUTE ceiling, not a per-paint one. 0 stays the unbounded
    // (test) mode.
    const fixed_overhead: usize = 8;
    if (options.command_budget > 0 and builder.len + fixed_overhead > options.command_budget) {
        // Not one row, not even the surface: the loudest degradation
        // there is, and the one most likely to read as "the terminal
        // widget is broken" if it stayed silent.
        if (report.rows_total > 0) report.stopped_by = .commands;
        noteTerminalDegradation(builder, options.id_base, report);
        return report;
    }

    // The terminal surface: full-bleed background under the grid.
    try builder.fillRect(.{
        .id = ids.at(0x61_0000),
        .rect = options.background_frame orelse options.frame,
        .fill = .{ .color = grid.background },
    });

    // Everything the grid paints is CLIPPED to its frame: for one frame
    // after a shrink the producer may still hold the pre-resize grid,
    // and unclipped rows or wide cells would paint past the region. The
    // clip makes the stale frame degrade to a cropped grid.
    try builder.pushClip(.{ .id = ids.at(0x61_0001), .rect = options.frame });

    const origin_x = options.frame.x;
    const origin_y = options.frame.y;
    const cell_w = metrics.width;
    const cell_h = metrics.height;

    // The id stride between box cells: a pure-double joint (╬ ╪ ╫ and the
    // double tees) emits up to eight commands, so a shorter stride would
    // collide adjacent double cells' ids.
    const commands_per_cell: usize = 8;
    // The command budget is checked PER ROW against that row's actual
    // upper-bound cost (`rowCommandCost`), not a flat worst-case-per-
    // column reserve: a cheap ASCII row costs ~2/column, so a wide grid
    // paints its rows instead of reserving them all away. The epilogue
    // (cursor, caret, scrollbar thumb, clip pop) rides this fixed slack.
    const epilogue_reserve: usize = 8;
    // The per-view TEXT budget is a separate ceiling from the command
    // count, and the runtime enforces it over EVERY `draw_text` in the
    // finished display list (`CanvasResourceCounts`, 32 KiB) — referenced
    // sibling text included, not just this builder's own `allocTextBytes`
    // bytes. So the grid degrades against the running total of ALL text
    // already in the list plus what it adds, minus the reserve held back
    // for widgets emitted AFTER it. Each row is measured up front and
    // skipped WHOLE if it would cross the ceiling — never torn midway.
    const text_ceiling: usize = if (canvas.max_display_list_text_bytes > options.text_reserve)
        canvas.max_display_list_text_bytes - options.text_reserve
    else
        0;
    var text_total: usize = displayListTextBytes(builder.displayList());
    // The per-view PATH-ELEMENT budget (2048), likewise enforced over the
    // whole display list including static sibling paths (an icon's
    // geometry) that never touch this builder's element store — so the
    // rounded-corner preflight degrades against the running list total,
    // not the builder-owned counter alone.
    var path_total: usize = displayListPathElements(builder.displayList());
    const path_ceiling: usize = builder.path_elements.len -| options.path_reserve;

    // The glyph-atlas proxy budget (see `TerminalPaintOptions`): clamped
    // under half the probe table so insertion can never scan a full
    // ring; the set costs one 64 KiB clear per bounded paint.
    const glyph_budget = @min(options.glyph_budget, glyph_probe_slots / 2);
    var glyph_seen: [glyph_probe_slots]u32 = undefined;
    if (glyph_budget > 0) @memset(&glyph_seen, 0);
    var glyphs_counted: usize = 0;

    // Light box-drawing line weight, scaled with the cell (roughly the
    // stroke a terminal font would carry at this size).
    const box_thickness: f32 = @max(1, @round(metrics.font_size / 8));

    // The lattice this paint will cover. Columns come from the widest
    // row the producer handed over (short rows pad with empty cells), so
    // the grid stays the rectangle every renderer indexes by (x, y)
    // arithmetic instead of a ragged array with a per-row offset table.
    var cols: usize = 0;
    for (grid.rows) |row| cols = @max(cols, row.cells.len);
    cols = @min(cols, max_cols);

    // The cluster INTERN table, reset PER ROW. A row repeats a tiny
    // alphabet across its columns, so a row's text blob holds one copy
    // of each distinct cluster in it — a 300-column ASCII row interns to
    // under a hundred bytes instead of 300.
    //
    // Per row, not per screen, because a row is a retained KEY: a blob
    // shared across the screen would put every row's fingerprint on
    // every other row's characters, so one keystroke that introduced a
    // new letter would re-encode and re-upload the whole screen. That is
    // measurable — it showed up as 31 upserts and 8.4 KB per keystroke
    // before this was per-row, against 1 upsert and ~400 bytes after.
    var blob: [text_scratch_bytes]u8 = undefined;
    var blob_len: usize = 0;
    var intern_slots: [cluster_intern_slots]u32 = undefined;

    // Rows painted so far (the loop paints 0..N contiguously from the
    // top and stops at the first row a budget rejects): the cursor and
    // caret below are suppressed on any row this never reached, so a row
    // dropped for budget never leaves its lone cursor floating over the
    // blank background.
    var painted_rows: usize = 0;
    // Commands this paint will emit: the prologue already in the
    // builder, plus per accepted row one grid command and whatever box
    // geometry and wash that row needs.
    var projected_commands: usize = builder.len;
    // Cells are claimed from the builder's store up front for the most
    // rows that could possibly paint, then the unused tail is handed
    // back (the store is a bump allocator, and nothing else claims cells
    // in between). That buys a single pass: a row can be filled and then
    // rejected by a later budget without leaving a hole.
    const cell_ceiling = builder.cells.len -| options.cell_reserve;
    const cells_available = cell_ceiling -| builder.cell_len;
    // A viewport of empty rows has no cells to store but still has
    // ROWS: they paint as bare surface, and the cursor sitting on one
    // is on a painted row. Bounding those by the cell store would
    // suppress the cursor of an empty terminal.
    const cell_row_limit = if (cols == 0) grid.rows.len else cells_available / cols;
    const claim_rows = @min(grid.rows.len, cell_row_limit);
    var cells: []canvas.Cell = &.{};
    if (claim_rows > 0) {
        cells = builder.allocCells(claim_rows * cols) catch &.{};
    }
    if (cells.len == 0 and grid.rows.len > 0 and cols > 0) report.stopped_by = .cells;

    for (grid.rows, 0..) |row, row_index| {
        if (row_index >= claim_rows) {
            // Ran out of cell store rather than out of screen.
            if (row_index < grid.rows.len) report.stopped_by = .cells;
            break;
        }
        const row_y = origin_y + @as(f32, @floatFromInt(row_index)) * cell_h;
        // Rows STARTING at or past the frame's bottom paint nothing
        // visible; a row straddling the edge still paints and the clip
        // crops it, so content reaches the very edge without spilling.
        if (row_y >= options.frame.y + options.frame.height) {
            report.stopped_by = .viewport;
            break;
        }
        // Command-count stop, ATOMIC per row. Backgrounds and text no
        // longer cost commands at all — they are cells now — so this
        // prices only what still emits: the row's box-drawing geometry
        // and its selection wash. The running PROJECTION is what makes
        // it correct: those commands are emitted in the second pass
        // below, so `builder.len` does not move while this loop runs and
        // charging against it would price every row as if it were the
        // first.
        // +1 for the row's own grid command (see the per-row emission
        // below).
        const row_commands = rowCommandCost(row) + 1;
        if (options.command_budget > 0 and
            projected_commands + row_commands + epilogue_reserve > options.command_budget)
        {
            report.stopped_by = .commands;
            break;
        }
        projected_commands += row_commands;
        // Glyph-budget stop, same row-atomic shape: stop BEFORE the row
        // whose new DISTINCT code points would cross the atlas proxy.
        if (glyph_budget > 0) {
            glyphs_counted += rowNewGlyphs(row, &glyph_seen) * atlas_variants_per_glyph;
            if (glyphs_counted > glyph_budget) {
                report.stopped_by = .glyphs;
                break;
            }
        }
        // Text stop, ATOMIC per row, against the interned blob. The row
        // is filled into a SNAPSHOT of the intern state so a row that
        // crosses the ceiling can be rolled back whole.
        if (cols > 0) {
            const row_cells = cells[row_index * cols ..][0..cols];
            blob_len = 0;
            @memset(&intern_slots, 0);
            fillGridRow(row, row_cells, &blob, &blob_len, &intern_slots);
            // A row that adds no cluster bytes can never cross anything,
            // so a blank or box-only row paints even when earlier widgets
            // already sit past the grid's reserved share — the ceiling
            // bounds what the grid adds, not what its siblings spent.
            if (blob_len > 0 and text_total + blob_len > text_ceiling) {
                report.stopped_by = .text_bytes;
                break;
            }
            const row_text = builder.allocTextBytes(blob[0..blob_len]) catch {
                report.stopped_by = .text_bytes;
                break;
            };
            text_total += blob_len;
            // The row's grid command, emitted here rather than in a
            // later pass so it lands BEFORE that row's box geometry and
            // selection wash, which composite over it.
            builder.cellGrid(.{
                .id = ids.at(0x60_0000 + @as(u64, @intCast(row_index))),
                .origin = geometry.PointF.init(
                    origin_x,
                    origin_y + @as(f32, @floatFromInt(row_index)) * cell_h,
                ),
                .cell_width = cell_w,
                .cell_height = cell_h,
                .cols = @intCast(cols),
                .rows = 1,
                .cells = row_cells,
                .text = row_text,
                .font_id = tokens.typography.mono_font_id,
                .font_size = metrics.font_size,
                // The baseline the canvas boxes a run at: one em of
                // ascent above the origin and a quarter below, centred
                // in the cell. Computed once so every renderer puts it
                // in the same place instead of re-deriving it from
                // metrics it may not share.
                .baseline = (cell_h - metrics.font_size * 1.25) * 0.5 + metrics.font_size,
                .measure = tokens.text_measure,
            }) catch {
                report.stopped_by = .commands;
                break;
            };
        }
        painted_rows = row_index + 1;
    }

    // Hand back the cells of rows that never painted: the store is a
    // bump allocator and nothing else claimed cells in between.
    if (claim_rows > painted_rows) builder.cell_len -= (claim_rows - painted_rows) * cols;

    // Over the lattice: box-drawing geometry (exact cell-bound shapes,
    // never glyphs) and the selection wash. Both composite ON TOP of the
    // grid, which is why they run after it rather than inside the fill
    // loop above.
    for (grid.rows[0..painted_rows], 0..) |row, row_index| {
        const row_y = origin_y + @as(f32, @floatFromInt(row_index)) * cell_h;
        const row_id = @as(u64, @intCast(row_index)) << 16;
        const row_paths = rowPathElements(row);
        const paths_fit = row_paths == 0 or path_total + row_paths <= path_ceiling;
        var x: usize = 0;
        while (x < row.cells.len) : (x += 1) {
            const cell = row.cells[x];
            if (cell.wide == .spacer or cell.cp == 0) continue;
            if (!box.isBoxDrawing(cell.cp)) continue;
            // Merge a run of the same seamless piece (a border's long
            // `─`) into ONE command: fewer commands and one unbroken bar
            // instead of per-cell segments.
            var span: usize = 1;
            if (box.mergesHorizontally(cell.cp)) {
                while (x + span < row.cells.len) : (span += 1) {
                    const next = row.cells[x + span];
                    if (next.cp != cell.cp or !colorEql(next.fg, cell.fg)) break;
                }
            }
            if (!paths_fit and cellPathElements(cell) > 0) {
                x += span - 1;
                continue;
            }
            const rect = geometry.RectF.init(
                origin_x + @as(f32, @floatFromInt(x)) * cell_w,
                row_y,
                @as(f32, @floatFromInt(span)) * cell_w,
                cell_h,
            );
            // Eight-command stride per column: a pure-double joint emits
            // up to eight commands, so a shorter stride would collide
            // the ids of adjacent double cells.
            box.paint(builder, ids.at(row_id + 0x6000 + @as(u64, @intCast(x)) * commands_per_cell), rect, cell.cp, cell.fg, box_thickness) catch {};
            x += span - 1;
        }
        if (paths_fit) path_total += row_paths;

        // Selection wash (over the backgrounds and the ink).
        if (row.selection) |range| {
            const wash = canvas.Color.rgba(
                grid.selection_color.r,
                grid.selection_color.g,
                grid.selection_color.b,
                0.30,
            );
            builder.fillRect(.{
                .id = ids.at(row_id + 0x4000),
                .rect = geometry.RectF.init(
                    origin_x + @as(f32, @floatFromInt(range[0])) * cell_w,
                    row_y,
                    @as(f32, @floatFromInt(@as(usize, range[1]) - range[0] + 1)) * cell_w,
                    cell_h,
                ),
                .fill = .{ .color = wash },
            }) catch {};
        }
    }
    report.rows_painted = painted_rows;
    noteTerminalDegradation(builder, options.id_base, report);

    // The cursor, over the ink: solid only while this live terminal owns
    // keyboard focus. Blur leaves the conventional hollow terminal
    // cursor; an ended session keeps that outline at the dimmer stopped
    // alpha. Suppressed if its row was never painted (dropped for budget).
    if (grid.cursor) |cursor| if (cursor.y < painted_rows) {
        const cursor_x = origin_x + @as(f32, @floatFromInt(cursor.x)) * cell_w;
        const cursor_y = origin_y + @as(f32, @floatFromInt(cursor.y)) * cell_h;
        const cursor_color = canvas.Color.rgba(
            grid.cursor_color.r,
            grid.cursor_color.g,
            grid.cursor_color.b,
            if (grid.running) 0.45 else 0.22,
        );
        // A cursor on a wide cell covers both of its columns.
        const cursor_w = if (cursor.wide) cell_w * 2 else cell_w;
        const rect = switch (cursor.shape) {
            .bar => geometry.RectF.init(cursor_x, cursor_y, 2, cell_h),
            .underline => geometry.RectF.init(cursor_x, cursor_y + cell_h - 2, cursor_w, 2),
            .block, .block_hollow => geometry.RectF.init(cursor_x, cursor_y, cursor_w, cell_h),
        };
        // Two independent reasons to paint hollow, kept independent: the
        // emulator ASKED for a hollow block, or the window does not own
        // the keyboard. Either one outlines; only a focused, live,
        // solid-shape cursor fills.
        const shape_is_hollow = cursor.shape == .block_hollow;
        if (options.focused and grid.running and !shape_is_hollow) {
            try builder.fillRect(.{
                .id = ids.at(0x61_0002),
                .rect = rect,
                .fill = .{ .color = cursor_color },
            });
        } else {
            try builder.strokeRect(.{
                .id = ids.at(0x61_0002),
                .rect = rect,
                .stroke = .{ .fill = .{ .color = cursor_color }, .width = 1 },
            });
        }
    };

    // Selection head outline while selecting (the keyboard caret).
    // Suppressed on a row that was never painted, like the cursor.
    if (grid.select_head) |head| if (head.y < painted_rows) {
        const head_x = origin_x + @as(f32, @floatFromInt(head.x)) * cell_w;
        const head_y = origin_y + @as(f32, @floatFromInt(head.y)) * cell_h;
        try builder.strokeRect(.{
            .id = ids.at(0x61_0003),
            .rect = geometry.RectF.init(head_x, head_y, cell_w, cell_h),
            .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = 1 },
        });
    };

    // Scrollback indicator: a right-edge thumb while the viewport is in
    // history, sized by the visible fraction.
    const bar = grid.scrollbar;
    if (bar.total > bar.len) {
        const total: f32 = @floatFromInt(bar.total);
        const offset: f32 = @floatFromInt(bar.offset);
        const visible: f32 = @floatFromInt(bar.len);
        const at_bottom = bar.offset + bar.len >= bar.total;
        if (!at_bottom) {
            const track_h = options.frame.height;
            const thumb_h = @max(24, track_h * (visible / total));
            const thumb_y = options.frame.y + (track_h - thumb_h) * (offset / @max(1, total - visible));
            try builder.fillRect(.{
                .id = ids.at(0x61_0004),
                .rect = geometry.RectF.init(
                    options.frame.x + options.frame.width - 5,
                    thumb_y,
                    3,
                    thumb_h,
                ),
                .fill = .{ .color = canvas.Color.rgba(
                    tokens.colors.text_muted.r,
                    tokens.colors.text_muted.g,
                    tokens.colors.text_muted.b,
                    0.6,
                ) },
            });
        }
    }
    try builder.popClip();
    return report;
}

/// Stamp a budget stop on the frame being built (see
/// `canvas.DisplayListDegradation`). A viewport stop is not a loss and
/// records nothing; a healthy paint clears nothing either — the record
/// belongs to whichever emitter last ran short, and `Builder.reset`
/// starts every frame clean.
fn noteTerminalDegradation(builder: *canvas.Builder, id: u64, report: TerminalPaintReport) void {
    if (!report.truncated()) return;
    const stop = report.stopped_by orelse return;
    const store = TerminalPaintReport.store(stop) orelse return;
    builder.noteDegradation(.{
        .id = id,
        .store = store,
        .produced = report.rows_painted,
        .requested = report.rows_total,
    });
}
