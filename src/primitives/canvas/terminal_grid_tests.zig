//! Terminal grid painter tests: snapshot-in, display-list-out. The
//! snapshots are hand-built (the painter's contract is resolved cell
//! data — no emulator here), so every assertion pins painter policy:
//! real text runs, run merging, geometric box drawing, the selection
//! wash, the cursor register, and the three row-atomic budgets.

const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");
const grid_model = @import("terminal_grid.zig");
const box = @import("terminal_box.zig");
const equality_model = @import("equality.zig");

const testing = std.testing;

const white = canvas.Color.rgba(1, 1, 1, 1);
const black = canvas.Color.rgba(0, 0, 0, 1);
const red = canvas.Color.rgba(1, 0, 0, 1);
const blue = canvas.Color.rgba(0, 0, 1, 1);

fn cell(cp: u21, cluster: []const u8, fg: canvas.Color) grid_model.TerminalCell {
    return .{ .cp = cp, .cluster = cluster, .fg = fg };
}

fn asciiRow(comptime text: []const u8, fg: canvas.Color) [text.len]grid_model.TerminalCell {
    var cells: [text.len]grid_model.TerminalCell = undefined;
    inline for (text, 0..) |ch, index| {
        cells[index] = if (ch == ' ')
            .{}
        else
            cell(ch, text[index .. index + 1], fg);
    }
    return cells;
}

fn baseGrid(rows: []const grid_model.TerminalRow) grid_model.TerminalGrid {
    return .{
        .rows = rows,
        .background = black,
        .foreground = white,
        .cursor_color = blue,
        .selection_color = blue,
    };
}

/// Paint into a builder the CALLER owns.
///
/// Deliberately not "return a builder": an emitter's slices point into
/// the builder's own stores (text bytes, path elements, a grid's
/// cells), so handing a Builder back by value aims every one of them at
/// a dead stack frame. Text runs were small enough to survive that by
/// luck; a packed cell grid is not.
fn paintInto(grid: grid_model.TerminalGrid, builder: *canvas.Builder, options: grid_model.TerminalPaintOptions) !void {
    try grid_model.paint(grid, builder, options);
}

// ------------------------------------------------- cell-grid helpers
//
// The painter emits ONE `cell_grid` command for a screen (see
// canvas/cell_grid.zig), so the assertions below read cells rather than
// per-run `draw_text` commands. What each test PINS is unchanged; only
// the surface it reads moved.

fn firstCellGrid(list: canvas.DisplayList) ?canvas.CellGrid {
    for (list.commands) |command| {
        if (command == .cell_grid) return command.cell_grid;
    }
    return null;
}

fn gridCell(list: canvas.DisplayList, x: usize, y: usize) ?canvas.Cell {
    const grid = firstCellGrid(list) orelse return null;
    return grid.at(x, y);
}

fn gridCluster(list: canvas.DisplayList, x: usize, y: usize) []const u8 {
    const grid = firstCellGrid(list) orelse return "";
    const cell_value = grid.at(x, y) orelse return "";
    return cell_value.cluster(grid.text);
}

/// The cluster bytes of row `y`, columns 0..cols, concatenated into
/// `out` — the row as a renderer would ink it.
fn gridRowText(list: canvas.DisplayList, y: usize, out: []u8) []const u8 {
    const grid = firstCellGrid(list) orelse return "";
    var len: usize = 0;
    var x: usize = 0;
    while (x < grid.cols) : (x += 1) {
        const cell_value = grid.at(x, y) orelse continue;
        const bytes = cell_value.cluster(grid.text);
        if (len + bytes.len > out.len) break;
        @memcpy(out[len..][0..bytes.len], bytes);
        len += bytes.len;
    }
    return out[0..len];
}

/// Rows of the grid that carry any ink or background — what "painted"
/// means once a screen is one command.
fn gridPaintedRows(list: canvas.DisplayList) usize {
    const grid = firstCellGrid(list) orelse return 0;
    return grid.rows;
}

test "the grid carries a per-cell foreground" {
    const row_cells = comptime asciiRow("hi red", white);
    var cells = row_cells;
    // Recolor the "red" run.
    cells[3].fg = red;
    cells[4].fg = red;
    cells[5].fg = red;
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    // Colour is a property of the CELL now, not of a merged run: the
    // renderer inks each cell with its own foreground, so a colour
    // change costs nothing and merges nothing.
    var text_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("hired", gridRowText(list, 0, &text_buffer));
    const h = gridCell(list, 0, 0) orelse return error.TestExpectedCell;
    try testing.expectEqual(canvas.CellColor.fromColor(white), h.fg);
    const r = gridCell(list, 3, 0) orelse return error.TestExpectedCell;
    try testing.expectEqual(canvas.CellColor.fromColor(red), r.fg);
    // The space between them inks nothing and keeps no cluster.
    const gap = gridCell(list, 2, 0) orelse return error.TestExpectedCell;
    try testing.expectEqual(@as(u8, 0), gap.text_len);
}

test "wide cells advance two columns and spacers carry no ink" {
    // "你!" — the wide cell occupies columns 0-1, '!' lands at column 2.
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 0x4F60, .cluster = "\xe4\xbd\xa0", .fg = white, .wide = .wide },
        .{ .wide = .spacer },
        cell('!', "!", white),
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();
    const grid = firstCellGrid(list) orelse return error.TestExpectedCellGrid;

    // The lattice puts '!' at column 2 by CONSTRUCTION — a cell's
    // position is its index, so a wide cluster can no longer shift its
    // neighbours off the grid however the face advances it.
    try testing.expectEqualStrings("\xe4\xbd\xa0", gridCluster(list, 0, 0));
    try testing.expectEqualStrings("!", gridCluster(list, 2, 0));
    const wide_cell = grid.at(0, 0) orelse return error.TestExpectedCell;
    try testing.expectEqual(canvas.CellWidth.wide, wide_cell.style().width);
    const spacer = grid.at(1, 0) orelse return error.TestExpectedCell;
    try testing.expectEqual(canvas.CellWidth.spacer, spacer.style().width);
    try testing.expectEqual(@as(u8, 0), spacer.text_len);
    // Column 2's rect is two cells in.
    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    try testing.expectApproxEqAbs(metrics.width * 2, grid.cellRect(2, 0).x, 0.01);
}

test "box-drawing cells render as geometry, never text" {
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 0x2500, .fg = white }, // ─
        .{ .cp = 0x2500, .fg = white },
        .{ .cp = 0x2502, .fg = white }, // │
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    var text_commands: usize = 0;
    var fills: usize = 0;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => text_commands += 1,
            .fill_rect => fills += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), text_commands);
    // Background + the merged ─ run + the │ bar at least.
    try testing.expect(fills >= 3);
}

test "the selection wash and keyboard caret paint from snapshot state" {
    const row_cells = comptime asciiRow("select me", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells, .selection = .{ 0, 5 } }};
    var grid = baseGrid(&rows);
    grid.select_head = .{ .x = 5, .y = 0 };

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(grid, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    var saw_wash = false;
    var saw_caret = false;
    for (list.commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.fill == .color and fill.fill.color.a > 0.29 and fill.fill.color.a < 0.31) saw_wash = true;
            },
            .stroke_rect => saw_caret = true,
            else => {},
        }
    }
    try testing.expect(saw_wash);
    try testing.expect(saw_caret);
}

test "the cursor register: filled only while focused and live, hollow otherwise" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };

    var commands: [16]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(grid, &builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
        .focused = true,
    });
    var running_alpha: f32 = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.fill == .color and fill.fill.color.b == blue.b and fill.fill.color.a < 1) running_alpha = fill.fill.color.a;
            },
            else => {},
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.45), running_alpha, 0.001);

    var blurred_commands: [16]canvas.CanvasCommand = undefined;
    var blurred_builder = canvas.Builder.init(&blurred_commands);
    try paintInto(grid, &blurred_builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
        .focused = false,
    });
    var blurred_alpha: f32 = 0;
    for (blurred_builder.displayList().commands) |command| {
        switch (command) {
            .stroke_rect => |stroke| {
                if (stroke.stroke.fill == .color and stroke.stroke.fill.color.b == blue.b) {
                    blurred_alpha = stroke.stroke.fill.color.a;
                    try testing.expectEqual(@as(f32, 1), stroke.stroke.width);
                }
            },
            else => {},
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.45), blurred_alpha, 0.001);

    grid.running = false;
    var ended_commands: [16]canvas.CanvasCommand = undefined;
    var ended_builder = canvas.Builder.init(&ended_commands);
    try paintInto(grid, &ended_builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
        .focused = true,
    });
    var ended_alpha: f32 = 0;
    for (ended_builder.displayList().commands) |command| {
        switch (command) {
            .stroke_rect => |stroke| {
                if (stroke.stroke.fill == .color and stroke.stroke.fill.color.b == blue.b) {
                    ended_alpha = stroke.stroke.fill.color.a;
                    try testing.expectEqual(@as(f32, 1), stroke.stroke.width);
                }
            },
            else => {},
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.22), ended_alpha, 0.001);
}

