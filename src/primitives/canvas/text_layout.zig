const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_atlas = @import("text_atlas.zig");
const text_layout_types = @import("text_layout_types.zig");
const text_layout_cache = @import("text_layout_cache.zig");
const text_layout_hash = @import("text_layout_hash.zig");
const text_metrics = @import("text_metrics.zig");

const Error = canvas.Error;
const FontId = canvas.FontId;
const DisplayList = canvas.DisplayList;
const Glyph = text_atlas.Glyph;
const max_text_bounds_layout_lines: usize = 64;

pub const DrawText = text_layout_types.DrawText;
pub const TextWrap = text_layout_types.TextWrap;
pub const TextAlign = text_layout_types.TextAlign;
pub const TextLayoutOptions = text_layout_types.TextLayoutOptions;
pub const TextLine = text_layout_types.TextLine;
pub const TextLayout = text_layout_types.TextLayout;
pub const TextLayoutKey = text_layout_types.TextLayoutKey;
pub const TextLayoutPlan = text_layout_cache.TextLayoutPlan;
pub const TextLayoutPlanSet = text_layout_cache.TextLayoutPlanSet;
pub const TextLayoutCacheEntry = text_layout_cache.TextLayoutCacheEntry;
pub const TextLayoutCacheActionKind = text_layout_cache.TextLayoutCacheActionKind;
pub const TextLayoutCacheAction = text_layout_cache.TextLayoutCacheAction;
pub const TextLayoutCachePlan = text_layout_cache.TextLayoutCachePlan;
pub const TextLayoutCachePlanner = text_layout_cache.TextLayoutCachePlanner;
pub const estimateTextWidth = text_metrics.estimateTextWidth;
pub const estimateTextWidthForFont = text_metrics.estimateTextWidthForFont;
pub const estimateTextAdvanceForBytes = text_metrics.estimateTextAdvanceForBytes;
pub const estimatedGlyphAdvance = text_metrics.estimatedGlyphAdvance;

const textLayoutOptionsForDrawText = text_layout_hash.textLayoutOptionsForDrawText;
const textLayoutKey = text_layout_hash.textLayoutKey;

pub const TextLayoutPlanner = struct {
    plans: []TextLayoutPlan,
    lines: []TextLine,
    plan_len: usize = 0,
    line_len: usize = 0,

    pub fn init(plans: []TextLayoutPlan, lines: []TextLine) TextLayoutPlanner {
        return .{ .plans = plans, .lines = lines };
    }

    pub fn reset(self: *TextLayoutPlanner) void {
        self.plan_len = 0;
        self.line_len = 0;
    }

    pub fn build(self: *TextLayoutPlanner, display_list: DisplayList, options: TextLayoutOptions) Error!TextLayoutPlanSet {
        self.reset();
        if (self.plans.len == 0 and self.lines.len == 0) return .{};

        for (display_list.commands) |command| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, options),
                else => {},
            }
        }
        return .{ .plans = self.plans[0..self.plan_len] };
    }

    fn consumeText(self: *TextLayoutPlanner, text: DrawText, options: TextLayoutOptions) Error!void {
        if (self.plan_len >= self.plans.len) return error.TextLayoutPlanListFull;
        const plan = try layoutTextRunPlan(text, textLayoutOptionsForDrawText(options, text), self.lines[self.line_len..]);
        self.plans[self.plan_len] = plan;
        self.plan_len += 1;
        self.line_len += plan.lineCount();
    }
};

const text_interaction = @import("text_interaction.zig");

pub const TextRange = text_interaction.TextRange;
pub const TextSelectionRect = text_interaction.TextSelectionRect;
pub const TextSelection = text_interaction.TextSelection;
pub const TextCaretDirection = text_interaction.TextCaretDirection;
pub const TextCaretMove = text_interaction.TextCaretMove;
pub const TextCompositionUpdate = text_interaction.TextCompositionUpdate;
pub const TextInputEvent = text_interaction.TextInputEvent;
pub const TextEditState = text_interaction.TextEditState;
pub const applyTextInputEvent = text_interaction.applyTextInputEvent;
pub const snapTextSelection = text_interaction.snapTextSelection;
pub const snapTextRange = text_interaction.snapTextRange;
pub const previousTextOffset = text_interaction.previousTextOffset;
pub const nextTextOffset = text_interaction.nextTextOffset;
pub const previousTextWordOffset = text_interaction.previousTextWordOffset;
pub const nextTextWordOffset = text_interaction.nextTextWordOffset;
pub const snapTextOffset = text_interaction.snapTextOffset;
pub const utf8SequenceLength = text_interaction.utf8SequenceLength;
pub const isUtf8ContinuationByte = text_interaction.isUtf8ContinuationByte;

