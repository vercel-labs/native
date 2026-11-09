const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const grid = c.terminal_grid;
const reference = c.TerminalGridReference;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [3]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 78) calls[input[2]] += 1;
    const length = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return length;
}
fn compare(left: anyerror!void, right: anyerror!void) !void {
    if (left) |_| try right else |err| try std.testing.expectError(err, right);
}
fn compareBuilders(left: *const c.Builder, right: *const c.Builder) !void {
    try exact(left.displayList(), right.displayList());
    try exact(left.path_element_len, right.path_element_len);
    try exact(left.path_elements[0..left.path_element_len], right.path_elements[0..right.path_element_len]);
    try exact(left.text_byte_len, right.text_byte_len);
    try exact(left.text_bytes[0..left.text_byte_len], right.text_bytes[0..right.text_byte_len]);
    try exact(left.label_byte_len, right.label_byte_len);
    try exact(left.label_bytes[0..left.label_byte_len], right.label_bytes[0..right.label_byte_len]);
}
fn paired(viewport: grid.TerminalGrid, capacity: usize, options: grid.TerminalPaintOptions, initial_text: usize, initial_paths: usize, sibling: bool) !void {
    const lcmd = try std.testing.allocator.alloc(c.CanvasCommand, capacity);
    defer std.testing.allocator.free(lcmd);
    const rcmd = try std.testing.allocator.alloc(c.CanvasCommand, capacity);
    defer std.testing.allocator.free(rcmd);
    const left = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(left);
    const right = try std.testing.allocator.create(c.Builder);
    defer std.testing.allocator.destroy(right);
    left.* = c.Builder.init(lcmd);
    right.* = c.Builder.init(rcmd);
    left.text_byte_len = initial_text;
    right.text_byte_len = initial_text;
    @memset(left.text_bytes[0..initial_text], 0xa5);
    @memset(right.text_bytes[0..initial_text], 0xa5);
    left.path_element_len = initial_paths;
    right.path_element_len = initial_paths;
    const empty: c.PathElement = .{ .verb = .move_to, .points = .{ .zero(), .zero(), .zero() } };
    @memset(left.path_elements[0..initial_paths], empty);
    @memset(right.path_elements[0..initial_paths], empty);
    const prior_paths = [_]c.PathElement{empty} ** 6;
    if (sibling and capacity >= 2) {
        for ([_]*c.Builder{ left, right }) |builder| {
            try builder.drawText(.{ .id = 1, .font_id = 2, .size = 13, .origin = .zero(), .color = .rgba(1, 1, 1, 1), .text = "sibling borrowed 日本 text" });
            try builder.strokePath(.{ .id = 2, .elements = &prior_paths, .stroke = .{ .fill = .{ .color = .rgba(1, 1, 1, 1) }, .width = 1 } });
        }
    }
    var compiled_options = options;
    compiled_options.tokens.terminal_paint_policy = observed;
    try compare(reference.paint(viewport, left, options), grid.paint(viewport, right, compiled_options));
    try compareBuilders(left, right);
    core.rt.frameReset();
    try compareBuilders(left, right);
}
fn base(rows: []const grid.TerminalRow) grid.TerminalGrid {
    return .{ .rows = rows, .background = .rgba(0.02, 0.04, 0.06, 1), .foreground = .rgba(1, 1, 1, 1), .cursor_color = .rgba(0, 0.5, 1, 0.75), .selection_color = .rgba(0.5, 0, 1, 0.8) };
}
const frame: sdk.geometry.RectF = .init(2.375, 3.25, 400.5, 200.25);

test "compiled terminal paint all box shapes fractional geometry identities and complete stores" {
    _ = core.initialModel();
    for ([_]u64{ 0, 1, 9007199254740993, std.math.maxInt(u64), 0xfedcba9876543210 }) |id| {
        var cells: [160]grid.TerminalCell = undefined;
        for (&cells, 0..) |*cell, i| cell.* = .{ .cp = @intCast(0x2500 + i), .fg = .rgba(0.5, 0.75, 1, 0.875), .underline = i % 2 == 0, .bg = if (i % 3 == 0) .rgba(0.1, 0.2, 0.3, 0.4) else null };
        var rows: [10]grid.TerminalRow = undefined;
        for (&rows, 0..) |*row, i| row.* = .{ .cells = cells[i * 16 ..][0..16], .selection = if (i % 2 == 0) .{ 2, 14 } else null };
        for ([_]f32{ 8, 13, 19.5 }) |size| {
            var tokens = c.DesignTokens{};
            tokens.typography.label_size = size;
            var viewport = base(&rows);
            viewport.cursor = .{ .x = 7, .y = 3 };
            viewport.select_head = .{ .x = 2, .y = 5 };
            viewport.scrollbar = .{ .offset = 4, .len = 10, .total = 50 };
            try paired(viewport, 2048, .{ .frame = frame, .tokens = tokens, .id_base = id, .background_frame = .init(0, 0, 420, 230) }, 0, 0, true);
        }
    }
    try std.testing.expect(calls[0] > 0 and calls[1] > 0);
}

