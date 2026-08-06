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

/// The widget tier's options, exactly as `emitTerminalWidget` builds
/// them: the frame command ceiling minus the chrome reserve, plus the
/// text, path, glyph, and cell reserves.
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

/// The grid command for lattice row `y`. The painter emits one per row
/// (the retained-patch granularity), so a row IS a command.
fn rowCellGrid(list: canvas.DisplayList, y: usize) ?canvas.CellGrid {
    var seen: usize = 0;
    for (list.commands) |command| {
        if (command != .cell_grid) continue;
        if (seen == y) return command.cell_grid;
        seen += 1;
    }
    return null;
}

fn firstCellGrid(list: canvas.DisplayList) ?canvas.CellGrid {
    return rowCellGrid(list, 0);
}

fn gridCell(list: canvas.DisplayList, x: usize, y: usize) ?canvas.Cell {
    const grid = rowCellGrid(list, y) orelse return null;
    return grid.at(x, 0);
}

fn gridCluster(list: canvas.DisplayList, x: usize, y: usize) []const u8 {
    const grid = rowCellGrid(list, y) orelse return "";
    const cell_value = grid.at(x, 0) orelse return "";
    return cell_value.cluster(grid.text);
}

/// The cluster bytes of row `y`, concatenated into `out` — the row as a
/// renderer would ink it.
fn gridRowText(list: canvas.DisplayList, y: usize, out: []u8) []const u8 {
    const grid = rowCellGrid(list, y) orelse return "";
    var len: usize = 0;
    var x: usize = 0;
    while (x < grid.cols) : (x += 1) {
        const cell_value = grid.at(x, 0) orelse continue;
        const bytes = cell_value.cluster(grid.text);
        if (len + bytes.len > out.len) break;
        @memcpy(out[len..][0..bytes.len], bytes);
        len += bytes.len;
    }
    return out[0..len];
}

/// Rows that reached the display list — one grid command each.
fn gridPaintedRows(list: canvas.DisplayList) usize {
    var count: usize = 0;
    for (list.commands) |command| {
        if (command == .cell_grid) count += 1;
    }
    return count;
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
    // One command per ROW plus the surface fill and the clip pair: the
    // count scales with rows, never with styling.
    try testing.expectEqual(screen_rows, gridPaintedRows(list));
    try testing.expect(builder.len <= screen_rows + 8);
    try testing.expectEqual(@as(u16, screen_cols), grid.cols);
    try testing.expectEqual(@as(u16, 1), grid.rows);
    try testing.expectEqual(screen_cols, grid.cells.len);
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
    try testing.expectEqual(@as(u16, 1), grid.rows);
    try testing.expectEqual(wide_cols, grid.cells.len);
    try testing.expectEqual(wide_rows_count, gridPaintedRows(list));
    // Memory is linear in cells and nothing else: 30,000 cells at 20 B.
    try testing.expectEqual(@as(usize, 20), @sizeOf(canvas.Cell));
    try testing.expect(wide_cols * wide_rows_count * @sizeOf(canvas.Cell) <= 640 * 1024);
    // Commands scale with ROWS, not with styling: one grid per row plus
    // the surface fill and the clip pair.
    try testing.expect(builder.len <= wide_rows_count + 8);
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

test "the packed row reaches the GPU packet, and one changed row is one upsert" {
    // The incremental contract, pinned at the layer that decides it.
    //
    // A screen is one grid command PER ROW, so the retained diff sees a
    // keystroke as one changed key. Measured on the real app at 1100x640
    // this is `present_patch_upserts=1` / `present_patch_bytes=417`; the
    // regression this guards is a screen-wide grid (or a screen-wide
    // shared text blob), either of which makes every row's fingerprint
    // move together and turns a keystroke back into a full re-upload.
    const before = comptime asciiRow("ready", white);
    var after_cells = before;
    after_cells[0].fg = red;
    const rows_before = [_]grid_model.TerminalRow{
        .{ .cells = &before },
        .{ .cells = &before },
        .{ .cells = &before },
    };
    const rows_after = [_]grid_model.TerminalRow{
        .{ .cells = &after_cells },
        .{ .cells = &before },
        .{ .cells = &before },
    };

    var commands_a: [64]canvas.CanvasCommand = undefined;
    var builder_a = canvas.Builder.init(&commands_a);
    try paintInto(baseGrid(&rows_before), &builder_a, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .id_base = 4,
    });
    var commands_b: [64]canvas.CanvasCommand = undefined;
    var builder_b = canvas.Builder.init(&commands_b);
    try paintInto(baseGrid(&rows_after), &builder_b, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .id_base = 4,
    });

    try testing.expectEqual(@as(usize, 3), gridPaintedRows(builder_a.displayList()));

    // Exactly one row's fingerprint moved. The other two must be
    // BYTE-identical, which is what lets the packet skip re-encoding
    // them — a shared text blob across rows breaks this immediately.
    var changed: usize = 0;
    var y: usize = 0;
    while (y < 3) : (y += 1) {
        const row_a = rowCellGrid(builder_a.displayList(), y) orelse return error.TestExpectedCellGrid;
        const row_b = rowCellGrid(builder_b.displayList(), y) orelse return error.TestExpectedCellGrid;
        if (canvas.cellGridFingerprint(row_a) != canvas.cellGridFingerprint(row_b)) changed += 1;
    }
    try testing.expectEqual(@as(usize, 1), changed);
}

