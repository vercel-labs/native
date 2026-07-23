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

/// One text run's staging capacity — shared by the paint loop's scratch
/// and the preflight's per-cell cap so measure and emission agree.
/// Sized to the WHOLE display-list text store, so the paint tier is
/// never the binding constraint on a grapheme cluster: any cluster the
/// emulator hands over paints complete, and only a cluster the store
/// itself cannot hold skips — row-atomically, the preflight rule. (The
/// emulator's own grapheme storage bounds clusters well below this
/// today; the store-sized scratch keeps that true as its bound moves.)
const text_scratch_bytes: usize = canvas.max_display_list_text_bytes;

/// One live emulator session. Heap-owned by the app (the model holds a
/// pointer): the emulator allocates internally and its state is derived
/// entirely from journaled inputs — fed pty bytes, resizes, and
/// selection edits — so a replayed session rebuilds it byte-identical.
pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState,
    /// Terminal answers to queries (DSR, DA1, XTVERSION, ...) produced
    /// while feeding output; the app drains this after every feed and
    /// writes it back to the pty. Heap-allocated and GROWN TO FIT (up to
    /// `response_capacity_max`): replies may sit retained here while the
    /// app's outbound ring is full, and further output keeps feeding —
    /// its replies must accumulate, not evaporate. A reply past the max
    /// (a child that ignored the whole pending ring while pipelining
    /// queries) is dropped WHOLE (never cut, which would desync the
    /// child's parser) and counted — the honest record that a reply was
    /// lost, checkable by the app.
    response_buffer: []u8 = &.{},
    response_len: usize = 0,
    responses_dropped: u32 = 0,
    /// Cached viewport plain text (see `refreshScreenText`): the grid's
    /// accessibility surface and the fingerprint's cell-state coverage.
    /// Heap-owned and EXACT — each refresh keeps the renderer's whole
    /// allocation, so the semantic text is never truncated (or cut
    /// mid-scalar) by an intermediate buffer: what paints is what
    /// assistive tech reads and what the fingerprint hashes. Empty
    /// means "unknown", never "same as before".
    screen_text: []const u8 = &.{},
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

    /// Query-answer buffer's INITIAL size (it grows to fit).
    pub const response_capacity: usize = 16 * 1024;

    /// The growth ceiling — matched to the app's pending-outbound ring:
    /// retained replies past this could never be enqueued whole anyway,
    /// so growing further would only defer the same counted drop.
    pub const response_capacity_max: usize = 256 * 1024;

    /// The app feeds output in sub-slices no larger than this, draining
    /// answers after each, so a burst of pipelined query replies cannot
    /// outrun the response buffer within one feed. A reply can be several
    /// times its triggering query (XTVERSION and the primary DA answer a
    /// ~4-byte request with ~25 bytes), so the slice is the buffer scaled
    /// down by a generous worst-case expansion factor: even an unbroken
    /// run of the shortest high-expansion query across a full slice
    /// produces fewer reply bytes than the buffer holds. That keeps the
    /// write-back lossless; `responses_dropped` stays the honest fallback
    /// count should a reply ever overflow anyway.
    pub const feed_slice_bytes: usize = response_capacity / 16;

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
        errdefer session.term.deinit(gpa);
        session.response_buffer = try gpa.alloc(u8, response_capacity);
        session.stream = .initAlloc(gpa, .init(&session.term));
        session.installStreamEffects();
        return session;
    }

    /// Wire the stream handler's effect callbacks — only `write_pty`
    /// (query answers routed back to the pty); everything else stays
    /// null (the emulator's read-only defaults). Called at create and
    /// after `reset` rebuilds the stream.
    fn installStreamEffects(session: *Session) void {
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
    }

    pub fn destroy(session: *Session) void {
        const gpa = session.gpa;
        session.render.deinit(gpa);
        session.stream.deinit();
        session.term.deinit(gpa);
        gpa.free(session.response_buffer);
        if (session.screen_text.len > 0) gpa.free(session.screen_text);
        gpa.destroy(session);
    }

    /// Feed one pty output batch through the VT stream. Parser state
    /// persists across batches (escape sequences split at a chunk
    /// boundary keep parsing).
    pub fn feed(session: *Session, bytes: []const u8) void {
        session.stream.nextSlice(bytes);
    }

    /// Hard-reset the emulator for a fresh session (a RIS): clears the
    /// screen, scrollback, modes (application-cursor, reverse video),
    /// palette overrides, and — by rebuilding the stream — any partial
    /// escape sequence left mid-parse. Without this, restarting a shell
    /// after the previous one exited mid-sequence or in a non-default
    /// mode would misencode the new shell's keys or misparse its first
    /// output as a continuation of the old stream.
    pub fn reset(session: *Session) void {
        session.term.fullReset();
        // `fullReset` (a RIS) leaves the OSC color state alone, so clear
        // it here: a shell that overrode palette entries (OSC 4) or the
        // foreground/background/cursor colors (OSC 10/11/12) and exited
        // must not tint the next session. Overrides drop; the theme
        // defaults stay (paint refreshes them every frame anyway).
        session.term.colors.foreground.override = null;
        session.term.colors.background.override = null;
        session.term.colors.cursor.override = null;
        session.term.colors.palette.resetAll();
        session.stream.deinit();
        session.stream = .initAlloc(session.gpa, .init(&session.term));
        session.installStreamEffects();
        session.response_len = 0;
        session.responses_dropped = 0;
        session.clearSelection();
        session.select_head = .{};
        session.select_block = false;
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
        const needed = session.response_len + bytes.len;
        if (needed > session.response_buffer.len) {
            // Grow to fit (doubling), up to the ceiling: replies may be
            // retained here across feeds while the app's outbound ring
            // is full, so accumulation is normal, not exceptional. Past
            // the ceiling — or under allocation failure — the reply
            // drops WHOLE and counted, never cut.
            if (needed > response_capacity_max) {
                session.responses_dropped +|= 1;
                return;
            }
            var new_cap = @max(session.response_buffer.len * 2, response_capacity);
            while (new_cap < needed) new_cap *= 2;
            if (new_cap > response_capacity_max) new_cap = response_capacity_max;
            if (session.gpa.realloc(session.response_buffer, new_cap)) |grown| {
                session.response_buffer = grown;
            } else |_| {
                session.responses_dropped +|= 1;
                return;
            }
        }
        @memcpy(session.response_buffer[session.response_len..needed], bytes);
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
        // Reflow moves every cell, so keyboard-selection coordinates
        // into the OLD grid are meaningless (and a caret past the new
        // edge would strand Shift+Arrow and copy on cells that no
        // longer exist). Re-anchor at the clamped head: selection mode
        // stays armed, the caret lands inside the new grid, and the
        // stale range is dropped rather than copied.
        if (session.select_anchor != null) {
            session.select_head = .{
                .x = @intCast(@min(@as(usize, session.select_head.x), @as(usize, session.term.cols) - 1)),
                .y = @intCast(@min(@as(usize, session.select_head.y), @as(usize, session.term.rows) - 1)),
            };
            session.select_anchor = session.select_head;
            session.applySelection();
        }
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
        session.scrollTracked(.{ .delta_row = delta });
    }

    pub fn scrollToBottom(session: *Session) void {
        session.scrollTracked(.{ .active = {} });
    }

    pub fn scrollToTop(session: *Session) void {
        session.scrollTracked(.{ .top = {} });
    }

    /// Every scroll goes through here: a scroll that actually MOVED the
    /// viewport changes what the screen shows, so the cached semantic
    /// text refreshes with it — scrollback browsing must read (to
    /// assistive tech) and fingerprint as the rows it paints, never the
    /// bottom viewport it left. The offset compare keeps the common
    /// no-op (`scrollToBottom` before typing while already pinned) from
    /// re-rendering the screen text every keystroke.
    fn scrollTracked(session: *Session, behavior: vt.PageList.Scroll) void {
        const before = session.scrollbar().offset;
        session.term.screens.active.pages.scroll(behavior);
        if (session.scrollbar().offset != before) session.refreshScreenText();
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
        // Any failure below CLEARS the emulator selection rather than
        // leaving the previous range live: the model caret has already
        // moved, so a copy against the stale range would return text
        // the painted outline no longer describes. No-selection is the
        // honest degraded state — the caret keeps painting from
        // `select_head`, and the next successful move re-establishes
        // the highlight.
        const tl = screen.pages.pin(.{ .viewport = .{ .x = anchor.x, .y = anchor.y } }) orelse {
            screen.clearSelection();
            return;
        };
        const br = screen.pages.pin(.{ .viewport = .{ .x = session.select_head.x, .y = session.select_head.y } }) orelse {
            screen.clearSelection();
            return;
        };
        screen.select(vt.Selection.init(tl, br, session.select_block)) catch screen.clearSelection();
    }

    /// The selected text, caller-owned (freed with the sentinel).
    /// Null means exactly "nothing is selected" — a serialization
    /// failure over an ACTIVE selection is an error, never a silent
    /// null: the caller owes the user a failure signal when a copy
    /// cannot be produced.
    pub fn selectionText(session: *Session, gpa: std.mem.Allocator) !?[:0]const u8 {
        const screen = session.term.screens.active;
        const selection = screen.selection orelse return null;
        return try screen.selectionString(gpa, .{ .sel = selection, .trim = true });
    }

    /// The viewport as plain text — the test and automation view of the
    /// grid (real cell state, no pixels).
    pub fn plainText(session: *Session, gpa: std.mem.Allocator) ![]const u8 {
        return session.term.plainString(gpa);
    }

    /// Refresh the cached viewport text — the grid's ACCESSIBILITY
    /// surface (a terminal's semantic content IS its text) and, through
    /// the a11y tree, the session-fingerprint coverage of real cell
    /// state: two screens with identical byte counters but different
    /// cells must never fingerprint alike. Called wherever the visible
    /// screen changes (output feeds, resizes, the restart reset, and
    /// scrolls that moved the viewport).
    pub fn refreshScreenText(session: *Session) void {
        const text = session.term.plainString(session.gpa) catch {
            // Unknown beats stale: a screen we could not render must
            // not keep reading (to assistive tech) or fingerprinting as
            // the previous one — the emulator and the painted grid have
            // already advanced. Empty is the loud degraded state (the
            // view falls back to its static label, and any checkpoint
            // over it diverges rather than false-verifying).
            if (session.screen_text.len > 0) session.gpa.free(session.screen_text);
            session.screen_text = &.{};
            return;
        };
        if (session.screen_text.len > 0) session.gpa.free(session.screen_text);
        session.screen_text = text;
    }

    /// The cached viewport text (see `refreshScreenText`).
    pub fn screenText(session: *const Session) []const u8 {
        return session.screen_text;
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
    /// Display-list TEXT bytes to hold back from the grid for the widgets
    /// the app appends AFTER this chrome prefix (a header, a status line).
    /// Those widgets draw their own glyphs into the SAME per-view text
    /// store (`canvas.max_display_list_text_bytes`), so a grapheme-heavy
    /// grid that consumed all of it would push the combined display list
    /// over the runtime limit and fail the whole frame — leaving stale
    /// content. Reserving their worst-case text here makes the grid
    /// degrade to a few fewer painted rows instead, and the widgets
    /// always fit. 0 means the grid may use the whole store (tests that
    /// paint no widgets).
    text_reserve: usize = 0,
    /// Ceiling on DISTINCT code points the grid may put on screen in one
    /// paint — a proxy bound for the runtime's per-view glyph-atlas
    /// entries, which an adversarial screen (thousands of distinct
    /// scalars plus distinct combining marks) can exhaust long before
    /// the command or text budgets bind, failing the whole frame
    /// instead of a row. Painting stops row-atomically BEFORE the row
    /// whose new code points would cross it. 0 means unbounded (tests
    /// that size their own builder).
    glyph_budget: usize = 0,
};