test "compiled terminal paint complete text clusters wide cells styles cursor and clipping" {
    const white = c.Color.rgba(1, 1, 1, 1);
    const red = c.Color.rgba(1, 0, 0, 1);
    const cells = [_]grid.TerminalCell{
        .{ .cp = 'A', .cluster = "A", .fg = white, .bg = red },                 .{ .cp = 'B', .cluster = "B", .fg = white, .bg = red },
        .{ .cp = 'e', .cluster = "e\xcc\x81", .fg = white, .underline = true },
        .{ .cp = '日', .cluster = "日", .fg = red, .wide = .wide },
        .{ .wide = .spacer, .bg = red },                                        .{ .cp = 0x2500, .fg = white, .underline = true },
        .{ .cp = 0x2500, .fg = white, .underline = true },                      .{ .cp = 0 },
        .{ .cp = 'Z', .cluster = "Z", .fg = red, .underline = true },           .{ .cp = 'Q', .cluster = "", .fg = red },
    };
    var rows: [4]grid.TerminalRow = @splat(.{ .cells = &cells, .selection = .{ 0, 8 } });
    for ([_]grid.TerminalCursorShape{ .block, .bar, .underline }) |shape| for ([_]bool{ false, true }) |running| for ([_]bool{ false, true }) |focused| for ([_]f32{ 0, 20, 200 }) |height| {
        var viewport = base(&rows);
        viewport.running = running;
        viewport.cursor = .{ .x = 3, .y = 1, .shape = shape };
        viewport.select_head = .{ .x = 2, .y = 1 };
        viewport.scrollbar = .{ .offset = 3, .len = 4, .total = 30 };
        try paired(viewport, 300, .{ .frame = .init(2.375, 3.25, 400.5, height), .tokens = .{}, .id_base = std.math.maxInt(u64), .focused = focused }, 0, 0, false);
    };
}

test "compiled terminal paint row atomic budgets and every builder failure prefix" {
    const text = "a" ** 32760;
    const cells = [_]grid.TerminalCell{
        .{ .cp = 'a', .cluster = "a", .fg = .rgba(1, 1, 1, 1) }, .{ .cp = 'e', .cluster = "e\xcc\x81", .fg = .rgba(1, 0, 0, 1), .underline = true },
        .{ .cp = 0x2554, .fg = .rgba(1, 1, 1, 1) },              .{ .cp = 0x256d, .fg = .rgba(1, 1, 1, 1), .underline = true },
    };
    const rows = [_]grid.TerminalRow{ .{ .cells = &cells, .selection = .{ 0, 3 } }, .{ .cells = &cells }, .{ .cells = &cells } };
    var viewport = base(&rows);
    viewport.cursor = .{ .x = 1, .y = 2 };
    viewport.select_head = .{ .x = 1, .y = 2 };
    for (0..45) |capacity| try paired(viewport, capacity, .{ .frame = frame, .tokens = .{}, .id_base = 42 }, 0, 0, false);
    for ([_]usize{ 0, 1, 8, 10, 20, 30, 50, 100 }) |budget| for ([_]usize{ 0, 32760, 32767, 32768 }) |reserve| for ([_]usize{ 0, 3, 8, 12 }) |glyphs| {
        try paired(viewport, 100, .{ .frame = frame, .tokens = .{}, .id_base = 42, .command_budget = budget, .text_reserve = reserve, .glyph_budget = glyphs }, 0, 0, true);
    };
    for ([_]usize{ 0, 2042, 2045, 2048 }) |paths| for ([_]usize{ 0, 32765, 32768 }) |bytes| try paired(viewport, 100, .{ .frame = frame, .tokens = .{}, .id_base = 42 }, bytes, paths, false);
    const long_cells = [_]grid.TerminalCell{ .{ .cp = 'a', .cluster = text, .fg = .rgba(1, 1, 1, 1) }, .{ .cp = 'e', .cluster = "e\xcc\x81", .fg = .rgba(1, 1, 1, 1) } };
    const long_rows = [_]grid.TerminalRow{.{ .cells = &long_cells }};
    try paired(base(&long_rows), 100, .{ .frame = frame, .tokens = .{} }, 0, 0, false);
}

test "compiled terminal paint native measurement facts and bounded exact grid sizing" {
    var tokens = c.DesignTokens{};
    tokens.terminal_paint_policy = observed;
    for ([_]f32{ -0.0, 0, 8, 13, 19.5, std.math.inf(f32), std.math.nan(f32) }) |size| {
        tokens.typography.label_size = size;
        try exact(reference.cellMetrics(tokens), grid.cellMetrics(tokens));
    }
    for ([_]usize{ 0, 1, 2, 96, 320, 400, std.math.maxInt(usize) }) |cols| for ([_]usize{ 0, 1, 2, 96, 320, 400, std.math.maxInt(usize) }) |rows| try exact(reference.clampGrid(cols, rows), grid.clampGridWithPolicy(cols, rows, observed));
    try std.testing.expect(calls[2] > 0);
}