pub fn layoutTextRun(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayout {
    return (try layoutTextRunPlan(text, options, output)).layout;
}

pub fn layoutTextRunPlan(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayoutPlan {
    var len: usize = 0;
    var bounds: ?geometry.RectF = null;
    if (text.glyphs.len > 0) {
        try appendGlyphTextLines(output, &len, text, options, &bounds);
        return .{
            .key = textLayoutKey(text, options),
            .layout = .{ .lines = output[0..len], .bounds = bounds },
        };
    }

    var start: usize = 0;
    while (start <= text.text.len and text.text.len > 0) {
        const end = nextTextLineEnd(text.text, start, text.font_id, text.size, options);
        try appendTextLine(output, &len, text, start, end - start, start, end - start, lineHeight(text, options), options, &bounds);
        if (end >= text.text.len) break;
        start = end;
        if (start < text.text.len and text.text[start] == '\n') start += 1;
        while (options.wrap == .word and start < text.text.len and isTextBreakByte(text.text[start])) start += 1;
    }
    if (text.text.len == 0) {
        try appendTextLine(output, &len, text, 0, 0, 0, 0, lineHeight(text, options), options, &bounds);
    }
    return .{
        .key = textLayoutKey(text, options),
        .layout = .{ .lines = output[0..len], .bounds = bounds },
    };
}

pub fn textBounds(value: DrawText) ?geometry.RectF {
    if (value.glyphs.len == 0 and value.text.len == 0) return null;
    if (value.text_layout) |options| {
        var lines: [max_text_bounds_layout_lines]TextLine = undefined;
        if (layoutTextRun(value, options, &lines)) |layout| {
            if (layout.bounds) |bounds| return bounds;
        } else |_| {}
    }

    var min_x = value.origin.x;
    var min_y = value.origin.y - value.size;
    var max_x = value.origin.x;
    var max_y = value.origin.y + value.size * 0.25;
    if (value.glyphs.len > 0) {
        min_x = value.origin.x + value.glyphs[0].x;
        max_x = min_x + estimatedGlyphAdvance(value.glyphs[0], value.size);
        min_y = value.origin.y + value.glyphs[0].y - value.size;
        max_y = value.origin.y + value.glyphs[0].y + value.size * 0.25;
        for (value.glyphs[1..]) |glyph| {
            const glyph_x = value.origin.x + glyph.x;
            const glyph_y = value.origin.y + glyph.y;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, value.size));
            min_y = @min(min_y, glyph_y - value.size);
            max_y = @max(max_y, glyph_y + value.size * 0.25);
        }
    } else {
        max_x = value.origin.x + estimateTextWidthForFont(value.font_id, value.text, value.size);
    }

    return geometry.RectF.init(
        min_x,
        min_y,
        @max(value.size * 0.25, max_x - min_x),
        @max(value.size * 1.25, max_y - min_y),
    );
}

pub fn layoutTextCaretRect(text: DrawText, options: TextLayoutOptions, offset: usize, lines: []TextLine) Error!?geometry.RectF {
    const layout = try layoutTextRun(text, options, lines);
    return textCaretRectForLayout(text, layout, offset);
}

pub fn textCaretRectForLayout(text: DrawText, layout: TextLayout, offset: usize) ?geometry.RectF {
    const line = textLineForOffset(layout, text.text.len, snapTextOffset(text.text, offset)) orelse return null;
    const x = textLineCaretX(text, line, offset);
    return geometry.RectF.init(x, line.bounds.y, 1, @max(1, line.bounds.height));
}

pub fn layoutTextSelectionRects(
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    lines: []TextLine,
    output: []TextSelectionRect,
) Error![]const TextSelectionRect {
    const layout = try layoutTextRun(text, options, lines);
    return textSelectionRectsForLayout(text, layout, range, output);
}