test "a cell-grid row encodes to the wire and stays compact for plain text" {
    // The wire form the AppKit host decodes (serialization.zig v6). A
    // row is a delta stream — a tag byte per cell, style repeated only
    // when it changes — which is what keeps a one-row patch in the
    // hundreds of bytes instead of the kilobytes a raw 20-byte-per-cell
    // dump would cost.
    var plain: [80]grid_model.TerminalCell = undefined;
    for (&plain) |*entry| entry.* = cell('x', "x", white);
    const rows = [_]grid_model.TerminalRow{.{ .cells = &plain }};

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, 800, 40),
        .tokens = .{},
        .id_base = 6,
    });
    const list = builder.displayList();

    var render_commands: [32]canvas.RenderCommand = undefined;
    var render_batches: [32]canvas.RenderBatch = undefined;
    var resources: [32]canvas.RenderResource = undefined;
    var resource_cache_entries: [32]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [64]canvas.RenderResourceCacheAction = undefined;
    var atlas_glyphs: [64]canvas.GlyphAtlasEntry = undefined;
    var changes: [32]canvas.DiffChange = undefined;
    const frame = try list.framePlan(null, .{
        .surface_size = geometry.SizeF.init(800, 40),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &atlas_glyphs,
        .changes = &changes,
    });

    // Every command of a terminal frame is representable now — that is
    // what returns the view to the retained packet path instead of a
    // full-surface CPU upload every frame.
    var gpu_commands: [32]canvas.CanvasGpuCommand = undefined;
    const packet = try frame.renderPass().gpuPacket(&gpu_commands);
    try testing.expect(packet.fullyRepresentable());
    try testing.expectEqual(@as(usize, 0), packet.unsupported_command_count);

    var saw_grid = false;
    for (gpu_commands[0..packet.commands.len]) |command| {
        if (command.kind != .cell_grid) continue;
        saw_grid = true;
        const grid = command.cells orelse return error.TestExpectedCellGridPayload;
        try testing.expectEqual(@as(u16, 80), grid.cols);
        try testing.expectEqual(@as(u16, 1), grid.rows);
    }
    try testing.expect(saw_grid);

    // The encoded packet holds the whole row well under a kilobyte: 80
    // identically styled cells cost one style block and a tag plus a
    // character each.
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try packet.writeBinary(&writer);
    try testing.expect(writer.buffered().len < 1024);
}

// -------------------------------------------------- bold and italic
//
// SGR weight and slant are INK, never layout. Everything below exists
// to keep it that way: a lattice whose cell rects moved with the face
// would give up the guarantee the whole packed-cell model rests on.

/// Paint one row of `text` with a style applied to every cell.
fn paintStyledRow(
    comptime text: []const u8,
    builder: *canvas.Builder,
    bold: bool,
    italic: bool,
    tokens: canvas.DesignTokens,
) !void {
    var cells = comptime asciiRow(text, white);
    for (&cells) |*entry| {
        entry.bold = bold;
        entry.italic = italic;
    }
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};
    try paintInto(baseGrid(&rows), builder, .{
        .frame = geometry.RectF.init(0, 0, 600, 60),
        .tokens = tokens,
        .id_base = 21,
    });
}

