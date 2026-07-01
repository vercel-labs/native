const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Color = drawing_model.Color;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;
const GlyphAtlasCachePlanner = canvas.GlyphAtlasCachePlanner;
const TextLayoutCachePlanner = canvas.TextLayoutCachePlanner;

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
        return canvas.applyTextInputEvent(self, event, output);
    }
};