pub fn textSelectionRectsForLayout(text: DrawText, layout: TextLayout, range: TextRange, output: []TextSelectionRect) Error![]const TextSelectionRect {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return output[0..0];

    var len: usize = 0;
    for (layout.lines) |line| {
        const line_range = textLineRange(text, line);
        const start = @max(normalized.start, line_range.start);
        const end = @min(normalized.end, line_range.end);
        if (start >= end) continue;
        if (len >= output.len) return error.TextSelectionRectListFull;

        const x0 = textLineCaretX(text, line, start);
        const x1 = textLineCaretX(text, line, end);
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        output[len] = .{
            .range = TextRange.init(start, end),
            .rect = geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
        };
        len += 1;
    }
    return output[0..len];
}

pub fn layoutTextOffsetForPoint(text: DrawText, options: TextLayoutOptions, point: geometry.PointF, lines: []TextLine) Error!?usize {
    const layout = try layoutTextRun(text, options, lines);
    return textOffsetForLayoutPoint(text, layout, point);
}

pub fn textOffsetForLayoutPoint(text: DrawText, layout: TextLayout, point: geometry.PointF) ?usize {
    const line = textLineForPoint(layout, point) orelse return null;
    return textLineOffsetForX(text, line, point.x);
}

pub fn nextTextLineEnd(text: []const u8, start: usize, font_id: FontId, size: f32, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) {
        return nextExplicitLineEnd(text, start);
    }

    var index = start;
    var last_break: ?usize = null;
    while (index < text.len) {
        if (text[index] == '\n') return index;
        const next_index = nextTextOffset(text, index);
        const next_width = estimateTextWidthForFont(font_id, text[start..next_index], size);
        if (isTextBreakByte(text[index])) last_break = next_index;
        if (next_width > max_width) {
            if (index == start) return next_index;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return trimTrailingTextBreak(text, start, break_index);
                }
            }
            return index;
        }
        index = next_index;
    }
    return text.len;
}

fn appendGlyphTextLines(output: []TextLine, len: *usize, text: DrawText, options: TextLayoutOptions, bounds: *?geometry.RectF) Error!void {
    const height = lineHeight(text, options);
    const initial_len = len.*;
    var glyph_start: usize = 0;
    while (glyph_start < text.glyphs.len) {
        while (options.wrap == .word and glyph_start < text.glyphs.len and isGlyphTextBreak(text, glyph_start)) glyph_start += 1;
        if (glyph_start >= text.glyphs.len) break;

        const glyph_end = nextGlyphLineEnd(text, glyph_start, options);
        const range = textRangeForGlyphRangeWithGlyphs(text.text, text.glyphs, glyph_start, glyph_end - glyph_start);
        try appendTextLine(output, len, text, range.start, range.byteLen(text.text.len), glyph_start, glyph_end - glyph_start, height, options, bounds);
        glyph_start = glyph_end;
    }
    if (len.* == initial_len) try appendTextLine(output, len, text, 0, 0, 0, 0, height, options, bounds);
}

fn nextGlyphLineEnd(text: DrawText, start: usize, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) return text.glyphs.len;

    var index = start;
    var width: f32 = 0;
    var last_break: ?usize = null;
    while (index < text.glyphs.len) {
        if (isGlyphTextBreak(text, index)) last_break = index;
        const next_width = width + estimatedGlyphAdvance(text.glyphs[index], text.size);
        if (next_width > max_width) {
            if (index == start) return index + 1;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return break_index;
                }
            }
            return index;
        }
        width = next_width;
        index += 1;
    }
    return text.glyphs.len;
}

fn nextExplicitLineEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\n') return index;
    }
    return text.len;
}

fn trimTrailingTextBreak(text: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) {
        trimmed -= 1;
    }
    return if (trimmed == start) end else trimmed;
}

fn appendTextLine(
    output: []TextLine,
    len: *usize,
    text: DrawText,
    text_start: usize,
    text_len: usize,
    glyph_start: usize,
    glyph_len: usize,
    line_height_value: f32,
    options: TextLayoutOptions,
    bounds: *?geometry.RectF,
) Error!void {
    if (len.* >= output.len) return error.TextLayoutLineListFull;
    const baseline = text.origin.y + @as(f32, @floatFromInt(len.*)) * line_height_value;
    const line_bounds = alignTextLineBounds(
        textLineBounds(text, text_start, text_len, glyph_start, glyph_len, baseline, line_height_value),
        options,
    );
    output[len.*] = .{
        .text_start = text_start,
        .text_len = text_len,
        .glyph_start = glyph_start,
        .glyph_len = glyph_len,
        .bounds = line_bounds,
        .baseline = baseline,
    };
    len.* += 1;
    bounds.* = unionOptionalBounds(bounds.*, line_bounds);
}

