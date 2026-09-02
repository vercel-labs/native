//! Multi-block markdown document model (GFM subset).
//!
//! Paragraph-scoped attributed editing (`text_attr.zig`) is v1. This module
//! owns the next layer: parse / serialize / split / merge / kind change for
//! a list of blocks that round-trip to GFM. The rich-document surface
//! (example + app cores) drives editing; paint chrome lives with the widget.

const std = @import("std");
pub const BlockKind = enum(u8) {
    paragraph = 0,
    heading1 = 1,
    heading2 = 2,
    heading3 = 3,
    bullet_item = 4,
    numbered_item = 5,
    code_fence = 6,
};

/// Compact style-run placeholder (editor layer maps these to text_attr.StyleRun).
pub const StyleRunRef = struct {
    start: u32 = 0,
    end: u32 = 0,
    flags: u8 = 0,
};

pub const Block = struct {
    kind: BlockKind = .paragraph,
    /// Plain UTF-8 body (no markdown markers for non-fence kinds).
    text: []const u8 = "",
    /// Style runs over `text` (paragraph / heading / list item only).
    runs: []const StyleRunRef = &.{},
    /// Fence language tag when kind == code_fence.
    language: []const u8 = "",
};

pub const max_document_blocks: usize = 256;

pub const ParseError = error{
    OutOfMemory,
    TooManyBlocks,
};

fn startsWith(hay: []const u8, needle: []const u8) bool {
    return hay.len >= needle.len and std.mem.eql(u8, hay[0..needle.len], needle);
}

fn trimRightNewline(line: []const u8) []const u8 {
    var end = line.len;
    if (end > 0 and line[end - 1] == '\r') end -= 1;
    return line[0..end];
}

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn numberedPrefixLen(line: []const u8) ?usize {
    // `1. ` / `12. ` …
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    if (i + 2 > line.len) return null;
    if (line[i] != '.' or line[i + 1] != ' ') return null;
    return i + 2;
}

fn classifyLine(line: []const u8) struct { kind: BlockKind, body: []const u8, language: []const u8 } {
    const trimmed = trimRightNewline(line);
    if (startsWith(trimmed, "### ")) {
        return .{ .kind = .heading3, .body = trimmed[4..], .language = "" };
    }
    if (startsWith(trimmed, "## ")) {
        return .{ .kind = .heading2, .body = trimmed[3..], .language = "" };
    }
    if (startsWith(trimmed, "# ")) {
        return .{ .kind = .heading1, .body = trimmed[2..], .language = "" };
    }
    if (startsWith(trimmed, "- ") or startsWith(trimmed, "* ")) {
        return .{ .kind = .bullet_item, .body = trimmed[2..], .language = "" };
    }
    if (numberedPrefixLen(trimmed)) |n| {
        return .{ .kind = .numbered_item, .body = trimmed[n..], .language = "" };
    }
    return .{ .kind = .paragraph, .body = trimmed, .language = "" };
}

