const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const equality_model = @import("equality.zig");
const fingerprints = @import("render_fingerprints.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Affine = drawing_model.Affine;
const optionalRectsEqual = equality_model.optionalRectsEqual;

const affinesEqual = fingerprints.affinesEqual;
const renderLayerFingerprint = fingerprints.renderLayerFingerprint;
const renderLayerFingerprintAppend = fingerprints.renderLayerFingerprintAppend;

pub const RenderLayer = struct {
    command_start: usize = 0,
    command_count: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
    fingerprint: u64 = 0,
};

pub const RenderLayerPlan = struct {
    layers: []const RenderLayer = &.{},

    pub fn layerCount(self: RenderLayerPlan) usize {
        return self.layers.len;
    }

    pub fn opacityLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.opacity != 1) count += 1;
        }
        return count;
    }

    pub fn clipLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.clip != null) count += 1;
        }
        return count;
    }

    pub fn transformLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (!affinesEqual(layer.transform, Affine.identity())) count += 1;
        }
        return count;
    }

    pub fn cachePlan(self: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64, entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) Error!RenderLayerCachePlan {
        var planner = RenderLayerCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
    pub fn cachePlanWithWorkspace(self: RenderLayerPlan, workspace: ?*compiled_cache.Workspace, previous: []const RenderLayerCacheEntry, frame_index: u64, entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) Error!RenderLayerCachePlan {
        var planner = RenderLayerCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderLayerPlanner = struct {
    layers: []RenderLayer,
    len: usize = 0,

    pub fn init(layers: []RenderLayer) RenderLayerPlanner {
        return .{ .layers = layers };
    }

    pub fn reset(self: *RenderLayerPlanner) void {
        self.len = 0;
    }

    pub fn buildCompiled(self: *RenderLayerPlanner, plan: anytype, policy: @import("render_resource_policy.zig").Policy) Error!RenderLayerPlan {
        return @import("render_resource_policy.zig").layers(self, plan, policy);
    }

    pub fn build(self: *RenderLayerPlanner, render_plan: anytype) Error!RenderLayerPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .layers = self.layers[0..self.len] };
    }

    fn consume(self: *RenderLayerPlanner, command: anytype, index: usize) Error!void {
        if (!renderCommandNeedsLayer(command)) return;

        if (self.len > 0 and renderLayerCanExtend(self.layers[self.len - 1], command, index)) {
            const layer = &self.layers[self.len - 1];
            layer.command_count += 1;
            layer.id = if (layer.id == command.id) layer.id else null;
            layer.bounds = geometry.RectF.unionWith(layer.bounds.normalized(), command.bounds.normalized());
            layer.fingerprint = renderLayerFingerprintAppend(layer.fingerprint, command);
            return;
        }

        if (self.len >= self.layers.len) return error.LayerListFull;
        self.layers[self.len] = .{
            .command_start = index,
            .command_count = 1,
            .id = command.id,
            .bounds = command.bounds,
            .opacity = command.opacity,
            .clip = command.clip,
            .transform = command.transform,
            .fingerprint = renderLayerFingerprint(command),
        };
        self.len += 1;
    }
};

pub const RenderLayerKey = struct {
    id: ?ObjectId = null,
    command_start: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderLayerCacheEntry = struct {
    key: RenderLayerKey,
    last_used_frame: u64 = 0,
};

pub const RenderLayerCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderLayerCacheAction = struct {
    kind: RenderLayerCacheActionKind,
    key: RenderLayerKey,
    layer_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderLayerCachePlan = struct {
    entries: []const RenderLayerCacheEntry = &.{},
    actions: []const RenderLayerCacheAction = &.{},

    pub fn entryCount(self: RenderLayerCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderLayerCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderLayerCachePlan, kind: RenderLayerCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderLayerCachePlanner = struct {
    entries: []RenderLayerCacheEntry,
    actions: []RenderLayerCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) RenderLayerCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderLayerCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *RenderLayerCachePlanner, plan: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!RenderLayerCachePlan {
        return compiled_cache.build(.layer, RenderLayerCachePlan, self, plan.layers, previous, frame_index, workspace, renderLayerKey, null, error.LayerCacheListFull);
    }

    pub fn build(self: *RenderLayerCachePlanner, layer_plan: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64) Error!RenderLayerCachePlan {
        self.reset();
        for (layer_plan.layers, 0..) |layer, layer_index| {
            const key = renderLayerKey(layer);
            if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderLayerCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .layer_index = layer_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
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

    fn appendEntry(self: *RenderLayerCachePlanner, entry: RenderLayerCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.LayerCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderLayerCachePlanner, action: RenderLayerCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.LayerCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderCommandNeedsLayer(command: anytype) bool {
    return command.opacity != 1 or command.clip != null or !affinesEqual(command.transform, Affine.identity());
}

fn renderLayerCanExtend(layer: RenderLayer, command: anytype, index: usize) bool {
    return layer.command_start + layer.command_count == index and
        layer.opacity == command.opacity and
        optionalRectsEqual(layer.clip, command.clip) and
        affinesEqual(layer.transform, command.transform);
}

fn renderLayerKey(layer: RenderLayer) RenderLayerKey {
    return .{
        .id = layer.id,
        .command_start = if (layer.id == null) layer.command_start else 0,
        .fingerprint = layer.fingerprint,
    };
}

fn findRenderLayerCacheEntry(entries: []const RenderLayerCacheEntry, key: RenderLayerKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderLayerKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderLayerKeysEqual(a: RenderLayerKey, b: RenderLayerKey) bool {
    return a.id == b.id and
        a.command_start == b.command_start and
        a.fingerprint == b.fingerprint;
}
