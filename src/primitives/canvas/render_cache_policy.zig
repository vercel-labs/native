const std = @import("std");

pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Family = enum(u8) { pipeline, path, image, layer, resource, effect };

/// One native-owned pair of copied buffers, reused by ordered render planning and cache
/// calls in a frame. Resources and committed core storage never cross the ABI.
pub const Workspace = struct {
    policy: Policy,
    request: []u8,
    result: []u8,

    pub fn init(policy: Policy, max_facts: usize, max_entries: usize, max_actions: usize) Workspace {
        return .{
            .policy = policy,
            .request = std.heap.page_allocator.alloc(u8, 24 + max_facts * 56) catch @panic("render cache request allocation failed"),
            .result = std.heap.page_allocator.alloc(u8, 16 + max_entries * 4 + max_actions * 12) catch @panic("render cache result allocation failed"),
        };
    }

    pub fn initPlanning(policy: Policy, command_count: usize, batch_count: usize) Workspace {
        return initBytes(policy, 16 + command_count * 48 + 864 + command_count * 68, @max(864 + command_count * 68, 32 + batch_count * 52));
    }

    pub fn initOverrides(policy: Policy, first: usize, second: usize, commands: usize, entries: usize, capacity: usize) Workspace {
        return initBytes(policy, 32 + (first + second) * 40 + commands * 92 + entries * 28, @max(64 + commands * 44, 16 + @min(first + second, capacity) * 4));
    }

    pub fn initDamage(policy: Policy, changes: usize, commands: usize, baseline: usize, current: usize) Workspace {
        const bytes = damageBytes(changes, commands, baseline, current);
        return initBytes(policy, bytes[0], bytes[1]);
    }

    fn damageBytes(changes: usize, commands: usize, baseline: usize, current: usize) [2]usize {
        const rect_bytes = @import("frame.zig").max_canvas_frame_dirty_rects * 16;
        return .{ @max(128 + changes * 20 + commands * 68 + rect_bytes, 128 + (baseline + current) * 32), 64 + rect_bytes + baseline * 2 + current };
    }

    fn initBytes(policy: Policy, request_bytes: usize, result_bytes: usize) Workspace {
        return .{
            .policy = policy,
            .request = std.heap.page_allocator.alloc(u8, request_bytes) catch @panic("render request allocation failed"),
            .result = std.heap.page_allocator.alloc(u8, result_bytes) catch @panic("render result allocation failed"),
        };
    }

    pub fn forFrame(policy: ?Policy, storage: anytype, options: anytype, command_count: usize) ?Workspace {
        return forFrameWithOverrides(policy, storage, options, command_count, 0, 0, 0, 0);
    }

    pub fn forFrameWithOverrides(policy: ?Policy, storage: anytype, options: anytype, command_count: usize, scheduled_count: usize, dirty_count: usize, merge_capacity: usize, baseline_count: usize) ?Workspace {
        const owner = policy orelse options.render_plan_policy orelse options.render_override_policy orelse options.render_damage_policy orelse return null;
        var facts: usize = 0;
        var entries: usize = 0;
        var actions: usize = 0;
        inline for (.{
            .{ "render_batches", "pipeline" }, .{ "path_geometries", "path_geometry" },
            .{ "images", "image" },            .{ "layers", "layer" },
            .{ "resources", "resource" },      .{ "visual_effects", "visual_effect" },
        }) |fields| {
            const current = @field(storage, fields[0]).len;
            const total = current + @field(options, "previous_" ++ fields[1] ++ "_cache").len;
            facts = @max(facts, total);
            entries = @max(entries, @min(current, @field(storage, fields[1] ++ "_cache_entries").len));
            actions = @max(actions, @min(total, @field(storage, fields[1] ++ "_cache_actions").len));
        }
        var request_bytes = 24 + facts * 56;
        var result_bytes = 16 + entries * 4 + actions * 12;
        if (options.render_plan_policy != null) {
            const draws = @min(command_count, storage.render_commands.len);
            request_bytes = @max(request_bytes, 16 + command_count * 48 + 864 + draws * 68);
            result_bytes = @max(result_bytes, @max(864 + draws * 68, 32 + @min(draws, storage.render_batches.len) * 52));
        }
        if (options.render_override_policy != null) {
            const draws = @min(command_count, storage.render_commands.len);
            const merged = scheduled_count + options.render_overrides.len;
            request_bytes = @max(request_bytes, 32 + (options.previous_render_overrides.len + merged) * 40 + draws * 92 + dirty_count * 28);
            result_bytes = @max(result_bytes, @max(64 + draws * 44, 16 + @min(merged, merge_capacity) * 4));
        }
        if (options.render_damage_policy != null) {
            const bytes = damageBytes(storage.changes.len, @min(command_count, storage.render_commands.len), baseline_count, @min(command_count, storage.render_commands.len));
            request_bytes = @max(request_bytes, bytes[0]);
            result_bytes = @max(result_bytes, bytes[1]);
        }
        return initBytes(owner, request_bytes, result_bytes);
    }

    pub fn deinit(self: Workspace) void {
        std.heap.page_allocator.free(self.request);
        std.heap.page_allocator.free(self.result);
    }
};

