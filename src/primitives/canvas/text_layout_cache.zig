const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_layout_types = @import("text_layout_types.zig");
const text_layout_hash = @import("text_layout_hash.zig");

const Error = canvas.Error;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;
const TextLayout = text_layout_types.TextLayout;
const TextLayoutKey = text_layout_types.TextLayoutKey;
const textLayoutKeysEqual = text_layout_hash.textLayoutKeysEqual;

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
