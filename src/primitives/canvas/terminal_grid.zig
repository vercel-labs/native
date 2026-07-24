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

pub fn cellMetrics(tokens: canvas.DesignTokens) TerminalCellMetrics {
    const font_size = tokens.typography.label_size;
    const height = @round(font_size * 1.4);
    var width: f32 = @round(font_size * 0.6);
    const measured = canvas.measureTextWidthForFont(
        tokens.text_measure,
        tokens.typography.mono_font_id,
        "M",
        font_size,
    );
    if (measured > 0) width = measured;
    return .{ .width = width, .height = height, .font_size = font_size };
}

/// Clamp a proposed grid to the canvas budgets: the glyph budget bounds
/// total cells, so a very wide viewport trades rows for columns to stay
/// under the cell ceiling instead of overflowing the frame.
pub fn clampGrid(proposed_cols: usize, proposed_rows: usize) TerminalCellPos {
    var c = std.math.clamp(proposed_cols, 2, max_cols);
    var r = std.math.clamp(proposed_rows, 2, max_rows);
    if (c * r > max_cells) r = @max(2, max_cells / c);
    if (c * r > max_cells) c = @max(2, max_cells / r);
    return .{ .x = @intCast(c), .y = @intCast(r) };
}

// ------------------------------------------------------------- painting