/// Distinct-code-point probe set backing `PaintOptions.glyph_budget`:
/// open-addressed, power-of-two slots, zero meaning empty (a stored
/// value is `cp + 1` so U+0000 never aliases an empty slot). Sized at
/// twice the runtime's per-view atlas capacity so any honest budget
/// stays under half load and lookups stay O(1); budgets are clamped to
/// half the slots so the probe loop can never run against a full table.
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
/// mirroring the paint loop's emissions exactly (spacer cells and
/// invisible-styled cells contribute nothing). Entries inserted by a
/// row the budget then rejects stay in the set harmlessly: painting
/// stops at that row, so the set is never consulted again.
fn rowNewGlyphs(row: anytype, seen: *[glyph_probe_slots]u32) usize {
    var new_count: usize = 0;
    var i: usize = 0;
    while (i < row.cells.len) : (i += 1) {
        const cell = row.cells.get(i);
        if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) continue;
        const cp: u21 = switch (cell.raw.content_tag) {
            .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
            else => 0,
        };
        if (cp == 0) continue;
        if (cell.raw.style_id != 0 and cell.style.flags.invisible) continue;
        if (glyphProbeInsert(seen, cp)) new_count += 1;
        if (cell.raw.content_tag == .codepoint_grapheme) {
            for (cell.grapheme) |extra| {
                if (glyphProbeInsert(seen, extra)) new_count += 1;
            }
        }
    }
    return new_count;
}

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

    // Push the theme colors into the emulator's DEFAULTS (not the OSC
    // overrides), so ghostty itself composes the final foreground,
    // background, and cursor: an unstyled terminal resolves to the
    // theme, an application's OSC 10/11/12 override wins, and DECSCNM
    // reverse-video swaps whichever pair is in effect. The renderer then
    // reads `rs.colors` verbatim — no second, divergent color policy
    // here. Setting `.default` never clobbers a live `.override`.
    session.term.colors.foreground.default = themeRgb(tokens.colors.text);
    session.term.colors.background.default = themeRgb(tokens.colors.background);
    session.term.colors.cursor.default = themeRgb(tokens.colors.accent);

    try session.render.update(session.gpa, &session.term);
    const rs = &session.render;
    const palette = Palette.init(tokens, &rs.colors, &session.term.colors.palette);

    // The terminal surface: full-bleed theme background under the grid.
    try builder.fillRect(.{
        .id = grid_id_base,
        .rect = options.frame,
        .fill = .{ .color = palette.background },
    });

    // Everything the grid paints is CLIPPED to its frame: for one frame
    // after a shrink, the emulator still holds the pre-resize grid (the
    // resize lands via the journaled viewport Msg), and unclipped rows
    // or wide cells would paint over the status bar and past the right
    // edge. The clip makes the stale frame degrade to a cropped grid.
    try builder.pushClip(.{ .id = grid_id_base + 0x4_0000_0000, .rect = options.frame });

    const origin_x = options.frame.x;
    const origin_y = options.frame.y;
    const cell_w = session.cell_width;
    const cell_h = session.cell_height;

    // Worst case for one row, when no runs merge (every cell a distinct
    // style): a background run, a text run, AND an underline run per
    // column — three commands each — plus one selection wash. Reserve
    // that so the LAST painted row can never push the list past the
    // budget; the cursor, scrollbar, and clip push/pop (+4) fit under
    // the same reserve.
    const row_reserve: usize = max_cols * 3 + 6;
    const row_ceiling: usize = if (options.command_budget > row_reserve)
        options.command_budget - row_reserve
    else
        0;
    // The display-list TEXT store is a separate budget from the command
    // count: a screen of multi-codepoint graphemes (emoji) can exhaust
    // its bytes long before the command budget. Each row is emitted
    // ATOMICALLY — its exact text-byte need is measured up front and the
    // row is skipped WHOLE if it would not fit the remaining store — so
    // the grid degrades to fewer complete rows, never a row torn
    // mid-way by an allocation failure.
    const text_store: usize = if (canvas.max_display_list_text_bytes > options.text_reserve)
        canvas.max_display_list_text_bytes - options.text_reserve
    else
        0;
    var text_bytes_emitted: usize = 0;

    // The glyph-atlas proxy budget (see `PaintOptions.glyph_budget`):
    // clamped under half the probe table so insertion can never scan a
    // full ring; the set costs one 64 KiB clear per bounded paint.
    const glyph_budget = @min(options.glyph_budget, glyph_probe_slots / 2);
    var glyph_seen: [glyph_probe_slots]u32 = undefined;
    if (glyph_budget > 0) @memset(&glyph_seen, 0);
    var glyphs_counted: usize = 0;

    // A run's staging buffer, sized to the whole text store (see
    // `text_scratch_bytes`): any cluster the store can hold stages
    // whole. The run-break flushes when the buffer nears full, so long
    // runs simply split across draw commands rather than overflow.
    var text_scratch: [text_scratch_bytes]u8 = undefined;
    var row_index: usize = 0;
    while (row_index < rs.row_data.len) : (row_index += 1) {
        // Command-count stop: once within one row's worst case of the
        // command ceiling, stop painting further rows.
        if (options.command_budget > 0 and builder.displayList().commands.len >= row_ceiling) break;
        const row = rs.row_data.get(row_index);
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
        const row_id = grid_id_base + (@as(u64, @intCast(row_index)) << 16);

        // Background runs: contiguous cells sharing a non-default bg.
        var run_start: usize = 0;
        var run_color: ?canvas.Color = null;
        var prev_bg: ?canvas.Color = null;
        var x: usize = 0;
        while (x <= row.cells.len) : (x += 1) {
            const bg: ?canvas.Color = if (x < row.cells.len) blk: {
                const cell = row.cells.get(x);
                // A wide glyph's style lives on its PRIMARY cell only:
                // the spacer tail extends the primary's background, or a
                // styled wide character (red-on-`界`, inverse video)
                // would paint over half its width.
                if (cell.raw.wide == .spacer_tail) break :blk prev_bg;
                break :blk cellBackground(cell, &palette);
            } else null;
            prev_bg = bg;
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
            // The current cell's full byte need (primary code point plus
            // any grapheme marks): the run breaks BEFORE a cell that
            // would not fit the remaining scratch, so the cell restarts
            // in a fresh buffer and a large grapheme landing near the
            // buffer's end keeps all its marks instead of being cut.
            const cell_bytes: usize = if (x < row.cells.len and cp != 0) cellTextBytes(row.cells.get(x)) else 0;
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
                    .size = session.font_size,
                    .origin = geometry.PointF.init(
                        origin_x + @as(f32, @floatFromInt(run_x)) * cell_w,
                        row_y + (cell_h - session.font_size) * 0.5,
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
                    // Stop before a partial code point: the break lands
                    // BETWEEN combining marks, so the emitted run is
                    // always valid UTF-8. The buffer is the whole text
                    // store, and the row preflight already skipped any
                    // row whose cluster bytes exceed it — this floor is
                    // defensive, never the working bound.
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
    try builder.popClip();
}

/// UTF-8 byte need of one cell's rendered text: its primary code point
/// plus every grapheme combining mark. Used to break a run before a
/// cell that would overflow the run scratch, and to measure a row's
/// total for the atomic text-store stop.
/// The bytes painting will actually EMIT for one cell — the preflight
/// (`rowTextBytes`) sums these against the text store, so this must
/// mirror the paint loop's suppressions exactly: an invisible-styled
/// cell paints nothing, and a cluster's marks stop at the run scratch's
/// capacity (the store itself). Counting suppressed bytes would measure
/// a paintable row past the budget and silently blank every row after
/// it.
fn cellTextBytes(cell: anytype) usize {
    const cp: u21 = switch (cell.raw.content_tag) {
        .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
        else => 0,
    };
    if (cp == 0) return 0;
    if (cell.raw.style_id != 0 and cell.style.flags.invisible) return 0;
    var n: usize = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
    if (cell.raw.content_tag == .codepoint_grapheme) {
        for (cell.grapheme) |extra| {
            // The paint loop's mark cap, from a fresh buffer (an
            // oversized cell always restarts one): stop where it stops.
            if (n + 8 > text_scratch_bytes) break;
            n += std.unicode.utf8CodepointSequenceLength(extra) catch 1;
        }
    }
    return n;
}

fn rowTextBytes(row: anytype) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < row.cells.len) : (i += 1) total += cellTextBytes(row.cells.get(i));
    return total;
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
/// A theme token color (f32 rgba 0..1) as the emulator's 8-bit RGB.
fn themeRgb(color: canvas.Color) vt.color.RGB {
    return .{
        .r = @intFromFloat(std.math.clamp(color.r, 0, 1) * 255 + 0.5),
        .g = @intFromFloat(std.math.clamp(color.g, 0, 1) * 255 + 0.5),
        .b = @intFromFloat(std.math.clamp(color.b, 0, 1) * 255 + 0.5),
    };
}

fn rgbToColor(rgb: vt.color.RGB) canvas.Color {
    return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
}

const Palette = struct {
    background: canvas.Color,
    foreground: canvas.Color,
    cursor: canvas.Color,
    selection: canvas.Color,
    ansi: [16]canvas.Color,
    terminal: *const vt.RenderState.Colors,
    /// The emulator's live palette WITH its override mask, so an
    /// explicit OSC 4 set is honored even when it happens to equal the
    /// default RGB — the mask, not RGB equality, decides "untouched".
    dynamic: *const vt.color.DynamicPalette,

    fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors, dynamic: *const vt.color.DynamicPalette) Palette {
        const colors = tokens.colors;
        const dark = colors.background.r + colors.background.g + colors.background.b < 1.5;
        const dim: f32 = if (dark) 0.85 else 1.0;
        const bright: f32 = if (dark) 1.0 else 0.8;
        // Primary colors come from the emulator's resolved render state
        // — which already folded in the theme defaults pushed above plus
        // any OSC 10/11/12 override and DECSCNM reverse swap — so an
        // application that recolors its terminal is honored exactly.
        // (`background`/`foreground` are always populated once a default
        // is set; `cursor` falls back to the accent if the emulator left
        // it unset.)
        return .{
            .background = rgbToColor(terminal_colors.background),
            .foreground = rgbToColor(terminal_colors.foreground),
            .cursor = if (terminal_colors.cursor) |cur| rgbToColor(cur) else colors.accent,
            .selection = colors.accent,
            .terminal = terminal_colors,
            .dynamic = dynamic,
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

    /// Palette index -> color: theme-derived for UNTOUCHED ANSI-16
    /// entries, the emulator's live palette everywhere else. "Untouched"
    /// is the emulator's own override mask, not RGB equality — a program
    /// that OSC-4-sets a slot to exactly the default RGB has still
    /// chosen it, and its choice is honored rather than replaced by the
    /// theme color.
    fn indexed(palette: *const Palette, index: u8) canvas.Color {
        if (index < 16 and !palette.dynamic.mask.isSet(index)) {
            return palette.ansi[index];
        }
        const live = palette.dynamic.current[index];
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
