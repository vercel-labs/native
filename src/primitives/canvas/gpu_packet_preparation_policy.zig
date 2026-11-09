//! Complete copied packet facts. Native owns allocations and retained storage;
//! compiled TypeScript derives identities, duplicate admission and edit flags.
const std = @import("std");
const gpu = @import("gpu.zig");
const canvas = @import("root.zig");
pub const Policy = @import("gpu_planning_policy.zig").Policy;
const allocator = std.heap.page_allocator;
const wire = @import("glyph_atlas_policy.zig");
const word = wire.word;
const put = wire.put;
const Facts = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn deinit(self: *Facts) void {
        self.bytes.deinit(allocator);
    }
    fn appendWord(self: *Facts, value: usize) !void {
        const n = std.math.cast(u32, value) orelse @panic("packet fact exceeds wire range");
        var data: [4]u8 = undefined;
        std.mem.writeInt(u32, &data, n, .little);
        try self.bytes.appendSlice(allocator, &data);
    }
    fn appendWide(self: *Facts, value: u64) !void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(u64, &data, value, .little);
        try self.bytes.appendSlice(allocator, &data);
    }
    fn scalar(self: *Facts, value: f32) !void {
        try self.appendWord(@as(u32, @bitCast(value)));
    }
    fn record(self: *Facts, value: anytype) !void {
        inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| try self.scalar(@field(value, field.name));
    }
    fn optionalRect(self: *Facts, value: anytype) !void {
        try self.appendWord(@intFromBool(value != null));
        if (value) |r| try self.record(r);
    }
    fn command(self: *Facts, value: gpu.CanvasGpuCommand) !void {
        const start = self.bytes.items.len;
        try self.appendWord(0);
        try self.appendWord(@intFromEnum(value.kind));
        try self.appendWord(@intFromEnum(value.cap));
        try self.appendWide(value.command_index);
        try self.appendWord(@intFromBool(value.id != null));
        if (value.id) |id| try self.appendWide(id);
        try self.record(value.bounds);
        try self.scalar(value.opacity);
        try self.scalar(value.stroke_width);
        try self.optionalRect(value.clip);
        try self.record(value.transform);
        try self.appendWord(@intFromEnum(std.meta.activeTag(value.shape)));
        switch (value.shape) {
            .none => {},
            .rect => |r| try self.record(r),
            .rounded_rect => |r| {
                try self.record(r.rect);
                try self.record(r.radius);
            },
            .stroke_rect => |r| {
                try self.record(r.rect);
                try self.record(r.radius);
                try self.scalar(r.width);
            },
            .line => |r| {
                try self.record(r.from);
                try self.record(r.to);
                try self.scalar(r.width);
            },
            .path => |elements| {
                try self.appendWord(elements.len);
                for (elements) |element| {
                    try self.appendWord(@intFromEnum(element.verb));
                    for (element.points) |point| try self.record(point);
                }
            },
        }
        try self.appendWord(@intFromEnum(std.meta.activeTag(value.paint)));
        switch (value.paint) {
            .none => {},
            .color => |c| try self.record(c),
            .linear_gradient => |g| {
                try self.record(g.start);
                try self.record(g.end);
                try self.appendWord(g.stops.len);
                for (g.stops) |stop| {
                    try self.scalar(stop.offset);
                    try self.record(stop.color);
                }
            },
        }
        try self.appendWord(@intFromBool(value.image != null));
        if (value.image) |image| {
            try self.appendWide(image.image_id);
            try self.optionalRect(image.src);
            try self.record(image.dst);
            try self.scalar(image.opacity);
            try self.appendWord(@intFromEnum(image.fit));
            try self.appendWord(@intFromEnum(image.sampling));
            try self.record(image.radius);
        }
        try self.appendWord(@intFromBool(value.text != null));
        if (value.text) |text| {
            try self.appendWide(text.font_id);
            try self.scalar(text.size);
            try self.record(text.origin);
            try self.record(text.color);
            try self.appendWord(text.text.len);
            try self.bytes.appendSlice(allocator, text.text);
            try self.appendWord(text.glyphs.len);
            for (text.glyphs) |glyph| {
                try self.appendWord(glyph.id);
                try self.appendWide(glyph.font_id);
                try self.scalar(glyph.x);
                try self.scalar(glyph.y);
                try self.scalar(glyph.advance);
                try self.appendWide(glyph.text_start);
                try self.appendWide(glyph.text_len);
            }
            try self.appendWord(@intFromBool(text.text_layout != null));
            if (text.text_layout) |options| {
                try self.scalar(options.max_width);
                try self.scalar(options.line_height);
                try self.appendWord(@intFromEnum(options.wrap));
                try self.appendWord(@intFromEnum(options.alignment));
                try self.appendWord(@intFromEnum(options.overflow));
            }
        }
        try self.appendWord(@intFromEnum(std.meta.activeTag(value.effect)));
        switch (value.effect) {
            .none => {},
            .shadow => |s| {
                try self.record(s.rect);
                try self.record(s.radius);
                try self.record(s.offset);
                try self.scalar(s.blur);
                try self.scalar(s.spread);
                try self.record(s.color);
            },
            .blur => |b| {
                try self.record(b.rect);
                try self.scalar(b.radius);
            },
        }
        put(self.bytes.items, start, self.bytes.items.len - start - 4);
    }
};
fn header(facts: *Facts, mode: u8, count: usize, baseline: usize, unique: bool) !void {
    try facts.bytes.appendSlice(allocator, &([_]u8{0} ** 32));
    facts.bytes.items[0..4].* = .{ 71, 1, mode, 0 };
    put(facts.bytes.items, 4, count);
    put(facts.bytes.items, 8, baseline);
    put(facts.bytes.items, 12, @intFromBool(unique));
}
fn resultExtent(mode: u8, current: usize, baseline: usize) usize {
    return std.math.add(usize, 32, if (mode == 0)
        std.math.mul(usize, current, 16) catch @panic("packet result too large")
    else
        std.math.add(usize, current, baseline) catch @panic("packet result too large")) catch @panic("packet result too large");
}
/// Envelope validation only: no native hash, key lookup or semantic verdict
/// is used to validate the compiled result before copying caller storage.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 32 or result.len < 32 or request[0] != 71 or request[1] != 1 or request[2] > 1 or request[3] != 0 or word(result, 0) != 1) return false;
    const current: usize = word(request, 4);
    const baseline: usize = word(request, 8);
    for (request[16..32]) |byte| if (byte != 0) return false;
    // Bound arithmetic by actual storage before computing the extent, also
    // when usize is narrower than the count words' combined byte length.
    if (request[2] == 0) {
        if (current > (result.len - 32) / 16) return false;
    } else {
        if (current > result.len - 32 or baseline > result.len - 32 - current) return false;
    }
    if (result.len != resultExtent(request[2], current, baseline) or word(result, 4) != current) return false;
    if (request[2] == 0) {
        if (baseline != 0 or word(request, 12) > 1 or word(result, 8) > word(request, 12)) return false;
        if (current > (request.len - 32) / 4) return false;
        var at: usize = 32;
        for (0..current) |_| {
            if (request.len - at < 4) return false;
            const length: usize = word(request, at);
            at += 4;
            if (length > request.len - at) return false;
            at += length;
        }
        if (at != request.len) return false;
        for (result[12..32]) |byte| if (byte != 0) return false;
    } else {
        if (current > (request.len - 32) / 16 or baseline > (request.len - 32) / 16 - current or request.len != 32 + (current + baseline) * 16) return false;
        if (word(request, 12) != 0 or word(result, 8) != baseline or word(result, 12) > current or word(result, 16) > baseline) return false;
        for (result[20..32]) |byte| if (byte != 0) return false;
        var upserts: usize = 0;
        var unmatched: usize = 0;
        for (result[32..][0..current]) |flag| {
            if (flag > 1) return false;
            upserts += flag;
        }
        for (result[32 + current ..]) |flag| {
            if (flag > 1) return false;
            unmatched += 1 - flag;
        }
        if (upserts != word(result, 12) or unmatched != word(result, 16)) return false;
    }
    return true;
}

