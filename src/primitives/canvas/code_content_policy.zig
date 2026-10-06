//! Owned code-policy packets. Source slices, allocation and paragraph storage
//! stay native; complete lexer state and span decisions are copied from scriptc.
const std = @import("std");
const code = @import("code.zig");
const text_spans = @import("text_spans.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const state_bytes = 608;
pub const header_bytes = 624;
const colors = [_]text_spans.TextSpanColor{ .syntax_plain, .syntax_comment, .syntax_keyword, .syntax_literal, .syntax_function, .syntax_property, .syntax_constant };
const flags = .{ "html_in_tag", "html_expect_tag_name", "html_tag_opened_element", "html_comment", "block_comment", "line_comment", "preprocessor_line", "markdown_line_start" };
comptime {
    const names = .{ "plain", "zig", "javascript", "typescript", "json", "yaml", "shell", "python", "rust", "c_like", "go", "html", "css", "sql", "jsx", "tsx", "markdown" };
    const actual = @typeInfo(code.Language).@"enum".fields;
    if (actual.len != names.len) @compileError("update code language wire");
    for (names, actual, 0..) |name, field, index| if (!std.mem.eql(u8, name, field.name) or field.value != index) @compileError("code language wire changed");
    if (text_spans.max_text_spans_per_paragraph != 32) @compileError("update code span wire capacity");
}

pub fn writeState(bytes: *[state_bytes]u8, state: code.HighlightState) void {
    bytes.* = @splat(0);
    var mask: u32 = 0;
    inline for (flags, 0..) |field, i| if (@field(state, field)) {
        mask |= @as(u32, 1) << @intCast(i);
    };
    std.mem.writeInt(u32, bytes[0..4], mask, .little);
    std.mem.writeInt(u64, bytes[4..12], state.html_expression_depth, .little);
    std.mem.writeInt(u64, bytes[12..20], state.html_tag_expression_base, .little);
    bytes[20] = @intCast(state.html_tag_context_len);
    bytes[21] = @intCast(state.html_element_len);
    bytes[22] = state.html_previous_significant;
    bytes[23] = @intFromBool(state.string_quote != null);
    bytes[24] = state.string_quote orelse 0;
    bytes[25] = state.markdown_fence_byte;
    bytes[26] = state.markdown_fence_len;
    bytes[27] = state.markdown_inline_code_len;
    for (0..32) |i| {
        std.mem.writeInt(u64, bytes[32 + i * 8 ..][0..8], state.html_tag_context_bases[i], .little);
        bytes[288 + i] = @intFromBool(state.html_tag_context_expect_names[i]);
        bytes[320 + i] = @intFromBool(state.html_tag_context_opened_elements[i]);
        std.mem.writeInt(u64, bytes[352 + i * 8 ..][0..8], state.html_element_expression_bases[i], .little);
    }
}

pub fn readState(bytes: *const [state_bytes]u8) error{InvalidCodeState}!code.HighlightState {
    const mask = std.mem.readInt(u32, bytes[0..4], .little);
    if (mask > 255 or bytes[20] > 32 or bytes[21] > 32 or bytes[23] > 1 or
        (bytes[23] == 0 and bytes[24] != 0) or std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.InvalidCodeState;
    var state: code.HighlightState = .{};
    inline for (flags, 0..) |field, i| @field(state, field) = mask & (@as(u32, 1) << @intCast(i)) != 0;
    state.html_expression_depth = @intCast(std.mem.readInt(u64, bytes[4..12], .little));
    state.html_tag_expression_base = @intCast(std.mem.readInt(u64, bytes[12..20], .little));
    state.html_tag_context_len = bytes[20];
    state.html_element_len = bytes[21];
    state.html_previous_significant = bytes[22];
    state.string_quote = if (bytes[23] == 1) bytes[24] else null;
    state.markdown_fence_byte = bytes[25];
    state.markdown_fence_len = bytes[26];
    state.markdown_inline_code_len = bytes[27];
    for (0..32) |i| {
        if (bytes[288 + i] > 1 or bytes[320 + i] > 1) return error.InvalidCodeState;
        state.html_tag_context_bases[i] = @intCast(std.mem.readInt(u64, bytes[32 + i * 8 ..][0..8], .little));
        state.html_tag_context_expect_names[i] = bytes[288 + i] == 1;
        state.html_tag_context_opened_elements[i] = bytes[320 + i] == 1;
        state.html_element_expression_bases[i] = @intCast(std.mem.readInt(u64, bytes[352 + i * 8 ..][0..8], .little));
    }
    return state;
}

pub fn highlight(owner: ?Policy, source: []const u8, language: code.Language, storage: *[text_spans.max_text_spans_per_paragraph]text_spans.TextSpan, state: *code.HighlightState) []const text_spans.TextSpan {
    const policy = owner orelse return code.highlightWithState(source, language, storage, state);
    var small: [4096]u8 = undefined;
    const needed = header_bytes + source.len;
    const input = if (needed <= small.len) small[0..needed] else std.heap.page_allocator.alloc(u8, needed) catch @panic("code policy allocation failed");
    defer if (needed > small.len) std.heap.page_allocator.free(input);
    @memset(input[0..16], 0);
    input[0..3].* = .{ 20, 0, @intCast(@intFromEnum(language)) };
    std.mem.writeInt(u64, input[4..12], source.len, .little);
    writeState(input[16..624], state.*);
    @memcpy(input[624..], source);
    var output: [616 + 32 * 24]u8 = undefined;
    const len = policy(input, &output);
    if (len < 616 or len > output.len) @panic("invalid compiled code result size");
    const count = std.mem.readInt(u32, output[608..612], .little);
    if (count > 32 or len != 616 + @as(usize, count) * 24 or std.mem.readInt(u32, output[612..616], .little) != 0) @panic("invalid compiled code span count");
    const copied_state = readState(output[0..608]) catch @panic("invalid compiled code state");
    var previous: u64 = 0;
    for (0..count) |i| {
        const at = 616 + i * 24;
        const start = std.mem.readInt(u64, output[at..][0..8], .little);
        const end = std.mem.readInt(u64, output[at + 8 ..][0..8], .little);
        const color = std.mem.readInt(u32, output[at + 16 ..][0..4], .little);
        if (start != previous or end <= start or end > source.len or color >= colors.len or std.mem.readInt(u32, output[at + 20 ..][0..4], .little) != 0) @panic("invalid compiled code span");
        storage[i] = .{ .text = source[@intCast(start)..@intCast(end)], .monospace = true, .color = colors[color] };
        previous = end;
    }
    if (previous != source.len) @panic("compiled code lost source bytes");
    state.* = copied_state;
    return storage[0..count];
}

pub const Recipe = struct {
    flags: u8,
    digits: u8,
    axes: u8,
    content: u8,
    line_count: usize,
    added: u128,
    removed: u128,
    chunk_count: usize,
};

pub fn recipe(policy: Policy, arena: std.mem.Allocator, source: []const u8, facts: u8, added: []const usize, removed: []const usize) !Recipe {
    const input = try arena.alloc(u8, 48 + source.len + (added.len + removed.len) * 8);
    @memset(input[0..48], 0);
    input[0..3].* = .{ 20, 1, facts };
    std.mem.writeInt(u64, input[4..12], source.len, .little);
    std.mem.writeInt(u64, input[16..24], added.len, .little);
    std.mem.writeInt(u64, input[24..32], removed.len, .little);
    @memcpy(input[48..][0..source.len], source);
    for (added, 0..) |line, i| std.mem.writeInt(u64, input[48 + source.len + i * 8 ..][0..8], line, .little);
    for (removed, 0..) |line, i| std.mem.writeInt(u64, input[48 + source.len + (added.len + i) * 8 ..][0..8], line, .little);
    var output: [64]u8 = undefined;
    if (policy(input, &output) != output.len or output[0] > 7 or output[1] > 5 or output[2] > 3 or output[3] > 2 or
        std.mem.readInt(u32, output[4..8], .little) != 0 or std.mem.readInt(u64, output[56..64], .little) != 0) @panic("invalid compiled code recipe");
    const lines = std.mem.readInt(u64, output[8..16], .little);
    const count = std.mem.readInt(u64, output[48..56], .little);
    if (lines == 0 or count == 0 or count > @max(1, source.len)) @panic("invalid compiled code recipe counts");
    return .{ .flags = output[0], .digits = output[1], .axes = output[2], .content = output[3], .line_count = @intCast(lines), .added = std.mem.readInt(u128, output[16..32], .little), .removed = std.mem.readInt(u128, output[32..48], .little), .chunk_count = @intCast(count) };
}

pub fn chunks(policy: Policy, arena: std.mem.Allocator, source: []const u8, wrap: bool, count: usize) ![]const usize {
    const input = try arena.alloc(u8, 16 + source.len);
    @memset(input[0..16], 0);
    input[0..3].* = .{ 20, 2, @intFromBool(wrap) };
    std.mem.writeInt(u64, input[4..12], source.len, .little);
    @memcpy(input[16..], source);
    const output = try arena.alloc(u8, 8 + count * 8);
    if (policy(input, output) != output.len or std.mem.readInt(u64, output[0..8], .little) != count) @panic("invalid compiled code chunk count");
    const ends = try arena.alloc(usize, count);
    var previous: usize = 0;
    for (ends, 0..) |*end, i| {
        const next = std.mem.readInt(u64, output[8 + i * 8 ..][0..8], .little);
        if (next > source.len or (next <= previous and source.len != 0)) @panic("invalid compiled code chunk extent");
        end.* = @intCast(next);
        previous = end.*;
    }
    if (previous != source.len) @panic("compiled code chunks lost source bytes");
    return ends;
}

pub const Budget = struct { used: usize, remaining: usize, plain: bool };
pub fn spanBudget(policy: Policy, used: usize, remaining: usize, spans: usize) Budget {
    var input: [32]u8 = @splat(0);
    input[0..2].* = .{ 20, 3 };
    std.mem.writeInt(u64, input[8..16], used, .little);
    std.mem.writeInt(u64, input[16..24], remaining, .little);
    std.mem.writeInt(u64, input[24..32], spans, .little);
    var output: [24]u8 = undefined;
    if (policy(&input, &output) != output.len or output[16] > 1) @panic("invalid compiled code span budget");
    for (output[17..]) |byte| if (byte != 0) @panic("invalid compiled code span budget reserved bytes");
    return .{ .used = @intCast(std.mem.readInt(u64, output[0..8], .little)), .remaining = @intCast(std.mem.readInt(u64, output[8..16], .little)), .plain = output[16] == 1 };
}