fn alignTextLineBounds(bounds: geometry.RectF, options: TextLayoutOptions) geometry.RectF {
    const max_width = nonNegative(options.max_width);
    if (max_width <= 0 or bounds.width >= max_width) return bounds;
    const extra = max_width - bounds.width;
    const dx = switch (options.alignment) {
        .start => 0,
        .center => extra * 0.5,
        .end => extra,
    };
    return bounds.translate(geometry.OffsetF.init(dx, 0));
}

fn textLineForOffset(layout: TextLayout, text_len: usize, offset: usize) ?TextLine {
    if (layout.lines.len == 0) return null;
    const normalized = @min(offset, text_len);
    var previous: ?TextLine = null;
    for (layout.lines) |line| {
        const range = textLineRangeForLength(text_len, line);
        if (normalized < range.start) return previous orelse line;
        if (normalized <= range.end) return line;
        previous = line;
    }
    return previous;
}

fn textLineForPoint(layout: TextLayout, point: geometry.PointF) ?TextLine {
    var previous: ?TextLine = null;
    for (layout.lines) |line| {
        if (point.y < line.bounds.y + line.bounds.height) return line;
        previous = line;
    }
    return previous;
}

pub fn textLineRange(text: DrawText, line: TextLine) TextRange {
    return textLineRangeForLength(text.text.len, line);
}

fn textLineRangeForLength(text_len: usize, line: TextLine) TextRange {
    const start = @min(line.text_start, text_len);
    const end = @min(text_len, start + line.text_len);
    return TextRange.init(start, end);
}

pub fn textLineCaretX(text: DrawText, line: TextLine, offset: usize) f32 {
    const range = textLineRange(text, line);
    const snapped = clampTextOffsetToRange(text.text, range, offset);
    if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len) {
        return textLineGlyphCaretX(text, line, range, snapped);
    }
    return line.bounds.x + estimateTextWidthForFont(text.font_id, text.text[range.start..snapped], text.size);
}

fn textLineGlyphCaretX(text: DrawText, line: TextLine, range: TextRange, offset: usize) f32 {
    if (range.end <= range.start) return line.bounds.x;
    if (offset <= range.start) return line.bounds.x;
    if (offset >= range.end) return line.bounds.x + line.bounds.width;

    if (textGlyphLineHasExplicitRanges(text, line)) {
        return textLineExplicitGlyphCaretX(text, line, range, offset);
    }

    const scalar_count = utf8ScalarCount(text.text[range.start..range.end]);
    if (scalar_count == 0) return line.bounds.x;
    const scalar_index = utf8ScalarIndexForOffset(text.text[range.start..range.end], offset - range.start);
    const glyph_offset = @min(line.glyph_len, (scalar_index * line.glyph_len) / scalar_count);
    if (glyph_offset == 0) return line.bounds.x;
    if (glyph_offset >= line.glyph_len or line.glyph_start + glyph_offset >= text.glyphs.len) return line.bounds.x + line.bounds.width;

    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const glyph = text.glyphs[line.glyph_start + glyph_offset];
    return text.origin.x + glyph.x - first_x + (line.bounds.x - raw_bounds.x);
}

fn textLineOffsetForX(text: DrawText, line: TextLine, x: f32) usize {
    const range = textLineRange(text, line);
    if (x <= line.bounds.x) return range.start;
    if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len) {
        return textLineGlyphOffsetForX(text, line, range, x);
    }

    var cursor = range.start;
    var caret_x = line.bounds.x;
    while (cursor < range.end) {
        const next_cursor = nextTextOffset(text.text, cursor);
        const advance = @max(1, estimateTextAdvanceForBytes(text.font_id, text.text[cursor..next_cursor], text.size));
        if (x < caret_x + advance * 0.5) return cursor;
        caret_x += advance;
        cursor = next_cursor;
    }
    return range.end;
}