/// Parse a GFM subset into owned blocks (caller frees via `freeBlocks`).
pub fn parseBlocks(allocator: std.mem.Allocator, source: []const u8) ParseError![]Block {
    var list: std.ArrayList(Block) = .empty;
    errdefer {
        for (list.items) |b| freeBlock(allocator, b);
        list.deinit(allocator);
    }

    var i: usize = 0;
    var para: std.ArrayList(u8) = .empty;
    defer para.deinit(allocator);

    const flush_para = struct {
        fn call(allocator_: std.mem.Allocator, list_: *std.ArrayList(Block), para_: *std.ArrayList(u8)) ParseError!void {
            if (para_.items.len == 0) return;
            if (list_.items.len >= max_document_blocks) return error.TooManyBlocks;
            const text = try allocator_.dupe(u8, para_.items);
            errdefer allocator_.free(text);
            try list_.append(allocator_, .{ .kind = .paragraph, .text = text });
            para_.clearRetainingCapacity();
        }
    }.call;

    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        const raw_line = source[line_start..i];
        const at_eof = i >= source.len;
        if (!at_eof) i += 1; // consume '\n'

        const line = trimRightNewline(raw_line);

        if (startsWith(line, "```")) {
            try flush_para(allocator, &list, &para);
            if (list.items.len >= max_document_blocks) return error.TooManyBlocks;
            const language = try allocator.dupe(u8, line[3..]);
            errdefer allocator.free(language);
            var body: std.ArrayList(u8) = .empty;
            errdefer body.deinit(allocator);
            while (i < source.len) {
                const fs = i;
                while (i < source.len and source[i] != '\n') : (i += 1) {}
                const fence_line = trimRightNewline(source[fs..i]);
                const fence_eof = i >= source.len;
                if (!fence_eof) i += 1;
                if (startsWith(fence_line, "```")) break;
                if (body.items.len > 0) try body.append(allocator, '\n');
                try body.appendSlice(allocator, fence_line);
            }
            const text = try body.toOwnedSlice(allocator);
            try list.append(allocator, .{
                .kind = .code_fence,
                .text = text,
                .language = language,
            });
            continue;
        }

        if (isBlank(line)) {
            try flush_para(allocator, &list, &para);
            continue;
        }

        const classified = classifyLine(line);
        if (classified.kind == .paragraph) {
            if (para.items.len > 0) try para.append(allocator, '\n');
            try para.appendSlice(allocator, classified.body);
            continue;
        }

        try flush_para(allocator, &list, &para);
        if (list.items.len >= max_document_blocks) return error.TooManyBlocks;
        const text = try allocator.dupe(u8, classified.body);
        errdefer allocator.free(text);
        try list.append(allocator, .{
            .kind = classified.kind,
            .text = text,
            .language = "",
        });
    }
    try flush_para(allocator, &list, &para);

    if (list.items.len == 0) {
        const text = try allocator.dupe(u8, "");
        try list.append(allocator, .{ .kind = .paragraph, .text = text });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeBlock(allocator: std.mem.Allocator, block: Block) void {
    if (block.text.len > 0) allocator.free(block.text);
    if (block.language.len > 0) allocator.free(block.language);
    // runs are not owned by parse today
}

pub fn freeBlocks(allocator: std.mem.Allocator, blocks: []Block) void {
    for (blocks) |b| freeBlock(allocator, b);
    allocator.free(blocks);
}

/// Serialize blocks to GFM into `out`. Returns bytes written or error if
/// the buffer is too small.
pub fn serializeBlocks(blocks: []const Block, out: []u8) error{BufferTooSmall}!usize {
    var o: usize = 0;
    for (blocks, 0..) |block, i| {
        if (i > 0) {
            if (o + 1 > out.len) return error.BufferTooSmall;
            out[o] = '\n';
            o += 1;
            // Blank line between paragraphs / after headings for readable GFM.
            if (block.kind == .paragraph or blocks[i - 1].kind == .paragraph or
                blocks[i - 1].kind == .heading1 or blocks[i - 1].kind == .heading2 or
                blocks[i - 1].kind == .heading3 or blocks[i - 1].kind == .code_fence)
            {
                if (o + 1 > out.len) return error.BufferTooSmall;
                out[o] = '\n';
                o += 1;
            }
        }
        const prefix: []const u8 = switch (block.kind) {
            .paragraph => "",
            .heading1 => "# ",
            .heading2 => "## ",
            .heading3 => "### ",
            .bullet_item => "- ",
            .numbered_item => "1. ",
            .code_fence => "```",
        };
        if (block.kind == .code_fence) {
            if (o + 3 + block.language.len + 1 + block.text.len + 4 > out.len)
                return error.BufferTooSmall;
            @memcpy(out[o .. o + 3], "```");
            o += 3;
            @memcpy(out[o .. o + block.language.len], block.language);
            o += block.language.len;
            out[o] = '\n';
            o += 1;
            @memcpy(out[o .. o + block.text.len], block.text);
            o += block.text.len;
            if (block.text.len == 0 or block.text[block.text.len - 1] != '\n') {
                out[o] = '\n';
                o += 1;
            }
            @memcpy(out[o .. o + 3], "```");
            o += 3;
            continue;
        }
        if (o + prefix.len + block.text.len > out.len) return error.BufferTooSmall;
        @memcpy(out[o .. o + prefix.len], prefix);
        o += prefix.len;
        @memcpy(out[o .. o + block.text.len], block.text);
        o += block.text.len;
    }
    return o;
}

pub const DocError = error{
    OutOfMemory,
    InvalidIndex,
    TooManyBlocks,
};

fn dupBlock(allocator: std.mem.Allocator, block: Block) DocError!Block {
    const text = try allocator.dupe(u8, block.text);
    errdefer allocator.free(text);
    const language = try allocator.dupe(u8, block.language);
    errdefer allocator.free(language);
    return .{
        .kind = block.kind,
        .text = text,
        .runs = block.runs,
        .language = language,
    };
}

/// Split block at `byte_offset` (UTF-8 byte index into block text).
/// Returns a new owned slice; caller frees with `freeBlocks`.
pub fn splitBlock(
    allocator: std.mem.Allocator,
    blocks: []const Block,
    index: usize,
    byte_offset: usize,
) DocError![]Block {
    if (index >= blocks.len) return error.InvalidIndex;
    if (blocks.len + 1 > max_document_blocks) return error.TooManyBlocks;
    const src = blocks[index];
    const off = @min(byte_offset, src.text.len);
    var out: std.ArrayList(Block) = .empty;
    errdefer {
        for (out.items) |b| freeBlock(allocator, b);
        out.deinit(allocator);
    }
    for (blocks, 0..) |b, i| {
        if (i == index) {
            const left_text = try allocator.dupe(u8, src.text[0..off]);
            errdefer allocator.free(left_text);
            const right_text = try allocator.dupe(u8, src.text[off..]);
            errdefer allocator.free(right_text);
            const left_lang = try allocator.dupe(u8, if (src.kind == .code_fence) src.language else "");
            errdefer allocator.free(left_lang);
            try out.append(allocator, .{
                .kind = src.kind,
                .text = left_text,
                .language = left_lang,
            });
            // New block after Enter is a paragraph (unless splitting a fence).
            const right_kind: BlockKind = if (src.kind == .code_fence) .code_fence else .paragraph;
            const right_lang = try allocator.dupe(u8, if (right_kind == .code_fence) src.language else "");
            errdefer allocator.free(right_lang);
            try out.append(allocator, .{
                .kind = right_kind,
                .text = right_text,
                .language = right_lang,
            });
        } else {
            try out.append(allocator, try dupBlock(allocator, b));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Merge `index` into the previous block (Backspace at start of block).
pub fn mergeWithPrevious(
    allocator: std.mem.Allocator,
    blocks: []const Block,
    index: usize,
) DocError![]Block {
    if (index == 0 or index >= blocks.len) return error.InvalidIndex;
    var out: std.ArrayList(Block) = .empty;
    errdefer {
        for (out.items) |b| freeBlock(allocator, b);
        out.deinit(allocator);
    }
    const left = blocks[index - 1];
    const right = blocks[index];
    for (blocks, 0..) |b, i| {
        if (i == index - 1) {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, left.text);
            try buf.appendSlice(allocator, right.text);
            const text = try buf.toOwnedSlice(allocator);
            const language = try allocator.dupe(u8, left.language);
            errdefer allocator.free(language);
            try out.append(allocator, .{
                .kind = left.kind,
                .text = text,
                .language = language,
            });
        } else if (i == index) {
            continue;
        } else {
            try out.append(allocator, try dupBlock(allocator, b));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Change the kind of one block (toolbar / `# ` prefix promotion).
pub fn changeBlockKind(
    allocator: std.mem.Allocator,
    blocks: []const Block,
    index: usize,
    kind: BlockKind,
) DocError![]Block {
    if (index >= blocks.len) return error.InvalidIndex;
    var out: std.ArrayList(Block) = .empty;
    errdefer {
        for (out.items) |b| freeBlock(allocator, b);
        out.deinit(allocator);
    }
    for (blocks, 0..) |b, i| {
        var next = try dupBlock(allocator, b);
        if (i == index) {
            next.kind = kind;
            if (kind != .code_fence and next.language.len > 0) {
                allocator.free(next.language);
                next.language = try allocator.dupe(u8, "");
            }
        }
        try out.append(allocator, next);
    }
    return try out.toOwnedSlice(allocator);
}

test "serializeBlocks heading and paragraph" {
    const blocks = [_]Block{
        .{ .kind = .heading1, .text = "Hi" },
        .{ .kind = .paragraph, .text = "body" },
    };
    var buf: [64]u8 = undefined;
    const n = try serializeBlocks(&blocks, &buf);
    try std.testing.expectEqualStrings("# Hi\n\nbody", buf[0..n]);
}

test "parseBlocks round-trip subset" {
    const src =
        \\# Untitled
        \\
        \\Hello **world**
        \\
        \\- one
        \\1. two
        \\
        \\```ts
        \\const x = 1;
        \\```
    ;
    const blocks = try parseBlocks(std.testing.allocator, src);
    defer freeBlocks(std.testing.allocator, blocks);
    try std.testing.expect(blocks.len >= 5);
    try std.testing.expect(blocks[0].kind == .heading1);
    try std.testing.expectEqualStrings("Untitled", blocks[0].text);
    try std.testing.expect(blocks[1].kind == .paragraph);
    try std.testing.expectEqualStrings("Hello **world**", blocks[1].text);
    try std.testing.expect(blocks[2].kind == .bullet_item);
    try std.testing.expectEqualStrings("one", blocks[2].text);
    try std.testing.expect(blocks[3].kind == .numbered_item);
    try std.testing.expectEqualStrings("two", blocks[3].text);
    try std.testing.expect(blocks[4].kind == .code_fence);
    try std.testing.expectEqualStrings("ts", blocks[4].language);
    try std.testing.expectEqualStrings("const x = 1;", blocks[4].text);
}

test "splitBlock and mergeWithPrevious" {
    const start = [_]Block{
        .{ .kind = .paragraph, .text = "abcdef" },
    };
    const split = try splitBlock(std.testing.allocator, &start, 0, 3);
    defer freeBlocks(std.testing.allocator, split);
    try std.testing.expect(split.len == 2);
    try std.testing.expectEqualStrings("abc", split[0].text);
    try std.testing.expectEqualStrings("def", split[1].text);
    const merged = try mergeWithPrevious(std.testing.allocator, split, 1);
    defer freeBlocks(std.testing.allocator, merged);
    try std.testing.expect(merged.len == 1);
    try std.testing.expectEqualStrings("abcdef", merged[0].text);
}

test "changeBlockKind" {
    const start = [_]Block{
        .{ .kind = .paragraph, .text = "Title" },
    };
    const next = try changeBlockKind(std.testing.allocator, &start, 0, .heading1);
    defer freeBlocks(std.testing.allocator, next);
    try std.testing.expect(next[0].kind == .heading1);
    var buf: [32]u8 = undefined;
    const n = try serializeBlocks(next, &buf);
    try std.testing.expectEqualStrings("# Title", buf[0..n]);
}