test "the terminal widget cursor follows logical focus independently of the outer ring" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };
    const terminal = canvas.Widget{
        .id = 9,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 200, 100),
        .terminal = .{ .pty = 1, .grid = &grid },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(terminal, terminal.frame, &nodes);
    const cursor_id = grid_model.paintIdBase(terminal.id) + 0x61_0002;

    // Logical focus fills the cursor even when the modality-specific
    // outer ring is quiet.
    var focused_commands: [32]canvas.CanvasCommand = undefined;
    var focused_builder = canvas.Builder.init(&focused_commands);
    try layout.emitDisplayListWithState(&focused_builder, .{}, .{ .focused_id = terminal.id });
    var saw_filled_cursor = false;
    var saw_outer_ring = false;
    for (focused_builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| if (fill.id == cursor_id) {
                saw_filled_cursor = true;
            },
            .stroke_rect => |stroke| if (stroke.id != cursor_id) {
                saw_outer_ring = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_filled_cursor);
    try testing.expect(!saw_outer_ring);

    var blurred_commands: [32]canvas.CanvasCommand = undefined;
    var blurred_builder = canvas.Builder.init(&blurred_commands);
    try layout.emitDisplayListWithState(&blurred_builder, .{}, .{
        .keyboard_active = false,
        .focused_id = terminal.id,
        .focus_visible_id = terminal.id,
    });
    var saw_hollow_cursor = false;
    var kept_outer_ring = false;
    for (blurred_builder.displayList().commands) |command| {
        switch (command) {
            .stroke_rect => |stroke| if (stroke.id == cursor_id) {
                saw_hollow_cursor = true;
            } else {
                kept_outer_ring = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_hollow_cursor);
    // Key-window/app activity gates the terminal's ownership cue only;
    // retained focus-visible chrome keeps its normal restoration state.
    try testing.expect(kept_outer_ring);
}

test "the scrollback thumb paints only while the viewport is in history" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);

    // Pinned to the bottom: no thumb.
    grid.scrollbar = .{ .offset = 76, .len = 24, .total = 100 };
    var pinned_commands: [16]canvas.CanvasCommand = undefined;
    var pinned = canvas.Builder.init(&pinned_commands);
    try paintInto(grid, &pinned, .{
        .frame = geometry.RectF.init(0, 0, 100, 200),
        .tokens = .{},
    });
    const pinned_count = pinned.displayList().commands.len;

    // Scrolled into history: exactly one extra fill (the thumb).
    grid.scrollbar = .{ .offset = 10, .len = 24, .total = 100 };
    var history_commands: [16]canvas.CanvasCommand = undefined;
    var history = canvas.Builder.init(&history_commands);
    try paintInto(grid, &history, .{
        .frame = geometry.RectF.init(0, 0, 100, 200),
        .tokens = .{},
    });
    try testing.expectEqual(pinned_count + 1, history.displayList().commands.len);
}

test "the command budget degrades row-wise, never overflowing the frame" {
    // Three rows of alternating colors (no run merging), tight budget.
    var cells: [3][8]grid_model.TerminalCell = undefined;
    for (&cells) |*row_cells| {
        for (row_cells, 0..) |*entry, index| {
            entry.* = cell('x', "x", if (index % 2 == 0) white else red);
            entry.bg = if (index % 2 == 0) blue else null;
        }
    }
    const rows = [_]grid_model.TerminalRow{
        .{ .cells = &cells[0] },
        .{ .cells = &cells[1] },
        .{ .cells = &cells[2] },
    };

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .command_budget = 60,
    });
    // Never exceeds the budget; the later rows dropped whole.
    try testing.expect(builder.displayList().commands.len <= 60);
}

test "the text budget stops before a row it cannot hold whole" {
    const row_a = comptime asciiRow("aaaa", white);
    const row_b = comptime asciiRow("bbbb", white);
    const rows = [_]grid_model.TerminalRow{
        .{ .cells = &row_a },
        .{ .cells = &row_b },
    };

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        // Reserve all but one byte of the store. The grid INTERNS
        // clusters, so row a's four 'a's cost one byte and row b's
        // four 'b's cost the second — which is the byte that crosses.
        .text_reserve = canvas.max_display_list_text_bytes - 1,
    });
    // Row a's cells reached the lattice; row b's never did, so the grid
    // is one row tall.
    const list = builder.displayList();
    try testing.expectEqual(@as(usize, 1), gridPaintedRows(list));
    var text_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("aaaa", gridRowText(list, 0, &text_buffer));
}

test "the glyph budget stops before the row whose new code points cross it" {
    // Row a introduces 4 distinct glyphs, row b 4 more.
    const row_a = comptime asciiRow("abcd", white);
    const row_b = comptime asciiRow("efgh", white);
    const rows = [_]grid_model.TerminalRow{
        .{ .cells = &row_a },
        .{ .cells = &row_b },
    };

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        // Atlas-entry units: each new code point charges four subpixel
        // variants, so row a (4 cps = 16 entries) fits a 24-entry budget
        // and row b (16 more) crosses it.
        .glyph_budget = 24,
    });
    const list = builder.displayList();
    try testing.expectEqual(@as(usize, 1), gridPaintedRows(list));
    var text_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd", gridRowText(list, 0, &text_buffer));
}

test "a wide row of mergeable box glyphs paints under the widget budget" {
    // 320 identical `─` cells merge to ONE geometry command, so the cost
    // estimate must not charge nine per column and skip the row.
    var box_cells: [320]grid_model.TerminalCell = undefined;
    for (&box_cells) |*c| c.* = .{ .cp = 0x2500, .fg = white };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &box_cells }};

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 2600, 40),
        .tokens = .{},
        .command_budget = 1792,
    });
    var box_fills: usize = 0;
    for (builder.displayList().commands) |command| {
        if (command == .fill_rect) box_fills += 1;
    }
    // Background + the single merged bar (+ no wash: no selection). The
    // row painted rather than being skipped for a bogus 2,880 estimate.
    try testing.expect(box_fills >= 2);
}

test "the text preflight counts referenced sibling text already in the list" {
    // A prior widget's REFERENCED draw_text (not builder-owned) counts
    // against the per-view text budget, so the grid must degrade against
    // it. Pre-emit a referenced-text command consuming most of the view
    // budget, then a terminal row that would cross the ceiling drops.
    const filler = "x" ** (canvas.max_display_list_text_bytes - 4);
    const row = comptime asciiRow("cells", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // Referenced text (a slice not from allocTextBytes), as a sibling
    // text widget emits.
    try builder.drawText(.{ .id = 1, .font_id = 2, .size = 12, .origin = geometry.PointF.init(0, 0), .color = white, .text = filler });
    try testing.expectEqual(@as(usize, 0), builder.text_byte_len); // referenced, not builder-owned

    try grid_model.paint(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    // Only 4 bytes of headroom remained, so the 5-byte row dropped: no
    // grid text command, and the frame's total text stays within budget.
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |t| try testing.expect(!std.mem.eql(u8, t.text, "cells")),
            else => {},
        }
    }
}

test "the prologue budget check accounts for commands already in the builder" {
    // A builder already near an absolute command ceiling must degrade to
    // nothing rather than emit the prologue and overrun. Pre-fill the
    // builder, then paint with a budget at the current length.
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var commands: [16]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    for (0..10) |i| {
        try builder.fillRect(.{ .id = 1000 + i, .rect = geometry.RectF.init(0, 0, 1, 1), .fill = .{ .color = white } });
    }
    const before = builder.len;
    try grid_model.paint(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
        // No room for the prologue above the already-consumed commands.
        .command_budget = before + 2,
    });
    // Nothing emitted (and no unbalanced clip): the len is unchanged.
    try testing.expectEqual(before, builder.len);
}

