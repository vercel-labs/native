const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const fingerprints = @import("render_fingerprints.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Radius = drawing_model.Radius;
const shadowBounds = drawing_model.shadowBounds;

const shadowFingerprint = fingerprints.shadowFingerprint;
const blurFingerprint = fingerprints.blurFingerprint;
const nonZeroObjectId = fingerprints.nonZeroObjectId;
const nonNegative = fingerprints.nonNegative;

pub const VisualEffectKind = enum {
    shadow,
    blur,
};

pub const VisualEffect = struct {
    kind: VisualEffectKind,
    command_index: usize,
    id: ?ObjectId = null,
    bounds: ?geometry.RectF = null,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    fingerprint: u64 = 0,
};

pub const VisualEffectPlan = struct {
    effects: []const VisualEffect = &.{},

    pub fn effectCount(self: VisualEffectPlan) usize {
        return self.effects.len;
    }

    pub fn shadowCount(self: VisualEffectPlan) usize {
        return self.effectCountByKind(.shadow);
    }

    pub fn blurCount(self: VisualEffectPlan) usize {
        return self.effectCountByKind(.blur);
    }

    pub fn cachePlan(self: VisualEffectPlan, previous: []const VisualEffectCacheEntry, frame_index: u64, entries: []VisualEffectCacheEntry, actions: []VisualEffectCacheAction) Error!VisualEffectCachePlan {
        var planner = VisualEffectCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }

    fn effectCountByKind(self: VisualEffectPlan, kind: VisualEffectKind) usize {
        var count: usize = 0;
        for (self.effects) |effect| {
            if (effect.kind == kind) count += 1;
        }
        return count;
    }
    pub fn cachePlanWithWorkspace(self: VisualEffectPlan, workspace: ?*compiled_cache.Workspace, previous: []const VisualEffectCacheEntry, frame_index: u64, entries: []VisualEffectCacheEntry, actions: []VisualEffectCacheAction) Error!VisualEffectCachePlan {
        var planner = VisualEffectCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const VisualEffectPlanner = struct {
    effects: []VisualEffect,
    len: usize = 0,

    pub fn init(effects: []VisualEffect) VisualEffectPlanner {
        return .{ .effects = effects };
    }

    pub fn reset(self: *VisualEffectPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *VisualEffectPlanner, display_list: anytype) Error!VisualEffectPlan {
        self.reset();
        for (display_list.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .effects = self.effects[0..self.len] };
    }

    fn consume(self: *VisualEffectPlanner, command: anytype, index: usize) Error!void {
        switch (command) {
            .shadow => |value| try self.append(.{
                .kind = .shadow,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = shadowBounds(value),
                .radius = value.radius,
                .offset = value.offset,
                .blur = nonNegative(value.blur),
                .spread = value.spread,
                .fingerprint = shadowFingerprint(value),
            }),
            .blur => |value| try self.append(.{
                .kind = .blur,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
                .blur = nonNegative(value.radius),
                .fingerprint = blurFingerprint(value),
            }),
            else => {},
        }
    }

    fn append(self: *VisualEffectPlanner, effect: VisualEffect) Error!void {
        if (self.len >= self.effects.len) return error.VisualEffectListFull;
        self.effects[self.len] = effect;
        self.len += 1;
    }
};

pub const VisualEffectKey = struct {
    kind: VisualEffectKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    fingerprint: u64 = 0,
};

pub const VisualEffectCacheEntry = struct {
    key: VisualEffectKey,
    last_used_frame: u64 = 0,
};

pub const VisualEffectCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const VisualEffectCacheAction = struct {
    kind: VisualEffectCacheActionKind,
    key: VisualEffectKey,
    effect_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const VisualEffectCachePlan = struct {
    entries: []const VisualEffectCacheEntry = &.{},
    actions: []const VisualEffectCacheAction = &.{},

    pub fn entryCount(self: VisualEffectCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: VisualEffectCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: VisualEffectCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: VisualEffectCachePlan, kind: VisualEffectCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const VisualEffectCachePlanner = struct {
    entries: []VisualEffectCacheEntry,
    actions: []VisualEffectCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []VisualEffectCacheEntry, actions: []VisualEffectCacheAction) VisualEffectCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *VisualEffectCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *VisualEffectCachePlanner, plan: VisualEffectPlan, previous: []const VisualEffectCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!VisualEffectCachePlan {
        return compiled_cache.build(.effect, VisualEffectCachePlan, self, plan.effects, previous, frame_index, workspace, visualEffectKey, null, error.VisualEffectCacheListFull);
    }

    pub fn build(self: *VisualEffectCachePlanner, effect_plan: VisualEffectPlan, previous: []const VisualEffectCacheEntry, frame_index: u64) Error!VisualEffectCachePlan {
        self.reset();
        for (effect_plan.effects, 0..) |effect, effect_index| {
            const key = visualEffectKey(effect);
            if (findVisualEffectCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findVisualEffectCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .effect_index = effect_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findVisualEffectCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *VisualEffectCachePlanner, entry: VisualEffectCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.VisualEffectCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *VisualEffectCachePlanner, action: VisualEffectCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.VisualEffectCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn visualEffectKey(effect: VisualEffect) VisualEffectKey {
    return .{
        .kind = effect.kind,
        .id = effect.id,
        .command_index = if (effect.id == null) effect.command_index else 0,
        .fingerprint = effect.fingerprint,
    };
}

fn findVisualEffectCacheEntry(entries: []const VisualEffectCacheEntry, key: VisualEffectKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (visualEffectKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn visualEffectKeysEqual(a: VisualEffectKey, b: VisualEffectKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.fingerprint == b.fingerprint;
}
