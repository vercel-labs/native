//! Multi-block markdown document model (sketch for M5).
//!
//! Paragraph-scoped attributed editing (`text_attr.zig`) is v1. This module
//! owns the *next* layer: a list of blocks that serialize to GFM. Not wired
//! into widgets yet — dogfood paragraph editing first.

const std = @import("std");
const text_attr = @import("text_attr.zig");

pub const BlockKind = enum {
    paragraph,
    heading1,
    heading2,
    heading3,
    bullet_item,
    numbered_item,
    code_fence,
};

pub const Block = struct {
    kind: BlockKind = .paragraph,
    /// Plain UTF-8 body (no markdown markers).
    text: []const u8 = "",
    /// Style runs over `text` (paragraph / heading / list item only).
    runs: []const text_attr.StyleRun = &.{},
    /// Fence language tag when kind == code_fence.
    language: []const u8 = "",
};

pub const max_document_blocks: usize = 256;

/// Serialize blocks to GFM into `out`. Returns bytes written or error if
/// the buffer is too small.
pub fn serializeBlocks(blocks: []const Block, out: []u8) error{BufferTooSmall}!usize {
    var o: usize = 0;
    for (blocks, 0..) |block, i| {
        if (i > 0) {
            if (o + 1 > out.len) return error.BufferTooSmall;
            out[o] = '\n';
            o += 1;
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

test "serializeBlocks heading and paragraph" {
    const blocks = [_]Block{
        .{ .kind = .heading1, .text = "Hi" },
        .{ .kind = .paragraph, .text = "body" },
    };
    var buf: [64]u8 = undefined;
    const n = try serializeBlocks(&blocks, &buf);
    try std.testing.expectEqualStrings("# Hi\nbody", buf[0..n]);
}
