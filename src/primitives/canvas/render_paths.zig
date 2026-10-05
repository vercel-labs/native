const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const hash_model = @import("hash.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Affine = drawing_model.Affine;
const PathElement = drawing_model.PathElement;

const path_geometry_curve_segments: usize = 12;
const resourceHashTag = hash_model.resourceHashTag;
const resourceHashBytes = hash_model.resourceHashBytes;
const resourceHashF32 = hash_model.resourceHashF32;
const resourceHashAffine = hash_model.resourceHashAffine;
const resourceHashOptionalObjectId = hash_model.resourceHashOptionalObjectId;
const resourceHashPath = hash_model.resourceHashPath;

pub const RenderPathGeometryKind = enum {
    fill,
    stroke,
};

pub const RenderPathGeometry = struct {
    kind: RenderPathGeometryKind,
    command_index: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    element_count: usize = 0,
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
    stroke_width: f32 = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryPlan = struct {
    geometries: []const RenderPathGeometry = &.{},

    pub fn geometryCount(self: RenderPathGeometryPlan) usize {
        return self.geometries.len;
    }

    pub fn vertexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.vertex_count;
        return count;
    }

    pub fn indexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.index_count;
        return count;
    }

    pub fn cachePlan(self: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) Error!RenderPathGeometryCachePlan {
        var planner = RenderPathGeometryCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
    pub fn cachePlanWithWorkspace(self: RenderPathGeometryPlan, workspace: ?*compiled_cache.Workspace, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) Error!RenderPathGeometryCachePlan {
        var planner = RenderPathGeometryCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderPathGeometryPlanner = struct {
    geometries: []RenderPathGeometry,
    len: usize = 0,

    pub fn init(geometries: []RenderPathGeometry) RenderPathGeometryPlanner {
        return .{ .geometries = geometries };
    }

    pub fn reset(self: *RenderPathGeometryPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderPathGeometryPlanner, render_plan: anytype) Error!RenderPathGeometryPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .geometries = self.geometries[0..self.len] };
    }

    fn consume(self: *RenderPathGeometryPlanner, command: anytype, index: usize) Error!void {
        switch (command.command) {
            .fill_path => |value| try self.consumePath(.fill, command, index, value.elements, 0),
            .stroke_path => |value| {
                const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
                if (stroke_width <= 0) return;
                try self.consumePath(.stroke, command, index, value.elements, stroke_width);
            },
            else => {},
        }
    }

    fn consumePath(self: *RenderPathGeometryPlanner, kind: RenderPathGeometryKind, command: anytype, index: usize, elements: []const PathElement, stroke_width: f32) Error!void {
        const counts = analyzePathGeometry(elements, kind);
        if (counts.vertex_count == 0 or counts.index_count == 0) return;
        if (self.len >= self.geometries.len) return error.PathGeometryListFull;
        self.geometries[self.len] = .{
            .kind = kind,
            .command_index = index,
            .id = command.id,
            .bounds = command.bounds,
            .element_count = elements.len,
            .contour_count = counts.contour_count,
            .line_segment_count = counts.line_segment_count,
            .quadratic_segment_count = counts.quadratic_segment_count,
            .cubic_segment_count = counts.cubic_segment_count,
            .flattened_segment_count = counts.flattened_segment_count,
            .vertex_count = counts.vertex_count,
            .index_count = counts.index_count,
            .stroke_width = stroke_width,
            .fingerprint = renderPathGeometryFingerprint(command, kind, elements, stroke_width),
        };
        self.len += 1;
    }
};

pub const PathGeometryCounts = struct {
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
};

pub fn analyzePathGeometry(elements: []const PathElement, kind: RenderPathGeometryKind) PathGeometryCounts {
    var counts = PathGeometryCounts{};
    var has_current = false;

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                counts.contour_count += 1;
                counts.vertex_count += 1;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    counts.contour_count += 1;
                    counts.vertex_count += 1;
                    has_current = true;
                    continue;
                }
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
                counts.vertex_count += 1;
            },
            .quad_to => {
                if (!has_current) continue;
                counts.quadratic_segment_count += 1;
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
            },
            .cubic_to => {
                if (!has_current) continue;
                counts.cubic_segment_count += 1;
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
            },
            .close => {
                if (!has_current) continue;
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
            },
        }
    }

    switch (kind) {
        .fill => {
            counts.index_count = if (counts.vertex_count >= 3) (counts.vertex_count - 2) * 3 else 0;
        },
        .stroke => {
            counts.vertex_count = counts.flattened_segment_count * 4;
            counts.index_count = counts.flattened_segment_count * 6;
        },
    }
    return counts;
}

