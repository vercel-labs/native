const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const DisplayList = canvas.DisplayList;
const Color = drawing_model.Color;
const default_sans_font_id = canvas.default_sans_font_id;
const default_mono_font_id = canvas.default_mono_font_id;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;

const max_text_bounds_layout_lines: usize = 64;

pub const Glyph = struct {
    id: u32,
    font_id: FontId = 0,
    x: f32,
    y: f32,
    advance: f32 = 0,
};

pub const GlyphAtlasKey = struct {
    font_id: FontId = 0,
    glyph_id: u32 = 0,
    size: f32 = 0,
    subpixel_x: u8 = 0,
    subpixel_y: u8 = 0,
};

pub const GlyphAtlasEntry = struct {
    key: GlyphAtlasKey,
    command_index: usize,
    glyph_index: usize,
};

pub const GlyphAtlasPlan = struct {
    entries: []const GlyphAtlasEntry = &.{},

    pub fn entryCount(self: GlyphAtlasPlan) usize {
        return self.entries.len;
    }

    pub fn cachePlan(self: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) Error!GlyphAtlasCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_glyph_atlas_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, retention_frames: u64, entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) Error!GlyphAtlasCachePlan {
        var planner = GlyphAtlasCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index, retention_frames);
    }
};

pub const GlyphAtlasPlanner = struct {
    entries: []GlyphAtlasEntry,
    len: usize = 0,

    pub fn init(entries: []GlyphAtlasEntry) GlyphAtlasPlanner {
        return .{ .entries = entries };
    }

    pub fn reset(self: *GlyphAtlasPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *GlyphAtlasPlanner, display_list: DisplayList) Error!GlyphAtlasPlan {
        self.reset();
        for (display_list.commands, 0..) |command, command_index| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, command_index),
                else => {},
            }
        }
        return .{ .entries = self.entries[0..self.len] };
    }

    fn consumeText(self: *GlyphAtlasPlanner, text: DrawText, command_index: usize) Error!void {
        if (text.glyphs.len > 0) {
            for (text.glyphs, 0..) |glyph, glyph_index| {
                const key = GlyphAtlasKey{
                    .font_id = glyphFontId(text.font_id, glyph),
                    .glyph_id = glyph.id,
                    .size = text.size,
                    .subpixel_x = subpixelBucket(text.origin.x + glyph.x),
                    .subpixel_y = subpixelBucket(text.origin.y + glyph.y),
                };
                try self.appendUnique(key, command_index, glyph_index);
            }
            return;
        }

        var text_offset: usize = 0;
        var scalar_index: usize = 0;
        while (text_offset < text.text.len) {
            const next_offset = nextTextOffset(text.text, text_offset);
            defer {
                text_offset = next_offset;
                scalar_index += 1;
            }
            if (isPlanTextSpace(text.text[text_offset])) continue;

            const key = GlyphAtlasKey{
                .font_id = text.font_id,
                .glyph_id = fallbackGlyphId(text.text[text_offset..next_offset]),
                .size = text.size,
                .subpixel_x = subpixelBucket(text.origin.x + @as(f32, @floatFromInt(scalar_index)) * text.size * 0.5),
                .subpixel_y = subpixelBucket(text.origin.y),
            };
            try self.appendUnique(key, command_index, scalar_index);
        }
    }

    fn appendUnique(self: *GlyphAtlasPlanner, key: GlyphAtlasKey, command_index: usize, glyph_index: usize) Error!void {
        for (self.entries[0..self.len]) |entry| {
            if (glyphAtlasKeysEqual(entry.key, key)) return;
        }
        if (self.len >= self.entries.len) return error.GlyphAtlasListFull;
        self.entries[self.len] = .{
            .key = key,
            .command_index = command_index,
            .glyph_index = glyph_index,
        };
        self.len += 1;
    }
};

pub const GlyphAtlasCacheEntry = struct {
    key: GlyphAtlasKey,
    last_used_frame: u64 = 0,
};

