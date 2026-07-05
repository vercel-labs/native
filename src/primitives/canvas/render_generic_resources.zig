const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const fingerprints = @import("render_fingerprints.zig");
const plan_key_index = @import("plan_key_index.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const shadowBounds = drawing_model.shadowBounds;
const textBounds = text_model.textBounds;

const drawImageFingerprint = fingerprints.drawImageFingerprint;
const drawTextFingerprint = fingerprints.drawTextFingerprint;
const linearGradientFingerprint = fingerprints.linearGradientFingerprint;
const shadowFingerprint = fingerprints.shadowFingerprint;
const blurFingerprint = fingerprints.blurFingerprint;
const nonZeroObjectId = fingerprints.nonZeroObjectId;
const nonNegative = fingerprints.nonNegative;

pub const RenderResourceKind = enum {
    linear_gradient,
    image,
    glyph_run,
    shadow,
    blur,
};

pub const RenderResource = struct {
    kind: RenderResourceKind,
    command_index: usize,
    id: ?ObjectId = null,
    bounds: ?geometry.RectF = null,
    image_id: ImageId = 0,
    font_id: FontId = 0,
    gradient_stop_count: usize = 0,
    glyph_count: usize = 0,
    text_len: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderResourcePlan = struct {
    resources: []const RenderResource = &.{},

    pub fn resourceCount(self: RenderResourcePlan) usize {
        return self.resources.len;
    }

    pub fn cachePlan(self: RenderResourcePlan, previous: []const RenderResourceCacheEntry, frame_index: u64, entries: []RenderResourceCacheEntry, actions: []RenderResourceCacheAction) Error!RenderResourceCachePlan {
        var planner = RenderResourceCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderResourcePlanner = struct {
    resources: []RenderResource,
    len: usize = 0,

    pub fn init(resources: []RenderResource) RenderResourcePlanner {
        return .{ .resources = resources };
    }

    pub fn reset(self: *RenderResourcePlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderResourcePlanner, display_list: anytype) Error!RenderResourcePlan {
        self.reset();
        for (display_list.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .resources = self.resources[0..self.len] };
    }

    fn consume(self: *RenderResourcePlanner, command: anytype, index: usize) Error!void {
        switch (command) {
            .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform => {},
            .fill_rect => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .stroke_rect => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .fill_rounded_rect => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .draw_line => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .fill_path => |value| try self.consumeFill(value.fill, index, value.id, command.bounds()),
            .stroke_path => |value| try self.consumeStroke(value.stroke, index, value.id, command.bounds()),
            .draw_image => |value| try self.append(.{
                .kind = .image,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.dst.normalized(),
                .image_id = value.image_id,
                .fingerprint = drawImageFingerprint(value),
            }),
            .draw_text => |value| try self.append(.{
                .kind = .glyph_run,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = textBounds(value),
                .font_id = value.font_id,
                .glyph_count = value.glyphs.len,
                .text_len = value.text.len,
                .fingerprint = drawTextFingerprint(value),
            }),
            .shadow => |value| try self.append(.{
                .kind = .shadow,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = shadowBounds(value),
                .fingerprint = shadowFingerprint(value),
            }),
            .blur => |value| try self.append(.{
                .kind = .blur,
                .command_index = index,
                .id = nonZeroObjectId(value.id),
                .bounds = value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
                .fingerprint = blurFingerprint(value),
            }),
        }
    }

    fn consumeStroke(self: *RenderResourcePlanner, stroke: Stroke, index: usize, id: ObjectId, bounds: ?geometry.RectF) Error!void {
        try self.consumeFill(stroke.fill, index, id, bounds);
    }

    fn consumeFill(self: *RenderResourcePlanner, fill: Fill, index: usize, id: ObjectId, bounds: ?geometry.RectF) Error!void {
        switch (fill) {
            .color => {},
            .linear_gradient => |gradient| try self.append(.{
                .kind = .linear_gradient,
                .command_index = index,
                .id = nonZeroObjectId(id),
                .bounds = bounds,
                .gradient_stop_count = gradient.stops.len,
                .fingerprint = linearGradientFingerprint(gradient),
            }),
        }
    }

    fn append(self: *RenderResourcePlanner, resource: RenderResource) Error!void {
        if (self.len >= self.resources.len) return error.RenderResourceListFull;
        self.resources[self.len] = resource;
        self.len += 1;
    }
};

pub const RenderResourceKey = struct {
    kind: RenderResourceKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    image_id: ImageId = 0,
    font_id: FontId = 0,
    fingerprint: u64 = 0,
};

pub const RenderResourceCacheEntry = struct {
    key: RenderResourceKey,
    last_used_frame: u64 = 0,
};

pub const RenderResourceCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderResourceCacheAction = struct {
    kind: RenderResourceCacheActionKind,
    key: RenderResourceKey,
    resource_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderResourceCachePlan = struct {
    entries: []const RenderResourceCacheEntry = &.{},
    actions: []const RenderResourceCacheAction = &.{},

    pub fn entryCount(self: RenderResourceCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderResourceCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderResourceCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderResourceCachePlan, kind: RenderResourceCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderResourceCachePlanner = struct {
    entries: []RenderResourceCacheEntry,
    actions: []RenderResourceCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderResourceCacheEntry, actions: []RenderResourceCacheAction) RenderResourceCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderResourceCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn build(self: *RenderResourceCachePlanner, resource_plan: RenderResourcePlan, previous: []const RenderResourceCacheEntry, frame_index: u64) Error!RenderResourceCachePlan {
        self.reset();
        // Keyed lookups ride the probe-table index whenever the inputs
        // fit its half-full bound (the runtime budgets always do);
        // oversized library inputs keep the linear scans. Same outputs
        // either way — the index resolves to the lowest-index equal
        // entry exactly like the scans it replaces.
        const use_index = (resource_plan.resources.len >= plan_key_index.min_entries_for_index or
            previous.len >= plan_key_index.min_entries_for_index) and
            plan_key_index.fitsHashSlots(resource_cache_index_slots, previous.len) and
            plan_key_index.fitsHashSlots(resource_cache_index_slots, resource_plan.resources.len);
        if (use_index) {
            resource_cache_previous_index.reset();
            for (previous, 0..) |entry, index| {
                var p = ResourceCacheIndex.probe(renderResourceKeyHash(entry.key));
                while (resource_cache_previous_index.next(&p)) |_| {}
                resource_cache_previous_index.insert(p, @intCast(index));
            }
            resource_cache_entry_index.reset();
        }

        for (resource_plan.resources, 0..) |resource, resource_index| {
            const key = renderResourceKey(resource);
            const key_hash = if (use_index) renderResourceKeyHash(key) else 0;
            if (use_index) {
                var p = ResourceCacheIndex.probe(key_hash);
                var duplicate = false;
                while (resource_cache_entry_index.next(&p)) |candidate| {
                    if (renderResourceKeysEqual(self.entries[candidate].key, key)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                const previous_index = findRenderResourceCacheEntryIndexed(previous, key, key_hash);
                try self.appendAction(.{
                    .kind = if (previous_index == null) .upload else .retain,
                    .key = key,
                    .resource_index = resource_index,
                    .cache_index = previous_index,
                });
                try self.appendEntry(.{
                    .key = key,
                    .last_used_frame = frame_index,
                });
                resource_cache_entry_index.insert(p, @intCast(self.entry_len - 1));
                continue;
            }
            if (findRenderResourceCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderResourceCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .resource_index = resource_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (use_index) {
                var p = ResourceCacheIndex.probe(renderResourceKeyHash(entry.key));
                var kept = false;
                while (resource_cache_entry_index.next(&p)) |candidate| {
                    if (renderResourceKeysEqual(self.entries[candidate].key, entry.key)) {
                        kept = true;
                        break;
                    }
                }
                if (kept) continue;
            } else if (findRenderResourceCacheEntry(self.entries[0..self.entry_len], entry.key) != null) {
                continue;
            }
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

    fn appendEntry(self: *RenderResourceCachePlanner, entry: RenderResourceCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.RenderResourceCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderResourceCachePlanner, action: RenderResourceCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.RenderResourceCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderResourceKey(resource: RenderResource) RenderResourceKey {
    return .{
        .kind = resource.kind,
        .id = resource.id,
        .command_index = if (resource.id == null and resource.kind != .image) resource.command_index else 0,
        .image_id = resource.image_id,
        .font_id = resource.font_id,
        .fingerprint = resource.fingerprint,
    };
}

fn findRenderResourceCacheEntry(entries: []const RenderResourceCacheEntry, key: RenderResourceKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderResourceKeysEqual(entry.key, key)) return index;
    }
    return null;
}

/// Probe-table scratch for the cache planner (see plan_key_index.zig):
/// sized for the runtime's per-view resource budget (2048) at the
/// half-full bound; bigger inputs fall back to the linear scans.
const resource_cache_index_slots = 4096;
const ResourceCacheIndex = plan_key_index.HashSlots(resource_cache_index_slots);
threadlocal var resource_cache_previous_index: ResourceCacheIndex = .{};
threadlocal var resource_cache_entry_index: ResourceCacheIndex = .{};

/// The chain's first equal candidate is the lowest-index equal entry —
/// the exact value the linear scan returned.
fn findRenderResourceCacheEntryIndexed(previous: []const RenderResourceCacheEntry, key: RenderResourceKey, key_hash: u64) ?usize {
    var p = ResourceCacheIndex.probe(key_hash);
    while (resource_cache_previous_index.next(&p)) |candidate| {
        if (renderResourceKeysEqual(previous[candidate].key, key)) return candidate;
    }
    return null;
}

fn renderResourceKeyHash(key: RenderResourceKey) u64 {
    var hash = plan_key_index.mixHash(key.fingerprint ^ @as(u64, @intFromEnum(key.kind)));
    hash = plan_key_index.mixHash(hash ^ @as(u64, key.id orelse 0) ^ @as(u64, @intCast(key.command_index)));
    hash = plan_key_index.mixHash(hash ^ @as(u64, key.image_id) ^ @as(u64, key.font_id) ^ @as(u64, @intFromBool(key.id != null)));
    return hash;
}

fn renderResourceKeysEqual(a: RenderResourceKey, b: RenderResourceKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.image_id == b.image_id and
        a.font_id == b.font_id and
        a.fingerprint == b.fingerprint;
}
