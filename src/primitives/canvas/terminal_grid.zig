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
    /// The viewport as plain text — the grid's accessibility surface (a
    /// terminal's semantic content IS its text) and, through the widget
    /// text channel, the session fingerprint's cell-state coverage.
    /// Empty means "unknown", never "same as before".
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
/// total cells, so very wide viewports trade rows for columns honestly
/// instead of overflowing the frame.
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
    /// Ceiling on DISTINCT code points the grid may put on screen in
    /// one paint — a proxy bound for the runtime's per-view glyph-atlas
    /// entries, which an adversarial screen can exhaust long before the
    /// command or text budgets bind. Painting stops row-atomically
    /// BEFORE the row whose new code points would cross it. 0 means
    /// unbounded.
    glyph_budget: usize = 0,
};

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
    // The command-id namespace: a per-grid-stable spread of the caller's
    // base across the u64 space, leaving the low 48 bits for row/run
    // slots exactly like the widget part-id convention leaves slots.
    const id_base = options.id_base *% 0x9E37_79B9_7F4A_7C15;

    // The terminal surface: full-bleed background under the grid.
    try builder.fillRect(.{
        .id = id_base,
        .rect = options.background_frame orelse options.frame,
        .fill = .{ .color = grid.background },
    });

    // Everything the grid paints is CLIPPED to its frame: for one frame
    // after a shrink the producer may still hold the pre-resize grid,
    // and unclipped rows or wide cells would paint past the region. The
    // clip makes the stale frame degrade to a cropped grid.
    try builder.pushClip(.{ .id = id_base +% 0x4_0000_0000, .rect = options.frame });

    const origin_x = options.frame.x;
    const origin_y = options.frame.y;
    const cell_w = metrics.width;
    const cell_h = metrics.height;

    // Worst case for one row, when no runs merge (every cell a distinct
    // style): a background run, a text run, AND an underline run per
    // column, or a box-drawing cell's up-to-four segments — four
    // commands each — plus one selection wash. Reserved for the ACTUAL
    // grid width so the LAST painted row can never push the list past
    // the budget; the cursor, caret, scrollbar, and clip push/pop (+4)
    // fit under the same reserve.
    const cols_actual: usize = if (grid.rows.len > 0) grid.rows[0].cells.len else max_cols;
    const row_reserve: usize = cols_actual * 4 + 8;
    const row_ceiling: usize = if (options.command_budget > row_reserve)
        options.command_budget - row_reserve
    else
        0;
    // The display-list TEXT store is a separate budget from the command
    // count: a screen of multi-codepoint graphemes (emoji) can exhaust
    // its bytes long before the command budget. Each row is emitted
    // ATOMICALLY — its exact text-byte need is measured up front and the
    // row is skipped WHOLE if it would not fit the remaining store — so
    // the grid degrades to fewer complete rows, never a row torn midway
    // by an allocation failure.
    const text_store: usize = if (canvas.max_display_list_text_bytes > options.text_reserve)
        canvas.max_display_list_text_bytes - options.text_reserve
    else
        0;
    var text_bytes_emitted: usize = 0;

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
    for (grid.rows, 0..) |row, row_index| {
        // Command-count stop: once within one row's worst case of the
        // command ceiling, stop painting further rows.
        if (options.command_budget > 0 and builder.displayList().commands.len >= row_ceiling) break;
        // Text-store stop, ATOMIC per row: measure this row's exact text
        // bytes and stop BEFORE it if the store cannot hold them — never
        // emit a row's first runs and then fail mid-row.
        if (text_bytes_emitted + rowTextBytes(row) > text_store) break;
        // Glyph-budget stop, same row-atomic shape: stop BEFORE the row
        // whose new DISTINCT code points would cross the atlas proxy —
        // the frame degrades to fewer rows instead of failing whole on
        // `GlyphAtlasListFull`.
        if (glyph_budget > 0) {
            glyphs_counted += rowNewGlyphs(row, &glyph_seen);
            if (glyphs_counted > glyph_budget) break;
        }
        const row_y = origin_y + @as(f32, @floatFromInt(row_index)) * cell_h;
        // Rows STARTING at or past the frame's bottom paint nothing
        // visible; a row straddling the edge still paints and the clip
        // crops it, so content reaches the very edge without spilling.
        if (row_y >= options.frame.y + options.frame.height) break;
        const row_id = id_base +% (@as(u64, @intCast(row_index)) << 16);

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
                        .id = row_id + 1 + run_start,
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
                .id = row_id + 0x4000,
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
        // mono face — weight axes come with registered companions,
        // stated honestly in the docs).
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
                const run_text = builder.allocTextBytes(text_scratch[0..text_len]) catch break;
                text_bytes_emitted += text_len;
                try builder.drawText(.{
                    .id = row_id + 0x8000 + run_x,
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
                        .id = row_id + 0xc000 + run_x,
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
                // unbroken bar instead of per-cell segments. Style
                // equality is color equality here — the snapshot already
                // resolved everything else.
                var span: usize = 1;
                if (box.mergesHorizontally(box_cp)) {
                    while (x + span < row.cells.len) : (span += 1) {
                        const next = row.cells[x + span];
                        if (next.cp != box_cp or !colorEql(next.fg, fg)) break;
                    }
                }
                const rect = geometry.RectF.init(
                    origin_x + @as(f32, @floatFromInt(x)) * cell_w,
                    row_y,
                    @as(f32, @floatFromInt(span)) * cell_w,
                    cell_h,
                );
                box.paint(builder, row_id + 0x6000 + @as(u64, @intCast(x)) * 4, rect, box_cp, fg, box_thickness) catch break;
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
    }

    // The cursor, over the ink: filled while live, hollow-dim after exit.
    if (grid.cursor) |cursor| {
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
            .id = id_base +% 0x1_0000_0000,
            .rect = rect,
            .fill = .{ .color = cursor_color },
        });
    }

    // Selection head outline while selecting (the keyboard caret).
    if (grid.select_head) |head| {
        const head_x = origin_x + @as(f32, @floatFromInt(head.x)) * cell_w;
        const head_y = origin_y + @as(f32, @floatFromInt(head.y)) * cell_h;
        try builder.strokeRect(.{
            .id = id_base +% 0x2_0000_0000,
            .rect = geometry.RectF.init(head_x, head_y, cell_w, cell_h),
            .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = 1 },
        });
    }

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
                .id = id_base +% 0x3_0000_0000,
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