fn renderPathGeometryKey(geometry_plan: RenderPathGeometry) RenderPathGeometryKey {
    return .{
        .kind = geometry_plan.kind,
        .id = geometry_plan.id,
        .command_index = if (geometry_plan.id == null) geometry_plan.command_index else 0,
        .fingerprint = geometry_plan.fingerprint,
    };
}

fn findRenderPathGeometryCacheEntry(entries: []const RenderPathGeometryCacheEntry, key: RenderPathGeometryKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderPathGeometryKeysEqual(entry.key, key)) return index;
    }
    return null;
}

fn renderPathGeometryKeysEqual(a: RenderPathGeometryKey, b: RenderPathGeometryKey) bool {
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.fingerprint == b.fingerprint;
}

fn renderPathGeometryFingerprint(command: anytype, kind: RenderPathGeometryKind, elements: []const PathElement, stroke_width: f32) u64 {
    var hash = resourceHashTag("path_geometry");
    hash = resourceHashBytes(hash, @tagName(kind));
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashAffine(hash, command.transform);
    hash = resourceHashPath(hash, elements);
    hash = resourceHashF32(hash, stroke_width);
    return hash;
}

pub const RenderPathGeometryKey = struct {
    kind: RenderPathGeometryKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryCacheEntry = struct {
    key: RenderPathGeometryKey,
    last_used_frame: u64 = 0,
};

pub const RenderPathGeometryCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderPathGeometryCacheAction = struct {
    kind: RenderPathGeometryCacheActionKind,
    key: RenderPathGeometryKey,
    geometry_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderPathGeometryCachePlan = struct {
    entries: []const RenderPathGeometryCacheEntry = &.{},
    actions: []const RenderPathGeometryCacheAction = &.{},

    pub fn entryCount(self: RenderPathGeometryCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderPathGeometryCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderPathGeometryCachePlan, kind: RenderPathGeometryCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderPathGeometryCachePlanner = struct {
    entries: []RenderPathGeometryCacheEntry,
    actions: []RenderPathGeometryCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) RenderPathGeometryCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderPathGeometryCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *RenderPathGeometryCachePlanner, plan: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!RenderPathGeometryCachePlan {
        return compiled_cache.build(.path, RenderPathGeometryCachePlan, self, plan.geometries, previous, frame_index, workspace, renderPathGeometryKey, null, error.PathGeometryCacheListFull);
    }

    pub fn build(self: *RenderPathGeometryCachePlanner, geometry_plan: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64) Error!RenderPathGeometryCachePlan {
        self.reset();
        for (geometry_plan.geometries, 0..) |geometry_plan_item, geometry_index| {
            const key = renderPathGeometryKey(geometry_plan_item);
            if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderPathGeometryCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .geometry_index = geometry_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], entry.key) != null) continue;
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

    fn appendEntry(self: *RenderPathGeometryCachePlanner, entry: RenderPathGeometryCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.PathGeometryCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderPathGeometryCachePlanner, action: RenderPathGeometryCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.PathGeometryCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn referenceTransformScale(transform: Affine) f32 {
    const x_scale = @sqrt(transform.a * transform.a + transform.b * transform.b);
    const y_scale = @sqrt(transform.c * transform.c + transform.d * transform.d);
    return @max(0.0001, @max(x_scale, y_scale));
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
