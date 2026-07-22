//! The terminal grid: libghostty-vt owns cell state, damage, scrollback,
//! and selection; this module wraps one emulator session and paints its
//! viewport as REAL text through the canvas primitives. The palette is
//! theme-derived where the emulator still holds its defaults (the honest
//! ANSI-16 story) and exact everywhere an application chose a color: the
//! 256-color cube, the grayscale ramp, and truecolor pass through
//! untouched.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

/// Grid ceilings, derived from the per-view canvas budgets: the glyph
/// budget (8192) bounds how many cells can hold ink at once, and the
/// command budget bounds per-row style runs. A viewport is clamped to
/// these before it reaches the emulator, so a huge window degrades to a
/// bounded grid instead of a budget error.
pub const max_cols: usize = 320;
pub const max_rows: usize = 96;
pub const max_cells: usize = 7168;

/// Stable command-id namespace for grid commands so the retained
/// renderer matches rows across rebuilds and damage stays row-shaped.
const grid_id_base: u64 = 0x7e21_0000_0000_0000;

/// One live emulator session. Heap-owned by the app (the model holds a
/// pointer): the emulator allocates internally and its state is derived
/// entirely from journaled inputs — fed pty bytes, resizes, and
/// selection edits — so a replayed session rebuilds it byte-identical.
pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState,
    /// Terminal answers to queries (DSR, DA1) produced while feeding
    /// output; the app drains this after every feed and writes it back
    /// to the pty. Bounded: a feed can only ask so much, and overflow
    /// drops the response whole (never cut) with a count.
    response_buffer: [1024]u8 = undefined,
    response_len: usize = 0,
    responses_dropped: u32 = 0,
    /// Keyboard-selection state: the anchor stays put, the head moves.
    select_anchor: ?CellPos = null,
    select_head: CellPos = .{},
    select_block: bool = false,
    /// Cell metrics for the mono face at the terminal type size,
    /// refreshed whenever tokens/scale reach the painter.
    cell_width: f32 = 8,
    cell_height: f32 = 18,
    font_size: f32 = 13,

    pub const CellPos = struct { x: u16 = 0, y: u16 = 0 };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, initial_cols: u16, initial_rows: u16) !*Session {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{
            .gpa = gpa,
            .term = try vt.Terminal.init(io, gpa, .{
                .cols = @intCast(@min(initial_cols, max_cols)),
                .rows = @intCast(@min(initial_rows, max_rows)),
                .max_scrollback = 1_000_000,
            }),
            .stream = undefined,
            .render = .empty,
        };
        session.stream = .initAlloc(gpa, .init(&session.term));
        session.stream.handler.effects = .{
            .bell = null,
            .clipboard_write = null,
            .color_scheme = null,
            .device_attributes = null,
            .enquiry = null,
            .size = null,
            .title_changed = null,
            .pwd_changed = null,
            .write_pty = writePtyResponse,
            .xtversion = null,
        };
        return session;
    }

    pub fn destroy(session: *Session) void {
        const gpa = session.gpa;
        session.render.deinit(gpa);
        session.stream.deinit();
        session.term.deinit(gpa);
        gpa.destroy(session);
    }

    /// Feed one pty output batch through the VT stream. Parser state
    /// persists across batches (escape sequences split at a chunk
    /// boundary keep parsing).
    pub fn feed(session: *Session, bytes: []const u8) void {
        session.stream.nextSlice(bytes);
    }

    /// Terminal query answers accumulated by the last feeds; the caller
    /// writes them to the pty and calls `clearResponses`.
    pub fn pendingResponses(session: *const Session) []const u8 {
        return session.response_buffer[0..session.response_len];
    }

    pub fn clearResponses(session: *Session) void {
        session.response_len = 0;
    }

    fn writePtyResponse(handler: *vt.TerminalStream.Handler, bytes: [:0]const u8) void {
        const session: *Session = @alignCast(@fieldParentPtr("term", handler.terminal));
        if (session.response_len + bytes.len > session.response_buffer.len) {
            session.responses_dropped +|= 1;
            return;
        }
        @memcpy(session.response_buffer[session.response_len .. session.response_len + bytes.len], bytes);
        session.response_len += bytes.len;
    }

    pub fn cols(session: *const Session) u16 {
        return @intCast(session.term.cols);
    }

    pub fn rows(session: *const Session) u16 {
        return @intCast(session.term.rows);
    }

    /// Resize the emulator grid (reflow included). Returns whether the
    /// grid now matches the request: a no-op (already that size) and a
    /// successful reflow both return true; an allocation failure returns
    /// false so the caller leaves its model dimensions unchanged and
    /// retries on the next frame, keeping the emulator and the pty from
    /// disagreeing about the size under memory pressure.
    pub fn resize(session: *Session, new_cols: u16, new_rows: u16) bool {
        const c: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_cols), 2, max_cols));
        const r: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_rows), 2, max_rows));
        if (c == session.term.cols and r == session.term.rows) return true;
        session.term.resize(session.gpa, .{ .cols = c, .rows = r }) catch return false;
        return true;
    }

    /// Clamp a proposed grid to the canvas budgets: the glyph budget
    /// bounds total cells, so very wide windows trade rows for columns
    /// honestly instead of overflowing the frame.
    pub fn clampGrid(proposed_cols: usize, proposed_rows: usize) Session.CellPos {
        var c = std.math.clamp(proposed_cols, 2, max_cols);
        var r = std.math.clamp(proposed_rows, 2, max_rows);
        if (c * r > max_cells) r = @max(2, max_cells / c);
        if (c * r > max_cells) c = @max(2, max_cells / r);
        return .{ .x = @intCast(c), .y = @intCast(r) };
    }

    // ---------------------------------------------------- scrollback

    /// Scroll the viewport into history (negative = toward the top).
    pub fn scrollLines(session: *Session, delta: isize) void {
        session.term.screens.active.pages.scroll(.{ .delta_row = delta });
    }

    pub fn scrollToBottom(session: *Session) void {
        session.term.screens.active.pages.scroll(.{ .active = {} });
    }

    pub fn scrollToTop(session: *Session) void {
        session.term.screens.active.pages.scroll(.{ .top = {} });
    }

    /// Rows of history above the viewport (0 = pinned to the live
    /// screen) plus the total row count, for the scroll indicator.
    pub fn scrollbar(session: *Session) vt.PageList.Scrollbar {
        return session.term.screens.active.pages.scrollbar();
    }

    // ---------------------------------------------------- selection

    pub fn selectionActive(session: *const Session) bool {
        return session.select_anchor != null;
    }

    /// Begin a keyboard selection at the terminal cursor (or extend the
    /// existing one). `block` selects a rectangle; otherwise the
    /// selection flows line-wise like every text surface.
    pub fn beginSelection(session: *Session, block: bool) void {
        const cursor = session.render.cursor.viewport orelse vt.RenderState.Cursor.Viewport{ .x = 0, .y = 0, .wide_tail = false };
        session.select_anchor = .{ .x = @intCast(cursor.x), .y = @intCast(cursor.y) };
        session.select_head = session.select_anchor.?;
        session.select_block = block;
        session.applySelection();
    }

    pub fn toggleSelectionBlock(session: *Session) void {
        if (session.select_anchor == null) return;
        session.select_block = !session.select_block;
        session.applySelection();
    }

    /// Move the selection head one step; `extend` keeps the anchor
    /// (shift held), otherwise anchor follows head (caret move).
    pub fn moveSelection(session: *Session, dx: i32, dy: i32, extend: bool) void {
        if (session.select_anchor == null) return;
        const grid_cols: i32 = @intCast(session.term.cols);
        const grid_rows: i32 = @intCast(session.term.rows);
        var x: i32 = @as(i32, session.select_head.x) + dx;
        var y: i32 = @as(i32, session.select_head.y) + dy;
        x = std.math.clamp(x, 0, grid_cols - 1);
        y = std.math.clamp(y, 0, grid_rows - 1);
        session.select_head = .{ .x = @intCast(x), .y = @intCast(y) };
        if (!extend) session.select_anchor = session.select_head;
        session.applySelection();
    }

    pub fn clearSelection(session: *Session) void {
        session.select_anchor = null;
        session.term.screens.active.clearSelection();
    }

    fn applySelection(session: *Session) void {
        const anchor = session.select_anchor orelse return;
        const screen = session.term.screens.active;
        const tl = screen.pages.pin(.{ .viewport = .{ .x = anchor.x, .y = anchor.y } }) orelse return;
        const br = screen.pages.pin(.{ .viewport = .{ .x = session.select_head.x, .y = session.select_head.y } }) orelse return;
        screen.select(vt.Selection.init(tl, br, session.select_block)) catch {};
    }

    /// The selected text, caller-owned (freed with the sentinel).
    /// Null when nothing is selected.
    pub fn selectionText(session: *Session, gpa: std.mem.Allocator) ?[:0]const u8 {
        const screen = session.term.screens.active;
        const selection = screen.selection orelse return null;
        return screen.selectionString(gpa, .{ .sel = selection, .trim = true }) catch null;
    }

    /// The viewport as plain text — the test and automation view of the
    /// grid (real cell state, no pixels).
    pub fn plainText(session: *Session, gpa: std.mem.Allocator) ![]const u8 {
        return session.term.plainString(gpa);
    }
};

