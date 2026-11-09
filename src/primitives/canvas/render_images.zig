const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const fingerprints = @import("render_fingerprints.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const ReferenceImage = canvas.ReferenceImage;
const DrawImage = drawing_model.DrawImage;

pub const RenderImage = struct {
    image_id: ImageId,
    command_index: usize = 0,
    id: ?ObjectId = null,
    draw_count: usize = 0,
    bounds: geometry.RectF = .{},
    width: usize = 0,
    height: usize = 0,
    pixels: []const u8 = &.{},
    fingerprint: u64 = 0,
};

pub const RenderImagePlan = struct {
    images: []const RenderImage = &.{},

    pub fn imageCount(self: RenderImagePlan) usize {
        return self.images.len;
    }

    pub fn drawCount(self: RenderImagePlan) usize {
        var count: usize = 0;
        for (self.images) |image| count += image.draw_count;
        return count;
    }

    pub fn cachePlan(self: RenderImagePlan, previous: []const RenderImageCacheEntry, frame_index: u64, entries: []RenderImageCacheEntry, actions: []RenderImageCacheAction) Error!RenderImageCachePlan {
        var planner = RenderImageCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
    pub fn cachePlanWithWorkspace(self: RenderImagePlan, workspace: ?*compiled_cache.Workspace, previous: []const RenderImageCacheEntry, frame_index: u64, entries: []RenderImageCacheEntry, actions: []RenderImageCacheAction) Error!RenderImageCachePlan {
        var planner = RenderImageCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderImageKey = struct {
    image_id: ImageId,
    fingerprint: u64 = 0,
};

pub const RenderImageCacheEntry = struct {
    key: RenderImageKey,
    last_used_frame: u64 = 0,
};

pub const RenderImageCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderImageCacheAction = struct {
    kind: RenderImageCacheActionKind,
    key: RenderImageKey,
    image_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderImageCachePlan = struct {
    entries: []const RenderImageCacheEntry = &.{},
    actions: []const RenderImageCacheAction = &.{},

    pub fn entryCount(self: RenderImageCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderImageCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderImageCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderImageCachePlan, kind: RenderImageCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderImagePlanner = struct {
    images: []RenderImage,
    image_resources: []const ReferenceImage = &.{},
    len: usize = 0,

    pub fn init(images: []RenderImage) RenderImagePlanner {
        return .{ .images = images };
    }

    pub fn reset(self: *RenderImagePlanner) void {
        self.len = 0;
    }

    pub fn buildCompiled(self: *RenderImagePlanner, plan: anytype, policy: @import("render_resource_policy.zig").Policy) Error!RenderImagePlan {
        return @import("render_resource_policy.zig").images(self, plan, policy);
    }

    pub fn build(self: *RenderImagePlanner, render_plan: anytype) Error!RenderImagePlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .images = self.images[0..self.len] };
    }

    fn consume(self: *RenderImagePlanner, command: anytype, index: usize) Error!void {
        switch (command.command) {
            .draw_image => |value| try self.appendOrExtend(value, command, index),
            else => {},
        }
    }

    fn appendOrExtend(self: *RenderImagePlanner, image: DrawImage, command: anytype, index: usize) Error!void {
        const resource = findReferenceImage(self.image_resources, image.image_id);
        const fingerprint = fingerprints.renderImageFingerprintForResource(image.image_id, resource);
        if (findRenderImage(self.images[0..self.len], image.image_id, fingerprint)) |existing_index| {
            const existing = &self.images[existing_index];
            existing.draw_count += 1;
            existing.id = if (existing.id == command.id) existing.id else null;
            existing.bounds = geometry.RectF.unionWith(existing.bounds.normalized(), command.bounds.normalized());
            return;
        }

        if (self.len >= self.images.len) return error.ImageListFull;
        self.images[self.len] = .{
            .image_id = image.image_id,
            .command_index = index,
            .id = command.id,
            .draw_count = 1,
            .bounds = command.bounds,
            .width = if (resource) |value| value.width else 0,
            .height = if (resource) |value| value.height else 0,
            .pixels = if (resource) |value| value.pixels else &.{},
            .fingerprint = fingerprint,
        };
        self.len += 1;
    }
};

pub const RenderImageCachePlanner = struct {
    entries: []RenderImageCacheEntry,
    actions: []RenderImageCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderImageCacheEntry, actions: []RenderImageCacheAction) RenderImageCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderImageCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *RenderImageCachePlanner, plan: RenderImagePlan, previous: []const RenderImageCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!RenderImageCachePlan {
        return compiled_cache.build(.image, RenderImageCachePlan, self, plan.images, previous, frame_index, workspace, renderImageKey, null, error.ImageCacheListFull);
    }

    pub fn build(self: *RenderImageCachePlanner, image_plan: RenderImagePlan, previous: []const RenderImageCacheEntry, frame_index: u64) Error!RenderImageCachePlan {
        self.reset();
        for (image_plan.images, 0..) |image, image_index| {
            const key = renderImageKey(image);
            if (findRenderImageCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderImageCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .image_index = image_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderImageCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
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

    fn appendEntry(self: *RenderImageCachePlanner, entry: RenderImageCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.ImageCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderImageCachePlanner, action: RenderImageCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.ImageCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderImageKey(image: RenderImage) RenderImageKey {
    return .{
        .image_id = image.image_id,
        .fingerprint = image.fingerprint,
    };
}

fn findRenderImage(images: []const RenderImage, image_id: ImageId, fingerprint: u64) ?usize {
    for (images, 0..) |image, index| {
        if (image.image_id == image_id and image.fingerprint == fingerprint) return index;
    }
    return null;
}

fn findRenderImageCacheEntry(entries: []const RenderImageCacheEntry, key: RenderImageKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderImageKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderImageKeysEqual(a: RenderImageKey, b: RenderImageKey) bool {
    return a.image_id == b.image_id and
        a.fingerprint == b.fingerprint;
}

fn findReferenceImage(images: []const ReferenceImage, id: ImageId) ?ReferenceImage {
    for (images) |image| {
        if (image.id == id) return image;
    }
    return null;
}