fn textLineGlyphOffsetForX(text: DrawText, line: TextLine, range: TextRange, x: f32) usize {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const dx = line.bounds.x - raw_bounds.x;
    if (textGlyphLineHasExplicitRanges(text, line)) {
        return textLineExplicitGlyphOffsetForX(text, line, range, x, first_x, dx);
    }

    for (text.glyphs[line.glyph_start..glyph_end], 0..) |glyph, glyph_index| {
        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance * 0.5) {
            const glyph_range = textRangeForGlyph(text.text, text.glyphs, line.glyph_start + glyph_index);
            return clampTextOffsetToRange(text.text, range, glyph_range.start);
        }
    }
    return range.end;
}

fn clampTextOffsetToRange(text: []const u8, range: TextRange, offset: usize) usize {
    const snapped = snapTextOffset(text, offset);
    if (snapped < range.start) return range.start;
    if (snapped > range.end) return range.end;
    return snapped;
}

fn utf8ScalarIndexForOffset(text: []const u8, offset: usize) usize {
    const target = snapTextOffset(text, offset);
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < target) : (index += 1) {
        cursor = nextTextOffset(text, cursor);
    }
    return index;
}

fn lineHeight(text: DrawText, options: TextLayoutOptions) f32 {
    return if (options.line_height > 0) options.line_height else text.size * 1.25;
}

pub fn textLineBounds(text: DrawText, text_start: usize, text_len: usize, glyph_start: usize, glyph_len: usize, baseline: f32, line_height_value: f32) geometry.RectF {
    if (glyph_len > 0 and glyph_start < text.glyphs.len) {
        const glyphs = text.glyphs[glyph_start..@min(text.glyphs.len, glyph_start + glyph_len)];
        const origin_x = glyphs[0].x;
        var min_x: f32 = 0;
        var max_x = estimatedGlyphAdvance(glyphs[0], text.size);
        var min_y = baseline - text.size;
        var max_y = min_y + line_height_value;
        for (glyphs) |glyph| {
            const glyph_x = glyph.x - origin_x;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, text.size));
            min_y = @min(min_y, baseline + glyph.y - text.size);
            max_y = @max(max_y, baseline + glyph.y + text.size * 0.25);
        }
        return geometry.RectF.init(text.origin.x + min_x, min_y, @max(0, max_x - min_x), @max(0, max_y - min_y));
    }
    return geometry.RectF.init(
        text.origin.x,
        baseline - text.size,
        estimateTextWidthForFont(text.font_id, text.text[text_start..@min(text.text.len, text_start + text_len)], text.size),
        line_height_value,
    );
}

pub fn isTextBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isGlyphTextBreak(text: DrawText, glyph_index: usize) bool {
    if (glyph_index >= text.glyphs.len) return false;
    const range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
    return range.start < range.end and isTextBreakByte(text.text[range.start]);
}

fn textRangeForGlyph(text: []const u8, glyphs: []const Glyph, glyph_index: usize) TextRange {
    if (glyph_index >= glyphs.len) return TextRange.init(text.len, text.len);
    const glyph = glyphs[glyph_index];
    if (glyph.text_len > 0) return snapTextRange(text, TextRange.init(glyph.text_start, glyph.text_start + glyph.text_len));
    return textRangeForGlyphRange(text, glyph_index, 1, glyphs.len);
}

fn textRangeForGlyphRangeWithGlyphs(text: []const u8, glyphs: []const Glyph, glyph_start: usize, glyph_len: usize) TextRange {
    if (glyph_len == 0 or glyph_start >= glyphs.len) return textRangeForGlyphRange(text, glyph_start, glyph_len, glyphs.len);
    const glyph_end = @min(glyphs.len, glyph_start + glyph_len);
    var explicit_start: usize = text.len;
    var explicit_end: usize = 0;
    for (glyphs[glyph_start..glyph_end]) |glyph| {
        if (glyph.text_len == 0) return textRangeForGlyphRange(text, glyph_start, glyph_len, glyphs.len);
        const range = snapTextRange(text, TextRange.init(glyph.text_start, glyph.text_start + glyph.text_len));
        explicit_start = @min(explicit_start, range.start);
        explicit_end = @max(explicit_end, range.end);
    }
    return TextRange.init(explicit_start, explicit_end);
}