// ------------------------------------------------------------- painting

/// Everything one paint needs beyond the session.
pub const PaintOptions = struct {
    /// Grid origin and extent in canvas points.
    frame: geometry.RectF,
    tokens: canvas.DesignTokens,
    /// The pty is live (cursor paints filled; an ended session paints
    /// the cursor hollow).
    running: bool,
    /// Selection mode is armed (the head cell paints a focus outline).
    selecting: bool,
    /// Hard ceiling on display-list commands this paint may emit — the
    /// chrome prefix budget the app reserved. A pathological screen
    /// (every cell a different style, so no run merges) can generate
    /// more commands than the budget; painting stops row-wise at the
    /// ceiling rather than overflowing the frame, so a busy screen
    /// degrades to fewer painted rows instead of a failed render. 0
    /// means unbounded (tests that size their own builder).
    command_budget: usize = 0,
};

/// Paint the session's viewport into the display list: per-row
/// background runs, the selection wash, per-run text, decorations, the
/// cursor, and the scrollback indicator. Row commands carry stable ids
/// so the retained renderer's diff keeps damage row-shaped.
pub fn paint(session: *Session, builder: *canvas.Builder, options: PaintOptions) !void {
    const tokens = options.tokens;
    session.font_size = tokens.typography.label_size;
    session.cell_height = @round(session.font_size * 1.4);
    const measured = canvas.measureTextWidthForFont(
        tokens.text_measure,
        tokens.typography.mono_font_id,
        "M",
        session.font_size,
    );
    if (measured > 0) session.cell_width = measured;

    try session.render.update(session.gpa, &session.term);
    const rs = &session.render;
    const palette = Palette.init(tokens, &rs.colors);

    // The terminal surface: full-bleed theme background under the grid.
    try builder.fillRect(.{
        .id = grid_id_base,
        .rect = options.frame,
        .fill = .{ .color = palette.background },
    });

    const origin_x = options.frame.x;
    const origin_y = options.frame.y;
    const cell_w = session.cell_width;
    const cell_h = session.cell_height;

    // Worst case for one row, when no runs merge (every cell a distinct
    // style): a background run, a text run, AND an underline run per
    // column — three commands each — plus one selection wash. Reserve
    // that so the LAST painted row can never push the list past the
    // budget; the cursor and scrollbar (+2) fit under the same reserve.
    const row_reserve: usize = max_cols * 3 + 4;
    const row_ceiling: usize = if (options.command_budget > row_reserve)
        options.command_budget - row_reserve
    else
        0;

    var text_scratch: [max_cols * 4]u8 = undefined;
    var row_index: usize = 0;
    while (row_index < rs.row_data.len) : (row_index += 1) {
        // Row-wise budget stop: once the list is within one row's worst
        // case of the ceiling, stop painting further rows.
        if (options.command_budget > 0 and builder.displayList().commands.len >= row_ceiling) break;
        const row = rs.row_data.get(row_index);
        const row_y = origin_y + @as(f32, @floatFromInt(row_index)) * cell_h;
        if (row_y + cell_h > options.frame.y + options.frame.height + cell_h) break;
        const row_id = grid_id_base + (@as(u64, @intCast(row_index)) << 16);

        // Background runs: contiguous cells sharing a non-default bg.
        var run_start: usize = 0;
        var run_color: ?canvas.Color = null;
        var x: usize = 0;
        while (x <= row.cells.len) : (x += 1) {
            const bg: ?canvas.Color = if (x < row.cells.len) cellBackground(row.cells.get(x), &palette) else null;
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
                palette.selection.r,
                palette.selection.g,
                palette.selection.b,
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
        // color change (bold/italic render with the one mono face —
        // weight axes come with registered companions, stated honestly
        // in the recipe).
        var run_len: usize = 0;
        var run_x: usize = 0;
        var run_fg: canvas.Color = palette.foreground;
        var run_underline = false;
        var text_len: usize = 0;
        x = 0;
        while (x <= row.cells.len) : (x += 1) {
            var cp: u21 = 0;
            var fg = palette.foreground;
            var underline = false;
            var skip = false;
            if (x < row.cells.len) {
                const cell = row.cells.get(x);
                if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) skip = true;
                cp = switch (cell.raw.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
                    else => 0,
                };
                if (cp != 0 and cell.raw.style_id != 0) {
                    const style = cell.style;
                    fg = palette.resolveFg(style, cellBackground(cell, &palette));
                    underline = style.flags.underline != .none;
                    if (style.flags.invisible) cp = 0;
                }
            }
            const breaks = x == row.cells.len or skip or cp == 0 or
                !colorEql(fg, run_fg) or underline != run_underline or text_len + 8 > text_scratch.len;
            if (breaks and run_len > 0 and text_len > 0) {
                try builder.drawText(.{
                    .id = row_id + 0x8000 + run_x,
                    .font_id = tokens.typography.mono_font_id,
                    .size = session.font_size,
                    .origin = geometry.PointF.init(
                        origin_x + @as(f32, @floatFromInt(run_x)) * cell_w,
                        row_y + (cell_h - session.font_size) * 0.5,
                    ),
                    .color = run_fg,
                    .text = builder.allocTextBytes(text_scratch[0..text_len]) catch break,
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
            if (cp == 0) continue;
            if (run_len == 0) {
                run_x = x;
                run_fg = fg;
                run_underline = underline;
            }
            const cell = row.cells.get(x);
            text_len += std.unicode.utf8Encode(cp, text_scratch[text_len..]) catch 0;
            if (cell.raw.content_tag == .codepoint_grapheme) {
                for (cell.grapheme) |extra| {
                    if (text_len + 8 > text_scratch.len) break;
                    text_len += std.unicode.utf8Encode(extra, text_scratch[text_len..]) catch 0;
                }
            }
            run_len += if (cell.raw.wide == .wide) 2 else 1;
        }
    }

    // The cursor, over the ink: filled while live, hollow after exit.
    if (rs.cursor.visible) {
        if (rs.cursor.viewport) |cursor| {
            const cursor_x = origin_x + @as(f32, @floatFromInt(cursor.x)) * cell_w;
            const cursor_y = origin_y + @as(f32, @floatFromInt(cursor.y)) * cell_h;
            const cursor_color = canvas.Color.rgba(
                palette.cursor.r,
                palette.cursor.g,
                palette.cursor.b,
                if (options.running) 0.45 else 0.22,
            );
            const rect = switch (rs.cursor.visual_style) {
                .bar => geometry.RectF.init(cursor_x, cursor_y, 2, cell_h),
                .underline => geometry.RectF.init(cursor_x, cursor_y + cell_h - 2, cell_w, 2),
                else => geometry.RectF.init(cursor_x, cursor_y, cell_w, cell_h),
            };
            try builder.fillRect(.{
                .id = grid_id_base + 0x1_0000_0000,
                .rect = rect,
                .fill = .{ .color = cursor_color },
            });
        }
    }

    // Selection head outline while selecting (the keyboard caret).
    if (options.selecting) {
        const head_x = origin_x + @as(f32, @floatFromInt(session.select_head.x)) * cell_w;
        const head_y = origin_y + @as(f32, @floatFromInt(session.select_head.y)) * cell_h;
        try builder.strokeRect(.{
            .id = grid_id_base + 0x2_0000_0000,
            .rect = geometry.RectF.init(head_x, head_y, cell_w, cell_h),
            .stroke = .{ .fill = .{ .color = tokens.colors.focus_ring }, .width = 1 },
        });
    }

    // Scrollback indicator: a right-edge thumb while the viewport is in
    // history, sized by the visible fraction.
    const bar = session.scrollbar();
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
                .id = grid_id_base + 0x3_0000_0000,
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
}

fn cellBackground(cell: anytype, palette: *const Palette) ?canvas.Color {
    switch (cell.raw.content_tag) {
        .bg_color_palette => return palette.indexed(cell.raw.content.color_palette.data),
        .bg_color_rgb => {
            const rgb = cell.raw.content.color_rgb;
            return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
        },
        else => {},
    }
    if (cell.raw.style_id == 0) return null;
    const style = cell.style;
    if (style.flags.inverse) {
        return palette.resolveFgRaw(style);
    }
    return switch (style.bg_color) {
        .none => null,
        .palette => |index| palette.indexed(index),
        .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
    };
}

fn colorEql(a: canvas.Color, b: canvas.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

// ------------------------------------------------------------- palette

/// The theme mapping, stated honestly: where the emulator's palette
/// entry still holds its DEFAULT value, the ANSI-16 slot derives from
/// the active theme tokens (background/text neutrals; red, green, and
/// yellow from the semantic hues) so a themed app and its terminal read
/// as one surface. The moment a program restyles an entry (OSC 4), the
/// programmed color wins verbatim — and the cube (16..231), the
/// grayscale ramp (232..255), and truecolor always pass through exactly.
const Palette = struct {
    background: canvas.Color,
    foreground: canvas.Color,
    cursor: canvas.Color,
    selection: canvas.Color,
    ansi: [16]canvas.Color,
    terminal: *const vt.RenderState.Colors,

    fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors) Palette {
        const colors = tokens.colors;
        const dark = colors.background.r + colors.background.g + colors.background.b < 1.5;
        const dim: f32 = if (dark) 0.85 else 1.0;
        const bright: f32 = if (dark) 1.0 else 0.8;
        return .{
            .background = colors.background,
            .foreground = colors.text,
            .cursor = colors.accent,
            .selection = colors.accent,
            .terminal = terminal_colors,
            .ansi = .{
                // 0-7: black, red, green, yellow, blue, magenta, cyan, white.
                blend(colors.text, colors.background, if (dark) 0.35 else 0.95),
                scale(colors.destructive, dim),
                scale(colors.success, dim),
                scale(colors.warning, dim),
                scale(canvas.Color.rgb8(37, 99, 235), dim),
                scale(canvas.Color.rgb8(147, 51, 234), dim),
                scale(canvas.Color.rgb8(8, 145, 178), dim),
                blend(colors.text, colors.background, if (dark) 0.75 else 0.35),
                // 8-15: the bright ramp.
                blend(colors.text, colors.background, if (dark) 0.5 else 0.75),
                scale(colors.destructive, bright),
                scale(colors.success, bright),
                scale(colors.warning, bright),
                scale(canvas.Color.rgb8(59, 130, 246), bright),
                scale(canvas.Color.rgb8(168, 85, 247), bright),
                scale(canvas.Color.rgb8(34, 211, 238), bright),
                colors.text,
            },
        };
    }

    /// Palette index -> color: theme-derived for untouched ANSI-16
    /// entries, the emulator's live palette everywhere else.
    fn indexed(palette: *const Palette, index: u8) canvas.Color {
        const live = palette.terminal.palette[index];
        if (index < 16) {
            const default_entry = vt.color.default[index];
            if (live.r == default_entry.r and live.g == default_entry.g and live.b == default_entry.b) {
                return palette.ansi[index];
            }
        }
        return canvas.Color.rgb8(live.r, live.g, live.b);
    }

    fn resolveFg(palette: *const Palette, style: vt.Style, bg: ?canvas.Color) canvas.Color {
        _ = bg;
        if (style.flags.inverse) {
            // Inverse paints the text in the cell's BACKGROUND color
            // (the theme background when the cell chose none) — the
            // opposite of `cellBackground`, which paints the swapped
            // foreground behind it. Resolving the real bg here, rather
            // than the already-swapped `bg` argument, is what keeps
            // default inverse text visible instead of foreground on
            // an identical foreground.
            return palette.resolveBgRaw(style);
        }
        var color = palette.resolveFgRaw(style);
        if (style.flags.faint) color = blend(color, palette.background, 0.5);
        return color;
    }

    fn resolveFgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.fg_color) {
            .none => palette.foreground,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn resolveBgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.bg_color) {
            .none => palette.background,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn blend(a: canvas.Color, b: canvas.Color, t: f32) canvas.Color {
        return canvas.Color.rgba(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            1,
        );
    }

    fn scale(color: canvas.Color, factor: f32) canvas.Color {
        return canvas.Color.rgba(
            @min(1, color.r * factor),
            @min(1, color.g * factor),
            @min(1, color.b * factor),
            1,
        );
    }
};