/// The native key and hash functions supply representation/resource facts.
/// The compiled owner decides matching, ordering and every capacity transition.
pub fn build(comptime family: Family, comptime Result: type, planner: anytype, current: anytype, previous: anytype, frame: u64, workspace: *Workspace, comptime keyFn: anytype, comptime hashFn: anytype, comptime full: anytype) @TypeOf(full)!Result {
    planner.reset();
    const total = current.len + previous.len;
    const request_length = 24 + total * 56;
    const result_capacity = 16 + @min(planner.entries.len, current.len) * 4 + @min(planner.actions.len, total) * 12;
    if (request_length > workspace.request.len or result_capacity > workspace.result.len) @panic("render cache workspace too small");
    const request = workspace.request[0..request_length];
    @memset(request, 0);
    request[0] = 12;
    request[1] = @intFromEnum(family);
    putWord(request, 4, current.len);
    putWord(request, 8, previous.len);
    putWord(request, 12, planner.entries.len);
    putWord(request, 16, planner.actions.len);
    for (current, 0..) |item, i| {
        const key = keyFn(item);
        fact(request[24 + i * 56 ..][0..56], key, if (comptime family == .resource) hashFn(key) else 0);
    }
    for (previous, 0..) |item, i| {
        const key = if (comptime family == .pipeline) item.pipeline else item.key;
        fact(request[24 + (current.len + i) * 56 ..][0..56], key, if (comptime family == .resource) hashFn(key) else 0);
    }
    const result = workspace.result[0..result_capacity];
    const length = workspace.policy(request, result);
    if (length < 16 or length > result.len) @panic("truncated compiled render cache result");
    const entry_count = word(result, 0);
    const action_count = word(result, 4);
    const failed = word(result, 8);
    if (failed > 1 or word(result, 12) != 0 or entry_count > @min(planner.entries.len, current.len) or action_count > @min(planner.actions.len, total) or length != 16 + @as(usize, entry_count) * 4 + @as(usize, action_count) * 12) @panic("invalid compiled render cache result");
    for (0..entry_count) |i| {
        const source = word(result, 16 + i * 4);
        if (source >= current.len) @panic("invalid compiled render cache entry source");
        const key = keyFn(current[source]);
        planner.entries[i] = if (comptime family == .pipeline) .{ .pipeline = key, .last_used_frame = frame } else .{ .key = key, .last_used_frame = frame };
    }
    planner.entry_len = entry_count;
    for (0..action_count) |i| {
        const at = 16 + @as(usize, entry_count) * 4 + i * 12;
        const kind = word(result, at);
        const source = word(result, at + 4);
        const cache = word(result, at + 8);
        if (kind > 2 or source >= total or (cache != 0xffffffff and cache >= previous.len) or (kind == 2) != (source >= current.len) or (kind == 0) != (cache == 0xffffffff)) @panic("invalid compiled render cache action");
        const key = if (source < current.len) keyFn(current[source]) else if (comptime family == .pipeline) previous[source - current.len].pipeline else previous[source - current.len].key;
        var action: @TypeOf(planner.actions[0]) = undefined;
        action.kind = @enumFromInt(kind);
        if (comptime family == .pipeline) action.pipeline = key else action.key = key;
        @field(action, switch (family) {
            .pipeline => "batch_index",
            .path => "geometry_index",
            .image => "image_index",
            .layer => "layer_index",
            .resource => "resource_index",
            .effect => "effect_index",
        }) = if (source < current.len) source else null;
        action.cache_index = if (cache == 0xffffffff) null else cache;
        planner.actions[i] = action;
    }
    planner.action_len = action_count;
    if (failed == 1) return full;
    return .{ .entries = planner.entries[0..entry_count], .actions = planner.actions[0..action_count] };
}

fn fact(bytes: []u8, key: anytype, hash: u64) void {
    const T = @TypeOf(key);
    if (comptime @typeInfo(T) == .@"enum") {
        putWord(bytes, 0, @intFromEnum(key));
    } else {
        if (comptime @hasField(T, "kind")) putWord(bytes, 0, @intFromEnum(key.kind));
        if (comptime @hasField(T, "id")) {
            putWord(bytes, 4, @intFromBool(key.id != null));
            putInt(bytes, 8, key.id orelse 0);
        }
        if (comptime @hasField(T, "command_index")) putInt(bytes, 16, key.command_index);
        if (comptime @hasField(T, "command_start")) putInt(bytes, 16, key.command_start);
        if (comptime @hasField(T, "image_id")) putInt(bytes, 24, key.image_id);
        if (comptime @hasField(T, "font_id")) putInt(bytes, 32, key.font_id);
        putInt(bytes, 40, key.fingerprint);
    }
    putWord(bytes, 48, @intCast(hash & 0xffffffff));
}
fn putWord(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("render cache wire integer overflow"), .little);
}
fn putInt(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