test "id_base near the u64 ceiling wraps instead of trapping" {
    // paintIdBase spans the full u64 space, so every emitted id offset
    // must wrap. An id_base whose spread lands near maxInt paints a
    // nonempty row without an overflow trap in safe builds.
    const cells = [_]grid_model.TerminalCell{
        cell('x', "x", white),
        .{ .cp = 0x256C, .fg = white }, // ╬ — the eight-command joint
        .{ .cp = 0x256D, .fg = white }, // ╭ — a rounded corner (path elements)
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells, .selection = .{ 0, 2 } }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };
    grid.select_head = .{ .x = 0, .y = 0 };

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // Any id_base is legal; the painter must not trap on the wrap.
    try grid_model.paint(grid, &builder, .{
        .frame = geometry.RectF.init(0, 0, 120, 40),
        .tokens = .{},
        .id_base = 0xffff_ffff_ffff_ffff,
    });
    try testing.expect(builder.displayList().commands.len > 0);
}

test "an underlined merged double run stays within the command budget" {
    // A merged ═ paints TWO bars of geometry; its UNDERLINE is a cell
    // attribute the grid carries, so it costs no command at all. The
    // cost estimate must still charge the bars, or a row of unmergeable
    // doubles (alternating colors break every merge) overruns the
    // ceiling.
    var cells: [320]grid_model.TerminalCell = undefined;
    for (&cells, 0..) |*c, i| {
        c.* = .{ .cp = 0x2550, .fg = if (i % 2 == 0) white else red, .underline = true };
    }
    const rows = [_]grid_model.TerminalRow{
        .{ .cells = &cells },
        .{ .cells = &cells },
    };

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 2600, 80),
        .tokens = .{},
        .command_budget = 1000,
    });
    // Whatever painted, the ceiling held.
    try testing.expect(builder.displayList().commands.len <= 1000);
}

test "ordinary underlined text is costed without integer overflow" {
    var cells: [320]grid_model.TerminalCell = undefined;
    for (&cells, 0..) |*c, i| {
        c.* = cell('x', "x", if (i % 2 == 0) white else red);
        c.underline = true;
    }
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 2600, 40),
        .tokens = .{},
        .command_budget = 700,
    });
    try testing.expect(builder.displayList().commands.len <= 700);
}

test "an anonymous grid keeps the unkeyed convention: every command id 0" {
    const cells = [_]grid_model.TerminalCell{
        cell('x', "x", white),
        .{ .cp = 0x256C, .fg = white }, // ╬
        .{ .cp = 0x2596, .fg = white }, // quadrant
        .{ .cp = 0x256D, .fg = white }, // rounded corner
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells, .selection = .{ 0, 1 } }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(grid, &builder, .{
        .frame = geometry.RectF.init(0, 0, 200, 40),
        .tokens = .{},
        .id_base = 0,
    });
    for (builder.displayList().commands) |command| {
        const id = switch (command) {
            .fill_rect => |c| c.id,
            .stroke_rect => |c| c.id,
            .draw_text => |c| c.id,
            .push_clip => |c| c.id,
            .stroke_path => |c| c.id,
            .draw_line => |c| c.id,
            else => continue,
        };
        try testing.expectEqual(@as(canvas.ObjectId, 0), id);
    }
}

test "two keyed grids in one builder never share a nonzero command id" {
    const row_cells = comptime asciiRow("ab", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // The adversarial pair: id B chosen so B's base lands inside A's
    // old wide-offset namespace. Under the strided scheme both stay
    // disjoint by construction.
    try grid_model.paint(grid, &builder, .{ .frame = geometry.RectF.init(0, 0, 100, 40), .tokens = .{}, .id_base = 1 });
    try grid_model.paint(grid, &builder, .{ .frame = geometry.RectF.init(0, 60, 100, 40), .tokens = .{}, .id_base = 0x64dd_ccf4_0000_0001 });
    var seen: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer seen.deinit(testing.allocator);
    for (builder.displayList().commands) |command| {
        const id = switch (command) {
            .fill_rect => |c| c.id,
            .stroke_rect => |c| c.id,
            .draw_text => |c| c.id,
            .push_clip => |c| c.id,
            else => continue,
        };
        if (id == 0) continue;
        for (seen.items) |prior| try testing.expect(prior != id);
        try seen.append(testing.allocator, id);
    }
}

test "pure-double corners draw nested L joins, never through-bars" {
    const cells = [_]grid_model.TerminalCell{.{ .cp = 0x2554, .fg = white }}; // ╔
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 40, 40),
        .tokens = .{},
    });
    // Background + exactly four bars (two nested Ls).
    var bar_fills: usize = 0;
    var min_x: f32 = 1000;
    var min_y: f32 = 1000;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                // Skip the full-bleed background.
                if (fill.rect.width >= 40) continue;
                bar_fills += 1;
                min_x = @min(min_x, fill.rect.x);
                min_y = @min(min_y, fill.rect.y);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 4), bar_fills);
    // ╔ opens down+right: no bar reaches the cell's left or top edge —
    // the old through-bars did (their stubs crossed the joint).
    try testing.expect(min_x > 0);
    try testing.expect(min_y > 0);
}

test "a wide row of one-bar box pieces paints under the widget budget" {
    // 198 columns of │ emit one bar each; the cost estimate must charge
    // what they paint, not a flat joint worst case that rejects the row.
    var cells: [198]grid_model.TerminalCell = undefined;
    for (&cells) |*c| c.* = .{ .cp = 0x2502, .fg = white };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 1700, 40),
        .tokens = .{},
        .command_budget = 1792,
    });
    var bars: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.rect.width < 40) bars += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 198), bars);
}

test "a row adding no text paints even when siblings spent the text share" {
    // Earlier widgets already sit past the grid's reserved text share;
    // an all-box row ADDS no text, so it must paint — the ceiling bounds
    // what the grid adds, never what siblings spent.
    const filler = "x" ** (canvas.max_display_list_text_bytes - 100);
    var cells: [8]grid_model.TerminalCell = undefined;
    for (&cells) |*c| c.* = .{ .cp = 0x2500, .fg = white };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawText(.{ .id = 1, .font_id = 2, .size = 12, .origin = geometry.PointF.init(0, 0), .color = white, .text = filler });

    try grid_model.paint(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
        // The default widget reserve leaves less than the filler already
        // consumed; the box row adds zero text and must still paint.
        .text_reserve = grid_model.widget_text_reserve,
    });
    // The box row adds no cluster bytes at all — its ink is geometry —
    // so the text ceiling can never reject it however much a sibling
    // widget already spent.
    var box_fills: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.rect.width < 100) box_fills += 1;
            },
            else => {},
        }
    }
    try testing.expect(box_fills >= 1);
}

test "a combining-mark cluster paints alone; its neighbor keeps its cell origin" {
    // "e" + combining acute in cell 0, "!" in cell 1: the cluster must
    // paint as its own run and "!" must start at exactly one cell width
    // — a layout that advanced the mark by a full glyph inside a merged
    // run would have shifted "!" off the grid.
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 'e', .cluster = "e\u{0301}", .fg = white },
        cell('!', "!", white),
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
    });
    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const list = builder.displayList();
    const grid = firstCellGrid(list) orelse return error.TestExpectedCellGrid;
    // The cluster keeps ALL its bytes in one cell, and "!" owns the
    // next: cell positions are indices, so a mark that advances like a
    // full glyph can no longer push its neighbour off the grid. That
    // whole class of bug is gone by construction.
    try testing.expectEqualStrings("e\u{0301}", gridCluster(list, 0, 0));
    try testing.expectEqualStrings("!", gridCluster(list, 1, 0));
    try testing.expectApproxEqAbs(@as(f32, 0), grid.cellRect(0, 0).x, 0.01);
    try testing.expectApproxEqAbs(metrics.width, grid.cellRect(1, 0).x, 0.01);
}