pub const GlyphAtlasCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const GlyphAtlasCacheAction = struct {
    kind: GlyphAtlasCacheActionKind,
    key: GlyphAtlasKey,
    atlas_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const GlyphAtlasCachePlan = struct {
    entries: []const GlyphAtlasCacheEntry = &.{},
    actions: []const GlyphAtlasCacheAction = &.{},

    pub fn entryCount(self: GlyphAtlasCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: GlyphAtlasCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: GlyphAtlasCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: GlyphAtlasCachePlan, kind: GlyphAtlasCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const GlyphAtlasCachePlanner = struct {
    entries: []GlyphAtlasCacheEntry,
    actions: []GlyphAtlasCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []GlyphAtlasCacheEntry, actions: []GlyphAtlasCacheAction) GlyphAtlasCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *GlyphAtlasCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *GlyphAtlasCachePlanner, plan: GlyphAtlasPlan, previous: []const GlyphAtlasCacheEntry, frame_index: u64, retention_frames: u64) Error!GlyphAtlasCachePlan {
        self.reset();

        for (plan.entries, 0..) |entry, atlas_index| {
            if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;

            const previous_index = findGlyphAtlasCacheEntry(previous, entry.key);
            try self.appendEntry(.{
                .key = entry.key,
                .last_used_frame = frame_index,
            });
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = entry.key,
                .atlas_index = atlas_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, previous_index| {
            if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntry(entry);
                try self.appendAction(.{
                    .kind = .retain,
                    .key = entry.key,
                    .cache_index = previous_index,
                });
            } else {
                try self.appendAction(.{
                    .kind = .evict,
                    .key = entry.key,
                    .cache_index = previous_index,
                });
            }
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *GlyphAtlasCachePlanner, entry: GlyphAtlasCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.GlyphAtlasCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn hasEntryCapacity(self: *GlyphAtlasCachePlanner) bool {
        return self.entry_len < self.entries.len;
    }

    fn appendAction(self: *GlyphAtlasCachePlanner, action: GlyphAtlasCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.GlyphAtlasCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const DrawText = struct {
    id: ObjectId = 0,
    font_id: FontId = 0,
    size: f32,
    origin: geometry.PointF,
    color: Color,
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
    text_layout: ?TextLayoutOptions = null,
};

pub const TextWrap = enum {
    none,
    word,
    character,
};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextLayoutOptions = struct {
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
};

pub const TextLine = struct {
    text_start: usize = 0,
    text_len: usize = 0,
    glyph_start: usize = 0,
    glyph_len: usize = 0,
    bounds: geometry.RectF = .{},
    baseline: f32 = 0,
};

pub const TextLayout = struct {
    lines: []const TextLine = &.{},
    bounds: ?geometry.RectF = null,

    pub fn lineCount(self: TextLayout) usize {
        return self.lines.len;
    }
};

pub const TextLayoutKey = struct {
    font_id: FontId = 0,
    size: f32 = 0,
    origin: geometry.PointF = .{},
    max_width: f32 = 0,
    line_height: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    text_len: usize = 0,
    glyph_count: usize = 0,
    fingerprint: u64 = 0,
};

pub const TextLayoutPlan = struct {
    key: TextLayoutKey = .{},
    layout: TextLayout = .{},

    pub fn lineCount(self: TextLayoutPlan) usize {
        return self.layout.lineCount();
    }

    pub fn cachePlan(self: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_text_layout_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        var planner = TextLayoutCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index, retention_frames);
    }
};

pub const TextLayoutPlanSet = struct {
    plans: []const TextLayoutPlan = &.{},

    pub fn planCount(self: TextLayoutPlanSet) usize {
        return self.plans.len;
    }

    pub fn lineCount(self: TextLayoutPlanSet) usize {
        var count: usize = 0;
        for (self.plans) |plan| count += plan.lineCount();
        return count;
    }

    pub fn cachePlan(self: TextLayoutPlanSet, previous: []const TextLayoutCacheEntry, frame_index: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        return self.cachePlanWithRetention(previous, frame_index, default_text_layout_cache_retention_frames, entries, actions);
    }

    pub fn cachePlanWithRetention(self: TextLayoutPlanSet, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64, entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) Error!TextLayoutCachePlan {
        var planner = TextLayoutCachePlanner.init(entries, actions);
        return planner.buildMany(self.plans, previous, frame_index, retention_frames);
    }
};

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

pub const TextLayoutCacheEntry = struct {
    key: TextLayoutKey,
    line_count: usize = 0,
    bounds: ?geometry.RectF = null,
    last_used_frame: u64 = 0,
};

pub const TextLayoutCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const TextLayoutCacheAction = struct {
    kind: TextLayoutCacheActionKind,
    key: TextLayoutKey,
    layout_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const TextLayoutCachePlan = struct {
    entries: []const TextLayoutCacheEntry = &.{},
    actions: []const TextLayoutCacheAction = &.{},

    pub fn entryCount(self: TextLayoutCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: TextLayoutCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: TextLayoutCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: TextLayoutCachePlan, kind: TextLayoutCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const TextLayoutCachePlanner = struct {
    entries: []TextLayoutCacheEntry,
    actions: []TextLayoutCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []TextLayoutCacheEntry, actions: []TextLayoutCacheAction) TextLayoutCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *TextLayoutCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *TextLayoutCachePlanner, plan: TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64) Error!TextLayoutCachePlan {
        return self.buildMany(&.{plan}, previous, frame_index, retention_frames);
    }

    pub fn buildMany(self: *TextLayoutCachePlanner, plans: []const TextLayoutPlan, previous: []const TextLayoutCacheEntry, frame_index: u64, retention_frames: u64) Error!TextLayoutCachePlan {
        self.reset();

        for (plans, 0..) |plan, layout_index| {
            if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], plan.key) != null) continue;

            const previous_index = findTextLayoutCacheEntry(previous, plan.key);
            try self.appendEntry(.{
                .key = plan.key,
                .line_count = plan.lineCount(),
                .bounds = plan.layout.bounds,
                .last_used_frame = frame_index,
            });
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = plan.key,
                .layout_index = layout_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, index| {
            if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntry(entry);
                try self.appendAction(.{
                    .kind = .retain,
                    .key = entry.key,
                    .cache_index = index,
                });
            } else {
                try self.appendAction(.{
                    .kind = .evict,
                    .key = entry.key,
                    .cache_index = index,
                });
            }
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *TextLayoutCachePlanner, entry: TextLayoutCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.TextLayoutCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn hasEntryCapacity(self: *TextLayoutCachePlanner) bool {
        return self.entry_len < self.entries.len;
    }

    fn appendAction(self: *TextLayoutCachePlanner, action: TextLayoutCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.TextLayoutCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn init(start: usize, end: usize) TextRange {
        return .{ .start = start, .end = end };
    }

    pub fn normalized(self: TextRange, text_len: usize) TextRange {
        const start = @min(self.start, text_len);
        const end = @min(self.end, text_len);
        return if (start <= end)
            .{ .start = start, .end = end }
        else
            .{ .start = end, .end = start };
    }

    pub fn byteLen(self: TextRange, text_len: usize) usize {
        const range = self.normalized(text_len);
        return range.end - range.start;
    }

    pub fn isCollapsed(self: TextRange, text_len: usize) bool {
        const range = self.normalized(text_len);
        return range.start == range.end;
    }
};

pub const TextSelectionRect = struct {
    range: TextRange = .{},
    rect: geometry.RectF = .{},
};

pub const TextSelection = struct {
    anchor: usize = 0,
    focus: usize = 0,

    pub fn collapsed(offset: usize) TextSelection {
        return .{ .anchor = offset, .focus = offset };
    }

    pub fn range(self: TextSelection, text_len: usize) TextRange {
        return TextRange.init(self.anchor, self.focus).normalized(text_len);
    }

    pub fn isCollapsed(self: TextSelection, text_len: usize) bool {
        return self.range(text_len).isCollapsed(text_len);
    }
};

pub const TextCaretDirection = enum {
    previous,
    next,
    previous_word,
    next_word,
    start,
    end,
};

pub const TextCaretMove = struct {
    direction: TextCaretDirection,
    extend: bool = false,
};

pub const TextCompositionUpdate = struct {
    text: []const u8 = "",
    cursor: ?usize = null,
};

pub const TextInputEvent = union(enum) {
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    clear,
    move_caret: TextCaretMove,
    set_selection: TextSelection,
    set_composition: TextCompositionUpdate,
    commit_composition,
    cancel_composition,
};

pub const TextEditState = struct {
    text: []const u8 = "",
    selection: TextSelection = .{},
    composition: ?TextRange = null,

    pub fn init(text: []const u8) TextEditState {
        return .{
            .text = text,
            .selection = TextSelection.collapsed(text.len),
        };
    }

    pub fn apply(self: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
        return applyTextInputEvent(self, event, output);
    }
};

pub fn applyTextInputEvent(state: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
    const normalized = normalizeTextEditState(state);
    return switch (event) {
        .insert_text => |text| replaceTextEditRange(normalized, activeTextReplaceRange(normalized), text, output, null, text.len),
        .delete_backward => deleteBackwardTextEdit(normalized, output),
        .delete_forward => deleteForwardTextEdit(normalized, output),
        .delete_word_backward => deleteWordBackwardTextEdit(normalized, output),
        .delete_word_forward => deleteWordForwardTextEdit(normalized, output),
        .clear => .{
            .text = "",
            .selection = TextSelection.collapsed(0),
            .composition = null,
        },
        .move_caret => |move| moveTextCaret(normalized, move),
        .set_selection => |selection| .{
            .text = normalized.text,
            .selection = snapTextSelection(normalized.text, selection),
            .composition = null,
        },
        .set_composition => |composition| setTextComposition(normalized, composition, output),
        .commit_composition => .{
            .text = normalized.text,
            .selection = normalized.selection,
            .composition = null,
        },
        .cancel_composition => cancelTextComposition(normalized, output),
    };
}

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
        const range = textRangeForGlyphRange(text.text, glyph_start, glyph_end - glyph_start, text.glyphs.len);
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
    for (text.glyphs[line.glyph_start..glyph_end], 0..) |glyph, glyph_index| {
        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance * 0.5) {
            const glyph_range = textRangeForGlyphRange(text.text, line.glyph_start + glyph_index, 1, text.glyphs.len);
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

pub fn estimateTextWidth(text: []const u8, size: f32) f32 {
    return estimateTextWidthForFont(default_sans_font_id, text, size);
}

pub fn estimateTextWidthForFont(font_id: FontId, text: []const u8, size: f32) f32 {
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = @min(text.len, index + utf8SequenceLength(text[index]));
        width += estimateTextAdvanceForBytes(font_id, text[index..next], size);
        index = next;
    }
    return width;
}

pub fn estimateTextAdvanceForBytes(font_id: FontId, bytes: []const u8, size: f32) f32 {
    if (bytes.len == 0) return 0;
    if (font_id == default_mono_font_id) return size * 0.6;
    if (bytes.len > 1) return size * 0.65;
    return size * geistSansAdvanceFactor(bytes[0]);
}

pub fn estimatedGlyphAdvance(glyph: Glyph, size: f32) f32 {
    return @max(size * 0.25, glyph.advance);
}

fn geistSansAdvanceFactor(byte: u8) f32 {
    return switch (byte) {
        ' ' => 0.25,
        '!' => 0.268,
        '"' => 0.408,
        '#' => 0.654,
        '$' => 0.647,
        '%' => 0.844,
        '&' => 0.718,
        '\'' => 0.213,
        '(' => 0.365,
        ')' => 0.365,
        '*' => 0.469,
        '+' => 0.633,
        ',' => 0.214,
        '-' => 0.424,
        '.' => 0.2,
        '/' => 0.458,
        '0' => 0.66,
        '1' => 0.348,
        '2' => 0.596,
        '3' => 0.622,
        '4' => 0.584,
        '5' => 0.602,
        '6' => 0.601,
        '7' => 0.553,
        '8' => 0.621,
        '9' => 0.601,
        ':' => 0.237,
        ';' => 0.237,
        '<' => 0.605,
        '=' => 0.606,
        '>' => 0.605,
        '?' => 0.498,
        '@' => 0.899,
        'A' => 0.668,
        'B' => 0.678,
        'C' => 0.7,
        'D' => 0.701,
        'E' => 0.602,
        'F' => 0.589,
        'G' => 0.707,
        'H' => 0.702,
        'I' => 0.269,
        'J' => 0.596,
        'K' => 0.651,
        'L' => 0.579,
        'M' => 0.876,
        'N' => 0.737,
        'O' => 0.74,
        'P' => 0.649,
        'Q' => 0.74,
        'R' => 0.67,
        'S' => 0.647,
        'T' => 0.578,
        'U' => 0.688,
        'V' => 0.668,
        'W' => 0.91,
        'X' => 0.628,
        'Y' => 0.628,
        'Z' => 0.542,
        '[' => 0.349,
        '\\' => 0.458,
        ']' => 0.349,
        '^' => 0.537,
        '_' => 0.562,
        '`' => 0.35,
        'a' => 0.574,
        'b' => 0.602,
        'c' => 0.551,
        'd' => 0.602,
        'e' => 0.567,
        'f' => 0.401,
        'g' => 0.601,
        'h' => 0.584,
        'i' => 0.252,
        'j' => 0.258,
        'k' => 0.594,
        'l' => 0.288,
        'm' => 0.879,
        'n' => 0.584,
        'o' => 0.578,
        'p' => 0.602,
        'q' => 0.602,
        'r' => 0.385,
        's' => 0.529,
        't' => 0.399,
        'u' => 0.586,
        'v' => 0.534,
        'w' => 0.817,
        'x' => 0.584,
        'y' => 0.535,
        'z' => 0.549,
        '{' => 0.365,
        '|' => 0.256,
        '}' => 0.365,
        '~' => 0.633,
        else => 0.58,
    };
}

pub fn isTextBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isGlyphTextBreak(text: DrawText, glyph_index: usize) bool {
    if (glyph_index >= text.glyphs.len) return false;
    const range = textRangeForGlyphRange(text.text, glyph_index, 1, text.glyphs.len);
    return range.start < range.end and isTextBreakByte(text.text[range.start]);
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

fn textOffsetForScalarIndex(text: []const u8, scalar_index: usize) usize {
    var offset: usize = 0;
    var index: usize = 0;
    while (offset < text.len and index < scalar_index) : (index += 1) {
        offset = nextTextOffset(text, offset);
    }
    return offset;
}

pub fn fallbackGlyphId(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0;
    const first = bytes[0];
    const len = utf8SequenceLength(first);
    if (len == 1 or len > bytes.len) return first;

    var value: u32 = switch (len) {
        2 => @as(u32, first & 0x1f),
        3 => @as(u32, first & 0x0f),
        4 => @as(u32, first & 0x07),
        else => return first,
    };
    var index: usize = 1;
    while (index < len) : (index += 1) {
        const byte = bytes[index];
        if (!isUtf8ContinuationByte(byte)) return first;
        value = (value << 6) | @as(u32, byte & 0x3f);
    }
    return value;
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

fn glyphAtlasKeysEqual(a: GlyphAtlasKey, b: GlyphAtlasKey) bool {
    return a.font_id == b.font_id and
        a.glyph_id == b.glyph_id and
        a.size == b.size and
        a.subpixel_x == b.subpixel_x and
        a.subpixel_y == b.subpixel_y;
}

fn findGlyphAtlasCacheEntry(entries: []const GlyphAtlasCacheEntry, key: GlyphAtlasKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (glyphAtlasKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn textLayoutOptionsForDrawText(frame_options: TextLayoutOptions, text: DrawText) TextLayoutOptions {
    return text.text_layout orelse frame_options;
}

fn textLayoutKey(text: DrawText, options: TextLayoutOptions) TextLayoutKey {
    return .{
        .font_id = text.font_id,
        .size = text.size,
        .origin = text.origin,
        .max_width = nonNegative(options.max_width),
        .line_height = nonNegative(options.line_height),
        .wrap = options.wrap,
        .alignment = options.alignment,
        .text_len = text.text.len,
        .glyph_count = text.glyphs.len,
        .fingerprint = textLayoutFingerprint(text, options),
    };
}

fn textLayoutFingerprint(text: DrawText, options: TextLayoutOptions) u64 {
    var hash = resourceHashTag("text_layout");
    hash = resourceHashU64(hash, drawTextFingerprint(text));
    hash = resourceHashF32(hash, nonNegative(options.max_width));
    hash = resourceHashF32(hash, nonNegative(options.line_height));
    hash = resourceHashEnum(hash, @intFromEnum(options.wrap));
    hash = resourceHashEnum(hash, @intFromEnum(options.alignment));
    return hash;
}

fn drawTextFingerprint(text: DrawText) u64 {
    var hash = resourceHashTag("glyph_run");
    hash = resourceHashU64(hash, text.font_id);
    hash = resourceHashF32(hash, text.size);
    hash = resourceHashPoint(hash, text.origin);
    hash = resourceHashBytes(hash, text.text);
    hash = resourceHashUsize(hash, text.glyphs.len);
    for (text.glyphs) |glyph| {
        hash = resourceHashU32(hash, glyph.id);
        hash = resourceHashU64(hash, glyphFontId(text.font_id, glyph));
        hash = resourceHashF32(hash, glyph.x);
        hash = resourceHashF32(hash, glyph.y);
        hash = resourceHashF32(hash, glyph.advance);
    }
    hash = resourceHashOptionalTextLayoutOptions(hash, text.text_layout);
    return hash;
}

fn glyphFontId(run_font_id: FontId, glyph: Glyph) FontId {
    return if (glyph.font_id == 0) run_font_id else glyph.font_id;
}

fn findTextLayoutCacheEntry(entries: []const TextLayoutCacheEntry, key: TextLayoutKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (textLayoutKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn shouldRetainUnusedCacheEntry(frame_index: u64, last_used_frame: u64, retention_frames: u64) bool {
    if (retention_frames == 0) return false;
    if (frame_index <= last_used_frame) return true;
    return frame_index - last_used_frame <= retention_frames;
}

fn textLayoutKeysEqual(a: TextLayoutKey, b: TextLayoutKey) bool {
    return a.font_id == b.font_id and
        a.size == b.size and
        a.origin.x == b.origin.x and
        a.origin.y == b.origin.y and
        a.max_width == b.max_width and
        a.line_height == b.line_height and
        a.wrap == b.wrap and
        a.alignment == b.alignment and
        a.text_len == b.text_len and
        a.glyph_count == b.glyph_count and
        a.fingerprint == b.fingerprint;
}

fn isPlanTextSpace(byte: u8) bool {
    return byte == '\n' or byte == '\r' or byte == '\t' or byte == ' ';
}

fn subpixelBucket(value: f32) u8 {
    const fraction = value - @floor(value);
    const scaled = @floor(fraction * 4.0);
    return @intFromFloat(std.math.clamp(scaled, 0, 3));
}

const resource_hash_offset: u64 = 14695981039346656037;
const resource_hash_prime: u64 = 1099511628211;

fn resourceHashTag(tag: []const u8) u64 {
    return resourceHashBytes(resource_hash_offset, tag);
}

fn resourceHashBytes(initial: u64, bytes: []const u8) u64 {
    var hash = initial;
    for (bytes) |byte| hash = resourceHashU8(hash, byte);
    return hash;
}

fn resourceHashU8(hash: u64, value: u8) u64 {
    return (hash ^ value) *% resource_hash_prime;
}

fn resourceHashU32(hash: u64, value: u32) u64 {
    var next = hash;
    next = resourceHashU8(next, @intCast(value & 0xff));
    next = resourceHashU8(next, @intCast((value >> 8) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 16) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 24) & 0xff));
    return next;
}

fn resourceHashU64(hash: u64, value: u64) u64 {
    var next = hash;
    next = resourceHashU32(next, @intCast(value & 0xffff_ffff));
    next = resourceHashU32(next, @intCast((value >> 32) & 0xffff_ffff));
    return next;
}

fn resourceHashUsize(hash: u64, value: usize) u64 {
    return resourceHashU64(hash, @intCast(value));
}

fn resourceHashEnum(hash: u64, value: anytype) u64 {
    return resourceHashU64(hash, @intCast(value));
}

fn resourceHashF32(hash: u64, value: f32) u64 {
    const bits: u32 = @bitCast(value);
    return resourceHashU32(hash, bits);
}

fn resourceHashPoint(hash: u64, point: geometry.PointF) u64 {
    return resourceHashF32(resourceHashF32(hash, point.x), point.y);
}

fn resourceHashOptionalTextLayoutOptions(hash: u64, options: ?TextLayoutOptions) u64 {
    if (options) |value| {
        var next = resourceHashU8(hash, 1);
        next = resourceHashF32(next, nonNegative(value.max_width));
        next = resourceHashF32(next, nonNegative(value.line_height));
        next = resourceHashEnum(next, @intFromEnum(value.wrap));
        next = resourceHashEnum(next, @intFromEnum(value.alignment));
        return next;
    }
    return resourceHashU8(hash, 0);
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

const TextReplaceResult = struct {
    text: []const u8,
    inserted_range: TextRange,
};

fn normalizeTextEditState(state: TextEditState) TextEditState {
    return .{
        .text = state.text,
        .selection = snapTextSelection(state.text, state.selection),
        .composition = if (state.composition) |range| snapTextRange(state.text, range) else null,
    };
}

fn activeTextReplaceRange(state: TextEditState) TextRange {
    if (state.composition) |range| return snapTextRange(state.text, range);
    return state.selection.range(state.text.len);
}

fn replaceTextEditRange(
    state: TextEditState,
    range: TextRange,
    replacement: []const u8,
    output: []u8,
    composition: ?TextRange,
    cursor_offset: usize,
) Error!TextEditState {
    const result = try replaceTextRange(state.text, range, replacement, output);
    const cursor = snapTextOffset(result.text, result.inserted_range.start + @min(cursor_offset, replacement.len));
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(cursor),
        .composition = composition,
    };
}

fn setTextComposition(state: TextEditState, composition: TextCompositionUpdate, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    const cursor = snapTextOffset(composition.text, composition.cursor orelse composition.text.len);
    const result = try replaceTextRange(state.text, range, composition.text, output);
    const absolute_cursor = snapTextOffset(result.text, result.inserted_range.start + cursor);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(absolute_cursor),
        .composition = result.inserted_range,
    };
}

fn cancelTextComposition(state: TextEditState, output: []u8) Error!TextEditState {
    const composition = state.composition orelse return state;
    const range = snapTextRange(state.text, composition);
    const result = try replaceTextRange(state.text, range, "", output);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(result.inserted_range.start),
        .composition = null,
    };
}

fn deleteBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextOffset(state.text, caret)), "", output, null, 0);
}

fn deleteWordBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextWordOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteWordForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextWordOffset(state.text, caret)), "", output, null, 0);
}

fn moveTextCaret(state: TextEditState, move: TextCaretMove) TextEditState {
    const range = state.selection.range(state.text.len);
    const focus = snapTextOffset(state.text, state.selection.focus);
    const target = switch (move.direction) {
        .previous => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextOffset(state.text, focus),
        .next => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextOffset(state.text, focus),
        .previous_word => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextWordOffset(state.text, focus),
        .next_word => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextWordOffset(state.text, focus),
        .start => 0,
        .end => state.text.len,
    };
    const selection = if (move.extend)
        TextSelection{ .anchor = state.selection.anchor, .focus = target }
    else
        TextSelection.collapsed(target);
    return .{
        .text = state.text,
        .selection = snapTextSelection(state.text, selection),
        .composition = null,
    };
}

fn replaceTextRange(source: []const u8, range: TextRange, replacement: []const u8, output: []u8) Error!TextReplaceResult {
    const snapped = snapTextRange(source, range);
    const prefix_len = snapped.start;
    const suffix = source[snapped.end..];
    const suffix_start = prefix_len + replacement.len;
    const next_len = prefix_len + replacement.len + suffix.len;
    if (next_len > output.len) return error.TextEditBufferTooSmall;

    if (suffix_start > snapped.end) {
        std.mem.copyBackwards(u8, output[suffix_start..next_len], suffix);
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
    } else {
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
        std.mem.copyForwards(u8, output[suffix_start..next_len], suffix);
    }
    return .{
        .text = output[0..next_len],
        .inserted_range = TextRange.init(prefix_len, suffix_start),
    };
}

pub fn snapTextSelection(text: []const u8, selection: TextSelection) TextSelection {
    return .{
        .anchor = snapTextOffset(text, selection.anchor),
        .focus = snapTextOffset(text, selection.focus),
    };
}

pub fn snapTextRange(text: []const u8, range: TextRange) TextRange {
    const normalized = range.normalized(text.len);
    return TextRange.init(
        snapTextOffset(text, normalized.start),
        snapTextOffset(text, normalized.end),
    ).normalized(text.len);
}

pub fn previousTextOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    if (cursor == 0) return 0;
    cursor -= 1;
    while (cursor > 0 and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

pub fn nextTextOffset(text: []const u8, offset: usize) usize {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return text.len;
    return @min(text.len, cursor + utf8SequenceLength(text[cursor]));
}

pub fn previousTextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor > 0) {
        const previous = previousTextOffset(text, cursor);
        if (textOffsetStartsWord(text, previous)) break;
        cursor = previous;
    }
    while (cursor > 0) {
        const previous = previousTextOffset(text, cursor);
        if (!textOffsetStartsWord(text, previous)) break;
        cursor = previous;
    }
    return cursor;
}

pub fn nextTextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor < text.len and !textOffsetStartsWord(text, cursor)) {
        cursor = nextTextOffset(text, cursor);
    }
    while (cursor < text.len and textOffsetStartsWord(text, cursor)) {
        cursor = nextTextOffset(text, cursor);
    }
    return cursor;
}

pub fn snapTextOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and cursor < text.len and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

pub fn utf8SequenceLength(lead: u8) usize {
    if ((lead & 0x80) == 0) return 1;
    if ((lead & 0xe0) == 0xc0) return 2;
    if ((lead & 0xf0) == 0xe0) return 3;
    if ((lead & 0xf8) == 0xf0) return 4;
    return 1;
}

pub fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn textOffsetStartsWord(text: []const u8, offset: usize) bool {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return false;
    const lead = text[cursor];
    if ((lead & 0x80) != 0) return true;
    return std.ascii.isAlphanumeric(lead) or lead == '_';
}