fn textRangeForGlyphRange(text: []const u8, glyph_start: usize, glyph_len: usize, glyph_count: usize) TextRange {
    if (text.len == 0 or glyph_count == 0) return TextRange.init(0, 0);
    const scalar_count = utf8ScalarCount(text);
    if (scalar_count == 0) return TextRange.init(0, 0);

    const glyph_end = @min(glyph_count, glyph_start + glyph_len);
    const start_scalar = @min(scalar_count, (glyph_start * scalar_count) / glyph_count);
    const end_scalar = @min(scalar_count, ((glyph_end * scalar_count) + glyph_count - 1) / glyph_count);
    return TextRange.init(textOffsetForScalarIndex(text, start_scalar), textOffsetForScalarIndex(text, end_scalar));
}

fn textGlyphLineHasExplicitRanges(text: DrawText, line: TextLine) bool {
    if (line.glyph_len == 0 or line.glyph_start >= text.glyphs.len) return false;
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    for (text.glyphs[line.glyph_start..glyph_end]) |glyph| {
        if (glyph.text_len == 0) return false;
    }
    return true;
}

fn textLineExplicitGlyphCaretX(text: DrawText, line: TextLine, range: TextRange, offset: usize) f32 {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const dx = line.bounds.x - raw_bounds.x;

    for (line.glyph_start..glyph_end) |glyph_index| {
        const glyph = text.glyphs[glyph_index];
        const glyph_range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
        if (glyph_range.end <= range.start or glyph_range.start >= range.end) continue;

        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        if (offset <= glyph_range.start) return glyph_x;
        if (offset < glyph_range.end) {
            const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
            return glyph_x + glyphTextRangeRatio(text.text, glyph_range, offset) * advance;
        }
    }
    return line.bounds.x + line.bounds.width;
}

fn textLineExplicitGlyphOffsetForX(text: DrawText, line: TextLine, range: TextRange, x: f32, first_x: f32, dx: f32) usize {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    for (line.glyph_start..glyph_end) |glyph_index| {
        const glyph = text.glyphs[glyph_index];
        const glyph_range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
        if (glyph_range.end <= range.start or glyph_range.start >= range.end) continue;

        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        if (x <= glyph_x) return @max(range.start, glyph_range.start);

        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance) {
            return textOffsetForGlyphRangeRatio(text.text, glyph_range, (x - glyph_x) / advance);
        }
    }
    return range.end;
}

fn glyphTextRangeRatio(text: []const u8, range: TextRange, offset: usize) f32 {
    const normalized = snapTextRange(text, range);
    if (normalized.end <= normalized.start) return 0;
    const scalar_count = utf8ScalarCount(text[normalized.start..normalized.end]);
    if (scalar_count == 0) return 0;
    const scalar_index = utf8ScalarIndexForOffset(text[normalized.start..normalized.end], offset - normalized.start);
    return @as(f32, @floatFromInt(@min(scalar_index, scalar_count))) / @as(f32, @floatFromInt(scalar_count));
}

fn textOffsetForGlyphRangeRatio(text: []const u8, range: TextRange, ratio: f32) usize {
    const normalized = snapTextRange(text, range);
    const scalar_count = utf8ScalarCount(text[normalized.start..normalized.end]);
    if (scalar_count == 0) return normalized.start;
    const clamped = std.math.clamp(if (std.math.isFinite(ratio)) ratio else 0, 0, 1);
    const scalar_index: usize = @intFromFloat(@floor(clamped * @as(f32, @floatFromInt(scalar_count)) + 0.5));
    return normalized.start + textOffsetForScalarIndex(text[normalized.start..normalized.end], @min(scalar_index, scalar_count));
}

fn textOffsetForScalarIndex(text: []const u8, scalar_index: usize) usize {
    var offset: usize = 0;
    var index: usize = 0;
    while (offset < text.len and index < scalar_index) : (index += 1) {
        offset = nextTextOffset(text, offset);
    }
    return offset;
}

fn utf8ScalarCount(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        count += 1;
        index += @min(utf8SequenceLength(text[index]), text.len - index);
    }
    return count;
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |left| {
        if (b) |right| return left.normalized().unionWith(right.normalized());
        return left;
    }
    return b;
}
fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