test "the widget diff reports paint damage for a changed bound grid" {
    const row_cells = comptime asciiRow("a", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells }};
    const grid_a = baseGrid(&rows);
    var grid_b = baseGrid(&rows);
    grid_b.cursor = .{ .x = 0, .y = 0 };

    var widget = canvas.Widget{
        .id = 11,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 200, 100),
        .terminal = .{ .pty = 1, .grid = &grid_a },
    };
    var nodes_a: [4]canvas.WidgetLayoutNode = undefined;
    const layout_a = try canvas.layoutWidgetTree(widget, geometry.RectF.init(0, 0, 200, 100), &nodes_a);
    widget.terminal.grid = &grid_b;
    var nodes_b: [4]canvas.WidgetLayoutNode = undefined;
    const layout_b = try canvas.layoutWidgetTree(widget, geometry.RectF.init(0, 0, 200, 100), &nodes_b);

    var output: [8]canvas.WidgetInvalidation = undefined;
    const changes = try layout_a.diff(layout_b, &output);
    var saw_paint_dirty = false;
    for (changes) |change| {
        if (change.id == 11 and change.paint_dirty) saw_paint_dirty = true;
    }
    try testing.expect(saw_paint_dirty);
}

test "clampGrid preserves full bounded viewport geometry" {
    const clamped = grid_model.clampGrid(400, 100);
    try testing.expectEqual(@as(u16, grid_model.max_cols), clamped.x);
    try testing.expectEqual(@as(u16, grid_model.max_rows), clamped.y);
    try testing.expectEqual(grid_model.max_cols * grid_model.max_rows, grid_model.max_cells);
    const tiny = grid_model.clampGrid(0, 0);
    try testing.expectEqual(@as(u16, 2), tiny.x);
    try testing.expectEqual(@as(u16, 2), tiny.y);
}

test "the path reserve holds one maximal filled-line chart series" {
    // A 256-point filled line strokes its polyline and fills its area
    // (points plus closure vertices): the reserve must cover both, or a
    // terminal of rounded corners starves the chart into
    // ChartPathElementListFull.
    try testing.expect(grid_model.widget_path_reserve >= 2 * canvas.max_chart_points_per_series + 3);
}

/// A mono face with a WIDER pitch than the estimator's 0.6 em — what
/// macOS resolves the mono id to when Geist Mono is absent (the system
/// monospaced face, 0.618 em). Everything mono measures at this pitch,
/// so cells and runs both derive from it.
const wide_pitch_em: f32 = 0.62;

fn measureWidePitch(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    _ = context;
    _ = font_id;
    var count: f32 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] & 0xc0 != 0x80) count += 1;
    }
    return count * size * wide_pitch_em;
}

const wide_pitch_provider = canvas.TextMeasureProvider{ .measure_fn = measureWidePitch };

test "a full-width row's runs declare bounds that cover their ink" {
    // The regression: a merged run's raster extent is its own declared
    // bounds, and an estimator-only bound (0.6 em) falls short of a
    // wider host face's ink — the row's last cell sheared off at the
    // widget edge. Cells and bounds must both come from the measurement
    // the host inks with.
    const tokens = canvas.DesignTokens{ .text_measure = &wide_pitch_provider };
    const metrics = grid_model.cellMetrics(tokens);
    try testing.expectApproxEqAbs(
        tokens.typography.label_size * wide_pitch_em,
        metrics.width,
        0.001,
    );

    const row_cells = comptime asciiRow("0123456789012345678901234567890123456789", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells }};
    const frame = geometry.RectF.init(
        0,
        0,
        metrics.width * @as(f32, @floatFromInt(row_cells.len)),
        metrics.height * 2,
    );

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = frame,
        .tokens = tokens,
    });

    // The bug this pins — a host face with a wider pitch inking past a
    // run's declared bounds and shearing the row's last cell — cannot
    // happen to a lattice: the command's bounds ARE the lattice, and
    // every cell's ink is clipped to its own cell. The assertion is now
    // that exact identity.
    const list = builder.displayList();
    const grid = firstCellGrid(list) orelse return error.TestExpectedCellGrid;
    const command = canvas.CanvasCommand{ .cell_grid = grid };
    const rect = command.bounds() orelse return error.MissingTextBounds;
    const ink_right = grid.origin.x + @as(f32, @floatFromInt(grid.cols)) * metrics.width;
    try testing.expectApproxEqAbs(ink_right, rect.x + rect.width, 0.001);
    try testing.expect(ink_right <= frame.x + frame.width + 0.001);
    try testing.expectEqual(@as(u16, @intCast(row_cells.len)), grid.cols);
}

test "cell metrics derive from the mono face and never collapse" {
    const metrics = grid_model.cellMetrics(.{});
    try testing.expect(metrics.width > 0);
    try testing.expect(metrics.height >= metrics.font_size);
}

test "the terminal widget paints its bound grid and the honest empty surface unbound" {
    const row_cells = comptime asciiRow("bound", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells }};
    const grid = baseGrid(&rows);

    // A realistic per-view builder (the widget path floors a builder at
    // or under the reserve to a degrade-only budget).
    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const bound = canvas.Widget{
        .id = 7,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .terminal = .{ .pty = 1, .grid = &grid },
    };
    try canvas.emitWidgetTree(&builder, bound, .{});
    var text_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("bound", gridRowText(builder.displayList(), 0, &text_buffer));

    // Unbound: one background fill, no text, never a hole.
    var empty_commands: [16]canvas.CanvasCommand = undefined;
    var empty_builder = canvas.Builder.init(&empty_commands);
    const unbound = canvas.Widget{
        .id = 8,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 400, 200),
    };
    try canvas.emitWidgetTree(&empty_builder, unbound, .{});
    var fills: usize = 0;
    var grids: usize = 0;
    for (empty_builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => fills += 1,
            .cell_grid => grids += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), fills);
    try testing.expectEqual(@as(usize, 0), grids);
}

test "a wide cheap terminal paints its rows under the widget command budget" {
    // 198 columns of plain ASCII across several rows: the per-row cost
    // preflight must let these cheap rows paint (a flat worst-case-per-
    // column reserve would seat none). Regression for the over-reserve
    // that blanked wide grids.
    var storage: [6][198]grid_model.TerminalCell = undefined;
    for (&storage) |*row_cells| {
        for (row_cells) |*entry| entry.* = cell('a', "a", white);
    }
    var rows: [6]grid_model.TerminalRow = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .cells = &storage[i] };

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 1600, 200),
        .tokens = .{},
        .command_budget = 1792,
    });
    // All six rows reach the lattice, and the whole screen is ONE
    // command — the over-reserve this pins cannot recur, because rows no
    // longer compete for command slots at all.
    const list = builder.displayList();
    try testing.expectEqual(@as(usize, 6), gridPaintedRows(list));
    var text_buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("a" ** 198, gridRowText(list, 5, &text_buffer));
}

test "a tall sparse colored terminal paints every representable row" {
    // cmatrix-like content: a tall viewport with sparse colored streaks. The
    // old per-cell upper bound charged every empty span and stopped around the
    // middle even though actual merged runs fit comfortably in the envelope.
    const row_count = 60;
    const col_count = 200;
    var storage: [row_count][col_count]grid_model.TerminalCell = @splat(@splat(.{}));
    var rows: [row_count]grid_model.TerminalRow = undefined;
    for (&storage, 0..) |*row_cells, row_index| {
        for (0..10) |streak| {
            const col = (streak * 19 + row_index * 3) % col_count;
            row_cells[col] = cell('x', "x", if (streak % 3 == 0) white else red);
        }
        rows[row_index] = .{ .cells = row_cells };
    }

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 1600, 1200),
        .tokens = .{},
        .command_budget = 1792,
    });
    const list = builder.displayList();
    try testing.expectEqual(@as(usize, row_count), gridPaintedRows(list));
    try testing.expect(list.commands.len <= 1792);
}

test "a focused bound terminal's ring id never collides with a grid command" {
    const row_cells = comptime asciiRow("shell", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row_cells }};
    const grid = baseGrid(&rows);

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const focused = canvas.Widget{
        // A high-entropy id in the range where the multiplicative spread
        // could alias a widgetPartId ring slot.
        .id = 0x2af6_89b9_153d_e19a,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .state = .{ .focused = true },
        .terminal = .{ .pty = 1, .grid = &grid },
    };
    try canvas.emitWidgetTree(&builder, focused, .{});
    var ring_id: canvas.ObjectId = 0;
    for (builder.displayList().commands) |command| {
        if (command == .stroke_rect) ring_id = command.stroke_rect.id;
    }
    try testing.expect(ring_id != 0);
    // No other command shares the ring's id.
    var collisions: usize = 0;
    for (builder.displayList().commands) |command| {
        const id = switch (command) {
            .fill_rect => |c| c.id,
            .draw_text => |c| c.id,
            .push_clip => |c| c.id,
            .stroke_path => |c| c.id,
            else => continue,
        };
        if (id == ring_id) collisions += 1;
    }
    try testing.expectEqual(@as(usize, 0), collisions);
}

