//! Execute copied Markdown recipes. Portable parsing and composition belong
//! to the compiled owner; this adapter supplies arenas, typed routes and Ui.
const std = @import("std");
const canvas = @import("root.zig");
const markdown = @import("markdown.zig");
pub const Policy = *const fn (request: []const u8, arena: std.mem.Allocator) []const u8;

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.at) return error.InvalidMarkdownRecipe;
        defer self.at += len;
        return self.bytes[self.at..][0..len];
    }
    fn word(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
};
fn put(bytes: []u8, at: usize, value: usize) !void {
    const encoded = std.math.cast(u32, value) orelse return error.MarkdownRequestTooLarge;
    std.mem.writeInt(u32, bytes[at..][0..4], encoded, .little);
}
fn request(arena: std.mem.Allocator, source: []const u8, issue: ?[]const u8, expanded: []const bool, images: []const markdown.ResolvedImage, operation: u8, capacity: usize) ![]u8 {
    const image_count = @min(images.len, markdown.max_markdown_images);
    var len = try std.math.add(usize, 24, source.len);
    len = try std.math.add(usize, len, if (issue) |bytes| bytes.len else 0);
    len = try std.math.add(usize, len, expanded.len);
    for (images[0..image_count]) |image| len = try std.math.add(usize, len, try std.math.add(usize, 20, image.source.len));
    const bytes = try arena.alloc(u8, len);
    @memset(bytes[0..24], 0);
    bytes[0] = 22;
    bytes[1] = operation;
    bytes[2] = 1;
    bytes[3] = @intFromBool(issue != null);
    try put(bytes, 4, source.len);
    try put(bytes, 8, if (issue) |value| value.len else 0);
    try put(bytes, 12, expanded.len);
    try put(bytes, 16, image_count);
    try put(bytes, 20, capacity);
    var at: usize = 24;
    @memcpy(bytes[at..][0..source.len], source);
    at += source.len;
    if (issue) |value| {
        @memcpy(bytes[at..][0..value.len], value);
        at += value.len;
    }
    for (expanded) |flag| {
        bytes[at] = @intFromBool(flag);
        at += 1;
    }
    for (images[0..image_count]) |image| {
        std.mem.writeInt(u64, bytes[at..][0..8], image.image, .little);
        std.mem.writeInt(u32, bytes[at + 8 ..][0..4], @bitCast(image.width), .little);
        std.mem.writeInt(u32, bytes[at + 12 ..][0..4], @bitCast(image.height), .little);
        try put(bytes, at + 16, image.source.len);
        at += 20;
        @memcpy(bytes[at..][0..image.source.len], image.source);
        at += image.source.len;
    }
    std.debug.assert(at == bytes.len);
    return bytes;
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn textAlign(value: u8) !canvas.TextAlign {
    return switch (value) {
        0 => .start,
        1 => .center,
        2 => .end,
        else => error.InvalidMarkdownRecipe,
    };
}
fn mainAlign(value: u32) !canvas.WidgetMainAlignment {
    return switch (value) {
        0 => .start,
        1 => .center,
        2 => .end,
        else => error.InvalidMarkdownRecipe,
    };
}

fn validateHeader(header: []const u8) !void {
    const op = header[0];
    if (op > 8 or header[2] > 2 or word(header, 36) > 64 or word(header, 40) > 32) return error.InvalidMarkdownRecipe;
    if (op != 5 and header[1] != 0 or op == 5 and header[1] > 5) return error.InvalidMarkdownRecipe;
    const allowed_flags: u8 = switch (op) {
        1 => 8,
        2 => 3,
        5 => 12,
        6 => 16,
        else => 0,
    };
    if (header[3] & ~allowed_flags != 0) return error.InvalidMarkdownRecipe;
    const ordinal: i32 = @bitCast(word(header, 32));
    if (ordinal < -1 or ordinal >= markdown.max_markdown_details_per_document or ordinal >= 0 and (op != 5 or header[1] != 2)) return error.InvalidMarkdownRecipe;
    if (op != 8 and (word(header, 24) != 0 or word(header, 28) != 0 or word(header, 52) != 0)) return error.InvalidMarkdownRecipe;
    if (op != 7 and word(header, 56) != 0) return error.InvalidMarkdownRecipe;
    if (op != 3 and op != 7 and word(header, 44) != 0) return error.InvalidMarkdownRecipe;
    if (op != 6 and op != 8 and ordinal < 0 and word(header, 48) != 0) return error.InvalidMarkdownRecipe;
    if (op != 2 and word(header, 40) != 0) return error.InvalidMarkdownRecipe;
    if (op != 0 and op != 1 and op != 5 and word(header, 36) != 0) return error.InvalidMarkdownRecipe;
    if (op != 2 and op != 5 and header[2] != 0) return error.InvalidMarkdownRecipe;
    const main = word(header, 60);
    if (main != std.math.maxInt(u32) and (op != 1 and op != 5 or main > 2)) return error.InvalidMarkdownRecipe;
    for ([_]usize{ 4, 8, 12 }) |offset| {
        const value = float(header, offset);
        if (!std.math.isFinite(value) or value < 0 or op != 0 and op != 1 and op != 2 and op != 5 and word(header, offset) != 0) return error.InvalidMarkdownRecipe;
    }
    if (op != 5 and op != 8 and (word(header, 16) != 0 or word(header, 20) != 0)) return error.InvalidMarkdownRecipe;
}

pub fn collect(policy: Policy, arena: std.mem.Allocator, source: []const u8, output: []markdown.CollectedImageSource) ![]const markdown.CollectedImageSource {
    const input = try request(arena, source, null, &.{}, &.{}, 1, output.len);
    var reader = Reader{ .bytes = policy(input, arena) };
    if (try reader.word() != 1) return error.InvalidMarkdownRecipe;
    const count = try reader.word();
    if (count > output.len) return error.InvalidMarkdownRecipe;
    for (output[0..count]) |*record| {
        const len = try reader.word();
        if (len > record.bytes.len) return error.InvalidMarkdownRecipe;
        @memcpy(record.bytes[0..len], try reader.take(len));
        record.len = len;
    }
    if (reader.at != reader.bytes.len) return error.InvalidMarkdownRecipe;
    return output[0..count];
}

pub fn view(comptime Msg: type, policy: Policy, ui: *canvas.Ui(Msg), source: []const u8, options: markdown.Markdown(Msg).Options) !canvas.Ui(Msg).Node {
    const input = try request(ui.arena, source, options.issue_link_base, options.details_expanded, options.images, 0, 0);
    return execute(Msg, ui, policy(input, ui.arena), options);
}

pub fn execute(comptime Msg: type, ui: *canvas.Ui(Msg), bytes: []const u8, routes: markdown.Markdown(Msg).Options) !canvas.Ui(Msg).Node {
    const Ui = canvas.Ui(Msg);
    // Text, links and labels all outlive the input packet, including when
    // nested code construction resets or replaces a compiled result arena.
    var reader = Reader{ .bytes = try ui.arena.dupe(u8, bytes) };
    if (try reader.word() != 1) return error.InvalidMarkdownRecipe;
    const count = try reader.word();
    const root = try reader.word();
    if (try reader.word() != 0 or count == 0 or root >= count or count > (bytes.len - reader.at) / 64) return error.InvalidMarkdownRecipe;
    const nodes = try ui.arena.alloc(Ui.Node, count);
    for (nodes, 0..) |*node, index| {
        const header = try reader.take(64);
        try validateHeader(header);
        const child_count = word(header, 36);
        if (child_count > (bytes.len - reader.at) / 4) return error.InvalidMarkdownRecipe;
        const children = try ui.arena.alloc(Ui.Node, child_count);
        for (children) |*child| {
            const slot = try reader.word();
            if (slot >= index) return error.InvalidMarkdownRecipe;
            child.* = nodes[slot];
        }
        const span_count = word(header, 40);
        const spans = try ui.arena.alloc(canvas.TextSpan, span_count);
        for (spans) |*span| {
            const h = try reader.take(16);
            const flags = word(h, 0);
            if (flags > 63 or !std.math.isFinite(float(h, 4)) or float(h, 4) < 0) return error.InvalidMarkdownRecipe;
            span.* = .{ .weight = if (flags & 1 != 0) .bold else .regular, .italic = flags & 2 != 0, .monospace = flags & 4 != 0, .underline = flags & 8 != 0, .strikethrough = flags & 16 != 0, .background = if (flags & 32 != 0) .surface_pressed else null, .scale = float(h, 4), .text = try reader.take(word(h, 8)), .link = try reader.take(word(h, 12)) };
        }
        const text = try reader.take(word(header, 44));
        const label = try reader.take(word(header, 48));
        const link = try reader.take(word(header, 52));
        const alignment = try textAlign(header[2]);
        const flags = header[3];
        const ordinal: i32 = @bitCast(word(header, 32));
        if (ordinal < -1 or ordinal >= markdown.max_markdown_details_per_document) return error.InvalidMarkdownRecipe;
        var o: Ui.ElementOptions = .{ .grow = float(header, 4), .padding = if (float(header, 8) == 0) null else float(header, 8), .gap = float(header, 12), .width = float(header, 16), .height = float(header, 20), .text_alignment = alignment, .on_link = routes.on_link, .style_tokens = .{ .foreground = if (flags & 1 != 0) .text_muted else null } };
        const main = word(header, 60);
        if (main != std.math.maxInt(u32)) o.main = try mainAlign(main);
        if (flags & 8 != 0) o.cross = .center;
        node.* = switch (header[0]) {
            0 => ui.column(o, .{children}),
            1 => ui.row(o, .{children}),
            2 => blk: {
                if (flags & 2 != 0) o.text_alignment = .start;
                var paragraph = ui.paragraph(o, spans);
                if (flags & 2 != 0) {
                    paragraph.widget.kind = .data_cell;
                    paragraph.widget.text_alignment = alignment;
                }
                break :blk paragraph;
            },
            3 => ui.text(.{}, text),
            4 => ui.separator(.{}),
            5 => blk: {
                const kind: canvas.WidgetKind = switch (header[1]) {
                    0 => .separator,
                    1 => .stack,
                    2 => .list_item,
                    3 => .table,
                    4 => .data_row,
                    5 => .data_cell,
                    else => return error.InvalidMarkdownRecipe,
                };
                if (header[1] == 0) {
                    o.width = 0;
                    o.frame = .init(0, 0, float(header, 16), 0);
                }
                if (ordinal >= 0) {
                    o.key = .{ .int = @intCast(ordinal) };
                    o.semantics.label = label;
                    o.on_press = if (routes.on_details) |make| make(@intCast(ordinal)) else null;
                }
                var element = ui.el(kind, o, .{children});
                if (ordinal >= 0) element.widget.state.expanded = flags & 4 != 0;
                if (header[1] == 5) element.widget.text_alignment = alignment;
                break :blk element;
            },
            6 => ui.checkbox(.{ .checked = flags & 16 != 0, .disabled = true, .semantics = .{ .label = label } }),
            7 => blk: {
                const language = std.enums.fromInt(canvas.code.Language, word(header, 56)) orelse return error.InvalidMarkdownRecipe;
                break :blk ui.code(.{ .language = language }, text);
            },
            8 => ui.image(.{ .image = std.mem.readInt(u64, header[24..32], .little), .width = float(header, 16), .height = float(header, 20), .semantics = .{ .role = if (link.len > 0) .link else .image, .label = label, .focusable = link.len > 0 }, .on_press = if (link.len > 0 and routes.on_link != null) routes.on_link.?(link) else null }),
            else => unreachable,
        };
    }
    if (reader.at != bytes.len) return error.InvalidMarkdownRecipe;
    return nodes[root];
}
