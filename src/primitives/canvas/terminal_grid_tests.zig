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

test "the cursor register: filled only while focused and live, hollow otherwise" {
    const rows = [_]grid_model.TerminalRow{.{ .cells = &.{} }};
    var grid = baseGrid(&rows);
    grid.cursor = .{ .x = 0, .y = 0 };

    var commands: [16]canvas.CanvasCommand = undefined;
    var builder = try paintInto(grid, &commands, .{
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
    var blurred_builder = try paintInto(grid, &blurred_commands, .{
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
    var ended_builder = try paintInto(grid, &ended_commands, .{
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
        // Atlas-entry units: each new code point charges four subpixel
        // variants, so row a (4 cps = 16 entries) fits a 24-entry budget
        // and row b (16 more) crosses it.
        .glyph_budget = 24,
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

test "a wide row of mergeable box glyphs paints under the widget budget" {
    // 320 identical `─` cells merge to ONE geometry command, so the cost
    // estimate must not charge nine per column and skip the row.
    var box_cells: [320]grid_model.TerminalCell = undefined;
    for (&box_cells) |*c| c.* = .{ .cp = 0x2500, .fg = white };
    const rows = [_]grid_model.TerminalRow{.{ .cells = &box_cells }};

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    // A merged ═ paints TWO bars plus its underline; the cost estimate
    // must charge all three or a row of unmergeable underlined doubles
    // (alternating colors break every merge) overruns the ceiling.
    var cells: [320]grid_model.TerminalCell = undefined;
    for (&cells, 0..) |*c, i| {
        c.* = .{ .cp = 0x2550, .fg = if (i % 2 == 0) white else red, .underline = true };
    }
    const rows = [_]grid_model.TerminalRow{
        .{ .cells = &cells },
        .{ .cells = &cells },
    };

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 2600, 80),
        .tokens = .{},
        .command_budget = 1000,
    });
    // Whatever painted, the ceiling held.
    try testing.expect(builder.displayList().commands.len <= 1000);
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
    var builder = try paintInto(grid, &commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 100, 40),
        .tokens = .{},
    });
    const tokens: canvas.DesignTokens = .{};
    const metrics = grid_model.cellMetrics(tokens);
    var saw_cluster = false;
    var saw_bang = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "e\u{0301}")) {
                    saw_cluster = true;
                    try testing.expectApproxEqAbs(@as(f32, 0), text.origin.x, 0.01);
                }
                if (std.mem.eql(u8, text.text, "!")) {
                    saw_bang = true;
                    try testing.expectApproxEqAbs(metrics.width, text.origin.x, 0.01);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_cluster);
    try testing.expect(saw_bang);
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

test "clampGrid trades rows for columns under the cell ceiling" {
    const clamped = grid_model.clampGrid(400, 100);
    try testing.expectEqual(@as(u16, grid_model.max_cols), clamped.x);
    try testing.expect(@as(usize, clamped.x) * @as(usize, clamped.y) <= grid_model.max_cells);
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = frame,
        .tokens = tokens,
    });

    var saw_run = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                saw_run = true;
                const bounds = canvas.CanvasCommand{ .draw_text = text };
                const rect = bounds.bounds() orelse return error.MissingTextBounds;
                const cells: f32 = @floatFromInt(text.text.len);
                const ink_right = text.origin.x + cells * metrics.width;
                try testing.expect(rect.x + rect.width >= ink_right);
                // The run's own frame has to hold it too — a row that
                // fits the grid's columns can never need more width
                // than the cells it was measured into.
                try testing.expect(ink_right <= frame.x + frame.width + 0.001);
            },
            else => {},
        }
    }
    try testing.expect(saw_run);
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
        .frame = geometry.RectF.init(0, 0, 1600, 200),
        .tokens = .{},
        .command_budget = 1792,
    });
    var text_rows: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |t| if (std.mem.eql(u8, t.text, "a" ** 198)) {
                text_rows += 1;
            },
            else => {},
        }
    }
    // Every row's run merges to one draw_text; all six must paint.
    try testing.expectEqual(@as(usize, 6), text_rows);
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
    var builder = try paintInto(baseGrid(&rows), &commands, .{
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