test "a focused terminal wears the house focus ring" {
    var commands: [16]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const focused = canvas.Widget{
        .id = 9,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .state = .{ .focused = true },
    };
    try canvas.emitWidgetTree(&builder, focused, .{});
    var rings: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .stroke_rect => rings += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), rings);
}

test "the terminal widget's register: focusable, press-claiming, I-beam, editable-text role" {
    const widget_access = @import("widget_access.zig");
    const widget_semantics = @import("widget_semantics.zig");
    const widget = canvas.Widget{ .id = 3, .kind = .terminal };
    try testing.expect(canvas.widgetKindHitTarget(.terminal));
    try testing.expect(widget_access.isFocusable(widget));
    try testing.expect(canvas.widgetClaimsPress(widget));
    try testing.expectEqual(canvas.WidgetCursor.text, canvas.cursorForWidgetTarget(.terminal, .{}));
    try testing.expectEqual(canvas.WidgetRole.textbox, widget_semantics.semanticRole(widget));
    // Deliberately NOT a text-input kind: the emulator owns the editing
    // model, so the TextBuffer pipeline must never claim it.
    try testing.expect(!canvas.widgetTextInputKind(.terminal));
}

test "rounded-corner path elements survive the builder's lifetime" {
    // The stroke_path command's elements must be builder-owned, not a
    // stack local: after paint returns, reading them back (the retained
    // renderer's path) must still see the move/line/quad verbs.
    const cells = [_]grid_model.TerminalCell{.{ .cp = 0x256D, .fg = white }}; // ╭
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 40, 40),
        .tokens = .{},
    });
    var saw_path = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .stroke_path => |path| {
                saw_path = true;
                try testing.expectEqual(@as(usize, 3), path.elements.len);
                try testing.expectEqual(canvas.PathVerb.move_to, path.elements[0].verb);
                try testing.expectEqual(canvas.PathVerb.quad_to, path.elements[2].verb);
            },
            else => {},
        }
    }
    try testing.expect(saw_path);
}

test "adjacent double-cross cells never collide command ids" {
    // ╬ emits up to eight commands; the per-column id stride must be at
    // least eight so neighbors never share an object id.
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 0x256C, .fg = white }, // ╬
        .{ .cp = 0x256C, .fg = white },
        .{ .cp = 0x256C, .fg = white },
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 120, 40),
        .tokens = .{},
        .id_base = 1,
    });
    var seen: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer seen.deinit(testing.allocator);
    for (builder.displayList().commands) |command| {
        const id = switch (command) {
            .fill_rect => |c| c.id,
            .stroke_rect => |c| c.id,
            .draw_text => |c| c.id,
            .push_clip => |c| c.id,
            else => continue,
        };
        if (id == 0) continue;
        for (seen.items) |prior| try testing.expect(prior != id);
        try seen.append(testing.allocator, id);
    }
}

test "the text preflight accounts for bytes earlier widgets already consumed" {
    // A grid sharing the builder with a widget that already spent most
    // of the text store must degrade against the REMAINING space, never
    // a fresh store — otherwise its rows pass preflight and then lose
    // text when allocTextBytes fails on the shared counter.
    const row = comptime asciiRow("cells", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // Pre-consume all but 2 bytes of the store, as an earlier widget
    // would.
    const filler = [_]u8{'x'} ** (canvas.max_display_list_text_bytes - 2);
    _ = try builder.allocTextBytes(&filler);

    try grid_model.paint(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    // The row (5 bytes) could not fit the 2 remaining, so it dropped
    // whole: no grid text command, and the shared counter never
    // overflowed.
    try testing.expect(builder.text_byte_len <= canvas.max_display_list_text_bytes);
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| try testing.expect(!std.mem.eql(u8, text.text, "cells")),
            else => {},
        }
    }
}

test "box drawing classifies the block and ignores neighbors" {
    try testing.expect(box.isBoxDrawing(0x2500));
    try testing.expect(box.isBoxDrawing(0x259F));
    try testing.expect(!box.isBoxDrawing(0x24FF));
    try testing.expect(!box.isBoxDrawing(0x25A0));
    try testing.expect(box.mergesHorizontally(0x2500));
    try testing.expect(!box.mergesHorizontally(0x2502));
}

// ------------------------------------------ full-screen paint coverage
//
// The tests above pin painter POLICY at cell scale. These pin the thing
// a terminal host actually cares about: how much of a real screen
// reaches the glass at the WIDGET tier — the shared per-view stores, the
// reserves held back for the chrome around the grid — and that whatever
// does not reach it is reported instead of silently missing.

/// The widget tier's options, exactly as `emitTerminalWidget` builds
/// them: the frame command ceiling minus the chrome reserve, plus the
/// text, path, and glyph reserves.
fn widgetPaintOptions(frame: geometry.RectF) grid_model.TerminalPaintOptions {
    return .{
        .frame = frame,
        .tokens = .{},
        .id_base = 1,
        .command_budget = canvas.max_display_list_commands - grid_model.widget_command_reserve,
        .text_reserve = grid_model.widget_text_reserve,
        .path_reserve = grid_model.widget_path_reserve,
        .glyph_budget = grid_model.widget_glyph_budget,
    };
}

/// Rows with ink in the finished list, counted independently of the
/// painter's own bookkeeping: text-run ids are
/// `paintIdBase(id_base) + (row << 16) + 0x8000 + column`, so the row
/// index falls straight out of the id.
fn paintedRowsFromIds(list: canvas.DisplayList, id_base: u64) usize {
    const base = grid_model.paintIdBase(id_base);
    var highest: ?usize = null;
    for (list.commands) |command| {
        const text = switch (command) {
            .draw_text => |value| value,
            else => continue,
        };
        const offset = text.id -% base;
        const row: usize = @intCast(offset >> 16);
        if (highest == null or row > highest.?) highest = row;
    }
    return if (highest) |row| row + 1 else 0;
}

const screen_cols: usize = 200;
const screen_rows: usize = 60;

/// A cell's cluster: one byte out of a fixed alphabet, so a screen's
/// text cost is one byte per cell (a terminal's ordinary case) and its
/// distinct-glyph cost stays a small alphabet.
fn screenCluster(index: usize) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    const at = index % alphabet.len;
    return alphabet[at .. at + 1];
}

/// A colour nothing merges with: consecutive indices always differ in
/// the red channel, so neither the background-run nor the text-run
/// merge can join two neighbours.
fn screenColor(index: usize, bias: f32) canvas.Color {
    const red_channel: f32 = @floatFromInt(index % 251);
    const green_channel: f32 = @floatFromInt((index / 251) % 241);
    return canvas.Color.rgba(red_channel / 251.0, green_channel / 241.0, bias, 1);
}

/// Build a `screen_cols` x `screen_rows` viewport whose every cell
/// carries its own foreground and background — the truecolor worst
/// case, where nothing merges and every cell costs one background
/// command plus one text command.
fn buildTruecolorScreen(
    cells: []grid_model.TerminalCell,
    rows: []grid_model.TerminalRow,
) void {
    for (rows, 0..) |*row, row_index| {
        const row_cells = cells[row_index * screen_cols ..][0..screen_cols];
        for (row_cells, 0..) |*entry, column| {
            const index = row_index * screen_cols + column;
            entry.* = .{
                .cp = screenCluster(index)[0],
                .cluster = screenCluster(index),
                .fg = screenColor(index, 0.25),
                .bg = screenColor(index, 0.75),
            };
        }
        row.* = .{ .cells = row_cells };
    }
}

