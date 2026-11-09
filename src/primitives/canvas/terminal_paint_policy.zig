//! Copied terminal canvas programs. Native owns measurement, builder storage
//! and command execution; no borrowed pointer crosses the portable boundary.
const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");
const model = @import("terminal_grid.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
fn put(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []u8, at: usize, v: f32) void {
    put(b, at, @bitCast(v));
}
fn getFloat(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn putRect(b: []u8, at: usize, r: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| float(b, at + i * 4, @field(r, name));
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .init(getFloat(b, at), getFloat(b, at + 4), getFloat(b, at + 8), getFloat(b, at + 12));
}
fn putColor(b: []u8, at: usize, c: canvas.Color) void {
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| float(b, at + i * 4, @field(c, name));
}
fn color(b: []const u8, at: usize) canvas.Color {
    return .rgba(getFloat(b, at), getFloat(b, at + 4), getFloat(b, at + 8), getFloat(b, at + 12));
}
fn size(v: usize) u32 {
    return std.math.cast(u32, v) orelse @panic("terminal program exceeds addressable storage");
}
fn saturatedSize(v: usize) u32 {
    return @intCast(@min(v, std.math.maxInt(u32)));
}
fn add(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch @panic("terminal program size overflow");
}
fn mul(a: usize, b: usize) usize {
    return std.math.mul(usize, a, b) catch @panic("terminal program size overflow");
}
fn header(b: []u8, mode: u8) void {
    @memset(b, 0);
    b[0..4].* = .{ 78, 1, mode, @import("render_plan_policy.zig").numericFlags() };
}

pub fn metrics(tokens: canvas.DesignTokens, policy: Policy) model.TerminalCellMetrics {
    var request: [16]u8 = undefined;
    header(&request, 1);
    const font_size = tokens.typography.label_size;
    float(&request, 4, font_size);
    float(&request, 8, canvas.measureTextWidthForFont(tokens.text_measure, tokens.typography.mono_font_id, "MMMMMMMMMMMMMMMM", font_size));
    var out: [16]u8 = @splat(0xa5);
    if (policy(&request, &out) != out.len or read(&out, 0) != 1) @panic("invalid compiled terminal metrics");
    return .{ .width = getFloat(&out, 4), .height = getFloat(&out, 8), .font_size = getFloat(&out, 12) };
}

pub fn clampGrid(cols: usize, rows: usize, policy: Policy) model.TerminalCellPos {
    var request: [16]u8 = undefined;
    header(&request, 2);
    put(&request, 4, saturatedSize(cols));
    put(&request, 8, saturatedSize(rows));
    var out: [12]u8 = @splat(0xa5);
    if (policy(&request, &out) != out.len or read(&out, 0) != 1 or read(&out, 4) < 2 or read(&out, 4) > model.max_cols or read(&out, 8) < 2 or read(&out, 8) > model.max_rows or @as(u64, read(&out, 4)) * read(&out, 8) > model.max_cells) @panic("invalid compiled terminal grid");
    return .{ .x = @intCast(read(&out, 4)), .y = @intCast(read(&out, 8)) };
}

pub fn paint(grid: model.TerminalGrid, builder: *canvas.Builder, options: model.TerminalPaintOptions, policy: Policy) !void {
    const allocator = std.heap.page_allocator;
    var bytes: usize = 272;
    for (grid.rows) |row| {
        bytes = add(bytes, 16);
        for (row.cells) |cell| bytes = add(bytes, add(48, cell.cluster.len));
    }
    const request = allocator.alloc(u8, bytes) catch @panic("terminal request storage exhausted");
    defer allocator.free(request);
    header(request, 0);
    const flags: u32 = @as(u32, @intFromBool(grid.running)) | (@as(u32, @intFromBool(options.focused)) << 1) | (@as(u32, @intFromBool(grid.cursor != null)) << 2) | (@as(u32, @intFromBool(grid.select_head != null)) << 3) | (@as(u32, @intFromBool(options.background_frame != null)) << 4);
    put(request, 4, flags);
    put(request, 8, size(grid.rows.len));
    put(request, 12, size(builder.len));
    put(request, 16, size(builder.commands.len));
    put(request, 20, saturatedSize(options.command_budget));
    put(request, 24, size(builder.text_byte_len));
    put(request, 28, size(builder.text_bytes.len));
    var text_total: usize = 0;
    var path_total: usize = 0;
    for (builder.displayList().commands) |command| switch (command) {
        .draw_text => |c| text_total = add(text_total, c.text.len),
        .fill_path => |c| path_total = add(path_total, c.elements.len),
        .stroke_path => |c| path_total = add(path_total, c.elements.len),
        else => {},
    };
    put(request, 32, size(text_total));
    put(request, 36, saturatedSize(options.text_reserve));
    put(request, 40, size(builder.path_element_len));
    put(request, 44, size(builder.path_elements.len));
    put(request, 48, size(path_total));
    put(request, 52, saturatedSize(options.path_reserve));
    put(request, 56, saturatedSize(options.glyph_budget));
    std.mem.writeInt(u64, request[64..72], options.id_base, .little);
    putRect(request, 72, options.frame);
    if (options.background_frame) |r| putRect(request, 88, r);
    const metric = model.cellMetrics(options.tokens);
    float(request, 104, metric.font_size);
    float(request, 108, metric.width);
    float(request, 112, metric.height);
    for ([_]canvas.Color{ grid.background, grid.foreground, grid.cursor_color, grid.selection_color, options.tokens.colors.focus_ring, options.tokens.colors.text_muted }, 0..) |c, i| putColor(request, 120 + i * 16, c);
    if (grid.cursor) |c| {
        put(request, 216, c.x);
        put(request, 220, c.y);
        put(request, 224, @intFromEnum(c.shape));
    }
    if (grid.select_head) |h| {
        put(request, 228, h.x);
        put(request, 232, h.y);
    }
    put(request, 236, grid.scrollbar.offset);
    put(request, 240, grid.scrollbar.len);
    put(request, 244, grid.scrollbar.total);
    var at: usize = 272;
    for (grid.rows) |row| {
        put(request, at, size(row.cells.len));
        if (row.selection) |s| {
            put(request, at + 4, 1);
            put(request, at + 8, s[0]);
            put(request, at + 12, s[1]);
        }
        at += 16;
        for (row.cells) |cell| {
            put(request, at, cell.cp);
            put(request, at + 4, @as(u32, @intFromEnum(cell.wide)) | (@as(u32, @intFromBool(cell.underline)) << 2) | (@as(u32, @intFromBool(cell.bg != null)) << 3));
            put(request, at + 8, size(cell.cluster.len));
            putColor(request, at + 16, cell.fg);
            if (cell.bg) |c| putColor(request, at + 32, c);
            @memcpy(request[at + 48 ..][0..cell.cluster.len], cell.cluster);
            at += 48 + cell.cluster.len;
        }
    }
    const capacity = add(32, add(mul(builder.commands.len - builder.len, 96), add(mul(builder.path_elements.len - builder.path_element_len, 28), builder.text_bytes.len - builder.text_byte_len)));
    const output = allocator.alloc(u8, capacity) catch @panic("terminal result storage exhausted");
    defer allocator.free(output);
    @memset(output, 0xa5);
    const length = policy(request, output);
    if (length < 32 or length > output.len) @panic("invalid compiled terminal result length");
    const result = output[0..length];
    const count = read(result, 4);
    const paths = read(result, 8);
    const text = read(result, 12);
    const err = read(result, 20);
    if (read(result, 0) != 1 or count > builder.commands.len - builder.len or paths > builder.path_elements.len - builder.path_element_len or text > builder.text_bytes.len - builder.text_byte_len or read(result, 16) > grid.rows.len or err > 2 or !std.mem.allEqual(u8, result[24..32], 0) or add(32, add(mul(count, 96), add(mul(paths, 28), text))) != length) @panic("invalid compiled terminal storage result");
    const path_at = 32 + @as(usize, count) * 96;
    const text_at = path_at + @as(usize, paths) * 28;
    // Copy the entire result's owned stores, including a failed append's
    // allocation prefix. Rollback of a torn row is already in the program.
    const elements = try builder.allocPathElements(paths);
    for (elements, 0..) |*element, i| {
        const a = path_at + i * 28;
        if (read(result, a) > 2) @panic("invalid terminal path capability");
        element.* = .{ .verb = @enumFromInt(read(result, a)), .points = .{ .init(getFloat(result, a + 4), getFloat(result, a + 8)), .init(getFloat(result, a + 12), getFloat(result, a + 16)), .init(getFloat(result, a + 20), getFloat(result, a + 24)) } };
    }
    const text_bytes = builder.allocTextBytes(result[text_at..]) catch @panic("invalid compiled terminal text capacity");
    for (0..count) |i| {
        const a = 32 + i * 96;
        const op = read(result, a);
        const id = std.mem.readInt(u64, result[a + 4 ..][0..8], .little);
        if (op > 6 or read(result, a + 12) != 0 or !std.mem.allEqual(u8, result[a + 76 ..][0..20], 0)) @panic("invalid terminal drawing capability");
        const r = rect(result, a + 16);
        const c = color(result, a + 32);
        const stroke = getFloat(result, a + 48);
        const start = read(result, a + 52);
        const n = read(result, a + 56);
        const p = read(result, a + 60);
        const pn = read(result, a + 64);
        if (@as(u64, start) + n > text or @as(u64, p) + pn > paths) @panic("invalid terminal borrowed range");
        switch (op) {
            0 => try builder.fillRect(.{ .id = id, .rect = r, .fill = .{ .color = c } }),
            1 => try builder.strokeRect(.{ .id = id, .rect = r, .stroke = .{ .fill = .{ .color = c }, .width = stroke } }),
            2 => try builder.pushClip(.{ .id = id, .rect = r }),
            3 => try builder.drawText(.{ .id = id, .font_id = options.tokens.typography.mono_font_id, .size = stroke, .origin = .init(r.x, r.y), .color = c, .text = text_bytes[start..][0..n], .text_layout = .{ .wrap = .none, .line_height = getFloat(result, a + 72), .measure = options.tokens.text_measure } }),
            4 => try builder.drawLine(.{ .id = id, .from = .init(r.x, r.y), .to = .init(r.width, r.height), .stroke = .{ .fill = .{ .color = c }, .width = stroke } }),
            5 => try builder.strokePath(.{ .id = id, .elements = elements[p..][0..pn], .stroke = .{ .fill = .{ .color = c }, .width = stroke }, .cap = .butt }),
            6 => try builder.popClip(),
            else => unreachable,
        }
    }
    if (err == 1) return error.DisplayListFull;
    if (err == 2) return error.ChartPathElementListFull;
}