test "packet preparation copied transport rejects unbounded flags counts and reserved bytes" {
    var request: [40]u8 = @splat(0);
    request[0..4].* = .{ 71, 1, 0, 0 };
    put(&request, 4, 2);
    put(&request, 12, 1);
    var result: [64]u8 = @splat(0);
    put(&result, 0, 1);
    put(&result, 4, 2);
    try std.testing.expect(resultValid(&request, &result));
    // Arbitrary identities are allowed: native never recomputes the policy.
    @memset(result[32..], 0xa5);
    put(&result, 8, 1);
    try std.testing.expect(resultValid(&request, &result));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28 }) |at| {
        var bad = result;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 12, 16, 20, 24, 28, 32, 36 }) |at| {
        var bad = request;
        bad[at] = 0xff;
        try std.testing.expect(!resultValid(&bad, &result));
    }
    for (0..result.len) |length| try std.testing.expect(!resultValid(&request, result[0..length]));
    var edits_request: [112]u8 = @splat(0);
    edits_request[0..4].* = .{ 71, 1, 1, 0 };
    put(&edits_request, 4, 3);
    put(&edits_request, 8, 2);
    var edits_result: [37]u8 = @splat(0);
    put(&edits_result, 0, 1);
    put(&edits_result, 4, 3);
    put(&edits_result, 8, 2);
    put(&edits_result, 12, 2);
    put(&edits_result, 16, 1);
    edits_result[32..].* = .{ 1, 0, 1, 0, 1 };
    try std.testing.expect(resultValid(&edits_request, &edits_result));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28 }) |at| {
        var bad = edits_result;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&edits_request, &bad));
    }
    for (32..37) |at| {
        var bad = edits_result;
        bad[at] = 2;
        try std.testing.expect(!resultValid(&edits_request, &bad));
        bad = edits_result;
        bad[at] ^= 1;
        try std.testing.expect(!resultValid(&edits_request, &bad));
    }
}
fn invoke(facts: *Facts, policy: Policy) ![]u8 {
    const request = facts.bytes.items;
    const result = try allocator.alloc(u8, resultExtent(request[2], word(request, 4), word(request, 8)));
    errdefer allocator.free(result);
    @memset(result, 0xa5);
    if (policy(request, result) != result.len or !resultValid(request, result)) @panic("invalid compiled packet preparation result");
    return result;
}
pub const Identity = struct { key: u64, fingerprint: u64 };
pub fn identities(commands: []const gpu.CanvasGpuCommand, output: []Identity, unique: bool, policy: Policy) bool {
    if (output.len != commands.len) @panic("packet identity storage mismatch");
    var facts: Facts = .{};
    defer facts.deinit();
    header(&facts, 0, commands.len, 0, unique) catch @panic("packet fact allocation failed");
    for (commands) |command| facts.command(command) catch @panic("packet fact allocation failed");
    const result = invoke(&facts, policy) catch @panic("packet identity allocation failed");
    defer allocator.free(result);
    for (output, 0..) |*identity, i| identity.* = .{
        .key = std.mem.readInt(u64, result[32 + i * 16 ..][0..8], .little),
        .fingerprint = std.mem.readInt(u64, result[40 + i * 16 ..][0..8], .little),
    };
    return word(result, 8) == 0;
}
pub const Edits = struct { upsert_count: usize, evict_count: usize };
pub fn edits(current: anytype, keys: []const u64, fingerprints: []const u64, matched: []bool, upserts: []bool, policy: Policy) Edits {
    if (keys.len != fingerprints.len or matched.len != keys.len or upserts.len != current.len) @panic("packet edit storage mismatch");
    var facts: Facts = .{};
    defer facts.deinit();
    header(&facts, 1, current.len, keys.len, false) catch @panic("packet edit allocation failed");
    for (current) |entry| {
        facts.appendWide(entry.key) catch @panic("packet edit allocation failed");
        facts.appendWide(entry.fingerprint) catch @panic("packet edit allocation failed");
    }
    for (keys, fingerprints) |key, fingerprint| {
        facts.appendWide(key) catch @panic("packet edit allocation failed");
        facts.appendWide(fingerprint) catch @panic("packet edit allocation failed");
    }
    const result = invoke(&facts, policy) catch @panic("packet edit allocation failed");
    defer allocator.free(result);
    for (upserts, result[32..][0..current.len]) |*slot, flag| slot.* = flag == 1;
    for (matched, result[32 + current.len ..]) |*slot, flag| slot.* = flag == 1;
    return .{ .upsert_count = word(result, 12), .evict_count = word(result, 16) };
}
pub fn gather(commands: []const canvas.RenderCommand, bounds: @import("geometry").RectF, current: anytype, policy: Policy) ?usize {
    return gatherMaterialized(commands, bounds, current, null, policy);
}
/// Preserve the complete compiled payloads through serialization. Their slices
/// borrow the render plan; the caller owns the materialized command storage.
pub fn gatherMaterialized(commands: []const canvas.RenderCommand, bounds: @import("geometry").RectF, current: anytype, materialized: ?[]gpu.CanvasGpuCommand, policy: Policy) ?usize {
    const capacity = @min(commands.len, current.len);
    const packets = allocator.alloc(gpu.CanvasGpuCommand, capacity) catch @panic("packet gather allocation failed");
    defer allocator.free(packets);
    var planner = gpu.CanvasGpuPacketPlanner.init(packets);
    const packet = planner.buildCompiled(canvas.CanvasRenderPass{ .commands = commands, .full_repaint = true, .dirty_bounds = bounds }, policy) catch return null;
    if (packet.unsupported_command_count != 0) return null;
    const identity = allocator.alloc(Identity, packet.commands.len) catch @panic("packet gather identity allocation failed");
    defer allocator.free(identity);
    if (!identities(packet.commands, identity, true, policy)) return null;
    for (packet.commands, identity, current[0..packet.commands.len]) |command, id, *slot| slot.* = .{
        .key = id.key,
        .fingerprint = id.fingerprint,
        .render_index = @intCast(command.command_index),
        .bounds = command.bounds,
    };
    if (materialized) |storage| {
        if (storage.len < packet.commands.len) @panic("retained command storage mismatch");
        @memcpy(storage[0..packet.commands.len], packet.commands);
    }
    return packet.commands.len;
}