/// The same viewport with REALISTIC styling: a styled span every four
/// columns (50 foreground runs per row) over two background bands — a
/// heavier read of syntax-highlighted source, an htop meter row, or a
/// colored build log, at ~52 commands per row.
fn buildStyledScreen(
    cells: []grid_model.TerminalCell,
    rows: []grid_model.TerminalRow,
) void {
    for (rows, 0..) |*row, row_index| {
        const row_cells = cells[row_index * screen_cols ..][0..screen_cols];
        for (row_cells, 0..) |*entry, column| {
            const index = row_index * screen_cols + column;
            entry.* = .{
                .cp = screenCluster(index)[0],
                .cluster = screenCluster(index),
                .fg = screenColor(column / 4, 0.25),
                .bg = if (column < 24) screenColor(row_index, 0.75) else null,
            };
        }
        row.* = .{ .cells = row_cells };
    }
}

test "a truecolor 200x60 screen paints every row" {
    // The measurement this whole primitive exists for. Every cell
    // carries its own foreground AND background, so nothing merges —
    // the shape that cost ~400 display-list commands per row and
    // painted 9 rows of 60 against a 4,096-command budget.
    //
    // As a packed lattice it is ONE command and 12,000 cells, and every
    // row paints.
    const cells = try testing.allocator.alloc(grid_model.TerminalCell, screen_cols * screen_rows);
    defer testing.allocator.free(cells);
    const rows = try testing.allocator.alloc(grid_model.TerminalRow, screen_rows);
    defer testing.allocator.free(rows);
    buildTruecolorScreen(cells, rows);

    const commands = try testing.allocator.alloc(canvas.CanvasCommand, canvas.max_display_list_commands);
    defer testing.allocator.free(commands);
    var builder = canvas.Builder.init(commands);
    const options = widgetPaintOptions(geometry.RectF.init(0, 0, 1600, 1200));
    const report = try grid_model.paintReport(baseGrid(rows), &builder, options);
    const list = builder.displayList();
    const grid = firstCellGrid(list) orelse return error.TestExpectedCellGrid;

    std.debug.print(
        "\n[terminal] truecolor {d}x{d}: {d}/{d} rows painted, {d} commands, {d} cells, {d} text bytes\n",
        .{
            screen_cols,           screen_rows,
            report.rows_painted,   report.rows_total,
            builder.len,           grid.cells.len,
            builder.text_byte_len,
        },
    );

    try testing.expectEqual(screen_rows, report.rows_painted);
    try testing.expect(report.stopped_by == null);
    try testing.expect(!report.truncated());
    try testing.expect(builder.degradation == null);
    // One command for the whole screen, plus the surface fill and the
    // clip pair. The command count no longer scales with styling at all.
    try testing.expect(builder.len <= 8);
    try testing.expectEqual(@as(u16, screen_cols), grid.cols);
    try testing.expectEqual(@as(u16, screen_rows), grid.rows);
    try testing.expectEqual(screen_cols * screen_rows, grid.cells.len);
    // Every cell kept its own colours: nothing merged, nothing was lost.
    const first = grid.at(0, 0) orelse return error.TestExpectedCell;
    const second = grid.at(1, 0) orelse return error.TestExpectedCell;
    try testing.expect(!first.fg.eql(second.fg));
    try testing.expect(first.style().has_background);
    // The cluster blob INTERNED: 12,000 cells drawn from a 36-character
    // alphabet cost 36 bytes, not 12,000.
    try testing.expect(grid.text.len <= 64);
}

test "a realistically styled 200x60 screen paints every row" {
    // The case the budget must actually carry: 50 foreground runs and a
    // couple of background runs per row — syntax-highlighted source,
    // htop, a colored build log. At the old 2,048-command ceiling this
    // screen painted 34 of its 60 rows; the whole point of the raise is
    // that it now paints all 60.
    const cells = try testing.allocator.alloc(grid_model.TerminalCell, screen_cols * screen_rows);
    defer testing.allocator.free(cells);
    const rows = try testing.allocator.alloc(grid_model.TerminalRow, screen_rows);
    defer testing.allocator.free(rows);
    buildStyledScreen(cells, rows);

    const commands = try testing.allocator.alloc(canvas.CanvasCommand, canvas.max_display_list_commands);
    defer testing.allocator.free(commands);
    var builder = canvas.Builder.init(commands);
    const options = widgetPaintOptions(geometry.RectF.init(0, 0, 1600, 1200));
    const report = try grid_model.paintReport(baseGrid(rows), &builder, options);

    std.debug.print(
        "\n[terminal] styled {d}x{d}: {d}/{d} rows painted, {d} commands, {d} text bytes\n",
        .{ screen_cols, screen_rows, report.rows_painted, report.rows_total, builder.len, builder.text_byte_len },
    );

    try testing.expectEqual(screen_rows, report.rows_painted);
    try testing.expectEqual(screen_rows, gridPaintedRows(builder.displayList()));
    try testing.expect(report.stopped_by == null);
    try testing.expect(!report.truncated());
    // A complete paint leaves no degradation note behind.
    try testing.expect(builder.degradation == null);
}

test "a viewport taller than its frame is clipped, not truncated" {
    // Rows below the frame's bottom edge have nowhere to paint. That is
    // a viewport ending, not a budget eating content, and it must not
    // raise the degradation alarm.
    const row_a = comptime asciiRow("first", white);
    const row_b = comptime asciiRow("second", white);
    const rows = [_]grid_model.TerminalRow{ .{ .cells = &row_a }, .{ .cells = &row_b } };

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const report = try grid_model.paintReport(baseGrid(&rows), &builder, .{
        // One cell tall: the second row starts past the bottom.
        .frame = geometry.RectF.init(0, 0, 400, metrics.height),
        .tokens = .{},
        .id_base = 1,
    });

    try testing.expectEqual(@as(usize, 1), report.rows_painted);
    try testing.expectEqual(grid_model.TerminalPaintStop.viewport, report.stopped_by.?);
    try testing.expect(!report.truncated());
    try testing.expect(builder.degradation == null);
}

test "a text-budget stop names the text store on the builder" {
    // The other cliff a wide screen can hit: the frame's text store,
    // shared with every other widget's glyphs. It must report as text,
    // not as commands — an author who reads "commands" would tune the
    // wrong knob.
    const row_a = comptime asciiRow("aaaa", white);
    const row_b = comptime asciiRow("bbbb", white);
    const rows = [_]grid_model.TerminalRow{ .{ .cells = &row_a }, .{ .cells = &row_b } };

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const report = try grid_model.paintReport(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .id_base = 7,
        // Room for row a's interned 'a' and nothing more.
        .text_reserve = canvas.max_display_list_text_bytes - 1,
    });

    try testing.expectEqual(@as(usize, 1), report.rows_painted);
    try testing.expectEqual(grid_model.TerminalPaintStop.text_bytes, report.stopped_by.?);
    const note = builder.degradation orelse return error.TestExpectedDegradationNote;
    try testing.expectEqual(canvas.DisplayListStore.text_bytes, note.store);
    try testing.expectEqual(@as(u64, 7), note.id);
    try testing.expectEqual(@as(usize, 1), note.produced);
    try testing.expectEqual(@as(usize, 2), note.requested);
}

test "a grid that cannot seat its prologue reports painting nothing" {
    // The loudest degradation: a builder so full the grid cannot even
    // lay down its background. Silence here reads as "the terminal
    // widget is broken".
    const row = comptime asciiRow("row", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const report = try grid_model.paintReport(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .id_base = 3,
        // Under the painter's own fixed prologue/epilogue overhead.
        .command_budget = 4,
    });

    try testing.expectEqual(@as(usize, 0), report.rows_painted);
    try testing.expectEqual(@as(usize, 0), builder.len);
    try testing.expectEqual(grid_model.TerminalPaintStop.commands, report.stopped_by.?);
    const note = builder.degradation orelse return error.TestExpectedDegradationNote;
    try testing.expectEqual(@as(usize, 0), note.produced);
    try testing.expectEqual(@as(usize, 1), note.requested);
}

