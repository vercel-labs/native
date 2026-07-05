const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_layout_types = @import("text_layout_types.zig");
const text_layout_hash = @import("text_layout_hash.zig");
const plan_key_index = @import("plan_key_index.zig");

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
        // Keyed lookups ride the probe-table index whenever the inputs
        // fit its half-full bound (the runtime budgets always do);
        // oversized library inputs keep the linear scans. Same outputs
        // either way. Entries appended by BOTH loops feed the entry
        // index — the retained-entry loop dedupes against its own
        // appends too. Total appended entries are bounded by
        // plans.len + previous.len, which the fit check covers.
        const use_index = (plans.len >= plan_key_index.min_entries_for_index or
            previous.len >= plan_key_index.min_entries_for_index) and
            plan_key_index.fitsHashSlots(text_layout_cache_index_slots, previous.len) and
            plan_key_index.fitsHashSlots(text_layout_cache_index_slots, plans.len + previous.len);
        if (use_index) {
            text_layout_cache_previous_index.reset();
            for (previous, 0..) |entry, index| {
                var p = TextLayoutCacheIndex.probe(textLayoutKeyHash(entry.key));
                while (text_layout_cache_previous_index.next(&p)) |_| {}
                text_layout_cache_previous_index.insert(p, @intCast(index));
            }
            text_layout_cache_entry_index.reset();
        }

        for (plans, 0..) |plan, layout_index| {
            const previous_index = blk: {
                if (use_index) {
                    const key_hash = textLayoutKeyHash(plan.key);
                    if (self.entryIndexProbe(plan.key, key_hash)) |_| continue;
                    break :blk findTextLayoutCacheEntryIndexed(previous, plan.key, key_hash);
                }
                if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], plan.key) != null) continue;
                break :blk findTextLayoutCacheEntry(previous, plan.key);
            };

            try self.appendEntryMaybeIndexed(.{
                .key = plan.key,
                .line_count = plan.lineCount(),
                .bounds = plan.layout.bounds,
                .last_used_frame = frame_index,
            }, use_index);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = plan.key,
                .layout_index = layout_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, index| {
            if (use_index) {
                if (self.entryIndexProbe(entry.key, textLayoutKeyHash(entry.key))) |_| continue;
            } else if (findTextLayoutCacheEntry(self.entries[0..self.entry_len], entry.key) != null) {
                continue;
            }
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntryMaybeIndexed(entry, use_index);
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

    /// First appended entry equal to `key`, walking the entry index's
    /// probe chain — the indexed equivalent of scanning
    /// `self.entries[0..self.entry_len]`.
    fn entryIndexProbe(self: *TextLayoutCachePlanner, key: TextLayoutKey, key_hash: u64) ?usize {
        var p = TextLayoutCacheIndex.probe(key_hash);
        while (text_layout_cache_entry_index.next(&p)) |candidate| {
            if (textLayoutKeysEqual(self.entries[candidate].key, key)) return candidate;
        }
        return null;
    }

    fn appendEntryMaybeIndexed(self: *TextLayoutCachePlanner, entry: TextLayoutCacheEntry, use_index: bool) Error!void {
        try self.appendEntry(entry);
        if (use_index) {
            var p = TextLayoutCacheIndex.probe(textLayoutKeyHash(entry.key));
            while (text_layout_cache_entry_index.next(&p)) |_| {}
            text_layout_cache_entry_index.insert(p, @intCast(self.entry_len - 1));
        }
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

/// Probe-table scratch for the cache planner (see plan_key_index.zig):
/// sized so the runtime's per-view text-layout budget (2048 plans plus
/// up to 2048 retained previous entries) stays under the half-full
/// bound; bigger inputs fall back to the linear scans.
const text_layout_cache_index_slots = 8192;
const TextLayoutCacheIndex = plan_key_index.HashSlots(text_layout_cache_index_slots);
threadlocal var text_layout_cache_previous_index: TextLayoutCacheIndex = .{};
threadlocal var text_layout_cache_entry_index: TextLayoutCacheIndex = .{};

fn findTextLayoutCacheEntryIndexed(previous: []const TextLayoutCacheEntry, key: TextLayoutKey, key_hash: u64) ?usize {
    var p = TextLayoutCacheIndex.probe(key_hash);
    while (text_layout_cache_previous_index.next(&p)) |candidate| {
        if (textLayoutKeysEqual(previous[candidate].key, key)) return candidate;
    }
    return null;
}

/// Hash agreeing with `textLayoutKeysEqual`: float fields fold negative
/// zero onto zero (`mixF32`) so `==`-equal keys always hash equal.
fn textLayoutKeyHash(key: TextLayoutKey) u64 {
    var hash = plan_key_index.mixHash(key.fingerprint ^ @as(u64, key.font_id));
    hash = plan_key_index.mixF32(hash, key.size);
    hash = plan_key_index.mixF32(hash, key.origin.x);
    hash = plan_key_index.mixF32(hash, key.origin.y);
    hash = plan_key_index.mixF32(hash, key.max_width);
    hash = plan_key_index.mixF32(hash, key.line_height);
    hash = plan_key_index.mixHash(hash ^ @as(u64, @intFromEnum(key.wrap)) ^ (@as(u64, @intFromEnum(key.alignment)) << 8));
    hash = plan_key_index.mixHash(hash ^ @as(u64, @intCast(key.text_len)) ^ (@as(u64, @intCast(key.glyph_count)) << 20));
    return hash;
}

fn shouldRetainUnusedCacheEntry(frame_index: u64, last_used_frame: u64, retention_frames: u64) bool {
    if (retention_frames == 0) return false;
    if (frame_index <= last_used_frame) return true;
    return frame_index - last_used_frame <= retention_frames;
}
