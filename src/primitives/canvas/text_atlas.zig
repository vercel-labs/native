const std = @import("std");
const canvas = @import("root.zig");
const text_interaction = @import("text_interaction.zig");
const plan_key_index = @import("plan_key_index.zig");

const Error = canvas.Error;
const FontId = canvas.FontId;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const isUtf8ContinuationByte = text_interaction.isUtf8ContinuationByte;
const nextTextOffset = text_interaction.nextTextOffset;
const utf8SequenceLength = text_interaction.utf8SequenceLength;

pub const Glyph = struct {
    id: u32,
    font_id: FontId = 0,
    x: f32,
    y: f32,
    advance: f32 = 0,
    text_start: usize = 0,
    text_len: usize = 0,
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

    pub fn build(self: *GlyphAtlasPlanner, display_list: anytype) Error!GlyphAtlasPlan {
        self.reset();
        // Per-glyph dedupe rides the probe-table index whenever the
        // glyph volume is worth a table reset and the output buffer
        // fits the half-full bound (the runtime budget always does);
        // small views and bigger buffers keep the linear scan. Same
        // entries either way.
        var estimated_glyphs: usize = 0;
        for (display_list.commands) |command| {
            switch (command) {
                .draw_text => |value| estimated_glyphs += if (value.glyphs.len > 0) value.glyphs.len else value.text.len,
                else => {},
            }
        }
        const use_index = estimated_glyphs >= plan_key_index.min_entries_for_index and
            plan_key_index.fitsHashSlots(glyph_atlas_index_slots, self.entries.len);
        if (use_index) glyph_atlas_plan_index.reset();
        for (display_list.commands, 0..) |command, command_index| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, command_index, use_index),
                else => {},
            }
        }
        return .{ .entries = self.entries[0..self.len] };
    }

    fn consumeText(self: *GlyphAtlasPlanner, text: anytype, command_index: usize, use_index: bool) Error!void {
        if (text.glyphs.len > 0) {
            for (text.glyphs, 0..) |glyph, glyph_index| {
                const key = GlyphAtlasKey{
                    .font_id = glyphFontId(text.font_id, glyph),
                    .glyph_id = glyph.id,
                    .size = text.size,
                    .subpixel_x = subpixelBucket(text.origin.x + glyph.x),
                    .subpixel_y = subpixelBucket(text.origin.y + glyph.y),
                };
                try self.appendUnique(key, command_index, glyph_index, use_index);
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
            try self.appendUnique(key, command_index, scalar_index, use_index);
        }
    }

    fn appendUnique(self: *GlyphAtlasPlanner, key: GlyphAtlasKey, command_index: usize, glyph_index: usize, use_index: bool) Error!void {
        var probe: GlyphAtlasIndex.Probe = undefined;
        if (use_index) {
            probe = GlyphAtlasIndex.probe(glyphAtlasKeyHash(key));
            while (glyph_atlas_plan_index.next(&probe)) |candidate| {
                if (glyphAtlasKeysEqual(self.entries[candidate].key, key)) return;
            }
        } else {
            for (self.entries[0..self.len]) |entry| {
                if (glyphAtlasKeysEqual(entry.key, key)) return;
            }
        }
        if (self.len >= self.entries.len) return error.GlyphAtlasListFull;
        self.entries[self.len] = .{
            .key = key,
            .command_index = command_index,
            .glyph_index = glyph_index,
        };
        self.len += 1;
        if (use_index) glyph_atlas_plan_index.insert(probe, @intCast(self.len - 1));
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
        // Keyed lookups ride the probe-table index whenever the inputs
        // fit its half-full bound (the runtime budgets always do);
        // oversized library inputs keep the linear scans. Same outputs
        // either way. Entries appended by BOTH loops feed the entry
        // index, bounded by plan.entries.len + previous.len.
        const use_index = (plan.entries.len >= plan_key_index.min_entries_for_index or
            previous.len >= plan_key_index.min_entries_for_index) and
            plan_key_index.fitsHashSlots(glyph_atlas_cache_index_slots, previous.len) and
            plan_key_index.fitsHashSlots(glyph_atlas_cache_index_slots, plan.entries.len + previous.len);
        if (use_index) {
            glyph_atlas_cache_previous_index.reset();
            for (previous, 0..) |entry, index| {
                var p = GlyphAtlasCacheIndex.probe(glyphAtlasKeyHash(entry.key));
                while (glyph_atlas_cache_previous_index.next(&p)) |_| {}
                glyph_atlas_cache_previous_index.insert(p, @intCast(index));
            }
            glyph_atlas_cache_entry_index.reset();
        }

        for (plan.entries, 0..) |entry, atlas_index| {
            const previous_index = blk: {
                if (use_index) {
                    const key_hash = glyphAtlasKeyHash(entry.key);
                    if (self.entryIndexProbe(entry.key, key_hash)) |_| continue;
                    break :blk findGlyphAtlasCacheEntryIndexed(previous, entry.key, key_hash);
                }
                if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
                break :blk findGlyphAtlasCacheEntry(previous, entry.key);
            };
            try self.appendEntryMaybeIndexed(.{
                .key = entry.key,
                .last_used_frame = frame_index,
            }, use_index);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = entry.key,
                .atlas_index = atlas_index,
                .cache_index = previous_index,
            });
        }

        for (previous, 0..) |entry, previous_index| {
            if (use_index) {
                if (self.entryIndexProbe(entry.key, glyphAtlasKeyHash(entry.key))) |_| continue;
            } else if (findGlyphAtlasCacheEntry(self.entries[0..self.entry_len], entry.key) != null) {
                continue;
            }
            if (shouldRetainUnusedCacheEntry(frame_index, entry.last_used_frame, retention_frames) and self.hasEntryCapacity()) {
                try self.appendEntryMaybeIndexed(entry, use_index);
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

    /// First appended entry equal to `key`, walking the entry index's
    /// probe chain — the indexed equivalent of scanning
    /// `self.entries[0..self.entry_len]`.
    fn entryIndexProbe(self: *GlyphAtlasCachePlanner, key: GlyphAtlasKey, key_hash: u64) ?usize {
        var p = GlyphAtlasCacheIndex.probe(key_hash);
        while (glyph_atlas_cache_entry_index.next(&p)) |candidate| {
            if (glyphAtlasKeysEqual(self.entries[candidate].key, key)) return candidate;
        }
        return null;
    }

    fn appendEntryMaybeIndexed(self: *GlyphAtlasCachePlanner, entry: GlyphAtlasCacheEntry, use_index: bool) Error!void {
        try self.appendEntry(entry);
        if (use_index) {
            var p = GlyphAtlasCacheIndex.probe(glyphAtlasKeyHash(entry.key));
            while (glyph_atlas_cache_entry_index.next(&p)) |_| {}
            glyph_atlas_cache_entry_index.insert(p, @intCast(self.entry_len - 1));
        }
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

/// Probe-table scratch for the atlas planners (see plan_key_index.zig):
/// sized so the runtime's per-view glyph budget (8192) stays under the
/// half-full bound; the cache tables allow plan entries plus retained
/// previous entries. Bigger inputs fall back to the linear scans.
const glyph_atlas_index_slots = 16384;
const glyph_atlas_cache_index_slots = 32768;
const GlyphAtlasIndex = plan_key_index.HashSlots(glyph_atlas_index_slots);
const GlyphAtlasCacheIndex = plan_key_index.HashSlots(glyph_atlas_cache_index_slots);
threadlocal var glyph_atlas_plan_index: GlyphAtlasIndex = .{};
threadlocal var glyph_atlas_cache_previous_index: GlyphAtlasCacheIndex = .{};
threadlocal var glyph_atlas_cache_entry_index: GlyphAtlasCacheIndex = .{};

fn findGlyphAtlasCacheEntryIndexed(previous: []const GlyphAtlasCacheEntry, key: GlyphAtlasKey, key_hash: u64) ?usize {
    var p = GlyphAtlasCacheIndex.probe(key_hash);
    while (glyph_atlas_cache_previous_index.next(&p)) |candidate| {
        if (glyphAtlasKeysEqual(previous[candidate].key, key)) return candidate;
    }
    return null;
}

/// Hash agreeing with `glyphAtlasKeysEqual`: `size` folds negative zero
/// onto zero (`mixF32`) so `==`-equal keys always hash equal.
fn glyphAtlasKeyHash(key: GlyphAtlasKey) u64 {
    var hash = plan_key_index.mixHash(@as(u64, key.font_id) ^ (@as(u64, key.glyph_id) << 32));
    hash = plan_key_index.mixF32(hash, key.size);
    hash = plan_key_index.mixHash(hash ^ @as(u64, key.subpixel_x) ^ (@as(u64, key.subpixel_y) << 8));
    return hash;
}

fn isPlanTextSpace(byte: u8) bool {
    return byte == '\n' or byte == '\r' or byte == '\t' or byte == ' ';
}

fn subpixelBucket(value: f32) u8 {
    const fraction = value - @floor(value);
    const scaled = @floor(fraction * 4.0);
    return @intFromFloat(std.math.clamp(scaled, 0, 3));
}

pub fn glyphFontId(run_font_id: FontId, glyph: Glyph) FontId {
    return if (glyph.font_id == 0) run_font_id else glyph.font_id;
}

fn shouldRetainUnusedCacheEntry(frame_index: u64, last_used_frame: u64, retention_frames: u64) bool {
    if (retention_frames == 0) return false;
    if (frame_index <= last_used_frame) return true;
    return frame_index - last_used_frame <= retention_frames;
}