/// Everything one paint needs beyond the grid.
pub const TerminalPaintOptions = struct {
    /// Grid origin and extent in canvas points (the text region).
    frame: geometry.RectF,
    tokens: canvas.DesignTokens,
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
/// slots < 16), making distinct widgets' parts DISJOINT BY CONSTRUCTION;
/// the grid needs a larger slot space (rows x runs x decorations), so it
/// reserves the low 24 bits (`id *% 2^24 + offset`, every painter offset
/// < 2^24) — the same shape, the same disjointness guarantee between two
/// terminals, and the same accepted residual (ids agreeing modulo the
/// shifted range, astronomically unlikely for hash-derived widget ids).
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

/// An UPPER BOUND on the display-list commands one row emits, assuming
/// no runs merge (the pathological worst case): a background run per
/// cell that carries one, plus the cell's ink — eight commands for a
/// pure-double box joint, two (text run + underline) for a styled
/// character, none for an empty cell — plus one selection wash. Real
/// rows merge runs and cost far less; this bound is what the per-row
/// preflight checks so a row is only started when it can finish whole,
/// and it is content-accurate (a cheap ASCII row costs ~2/column, not a
/// flat worst-case-per-column reserve that would starve wide grids).
fn rowCommandCost(row: TerminalRow) usize {
    var total: usize = 1; // the selection wash
    var i: usize = 0;
    while (i < row.cells.len) : (i += 1) {
        const cell = row.cells[i];
        if (cell.wide == .spacer) continue;
        if (cell.bg != null) total += 1;
        if (cell.cp == 0) continue;
        if (box.isBoxDrawing(cell.cp)) {
            if (box.mergesHorizontally(cell.cp)) {
                // A horizontally-merged run (a long `─` border) paints
                // ONE geometry command plus a possible underline, no
                // matter how wide — mirror the paint loop's merge (same
                // code point, foreground, and underline) so the estimate
                // does not charge nine per column for what collapses to
                // two commands. Backgrounds still count per cell (their
                // own run pass is separate).
                var span: usize = 1;
                while (i + span < row.cells.len) : (span += 1) {
                    const next = row.cells[i + span];
                    if (next.cp != cell.cp or !colorEql(next.fg, cell.fg) or next.underline != cell.underline) break;
                    if (next.bg != null) total += 1;
                }
                // A merged run's worst-case ink: a double piece (═)
                // paints TWO parallel bars, plus a possible underline.
                total += 3;
                i += span - 1;
            } else {
                total += 9; // a joint: up to eight geometry commands plus an underline
            }
        } else {
            total += 2; // the text run plus its underline
        }
    }
    return total;
}

fn colorEql(a: canvas.Color, b: canvas.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// Paint the grid into the display list: per-row background runs, the
/// selection wash, per-run text, decorations, the cursor, the keyboard
/// caret, and the scrollback indicator. Row commands carry stable ids
/// derived from `options.id_base` so the retained renderer's diff keeps
/// damage row-shaped.
pub fn paint(grid: TerminalGrid, builder: *canvas.Builder, options: TerminalPaintOptions) !void {
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
    if (options.command_budget > 0 and builder.len + fixed_overhead > options.command_budget) return;

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

    // A run's staging buffer, sized to the whole text store (see
    // `text_scratch_bytes`): any cluster the store can hold stages
    // whole. The run-break flushes when the buffer nears full, so long
    // runs simply split across draw commands rather than overflow.
    var text_scratch: [text_scratch_bytes]u8 = undefined;
    // Rows painted so far (the loop paints 0..N contiguously from the
    // top and stops at the first row a budget rejects): the cursor and
    // caret below are suppressed on any row this never reached, so a row
    // dropped for budget never leaves its lone cursor floating over the
    // blank background.
    var painted_rows: usize = 0;
    for (grid.rows, 0..) |row, row_index| {
        // Command-count stop, ATOMIC per row: this row's actual
        // upper-bound cost plus the epilogue must fit the budget, so a
        // cheap wide row paints while a genuinely too-dense row (and
        // everything after it) is skipped whole — never started and torn.
        if (options.command_budget > 0 and
            builder.len + rowCommandCost(row) + epilogue_reserve > options.command_budget) break;
        // Text stop, ATOMIC per row, against the view-global running
        // total (all draw_text already in the list plus this row's
        // bytes) — stop BEFORE a row that would cross the per-view text
        // ceiling, never emit its first runs and then have the frame
        // rejected at commit.
        if (text_total + rowTextBytes(row) > text_ceiling) break;
        // Path-element stop, ATOMIC per row, against the view-global
        // running total (static sibling paths included): a row of rounded
        // corners is skipped BEFORE it would cross the per-view
        // path-element budget.
        if (path_total + rowPathElements(row) > builder.path_elements.len) break;
        // Glyph-budget stop, same row-atomic shape: stop BEFORE the row
        // whose new DISTINCT code points would cross the atlas proxy —
        // the frame degrades to fewer rows instead of failing whole on
        // `GlyphAtlasListFull`.
        if (glyph_budget > 0) {
            glyphs_counted += rowNewGlyphs(row, &glyph_seen) * atlas_variants_per_glyph;
            if (glyphs_counted > glyph_budget) break;
        }
        // Row-atomic rollback snapshot: the preflights above make a tear
        // unreachable, but if a builder store is ever exhausted mid-row
        // anyway, these restore points drop the partial row's commands
        // whole (see the `row_torn` handling below) so nothing half a row
        // ever reaches the glass.
        const row_start_len = builder.len;
        const row_start_paths = builder.path_element_len;
        const row_start_text = builder.text_byte_len;
        const row_y = origin_y + @as(f32, @floatFromInt(row_index)) * cell_h;
        // Rows STARTING at or past the frame's bottom paint nothing
        // visible; a row straddling the edge still paints and the clip
        // crops it, so content reaches the very edge without spilling.
        if (row_y >= options.frame.y + options.frame.height) break;
        const row_id = @as(u64, @intCast(row_index)) << 16;

        // Background runs: contiguous cells sharing a non-default bg
        // (the producer already extended a wide primary's background
        // onto its spacer column).
        var run_start: usize = 0;
        var run_color: ?canvas.Color = null;
        var x: usize = 0;
        while (x <= row.cells.len) : (x += 1) {
            const bg: ?canvas.Color = if (x < row.cells.len) row.cells[x].bg else null;
            if (run_color) |color| {
                const same = if (bg) |next| colorEql(color, next) else false;
                if (!same) {
                    try builder.fillRect(.{
                        .id = ids.at(row_id + 1 + run_start),
                        .rect = geometry.RectF.init(
                            origin_x + @as(f32, @floatFromInt(run_start)) * cell_w,
                            row_y,
                            @as(f32, @floatFromInt(x - run_start)) * cell_w,
                            cell_h,
                        ),
                        .fill = .{ .color = color },
                    });
                    run_color = bg;
                    run_start = x;
                }
            } else if (bg != null) {
                run_color = bg;
                run_start = x;
            }
        }

        // Selection wash (under the ink, over the backgrounds).
        if (row.selection) |range| {
            const wash = canvas.Color.rgba(
                grid.selection_color.r,
                grid.selection_color.g,
                grid.selection_color.b,
                0.30,
            );
            try builder.fillRect(.{
                .id = ids.at(row_id + 0x4000),
                .rect = geometry.RectF.init(
                    origin_x + @as(f32, @floatFromInt(range[0])) * cell_w,
                    row_y,
                    @as(f32, @floatFromInt(@as(usize, range[1]) - range[0] + 1)) * cell_w,
                    cell_h,
                ),
                .fill = .{ .color = wash },
            });
        }

        // Text runs: contiguous cells sharing a foreground, flushed on
        // color or decoration change (bold/italic render with the one
        // mono face — weight axes require registered companion faces,
        // a limitation the docs state outright).
        // A builder-store exhaustion mid-row (the display list, its text
        // bytes, or its path elements filling despite the reserves) TEARS
        // the row: the reserves make it unreachable in the widget path,
        // but if it ever happens the row is left incomplete, so it must
        // NOT count as painted and no further row may start — otherwise
        // the cursor could paint over content the tear dropped.
        var row_torn = false;
        var run_len: usize = 0;
        var run_x: usize = 0;
        var run_fg: canvas.Color = grid.foreground;
        var run_underline = false;
        var text_len: usize = 0;
        x = 0;
        while (x <= row.cells.len) : (x += 1) {
            var cp: u21 = 0;
            var fg = grid.foreground;
            var underline = false;
            var skip = false;
            var box_cp: u21 = 0;
            var cell_bytes: usize = 0;
            if (x < row.cells.len) {
                const cell = row.cells[x];
                if (cell.wide == .spacer) skip = true;
                cp = cell.cp;
                fg = cell.fg;
                underline = cell.underline;
                // Box-drawing, block, and shade cells render as GEOMETRY
                // at exact cell bounds, never font glyphs: glyphs fill
                // the em box, not the padded cell, so borders drawn from
                // them show seams between rows and columns. The cell
                // still breaks the text run (cp zeroes) and paints below.
                if (cp != 0 and !skip and box.isBoxDrawing(cp)) {
                    box_cp = cp;
                    cp = 0;
                }
                // The current cell's full byte need: the run breaks
                // BEFORE a cell that would not fit the remaining
                // scratch, so the cell restarts in a fresh buffer and a
                // large grapheme landing near the buffer's end keeps
                // all its marks instead of being cut.
                if (cp != 0 and !skip) cell_bytes = cell.cluster.len;
            }
            const breaks = x == row.cells.len or skip or cp == 0 or
                !colorEql(fg, run_fg) or underline != run_underline or text_len + cell_bytes > text_scratch.len;
            if (breaks and run_len > 0 and text_len > 0) {
                // The row-wise text ceiling reserves enough that this
                // append fits; the catch is a defensive floor that stops
                // the run cleanly if it ever did not (never a torn cell).
                const run_text = builder.allocTextBytes(text_scratch[0..text_len]) catch {
                    row_torn = true;
                    break;
                };
                try builder.drawText(.{
                    .id = ids.at(row_id + 0x8000 + run_x),
                    .font_id = tokens.typography.mono_font_id,
                    .size = metrics.font_size,
                    // `origin` is the BASELINE, not the glyph top: the
                    // canvas boxes a run as one em of ascent above the
                    // origin and a quarter below, so centering that
                    // 1.25em box in the cell puts the baseline at
                    // row top + (cell - 1.25*size)/2 + size. Anchoring
                    // the top here instead paints every row one line
                    // high — and the clip swallows row zero whole.
                    .origin = geometry.PointF.init(
                        origin_x + @as(f32, @floatFromInt(run_x)) * cell_w,
                        row_y + (cell_h - metrics.font_size * 1.25) * 0.5 + metrics.font_size,
                    ),
                    .color = run_fg,
                    .text = run_text,
                });
                if (run_underline) {
                    try builder.fillRect(.{
                        .id = ids.at(row_id + 0xc000 + run_x),
                        .rect = geometry.RectF.init(
                            origin_x + @as(f32, @floatFromInt(run_x)) * cell_w,
                            row_y + cell_h - 2,
                            @as(f32, @floatFromInt(run_len)) * cell_w,
                            1,
                        ),
                        .fill = .{ .color = run_fg },
                    });
                }
                text_len = 0;
                run_len = 0;
            }
            if (x >= row.cells.len or skip) continue;
            if (box_cp != 0) {
                // Merge a run of the same seamless piece (a border's
                // long `─`) into ONE command: fewer commands and one
                // unbroken bar instead of per-cell segments. Cells merge
                // only when they match on EVERY channel the span paints —
                // code point, foreground, AND underline — so a run where
                // underline toggles mid-way breaks into separate spans
                // and each keeps its own decoration.
                var span: usize = 1;
                if (box.mergesHorizontally(box_cp)) {
                    while (x + span < row.cells.len) : (span += 1) {
                        const next = row.cells[x + span];
                        if (next.cp != box_cp or !colorEql(next.fg, fg) or next.underline != underline) break;
                    }
                }
                const rect = geometry.RectF.init(
                    origin_x + @as(f32, @floatFromInt(x)) * cell_w,
                    row_y,
                    @as(f32, @floatFromInt(span)) * cell_w,
                    cell_h,
                );
                // Eight-command stride per column: a pure-double joint
                // emits up to eight commands (two bars per side), so a
                // four-wide stride would collide the ids of adjacent
                // double cells and fail the retained diff with
                // DuplicateObjectId.
                box.paint(builder, ids.at(row_id + 0x6000 + @as(u64, @intCast(x)) * commands_per_cell), rect, box_cp, fg, box_thickness) catch {
                    row_torn = true;
                    break;
                };
                // A box/block cell can still carry SGR underline: the
                // geometry replaces the glyph, not its decoration, so an
                // underlined `─` or `█` keeps its underline like any other
                // styled cell (0xd000 id range, clear of the box geometry
                // and text ranges).
                if (underline) {
                    builder.fillRect(.{
                        .id = ids.at(row_id + 0xd000 + @as(u64, @intCast(x))),
                        .rect = geometry.RectF.init(rect.x, row_y + cell_h - 2, rect.width, 1),
                        .fill = .{ .color = fg },
                    }) catch {
                        row_torn = true;
                        break;
                    };
                }
                x += span - 1;
                continue;
            }
            if (cp == 0) continue;
            if (run_len == 0) {
                run_x = x;
                run_fg = fg;
                run_underline = underline;
            }
            const cell = row.cells[x];
            // Stage the whole cluster; the break above guaranteed it
            // fits, and the min is a defensive floor that can only cut
            // where the preflight already stopped the row.
            const take = @min(cell.cluster.len, text_scratch.len - text_len);
            @memcpy(text_scratch[text_len..][0..take], cell.cluster[0..take]);
            text_len += take;
            run_len += if (cell.wide == .wide) 2 else 1;
        }
        // A torn row is not painted content: roll the builder back to the
        // row's start so no partial row reaches the glass, then stop (the
        // suppressed cursor/caret rely on `painted_rows` not advancing).
        if (row_torn) {
            builder.len = row_start_len;
            builder.path_element_len = row_start_paths;
            builder.text_byte_len = row_start_text;
            break;
        }
        // Advance the view-global running totals by exactly what this row
        // added (the builder-owned deltas): the terminal's own text/path
        // emissions all flow through `allocTextBytes`/`allocPathElements`,
        // so the counter deltas are its contribution to the per-view
        // budgets the next row's preflight checks.
        text_total += builder.text_byte_len - row_start_text;
        path_total += builder.path_element_len - row_start_paths;
        painted_rows = row_index + 1;
    }

    // The cursor, over the ink: filled while live, hollow-dim after exit.
    // Suppressed if its row was never painted (dropped for budget).
    if (grid.cursor) |cursor| if (cursor.y < painted_rows) {
        const cursor_x = origin_x + @as(f32, @floatFromInt(cursor.x)) * cell_w;
        const cursor_y = origin_y + @as(f32, @floatFromInt(cursor.y)) * cell_h;
        const cursor_color = canvas.Color.rgba(
            grid.cursor_color.r,
            grid.cursor_color.g,
            grid.cursor_color.b,
            if (grid.running) 0.45 else 0.22,
        );
        const rect = switch (cursor.shape) {
            .bar => geometry.RectF.init(cursor_x, cursor_y, 2, cell_h),
            .underline => geometry.RectF.init(cursor_x, cursor_y + cell_h - 2, cell_w, 2),
            .block => geometry.RectF.init(cursor_x, cursor_y, cell_w, cell_h),
        };
        try builder.fillRect(.{
            .id = ids.at(0x61_0002),
            .rect = rect,
            .fill = .{ .color = cursor_color },
        });
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
}
