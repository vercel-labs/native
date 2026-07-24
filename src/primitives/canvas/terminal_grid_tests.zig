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

fn paintInto(grid: grid_model.TerminalGrid, commands: []canvas.CanvasCommand, options: grid_model.TerminalPaintOptions) !canvas.Builder {
    var builder = canvas.Builder.init(commands);
    try grid_model.paint(grid, &builder, options);
    return builder;
}

test "the painter emits merged text runs with per-run colors" {
    const row_cells = comptime asciiRow("hi red", white);
    var cells = row_cells;
    // Recolor the "red" run.
    cells[3].fg = red;
    cells[4].fg = red;
    cells[5].fg = red;
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    var saw_hi = false;
    var saw_red = false;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "hi")) {
                    saw_hi = true;
                    try testing.expectEqual(white.r, text.color.r);
                }
                if (std.mem.eql(u8, text.text, "red")) {
                    saw_red = true;
                    try testing.expectEqual(red.r, text.color.r);
                    try testing.expectEqual(red.g, text.color.g);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_hi);
    try testing.expect(saw_red);
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 400, 100),
        .tokens = .{},
    });
    const list = builder.displayList();

    const tokens: canvas.DesignTokens = .{};
    const metrics = grid_model.cellMetrics(tokens);
    var saw_bang = false;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "!")) {
                    saw_bang = true;
                    // One wide cluster before it: x = 2 cells.
                    try testing.expectApproxEqAbs(metrics.width * 2, text.origin.x, 0.01);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_bang);
}

test "box-drawing cells render as geometry, never text" {
    const cells = [_]grid_model.TerminalCell{
        .{ .cp = 0x2500, .fg = white }, // ─
        .{ .cp = 0x2500, .fg = white },
        .{ .cp = 0x2502, .fg = white }, // │
    };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &cells }};

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    var builder = try paintInto(grid, &commands, .{
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

test "the cursor register: filled while running, dim after exit" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };

    var commands: [16]canvas.CanvasCommand = undefined;
    var builder = try paintInto(grid, &commands, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
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

    grid.running = false;
    var ended_commands: [16]canvas.CanvasCommand = undefined;
    var ended_builder = try paintInto(grid, &ended_commands, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
    });
    var ended_alpha: f32 = 0;
    for (ended_builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (fill.fill == .color and fill.fill.color.b == blue.b and fill.fill.color.a < 1) ended_alpha = fill.fill.color.a;
            },
            else => {},
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.22), ended_alpha, 0.001);
}

test "the scrollback thumb paints only while the viewport is in history" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);

    // Pinned to the bottom: no thumb.
    grid.scrollbar = .{ .offset = 76, .len = 24, .total = 100 };
    var pinned_commands: [16]canvas.CanvasCommand = undefined;
    var pinned = try paintInto(grid, &pinned_commands, .{
        .frame = geometry.RectF.init(0, 0, 100, 200),
        .tokens = .{},
    });
    const pinned_count = pinned.displayList().commands.len;

    // Scrolled into history: exactly one extra fill (the thumb).
    grid.scrollbar = .{ .offset = 10, .len = 24, .total = 100 };
    var history_commands: [16]canvas.CanvasCommand = undefined;
    var history = try paintInto(grid, &history_commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        // Reserve all but 6 bytes of the store: row a (4 bytes) fits,
        // row b would cross, so it drops whole.
        .text_reserve = canvas.max_display_list_text_bytes - 6,
    });
    var texts: usize = 0;
    var saw_a = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                texts += 1;
                if (std.mem.eql(u8, text.text, "aaaa")) saw_a = true;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), texts);
    try testing.expect(saw_a);
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .glyph_budget = 6,
    });
    var saw_a = false;
    var saw_b = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "abcd")) saw_a = true;
                if (std.mem.eql(u8, text.text, "efgh")) saw_b = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_a);
    try testing.expect(!saw_b);
}

test "clampGrid trades rows for columns under the cell ceiling" {
    const clamped = grid_model.clampGrid(400, 100);
    try testing.expectEqual(@as(u16, grid_model.max_cols), clamped.x);
    try testing.expect(@as(usize, clamped.x) * @as(usize, clamped.y) <= grid_model.max_cells);
    const tiny = grid_model.clampGrid(0, 0);
    try testing.expectEqual(@as(u16, 2), tiny.x);
    try testing.expectEqual(@as(u16, 2), tiny.y);
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

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const bound = canvas.Widget{
        .id = 7,
        .kind = .terminal,
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .terminal = .{ .pty = 1, .grid = &grid },
    };
    try canvas.emitWidgetTree(&builder, bound, .{});
    var saw_text = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "bound")) saw_text = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_text);

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
    var texts: usize = 0;
    for (empty_builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => fills += 1,
            .draw_text => texts += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), fills);
    try testing.expectEqual(@as(usize, 0), texts);
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

test "box drawing classifies the block and ignores neighbors" {
    try testing.expect(box.isBoxDrawing(0x2500));
    try testing.expect(box.isBoxDrawing(0x259F));
    try testing.expect(!box.isBoxDrawing(0x24FF));
    try testing.expect(!box.isBoxDrawing(0x25A0));
    try testing.expect(box.mergesHorizontally(0x2500));
    try testing.expect(!box.mergesHorizontally(0x2502));
}