test "widening a pane dirties the columns it reveals" {
    // The stale-column bug's display-list tier: a pane painted wide,
    // repainted narrow (a split opening), then wide again (the split
    // collapsing). The columns the narrow frame hid must come back
    // BLANK, which means the narrow -> wide diff has to name them dirty
    // — a repaint bounded by the narrow pane's right edge leaves the old
    // wide frame's glyphs standing exactly where they were.
    //
    // The painter itself is stateless (it rebuilds the list every
    // frame), so what this pins is that the rebuilt list's diff covers
    // the revealed region. The retained PACKET tier has its own hole
    // here — it erases clips entirely — and its own regression test
    // (runtime/canvas_frame_patch_tests.zig).
    const wide_cells = comptime asciiRow("phalls-Mac-mini ~ %", white);
    const narrow_cells = comptime asciiRow("phalls-Mac-min", white);
    const wide_rows = [_]grid_model.TerminalRow{ .{ .cells = &wide_cells }, .{ .cells = &wide_cells } };
    const narrow_rows = [_]grid_model.TerminalRow{ .{ .cells = &narrow_cells }, .{} };

    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const wide_frame = geometry.RectF.init(0, 0, metrics.width * 40, metrics.height * 2);
    const narrow_frame = geometry.RectF.init(0, 0, metrics.width * 20, metrics.height * 2);

    var wide_commands: [128]canvas.CanvasCommand = undefined;
    var wide_builder = canvas.Builder.init(&wide_commands);
    try paintInto(baseGrid(&wide_rows), &wide_builder, .{
        .frame = wide_frame,
        .tokens = .{},
        .id_base = 11,
    });
    var narrow_commands: [128]canvas.CanvasCommand = undefined;
    var narrow_builder = canvas.Builder.init(&narrow_commands);
    try paintInto(baseGrid(&narrow_rows), &narrow_builder, .{
        .frame = narrow_frame,
        .tokens = .{},
        .id_base = 11,
    });

    // The frame that reveals the hidden columns: narrow list -> wide list.
    var changes: [512]canvas.DiffChange = undefined;
    const reveal = try canvas.DisplayList.diff(
        narrow_builder.displayList(),
        wide_builder.displayList(),
        &changes,
    );
    try testing.expect(reveal.len > 0);
    var dirty: ?geometry.RectF = null;
    for (reveal) |change| {
        const bounds = change.dirty_bounds orelse continue;
        dirty = if (dirty) |current| geometry.RectF.unionWith(current, bounds) else bounds;
    }
    const revealed = dirty orelse return error.TestExpectedDirtyBounds;
    // Every column the narrow pane hid is inside the repaint.
    try testing.expect(revealed.x <= narrow_frame.width);
    try testing.expect(revealed.x + revealed.width >= wide_frame.width);

    // ...and nothing from the narrow frame survives into the wide list:
    // both rows carry ink again, not the blank second row the narrow
    // pane left behind.
    try testing.expectEqual(@as(usize, 2), gridPaintedRows(wide_builder.displayList()));
    var wide_text: [64]u8 = undefined;
    try testing.expectEqualStrings("phalls-Mac-mini~%", gridRowText(wide_builder.displayList(), 1, &wide_text));
}

test "resetting a builder clears a previous frame's degradation note" {
    const row = comptime asciiRow("row", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid_model.paint(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .id_base = 3,
        .command_budget = 4,
    });
    try testing.expect(builder.degradation != null);
    builder.reset();
    try testing.expect(builder.degradation == null);
}

// ------------------------------------------------ the packed primitive
//
// The cell grid is a CanvasCommand like any other, so it owes the same
// four contracts every command owes: equality, a content fingerprint,
// retained diffing, and a renderer that draws it. These pin all four.

const wide_cols: usize = 300;
const wide_rows_count: usize = 100;

/// A 300x100 viewport with a distinct truecolor foreground AND
/// background on every one of its 30,000 cells — the density the
/// display-list model could not express at any budget.
fn buildWideTruecolorScreen(
    cells: []grid_model.TerminalCell,
    rows: []grid_model.TerminalRow,
) void {
    for (rows, 0..) |*row, row_index| {
        const row_cells = cells[row_index * wide_cols ..][0..wide_cols];
        for (row_cells, 0..) |*entry, column| {
            const index = row_index * wide_cols + column;
            entry.* = .{
                .cp = screenCluster(index)[0],
                .cluster = screenCluster(index),
                .fg = screenColor(index, 0.25),
                .bg = screenColor(index, 0.75),
            };
        }
        row.* = .{ .cells = row_cells };
    }
}

test "a 300x100 truecolor screen paints every row as one command" {
    // The requirement the primitive exists to meet.
    const cells = try testing.allocator.alloc(grid_model.TerminalCell, wide_cols * wide_rows_count);
    defer testing.allocator.free(cells);
    const rows = try testing.allocator.alloc(grid_model.TerminalRow, wide_rows_count);
    defer testing.allocator.free(rows);
    buildWideTruecolorScreen(cells, rows);

    const commands = try testing.allocator.alloc(canvas.CanvasCommand, canvas.max_display_list_commands);
    defer testing.allocator.free(commands);
    var builder = canvas.Builder.init(commands);
    // The direct-painter tier (a host that owns its own builder): the
    // whole cell store, no split reserve.
    const report = try grid_model.paintReport(baseGrid(rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 2400, 2000),
        .tokens = .{},
        .id_base = 1,
        .command_budget = canvas.max_display_list_commands - grid_model.widget_command_reserve,
        .text_reserve = grid_model.widget_text_reserve,
        .glyph_budget = grid_model.widget_glyph_budget,
    });
    const list = builder.displayList();
    const grid = firstCellGrid(list) orelse return error.TestExpectedCellGrid;

    std.debug.print(
        "\n[terminal] truecolor {d}x{d}: {d}/{d} rows painted, {d} commands, {d} cells ({d} KB), {d} text bytes\n",
        .{
            wide_cols,                                      wide_rows_count,
            report.rows_painted,                            report.rows_total,
            builder.len,                                    grid.cells.len,
            (grid.cells.len * @sizeOf(canvas.Cell)) / 1024, builder.text_byte_len,
        },
    );

    try testing.expectEqual(wide_rows_count, report.rows_painted);
    try testing.expect(report.stopped_by == null);
    try testing.expect(builder.degradation == null);
    try testing.expectEqual(@as(u16, wide_cols), grid.cols);
    try testing.expectEqual(@as(u16, wide_rows_count), grid.rows);
    try testing.expectEqual(wide_cols * wide_rows_count, grid.cells.len);
    // Memory is linear in cells and nothing else: 30,000 cells at 20 B.
    try testing.expectEqual(@as(usize, 20), @sizeOf(canvas.Cell));
    try testing.expect(grid.cells.len * @sizeOf(canvas.Cell) <= 640 * 1024);
    // And the command count is a constant, not a function of styling.
    try testing.expect(builder.len <= 8);
}

test "the grid carries every SGR attribute the producer resolves" {
    // Six attributes the producer used to discard because the display
    // list had nowhere to put them.
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 'a', .cluster = "a", .fg = white, .bold = true },
        .{ .cp = 'b', .cluster = "b", .fg = white, .italic = true },
        .{ .cp = 'c', .cluster = "c", .fg = white, .strikethrough = true },
        .{ .cp = 'd', .cluster = "d", .fg = white, .overline = true },
        .{ .cp = 'e', .cluster = "e", .fg = white, .underline = true, .underline_style = .curly },
        .{ .cp = 'f', .cluster = "f", .fg = white, .underline = true, .underline_style = .dashed, .underline_color = red },
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    try testing.expect((gridCell(list, 0, 0).?).style().bold);
    try testing.expect((gridCell(list, 1, 0).?).style().italic);
    try testing.expect((gridCell(list, 2, 0).?).style().strikethrough);
    try testing.expect((gridCell(list, 3, 0).?).style().overline);
    try testing.expectEqual(canvas.CellUnderline.curly, (gridCell(list, 4, 0).?).style().underline);

    const colored = gridCell(list, 5, 0).?;
    try testing.expectEqual(canvas.CellUnderline.dashed, colored.style().underline);
    try testing.expect(colored.style().has_underline_color);
    try testing.expectEqual(canvas.CellColor.fromColor(red), colored.underline_color);

    // A cell with no underline declared carries none, whatever style it
    // names: the flag and the style are one field.
    try testing.expectEqual(canvas.CellUnderline.none, (gridCell(list, 0, 0).?).style().underline);
}