test "a bold or italic row occupies exactly the cell rects a regular row does" {
    // The invariant. A bold face has different advances than a regular
    // one; in a lattice that must change nothing, because a cell's
    // position is its INDEX.
    var regular_commands: [32]canvas.CanvasCommand = undefined;
    var regular = canvas.Builder.init(&regular_commands);
    try paintStyledRow("weight", &regular, false, false, .{});

    var bold_commands: [32]canvas.CanvasCommand = undefined;
    var bold = canvas.Builder.init(&bold_commands);
    try paintStyledRow("weight", &bold, true, false, .{});

    var italic_commands: [32]canvas.CanvasCommand = undefined;
    var italic = canvas.Builder.init(&italic_commands);
    try paintStyledRow("weight", &italic, false, true, .{});

    const regular_grid = firstCellGrid(regular.displayList()) orelse return error.TestExpectedCellGrid;
    const bold_grid = firstCellGrid(bold.displayList()) orelse return error.TestExpectedCellGrid;
    const italic_grid = firstCellGrid(italic.displayList()) orelse return error.TestExpectedCellGrid;

    try testing.expectEqual(regular_grid.cols, bold_grid.cols);
    try testing.expectEqual(regular_grid.cols, italic_grid.cols);
    try testing.expectEqual(regular_grid.cell_width, bold_grid.cell_width);
    try testing.expectEqual(regular_grid.cell_width, italic_grid.cell_width);
    try testing.expectEqual(regular_grid.baseline, bold_grid.baseline);

    // Every cell rect is identical, column by column.
    var column: usize = 0;
    while (column < regular_grid.cols) : (column += 1) {
        try testing.expectEqualDeep(regular_grid.cellRect(column, 0), bold_grid.cellRect(column, 0));
        try testing.expectEqualDeep(regular_grid.cellRect(column, 0), italic_grid.cellRect(column, 0));
    }
    // ...and so is the command's raster extent.
    try testing.expectEqualDeep(regular_grid.bounds(), bold_grid.bounds());
    try testing.expectEqualDeep(regular_grid.bounds(), italic_grid.bounds());

    // The styles DID reach the cells — this is not passing because
    // nothing was applied.
    try testing.expect((bold_grid.at(0, 0).?).style().bold);
    try testing.expect((italic_grid.at(0, 0).?).style().italic);
}

test "face selection prefers real companions and synthesizes only what is missing" {
    var full = canvas.DesignTokens{};
    full.typography.mono_bold_font_id = 64;
    full.typography.mono_italic_font_id = 65;
    full.typography.mono_bold_italic_font_id = 66;

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintStyledRow("x", &builder, true, true, full);
    const grid = firstCellGrid(builder.displayList()) orelse return error.TestExpectedCellGrid;

    // A complete family: the real bold-italic face, nothing faked.
    const chosen = grid.face(.{ .bold = true, .italic = true });
    try testing.expectEqual(@as(canvas.FontId, 66), chosen.font_id);
    try testing.expect(!chosen.synthetic_bold);
    try testing.expect(!chosen.synthetic_italic);
    try testing.expectEqual(@as(canvas.FontId, 64), grid.face(.{ .bold = true }).font_id);
    try testing.expectEqual(@as(canvas.FontId, 65), grid.face(.{ .italic = true }).font_id);
    try testing.expectEqual(grid.font_id, grid.face(.{}).font_id);

    // A HALF family: real weight, sheared. Better than faking both.
    var half = canvas.CellGrid{ .font_id = 2, .bold_font_id = 64 };
    const mixed = half.face(.{ .bold = true, .italic = true });
    try testing.expectEqual(@as(canvas.FontId, 64), mixed.font_id);
    try testing.expect(!mixed.synthetic_bold);
    try testing.expect(mixed.synthetic_italic);

    // NO family: the regular face, both synthesized — carried and
    // visible rather than silently dropped.
    var bare = canvas.CellGrid{ .font_id = 2 };
    const faked = bare.face(.{ .bold = true, .italic = true });
    try testing.expectEqual(@as(canvas.FontId, 2), faked.font_id);
    try testing.expect(faked.synthetic_bold);
    try testing.expect(faked.synthetic_italic);
}