test "two grids of the same screen are equal; one changed cell is not" {
    const row_a = comptime asciiRow("hello", white);
    var row_b = row_a;
    const rows_a = [_]grid_model.TerminalRow{.{ .cells = &row_a }};

    var commands_a: [64]canvas.CanvasCommand = undefined;
    var builder_a = canvas.Builder.init(&commands_a);
    try paintInto(baseGrid(&rows_a), &builder_a, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
        .id_base = 3,
    });

    var commands_b: [64]canvas.CanvasCommand = undefined;
    var builder_b = canvas.Builder.init(&commands_b);
    try paintInto(baseGrid(&rows_a), &builder_b, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
        .id_base = 3,
    });

    const grid_a = firstCellGrid(builder_a.displayList()) orelse return error.TestExpectedCellGrid;
    const grid_b = firstCellGrid(builder_b.displayList()) orelse return error.TestExpectedCellGrid;
    try testing.expect(equality_model.commandsEqual(.{ .cell_grid = grid_a }, .{ .cell_grid = grid_b }));

    // One recolored cell breaks equality — the diff must see a screen
    // that changed, whatever changed in it.
    row_b[2].fg = red;
    const rows_b = [_]grid_model.TerminalRow{.{ .cells = &row_b }};
    var commands_c: [64]canvas.CanvasCommand = undefined;
    var builder_c = canvas.Builder.init(&commands_c);
    try paintInto(baseGrid(&rows_b), &builder_c, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
        .id_base = 3,
    });
    const grid_c = firstCellGrid(builder_c.displayList()) orelse return error.TestExpectedCellGrid;
    try testing.expect(!equality_model.commandsEqual(.{ .cell_grid = grid_a }, .{ .cell_grid = grid_c }));
}

test "a grid's fingerprint is stable for identical content and moves for any cell" {
    const row = comptime asciiRow("hello", white);
    var changed = row;
    const rows = [_]grid_model.TerminalRow{.{ .cells = &row }};

    var commands_a: [64]canvas.CanvasCommand = undefined;
    var builder_a = canvas.Builder.init(&commands_a);
    try paintInto(baseGrid(&rows), &builder_a, .{ .frame = geometry.RectF.init(0, 0, 400, 100), .tokens = .{}, .id_base = 5 });
    var commands_b: [64]canvas.CanvasCommand = undefined;
    var builder_b = canvas.Builder.init(&commands_b);
    try paintInto(baseGrid(&rows), &builder_b, .{ .frame = geometry.RectF.init(0, 0, 400, 100), .tokens = .{}, .id_base = 5 });

    const grid_a = firstCellGrid(builder_a.displayList()) orelse return error.TestExpectedCellGrid;
    const grid_b = firstCellGrid(builder_b.displayList()) orelse return error.TestExpectedCellGrid;
    // Stable: the retained patch path re-encodes only what changed, so a
    // fingerprint that drifted between identical frames would re-upload
    // the whole screen every frame.
    try testing.expectEqual(canvas.cellGridFingerprint(grid_a), canvas.cellGridFingerprint(grid_b));

    // ...and sensitive: a single cell's background must move it, or a
    // patch would skip a screen that visibly changed.
    changed[1].bg = blue;
    const changed_rows = [_]grid_model.TerminalRow{.{ .cells = &changed }};
    var commands_c: [64]canvas.CanvasCommand = undefined;
    var builder_c = canvas.Builder.init(&commands_c);
    try paintInto(baseGrid(&changed_rows), &builder_c, .{ .frame = geometry.RectF.init(0, 0, 400, 100), .tokens = .{}, .id_base = 5 });
    const grid_c = firstCellGrid(builder_c.displayList()) orelse return error.TestExpectedCellGrid;
    try testing.expect(canvas.cellGridFingerprint(grid_a) != canvas.cellGridFingerprint(grid_c));
}

test "the retained diff replaces a changed screen wholesale" {
    // The reflow-safety property: a screen is ONE key, so a row that
    // loses content cannot leave an orphaned per-run command behind.
    const before = comptime asciiRow("phalls-Mac-mini ~ %", white);
    const after = comptime asciiRow("phalls-Mac-min", white);
    const rows_before = [_]grid_model.TerminalRow{.{ .cells = &before }};
    const rows_after = [_]grid_model.TerminalRow{.{ .cells = &after }};

    var commands_a: [64]canvas.CanvasCommand = undefined;
    var builder_a = canvas.Builder.init(&commands_a);
    try paintInto(baseGrid(&rows_before), &builder_a, .{ .frame = geometry.RectF.init(0, 0, 400, 100), .tokens = .{}, .id_base = 9 });
    var commands_b: [64]canvas.CanvasCommand = undefined;
    var builder_b = canvas.Builder.init(&commands_b);
    try paintInto(baseGrid(&rows_after), &builder_b, .{ .frame = geometry.RectF.init(0, 0, 400, 100), .tokens = .{}, .id_base = 9 });

    var changes: [64]canvas.DiffChange = undefined;
    const diff = try canvas.DisplayList.diff(builder_a.displayList(), builder_b.displayList(), &changes);

    // Exactly one CHANGED grid key, and no removals at all: nothing can
    // be orphaned because nothing was ever per-run.
    var changed_grids: usize = 0;
    var removals: usize = 0;
    const grid_id = (firstCellGrid(builder_a.displayList()) orelse return error.TestExpectedCellGrid).id;
    for (diff) |change| {
        if (change.kind == .removed) removals += 1;
        if (change.kind == .changed and change.id != null and change.id.? == grid_id) changed_grids += 1;
    }
    try testing.expectEqual(@as(usize, 1), changed_grids);
    try testing.expectEqual(@as(usize, 0), removals);
}

test "golden: the reference renderer inks cell backgrounds, glyphs, and decorations" {
    // The correctness ORACLE. Automation screenshots go through this
    // renderer, so what it draws is what the app is verified against —
    // and any host encoder has to match it.
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 'A', .cluster = "A", .fg = white, .bg = red },
        .{ .cp = 0, .bg = blue },
        .{ .cp = 'B', .cluster = "B", .fg = white, .underline = true, .underline_color = red },
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 120, 40),
        .tokens = .{},
    });

    const width: usize = 120;
    const height: usize = 40;
    const list = builder.displayList();
    var render_commands: [64]canvas.RenderCommand = undefined;
    var render_batches: [64]canvas.RenderBatch = undefined;
    var resources: [64]canvas.RenderResource = undefined;
    var resource_cache_entries: [64]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [128]canvas.RenderResourceCacheAction = undefined;
    var atlas_glyphs: [256]canvas.GlyphAtlasEntry = undefined;
    var changes: [64]canvas.DiffChange = undefined;
    const frame = try list.framePlan(null, .{
        .surface_size = geometry.SizeF.init(width, height),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &atlas_glyphs,
        .changes = &changes,
    });

    const pixels = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(pixels);
    const surface = try canvas.ReferenceRenderSurface.init(width, height, pixels);
    try surface.renderPass(frame.renderPass(), canvas.Color.rgb8(0, 0, 0));

    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const sample = struct {
        fn at(px: []const u8, w: usize, x: usize, y: usize) [4]u8 {
            const index = (y * w + x) * 4;
            return .{ px[index], px[index + 1], px[index + 2], px[index + 3] };
        }
    };

    // Cell 0's background is red, cell 1's is blue: the lattice inked
    // both, including the cell that carries no glyph at all.
    const cell_w: usize = @intFromFloat(metrics.width);
    const red_px = sample.at(pixels, width, cell_w / 2, 2);
    try testing.expect(red_px[0] > 200 and red_px[1] < 60 and red_px[2] < 60);
    const blue_px = sample.at(pixels, width, cell_w + cell_w / 2, 2);
    try testing.expect(blue_px[2] > 200 and blue_px[0] < 60);

    // Cell 2's underline paints in its own colour, not the foreground:
    // a row of white text with a red underline must show red there.
    const underline_y: usize = @intFromFloat(metrics.height - canvas.CellDecoration.strokeWidth(metrics.font_size) * 2);
    const underline_px = sample.at(pixels, width, cell_w * 2 + cell_w / 2, underline_y);
    try testing.expect(underline_px[0] > underline_px[2]);

    // And the glyph itself inked: some pixel inside cell 0 is neither
    // its background nor untouched.
    var glyph_ink = false;
    var y: usize = 0;
    while (y < @as(usize, @intFromFloat(metrics.height))) : (y += 1) {
        var x: usize = 0;
        while (x < cell_w) : (x += 1) {
            const px = sample.at(pixels, width, x, y);
            if (px[1] > 90 and px[2] > 90) glyph_ink = true;
        }
    }
    try testing.expect(glyph_ink);
}