test "an italic glyph's overhang survives the next cell's background" {
    // The two-pass order exists for exactly this: a sheared glyph leans
    // into its neighbour, and a renderer that filled each cell's
    // background just before its glyph would erase the lean.
    //
    // Rendered for real: an italic 'H' in cell 0 against a bright
    // background in cell 1. If the passes ever collapse, the ink that
    // crosses the boundary disappears.
    var cells = [_]grid_model.TerminalCell{
        .{ .cp = 'H', .cluster = "H", .fg = white, .italic = true },
        .{ .bg = blue },
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const width: usize = @intFromFloat(@round(metrics.width * 2));
    const height: usize = @intFromFloat(@round(metrics.height));

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, @floatFromInt(width), @floatFromInt(height)),
        .tokens = .{},
    });

    var render_commands: [32]canvas.RenderCommand = undefined;
    var render_batches: [32]canvas.RenderBatch = undefined;
    var resources: [32]canvas.RenderResource = undefined;
    var resource_cache_entries: [32]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [64]canvas.RenderResourceCacheAction = undefined;
    var atlas_glyphs: [64]canvas.GlyphAtlasEntry = undefined;
    var changes: [32]canvas.DiffChange = undefined;
    const frame = try builder.displayList().framePlan(null, .{
        .surface_size = geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)),
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

    // Cell 1 is a blue field. Any pixel there that is NOT blue is the
    // italic glyph leaning across the boundary — the ink the ordering
    // protects.
    const boundary: usize = @intFromFloat(metrics.width);
    var leaned = false;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x = boundary;
        while (x < width) : (x += 1) {
            const index = (y * width + x) * 4;
            const r = pixels[index];
            const g = pixels[index + 1];
            if (r > 90 and g > 90) leaned = true;
        }
    }
    try testing.expect(leaned);
}

/// Render one styled row and return how many pixels carry ink.
fn styledRowInk(comptime text: []const u8, bold: bool, italic: bool) !usize {
    var cells = comptime asciiRow(text, white);
    for (&cells) |*entry| {
        entry.bold = bold;
        entry.italic = italic;
    }
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    const metrics = grid_model.cellMetrics(canvas.DesignTokens{});
    const width: usize = @intFromFloat(@round(metrics.width * @as(f32, @floatFromInt(text.len)) + 4));
    const height: usize = @intFromFloat(@round(metrics.height));

    var commands: [32]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try paintInto(baseGrid(&rows), &builder, .{
        .frame = geometry.RectF.init(0, 0, @floatFromInt(width), @floatFromInt(height)),
        .tokens = .{},
    });

    var render_commands: [32]canvas.RenderCommand = undefined;
    var render_batches: [32]canvas.RenderBatch = undefined;
    var resources: [32]canvas.RenderResource = undefined;
    var resource_cache_entries: [32]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [64]canvas.RenderResourceCacheAction = undefined;
    var atlas_glyphs: [64]canvas.GlyphAtlasEntry = undefined;
    var changes: [32]canvas.DiffChange = undefined;
    const frame = try builder.displayList().framePlan(null, .{
        .surface_size = geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)),
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

    var ink: usize = 0;
    for (0..width * height) |index| {
        if (pixels[index * 4] > 40) ink += 1;
    }
    return ink;
}

test "synthetic bold inks more than regular, and italic inks differently, at the same cells" {
    // The measurement behind "bold is visible". Faux bold is a second
    // offset pass, so it strictly ADDS covered pixels; faux italic is a
    // shear, so it moves them without adding a whole pass. Both draw at
    // the same pens — the geometry test above pins that separately —
    // so any difference here is ink and only ink.
    const regular = try styledRowInk("mono", false, false);
    const bold = try styledRowInk("mono", true, false);
    const italic = try styledRowInk("mono", false, true);

    std.debug.print(
        "\n[terminal] ink coverage: regular={d} bold={d} italic={d}\n",
        .{ regular, bold, italic },
    );

    try testing.expect(regular > 0);
    // Bold is heavier by a real margin, not by a pixel or two.
    try testing.expect(bold > regular);
    try testing.expect(bold - regular > regular / 20);
    // Italic is a different shape, not merely the same one again.
    try testing.expect(italic != regular);
}
